local M = {}

local comment_store = require("local_review.domain.comment_store")

local namespace = vim.api.nvim_create_namespace("local-review-markers")

local function marker_opts()
  return require("local_review").get_opts()
end

local function buffer_winid(bufnr)
  for _, winid in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(winid) and vim.api.nvim_win_get_buf(winid) == bufnr then
      return winid
    end
  end
  return nil
end

local function box_width(bufnr)
  local winid = buffer_winid(bufnr)
  if not winid then
    return nil
  end

  local win_width = vim.api.nvim_win_get_width(winid)
  local textoff = vim.fn.getwininfo(winid)[1].textoff
  return math.max(8, win_width - textoff)
end

local function split_at_display_width(text, width)
  if width <= 0 then
    return "", text
  end

  local chars = vim.fn.strchars(text)
  if chars == 0 then
    return "", ""
  end

  local low, high = 0, chars
  while low < high do
    local mid = math.ceil((low + high) / 2)
    local part = vim.fn.strcharpart(text, 0, mid)
    if vim.fn.strdisplaywidth(part) <= width then
      low = mid
    else
      high = mid - 1
    end
  end

  local prefix = vim.fn.strcharpart(text, 0, low)
  local rest = vim.fn.strcharpart(text, low, chars - low)
  return prefix, rest
end

local function wrap_line(text, width)
  if width <= 0 then
    return {}
  end

  local lines = {}
  while text ~= "" do
    local part, rest = split_at_display_width(text, width)
    if part == "" then
      -- Even one character exceeds the budget; take it anyway to avoid looping.
      part = vim.fn.strcharpart(text, 0, 1)
      rest = vim.fn.strcharpart(text, 1, vim.fn.strchars(text) - 1)
    end
    lines[#lines + 1] = part
    text = rest
  end
  return lines
end

local function wrapped_body_lines(body, text_width)
  local result = {}
  for _, line in ipairs(vim.split(body or "", "\n", { plain = true })) do
    if line == "" then
      result[#result + 1] = ""
    else
      for _, wrapped in ipairs(wrap_line(line, text_width)) do
        result[#result + 1] = wrapped
      end
    end
  end
  return result
end

local max_visible_body_lines = 3

local function truncated_body_lines(body, text_width)
  local wrapped = wrapped_body_lines(body, text_width)
  if #wrapped <= max_visible_body_lines then
    return wrapped
  end

  local result = {}
  for i = 1, max_visible_body_lines do
    result[i] = wrapped[i]
  end
  result[max_visible_body_lines + 1] = "… (K to read)"
  return result
end

local function pad(text, width)
  local pad_len = math.max(0, width - vim.fn.strdisplaywidth(text))
  return text .. string.rep(" ", pad_len)
end

local function border_top(title, width)
  local title_width = vim.fn.strdisplaywidth(title)
  if title_width + 4 > width then
    title = ""
    title_width = 0
  end
  local fill = width - 2 - title_width
  return "┌" .. title .. string.rep("─", fill) .. "┐"
end

local function border_bottom(width)
  return "└" .. string.rep("─", width - 2) .. "┘"
end

local function truncate_to_width(text, width)
  if vim.fn.strdisplaywidth(text) <= width then
    return text
  end
  local prefix, _ = split_at_display_width(text, width)
  return prefix
end

local function body_virt_line(text, width)
  local inner = width - 4
  local truncated = truncate_to_width(text, inner)
  local padded = pad(truncated, inner)
  return {
    { "│ ", "FloatBorder" },
    { padded, "NormalFloat" },
    { " │", "FloatBorder" },
  }
end

local function comment_virt_lines(comment, width)
  if width < 8 then
    return {}
  end

  local inner = width - 4
  local first = comment.anchor.line_number
  local last = math.max(first, comment.line_end or first)
  local range = last > first and string.format(" %d-%d", first, last) or ""
  local stale = comment.stale and " [stale]" or ""
  local title

  if comment_store.is_remote(comment) then
    local author = comment.remote and comment.remote.author or "unknown"
    local outdated = comment.remote and comment.remote.outdated and " [outdated]" or ""
    title = string.format(" GitHub Review · @%s%s%s ", author, range, outdated)
  else
    title = string.format(" Review Comment%s%s ", range, stale)
  end

  local top = border_top(title, width)
  local bottom = border_bottom(width)

  local virt_lines = {}
  virt_lines[#virt_lines + 1] = { { top, "FloatBorder" } }
  for _, line in ipairs(truncated_body_lines(comment.body, inner)) do
    virt_lines[#virt_lines + 1] = body_virt_line(line, width)
  end
  virt_lines[#virt_lines + 1] = { { bottom, "FloatBorder" } }

  return virt_lines
end

---Refreshes markers on every loaded file buffer belonging to the scope.
---@param scope_root string
function M.refresh_scope(scope_root)
  local context = require("local_review.infrastructure.context")
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].buftype == "" then
      local path = vim.api.nvim_buf_get_name(bufnr)
      if path ~= "" then
        local root = context.scope_root(path)
        if root == scope_root then
          M.refresh(bufnr)
        end
      end
    end
  end
end

function M.refresh(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) or vim.bo[bufnr].buftype ~= "" then
    return
  end

  vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)

  local comments = require("local_review.application.comments").comments_for_buffer(bufnr, { silent = true })
  local ui = require("local_review.presentation.ui")
  local opts = marker_opts()
  local max_line = math.max(vim.api.nvim_buf_line_count(bufnr), 1)
  local active_line = ui.active_source_line(bufnr)
  local width = box_width(bufnr)

  for index, comment in ipairs(comments) do
    local first = math.max(1, math.min(comment.anchor.line_number, max_line))
    local last = math.max(first, math.min(comment.line_end or comment.anchor.line_number, max_line))
    local active = active_line ~= nil and active_line >= first and active_line <= last

    -- Git-style gutter bar on every commented line; the comment box is drawn
    -- below the last line of the range.
    for line = first, last do
      local mark = {
        sign_text = opts.marker_text,
        sign_hl_group = comment.stale and opts.stale_marker_hl
          or (comment_store.is_remote(comment) and opts.gh_marker_hl or opts.marker_hl),
        priority = 10 + index,
      }
      if line == last and not active and width then
        mark.virt_lines = comment_virt_lines(comment, width)
        mark.virt_lines_leftcol = false
        mark.hl_mode = "combine"
      end
      vim.api.nvim_buf_set_extmark(bufnr, namespace, line - 1, 0, mark)
    end
  end
end

return M
