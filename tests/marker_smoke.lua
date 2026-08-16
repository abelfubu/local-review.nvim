-- Marker smoke test for inline comment box truncation and wide-character alignment.
-- Run with: nvim --headless -u NONE -l tests/marker_smoke.lua

local plugin_root = vim.uv.cwd()
vim.opt.runtimepath:append(plugin_root)

local storage_dir = vim.fn.tempname() .. "_marker_smoke"
local source_path = vim.fn.tempname() .. ".lua"
vim.fn.mkdir(storage_dir, "p")
vim.fn.writefile({ "local value = 1" }, source_path)

require("local_review").setup({ storage_dir = storage_dir, keymaps = {} })
vim.cmd.edit(vim.fn.fnameescape(source_path))

local source_bufnr = vim.api.nvim_get_current_buf()
local absolute_path = vim.api.nvim_buf_get_name(source_bufnr)
local context = require("local_review.infrastructure.context")
local scope_root = context.scope_root(absolute_path)
assert(scope_root, "failed to resolve scope root")
local scope_file = string.format("%s/%s.json", storage_dir, vim.fn.sha256(scope_root))

local long_body = {}
for i = 1, 10 do
  long_body[i] = string.format("Line %d of the comment body that may wrap.", i)
end

local short_body = { "One.", "Two." }

local long_comment = {
  id = "local:long",
  origin = "local",
  absolute_path = absolute_path,
  relative_path = vim.fn.fnamemodify(absolute_path, ":t"),
  body = table.concat(long_body, "\n"),
  created_at = "2024-01-01T00:00:00Z",
  updated_at = "2024-01-01T00:00:00Z",
  anchor = { line_number = 1, line_text = "local value = 1" },
  line_end = 1,
  source_kind = "buffer",
  source_meta = {},
  stale = false,
}

vim.fn.writefile({ vim.json.encode({ scope_root = scope_root, comments = { long_comment } }) }, scope_file)

require("local_review.presentation.markers").refresh(source_bufnr)

local namespace = vim.api.nvim_create_namespace("local-review-markers")
local extmarks = vim.api.nvim_buf_get_extmarks(source_bufnr, namespace, { 0, 0 }, { -1, -1 }, { details = true })
assert(#extmarks > 0, "no marker extmarks found")

local virt_lines = nil
for _, extmark in ipairs(extmarks) do
  if extmark[4] and extmark[4].virt_lines then
    virt_lines = extmark[4].virt_lines
    break
  end
end
assert(virt_lines, "marker extmark has no virt_lines")

-- Top border + bottom border + up to 3 body lines + optional truncation hint.
local max_body_lines = 3
local expected_max = 2 + max_body_lines + 1
assert(#virt_lines <= expected_max, string.format("marker too tall: %d lines", #virt_lines))

local found_hint = false
local body_count = 0
for index, virt_line in ipairs(virt_lines) do
  if index == 1 then
    -- top border
  elseif index == #virt_lines then
    -- bottom border
  else
    body_count = body_count + 1
    local text = virt_line[2] and virt_line[2][1] or ""
    if text:find("K to read") then
      found_hint = true
    end
  end
end
assert(found_hint, "truncated marker did not render the K hint")
assert(body_count == max_body_lines + 1, string.format("expected 3 body lines + hint, got %d", body_count))

-- Now verify a short comment renders its body without a hint.
vim.api.nvim_buf_clear_namespace(source_bufnr, namespace, 0, -1)
local short_comment = vim.deepcopy(long_comment)
short_comment.id = "local:short"
short_comment.body = table.concat(short_body, "\n")
vim.fn.writefile({ vim.json.encode({ scope_root = scope_root, comments = { short_comment } }) }, scope_file)

require("local_review.presentation.markers").refresh(source_bufnr)
extmarks = vim.api.nvim_buf_get_extmarks(source_bufnr, namespace, { 0, 0 }, { -1, -1 }, { details = true })
virt_lines = nil
for _, extmark in ipairs(extmarks) do
  if extmark[4] and extmark[4].virt_lines then
    virt_lines = extmark[4].virt_lines
    break
  end
end
assert(virt_lines, "short marker extmark has no virt_lines")
assert(#virt_lines == 2 + #short_body, string.format("short marker wrong height: %d", #virt_lines))

for index, virt_line in ipairs(virt_lines) do
  if index ~= 1 and index ~= #virt_lines then
    local text = virt_line[2] and virt_line[2][1] or ""
    assert(not text:find("K to read"), "short marker unexpectedly rendered truncation hint")
  end
end

-- Wide-character body: CJK characters have display width 2, so wrapping by
-- character count would overflow the inner box width. Verify every rendered
-- line is exactly the expected box width and that body chunks fit inside it.
vim.api.nvim_buf_clear_namespace(source_bufnr, namespace, 0, -1)
local wide_comment = vim.deepcopy(long_comment)
wide_comment.id = "local:wide"
wide_comment.body = "一二三四五六七八九十"
vim.fn.writefile({ vim.json.encode({ scope_root = scope_root, comments = { wide_comment } }) }, scope_file)

require("local_review.presentation.markers").refresh(source_bufnr)
extmarks = vim.api.nvim_buf_get_extmarks(source_bufnr, namespace, { 0, 0 }, { -1, -1 }, { details = true })
virt_lines = nil
for _, extmark in ipairs(extmarks) do
  if extmark[4] and extmark[4].virt_lines then
    virt_lines = extmark[4].virt_lines
    break
  end
end
assert(virt_lines, "wide marker extmark has no virt_lines")

local winid = vim.fn.bufwinid(source_bufnr)
local win_width = vim.api.nvim_win_get_width(winid)
local textoff = vim.fn.getwininfo(winid)[1].textoff
local box_width = math.max(8, win_width - textoff)
local inner = box_width - 4

for index, virt_line in ipairs(virt_lines) do
  local is_border = index == 1 or index == #virt_lines
  if not is_border then
    local line_text = ""
    for _, chunk in ipairs(virt_line) do
      line_text = line_text .. (chunk[1] or "")
    end
    local line_width = vim.fn.strdisplaywidth(line_text)
    assert(
      line_width == box_width,
      string.format("line %d width %d ~= %d: %q", index, line_width, box_width, line_text)
    )

    local body_chunk = virt_line[2] and virt_line[2][1] or ""
    local body_width = vim.fn.strdisplaywidth(body_chunk)
    assert(body_width <= inner, string.format("line %d body width %d > inner %d", index, body_width, inner))
  end
end

-- Tab-containing body: a tab's display width depends on the starting column.
-- The body text starts after "│ " (column 2), so verify it fits the inner
-- width when measured from that column.
vim.api.nvim_buf_clear_namespace(source_bufnr, namespace, 0, -1)
local tab_comment = vim.deepcopy(long_comment)
tab_comment.id = "local:tab"
tab_comment.body = "\tfirst\tsecond\tthird"
vim.fn.writefile({ vim.json.encode({ scope_root = scope_root, comments = { tab_comment } }) }, scope_file)

require("local_review.presentation.markers").refresh(source_bufnr)
extmarks = vim.api.nvim_buf_get_extmarks(source_bufnr, namespace, { 0, 0 }, { -1, -1 }, { details = true })
virt_lines = nil
for _, extmark in ipairs(extmarks) do
  if extmark[4] and extmark[4].virt_lines then
    virt_lines = extmark[4].virt_lines
    break
  end
end
assert(virt_lines, "tab marker extmark has no virt_lines")

for index, virt_line in ipairs(virt_lines) do
  local is_border = index == 1 or index == #virt_lines
  if not is_border then
    local line_text = ""
    for _, chunk in ipairs(virt_line) do
      line_text = line_text .. (chunk[1] or "")
    end
    local line_width = vim.fn.strdisplaywidth(line_text)
    assert(
      line_width == box_width,
      string.format("tab line %d width %d ~= %d: %q", index, line_width, box_width, line_text)
    )

    local body_chunk = virt_line[2] and virt_line[2][1] or ""
    local body_width = vim.fn.strdisplaywidth(body_chunk, 2)
    assert(body_width <= inner, string.format("tab line %d body width %d > inner %d", index, body_width, inner))
  end
end

vim.fn.delete(storage_dir, "rf")
vim.fn.delete(source_path)
print("PASS: inline markers truncate long bodies and keep short bodies intact")
