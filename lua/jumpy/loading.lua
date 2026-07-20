local M = {}

local FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

-- Refcounted spinner: each in-flight request calls start()/stop() once, so
-- parallel requests share one spinner that reports how many are running.
local count = 0
local timer
local dismiss_timer
local frame_idx = 1
local start_time = 0
local spin_win, spin_buf
local err_win, err_buf

local function close_float(win, buf)
  if win and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_close, win, true)
  end
  if buf and vim.api.nvim_buf_is_valid(buf) then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end
end

local function close_spinner()
  close_float(spin_win, spin_buf)
  spin_win, spin_buf = nil, nil
end

local function close_error()
  close_float(err_win, err_buf)
  err_win, err_buf = nil, nil
end

local function cancel_dismiss()
  if dismiss_timer then
    dismiss_timer:stop()
    dismiss_timer:close()
    dismiss_timer = nil
  end
end

local function float_width(text)
  local w = math.min(vim.api.nvim_strwidth(text) + 4, vim.o.columns - 4)
  return math.max(w, 20)
end

local function spinner_row()
  return math.max(0, vim.o.lines - vim.o.cmdheight - 4)
end

local function open_float(text, row)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"

  local w = float_width(text)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { text })

  local win = vim.api.nvim_open_win(buf, false, {
    relative = "editor",
    width = w,
    height = 1,
    row = row,
    col = math.max(0, math.floor((vim.o.columns - w) / 2)),
    style = "minimal",
    border = "rounded",
    zindex = 300,
    focusable = false,
    title = " jumpy ",
    title_pos = "center",
  })
  vim.wo[win].wrap = false

  return win, buf
end

local function spinner_text()
  local secs = math.floor((vim.loop.now() - start_time) / 1000)
  local elapsed = secs >= 1 and string.format(" %ds", secs) or ""
  local frame = FRAMES[frame_idx]
  if count > 1 then
    return string.format("  %s  waiting for %d requests…%s  ", frame, count, elapsed)
  end
  return string.format("  %s  waiting for model…%s  ", frame, elapsed)
end

local function update_spinner()
  if not spin_buf or not vim.api.nvim_buf_is_valid(spin_buf) then
    return
  end
  local text = spinner_text()
  vim.api.nvim_buf_set_lines(spin_buf, 0, -1, false, { text })
  if spin_win and vim.api.nvim_win_is_valid(spin_win) then
    vim.api.nvim_win_set_width(spin_win, float_width(text))
  end
end

function M.start()
  count = count + 1

  if count > 1 then
    update_spinner()
    return
  end

  frame_idx = 1
  start_time = vim.loop.now()
  close_spinner()
  spin_win, spin_buf = open_float(spinner_text(), spinner_row())

  timer = vim.loop.new_timer()
  timer:start(
    80,
    80,
    vim.schedule_wrap(function()
      if count == 0 then
        return
      end
      frame_idx = frame_idx % #FRAMES + 1
      update_spinner()
    end)
  )
end

function M.stop()
  if count == 0 then
    return
  end
  count = count - 1

  if count > 0 then
    update_spinner()
    return
  end

  if timer then
    timer:stop()
    timer:close()
    timer = nil
  end
  close_spinner()
end

function M.cancel()
  local requests = require("jumpy.requests")
  local n = requests.cancel_all()
  if n > 0 then
    vim.notify(string.format("jumpy: cancelled %d request(s)", n), vim.log.levels.INFO)
  else
    vim.notify("jumpy: no requests in flight", vim.log.levels.INFO)
  end
end

function M.is_active()
  return count > 0
end

-- Transient error toast; independent of the spinner so one failed request
-- doesn't hide the progress of others still running.
function M.error(msg)
  cancel_dismiss()
  close_error()

  local row = spinner_row()
  if count > 0 then
    row = math.max(0, row - 3)
  end
  err_win, err_buf = open_float(string.format("  ✗ %s  ", msg), row)

  dismiss_timer = vim.loop.new_timer()
  dismiss_timer:start(
    4000,
    0,
    vim.schedule_wrap(function()
      cancel_dismiss()
      close_error()
    end)
  )
end

return M
