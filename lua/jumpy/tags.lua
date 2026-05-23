local M = {}

-- TODO: hook into prompt._submit, stash result on state.tagged_files

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
      local path = rest:match("^([%.%w%-_/]+)")
      if path and path ~= "" and not RESERVED[path] and word_boundary_after(text, at + #path) then
        if not seen[path] then
          seen[path] = true
          table.insert(mentions, path)
        end
        search_from = at + #path + 1
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
  for _, path in ipairs(M.find_mentions(text)) do
    stripped = stripped:gsub("%f[%w@]@" .. path:gsub("([%-%.%+%[%]%(%)%$%^%%%?%*])", "%%%1") .. "%f[%W]", "")
  end
  return trim((stripped:gsub("%s+", " ")))
end

function M.normalize_abs(path)
  if vim and vim.fn and vim.fn.fnamemodify then
    path = vim.fn.fnamemodify(path, ":p")
  end
  if path:sub(-1) == "/" then
    path = path:sub(1, -2)
  end
  return path
end

function M.resolve_path(raw_path, root)
  root = M.normalize_abs(root or (vim and vim.fn and vim.fn.getcwd() or "."))
  if raw_path:sub(1, 1) == "/" then
    return M.normalize_abs(raw_path)
  end
  return M.normalize_abs(root .. "/" .. raw_path)
end

function M.rel_path(abs_path, root)
  abs_path = M.normalize_abs(abs_path)
  root = M.normalize_abs(root)
  local prefix = root .. "/"
  if abs_path:sub(1, #prefix) == prefix then
    return abs_path:sub(#prefix + 1)
  end
  return abs_path
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

function M.project_root()
  local cwd = vim.fn.getcwd()
  if vim.system then
    local result = vim.system({ "git", "rev-parse", "--show-toplevel" }, { cwd = cwd }):wait()
    if result.code == 0 then
      local root = vim.trim(result.stdout or "")
      if root ~= "" then
        return M.normalize_abs(root)
      end
    end
  end
  return M.normalize_abs(cwd)
end

function M.find_bufnr(abs_path)
  -- TODO: open the file if no buffer exists yet (probably at apply time)
  abs_path = M.normalize_abs(abs_path)
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      local name = vim.api.nvim_buf_get_name(bufnr)
      if name ~= "" and M.normalize_abs(name) == abs_path then
        return bufnr
      end
    end
  end
  return nil
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
  -- TODO: should probably always include the source buffer too, even without @
  opts = opts or {}
  local root = opts.root or M.project_root()
  local mentions = M.find_mentions(prompt_text)
  local tagged = {}
  local errors = {}

  for _, raw_path in ipairs(mentions) do
    local abs_path = M.resolve_path(raw_path, root)
    local lines, err, bufnr = M.read_lines(abs_path, opts)

    if not lines then
      table.insert(errors, err or ("could not read: " .. raw_path))
    else
      table.insert(tagged, {
        path = M.rel_path(abs_path, root),
        abs_path = abs_path,
        lines = lines,
        bufnr = bufnr,
      })
      if err then
        table.insert(errors, err)
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
