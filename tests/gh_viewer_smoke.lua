-- Viewer smoke test for read-only remote GitHub review comments.
-- Run with: nvim --headless -u NONE -l tests/gh_viewer_smoke.lua

local plugin_root = vim.uv.cwd()
vim.opt.runtimepath:append(plugin_root)

local storage_dir = vim.fn.tempname() .. "_gh_viewer_smoke"
local source_path = vim.fn.tempname() .. ".lua"
vim.fn.mkdir(storage_dir, "p")
vim.fn.writefile({ "local value = 1" }, source_path)

require("local_review").setup({ storage_dir = storage_dir, keymaps = {} })
vim.cmd.edit(vim.fn.fnameescape(source_path))

local source_bufnr = vim.api.nvim_get_current_buf()
local source_winid = vim.api.nvim_get_current_win()
local absolute_path = vim.api.nvim_buf_get_name(source_bufnr)
local context = require("local_review.infrastructure.context")
local scope_root = context.scope_root(absolute_path)
assert(scope_root, "failed to resolve scope root")
local scope_file = string.format("%s/%s.json", storage_dir, vim.fn.sha256(scope_root))

local remote_comment = {
  id = "gh:comment-1",
  origin = "github",
  absolute_path = absolute_path,
  relative_path = vim.fn.fnamemodify(absolute_path, ":t"),
  body = "Remote **feedback** with `markdown`.",
  created_at = "2024-01-01T00:00:00Z",
  updated_at = "2024-01-01T00:00:00Z",
  anchor = { line_number = 1, line_text = "local value = 1" },
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

vim.fn.writefile({ vim.json.encode({ scope_root = scope_root, comments = { remote_comment } }) }, scope_file)

require("local_review.presentation.markers").refresh(source_bufnr)

-- Open the viewer for the remote comment on line 1.
require("local_review.presentation.ui").open_current_line()

local viewer_winid = vim.api.nvim_get_current_win()
assert(viewer_winid ~= source_winid, "viewer did not open in a new window")

local viewer_bufnr = vim.api.nvim_get_current_buf()
assert(vim.bo[viewer_bufnr].filetype == "markdown", "viewer buffer is not markdown filetype")
assert(not vim.bo[viewer_bufnr].modifiable, "viewer buffer is modifiable")
assert(
  vim.api.nvim_buf_get_name(viewer_bufnr):find("github%-comment"),
  "viewer buffer name does not contain github-comment"
)

local viewer_lines = vim.api.nvim_buf_get_lines(viewer_bufnr, 0, -1, false)
local found_author = false
for _, line in ipairs(viewer_lines) do
  if line:find("@reviewer") then
    found_author = true
  end
end
assert(found_author, "viewer did not render the author header")

-- Close with the mapped 'q' key.
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("q", true, false, true), "x", false)
vim.wait(200, function()
  return not vim.api.nvim_win_is_valid(viewer_winid)
end)
assert(not vim.api.nvim_win_is_valid(viewer_winid), "viewer did not close on q")

vim.fn.delete(storage_dir, "rf")
vim.fn.delete(source_path)
print("PASS: remote comment viewer opened as markdown, was non-modifiable, and closed on q")
