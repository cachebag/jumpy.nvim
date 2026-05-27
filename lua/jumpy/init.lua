local M = {}

M.config = {
  provider = "openrouter",
  endpoint = nil,
  model = nil,
  api_key = nil,
  system_prompt = table.concat({
    "You are a code editor. The user will give you a file and an instruction.",
    "Return ONLY the changed sections as SEARCH/REPLACE blocks.",
    "",
    "Format for each change:",
    "<<<< SEARCH",
    "exact existing lines from the file",
    "====",
    "replacement lines",
    ">>>> REPLACE",
    "",
    "Rules:",
    "- SEARCH content must match the file EXACTLY (whitespace, indentation, etc.)",
    "- Include 1-2 lines of surrounding context so the match is unique",
    "- For deletions, leave the section between ==== and >>>> REPLACE empty",
    "- Output NOTHING outside of SEARCH/REPLACE blocks",
    "- Do NOT wrap in markdown code fences",
    "- Do NOT explain",
  }, "\n"),
  system_prompt_multi_file = table.concat({
    "When multiple files are provided, prefix SEARCH with the exact path from ",
    "each --- FILE: ... --- header:",
    "<<<< SEARCH src/foo.lua",
    "exact existing lines from that file",
    "====",
    "replacement lines",
    ">>>> REPLACE",
    "",
    "The path after SEARCH must be copied VERBATIM from the --- FILE: ... --- header. Do NOT add any prefix.",
    "You may edit any subset of the provided files. Every SEARCH block MUST include a path.",
  }, "\n"),
  keymaps = {
    prompt = "<leader>j",
    next_hunk = "]h",
    prev_hunk = "[h",
    accept = "<leader>a",
    reject = "<leader>x",
    accept_all = "<leader>A",
    reject_all = "<leader>X",
    reprompt = "<leader>r",
    quickfix = "<leader>q",
  },
  highlights = {
    added = "JumpyAdded",
    removed = "JumpyRemoved",
  },
}

local provider_defaults = {
  openrouter = {
    endpoint = "https://openrouter.ai/api/v1/chat/completions",
    model = "openai/gpt-4o",
    env_key = "JUMPY_API_KEY",
  },
  openai = {
    endpoint = "https://api.openai.com/v1/chat/completions",
    model = "gpt-4o",
    env_key = "OPENAI_API_KEY",
  },
  anthropic = {
    endpoint = "https://api.anthropic.com/v1/messages",
    model = "claude-sonnet-4-6",
    env_key = "ANTHROPIC_API_KEY",
  },
}

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})

  local p = provider_defaults[M.config.provider]
  if p then
    M.config.endpoint = M.config.endpoint or p.endpoint
    M.config.model = M.config.model or p.model
    if not M.config.api_key then
      M.config.api_key = vim.env[p.env_key] or vim.env.JUMPY_API_KEY
    end
  else
    if not M.config.api_key then
      M.config.api_key = vim.env.JUMPY_API_KEY
    end
  end

  M._setup_highlights()
  M._setup_keymaps()
end

function M.auto_setup()
  M._setup_highlights()
  vim.api.nvim_create_user_command("Jumpy", function()
    require("jumpy.prompt").open()
  end, { desc = "Open Jumpy prompt" })
end

function M._setup_highlights()
  local hl = vim.api.nvim_set_hl
  hl(0, "JumpyAdded", { bg = "#1a3a1a", default = true })
  hl(0, "JumpyRemoved", { bg = "#3a1a1a", strikethrough = true, default = true })
  hl(0, "JumpyAddedSign", { fg = "#4ec94e", default = true })
  hl(0, "JumpyRemovedSign", { fg = "#e05252", default = true })
end

function M._setup_keymaps()
  local map = vim.keymap.set
  local opts = { silent = true }
  local c = M.config.keymaps

  local keymaps = {
    { c.prompt, "jumpy.prompt", "open" },
    { c.next_hunk, "jumpy.navigate", "next_hunk" },
    { c.prev_hunk, "jumpy.navigate", "prev_hunk" },
    { c.accept, "jumpy.navigate", "accept" },
    { c.reject, "jumpy.navigate", "reject" },
    { c.accept_all, "jumpy.navigate", "accept_all" },
    { c.reject_all, "jumpy.navigate", "reject_all" },
    { c.reprompt, "jumpy.prompt", "reprompt" },
    { c.quickfix, "jumpy.navigate", "add_hunks_to_quickfix" },
  }

  for _, km in ipairs(keymaps) do
    local key, mod, fn = km[1], km[2], km[3]
    map("n", key, function()
      require(mod)[fn]()
    end, opts)
  end
end

return M
