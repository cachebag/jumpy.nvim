local M = {}

function M.get_workspace_symbols(bufnr, callback)
  local MAX_SYMBOLS = 200
  vim.lsp.buf_request(bufnr, "workspace/symbol", { query = "" }, function(_, result)
    local out = {}
    local kinds = vim.lsp.protocol.SymbolKind

    for i, s in ipairs(result or {}) do
      if i > MAX_SYMBOLS then
        break
      end
      local path = vim.uri_to_fname(s.location.uri)
      path = vim.fn.fnamemodify(path, ":.")
      out[#out + 1] = string.format("- %s [%s] > %s (%s)", s.name, kinds[s.kind] or "?", s.containerName, path)
    end

    callback(table.concat(out, "\n"))
  end)
end

return M
