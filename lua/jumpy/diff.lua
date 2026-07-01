local M = {}

-- Myers diff algorithm (simplified O(ND) for line-level diffing)
-- Returns a list of edit operations: "equal", "insert", "delete"

local function myers_diff(old_lines, new_lines)
  local n = #old_lines
  local m = #new_lines
  local max = n + m

  if max == 0 then
    return {}
  end

  local v = {}
  v[1] = 0
  local trace = {}
  local done = false

  for d = 0, max do
    if done then
      break
    end

    local snapshot = {}
    for k, val in pairs(v) do
      snapshot[k] = val
    end
    table.insert(trace, snapshot)

    for k = -d, d, 2 do
      local x
      if k == -d or (k ~= d and (v[k - 1] or 0) < (v[k + 1] or 0)) then
        x = v[k + 1] or 0
      else
        x = (v[k - 1] or 0) + 1
      end

      local y = x - k
      while x < n and y < m and old_lines[x + 1] == new_lines[y + 1] do
        x = x + 1
        y = y + 1
      end

      v[k] = x

      if x >= n and y >= m then
        done = true
        break
      end
    end
  end

  local edits = {}
  local x, y = n, m

  for d = #trace, 1, -1 do
    local prev_v = trace[d]
    local k = x - y

    local prev_k
    if k == -(d - 1) or (k ~= (d - 1) and (prev_v[k - 1] or 0) < (prev_v[k + 1] or 0)) then
      prev_k = k + 1
    else
      prev_k = k - 1
    end

    local prev_x = prev_v[prev_k] or 0
    local prev_y = prev_x - prev_k

    -- diagonal (equal)
    while x > prev_x and y > prev_y do
      x = x - 1
      y = y - 1
      table.insert(edits, 1, { op = "equal", old_idx = x + 1, new_idx = y + 1 })
    end

    if d > 1 then
      if x == prev_x then
        table.insert(edits, 1, { op = "insert", old_idx = x + 1, new_idx = y })
        y = y - 1
      else
        table.insert(edits, 1, { op = "delete", old_idx = x })
        x = x - 1
      end
    end
  end

  return edits
end

-- Group edits into contiguous hunks with context
function M.compute(old_lines, new_lines)
  local edits = myers_diff(old_lines, new_lines)
  local hunks = {}
  local current_hunk = nil

  for _, edit in ipairs(edits) do
    if edit.op == "equal" then
      if current_hunk then
        table.insert(hunks, current_hunk)
        current_hunk = nil
      end
    else
      if not current_hunk then
        current_hunk = {
          old_start = nil,
          old_count = 0,
          new_start = nil,
          new_count = 0,
          removed_lines = {},
          added_lines = {},
        }
      end

      if edit.op == "delete" then
        if not current_hunk.old_start then
          current_hunk.old_start = edit.old_idx
        end
        current_hunk.old_count = current_hunk.old_count + 1
        table.insert(current_hunk.removed_lines, old_lines[edit.old_idx])
      elseif edit.op == "insert" then
        if not current_hunk.old_start then
          current_hunk.old_start = edit.old_idx
        end
        if not current_hunk.new_start then
          current_hunk.new_start = edit.new_idx
        end
        current_hunk.new_count = current_hunk.new_count + 1
        table.insert(current_hunk.added_lines, new_lines[edit.new_idx])
      end
    end
  end

  if current_hunk then
    table.insert(hunks, current_hunk)
  end

  -- fill in missing start positions
  for _, hunk in ipairs(hunks) do
    if not hunk.old_start then
      hunk.old_start = hunk.new_start or 1
    end
    if not hunk.new_start then
      hunk.new_start = hunk.old_start
    end
  end

  return hunks
end

return M
