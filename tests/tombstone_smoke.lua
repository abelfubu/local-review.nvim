-- Tombstone concurrency smoke test for storage.lua.
--
-- Simulates two Neovim instances sharing the same storage_dir:
--   1. Instance A loads the scope (comment-doomed inside) and decides to remove
--      it via remove_comments_by_ids.
--   2. Instance B (separate headless nvim) concurrently adds comment-new.
--   3. Instance A persists the removal.
--
-- The removal must stick (comment-doomed must NOT be resurrected by the LWW
-- merge) while the concurrent addition must survive.

local plugin_root = vim.uv.cwd()
vim.opt.runtimepath:append(plugin_root)

local storage_dir = vim.fn.tempname() .. "_tombstone_smoke"
vim.fn.mkdir(storage_dir, "p")

require("local_review").setup({ storage_dir = storage_dir })

local scope_root = "/tmp/local_review_tombstone_repo"
local storage = require("local_review.infrastructure.storage")

-- Seed the scope with one comment that instance A will remove.
local seed = storage.load_scope(scope_root)
table.insert(seed.comments, {
  id = "comment-doomed",
  body = "will be removed by A",
  absolute_path = "/tmp/a.txt",
  origin = "local",
})
assert(storage.save_scope(scope_root, seed), "seed save failed")

-- Instance A loads (records the fingerprint), then B writes concurrently.
local _ = storage.load_scope(scope_root)

local b_script = string.format(
  [[
vim.opt.runtimepath:append("%s")
require("local_review").setup({ storage_dir = "%s" })
local storage = require("local_review.infrastructure.storage")
local data = storage.load_scope("%s")
table.insert(data.comments, {
  id = "comment-new",
  body = "from instance B",
  absolute_path = "/tmp/b.txt",
  origin = "local",
})
assert(storage.save_scope("%s", data))
]],
  plugin_root,
  storage_dir,
  scope_root,
  scope_root
)

local b_path = vim.fn.tempname() .. ".lua"
vim.fn.writefile(vim.split(b_script, "\n"), b_path)
local result = vim.system({ "nvim", "--headless", "--clean", "-u", "NONE", "-l", b_path }):wait()
if result.code ~= 0 then
  error(string.format("Instance B failed: %s", result.stderr or "unknown error"))
end

-- Instance A removes comment-doomed; its last-known fingerprint is stale, so
-- save_scope will merge with B's on-disk state. Tombstones must win.
local removed, err = storage.remove_comments_by_ids(scope_root, { "comment-doomed" })
assert(removed, err or "removal failed")
assert(#removed == 1, "expected exactly one removed comment")

local final = storage.load_scope(scope_root)
local ids = {}
for _, comment in ipairs(final.comments) do
  ids[comment.id] = true
end

assert(not ids["comment-doomed"], "comment-doomed was resurrected by the LWW merge")
assert(ids["comment-new"], "comment-new from instance B was lost")

print("PASS: removal tombstones survive concurrent additions")
