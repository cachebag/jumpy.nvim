local M = {}

local function is_git_repo(dir)
  local matches = vim.fn.readdir(dir, function(n)
    return n == ".git" and 1 or 0
  end)
  return #matches > 0
end

function M.parse()
  local paths = {}

  local cwd = vim.fn.getcwd()
  if is_git_repo(cwd) then
    local rel = vim.fn.systemlist({
      "git",
      "-C",
      cwd,
      "ls-files",
      "--cached",
      "--others",
      "--exclude-standard",
    })
    if vim.v.shell_error == 0 then
      for _, p in ipairs(rel) do
        if p ~= "" then
          table.insert(paths, p)
        end
      end
    else
      vim.notify("jumpy: unable to execute command", vim.log.levels.ERROR)
      return paths
    end
  else
    print("TODO")
  end

  return paths
end

return M
