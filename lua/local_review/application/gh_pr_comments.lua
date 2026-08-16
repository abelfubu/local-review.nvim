local positioning = require("local_review.domain.positioning")
local gh = require("local_review.infrastructure.gh")

local M = {}

M.QUERY = [[
query($owner: String!, $repo: String!, $pr: Int!, $threadsCursor: String, $reviewsCursor: String) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $pr) {
      reviewThreads(first: 100, after: $threadsCursor) {
        pageInfo {
          hasNextPage
          endCursor
        }
        nodes {
          id
          isResolved
          isOutdated
          path
          subjectType
          line
          originalLine
          startLine
          originalStartLine
          diffSide
          startDiffSide
          comments(first: 100) {
            pageInfo {
              hasNextPage
              endCursor
            }
            nodes {
              id
              body
              author {
                login
              }
              url
              createdAt
              updatedAt
              commit {
                oid
              }
              pullRequestReview {
                id
              }
              diffHunk
            }
          }
        }
      }
      reviews(first: 100, after: $reviewsCursor) {
        pageInfo {
          hasNextPage
          endCursor
        }
        nodes {
          id
          body
          state
          url
          author {
            login
          }
          submittedAt
        }
      }
    }
  }
}
]]

local COMMENTS_QUERY = [[
query($id: ID!, $cursor: String) {
  node(id: $id) {
    ... on PullRequestReviewThread {
      comments(first: 100, after: $cursor) {
        pageInfo {
          hasNextPage
          endCursor
        }
        nodes {
          id
          body
          author {
            login
          }
          url
          createdAt
          updatedAt
          commit {
            oid
          }
          pullRequestReview {
            id
          }
          diffHunk
        }
      }
    }
  }
}
]]

local MAX_RETRIES = 3
local RETRY_DELAY = 1.0

M._sleep = function(seconds)
  -- `Retry-After` / `x-ratelimit-reset` headers are not exposed by the
  -- current `gh.run` helper (which does not pass `-i`). Use a simple
  -- exponential backoff until we need header-aware retry logic.
  vim.uv.sleep(math.floor(seconds * 1000))
end

local function is_transient_error(stderr)
  stderr = stderr or ""
  return stderr:match("HTTP 403") or stderr:match("HTTP 429") or stderr:lower():match("rate limit")
end

local function run_with_retry(command, cwd)
  local attempts = 0
  while true do
    local out, err = gh.run(command, cwd)
    if out then
      return out
    end

    if not is_transient_error(err) or attempts >= MAX_RETRIES then
      return nil, err
    end

    attempts = attempts + 1
    M._sleep(RETRY_DELAY * (2 ^ (attempts - 1)))
  end
end

local function run_query(scope_root, query, variables)
  local command = { "gh", "api", "graphql", "-f", "query=" .. query }

  for key, value in pairs(variables) do
    if value ~= nil then
      local flag = (key == "pr") and "-F" or "-f"
      table.insert(command, flag)
      table.insert(command, key .. "=" .. tostring(value))
    end
  end

  return run_with_retry(command, scope_root)
end

local function parse_diff_hunk(hunk)
  local left_lines = {}
  local right_lines = {}
  local left_line
  local right_line
  local in_hunk = false

  for raw_line in (hunk or ""):gmatch("[^\r\n]+") do
    if raw_line:match("^@@") then
      local left_start, right_start = raw_line:match("^@@ %-(%d+),?%d* %+(%d+),?%d* @@")
      if left_start and right_start then
        left_line = tonumber(left_start)
        right_line = tonumber(right_start)
        in_hunk = true
      end
    elseif in_hunk then
      local marker = raw_line:sub(1, 1)
      local text = raw_line:sub(2)

      if marker == "-" then
        left_lines[left_line] = text
        left_line = left_line + 1
      elseif marker == "+" then
        right_lines[right_line] = text
        right_line = right_line + 1
      elseif marker == " " then
        left_lines[left_line] = text
        right_lines[right_line] = text
        left_line = left_line + 1
        right_line = right_line + 1
      end
    end
  end

  return left_lines, right_lines
end

local function resolve_line(diff_side, line, original_line)
  if diff_side == "RIGHT" then
    return line
  elseif diff_side == "LEFT" then
    return original_line
  end
  return nil
end

local function make_anchor(hunk, diff_side, line_number)
  local left_lines, right_lines = parse_diff_hunk(hunk)
  local lines = diff_side == "RIGHT" and right_lines or left_lines
  return positioning.capture(lines, line_number)
end

---@param node table raw reviewThread node
---@return string? err
function M.validate(node)
  if type(node) ~= "table" then
    return "thread node must be a table"
  end

  if not node.id or node.id == "" then
    return "thread missing id"
  end

  if not node.path or node.path == "" then
    return "thread missing path"
  end

  if not node.diffSide then
    return "thread missing diffSide"
  end

  if type(node.comments) ~= "table" or type(node.comments.nodes) ~= "table" then
    return "thread missing comments"
  end

  return nil
end

---@param thread table raw reviewThread node
---@param ctx { repository: string, pull_number: integer, scope_root: string }
---@return LocalReviewComment[] comments, string? skip_reason
function M.normalize(thread, ctx)
  local result = {}

  if thread.subjectType ~= "LINE" then
    return result, "non-LINE subjectType"
  end

  local end_side = thread.diffSide
  local end_line = resolve_line(end_side, thread.line, thread.originalLine)
  if not end_line then
    return result, "unresolvable line"
  end

  local start_side = thread.startDiffSide or end_side
  local start_line = resolve_line(start_side, thread.startLine, thread.originalStartLine)

  if start_line and end_line < start_line then
    start_line, end_line = end_line, start_line
    start_side, end_side = end_side, start_side
  end

  local anchor_side = start_side or end_side
  local anchor_line = start_line or end_line
  local is_range = start_line and start_line ~= end_line

  for _, comment in ipairs(thread.comments.nodes or {}) do
    local hunk = comment.diffHunk
    local anchor = make_anchor(hunk, anchor_side, anchor_line)

    local comment_result = {
      id = "gh:" .. comment.id,
      absolute_path = ctx.scope_root .. "/" .. thread.path,
      relative_path = thread.path,
      origin = "github",
      body = comment.body or "",
      created_at = comment.createdAt or "",
      updated_at = comment.updatedAt or comment.createdAt or "",
      anchor = anchor,
      anchor_end = nil,
      line_end = nil,
      source_kind = "github",
      source_meta = {},
      -- Required shape field, not a staleness decision (stale is derived by local anchoring only).
      stale = false,
      remote = {
        repository = ctx.repository,
        pull_number = ctx.pull_number,
        thread_id = thread.id,
        comment_id = comment.id,
        review_id = comment.pullRequestReview and comment.pullRequestReview.id,
        author = comment.author and comment.author.login,
        url = comment.url,
        commit_id = comment.commit and comment.commit.oid,
        resolved = thread.isResolved,
        outdated = thread.isOutdated,
      },
    }

    if is_range then
      comment_result.anchor_end = make_anchor(hunk, end_side, end_line)
      comment_result.line_end = end_line
    end

    table.insert(result, comment_result)
  end

  return result, nil
end

local function fetch_comments_page(scope_root, thread_id, cursor)
  local out, err = run_query(scope_root, COMMENTS_QUERY, { id = thread_id, cursor = cursor })
  if not out then
    return nil, err
  end

  local ok, decoded = pcall(vim.json.decode, out)
  if not ok then
    return nil, "Failed to parse review comments page"
  end

  local thread = decoded.data and decoded.data.node
  if not thread or not thread.comments then
    return nil, "Invalid review comments page response"
  end

  return thread.comments
end

local function fetch_all_comments(scope_root, thread)
  local nodes = {}

  for _, node in ipairs(thread.comments.nodes or {}) do
    table.insert(nodes, node)
  end

  local prev_cursor
  while thread.comments.pageInfo and thread.comments.pageInfo.hasNextPage do
    local cursor = thread.comments.pageInfo.endCursor
    if cursor == prev_cursor then
      return nil, "Pagination cursor did not advance for thread comments"
    end
    prev_cursor = cursor

    local page, page_err = fetch_comments_page(scope_root, thread.id, cursor)
    if not page then
      return nil, page_err
    end

    for _, node in ipairs(page.nodes or {}) do
      table.insert(nodes, node)
    end

    thread.comments.pageInfo = page.pageInfo
  end

  return nodes
end

local function fetch_snapshot(
  scope_root,
  owner,
  repo,
  pr,
  threads_cursor,
  reviews_cursor,
  threads,
  reviews,
  reviews_included,
  threads_done,
  reviews_done
)
  threads = threads or {}
  reviews = reviews or {}
  reviews_included = reviews_included or false
  threads_done = threads_done or false
  reviews_done = reviews_done or false

  local out, err = run_query(scope_root, M.QUERY, {
    owner = owner,
    repo = repo,
    pr = pr,
    threadsCursor = threads_cursor,
    reviewsCursor = reviews_cursor,
  })
  if not out then
    return nil, nil, false, err
  end

  local ok, decoded = pcall(vim.json.decode, out)
  if not ok then
    return nil, nil, false, "Failed to parse review snapshot response"
  end

  local pull_request = decoded.data and decoded.data.repository and decoded.data.repository.pullRequest
  if not pull_request then
    return nil, nil, false, "Invalid review snapshot response"
  end

  local review_threads = pull_request.reviewThreads
  if not review_threads then
    return nil, nil, false, "Invalid review snapshot response"
  end

  if not threads_done then
    for _, node in ipairs(review_threads.nodes or {}) do
      table.insert(threads, node)
    end
  end

  local reviews_connection = pull_request.reviews
  if reviews_connection ~= nil then
    reviews_included = true
    if not reviews_done then
      for _, node in ipairs(reviews_connection.nodes or {}) do
        table.insert(reviews, node)
      end
    end
  else
    reviews_done = true
  end

  local threads_page_info = review_threads.pageInfo or {}
  local reviews_page_info = reviews_connection and reviews_connection.pageInfo or {}

  local has_threads_next = threads_page_info.hasNextPage
  local has_reviews_next = reviews_page_info.hasNextPage

  if has_threads_next then
    local next_threads_cursor = threads_page_info.endCursor
    if next_threads_cursor == threads_cursor then
      return nil, nil, false, "Pagination cursor did not advance for review threads"
    end
    threads_cursor = next_threads_cursor
  else
    threads_done = true
  end

  if has_reviews_next then
    local next_reviews_cursor = reviews_page_info.endCursor
    if next_reviews_cursor == reviews_cursor then
      return nil, nil, false, "Pagination cursor did not advance for reviews"
    end
    reviews_cursor = next_reviews_cursor
  else
    reviews_done = true
  end

  if has_threads_next or has_reviews_next then
    return fetch_snapshot(
      scope_root,
      owner,
      repo,
      pr,
      threads_cursor,
      reviews_cursor,
      threads,
      reviews,
      reviews_included,
      threads_done,
      reviews_done
    )
  end

  return threads, reviews, reviews_included
end

---@class ReviewBody
---@field id string
---@field author string?
---@field state string
---@field body string
---@field url string
---@field submitted_at string?

---@class FetchedRemoteComments
---@field repository string
---@field skipped integer?
---@field reviews ReviewBody[]
---@field reviews_included boolean
---@field [integer] LocalReviewComment

---@param scope_root string
---@param pr_info { number: integer }
---@param callback fun(fetched: FetchedRemoteComments?, err: string?)
function M.fetch(scope_root, pr_info, callback)
  local repo_slug, slug_err = gh.get_repo_slug(scope_root)
  if not repo_slug then
    callback(nil, slug_err or "Failed to determine repository slug")
    return
  end

  local owner, repo = repo_slug:match("^([^/]+)/([^/]+)$")
  if not owner or not repo then
    callback(nil, "Invalid repository slug: " .. repo_slug)
    return
  end

  local threads, reviews, reviews_included, snapshot_err = fetch_snapshot(scope_root, owner, repo, pr_info.number)
  if not threads then
    callback(nil, snapshot_err)
    return
  end

  reviews = reviews or {}

  for _, thread in ipairs(threads) do
    if thread.comments and thread.comments.pageInfo and thread.comments.pageInfo.hasNextPage then
      local comments, comments_err = fetch_all_comments(scope_root, thread)
      if not comments then
        callback(nil, comments_err)
        return
      end
      thread.comments.nodes = comments
    end
  end

  local ctx = {
    repository = repo_slug,
    pull_number = pr_info.number,
    scope_root = scope_root,
  }

  local result = {}
  local skipped = 0
  local reason_counts = {}
  for _, thread in ipairs(threads) do
    if thread.isResolved ~= true then
      local validation_err = M.validate(thread)
      if validation_err then
        callback(nil, validation_err)
        return
      end

      local comments, skip_reason = M.normalize(thread, ctx)
      if skip_reason then
        skipped = skipped + 1
        reason_counts[skip_reason] = (reason_counts[skip_reason] or 0) + 1
      else
        for _, comment in ipairs(comments) do
          table.insert(result, comment)
        end
      end
    end
  end

  if skipped > 0 then
    local reasons = {}
    for reason, count in pairs(reason_counts) do
      table.insert(reasons, string.format("%d %s", count, reason))
    end
    vim.notify(
      string.format("Skipped %d PR review thread(s): %s", skipped, table.concat(reasons, ", ")),
      vim.log.levels.WARN
    )
  end

  local review_bodies = {}
  for _, review in ipairs(reviews) do
    if review.body and review.body:match("%S") and review.state ~= "PENDING" then
      table.insert(review_bodies, {
        id = review.id,
        author = review.author and review.author.login,
        state = review.state,
        body = review.body,
        url = review.url,
        submitted_at = review.submittedAt,
      })
    end
  end

  table.sort(review_bodies, function(a, b)
    return (a.submitted_at or "") > (b.submitted_at or "")
  end)

  result.repository = repo_slug
  result.skipped = skipped
  result.reviews = review_bodies
  result.reviews_included = reviews_included
  callback(result, nil)
end

return M
