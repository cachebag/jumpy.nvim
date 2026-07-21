-- Add lua/ to package.path so require works outside Neovim
package.path = package.path .. ";lua/?.lua;lua/?/init.lua"

local persist = require("jumpy.persist")

local function sample_session()
  return {
    id = "20260720T101010-1234",
    root = "/home/user/proj",
    started = 1000,
    entries = {
      {
        id = 1,
        kind = "prompt",
        text = "first prompt",
        mode = "buffer",
        time = 1001,
        results = {
          {
            path = "a.lua",
            bufnr = 7,
            live = true,
            hunks = { [1] = { status = "pending", line = 3, preview = "+ x" } },
          },
        },
      },
      {
        id = 2,
        kind = "prompt",
        text = "second prompt",
        mode = "multi_file",
        time = 1002,
        results = {},
      },
    },
  }
end

describe("persist pure helpers", function()
  it("strips runtime-only bufnr fields for serialization", function()
    local stripped = persist.strip_runtime(sample_session())
    assert.is_nil(stripped.entries[1].results[1].bufnr)
    -- original preserved (deep copy, not mutation)
    local original = sample_session()
    assert.are.equal(7, original.entries[1].results[1].bufnr)
    -- other fields survive
    assert.are.equal("+ x", stripped.entries[1].results[1].hunks[1].preview)
  end)

  it("summarizes a session using the first prompt text", function()
    local summary = persist.summarize(sample_session())
    assert.are.equal("20260720T101010-1234", summary.id)
    assert.are.equal("/home/user/proj", summary.root)
    assert.are.equal(1000, summary.started)
    assert.are.equal(2, summary.entry_count)
    assert.are.equal("first prompt", summary.summary)
  end)

  it("produces distinct, filesystem-safe keys per root", function()
    local a = persist.root_key("/home/user/projectA")
    local b = persist.root_key("/home/user/projectB")

    assert.are_not.equal(a, b)
    assert.is_nil(a:find("/"))
    -- deterministic
    assert.are.equal(a, persist.root_key("/home/user/projectA"))
    -- readable basename prefix
    assert.is_truthy(a:find("^projectA%-"))
  end)

  it("summary is empty when there are no prompt entries", function()
    local summary = persist.summarize({ id = "x", root = "/r", started = 1, entries = {} })
    assert.are.equal("", summary.summary)
    assert.are.equal(0, summary.entry_count)
  end)
end)
