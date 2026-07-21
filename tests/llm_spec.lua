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
      "user",
    }, cmd)
  end)
end)
