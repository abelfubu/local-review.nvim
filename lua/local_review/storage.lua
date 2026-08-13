local M = {}

local function opts()
  return require("local_review").get_opts()
end

local function ensure_dir(path)
  vim.fn.mkdir(path, "p")
end

local function scope_key(scope_root)
  return vim.fn.sha256(scope_root)
end

---@class LocalReviewStorageState
---@field hash string|nil

---Per-scope in-memory fingerprint of the file that was last loaded or saved
---by this process. Used to detect concurrent modifications by another Neovim
---instance or external process.
---@type table<string, LocalReviewStorageState>
local last_known = {}

local function file_hash(path)
  if vim.fn.filereadable(path) == 0 then
    return nil
  end

  local lines = vim.fn.readfile(path)
  return vim.fn.sha256(table.concat(lines, "\n"))
end

local function load_json(path)
  if vim.fn.filereadable(path) == 0 then
    return { comments = {} }
  end

  local lines = vim.fn.readfile(path)
  local ok, decoded = pcall(vim.json.decode, table.concat(lines, "\n"))
  if not ok or type(decoded) ~= "table" then
    return { comments = {} }
  end

  decoded.comments = type(decoded.comments) == "table" and decoded.comments or {}
  return decoded
end

function M.scope_file(scope_root)
  local base = opts().storage_dir
  return string.format("%s/%s.json", base, scope_key(scope_root))
end

function M.load_scope(scope_root)
  local path = M.scope_file(scope_root)
  local data = load_json(path)

  -- Record the disk fingerprint so subsequent writes can detect clobbering.
  last_known[scope_root] = { hash = file_hash(path) }

  return data
end

local function present_binding(binding)
  if not binding then
    return nil
  end

  if binding.kind == "branch" and binding.name and binding.name ~= "" then
    return binding
  end

  if binding.kind == "commit" and binding.commit and binding.commit ~= "" then
    return binding
  end

  return nil
end

local function same_binding(left, right)
  if not left or not right then
    return false
  end

  if left.kind ~= right.kind then
    return false
  end

  if left.kind == "branch" then
    return left.name == right.name
  end

  return left.commit == right.commit
end

local function binding_label(binding)
  if binding.kind == "branch" then
    return binding.name
  end

  return binding.commit
end

local LOCK_TIMEOUT_MS = 5000
local LOCK_POLL_MS = 20
local STALE_GRACE_MS = 5000

local function lock_path(scope_root)
  return M.scope_file(scope_root) .. ".lock"
end

local function owner_json_path(lock)
  return string.format("%s/owner.json", lock)
end

local function random_token()
  local bytes = vim.uv.random(16)
  if not bytes then
    bytes = vim.fn.sha256(tostring(vim.uv.hrtime()) .. tostring(math.random()))
  end
  local hex = {}
  for i = 1, #bytes do
    table.insert(hex, string.format("%02x", string.byte(bytes, i)))
  end
  return table.concat(hex)
end

local function make_owner()
  return {
    pid = vim.uv.os_getpid(),
    token = random_token(),
    created_at = os.time(),
  }
end

local function write_owner(lock, owner)
  local path = owner_json_path(lock)
  vim.fn.writefile({ vim.json.encode(owner) }, path)
end

local function read_owner(lock)
  local path = owner_json_path(lock)
  if vim.fn.filereadable(path) == 0 then
    return nil
  end

  local lines = vim.fn.readfile(path)
  local ok, decoded = pcall(vim.json.decode, table.concat(lines, "\n"))
  if ok and type(decoded) == "table" and type(decoded.pid) == "number" and type(decoded.token) == "string" then
    return decoded
  end

  return nil
end

local function owner_alive(owner)
  local ok, _, errname = vim.uv.kill(owner.pid, 0)
  if ok then
    return true
  end

  if errname == "EPERM" then
    return true
  end

  return false
end

local function lock_age_seconds(lock)
  local stat = vim.uv.fs_stat(lock)
  if not stat or not stat.mtime then
    return 0
  end

  return os.time() - stat.mtime.sec
end

local function release_lock(lock, owner)
  local disk_owner = read_owner(lock)
  if disk_owner and disk_owner.token ~= owner.token then
    return false
  end

  vim.fn.delete(lock, "rf")
  return true
end

local function reclaim_lock(lock, owner)
  local stat = vim.uv.fs_stat(lock)
  if not stat or stat.type ~= "directory" then
    return false
  end

  local disk_owner = read_owner(lock)
  if disk_owner then
    if owner_alive(disk_owner) then
      return false
    end
  else
    local grace_seconds = math.ceil((M._test_config.stale_grace_ms or STALE_GRACE_MS) / 1000)
    if lock_age_seconds(lock) < grace_seconds then
      return false
    end
  end

  local tomb = string.format("%s.stale.%s.%s", lock, owner.pid, owner.token)
  local renamed = vim.uv.fs_rename(lock, tomb)
  if not renamed then
    return false
  end

  vim.fn.delete(tomb, "rf")
  return true
end

local function hrtime_ms()
  return math.floor(vim.uv.hrtime() / 1e6)
end

local function acquire_lock(scope_root, owner)
  local lock = lock_path(scope_root)
  local timeout_ms = M._test_config.lock_timeout_ms or LOCK_TIMEOUT_MS
  local poll_ms = LOCK_POLL_MS
  local deadline = hrtime_ms() + timeout_ms

  while true do
    local created = vim.uv.fs_mkdir(lock, 448)
    if created then
      write_owner(lock, owner)
      return true
    end

    local stat = vim.uv.fs_stat(lock)
    if stat and stat.type == "directory" then
      if reclaim_lock(lock, owner) then
        -- retry mkdir on the next loop iteration
      else
        if hrtime_ms() >= deadline then
          return nil, string.format("Timed out waiting for scope lock for %s.", scope_root)
        end
        vim.uv.sleep(poll_ms)
      end
    else
      return nil, string.format("Scope lock path %s is not a directory.", lock)
    end
  end
end

local function atomic_write(path, contents, owner)
  local tmp = string.format("%s.%s.tmp", path, owner.token)
  local fd = vim.uv.fs_open(tmp, "wx", 384)
  if not fd then
    return nil, string.format("Failed to create temporary file %s.", tmp)
  end

  local written = vim.uv.fs_write(fd, contents, -1)
  local close_ok = vim.uv.fs_close(fd)
  if not written or written ~= #contents or not close_ok then
    vim.fn.delete(tmp)
    return nil, string.format("Failed to write temporary file %s.", tmp)
  end

  local renamed = vim.uv.fs_rename(tmp, path)
  if not renamed then
    vim.fn.delete(tmp)
    return nil, string.format("Failed to rename temporary file to %s.", path)
  end

  return true
end

---overlap and preserving the order of `save_comments` before appending any
---disk-only comments.
---@param save_comments table
---@param disk_comments table
---@return table
local function merge_comments(save_comments, disk_comments)
  local by_id = {}

  for _, comment in ipairs(disk_comments or {}) do
    if type(comment) == "table" and type(comment.id) == "string" and comment.id ~= "" then
      by_id[comment.id] = comment
    end
  end

  -- Prefer the version being saved for duplicate ids.
  for _, comment in ipairs(save_comments or {}) do
    if type(comment) == "table" and type(comment.id) == "string" and comment.id ~= "" then
      by_id[comment.id] = comment
    end
  end

  local merged = {}

  -- Keep the caller's comment order first.
  for _, comment in ipairs(save_comments or {}) do
    if by_id[comment.id] then
      table.insert(merged, by_id[comment.id])
      by_id[comment.id] = nil
    end
  end

  -- Append comments that exist only on disk.
  for _, comment in ipairs(disk_comments or {}) do
    if by_id[comment.id] then
      table.insert(merged, by_id[comment.id])
      by_id[comment.id] = nil
    end
  end

  return merged
end

M._test_hooks = {}
M._test_config = {
  lock_timeout_ms = nil,
  stale_grace_ms = nil,
}

function M.save_scope(scope_root, data)
  local path = M.scope_file(scope_root)
  data.scope_root = scope_root
  data.comments = type(data.comments) == "table" and data.comments or {}

  ensure_dir(vim.fn.fnamemodify(path, ":h"))

  local owner = make_owner()
  local lock = lock_path(scope_root)
  local acquired, lock_err = acquire_lock(scope_root, owner)
  if not acquired then
    return nil, lock_err
  end

  local function cleanup()
    release_lock(lock, owner)
  end

  if M._test_hooks.after_lock_acquire then
    M._test_hooks.after_lock_acquire(scope_root)
  end

  -- Inside the lock: reload disk, validate binding, merge when the file
  -- changed since we last touched it, then replace the JSON atomically.
  local file_readable = vim.fn.filereadable(path) == 1
  local known = last_known[scope_root]
  local current_hash = file_readable and file_hash(path) or nil

  local disk
  if file_readable then
    disk = load_json(path)
  end

  local disk_binding = disk and disk.session and disk.session.binding
  local save_binding = data and data.session and data.session.binding
  if present_binding(disk_binding) and not same_binding(disk_binding, save_binding) then
    cleanup()
    return nil,
      string.format("Review session belongs to %s; findings cannot be changed here.", binding_label(disk_binding))
  end

  if file_readable and (known == nil or current_hash ~= known.hash) then
    if disk and type(disk.comments) == "table" then
      data.comments = merge_comments(data.comments, disk.comments)
    end
  end

  local encoded = vim.json.encode(data)
  local written, write_err = atomic_write(path, encoded, owner)
  if not written then
    cleanup()
    return nil, write_err
  end

  if M._test_hooks.before_lock_release then
    M._test_hooks.before_lock_release(scope_root)
  end

  cleanup()

  -- Remember the fingerprint of the file we just produced.
  last_known[scope_root] = { hash = file_hash(path) }

  return true
end

function M.delete_scope(scope_root)
  local path = M.scope_file(scope_root)
  last_known[scope_root] = nil

  if vim.fn.filereadable(path) == 1 then
    return vim.fn.delete(path) == 0
  end

  return true
end

function M.list_scopes()
  local base = opts().storage_dir
  ensure_dir(base)

  local paths = vim.fn.glob(vim.fs.joinpath(base, "*.json"), false, true)
  local scopes = {}
  for _, path in ipairs(paths) do
    local data = load_json(path)
    local scope_root = data.scope_root
    if type(scope_root) == "string" and scope_root ~= "" then
      table.insert(scopes, {
        scope_root = scope_root,
        path = path,
        data = data,
      })
    end
  end

  return scopes
end

return M
