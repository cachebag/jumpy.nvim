package.path = package.path .. ";lua/?.lua;lua/?/init.lua"

_G.vim = _G.vim or {}
_G.vim.fn = _G.vim.fn or {}
_G.vim.fn.getcwd = _G.vim.fn.getcwd or function()
  return "/project"
end
_G.vim.fn.fnamemodify = _G.vim.fn.fnamemodify
  or function(path, mod)
    if mod == ":p" then
      if path:sub(1, 1) == "/" then
        return path:sub(-1) == "/" and path:sub(1, -2) or path
      end
      local joined = "/project/" .. path
      while joined:find("/%./") do
        joined = joined:gsub("/%./", "/")
      end
      return joined:sub(-1) == "/" and joined:sub(1, -2) or joined
    end
    return path
  end

local tags = require("jumpy.tags")

describe("tags.find_mentions", function()
  it("finds a single file mention", function()
    assert.are.same({ "lua/jumpy/foo.lua" }, tags.find_mentions("move helpers from @lua/jumpy/foo.lua"))
  end)

  it("finds multiple unique mentions", function()
    local mentions = tags.find_mentions("merge @lua/a.lua into @lua/b.lua and @lua/a.lua again")
    assert.are.same({ "lua/a.lua", "lua/b.lua" }, mentions)
  end)

  it("ignores reserved @lsp", function()
    assert.are.same({}, tags.find_mentions("use @lsp to find symbols"))
  end)

  it("ignores email addresses", function()
    assert.are.same({}, tags.find_mentions("contact me at user@domain.com"))
  end)

  it("finds simple filenames", function()
    assert.are.same({ "foo.c" }, tags.find_mentions("take methods in @foo.c"))
  end)
end)

describe("tags.strip_mentions", function()
  it("removes file mentions and trims whitespace", function()
    assert.are.equal(
      "move helpers from into this file",
      tags.strip_mentions("move helpers from @lua/jumpy/foo.lua into this file")
    )
  end)
end)

describe("tags.resolve_path", function()
  it("resolves relative paths against root", function()
    assert.are.equal("/project/lua/foo.lua", tags.resolve_path("lua/foo.lua", "/project"))
  end)

  it("keeps absolute paths unchanged", function()
    assert.are.equal("/tmp/foo.lua", tags.resolve_path("/tmp/foo.lua", "/project"))
  end)
end)

describe("tags.rel_path", function()
  it("returns a path relative to root", function()
    assert.are.equal("lua/foo.lua", tags.rel_path("/project/lua/foo.lua", "/project"))
  end)

  it("returns absolute path when outside root", function()
    assert.are.equal("/tmp/foo.lua", tags.rel_path("/tmp/foo.lua", "/project"))
  end)
end)

describe("tags.truncate_lines", function()
  it("passes through small files", function()
    local lines = { "a", "b" }
    local out, truncated = tags.truncate_lines(lines)
    assert.are.same(lines, out)
    assert.is_false(truncated)
  end)

  it("truncates at the line limit", function()
    local lines = {}
    for i = 1, tags.MAX_LINES + 10 do
      lines[i] = tostring(i)
    end

    local out, truncated = tags.truncate_lines(lines)
    assert.are.equal(tags.MAX_LINES, #out)
    assert.is_true(truncated)
  end)
end)

describe("tags.parse", function()
  it("loads tagged files and strips mentions from the prompt", function()
    local files = {
      ["/project/lua/a.lua"] = { "a" },
      ["/project/lua/b.lua"] = { "b" },
    }

    local result = tags.parse("merge @lua/a.lua into @lua/b.lua", {
      root = "/project",
      read_file = function(abs_path)
        return files[abs_path], nil, nil
      end,
    })

    assert.are.equal("merge into", result.cleaned_prompt)
    assert.are.equal(2, #result.tagged)
    assert.are.equal("lua/a.lua", result.tagged[1].path)
    assert.are.equal("lua/b.lua", result.tagged[2].path)
    assert.are.same({ "a" }, result.tagged[1].lines)
    assert.are.same({ "b" }, result.tagged[2].lines)
    assert.are.equal(0, #result.errors)
  end)

  it("records errors for missing files", function()
    local result = tags.parse("fix @missing.lua", {
      root = "/project",
      read_file = function()
        return nil, "file not found"
      end,
    })

    assert.are.equal(0, #result.tagged)
    assert.are.equal(1, #result.errors)
    assert.are.equal("fix", result.cleaned_prompt)
  end)
end)
