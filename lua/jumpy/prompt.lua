local M = {}

local context_tools = require("jumpy.context-tools")
local utils = require("jumpy.utils")

local state = {
  win = nil,
  buf = nil,
  source_buf = nil,
  reprompt_hunk_idx = nil,
}

local mention_ns = vim.api.nvim_create_namespace("jumpy_mentions")

local function highlight_mentions(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, mention_ns, 0, -1)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  for lnum, line in ipairs(lines) do
    local search_from = 1
    while true do
      local s, e = line:find("@lsp", search_from, true)
      if not s then
        break
      end
      local prev_ch = s > 1 and line:sub(s - 1, s - 1) or ""
      local next_ch = line:sub(e + 1, e + 1)
      if not prev_ch:match("[%w@]") and not next_ch:match("[%w]") then
        vim.api.nvim_buf_set_extmark(buf, mention_ns, lnum - 1, s - 1, {
          end_col = e,
          hl_group = "JumpyMention",
        })
      end
      search_from = e + 1
    end
  end
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
    title = title or " jumpy ",
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

  local mode = vim.api.nvim_get_mode().mode
  local is_scoped = mode == "v" or mode == "V" or mode == "\22"

  state.source_buf = vim.api.nvim_get_current_buf()
  state.reprompt_hunk_idx = nil

  state.visual_selection = is_scoped and utils.get_visual_selection(state.source_buf) or nil
  local title = is_scoped and " jumpy (scoped) " or " jumpy "

  state.buf, state.win = create_float(title)

  M._set_submit_keymap()
  M._setup_completions(state.buf)
end

function M._setup_completions(buf)
  vim.bo[buf].completeopt = "menu,menuone,noselect"

  -- Disable nvim-cmp in this buffer so it doesn't fight with vim.fn.complete and
  -- doesn't intercept <CR>.
  pcall(function()
    require("cmp").setup.buffer({ enabled = false })
  end)

  -- Highlight group for confirmed mentions (only the actual @lsp token, after a
  -- valid word boundary — i.e. exactly what _submit will detect).
  vim.api.nvim_set_hl(0, "JumpyMention", { link = "Special", default = true })

  local completionItems = {
    { word = "@lsp", menu = "[jumpy]" },
  }

  vim.api.nvim_create_autocmd({ "TextChangedI", "TextChanged" }, {
    buffer = buf,
    callback = function()
      highlight_mentions(buf)

      if vim.fn.mode() ~= "i" then
        return
      end

      local line = vim.api.nvim_get_current_line()
      local col = vim.fn.col(".")
      local before = line:sub(1, col - 1)
      local match = before:match("@%w*$")

      if match then
        vim.schedule(function()
          vim.fn.complete(col - #match, completionItems)
        end)
      end
    end,
  })

  highlight_mentions(buf)
end

function M.reprompt()
  local nav = require("jumpy.navigate")
  local hunk_idx = nav.hunk_at_cursor()
  if not hunk_idx then
    vim.notify("jumpy: no hunk under cursor", vim.log.levels.WARN)
    return
  end

  state.source_buf = vim.api.nvim_get_current_buf()
  state.reprompt_hunk_idx = hunk_idx
  state.buf, state.win = create_float(" jumpy: reprompt this hunk ")

  M._set_submit_keymap()
  M._setup_completions(state.buf)
end

function M._set_submit_keymap()
  vim.keymap.set("i", "<CR>", function()
    if vim.fn.pumvisible() == 1 then
      return "<C-y>"
    end
    vim.schedule(M._submit)
    return ""
  end, { buffer = state.buf, silent = true, expr = true })

  vim.keymap.set("n", "<CR>", function()
    M._submit()
  end, { buffer = state.buf, silent = true })

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
  local tags = require("jumpy.tags")

  local source_lines = state.visual_selection and vim.split(state.visual_selection.text, "\n", { plain = true })
    or vim.api.nvim_buf_get_lines(source_buf, 0, -1, false)

  local source_name = vim.api.nvim_buf_get_name(source_buf)
  local source_rel = source_name ~= "" and tags.rel_path(source_name, tags.project_root()) or "current"

  local parsed = tags.parse(prompt_text, {
    source = {
      path = source_rel,
      abs_path = source_name ~= "" and tags.normalize_abs(source_name) or nil,
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
      end)
    elseif is_multi_file then
      local context = {
        file_contents = table.concat(source_lines, "\n"),
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

          local files_by_path = {}
          for _, file in ipairs(tagged_files) do
            files_by_path[file.path] = file.lines
          end

          local results, total_unmatched = patch.apply_by_file(files_by_path, response_text, source_rel)

          if total_unmatched > 0 then
            vim.notify(string.format("jumpy: %d block(s) could not be matched", total_unmatched), vim.log.levels.WARN)
          end

          local total_hunks = 0

          for path, result in pairs(results) do
            local file_entry
            for _, f in ipairs(tagged_files) do
              if f.path == path then
                file_entry = f
                break
              end
            end
            if not file_entry then
              goto continue
            end

            local bufnr = file_entry.bufnr or tags.find_bufnr(file_entry.abs_path)
            if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
              vim.notify("jumpy: no buffer for " .. path .. ", skipping", vim.log.levels.WARN)
              goto continue
            end

            local hunks = diff.compute(file_entry.lines, result.lines)
            if #hunks > 0 then
              render.show(bufnr, hunks, file_entry.lines, result.lines)
              total_hunks = total_hunks + #hunks
            end

            ::continue::
          end

          if total_hunks == 0 then
            vim.notify("jumpy: no changes proposed", vim.log.levels.INFO)
            return
          end

          vim.notify(
            string.format("jumpy: %d hunk(s) proposed across %d file(s)", total_hunks, vim.tbl_count(results)),
            vim.log.levels.INFO
          )

          local nav = require("jumpy.navigate")
          nav.next_hunk()
        end)
      end)
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

          local proposed_lines, unmatched = patch.apply(source_lines, response_text)

          if unmatched > 0 then
            vim.notify(string.format("jumpy: %d block(s) could not be matched", unmatched), vim.log.levels.WARN)
          end

          local hunks = diff.compute(source_lines, proposed_lines)
          if state.visual_selection then
            local offset = state.visual_selection.start_line - 1

            for _, hunk in ipairs(hunks) do
              hunk.old_start = hunk.old_start + offset
            end
          end

          if #hunks == 0 then
            vim.notify("jumpy: no changes proposed", vim.log.levels.INFO)
            return
          end

          render.show(source_buf, hunks, source_lines, proposed_lines)

          vim.notify(string.format("jumpy: %d hunk(s) proposed", #hunks), vim.log.levels.INFO)

          local nav = require("jumpy.navigate")
          nav.next_hunk()
        end)
      end)
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
  vim.cmd("stopinsert")
end

return M
