-- Read-only "inspect" overlay for a single recorded hunk. Unlike jumpy.render
-- (the live accept/reject workflow), this paints a purely visual before/after
-- diff in yellow so you can revisit what a hunk changed -- including hunks that
-- were already accepted -- while cycling through a session in the sidebar.
--
-- The overlay shows the side currently present in the buffer as highlighted
-- lines, and the opposite side as virtual lines beneath them:
--   * accepted hunk  -> buffer holds the added lines; removed lines shown virt
--   * otherwise      -> buffer holds the original lines; added lines shown virt
--
-- Anchoring is best-effort: within the same session the recorded old_start is
-- accurate; across sessions the file may have drifted, so we re-anchor by
-- searching for the present side's first line near the recorded position.
local M = {}

local function has_vim()
  return type(vim) == "table"
end

local ns = has_vim() and vim.api.nvim_create_namespace("jumpy_inspect") or nil

-- Buffers we have painted, so clear_all can wipe every overlay.
local active = {}

local SEARCH_WINDOW = 300

--- Which side of the diff is currently in the buffer for a hunk of `status`,
--- and which side to show as virtual context.
--- @return table present, table other, string sign  -- sign labels the virt side
function M._present_side(hunk, status)
  local removed = hunk.removed_lines or {}
  local added = hunk.added_lines or {}
  if status == "accepted" then
    -- The change was applied: the buffer holds the new (added) lines; the old
    -- (removed) lines are gone, so we show them as context.
    return added, removed, "-"
  end
  -- Pending / rejected / superseded: the buffer still holds the original
  -- (removed) lines; the proposed (added) lines are the context.
  return removed, added, "+"
end

--- Best-effort 1-based line where the present side begins in `buf_lines`.
--- Pure (no vim) so it can be unit-tested.
function M._anchor(buf_lines, hunk, status)
  local present = M._present_side(hunk, status)
  local hint = hunk.old_start or 1
  local total = #buf_lines

  if #present == 0 then
    -- Nothing present to anchor on (pure insertion not yet applied, or pure
    -- deletion already applied): clamp the recorded position into range.
    return math.max(1, math.min(hint, total + 1))
  end

  local needle = present[1]
  if buf_lines[hint] == needle then
    return hint
  end

  local lo = math.max(1, hint - SEARCH_WINDOW)
  local hi = math.min(total, hint + SEARCH_WINDOW)
  local best, best_dist
  for i = lo, hi do
    if buf_lines[i] == needle then
      local dist = math.abs(i - hint)
      if not best_dist or dist < best_dist then
        best, best_dist = i, dist
      end
    end
  end

  return best or math.max(1, math.min(hint, total))
end

--- Paint the before/after overlay for `hunk` in `bufnr`. Returns the 1-based
--- anchor line so callers can position the cursor, or nil if nothing was drawn.
function M.show(bufnr, hunk, status)
  if not (has_vim() and bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
    return nil
  end
  -- Requires enriched geometry; older sessions won't have it.
  if not hunk or not hunk.old_start then
    return nil
  end

  M.clear(bufnr)

  local buf_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local total = #buf_lines
  local present, other, sign = M._present_side(hunk, status)
  local anchor = M._anchor(buf_lines, hunk, status)

  local ids = {}

  for j = 0, #present - 1 do
    local line0 = anchor - 1 + j
    if line0 >= 0 and line0 < total then
      ids[#ids + 1] = vim.api.nvim_buf_set_extmark(bufnr, ns, line0, 0, {
        line_hl_group = "JumpyInspect",
        sign_text = "▍",
        sign_hl_group = "JumpyInspectSign",
        priority = 200,
      })
    end
  end

  if #other > 0 then
    local virt_lines = {}
    for _, line in ipairs(other) do
      virt_lines[#virt_lines + 1] = { { sign .. " " .. line, "JumpyInspectOther" } }
    end

    local anchor0
    if #present > 0 then
      anchor0 = math.min(anchor - 1 + #present - 1, total - 1)
    else
      anchor0 = math.min(anchor - 1, total - 1)
    end
    anchor0 = math.max(0, anchor0)

    ids[#ids + 1] = vim.api.nvim_buf_set_extmark(bufnr, ns, anchor0, 0, {
      virt_lines = virt_lines,
      virt_lines_above = false,
      priority = 200,
    })
  end

  active[bufnr] = ids
  return anchor
end

--- Remove the overlay from a single buffer.
function M.clear(bufnr)
  if not (has_vim() and bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
    active[bufnr] = nil
    return
  end
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  active[bufnr] = nil
end

--- Remove overlays from every buffer we painted.
function M.clear_all()
  if not has_vim() then
    active = {}
    return
  end
  for bufnr in pairs(active) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
    end
  end
  active = {}
end

function M.get_namespace()
  return ns
end

return M
