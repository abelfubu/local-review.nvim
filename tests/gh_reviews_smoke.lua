-- Reviews split smoke test for read-only PR review summaries.
-- Run with: nvim --headless -u NONE -l tests/gh_reviews_smoke.lua

local plugin_root = vim.uv.cwd()
vim.opt.runtimepath:append(plugin_root)

require("local_review").setup({ storage_dir = vim.fn.tempname() .. "_gh_reviews_smoke", keymaps = {} })

local context = require("local_review.infrastructure.context")

local function git(dir, ...)
  local args = { "git", "-C", dir, ... }
  local result = vim.fn.system(table.concat(args, " "))
  local code = vim.v.shell_error
  if code ~= 0 then
    error(string.format("git command failed (%d): %s\n%s", code, table.concat(args, " "), result))
  end
  return result
end

local repo_dir = vim.fn.tempname() .. "_gh_reviews_smoke_repo"
vim.fn.mkdir(repo_dir, "p")

git(repo_dir, "init", "--quiet")
git(repo_dir, "config", "user.email", "test@example.com")
git(repo_dir, "config", "user.name", "Test")

local source_path = vim.fs.joinpath(repo_dir, "file.lua")
vim.fn.writefile({ "local value = 1" }, source_path)
git(repo_dir, "add", "file.lua")
git(repo_dir, "commit", "-m", "initial", "--quiet")

vim.cmd.edit(vim.fn.fnameescape(source_path))

local source_winid = vim.api.nvim_get_current_win()
local scope_root = assert(context.comment_context(0).scope_root, "failed to resolve scope root")
local branch = assert(context.current_branch(scope_root), "failed to resolve current branch")

local function find_line(lines, pattern)
  for _, line in ipairs(lines) do
    if line:find(pattern) then
      return true
    end
  end
  return false
end

local reviews_a = {
  {
    id = "review-1",
    author = "reviewer-one",
    state = "COMMENTED",
    body = "First review body.",
    url = "https://github.com/owner/repo/pull/1#pullrequestreview-1",
    submitted_at = "2024-01-15T10:00:00Z",
  },
  {
    id = "review-2",
    author = "reviewer-two",
    state = "APPROVED",
    body = "Second review body.\nWith a second line.",
    url = "https://github.com/owner/repo/pull/1#pullrequestreview-2",
    submitted_at = "2024-02-20T12:30:00Z",
  },
}

local reviews_b = {
  {
    id = "review-3",
    author = "reviewer-three",
    state = "CHANGES_REQUESTED",
    body = "Updated review body.",
    url = "https://github.com/owner/repo/pull/1#pullrequestreview-3",
    submitted_at = "2024-03-25T14:00:00Z",
  },
}

-- Seed the session so the clear flow can wipe the reviews buffer.
require("local_review.application.gh_session").set(scope_root, {}, reviews_a, 1, branch)

require("local_review.presentation.ui").open_reviews_split(reviews_a, scope_root)

local windows = vim.api.nvim_list_wins()
assert(#windows == 2, "reviews split did not open a second window")

local review_winid = vim.api.nvim_get_current_win()
assert(review_winid ~= source_winid, "reviews split did not open in a new window")

local review_bufnr = vim.api.nvim_get_current_buf()
assert(vim.bo[review_bufnr].filetype == "markdown", "reviews buffer is not markdown filetype")
assert(not vim.bo[review_bufnr].modifiable, "reviews buffer is modifiable")
assert(vim.bo[review_bufnr].bufhidden == "hide", "reviews buffer is not bufhidden=hide")
assert(vim.bo[review_bufnr].buflisted, "reviews buffer is not listed")
assert(vim.api.nvim_buf_get_name(review_bufnr):find("gh%-reviews"), "reviews buffer name does not contain gh-reviews")

local lines = vim.api.nvim_buf_get_lines(review_bufnr, 0, -1, false)
assert(find_line(lines, "@reviewer%-one"), "first review section not rendered")
assert(find_line(lines, "@reviewer%-two"), "second review section not rendered")

-- Close with the mapped 'q' key; the buffer should survive.
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("q", true, false, true), "x", false)

vim.wait(100, function()
  return not vim.api.nvim_win_is_valid(review_winid)
end)
assert(not vim.api.nvim_win_is_valid(review_winid), "reviews split did not close on q")
assert(vim.api.nvim_buf_is_valid(review_bufnr), "reviews buffer was wiped on window close")
assert(vim.api.nvim_get_current_win() == source_winid, "focus did not return to the source window")

-- Re-pull updated reviews and reopen the split.
require("local_review.application.gh_session").set(scope_root, {}, reviews_b, 1, branch)
require("local_review.presentation.ui").open_reviews_split(reviews_b, scope_root)

local reused_bufnr = vim.api.nvim_get_current_buf()
assert(reused_bufnr == review_bufnr, "re-pull did not reuse the existing reviews buffer")
assert(#vim.api.nvim_list_wins() == 2, "re-pull did not reopen a reviews split")

local updated_lines = vim.api.nvim_buf_get_lines(reused_bufnr, 0, -1, false)
assert(not find_line(updated_lines, "@reviewer%-one"), "stale first review still present after re-pull")
assert(not find_line(updated_lines, "@reviewer%-two"), "stale second review still present after re-pull")
assert(find_line(updated_lines, "@reviewer%-three"), "updated review section not rendered")
assert(not vim.bo[reused_bufnr].modifiable, "reused reviews buffer became modifiable")

-- Clear the session and trigger the wipe listener.
require("local_review.application.gh_session").clear(scope_root)
vim.api.nvim_exec_autocmds("User", {
  pattern = "LocalReviewChanged",
  data = { scope_root = scope_root },
})

vim.wait(200, function()
  return not vim.api.nvim_buf_is_valid(reused_bufnr)
end)
assert(not vim.api.nvim_buf_is_valid(reused_bufnr), "reviews buffer was not wiped on clear")
assert(#vim.api.nvim_list_wins() == 1, "reviews split did not close when buffer was wiped")
assert(vim.api.nvim_get_current_win() == source_winid, "focus did not return to the source window after clear")

vim.fn.delete(repo_dir, "rf")
print("PASS: reviews split opened, closed, re-pulled, and cleared correctly")
