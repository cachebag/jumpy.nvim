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
    add(truncate("  jumpy · saved session (read-only)", width), nil, "JumpySessionBanner")
  else
    add(truncate("  jumpy · session", width), nil, "JumpySessionBanner")
  end
  if state.readonly then
    add(truncate("  ⏎ open   ⇥/⇧⇥ cycle   q quit", width), nil, "JumpySessionHint")
  else
    add(
      truncate("  ⏎ open   ⇥/⇧⇥ cycle   a/x accept·reject   r reprompt   q quit", width),
      nil,
      "JumpySessionHint"
    )
  end
  add(string.rep("─", width - 1), nil, "JumpySessionBanner")

  if #entries == 0 then
    add("")
    add("  No jumpy activity yet.")
    add("")
    add(truncate("  Run a prompt with <leader>j to get started.", width), nil, "JumpySessionHint")
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
          hunk = item.hunk,
          status = item.hunk.status,
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

--- Make an editor window current and show the target's file, returning the
--- buffer number (or nil). Prefers the live buffer; falls back to the path.
local function editor_open(target)
  focus_editor_window()
  if target.bufnr and vim.api.nvim_buf_is_valid(target.bufnr) then
    vim.api.nvim_win_set_buf(0, target.bufnr)
    return target.bufnr
  end
  if not target.path then
    return nil
  end
  local root = (state.readonly and state.readonly.root) or require("jumpy.path").project_root()
  local abs = target.path
  if not abs:match("^/") then
    abs = root .. "/" .. target.path
  end
  vim.cmd("edit " .. vim.fn.fnameescape(abs))
  return vim.api.nvim_get_current_buf()
end

--- Is this hunk still an unresolved hunk in the live diff render? If so, the
--- red/green accept/reject overlay is already shown and we should jump to it
--- rather than paint the yellow inspect overlay on top.
local function live_pending(target)
  if state.readonly or target.kind ~= "hunk" then
    return false
  end
  if not (target.bufnr and vim.api.nvim_buf_is_valid(target.bufnr)) then
    return false
  end
  local ok, render = pcall(require, "jumpy.render")
  if not ok then
    return false
  end
  local st = render.get_state(target.bufnr)
  return st ~= nil and st.hunks[target.idx] ~= nil
end

--- Show a hunk's before/after in the editor. `keep_focus` returns the cursor to
--- the sidebar afterwards (used while cycling); otherwise focus stays in the
--- editor (used on <CR>).
local function preview_target(target, keep_focus)
  local inspect = require("jumpy.inspect")
  inspect.clear_all()

  if not target or (target.kind ~= "hunk" and target.kind ~= "file") then
    return
  end

  local sidebar_win = state.win

  -- Live, still-pending hunk: reuse the existing diff overlay + navigation.
  if live_pending(target) then
    local navigate = require("jumpy.navigate")
    focus_editor_window()
    navigate.jump_to_hunk(target.bufnr, target.idx)
    if keep_focus and sidebar_win and vim.api.nvim_win_is_valid(sidebar_win) then
      vim.api.nvim_set_current_win(sidebar_win)
    end
    return
  end

  if target.kind ~= "hunk" or not target.hunk or not target.hunk.old_start then
    -- No geometry to inspect (a file row, or a pre-enrichment session): just
    -- open the file at the recorded line.
    local editor_win = vim.api.nvim_get_current_win()
    if editor_open(target) and target.line then
      pcall(vim.api.nvim_win_set_cursor, editor_win, { target.line, 0 })
      vim.api.nvim_win_call(editor_win, function()
        vim.cmd("normal! zz")
      end)
    end
    if keep_focus and sidebar_win and vim.api.nvim_win_is_valid(sidebar_win) then
      vim.api.nvim_set_current_win(sidebar_win)
    end
    return
  end

  local bufnr = editor_open(target)
  if not bufnr then
    return
  end
  local editor_win = vim.api.nvim_get_current_win()
  local anchor = inspect.show(bufnr, target.hunk, target.status or target.hunk.status)
  if anchor then
    local line_count = vim.api.nvim_buf_line_count(bufnr)
    pcall(vim.api.nvim_win_set_cursor, editor_win, { math.min(anchor, line_count), 0 })
    vim.api.nvim_win_call(editor_win, function()
      vim.cmd("normal! zz")
    end)
  end

  if keep_focus and sidebar_win and vim.api.nvim_win_is_valid(sidebar_win) then
    vim.api.nvim_set_current_win(sidebar_win)
  end
end

local function target_at_cursor()
  if not (state.win and vim.api.nvim_win_is_valid(state.win)) then
    return nil
  end
  local lnum = vim.api.nvim_win_get_cursor(state.win)[1]
  return state.targets[lnum]
end

--- Open the target and move focus into the editor.
local function on_enter()
  local target = target_at_cursor()
  if not target then
    return
  end
  preview_target(target, false)
end

--- Ordered sidebar line numbers that hold a hunk target.
local function hunk_lnums()
  local arr = {}
  for lnum, target in pairs(state.targets) do
    if target.kind == "hunk" then
      arr[#arr + 1] = lnum
    end
  end
  table.sort(arr)
  return arr
end

--- Move to the next/prev hunk row and preview it without leaving the sidebar.
local function cycle(dir)
  if not (state.win and vim.api.nvim_win_is_valid(state.win)) then
    return
  end
  local arr = hunk_lnums()
  if #arr == 0 then
    return
  end

  local cur = vim.api.nvim_win_get_cursor(state.win)[1]
  local target_lnum
  if dir > 0 then
    for _, lnum in ipairs(arr) do
      if lnum > cur then
        target_lnum = lnum
        break
      end
    end
    target_lnum = target_lnum or arr[1]
  else
    for i = #arr, 1, -1 do
      if arr[i] < cur then
        target_lnum = arr[i]
        break
      end
    end
    target_lnum = target_lnum or arr[#arr]
  end

  pcall(vim.api.nvim_win_set_cursor, state.win, { target_lnum, 0 })
  preview_target(state.targets[target_lnum], true)
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

  -- Live geometry just shifted; drop any stale inspect overlay.
  require("jumpy.inspect").clear_all()
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
  vim.keymap.set("n", "<Tab>", function()
    cycle(1)
  end, opts)
  vim.keymap.set("n", "<S-Tab>", function()
    cycle(-1)
  end, opts)
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
  pcall(function()
    require("jumpy.inspect").clear_all()
  end)
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
