local M = {}

local context = require("local_review.context")
local positioning = require("local_review.positioning")
local storage = require("local_review.storage")
local comment_store = require("local_review.comment_store")
local session = require("local_review.session")

local function ensure_binding(line_state)
  local binding = line_state.ctx.git_binding
  if binding and binding.kind == "branch" and not line_state.session.binding then
    session.bind(line_state.scope_state.data, binding)
  end
  return true
end

local state = {
  file_fingerprints = {},
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

local function ensure_defaults(comment)
  comment_store.ensure_comment_defaults(comment, generate_id)
end

---@param bufnr integer
---@return string[]
local function buffer_lines(bufnr)
  return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
end

local function current_line()
  return vim.api.nvim_win_get_cursor(0)[1]
end

local function refresh_scope_buffers(scope_root)
  local markers = require("local_review.markers")
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].buftype == "" then
      local path = vim.api.nvim_buf_get_name(bufnr)
      if path ~= "" then
        local root = context.scope_root(path)
        if root == scope_root then
          markers.refresh(bufnr)
        end
      end
    end
  end
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
      if comment_store.reconcile_comment(comment, lines, positioning.resolve, positioning.capture, generate_id) then
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
  local session_state = session.open(scope_state.data, ctx.git_binding)

  reconcile_buffer_state(bufnr or 0, scope_state, ctx)
  return {
    ctx = ctx,
    scope_state = scope_state,
    session = session_state,
  }
end

---@return LocalReviewComment, boolean
local function upsert_comment(scope_state, ctx, line, body, line_end)
  local filetype = vim.bo[ctx.bufnr].filetype or ""
  return comment_store.upsert_comment(scope_state.data.comments, {
    absolute_path = ctx.absolute_path,
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

local function find_current_comment()
  local resolved, err = scope_state_for_buffer(0)
  if not resolved then
    vim.notify(err or "Failed to find the current review comment.", vim.log.levels.WARN)
    return nil
  end

  local line = current_line()
  local comment, index =
    comment_store.find_comment_entry_at_line(resolved.scope_state.data.comments, resolved.ctx.absolute_path, line)
  return {
    ---@type LocalReviewComment?
    comment = comment,
    index = index,
    ctx = resolved.ctx,
    scope_state = resolved.scope_state,
    session = resolved.session,
  }
end

local function find_line_comment(bufnr, line)
  local resolved, err = scope_state_for_buffer(bufnr)
  if not resolved then
    return nil, err
  end

  local comment, index =
    comment_store.find_comment_entry_at_line(resolved.scope_state.data.comments, resolved.ctx.absolute_path, line)
  return {
    ---@type LocalReviewComment?
    comment = comment,
    index = index,
    ctx = resolved.ctx,
    scope_state = resolved.scope_state,
    session = resolved.session,
  }
end

local function comments_in_scope(scope_root)
  local data = storage.load_scope(scope_root)
  for _, comment in ipairs(data.comments) do
    ensure_defaults(comment)
  end
  table.sort(data.comments, comment_store.comment_sorter)
  return data.comments
end

local function comments_matching_path(target_path, kind)
  local matches = {}
  for _, scope in ipairs(storage.list_scopes()) do
    for _, comment in ipairs(scope.data.comments or {}) do
      ensure_defaults(comment)
      if kind == "file" then
        if comment.absolute_path == target_path then
          table.insert(matches, comment)
        end
      elseif context.is_within(target_path, comment.absolute_path) then
        table.insert(matches, comment)
      end
    end
  end

  table.sort(matches, comment_store.comment_sorter)
  return matches
end

local function remove_matching_comments(target_path, kind)
  local changed_scopes = {}

  for _, scope in ipairs(storage.list_scopes()) do
    local kept = {}
    local changed = false
    for _, comment in ipairs(scope.data.comments or {}) do
      local matches = false
      if kind == "file" then
        matches = comment.absolute_path == target_path
      else
        matches = context.is_within(target_path, comment.absolute_path)
      end

      if matches then
        changed = true
      else
        table.insert(kept, comment)
      end
    end

    if changed then
      local new_data = { scope_root = scope.scope_root }
      for key, value in pairs(scope.data) do
        new_data[key] = value
      end
      new_data.comments = kept
      changed_scopes[#changed_scopes + 1] = {
        scope_root = scope.scope_root,
        data = new_data,
      }
    end
  end

  return changed_scopes
end

function M.status_label(comment)
  if comment and comment.stale then
    return "stale"
  end
  return nil
end

function M.list_scope_comments(scope_root)
  return comments_in_scope(scope_root)
end

function M.list_comments_in_path(path)
  local target = path
  if target == nil or target == "" then
    target = context.default_export_root()
  end

  local kind, normalized_or_err = context.path_kind(target)
  if not kind then
    return nil, normalized_or_err
  end

  return comments_matching_path(normalized_or_err, kind), normalized_or_err, kind
end

function M.comments_for_buffer(bufnr, opts)
  local resolved, err = scope_state_for_buffer(bufnr or 0)
  if not resolved then
    if not (opts and opts.silent) then
      vim.notify(err or "Failed to load comments for the current buffer.", vim.log.levels.WARN)
    end
    return {}
  end

  local matches = {}
  for _, comment in ipairs(comments_in_scope(resolved.ctx.scope_root)) do
    if comment.absolute_path == resolved.ctx.absolute_path then
      table.insert(matches, comment)
    end
  end
  return matches
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
  if not line_state.session.available then
    return nil,
      string.format("Review session belongs to %s; findings cannot be changed here.", line_state.session.bound_to)
  end

  local trimmed = vim.trim(body or "")
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

  ensure_binding(line_state)

  local anchor_line = line
  local line_end = nil
  if range then
    anchor_line = math.min(range.start_line, range.end_line)
    line_end = math.max(range.start_line, range.end_line)
  end

  local _, updated = upsert_comment(line_state.scope_state, line_state.ctx, anchor_line, trimmed, line_end)
  local ok, err = persist_scope_state(line_state.ctx.scope_root, line_state.scope_state.data)
  if not ok then
    return nil, err
  end
  return updated and "updated" or "created"
end

function M.delete_line_comment(bufnr, line)
  local line_state = M.get_line_state(bufnr, line)
  if not line_state then
    return nil, "Unable to resolve comment target."
  end
  if not line_state.session.available then
    return nil,
      string.format("Review session belongs to %s; findings cannot be changed here.", line_state.session.bound_to)
  end

  if line_state.index == nil then
    return "missing"
  end

  table.remove(line_state.scope_state.data.comments, line_state.index)
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

  if result.index == nil then
    vim.notify("No review comment on the current line.", vim.log.levels.INFO)
    return
  end
  if not result.session.available then
    vim.notify(
      string.format("Review session belongs to %s; findings cannot be changed here.", result.session.bound_to),
      vim.log.levels.WARN
    )
    return
  end

  table.remove(result.scope_state.data.comments, result.index)
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

  local line = current_line()
  table.sort(comments, function(a, b)
    return a.anchor.line_number < b.anchor.line_number
  end)

  local target
  if direction > 0 then
    for _, comment in ipairs(comments) do
      if comment.anchor.line_number > line then
        target = comment
        break
      end
    end
    target = target or comments[1]
  else
    for index = #comments, 1, -1 do
      if comments[index].anchor.line_number < line then
        target = comments[index]
        break
      end
    end
    target = target or comments[#comments]
  end

  local max_line = math.max(vim.api.nvim_buf_line_count(0), 1)
  local target_line = math.max(1, math.min(target.anchor.line_number, max_line))
  vim.api.nvim_win_set_cursor(0, { target_line, 0 })
  if target.stale then
    vim.notify("Jumped to a stale review comment.", vim.log.levels.WARN)
  end
end

function M.clear_path(path, opts)
  local silent = opts and opts.silent
  local comments_in_path, target_path, kind = M.list_comments_in_path(path)
  if not comments_in_path then
    vim.notify(target_path or "Failed to resolve comment scope.", vim.log.levels.WARN)
    return
  end

  if #comments_in_path == 0 then
    if not silent then
      vim.notify("No review comments found for the selected path.", vim.log.levels.INFO)
    end
    return
  end

  local changed_scopes = remove_matching_comments(target_path, kind)
  for _, scope in ipairs(changed_scopes) do
    local binding = context.git_binding(scope.scope_root)
    local session_state = session.open(scope.data, binding)
    if not session_state.available then
      vim.notify(
        string.format("Review session belongs to %s; findings cannot be changed here.", session_state.bound_to),
        vim.log.levels.WARN
      )
      return
    end
  end

  for _, scope in ipairs(changed_scopes) do
    if #scope.data.comments == 0 then
      if not storage.delete_scope(scope.scope_root) then
        local ok, err = persist_scope_state(scope.scope_root, scope.data)
        if not ok then
          vim.notify(err or "Failed to clear review comments.", vim.log.levels.ERROR)
          return
        end
      else
        refresh_scope_buffers(scope.scope_root)
      end
    else
      local ok, err = persist_scope_state(scope.scope_root, scope.data)
      if not ok then
        vim.notify(err or "Failed to clear review comments.", vim.log.levels.ERROR)
        return
      end
    end
  end

  if not silent then
    vim.notify("Cleared review comments for selected path.", vim.log.levels.INFO)
  end
end

function M.clear_repo()
  M.clear_path()
end

return M
