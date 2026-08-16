---@diagnostic disable: undefined-global, undefined-field
require("busted.runner")()

package.path = table.concat({
  "./lua/?.lua",
  "./lua/?/init.lua",
  package.path,
}, ";")

describe("export", function()
  local local_comments
  local session_comments
  local removed_comments
  local remove_args
  local saved_scopes
  local stdout_lines
  local notifications

  before_each(function()
    local_comments = {}
    session_comments = {}
    removed_comments = {}
    remove_args = nil
    saved_scopes = {}
    stdout_lines = {}
    notifications = {}

    package.loaded["local_review.application.export"] = nil
    package.loaded["local_review.application.gh_session"] = nil
    package.loaded["local_review.infrastructure.storage"] = nil
    package.loaded["local_review.infrastructure.context"] = nil
    package.loaded["local_review"] = nil

    package.preload["local_review"] = function()
      return {
        get_opts = function()
          return {
            marker_text = "▎",
            marker_hl = "LocalReviewMarker",
            stale_marker_hl = "LocalReviewStaleMarker",
            gh_marker_hl = "LocalReviewGhMarker",
          }
        end,
      }
    end

    package.preload["local_review.application.gh_session"] = function()
      return {
        comments_for_path = function(_scope_root, _path, _kind)
          return session_comments
        end,
      }
    end

    package.preload["local_review.infrastructure.storage"] = function()
      return {
        comments_for_path = function(_scope_root, _path, _kind)
          return local_comments
        end,
        remove_comments_for_path = function(scope_root, path, kind)
          remove_args = { scope_root = scope_root, path = path, kind = kind }
          return removed_comments, nil
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
          if path:sub(1, 5) == "/repo" then
            return "/repo"
          end
          return path
        end,
        relative_path = function(root, absolute)
          return absolute:sub(#root + 2)
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
      api = {
        nvim_list_uis = function()
          return {}
        end,
        nvim_exec_autocmds = function() end,
      },
      fn = {
        setreg = function()
          return true
        end,
      },
    }

    ---@diagnostic disable-next-line: duplicate-set-field
    io.write = function(text)
      table.insert(stdout_lines, text)
    end
  end)

  after_each(function()
    package.preload["local_review"] = nil
    package.preload["local_review.application.gh_session"] = nil
    package.preload["local_review.infrastructure.storage"] = nil
    package.preload["local_review.infrastructure.context"] = nil
    package.loaded["local_review"] = nil
    package.loaded["local_review.application.gh_session"] = nil
    package.loaded["local_review.infrastructure.storage"] = nil
    package.loaded["local_review.infrastructure.context"] = nil
    package.loaded["local_review.application.export"] = nil
    _G.vim = nil
  end)

  local function local_comment(overrides)
    local comment = {
      id = "local-1",
      origin = "local",
      absolute_path = "/repo/lua/example.lua",
      relative_path = "lua/example.lua",
      body = "Please handle the nil case.",
      created_at = "2024-01-01T00:00:00Z",
      updated_at = "2024-01-01T00:00:00Z",
      anchor = { line_number = 20 },
      line_end = 20,
      source_kind = "buffer",
      source_meta = {},
      stale = false,
    }
    if overrides then
      for key, value in pairs(overrides) do
        comment[key] = value
      end
    end
    return comment
  end

  local function remote_comment(overrides)
    local comment = {
      id = "gh:comment-1",
      origin = "github",
      absolute_path = "/repo/lua/example.lua",
      relative_path = "lua/example.lua",
      body = "Please handle the nil case.",
      created_at = "2024-01-01T00:00:00Z",
      updated_at = "2024-01-01T00:00:00Z",
      anchor = { line_number = 20 },
      line_end = 20,
      source_kind = "github",
      source_meta = {},
      stale = false,
      remote = {
        repository = "owner/repo",
        pull_number = 123,
        thread_id = "thread-1",
        comment_id = "comment-1",
        author = "reviewer",
        url = "https://github.com/owner/repo/pull/123#discussion_r1",
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

  it("includes local and remote comments in export", function()
    local_comments = { local_comment({ body = "Local note." }) }
    session_comments = { remote_comment() }

    local export = require("local_review.application.export")
    local text, err, count = export.path_export_text("/repo")

    assert.is_string(text)
    ---@cast text string
    assert.is_nil(err)
    assert.are.equal(2, count)
    assert.is_not_nil(text:find("Local note.", 1, true), "local comment missing")
    assert.is_not_nil(text:find("github @reviewer", 1, true), "remote attribution missing")
    assert.is_not_nil(text:find("https://github.com/owner/repo/pull/123#discussion_r1", 1, true), "remote url missing")
  end)

  it("formats remote comments with attribution and url", function()
    session_comments = { remote_comment() }

    local export = require("local_review.application.export")
    local text = export.path_export_text("/repo")

    assert.is_string(text)
    ---@cast text string
    local expected = "1. lua/example.lua:20 [github @reviewer]"
    assert.is_not_nil(text:find(expected, 1, true), "expected location line not found: " .. text)
    assert.is_not_nil(
      text:find("   https://github.com/owner/repo/pull/123#discussion_r1", 1, true),
      "url line not found"
    )
  end)

  it("keeps local comments format unchanged", function()
    local_comments = { local_comment() }

    local export = require("local_review.application.export")
    local text = export.path_export_text("/repo")

    assert.is_string(text)
    ---@cast text string
    assert.is_not_nil(text:find("1. lua/example.lua:20", 1, true), "local location line not found")
    assert.is_nil(text:find("%[github"), "remote attribution should not appear")
  end)

  it("preserves remote comments when clearing after export", function()
    local_comments = { local_comment() }
    session_comments = { remote_comment() }
    removed_comments = { local_comments[1] }

    local export = require("local_review.application.export")
    export.open_export("/repo", { clear_after_export = true })

    assert.is_not_nil(remove_args)
    assert.are.equal("/repo", remove_args.scope_root)
    assert.are.equal("/repo", remove_args.path)
    assert.are.equal("directory", remove_args.kind)
    assert.are.equal(1, #removed_comments)
    assert.are.equal("local-1", removed_comments[1].id)
    assert.are.equal("local", removed_comments[1].origin)
  end)
end)
