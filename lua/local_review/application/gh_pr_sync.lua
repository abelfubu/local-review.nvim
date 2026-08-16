local M = {}

---Fetch PR comments from GitHub and replace the in-memory session set for
---the scope. Failed fetches leave any existing session state untouched.
---@param scope_root string
---@param pr_info { number: integer }
---@param callback fun(ok: boolean, err: string?, stats: { count: integer }?)
function M.sync(scope_root, pr_info, callback)
  local gh_pr_comments = require("local_review.application.gh_pr_comments")
  local gh_session = require("local_review.application.gh_session")
  local context = require("local_review.infrastructure.context")

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

    local branch = context.current_branch(scope_root) or ""
    gh_session.set(scope_root, fetched, pr_info.number, branch)

    callback(true, nil, { count = #fetched })
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

    if stats and stats.count and stats.count > 0 then
      vim.notify(string.format("Pulled %d PR comments.", stats.count), vim.log.levels.INFO)
    else
      vim.notify("No new PR comments.", vim.log.levels.INFO)
    end
    vim.api.nvim_exec_autocmds("User", {
      pattern = "LocalReviewChanged",
      data = { scope_root = ctx.scope_root },
    })
  end)
end

---Clear the in-memory session set for the current scope and notify the UI.
function M.clear_current()
  local context = require("local_review.infrastructure.context")
  local gh_session = require("local_review.application.gh_session")

  local ctx, ctx_err = context.comment_context()
  if not ctx then
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

  gh_session.clear(ctx.scope_root)
  vim.api.nvim_exec_autocmds("User", {
    pattern = "LocalReviewChanged",
    data = { scope_root = ctx.scope_root },
  })
  vim.notify("Cleared pulled PR comments for current scope.", vim.log.levels.INFO)
end

return M
