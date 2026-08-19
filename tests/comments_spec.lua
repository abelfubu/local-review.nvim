---@diagnostic disable: undefined-global, undefined-field
require("busted.runner")()

package.path = table.concat({
  "./lua/?.lua",
  "./lua/?/init.lua",
  package.path,
}, ";")

describe("comments", function()
  local module
  local scope_data
  local session_comments
  local context_ctx
  local buffer_lines_value
  local cursor_line
  local autocmd_data
  local notifications
  local next_hrtime

  before_each(function()
    scope_data = { comments = {} }
    session_comments = {}
    context_ctx = {
      absolute_path = "/repo/src/a.lua",
      relative_path = "src/a.lua",
      scope_root = "/repo",
      bufnr = 1,
    }
    buffer_lines_value = { "line 1", "line 2", "line 3", "line 4", "line 5", "line 6" }
    cursor_line = 1
    autocmd_data = {}
    notifications = {}
    next_hrtime = 1

    package.loaded["local_review.application.comments"] = nil
    package.loaded["local_review.infrastructure.context"] = nil
    package.loaded["local_review.infrastructure.storage"] = nil
    package.loaded["local_review.application.gh_session"] = nil
    package.loaded["local_review.domain.positioning"] = nil
    package.loaded["local_review.domain.comment_store"] = nil

    _G.vim = {
      log = { levels = { ERROR = 1, INFO = 2, WARN = 3 } },
      notify = function(message, level)
        notifications[#notifications + 1] = { message = message, level = level }
      end,
      trim = function(value)
        return (value or ""):match("^%s*(.-)%s*$")
      end,
      fn = {
        sha256 = function(value)
          return "hash-" .. tostring(value)
        end,
        getcwd = function()
          return "/repo"
        end,
      },
      api = {
        nvim_buf_get_lines = function(bufnr, _, _, _)
          return buffer_lines_value
        end,
        nvim_win_get_cursor = function(_)
          return { cursor_line, 0 }
        end,
        nvim_buf_line_count = function(_)
          return #buffer_lines_value
        end,
        nvim_exec_autocmds = function(_, opts)
          if opts and opts.data then
            autocmd_data[#autocmd_data + 1] = opts.data
          end
        end,
      },
      bo = {
        [1] = { filetype = "lua" },
      },
      uv = {
        hrtime = function()
          next_hrtime = next_hrtime + 1
          return next_hrtime - 1
        end,
      },
      json = {
        encode = function(value)
          return require("dkjson").encode(value)
        end,
        decode = function(value)
          return require("dkjson").decode(value)
        end,
      },
    }

    ---@diagnostic disable-next-line: duplicate-set-field
    package.preload["local_review.infrastructure.context"] = function()
      return {
        comment_context = function(bufnr)
          return {
            absolute_path = context_ctx.absolute_path,
            relative_path = context_ctx.relative_path,
            scope_root = context_ctx.scope_root,
            bufnr = bufnr or 0,
          }
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
          return nil, "unexpected path"
        end,
        default_export_root = function()
          return "/repo"
        end,
        current_branch = function(_)
          return "feature"
        end,
        relative_path = function(root, absolute)
          return absolute:sub(#root + 2)
        end,
      }
    end

    ---Deep copy matching the real storage.load_scope contract: every call
    ---hands out detached tables, so writes must go through save_scope.
    local function deep_copy(value)
      if type(value) ~= "table" then
        return value
      end
      local copy = {}
      for k, v in pairs(value) do
        copy[deep_copy(k)] = deep_copy(v)
      end
      return copy
    end

    ---@diagnostic disable-next-line: duplicate-set-field
    package.preload["local_review.infrastructure.storage"] = function()
      return {
        load_scope = function(_)
          return deep_copy(scope_data)
        end,
        save_scope = function(scope_root, data)
          scope_data = data
          return true
        end,
        comments_for_path = function(_, target_path, kind)
          local matches = {}
          for _, comment in ipairs(scope_data.comments) do
            if kind == "file" and comment.absolute_path == target_path then
              table.insert(matches, deep_copy(comment))
            elseif kind == "directory" and comment.absolute_path:sub(1, #target_path + 1) == target_path .. "/" then
              table.insert(matches, comment)
            end
          end
          return matches
        end,
        remove_comments_for_path = function(_, target_path, kind)
          local matched = {}
          local kept = {}
          for _, comment in ipairs(scope_data.comments) do
            if kind == "file" and comment.absolute_path == target_path then
              table.insert(matched, comment)
            elseif kind == "directory" and comment.absolute_path:sub(1, #target_path + 1) == target_path .. "/" then
              table.insert(matched, comment)
            else
              table.insert(kept, comment)
            end
          end
          scope_data.comments = kept
          return matched, nil
        end,
      }
    end

    ---@diagnostic disable-next-line: duplicate-set-field
    package.preload["local_review.application.gh_session"] = function()
      return {
        comments_for_path = function(_, target_path, kind)
          local matches = {}
          for _, comment in ipairs(session_comments) do
            if kind == "file" and comment.absolute_path == target_path then
              table.insert(matches, comment)
            elseif kind == "directory" and comment.absolute_path:sub(1, #target_path + 1) == target_path .. "/" then
              table.insert(matches, comment)
            end
          end
          return matches
        end,
      }
    end

    module = require("local_review.application.comments")
  end)

  after_each(function()
    _G.vim = nil
    package.preload["local_review.infrastructure.context"] = nil
    package.preload["local_review.infrastructure.storage"] = nil
    package.preload["local_review.application.gh_session"] = nil
    package.loaded["local_review.application.comments"] = nil
    package.loaded["local_review.infrastructure.context"] = nil
    package.loaded["local_review.infrastructure.storage"] = nil
    package.loaded["local_review.application.gh_session"] = nil
  end)

  local function local_comment(overrides)
    overrides = overrides or {}
    local anchor = overrides.anchor
      or {
        line_number = 2,
        line_text = "line 2",
        normalized_line_text = "line 2",
        normalized_before_context = { "line 1" },
        normalized_after_context = { "line 3", "line 4", "line 5", "line 6" },
      }
    return {
      id = overrides.id or "local-1",
      origin = "local",
      absolute_path = overrides.absolute_path or "/repo/src/a.lua",
      relative_path = overrides.relative_path or "src/a.lua",
      body = overrides.body or "local note",
      created_at = "2024-01-01T00:00:00Z",
      updated_at = "2024-01-01T00:00:00Z",
      anchor = anchor,
      line_end = overrides.line_end or 2,
      source_kind = "buffer",
      source_meta = {},
      stale = overrides.stale == nil and false or overrides.stale,
    }
  end

  local function remote_comment(overrides)
    overrides = overrides or {}
    local anchor = overrides.anchor
      or {
        line_number = 5,
        line_text = "line 5",
        normalized_line_text = "line 5",
        normalized_before_context = { "line 1", "line 2", "line 3", "line 4" },
        normalized_after_context = { "line 6" },
      }
    return {
      id = overrides.id or "gh:c1",
      origin = "github",
      absolute_path = overrides.absolute_path or "/repo/src/a.lua",
      relative_path = overrides.relative_path or "src/a.lua",
      body = overrides.body or "remote note",
      created_at = "2024-01-01T00:00:00Z",
      updated_at = "2024-01-01T00:00:00Z",
      anchor = anchor,
      line_end = overrides.line_end or 5,
      source_kind = "github",
      source_meta = {},
      stale = false,
      remote = {
        repository = "owner/repo",
        pull_number = 1,
        thread_id = "t1",
        comment_id = "c1",
        author = "reviewer",
        url = "https://github.com/owner/repo/pull/1",
        resolved = false,
        outdated = false,
      },
    }
  end

  describe("comments_for_buffer", function()
    it("returns the union of local and session remote comments", function()
      scope_data.comments = { local_comment() }
      session_comments = { remote_comment() }

      local comments = module.comments_for_buffer(1)
      assert.are.equal(2, #comments)
      assert.are.equal("local-1", comments[1].id)
      assert.are.equal("gh:c1", comments[2].id)
    end)

    it("returns only locals when session has no matching comments", function()
      scope_data.comments = { local_comment() }

      local comments = module.comments_for_buffer(1)
      assert.are.equal(1, #comments)
      assert.are.equal("local-1", comments[1].id)
    end)

    it("returns empty when there are no comments", function()
      local comments = module.comments_for_buffer(1)
      assert.are.equal(0, #comments)
    end)
  end)

  describe("list_comments_in_path", function()
    it("returns the union of local and session remote comments", function()
      scope_data.comments = { local_comment() }
      session_comments = { remote_comment() }

      local comments = module.list_comments_in_path("/repo/src/a.lua")
      assert.is_not_nil(comments)
      ---@cast comments LocalReviewComment[]
      assert.are.equal(2, #comments)
    end)

    it("supports directory queries", function()
      scope_data.comments = {
        local_comment({ absolute_path = "/repo/src/a.lua" }),
        local_comment({ id = "local-2", absolute_path = "/repo/src/b.lua" }),
      }
      session_comments = {
        remote_comment({ absolute_path = "/repo/src/b.lua", id = "gh:c2" }),
        remote_comment({ absolute_path = "/repo/test/c.lua", id = "gh:c3" }),
      }

      local comments = module.list_comments_in_path("/repo/src")
      assert.is_not_nil(comments)
      ---@cast comments LocalReviewComment[]
      assert.are.equal(3, #comments)
    end)
  end)

  describe("get_line_state", function()
    it("finds a session remote on a line", function()
      scope_data.comments = {}
      session_comments = { remote_comment() }

      local state = module.get_line_state(1, 5)
      assert.is_not_nil(state)
      assert.is_not_nil(state.comment)
      assert.are.equal("gh:c1", state.comment.id)
      assert.is_nil(state.index)
    end)

    it("finds a local comment on a line", function()
      scope_data.comments = { local_comment() }

      local state = module.get_line_state(1, 2)
      assert.is_not_nil(state)
      assert.is_not_nil(state.comment)
      assert.are.equal("local-1", state.comment.id)
      assert.are.equal(1, state.index)
    end)
  end)

  describe("set_line_comment", function()
    it("refuses to edit a session remote comment", function()
      scope_data.comments = {}
      session_comments = { remote_comment() }

      local result, err = module.set_line_comment(1, 5, "updated")
      assert.is_nil(result)
      assert.are.equal("Remote comments are read-only", err)
    end)

    it("refuses to create a comment on a line occupied by a session remote", function()
      scope_data.comments = {}
      session_comments = { remote_comment() }

      local result, err = module.set_line_comment(1, 5, "new comment")
      assert.is_nil(result)
      assert.are.equal("Remote comments are read-only", err)
    end)

    it("creates a local comment on an empty line", function()
      scope_data.comments = {}
      session_comments = {}

      local result, err = module.set_line_comment(1, 3, "new comment")
      assert.is_nil(err)
      assert.are.equal("created", result)
      assert.are.equal(1, #scope_data.comments)
      assert.are.equal("new comment", scope_data.comments[1].body)
    end)

    it("updates an existing local comment", function()
      scope_data.comments = { local_comment() }

      local result, err = module.set_line_comment(1, 2, "updated")
      assert.is_nil(err)
      assert.are.equal("updated", result)
      assert.are.equal("updated", scope_data.comments[1].body)
    end)

    it("clears stale when editing a stale comment", function()
      scope_data.comments = { local_comment({ stale = true }) }

      local result, err = module.set_line_comment(1, 2, "updated")
      assert.is_nil(err)
      assert.are.equal("updated", result)
      assert.are.equal("updated", scope_data.comments[1].body)
      assert.are.equal(false, scope_data.comments[1].stale)
    end)
  end)

  describe("delete_line_comment", function()
    it("refuses to delete a session remote comment", function()
      scope_data.comments = {}
      session_comments = { remote_comment() }

      local result, err = module.delete_line_comment(1, 5)
      assert.is_nil(result)
      assert.are.equal("Remote comments are read-only", err)
    end)

    it("deletes a local comment", function()
      scope_data.comments = { local_comment() }

      local result, err = module.delete_line_comment(1, 2)
      assert.is_nil(err)
      assert.are.equal("deleted", result)
      assert.are.equal(0, #scope_data.comments)
    end)
  end)

  describe("delete_current_line", function()
    it("notifies read-only for a session remote", function()
      scope_data.comments = {}
      session_comments = { remote_comment() }
      cursor_line = 5

      module.delete_current_line()
      assert.are.equal("Remote comments are read-only", notifications[#notifications].message)
      assert.are.equal(vim.log.levels.WARN, notifications[#notifications].level)
    end)
  end)
end)
