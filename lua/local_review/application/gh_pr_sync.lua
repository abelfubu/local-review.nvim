local M = {}

---Fetch PR comments from GitHub and merge them into the local storage scope.
---The persisted state is only written when the fetch succeeds completely and
---at least one comment changed.
---@param scope_root string
---@param pr_info { number: integer }
---@param callback fun(ok: boolean, err: string?, stats: ReconcileRemoteStats?)
function M.sync(scope_root, pr_info, callback)
  local gh_pr_comments = require("local_review.application.gh_pr_comments")
  local storage = require("local_review.infrastructure.storage")
  local comment_store = require("local_review.domain.comment_store")

  gh_pr_comments.fetch(scope_root, pr_info, function(fetched, err)
    if err then
      callback(false, err, nil)
      return
    end

    if not fetched then
      callback(false, "Failed to fetch PR comments", nil)
      return
    end

    local repository = fetched.repository
    if not repository then
      callback(false, "Fetched comments are missing repository metadata", nil)
      return
    end

    local data = storage.load_scope(scope_root)
    local result = comment_store.reconcile_remote(data.comments or {}, fetched, {
      repository = repository,
      pull_number = pr_info.number,
    })

    if result.changed then
      data.comments = result.comments
      local ok, save_err = storage.save_scope(scope_root, data)
      if not ok then
        callback(false, save_err, nil)
        return
      end
    end

    callback(true, nil, result.stats)
  end)
end

return M
