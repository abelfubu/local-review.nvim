-- Deterministic cross-process atomicity smoke tests for storage.save_scope.
--
-- These tests exercise the per-scope directory lock, atomic temp+rename, and
-- stale-lock recovery using real child Neovim processes and filesystem
-- markers as barriers.  No scheduler-dependent sleeps are used for ordering
-- assertions.

local plugin_root = vim.uv.cwd()
vim.opt.runtimepath:append(plugin_root)

local storage_dir = vim.fn.tempname() .. "_storage_atomic"
vim.fn.mkdir(storage_dir, "p")

require("local_review").setup({ storage_dir = storage_dir })

local storage = require("local_review.storage")
local session = require("local_review.session")

local barrier_dir = vim.fn.tempname() .. "_barriers"
vim.fn.mkdir(barrier_dir, "p")

local function marker(name)
  return vim.fs.joinpath(barrier_dir, name)
end

local function set_marker(path)
  vim.fn.writefile({}, path)
end

local function clear_marker(path)
  if vim.fn.filereadable(path) == 1 then
    vim.fn.delete(path)
  end
end

local function wait_marker(path, timeout_ms)
  return vim.wait(timeout_ms or 10000, function()
    return vim.fn.filereadable(path) == 1
  end, 50)
end

local function assert_no_artifacts(label)
  local entries = vim.fn.glob(vim.fs.joinpath(storage_dir, "*"), false, true)
  for _, entry in ipairs(entries) do
    local basename = vim.fn.fnamemodify(entry, ":t")
    assert(
      not (basename:match("%.lock$") or basename:match("%.tmp$") or basename:match("%.stale%.")),
      string.format("%s: leftover artifact %s", label, entry)
    )
  end
end

local function spawn_child(script, timeout_ms)
  local path = vim.fn.tempname() .. "_child.lua"
  vim.fn.writefile(vim.split(script, "\n"), path)
  return vim.system({
    "nvim",
    "--headless",
    "--clean",
    "-u",
    "NONE",
    "-l",
    path,
  })
end

local function read_done(path)
  assert(vim.fn.filereadable(path) == 1, "missing child result file: " .. path)
  local lines = vim.fn.readfile(path)
  local ok, decoded = pcall(vim.json.decode, table.concat(lines, "\n"))
  assert(ok and type(decoded) == "table", "invalid child result file: " .. path)
  return decoded
end

local function run_binding_race()
  local scope_root = vim.fn.tempname() .. "_binding_race_scope"
  local locked_a = marker("locked_a")
  local release_a = marker("release_a")
  local done_a = marker("done_a")
  local done_b = marker("done_b")

  for _, m in ipairs({ locked_a, release_a, done_a, done_b }) do
    clear_marker(m)
  end

  local script_a = string.format(
    [[
vim.opt.runtimepath:append(%q)
require("local_review").setup({ storage_dir = %q })
local storage = require("local_review.storage")
local session = require("local_review.session")
local scope_root = %q
storage._test_hooks.after_lock_acquire = function(sr)
  if sr == scope_root then
    vim.fn.writefile({}, %q)
    vim.wait(10000, function() return vim.fn.filereadable(%q) == 1 end, 50)
  end
end
local data = storage.load_scope(scope_root)
table.insert(data.comments, { id = "comment-a", body = "from A", absolute_path = "/tmp/a.txt" })
session.bind(data, { kind = "branch", name = "feature/a" })
local ok, err = storage.save_scope(scope_root, data)
vim.fn.writefile({ vim.json.encode({ ok = ok == true, err = err or vim.NIL }) }, %q)
]],
    plugin_root,
    storage_dir,
    scope_root,
    locked_a,
    release_a,
    done_a
  )

  local script_b = string.format(
    [[
vim.opt.runtimepath:append(%q)
require("local_review").setup({ storage_dir = %q })
local storage = require("local_review.storage")
local session = require("local_review.session")
local scope_root = %q
vim.wait(10000, function() return vim.fn.filereadable(%q) == 1 end, 50)
local data = storage.load_scope(scope_root)
table.insert(data.comments, { id = "comment-b", body = "from B", absolute_path = "/tmp/b.txt" })
session.bind(data, { kind = "branch", name = "feature/b" })
local ok, err = storage.save_scope(scope_root, data)
vim.fn.writefile({ vim.json.encode({ ok = ok == true, err = err or vim.NIL }) }, %q)
]],
    plugin_root,
    storage_dir,
    scope_root,
    locked_a,
    done_b
  )

  local proc_a = spawn_child(script_a)
  assert(wait_marker(locked_a, 10000), "child A did not acquire the lock")

  local proc_b = spawn_child(script_b)
  local b_finished_early = vim.wait(1000, function()
    return vim.fn.filereadable(done_b) == 1
  end, 50)
  assert(not b_finished_early, "child B finished while child A held the lock")

  set_marker(release_a)

  local res_a = proc_a:wait(20000)
  local res_b = proc_b:wait(20000)
  assert(res_a and res_a.code == 0, "child A failed: " .. (res_a and res_a.stderr or "unknown"))
  assert(res_b and res_b.code == 0, "child B failed: " .. (res_b and res_b.stderr or "unknown"))

  local result_a = read_done(done_a)
  local result_b = read_done(done_b)

  assert(result_a.ok, "child A save should succeed: " .. tostring(result_a.err))
  assert(not result_b.ok, "child B save should be rejected")
  assert(
    result_b.err and result_b.err:match("feature/a"),
    "child B error should name the bound branch: " .. tostring(result_b.err)
  )

  local final = storage.load_scope(scope_root)
  assert(
    final.session and final.session.binding and final.session.binding.name == "feature/a",
    "winner binding should be feature/a"
  )
  local ids = {}
  for _, c in ipairs(final.comments) do
    ids[c.id] = (ids[c.id] or 0) + 1
  end
  assert(ids["comment-a"] == 1, "winner comment should survive exactly once")
  assert(ids["comment-b"] == nil, "loser comment should not be persisted")

  assert_no_artifacts("binding race")
end

local function run_same_branch_race()
  local scope_root = vim.fn.tempname() .. "_same_branch_scope"
  local locked_a = marker("locked_a2")
  local release_a = marker("release_a2")
  local done_a = marker("done_a2")
  local done_b = marker("done_b2")

  for _, m in ipairs({ locked_a, release_a, done_a, done_b }) do
    clear_marker(m)
  end

  local script_a = string.format(
    [[
vim.opt.runtimepath:append(%q)
require("local_review").setup({ storage_dir = %q })
local storage = require("local_review.storage")
local session = require("local_review.session")
local scope_root = %q
storage._test_hooks.after_lock_acquire = function(sr)
  if sr == scope_root then
    vim.fn.writefile({}, %q)
    vim.wait(10000, function() return vim.fn.filereadable(%q) == 1 end, 50)
  end
end
local data = storage.load_scope(scope_root)
table.insert(data.comments, { id = "comment-a", body = "from A", absolute_path = "/tmp/a.txt" })
session.bind(data, { kind = "branch", name = "feature/x" })
local ok, err = storage.save_scope(scope_root, data)
vim.fn.writefile({ vim.json.encode({ ok = ok == true, err = err or vim.NIL }) }, %q)
]],
    plugin_root,
    storage_dir,
    scope_root,
    locked_a,
    release_a,
    done_a
  )

  local script_b = string.format(
    [[
vim.opt.runtimepath:append(%q)
require("local_review").setup({ storage_dir = %q })
local storage = require("local_review.storage")
local session = require("local_review.session")
local scope_root = %q
vim.wait(10000, function() return vim.fn.filereadable(%q) == 1 end, 50)
local data = storage.load_scope(scope_root)
table.insert(data.comments, { id = "comment-b", body = "from B", absolute_path = "/tmp/b.txt" })
session.bind(data, { kind = "branch", name = "feature/x" })
local ok, err = storage.save_scope(scope_root, data)
vim.fn.writefile({ vim.json.encode({ ok = ok == true, err = err or vim.NIL }) }, %q)
]],
    plugin_root,
    storage_dir,
    scope_root,
    locked_a,
    done_b
  )

  local proc_a = spawn_child(script_a)
  assert(wait_marker(locked_a, 10000), "child A did not acquire the lock")

  local proc_b = spawn_child(script_b)
  local b_finished_early = vim.wait(1000, function()
    return vim.fn.filereadable(done_b) == 1
  end, 50)
  assert(not b_finished_early, "child B finished while child A held the lock")

  set_marker(release_a)

  local res_a = proc_a:wait(20000)
  local res_b = proc_b:wait(20000)
  assert(res_a and res_a.code == 0, "child A failed: " .. (res_a and res_a.stderr or "unknown"))
  assert(res_b and res_b.code == 0, "child B failed: " .. (res_b and res_b.stderr or "unknown"))

  local result_a = read_done(done_a)
  local result_b = read_done(done_b)
  assert(result_a.ok, "child A save should succeed: " .. tostring(result_a.err))
  assert(result_b.ok, "child B same-branch save should succeed: " .. tostring(result_b.err))

  local final = storage.load_scope(scope_root)
  assert(
    final.session and final.session.binding and final.session.binding.name == "feature/x",
    "binding should be feature/x"
  )
  local ids = {}
  for _, c in ipairs(final.comments) do
    ids[c.id] = (ids[c.id] or 0) + 1
  end
  assert(ids["comment-a"] == 1 and ids["comment-b"] == 1, "both comments should survive exactly once")

  -- JSON must be decodable (atomic rename exposes only complete files).
  local path = storage.scope_file(scope_root)
  local raw = table.concat(vim.fn.readfile(path), "\n")
  local decode_ok = pcall(vim.json.decode, raw)
  assert(decode_ok, "persisted JSON should be valid after concurrent saves")

  assert_no_artifacts("same-branch race")
end

local function run_dead_lock_recovery()
  local scope_root = vim.fn.tempname() .. "_dead_lock_scope"
  local path = storage.scope_file(scope_root)
  local lock = path .. ".lock"

  assert(vim.uv.fs_mkdir(lock, 448), "failed to seed dead lock directory")
  vim.fn.writefile({ vim.json.encode({ pid = 99999999, token = "dead-token", created_at = 0 }) }, lock .. "/owner.json")

  local data = storage.load_scope(scope_root)
  table.insert(data.comments, { id = "dead-comment", body = "after recovery", absolute_path = "/tmp/d.txt" })
  session.bind(data, { kind = "branch", name = "feature/recovered" })
  local ok, err = storage.save_scope(scope_root, data)
  assert(ok, "save should reclaim dead lock: " .. tostring(err))

  local final = storage.load_scope(scope_root)
  assert(final.session.binding.name == "feature/recovered", "binding should be persisted after recovery")
  assert_no_artifacts("dead lock recovery")
end

local function run_live_lock_timeout()
  local scope_root = vim.fn.tempname() .. "_live_lock_scope"
  local path = storage.scope_file(scope_root)
  local lock = path .. ".lock"

  assert(vim.uv.fs_mkdir(lock, 448), "failed to seed live lock directory")
  vim.fn.writefile(
    { vim.json.encode({ pid = vim.uv.os_getpid(), token = "live-token", created_at = os.time() }) },
    lock .. "/owner.json"
  )

  storage._test_config.lock_timeout_ms = 200
  local data = storage.load_scope(scope_root)
  session.bind(data, { kind = "branch", name = "feature/timeout" })
  local ok, err = storage.save_scope(scope_root, data)
  storage._test_config.lock_timeout_ms = nil

  assert(not ok, "save should time out against a live owner")
  assert(err and err:match("Timed out"), "error should report a timeout: " .. tostring(err))
  assert(vim.fn.isdirectory(lock) == 1, "live lock should not be stolen")
  vim.fn.delete(lock, "rf")
  assert_no_artifacts("live lock timeout")
end

local function run_ownerless_stale_lock_recovery()
  local scope_root = vim.fn.tempname() .. "_ownerless_lock_scope"
  local path = storage.scope_file(scope_root)
  local lock = path .. ".lock"

  assert(vim.uv.fs_mkdir(lock, 448), "failed to seed ownerless lock directory")
  local utime_ok = vim.uv.fs_utime(lock, 0, 0)
  assert(utime_ok, "failed to age ownerless lock")

  local data = storage.load_scope(scope_root)
  table.insert(data.comments, { id = "ownerless-comment", body = "after recovery", absolute_path = "/tmp/o.txt" })
  session.bind(data, { kind = "branch", name = "feature/ownerless" })
  local ok, err = storage.save_scope(scope_root, data)
  assert(ok, "save should reclaim ownerless stale lock: " .. tostring(err))

  local final = storage.load_scope(scope_root)
  assert(final.session.binding.name == "feature/ownerless", "binding should be persisted after ownerless recovery")
  assert_no_artifacts("ownerless stale lock recovery")
end

local function run_sequential_binding_rules()
  local scope_a = vim.fn.tempname() .. "_seq_scope_a"
  local first_a = { comments = {} }
  session.bind(first_a, { kind = "branch", name = "feature/a" })
  assert(storage.save_scope(scope_a, first_a) == true, "first save to scope_a should succeed")

  local second_a = { comments = {} }
  session.bind(second_a, { kind = "branch", name = "feature/b" })
  local ok_a, err_a = storage.save_scope(scope_a, second_a)
  assert(ok_a == nil, "second conflicting save to scope_a should be rejected")
  assert(err_a and err_a:match("feature/a"), "error should name the bound branch for scope_a: " .. tostring(err_a))

  local scope_b = vim.fn.tempname() .. "_seq_scope_b"
  local first_b = { comments = {} }
  session.bind(first_b, { kind = "branch", name = "feature/x" })
  assert(storage.save_scope(scope_b, first_b) == true, "first save to scope_b should succeed")

  local second_b = { comments = {} }
  session.bind(second_b, { kind = "branch", name = "feature/x" })
  assert(storage.save_scope(scope_b, second_b) == true, "same-branch save to scope_b should succeed")

  local scope_c = vim.fn.tempname() .. "_seq_scope_c"
  local first_c = { comments = {} }
  session.bind(first_c, { kind = "branch", name = "feature/y" })
  assert(storage.save_scope(scope_c, first_c) == true, "first save to scope_c should succeed")

  local late_c = { comments = {} }
  local ok_c, err_c = storage.save_scope(scope_c, late_c)
  assert(ok_c == nil, "unbound save to scope_c should be rejected")
  assert(err_c and err_c:match("feature/y"), "error should name the bound branch for scope_c: " .. tostring(err_c))

  assert_no_artifacts("sequential binding rules")
end

local function run_rejection_leaves_no_artifacts()
  local scope_root = vim.fn.tempname() .. "_rejection_scope"
  local first = storage.load_scope(scope_root)
  table.insert(first.comments, { id = "first", body = "first", absolute_path = "/tmp/f.txt" })
  session.bind(first, { kind = "branch", name = "feature/owned" })
  assert(storage.save_scope(scope_root, first) == true, "first binding save should succeed")

  local second = { comments = {} }
  table.insert(second.comments, { id = "second", body = "second", absolute_path = "/tmp/s.txt" })
  second.session = { binding = { kind = "branch", name = "feature/other" } }
  local ok, err = storage.save_scope(scope_root, second)
  assert(not ok, "conflicting binding should be rejected")
  assert(err and err:match("feature/owned"), "error should name the bound branch: " .. tostring(err))
  assert_no_artifacts("binding rejection")
end

local function run_injected_write_failure()
  local scope_root = vim.fn.tempname() .. "_write_failure_scope"
  local data = storage.load_scope(scope_root)
  table.insert(data.comments, { id = "wf", body = "write failure", absolute_path = "/tmp/wf.txt" })
  session.bind(data, { kind = "branch", name = "feature/writefail" })

  storage._test_hooks.fail_write = true
  local ok, err = storage.save_scope(scope_root, data)
  storage._test_hooks.fail_write = nil

  assert(not ok, "write failure should be rejected")
  assert(err and err:match("injected write failure"), "error should mention injected write failure: " .. tostring(err))
  assert_no_artifacts("injected write failure")

  local retry_ok, retry_err = storage.save_scope(scope_root, data)
  assert(retry_ok, "save after write failure should succeed: " .. tostring(retry_err))
  assert_no_artifacts("after write failure recovery")
end

local function run_injected_rename_failure()
  local scope_root = vim.fn.tempname() .. "_rename_failure_scope"
  local data = storage.load_scope(scope_root)
  table.insert(data.comments, { id = "rf", body = "rename failure", absolute_path = "/tmp/rf.txt" })
  session.bind(data, { kind = "branch", name = "feature/renamefail" })

  storage._test_hooks.fail_rename = true
  local ok, err = storage.save_scope(scope_root, data)
  storage._test_hooks.fail_rename = nil

  assert(not ok, "rename failure should be rejected")
  assert(
    err and err:match("injected rename failure"),
    "error should mention injected rename failure: " .. tostring(err)
  )
  assert_no_artifacts("injected rename failure")

  local retry_ok, retry_err = storage.save_scope(scope_root, data)
  assert(retry_ok, "save after rename failure should succeed: " .. tostring(retry_err))
  assert_no_artifacts("after rename failure recovery")
end

local function run_lock_cleanup_without_temp()
  local scope_root = vim.fn.tempname() .. "_lock_cleanup_scope"
  local data = storage.load_scope(scope_root)
  table.insert(data.comments, { id = "lc", body = "lock cleanup", absolute_path = "/tmp/lc.txt" })
  session.bind(data, { kind = "branch", name = "feature/lockcleanup" })

  storage._test_hooks.after_lock_acquire = function()
    error("injected lock body failure")
  end
  local ok, err = storage.save_scope(scope_root, data)
  storage._test_hooks.after_lock_acquire = nil

  assert(not ok, "lock body failure should be rejected")
  assert(
    err and err:match("injected lock body failure"),
    "error should mention injected lock body failure: " .. tostring(err)
  )
  assert_no_artifacts("lock cleanup without temp")

  local retry_ok, retry_err = storage.save_scope(scope_root, data)
  assert(retry_ok, "save after lock body failure should succeed: " .. tostring(retry_err))
  assert_no_artifacts("after lock cleanup recovery")
end

local function run_injected_owner_write_failure()
  local scope_root = vim.fn.tempname() .. "_owner_write_failure_scope"
  local data = storage.load_scope(scope_root)
  table.insert(data.comments, { id = "owf", body = "owner write failure", absolute_path = "/tmp/owf.txt" })
  session.bind(data, { kind = "branch", name = "feature/ownerwritefail" })

  storage._test_hooks.fail_owner_write = true
  local ok, res, err = pcall(storage.save_scope, scope_root, data)
  storage._test_hooks.fail_owner_write = nil

  assert(ok, "save_scope should not throw on owner write failure: " .. tostring(res))
  assert(res == nil, "owner write failure should return nil")
  assert(
    err and err:match("injected owner write failure"),
    "error should mention injected owner write failure: " .. tostring(err)
  )
  assert(vim.fn.isdirectory(storage.scope_file(scope_root) .. ".lock") == 0, "canonical lock should be absent")
  assert_no_artifacts("owner write failure")

  local retry_ok, retry_err = storage.save_scope(scope_root, data)
  assert(retry_ok, "save after owner write failure should succeed: " .. tostring(retry_err))
  assert_no_artifacts("after owner write failure recovery")
end

local function run_release_owner_read_throw_success()
  local scope_root = vim.fn.tempname() .. "_release_read_throw_success_scope"
  local data = storage.load_scope(scope_root)
  table.insert(data.comments, { id = "rrts", body = "release read throw success", absolute_path = "/tmp/rrts.txt" })
  session.bind(data, { kind = "branch", name = "feature/releasereadsuccess" })

  storage._test_hooks.fail_release_owner_read = true
  local ok, res, err = pcall(storage.save_scope, scope_root, data)
  storage._test_hooks.fail_release_owner_read = nil

  assert(ok, "save_scope should not throw on release owner read failure: " .. tostring(res))
  assert(res == true, "successful body should remain true despite release failure: " .. tostring(err))

  local lock = storage.scope_file(scope_root) .. ".lock"
  assert(vim.fn.isdirectory(lock) == 0, "canonical lock should be quarantined")

  local tomb
  for _, entry in ipairs(vim.fn.glob(vim.fs.joinpath(storage_dir, "*"), false, true)) do
    if entry:match("%.stale%.") then
      tomb = entry
      break
    end
  end
  assert(tomb, "quarantined tomb should exist after release owner read failure")
  vim.fn.delete(tomb, "rf")

  local final = storage.load_scope(scope_root)
  assert(
    final.session and final.session.binding and final.session.binding.name == "feature/releasereadsuccess",
    "persisted binding should survive release read failure"
  )
  assert_no_artifacts("release owner read throw success")
end

local function run_release_owner_read_throw_failure()
  local scope_root = vim.fn.tempname() .. "_release_read_throw_failure_scope"
  local data = storage.load_scope(scope_root)
  table.insert(data.comments, { id = "rrtf", body = "release read throw failure", absolute_path = "/tmp/rrtf.txt" })
  session.bind(data, { kind = "branch", name = "feature/releasereadfail" })

  storage._test_hooks.fail_write = true
  storage._test_hooks.fail_release_owner_read = true
  local ok, res, err = pcall(storage.save_scope, scope_root, data)
  storage._test_hooks.fail_write = nil
  storage._test_hooks.fail_release_owner_read = nil

  assert(ok, "save_scope should not throw on combined failure: " .. tostring(res))
  assert(res == nil, "combined failure should return nil")
  assert(err and err:match("injected write failure"), "original write error should survive: " .. tostring(err))

  local lock = storage.scope_file(scope_root) .. ".lock"
  assert(vim.fn.isdirectory(lock) == 0, "canonical lock should be quarantined")

  local tomb
  for _, entry in ipairs(vim.fn.glob(vim.fs.joinpath(storage_dir, "*"), false, true)) do
    if entry:match("%.stale%.") then
      tomb = entry
      break
    end
  end
  assert(tomb, "quarantined tomb should exist after release owner read failure on failed body")
  vim.fn.delete(tomb, "rf")
  assert_no_artifacts("release owner read throw failure")
end

run_sequential_binding_rules()
run_binding_race()
run_same_branch_race()
run_dead_lock_recovery()
run_live_lock_timeout()
run_ownerless_stale_lock_recovery()
run_rejection_leaves_no_artifacts()
run_injected_owner_write_failure()
run_injected_write_failure()
run_injected_rename_failure()
run_lock_cleanup_without_temp()
run_release_owner_read_throw_success()
run_release_owner_read_throw_failure()

vim.fn.delete(storage_dir, "rf")
vim.fn.delete(barrier_dir, "rf")

print("PASS: storage atomic saves are cross-process safe")
