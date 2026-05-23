local M = {}

local function get_config()
  return require("jumpy").config
end

local function build_file_block(path, contents)
  return string.format("--- FILE: %s ---\n%s\n--- END FILE ---", path, contents)
end

local function tagged_files_with_source(context)
  local tagged = context.tagged_files or {}
  local primary_path = context.primary_path or "current"

  for _, file in ipairs(tagged) do
    if file.path == primary_path then
      return tagged
    end
  end

  if not context.file_contents then
    return tagged
  end

  local files = {
    {
      path = primary_path,
      lines = vim.split(context.file_contents, "\n", { plain = true }),
    },
  }
  for _, file in ipairs(tagged) do
    table.insert(files, file)
  end
  return files
end

local function build_messages(context)
  local config = get_config()

  local tagged = context.tagged_files
  if tagged and #tagged > 0 then
    local parts = {}
    for _, file in ipairs(tagged_files_with_source(context)) do
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

local function build_curl_cmd_openai(body_json, config)
  return {
    "curl",
    "-s",
    "-H",
    "Content-Type: application/json",
    "-H",
    string.format("Authorization: Bearer %s", config.api_key),
    "-d",
    body_json,
    config.endpoint,
  }
end

local function build_curl_cmd_anthropic(body_json, config)
  return {
    "curl",
    "-s",
    "-H",
    "Content-Type: application/json",
    "-H",
    string.format("x-api-key: %s", config.api_key),
    "-H",
    "anthropic-version: 2023-06-01",
    "-d",
    body_json,
    config.endpoint,
  }
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

local function make_request(messages, callback)
  local config = get_config()

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
  local cancelled = false
  loading.start()

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
      if not loading.is_active() then
        cancelled = true
      end

      if cancelled then
        loading.stop()
        return
      end

      local stderr_text = table.concat(stderr_chunks, "\n")

      if exit_code ~= 0 then
        vim.schedule(function()
          local msg = "request failed (curl exit " .. exit_code .. ")"
          if stderr_text ~= "" then
            msg = msg .. " — " .. stderr_text
          end
          loading.error(msg)
        end)
        return
      end

      local raw = table.concat(response_chunks, "\n")
      local ok, parsed = pcall(vim.fn.json_decode, raw)

      if not ok then
        vim.schedule(function()
          local preview = vim.fn.strcharpart(vim.fn.substitute(raw, "\n", " ", "g"), 0, 120)
          loading.error("response was not JSON: " .. preview)
        end)
        return
      end

      if parsed.error then
        vim.schedule(function()
          local err = parsed.error
          local msg = type(err) == "table" and (err.message or vim.inspect(err)) or tostring(err)
          loading.error("API error: " .. msg)
        end)
        return
      end

      local content
      if is_anthropic() then
        content = extract_content_anthropic(parsed)
      else
        content = extract_content_openai(parsed)
      end

      if not content then
        vim.schedule(function()
          loading.error("empty response from LLM (check model / response shape)")
        end)
        return
      end

      loading.stop()
      content = content:gsub("^```[%w]*\n", ""):gsub("\n```%s*$", "")

      callback(content)
    end,
  })

  if jid <= 0 then
    loading.error("failed to start curl — is it installed?")
  else
    loading.set_job(jid)
  end
end

function M.request(context, callback)
  local messages = build_messages(context)
  make_request(messages, callback)
end

function M.reprompt(context, callback)
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
  end)
end

return M
