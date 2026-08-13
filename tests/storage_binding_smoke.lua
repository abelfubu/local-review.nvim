-- Storage rejects concurrent first findings that would rebind a session.
local plugin_root = vim.uv.cwd()
vim.opt.runtimepath:append(plugin_root)

local storage_dir = vim.fn.tempname() .. "_storage_binding"
vim.fn.mkdir(storage_dir, "p")

require("local_review").setup({ storage_dir = storage_dir })

local storage = require("local_review.storage")
local session = require("local_review.session")

local scope_a = vim.fn.tempname() .. "_scope_a"
local first_a = { comments = {} }
session.bind(first_a, { kind = "branch", name = "feature/a" })
assert(storage.save_scope(scope_a, first_a) == true, "first save to scope_a should succeed")

local second_a = { comments = {} }
session.bind(second_a, { kind = "branch", name = "feature/b" })
local ok_a, err_a = storage.save_scope(scope_a, second_a)
assert(ok_a == nil, "second conflicting save to scope_a should be rejected")
assert(err_a and err_a:match("feature/a"), "error should name the bound branch for scope_a: " .. tostring(err_a))

local scope_b = vim.fn.tempname() .. "_scope_b"
local first_b = { comments = {} }
session.bind(first_b, { kind = "branch", name = "feature/x" })
assert(storage.save_scope(scope_b, first_b) == true, "first save to scope_b should succeed")

local second_b = { comments = {} }
session.bind(second_b, { kind = "branch", name = "feature/x" })
assert(storage.save_scope(scope_b, second_b) == true, "same-branch save to scope_b should succeed")

local scope_c = vim.fn.tempname() .. "_scope_c"
local first_c = { comments = {} }
session.bind(first_c, { kind = "branch", name = "feature/y" })
assert(storage.save_scope(scope_c, first_c) == true, "first save to scope_c should succeed")

local late_c = { comments = {} }
local ok_c, err_c = storage.save_scope(scope_c, late_c)
assert(ok_c == nil, "unbound save to scope_c should be rejected")
assert(err_c and err_c:match("feature/y"), "error should name the bound branch for scope_c: " .. tostring(err_c))

vim.fn.delete(storage_dir, "rf")
print("PASS: storage binding conflicts prevent concurrent rebinding")
