---@diagnostic disable: undefined-global, undefined-field
require("busted.runner")()

package.path = table.concat({
  "./lua/?.lua",
  "./lua/?/init.lua",
  package.path,
}, ";")

describe("GitHub PR reviews", function()
  local processes
  local encoded_payload
  local summary_input
  local path_comments
  local removed_ids
  local remove_ok
  local remove_err
  local review_choice
  local notifications
  local remote_pr_info

  before_each(function()
    processes = {}
    encoded_payload = nil
    removed_ids = nil
    remove_ok = true
    remove_err = nil
    notifications = {}
    remote_pr_info = { number = 42, headRefOid = "pr-head" }
    summary_input = nil
    review_choice = "Comment"
    path_comments = {
      {
        id = "comment-1",
        origin = "local",
        relative_path = "lua/example.lua",
        body = "Please rename this.",
        anchor = { line_number = 3 },
        stale = false,
      },
    }

    package.loaded["local_review.application.gh_pr"] = nil
    package.loaded["local_review.infrastructure.storage"] = nil
    package.loaded["local_review.infrastructure.context"] = nil
    ---@diagnostic disable-next-line: duplicate-set-field
    package.preload["local_review.infrastructure.storage"] = function()
      return {
        comments_for_path = function(_, _, _)
          return path_comments
        end,
        remove_comments_by_ids = function(_, ids)
          removed_ids = ids
          if remove_ok then
            return {}
          end
          return nil, remove_err
        end,
      }
    end
    package.preload["local_review.infrastructure.context"] = function()
      return {
        default_export_root = function()
          return "/repo"
        end,
        path_kind = function(path)
          if path:match("%.lua$") then
            return "file", path
          end
          return "directory", path
        end,
        scope_root = function(path)
          if path == "/repo/lua/example.lua" then
            return "/repo"
          end
          return path
        end,
      }
    end

    _G.vim = {
      log = { levels = { ERROR = 1, INFO = 2, WARN = 3 } },
      notify = function(message, level)
        notifications[#notifications + 1] = { message = message, level = level }
      end,
      trim = function(value)
        return value:match("^%s*(.-)%s*$")
      end,
      json = {
        decode = function()
          return remote_pr_info
        end,
        encode = function(payload)
          encoded_payload = payload
          return "{}"
        end,
      },
      ui = {
        select = function(_, _, callback)
          callback(review_choice)
        end,
        input = function(_, callback)
          callback(summary_input)
        end,
      },
      system = function(command, opts)
        processes[#processes + 1] = { command = command, cwd = opts and opts.cwd }
        local stdout = "ok"
        if command[1] == "git" then
          stdout = "local-head\n"
        elseif command[1] == "gh" and command[2] == "repo" then
          stdout = "owner/repo\n"
        elseif command[1] == "gh" and command[2] == "pr" and command[3] == "view" then
          stdout = command[5] == "number" and "42\n" or '{"number":42,"headRefOid":"pr-head"}'
        end
        return {
          wait = function()
            return { code = 0, stdout = stdout, stderr = "" }
          end,
        }
      end,
      fn = {
        tempname = function()
          return os.tmpname()
        end,
      },
    }
  end)

  after_each(function()
    package.preload["local_review.infrastructure.storage"] = nil
    package.preload["local_review.infrastructure.context"] = nil
    package.loaded["local_review.infrastructure.storage"] = nil
    package.loaded["local_review.infrastructure.context"] = nil
    package.loaded["local_review.application.gh_pr"] = nil
    _G.vim = nil
  end)

  it("does not submit or clear comments when the summary prompt is cancelled", function()
    require("local_review.application.gh_pr").create_review(nil, { clear_after_export = true })

    -- One command is used to discover the PR before prompting.
    assert.are.equal(1, #processes)
  end)

  it("excludes remote comments from the submitted review", function()
    table.insert(path_comments, {
      id = "remote-1",
      origin = "github",
      relative_path = "lua/example.lua",
      body = "Reviewer feedback.",
      anchor = { line_number = 10 },
      stale = false,
    })
    summary_input = "Review summary"

    require("local_review.application.gh_pr").create_review(nil, { clear_after_export = true })

    assert.are.equal(1, #encoded_payload.comments)
    assert.are.equal("Please rename this.", encoded_payload.comments[1].body)
    assert.same({ "comment-1" }, removed_ids)
  end)

  it("submits an approve review without comments", function()
    path_comments = {}
    review_choice = "Approve"
    summary_input = ""

    require("local_review.application.gh_pr").create_review(nil, { clear_after_export = true })

    assert.are.equal("APPROVE", encoded_payload.event)
    assert.are.equal(0, #encoded_payload.comments)
    assert.is_nil(removed_ids)
  end)

  it("submits the review against the remote PR head", function()
    summary_input = "Review summary"

    require("local_review.application.gh_pr").create_review(nil, { clear_after_export = false })

    assert.are.equal("pr-head", encoded_payload.commit_id)
  end)

  it("runs GitHub commands in the repository selected by path", function()
    summary_input = "Review summary"

    require("local_review.application.gh_pr").create_review("/repo/lua/example.lua", { clear_after_export = false })

    assert.is_true(#processes > 0)
    for _, process in ipairs(processes) do
      assert.are.equal("/repo", process.cwd)
    end
  end)

  it("does not submit stale comments", function()
    path_comments[1].stale = true
    summary_input = "Review summary"

    require("local_review.application.gh_pr").create_review(nil, { clear_after_export = true })

    assert.are.equal(0, #processes)
  end)

  it("clears only comments included in a successful submission", function()
    summary_input = "Review summary"

    require("local_review.application.gh_pr").create_review(nil, { clear_after_export = true })

    assert.same({ "comment-1" }, removed_ids)
  end)

  it("requires a summary for comment reviews", function()
    summary_input = ""

    require("local_review.application.gh_pr").create_review(nil, { clear_after_export = true })

    assert.are.equal(1, #processes)
    assert.is_nil(removed_ids)
  end)

  it("requires a summary when requesting changes", function()
    review_choice = "Request Changes"
    summary_input = ""

    require("local_review.application.gh_pr").create_review(nil, { clear_after_export = true })

    assert.are.equal(1, #processes)
    assert.is_nil(removed_ids)
  end)

  it("warns when submitted comments cannot be cleared locally", function()
    summary_input = "Review summary"
    remove_ok = nil
    remove_err = "disk full"

    require("local_review.application.gh_pr").create_review(nil, { clear_after_export = true })

    assert.are.equal("PR review submitted: COMMENT", notifications[#notifications - 1].message)
    assert.are.equal("Failed to clear submitted comments: disk full", notifications[#notifications].message)
    assert.are.equal(vim.log.levels.ERROR, notifications[#notifications].level)
  end)

  it("rejects PR metadata without a remote head SHA", function()
    summary_input = "Review summary"
    remote_pr_info.headRefOid = nil

    require("local_review.application.gh_pr").create_review(nil, { clear_after_export = true })

    assert.are.equal(1, #processes)
    assert.are.equal("Failed to create PR review:\nPR head commit is missing", notifications[#notifications].message)
    assert.is_nil(removed_ids)
  end)
end)
