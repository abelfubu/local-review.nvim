-- Range-comment dual-anchor smoke test.
--
-- Creates a multi-line comment, inserts lines inside the range, and verifies
-- that reconcile keeps the start anchored while shifting the end line.

local plugin_root = vim.uv.cwd()
vim.opt.runtimepath:append(plugin_root)

local storage_dir = vim.fn.tempname() .. "_range_anchor_smoke"
vim.fn.mkdir(storage_dir, "p")

require("local_review").setup({ storage_dir = storage_dir })

local comments = require("local_review.application.comments")

local buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(buf)

local path = vim.fs.joinpath(vim.fn.getcwd(), "smoke_range_anchor_sample.lua")
vim.api.nvim_buf_set_name(buf, path)

local initial_lines = {
  "alpha",
  "beta",
  "start anchor",
  "inside",
  "end anchor",
  "gamma",
}
vim.api.nvim_buf_set_lines(buf, 0, -1, false, initial_lines)

local result = comments.set_line_comment(buf, 3, "range smoke", { start_line = 3, end_line = 5 })
assert(result == "created", "expected created, got " .. tostring(result))

local state = assert(comments.get_line_state(buf, 3), "get_line_state returned nil")
local comment = assert(state.comment, "comment not found after creation")
assert(comment.anchor.line_number == 3, "expected start 3, got " .. tostring(comment.anchor.line_number))
assert(comment.line_end == 5, "expected line_end 5, got " .. tostring(comment.line_end))
assert(not comment.stale, "comment should not be stale after creation")
assert(comment.anchor_end ~= nil, "range comment should have anchor_end")
assert(comment.anchor_end.line_number == 5, "expected anchor_end 5")

-- Insert two lines before the end anchor, inside the existing range.
-- nvim_buf_set_lines is 0-indexed; line 5 in 1-based terms is index 4.
vim.api.nvim_buf_set_lines(buf, 4, 4, false, { "inserted one", "inserted two" })

-- Force a reconcile by asking for the comment state again.
state = assert(comments.get_line_state(buf, 3), "get_line_state returned nil after edit")
comment = assert(state.comment, "comment not found after edit")
assert(not comment.stale, "comment went stale unexpectedly")
assert(comment.anchor.line_number == 3, "start should stay at 3, got " .. tostring(comment.anchor.line_number))
assert(comment.line_end == 7, "end should shift to 7, got " .. tostring(comment.line_end))
assert(comment.anchor_end.line_number == 7, "anchor_end should shift to 7")

print("PASS: range anchor stayed at 3 and end shifted from 5 to 7")
