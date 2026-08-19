local M = {}

---Run a `gh` (or any other) CLI command and return its trimmed stdout.
---@param command string[]
---@param cwd string?
---@param opts { env: table<string,string>? }?
---@return string? output, string? error
function M.run(command, cwd, opts)
  local timeout_ms = 30000
  local sys_opts = { cwd = cwd, text = true }
  if opts and opts.env then
    sys_opts.env = opts.env
  end
  local ok, proc = pcall(vim.system, command, sys_opts)
  if not ok then
    return nil, vim.trim(tostring(proc))
  end
  if proc == nil then
    return nil, "gh command failed to start"
  end

  local result = proc:wait(timeout_ms)

  if result == nil or result.code == 124 then
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
