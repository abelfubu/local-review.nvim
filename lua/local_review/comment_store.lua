local M = {}

---@class LocalReviewComment
---@field id string
---@field absolute_path string
---@field body string
---@field created_at string
---@field updated_at string
---@field source_kind string
---@field source_meta table
---@field stale boolean
---@field line_end integer?
---@field anchor LineAnchor
---@field anchor_end LineAnchor?

---@param comment LocalReviewComment
---@param generate_id (fun(): string)?
function M.ensure_comment_defaults(comment, generate_id)
  if comment.id == "" and generate_id then
    comment.id = generate_id()
  end
  if comment.stale == nil then
    comment.stale = false
  end
  if comment.line_end == nil then
    if comment.anchor_end then
      comment.line_end = comment.anchor_end.line_number
    else
      comment.line_end = comment.anchor.line_number
    end
  end
  if comment.line_end < comment.anchor.line_number then
    comment.line_end = comment.anchor.line_number
  end
end

---@param line integer
---@param lines string[]
---@return integer
function M.clamp_line(line, lines)
  local max_line = math.max(#lines, 1)
  return math.max(1, math.min(line, max_line))
end

---@param comment LocalReviewComment
---@param absolute_path string
---@param line integer
---@return boolean
function M.comment_covers_line(comment, absolute_path, line)
  if comment.absolute_path ~= absolute_path then
    return false
  end

  local first = comment.anchor.line_number
  local last = math.max(first, comment.line_end or first)
  return line >= first and line <= last
end

---@param comments LocalReviewComment[]
---@param absolute_path string
---@param line integer
---@param generate_id (fun(): string)?
---@return LocalReviewComment?
function M.find_comment_at_line(comments, absolute_path, line, generate_id)
  for _, comment in ipairs(comments) do
    M.ensure_comment_defaults(comment, generate_id)
    if M.comment_covers_line(comment, absolute_path, line) then
      return comment
    end
  end
  return nil
end

---@param comments LocalReviewComment[]
---@param absolute_path string
---@param line integer
---@param generate_id (fun(): string)?
---@return LocalReviewComment?, integer?
function M.find_comment_entry_at_line(comments, absolute_path, line, generate_id)
  for index, comment in ipairs(comments) do
    M.ensure_comment_defaults(comment, generate_id)
    if M.comment_covers_line(comment, absolute_path, line) then
      return comment, index
    end
  end
  return nil, nil
end

---@param comment LocalReviewComment
---@param capture fun(lines: string[], line: integer): LineAnchor
---@param lines string[]
---@param line integer
function M.apply_anchor(comment, capture, lines, line)
  comment.anchor = capture(lines, line)
  comment.stale = false
end

---@param comment LocalReviewComment
---@param capture fun(lines: string[], line: integer): LineAnchor
---@param lines string[]
---@param line integer
function M.apply_anchor_end(comment, capture, lines, line)
  comment.anchor_end = capture(lines, line)
end

---@param comment LocalReviewComment
---@param lines string[]
---@param resolve fun(anchor: LineAnchor, lines: string[]): integer?
---@param capture fun(lines: string[], line: integer): LineAnchor
---@param generate_id fun(): string
---@return boolean
function M.reconcile_comment(comment, lines, resolve, capture, generate_id)
  M.ensure_comment_defaults(comment, generate_id)

  -- Comments created before dual-anchor support only store a single anchor.
  -- Keep the legacy delta-shift behaviour for them; they will be upgraded to
  -- dual anchors the next time the comment is re-created or edited with a
  -- range.
  local is_legacy = comment.anchor_end == nil

  if is_legacy then
    return M.reconcile_legacy_comment(comment, lines, resolve, capture)
  end

  return M.reconcile_dual_anchor_comment(comment, lines, resolve, capture)
end

---@param comment LocalReviewComment
---@param lines string[]
---@param resolve fun(anchor: LineAnchor, lines: string[]): integer?
---@param capture fun(lines: string[], line: integer): LineAnchor
---@return boolean
function M.reconcile_legacy_comment(comment, lines, resolve, capture)
  local resolved = resolve(comment.anchor, lines)
  if not resolved then
    if not comment.stale then
      comment.stale = true
      return true
    end
    return false
  end

  if comment.anchor.line_number == resolved and not comment.stale then
    M.apply_anchor(comment, capture, lines, resolved)
    return false
  end

  local line_end = (comment.line_end or comment.anchor.line_number) + (resolved - comment.anchor.line_number)
  M.apply_anchor(comment, capture, lines, resolved)
  comment.line_end = math.max(resolved, line_end)
  return true
end

---@param comment LocalReviewComment
---@param lines string[]
---@param resolve fun(anchor: LineAnchor, lines: string[]): integer?
---@param capture fun(lines: string[], line: integer): LineAnchor
---@return boolean
function M.reconcile_dual_anchor_comment(comment, lines, resolve, capture)
  local resolved_start = resolve(comment.anchor, lines)
  local resolved_end = resolve(comment.anchor_end, lines)

  if not resolved_start and not resolved_end then
    if not comment.stale then
      comment.stale = true
      return true
    end
    return false
  end

  if resolved_start and resolved_end then
    if resolved_end < resolved_start then
      resolved_start, resolved_end = resolved_end, resolved_start
    end

    if
      resolved_start == comment.anchor.line_number
      and resolved_end == comment.anchor_end.line_number
      and not comment.stale
    then
      return false
    end

    M.apply_anchor(comment, capture, lines, resolved_start)
    M.apply_anchor_end(comment, capture, lines, resolved_end)
    comment.line_end = resolved_end
    return true
  end

  -- Partial loss: one end resolves, the other does not. Preserve the resolved
  -- side and mark the comment stale. The lost side keeps its last known
  -- position. Do not use M.apply_anchor here because it resets stale to false.
  comment.stale = true

  if resolved_start then
    comment.anchor = capture(lines, resolved_start)
  elseif resolved_end then
    M.apply_anchor_end(comment, capture, lines, resolved_end)
    comment.line_end = resolved_end
  end

  return true
end

---@class UpsertCommentOpts
---@field absolute_path string
---@field line integer
---@field body string
---@field line_end integer?
---@field lines string[]
---@field timestamp string
---@field capture fun(lines: string[], line: integer): LineAnchor
---@field generate_id fun(): string
---@field source_kind string
---@field source_meta table?

---@param comments LocalReviewComment[]
---@param opts UpsertCommentOpts
---@return LocalReviewComment, boolean
function M.upsert_comment(comments, opts)
  opts = opts or {}

  local existing = M.find_comment_at_line(comments, opts.absolute_path, opts.line)
  local resolved_line = M.clamp_line(opts.line, opts.lines)
  local resolved_end = M.clamp_line(math.max(opts.line, opts.line_end or opts.line), opts.lines)

  if existing then
    M.ensure_comment_defaults(existing, opts.generate_id)
    existing.body = opts.body
    existing.updated_at = opts.timestamp
    existing.absolute_path = opts.absolute_path
    if opts.line_end ~= nil then
      M.apply_anchor(existing, opts.capture, opts.lines, resolved_line)
      existing.line_end = resolved_end
      if resolved_end > resolved_line then
        M.apply_anchor_end(existing, opts.capture, opts.lines, resolved_end)
      else
        existing.anchor_end = nil
      end
    end
    return existing, true
  end

  local comment = {
    id = opts.generate_id(),
    absolute_path = opts.absolute_path,
    body = opts.body,
    created_at = opts.timestamp,
    updated_at = opts.timestamp,
    source_kind = opts.source_kind,
    source_meta = opts.source_meta or {},
    stale = false,
  }

  M.apply_anchor(comment, opts.capture, opts.lines, resolved_line)
  comment.line_end = resolved_end
  if resolved_end > resolved_line then
    M.apply_anchor_end(comment, opts.capture, opts.lines, resolved_end)
  end
  table.insert(comments, comment)
  return comment, false
end

---@param a LocalReviewComment
---@param b LocalReviewComment
---@return boolean
function M.comment_sorter(a, b)
  if a.absolute_path ~= b.absolute_path then
    return a.absolute_path < b.absolute_path
  end
  if a.anchor.line_number ~= b.anchor.line_number then
    return a.anchor.line_number < b.anchor.line_number
  end
  return (a.created_at or "") < (b.created_at or "")
end

return M
