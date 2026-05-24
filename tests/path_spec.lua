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

local path = require("jumpy.path")

describe("path.resolve_path", function()
  it("resolves relative paths against root", function()
    assert.are.equal("/project/lua/foo.lua", path.resolve_path("lua/foo.lua", "/project"))
  end)

  it("keeps absolute paths unchanged", function()
    assert.are.equal("/tmp/foo.lua", path.resolve_path("/tmp/foo.lua", "/project"))
  end)
end)

describe("path.rel_path", function()
  it("returns a path relative to root", function()
    assert.are.equal("lua/foo.lua", path.rel_path("/project/lua/foo.lua", "/project"))
  end)

  it("returns absolute path when outside root", function()
    assert.are.equal("/tmp/foo.lua", path.rel_path("/tmp/foo.lua", "/project"))
  end)
end)
