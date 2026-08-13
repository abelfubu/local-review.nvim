-- Review sessions remain bound to the branch where their first finding was created.
local plugin_root = vim.uv.cwd()
vim.opt.runtimepath:append(plugin_root)

local storage_dir = vim.fn.tempname() .. "_session_branch"
local repo = vim.fn.tempname() .. "_repo"
vim.fn.mkdir(repo, "p")

local function git(...)
  local args = { "git", "-C", repo }
  vim.list_extend(args, { ... })
  local result = vim.system(args, { text = true }):wait()
  assert(result.code == 0, result.stderr)
end

git("init", "-b", "review-branch")
git("config", "user.email", "review@example.com")
git("config", "user.name", "Reviewer")

local path = vim.fs.joinpath(repo, "sample.lua")
vim.fn.writefile({ "local value = 1" }, path)
git("add", "sample.lua")
git("commit", "-m", "initial")

require("local_review").setup({ storage_dir = storage_dir })
vim.cmd.edit(vim.fn.fnameescape(path))

local comments = require("local_review.comments")
assert(comments.set_line_comment(0, 1, "first finding") == "created")

git("switch", "-c", "other-branch")

local result, err = comments.set_line_comment(0, 1, "changed finding")
assert(result == nil, "expected mutation to be blocked on another branch")
assert(err and err:match("review%-branch"), "expected error to identify the reviewed branch, got: " .. tostring(err))

result, err = comments.delete_line_comment(0, 1)
assert(result == nil, "expected delete to be blocked on another branch")
assert(
  err and err:match("review%-branch"),
  "expected delete error to identify the reviewed branch, got: " .. tostring(err)
)

result, err = comments.set_line_comment(0, 1, "")
assert(result == nil, "expected empty-body delete to be blocked on another branch")
assert(
  err and err:match("review%-branch"),
  "expected empty-body delete error to identify the reviewed branch, got: " .. tostring(err)
)

vim.api.nvim_win_set_cursor(0, { 1, 0 })
comments.delete_current_line()
local still_there = comments.get_line_state(0, 1)
assert(still_there and still_there.comment, "expected delete_current_line to be blocked on another branch")

comments.clear_path(repo, { silent = true })
still_there = comments.get_line_state(0, 1)
assert(still_there and still_there.comment, "expected clear_path to be blocked on another branch")

local read_state = comments.get_line_state(0, 1)
assert(read_state and read_state.comment, "expected findings to remain readable on another branch")

git("switch", "review-branch")
vim.cmd.edit(vim.fn.fnameescape(path))
local reopened = comments.get_line_state(0, 1)
assert(reopened and reopened.comment, "expected reading to work after reopening on the bound branch")
assert(reopened.session.available, "expected session to be available on the bound branch")

result, err = comments.set_line_comment(0, 1, "updated finding")
assert(result == "updated", "expected mutation to succeed on the bound branch, got: " .. tostring(err))

-- Non-Git files retain legacy mutation behavior and do not crash.
local standalone_dir = vim.fn.tempname() .. "_standalone"
vim.fn.mkdir(standalone_dir, "p")
local standalone = vim.fs.joinpath(standalone_dir, "file.lua")
vim.fn.writefile({ "local x = 1" }, standalone)
vim.cmd.edit(vim.fn.fnameescape(standalone))

local ok, standalone_err = pcall(comments.set_line_comment, 0, 1, "standalone finding")
assert(ok, "expected non-Git mutation to succeed without crashing, got: " .. tostring(standalone_err))

local standalone_state = comments.get_line_state(0, 1)
assert(standalone_state and standalone_state.comment, "expected non-Git finding to be readable")

vim.fn.delete(storage_dir, "rf")
vim.fn.delete(repo, "rf")
vim.fn.delete(standalone_dir, "rf")
print("PASS: review session mutation blocked on another branch")
