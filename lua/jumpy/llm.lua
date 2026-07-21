local M = {}

local function get_config()
  return require("jumpy").config
end

local function build_file_block(path, contents)
  return string.format("--- FILE: %s ---\n%s\n--- END FILE ---", path, contents)
end

local function build_messages(context)
  local config = get_config()

  local tagged = context.tagged_files
  if tagged and #tagged > 0 then
    local parts = {}
    for _, file in ipairs(tagged) do
      table.insert(parts, build_file_block(file.path, table.concat(file.lines, "\n")))
    end
    if context.symbols and context.symbols ~= "" then
      table.insert(parts, context.symbols)
    end
    table.insert(parts, "")
    table.insert(parts, "Instruction: " .. context.prompt)
    local user_content = table.concat(parts, "\n")
    local system = config.system_prompt .. "\n\n" .. config.system_prompt_multi_file
    return {
      { role = "system", content = system },
      { role = "user", content = user_content },
    }
  end

  local user_content = string.format(
    "File type: %s\n\n--- FILE CONTENTS ---\n%s\n--- END FILE ---%s\n\nInstruction: %s",
    context.filetype or "text",
    context.file_contents,
    context.symbols,
    context.prompt
  )

  return {
    { role = "system", content = config.system_prompt },
    { role = "user", content = user_content },
  }
end

local function build_reprompt_messages(context)
  local config = get_config()
  local template = "File type: %s\n\n"
    .. "--- PROPOSED BLOCK ---\n%s\n--- END PROPOSED ---%s\n\n"
    .. "The user rejected the PROPOSED BLOCK above. "
    .. "Return SEARCH/REPLACE blocks (per the system prompt) whose SEARCH "
    .. "content matches lines from the PROPOSED BLOCK, revising it "
    .. "according to:\n\n"
    .. "New instruction: %s"
  local user_content = string.format(
    template,
    context.filetype or "text",
    table.concat(context.proposed_lines, "\n"),
    context.symbols or "",
    context.prompt
  )

  return {
    { role = "system", content = config.system_prompt },
    { role = "user", content = user_content },
  }
end

local function is_anthropic()
  local config = get_config()
  return config.provider == "anthropic"
end

local function is_claude_code()
  local config = get_config()
  return config.provider == "claude_code"
end

local function build_curl_cmd(body_json, config, extra_headers)
  local cmd = { "curl", "-s", "-H", "Content-Type: application/json" }
  for _, h in ipairs(extra_headers or {}) do
    table.insert(cmd, "-H")
    table.insert(cmd, h)
  end
  table.insert(cmd, "-d")
  table.insert(cmd, body_json)
  table.insert(cmd, config.endpoint)
  return cmd
end

local function build_curl_cmd_openai(body_json, config)
  return build_curl_cmd(body_json, config, {
    string.format("Authorization: Bearer %s", config.api_key),
  })
end

local function build_curl_cmd_anthropic(body_json, config)
  return build_curl_cmd(body_json, config, {
    string.format("x-api-key: %s", config.api_key),
    "anthropic-version: 2023-06-01",
  })
end

local function extract_content_openai(parsed)
  return parsed.choices and parsed.choices[1] and parsed.choices[1].message and parsed.choices[1].message.content
end

local function extract_content_anthropic(parsed)
  if not parsed.content or #parsed.content == 0 then
    return nil
  end
  for _, block in ipairs(parsed.content) do
    if block.type == "text" then
      return block.text
    end
  end
  return nil
end

local function extract_content_claude_code(parsed)
  return parsed.result
end

local function claude_code_env()
  local env = vim.fn.environ()
  -- Claude Code prefers an API key over its subscription login if both exist.
  env.ANTHROPIC_API_KEY = nil
  return env
end

function M._build_claude_code_cmd(messages, config)
  local system_text = ""
  local user_text = ""
  for _, message in ipairs(messages) do
    if message.role == "system" then
      system_text = message.content
    elseif message.role == "user" then
      user_text = message.content
    end
  end

  -- Note: we deliberately do NOT pass --bare. In current Claude Code, --bare
  -- forces Anthropic auth to ANTHROPIC_API_KEY/apiKeyHelper only and never
  -- reads the OAuth/keychain login, which breaks Pro/Max subscription users
  -- (the CLI reports "Not logged in"). We still keep the request tool-free,
  -- MCP-restricted, and session-less via the explicit flags below.
  local cmd = {
    config.claude_code_command or "claude",
    "-p",
    "--output-format",
    "json",
    "--tools",
    "",
    "--strict-mcp-config",
    "--no-session-persistence",
    "--system-prompt",
    system_text,
  }
  if config.model and config.model ~= "" then
    table.insert(cmd, "--model")
    table.insert(cmd, config.model)
  end
  table.insert(cmd, user_text)
  return cmd
end

local function make_claude_code_request(messages, callback, opts)
  opts = opts or {}
  local config = get_config()
  local command = config.claude_code_command or "claude"
  local loading = require("jumpy.loading")
  local requests = require("jumpy.requests")

  if vim.fn.executable(command) ~= 1 then
    loading.error("Claude Code CLI not found; install it or set claude_code_command")
    return
  end

  local env = claude_code_env()

  local request_id = requests.begin({ label = opts.label, targets = opts.targets })
  loading.start()

  -- Every terminal path must release exactly one spinner refcount and drop
  -- the request from the registry.
  local finished = false
  local function finish()
    if finished then
      return
    end
    finished = true
    requests.finish(request_id)
    loading.stop()
  end

  local function fail(msg)
    vim.schedule(function()
      finish()
      loading.error(msg)
    end)
  end

  local auth_jid
  auth_jid = vim.fn.jobstart({ command, "auth", "status" }, {
    env = env,
    clear_env = true,
    stdout_buffered = true,
    stderr_buffered = true,
    on_exit = function(_, exit_code)
      if requests.is_cancelled(request_id) then
        finish()
        return
      end
      if exit_code ~= 0 then
        fail("Claude Code is not authenticated; run 'claude login' and select your Claude plan")
        return
      end

      local response_chunks = {}
      local stderr_chunks = {}
      local request_jid
      request_jid = vim.fn.jobstart(M._build_claude_code_cmd(messages, config), {
        env = env,
        clear_env = true,
        stdout_buffered = true,
        stderr_buffered = true,
        on_stdout = function(_, data)
          if data then
            for _, line in ipairs(data) do
              table.insert(response_chunks, line)
            end
          end
        end,
        on_stderr = function(_, data)
          if data then
            for _, line in ipairs(data) do
              if line ~= "" then
                table.insert(stderr_chunks, line)
              end
            end
          end
        end,
        on_exit = function(_, request_exit_code)
          if requests.is_cancelled(request_id) then
            finish()
            return
          end

          local stderr_text = table.concat(stderr_chunks, "\n")
          if request_exit_code ~= 0 then
            local msg = "Claude Code request failed (exit " .. request_exit_code .. ")"
            if stderr_text ~= "" then
              msg = msg .. " — " .. stderr_text
            end
            fail(msg)
            return
          end

          local raw = table.concat(response_chunks, "\n")
          local ok, parsed = pcall(vim.fn.json_decode, raw)
          local content = ok and extract_content_claude_code(parsed) or nil
          if type(content) ~= "string" or content == "" then
            fail("Claude Code returned an invalid response (update the CLI and try again)")
            return
          end

          finish()
          content = content:gsub("^```[%w]*\n", ""):gsub("\n```%s*$", "")
          callback(content)
        end,
      })

      if request_jid <= 0 then
        finish()
        loading.error("failed to start Claude Code CLI")
      else
        -- Jumpy never writes to Claude Code's stdin; close it so the CLI does
        -- not wait ~3s for piped input ("no stdin data received in 3s").
        pcall(vim.fn.chanclose, request_jid, "stdin")
        requests.set_job(request_id, request_jid)
      end
    end,
  })

  if auth_jid <= 0 then
    finish()
    loading.error("failed to start Claude Code CLI")
  else
    requests.set_job(request_id, auth_jid)
  end
end

local function make_request(messages, callback, opts)
  opts = opts or {}
  local config = get_config()

  if is_claude_code() then
    make_claude_code_request(messages, callback, opts)
    return
  end

  if not config.api_key or config.api_key == "" then
    local loading = require("jumpy.loading")
    loading.error("no API key — set " .. (config.provider or "JUMPY") .. " env var or pass api_key in setup()")
    return
  end

  local cmd, body_json

  if is_anthropic() then
    local system_text = nil
    local api_messages = {}
    for _, msg in ipairs(messages) do
      if msg.role == "system" then
        system_text = msg.content
      else
        table.insert(api_messages, msg)
      end
    end

    local body = {
      model = config.model,
      max_tokens = 8192,
      messages = api_messages,
    }
    if system_text then
      body.system = system_text
    end

    body_json = vim.fn.json_encode(body)
    cmd = build_curl_cmd_anthropic(body_json, config)
  else
    body_json = vim.fn.json_encode({
      model = config.model,
      messages = messages,
      temperature = 0,
    })
    cmd = build_curl_cmd_openai(body_json, config)
  end

  local response_chunks = {}
  local stderr_chunks = {}
  local loading = require("jumpy.loading")
  local requests = require("jumpy.requests")

  local request_id = requests.begin({ label = opts.label, targets = opts.targets })
  loading.start()

  -- Every terminal path must release exactly one spinner refcount and drop
  -- the request from the registry.
  local finished = false
  local function finish()
    if finished then
      return
    end
    finished = true
    requests.finish(request_id)
    loading.stop()
  end

  local function fail(msg)
    vim.schedule(function()
      finish()
      loading.error(msg)
    end)
  end

  local jid
  jid = vim.fn.jobstart(cmd, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      if data then
        for _, line in ipairs(data) do
          table.insert(response_chunks, line)
        end
      end
    end,
    on_stderr = function(_, data)
      if data then
        for _, line in ipairs(data) do
          if line ~= "" then
            table.insert(stderr_chunks, line)
          end
        end
      end
    end,
    on_exit = function(_, exit_code)
      if requests.is_cancelled(request_id) then
        finish()
        return
      end

      local stderr_text = table.concat(stderr_chunks, "\n")

      if exit_code ~= 0 then
        local msg = "request failed (curl exit " .. exit_code .. ")"
        if stderr_text ~= "" then
          msg = msg .. " — " .. stderr_text
        end
        fail(msg)
        return
      end

      local raw = table.concat(response_chunks, "\n")
      local ok, parsed = pcall(vim.fn.json_decode, raw)

      if not ok then
        vim.schedule(function()
          local preview = vim.fn.strcharpart(vim.fn.substitute(raw, "\n", " ", "g"), 0, 120)
          fail("response was not JSON: " .. preview)
        end)
        return
      end

      if parsed.error then
        local err = parsed.error
        local msg = type(err) == "table" and (err.message or vim.inspect(err)) or tostring(err)
        fail("API error: " .. msg)
        return
      end

      local content
      if is_anthropic() then
        content = extract_content_anthropic(parsed)
      else
        content = extract_content_openai(parsed)
      end

      if not content then
        fail("empty response from LLM (check model / response shape)")
        return
      end

      finish()
      content = content:gsub("^```[%w]*\n", ""):gsub("\n```%s*$", "")

      callback(content)
    end,
  })

  if jid <= 0 then
    finish()
    loading.error("failed to start curl — is it installed?")
  else
    requests.set_job(request_id, jid)
  end
end

function M.request(context, callback, opts)
  local messages = build_messages(context)
  make_request(messages, callback, opts)
end

function M.reprompt(context, callback, opts)
  local messages = build_reprompt_messages(context)
  make_request(messages, function(content)
    local patch = require("jumpy.patch")
    local new_lines, unmatched = patch.apply(context.proposed_lines or {}, content)
    if unmatched > 0 then
      vim.schedule(function()
        vim.notify(string.format("jumpy: %d reprompt block(s) could not be matched", unmatched), vim.log.levels.WARN)
      end)
    end
    callback(new_lines)
  end, opts)
end

return M
