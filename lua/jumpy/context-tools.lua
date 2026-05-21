local M = {}

function M.get_workspace_symbols(bufnr, callback)
  local MAX_SYMBOLS = 200

  local clients = vim.lsp.get_clients({ bufnr = bufnr })
  local supports_workspace_symbols = vim.tbl_any(function(client)
    return client:supports_method("workspace/symbol")
  end, clients)

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

    local out = {}
    local kinds = vim.lsp.protocol.SymbolKind

    for i, s in ipairs(result or {}) do
      if i > MAX_SYMBOLS then
        break
      end

      local path = vim.uri_to_fname(s.location.uri)
      path = vim.fn.fnamemodify(path, ":.")

      out[#out + 1] =
        string.format("- %s [%s] > %s (%s)", s.name, kinds[s.kind] or "?", s.containerName or "global", path)
    end

    callback(table.concat(out, "\n"))
  end)
end

return M
