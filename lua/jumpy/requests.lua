-- Registry of in-flight LLM requests. Each request owns its own id, job and
-- target files, so multiple prompts can run in parallel without sharing the
-- single global "loading" state that made jumpy single-flight.
local M = {}

local next_id = 0
local inflight = {}

--- Register a new request.
--- @param opts table|nil { label = string, targets = { [key] = true } }
--- @return number request id
function M.begin(opts)
  opts = opts or {}
  next_id = next_id + 1
  inflight[next_id] = {
    label = opts.label,
    targets = opts.targets or {},
    job_id = nil,
    cancelled = false,
  }
  return next_id
end

function M.set_job(id, job_id)
  local req = inflight[id]
  if req then
    req.job_id = job_id
  end
end

function M.finish(id)
  inflight[id] = nil
end

--- Unknown/finished ids count as cancelled so late callbacks are discarded.
function M.is_cancelled(id)
  local req = inflight[id]
  return req == nil or req.cancelled
end

--- A target key is a normalized absolute file path, or "buf:N" for
--- unnamed buffers.
function M.target_key(bufnr, abs_path)
  if abs_path and abs_path ~= "" then
    return abs_path
  end
  if bufnr then
    local name = vim.api.nvim_buf_get_name(bufnr)
    if name ~= "" then
      return require("jumpy.path").normalize_abs(name)
    end
    return "buf:" .. bufnr
  end
  return nil
end

function M.is_target_busy(target)
  for _, req in pairs(inflight) do
    if not req.cancelled and req.targets[target] then
      return true
    end
  end
  return false
end

function M.count()
  local n = 0
  for _, req in pairs(inflight) do
    if not req.cancelled then
      n = n + 1
    end
  end
  return n
end

--- Cancel every in-flight request. Jobs are stopped; each request is cleaned
--- up by its own on_exit handler. Returns how many requests were cancelled.
function M.cancel_all()
  local n = 0
  for _, req in pairs(inflight) do
    if not req.cancelled then
      req.cancelled = true
      n = n + 1
      if req.job_id and vim and vim.fn and vim.fn.jobstop then
        pcall(vim.fn.jobstop, req.job_id)
      end
    end
  end
  return n
end

--- Test helper: drop all state.
function M._reset()
  next_id = 0
  inflight = {}
end

return M
