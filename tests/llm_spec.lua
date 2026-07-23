package.path = package.path .. ";lua/?.lua;lua/?/init.lua"

local llm = require("jumpy.llm")

describe("llm Claude Code command", function()
  it("runs Claude Code as a stateless, tool-free JSON request", function()
    local cmd = llm._build_claude_code_cmd({
      { role = "system", content = "Return only SEARCH/REPLACE blocks." },
      { role = "user", content = "Change this function." },
    }, {
      claude_code_command = "claude",
      model = "sonnet",
    })

    assert.are.same({
      "claude",
      "-p",
      "--output-format",
      "json",
      "--tools",
      "",
      "--strict-mcp-config",
      "--no-session-persistence",
      "--system-prompt",
      "Return only SEARCH/REPLACE blocks.",
      "--model",
      "sonnet",
      "--",
      "Change this function.",
    }, cmd)
  end)

  it("allows a custom Claude Code executable and no model override", function()
    local cmd = llm._build_claude_code_cmd({
      { role = "system", content = "system" },
      { role = "user", content = "user" },
    }, {
      claude_code_command = "/opt/bin/claude",
    })

    assert.are.same({
      "/opt/bin/claude",
      "-p",
      "--output-format",
      "json",
      "--tools",
      "",
      "--strict-mcp-config",
      "--no-session-persistence",
      "--system-prompt",
      "system",
      "--",
      "user",
    }, cmd)
  end)
end)

describe("llm multi-file messages", function()
  it("names the current file so relative references resolve", function()
    local msgs = llm._build_messages({
      tagged_files = {
        { path = "a.lua", lines = { "local a = 1" } },
        { path = "b.lua", lines = { "local b = 2" } },
      },
      primary_path = "a.lua",
      prompt = "add a comment in this file",
    })

    local user = msgs[2].content
    assert.is_truthy(user:find("current file", 1, true))
    assert.is_truthy(user:find('The current file (what "this file" refers to) is: a.lua', 1, true))
    -- FILE headers stay verbatim so SEARCH paths still match
    assert.is_truthy(user:find("--- FILE: a.lua ---", 1, true))
    assert.is_truthy(user:find("--- FILE: b.lua ---", 1, true))
    assert.is_truthy(user:find("Instruction: add a comment in this file", 1, true))
  end)
end)
