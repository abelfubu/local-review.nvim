-- Hover smoke test for review comment hover peek.
-- Run with: nvim --headless -u NONE -l tests/hover_smoke.lua

local plugin_root = vim.uv.cwd()
vim.opt.runtimepath:append(plugin_root)

local storage_dir = vim.fn.tempname() .. "_hover_smoke"
local source_path = vim.fn.tempname() .. ".lua"
vim.fn.mkdir(storage_dir, "p")
vim.fn.writefile({ "local first = 1", "local second = 2" }, source_path)

require("local_review").setup({ storage_dir = storage_dir, keymaps = {} })
vim.cmd.edit(vim.fn.fnameescape(source_path))

local source_bufnr = vim.api.nvim_get_current_buf()
local source_winid = vim.api.nvim_get_current_win()
local absolute_path = vim.api.nvim_buf_get_name(source_bufnr)
local context = require("local_review.infrastructure.context")
local scope_root = context.scope_root(absolute_path)
assert(scope_root, "failed to resolve scope root")
local scope_file = string.format("%s/%s.json", storage_dir, vim.fn.sha256(scope_root))

local local_comment = {
  id = "local:comment-1",
  origin = "local",
  absolute_path = absolute_path,
  relative_path = vim.fn.fnamemodify(absolute_path, ":t"),
  body = "Local **feedback** with `markdown`.",
  created_at = "2024-01-01T00:00:00Z",
  updated_at = "2024-01-01T00:00:00Z",
  anchor = { line_number = 1, line_text = "local first = 1" },
  line_end = 1,
  source_kind = "buffer",
  source_meta = {},
  stale = false,
}

local remote_comment = {
  id = "gh:comment-1",
  origin = "github",
  absolute_path = absolute_path,
  relative_path = vim.fn.fnamemodify(absolute_path, ":t"),
  body = "Remote **feedback** with `markdown`.",
  created_at = "2024-01-01T00:00:00Z",
  updated_at = "2024-01-01T00:00:00Z",
  anchor = { line_number = 1, line_text = "local first = 1" },
  line_end = 1,
  source_kind = "github",
  source_meta = {},
  stale = false,
  remote = {
    repository = "owner/repo",
    pull_number = 1,
    thread_id = "thread-1",
    comment_id = "comment-1",
    author = "reviewer",
    url = "https://github.com/owner/repo/pull/1#discussion_r1",
    resolved = false,
    outdated = true,
  },
}

vim.fn.writefile(
  { vim.json.encode({ scope_root = scope_root, comments = { local_comment, remote_comment } }) },
  scope_file
)

require("local_review.presentation.markers").refresh(source_bufnr)

local function find_hover_winid()
  for _, winid in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(winid) then
      local bufnr = vim.api.nvim_win_get_buf(winid)
      local name = vim.api.nvim_buf_get_name(bufnr)
      if name:find("hover%-comment") then
        return winid
      end
    end
  end
  return nil
end

-- Press K on the commented line.
vim.api.nvim_win_set_cursor(source_winid, { 1, 0 })
vim.cmd("normal K")

local hover_winid = find_hover_winid()
assert(hover_winid, "hover did not open on commented line")
assert(hover_winid ~= source_winid, "hover is not a new window")

local hover_bufnr = vim.api.nvim_win_get_buf(hover_winid)
assert(vim.bo[hover_bufnr].filetype == "markdown", "hover buffer is not markdown filetype")
assert(not vim.bo[hover_bufnr].modifiable, "hover buffer is modifiable")
assert(vim.api.nvim_get_current_win() == source_winid, "hover should not be focused initially")

local hover_lines = vim.api.nvim_buf_get_lines(hover_bufnr, 0, -1, false)
local found_local_header = false
local found_remote_header = false
for _, line in ipairs(hover_lines) do
  if line:find("### Review Comment") then
    found_local_header = true
  end
  if line:find("### @reviewer") then
    found_remote_header = true
  end
end
assert(found_local_header, "hover did not render the local comment header")
assert(found_remote_header, "hover did not render the remote author header")

-- Move to another line in the source to trigger CursorMoved and close the hover.
vim.api.nvim_win_set_cursor(source_winid, { 2, 0 })
vim.api.nvim_exec_autocmds("CursorMoved", { buffer = source_bufnr })
assert(find_hover_winid() == nil, "hover did not close on CursorMoved")

-- Press K on a commentless line; it should not open the hover.
vim.api.nvim_win_set_cursor(source_winid, { 2, 0 })
vim.cmd("normal K")
assert(find_hover_winid() == nil, "hover opened on a commentless line")

vim.fn.delete(storage_dir, "rf")
vim.fn.delete(source_path)
print("PASS: hover peek opens for comments, closes on CursorMoved, and falls through on commentless lines")
