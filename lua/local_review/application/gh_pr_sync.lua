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

    if fetched.skipped and fetched.skipped > 0 then
      result.stats.skipped = fetched.skipped
    end

    callback(true, nil, result.stats)
  end)
end

---Pull PR comments for the current context and notify the user.
function M.pull()
  local context = require("local_review.infrastructure.context")
  local gh_pr = require("local_review.application.gh_pr")

  local ctx, ctx_err = context.comment_context()
  if not ctx then
    -- Pulling only needs a scope_root (storage + gh cwd), not a buffer file.
    -- Fall back to the current working directory when the buffer is unnamed.
    if ctx_err == "Current buffer has no file path." then
      local scope_root, scope_err = context.scope_root(vim.fn.getcwd())
      if not scope_root then
        vim.notify(scope_err or "Failed to determine the review scope.", vim.log.levels.WARN)
        return
      end
      ctx = { scope_root = scope_root }
    else
      vim.notify(ctx_err or "Failed to determine the review scope.", vim.log.levels.WARN)
      return
    end
  end

  local pr_info, pr_err = gh_pr.get_pr_info(ctx.scope_root)
  if not pr_info then
    vim.notify(pr_err or "No PR found for current branch.", vim.log.levels.ERROR)
    return
  end

  M.sync(ctx.scope_root, pr_info, function(ok, err, stats)
    if not ok then
      vim.notify("Failed to pull PR comments:\n" .. (err or "Unknown error"), vim.log.levels.ERROR)
      return
    end

    if
      stats
      and (stats.inserted > 0 or stats.updated > 0 or stats.resolved > 0 or (stats.skipped and stats.skipped > 0))
    then
      local message = string.format(
        "Pulled PR comments: %d new, %d updated, %d resolved",
        stats.inserted,
        stats.updated,
        stats.resolved
      )
      if stats.skipped and stats.skipped > 0 then
        message = message .. string.format(", %d skipped", stats.skipped)
      end
      vim.notify(message, vim.log.levels.INFO)
      vim.api.nvim_exec_autocmds("User", {
        pattern = "LocalReviewChanged",
        data = { scope_root = ctx.scope_root },
      })
    else
      vim.notify("No new PR comments.", vim.log.levels.INFO)
    end
  end)
end

return M
