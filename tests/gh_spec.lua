---@diagnostic disable: undefined-global, undefined-field, duplicate-set-field
require("busted.runner")()

package.path = table.concat({
  "./lua/?.lua",
  "./lua/?/init.lua",
  package.path,
}, ";")

describe("gh infrastructure", function()
  local gh

  before_each(function()
    package.loaded["local_review.infrastructure.gh"] = nil

    _G.vim = {
      trim = function(value)
        return (value or ""):match("^%s*(.-)%s*$")
      end,
      system = function(_command, _opts)
        return {
          wait = function()
            return { code = 0, stdout = "ok\n", stderr = "" }
          end,
        }
      end,
    }

    gh = require("local_review.infrastructure.gh")
  end)

  after_each(function()
    _G.vim = nil
    package.loaded["local_review.infrastructure.gh"] = nil
  end)

  it("returns trimmed spawn errors through the error return path", function()
    _G.vim.system = function()
      error("  spawn error: ENOENT  ", 0)
    end

    local output, err = gh.run({ "gh", "repo", "view" }, "/repo")

    assert.is_nil(output)
    assert.are.equal("spawn error: ENOENT", err)
  end)

  it("detects timeout via exit code 124", function()
    _G.vim.system = function()
      return {
        wait = function()
          return { code = 124, stdout = "", stderr = "" }
        end,
      }
    end

    local output, err = gh.run({ "gh", "repo", "view" }, "/repo")

    assert.is_nil(output)
    assert.are.equal("gh command timed out after 30000ms", err)
  end)

  it("returns trimmed stdout on success", function()
    _G.vim.system = function()
      return {
        wait = function()
          return { code = 0, stdout = "owner/repo\n", stderr = "" }
        end,
      }
    end

    local output, err = gh.run({ "gh", "repo", "view" }, "/repo")

    assert.are.equal("owner/repo", output)
    assert.is_nil(err)
  end)
end)
