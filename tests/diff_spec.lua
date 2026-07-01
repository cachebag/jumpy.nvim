-- Add lua/ to package.path so require works outside Neovim
package.path = package.path .. ";lua/?.lua;lua/?/init.lua"

local diff = require("jumpy.diff")

describe("diff.compute", function()
  it("returns empty for identical inputs", function()
    local old = { "a", "b", "c" }
    local new = { "a", "b", "c" }
    local hunks = diff.compute(old, new)
    assert.are.equal(0, #hunks)
  end)

  it("returns empty for two empty inputs", function()
    local hunks = diff.compute({}, {})
    assert.are.equal(0, #hunks)
  end)

  it("detects single line deletion", function()
    local old = { "a", "b", "c" }
    local new = { "a", "c" }
    local hunks = diff.compute(old, new)

    assert.are.equal(1, #hunks)
    assert.are.equal(1, hunks[1].old_count)
    assert.are.equal(0, hunks[1].new_count)
    assert.are.same({ "b" }, hunks[1].removed_lines)
    assert.are.same({}, hunks[1].added_lines)
  end)

  it("detects single line insertion", function()
    local old = { "a", "c" }
    local new = { "a", "b", "c" }
    local hunks = diff.compute(old, new)

    assert.are.equal(1, #hunks)
    assert.are.equal(0, hunks[1].old_count)
    assert.are.equal(1, hunks[1].new_count)
    assert.are.same({}, hunks[1].removed_lines)
    assert.are.same({ "b" }, hunks[1].added_lines)
  end)

  it("detects single line replacement", function()
    local old = { "a", "b", "c" }
    local new = { "a", "X", "c" }
    local hunks = diff.compute(old, new)

    assert.are.equal(1, #hunks)
    assert.are.equal(1, hunks[1].old_count)
    assert.are.equal(1, hunks[1].new_count)
    assert.are.same({ "b" }, hunks[1].removed_lines)
    assert.are.same({ "X" }, hunks[1].added_lines)
  end)

  it("detects multiple separate hunks", function()
    local old = { "a", "b", "c", "d", "e" }
    local new = { "a", "X", "c", "Y", "e" }
    local hunks = diff.compute(old, new)

    assert.are.equal(2, #hunks)
    assert.are.same({ "b" }, hunks[1].removed_lines)
    assert.are.same({ "X" }, hunks[1].added_lines)
    assert.are.same({ "d" }, hunks[2].removed_lines)
    assert.are.same({ "Y" }, hunks[2].added_lines)
  end)

  it("handles deletion at start", function()
    local old = { "a", "b", "c" }
    local new = { "b", "c" }
    local hunks = diff.compute(old, new)

    assert.are.equal(1, #hunks)
    assert.are.equal(1, hunks[1].old_start)
    assert.are.same({ "a" }, hunks[1].removed_lines)
  end)

  it("handles deletion at end", function()
    local old = { "a", "b", "c" }
    local new = { "a", "b" }
    local hunks = diff.compute(old, new)

    assert.are.equal(1, #hunks)
    assert.are.same({ "c" }, hunks[1].removed_lines)
  end)

  it("handles insertion at start", function()
    local old = { "b", "c" }
    local new = { "a", "b", "c" }
    local hunks = diff.compute(old, new)

    assert.are.equal(1, #hunks)
    assert.are.equal(1, hunks[1].old_start)
    assert.are.same({ "a" }, hunks[1].added_lines)
  end)

  it("handles insertion at end", function()
    local old = { "a", "b" }
    local new = { "a", "b", "c" }
    local hunks = diff.compute(old, new)

    assert.are.equal(1, #hunks)
    assert.are.equal(3, hunks[1].old_start)
    assert.are.same({ "c" }, hunks[1].added_lines)
  end)

  it("keeps repeated insertion hunks anchored to old-file lines", function()
    local old = {
      "local function one()",
      "end",
      "",
      "local function two()",
      "end",
      "",
      "local function three()",
      "end",
    }
    local new = {
      "--- One.",
      "local function one()",
      "end",
      "",
      "--- Two.",
      "local function two()",
      "end",
      "",
      "--- Three.",
      "local function three()",
      "end",
    }
    local hunks = diff.compute(old, new)

    assert.are.equal(3, #hunks)
    assert.are.equal(1, hunks[1].old_start)
    assert.are.equal(4, hunks[2].old_start)
    assert.are.equal(7, hunks[3].old_start)
    assert.are.same({ "--- One." }, hunks[1].added_lines)
    assert.are.same({ "--- Two." }, hunks[2].added_lines)
    assert.are.same({ "--- Three." }, hunks[3].added_lines)
  end)

  it("handles complete replacement", function()
    local old = { "a", "b" }
    local new = { "x", "y", "z" }
    local hunks = diff.compute(old, new)

    assert.are.equal(1, #hunks)
    assert.are.equal(2, hunks[1].old_count)
    assert.are.equal(3, hunks[1].new_count)
    assert.are.same({ "a", "b" }, hunks[1].removed_lines)
    assert.are.same({ "x", "y", "z" }, hunks[1].added_lines)
  end)

  it("handles old empty, new has lines", function()
    local old = {}
    local new = { "a", "b" }
    local hunks = diff.compute(old, new)

    assert.are.equal(1, #hunks)
    assert.are.equal(0, hunks[1].old_count)
    assert.are.equal(2, hunks[1].new_count)
    assert.are.same({ "a", "b" }, hunks[1].added_lines)
  end)

  it("handles new empty, old has lines", function()
    local old = { "a", "b" }
    local new = {}
    local hunks = diff.compute(old, new)

    assert.are.equal(1, #hunks)
    assert.are.equal(2, hunks[1].old_count)
    assert.are.equal(0, hunks[1].new_count)
    assert.are.same({ "a", "b" }, hunks[1].removed_lines)
  end)

  it("handles multi-line contiguous change", function()
    local old = { "a", "b", "c", "d" }
    local new = { "a", "X", "Y", "d" }
    local hunks = diff.compute(old, new)

    assert.are.equal(1, #hunks)
    assert.are.same({ "b", "c" }, hunks[1].removed_lines)
    assert.are.same({ "X", "Y" }, hunks[1].added_lines)
  end)

  it("preserves line content exactly", function()
    local old = { "  indented", "trailing  ", "" }
    local new = { "  indented", "changed", "" }
    local hunks = diff.compute(old, new)

    assert.are.equal(1, #hunks)
    assert.are.same({ "trailing  " }, hunks[1].removed_lines)
    assert.are.same({ "changed" }, hunks[1].added_lines)
  end)

  it("old_start is 1-indexed", function()
    local old = { "a", "b", "c" }
    local new = { "a", "X", "c" }
    local hunks = diff.compute(old, new)

    assert.are.equal(2, hunks[1].old_start)
  end)
end)
