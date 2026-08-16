local M = {}

local context = require("local_review.infrastructure.context")
local comments = require("local_review.application.comments")
local storage = require("local_review.infrastructure.storage")
local store = require("local_review.domain.comment_store")
local export_indent_width = 3
local export_indent = string.rep(" ", export_indent_width)

local function display_path(root_path, kind, absolute_path)
  if kind == "file" then
    return absolute_path
  end

  return context.relative_path(root_path, absolute_path) or absolute_path
end

local function get_exportable_comments(path_comments)
  -- Export includes both local and remote (GitHub) comments. Remote comments
  -- are rendered with attribution and a URL below the body.
  return path_comments
end

---@param path string?
---@return { scope_root: string, path: string, kind: "file"|"directory" }? target, string? err
local function resolve_target(path)
  local target = path
  if target == nil or target == "" then
    target = context.default_export_root()
  end

  local kind, normalized_or_err = context.path_kind(target)
  if not kind then
    return nil, normalized_or_err
  end

  local scope_root, scope_err = context.scope_root(normalized_or_err)
  if not scope_root then
    return nil, scope_err
  end

  return { scope_root = scope_root, path = normalized_or_err, kind = kind }
end

local function export_lines(path)
  local target, resolve_err = resolve_target(path)
  if not target then
    return nil, resolve_err or "Failed to resolve export path."
  end

  local exportable_comments, list_err = comments.list_comments_in_path(target.path)
  if not exportable_comments then
    return nil, list_err or "Failed to load comments."
  end

  if #exportable_comments == 0 then
    return {
      "No review comments found for the selected path.",
    }, nil, 0
  end

  local lines = {}

  for index, comment in ipairs(exportable_comments) do
    local stale_suffix = comment.stale and " [stale]" or ""
    local line_ref = tostring(comment.anchor.line_number)
    if (comment.line_end or comment.anchor.line_number) > comment.anchor.line_number then
      line_ref = string.format("%d-%d", comment.anchor.line_number, comment.line_end)
    end

    local location = string.format(
      "%d. %s:%s%s",
      index,
      display_path(target.path, target.kind, comment.absolute_path),
      line_ref,
      stale_suffix
    )

    if store.is_remote(comment) then
      local author = comment.remote and comment.remote.author or "unknown"
      location = location .. string.format(" [github @%s]", author)
    end

    lines[#lines + 1] = location
    lines[#lines + 1] = export_indent .. comment.body:gsub("\n", "\n" .. export_indent)

    if store.is_remote(comment) and comment.remote and comment.remote.url then
      lines[#lines + 1] = export_indent .. comment.remote.url
    end

    lines[#lines + 1] = ""
  end

  return lines, nil, #exportable_comments
end

function M.path_export_text(path)
  local lines, err, comment_count = export_lines(path)
  if not lines then
    return nil, err
  end

  return table.concat(lines, "\n"), nil, comment_count
end

function M.open_export(path, opts)
  local export_path = path
  if export_path == nil or export_path == "" then
    export_path = context.default_export_root()
  end

  local text, err, comment_count = M.path_export_text(export_path)
  if not text then
    vim.notify(err or "Failed to export review comments.", vim.log.levels.WARN)
    return
  end

  local copied = false
  if #vim.api.nvim_list_uis() == 0 then
    -- Headless runs (e.g. skills) still need stdout output.
    io.write(text .. "\n")
    copied = true
  else
    for _, reg in ipairs({ "+", "*" }) do
      local ok = pcall(vim.fn.setreg, reg, text)
      if ok then
        copied = true
      end
    end

    if copied then
      vim.notify(
        string.format("Copied %d review comment(s) to the system clipboard.", comment_count),
        vim.log.levels.INFO
      )
    else
      vim.notify("Failed to copy review comments to the system clipboard; comments were kept.", vim.log.levels.ERROR)
    end
  end

  if opts and opts.clear_after_export and comment_count > 0 and copied then
    local target, resolve_err = resolve_target(export_path)
    if not target then
      vim.notify(resolve_err or "Failed to resolve export path.", vim.log.levels.WARN)
      return
    end
    local removed, clear_err = storage.remove_comments_for_path(target.scope_root, target.path, target.kind)
    if not removed then
      vim.notify(clear_err or "Failed to clear exported comments.", vim.log.levels.ERROR)
    elseif #removed > 0 then
      vim.api.nvim_exec_autocmds("User", {
        pattern = "LocalReviewChanged",
        data = { scope_root = target.scope_root },
      })
    end
  end
end

function M.open_export_preserve(path)
  M.open_export(path)
end

return M
