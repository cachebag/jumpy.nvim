local M = {}

local render = require("jumpy.render")

local MSG_NO_HUNKS = "jumpy: no hunks"
local MSG_NO_HUNK_UNDER_CURSOR = "jumpy: no hunk under cursor"
local offset_table = {}
local undo_history = {}
local syncing_undo = {}

local function copy_offsets(bufnr)
  return vim.deepcopy(offset_table[bufnr] or {})
end

local function restore_offsets(bufnr, offsets)
  offset_table[bufnr] = vim.deepcopy(offsets or {})
end

local function same_lines(a, b)
  return vim.deep_equal(a, b)
end

local function sync_undo_state(bufnr)
  if syncing_undo[bufnr] or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local history = undo_history[bufnr]
  if not history then
    return
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for i = #history, 1, -1 do
    local entry = history[i]
    if same_lines(lines, entry.before_lines) then
      syncing_undo[bufnr] = true
      render.restore(bufnr, entry.before_state)
      restore_offsets(bufnr, entry.before_offsets)
      syncing_undo[bufnr] = nil
      M._refresh_quickfix()
      return
    end
    if same_lines(lines, entry.after_lines) then
      syncing_undo[bufnr] = true
      render.restore(bufnr, entry.after_state)
      restore_offsets(bufnr, entry.after_offsets)
      syncing_undo[bufnr] = nil
      M._refresh_quickfix()
      return
    end
  end
end

M._sync_undo_state = sync_undo_state

local function record_undo_state(bufnr, before_state, before_offsets, before_lines)
  local history = undo_history[bufnr] or {}
  table.insert(history, {
    before_state = before_state,
    before_offsets = before_offsets,
    before_lines = before_lines,
    after_state = render.snapshot(bufnr),
    after_offsets = copy_offsets(bufnr),
    after_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false),
  })
  undo_history[bufnr] = history
end

function M._clear_undo_history(bufnr)
  undo_history[bufnr] = nil
  offset_table[bufnr] = nil
  syncing_undo[bufnr] = nil
end

vim.api.nvim_create_autocmd("TextChanged", {
  callback = function(args)
    sync_undo_state(args.buf)
  end,
})

vim.api.nvim_create_autocmd("BufWipeout", {
  callback = function(args)
    M._clear_undo_history(args.buf)
  end,
})

local function center_cursor()
  vim.cmd("normal! zz")
end

local function set_cursor_centered(line)
  local line_count = vim.api.nvim_buf_line_count(0)
  local target_line = math.min(math.max(line, 1), line_count)
  vim.api.nvim_win_set_cursor(0, { target_line, 0 })
  center_cursor()
end

local function current_hunk_line(bufnr, idx, hunk)
  local line = hunk.old_start + M._get_offset(bufnr, idx)
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  return math.min(math.max(line, 1), line_count)
end

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
    local hunk_start = current_hunk_line(bufnr, entry.idx, hunk)
    local hunk_end = hunk_start + math.max(hunk.old_count, 1) - 1

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
    local hunk_line = current_hunk_line(bufnr, entry.idx, entry.hunk)
    if hunk_line > cursor_line then
      set_cursor_centered(hunk_line)
      return
    end
  end

  set_cursor_centered(current_hunk_line(bufnr, active[1].idx, active[1].hunk))
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
    local hunk_line = current_hunk_line(bufnr, active[i].idx, active[i].hunk)
    if hunk_line < cursor_line then
      set_cursor_centered(hunk_line)
      return
    end
  end

  set_cursor_centered(current_hunk_line(bufnr, active[#active].idx, active[#active].hunk))
end

function M.accept_hunk(bufnr, hunk_idx)
  local state = render.get_state(bufnr)
  if not state then
    return false
  end
  local hunk = state.hunks[hunk_idx]
  if not hunk then
    return false
  end

  local offset = M._get_offset(bufnr, hunk_idx)
  local before_state = render.snapshot(bufnr)
  local before_offsets = copy_offsets(bufnr)
  local before_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  local start_line = hunk.old_start - 1 + offset
  local end_line = start_line + hunk.old_count

  syncing_undo[bufnr] = true
  vim.api.nvim_buf_set_lines(bufnr, start_line, end_line, false, hunk.added_lines)

  local delta = #hunk.added_lines - hunk.old_count
  M._apply_offset(bufnr, hunk_idx, delta)

  render.clear_hunk(bufnr, hunk_idx)
  if not render.get_state(bufnr) then
    offset_table[bufnr] = nil
  end
  record_undo_state(bufnr, before_state, before_offsets, before_lines)
  syncing_undo[bufnr] = nil
  M._refresh_quickfix()
  return true
end

function M.accept()
  local bufnr = vim.api.nvim_get_current_buf()
  local hunk_idx = M.hunk_at_cursor()

  if not hunk_idx then
    vim.notify(MSG_NO_HUNK_UNDER_CURSOR, vim.log.levels.WARN)
    return
  end

  M.accept_hunk(bufnr, hunk_idx)
  M._advance_to_next(bufnr)
end

function M.reject_hunk(bufnr, hunk_idx)
  local state = render.get_state(bufnr)
  if not state or not state.hunks[hunk_idx] then
    return false
  end
  render.clear_hunk(bufnr, hunk_idx)
  M._refresh_quickfix()
  return true
end

function M.reject()
  local bufnr = vim.api.nvim_get_current_buf()
  local hunk_idx = M.hunk_at_cursor()

  if not hunk_idx then
    vim.notify(MSG_NO_HUNK_UNDER_CURSOR, vim.log.levels.WARN)
    return
  end

  M.reject_hunk(bufnr, hunk_idx)
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

  local before_state = render.snapshot(bufnr)
  local before_offsets = copy_offsets(bufnr)
  local before_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  syncing_undo[bufnr] = true
  for _, entry in ipairs(reversed) do
    local hunk = entry.hunk
    local start_line = hunk.old_start - 1
    local end_line = start_line + hunk.old_count
    vim.api.nvim_buf_set_lines(bufnr, start_line, end_line, false, hunk.added_lines)
  end

  render.clear(bufnr)
  offset_table[bufnr] = nil
  record_undo_state(bufnr, before_state, before_offsets, before_lines)
  syncing_undo[bufnr] = nil
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
  M._setup_quickfix_keymaps()
end

function M._refresh_quickfix(index)
  local quickfix = vim.fn.getqflist({ title = 0, idx = 0 })
  if quickfix.title ~= "jumpy:hunks" then
    return
  end
  local items = M._transform_hunks_to_quickfix(render.get_all_states())
  if #items == 0 then
    vim.fn.setqflist({}, "r", { title = "jumpy:hunks", items = {} })
    vim.cmd("cclose")
    return
  end

  local target_index = math.min(index or quickfix.idx, #items)
  vim.fn.setqflist({}, "r", {
    title = "jumpy:hunks",
    items = items,
    idx = math.max(target_index, 1),
  })
end

function M._transform_hunks_to_quickfix(states)
  local items = {}
  for bufnr, state in pairs(states) do
    for hunk_idx, hunk in pairs(state.hunks) do
      if hunk then
        local text
        if #hunk.added_lines > 0 then
          text = "+ " .. hunk.added_lines[1]
        else
          text = "- " .. hunk.removed_lines[1]
        end

        table.insert(items, {
          bufnr = bufnr,
          lnum = current_hunk_line(bufnr, hunk_idx, hunk),
          col = 1,
          text = text,
          user_data = { bufnr = bufnr, hunk_idx = hunk_idx },
        })
      end
    end
  end

  table.sort(items, function(a, b)
    local a_name = vim.api.nvim_buf_get_name(a.bufnr)
    local b_name = vim.api.nvim_buf_get_name(b.bufnr)
    if a_name ~= b_name then
      return a_name < b_name
    end
    if a.lnum ~= b.lnum then
      return a.lnum < b.lnum
    end
    return a.user_data.hunk_idx < b.user_data.hunk_idx
  end)

  return items
end

local function current_quickfix_hunk()
  local quickfix = vim.fn.getqflist({ title = 0, items = 0, idx = 0 })
  if quickfix.title ~= "jumpy:hunks" then
    return nil
  end

  local item = quickfix.items[quickfix.idx]
  local user_data = item and item.user_data
  if type(user_data) ~= "table" then
    return nil
  end

  return user_data.bufnr, user_data.hunk_idx, quickfix.idx
end

local function advance_quickfix(index)
  local quickfix = vim.fn.getqflist({ title = 0, size = 0 })
  if quickfix.size == 0 then
    return
  end
  vim.cmd("cc " .. math.min(index, quickfix.size))
end

function M.accept_quickfix_hunk()
  local bufnr, hunk_idx, index = current_quickfix_hunk()
  if not bufnr or not M.accept_hunk(bufnr, hunk_idx) then
    M._refresh_quickfix(index)
    vim.notify("jumpy: quickfix hunk is no longer pending", vim.log.levels.WARN)
    return
  end
  M._refresh_quickfix(index)
  advance_quickfix(index)
end

function M.reject_quickfix_hunk()
  local bufnr, hunk_idx, index = current_quickfix_hunk()
  if not bufnr or not M.reject_hunk(bufnr, hunk_idx) then
    M._refresh_quickfix(index)
    vim.notify("jumpy: quickfix hunk is no longer pending", vim.log.levels.WARN)
    return
  end
  M._refresh_quickfix(index)
  advance_quickfix(index)
end

function M._setup_quickfix_keymaps()
  local quickfix_bufnr = vim.fn.getqflist({ qfbufnr = 0 }).qfbufnr
  if quickfix_bufnr == 0 then
    return
  end

  vim.keymap.set("n", "a", M.accept_quickfix_hunk, {
    buffer = quickfix_bufnr,
    silent = true,
    desc = "Accept Jumpy hunk",
  })
  vim.keymap.set("n", "x", M.reject_quickfix_hunk, {
    buffer = quickfix_bufnr,
    silent = true,
    desc = "Reject Jumpy hunk",
  })
end

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

local function get_all_active_hunks()
  local all = {}
  for bufnr, state in pairs(render.get_all_states()) do
    for idx, hunk in pairs(state.hunks) do
      if hunk then
        table.insert(all, { bufnr = bufnr, idx = idx, hunk = hunk })
      end
    end
  end
  table.sort(all, function(a, b)
    local na = vim.api.nvim_buf_get_name(a.bufnr)
    local nb = vim.api.nvim_buf_get_name(b.bufnr)
    if na ~= nb then
      return na < nb
    end
    return a.hunk.old_start < b.hunk.old_start
  end)
  return all
end

local function jump_to(bufnr, line)
  local cur_win = vim.api.nvim_get_current_win()
  local win_cfg = vim.api.nvim_win_get_config(cur_win)
  if win_cfg.relative ~= "" then
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_config(win).relative == "" then
        vim.api.nvim_set_current_win(win)
        break
      end
    end
  end
  vim.cmd("normal! m'")
  vim.api.nvim_win_set_buf(0, bufnr)
  set_cursor_centered(line)
end

function M.first_hunk_any_buf()
  local all = get_all_active_hunks()
  if #all == 0 then
    vim.notify(MSG_NO_HUNKS, vim.log.levels.INFO)
    return
  end
  local entry = all[1]
  jump_to(entry.bufnr, entry.hunk.old_start)
end

function M._advance_to_next(bufnr)
  local active = get_active_hunks(bufnr)
  if #active > 0 then
    local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
    for _, entry in ipairs(active) do
      local hunk_line = current_hunk_line(bufnr, entry.idx, entry.hunk)
      if hunk_line >= cursor_line then
        set_cursor_centered(hunk_line)
        return
      end
    end
    set_cursor_centered(current_hunk_line(bufnr, active[1].idx, active[1].hunk))
  else
    offset_table[bufnr] = nil
    local all = get_all_active_hunks()
    if #all > 0 then
      jump_to(all[1].bufnr, all[1].hunk.old_start)
    else
      vim.cmd("normal! \\<C-o>")
    end
  end
end

return M
