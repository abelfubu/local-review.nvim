local M = {}

local comments = require("local_review.application.comments")
local context = require("local_review.infrastructure.context")
local preview_namespace = vim.api.nvim_create_namespace("local-review-telescope-preview")

local function telescope_modules()
  local ok, telescope = pcall(require, "telescope")
  if not ok then
    return nil, "local-review.nvim Telescope picker requires nvim-telescope/telescope.nvim"
  end

  return {
    telescope = telescope,
    pickers = require("telescope.pickers"),
    finders = require("telescope.finders"),
    conf = require("telescope.config").values,
    actions = require("telescope.actions"),
    action_state = require("telescope.actions.state"),
    previewers = require("telescope.previewers"),
    entry_display = require("telescope.pickers.entry_display"),
  }
end

local function entry_displayer(entry_display, line_width)
  return entry_display.create({
    separator = " ",
    items = {
      { width = 40 },
      { width = line_width },
      { remaining = true },
    },
  })
end

local function line_range_str(comment)
  local start_line = comment.anchor.line_number
  local end_line = comment.line_end
  if end_line and end_line ~= start_line then
    return string.format("%d-%d", start_line, end_line)
  end
  return tostring(start_line)
end

local function comment_summary(body)
  return vim.trim((body or ""):gsub("%s+", " "))
end

local function status_summary(comment)
  if comment.stale then
    return "[stale] " .. comment_summary(comment.body)
  end
  return comment_summary(comment.body)
end

---@param comment LocalReviewComment
local function open_comment(comment)
  if vim.fn.filereadable(comment.absolute_path) == 0 then
    vim.notify(string.format("Comment file no longer exists: %s", comment.absolute_path), vim.log.levels.WARN)
    return
  end

  vim.cmd.edit(vim.fn.fnameescape(comment.absolute_path))
  local max_line = math.max(vim.api.nvim_buf_line_count(0), 1)
  local start_line = math.max(1, math.min(comment.anchor.line_number, max_line))
  local end_line = comment.line_end and math.max(1, math.min(comment.line_end, max_line)) or start_line
  if end_line < start_line then
    end_line = start_line
  end

  vim.api.nvim_win_set_cursor(0, { start_line, 0 })
  vim.cmd("normal! V")
  if end_line > start_line then
    vim.cmd("normal! " .. (end_line - start_line) .. "j")
  end

  if comment.stale then
    vim.notify("This review comment is stale and may no longer point at the original code.", vim.log.levels.WARN)
  end
end

local function preview_lines(comment)
  if vim.fn.filereadable(comment.absolute_path) == 0 then
    return {
      string.format("File not found: %s", comment.absolute_path),
      "",
      comment.body,
    },
      nil,
      nil
  end

  return vim.fn.readfile(comment.absolute_path), comment.anchor.line_number, comment.line_end
end

local function previewer(previewers)
  return previewers.new_buffer_previewer({
    title = "Review Comment",
    define_preview = function(self, entry, status)
      local comment = entry.value
      local lines, start_line, end_line = preview_lines(comment)

      vim.bo[self.state.bufnr].modifiable = true
      vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
      vim.bo[self.state.bufnr].modifiable = false
      vim.bo[self.state.bufnr].buflisted = false

      local filetype = vim.filetype.match({ filename = comment.absolute_path })
      if filetype then
        vim.bo[self.state.bufnr].filetype = filetype
      end

      vim.api.nvim_buf_clear_namespace(self.state.bufnr, preview_namespace, 0, -1)
      if start_line then
        local max_line = vim.api.nvim_buf_line_count(self.state.bufnr)
        local clamped_start = math.max(1, math.min(start_line, max_line))
        local clamped_end = math.max(clamped_start, math.min(end_line or start_line, max_line))
        vim.hl.range(self.state.bufnr, preview_namespace, "Visual", { clamped_start - 1, 0 }, { clamped_end - 1, -1 })
        pcall(vim.api.nvim_win_set_cursor, status.preview_win, { clamped_start, 0 })
        pcall(vim.api.nvim_win_call, status.preview_win, function()
          vim.cmd("normal! zz")
        end)
      end
    end,
  })
end

function M.comments(opts)
  local modules, err = telescope_modules()
  if not modules then
    vim.notify(err or "Failed to load Telescope.", vim.log.levels.ERROR)
    return
  end

  opts = opts or {}
  local target_path = opts.path or context.default_export_root()
  local path_comments, _, err = comments.list_comments_in_path(target_path)
  if not path_comments then
    vim.notify(err or "Failed to determine the current comment scope.", vim.log.levels.WARN)
    return
  end

  if #path_comments == 0 then
    vim.notify("No review comments found for the selected path.", vim.log.levels.INFO)
    return
  end

  local line_width = 6
  for _, c in ipairs(path_comments) do
    line_width = math.max(line_width, #line_range_str(c))
  end
  local displayer = entry_displayer(modules.entry_display, line_width)

  modules.pickers
    .new(opts, {
      prompt_title = "Local Review Comments",
      finder = modules.finders.new_table({
        results = path_comments,
        entry_maker = function(comment)
          local summary = status_summary(comment)
          return {
            value = comment,
            ordinal = table.concat({
              comment.absolute_path,
              line_range_str(comment),
              summary,
            }, " "),
            display = function(entry)
              return displayer({
                entry.value.absolute_path,
                line_range_str(entry.value),
                status_summary(entry.value),
              })
            end,
          }
        end,
      }),
      sorter = modules.conf.generic_sorter(opts),
      previewer = previewer(modules.previewers),
      attach_mappings = function(prompt_bufnr)
        modules.actions.select_default:replace(function()
          local selection = modules.action_state.get_selected_entry()
          modules.actions.close(prompt_bufnr)
          if not selection then
            return
          end

          open_comment(selection.value)
        end)
        return true
      end,
    })
    :find()
end

return M
