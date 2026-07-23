-- Disk persistence for Jumpy sessions, organized per project root under
-- stdpath("data")/jumpy/sessions/<root-key>/<session-id>.json. Pure helpers
-- (strip_runtime, summarize, root_key) are Neovim-free and unit-tested; the
-- actual IO is guarded so this module loads and no-ops outside Neovim.
local M = {}

local DEBOUNCE_MS = 250

local pending_session = nil
local debounce_timer = nil

local function has_vim()
  return type(vim) == "table"
end

local function deep_copy(value)
  if type(value) ~= "table" then
    return value
  end
  local out = {}
  for k, v in pairs(value) do
    out[k] = deep_copy(v)
  end
  return out
end

--- Copy a session with runtime-only fields (bufnr) removed so it is safe to
--- serialize and later reload without stale buffer references.
function M.strip_runtime(session)
  local copy = deep_copy(session)
  for _, entry in ipairs(copy.entries or {}) do
    for _, result in ipairs(entry.results or {}) do
      result.bufnr = nil
    end
  end
  return copy
end

--- Compact metadata for a session, used by the picker list.
function M.summarize(session)
  local summary = ""
  local entries = session.entries or {}
  for _, entry in ipairs(entries) do
    if entry.kind == "prompt" and entry.text and entry.text ~= "" then
      summary = entry.text
      break
    end
  end
  return {
    id = session.id,
    root = session.root,
    started = session.started,
    entry_count = #entries,
    summary = summary,
  }
end

--- Deterministic, filesystem-safe directory name for a project root: a readable
--- basename plus a djb2 hash so distinct roots never collide.
function M.root_key(root)
  root = root or "."
  local h = 5381
  for i = 1, #root do
    h = (h * 33 + root:byte(i)) % 4294967296
  end
  local base = root:gsub("[/\\]+$", ""):match("[^/\\]+$") or "root"
  base = base:gsub("[^%w%-_]", "_")
  return string.format("%s-%08x", base, h)
end

local function sessions_root()
  return vim.fn.stdpath("data") .. "/jumpy/sessions"
end

function M.dir_for(root)
  return sessions_root() .. "/" .. M.root_key(root)
end

local function file_for(root, id)
  return M.dir_for(root) .. "/" .. id .. ".json"
end

local function write_session(session)
  if not session or not session.entries or #session.entries == 0 then
    return
  end
  local dir = M.dir_for(session.root)
  pcall(vim.fn.mkdir, dir, "p")

  local ok, encoded = pcall(vim.json.encode, M.strip_runtime(session))
  if not ok then
    return
  end

  local f = io.open(file_for(session.root, session.id), "w")
  if not f then
    return
  end
  f:write(encoded)
  f:close()
end

--- Debounced save of the current session; rapid accepts collapse into one write.
function M.save(session)
  if not has_vim() then
    return
  end
  pending_session = session

  if not (vim.loop and vim.loop.new_timer) then
    write_session(pending_session)
    pending_session = nil
    return
  end

  if debounce_timer then
    debounce_timer:stop()
  else
    debounce_timer = vim.loop.new_timer()
  end

  debounce_timer:start(
    DEBOUNCE_MS,
    0,
    vim.schedule_wrap(function()
      if pending_session then
        write_session(pending_session)
        pending_session = nil
      end
    end)
  )
end

--- Write any pending session immediately (call on VimLeavePre).
function M.flush()
  if not has_vim() then
    return
  end
  if debounce_timer then
    debounce_timer:stop()
  end
  if pending_session then
    write_session(pending_session)
    pending_session = nil
  end
end

--- List saved sessions for a project root, newest-first, as summaries plus id.
function M.list(root)
  if not has_vim() then
    return {}
  end
  local dir = M.dir_for(root)
  if vim.fn.isdirectory(dir) == 0 then
    return {}
  end
  local ok, names = pcall(vim.fn.readdir, dir)
  if not ok or type(names) ~= "table" then
    return {}
  end

  local sessions = {}
  for _, name in ipairs(names) do
    if name:match("%.json$") then
      local id = name:gsub("%.json$", "")
      local session = M.load(root, id)
      if session then
        sessions[#sessions + 1] = M.summarize(session)
      end
    end
  end

  table.sort(sessions, function(a, b)
    return (a.started or 0) > (b.started or 0)
  end)
  return sessions
end

--- Decode a saved session into a table, or nil on failure.
function M.load(root, id)
  if not has_vim() then
    return nil
  end
  local f = io.open(file_for(root, id), "r")
  if not f then
    return nil
  end
  local content = f:read("*a")
  f:close()

  local ok, decoded = pcall(vim.json.decode, content)
  if not ok or type(decoded) ~= "table" then
    return nil
  end
  return decoded
end

--- Test helper: drop debounce state.
function M._reset()
  if debounce_timer then
    pcall(function()
      debounce_timer:stop()
    end)
    debounce_timer = nil
  end
  pending_session = nil
end

return M
