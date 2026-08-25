---@diagnostic disable: undefined-global, undefined-field
require("busted.runner")()

package.path = table.concat({
  "./lua/?.lua",
  "./lua/?/init.lua",
  package.path,
}, ";")

describe("context.normalize_path", function()
  before_each(function()
    package.loaded["local_review.infrastructure.context"] = nil

    _G.vim = {
      fs = {
        normalize = function(path)
          return path
        end,
      },
      fn = {
        fnamemodify = function(path, modifier)
          if modifier == ":p" then
            return path
          end
          return path
        end,
        resolve = function(path)
          -- Simulates /var -> /private/var symlink resolution on macOS.
          return path:gsub("^/var/", "/private/var/")
        end,
      },
    }
  end)

  after_each(function()
    _G.vim = nil
    package.loaded["local_review.infrastructure.context"] = nil
  end)

  it("resolves symlinks so git repo roots and file paths match", function()
    local ctx = require("local_review.infrastructure.context")
    assert.are.equal("/private/var/tmp/repo/example.lua", ctx.normalize_path("/var/tmp/repo/example.lua"))
  end)
end)

describe("context.current_branch cache", function()
  local system_calls
  local branch_result
  local short_result
  local shell_error

  before_each(function()
    system_calls = {}
    branch_result = { "feature" }
    short_result = { "abc1234" }
    shell_error = 0

    package.loaded["local_review.infrastructure.context"] = nil

    _G.vim = {
      fs = {
        normalize = function(path)
          return path
        end,
      },
      fn = {
        getcwd = function()
          return "/repo"
        end,
        fnamemodify = function(path, modifier)
          if modifier == ":h" then
            return path:match("^(.*)/[^/]+$") or path
          end
          return path
        end,
        resolve = function(path)
          return path
        end,
        isdirectory = function()
          return 0
        end,
      },
      v = {
        shell_error = shell_error,
      },
    }

    ---@diagnostic disable-next-line: duplicate-set-field
    _G.vim.fn.systemlist = function(args)
      system_calls[#system_calls + 1] = args
      _G.vim.v.shell_error = shell_error
      if args[5] == "--abbrev-ref" then
        return branch_result
      end
      if args[5] == "--short" then
        return short_result
      end
      return {}
    end
  end)

  after_each(function()
    _G.vim = nil
    package.loaded["local_review.infrastructure.context"] = nil
  end)

  it("returns the resolved branch", function()
    local ctx = require("local_review.infrastructure.context")
    assert.are.equal("feature", ctx.current_branch("/repo"))
  end)

  it("caches branch lookups per path", function()
    local ctx = require("local_review.infrastructure.context")
    assert.are.equal("feature", ctx.current_branch("/repo"))
    assert.are.equal("feature", ctx.current_branch("/repo"))
    assert.are.equal(1, #system_calls)
  end)

  it("falls back to cwd when no path is given", function()
    local ctx = require("local_review.infrastructure.context")
    assert.are.equal("feature", ctx.current_branch())
    assert.are.equal(1, #system_calls)
  end)

  it("refreshes after explicit invalidation", function()
    local ctx = require("local_review.infrastructure.context")
    ctx.current_branch("/repo")
    ctx.invalidate_branch_cache("/repo")
    ctx.current_branch("/repo")
    assert.are.equal(2, #system_calls)
  end)

  it("invalidates all cached branches when no path is given", function()
    local ctx = require("local_review.infrastructure.context")
    ctx.current_branch("/repo")
    ctx.current_branch("/other")
    ctx.invalidate_branch_cache()
    ctx.current_branch("/repo")
    ctx.current_branch("/other")
    assert.are.equal(4, #system_calls)
  end)

  it("returns nil when git fails", function()
    shell_error = 1
    branch_result = {}
    local ctx = require("local_review.infrastructure.context")
    assert.is_nil(ctx.current_branch("/repo"))
  end)

  it("includes the short commit hash for detached HEAD", function()
    branch_result = { "HEAD" }
    local ctx = require("local_review.infrastructure.context")
    local branch = ctx.current_branch("/repo")
    assert.are.equal("HEAD@abc1234", branch)
    assert.are.equal(2, #system_calls)

    ctx.invalidate_branch_cache("/repo")
    ctx.current_branch("/repo")
    assert.are.equal(4, #system_calls)
  end)
end)

describe("context.default_export_root", function()
  before_each(function()
    package.loaded["local_review.infrastructure.context"] = nil

    _G.vim = {
      fs = {
        normalize = function(path)
          return path
        end,
      },
      api = {
        nvim_buf_get_name = function(_)
          return "/repo/src/file.lua"
        end,
      },
      fn = {
        getcwd = function()
          return "/parent"
        end,
        fnamemodify = function(path, modifier)
          if modifier == ":h" then
            local parent = path:match("^(.*)/[^/]+")
            if not parent or parent == "" then
              return "/"
            end
            return parent
          end
          return path
        end,
        resolve = function(path)
          return path
        end,
        isdirectory = function(path)
          return path ~= "/repo/src/file.lua" and 1 or 0
        end,
        filereadable = function(path)
          return path == "/repo/src/file.lua" and 1 or 0
        end,
      },
      v = {
        shell_error = 0,
      },
    }

    ---@diagnostic disable-next-line: duplicate-set-field
    _G.vim.fn.systemlist = function(args)
      if args[4] == "rev-parse" and args[5] == "--show-toplevel" then
        return { "/repo" }
      end
      if args[5] == "rev-parse" and args[6] == "--abbrev-ref" then
        return { "main" }
      end
      return {}
    end
  end)

  after_each(function()
    _G.vim = nil
    package.loaded["local_review.infrastructure.context"] = nil
  end)

  it("prefers the current buffer's repo root over cwd", function()
    local ctx = require("local_review.infrastructure.context")
    assert.are.equal("/repo", ctx.default_export_root())
  end)

  it("falls back to cwd's repo root when buffer has no real file", function()
    ---@diagnostic disable-next-line: duplicate-set-field
    _G.vim.api.nvim_buf_get_name = function(_)
      return ""
    end
    ---@diagnostic disable-next-line: duplicate-set-field
    _G.vim.fn.systemlist = function(args)
      if args[4] == "rev-parse" and args[5] == "--show-toplevel" then
        return { "/parent/repo" }
      end
      if args[5] == "rev-parse" and args[6] == "--abbrev-ref" then
        return { "main" }
      end
      return {}
    end

    local ctx = require("local_review.infrastructure.context")
    assert.are.equal("/parent/repo", ctx.default_export_root())
  end)

  it("falls back to cwd when neither buffer nor cwd is in a repo", function()
    ---@diagnostic disable-next-line: duplicate-set-field
    _G.vim.api.nvim_buf_get_name = function(_)
      return ""
    end
    ---@diagnostic disable-next-line: duplicate-set-field
    _G.vim.fn.systemlist = function(_)
      _G.vim.v.shell_error = 1
      return {}
    end

    local ctx = require("local_review.infrastructure.context")
    assert.are.equal("/parent", ctx.default_export_root())
  end)
end)
