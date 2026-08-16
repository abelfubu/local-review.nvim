-- Hover fallback smoke test for <Plug>, <expr> and built-in K semantics.
-- Run with: nvim --headless -u NONE -l tests/hover_fallback_smoke.lua

local plugin_root = vim.uv.cwd()
vim.opt.runtimepath:append(plugin_root)

local storage_dir = vim.fn.tempname() .. "_hover_fallback_smoke"
local source_path = vim.fn.tempname() .. ".lua"
vim.fn.mkdir(storage_dir, "p")
vim.fn.writefile({ "local first = 1", "local second = 2" }, source_path)

-- Map K to a <Plug> action before setup so the fallback is captured.
local plug_triggered = false
vim.keymap.set("n", "<Plug>LocalReviewTestFallback", function()
  plug_triggered = true
end)
vim.keymap.set("n", "K", "<Plug>LocalReviewTestFallback")

require("local_review").setup({ storage_dir = storage_dir, keymaps = { hover = "K" } })
vim.cmd.edit(vim.fn.fnameescape(source_path))

local source_bufnr = vim.api.nvim_get_current_buf()
local source_winid = vim.api.nvim_get_current_win()
local absolute_path = vim.api.nvim_buf_get_name(source_bufnr)
local context = require("local_review.infrastructure.context")
local scope_root = context.scope_root(absolute_path)
assert(scope_root, "failed to resolve scope root")

local function feed(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
end

-- Press K on a commentless line: hover should fall back to the captured <Plug>
-- mapping, which is invoked with remapping enabled.
vim.api.nvim_win_set_cursor(source_winid, { 2, 0 })
feed("K")
vim.wait(200, function()
  return plug_triggered
end)
assert(plug_triggered, "hover did not fall back to <Plug> mapping")

-- Re-map K to an <expr> mapping and reload setup so it captures the new
-- fallback. The callback returns an empty string so no further action occurs.
local expr_triggered = false
vim.keymap.del("n", "K")
vim.keymap.set("n", "K", function()
  expr_triggered = true
  return ""
end, { expr = true })

package.loaded["local_review"] = nil
require("local_review").setup({ storage_dir = storage_dir, keymaps = { hover = "K" } })

vim.api.nvim_win_set_cursor(source_winid, { 2, 0 })
feed("K")
vim.wait(200, function()
  return expr_triggered
end)
assert(expr_triggered, "hover did not fall back to <expr> mapping")

-- No LSP client attached: the built-in K path must be reached instead of
-- vim.lsp.buf.hover(). Remove any previous K fallback first.
vim.keymap.del("n", "K")
package.loaded["local_review"] = nil
require("local_review").setup({ storage_dir = storage_dir, keymaps = { hover = "K" } })

local lsp_hover_called = false
local builtin_k_called = false
local original_lsp_hover = vim.lsp.buf.hover
---@diagnostic disable-next-line: duplicate-set-field
vim.lsp.buf.hover = function()
  lsp_hover_called = true
end
local original_get_clients = vim.lsp.get_clients
---@diagnostic disable-next-line: duplicate-set-field
vim.lsp.get_clients = function(_)
  return {}
end
local original_cmd = vim.cmd
---@diagnostic disable-next-line: param-type-mismatch
vim.cmd = function(cmd)
  if type(cmd) == "string" and cmd:find("normal! K") then
    builtin_k_called = true
    return nil
  end
  return original_cmd(cmd)
end

vim.api.nvim_win_set_cursor(source_winid, { 2, 0 })
feed("K")
vim.wait(200, function()
  return builtin_k_called
end)

assert(not lsp_hover_called, "vim.lsp.buf.hover was called with no hover client")
assert(builtin_k_called, "built-in K was not invoked when no LSP hover client exists")

vim.lsp.buf.hover = original_lsp_hover
vim.lsp.get_clients = original_get_clients
vim.cmd = original_cmd

-- Hover opt-out: hover = false must not create any K mapping.
vim.keymap.del("n", "K")
package.loaded["local_review"] = nil
require("local_review").setup({ storage_dir = storage_dir, keymaps = { hover = false } })
assert(vim.fn.maparg("K", "n") == "", "hover=false still created a K mapping")

vim.fn.delete(storage_dir, "rf")
vim.fn.delete(source_path)
print("PASS: hover fallback preserves <Plug>, <expr> and built-in K semantics")
