local M = {}

local render = require("jumpy.render")

local MSG_NO_HUNKS = "jumpy: no hunks"
local MSG_NO_HUNK_UNDER_CURSOR = "jumpy: no hunk under cursor"

local function get_active_hunks(bufnr)
  local state = render.get_state(bufnr)
  if not state then
    return {}
  end

  local active = {}
  for idx, hunk in pairs(state.hunks) do
    if hunk then
      table.insert(active, { idx = idx, hunk = hunk })
    end
  end

  table.sort(active, function(a, b)
    return a.hunk.old_start < b.hunk.old_start
  end)

  return active
end

function M.hunk_at_cursor()
  local bufnr = vim.api.nvim_get_current_buf()
  local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
  local active = get_active_hunks(bufnr)

  for _, entry in ipairs(active) do
    local hunk = entry.hunk
    local hunk_start = hunk.old_start
    local hunk_end = hunk.old_start + math.max(hunk.old_count, 1) - 1

    if cursor_line >= hunk_start and cursor_line <= hunk_end then
      return entry.idx
    end
  end

  return nil
end

function M.next_hunk()
  local bufnr = vim.api.nvim_get_current_buf()
  local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
  local active = get_active_hunks(bufnr)

  if #active == 0 then
    vim.notify(MSG_NO_HUNKS, vim.log.levels.INFO)
    return
  end

  for _, entry in ipairs(active) do
    if entry.hunk.old_start > cursor_line then
      vim.api.nvim_win_set_cursor(0, { entry.hunk.old_start, 0 })
      return
    end
  end

  vim.api.nvim_win_set_cursor(0, { active[1].hunk.old_start, 0 })
end

function M.prev_hunk()
  local bufnr = vim.api.nvim_get_current_buf()
  local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
  local active = get_active_hunks(bufnr)

  if #active == 0 then
    vim.notify(MSG_NO_HUNKS, vim.log.levels.INFO)
    return
  end

  for i = #active, 1, -1 do
    if active[i].hunk.old_start < cursor_line then
      vim.api.nvim_win_set_cursor(0, { active[i].hunk.old_start, 0 })
      return
    end
  end

  vim.api.nvim_win_set_cursor(0, { active[#active].hunk.old_start, 0 })
end

function M.accept()
  local bufnr = vim.api.nvim_get_current_buf()
  local hunk_idx = M.hunk_at_cursor()

  if not hunk_idx then
    vim.notify(MSG_NO_HUNK_UNDER_CURSOR, vim.log.levels.WARN)
    return
  end

  local state = render.get_state(bufnr)
  local hunk = state.hunks[hunk_idx]

  local offset = M._get_offset(bufnr, hunk_idx)

  local start_line = hunk.old_start - 1 + offset
  local end_line = start_line + hunk.old_count

  vim.api.nvim_buf_set_lines(bufnr, start_line, end_line, false, hunk.added_lines)

  local delta = #hunk.added_lines - hunk.old_count
  M._apply_offset(bufnr, hunk_idx, delta)

  render.clear_hunk(bufnr, hunk_idx)
  M._refresh_quickfix()
  M._advance_to_next(bufnr)
end

function M.reject()
  local bufnr = vim.api.nvim_get_current_buf()
  local hunk_idx = M.hunk_at_cursor()

  if not hunk_idx then
    vim.notify(MSG_NO_HUNK_UNDER_CURSOR, vim.log.levels.WARN)
    return
  end

  render.clear_hunk(bufnr, hunk_idx)
  M._refresh_quickfix()
  M._advance_to_next(bufnr)
end

function M.accept_all()
  local bufnr = vim.api.nvim_get_current_buf()
  local active = get_active_hunks(bufnr)

  if #active == 0 then
    vim.notify(MSG_NO_HUNKS, vim.log.levels.INFO)
    return
  end

  local reversed = {}
  for i = #active, 1, -1 do
    table.insert(reversed, active[i])
  end

  for _, entry in ipairs(reversed) do
    local hunk = entry.hunk
    local start_line = hunk.old_start - 1
    local end_line = start_line + hunk.old_count
    vim.api.nvim_buf_set_lines(bufnr, start_line, end_line, false, hunk.added_lines)
  end

  render.clear(bufnr)
  M._refresh_quickfix()
  vim.notify("jumpy: all hunks accepted", vim.log.levels.INFO)
end

function M.reject_all()
  local bufnr = vim.api.nvim_get_current_buf()
  render.clear(bufnr)
  M._refresh_quickfix()
  vim.notify("jumpy: all hunks rejected", vim.log.levels.INFO)
end

function M.replace_hunk(bufnr, hunk_idx, new_lines)
  render.update_hunk_lines(bufnr, hunk_idx, new_lines)
  M._refresh_quickfix()
end

function M.add_hunks_to_quickfix()
  local states = render.get_all_states()
  local items = M._transform_hunks_to_quickfix(states)

  if #items == 0 then
    vim.notify(MSG_NO_HUNKS, vim.log.levels.INFO)
    return
  end

  vim.fn.setqflist({}, " ", { title = "jumpy:hunks", items = items })
  vim.cmd("copen")
end

function M._refresh_quickfix()
  if vim.fn.getqflist({ title = 0 }).title ~= "jumpy:hunks" then
    return
  end
  local items = M._transform_hunks_to_quickfix(render.get_all_states())
  vim.fn.setqflist({}, "r", { title = "jumpy:hunks", items = items })
end

function M._transform_hunks_to_quickfix(states)
  local items = {}
  for bufnr, state in pairs(states) do
    for _, hunk in pairs(state.hunks) do
      if hunk then
        local text
        if #hunk.added_lines > 0 then
          text = "+ " .. hunk.added_lines[1]
        else
          text = "- " .. hunk.removed_lines[1]
        end

        table.insert(items, {
          bufnr = bufnr,
          lnum = hunk.old_start,
          col = 1,
          text = text,
        })
      end
    end
  end

  return items
end

local offset_table = {}

function M._get_offset(bufnr, hunk_idx)
  if not offset_table[bufnr] then
    offset_table[bufnr] = {}
  end
  return offset_table[bufnr][hunk_idx] or 0
end

function M._apply_offset(bufnr, accepted_idx, delta)
  if not offset_table[bufnr] then
    offset_table[bufnr] = {}
  end

  local state = render.get_state(bufnr)
  if not state then
    return
  end

  for idx, hunk in pairs(state.hunks) do
    if hunk and idx > accepted_idx then
      offset_table[bufnr][idx] = (offset_table[bufnr][idx] or 0) + delta
    end
  end
end

function M._advance_to_next(bufnr)
  local active = get_active_hunks(bufnr)
  if #active > 0 then
    local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
    for _, entry in ipairs(active) do
      if entry.hunk.old_start >= cursor_line then
        vim.api.nvim_win_set_cursor(0, { entry.hunk.old_start, 0 })
        return
      end
    end
    vim.api.nvim_win_set_cursor(0, { active[1].hunk.old_start, 0 })
  else
    offset_table[bufnr] = nil
  end
end

return M
