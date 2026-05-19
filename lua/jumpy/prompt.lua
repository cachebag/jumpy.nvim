local M = {}

local state = {
  win = nil,
  buf = nil,
  source_buf = nil,
  reprompt_hunk_idx = nil,
}

local function create_float(title, initial_lines)
  local width = math.floor(vim.o.columns * 0.6)
  local height = 5
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].filetype = "jumpy_prompt"

  if initial_lines then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, initial_lines)
  end

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = title or " jumpy ",
    title_pos = "center",
  })

  vim.wo[win].winblend = 0
  vim.cmd("startinsert")

  return buf, win
end

function M.open()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_set_current_win(state.win)
    return
  end

  state.source_buf = vim.api.nvim_get_current_buf()
  state.reprompt_hunk_idx = nil
  state.buf, state.win = create_float(" jumpy ")

  M._set_submit_keymap()
end

function M.reprompt()
  local nav = require("jumpy.navigate")
  local hunk_idx = nav.hunk_at_cursor()
  if not hunk_idx then
    vim.notify("jumpy: no hunk under cursor", vim.log.levels.WARN)
    return
  end

  state.source_buf = vim.api.nvim_get_current_buf()
  state.reprompt_hunk_idx = hunk_idx
  state.buf, state.win = create_float(" jumpy: reprompt this hunk ")

  M._set_submit_keymap()
end

function M._set_submit_keymap()
  vim.keymap.set({ "n", "i" }, "<CR>", function()
    M._submit()
  end, { buffer = state.buf, silent = true })

  vim.keymap.set("n", "<Esc>", function()
    M._close()
  end, { buffer = state.buf, silent = true })

  vim.keymap.set("n", "q", function()
    M._close()
  end, { buffer = state.buf, silent = true })
end

function M._submit()
  local lines = vim.api.nvim_buf_get_lines(state.buf, 0, -1, false)
  local prompt_text = table.concat(lines, "\n")

  if vim.trim(prompt_text) == "" then
    vim.notify("jumpy: empty prompt", vim.log.levels.WARN)
    return
  end

  M._close()

  local source_buf = state.source_buf
  local source_lines = vim.api.nvim_buf_get_lines(source_buf, 0, -1, false)
  local filetype = vim.bo[source_buf].filetype
  local reprompt_idx = state.reprompt_hunk_idx

  local llm = require("jumpy.llm")

  if reprompt_idx then
    local render = require("jumpy.render")
    local hunk_state = render.get_state(source_buf)
    if not hunk_state or not hunk_state.hunks[reprompt_idx] then
      vim.notify("jumpy: hunk no longer exists", vim.log.levels.WARN)
      return
    end

    local hunk = hunk_state.hunks[reprompt_idx]
    local context = {
      original_lines = hunk.removed_lines,
      proposed_lines = hunk.added_lines,
      prompt = prompt_text,
      filetype = filetype,
    }

    llm.reprompt(context, function(new_lines)
      vim.schedule(function()
        local nav = require("jumpy.navigate")
        nav.replace_hunk(source_buf, reprompt_idx, new_lines)
        vim.notify("jumpy: hunk updated", vim.log.levels.INFO)
      end)
    end)
  else
    local context = {
      file_contents = table.concat(source_lines, "\n"),
      prompt = prompt_text,
      filetype = filetype,
    }

    llm.request(context, function(response_text)
      vim.schedule(function()
        if not vim.api.nvim_buf_is_valid(source_buf) then
          vim.notify("jumpy: buffer closed, discarding response", vim.log.levels.WARN)
          return
        end

        local diff = require("jumpy.diff")
        local render = require("jumpy.render")
        local patch = require("jumpy.patch")

        local proposed_lines, unmatched = patch.apply(source_lines, response_text)
        if unmatched > 0 then
          vim.notify(string.format("jumpy: %d block(s) could not be matched", unmatched), vim.log.levels.WARN)
        end
        local hunks = diff.compute(source_lines, proposed_lines)

        if #hunks == 0 then
          vim.notify("jumpy: no changes proposed", vim.log.levels.INFO)
          return
        end

        render.show(source_buf, hunks, source_lines, proposed_lines)
        vim.notify(string.format("jumpy: %d hunk(s) proposed", #hunks), vim.log.levels.INFO)

        local nav = require("jumpy.navigate")
        nav.next_hunk()
      end)
    end)
  end
end

function M._close()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_win_close(state.win, true)
  end
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    vim.api.nvim_buf_delete(state.buf, { force = true })
  end
  state.win = nil
  state.buf = nil
  vim.cmd("stopinsert")
end

return M
