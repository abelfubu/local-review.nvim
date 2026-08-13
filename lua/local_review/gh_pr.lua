local comments = require("local_review.comments")

local M = {}

local function get_repo_slug()
  local out = vim.fn.system("gh repo view --json owner,name -q '.owner.login + \"/\" + .name'")
  return vim.trim(out)
end

local function get_pr_number()
  local out = vim.fn.system("gh pr view --json number -q .number")
  return vim.trim(out)
end

local function get_commit_id()
  local out = vim.fn.system("git rev-parse HEAD")
  return vim.trim(out)
end

local function get_pr_info()
  local out = vim.fn.system("gh pr view --json number,headRefOid 2>&1")

  if vim.v.shell_error ~= 0 then
    return nil, out
  end

  local ok, decoded = pcall(vim.json.decode, out)
  if not ok then
    return nil, "Failed to parse PR info"
  end

  return decoded, nil
end

local function prompt_review_type(callback)
  vim.ui.select({ "Approve", "Comment", "Request Changes" }, {
    prompt = "Review type:",
    format_item = function(item)
      return item
    end,
  }, function(choice)
    if not choice then
      return -- user cancelled
    end

    local event_map = {
      ["Approve"] = "APPROVE",
      ["Comment"] = "COMMENT",
      ["Request Changes"] = "REQUEST_CHANGES",
    }

    callback(event_map[choice])
  end)
end

local function prompt_review_body(event, callback)
  vim.ui.input({ prompt = "Review summary (optional): " }, function(input)
    -- input is nil if user cancelled with <Esc>, "" if they just hit enter
    callback(event, input or "")
  end)
end

function M.create_review(path)
  local path_comments, root_path, path_kind = comments.list_comments_in_path(path)

  if not path_comments or #path_comments == 0 then
    vim.notify("No comments to submit", vim.log.levels.WARN)
    return
  end

  local pr_info, err = get_pr_info()
  if not pr_info then
    vim.notify("No PR found for current branch. Create one first:\n  gh pr create", vim.log.levels.ERROR)
    return
  end

  prompt_review_type(function(event)
    prompt_review_body(event, function(_, body)
      M.submit_review(path_comments, event, body)
    end)
  end)
end

function M.submit_review(path_comments, event, body)
  local review_comments = {}
  for _, c in ipairs(path_comments) do
    table.insert(review_comments, {
      path = c.relative_path,
      side = "RIGHT",
      line = c.line_end,
      body = c.body,
    })
  end

  local payload = {
    commit_id = get_commit_id(),
    event = event,
    body = body,
    comments = review_comments,
  }

  local json_str = vim.json.encode(payload)
  local tmpfile = vim.fn.tempname() .. ".json"
  local f = io.open(tmpfile, "w")
  f:write(json_str)
  f:close()

  local repo_slug = get_repo_slug()
  local pr_number = get_pr_number()

  local cmd = string.format(
    "gh api repos/%s/pulls/%s/reviews --method POST --input %s",
    repo_slug,
    pr_number,
    vim.fn.shellescape(tmpfile)
  )

  local result = vim.fn.system(cmd)
  os.remove(tmpfile)

  if vim.v.shell_error ~= 0 then
    vim.notify("Failed to create PR review:\n" .. result, vim.log.levels.ERROR)
  else
    vim.notify("PR review submitted: " .. event, vim.log.levels.INFO)
  end
end

return M
