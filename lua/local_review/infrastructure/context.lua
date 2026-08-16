local M = {}

---@type table<string, string>
local branch_cache = {}

local function normalize(path)
  return vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
end

function M.normalize_path(path)
  if path == nil or path == "" then
    return nil
  end

  return normalize(path)
end

function M.current_file(bufnr)
  local path = vim.api.nvim_buf_get_name(bufnr or 0)
  if path == nil or path == "" then
    return nil, "Current buffer has no file path."
  end
  -- Scheme-prefixed buffer names (diffview://, fugitive://, oil://, ...)
  -- are not real files; comments on them could never be reopened.
  if path:match("^%a[%w+%.%-]*://") then
    return nil, "Cannot add a review comment here: not a real file."
  end
  return normalize(path)
end

function M.repo_root(path)
  local target = path
  if target == nil or target == "" then
    target = vim.fn.getcwd()
  end

  local normalized = normalize(target)
  local directory = normalized
  if vim.fn.isdirectory(normalized) == 0 then
    directory = vim.fn.fnamemodify(normalized, ":h")
  end

  local result = vim.fn.systemlist({ "git", "-C", directory, "rev-parse", "--show-toplevel" })
  if vim.v.shell_error ~= 0 or result[1] == nil or result[1] == "" then
    return nil, "Not inside a git repository."
  end

  return normalize(result[1])
end

---@param path string?
---@return string?
function M.current_branch(path)
  local target = path
  if target == nil or target == "" then
    target = vim.fn.getcwd()
  end

  local normalized = normalize(target)
  local cached = branch_cache[normalized]
  if cached ~= nil then
    return cached
  end

  local directory = normalized
  if vim.fn.isdirectory(normalized) == 0 then
    directory = vim.fn.fnamemodify(normalized, ":h")
  end

  local result = vim.fn.systemlist({ "git", "-C", directory, "rev-parse", "--abbrev-ref", "HEAD" })
  if vim.v.shell_error ~= 0 or result[1] == nil or result[1] == "" then
    return nil
  end

  local branch = result[1]
  -- `git rev-parse --abbrev-ref HEAD` returns the literal string "HEAD" in a
  -- detached-HEAD state, so two different detached commits would otherwise
  -- compare equal. Append the short commit hash to keep them distinct.
  if branch == "HEAD" then
    local short = vim.fn.systemlist({ "git", "-C", directory, "rev-parse", "--short", "HEAD" })
    if short[1] and short[1] ~= "" then
      branch = "HEAD@" .. short[1]
    end
  end

  branch_cache[normalized] = branch
  return branch
end

---Invalidate cached branch lookups. When `path` is omitted, the entire cache
---is cleared.
---@param path string?
function M.invalidate_branch_cache(path)
  if path == nil or path == "" then
    branch_cache = {}
  else
    branch_cache[normalize(path)] = nil
  end
end

function M.scope_root(path)
  local normalized = M.normalize_path(path)
  if not normalized then
    return nil, "Path is required."
  end

  local repo_root = M.repo_root(normalized)
  if repo_root then
    return repo_root
  end

  if vim.fn.isdirectory(normalized) == 1 then
    return normalized
  end

  return normalize(vim.fn.fnamemodify(normalized, ":h"))
end

function M.default_export_root()
  local cwd = normalize(vim.fn.getcwd())
  return M.repo_root(cwd) or cwd
end

function M.path_kind(path)
  local normalized = M.normalize_path(path)
  if not normalized then
    return nil, "Path is required."
  end

  if vim.fn.filereadable(normalized) == 1 then
    return "file", normalized
  end

  if vim.fn.isdirectory(normalized) == 1 then
    return "directory", normalized
  end

  return nil, string.format("Path does not exist: %s", normalized)
end

function M.relative_path(root_path, absolute_path)
  local root = normalize(root_path)
  local path = normalize(absolute_path)
  local prefix = root .. "/"

  if path == root then
    return "."
  end

  if path:sub(1, #prefix) == prefix then
    return path:sub(#prefix + 1)
  end

  return nil, string.format("Path is outside the root: %s", path)
end

function M.is_within(root_path, candidate_path)
  return M.relative_path(root_path, candidate_path) ~= nil
end

function M.comment_context(bufnr)
  local absolute_path, file_err = M.current_file(bufnr)
  if not absolute_path then
    return nil, file_err
  end

  local scope_root, scope_err = M.scope_root(absolute_path)
  if not scope_root then
    return nil, scope_err
  end

  return {
    absolute_path = absolute_path,
    relative_path = M.relative_path(scope_root, absolute_path),
    scope_root = scope_root,
    bufnr = bufnr or 0,
  }
end

return M
