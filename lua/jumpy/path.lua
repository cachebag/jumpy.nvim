local M = {}

function M.normalize_abs(raw_path)
  if vim and vim.fn and vim.fn.fnamemodify then
    raw_path = vim.fn.fnamemodify(raw_path, ":p")
  end
  if raw_path:sub(-1) == "/" then
    raw_path = raw_path:sub(1, -2)
  end
  return raw_path
end

function M.project_root()
  local cwd = vim.fn.getcwd()
  if vim.system then
    local result = vim.system({ "git", "rev-parse", "--show-toplevel" }, { cwd = cwd }):wait()
    if result.code == 0 then
      local root = vim.trim(result.stdout or "")
      if root ~= "" then
        return M.normalize_abs(root)
      end
    end
  end
  return M.normalize_abs(cwd)
end

function M.resolve_path(raw_path, root)
  root = M.normalize_abs(root or (vim and vim.fn and vim.fn.getcwd() or "."))
  if raw_path:sub(1, 1) == "/" then
    return M.normalize_abs(raw_path)
  end
  return M.normalize_abs(root .. "/" .. raw_path)
end

function M.rel_path(abs_path, root)
  abs_path = M.normalize_abs(abs_path)
  root = M.normalize_abs(root)
  local prefix = root .. "/"
  if abs_path:sub(1, #prefix) == prefix then
    return abs_path:sub(#prefix + 1)
  end
  return abs_path
end

function M.list_files()
  local paths = {}
  local root = M.project_root()

  local git_files = vim.fn.systemlist({
    "git",
    "-C",
    root,
    "ls-files",
    "--cached",
    "--others",
    "--exclude-standard",
  })

  -- git command runs successfully
  if vim.v.shell_error == 0 then
    for _, path in ipairs(git_files) do
      if path ~= "" then
        table.insert(paths, path)
      end
    end
    return paths
  end

  -- fallback to all files
  for path, ftype in vim.fs.dir(root, { depth = math.huge }) do
    if ftype == "file" and path ~= "" then
      table.insert(paths, path)
    end
  end
  return paths
end

return M
