local M = {}

-- TODO:
-- Revisit this...
-- I don't really like it, but it works for now.
local STRUCTURAL_KINDS = {
  [vim.lsp.protocol.SymbolKind.Class] = true,
  [vim.lsp.protocol.SymbolKind.Method] = true,
  [vim.lsp.protocol.SymbolKind.Function] = true,
  [vim.lsp.protocol.SymbolKind.Constructor] = true,
  [vim.lsp.protocol.SymbolKind.Field] = true,
  [vim.lsp.protocol.SymbolKind.Constant] = true,
  [vim.lsp.protocol.SymbolKind.Enum] = true,
  [vim.lsp.protocol.SymbolKind.EnumMember] = true,
  [vim.lsp.protocol.SymbolKind.Interface] = true,
  [vim.lsp.protocol.SymbolKind.Module] = true,
  [vim.lsp.protocol.SymbolKind.Namespace] = true,
  [vim.lsp.protocol.SymbolKind.Package] = true,
  [vim.lsp.protocol.SymbolKind.Struct] = true,
}

function M.get_workspace_symbols(bufnr, callback)
  local MAX_SYMBOLS = 200

  local clients = vim.lsp.get_clients({ bufnr = bufnr })
  local supports_workspace_symbols = false
  for _, client in ipairs(clients) do
    if client:supports_method("workspace/symbol") then
      supports_workspace_symbols = true
      break
    end
  end

  if not supports_workspace_symbols then
    vim.notify("No attached LSP supports workspace/symbol", vim.log.levels.WARN)
    callback("")
    return
  end

  vim.lsp.buf_request(bufnr, "workspace/symbol", { query = "" }, function(err, result)
    if err then
      vim.notify("workspace/symbol request failed: " .. err.message, vim.log.levels.WARN)
      callback("")
      return
    end

    local cwd = (vim.uv and vim.uv.cwd and vim.uv.cwd()) or vim.fn.getcwd()
    if cwd:sub(-1) ~= "/" then
      cwd = cwd .. "/"
    end

    local out = {}
    local kinds = vim.lsp.protocol.SymbolKind
    local kept = 0

    for _, s in ipairs(result or {}) do
      local path = vim.uri_to_fname(s.location.uri)
      if STRUCTURAL_KINDS[s.kind] and path:sub(1, #cwd) == cwd then
        kept = kept + 1
        if kept > MAX_SYMBOLS then
          break
        end
        local rel = path:sub(#cwd + 1)
        out[#out + 1] =
          string.format("- %s [%s] > %s (%s)", s.name, kinds[s.kind] or "?", s.containerName or "global", rel)
      end
    end

    callback(table.concat(out, "\n"))
  end)
end

return M

