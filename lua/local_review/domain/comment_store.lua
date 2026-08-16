local M = {}

---@class ReviewMetadata
---@field repository string
---@field pull_number integer
---@field thread_id string
---@field comment_id string
---@field review_id string?
---@field author string
---@field url string
---@field commit_id string?
---@field resolved boolean
---@field outdated boolean

---@class LocalReviewComment
---@field absolute_path string
---@field anchor LineAnchor
---@field anchor_end LineAnchor?
---@field body string
---@field created_at string
---@field id string
---@field line_end integer?
---@field origin "github" | "local"
---@field relative_path string
---@field remote ReviewMetadata?
---@field source_kind string
---@field source_meta table
---@field stale boolean
---@field updated_at string

---Both paths must be absolute and normalized; `context` guarantees this at the
---boundary (creation time for comments, query time for the target path).
---@param dir string
---@param path string
---@return boolean
local function is_within(dir, path)
  return path == dir or path:sub(1, #dir + 1) == dir .. "/"
end

---@param comment LocalReviewComment
---@param target_path string
---@param kind "file"|"directory"
---@return boolean
local function matches_path(comment, target_path, kind)
  if kind == "file" then
    return comment.absolute_path == target_path
  end
  return is_within(target_path, comment.absolute_path)
end

---@param scopes { data: { comments: LocalReviewComment[]? } }[]
---@param target_path string absolute, normalized
---@param kind "file"|"directory"
---@return LocalReviewComment[]
function M.matching_path(scopes, target_path, kind)
  local matches = {}
  for _, scope in ipairs(scopes) do
    for _, comment in ipairs(scope.data.comments or {}) do
      if matches_path(comment, target_path, kind) then
        table.insert(matches, comment)
      end
    end
  end

  table.sort(matches, M.comment_sorter)
  return matches
end

---Splits one comment list into those matching the path and those to keep.
---@param comments LocalReviewComment[]
---@param target_path string absolute, normalized
---@param kind "file"|"directory"
---@return LocalReviewComment[] matched, LocalReviewComment[] kept
function M.partition_path(comments, target_path, kind)
  local matched, kept = {}, {}
  for _, comment in ipairs(comments) do
    if matches_path(comment, target_path, kind) then
      table.insert(matched, comment)
    else
      table.insert(kept, comment)
    end
  end
  return matched, kept
end

---Splits one comment list by id membership (e.g. post-submit cleanup).
---@param comments LocalReviewComment[]
---@param ids table<string, boolean>
---@return LocalReviewComment[] matched, LocalReviewComment[] kept
function M.partition_ids(comments, ids)
  local matched, kept = {}, {}
  for _, comment in ipairs(comments) do
    if ids[comment.id] then
      table.insert(matched, comment)
    else
      table.insert(kept, comment)
    end
  end
  return matched, kept
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
---@return LocalReviewComment?
function M.find_comment_at_line(comments, absolute_path, line)
  for _, comment in ipairs(comments) do
    if M.comment_covers_line(comment, absolute_path, line) then
      return comment
    end
  end
  return nil
end

---@param comments LocalReviewComment[]
---@param absolute_path string
---@param line integer
---@return LocalReviewComment?, integer?
function M.find_comment_entry_at_line(comments, absolute_path, line)
  for index, comment in ipairs(comments) do
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
---@return boolean
function M.reconcile_comment(comment, lines, resolve, capture)
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

---@param comment LocalReviewComment
---@return boolean
function M.is_remote(comment)
  return comment.origin == "github"
end

---@param comment LocalReviewComment
---@return boolean
function M.is_editable(comment)
  return comment.origin == "local"
end

---@class UpsertCommentOpts
---@field absolute_path string
---@field body string
---@field capture fun(lines: string[], line: integer): LineAnchor
---@field generate_id fun(): string
---@field line integer
---@field line_end integer?
---@field lines string[]
---@field relative_path string
---@field source_kind string
---@field source_meta table?
---@field timestamp string

---@param comments LocalReviewComment[]
---@param opts UpsertCommentOpts
---@return LocalReviewComment?, boolean?, string?
function M.upsert_comment(comments, opts)
  opts = opts or {}

  local existing = M.find_comment_at_line(comments, opts.absolute_path, opts.line)

  if existing and M.is_remote(existing) then
    return nil, nil, "Remote comments are read-only"
  end

  local resolved_line = M.clamp_line(opts.line, opts.lines)
  local resolved_end = M.clamp_line(math.max(opts.line, opts.line_end or opts.line), opts.lines)

  if existing then
    existing.body = opts.body
    existing.updated_at = opts.timestamp
    existing.absolute_path = opts.absolute_path
    existing.relative_path = opts.relative_path
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
    relative_path = opts.relative_path,
    origin = "local",
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

---@param comments LocalReviewComment[]
---@param comment LocalReviewComment
---@return boolean?, string?
function M.remove_comment(comments, comment)
  if M.is_remote(comment) then
    return nil, "Remote comments are read-only"
  end

  for i, c in pairs(comments) do
    if c.id == comment.id then
      table.remove(comments, i)
      return true, nil
    end
  end

  return false, "Comment not found"
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
