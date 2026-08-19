local context = require("local_review.infrastructure.context")
local storage = require("local_review.infrastructure.storage")
local store = require("local_review.domain.comment_store")
local gh = require("local_review.infrastructure.gh")

---What may be submitted as a GitHub review: local comments only. This is a
---gh_pr policy (mirroring export's own filter), not a domain primitive.
---@param comments LocalReviewComment[]
---@return LocalReviewComment[]
local function get_submittable_comments(comments)
  local result = {}
  for _, comment in ipairs(comments) do
    if store.is_editable(comment) then
      table.insert(result, comment)
    end
  end
  return result
end

local M = {}

function M.get_pr_info(repo_root)
  local out, err = gh.run({ "gh", "pr", "view", "--json", "number,headRefOid" }, repo_root)
  if not out then
    return nil, err
  end

  local ok, decoded = pcall(vim.json.decode, out)
  if not ok then
    return nil, "Failed to parse PR info"
  end

  return decoded, nil
end

---@param callback fun(review_type: string)
local function prompt_review_type(callback)
  vim.ui.select({ "Approve", "Comment", "Request Changes" }, {
    prompt = "Review type:",
    format_item = function(item)
      return item
    end,
  }, function(choice)
    if not choice then
      return
    end

    local event_map = {
      ["Approve"] = "APPROVE",
      ["Comment"] = "COMMENT",
      ["Request Changes"] = "REQUEST_CHANGES",
    }

    callback(event_map[choice])
  end)
end

---@param event string
---@param callback fun(event: string, input: string)
local function prompt_review_body(event, callback)
  local required = event == "COMMENT" or event == "REQUEST_CHANGES"
  local prompt = required and "Review summary (required): " or "Review summary (optional): "
  vim.ui.input({ prompt = prompt }, function(input)
    -- input is nil if user cancelled with <Esc>, "" if they just hit enter
    if input == nil then
      return
    end
    if required and vim.trim(input) == "" then
      vim.notify("A review summary is required for this review type.", vim.log.levels.ERROR)
      return
    end
    callback(event, input)
  end)
end

local function to_github_comment(c)
  local entry = {
    path = c.relative_path,
    side = "RIGHT",
    body = c.body,
  }

  if c.anchor_end then
    -- multiline / range comment
    entry.start_line = c.anchor.line_number
    entry.start_side = "RIGHT"
    entry.line = c.anchor_end.line_number
  else
    -- single line comment
    entry.line = c.anchor.line_number
  end

  return entry
end

---List the file paths changed in the current branch's PR.
---@param repo_root string
---@return string[]? files, string? error
local function get_pr_files(repo_root)
  local out, err = gh.run({ "gh", "pr", "view", "--json", "files", "-q", ".files[].path" }, repo_root)
  if not out then
    return nil, err
  end
  return vim.split(out, "\n", { trimempty = true })
end

---@param path string?
---@param opts table
function M.create_review(path, opts)
  local target = path
  if target == nil or target == "" then
    target = context.default_export_root()
  end

  local kind, normalized_or_err = context.path_kind(target)
  if not kind then
    vim.notify(normalized_or_err, vim.log.levels.WARN)
    return
  end
  local target_path = normalized_or_err

  local repo_root, scope_err = context.scope_root(target_path)
  if not repo_root then
    vim.notify(scope_err or "Failed to determine the comment scope.", vim.log.levels.WARN)
    return
  end
  local path_comments = storage.comments_for_path(repo_root, target_path, kind)

  for _, comment in ipairs(path_comments) do
    if comment.stale then
      vim.notify("Cannot submit stale comments. Recreate or delete them first.", vim.log.levels.ERROR)
      return
    end
  end

  local submittable_comments = get_submittable_comments(path_comments)

  local pr_info, err = M.get_pr_info(repo_root)
  if not pr_info then
    vim.notify(err or "No PR found for current branch. Create one first:\n  gh pr create", vim.log.levels.ERROR)
    return
  end

  -- GitHub rejects the whole review (422 "Path could not be resolved") if any
  -- comment targets a file that is not part of the PR diff. Fail fast instead.
  local pr_files, files_err = get_pr_files(repo_root)
  if not pr_files then
    vim.notify(files_err or "Failed to list PR files.", vim.log.levels.ERROR)
    return
  end

  local in_diff = {}
  for _, p in ipairs(pr_files) do
    in_diff[p] = true
  end
  local outside = {}
  for _, c in ipairs(submittable_comments) do
    if not in_diff[c.relative_path] then
      outside[c.relative_path] = true
    end
  end
  if next(outside) then
    local paths = vim.tbl_keys(outside)
    table.sort(paths)
    vim.notify(
      "Some comments target files that are not in the PR diff:\n  " .. table.concat(paths, "\n  "),
      vim.log.levels.ERROR
    )
    return
  end

  prompt_review_type(function(event)
    prompt_review_body(event, function(_, body)
      local ok, submit_err = M.submit_review(submittable_comments, event, body, pr_info, repo_root)
      if not ok then
        vim.notify("Failed to create PR review:\n" .. submit_err, vim.log.levels.ERROR)
        return
      end

      vim.notify("PR review submitted: " .. event, vim.log.levels.INFO)
      if opts and opts.clear_after_export and #submittable_comments > 0 then
        local submitted_ids = {}
        for _, comment in ipairs(submittable_comments) do
          submitted_ids[#submitted_ids + 1] = comment.id
        end
        local cleared, clear_err = storage.remove_comments_by_ids(repo_root, submitted_ids)
        if not cleared then
          vim.notify("Failed to clear submitted comments: " .. (clear_err or "Unknown error"), vim.log.levels.ERROR)
        elseif #cleared > 0 then
          vim.api.nvim_exec_autocmds("User", {
            pattern = "LocalReviewChanged",
            data = { scope_root = repo_root },
          })
        end
      end
    end)
  end)
end
---Pull the real GitHub error out of `gh api --verbose` stderr. On failure,
---gh prints only "gh: <message> (HTTP <code>)"; the response body (with the
---`errors` array explaining *why* a 422 happened) only shows up in verbose logs.
---@param stderr string?
---@return string?
local function extract_api_error(stderr)
  if not stderr then
    return nil
  end

  local function format_decoded(decoded)
    local parts = {}
    if type(decoded.message) == "string" and decoded.message ~= "" then
      table.insert(parts, decoded.message)
    end
    for _, e in ipairs(decoded.errors or {}) do
      if type(e) == "table" then
        table.insert(
          parts,
          vim.trim(string.format("%s %s %s", e.resource or "", e.field or "", e.message or e.code or ""))
        )
      else
        table.insert(parts, tostring(e))
      end
    end
    if #parts > 0 then
      return table.concat(parts, "\n")
    end
    return nil
  end

  -- GH_DEBUG=api dumps the response body either compact on one line
  -- (sometimes glued to other log text, e.g. `{"message":...}gh: ...`), or
  -- pretty-printed across multiple lines. Handle both.
  local buffer, depth = nil, 0
  for line in stderr:gmatch("[^\r\n]+") do
    if buffer then
      buffer = buffer .. line
      local opens = select(2, line:gsub("{", ""))
      local closes = select(2, line:gsub("}", ""))
      depth = depth + opens - closes
      if depth <= 0 then
        local ok, decoded = pcall(vim.json.decode, buffer)
        if ok and type(decoded) == "table" then
          local formatted = format_decoded(decoded)
          if formatted then
            return formatted
          end
        end
        buffer, depth = nil, 0
      end
    elseif vim.trim(line) == "{" then
      buffer, depth = "{", 1
    else
      local start = line:find("{")
      local candidate = start and line:sub(start):match("^(%b{})") or nil
      if candidate then
        local ok, decoded = pcall(vim.json.decode, candidate)
        if ok and type(decoded) == "table" then
          local formatted = format_decoded(decoded)
          if formatted then
            return formatted
          end
        end
      end
    end
  end

  return nil
end

function M.submit_review(path_comments, event, body, pr_info, repo_root)
  if not pr_info.headRefOid or pr_info.headRefOid == "" then
    return nil, "PR head commit is missing"
  end

  local review_comments = {}
  for _, c in ipairs(path_comments) do
    table.insert(review_comments, to_github_comment(c))
  end

  local payload = {
    commit_id = pr_info.headRefOid,
    event = event,
    body = body,
    comments = review_comments,
  }

  local json_str = vim.json.encode(payload)
  local tmpfile = vim.fn.tempname() .. ".json"
  local f = io.open(tmpfile, "w")

  if not f then
    return nil, "Failed to create temp file"
  end

  f:write(json_str)
  f:close()

  local repo_slug, repo_err = gh.get_repo_slug(repo_root)
  local result, submit_err
  if repo_slug then
    result, submit_err = gh.run({
      "gh",
      "api",
      string.format("repos/%s/pulls/%s/reviews", repo_slug, pr_info.number),
      "--method",
      "POST",
      "--input",
      tmpfile,
    }, repo_root, { env = { GH_DEBUG = "api" } })
  end
  os.remove(tmpfile)

  if not result then
    local detail = extract_api_error(submit_err)
    if detail then
      return nil, detail
    end
    -- No parseable body: show the tail of the raw gh output for debugging.
    local lines = vim.split(submit_err or "", "\n", { trimempty = true })
    local tail = {}
    for i = math.max(1, #lines - 10), #lines do
      table.insert(tail, lines[i])
    end
    return nil, "gh api failed (no error body parsed). Raw output:\n" .. table.concat(tail, "\n")
  end

  return true
end

return M
