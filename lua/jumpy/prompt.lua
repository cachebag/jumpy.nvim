local M = {}

local context_tools = require("jumpy.context-tools")
local path = require("jumpy.path")
local tags = require("jumpy.tags")
local utils = require("jumpy.utils")

local state = {
  win = nil,
  buf = nil,
  source_buf = nil,
  reprompt_hunk_idx = nil,
  paths = nil,
  history_idx = nil,
  draft_lines = nil,
}

-- Session-scoped prompt history (newest at the end).
local history = {}
local HISTORY_MAX = 50

local TITLE_HINT = " · Ctrl-CR submit"
local mention_ns = vim.api.nvim_create_namespace("jumpy_mentions")

local function index_tagged_files(tagged_files)
  local by_path = {}
  for _, file in ipairs(tagged_files) do
    by_path[file.path] = file
  end
  return by_path
end

local function buffer_for_tagged_file(file)
  if file.bufnr and vim.api.nvim_buf_is_valid(file.bufnr) then
    return file.bufnr
  end
  return tags.open_buffer(file.abs_path)
end

-- Build session-log descriptors from a diff hunk list. The idx matches the
-- render state's hunk key (diff.compute returns a 1..n array), and line/preview
-- let the sidebar render and jump without the live render state.
local function hunk_descriptors(hunks)
  local out = {}
  for idx, hunk in ipairs(hunks) do
    local preview
    if #hunk.added_lines > 0 then
      preview = "+ " .. hunk.added_lines[1]
    elseif #hunk.removed_lines > 0 then
      preview = "- " .. hunk.removed_lines[1]
    else
      preview = "(change)"
    end
    out[#out + 1] = {
      idx = idx,
      line = hunk.old_start,
      preview = preview,
      -- Geometry + content so the sidebar can re-render this diff later
      -- (e.g. inspect an accepted hunk). See jumpy.inspect.
      old_start = hunk.old_start,
      old_count = hunk.old_count,
      new_start = hunk.new_start,
      new_count = hunk.new_count,
      removed_lines = hunk.removed_lines,
      added_lines = hunk.added_lines,
    }
  end
  return out
end

local function highlight_mentions(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, mention_ns, 0, -1)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

  local path_set = {}
  for _, p in ipairs(state.paths or {}) do
    path_set[p] = true
  end

  for lnum, line in ipairs(lines) do
    local search_from = 1
    while true do
      local lsp_start, lsp_end = line:find("@lsp", search_from, true)
      if not lsp_start then
        break
      end
      local prev_ch = lsp_start > 1 and line:sub(lsp_start - 1, lsp_start - 1) or ""
      local next_ch = line:sub(lsp_end + 1, lsp_end + 1)
      if not prev_ch:match("[%w@]") and not next_ch:match("[%w]") then
        vim.api.nvim_buf_set_extmark(buf, mention_ns, lnum - 1, lsp_start - 1, {
          end_col = lsp_end,
          hl_group = "JumpyMention",
        })
      end
      search_from = lsp_end + 1
    end

    if next(path_set) ~= nil then
      search_from = 1
      while true do
        local at_pos = line:find("@", search_from, true)
        if not at_pos then
          break
        end
        local prev_ch = at_pos > 1 and line:sub(at_pos - 1, at_pos - 1) or ""
        if prev_ch:match("[%w@]") then
          search_from = at_pos + 1
        else
          local _, _, token = line:find("^(" .. tags.MENTION_CHARS .. "+)", at_pos + 1)
          if token and path_set[token] then
            vim.api.nvim_buf_set_extmark(buf, mention_ns, lnum - 1, at_pos - 1, {
              end_col = at_pos + #token,
              hl_group = "JumpyMention",
            })
            search_from = at_pos + 1 + #token
          else
            search_from = at_pos + 1
          end
        end
      end
    end
  end
end

local function push_history(text)
  if vim.trim(text) == "" then
    return
  end
  if history[#history] == text then
    return
  end
  history[#history + 1] = text
  while #history > HISTORY_MAX do
    table.remove(history, 1)
  end
end

local function apply_prompt_lines(lines)
  if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then
    return
  end
  if not lines or #lines == 0 then
    lines = { "" }
  end
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    local last = #lines
    local col = #lines[last]
    vim.api.nvim_win_set_cursor(state.win, { last, col })
  end
  highlight_mentions(state.buf)
end

local function history_prev()
  if #history == 0 then
    return
  end
  if state.history_idx == nil then
    state.draft_lines = vim.api.nvim_buf_get_lines(state.buf, 0, -1, false)
    state.history_idx = #history
  elseif state.history_idx > 1 then
    state.history_idx = state.history_idx - 1
  else
    return
  end
  apply_prompt_lines(vim.split(history[state.history_idx], "\n", { plain = true }))
end

local function history_next()
  if state.history_idx == nil then
    return
  end
  if state.history_idx < #history then
    state.history_idx = state.history_idx + 1
    apply_prompt_lines(vim.split(history[state.history_idx], "\n", { plain = true }))
    return
  end
  state.history_idx = nil
  local draft = state.draft_lines or { "" }
  state.draft_lines = nil
  apply_prompt_lines(draft)
end

local function create_float(title, initial_lines)
  local width = math.floor(vim.o.columns * 0.6)
  local height = 5
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].filetype = "jumpy_prompt"

  if initial_lines then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, initial_lines)
  end

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = title or (" jumpy" .. TITLE_HINT .. " "),
    title_pos = "center",
  })

  vim.wo[win].winblend = 0
  vim.cmd("startinsert")

  return buf, win
end

function M.open()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_set_current_win(state.win)
    return
  end

  local ok, reason = utils.check_source_buffer()
  if not ok then
    vim.notify(reason, vim.log.levels.WARN)
    return
  end

  local mode = vim.api.nvim_get_mode().mode
  local is_scoped = mode == "v" or mode == "V" or mode == "\22"

  state.source_buf = vim.api.nvim_get_current_buf()
  state.reprompt_hunk_idx = nil
  state.history_idx = nil
  state.draft_lines = nil
  state.paths = path.list_files()

  state.visual_selection = is_scoped and utils.get_visual_selection(state.source_buf) or nil
  local title = is_scoped and (" jumpy (scoped)" .. TITLE_HINT .. " ") or (" jumpy" .. TITLE_HINT .. " ")

  state.buf, state.win = create_float(title)

  M._set_submit_keymap()
  M._setup_completions(state.buf)
end

local function build_completion_items(query)
  local items = {}
  local PATH_COMPLETION_LIMIT = 50

  if ("lsp"):sub(1, #query) == query then
    items[#items + 1] = { word = "@lsp", menu = "[jumpy]", equal = 1 }
  end

  local paths = state.paths or {}
  local matches
  if query == "" then
    matches = paths
  else
    local ok, res = pcall(vim.fn.matchfuzzy, paths, query)
    matches = ok and res or {}
  end

  local limit = math.min(PATH_COMPLETION_LIMIT, #matches)
  for i = 1, limit do
    items[#items + 1] = {
      word = "@" .. matches[i],
      abbr = matches[i],
      menu = "[file]",
      equal = 1,
    }
  end
  return items
end

function M._setup_completions(buf)
  vim.bo[buf].completeopt = "menu,menuone,noselect"

  pcall(function()
    require("cmp").setup.buffer({ enabled = false }) -- avoids fighting vim.fn.complete
  end)

  vim.api.nvim_set_hl(0, "JumpyMention", { link = "Special", default = true })

  vim.api.nvim_create_autocmd({ "TextChangedI", "TextChangedP", "TextChanged" }, {
    buffer = buf,
    callback = function()
      highlight_mentions(buf)

      if vim.fn.mode() ~= "i" then
        return
      end

      local line = vim.api.nvim_get_current_line()
      local col = vim.fn.col(".")
      local before = line:sub(1, col - 1)

      local query = before:match("@(" .. tags.MENTION_CHARS .. "*)$")
      if not query then
        return
      end

      local items = build_completion_items(query)
      if #items == 0 then
        return
      end

      local start_col = col - #query - 1
      vim.schedule(function()
        vim.fn.complete(start_col, items)
      end)
    end,
  })

  highlight_mentions(buf)
end

function M.reprompt()
  local ok, reason = utils.check_source_buffer()
  if not ok then
    vim.notify(reason, vim.log.levels.WARN)
    return
  end

  local nav = require("jumpy.navigate")
  local hunk_idx = nav.hunk_at_cursor()
  if not hunk_idx then
    vim.notify("jumpy: no hunk under cursor", vim.log.levels.WARN)
    return
  end

  state.source_buf = vim.api.nvim_get_current_buf()
  state.reprompt_hunk_idx = hunk_idx
  state.visual_selection = nil
  state.history_idx = nil
  state.draft_lines = nil
  state.paths = path.list_files()
  state.buf, state.win = create_float(" jumpy: reprompt" .. TITLE_HINT .. " ")

  M._set_submit_keymap()
  M._setup_completions(state.buf)
end

function M._set_submit_keymap()
  -- Enter inserts a newline; Ctrl-CR submits. Completion menu still confirms with Enter.
  vim.keymap.set("i", "<CR>", function()
    if vim.fn.pumvisible() == 1 then
      return "<C-y>"
    end
    return "<CR>"
  end, { buffer = state.buf, silent = true, expr = true })

  vim.keymap.set("i", "<C-CR>", function()
    vim.schedule(M._submit)
  end, { buffer = state.buf, silent = true })

  vim.keymap.set("n", "<CR>", function()
    M._submit()
  end, { buffer = state.buf, silent = true })

  -- Buffer edits are forbidden while an expr mapping evaluates (E565), so the
  -- history swap is deferred with vim.schedule; the pum case returns the key.
  vim.keymap.set({ "i", "n" }, "<Up>", function()
    if vim.fn.mode():sub(1, 1) == "i" and vim.fn.pumvisible() == 1 then
      return "<Up>"
    end
    vim.schedule(history_prev)
    return ""
  end, { buffer = state.buf, silent = true, expr = true })

  vim.keymap.set({ "i", "n" }, "<Down>", function()
    if vim.fn.mode():sub(1, 1) == "i" and vim.fn.pumvisible() == 1 then
      return "<Down>"
    end
    vim.schedule(history_next)
    return ""
  end, { buffer = state.buf, silent = true, expr = true })

  vim.keymap.set("n", "<Esc>", function()
    M._close()
  end, { buffer = state.buf, silent = true })

  vim.keymap.set("n", "q", function()
    M._close()
  end, { buffer = state.buf, silent = true })
end

function M._submit()
  local lines = vim.api.nvim_buf_get_lines(state.buf, 0, -1, false)
  local prompt_text = table.concat(lines, "\n")

  if vim.trim(prompt_text) == "" then
    vim.notify("jumpy: empty prompt", vim.log.levels.WARN)
    return
  end

  local source_buf = state.source_buf
  local visual_selection = state.visual_selection

  local source_lines = visual_selection and vim.split(visual_selection.text, "\n", { plain = true })
    or vim.api.nvim_buf_get_lines(source_buf, 0, -1, false)

  local source_name = vim.api.nvim_buf_get_name(source_buf)
  local source_rel = source_name ~= "" and path.rel_path(source_name, path.project_root()) or "current"

  local parsed = tags.parse(prompt_text, {
    source = {
      path = source_rel,
      abs_path = source_name ~= "" and path.normalize_abs(source_name) or nil,
      lines = source_lines,
      bufnr = source_buf,
    },
  })

  local cleaned_prompt = parsed.cleaned_prompt
  local tagged_files = parsed.tagged

  if #parsed.errors > 0 then
    for _, err in ipairs(parsed.errors) do
      vim.notify("jumpy: " .. err, vim.log.levels.WARN)
    end
  end

  local filetype = vim.bo[source_buf].filetype
  local reprompt_idx = state.reprompt_hunk_idx
  local is_multi_file = #tagged_files > 1

  local llm = require("jumpy.llm")
  local requests = require("jumpy.requests")

  -- One in-flight request per file: a second request against the same file
  -- would clobber the first one's pending hunks when it lands.
  local targets = {}
  for _, file in ipairs(tagged_files) do
    local key = requests.target_key(file.bufnr, file.abs_path)
    if key then
      if requests.is_target_busy(key) then
        vim.notify("jumpy: a request is already running for " .. file.path, vim.log.levels.WARN)
        return
      end
      targets[key] = true
    end
  end

  push_history(prompt_text)

  local session = require("jumpy.session")
  local mode = (reprompt_idx and "reprompt")
    or (is_multi_file and "multi_file")
    or (visual_selection and "visual")
    or "buffer"
  local session_entry = session.record_prompt({
    text = cleaned_prompt ~= "" and cleaned_prompt or prompt_text,
    mode = mode,
  })

  local request_opts = { targets = targets, label = source_rel }

  local function send_request(symbols)
    symbols = symbols or ""

    if symbols ~= "" then
      symbols = "\n\n--- WORKSPACE SYMBOLS ---\n" .. symbols .. "\n--- END SYMBOLS ---"
    end

    M._close()

    if reprompt_idx then
      local render = require("jumpy.render")
      local hunk_state = render.get_state(source_buf)

      if not hunk_state or not hunk_state.hunks[reprompt_idx] then
        vim.notify("jumpy: hunk no longer exists", vim.log.levels.WARN)
        return
      end

      local hunk = hunk_state.hunks[reprompt_idx]

      local context = {
        original_lines = hunk.removed_lines,
        proposed_lines = hunk.added_lines,
        prompt = cleaned_prompt,
        symbols = symbols,
        filetype = filetype,
      }

      llm.reprompt(context, function(new_lines)
        vim.schedule(function()
          local nav = require("jumpy.navigate")

          nav.replace_hunk(source_buf, reprompt_idx, new_lines)

          vim.notify("jumpy: hunk updated", vim.log.levels.INFO)
        end)
      end, request_opts)
    elseif is_multi_file then
      local context = {
        tagged_files = tagged_files,
        primary_path = source_rel,
        prompt = cleaned_prompt,
        symbols = symbols,
        filetype = filetype,
      }

      llm.request(context, function(response_text)
        vim.schedule(function()
          local diff = require("jumpy.diff")
          local render = require("jumpy.render")
          local patch = require("jumpy.patch")

          -- The buffer may have been edited while the request was in flight
          -- (e.g. reviewing hunks from a parallel prompt), so apply against
          -- the freshest lines we can get, not the snapshot from submit time.
          local files_by_path = {}
          for _, file in ipairs(tagged_files) do
            local file_lines = file.lines
            if file.bufnr and vim.api.nvim_buf_is_valid(file.bufnr) then
              file_lines = vim.api.nvim_buf_get_lines(file.bufnr, 0, -1, false)
            end
            files_by_path[file.path] = file_lines
          end

          local results, total_unmatched = patch.apply_by_file(files_by_path, response_text, source_rel)

          if total_unmatched > 0 then
            vim.notify(string.format("jumpy: %d block(s) could not be matched", total_unmatched), vim.log.levels.WARN)
          end

          local tagged_by_path = index_tagged_files(tagged_files)
          local total_hunks = 0
          local target_bufs = {}

          for file_path, result in pairs(results) do
            local file = tagged_by_path[file_path]
            if file then
              local bufnr = buffer_for_tagged_file(file)
              if bufnr then
                local original = files_by_path[file_path]
                local hunks = diff.compute(original, result.lines)
                if #hunks > 0 then
                  require("jumpy.navigate")._clear_undo_history(bufnr)
                  render.show(bufnr, hunks, original, result.lines)
                  session.record_result(session_entry, {
                    path = file_path,
                    bufnr = bufnr,
                    hunks = hunk_descriptors(hunks),
                  })
                  total_hunks = total_hunks + #hunks
                  target_bufs[bufnr] = true
                end
              else
                vim.notify("jumpy: could not open " .. file_path .. ", skipping", vim.log.levels.WARN)
              end
            end
          end

          if total_hunks == 0 then
            vim.notify("jumpy: no changes proposed", vim.log.levels.INFO)
            return
          end

          local nav = require("jumpy.navigate")
          nav._refresh_quickfix()

          vim.notify(
            string.format("jumpy: %d hunk(s) proposed across %d file(s)", total_hunks, vim.tbl_count(results)),
            vim.log.levels.INFO
          )

          -- Only steal the cursor if the user is still in one of the target
          -- buffers; otherwise they may be busy with another prompt/review.
          if target_bufs[vim.api.nvim_get_current_buf()] then
            nav.first_hunk_any_buf()
          end
        end)
      end, request_opts)
    else
      local context = {
        file_contents = table.concat(source_lines, "\n"),
        prompt = cleaned_prompt,
        symbols = symbols,
        filetype = filetype,
      }

      llm.request(context, function(response_text)
        vim.schedule(function()
          if not vim.api.nvim_buf_is_valid(source_buf) then
            vim.notify("jumpy: buffer closed, discarding response", vim.log.levels.WARN)
            return
          end

          local diff = require("jumpy.diff")
          local render = require("jumpy.render")
          local patch = require("jumpy.patch")

          -- Full-buffer prompts re-read the buffer so parallel work done in
          -- the meantime is respected; visual-selection prompts keep the
          -- snapshot since they target a fixed region.
          local original = visual_selection and source_lines or vim.api.nvim_buf_get_lines(source_buf, 0, -1, false)

          local proposed_lines, unmatched = patch.apply(original, response_text)

          if unmatched > 0 then
            vim.notify(string.format("jumpy: %d block(s) could not be matched", unmatched), vim.log.levels.WARN)
          end

          local hunks = diff.compute(original, proposed_lines)
          if visual_selection then
            local offset = visual_selection.start_line - 1

            for _, hunk in ipairs(hunks) do
              hunk.old_start = hunk.old_start + offset
            end
          end

          if #hunks == 0 then
            vim.notify("jumpy: no changes proposed", vim.log.levels.INFO)
            return
          end

          require("jumpy.navigate")._clear_undo_history(source_buf)
          render.show(source_buf, hunks, original, proposed_lines)
          session.record_result(session_entry, {
            path = source_rel,
            bufnr = source_buf,
            hunks = hunk_descriptors(hunks),
          })

          local nav = require("jumpy.navigate")
          nav._refresh_quickfix()

          vim.notify(string.format("jumpy: %d hunk(s) proposed in %s", #hunks, source_rel), vim.log.levels.INFO)

          if vim.api.nvim_get_current_buf() == source_buf then
            nav.next_hunk()
          end
        end)
      end, request_opts)
    end
  end

  if prompt_text:find("@lsp") then
    cleaned_prompt = vim.trim(cleaned_prompt:gsub("%f[%w@]@lsp%f[%W]", ""))

    context_tools.get_workspace_symbols(tonumber(source_buf) or 0, send_request)
  else
    send_request("")
  end
end

function M._close()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_win_close(state.win, true)
  end
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    vim.api.nvim_buf_delete(state.buf, { force = true })
  end
  state.win = nil
  state.buf = nil
  state.paths = nil
  state.history_idx = nil
  state.draft_lines = nil
  vim.cmd("stopinsert")
end

return M
