---@diagnostic disable: undefined-global, undefined-field
require("busted.runner")()

package.path = table.concat({
  "./lua/?.lua",
  "./lua/?/init.lua",
  package.path,
}, ";")

describe("gh_session", function()
  local module
  local current_branch
  local state

  before_each(function()
    current_branch = "feature"
    state = {}

    package.loaded["local_review.application.gh_session"] = nil
    package.loaded["local_review.infrastructure.context"] = nil
    package.loaded["local_review.domain.comment_store"] = nil

    package.preload["local_review.infrastructure.context"] = function()
      return {
        current_branch = function(_)
          return current_branch
        end,
      }
    end

    module = require("local_review.application.gh_session")
  end)

  after_each(function()
    _G.vim = nil
    package.preload["local_review.infrastructure.context"] = nil
    package.loaded["local_review.application.gh_session"] = nil
    package.loaded["local_review.infrastructure.context"] = nil
  end)

  local function make_comment(overrides)
    overrides = overrides or {}
    return {
      id = overrides.id or "gh:c1",
      origin = overrides.origin or "github",
      absolute_path = overrides.absolute_path or "/repo/src/a.lua",
      relative_path = overrides.relative_path or "src/a.lua",
      body = overrides.body or "note",
      created_at = "2024-01-01T00:00:00Z",
      updated_at = "2024-01-01T00:00:00Z",
      anchor = overrides.anchor or { line_number = 5 },
      line_end = overrides.line_end or 5,
      source_kind = "github",
      source_meta = {},
      stale = false,
    }
  end

  describe("set / get / clear", function()
    it("stores fetched comments with metadata", function()
      module.set("/repo", { make_comment() }, {}, 42, "feature")
      local session = module.get("/repo")
      assert.is_not_nil(session)
      assert.are.equal(1, #session.comments)
      assert.are.equal(42, session.pull_number)
      assert.are.equal("feature", session.branch)
      assert.is_string(session.fetched_at)
    end)

    it("replaces an existing session set wholesale", function()
      module.set("/repo", { make_comment({ id = "gh:old" }) }, {}, 1, "main")
      module.set("/repo", { make_comment({ id = "gh:new" }) }, {}, 2, "feature")
      local session = module.get("/repo")
      assert.are.equal(1, #session.comments)
      assert.are.equal("gh:new", session.comments[1].id)
      assert.are.equal(2, session.pull_number)
      assert.are.equal("feature", session.branch)
    end)

    it("clears the session state for a scope", function()
      module.set("/repo", { make_comment() }, {}, 42, "feature")
      module.clear("/repo")
      assert.is_nil(module.get("/repo"))
    end)
  end)

  describe("comments_for_path", function()
    it("returns matching session comments", function()
      module.set("/repo", { make_comment({ absolute_path = "/repo/src/a.lua" }) }, {}, 42, "feature")
      local matches = module.comments_for_path("/repo", "/repo/src/a.lua", "file")
      assert.are.equal(1, #matches)
    end)

    it("returns empty when there is no session", function()
      local matches = module.comments_for_path("/repo", "/repo/src/a.lua", "file")
      assert.are.equal(0, #matches)
    end)

    it("filters by current branch", function()
      module.set("/repo", { make_comment() }, {}, 42, "feature")
      current_branch = "other"
      local matches = module.comments_for_path("/repo", "/repo/src/a.lua", "file")
      assert.are.equal(0, #matches)
    end)

    it("includes comments when the branch matches", function()
      module.set("/repo", { make_comment() }, {}, 42, "feature")
      current_branch = "feature"
      local matches = module.comments_for_path("/repo", "/repo/src/a.lua", "file")
      assert.are.equal(1, #matches)
    end)

    it("excludes comments when the branch cannot be determined", function()
      module.set("/repo", { make_comment() }, {}, 42, "feature")
      current_branch = nil
      local matches = module.comments_for_path("/repo", "/repo/src/a.lua", "file")
      assert.are.equal(0, #matches)
    end)

    it("supports directory queries", function()
      module.set("/repo", {
        make_comment({ absolute_path = "/repo/src/a.lua" }),
        make_comment({ absolute_path = "/repo/src/b.lua", id = "gh:c2" }),
        make_comment({ absolute_path = "/repo/test/c.lua", id = "gh:c3" }),
      }, {}, 42, "feature")
      local matches = module.comments_for_path("/repo", "/repo/src", "directory")
      assert.are.equal(2, #matches)
    end)
  end)
  describe("reviews_for_scope", function()
    it("returns reviews when the branch matches", function()
      local reviews = {
        {
          id = "review-1",
          author = "reviewer",
          state = "COMMENTED",
          body = "Great work",
          url = "https://example.com",
          submitted_at = "2024-01-01T00:00:00Z",
        },
      }
      module.set("/repo", {}, reviews, 1, "main")
      current_branch = "main"

      local result = module.reviews_for_scope("/repo")
      assert.are.equal(1, #result)
      assert.are.equal("Great work", result[1].body)
    end)

    it("hides reviews when the branch differs", function()
      module.set("/repo", {}, { { id = "review-1", body = "secret" } }, 1, "main")
      current_branch = "other"

      local result = module.reviews_for_scope("/repo")
      assert.are.equal(0, #result)
    end)

    it("returns an empty list when no session exists", function()
      local result = module.reviews_for_scope("/missing")
      assert.are.equal(0, #result)
    end)
  end)
end)
