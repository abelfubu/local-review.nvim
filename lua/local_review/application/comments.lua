local M = {}

local context = require("local_review.infrastructure.context")
local positioning = require("local_review.domain.positioning")
local storage = require("local_review.infrastructure.storage")
local comment_store = require("local_review.domain.comment_store")
local gh_session = require("local_review.application.gh_session")

local state = {
  file_fingerprints = {},
  line_selection = {},
  jump_cursor = nil,
}

local function now()
  return tostring(os.date("!%Y-%m-%dT%H:%M:%SZ"))
end

local function hrtime()
  ---@diagnostic disable-next-line: undefined-field
  return vim.uv.hrtime()
end

local function generate_id()
  return tostring(hrtime())
end

---@param bufnr integer
---@return string[]
local function buffer_lines(bufnr)
  return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
end

local function current_line()
  return vim.api.nvim_win_get_cursor(0)[1]
end

---Announces that comments in the scope changed; presentation subscribes via
---the `User`/`LocalReviewChanged` autocmd registered in init.lua.
local function refresh_scope_buffers(scope_root)
  vim.api.nvim_exec_autocmds("User", {
    pattern = "LocalReviewChanged",
    data = { scope_root = scope_root },
  })
end

local function persist_scope_state(scope_root, data)
  local ok, err = storage.save_scope(scope_root, data)
  if not ok then
    return nil, err
  end

  refresh_scope_buffers(scope_root)
  return true
end

---@param lines string[]
---@return string
local function buffer_fingerprint(lines)
  return vim.fn.sha256(table.concat(lines, "\n"))
end

local function reconcile_buffer_state(bufnr, scope_state, ctx)
  local lines = buffer_lines(bufnr)
  local fingerprint = buffer_fingerprint(lines)
  local previous = state.file_fingerprints[ctx.absolute_path]
  local comments = scope_state.data.comments

  if previous == fingerprint then
    return scope_state
  end

  local changed = false
  for _, comment in ipairs(comments) do
    if comment.absolute_path == ctx.absolute_path then
      if comment_store.reconcile_comment(comment, lines, positioning.resolve, positioning.capture) then
        changed = true
      end
    end
  end

  if changed then
    local ok, err = storage.save_scope(ctx.scope_root, scope_state.data)
    if not ok then
      vim.notify(err or "Failed to save review comments.", vim.log.levels.ERROR)
    end
  end

  state.file_fingerprints[ctx.absolute_path] = fingerprint
  return scope_state
end

local function scope_state_for_buffer(bufnr)
  local ctx, err = context.comment_context(bufnr)
  if not ctx then
    return nil, err
  end

  local scope_state = {
    scope_root = ctx.scope_root,
    data = storage.load_scope(ctx.scope_root),
  }

  reconcile_buffer_state(bufnr or 0, scope_state, ctx)
  return {
    ctx = ctx,
    scope_state = scope_state,
  }
end

---Return local and session remote comments for a path, merged and sorted.
---@param scope_root string
---@param target_path string
---@param kind "file"|"directory"
---@return LocalReviewComment[]
local function union_comments_for_path(scope_root, target_path, kind)
  local locals = storage.comments_for_path(scope_root, target_path, kind)
  local remotes = gh_session.comments_for_path(scope_root, target_path, kind)

  return comment_store.merge_sorted_comments(locals, remotes)
end

---Return the merged comment set for a buffer (local + session remotes).
---@param ctx { absolute_path: string, scope_root: string }
---@return LocalReviewComment[]
local function buffer_comments(ctx)
  return union_comments_for_path(ctx.scope_root, ctx.absolute_path, "file")
end

---@return LocalReviewComment?, boolean?, string?
local function upsert_comment(scope_state, ctx, line, body, line_end)
  local filetype = vim.bo[ctx.bufnr].filetype or ""
  return comment_store.upsert_comment(scope_state.data.comments, {
    absolute_path = ctx.absolute_path,
    relative_path = ctx.relative_path,
    line = line,
    body = body,
    line_end = line_end,
    lines = buffer_lines(ctx.bufnr),
    timestamp = now(),
    capture = positioning.capture,
    generate_id = generate_id,
    source_kind = filetype:match("^Diffview") and "diffview" or "buffer",
    source_meta = {},
  })
end

local function find_comment_index_by_id(comments, id)
  for index, comment in ipairs(comments) do
    if comment.id == id then
      return index
    end
  end
  return nil
end

local function select_comment_at_line(comments, absolute_path, bufnr, line, advance)
  local matches = comment_store.comments_at_line(comments, absolute_path, line)
  if #matches == 0 then
    return nil, nil
  end

  local selection = state.line_selection[bufnr]
  local index = 1
  if selection and selection.path == absolute_path and selection.line == line then
    index = selection.index
    if advance then
      index = (index % #matches) + 1
    end
  end
  state.line_selection[bufnr] = { path = absolute_path, line = line, index = index }

  return matches[index], nil
end

---Build a line-state result. For session remotes the scope index is nil.
---@param scope_state table
---@param ctx table
---@param comment LocalReviewComment?
---@return table
local function line_result(scope_state, ctx, comment)
  return {
    ---@type LocalReviewComment?
    comment = comment,
    index = comment and not comment_store.is_remote(comment) and find_comment_index_by_id(
      scope_state.data.comments,
      comment.id
    ) or nil,
    ctx = ctx,
    scope_state = scope_state,
  }
end

local function find_current_comment()
  local resolved, err = scope_state_for_buffer(0)
  if not resolved then
    vim.notify(err or "Failed to find the current review comment.", vim.log.levels.WARN)
    return nil
  end

  local line = current_line()
  local all = buffer_comments(resolved.ctx)
  local comment = select_comment_at_line(all, resolved.ctx.absolute_path, resolved.ctx.bufnr, line)
  return line_result(resolved.scope_state, resolved.ctx, comment)
end

local function find_line_comment(bufnr, line)
  local resolved, err = scope_state_for_buffer(bufnr)
  if not resolved then
    return nil, err
  end

  local all = buffer_comments(resolved.ctx)
  local comment = select_comment_at_line(all, resolved.ctx.absolute_path, bufnr, line, false)
  return line_result(resolved.scope_state, resolved.ctx, comment)
end

---Return true if a session remote occupies any line in the range.
---@param ctx table
---@param line integer
---@param line_end integer?
---@return boolean
local function session_remote_at_line(ctx, line, line_end)
  local session_comments = gh_session.comments_for_path(ctx.scope_root, ctx.absolute_path, "file")
  if #session_comments == 0 then
    return false
  end

  local start_line = math.min(line, line_end or line)
  local end_line = math.max(line, line_end or line)
  for l = start_line, end_line do
    local matches = comment_store.comments_at_line(session_comments, ctx.absolute_path, l)
    if #matches > 0 then
      return true
    end
  end
  return false
end

function M.status_label(comment)
  if comment and comment.stale then
    return "stale"
  end
  return nil
end

---@param path string?
---@return LocalReviewComment[]? comments, string? target_path, "file"|"directory"? kind, string? scope_root
function M.list_comments_in_path(path)
  local target = path
  if target == nil or target == "" then
    target = context.default_export_root()
  end

  local kind, normalized_or_err = context.path_kind(target)
  if not kind then
    return nil, normalized_or_err
  end

  local scope_root, scope_err = context.scope_root(normalized_or_err)
  if not scope_root then
    return nil, scope_err
  end

  return union_comments_for_path(scope_root, normalized_or_err, kind), normalized_or_err, kind, scope_root
end

function M.comments_for_buffer(bufnr, opts)
  local resolved, err = scope_state_for_buffer(bufnr or 0)
  if not resolved then
    if not (opts and opts.silent) then
      vim.notify(err or "Failed to load comments for the current buffer.", vim.log.levels.WARN)
    end
    return {}
  end

  return buffer_comments(resolved.ctx)
end

function M.get_line_state(bufnr, line)
  local result, err = find_line_comment(bufnr or 0, line)
  if not result then
    vim.notify(err or "Failed to find a review comment for the current line.", vim.log.levels.WARN)
    return nil
  end

  return result
end

function M.set_line_comment(bufnr, line, body, range)
  local line_state = M.get_line_state(bufnr, line)
  if not line_state then
    return nil, "Unable to resolve comment target."
  end

  local trimmed = vim.trim(body or "")

  local anchor_line = line
  local line_end = nil
  if range then
    anchor_line = math.min(range.start_line, range.end_line)
    line_end = math.max(range.start_line, range.end_line)
  end

  if line_state.comment and comment_store.is_remote(line_state.comment) then
    return nil, "Remote comments are read-only"
  end

  if trimmed == "" then
    if line_state.index ~= nil then
      table.remove(line_state.scope_state.data.comments, line_state.index)
      local ok, err = persist_scope_state(line_state.ctx.scope_root, line_state.scope_state.data)
      if not ok then
        return nil, err
      end
      return "deleted"
    end

    return "noop"
  end

  if session_remote_at_line(line_state.ctx, anchor_line, line_end) then
    return nil, "Remote comments are read-only"
  end

  if line_state.comment then
    -- line_state.comment comes from a separate load_scope() deep copy than
    -- scope_state.data.comments; mutating it would not touch the persisted
    -- table. Write through to the stored entry (located by id) instead.
    local stored = line_state.index and line_state.scope_state.data.comments[line_state.index] or nil
    if not stored then
      return nil, "Failed to locate the stored review comment."
    end

    local lines = buffer_lines(line_state.ctx.bufnr)
    local resolved_line = comment_store.clamp_line(anchor_line, lines)
    local resolved_end = comment_store.clamp_line(math.max(anchor_line, line_end or anchor_line), lines)

    stored.body = trimmed
    stored.updated_at = now()
    stored.absolute_path = line_state.ctx.absolute_path
    stored.relative_path = line_state.ctx.relative_path
    comment_store.apply_anchor(stored, positioning.capture, lines, resolved_line)
    stored.line_end = resolved_end
    if resolved_end > resolved_line then
      comment_store.apply_anchor_end(stored, positioning.capture, lines, resolved_end)
    else
      stored.anchor_end = nil
    end
    -- The edit re-anchors the comment on current buffer content.
    stored.stale = nil

    local ok, persist_err = persist_scope_state(line_state.ctx.scope_root, line_state.scope_state.data)
    if not ok then
      return nil, persist_err
    end
    return "updated"
  end

  local _, updated, reason = upsert_comment(line_state.scope_state, line_state.ctx, anchor_line, trimmed, line_end)
  if reason then
    return nil, reason
  end

  local ok, persist_err = persist_scope_state(line_state.ctx.scope_root, line_state.scope_state.data)
  if not ok then
    return nil, persist_err
  end
  return updated and "updated" or "created"
end

function M.delete_line_comment(bufnr, line)
  local line_state = M.get_line_state(bufnr, line)
  if not line_state then
    return nil, "Unable to resolve comment target."
  end

  if line_state.comment and comment_store.is_remote(line_state.comment) then
    return nil, "Remote comments are read-only"
  end

  if line_state.index == nil then
    return "missing"
  end

  local comments = line_state.scope_state.data.comments
  local removed, reason = comment_store.remove_comment(comments, comments[line_state.index])
  if not removed then
    return nil, reason
  end

  local ok, err = persist_scope_state(line_state.ctx.scope_root, line_state.scope_state.data)
  if not ok then
    return nil, err
  end
  return "deleted"
end

function M.delete_current_line()
  local result = find_current_comment()
  if not result then
    return
  end

  if result.comment and comment_store.is_remote(result.comment) then
    vim.notify("Remote comments are read-only", vim.log.levels.WARN)
    return
  end

  if result.index == nil then
    vim.notify("No review comment on the current line.", vim.log.levels.INFO)
    return
  end

  local comment = result.scope_state.data.comments[result.index]
  local removed, reason = comment_store.remove_comment(result.scope_state.data.comments, comment)
  if not removed then
    vim.notify(reason, vim.log.levels.WARN)
    return
  end

  local ok, err = persist_scope_state(result.ctx.scope_root, result.scope_state.data)
  if not ok then
    vim.notify(err or "Failed to delete the review comment.", vim.log.levels.ERROR)
    return
  end
  vim.notify("Review comment deleted.", vim.log.levels.INFO)
end

function M.jump(direction)
  local comments = M.comments_for_buffer(0)
  if #comments == 0 then
    vim.notify("No review comments in the current buffer.", vim.log.levels.INFO)
    return
  end

  table.sort(comments, comment_store.comment_sorter)

  local line = current_line()
  local cursor_index = nil
  local absolute_path = comments[1] and comments[1].absolute_path

  if state.jump_cursor and state.jump_cursor.comment_id and absolute_path then
    for index, comment in ipairs(comments) do
      if comment.id == state.jump_cursor.comment_id then
        if comment_store.comment_covers_line(comment, absolute_path, line) then
          cursor_index = index
        end
        break
      end
    end
  end

  if cursor_index == nil then
    for index, comment in ipairs(comments) do
      if comment.anchor.line_number == line then
        cursor_index = index
        break
      end
    end
  end

  if cursor_index == nil then
    if direction > 0 then
      for index, comment in ipairs(comments) do
        if comment.anchor.line_number > line then
          cursor_index = index
          break
        end
      end
      cursor_index = cursor_index or 1
    else
      for index = #comments, 1, -1 do
        if comments[index].anchor.line_number < line then
          cursor_index = index
          break
        end
      end
      cursor_index = cursor_index or #comments
    end
  end

  local target_index = cursor_index + direction
  if target_index > #comments then
    target_index = 1
  elseif target_index < 1 then
    target_index = #comments
  end

  local target = comments[target_index]
  state.jump_cursor = { comment_id = target.id }

  local max_line = math.max(vim.api.nvim_buf_line_count(0), 1)
  local target_line = math.max(1, math.min(target.anchor.line_number, max_line))
  vim.api.nvim_win_set_cursor(0, { target_line, 0 })
  if target.stale then
    vim.notify("Jumped to a stale review comment.", vim.log.levels.WARN)
  end
end

function M.clear_path(path, opts)
  local silent = opts and opts.silent

  local target = path
  if target == nil or target == "" then
    target = context.default_export_root()
  end

  local kind, normalized_or_err = context.path_kind(target)
  if not kind then
    vim.notify(normalized_or_err or "Failed to resolve comment scope.", vim.log.levels.WARN)
    return
  end

  local scope_root, scope_err = context.scope_root(normalized_or_err)
  if not scope_root then
    vim.notify(scope_err or "Failed to resolve comment scope.", vim.log.levels.WARN)
    return
  end

  local comments_in_path = storage.comments_for_path(scope_root, normalized_or_err, kind)
  if #comments_in_path == 0 then
    if not silent then
      vim.notify("No review comments found for the selected path.", vim.log.levels.INFO)
    end
    return
  end

  local removed, err = storage.remove_comments_for_path(scope_root, normalized_or_err, kind)
  if not removed then
    vim.notify(err or "Failed to clear review comments.", vim.log.levels.ERROR)
    return
  end

  if #removed > 0 then
    refresh_scope_buffers(scope_root)
  end

  if not silent then
    vim.notify("Cleared review comments for selected path.", vim.log.levels.INFO)
  end
end

function M.clear_repo()
  M.clear_path()
end

return M
