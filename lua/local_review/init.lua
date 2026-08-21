local M = {}

local defaults = {
  marker_text = "▎",
  marker_hl = "LocalReviewMarker",
  stale_marker_hl = "LocalReviewStaleMarker",
  gh_marker_hl = "LocalReviewGhMarker",
  storage_dir = vim.fs.joinpath(vim.fn.stdpath("state"), "local-review"),
  keymaps = {
    hover = "K",
  },
  comment_close_keys = {
    { modes = { "n" }, key = "q" },
    { modes = { "n", "i" }, key = "<C-c>" },
  },
}

local state = {
  configured = false,
  opts = vim.deepcopy(defaults),
}

local function command(name, rhs, opts)
  vim.api.nvim_create_user_command(name, rhs, opts or {})
end

local function map(mode, lhs, rhs, desc)
  if lhs == nil or lhs == "" or lhs == false then
    return
  end

  vim.keymap.set(mode, lhs, rhs, { desc = desc, silent = true })
end

local function visual_safe_cmd(command_name)
  return function()
    local mode = vim.api.nvim_get_mode().mode
    if mode:match("^[vV\22]") then
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
      if command_name == "LocalReviewComment" then
        require("local_review.presentation.ui").set_pending_range(vim.fn.getpos("'<")[2], vim.fn.getpos("'>")[2])
      end
    end
    vim.cmd(command_name)
  end
end

local function refresh_current_buffer(bufnr)
  require("local_review.presentation.markers").refresh(
    (bufnr and bufnr ~= 0) and bufnr or vim.api.nvim_get_current_buf()
  )
end

local function list_comments(path)
  local path_comments, err =
    require("local_review.application.comments").list_comments_in_path(path ~= "" and path or nil)
  if not path_comments then
    vim.notify(err or "Failed to list review comments.", vim.log.levels.WARN)
    return
  end

  if #path_comments == 0 then
    vim.notify("No review comments found.", vim.log.levels.INFO)
    return
  end

  local items = {}
  local file_lines_cache = {}
  for _, comment in ipairs(path_comments) do
    local summary = vim.trim((comment.body or ""):gsub("%s+", " "))
    local start_line = comment.anchor.line_number
    local filename = comment.absolute_path

    local lines = file_lines_cache[filename]
    if lines == nil then
      local ok, read_lines = pcall(vim.fn.readfile, filename)
      lines = ok and read_lines or false
      file_lines_cache[filename] = lines
    end

    local raw_end_line = comment.line_end or start_line
    local end_line = raw_end_line
    local preview_start_line = start_line
    local preview_end_line = end_line
    local end_pos = nil
    if lines and type(lines) == "table" then
      local line_count = #lines
      preview_start_line = math.min(math.max(1, start_line), line_count)
      preview_end_line = math.min(math.max(1, raw_end_line), line_count)
      if preview_end_line >= 1 then
        end_pos = { preview_end_line, #lines[preview_end_line] }
      end
    end

    local range_suffix = ""
    if end_line and end_line ~= start_line then
      range_suffix = string.format(" [lines %d-%d]", start_line, end_line)
    end
    items[#items + 1] = {
      filename = filename,
      file = filename,
      lnum = math.max(1, start_line),
      line = math.max(1, start_line),
      col = 1,
      pos = { preview_start_line, 0 },
      end_pos = end_pos,
      text = summary,
      body = comment.body,
      start_line = start_line,
      end_line = end_line,
      stale = comment.stale,
    }
  end

  local icons = {
    file = " ",
    lines = " ",
    stale = " ",
    comment = " ",
    empty = " ",
  }

  local function file_icon(filename)
    local ok, devicons = pcall(require, "nvim-web-devicons")
    if not ok or not devicons then
      return icons.file
    end
    local icon, hl =
      devicons.get_icon(vim.fn.fnamemodify(filename, ":t"), vim.fn.fnamemodify(filename, ":e"), { default = true })
    return icon and (icon .. " ") or icons.file, hl
  end

  local function format_range(item)
    if item.end_line and item.end_line ~= item.start_line then
      return string.format("%d-%d", item.start_line, item.end_line)
    end
    return tostring(item.start_line)
  end

  local function preview_comment(item)
    local preview = {}
    local icon = (file_icon(item.filename))
    local header = string.format(
      "%s%s:%s  %s",
      icon,
      vim.fn.fnamemodify(item.filename, ":~:."),
      format_range(item),
      item.stale and (icons.stale .. "stale") or ""
    )
    table.insert(preview, header)
    table.insert(preview, "")
    local body = item.body or ""
    if vim.trim(body) == "" then
      table.insert(preview, icons.empty .. " *No comment text*")
    else
      table.insert(preview, icons.comment .. "**Comment**")
      table.insert(preview, "")
      for _, line in ipairs(vim.split(body, "\n", { plain = true })) do
        table.insert(preview, "> " .. line)
      end
    end
    return { kind = "markdown", content = preview }
  end

  vim.ui.select(items, {
    prompt = "Local Review Comments ",
    ---@diagnostic disable: redundant-parameter, return-type-mismatch
    format_item = function(item, supports_chunks)
      local icon, icon_hl = file_icon(item.filename)
      local stale_prefix = item.stale and (icons.stale .. " ") or ""
      local path_range = vim.fn.fnamemodify(item.filename, ":~:.") .. ":" .. format_range(item)
      if supports_chunks then
        return {
          { icon, icon_hl },
          { " " .. path_range .. "  ", nil },
          { stale_prefix .. item.text, nil },
        }
      end
      return string.format("%s%s  %s%s", icon, path_range, stale_prefix, item.text)
    end,
    ---@diagnostic enable: redundant-parameter, return-type-mismatch
    preview_item = function(item)
      return preview_comment(item)
    end,
    snacks = {
      layout = { preset = "default" },
    },
  }, function(choice)
    if not choice then
      return
    end
    if vim.fn.filereadable(choice.filename) == 0 then
      vim.notify(string.format("File no longer exists: %s", choice.filename), vim.log.levels.WARN)
      return
    end
    vim.cmd.edit(vim.fn.fnameescape(choice.filename))
    local max_line = math.max(vim.api.nvim_buf_line_count(0), 1)
    local start_line = math.max(1, math.min(choice.start_line, max_line))
    local end_line = choice.end_line and math.max(1, math.min(choice.end_line, max_line)) or start_line
    if end_line < start_line then
      end_line = start_line
    end
    vim.api.nvim_win_set_cursor(0, { start_line, 0 })
    vim.cmd("normal! V")
    if end_line > start_line then
      vim.cmd("normal! " .. (end_line - start_line) .. "j")
    end
    if choice.stale then
      vim.notify("This review comment is stale and may no longer point at the original code.", vim.log.levels.WARN)
    end
  end)
end

function M.setup(opts)
  state.opts = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})

  -- Gutter marker for commented lines. Linked to an info-style group (blue in
  -- most colorschemes); override with :highlight to customize. The group name
  -- doubles as the sign name for statuscolumn plugins.
  vim.api.nvim_set_hl(0, "LocalReviewMarker", { link = "DiagnosticInfo", default = true })

  -- Marker for stale comments (anchor text no longer found in the file).
  vim.api.nvim_set_hl(0, "LocalReviewStaleMarker", { link = "DiagnosticWarn", default = true })

  -- Marker for imported GitHub review comments. Distinct group so it can be
  -- styled independently; defaults to the same info style as local markers.
  vim.api.nvim_set_hl(0, "LocalReviewGhMarker", { link = "DiagnosticInfo", default = true })

  -- Title of the comment box while creating/editing. Linked to a group that
  -- is orange in most colorschemes; override with :highlight to customize.
  vim.api.nvim_set_hl(0, "LocalReviewEditorTitle", { link = "Number", default = true })

  local function jump_and_echo(direction)
    local comments = require("local_review.application.comments")
    comments.jump(direction)
    local line = vim.api.nvim_win_get_cursor(0)[1]
    local line_state = comments.get_line_state(0, line)
    if not line_state or not line_state.comment then
      return
    end
    local body = line_state.comment.body or ""
    local summary = vim.trim(body:gsub("%s+", " "))
    if #summary > 80 then
      summary = summary:sub(1, 80) .. "..."
    end
    local stale_suffix = line_state.comment.stale and " [stale]" or ""
    vim.api.nvim_echo({ { summary .. stale_suffix, "Normal" } }, true, {})
  end

  if not state.configured then
    command("LocalReviewComment", function(command_opts)
      local range
      if command_opts.range and command_opts.range > 0 then
        range = { command_opts.line1, command_opts.line2 }
      end
      require("local_review.presentation.ui").open_current_line(range)
    end, { range = true })

    command("LocalReviewDelete", function()
      require("local_review.application.comments").delete_current_line()
    end, {})

    command("LocalReviewNext", function()
      jump_and_echo(1)
    end, {})

    command("LocalReviewPrev", function()
      jump_and_echo(-1)
    end, {})

    command("LocalReviewGh", function(command_opts)
      require("local_review.application.gh_pr").create_review(command_opts.args, { clear_after_export = true })
    end, { nargs = "?" })

    command("LocalReviewGhPull", function()
      require("local_review.application.gh_pr_sync").pull()
    end, {})

    command("LocalReviewGhClear", function()
      require("local_review.application.gh_pr_sync").clear_current()
    end, {})

    command("LocalReviewExport", function(command_opts)
      require("local_review.application.export").open_export(command_opts.args, { clear_after_export = true })
    end, { nargs = "?" })

    command("LocalReviewExportPreserve", function(command_opts)
      require("local_review.application.export").open_export_preserve(command_opts.args)
    end, { nargs = "?" })

    command("LocalReviewClear", function(command_opts)
      require("local_review.application.comments").clear_path(command_opts.args)
    end, { nargs = "?" })

    command("LocalReviewList", function(command_opts)
      list_comments(command_opts.args)
    end, { nargs = "?" })

    vim.api.nvim_create_autocmd({ "BufEnter", "BufReadPost", "BufWritePost", "FileChangedShellPost", "VimResized" }, {
      group = vim.api.nvim_create_augroup("local-review-refresh", { clear = true }),
      callback = function(event)
        -- External file changes could invalidate our in-memory scope cache.
        if event.event == "FileChangedShellPost" then
          require("local_review.infrastructure.storage").invalidate_scope_cache()
        end
        refresh_current_buffer(event.buf)
      end,
    })

    vim.api.nvim_create_autocmd("User", {
      group = vim.api.nvim_create_augroup("local-review-changed", { clear = true }),
      pattern = "LocalReviewChanged",
      callback = function(event)
        -- Application-layer mutations may have changed persisted state; drop
        -- the cached scope so the next load picks up the new canonical data.
        if event.data and event.data.scope_root then
          require("local_review.infrastructure.storage").invalidate_scope_cache(event.data.scope_root)
          require("local_review.presentation.markers").refresh_scope(event.data.scope_root)
        end
      end,
    })

    vim.api.nvim_create_autocmd({ "BufEnter", "DirChanged" }, {
      group = vim.api.nvim_create_augroup("local-review-branch-cache", { clear = true }),
      callback = function()
        require("local_review.infrastructure.context").invalidate_branch_cache()
        require("local_review.presentation.ui").reconcile_reviews_buffer()
      end,
    })

    vim.api.nvim_create_autocmd("User", {
      group = vim.api.nvim_create_augroup("local-review-reviews", { clear = true }),
      pattern = "LocalReviewReviews",
      callback = function(event)
        if event.data and event.data.reviews then
          require("local_review.presentation.ui").open_reviews_split(event.data.reviews, event.data.scope_root)
        end
      end,
    })

    state.configured = true
  end

  local hover_key = state.opts.keymaps.hover
  local hover_fallback = nil
  if hover_key and hover_key ~= "" then
    hover_fallback = vim.fn.maparg(hover_key, "n", false, true)
    if
      hover_fallback == "" or (type(hover_fallback) == "table" and not (hover_fallback.rhs or hover_fallback.callback))
    then
      hover_fallback = nil
    end
  end

  local function hover_or_fallback()
    local source_bufnr = vim.api.nvim_get_current_buf()
    local source_winid = vim.api.nvim_get_current_win()
    local line = vim.api.nvim_win_get_cursor(source_winid)[1]
    if require("local_review.presentation.ui").hover_peek(source_bufnr, source_winid, line) then
      return
    end

    if hover_fallback then
      if hover_fallback.callback then
        if hover_fallback.expr == 1 then
          local ok, result = pcall(hover_fallback.callback)
          if ok and result then
            local keys = vim.api.nvim_replace_termcodes(tostring(result), true, false, true)
            vim.api.nvim_feedkeys(keys, "m", false)
          end
        else
          hover_fallback.callback()
        end
      elseif hover_fallback.expr == 1 and hover_fallback.rhs then
        local ok, result = pcall(vim.api.nvim_eval, hover_fallback.rhs)
        if ok and result then
          local keys = vim.api.nvim_replace_termcodes(tostring(result), true, false, true)
          vim.api.nvim_feedkeys(keys, "m", false)
        end
      elseif hover_fallback.rhs then
        local keys = vim.api.nvim_replace_termcodes(hover_fallback.rhs, true, true, true)
        vim.api.nvim_feedkeys(keys, "m", false)
      end
    elseif vim.lsp and vim.lsp.buf and vim.lsp.buf.hover then
      local clients = vim.lsp.get_clients({ bufnr = source_bufnr, method = "textDocument/hover" })
      if #clients > 0 then
        vim.lsp.buf.hover()
      else
        pcall(function()
          vim.cmd("normal! K")
        end)
      end
    else
      pcall(function()
        vim.cmd("normal! K")
      end)
    end
  end

  map({ "n", "x" }, state.opts.keymaps.comment, visual_safe_cmd("LocalReviewComment"), "Local Review: Comment")
  map({ "n", "x" }, state.opts.keymaps.delete, visual_safe_cmd("LocalReviewDelete"), "Local Review: Delete")
  map({ "n", "x" }, state.opts.keymaps.next, visual_safe_cmd("LocalReviewNext"), "Local Review: Next")
  map({ "n", "x" }, state.opts.keymaps.prev, visual_safe_cmd("LocalReviewPrev"), "Local Review: Prev")
  map({ "n", "x" }, state.opts.keymaps.export, visual_safe_cmd("LocalReviewExport"), "Local Review: Export")
  map({ "n", "x" }, state.opts.keymaps.github_review, visual_safe_cmd("LocalReviewGh"), "Local Review: Github Review")
  map({ "n", "x" }, state.opts.keymaps.list, visual_safe_cmd("LocalReviewList"), "Local Review: List")
  map("n", state.opts.keymaps.hover, hover_or_fallback, "Local Review: Hover")
end

function M.get_opts()
  return state.opts
end

return M
