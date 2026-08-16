local M = {}

function M.merge(base, overrides)
  local out = {}
  for k, v in pairs(base) do
    out[k] = v
  end
  for k, v in pairs(overrides or {}) do
    out[k] = v
  end
  return out
end

return M
