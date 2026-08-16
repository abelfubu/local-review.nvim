local comment_store = require("local_review.domain.comment_store")

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

---@param scope_root string
---@param target_path string absolute and normalized
---@param kind "file"|"directory"
---@return LocalReviewComment[]
function M.comments_for_path(scope_root, target_path, kind)
  return comment_store.matching_path({ { data = M.load_scope(scope_root) } }, target_path, kind)
end

---Keeps remote comments (read-only policy), persists the kept list and
---deletes the scope file when no comments remain.
---@param scope_root string
---@param data table scope data with a comments array
---@param matched LocalReviewComment[]
---@param kept LocalReviewComment[]
---@return LocalReviewComment[]? removed, string? err
local function apply_removal(scope_root, data, matched, kept)
  local removable = {}
  for _, comment in ipairs(matched) do
    if comment_store.is_editable(comment) then
      table.insert(removable, comment)
    else
      table.insert(kept, comment)
    end
  end

  if #removable == 0 then
    return {}, nil
  end

  data.comments = kept
  if #kept == 0 then
    if not M.delete_scope(scope_root) then
      return nil, "Failed to delete the empty review scope."
    end
  else
    local ok, err = M.save_scope(scope_root, data)
    if not ok then
      return nil, err
    end
  end
  return removable, nil
end

---@param scope_root string
---@param target_path string absolute and normalized
---@param kind "file"|"directory"
---@return LocalReviewComment[]? removed, string? err
function M.remove_comments_for_path(scope_root, target_path, kind)
  local data = M.load_scope(scope_root)
  local matched, kept = comment_store.partition_path(data.comments or {}, target_path, kind)
  return apply_removal(scope_root, data, matched, kept)
end

---@param scope_root string
---@param ids string[]
---@return LocalReviewComment[]? removed, string? err
function M.remove_comments_by_ids(scope_root, ids)
  local wanted = {}
  for _, id in ipairs(ids) do
    wanted[id] = true
  end
  local data = M.load_scope(scope_root)
  local matched, kept = comment_store.partition_ids(data.comments or {}, wanted)
  return apply_removal(scope_root, data, matched, kept)
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

---Union two comment lists by comment id, preferring `save_comments` when ids
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

function M.save_scope(scope_root, data)
  local path = M.scope_file(scope_root)
  data.scope_root = scope_root
  data.comments = type(data.comments) == "table" and data.comments or {}

  ensure_dir(vim.fn.fnamemodify(path, ":h"))

  local file_readable = vim.fn.filereadable(path) == 1
  local known = last_known[scope_root]
  local current_hash = file_readable and file_hash(path) or nil

  if file_readable and (known == nil or current_hash ~= known.hash) then
    -- The file changed on disk since we last touched it. Merge instead of
    -- overwriting. If the disk state is corrupt or unreadable, fall back to
    -- the plain overwrite below.
    local disk = load_json(path)
    if disk and type(disk.comments) == "table" then
      data.comments = merge_comments(data.comments, disk.comments)
    end
  end

  if vim.fn.writefile({ vim.json.encode(data) }, path) ~= 0 then
    return nil, string.format("Failed to save review comments to %s.", path)
  end

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

return M
