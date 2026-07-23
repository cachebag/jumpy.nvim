package.path = package.path .. ";lua/?.lua;lua/?/init.lua"

local inspect = require("jumpy.inspect")

describe("inspect present side", function()
  it("shows added lines for an accepted hunk, removed as context", function()
    local present, other, sign = inspect._present_side({
      removed_lines = { "old" },
      added_lines = { "new" },
    }, "accepted")

    assert.are.same({ "new" }, present)
    assert.are.same({ "old" }, other)
    assert.are.equal("-", sign)
  end)

  it("shows removed lines for a pending/rejected hunk, added as context", function()
    local present, other, sign = inspect._present_side({
      removed_lines = { "old" },
      added_lines = { "new" },
    }, "rejected")

    assert.are.same({ "old" }, present)
    assert.are.same({ "new" }, other)
    assert.are.equal("+", sign)
  end)
end)

describe("inspect anchoring", function()
  local buf = { "line 1", "target", "line 3", "line 4", "target", "line 6" }

  it("keeps the recorded position when it still matches", function()
    local hunk = { old_start = 2, removed_lines = { "target" }, added_lines = {} }
    assert.are.equal(2, inspect._anchor(buf, hunk, "rejected"))
  end)

  it("re-anchors to the nearest matching line when the file drifted", function()
    -- Recorded at 6, but the present content now lives at 2 and 5; nearest wins.
    local hunk = { old_start = 6, removed_lines = { "target" }, added_lines = {} }
    assert.are.equal(5, inspect._anchor(buf, hunk, "rejected"))
  end)

  it("clamps into range when the present side is empty", function()
    local hunk = { old_start = 99, removed_lines = {}, added_lines = { "x" } }
    -- pending hunk: present side is removed_lines (empty) -> clamp to len+1
    assert.are.equal(#buf + 1, inspect._anchor(buf, hunk, "pending"))
  end)

  it("falls back to a clamped hint when no match is found", function()
    local hunk = { old_start = 3, removed_lines = { "nowhere" }, added_lines = {} }
    assert.are.equal(3, inspect._anchor(buf, hunk, "rejected"))
  end)
end)
