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
