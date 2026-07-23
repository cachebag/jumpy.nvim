local M = {}

--- Whether `buf` is a normal, editable file buffer that Jumpy can act on.
--- Returns ok(boolean) and, when not ok, a user-facing reason string. This lets
--- entry points fail with a clear hint instead of trying to edit the session
--- sidebar, a help window, quickfix, a terminal, etc.
--- @param buf number|nil defaults to the current buffer
--- @return boolean ok, string|nil reason
function M.check_source_buffer(buf)
  buf = buf or vim.api.nvim_get_current_buf()

  if vim.bo[buf].filetype == "jumpy_session" then
    return false, "jumpy: you're in the session sidebar — press <CR> or <Tab> to jump into a file first"
  end

  local buftype = vim.bo[buf].buftype
  if buftype ~= "" then
    return false, string.format("jumpy: this isn't an editable file buffer (%s)", buftype)
  end

  return true
end

function M.get_visual_selection(bufnr)
  bufnr = bufnr or 0

  local mode = vim.api.nvim_get_mode().mode

  local start_pos = vim.fn.getpos("v")
  local end_pos = vim.fn.getpos(".")

  local start_line = start_pos[2]
  local end_line = end_pos[2]

  if start_line > end_line or (start_line == end_line) then
    start_line, end_line = end_line, start_line
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, start_line - 1, end_line, false)

  if #lines == 0 then
    return nil
  end

  return {
    text = table.concat(lines, "\n"),
    start_line = start_line,
    end_line = end_line,
    mode = mode,
  }
end

return M
