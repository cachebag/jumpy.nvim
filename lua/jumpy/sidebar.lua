-- Session sidebar: a vertical split that renders the jumpy.session log and lets
-- you jump to, accept/reject, and re-prompt hunks from one place. It is a pure
-- view over session state (live) or a reloaded past session (read-only); all
-- mutations are delegated back to jumpy.navigate.
local M = {}

local session = require("jumpy.session")

local ns = vim.api.nvim_create_namespace("jumpy_session_sidebar")

local DEFAULT_WIDTH = 42

local state = {
  win = nil,
  buf = nil,
  width = DEFAULT_WIDTH,
  unsubscribe = nil,
  readonly = nil, -- a loaded past-session table, or nil for the live session
  targets = {}, -- [lnum] = { kind, bufnr, idx, result, path, line }
}

--- Read the user's sidebar layout config, falling back to defaults.
local function layout()
  local ok, jumpy = pcall(require, "jumpy")
  local cfg = (ok and jumpy.config and jumpy.config.sidebar) or {}
  return {
    position = cfg.position == "right" and "right" or "left",
    width = tonumber(cfg.width) or DEFAULT_WIDTH,
  }
end

local STATUS = {
  pending = { glyph = "○", label = "pending", hl = "JumpySessionPending" },
  accepted = { glyph = "●", label = "accepted", hl = "JumpySessionAccepted" },
  rejected = { glyph = "✕", label = "rejected", hl = "JumpySessionRejected" },
  superseded = { glyph = "·", label = "superseded", hl = "JumpySessionSuperseded" },
}

local function truncate(s, width)
  s = s:gsub("\n", " ")
  if vim.api.nvim_strwidth(s) <= width then
    return s
  end
  return vim.fn.strcharpart(s, 0, math.max(1, width - 1)) .. "…"
end

local function rel_time(t)
  if not t then
    return ""
  end
  local secs = os.time() - t
  if secs < 60 then
    return "just now"
  elseif secs < 3600 then
    return math.floor(secs / 60) .. "m ago"
  elseif secs < 86400 then
    return math.floor(secs / 3600) .. "h ago"
  end
  return math.floor(secs / 86400) .. "d ago"
end

local function sorted_hunks(result)
  local arr = {}
  for idx, hunk in pairs(result.hunks or {}) do
    arr[#arr + 1] = { idx = idx, hunk = hunk }
  end
  table.sort(arr, function(a, b)
    local la, lb = a.hunk.line or 0, b.hunk.line or 0
    if la ~= lb then
      return la < lb
    end
    return tostring(a.idx) < tostring(b.idx)
  end)
  return arr
end

local function counts_summary(result)
  local counts = session.status_counts(result)
  local parts = {}
  for _, s in ipairs({ "pending", "accepted", "rejected", "superseded" }) do
    if (counts[s] or 0) > 0 then
      parts[#parts + 1] = counts[s] .. " " .. s
    end
  end
  return table.concat(parts, " · ")
end

--- Collect display lines + per-line targets + highlight spans for the buffer.
local function build_lines()
  local lines = {}
  local targets = {}
  local highlights = {}

  local function add(text, target, hl)
    lines[#lines + 1] = text
    local lnum = #lines
    if target then
      targets[lnum] = target
    end
    if hl then
      highlights[#highlights + 1] = { line = lnum - 1, group = hl }
    end
  end

  local width = state.width or DEFAULT_WIDTH
  local sess = state.readonly or session.get_session()
  local entries = sess and sess.entries or {}

  if state.readonly then
    add(truncate("jumpy session (saved · read-only)", width), nil, "JumpySessionBanner")
  else
    add(truncate("jumpy session", width), nil, "JumpySessionBanner")
  end
  add(string.rep("─", width - 1), nil, "JumpySessionBanner")

  if #entries == 0 then
    add("")
    add("  No jumpy activity yet.")
    return lines, targets, highlights
  end

  for i = #entries, 1, -1 do
    local entry = entries[i]
    add("")
    local meta = string.format("[%s · %s]", entry.mode or "buffer", rel_time(entry.time))
    add(truncate("▍ " .. (entry.text ~= "" and entry.text or "(no prompt)"), width - #meta - 1) .. "  " .. meta, {
      kind = "entry",
    }, "JumpySessionHeader")

    for _, result in ipairs(entry.results or {}) do
      local summary = counts_summary(result)
      add(truncate("   " .. (result.path or "?"), width - #summary - 4) .. "  " .. summary, {
        kind = "file",
        bufnr = result.bufnr,
        result = result,
        path = result.path,
      }, "JumpySessionFile")

      for _, item in ipairs(sorted_hunks(result)) do
        local st = STATUS[item.hunk.status] or STATUS.pending
        add(truncate("     " .. st.glyph .. " " .. (item.hunk.preview or ""), width), {
          kind = "hunk",
          bufnr = result.bufnr,
          idx = item.idx,
          path = result.path,
          line = item.hunk.line,
        }, st.hl)
      end
    end
  end

  return lines, targets, highlights
end

function M.render()
  if not (state.buf and vim.api.nvim_buf_is_valid(state.buf)) then
    return
  end

  local cursor
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    cursor = vim.api.nvim_win_get_cursor(state.win)
  end

  local lines, targets, highlights = build_lines()
  state.targets = targets

  vim.bo[state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
  vim.bo[state.buf].modifiable = false

  vim.api.nvim_buf_clear_namespace(state.buf, ns, 0, -1)
  for _, hl in ipairs(highlights) do
    vim.api.nvim_buf_add_highlight(state.buf, ns, hl.group, hl.line, 0, -1)
  end

  if cursor and state.win and vim.api.nvim_win_is_valid(state.win) then
    local target_line = math.min(cursor[1], #lines)
    pcall(vim.api.nvim_win_set_cursor, state.win, { math.max(1, target_line), 0 })
  end
end

--- Switch focus to a normal (non-sidebar, non-floating) window, creating a
--- split if the sidebar is the only window left.
local function focus_editor_window()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if win ~= state.win and vim.api.nvim_win_get_config(win).relative == "" then
      vim.api.nvim_set_current_win(win)
      return true
    end
  end
  vim.cmd("rightbelow vsplit")
  return true
end

local function open_readonly_target(target)
  if not target.path then
    return
  end
  local root = (state.readonly and state.readonly.root) or require("jumpy.path").project_root()
  local abs = target.path
  if not abs:match("^/") then
    abs = root .. "/" .. target.path
  end
  focus_editor_window()
  vim.cmd("edit " .. vim.fn.fnameescape(abs))
  if target.line then
    pcall(vim.api.nvim_win_set_cursor, 0, { target.line, 0 })
    vim.cmd("normal! zz")
  end
end

local function first_pending_idx(result)
  local best
  for _, item in ipairs(sorted_hunks(result)) do
    if item.hunk.status == "pending" then
      best = item.idx
      break
    end
  end
  return best
end

local function target_at_cursor()
  if not (state.win and vim.api.nvim_win_is_valid(state.win)) then
    return nil
  end
  local lnum = vim.api.nvim_win_get_cursor(state.win)[1]
  return state.targets[lnum]
end

local function on_enter()
  local target = target_at_cursor()
  if not target then
    return
  end

  if state.readonly then
    if target.kind == "hunk" or target.kind == "file" then
      open_readonly_target(target)
    end
    return
  end

  local navigate = require("jumpy.navigate")
  if target.kind == "hunk" then
    focus_editor_window()
    if not navigate.jump_to_hunk(target.bufnr, target.idx) then
      vim.notify("jumpy: hunk is no longer pending", vim.log.levels.WARN)
    end
  elseif target.kind == "file" and target.result then
    local idx = first_pending_idx(target.result)
    if idx then
      focus_editor_window()
      navigate.jump_to_hunk(target.bufnr, idx)
    end
  end
end

local function act_on_target(status)
  if state.readonly then
    vim.notify("jumpy: saved sessions are read-only", vim.log.levels.INFO)
    return
  end
  local target = target_at_cursor()
  if not target then
    return
  end

  local navigate = require("jumpy.navigate")
  local action = status == "accepted" and navigate.accept_hunk or navigate.reject_hunk

  if target.kind == "hunk" then
    if not action(target.bufnr, target.idx) then
      vim.notify("jumpy: hunk is no longer pending", vim.log.levels.WARN)
    end
  elseif target.kind == "file" and target.result then
    -- Accept/reject from highest line down so earlier hunks keep their indices.
    local items = sorted_hunks(target.result)
    for j = #items, 1, -1 do
      if items[j].hunk.status == "pending" then
        action(target.bufnr, items[j].idx)
      end
    end
  end
end

local function on_reprompt()
  if state.readonly then
    return
  end
  local target = target_at_cursor()
  if not target or target.kind ~= "hunk" then
    return
  end
  local navigate = require("jumpy.navigate")
  focus_editor_window()
  if navigate.jump_to_hunk(target.bufnr, target.idx) then
    require("jumpy.prompt").reprompt()
  end
end

local function setup_keymaps()
  local opts = { buffer = state.buf, silent = true, nowait = true }
  vim.keymap.set("n", "<CR>", on_enter, opts)
  vim.keymap.set("n", "a", function()
    act_on_target("accepted")
  end, opts)
  vim.keymap.set("n", "x", function()
    act_on_target("rejected")
  end, opts)
  vim.keymap.set("n", "r", on_reprompt, opts)
  vim.keymap.set("n", "R", function()
    if not state.readonly then
      session.clear()
    end
  end, opts)
  vim.keymap.set("n", "q", M.close, opts)
  vim.keymap.set("n", "<Esc>", M.close, opts)
end

local function create_window()
  state.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[state.buf].buftype = "nofile"
  vim.bo[state.buf].bufhidden = "wipe"
  vim.bo[state.buf].swapfile = false
  vim.bo[state.buf].filetype = "jumpy_session"

  local cfg = layout()
  state.width = cfg.width
  vim.cmd((cfg.position == "right" and "botright" or "topleft") .. " vsplit")
  state.win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(state.win, state.buf)
  vim.api.nvim_win_set_width(state.win, state.width)

  vim.wo[state.win].number = false
  vim.wo[state.win].relativenumber = false
  vim.wo[state.win].wrap = false
  vim.wo[state.win].cursorline = true
  vim.wo[state.win].winfixwidth = true
  vim.wo[state.win].signcolumn = "no"

  setup_keymaps()

  vim.api.nvim_create_autocmd("WinClosed", {
    buffer = state.buf,
    callback = function()
      M._teardown()
    end,
  })
end

function M._teardown()
  if state.unsubscribe then
    state.unsubscribe()
    state.unsubscribe = nil
  end
  state.win = nil
  state.buf = nil
  state.targets = {}
  state.readonly = nil
end

function M.close()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_win_close(state.win, true)
  end
  M._teardown()
end

--- Open the live session sidebar (subscribes for live updates).
function M.open()
  state.readonly = nil
  if not (state.win and vim.api.nvim_win_is_valid(state.win)) then
    create_window()
  else
    vim.api.nvim_set_current_win(state.win)
  end
  if not state.unsubscribe then
    state.unsubscribe = session.subscribe(function()
      vim.schedule(M.render)
    end)
  end
  M.render()
end

--- Open a reloaded past session in read-only mode.
function M.open_session(saved)
  M.close()
  create_window()
  state.readonly = saved
  M.render()
end

function M.toggle()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    M.close()
  else
    M.open()
  end
end

--- Present a picker of saved sessions for the project root and open the choice.
function M.pick()
  local path = require("jumpy.path")
  local persist = require("jumpy.persist")
  local root = path.project_root()
  local sessions = persist.list(root)

  if #sessions == 0 then
    vim.notify("jumpy: no saved sessions for this project", vim.log.levels.INFO)
    return
  end

  vim.ui.select(sessions, {
    prompt = "Jumpy sessions",
    format_item = function(item)
      local when = os.date("%Y-%m-%d %H:%M", item.started or 0)
      local summary = item.summary ~= "" and item.summary or "(no prompt)"
      return string.format("%s · %d prompt(s) · %s", when, item.entry_count or 0, summary)
    end,
  }, function(choice)
    if not choice then
      return
    end
    local saved = persist.load(root, choice.id)
    if not saved then
      vim.notify("jumpy: could not load session", vim.log.levels.WARN)
      return
    end
    M.open_session(saved)
  end)
end

return M
