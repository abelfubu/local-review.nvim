local plugin_root = vim.uv.cwd()
vim.opt.runtimepath:append(plugin_root)

local tmp = vim.fn.tempname() .. "-export-smoke"
vim.fn.mkdir(tmp, "p")
local repo = tmp .. "/repo"
vim.fn.mkdir(repo, "p")

vim.fn.system({ "git", "-C", repo, "init" })
vim.fn.system({ "git", "-C", repo, "config", "user.email", "test@test.com" })
vim.fn.system({ "git", "-C", repo, "config", "user.name", "Test" })

local file = repo .. "/example.lua"
vim.fn.writefile({ "line1", "line2", "line3" }, file)
vim.fn.system({ "git", "-C", repo, "add", "." })
vim.fn.system({ "git", "-C", repo, "commit", "-m", "init" })

local storage_dir = tmp .. "/storage"
vim.fn.mkdir(storage_dir, "p")

require("local_review").setup({ storage_dir = storage_dir })

local buf = vim.fn.bufadd(file)
vim.fn.bufload(buf)
vim.api.nvim_set_current_buf(buf)

local comments = require("local_review.application.comments")
local result, err = comments.set_line_comment(buf, 2, "Please fix this.")
assert(result, err or "failed to create comment")

local export = require("local_review.application.export")
local text, export_err, count = export.path_export_text(repo)
assert(text, export_err)
assert(count == 1, "expected 1 comment, got " .. tostring(count))
assert(text:find("Please fix this.", 1, true), "exported text missing comment body: " .. text)

export.open_export(repo, { clear_after_export = true })

local storage = require("local_review.infrastructure.storage")
local resolved_root = require("local_review.infrastructure.context").scope_root(repo)
local data = storage.load_scope(resolved_root)
assert(#data.comments == 0, "expected comments to be cleared, got " .. #data.comments)

print("PASS: export finds comment and clears it")
