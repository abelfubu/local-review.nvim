-- Reviews split smoke test for read-only PR review summaries.
-- Run with: nvim --headless -u NONE -l tests/gh_reviews_smoke.lua

local plugin_root = vim.uv.cwd()
vim.opt.runtimepath:append(plugin_root)

require("local_review").setup({ storage_dir = vim.fn.tempname() .. "_gh_reviews_smoke", keymaps = {} })

local source_path = vim.fn.tempname() .. ".lua"
vim.fn.writefile({ "local value = 1" }, source_path)
vim.cmd.edit(vim.fn.fnameescape(source_path))

local source_winid = vim.api.nvim_get_current_win()

local reviews = {
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

require("local_review.presentation.ui").open_reviews_split(reviews)

local windows = vim.api.nvim_list_wins()
assert(#windows == 2, "reviews split did not open a second window")

local review_winid = vim.api.nvim_get_current_win()
assert(review_winid ~= source_winid, "reviews split did not open in a new window")

local review_bufnr = vim.api.nvim_get_current_buf()
assert(vim.bo[review_bufnr].filetype == "markdown", "reviews buffer is not markdown filetype")
assert(not vim.bo[review_bufnr].modifiable, "reviews buffer is modifiable")
assert(vim.bo[review_bufnr].bufhidden == "wipe", "reviews buffer is not bufhidden=wipe")
assert(vim.api.nvim_buf_get_name(review_bufnr):find("gh%-reviews"), "reviews buffer name does not contain gh-reviews")

local lines = vim.api.nvim_buf_get_lines(review_bufnr, 0, -1, false)
local found_first = false
local found_second = false
for _, line in ipairs(lines) do
  if line:find("@reviewer%-one") and line:find("COMMENTED") and line:find("2024%-01%-15") then
    found_first = true
  end
  if line:find("@reviewer%-two") and line:find("APPROVED") and line:find("2024%-02%-20") then
    found_second = true
  end
end
assert(found_first, "first review section not rendered")
assert(found_second, "second review section not rendered")

-- Close with the mapped 'q' key.
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("q", true, false, true), "x", false)
vim.wait(200, function()
  return not vim.api.nvim_win_is_valid(review_winid)
end)
assert(not vim.api.nvim_win_is_valid(review_winid), "reviews split did not close on q")
assert(vim.api.nvim_get_current_win() == source_winid, "focus did not return to the source window")

vim.fn.delete(source_path)
print("PASS: reviews split opened as markdown, was non-modifiable, rendered sections, and closed on q")
