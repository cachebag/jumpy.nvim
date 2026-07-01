local M = {}

local ns = vim.api.nvim_create_namespace("jumpy")

local function build_virt_lines(added_lines)
  local virt_lines = {}
  for _, line in ipairs(added_lines) do
    table.insert(virt_lines, { { line, "JumpyAdded" } })
  end
  return virt_lines
end

local function insertion_anchor(bufnr, old_start)
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  local is_eof = old_start > line_count
  local anchor_line = is_eof and line_count - 1 or old_start - 1
  return math.max(0, anchor_line), not is_eof
end

local buf_states = {}

function M.get_state(bufnr)
  return buf_states[bufnr]
end

function M.get_all_states()
  local states = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      local state = M.get_state(buf)
      if state then
        states[buf] = state
      end
    end
  end

  return states
end

function M.show(bufnr, hunks, original_lines, proposed_lines)
  M.clear(bufnr)

  local state = {
    hunks = {},
    original_lines = original_lines,
    proposed_lines = proposed_lines,
    extmark_ids = {},
  }

  local line_offset = 0

  for i, hunk in ipairs(hunks) do
    local display_hunk = {
      removed_lines = hunk.removed_lines,
      added_lines = hunk.added_lines,
      old_start = hunk.old_start,
      old_count = hunk.old_count,
      new_start = hunk.new_start,
      new_count = hunk.new_count,
      buf_line = hunk.old_start - 1,
      extmarks = {},
    }

    for j = 0, hunk.old_count - 1 do
      local line = hunk.old_start - 1 + j
      if line < vim.api.nvim_buf_line_count(bufnr) then
        local id = vim.api.nvim_buf_set_extmark(bufnr, ns, line, 0, {
          line_hl_group = "JumpyRemoved",
          sign_text = "-",
          sign_hl_group = "JumpyRemovedSign",
          priority = 100,
        })
        table.insert(display_hunk.extmarks, id)
      end
    end

    if #hunk.added_lines > 0 then
      local virt_lines = build_virt_lines(hunk.added_lines)

      local anchor_line = math.min(hunk.old_start - 1 + hunk.old_count - 1, vim.api.nvim_buf_line_count(bufnr) - 1)
      anchor_line = math.max(0, anchor_line)

      local id = vim.api.nvim_buf_set_extmark(bufnr, ns, anchor_line, 0, {
        virt_lines = virt_lines,
        virt_lines_above = false,
        priority = 100,
      })
      table.insert(display_hunk.extmarks, id)
    end

    if hunk.old_count == 0 and #hunk.added_lines > 0 then
      for _, eid in ipairs(display_hunk.extmarks) do
        vim.api.nvim_buf_del_extmark(bufnr, ns, eid)
      end
      display_hunk.extmarks = {}

      local virt_lines = build_virt_lines(hunk.added_lines)

      local anchor_line, virt_lines_above = insertion_anchor(bufnr, hunk.old_start)

      local id = vim.api.nvim_buf_set_extmark(bufnr, ns, anchor_line, 0, {
        virt_lines = virt_lines,
        virt_lines_above = virt_lines_above,
        sign_text = "+",
        sign_hl_group = "JumpyAddedSign",
        priority = 100,
      })
      table.insert(display_hunk.extmarks, id)
    end

    state.hunks[i] = display_hunk
    line_offset = line_offset + #hunk.added_lines
  end

  buf_states[bufnr] = state
end

function M.clear(bufnr)
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  buf_states[bufnr] = nil
end

function M.clear_hunk(bufnr, hunk_idx)
  local state = buf_states[bufnr]
  if not state then
    return
  end

  local hunk = state.hunks[hunk_idx]
  if not hunk then
    return
  end

  for _, eid in ipairs(hunk.extmarks) do
    vim.api.nvim_buf_del_extmark(bufnr, ns, eid)
  end

  state.hunks[hunk_idx] = nil

  local any_remaining = false
  for _, h in pairs(state.hunks) do
    if h then
      any_remaining = true
      break
    end
  end

  if not any_remaining then
    buf_states[bufnr] = nil
    vim.notify("jumpy: all hunks resolved", vim.log.levels.INFO)
  end
end

function M.update_hunk_lines(bufnr, hunk_idx, new_added_lines)
  local state = buf_states[bufnr]
  if not state then
    return
  end

  local hunk = state.hunks[hunk_idx]
  if not hunk then
    return
  end

  for _, eid in ipairs(hunk.extmarks) do
    vim.api.nvim_buf_del_extmark(bufnr, ns, eid)
  end
  hunk.extmarks = {}
  hunk.added_lines = new_added_lines

  for j = 0, hunk.old_count - 1 do
    local line = hunk.old_start - 1 + j
    if line < vim.api.nvim_buf_line_count(bufnr) then
      local id = vim.api.nvim_buf_set_extmark(bufnr, ns, line, 0, {
        line_hl_group = "JumpyRemoved",
        sign_text = "-",
        sign_hl_group = "JumpyRemovedSign",
        priority = 100,
      })
      table.insert(hunk.extmarks, id)
    end
  end

  if #new_added_lines > 0 then
    local virt_lines = build_virt_lines(new_added_lines)

    local anchor_line
    local virt_lines_above = false
    if hunk.old_count > 0 then
      anchor_line = math.min(hunk.old_start - 1 + hunk.old_count - 1, vim.api.nvim_buf_line_count(bufnr) - 1)
      anchor_line = math.max(0, anchor_line)
    else
      anchor_line, virt_lines_above = insertion_anchor(bufnr, hunk.old_start)
    end

    local id = vim.api.nvim_buf_set_extmark(bufnr, ns, anchor_line, 0, {
      virt_lines = virt_lines,
      virt_lines_above = virt_lines_above,
      priority = 100,
    })
    table.insert(hunk.extmarks, id)
  end
end

function M.get_namespace()
  return ns
end

return M
