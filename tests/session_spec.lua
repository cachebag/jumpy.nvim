-- Add lua/ to package.path so require works outside Neovim
package.path = package.path .. ";lua/?.lua;lua/?/init.lua"

local session = require("jumpy.session")

local function result_of(entry, i)
  return entry.results[i]
end

describe("session log", function()
  before_each(function()
    session._reset()
  end)

  it("records a prompt entry with mode and text", function()
    local entry = session.record_prompt({ text = "fix bug", mode = "buffer" })

    assert.are.equal("prompt", entry.kind)
    assert.are.equal("fix bug", entry.text)
    assert.are.equal("buffer", entry.mode)
    assert.are.equal(1, #session.get_entries())
  end)

  it("attaches results with per-hunk pending status", function()
    local entry = session.record_prompt({ text = "x", mode = "buffer" })
    session.record_result(entry, {
      path = "a.lua",
      bufnr = 1,
      hunks = {
        { idx = 1, line = 10, preview = "+ foo" },
        { idx = 2, line = 20, preview = "- bar" },
      },
    })

    local result = result_of(entry, 1)
    assert.are.equal("a.lua", result.path)
    assert.is_true(result.live)
    assert.are.equal("pending", result.hunks[1].status)
    assert.are.equal("+ foo", result.hunks[1].preview)
    assert.are.equal(10, result.hunks[1].line)
  end)

  it("marks a single hunk on the live result", function()
    local entry = session.record_prompt({ text = "x", mode = "buffer" })
    session.record_result(entry, {
      path = "a.lua",
      bufnr = 1,
      hunks = { { idx = 1, line = 1, preview = "+ a" }, { idx = 2, line = 2, preview = "+ b" } },
    })

    assert.is_true(session.mark_hunk(1, 1, "accepted"))
    assert.are.equal("accepted", result_of(entry, 1).hunks[1].status)
    assert.are.equal("pending", result_of(entry, 1).hunks[2].status)
  end)

  it("mark_all only touches pending hunks", function()
    local entry = session.record_prompt({ text = "x", mode = "buffer" })
    session.record_result(entry, {
      path = "a.lua",
      bufnr = 1,
      hunks = { { idx = 1, line = 1, preview = "+ a" }, { idx = 2, line = 2, preview = "+ b" } },
    })
    session.mark_hunk(1, 1, "rejected")

    session.mark_all(1, "accepted")
    assert.are.equal("rejected", result_of(entry, 1).hunks[1].status)
    assert.are.equal("accepted", result_of(entry, 1).hunks[2].status)
  end)

  it("supersedes a prior live result for the same buffer on a new proposal", function()
    local first = session.record_prompt({ text = "one", mode = "buffer" })
    session.record_result(first, {
      path = "a.lua",
      bufnr = 1,
      hunks = { { idx = 1, line = 1, preview = "+ a" }, { idx = 2, line = 2, preview = "+ b" } },
    })
    session.mark_hunk(1, 1, "accepted")

    local second = session.record_prompt({ text = "two", mode = "buffer" })
    session.record_result(second, {
      path = "a.lua",
      bufnr = 1,
      hunks = { { idx = 1, line = 5, preview = "+ c" } },
    })

    local old = result_of(first, 1)
    assert.is_false(old.live)
    assert.are.equal("accepted", old.hunks[1].status) -- already resolved stays
    assert.are.equal("superseded", old.hunks[2].status) -- leftover pending frozen

    local new = result_of(second, 1)
    assert.is_true(new.live)
    -- New live result owns bufnr 1 now; marks route to it.
    assert.is_true(session.mark_hunk(1, 1, "rejected"))
    assert.are.equal("rejected", new.hunks[1].status)
  end)

  it("does not supersede results for a different buffer", function()
    local e1 = session.record_prompt({ text = "one", mode = "multi_file" })
    session.record_result(e1, { path = "a.lua", bufnr = 1, hunks = { { idx = 1, line = 1, preview = "a" } } })
    session.record_result(e1, { path = "b.lua", bufnr = 2, hunks = { { idx = 1, line = 1, preview = "b" } } })

    assert.is_true(result_of(e1, 1).live)
    assert.is_true(result_of(e1, 2).live)
  end)

  it("derives status counts", function()
    local entry = session.record_prompt({ text = "x", mode = "buffer" })
    session.record_result(entry, {
      path = "a.lua",
      bufnr = 1,
      hunks = {
        { idx = 1, line = 1, preview = "a" },
        { idx = 2, line = 2, preview = "b" },
        { idx = 3, line = 3, preview = "c" },
      },
    })
    session.mark_hunk(1, 1, "accepted")

    local counts = session.status_counts(result_of(entry, 1))
    assert.are.equal(1, counts.accepted)
    assert.are.equal(2, counts.pending)
    assert.are.equal(3, counts.total)
  end)

  it("notifies observers on change", function()
    local calls = 0
    session.subscribe(function()
      calls = calls + 1
    end)
    session.record_prompt({ text = "x", mode = "buffer" })
    assert.is_true(calls >= 1)
  end)

  it("update_hunk_preview refreshes a live hunk in place", function()
    local entry = session.record_prompt({ text = "x", mode = "buffer" })
    session.record_result(entry, { path = "a.lua", bufnr = 1, hunks = { { idx = 1, line = 1, preview = "old" } } })

    assert.is_true(session.update_hunk_preview(1, 1, "new"))
    assert.are.equal("new", result_of(entry, 1).hunks[1].preview)
  end)
end)
