local path = require("jumpy.path")

local M = {}

M.MAX_BYTES = 256 * 1024
M.MAX_LINES = 2000

local RESERVED = {
  lsp = true,
}

local function word_boundary_before(text, pos)
  if pos <= 1 then
    return true
  end
  return not text:sub(pos - 1, pos - 1):match("[%w@]")
end

local function word_boundary_after(text, pos)
  if pos >= #text then
    return true
  end
  return not text:sub(pos + 1, pos + 1):match("[%w]")
end

local function normalize_mention_path(path)
  path = path:gsub("/+$", "")
  path = path:gsub("%.$", "")
  return path
end

local function mention_remove_len(raw)
  local norm_path = normalize_mention_path(raw)
  if raw:sub(-1) == "." and #raw == #norm_path + 1 then
    return #norm_path
  end
  return #raw
end

function M.find_mentions(text)
  local mentions = {}
  local seen = {}
  local search_from = 1

  while search_from <= #text do
    local at = text:find("@", search_from, true)
    if not at then
      break
    end

    if word_boundary_before(text, at) then
      local rest = text:sub(at + 1)
      local raw = rest:match("^([%.%w%-_/]+)")
      local norm_path = raw and normalize_mention_path(raw) or nil
      if norm_path and norm_path ~= "" and not RESERVED[norm_path] and word_boundary_after(text, at + #raw) then
        if not seen[norm_path] then
          seen[norm_path] = true
          table.insert(mentions, norm_path)
        end
        search_from = at + #raw + 1
      else
        search_from = at + 1
      end
    else
      search_from = at + 1
    end
  end

  return mentions
end

local function trim(text)
  return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

function M.strip_mentions(text)
  local stripped = text
  local search_from = 1

  while search_from <= #stripped do
    local at = stripped:find("@", search_from, true)
    if not at then
      break
    end

    if word_boundary_before(stripped, at) then
      local rest = stripped:sub(at + 1)
      local raw = rest:match("^([%.%w%-_/]+)")
      local path = raw and normalize_mention_path(raw) or nil
      if path and path ~= "" and not RESERVED[path] and word_boundary_after(stripped, at + #raw) then
        local remove_len = mention_remove_len(raw)
        stripped = stripped:sub(1, at - 1) .. stripped:sub(at + remove_len + 1)
        search_from = at
      else
        search_from = at + 1
      end
    else
      search_from = at + 1
    end
  end

  return trim((stripped:gsub("%s+", " ")))
end

local function slice_lines(lines, count)
  local out = {}
  for i = 1, math.min(count, #lines) do
    out[i] = lines[i]
  end
  return out
end

function M.truncate_lines(lines)
  local truncated = false
  if #lines > M.MAX_LINES then
    lines = slice_lines(lines, M.MAX_LINES)
    truncated = true
  end
  return lines, truncated
end

function M.find_bufnr(abs_path)
  abs_path = path.normalize_abs(abs_path)
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      local name = vim.api.nvim_buf_get_name(bufnr)
      if name ~= "" and path.normalize_abs(name) == abs_path then
        return bufnr
      end
    end
  end
  return nil
end

function M.open_buffer(abs_path)
  abs_path = path.normalize_abs(abs_path)

  local bufnr = M.find_bufnr(abs_path)
  if bufnr then
    return bufnr
  end

  if vim.fn.filereadable(abs_path) ~= 1 then
    return nil
  end

  bufnr = vim.fn.bufadd(abs_path)
  vim.fn.bufload(bufnr)
  return bufnr
end

function M.read_lines(abs_path, opts)
  opts = opts or {}

  if opts.read_file then
    return opts.read_file(abs_path)
  end

  local bufnr = M.find_bufnr(abs_path)
  if bufnr then
    local lines, truncated = M.truncate_lines(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
    local err = truncated and string.format("file exceeds %d line limit: %s", M.MAX_LINES, abs_path) or nil
    return lines, err, bufnr
  end

  local fd = vim.uv and vim.uv.fs_open(abs_path, "r", 438) or nil
  if not fd then
    return nil, "file not found: " .. abs_path
  end

  local stat = vim.uv.fs_fstat(fd)
  if stat and stat.size > M.MAX_BYTES then
    vim.uv.fs_close(fd)
    return nil, string.format("file exceeds %d byte limit: %s", M.MAX_BYTES, abs_path)
  end

  local data = vim.uv.fs_read(fd, M.MAX_BYTES)
  vim.uv.fs_close(fd)

  if not data then
    return nil, "could not read file: " .. abs_path
  end

  if data:sub(-1) == "\n" then
    data = data:sub(1, -2)
  end

  local lines = data == "" and {} or vim.split(data, "\n", { plain = true })
  local truncated
  lines, truncated = M.truncate_lines(lines)
  if truncated then
    return lines, string.format("file exceeds %d line limit: %s", M.MAX_LINES, abs_path)
  end

  return lines, nil, nil
end

function M.parse(prompt_text, opts)
  opts = opts or {}
  local root = opts.root or path.project_root()
  local mentions = M.find_mentions(prompt_text)
  local tagged = {}
  local errors = {}
  local seen_abs = {}

  if opts.source then
    local src = opts.source
    local abs_path = path.normalize_abs(src.abs_path or path.resolve_path(src.path, root))
    seen_abs[abs_path] = true
    table.insert(tagged, {
      path = src.path or path.rel_path(abs_path, root),
      abs_path = abs_path,
      lines = src.lines,
      bufnr = src.bufnr,
    })
  end

  for _, raw_path in ipairs(mentions) do
    local abs_path = path.resolve_path(raw_path, root)
    if not seen_abs[abs_path] then
      local lines, err, bufnr = M.read_lines(abs_path, opts)

      if not lines then
        table.insert(errors, err or ("could not read: " .. raw_path))
      else
        table.insert(tagged, {
          path = path.rel_path(abs_path, root),
          abs_path = abs_path,
          lines = lines,
          bufnr = bufnr,
        })
        if err then
          table.insert(errors, err)
        end
      end
    end
  end

  return {
    tagged = tagged,
    cleaned_prompt = M.strip_mentions(prompt_text),
    errors = errors,
  }
end

return M
