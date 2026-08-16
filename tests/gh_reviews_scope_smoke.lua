-- Regression smoke test: reviews split only wipes for its own scope.
-- Run with: nvim --headless -u NONE -l tests/gh_reviews_scope_smoke.lua

local plugin_root = vim.uv.cwd()
vim.opt.runtimepath:append(plugin_root)

require("local_review").setup({ storage_dir = vim.fn.tempname() .. "_gh_reviews_scope_smoke", keymaps = {} })

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

local function make_scope_dir_and_file(name)
  local dir = vim.fn.tempname() .. "_" .. name
  vim.fn.mkdir(dir, "p")
  local file = vim.fs.joinpath(dir, "file.lua")
  vim.fn.writefile({ string.format("local %s = 1", name) }, file)

  git(dir, "init", "--quiet")
  git(dir, "config", "user.email", "test@example.com")
  git(dir, "config", "user.name", "Test")
  git(dir, "add", "file.lua")
  git(dir, "commit", "-m", "initial", "--quiet")

  return dir, file
end

local scope_a_dir, scope_a_file = make_scope_dir_and_file("a")
local scope_b_dir, scope_b_file = make_scope_dir_and_file("b")

assert(
  context.scope_root(scope_a_file) ~= context.scope_root(scope_b_file),
  "scope roots must be different for the regression"
)

vim.cmd.edit(vim.fn.fnameescape(scope_a_file))
local source_winid = vim.api.nvim_get_current_win()

local scope_a_root = assert(context.comment_context(0).scope_root, "failed to resolve scope A root")
local scope_b_root = assert(context.scope_root(scope_b_file), "failed to resolve scope B root")
local branch_a = assert(context.current_branch(scope_a_root), "failed to resolve branch A")
local branch_b = assert(context.current_branch(scope_b_root), "failed to resolve branch B")

local reviews_a = {
  {
    id = "review-a",
    author = "reviewer-a",
    state = "COMMENTED",
    body = "Scope A review body.",
    url = "https://github.com/owner/repo/pull/1#pullrequestreview-a",
    submitted_at = "2024-01-15T10:00:00Z",
  },
}

local reviews_b = {
  {
    id = "review-b",
    author = "reviewer-b",
    state = "APPROVED",
    body = "Scope B review body.",
    url = "https://github.com/owner/repo/pull/1#pullrequestreview-b",
    submitted_at = "2024-01-20T10:00:00Z",
  },
}

-- Seed scope A's session and open its reviews.
gh_session.set(scope_a_root, {}, reviews_a, 1, branch_a)
ui.open_reviews_split(reviews_a, scope_a_root)

local windows = vim.api.nvim_list_wins()
assert(#windows == 2, "reviews split did not open a second window")

local review_bufnr = vim.api.nvim_get_current_buf()
assert(vim.api.nvim_buf_get_name(review_bufnr):find("gh%-reviews"), "reviews buffer not active")
assert(vim.b[review_bufnr].local_review_scope_root == scope_a_root, "reviews buffer not tagged with scope A")

-- A LocalReviewChanged for an unrelated scope B (with empty session) must NOT wipe the buffer.
gh_session.set(scope_b_root, {}, reviews_b, 1, branch_b)
vim.api.nvim_exec_autocmds("User", {
  pattern = "LocalReviewChanged",
  data = { scope_root = scope_b_root },
})
assert(vim.api.nvim_buf_is_valid(review_bufnr), "reviews buffer closed on unrelated scope change")
assert(#vim.api.nvim_list_wins() == 2, "reviews split closed on unrelated scope change")

-- A LocalReviewChanged for scope A after clearing its session MUST wipe the buffer.
gh_session.clear(scope_a_root)
vim.api.nvim_exec_autocmds("User", {
  pattern = "LocalReviewChanged",
  data = { scope_root = scope_a_root },
})
vim.wait(200, function()
  return not vim.api.nvim_buf_is_valid(review_bufnr)
end)
assert(not vim.api.nvim_buf_is_valid(review_bufnr), "reviews buffer was not wiped on matching scope clear")
assert(#vim.api.nvim_list_wins() == 1, "reviews split did not close when buffer was wiped")
assert(vim.api.nvim_get_current_win() == source_winid, "focus did not return to the source window")

vim.fn.delete(scope_a_file)
vim.fn.delete(scope_b_file)
vim.fn.delete(scope_a_dir, "rf")
vim.fn.delete(scope_b_dir, "rf")
print("PASS: reviews split only wipes for its own scope")
