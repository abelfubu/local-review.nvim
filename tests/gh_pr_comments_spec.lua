---@diagnostic disable: undefined-global, undefined-field, duplicate-set-field
require("busted.runner")()

package.path = table.concat({
  "./lua/?.lua",
  "./lua/?/init.lua",
  package.path,
}, ";")

local dkjson = require("dkjson")

local function load_fixture(name)
  local path = "tests/fixtures/" .. name
  local f = io.open(path, "r")
  if not f then
    return nil
  end
  local content = f:read("*a")
  f:close()
  return content
end

local function parse_graphql_variables(command)
  local variables = {}
  for i = 1, #command do
    if command[i] == "-F" or command[i] == "-f" then
      local raw = command[i + 1]
      if raw then
        local key, value = raw:match("^([^=]+)=(.*)$")
        if key then
          variables[key] = value
        end
      end
    end
  end
  return variables
end

describe("gh_pr_comments", function()
  local module
  local processes
  local notifications
  local repo_slug
  local should_fail_repo_slug
  local next_system_error
  local next_system_result
  local graphql_handler
  local call_counts

  before_each(function()
    processes = {}
    notifications = {}
    repo_slug = "owner/repo"
    should_fail_repo_slug = false
    next_system_error = nil
    next_system_result = nil
    graphql_handler = nil
    call_counts = {}

    package.loaded["local_review.application.gh_pr_comments"] = nil
    package.loaded["local_review.domain.positioning"] = nil

    _G.vim = {
      log = { levels = { ERROR = 1, INFO = 2, WARN = 3 } },
      notify = function(message, level)
        table.insert(notifications, { message = message, level = level })
      end,
      trim = function(value)
        return (value or ""):match("^%s*(.-)%s*$")
      end,
      json = {
        decode = function(value)
          return dkjson.decode(value)
        end,
        encode = function(value)
          return dkjson.encode(value)
        end,
      },
      system = function(command, opts)
        local key = table.concat(command, " ")
        call_counts[key] = (call_counts[key] or 0) + 1
        table.insert(processes, { command = command, cwd = opts and opts.cwd })

        if command[1] == "gh" and command[2] == "repo" and command[3] == "view" then
          if should_fail_repo_slug then
            return {
              wait = function()
                return { code = 1, stdout = "", stderr = "no repo" }
              end,
            }
          end
          return {
            wait = function()
              return { code = 0, stdout = repo_slug .. "\n", stderr = "" }
            end,
          }
        end

        if next_system_error then
          local err = next_system_error
          next_system_error = nil
          return {
            wait = function()
              return { code = 1, stdout = "", stderr = err }
            end,
          }
        end

        if next_system_result then
          local result = next_system_result
          next_system_result = nil
          return {
            wait = function()
              return result
            end,
          }
        end

        if graphql_handler and command[1] == "gh" and command[2] == "api" and command[3] == "graphql" then
          local response = graphql_handler(command, parse_graphql_variables(command))
          return {
            wait = function()
              return { code = 0, stdout = vim.json.encode(response), stderr = "" }
            end,
          }
        end

        return {
          wait = function()
            return { code = 0, stdout = "", stderr = "" }
          end,
        }
      end,
    }

    module = require("local_review.application.gh_pr_comments")
    module._sleep = function() end
  end)

  after_each(function()
    _G.vim = nil
    package.loaded["local_review.application.gh_pr_comments"] = nil
    package.loaded["local_review.domain.positioning"] = nil
  end)

  describe("QUERY", function()
    it("is a non-empty GraphQL string", function()
      assert.is_string(module.QUERY)
      assert.is_truthy(module.QUERY:match("reviewThreads"))
      assert.is_truthy(module.QUERY:match("reviews"))
      assert.is_truthy(module.QUERY:match("pageInfo"))
      assert.is_truthy(module.QUERY:match("comments"))
      assert.is_truthy(module.QUERY:match("diffHunk"))
      assert.is_truthy(module.QUERY:match("submittedAt"))
    end)
  end)

  describe("validate", function()
    it("accepts a well-formed LINE thread", function()
      local node = {
        id = "t1",
        path = "lua/a.lua",
        diffSide = "RIGHT",
        subjectType = "LINE",
        comments = { nodes = {} },
      }
      assert.is_nil(module.validate(node))
    end)

    it("rejects a node without id", function()
      local node = {
        path = "lua/a.lua",
        diffSide = "RIGHT",
        comments = { nodes = {} },
      }
      assert.is_truthy(module.validate(node))
    end)

    it("rejects a node without path", function()
      local node = {
        id = "t1",
        diffSide = "RIGHT",
        comments = { nodes = {} },
      }
      assert.is_truthy(module.validate(node))
    end)

    it("rejects a node without diffSide", function()
      local node = {
        id = "t1",
        path = "lua/a.lua",
        comments = { nodes = {} },
      }
      assert.is_truthy(module.validate(node))
    end)

    it("rejects a node without comments.nodes", function()
      local node = {
        id = "t1",
        path = "lua/a.lua",
        diffSide = "RIGHT",
        comments = {},
      }
      assert.is_truthy(module.validate(node))
    end)
  end)

  describe("normalize", function()
    local ctx = { repository = "owner/repo", pull_number = 4, scope_root = "/repo" }

    local diff_hunk = table.concat({
      "@@ -1,5 +1,6 @@",
      " context one",
      "-context two",
      "+context two edited",
      "+added line",
      " context three",
      " context four",
    }, "\n")

    local function make_comment(id, overrides)
      overrides = overrides or {}
      return {
        id = id,
        body = overrides.body or "Please fix this.",
        author = { login = "reviewer" },
        url = "https://github.com/owner/repo/pull/4#discussion_r" .. id,
        createdAt = "2024-01-01T00:00:00Z",
        updatedAt = "2024-01-01T00:00:00Z",
        commit = { oid = "abc123" },
        pullRequestReview = { id = "review-" .. id },
        diffHunk = diff_hunk,
      }
    end

    local function make_thread(overrides)
      overrides = overrides or {}
      return {
        id = "thread-1",
        isResolved = overrides.isResolved or false,
        isOutdated = overrides.isOutdated or false,
        path = "lua/example.lua",
        subjectType = "LINE",
        line = overrides.line or 2,
        originalLine = overrides.originalLine or 2,
        startLine = overrides.startLine,
        originalStartLine = overrides.originalStartLine,
        diffSide = overrides.diffSide or "RIGHT",
        startDiffSide = overrides.startDiffSide,
        diffHunk = diff_hunk,
        comments = { nodes = { make_comment("comment-1") } },
      }
    end

    it("returns an empty list for non-LINE threads", function()
      local thread = make_thread()
      thread.subjectType = "FILE"
      assert.are.equal(0, #module.normalize(thread, ctx))
    end)

    it("returns an empty list when the line cannot be resolved", function()
      local thread = make_thread()
      thread.line = nil
      thread.originalLine = nil
      assert.are.equal(0, #module.normalize(thread, ctx))
    end)

    it("anchors a RIGHT-side comment at line", function()
      local comments = module.normalize(make_thread(), ctx)
      assert.are.equal(1, #comments)
      local c = comments[1]
      assert.are.equal("/repo/lua/example.lua", c.absolute_path)
      assert.are.equal("lua/example.lua", c.relative_path)
      assert.are.equal(2, c.anchor.line_number)
      assert.are.equal("context two edited", c.anchor.line_text)
      assert.is_nil(c.anchor_end)
      assert.is_nil(c.line_end)
    end)

    it("anchors a LEFT-side comment at originalLine", function()
      local comments = module.normalize(make_thread({ diffSide = "LEFT", line = nil, originalLine = 2 }), ctx)
      assert.are.equal(1, #comments)
      local c = comments[1]
      assert.are.equal(2, c.anchor.line_number)
      assert.are.equal("context two", c.anchor.line_text)
    end)

    it("uses diffHunk context for the anchor", function()
      local comments = module.normalize(make_thread(), ctx)
      local c = comments[1]
      assert.are.equal("context one", c.anchor.normalized_before_context[1])
      assert.are.equal("added line", c.anchor.normalized_after_context[1])
      assert.are.equal("context three", c.anchor.normalized_after_context[2])
    end)

    it("creates a range comment for start/end lines", function()
      local comments = module.normalize(
        make_thread({
          diffSide = "RIGHT",
          line = 3,
          startLine = 2,
          startDiffSide = "RIGHT",
        }),
        ctx
      )
      assert.are.equal(1, #comments)
      local c = comments[1]
      assert.are.equal(2, c.anchor.line_number)
      assert.are.equal(3, c.anchor_end.line_number)
      assert.are.equal(3, c.line_end)
      assert.are.equal("context two edited", c.anchor.line_text)
      assert.are.equal("added line", c.anchor_end.line_text)
    end)

    it("swaps reversed ranges so the anchor is the start", function()
      local comments = module.normalize(
        make_thread({
          diffSide = "RIGHT",
          line = 5,
          startLine = 2,
          startDiffSide = "RIGHT",
        }),
        ctx
      )
      local c = comments[1]
      assert.are.equal(2, c.anchor.line_number)
      assert.are.equal(5, c.anchor_end.line_number)
    end)

    it("sets remote metadata from the thread and comment", function()
      local comments = module.normalize(make_thread({ isResolved = false, isOutdated = true }), ctx)
      local c = comments[1]
      assert.are.equal("github", c.origin)
      assert.are.equal("gh:comment-1", c.id)
      assert.are.equal("owner/repo", c.remote.repository)
      assert.are.equal(4, c.remote.pull_number)
      assert.are.equal("thread-1", c.remote.thread_id)
      assert.are.equal("comment-1", c.remote.comment_id)
      assert.are.equal("review-comment-1", c.remote.review_id)
      assert.are.equal("reviewer", c.remote.author)
      assert.are.equal("abc123", c.remote.commit_id)
      assert.is_false(c.remote.resolved)
      assert.is_true(c.remote.outdated)
    end)
  end)

  describe("fetch", function()
    local function graphql_page(threads, has_next, cursor, reviews, reviews_has_next, reviews_cursor)
      return {
        data = {
          repository = {
            pullRequest = {
              reviewThreads = {
                pageInfo = { hasNextPage = has_next or false, endCursor = cursor },
                nodes = threads or {},
              },
              reviews = {
                pageInfo = { hasNextPage = reviews_has_next or false, endCursor = reviews_cursor },
                nodes = reviews or {},
              },
            },
          },
        },
      }
    end

    local function graphql_page_without_reviews(threads, has_next, cursor)
      return {
        data = {
          repository = {
            pullRequest = {
              reviewThreads = {
                pageInfo = { hasNextPage = has_next or false, endCursor = cursor },
                nodes = threads or {},
              },
            },
          },
        },
      }
    end

    local function reviews_page(nodes, has_next, cursor)
      return {
        data = {
          repository = {
            pullRequest = {
              reviewThreads = {
                pageInfo = { hasNextPage = false, endCursor = nil },
                nodes = {},
              },
              reviews = {
                pageInfo = { hasNextPage = has_next or false, endCursor = cursor },
                nodes = nodes or {},
              },
            },
          },
        },
      }
    end

    local function comments_page(nodes, has_next, cursor)
      return {
        data = {
          node = {
            comments = {
              pageInfo = { hasNextPage = has_next or false, endCursor = cursor },
              nodes = nodes or {},
            },
          },
        },
      }
    end

    local function make_review(id, overrides)
      overrides = overrides or {}
      return {
        id = id,
        body = overrides.body ~= nil and overrides.body or "Review body",
        state = overrides.state or "COMMENTED",
        url = "https://github.com/owner/repo/pull/4#" .. id,
        author = { login = overrides.author or "reviewer" },
        submittedAt = overrides.submittedAt or "2024-01-01T00:00:00Z",
      }
    end

    local function make_thread(id, overrides)
      overrides = overrides or {}
      return {
        id = id,
        isResolved = overrides.isResolved or false,
        isOutdated = false,
        path = "lua/example.lua",
        subjectType = "LINE",
        line = 2,
        diffSide = "RIGHT",
        comments = overrides.comments or {
          pageInfo = { hasNextPage = false },
          nodes = {
            {
              id = id .. "-c1",
              body = "comment",
              author = { login = "reviewer" },
              url = "https://example.com",
              createdAt = "2024-01-01T00:00:00Z",
              updatedAt = "2024-01-01T00:00:00Z",
              commit = { oid = "abc123" },
              pullRequestReview = { id = "review-" .. id },
              diffHunk = "@@ -1,2 +1,2 @@\n old\n+new",
            },
          },
        },
      }
    end

    it("returns PR review bodies alongside inline threads", function()
      graphql_handler = function(_, _)
        return graphql_page(
          {
            make_thread("t1"),
          },
          false,
          nil,
          {
            make_review("review-1"),
          }
        )
      end

      local result, err
      module.fetch("/repo", { number = 4 }, function(r, e)
        result = r
        err = e
      end)
      assert.is_nil(err)
      assert.are.equal(1, #result)
      assert.are.equal("gh:t1-c1", result[1].id)
      assert.is_not_nil(result.reviews)
      assert.are.equal(1, #result.reviews)
      assert.is_true(result.reviews_included)
      assert.are.equal("review-1", result.reviews[1].id)
      assert.are.equal("Review body", result.reviews[1].body)
      assert.are.equal("COMMENTED", result.reviews[1].state)
      assert.are.equal("reviewer", result.reviews[1].author)
      assert.are.equal("2024-01-01T00:00:00Z", result.reviews[1].submitted_at)
    end)

    it("paginates reviews", function()
      local page1 = {}
      for i = 1, 100 do
        page1[i] = make_review("r" .. i)
      end
      local page2 = { make_review("r101") }

      graphql_handler = function(_, variables)
        if not variables.reviewsCursor then
          return graphql_page({}, true, "c1", page1, true, "rc1")
        elseif variables.reviewsCursor == "rc1" then
          return graphql_page({}, false, nil, page2, false)
        end
        return {}
      end

      local result, err
      module.fetch("/repo", { number = 4 }, function(r, e)
        result = r
        err = e
      end)
      assert.is_nil(err)
      assert.are.equal(0, #result)
      assert.are.equal(101, #result.reviews)
      assert.is_true(result.reviews_included)
    end)

    it("errors when reviews pagination cursor does not advance", function()
      graphql_handler = function(_, _)
        return graphql_page({}, false, nil, { make_review("r1") }, true, "stuck")
      end

      local result, err
      module.fetch("/repo", { number = 4 }, function(r, e)
        result = r
        err = e
      end)
      assert.is_nil(result)
      assert.is_truthy(err)
      assert.matches("cursor did not advance", err)
      assert.matches("reviews", err)
    end)

    it("returns a single error when reviews pagination fails mid-way", function()
      local page1_reviews = { make_review("r1") }

      graphql_handler = function(_, variables)
        if variables.reviewsCursor == nil then
          next_system_error = "HTTP 500: boom"
          return graphql_page({}, false, nil, page1_reviews, true, "rc1")
        end
        return {}
      end

      local result, err
      module.fetch("/repo", { number = 4 }, function(r, e)
        result = r
        err = e
      end)
      assert.is_nil(result)
      assert.is_truthy(err)
      assert.matches("HTTP 500", err)
    end)

    it("filters reviews: drops empty body and PENDING, keeps other states", function()
      graphql_handler = function(_, _)
        return graphql_page({}, false, nil, {
          make_review("empty-body", { body = "" }),
          make_review("pending", { state = "PENDING" }),
          make_review("approved", { state = "APPROVED", body = "LGTM" }),
          make_review("changes", { state = "CHANGES_REQUESTED", body = "Please fix" }),
        })
      end

      local result, err
      module.fetch("/repo", { number = 4 }, function(r, e)
        result = r
        err = e
      end)
      assert.is_nil(err)
      assert.are.equal(2, #result.reviews)
      local ids = {}
      for _, review in ipairs(result.reviews) do
        ids[review.id] = true
      end
      assert.is_true(ids["approved"])
      assert.is_true(ids["changes"])
      assert.is_nil(ids["empty-body"])
      assert.is_nil(ids["pending"])
    end)

    it("returns an empty result for a PR with no review threads", function()
      next_system_result = { code = 0, stdout = vim.json.encode(graphql_page({}, false)), stderr = "" }
      local result, err
      module.fetch("/repo", { number = 4 }, function(r, e)
        result = r
        err = e
      end)
      assert.is_nil(err)
      assert.are.equal(0, #result)
      assert.is_true(result.reviews_included)
    end)

    it("sets reviews_included false when the reviews field is absent", function()
      graphql_handler = function(_, _)
        return graphql_page_without_reviews({
          make_thread("t1"),
        }, false)
      end

      local result, err
      module.fetch("/repo", { number = 4 }, function(r, e)
        result = r
        err = e
      end)
      assert.is_nil(err)
      assert.are.equal(1, #result)
      assert.is_not_nil(result.reviews)
      assert.are.equal(0, #result.reviews)
      assert.is_false(result.reviews_included)
    end)

    it("sorts review bodies by submittedAt descending", function()
      graphql_handler = function(_, _)
        return graphql_page({ make_thread("t1") }, false, nil, {
          make_review("older", { submittedAt = "2024-01-01T00:00:00Z" }),
          make_review("newer", { submittedAt = "2024-03-01T00:00:00Z" }),
          make_review("middle", { submittedAt = "2024-02-01T00:00:00Z" }),
        })
      end

      local result, err
      module.fetch("/repo", { number = 4 }, function(r, e)
        result = r
        err = e
      end)
      assert.is_nil(err)
      assert.are.equal(3, #result.reviews)
      assert.are.equal("newer", result.reviews[1].id)
      assert.are.equal("middle", result.reviews[2].id)
      assert.are.equal("older", result.reviews[3].id)
    end)

    it("paginates review threads", function()
      local page1 = {}
      for i = 1, 100 do
        page1[i] = make_thread("t" .. i)
      end
      local page2 = { make_thread("t101") }

      local call_count = 0
      graphql_handler = function(_, variables)
        local is_threads_query = variables.pr ~= nil
        if not is_threads_query then
          return {}
        end

        call_count = call_count + 1
        if not variables.threadsCursor then
          return graphql_page(page1, true, "c1")
        elseif variables.threadsCursor == "c1" then
          return graphql_page(page2, false)
        end
        return {}
      end

      local result, err
      module.fetch("/repo", { number = 4 }, function(r, e)
        result = r
        err = e
      end)
      assert.is_nil(err)
      assert.are.equal(101, #result)
    end)

    it("errors when review thread pagination cursor does not advance", function()
      graphql_handler = function(_, variables)
        if variables.pr then
          return graphql_page({ make_thread("t1") }, true, "stuck")
        end
        return {}
      end

      local result, err
      module.fetch("/repo", { number = 4 }, function(r, e)
        result = r
        err = e
      end)
      assert.is_nil(result)
      assert.is_truthy(err)
      assert.matches("cursor did not advance", err)
    end)

    it("does not duplicate threads when reviews paginate past a completed thread page", function()
      local thread = make_thread("t1")
      local reviews_page1 = {}
      for i = 1, 100 do
        reviews_page1[i] = make_review("r" .. i)
      end
      local reviews_page2 = { make_review("r101") }

      graphql_handler = function(_, variables)
        local is_threads_query = variables.pr ~= nil
        if not is_threads_query then
          return {}
        end

        if not variables.threadsCursor and not variables.reviewsCursor then
          return graphql_page({ thread }, false, nil, reviews_page1, true, "rc1")
        elseif variables.reviewsCursor == "rc1" then
          return graphql_page({ thread }, false, nil, reviews_page2, false)
        end
        return {}
      end

      local result, err
      module.fetch("/repo", { number = 4 }, function(r, e)
        result = r
        err = e
      end)
      assert.is_nil(err)
      assert.are.equal(1, #result)
      assert.are.equal("gh:t1-c1", result[1].id)

      local review_ids = {}
      for _, review in ipairs(result.reviews) do
        assert.is_nil(review_ids[review.id])
        review_ids[review.id] = true
      end
      assert.are.equal(101, #result.reviews)
      assert.is_true(review_ids["r1"])
      assert.is_true(review_ids["r101"])
    end)

    it("does not duplicate reviews when threads paginate past a completed review page", function()
      local review = make_review("r1")
      local threads_page1 = {}
      for i = 1, 100 do
        threads_page1[i] = make_thread("t" .. i)
      end
      local threads_page2 = { make_thread("t101") }

      graphql_handler = function(_, variables)
        local is_threads_query = variables.pr ~= nil
        if not is_threads_query then
          return {}
        end

        if not variables.threadsCursor and not variables.reviewsCursor then
          return graphql_page(threads_page1, true, "c1", { review }, false)
        elseif variables.threadsCursor == "c1" then
          return graphql_page(threads_page2, false, nil, { review }, false)
        end
        return {}
      end

      local result, err
      module.fetch("/repo", { number = 4 }, function(r, e)
        result = r
        err = e
      end)
      assert.is_nil(err)
      assert.are.equal(101, #result)

      local thread_ids = {}
      for _, comment in ipairs(result) do
        assert.is_nil(thread_ids[comment.remote.thread_id])
        thread_ids[comment.remote.thread_id] = true
      end
      assert.is_true(thread_ids["t1"])
      assert.is_true(thread_ids["t101"])
      assert.are.equal(1, #result.reviews)
      assert.are.equal("r1", result.reviews[1].id)
    end)

    it("paginates nested comments on a thread", function()
      local thread = make_thread("t1", {
        comments = {
          pageInfo = { hasNextPage = true, endCursor = "cc1" },
          nodes = {
            {
              id = "c1",
              body = "first",
              author = { login = "a" },
              url = "u1",
              createdAt = "2024-01-01T00:00:00Z",
              updatedAt = "2024-01-01T00:00:00Z",
              commit = { oid = "abc" },
              pullRequestReview = { id = "r1" },
              diffHunk = "@@ -1,2 +1,2 @@\n old\n+new",
            },
          },
        },
      })

      local extra_comment = {
        id = "c2",
        body = "second",
        author = { login = "a" },
        url = "u2",
        createdAt = "2024-01-01T00:00:00Z",
        updatedAt = "2024-01-01T00:00:00Z",
        commit = { oid = "abc" },
        pullRequestReview = { id = "r1" },
        diffHunk = "@@ -1,2 +1,2 @@\n old\n+new",
      }

      graphql_handler = function(_, variables)
        if variables.pr then
          return graphql_page({ thread }, false)
        elseif variables.id == "t1" and variables.cursor == "cc1" then
          return comments_page({ extra_comment }, false)
        end
        return {}
      end

      local result, err
      module.fetch("/repo", { number = 4 }, function(r, e)
        result = r
        err = e
      end)
      assert.is_nil(err)
      assert.are.equal(2, #result)
      assert.are.equal("gh:c1", result[1].id)
      assert.are.equal("gh:c2", result[2].id)
    end)

    it("errors when nested comment pagination cursor does not advance", function()
      local thread = make_thread("t1", {
        comments = {
          pageInfo = { hasNextPage = true, endCursor = "cc1" },
          nodes = {
            {
              id = "c1",
              body = "first",
              author = { login = "a" },
              url = "u1",
              createdAt = "2024-01-01T00:00:00Z",
              updatedAt = "2024-01-01T00:00:00Z",
              commit = { oid = "abc" },
              pullRequestReview = { id = "r1" },
              diffHunk = "@@ -1,2 +1,2 @@\n old\n+new",
            },
          },
        },
      })

      local extra_comment = {
        id = "c2",
        body = "second",
        author = { login = "a" },
        url = "u2",
        createdAt = "2024-01-01T00:00:00Z",
        updatedAt = "2024-01-01T00:00:00Z",
        commit = { oid = "abc" },
        pullRequestReview = { id = "r1" },
        diffHunk = "@@ -1,2 +1,2 @@\n old\n+new",
      }

      graphql_handler = function(_, variables)
        if variables.pr then
          return graphql_page({ thread }, false)
        elseif variables.id == "t1" and variables.cursor == "cc1" then
          return comments_page({ extra_comment }, true, "cc1")
        end
        return {}
      end

      local result, err
      module.fetch("/repo", { number = 4 }, function(r, e)
        result = r
        err = e
      end)
      assert.is_nil(result)
      assert.is_truthy(err)
      assert.matches("cursor did not advance", err)
    end)

    it("returns a single error on mid-pagination failure", function()
      local page1 = { make_thread("t1") }

      graphql_handler = function(_, variables)
        if variables.pr and not variables.threadsCursor then
          next_system_error = "HTTP 500: boom"
          return graphql_page(page1, true, "c1")
        end
        return {}
      end

      local result, err
      module.fetch("/repo", { number = 4 }, function(r, e)
        result = r
        err = e
      end)
      assert.is_nil(result)
      assert.is_truthy(err)
    end)

    it("retries a transient 403 error and then succeeds", function()
      next_system_error = "HTTP 403: API rate limit"
      next_system_result =
        { code = 0, stdout = vim.json.encode(graphql_page({ make_thread("t1") }, false)), stderr = "" }

      local result, err
      module.fetch("/repo", { number = 4 }, function(r, e)
        result = r
        err = e
      end)
      assert.is_nil(err)
      assert.are.equal(1, #result)
    end)

    it("uses exponential backoff in seconds on transient errors", function()
      local sleeps = {}
      module._sleep = function(seconds)
        table.insert(sleeps, seconds)
      end

      next_system_error = "HTTP 403: API rate limit"
      next_system_result =
        { code = 0, stdout = vim.json.encode(graphql_page({ make_thread("t1") }, false)), stderr = "" }

      local result, err
      module.fetch("/repo", { number = 4 }, function(r, e)
        result = r
        err = e
      end)
      assert.is_nil(err)
      assert.are.equal(1, #result)
      assert.are.equal(1, #sleeps)
      assert.are.near(1.0, sleeps[1], 0.001)
    end)

    it("filters out resolved threads", function()
      next_system_result = {
        code = 0,
        stdout = vim.json.encode(graphql_page({
          make_thread("t1", { isResolved = false }),
          make_thread("t2", { isResolved = true }),
        }, false)),
        stderr = "",
      }
      local result, err
      module.fetch("/repo", { number = 4 }, function(r, e)
        result = r
        err = e
      end)
      assert.is_nil(err)
      assert.are.equal(1, #result)
      assert.are.equal("gh:t1-c1", result[1].id)
    end)

    it("returns an error when the repository slug cannot be determined", function()
      should_fail_repo_slug = true
      local result, err
      module.fetch("/repo", { number = 4 }, function(r, e)
        result = r
        err = e
      end)
      assert.is_nil(result)
      assert.is_truthy(err)
    end)

    it("runs gh commands in the requested scope root", function()
      next_system_result = { code = 0, stdout = vim.json.encode(graphql_page({}, false)), stderr = "" }
      module.fetch("/repo", { number = 4 }, function() end)
      for _, process in ipairs(processes) do
        assert.are.equal("/repo", process.cwd)
      end
    end)

    it("passes owner, repo, and pr variables to the graphql query", function()
      local captured
      graphql_handler = function(_, variables)
        captured = variables
        return graphql_page({ make_thread("t1") }, false)
      end
      local result, err
      module.fetch("/repo", { number = 4 }, function(r, e)
        result = r
        err = e
      end)
      assert.is_nil(err)
      assert.is_not_nil(captured)
      assert.are.equal("owner", captured.owner)
      assert.are.equal("repo", captured.repo)
      assert.are.equal("4", captured.pr)
      assert.are.equal("gh:t1-c1", result[1].id)
    end)

    it("sends string GraphQL variables as raw strings and pr as an integer", function()
      local function find_pair(command, flag, prefix)
        for i = 1, #command - 1 do
          if command[i] == flag and command[i + 1]:match("^" .. prefix) then
            return true
          end
        end
        return false
      end

      graphql_handler = function()
        return graphql_page({ make_thread("t1") }, false)
      end

      local result, err
      module.fetch("/repo", { number = 4 }, function(r, e)
        result = r
        err = e
      end)
      assert.is_nil(err)

      local graphql_cmd
      for _, process in ipairs(processes) do
        if process.command[1] == "gh" and process.command[2] == "api" and process.command[3] == "graphql" then
          graphql_cmd = process.command
          break
        end
      end
      assert.is_not_nil(graphql_cmd)

      assert.is_true(find_pair(graphql_cmd, "-f", "owner=owner"))
      assert.is_true(find_pair(graphql_cmd, "-f", "repo=repo"))
      assert.is_true(find_pair(graphql_cmd, "-F", "pr=4"))
    end)
  end)

  describe("captured fixture", function()
    it("loads the PR #4 fixture without threads", function()
      local content = load_fixture("pr_threads.json")
      assert.is_truthy(content)
      local ok, decoded = pcall(vim.json.decode, content)
      assert.is_true(ok)
      local threads = decoded.data.repository.pullRequest.reviewThreads.nodes
      assert.are.equal(0, #threads)
    end)
  end)
end)
