-- Inline editor split-navigation smoke test.
-- Run with: nvim --headless -u NONE -l tests/ui_split_smoke.lua

local plugin_root = vim.uv.cwd()
vim.opt.runtimepath:append(plugin_root)

local storage_dir = vim.fn.tempname() .. "_ui_split_smoke"
local source_path = vim.fn.tempname() .. ".lua"
vim.fn.mkdir(storage_dir, "p")
vim.fn.writefile({ "local value = 1" }, source_path)

require("local_review").setup({ storage_dir = storage_dir, keymaps = {} })
vim.cmd.edit(vim.fn.fnameescape(source_path))
vim.cmd.vsplit()

local windows = vim.api.nvim_list_wins()
assert(#windows == 2, "expected two source windows")

table.sort(windows, function(left, right)
  return vim.api.nvim_win_get_position(left)[2] < vim.api.nvim_win_get_position(right)[2]
end)
local left_winid, right_winid = windows[1], windows[2]
vim.api.nvim_set_current_win(right_winid)

local source_bufnr = vim.api.nvim_get_current_buf()
require("local_review.ui").open_current_line()
local editor_winid = vim.api.nvim_get_current_win()
assert(editor_winid ~= right_winid, "comment editor did not open")
local editor_col = vim.fn.win_screenpos(editor_winid)[2]
local right_col = vim.fn.win_screenpos(right_winid)[2]
assert(editor_col >= right_col, "comment editor appeared in the left split")
local editor_bufnr = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(editor_bufnr, 0, -1, false, { "split navigation comment" })

vim.api.nvim_set_current_win(left_winid)
vim.wait(100, function()
  return not vim.api.nvim_win_is_valid(editor_winid)
end)

assert(not vim.api.nvim_win_is_valid(editor_winid), "comment editor remained open after changing splits")
assert(require("local_review.ui").active_source_line(source_bufnr) == nil, "comment editor state remained active")
local line_state = assert(require("local_review.comments").get_line_state(source_bufnr, 1))
assert(line_state.comment and line_state.comment.body == "split navigation comment", "comment was not saved")

vim.fn.delete(storage_dir, "rf")
vim.fn.delete(source_path)
print("PASS: comment editor opened in the right split and closed after leaving it")
