local M = {}

---Run a `gh` (or any other) CLI command and return its trimmed stdout.
---@param command string[]
---@param cwd string?
---@return string? output, string? error
function M.run(command, cwd)
  local timeout_ms = 30000
  local proc = vim.system(command, { cwd = cwd, text = true })
  local result = proc:wait(timeout_ms)

  if result == nil then
    return nil, "gh command timed out after " .. timeout_ms .. "ms"
  end

  if result.code ~= 0 then
    return nil, vim.trim(result.stderr or result.stdout or "")
  end

  return vim.trim(result.stdout or "")
end

---Resolve the repository slug (`owner/name`) from the local checkout root.
---@param repo_root string
---@return string? slug, string? error
function M.get_repo_slug(repo_root)
  return M.run({ "gh", "repo", "view", "--json", "owner,name", "-q", '.owner.login + "/" + .name' }, repo_root)
end

return M
