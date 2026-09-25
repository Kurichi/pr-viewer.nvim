-- コールバック API を coroutine で直列に書くための最小ヘルパー。
--
--   async.run(function()
--     local root = async.must(async.await(git.root))
--     local data = async.must(async.await(function(cb) transport.graphql(q, v, cb) end))
--   end, function(err) vim.notify(err) end)
--
-- await に渡す関数は `fn(cb)` の形で、cb は必ずメインループ上で呼ばれること（transport / git はそうなっている）。
local M = {}

---@type table<thread, fun(...)>
local steps = setmetatable({}, { __mode = "k" })

--- coroutine の中で非同期関数の完了を待つ。
---@generic T
---@param fn fun(cb: fun(...: T))
---@return T ...
function M.await(fn)
  local co, is_main = coroutine.running()
  assert(co and not is_main, "async.await must be called inside async.run")
  local step = assert(steps[co], "coroutine was not started by async.run")
  local results, yielded = nil, false
  fn(function(...)
    if results then
      return -- 二重呼び出しは無視
    end
    results = vim.F.pack_len(...)
    if yielded then
      step(vim.F.unpack_len(results))
    end
  end)
  if results then
    -- コールバックが同期的に呼ばれた（テストの偽装など）
    return vim.F.unpack_len(results)
  end
  yielded = true
  return coroutine.yield()
end

--- `(err, ...)` 形式の戻り値で err があれば error() にする。
---@param err string?
---@param ... any
---@return any ...
function M.must(err, ...)
  if err then
    error(err, 0)
  end
  return ...
end

--- fn を coroutine で実行する。fn 内の error は on_error に渡る。
---@param fn fun()
---@param on_error? fun(err: string)
function M.run(fn, on_error)
  local co = coroutine.create(fn)
  local function step(...)
    local ok, err = coroutine.resume(co, ...)
    if not ok then
      steps[co] = nil
      if on_error then
        on_error(tostring(err))
      else
        vim.notify("pr-viewer.nvim: " .. tostring(err), vim.log.levels.ERROR)
      end
    elseif coroutine.status(co) == "dead" then
      steps[co] = nil
    end
  end
  steps[co] = step
  step()
end

return M
