local M = {}

local function split_lines(text)
  if vim and vim.split then
    return vim.split(text, "\n", { plain = true })
  end
  local lines = {}
  local start = 1
  while true do
    local pos = text:find("\n", start, true)
    if pos then
      table.insert(lines, text:sub(start, pos - 1))
      start = pos + 1
    else
      table.insert(lines, text:sub(start))
      break
    end
  end
  return lines
end

local function shallow_copy(t)
  if vim and vim.deepcopy then
    return vim.deepcopy(t)
  end
  local copy = {}
  for _, v in ipairs(t) do
    table.insert(copy, v)
  end
  return copy
end

local function find_lines(haystack, needle)
  if #needle == 0 then
    return nil
  end
  for i = 1, #haystack - #needle + 1 do
    local match = true
    for j = 1, #needle do
      if haystack[i + j - 1] ~= needle[j] then
        match = false
        break
      end
    end
    if match then
      return i
    end
  end
  return nil
end

local function parse_search_marker(line)
  local rest = line:match("^<<<< SEARCH%s*(.*)$")
  if rest == nil then
    return nil
  end
  rest = rest:match("^%s*(.-)%s*$")
  if rest == "" then
    return nil
  end
  return rest
end

local function normalize_block_path(raw_path)
  raw_path = raw_path:gsub("^%./", "")
  raw_path = raw_path:gsub("^path/", "")
  raw_path = raw_path:gsub("/+", "/")
  return raw_path
end

-- Pick file for a SEARCH/REPLACE block: normalized path when it exists in context;
-- pathless blocks use content match, then primary. An explicit path not in context
-- is returned as-is so apply_by_file counts those blocks unmatched (never steal
-- matches from sibling files).
local function resolve_block_path(block, files_by_path, primary_path)
  local resolved

  if block.path then
    local normalized = normalize_block_path(block.path)
    if files_by_path[normalized] then
      resolved = normalized
    else
      return normalized
    end
  end

  if not resolved and #block.search > 0 then
    for file_path, lines in pairs(files_by_path) do
      if find_lines(lines, block.search) then
        resolved = file_path
        break
      end
    end
  end

  if not resolved then
    resolved = primary_path
  end

  return resolved
end

function M.parse(text)
  local blocks = {}
  local lines = split_lines(text)
  local i = 1

  while i <= #lines do
    local path = parse_search_marker(lines[i])
    if path ~= nil or lines[i]:match("^<<<< SEARCH%s*$") then
      local search_lines = {}
      local replace_lines = {}
      i = i + 1

      while i <= #lines and not lines[i]:match("^====%s*$") do
        table.insert(search_lines, lines[i])
        i = i + 1
      end

      i = i + 1 -- skip ====

      while i <= #lines and not lines[i]:match("^>>>> REPLACE%s*$") do
        table.insert(replace_lines, lines[i])
        i = i + 1
      end

      table.insert(blocks, {
        path = path,
        search = search_lines,
        replace = replace_lines,
      })
    end
    i = i + 1
  end

  return blocks
end

local function apply_blocks(original_lines, blocks)
  local lines = shallow_copy(original_lines)

  local unmatched = 0

  for _, block in ipairs(blocks) do
    local pos = find_lines(lines, block.search)
    if pos then
      local new = {}
      for j = 1, pos - 1 do
        table.insert(new, lines[j])
      end
      for _, l in ipairs(block.replace) do
        table.insert(new, l)
      end
      for j = pos + #block.search, #lines do
        table.insert(new, lines[j])
      end
      lines = new
    else
      unmatched = unmatched + 1
    end
  end

  return lines, unmatched
end

function M.apply(original_lines, response_text)
  local blocks = M.parse(response_text)

  if #blocks == 0 then
    return split_lines(response_text), 0
  end

  return apply_blocks(original_lines, blocks)
end

function M.apply_by_file(files_by_path, response_text, primary_path)
  assert(primary_path, "apply_by_file requires a primary_path")

  local blocks = M.parse(response_text)

  if #blocks == 0 then
    if files_by_path[primary_path] then
      local lines, unmatched = M.apply(files_by_path[primary_path], response_text)
      return { [primary_path] = { lines = lines, unmatched = unmatched } }, unmatched
    end
    return {}, 0
  end

  local grouped = {}
  for _, block in ipairs(blocks) do
    local key = resolve_block_path(block, files_by_path, primary_path)
    grouped[key] = grouped[key] or {}
    table.insert(grouped[key], block)
  end

  local results = {}
  local total_unmatched = 0

  for path, file_blocks in pairs(grouped) do
    local original = files_by_path[path]
    if not original then
      total_unmatched = total_unmatched + #file_blocks
    else
      local lines, unmatched = apply_blocks(original, file_blocks)
      results[path] = { lines = lines, unmatched = unmatched }
      total_unmatched = total_unmatched + unmatched
    end
  end

  return results, total_unmatched
end

return M
