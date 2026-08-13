local M = {}

local function binding_label(binding)
  if not binding then
    return nil
  end

  return binding.name or binding.commit
end

local function same_binding(left, right)
  if not left or not right or left.kind ~= right.kind then
    return false
  end

  if left.kind == "branch" then
    return left.name == right.name
  end

  return left.commit == right.commit
end

---Decide whether a review session is available for mutation on the current
---binding. Repository sessions are not bound until the first successful
---finding mutation, so empty and legacy records stay readable without being
---rewritten on read. Non-Git targets and detached HEADs are never bound in
---this PR.
---
---When a stored branch binding exists, it takes precedence over the current
---legacy/unbound status. Opening a branch-bound session on detached HEAD,
---a non-Git target, or a different branch is unavailable and reports the
---bound branch name.
---@param data table persisted scope data (may be mutated by M.bind, not here)
---@param current_binding table|nil branch/commit binding from context.git_binding
---@return table session { available, bound_to, binding }
function M.open(data, current_binding)
  local binding = data.session and data.session.binding

  if binding and binding.kind == "branch" then
    local available = false
    if current_binding and current_binding.kind == "branch" then
      available = same_binding(binding, current_binding)
    end
    return {
      available = available,
      bound_to = binding_label(binding),
      binding = binding,
    }
  end

  -- Non-Git targets and detached commits remain unbound and unrestricted.
  if not current_binding or current_binding.kind ~= "branch" then
    return { available = true, bound_to = nil, binding = nil }
  end

  -- Repository sessions start unbound so the first finding mutation can
  -- assign the binding atomically with the mutation.
  return { available = true, bound_to = nil, binding = nil, unbound = true }
end

---Bind a repository session to `current_binding` as part of the first
---successful finding mutation. Does nothing for non-branch targets or when a
---binding already exists.
---@param data table persisted scope data
---@param current_binding table|nil branch/commit binding from context.git_binding
---@return boolean changed
function M.bind(data, current_binding)
  if not current_binding or current_binding.kind ~= "branch" then
    return false
  end

  if data.session and data.session.binding then
    return false
  end

  data.session = data.session or {}
  data.session.binding = current_binding
  return true
end

return M
