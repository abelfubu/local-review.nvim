-- Marker smoke test for imported GitHub comments.
-- Run with: nvim --headless -u NONE -l tests/gh_marker_smoke.lua

local plugin_root = vim.uv.cwd()
vim.opt.runtimepath:append(plugin_root)

local storage_dir = vim.fn.tempname() .. "_gh_marker_smoke"
local source_path = vim.fn.tempname() .. ".lua"
vim.fn.mkdir(storage_dir, "p")
vim.fn.writefile({ "local value = 1" }, source_path)

require("local_review").setup({ storage_dir = storage_dir, keymaps = {} })
vim.cmd.edit(vim.fn.fnameescape(source_path))

local source_bufnr = vim.api.nvim_get_current_buf()
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
  body = "Remote feedback.",
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

local extmarks =
  vim.api.nvim_buf_get_extmarks(source_bufnr, vim.api.nvim_create_namespace("local-review-markers"), 0, -1, {
    details = true,
  })
assert(#extmarks > 0, "no marker extmarks were created for the remote comment")

local found_outdated = false
for _, mark in ipairs(extmarks) do
  local details = mark[4] or {}
  local virt_lines = details.virt_lines or {}
  for _, virt_line in ipairs(virt_lines) do
    for _, chunk in ipairs(virt_line) do
      local text = chunk[1]
      if text and text:find("%[outdated%]") then
        found_outdated = true
      end
    end
  end
end
assert(found_outdated, "remote comment marker did not render the [outdated] suffix")

vim.fn.delete(storage_dir, "rf")
vim.fn.delete(source_path)
print("PASS: GitHub comment marker rendered with the [outdated] suffix")
