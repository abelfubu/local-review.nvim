---@diagnostic disable: undefined-global, undefined-field
require("busted.runner")()

package.path = table.concat({
  "./lua/?.lua",
  "./lua/?/init.lua",
  package.path,
}, ";")

describe("storage", function()
  local module
  local file_contents
  local readable_files
  local saved_rename
  local saved_remove

  before_each(function()
    file_contents = {}
    readable_files = {}

    package.loaded["local_review.infrastructure.storage"] = nil
    package.loaded["local_review.domain.comment_store"] = nil

    _G.vim = {
      fn = {
        sha256 = function(value)
          return "hash-" .. tostring(value)
        end,
        filereadable = function(path)
          return readable_files[path] and 1 or 0
        end,
        readfile = function(path)
          return file_contents[path] and { file_contents[path] } or {}
        end,
        mkdir = function() end,
        fnamemodify = function(path, mod)
          if mod == ":h" then
            return "/state/local-review"
          end
          return path
        end,
        writefile = function(lines, path)
          file_contents[path] = lines[1]
          readable_files[path] = true
          return 0
        end,
      },
      json = {
        decode = function(value)
          local ok, result = pcall(require("dkjson").decode, value)
          if not ok then
            return nil
          end
          return result
        end,
        encode = function(value)
          return require("dkjson").encode(value)
        end,
      },
    }

    ---@diagnostic disable-next-line: duplicate-set-field
    package.preload["local_review"] = function()
      return {
        get_opts = function()
          return { storage_dir = "/state/local-review" }
        end,
      }
    end

    saved_rename = os.rename
    saved_remove = os.remove
    ---@diagnostic disable-next-line: duplicate-set-field
    os.rename = function(src, dst)
      file_contents[dst] = file_contents[src]
      readable_files[dst] = file_contents[dst] ~= nil
      if src ~= dst then
        file_contents[src] = nil
        readable_files[src] = nil
      end
      return true
    end
    ---@diagnostic disable-next-line: duplicate-set-field
    os.remove = function(path)
      file_contents[path] = nil
      readable_files[path] = nil
      return true
    end

    module = require("local_review.infrastructure.storage")
  end)

  after_each(function()
    _G.vim = nil
    os.rename = saved_rename
    os.remove = saved_remove
    package.preload["local_review"] = nil
    package.loaded["local_review.infrastructure.storage"] = nil
    package.loaded["local_review.domain.comment_store"] = nil
  end)

  it("filters out persisted remote comments on load", function()
    local data = {
      comments = {
        { id = "local-1", origin = "local", absolute_path = "/repo/a.lua", anchor = { line_number = 1 } },
        { id = "gh:c1", origin = "github", absolute_path = "/repo/a.lua", anchor = { line_number = 2 } },
        { id = "local-2", origin = "local", absolute_path = "/repo/b.lua", anchor = { line_number = 3 } },
      },
    }

    local path = module.scope_file("/repo")
    file_contents[path] = require("dkjson").encode(data)
    readable_files[path] = true

    local loaded = module.load_scope("/repo")
    assert.are.equal(2, #loaded.comments)
    assert.are.equal("local-1", loaded.comments[1].id)
    assert.are.equal("local-2", loaded.comments[2].id)
  end)

  it("keeps local comments unchanged", function()
    local data = {
      comments = {
        { id = "local-1", origin = "local", absolute_path = "/repo/a.lua", anchor = { line_number = 1 } },
      },
    }

    local path = module.scope_file("/repo")
    file_contents[path] = require("dkjson").encode(data)
    readable_files[path] = true

    local loaded = module.load_scope("/repo")
    assert.are.equal(1, #loaded.comments)
    assert.are.equal("local-1", loaded.comments[1].id)
  end)

  it("filters out remote comments from disk during concurrent merge", function()
    local path = module.scope_file("/repo")
    file_contents[path] = require("dkjson").encode({
      comments = {
        { id = "local-1", origin = "local", absolute_path = "/repo/a.lua", anchor = { line_number = 1 } },
        { id = "gh:c1", origin = "github", absolute_path = "/repo/a.lua", anchor = { line_number = 2 } },
      },
    })
    readable_files[path] = true

    local ok, err = module.save_scope("/repo", {
      comments = { { id = "local-2", origin = "local", absolute_path = "/repo/b.lua", anchor = { line_number = 3 } } },
    })

    assert.is_true(ok)
    assert.is_nil(err)

    local saved = require("dkjson").decode(file_contents[path])
    assert.is_not_nil(saved)
    assert.are.equal(2, #saved.comments)
    local ids = {}
    for _, comment in ipairs(saved.comments) do
      ids[comment.id] = true
    end
    assert.is_true(ids["local-1"] and ids["local-2"])
    assert.is_nil(ids["gh:c1"])
  end)

  it("handles an empty scope file", function()
    local path = module.scope_file("/repo")
    file_contents[path] = "{}"
    readable_files[path] = true

    local loaded = module.load_scope("/repo")
    assert.are.equal(0, #loaded.comments)
  end)
end)
