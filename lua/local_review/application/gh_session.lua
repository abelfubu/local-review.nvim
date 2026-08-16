local M = {}

local context = require("local_review.infrastructure.context")
local comment_store = require("local_review.domain.comment_store")

---@class GhSessionState
---@field comments LocalReviewComment[]
---@field pull_number integer
---@field branch string
---@field fetched_at string

---@type table<string, GhSessionState>
local state = {}

---Replace the in-memory session state for a scope.
---@param scope_root string
---@param comments LocalReviewComment[]
---@param pull_number integer
---@param branch string
function M.set(scope_root, comments, pull_number, branch)
  state[scope_root] = {
    comments = comments or {},
    pull_number = pull_number,
    branch = branch or "",
    fetched_at = tostring(os.date("!%Y-%m-%dT%H:%M:%SZ")),
  }
end

---@param scope_root string
---@return GhSessionState?
function M.get(scope_root)
  return state[scope_root]
end

---Drop the in-memory session state for a scope.
---@param scope_root string
function M.clear(scope_root)
  state[scope_root] = nil
end

---Return session remote comments matching the path, but only when the
---current git branch matches the branch recorded at pull time.
---@param scope_root string
---@param target_path string absolute and normalized
---@param kind "file"|"directory"
---@return LocalReviewComment[]
function M.comments_for_path(scope_root, target_path, kind)
  local session = state[scope_root]
  if not session then
    return {}
  end

  local current_branch = context.current_branch(scope_root)
  if not current_branch or current_branch ~= session.branch then
    return {}
  end

  return comment_store.matching_path({ { data = session } }, target_path, kind)
end

return M
