-- 楽観的更新の裏同期キュー（docs/DESIGN.md D7）。
--
-- 呼び出し側は先にローカル状態と表示を変え、ここには「最終的にこうしたい」だけを積む。
-- debounce_ms の間に積まれた変更は 1 回の GraphQL リクエスト（alias で複数 mutation）にまとめて送る。
-- 送信中に積まれた分は、完了後にもう 1 回まとめて送る。失敗したら on_rollback で戻してもらう。
local config = require("pr-viewer.config")
local graphql = require("pr-viewer.gh.graphql")
local transport = require("pr-viewer.gh.transport")

local M = {}

---@class PrViewer.SyncState
---@field pending table<string, boolean> path -> viewed（送信待ち）
---@field confirmed table<string, boolean> path -> viewed（サーバに反映済みと分かっている値）
---@field timer uv.uv_timer_t?
---@field in_flight boolean
---@field on_rollback fun(path: string, viewed: boolean)? 失敗時に呼ぶ

---@param session PrViewer.Session
---@return PrViewer.SyncState
local function state_of(session)
  if not session.sync then
    local confirmed = {}
    for _, f in ipairs(session.pr.files) do
      confirmed[f.path] = (f.viewed == "VIEWED")
    end
    session.sync = { pending = {}, confirmed = confirmed, timer = nil, in_flight = false }
  end
  return session.sync
end

---@param st PrViewer.SyncState
local function stop_timer(st)
  if st.timer then
    st.timer:stop()
    st.timer:close()
    st.timer = nil
  end
end

---@param session PrViewer.Session
local function send(session)
  local st = state_of(session)
  if st.in_flight or next(st.pending) == nil then
    return
  end
  local batch = {}
  for path, viewed in pairs(st.pending) do
    -- サーバ側と同じ値なら送らない（トグルを往復して元に戻った場合）
    if st.confirmed[path] ~= viewed then
      batch[#batch + 1] = { path = path, viewed = viewed }
    end
  end
  st.pending = {}
  if #batch == 0 then
    return
  end
  table.sort(batch, function(a, b)
    return a.path < b.path
  end)

  st.in_flight = true
  local query, variables = graphql.mark_viewed_mutation(session.pr.id, batch)
  transport.graphql(query, variables, function(err)
    st.in_flight = false
    if err then
      vim.notify("pr-viewer.nvim: failed to sync viewed state: " .. err, vim.log.levels.ERROR)
      for _, item in ipairs(batch) do
        -- 送信中にさらに変更されていなければ、確定値に戻す
        if st.pending[item.path] == nil and st.on_rollback then
          st.on_rollback(item.path, st.confirmed[item.path] or false)
        end
      end
    else
      for _, item in ipairs(batch) do
        st.confirmed[item.path] = item.viewed
      end
    end
    if next(st.pending) ~= nil then
      send(session)
    end
  end)
end

--- viewed 状態の変更を積む。debounce 後にまとめて送る。
---@param session PrViewer.Session
---@param path string
---@param viewed boolean
function M.mark_viewed(session, path, viewed)
  local st = state_of(session)
  st.pending[path] = viewed
  stop_timer(st)
  local ms = config.get().sync.debounce_ms
  st.timer = assert(vim.uv.new_timer())
  st.timer:start(ms, 0, function()
    vim.schedule(function()
      stop_timer(st)
      send(session)
    end)
  end)
end

--- 待たずに今すぐ送る（セッションを閉じるときなど）。
---@param session PrViewer.Session
function M.flush(session)
  local st = state_of(session)
  stop_timer(st)
  send(session)
end

---@param session PrViewer.Session
---@param fn fun(path: string, viewed: boolean)
function M.on_rollback(session, fn)
  state_of(session).on_rollback = fn
end

--- 送信待ちか送信中のものがあるか（テスト・ステータス表示用）。
---@param session PrViewer.Session
---@return boolean
function M.is_dirty(session)
  local st = state_of(session)
  return st.in_flight or next(st.pending) ~= nil
end

return M
