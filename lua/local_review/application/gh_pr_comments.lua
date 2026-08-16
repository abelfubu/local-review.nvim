local positioning = require("local_review.domain.positioning")

local M = {}

M.QUERY = [[
query($owner: String!, $repo: String!, $pr: Int!, $threadsCursor: String) {
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
local RETRY_DELAY = 0.01

M._sleep = function(seconds)
  local start = os.clock()
  while os.clock() - start < seconds do
    -- busy-wait to avoid depending on vim.uv or a subprocess sleep
  end
end

local function is_transient_error(stderr)
  stderr = stderr or ""
  return stderr:match("HTTP 403") or stderr:match("HTTP 429") or stderr:lower():match("rate limit")
end

local function run(command, cwd)
  local result = vim.system(command, { cwd = cwd, text = true }):wait()

  if result.code ~= 0 then
    return nil, vim.trim(result.stderr or result.stdout or "")
  end

  return vim.trim(result.stdout or "")
end

local function run_with_retry(command, cwd)
  local attempts = 0
  while true do
    local out, err = run(command, cwd)
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

local function get_repo_slug(repo_root)
  return run({ "gh", "repo", "view", "--json", "owner,name", "-q", '.owner.login + "/" + .name' }, repo_root)
end

local function run_query(scope_root, query, variables)
  local command = { "gh", "api", "graphql", "-f", "query=" .. query }

  for key, value in pairs(variables) do
    if value ~= nil then
      table.insert(command, "-F")
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
---@return LocalReviewComment[]
function M.normalize(thread, ctx)
  local result = {}

  if thread.subjectType ~= "LINE" then
    return result
  end

  local end_side = thread.diffSide
  local end_line = resolve_line(end_side, thread.line, thread.originalLine)
  if not end_line then
    return result
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

  return result
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

  local cursor = thread.comments.pageInfo and thread.comments.pageInfo.endCursor
  while thread.comments.pageInfo and thread.comments.pageInfo.hasNextPage do
    local page, page_err = fetch_comments_page(scope_root, thread.id, cursor)
    if not page then
      return nil, page_err
    end

    for _, node in ipairs(page.nodes or {}) do
      table.insert(nodes, node)
    end

    thread.comments.pageInfo = page.pageInfo
    cursor = page.pageInfo and page.pageInfo.endCursor
  end

  return nodes
end

local function fetch_threads(scope_root, owner, repo, pr, cursor, threads)
  threads = threads or {}

  local out, err = run_query(scope_root, M.QUERY, {
    owner = owner,
    repo = repo,
    pr = pr,
    threadsCursor = cursor,
  })
  if not out then
    return nil, err
  end

  local ok, decoded = pcall(vim.json.decode, out)
  if not ok then
    return nil, "Failed to parse review threads response"
  end

  local review_threads = decoded.data
    and decoded.data.repository
    and decoded.data.repository.pullRequest
    and decoded.data.repository.pullRequest.reviewThreads
  if not review_threads then
    return nil, "Invalid review threads response"
  end

  for _, node in ipairs(review_threads.nodes or {}) do
    table.insert(threads, node)
  end

  if review_threads.pageInfo and review_threads.pageInfo.hasNextPage then
    return fetch_threads(scope_root, owner, repo, pr, review_threads.pageInfo.endCursor, threads)
  end

  return threads
end

---@class FetchedRemoteComments
---@field repository string
---@field [integer] LocalReviewComment

---@param scope_root string
---@param pr_info { number: integer }
---@param callback fun(fetched: FetchedRemoteComments?, err: string?)
function M.fetch(scope_root, pr_info, callback)
  local repo_slug, slug_err = get_repo_slug(scope_root)
  if not repo_slug then
    callback(nil, slug_err or "Failed to determine repository slug")
    return
  end

  local owner, repo = repo_slug:match("^([^/]+)/([^/]+)$")
  if not owner or not repo then
    callback(nil, "Invalid repository slug: " .. repo_slug)
    return
  end

  local threads, threads_err = fetch_threads(scope_root, owner, repo, pr_info.number)
  if not threads then
    callback(nil, threads_err)
    return
  end

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
  for _, thread in ipairs(threads) do
    if thread.isResolved ~= true then
      local validation_err = M.validate(thread)
      if validation_err then
        callback(nil, validation_err)
        return
      end

      for _, comment in ipairs(M.normalize(thread, ctx)) do
        table.insert(result, comment)
      end
    end
  end

  result.repository = repo_slug
  callback(result, nil)
end

return M
