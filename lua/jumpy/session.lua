-- In-memory log of Jumpy activity for the current Neovim run. Records each
-- prompt and its per-file hunk outcomes so the sidebar can present a reviewable,
-- iterable history. Entries are plain, JSON-serializable tables (see persist.lua)
-- and carry a generic `kind` so future agentic steps (tool_read/tool_edit) can
-- be appended without reshaping this module.
local M = {}

local HUNK_STATUS = {
  pending = true,
  accepted = true,
  rejected = true,
  superseded = true,
}

local current = nil
local next_entry_id = 0
local observers = {}

local function has_vim()
  return type(vim) == "table"
end

local function now()
  return os.time()
end

local function project_root()
  local ok, root = pcall(function()
    return require("jumpy.path").project_root()
  end)
  if ok and type(root) == "string" and root ~= "" then
    return root
  end
  return "."
end

local function generate_id()
  local stamp = os.date("!%Y%m%dT%H%M%S")
  local pid = 0
  if has_vim() and vim.fn and vim.fn.getpid then
    pid = vim.fn.getpid()
  end
  return string.format("%s-%d", stamp, pid)
end

local function notify()
  for _, fn in ipairs(observers) do
    pcall(fn, current)
  end
end

-- Persist is a no-op outside Neovim (tests) and best-effort otherwise so a
-- write failure never breaks the editing flow.
local function save()
  if not has_vim() or not current then
    return
  end
  pcall(function()
    require("jumpy.persist").save(current)
  end)
end

local function ensure_session()
  if not current then
    current = {
      id = generate_id(),
      root = project_root(),
      started = now(),
      entries = {},
    }
  end
  return current
end

--- Find the single live result tracking `bufnr`, searching newest-first.
local function live_result_for_buf(bufnr)
  if not current then
    return nil
  end
  for i = #current.entries, 1, -1 do
    local results = current.entries[i].results
    for _, result in ipairs(results) do
      if result.live and result.bufnr == bufnr then
        return result
      end
    end
  end
  return nil
end

--- A new proposal for a buffer replaces whatever was pending there, so the
--- previous live result is frozen: still-pending hunks become "superseded" and
--- it stops matching future mark_hunk/mark_all calls (which key on bufnr).
local function supersede_buf(bufnr)
  if not current then
    return
  end
  for _, entry in ipairs(current.entries) do
    for _, result in ipairs(entry.results) do
      if result.live and result.bufnr == bufnr then
        for _, hunk in pairs(result.hunks) do
          if hunk.status == "pending" then
            hunk.status = "superseded"
          end
        end
        result.live = false
      end
    end
  end
end

--- @param opts table { text = string, mode = string }
--- @return table entry
function M.record_prompt(opts)
  opts = opts or {}
  local session = ensure_session()
  next_entry_id = next_entry_id + 1
  local entry = {
    id = next_entry_id,
    kind = "prompt",
    text = opts.text or "",
    mode = opts.mode or "buffer",
    time = now(),
    results = {},
  }
  table.insert(session.entries, entry)
  notify()
  save()
  return entry
end

--- Attach a proposed-hunks result to `entry`, superseding any prior live result
--- for the same buffer first.
--- @param entry table entry returned by record_prompt
--- @param opts table { path = string, bufnr = number|nil, hunks = { { idx, line, preview } } }
function M.record_result(entry, opts)
  if not entry then
    return
  end
  opts = opts or {}

  if opts.bufnr ~= nil then
    supersede_buf(opts.bufnr)
  end

  local hunks = {}
  for _, h in ipairs(opts.hunks or {}) do
    hunks[h.idx] = {
      status = "pending",
      line = h.line,
      preview = h.preview or "",
    }
  end

  table.insert(entry.results, {
    path = opts.path,
    bufnr = opts.bufnr,
    live = true,
    hunks = hunks,
  })
  notify()
  save()
end

--- @return boolean whether a live hunk was updated
function M.mark_hunk(bufnr, idx, status)
  if not HUNK_STATUS[status] then
    return false
  end
  local result = live_result_for_buf(bufnr)
  if not result then
    return false
  end
  local hunk = result.hunks[idx]
  if not hunk then
    return false
  end
  hunk.status = status
  notify()
  save()
  return true
end

--- Mark every still-pending hunk of a buffer's live result.
function M.mark_all(bufnr, status)
  if not HUNK_STATUS[status] then
    return false
  end
  local result = live_result_for_buf(bufnr)
  if not result then
    return false
  end
  local changed = false
  for _, hunk in pairs(result.hunks) do
    if hunk.status == "pending" then
      hunk.status = status
      changed = true
    end
  end
  if changed then
    notify()
    save()
  end
  return changed
end

--- Keep a live hunk's preview in sync when it is reprompted in place.
function M.update_hunk_preview(bufnr, idx, preview)
  local result = live_result_for_buf(bufnr)
  if not result or not result.hunks[idx] then
    return false
  end
  result.hunks[idx].preview = preview or result.hunks[idx].preview
  notify()
  save()
  return true
end

--- Derived counts for a result, for display.
function M.status_counts(result)
  local counts = { pending = 0, accepted = 0, rejected = 0, superseded = 0, total = 0 }
  for _, hunk in pairs(result.hunks or {}) do
    counts[hunk.status] = (counts[hunk.status] or 0) + 1
    counts.total = counts.total + 1
  end
  return counts
end

function M.get_session()
  return current
end

function M.get_entries()
  return current and current.entries or {}
end

--- Persist and end the current run's session; the next activity starts fresh.
function M.clear()
  if current then
    save()
  end
  current = nil
  notify()
end

--- Register an observer called with the current session on every change.
--- Returns an unsubscribe function.
function M.subscribe(fn)
  table.insert(observers, fn)
  return function()
    for i, o in ipairs(observers) do
      if o == fn then
        table.remove(observers, i)
        return
      end
    end
  end
end

--- Test helper: drop all state.
function M._reset()
  current = nil
  next_entry_id = 0
  observers = {}
end

return M
