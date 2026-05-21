local M = {}

local ns = vim.api.nvim_create_namespace("jumpy")

local buf_states = {}

function M.get_state(bufnr)
  return buf_states[bufnr]
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
      local virt_lines = {}
      for _, added_line in ipairs(hunk.added_lines) do
        table.insert(virt_lines, { { added_line, "JumpyAdded" } })
      end

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

      local virt_lines = {}
      for _, added_line in ipairs(hunk.added_lines) do
        table.insert(virt_lines, { { added_line, "JumpyAdded" } })
      end

      local anchor_line = math.max(0, hunk.old_start - 1)
      anchor_line = math.min(anchor_line, vim.api.nvim_buf_line_count(bufnr) - 1)

      local id = vim.api.nvim_buf_set_extmark(bufnr, ns, anchor_line, 0, {
        virt_lines = virt_lines,
        virt_lines_above = anchor_line ~= 0,
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
    local virt_lines = {}
    for _, added_line in ipairs(new_added_lines) do
      table.insert(virt_lines, { { added_line, "JumpyAdded" } })
    end

    local anchor_line
    if hunk.old_count > 0 then
      anchor_line = math.min(hunk.old_start - 1 + hunk.old_count - 1, vim.api.nvim_buf_line_count(bufnr) - 1)
      anchor_line = math.max(0, anchor_line)
    else
      anchor_line = math.max(0, hunk.old_start - 1)
      anchor_line = math.min(anchor_line, vim.api.nvim_buf_line_count(bufnr) - 1)
    end

    local id = vim.api.nvim_buf_set_extmark(bufnr, ns, anchor_line, 0, {
      virt_lines = virt_lines,
      virt_lines_above = (hunk.old_count == 0),
      priority = 100,
    })
    table.insert(hunk.extmarks, id)
  end
end

function M.get_namespace()
  return ns
end

return M
