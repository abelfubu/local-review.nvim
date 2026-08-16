-- Hover smoke test for review comment hover peek and remote-viewer removal.
-- Run with: nvim --headless -u NONE -l tests/hover_smoke.lua

local plugin_root = vim.uv.cwd()
vim.opt.runtimepath:append(plugin_root)

local storage_dir = vim.fn.tempname() .. "_hover_smoke"
local source_path = vim.fn.tempname() .. ".lua"
vim.fn.mkdir(storage_dir, "p")
vim.fn.writefile({ "local first = 1", "local second = 2", "local third = 3" }, source_path)

require("local_review").setup({ storage_dir = storage_dir, keymaps = { hover = "K" } })
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

local remote_only_comment = {
  id = "gh:comment-2",
  origin = "github",
  absolute_path = absolute_path,
  relative_path = vim.fn.fnamemodify(absolute_path, ":t"),
  body = "Remote-only comment.",
  created_at = "2024-01-01T00:00:00Z",
  updated_at = "2024-01-01T00:00:00Z",
  anchor = { line_number = 2, line_text = "local second = 2" },
  line_end = 2,
  source_kind = "github",
  source_meta = {},
  stale = false,
  remote = {
    repository = "owner/repo",
    pull_number = 1,
    thread_id = "thread-2",
    comment_id = "comment-2",
    author = "reviewer",
    url = "https://github.com/owner/repo/pull/1#discussion_r2",
    resolved = false,
    outdated = false,
  },
}

vim.fn.writefile({ vim.json.encode({ scope_root = scope_root, comments = { local_comment } }) }, scope_file)

-- Session remotes are not persisted; load them through the in-memory session store.
local gh_session = require("local_review.application.gh_session")
---@diagnostic disable-next-line: duplicate-set-field
context.current_branch = function()
  return "main"
end
gh_session.set(scope_root, { remote_comment, remote_only_comment }, {}, 1, "main")

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

local function find_editor_winid()
  for _, winid in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(winid) then
      local bufnr = vim.api.nvim_win_get_buf(winid)
      local name = vim.api.nvim_buf_get_name(bufnr)
      if name:find("local%-review://comment") then
        return winid
      end
    end
  end
  return nil
end

local function win_count()
  local count = 0
  for _, winid in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(winid) then
      count = count + 1
    end
  end
  return count
end

local function feed(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
end

local notify_message = nil
---@diagnostic disable-next-line: duplicate-set-field
vim.notify = function(msg, level)
  notify_message = { msg = msg, level = level }
end

-- Press K on the commented line.
vim.api.nvim_win_set_cursor(source_winid, { 1, 0 })
feed("K")

local hover_winid = find_hover_winid()
assert(hover_winid, "hover did not open on commented line")
assert(hover_winid ~= source_winid, "hover is not a new window")

local hover_bufnr = vim.api.nvim_win_get_buf(hover_winid)
assert(vim.bo[hover_bufnr].filetype == "markdown", "hover buffer is not markdown filetype")
assert(not vim.bo[hover_bufnr].modifiable, "hover buffer is modifiable")
assert(vim.api.nvim_get_current_win() == source_winid, "hover should not be focused initially")
assert(vim.api.nvim_win_get_config(hover_winid).focusable == false, "hover window should not be focusable initially")

local hover_lines = vim.api.nvim_buf_get_lines(hover_bufnr, 0, -1, false)
local found_local_header = false
local found_remote_header = false
local found_local_body = false
local found_remote_body = false
for _, line in ipairs(hover_lines) do
  if line:find("### Review Comment") then
    found_local_header = true
  end
  if line:find("### @reviewer") then
    found_remote_header = true
  end
  if line:find("Local %*%*feedback%*%*") then
    found_local_body = true
  end
  if line:find("Remote %*%*feedback%*%*") then
    found_remote_body = true
  end
end
assert(found_local_header, "hover did not render the local comment header")
assert(found_remote_header, "hover did not render the remote author header")
assert(found_local_body, "hover did not render the local comment body")
assert(found_remote_body, "hover did not render the remote comment body")

-- Second K focuses the hover and cancels auto-close.
feed("K")
assert(vim.api.nvim_get_current_win() == hover_winid, "second K did not focus the hover")

-- Moving the cursor inside the focused hover must not close it.
vim.api.nvim_win_set_cursor(hover_winid, { 2, 0 })
vim.api.nvim_exec_autocmds("CursorMoved", { buffer = hover_bufnr })
assert(find_hover_winid() ~= nil, "hover closed after moving cursor inside the focused window")

-- q closes the hover and returns focus to the source window.
feed("q")
vim.wait(200, function()
  return not vim.api.nvim_win_is_valid(hover_winid)
end)
assert(not vim.api.nvim_win_is_valid(hover_winid), "hover did not close on q")
assert(vim.api.nvim_get_current_win() == source_winid, "focus did not return to the source window after q")

-- Move to another line in the source to trigger CursorMoved and close any stale hover.
vim.api.nvim_win_set_cursor(source_winid, { 3, 0 })
vim.api.nvim_exec_autocmds("CursorMoved", { buffer = source_bufnr })
assert(find_hover_winid() == nil, "hover did not close on CursorMoved")

-- Press K on a commentless line; it should not open the hover.
vim.api.nvim_win_set_cursor(source_winid, { 3, 0 })
feed("K")
assert(find_hover_winid() == nil, "hover opened on a commentless line")

-- :LocalReviewComment on a remote-only line must notify and open nothing.
notify_message = nil
vim.api.nvim_win_set_cursor(source_winid, { 2, 0 })
vim.cmd("LocalReviewComment")
assert(notify_message, "remote-only comment key did not notify")
assert(
  notify_message.msg:find("GitHub comments are read%-only") and notify_message.level == vim.log.levels.INFO,
  "remote-only comment key did not show the expected INFO notification"
)
assert(win_count() == 1, "remote-only comment key opened a window")
assert(find_editor_winid() == nil, "remote-only comment key opened an editor")
assert(find_hover_winid() == nil, "remote-only comment key opened a hover")

-- :LocalReviewComment on a line with a local comment opens the editor.
vim.api.nvim_win_set_cursor(source_winid, { 1, 0 })
vim.cmd("LocalReviewComment")
local editor_winid = find_editor_winid()
assert(editor_winid, "comment key did not open the editor for a local comment")
assert(editor_winid ~= source_winid, "editor did not open in a new window")
feed("q")
vim.wait(200, function()
  return not vim.api.nvim_win_is_valid(editor_winid)
end)
assert(not vim.api.nvim_win_is_valid(editor_winid), "editor did not close on q")
assert(vim.api.nvim_get_current_win() == source_winid, "focus did not return to the source window after editor q")

vim.fn.delete(storage_dir, "rf")
vim.fn.delete(source_path)
print("PASS: hover peek is the single reader, focuses persistently, and returns focus on q")
