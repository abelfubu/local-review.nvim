---@diagnostic disable: undefined-global, undefined-field, need-check-nil
require("busted.runner")()

package.path = table.concat({
  "./lua/?.lua",
  "./lua/?/init.lua",
  package.path,
}, ";")

local comment_store = require("local_review.domain.comment_store")
local helpers = require("tests.helpers.helpers")

---@return fun(): string
local function id_generator()
  local counter = 0
  return function()
    counter = counter + 1
    return tostring(counter)
  end
end

---@param lines string[]
---@param line integer
---@return table
local function simple_capture(lines, line)
  return {
    line_number = line,
    line_text = lines[line] or "",
  }
end

local function lines_fixture()
  return { "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten" }
end

local function base_opts(overrides)
  local generate_id = id_generator()
  local opts = {
    absolute_path = "/fake/path.lua",
    line = 5,
    body = "comment body",
    lines = lines_fixture(),
    timestamp = "2024-01-01T00:00:00Z",
    capture = simple_capture,
    generate_id = generate_id,
    source_kind = "test",
    source_meta = {},
    origin = "local",
  }

  if overrides then
    for key, value in pairs(overrides) do
      opts[key] = value
    end
  end

  -- ensure a fresh generator unless the caller provided one
  if not overrides or overrides.generate_id == nil then
    opts.generate_id = generate_id
  end

  return opts
end

describe("comment_store.upsert_comment", function()
  it("creates a single-line comment", function()
    local comments = {}
    local opts = base_opts({ line = 5 })

    local comment, updated = comment_store.upsert_comment(comments, opts)

    assert.is_false(updated)
    assert.are.equal(1, #comments)
    assert.are.equal(opts.body, comment.body)
    assert.are.equal(5, comment.anchor.line_number)
    assert.are.equal(5, comment.line_end)
    assert.are.equal(opts.timestamp, comment.created_at)
    assert.are.equal(opts.timestamp, comment.updated_at)
    assert.are.equal("1", comment.id)
    assert.are.equal("local", comment.origin)
  end)

  it("creates a range comment", function()
    local comments = {}
    local opts = base_opts({ line = 3, line_end = 7 })

    local comment, updated = comment_store.upsert_comment(comments, opts)

    assert.is_false(updated)
    assert.are.equal(3, comment.anchor.line_number)
    assert.are.equal(7, comment.line_end)
  end)

  it("updates an existing range instead of duplicating when inside it", function()
    local comments = {}
    local gen = id_generator()
    local opts = base_opts({
      line = 3,
      line_end = 7,
      body = "original",
      generate_id = gen,
    })

    comment_store.upsert_comment(comments, opts)

    local update_opts = base_opts({
      line = 5,
      body = "updated",
      timestamp = "2024-02-02T00:00:00Z",
      generate_id = gen,
    })

    local comment, updated = comment_store.upsert_comment(comments, update_opts)

    assert.is_true(updated)
    assert.are.equal(1, #comments)
    assert.are.equal("updated", comment.body)
    assert.are.equal(3, comment.anchor.line_number)
    assert.are.equal(7, comment.line_end)
    assert.are.equal("2024-02-02T00:00:00Z", comment.updated_at)
    assert.are.equal("2024-01-01T00:00:00Z", comment.created_at)
  end)

  it("clamps out-of-bounds range ends to the buffer", function()
    local comments = {}
    local opts = base_opts({
      line = 8,
      line_end = 25,
    })

    local comment = comment_store.upsert_comment(comments, opts)

    assert.are.equal(10, comment.line_end)
  end)
end)

describe("comment_store containment", function()
  local function make_range_comment()
    return {
      id = "r1",
      absolute_path = "/fake/path.lua",
      body = "range",
      created_at = "t1",
      updated_at = "t1",
      source_kind = "test",
      source_meta = {},
      stale = false,
      anchor = { line_number = 4 },
      line_end = 6,
    }
  end

  it("finds the comment at the first, middle, and last line of the range", function()
    local comments = { make_range_comment() }

    assert.are.equal(comments[1], comment_store.find_comment_at_line(comments, "/fake/path.lua", 4))
    assert.are.equal(comments[1], comment_store.find_comment_at_line(comments, "/fake/path.lua", 5))
    assert.are.equal(comments[1], comment_store.find_comment_at_line(comments, "/fake/path.lua", 6))
  end)

  it("returns nil outside the range and for a different path", function()
    local comments = { make_range_comment() }

    assert.is_nil(comment_store.find_comment_at_line(comments, "/fake/path.lua", 3))
    assert.is_nil(comment_store.find_comment_at_line(comments, "/fake/path.lua", 7))
    assert.is_nil(comment_store.find_comment_at_line(comments, "/other/path.lua", 5))
  end)

  it("finds the entry index for deletion by containment", function()
    local comments = { make_range_comment() }

    local comment, index = comment_store.find_comment_entry_at_line(comments, "/fake/path.lua", 5)
    assert.are.equal(comments[1], comment)
    assert.are.equal(1, index)

    table.remove(comments, index)
    assert.are.equal(0, #comments)
  end)
end)

describe("comment_store.reconcile_comment", function()
  local function make_comment(line_number, line_end)
    return {
      id = "rc",
      absolute_path = "/fake/path.lua",
      body = "body",
      created_at = "t1",
      updated_at = "t1",
      source_kind = "test",
      source_meta = {},
      stale = false,
      anchor = { line_number = line_number },
      line_end = line_end,
    }
  end

  it("keeps the comment unchanged when resolved to the same line", function()
    local comment = make_comment(5, 8)
    local lines = lines_fixture()
    local function resolve(anchor, _)
      return anchor.line_number
    end

    local changed = comment_store.reconcile_comment(comment, lines, resolve, simple_capture)

    assert.is_false(changed)
    assert.are.equal(5, comment.anchor.line_number)
    assert.are.equal(8, comment.line_end)
    assert.is_false(comment.stale)
  end)

  it("shifts line_end by the delta when the anchor moves down", function()
    local comment = make_comment(3, 5)
    local lines = lines_fixture()
    local function resolve(anchor, _)
      return anchor.line_number + 3
    end

    local changed = comment_store.reconcile_comment(comment, lines, resolve, simple_capture)

    assert.is_true(changed)
    assert.are.equal(6, comment.anchor.line_number)
    assert.are.equal(8, comment.line_end)
  end)

  it("shifts line_end by the delta when the anchor moves up", function()
    local comment = make_comment(8, 10)
    local lines = lines_fixture()
    local function resolve(anchor, _)
      return anchor.line_number - 2
    end

    local changed = comment_store.reconcile_comment(comment, lines, resolve, simple_capture)

    assert.is_true(changed)
    assert.are.equal(6, comment.anchor.line_number)
    assert.are.equal(8, comment.line_end)
  end)

  it("collapses a single-line comment when moved", function()
    local comment = make_comment(5, nil)
    local lines = lines_fixture()
    local function resolve(anchor, _)
      return anchor.line_number + 2
    end

    local changed = comment_store.reconcile_comment(comment, lines, resolve, simple_capture)

    assert.is_true(changed)
    assert.are.equal(7, comment.anchor.line_number)
    assert.are.equal(7, comment.line_end)
  end)

  it("marks the comment stale when it is unresolvable", function()
    local comment = make_comment(5, 8)
    local lines = lines_fixture()
    local function resolve(_, _)
      return nil
    end

    local changed = comment_store.reconcile_comment(comment, lines, resolve, simple_capture)

    assert.is_true(changed)
    assert.is_true(comment.stale)
    assert.are.equal(5, comment.anchor.line_number)
  end)

  it("does not mark stale again if the comment is already stale", function()
    local comment = make_comment(5, 8)
    comment.stale = true
    local lines = lines_fixture()
    local function resolve(_, _)
      return nil
    end

    local changed = comment_store.reconcile_comment(comment, lines, resolve, simple_capture)

    assert.is_false(changed)
    assert.is_true(comment.stale)
  end)
end)

describe("comment_store sorting", function()
  local function make_comment(absolute_path, line_number, created_at)
    return {
      id = absolute_path .. line_number,
      absolute_path = absolute_path,
      body = "x",
      created_at = created_at,
      updated_at = created_at,
      source_kind = "test",
      source_meta = {},
      stale = false,
      anchor = { line_number = line_number },
      line_end = line_number,
    }
  end

  it("orders by path, then line, then created_at", function()
    local comments = {
      make_comment("/b/file.lua", 1, "c1"),
      make_comment("/a/file.lua", 10, "c1"),
      make_comment("/a/file.lua", 1, "c2"),
      make_comment("/a/file.lua", 1, "c1"),
    }

    table.sort(comments, comment_store.comment_sorter)

    assert.are.equal("/a/file.lua", comments[1].absolute_path)
    assert.are.equal(1, comments[1].anchor.line_number)
    assert.are.equal("c1", comments[1].created_at)

    assert.are.equal("/a/file.lua", comments[2].absolute_path)
    assert.are.equal(1, comments[2].anchor.line_number)
    assert.are.equal("c2", comments[2].created_at)

    assert.are.equal("/a/file.lua", comments[3].absolute_path)
    assert.are.equal(10, comments[3].anchor.line_number)

    assert.are.equal("/b/file.lua", comments[4].absolute_path)
  end)
end)

describe("comment_store dual-anchor reconcile", function()
  local function make_dual_anchor_comment(start_line, end_line)
    return {
      id = "dual",
      absolute_path = "/fake/path.lua",
      body = "body",
      created_at = "t1",
      updated_at = "t1",
      source_kind = "test",
      source_meta = {},
      stale = false,
      anchor = { line_number = start_line },
      anchor_end = { line_number = end_line },
      line_end = end_line,
    }
  end

  local function resolve_with_offsets(start_offset, end_offset)
    return function(anchor, _)
      if anchor.line_number == 3 then
        return anchor.line_number + start_offset
      end
      return anchor.line_number + end_offset
    end
  end

  it("keeps start and shifts end when lines are inserted inside the range", function()
    local comment = make_dual_anchor_comment(3, 7)
    local lines = lines_fixture()

    local changed = comment_store.reconcile_comment(comment, lines, resolve_with_offsets(0, 2), simple_capture)

    assert.is_true(changed)
    assert.is_false(comment.stale)
    assert.are.equal(3, comment.anchor.line_number)
    assert.are.equal(9, comment.anchor_end.line_number)
    assert.are.equal(9, comment.line_end)
  end)

  it("marks the comment stale when the end anchor is lost", function()
    local comment = make_dual_anchor_comment(3, 7)
    local lines = lines_fixture()
    local function resolve(anchor, _)
      if anchor.line_number == 3 then
        return 3
      end
      return nil
    end

    local changed = comment_store.reconcile_comment(comment, lines, resolve, simple_capture)

    assert.is_true(changed)
    assert.is_true(comment.stale)
    assert.are.equal(3, comment.anchor.line_number)
    assert.are.equal(7, comment.anchor_end.line_number)
    assert.are.equal(7, comment.line_end)
  end)

  it("shifts both ends when the whole range is moved", function()
    local comment = make_dual_anchor_comment(3, 7)
    local lines = lines_fixture()

    local changed = comment_store.reconcile_comment(comment, lines, resolve_with_offsets(2, 2), simple_capture)

    assert.is_true(changed)
    assert.is_false(comment.stale)
    assert.are.equal(5, comment.anchor.line_number)
    assert.are.equal(9, comment.anchor_end.line_number)
    assert.are.equal(9, comment.line_end)
  end)

  it("leaves a single-line dual-anchor comment unchanged when resolved to the same line", function()
    local comment = make_dual_anchor_comment(5, 5)
    local lines = lines_fixture()
    local function resolve(anchor, _)
      return anchor.line_number
    end

    local changed = comment_store.reconcile_comment(comment, lines, resolve, simple_capture)

    assert.is_false(changed)
    assert.is_false(comment.stale)
    assert.are.equal(5, comment.anchor.line_number)
    assert.are.equal(5, comment.anchor_end.line_number)
    assert.are.equal(5, comment.line_end)
  end)

  it("swaps start and end when the resolved range is inverted", function()
    local comment = make_dual_anchor_comment(3, 7)
    local lines = lines_fixture()
    local function resolve(anchor, _)
      if anchor.line_number == 3 then
        return 8
      end
      return 2
    end

    local changed = comment_store.reconcile_comment(comment, lines, resolve, simple_capture)

    assert.is_true(changed)
    assert.is_false(comment.stale)
    assert.are.equal(2, comment.anchor.line_number)
    assert.are.equal(8, comment.anchor_end.line_number)
    assert.are.equal(8, comment.line_end)
  end)
end)

describe("remote comments", function()
  ---@param overrides table
  ---@return LocalReviewComment
  local function make_comment(overrides)
    return helpers.merge({ origin = "github" }, overrides)
  end

  it("checks for a remote comment", function()
    assert.is_false(comment_store.is_remote(make_comment({ origin = "local" })))
    assert.is_true(comment_store.is_remote(make_comment({})))
  end)

  it("checks for an editable comment", function()
    assert.is_true(comment_store.is_editable(make_comment({ origin = "local" })))
    assert.is_false(comment_store.is_editable(make_comment({})))
  end)

  it("checks for a submitable review session", function()
    assert.is_true(#comment_store.submittable({ make_comment({ origin = "local" }) }) > 0)
    assert.is_false(#comment_store.submittable({ make_comment({}) }) > 0)
    assert.is_true(#comment_store.submittable({ make_comment({}), make_comment({ origin = "local" }) }) > 0)
  end)
end)

describe("remote comment guards", function()
  ---@param overrides table?
  ---@return LocalReviewComment
  local function make_remote_comment(overrides)
    return helpers.merge({
      id = "remote-1",
      absolute_path = "/fake/path.lua",
      relative_path = "path.lua",
      body = "github body",
      created_at = "2024-01-01T00:00:00Z",
      updated_at = "2024-01-01T00:00:00Z",
      source_kind = "github",
      source_meta = {},
      stale = false,
      origin = "github",
      anchor = { line_number = 5, line_text = "five" },
      line_end = 5,
    }, overrides)
  end

  it("refuses to upsert over a remote comment", function()
    local remote = make_remote_comment()
    local comments = { remote }

    local comment, updated, reason = comment_store.upsert_comment(comments, base_opts({ line = 5, body = "hijack" }))

    assert.is_nil(comment)
    assert.is_nil(updated)
    assert.matches("read%-only", reason)
    assert.are.equal("github body", remote.body)
    assert.are.equal(5, remote.anchor.line_number)
    assert.are.equal(1, #comments)
  end)

  it("still creates a local comment on a different line", function()
    local comments = { make_remote_comment() }

    local comment, updated, reason = comment_store.upsert_comment(comments, base_opts({ line = 7 }))

    assert.is_not_nil(comment)
    assert.is_false(updated)
    assert.is_nil(reason)
    assert.are.equal("local", comment.origin)
    assert.are.equal(2, #comments)
  end)

  it("removes a local comment", function()
    local comment = make_remote_comment({ origin = "local" })
    local comments = { comment }

    local ok, reason = comment_store.remove_comment(comments, comment)

    assert.is_true(ok)
    assert.is_nil(reason)
    assert.are.equal(0, #comments)
  end)

  it("refuses to remove a remote comment", function()
    local remote = make_remote_comment()
    local comments = { remote }

    local ok, reason = comment_store.remove_comment(comments, remote)

    assert.is_nil(ok)
    assert.matches("read%-only", reason)
    assert.are.equal(1, #comments)
  end)

  it("removes a local comment that is not first in the list", function()
    local first = make_remote_comment({ origin = "local", id = "first" })
    local second = make_remote_comment({ origin = "local", id = "second" })
    local comments = { first, second }

    local ok, reason = comment_store.remove_comment(comments, second)

    assert.is_true(ok)
    assert.is_nil(reason)
    assert.are.equal(1, #comments)
    assert.are.equal("first", comments[1].id)
  end)
end)

describe("comment_store.matching_path / partitions", function()
  ---@param overrides table?
  ---@return LocalReviewComment
  local function path_comment(overrides)
    return helpers.merge({
      id = "c1",
      absolute_path = "/repo/src/a.lua",
      anchor = { line_number = 1, line_text = "x" },
      line_end = 1,
      created_at = "2024-01-01T00:00:00Z",
      origin = "local",
    }, overrides)
  end

  local function scopes_with(...)
    local scopes = {}
    for _, comments in ipairs({ ... }) do
      table.insert(scopes, { data = { comments = comments } })
    end
    return scopes
  end

  it("matches exact file path", function()
    local wanted = path_comment()
    local other = path_comment({ id = "c2", absolute_path = "/repo/b.lua" })
    local result = comment_store.matching_path(scopes_with({ wanted }, { other }), "/repo/src/a.lua", "file")
    assert.are.equal(1, #result)
    assert.are.equal("c1", result[1].id)
  end)

  it("matches comments within a directory", function()
    local inside = path_comment()
    local nested = path_comment({ id = "c2", absolute_path = "/repo/src/deep/b.lua" })
    local outside = path_comment({ id = "c3", absolute_path = "/other/c.lua" })
    local result = comment_store.matching_path(scopes_with({ inside, nested, outside }), "/repo/src", "directory")
    assert.are.equal(2, #result)
  end)

  it("does not match sibling directories sharing a prefix", function()
    local sibling = path_comment({ absolute_path = "/repo/src2/a.lua" })
    local result = comment_store.matching_path(scopes_with({ sibling }), "/repo/src", "directory")
    assert.are.equal(0, #result)
  end)

  it("returns results sorted by path then line", function()
    local later = path_comment({ id = "c2", anchor = { line_number = 9, line_text = "x" } })
    local earlier = path_comment({ id = "c1", anchor = { line_number = 2, line_text = "x" } })
    local result = comment_store.matching_path(scopes_with({ later, earlier }), "/repo/src/a.lua", "file")
    assert.are.equal("c1", result[1].id)
    assert.are.equal("c2", result[2].id)
  end)

  it("partition_path splits matching from kept comments", function()
    local hit = path_comment()
    local miss = path_comment({ id = "c2", absolute_path = "/repo/b.lua" })
    local matched, kept = comment_store.partition_path({ hit, miss }, "/repo/src/a.lua", "file")
    assert.are.equal(1, #matched)
    assert.are.equal("c1", matched[1].id)
    assert.are.equal(1, #kept)
    assert.are.equal("c2", kept[1].id)
  end)

  it("partition_ids splits by id membership", function()
    local a = path_comment({ id = "a" })
    local b = path_comment({ id = "b" })
    local matched, kept = comment_store.partition_ids({ a, b }, { b = true })
    assert.are.equal(1, #matched)
    assert.are.equal("b", matched[1].id)
    assert.are.equal(1, #kept)
    assert.are.equal("a", kept[1].id)
  end)
end)
