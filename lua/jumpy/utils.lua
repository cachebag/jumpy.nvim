local M = {}

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
