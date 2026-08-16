---@diagnostic disable: undefined-global, undefined-field
require("busted.runner")()

package.path = table.concat({
  "./lua/?.lua",
  "./lua/?/init.lua",
  package.path,
}, ";")

describe("GitHub PR comment sync", function()
  local storage_state
  local save_calls
  local fetch_result
  local fetch_error
  local fetch_calls

  before_each(function()
    storage_state = { comments = {} }
    save_calls = {}
    fetch_result = {}
    fetch_error = nil
    fetch_calls = {}

    package.loaded["local_review.application.gh_pr_sync"] = nil
    package.loaded["local_review.application.gh_pr_comments"] = nil
    package.loaded["local_review.infrastructure.storage"] = nil
    package.loaded["local_review.domain.comment_store"] = nil

    package.preload["local_review.application.gh_pr_comments"] = function()
      return {
        fetch = function(scope_root, pr_info, callback)
          fetch_calls[#fetch_calls + 1] = { scope_root = scope_root, pr_info = pr_info }
          callback(fetch_result, fetch_error)
        end,
      }
    end

    ---@diagnostic disable-next-line: duplicate-set-field
    package.preload["local_review.infrastructure.storage"] = function()
      return {
        load_scope = function(_)
          return { comments = storage_state.comments }
        end,
        save_scope = function(_, data)
          save_calls[#save_calls + 1] = data
          storage_state.comments = data.comments
          return true
        end,
      }
    end
  end)

  after_each(function()
    package.preload["local_review.application.gh_pr_comments"] = nil
    package.preload["local_review.infrastructure.storage"] = nil
    package.loaded["local_review.application.gh_pr_sync"] = nil
    package.loaded["local_review.application.gh_pr_comments"] = nil
    package.loaded["local_review.infrastructure.storage"] = nil
    package.loaded["local_review.domain.comment_store"] = nil
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

  it("writes the reconciled scope on complete success", function()
    fetch_result = { remote_comment(), repository = "owner/repo" }

    local ok, err, stats
    require("local_review.application.gh_pr_sync").sync("/repo", { number = 42 }, function(r_ok, r_err, r_stats)
      ok = r_ok
      err = r_err
      stats = r_stats
    end)

    assert.is_true(ok)
    assert.is_nil(err)
    assert.are.equal(1, stats.inserted)
    assert.are.equal(0, stats.updated)
    assert.are.equal(0, stats.resolved)
    assert.are.equal(1, #save_calls)
    assert.are.equal(1, #storage_state.comments)
  end)

  it("performs zero writes when the fetch fails", function()
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
    assert.are.equal(0, #save_calls)
  end)

  it("skips save when nothing changed", function()
    storage_state.comments = { remote_comment() }
    fetch_result = { remote_comment(), repository = "owner/repo" }

    local ok, err, stats
    require("local_review.application.gh_pr_sync").sync("/repo", { number = 42 }, function(r_ok, r_err, r_stats)
      ok = r_ok
      err = r_err
      stats = r_stats
    end)

    assert.is_true(ok)
    assert.is_nil(err)
    assert.are.equal(0, stats.inserted)
    assert.are.equal(0, stats.updated)
    assert.are.equal(0, stats.resolved)
    assert.are.equal(0, #save_calls)
  end)
end)

describe("GitHub PR comment pull", function()
  local notifications
  local pr_info
  local scope_root_result
  local scope_root_error
  local comment_context_error
  local sync_calls

  before_each(function()
    notifications = {}
    pr_info = { number = 42 }
    scope_root_result = "/repo"
    scope_root_error = nil
    comment_context_error = "Current buffer has no file path."
    sync_calls = {}

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
        nvim_exec_autocmds = function() end,
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
    package.loaded["local_review.application.gh_pr_sync"] = nil
  end)

  it("falls back to cwd scope when buffer has no filepath", function()
    local module = require("local_review.application.gh_pr_sync")
    ---@diagnostic disable-next-line: duplicate-set-field
    module.sync = function(scope_root, info, callback)
      sync_calls[#sync_calls + 1] = { scope_root = scope_root, info = info }
      callback(true, nil, { inserted = 0, updated = 0, resolved = 0 })
    end

    module.pull()

    assert.are.equal(1, #sync_calls)
    assert.are.equal("/repo", sync_calls[1].scope_root)
    assert.are.equal(pr_info, sync_calls[1].info)
    assert.are.equal("No new PR comments.", notifications[#notifications].message)
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
end)
