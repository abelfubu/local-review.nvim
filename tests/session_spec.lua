---@diagnostic disable: undefined-global, undefined-field
require("busted.runner")()

package.path = table.concat({
  "./lua/?.lua",
  "./lua/?/init.lua",
  package.path,
}, ";")

local session = require("local_review.session")

describe("review session branch availability", function()
  it("does not bind or block non-git targets", function()
    local stored = { comments = {} }

    local opened = session.open(stored, nil)

    assert.is_true(opened.available)
    assert.is_nil(opened.bound_to)
    assert.is_nil(stored.session)
  end)

  it("starts unbound and only binds on the first successful finding mutation", function()
    local stored = { comments = {} }

    local created = session.open(stored, { kind = "branch", name = "feature/review" })
    assert.is_true(created.available)
    assert.is_nil(created.bound_to)
    assert.is_nil(stored.session)

    session.bind(stored, { kind = "branch", name = "feature/review" })
    assert.are.same({ kind = "branch", name = "feature/review" }, stored.session.binding)

    local reopened = session.open(stored, { kind = "branch", name = "feature/review" })
    assert.is_true(reopened.available)
    assert.are.equal("feature/review", reopened.bound_to)

    local switched = session.open(stored, { kind = "branch", name = "main" })
    assert.is_false(switched.available)
    assert.are.equal("feature/review", switched.bound_to)
  end)

  it("does not bind detached commits", function()
    local stored = { comments = {} }

    local opened = session.open(stored, { kind = "commit", commit = "abc123" })
    assert.is_true(opened.available)
    assert.is_nil(opened.bound_to)

    session.bind(stored, { kind = "commit", commit = "abc123" })
    assert.is_nil(stored.session)
  end)

  it("refuses to bind when a binding already exists", function()
    local stored = { session = { binding = { kind = "branch", name = "feature/review" } }, comments = {} }

    local changed = session.bind(stored, { kind = "branch", name = "main" })

    assert.is_false(changed)
    assert.are.same({ kind = "branch", name = "feature/review" }, stored.session.binding)
  end)

  it("does not mutate data on open", function()
    local stored = { comments = { { id = "1" } } }

    session.open(stored, { kind = "branch", name = "feature/review" })

    assert.is_nil(stored.session)
    assert.are.same({ { id = "1" } }, stored.comments)
  end)
end)
