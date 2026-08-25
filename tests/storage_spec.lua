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
  local file_mtimes
  local saved_rename
  local saved_remove
  local next_mtime

  before_each(function()
    file_contents = {}
    readable_files = {}
    file_mtimes = {}
    next_mtime = 1

    package.loaded["local_review.infrastructure.storage"] = nil
    package.loaded["local_review.domain.comment_store"] = nil

    _G.vim = {
      fs = {
        normalize = function(path)
          return path
        end,
      },
      fn = {
        sha256 = function(value)
          return "hash-" .. tostring(value)
        end,
        resolve = function(path)
          return path
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
          file_mtimes[path] = next_mtime
          next_mtime = next_mtime + 1
          return 0
        end,
        getftime = function(path)
          return file_mtimes[path] or 0
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
    file_mtimes[path] = next_mtime
    next_mtime = next_mtime + 1

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
    file_mtimes[path] = next_mtime
    next_mtime = next_mtime + 1

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
    file_mtimes[path] = next_mtime
    next_mtime = next_mtime + 1

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
    file_mtimes[path] = next_mtime
    next_mtime = next_mtime + 1

    local loaded = module.load_scope("/repo")
    assert.are.equal(0, #loaded.comments)
  end)

  it("caches scope data and avoids re-decoding on repeated loads", function()
    local path = module.scope_file("/repo")
    file_contents[path] = require("dkjson").encode({
      comments = {
        { id = "local-1", origin = "local", absolute_path = "/repo/a.lua", anchor = { line_number = 1 } },
      },
    })
    readable_files[path] = true
    file_mtimes[path] = next_mtime
    next_mtime = next_mtime + 1

    local decode_calls = 0
    local original_decode = _G.vim.json.decode
    ---@diagnostic disable-next-line: duplicate-set-field
    _G.vim.json.decode = function(value)
      decode_calls = decode_calls + 1
      return original_decode(value)
    end

    local first = module.load_scope("/repo")
    assert.are.equal(1, decode_calls)
    assert.are.equal("local-1", first.comments[1].id)

    local second = module.load_scope("/repo")
    assert.are.equal(1, decode_calls)
    assert.are.equal("local-1", second.comments[1].id)

    _G.vim.json.decode = original_decode
  end)

  it("returns copies so caller mutation cannot corrupt the cache", function()
    local path = module.scope_file("/repo")
    file_contents[path] = require("dkjson").encode({
      comments = {
        {
          id = "local-1",
          origin = "local",
          absolute_path = "/repo/a.lua",
          body = "original",
          anchor = { line_number = 1 },
        },
      },
    })
    readable_files[path] = true
    file_mtimes[path] = next_mtime
    next_mtime = next_mtime + 1

    local first = module.load_scope("/repo")
    first.comments[1].body = "mutated"
    first.comments[1].anchor.line_number = 99
    table.insert(first.comments, { id = "injected" })

    local second = module.load_scope("/repo")
    assert.are.equal("original", second.comments[1].body)
    assert.are.equal(1, second.comments[1].anchor.line_number)
    assert.are.equal(1, #second.comments)
  end)

  it("writes through the cache on save_scope", function()
    local path = module.scope_file("/repo")
    file_contents[path] = require("dkjson").encode({
      comments = {
        { id = "local-1", origin = "local", absolute_path = "/repo/a.lua", anchor = { line_number = 1 } },
      },
    })
    readable_files[path] = true
    file_mtimes[path] = next_mtime
    next_mtime = next_mtime + 1

    local first = module.load_scope("/repo")
    assert.are.equal(1, #first.comments)

    local ok, err = module.save_scope("/repo", {
      comments = { { id = "local-2", origin = "local", absolute_path = "/repo/b.lua", anchor = { line_number = 2 } } },
    })
    assert.is_true(ok)
    assert.is_nil(err)

    local second = module.load_scope("/repo")
    assert.are.equal(1, #second.comments)
    assert.are.equal("local-2", second.comments[1].id)
  end)

  it("invalidates the cache for one scope or all scopes", function()
    local path_a = module.scope_file("/repo-a")
    file_contents[path_a] = require("dkjson").encode({
      comments = { { id = "a", origin = "local", absolute_path = "/repo-a/f.lua", anchor = { line_number = 1 } } },
    })
    readable_files[path_a] = true
    file_mtimes[path_a] = 100

    local path_b = module.scope_file("/repo-b")
    file_contents[path_b] = require("dkjson").encode({
      comments = { { id = "b", origin = "local", absolute_path = "/repo-b/f.lua", anchor = { line_number = 1 } } },
    })
    readable_files[path_b] = true
    file_mtimes[path_b] = 200

    module.load_scope("/repo-a")
    module.load_scope("/repo-b")

    -- Change the backing file for repo-a but keep its mtime unchanged so the
    -- explicit invalidation function is the only thing that refreshes it.
    file_contents[path_a] = require("dkjson").encode({
      comments = { { id = "a2", origin = "local", absolute_path = "/repo-a/f.lua", anchor = { line_number = 1 } } },
    })

    local stale_a = module.load_scope("/repo-a")
    assert.are.equal("a", stale_a.comments[1].id)

    module.invalidate_scope_cache("/repo-a")
    local fresh_a = module.load_scope("/repo-a")
    assert.are.equal("a2", fresh_a.comments[1].id)

    -- Change repo-b without touching mtime, then invalidate every scope.
    file_contents[path_b] = require("dkjson").encode({
      comments = { { id = "b2", origin = "local", absolute_path = "/repo-b/f.lua", anchor = { line_number = 1 } } },
    })

    local stale_b = module.load_scope("/repo-b")
    assert.are.equal("b", stale_b.comments[1].id)

    module.invalidate_scope_cache()
    local fresh_b = module.load_scope("/repo-b")
    assert.are.equal("b2", fresh_b.comments[1].id)
  end)

  it("does not serve stale entries when the scope file is deleted externally", function()
    local path = module.scope_file("/repo")
    file_contents[path] = require("dkjson").encode({
      comments = { { id = "local-1", origin = "local", absolute_path = "/repo/a.lua", anchor = { line_number = 1 } } },
    })
    readable_files[path] = true
    file_mtimes[path] = next_mtime
    next_mtime = next_mtime + 1

    local first = module.load_scope("/repo")
    assert.are.equal(1, #first.comments)

    file_contents[path] = nil
    readable_files[path] = nil

    local second = module.load_scope("/repo")
    assert.are.equal(0, #second.comments)
  end)

  it("invalidates the cache via vim.uv.fs_stat mtime changes (primary path)", function()
    local path = module.scope_file("/repo")
    local uv_mtimes = {}
    _G.vim.uv = {
      fs_stat = function(p)
        local mt = uv_mtimes[p]
        return mt and { mtime = mt } or nil
      end,
    }
    file_contents[path] = require("dkjson").encode({
      comments = {
        { id = "local-1", origin = "local", absolute_path = "/repo/a.lua", anchor = { line_number = 1 } },
      },
    })
    readable_files[path] = true
    uv_mtimes[path] = { sec = 100, nsec = 5 }

    local first = module.load_scope("/repo")
    assert.are.equal("local-1", first.comments[1].id)

    -- External writer changes content with an nsec-only bump: invisible to the
    -- getftime fallback (second resolution), so this exercises the fs_stat path.
    file_contents[path] = require("dkjson").encode({
      comments = {
        { id = "local-2", origin = "local", absolute_path = "/repo/a.lua", anchor = { line_number = 1 } },
      },
    })
    uv_mtimes[path] = { sec = 100, nsec = 6 }

    local second = module.load_scope("/repo")
    assert.are.equal("local-2", second.comments[1].id)
  end)

  it("save_scope merge still reads disk directly and does not use the cache", function()
    local path = module.scope_file("/repo")
    file_contents[path] = require("dkjson").encode({
      comments = { { id = "local-1", origin = "local", absolute_path = "/repo/a.lua", anchor = { line_number = 1 } } },
    })
    readable_files[path] = true
    file_mtimes[path] = next_mtime
    next_mtime = next_mtime + 1

    module.load_scope("/repo")

    -- Simulate a concurrent external write that the cache cannot see.
    file_contents[path] = require("dkjson").encode({
      comments = {
        { id = "local-1", origin = "local", absolute_path = "/repo/a.lua", anchor = { line_number = 1 } },
        { id = "local-3", origin = "local", absolute_path = "/repo/c.lua", anchor = { line_number = 3 } },
      },
    })
    file_mtimes[path] = next_mtime
    next_mtime = next_mtime + 1

    local ok, err = module.save_scope("/repo", {
      comments = { { id = "local-2", origin = "local", absolute_path = "/repo/b.lua", anchor = { line_number = 2 } } },
    })
    assert.is_true(ok)
    assert.is_nil(err)

    local saved = require("dkjson").decode(file_contents[path])
    local ids = {}
    for _, comment in ipairs(saved.comments) do
      ids[comment.id] = true
    end
    assert.is_true(ids["local-1"])
    assert.is_true(ids["local-2"])
    assert.is_true(ids["local-3"])
  end)

  it("resolves symlinks in persisted comment paths on load", function()
    ---@diagnostic disable-next-line: duplicate-set-field
    _G.vim.fn.resolve = function(path)
      return path:gsub("^/var/", "/private/var/")
    end

    local path = module.scope_file("/private/var/repo")
    file_contents[path] = require("dkjson").encode({
      comments = {
        { id = "local-1", origin = "local", absolute_path = "/var/repo/a.lua", anchor = { line_number = 1 } },
      },
    })
    readable_files[path] = true
    file_mtimes[path] = next_mtime
    next_mtime = next_mtime + 1

    local data = module.load_scope("/private/var/repo")
    assert.are.equal("/private/var/repo/a.lua", data.comments[1].absolute_path)
  end)
end)
