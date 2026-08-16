---@diagnostic disable: undefined-global, undefined-field
require("busted.runner")()

package.path = table.concat({
  "./lua/?.lua",
  "./lua/?/init.lua",
  package.path,
}, ";")

describe("GitHub PR comment sync", function()
  local session_state
  local fetch_result
  local fetch_error
  local fetch_calls
  local current_branch

  before_each(function()
    session_state = {}
    fetch_result = {}
    fetch_error = nil
    fetch_calls = {}
    current_branch = "feature"

    package.loaded["local_review.application.gh_pr_sync"] = nil
    package.loaded["local_review.application.gh_pr_comments"] = nil
    package.loaded["local_review.application.gh_session"] = nil
    package.loaded["local_review.infrastructure.context"] = nil

    package.preload["local_review.application.gh_pr_comments"] = function()
      return {
        fetch = function(scope_root, pr_info, callback)
          fetch_calls[#fetch_calls + 1] = { scope_root = scope_root, pr_info = pr_info }
          callback(fetch_result, fetch_error)
        end,
      }
    end

    package.preload["local_review.infrastructure.context"] = function()
      return {
        current_branch = function(_)
          return current_branch
        end,
      }
    end

    package.preload["local_review.application.gh_session"] = function()
      return {
        set = function(scope_root, comments, reviews, pull_number, branch)
          session_state[scope_root] = {
            comments = comments,
            reviews = reviews or {},
            pull_number = pull_number,
            branch = branch,
          }
        end,
      }
    end
  end)

  after_each(function()
    package.preload["local_review.application.gh_pr_comments"] = nil
    package.preload["local_review.infrastructure.context"] = nil
    package.preload["local_review.application.gh_session"] = nil
    package.loaded["local_review.application.gh_pr_sync"] = nil
    package.loaded["local_review.application.gh_pr_comments"] = nil
    package.loaded["local_review.application.gh_session"] = nil
    package.loaded["local_review.infrastructure.context"] = nil
  end)

  local function remote_comment(overrides)
    local comment = {
      id = "gh:c1",
      origin = "github",
      absolute_path = "/repo/src/a.lua",
      relative_path = "src/a.lua",
      body = "reviewer note",
      created_at = "2024-01-01T00:00:00Z",
      updated_at = "2024-01-01T00:00:00Z",
      anchor = { line_number = 5, line_text = "line" },
      line_end = 5,
      source_kind = "github",
      source_meta = {},
      stale = false,
      remote = {
        repository = "owner/repo",
        pull_number = 42,
        thread_id = "t1",
        comment_id = "c1",
        review_id = "r1",
        author = "reviewer",
        url = "https://github.com/owner/repo/pull/42#discussion_r1",
        commit_id = "abc123",
        resolved = false,
        outdated = false,
      },
    }

    if overrides then
      for key, value in pairs(overrides) do
        if key == "remote" and type(value) == "table" then
          for rkey, rvalue in pairs(value) do
            comment.remote[rkey] = rvalue
          end
        else
          comment[key] = value
        end
      end
    end

    return comment
  end

  it("replaces the session set on complete success", function()
    fetch_result = { remote_comment(), repository = "owner/repo" }

    local ok, err, stats
    require("local_review.application.gh_pr_sync").sync("/repo", { number = 42 }, function(r_ok, r_err, r_stats)
      ok = r_ok
      err = r_err
      stats = r_stats
    end)

    assert.is_true(ok)
    assert.is_nil(err)
    assert.are.equal(1, stats.count)
    assert.are.equal(1, #session_state["/repo"].comments)
    assert.are.equal(42, session_state["/repo"].pull_number)
    assert.are.equal("feature", session_state["/repo"].branch)
  end)

  it("performs no replacement when the fetch fails", function()
    fetch_result = nil
    fetch_error = "network timeout"

    local ok, err, stats
    require("local_review.application.gh_pr_sync").sync("/repo", { number = 42 }, function(r_ok, r_err, r_stats)
      ok = r_ok
      err = r_err
      stats = r_stats
    end)

    assert.is_false(ok)
    assert.are.equal("network timeout", err)
    assert.is_nil(stats)
    assert.is_nil(session_state["/repo"])
  end)

  it("keeps the previous session set on a failed fetch", function()
    session_state["/repo"] = { comments = { remote_comment() }, pull_number = 42, branch = "feature" }
    package.preload["local_review.application.gh_session"] = function()
      return {
        set = function(scope_root, comments, reviews, pull_number, branch)
          session_state[scope_root] = {
            comments = comments,
            reviews = reviews or {},
            pull_number = pull_number,
            branch = branch,
          }
        end,
        get = function(scope_root)
          return session_state[scope_root]
        end,
      }
    end

    fetch_result = nil
    fetch_error = "network timeout"

    local ok, err, stats
    require("local_review.application.gh_pr_sync").sync("/repo", { number = 42 }, function(r_ok, r_err, r_stats)
      ok = r_ok
      err = r_err
      stats = r_stats
    end)

    assert.is_false(ok)
    assert.are.equal("network timeout", err)
    assert.is_nil(stats)
    assert.are.equal(1, #session_state["/repo"].comments)
  end)

  it("warns when branch resolution fails", function()
    fetch_result = { remote_comment(), repository = "owner/repo" }
    current_branch = nil

    local warnings = {}
    _G.vim = {
      log = { levels = { WARN = 3 } },
      notify = function(message, level)
        if level == _G.vim.log.levels.WARN then
          warnings[#warnings + 1] = message
        end
      end,
    }

    local ok
    require("local_review.application.gh_pr_sync").sync("/repo", { number = 42 }, function(r_ok)
      ok = r_ok
    end)

    assert.is_true(ok)
    assert.are.equal("", session_state["/repo"].branch)
    assert.are.equal(1, #warnings)
    assert.is_not_nil(warnings[1]:find("branch", 1, true))
  end)

  it("replaces the session set even when nothing changed", function()
    session_state["/repo"] = { comments = { remote_comment() }, pull_number = 42, branch = "feature" }
    fetch_result = { remote_comment(), repository = "owner/repo" }

    local ok, err, stats
    require("local_review.application.gh_pr_sync").sync("/repo", { number = 42 }, function(r_ok, r_err, r_stats)
      ok = r_ok
      err = r_err
      stats = r_stats
    end)

    assert.is_true(ok)
    assert.is_nil(err)
    assert.are.equal(1, stats.count)
    assert.are.equal(1, #session_state["/repo"].comments)
  end)

  it("stores review bodies in the session and returns them in stats", function()
    fetch_result = {
      remote_comment(),
      repository = "owner/repo",
      reviews_included = true,
      reviews = {
        {
          id = "review-1",
          author = "reviewer",
          state = "COMMENTED",
          body = "Review body",
          url = "https://example.com",
          submitted_at = "2024-01-01T00:00:00Z",
        },
      },
    }

    local ok, err, stats
    require("local_review.application.gh_pr_sync").sync("/repo", { number = 42 }, function(r_ok, r_err, r_stats)
      ok = r_ok
      err = r_err
      stats = r_stats
    end)

    assert.is_true(ok)
    assert.is_nil(err)
    assert.are.equal(1, stats.count)
    assert.is_true(stats.reviews_included)
    assert.is_not_nil(stats.reviews)
    assert.are.equal(1, #stats.reviews)
    assert.are.equal("Review body", stats.reviews[1].body)
    assert.is_not_nil(session_state["/repo"].reviews)
    assert.are.equal(1, #session_state["/repo"].reviews)
  end)

  it("reports reviews_included false when the fetch omits the reviews field", function()
    fetch_result = { remote_comment(), repository = "owner/repo" }

    local ok, err, stats
    require("local_review.application.gh_pr_sync").sync("/repo", { number = 42 }, function(r_ok, r_err, r_stats)
      ok = r_ok
      err = r_err
      stats = r_stats
    end)

    assert.is_true(ok)
    assert.is_nil(err)
    assert.is_not_nil(stats)
    assert.are.equal(0, #stats.reviews)
    assert.is_false(stats.reviews_included)
  end)
end)

describe("GitHub PR comment pull", function()
  local notifications
  local pr_info
  local scope_root_result
  local scope_root_error
  local comment_context_error
  local sync_calls
  local clear_calls
  local reviews_event_calls

  before_each(function()
    notifications = {}
    pr_info = { number = 42 }
    scope_root_result = "/repo"
    scope_root_error = nil
    comment_context_error = "Current buffer has no file path."
    sync_calls = {}
    clear_calls = {}
    reviews_event_calls = {}

    package.loaded["local_review.application.gh_pr_sync"] = nil
    package.loaded["local_review.infrastructure.context"] = nil
    package.loaded["local_review.application.gh_pr"] = nil

    _G.vim = {
      log = { levels = { ERROR = 1, INFO = 2, WARN = 3 } },
      notify = function(message, level)
        notifications[#notifications + 1] = { message = message, level = level }
      end,
      fn = {
        getcwd = function()
          return "/repo"
        end,
      },
      api = {
        nvim_exec_autocmds = function(name, opts)
          if name == "User" and opts and opts.data and opts.data.reviews then
            reviews_event_calls[#reviews_event_calls + 1] = opts.data
          end
        end,
      },
    }

    ---@diagnostic disable-next-line: duplicate-set-field
    package.preload["local_review.infrastructure.context"] = function()
      return {
        comment_context = function()
          return nil, comment_context_error
        end,
        scope_root = function(path)
          if path == "/repo" then
            return scope_root_result, scope_root_error
          end
          return nil, "unexpected path"
        end,
      }
    end

    ---@diagnostic disable-next-line: duplicate-set-field
    package.preload["local_review.application.gh_pr"] = function()
      return {
        get_pr_info = function(_scope_root)
          return pr_info, nil
        end,
      }
    end
  end)

  after_each(function()
    _G.vim = nil
    package.preload["local_review.infrastructure.context"] = nil
    package.preload["local_review.application.gh_pr"] = nil
    package.loaded["local_review.infrastructure.context"] = nil
    package.loaded["local_review.application.gh_pr"] = nil
    package.loaded["local_review.application.gh_pr_sync"] = nil
  end)

  it("falls back to cwd scope when buffer has no filepath", function()
    local module = require("local_review.application.gh_pr_sync")
    ---@diagnostic disable-next-line: duplicate-set-field
    module.sync = function(scope_root, info, callback)
      sync_calls[#sync_calls + 1] = { scope_root = scope_root, info = info }
      callback(true, nil, { count = 0 })
    end

    module.pull()

    assert.are.equal(1, #sync_calls)
    assert.are.equal("/repo", sync_calls[1].scope_root)
    assert.are.equal(pr_info, sync_calls[1].info)
    assert.are.equal("No PR comments found — cleared previous session.", notifications[#notifications].message)
    assert.are.equal(vim.log.levels.INFO, notifications[#notifications].level)
  end)

  it("errors when cwd scope also cannot be determined", function()
    scope_root_result = nil
    scope_root_error = "Not inside a git repository."

    local module = require("local_review.application.gh_pr_sync")
    ---@diagnostic disable-next-line: duplicate-set-field
    module.sync = function(_, _, _callback)
      sync_calls[#sync_calls + 1] = {}
    end

    module.pull()

    assert.are.equal(0, #sync_calls)
    assert.are.equal("Not inside a git repository.", notifications[#notifications].message)
    assert.are.equal(vim.log.levels.WARN, notifications[#notifications].level)
  end)

  it("notifies the number of pulled comments", function()
    local module = require("local_review.application.gh_pr_sync")
    ---@diagnostic disable-next-line: duplicate-set-field
    module.sync = function(scope_root, info, callback)
      sync_calls[#sync_calls + 1] = { scope_root = scope_root, info = info }
      callback(true, nil, { count = 3 })
    end

    module.pull()

    assert.are.equal(1, #sync_calls)
    assert.are.equal("Pulled 3 PR comments.", notifications[#notifications].message)
    assert.are.equal(vim.log.levels.INFO, notifications[#notifications].level)
  end)

  it("notifies comments and review summaries together", function()
    local module = require("local_review.application.gh_pr_sync")
    ---@diagnostic disable-next-line: duplicate-set-field
    module.sync = function(scope_root, info, callback)
      sync_calls[#sync_calls + 1] = { scope_root = scope_root, info = info }
      callback(true, nil, {
        count = 2,
        reviews = {
          {
            id = "review-1",
            author = "reviewer",
            state = "COMMENTED",
            body = "Review body",
            url = "https://example.com",
            submitted_at = "2024-01-01T00:00:00Z",
          },
        },
        reviews_included = true,
      })
    end

    module.pull()

    assert.are.equal(1, #sync_calls)
    assert.are.equal("Pulled 2 PR comments · 1 review summary.", notifications[#notifications].message)
    assert.are.equal(vim.log.levels.INFO, notifications[#notifications].level)
    assert.are.equal(1, #reviews_event_calls)
    assert.are.equal(1, #reviews_event_calls[1].reviews)
    assert.are.equal("/repo", reviews_event_calls[1].scope_root)
  end)

  it("notifies no review summaries when reviews field is empty", function()
    local module = require("local_review.application.gh_pr_sync")
    ---@diagnostic disable-next-line: duplicate-set-field
    module.sync = function(scope_root, info, callback)
      sync_calls[#sync_calls + 1] = { scope_root = scope_root, info = info }
      callback(true, nil, { count = 1, reviews = {}, reviews_included = true })
    end

    module.pull()

    assert.are.equal(1, #sync_calls)
    assert.are.equal("Pulled 1 PR comments · no review summaries.", notifications[#notifications].message)
    assert.are.equal(vim.log.levels.INFO, notifications[#notifications].level)
    assert.are.equal(0, #reviews_event_calls)
  end)

  it("notifies no review summaries when reviews are absent", function()
    local module = require("local_review.application.gh_pr_sync")
    ---@diagnostic disable-next-line: duplicate-set-field
    module.sync = function(scope_root, info, callback)
      sync_calls[#sync_calls + 1] = { scope_root = scope_root, info = info }
      callback(true, nil, { count = 1, reviews = {} })
    end

    module.pull()

    assert.are.equal(1, #sync_calls)
    assert.are.equal("Pulled 1 PR comments.", notifications[#notifications].message)
    assert.are.equal(vim.log.levels.INFO, notifications[#notifications].level)
    assert.are.equal(0, #reviews_event_calls)
  end)
end)

describe("GitHub PR comment clear", function()
  local notifications
  local cleared_scope
  local autocmd_calls
  local comment_context_error
  local scope_root_result
  local scope_root_error

  before_each(function()
    notifications = {}
    cleared_scope = nil
    autocmd_calls = {}
    comment_context_error = "Current buffer has no file path."
    scope_root_result = "/repo"
    scope_root_error = nil

    package.loaded["local_review.application.gh_pr_sync"] = nil
    package.loaded["local_review.application.gh_session"] = nil
    package.loaded["local_review.infrastructure.context"] = nil

    _G.vim = {
      log = { levels = { ERROR = 1, INFO = 2, WARN = 3 } },
      notify = function(message, level)
        notifications[#notifications + 1] = { message = message, level = level }
      end,
      fn = {
        getcwd = function()
          return "/repo"
        end,
      },
      api = {
        nvim_exec_autocmds = function(_, opts)
          if opts and opts.data then
            autocmd_calls[#autocmd_calls + 1] = opts.data
          end
        end,
      },
    }

    ---@diagnostic disable-next-line: duplicate-set-field
    package.preload["local_review.infrastructure.context"] = function()
      return {
        comment_context = function()
          return nil, comment_context_error
        end,
        scope_root = function(path)
          if path == "/repo" then
            return scope_root_result, scope_root_error
          end
          return nil, "unexpected path"
        end,
      }
    end

    ---@diagnostic disable-next-line: duplicate-set-field
    package.preload["local_review.application.gh_session"] = function()
      return {
        clear = function(scope_root)
          cleared_scope = scope_root
        end,
      }
    end
  end)

  after_each(function()
    _G.vim = nil
    package.preload["local_review.infrastructure.context"] = nil
    package.preload["local_review.application.gh_session"] = nil
    package.loaded["local_review.infrastructure.context"] = nil
    package.loaded["local_review.application.gh_session"] = nil
    package.loaded["local_review.application.gh_pr_sync"] = nil
  end)

  it("clears the session for the current scope and fires an event", function()
    local module = require("local_review.application.gh_pr_sync")
    module.clear_current()

    assert.are.equal("/repo", cleared_scope)
    assert.are.equal(1, #autocmd_calls)
    assert.are.equal("/repo", autocmd_calls[1].scope_root)
    assert.are.equal("Cleared pulled PR comments for current scope.", notifications[#notifications].message)
    assert.are.equal(vim.log.levels.INFO, notifications[#notifications].level)
  end)

  it("warns when the scope cannot be determined", function()
    scope_root_result = nil
    scope_root_error = "Not inside a git repository."

    local module = require("local_review.application.gh_pr_sync")
    module.clear_current()

    assert.is_nil(cleared_scope)
    assert.are.equal("Not inside a git repository.", notifications[#notifications].message)
    assert.are.equal(vim.log.levels.WARN, notifications[#notifications].level)
  end)
end)
