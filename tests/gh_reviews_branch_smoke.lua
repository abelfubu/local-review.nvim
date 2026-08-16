-- Regression smoke test: reviews split hides when the current branch changes.
-- Run with: nvim --headless -u NONE -l tests/gh_reviews_branch_smoke.lua

local plugin_root = vim.uv.cwd()
vim.opt.runtimepath:append(plugin_root)

require("local_review").setup({ storage_dir = vim.fn.tempname() .. "_gh_reviews_branch_smoke", keymaps = {} })

local context = require("local_review.infrastructure.context")
local gh_session = require("local_review.application.gh_session")
local ui = require("local_review.presentation.ui")

local function git(dir, ...)
  local args = { "git", "-C", dir, ... }
  local result = vim.fn.system(table.concat(args, " "))
  local code = vim.v.shell_error
  if code ~= 0 then
    error(string.format("git command failed (%d): %s\n%s", code, table.concat(args, " "), result))
  end
  return result
end

local repo_dir = vim.fn.tempname() .. "_gh_reviews_branch_smoke_repo"
vim.fn.mkdir(repo_dir, "p")

git(repo_dir, "init", "--quiet")
git(repo_dir, "config", "user.email", "test@example.com")
git(repo_dir, "config", "user.name", "Test")
git(repo_dir, "checkout", "-b", "branch-a")

local source_file = vim.fs.joinpath(repo_dir, "file.lua")
vim.fn.writefile({ "local value = 1" }, source_file)
git(repo_dir, "add", "file.lua")
git(repo_dir, "commit", "-m", "initial", "--quiet")

git(repo_dir, "checkout", "-b", "branch-b")
git(repo_dir, "checkout", "branch-a")

vim.cmd.edit(vim.fn.fnameescape(source_file))

local source_winid = vim.api.nvim_get_current_win()
local scope_root = assert(context.comment_context(0).scope_root, "failed to resolve scope root")

local reviews_a = {
  {
    id = "review-a",
    author = "reviewer-a",
    state = "COMMENTED",
    body = "Branch A review body.",
    url = "https://github.com/owner/repo/pull/1#pullrequestreview-a",
    submitted_at = "2024-01-15T10:00:00Z",
  },
}

gh_session.set(scope_root, {}, reviews_a, 1, "branch-a")
ui.open_reviews_split(reviews_a, scope_root)

local windows = vim.api.nvim_list_wins()
assert(#windows == 2, "reviews split did not open a second window")

local review_bufnr = vim.api.nvim_get_current_buf()
assert(vim.api.nvim_buf_get_name(review_bufnr):find("gh%-reviews"), "reviews buffer not active")

-- Switch to branch B and trigger the branch-context reconciliation from the
-- source window so the review buffer is not the autocmd's target buffer.
git(repo_dir, "checkout", "branch-b")
vim.api.nvim_set_current_win(source_winid)
vim.api.nvim_exec_autocmds("BufEnter", { buffer = vim.api.nvim_get_current_buf() })

vim.wait(200, function()
  return not vim.api.nvim_buf_is_valid(review_bufnr)
end)
assert(not vim.api.nvim_buf_is_valid(review_bufnr), "reviews buffer was not wiped after branch switch")
assert(#vim.api.nvim_list_wins() == 1, "reviews split did not close after branch switch")
assert(vim.api.nvim_get_current_win() == source_winid, "focus did not return to the source window after branch switch")

-- Switch back to branch A without re-pulling: the split should remain closed.
git(repo_dir, "checkout", "branch-a")
vim.api.nvim_exec_autocmds("BufEnter", { buffer = vim.api.nvim_get_current_buf() })
assert(#vim.api.nvim_list_wins() == 1, "reviews split reopened without a re-pull")

-- Simulate re-pull by re-seeding the session and opening the split again.
gh_session.set(scope_root, {}, reviews_a, 1, "branch-a")
ui.open_reviews_split(reviews_a, scope_root)
assert(#vim.api.nvim_list_wins() == 2, "re-pull did not restore the reviews split")

-- Clean up.
vim.cmd("silent bwipeout! " .. vim.api.nvim_get_current_buf())
vim.fn.delete(repo_dir, "rf")
print("PASS: reviews split hides on branch switch and re-pull restores it")
