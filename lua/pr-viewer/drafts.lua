-- 下書きコメント（docs/DESIGN.md D7'）。
--
-- 下書きの置き場所は GitHub の pending review。`add` はローカルに即座にスレッドを作って表示し、
-- 裏で pending review の作成（初回のみ）→ addPullRequestReviewThread を送る。
-- ネットワーク等の一時的な失敗ならローカル JSON に退避して後で再送する。
-- GitHub が拒否した（位置が diff 外など）恒久的な失敗は再送しても無駄なので、通知して下書きを消す。
local async = require("pr-viewer.async")
local graphql = require("pr-viewer.gh.graphql")
local model = require("pr-viewer.model.pr")
local storage = require("pr-viewer.storage")
local transport = require("pr-viewer.gh.transport")

local M = {}

---@class PrViewer.DraftPosition
---@field path string
---@field side "LEFT"|"RIGHT"
---@field line integer
---@field start_line integer?
---@field start_side "LEFT"|"RIGHT"?

---@param err string
---@return boolean
local function is_permanent(err)
  return err:find("^GraphQL error:") ~= nil
end

local function uuid()
  local t = {}
  for _ = 1, 16 do
    t[#t + 1] = ("%02x"):format(math.random(0, 255))
  end
  return table.concat(t)
end

---@param session PrViewer.Session
local function changed(session)
  require("pr-viewer.session").reindex(session)
  if session.on_threads_changed then
    session.on_threads_changed()
  end
end

--- sync == "local" の下書きをファイルへ退避する（無ければファイルを消す）。
---@param session PrViewer.Session
local function persist(session)
  local path = storage.draft_path(session.owner, session.repo, session.pr.number)
  local items = {}
  for _, t in ipairs(session.pr.threads) do
    if t.pending and t.sync == "local" then
      items[#items + 1] = {
        local_id = t.local_id,
        path = t.path,
        side = t.side,
        line = t.line,
        start_line = t.start_line,
        start_side = t.start_side,
        body = t.comments[1] and t.comments[1].body or "",
        created_at = t.comments[1] and t.comments[1].created_at or "",
      }
    end
  end
  if #items == 0 then
    storage.remove(path)
  else
    storage.write_json(path, { version = 1, drafts = items })
  end
end

---@param session PrViewer.Session
---@param pos PrViewer.DraftPosition
---@param body string
---@param created_at string?
---@return PrViewer.Thread
local function new_local_thread(session, pos, body, created_at)
  local local_id = uuid()
  return {
    id = "local:" .. local_id,
    local_id = local_id,
    path = pos.path,
    side = pos.side,
    line = pos.line,
    start_line = pos.start_line,
    start_side = pos.start_side,
    resolved = false,
    outdated = false,
    pending = true,
    sync = "sending",
    comments = {
      {
        id = "local:" .. local_id,
        author = session.pr.viewer,
        body = body,
        created_at = created_at or os.date("!%Y-%m-%dT%H:%M:%SZ"),
        review_state = "PENDING",
      },
    },
  }
end

--- pending review の id を返す。無ければ作る。同時に複数呼ばれても作るのは 1 回。
---@param session PrViewer.Session
---@param cb fun(err: string?, id: string?)
local function ensure_review(session, cb)
  if session.pr.pending_review_id then
    return cb(nil, session.pr.pending_review_id)
  end
  if session._review_waiters then
    table.insert(session._review_waiters, cb)
    return
  end
  session._review_waiters = { cb }
  transport.graphql(graphql.create_pending_review, {
    pr = session.pr.id,
    commit = session.pr.head_oid,
  }, function(err, data)
    local waiters = session._review_waiters or {}
    session._review_waiters = nil
    local id = not err
      and data
      and data.addPullRequestReview
      and data.addPullRequestReview.pullRequestReview.id
    if id then
      session.pr.pending_review_id = id
    end
    for _, w in ipairs(waiters) do
      w(err or (not id and "no review id in response" or nil), id)
    end
  end)
end

--- サーバから返ったスレッドでローカルの下書きを置き換える（位置は保持）。
---@param thread PrViewer.Thread
---@param node table
local function adopt(thread, node)
  local server = model.thread_from_node(node)
  thread.id = server.id
  thread.comments = server.comments
  thread.line = server.line or thread.line
  thread.start_line = server.start_line or thread.start_line
  thread.side = server.side or thread.side
  thread.pending = true
  thread.sync = "synced"
end

--- 下書き 1 件を送る。
---@param session PrViewer.Session
---@param thread PrViewer.Thread
---@param cb? fun(err: string?)
local function send(session, thread, cb)
  thread.sync = "sending"
  async.run(function()
    local review = async.must(async.await(function(k)
      ensure_review(session, k)
    end))
    local data = async.must(async.await(function(k)
      transport.graphql(graphql.add_review_thread, {
        review = review,
        path = thread.path,
        line = thread.line,
        side = thread.side,
        startLine = thread.start_line,
        startSide = thread.start_side,
        body = thread.comments[1].body,
      }, k)
    end))
    adopt(thread, data.addPullRequestReviewThread.thread)
    persist(session)
    changed(session)
    if cb then
      cb(nil)
    end
  end, function(err)
    if is_permanent(err) then
      -- GitHub に拒否された: 再送しても無駄なので消す
      for i, t in ipairs(session.pr.threads) do
        if t == thread then
          table.remove(session.pr.threads, i)
          break
        end
      end
      vim.notify(
        "pr-viewer.nvim: comment rejected by GitHub, discarded: " .. err,
        vim.log.levels.ERROR
      )
    else
      thread.sync = "local"
      vim.notify(
        "pr-viewer.nvim: could not send comment, kept locally (will retry): " .. err,
        vim.log.levels.WARN
      )
    end
    persist(session)
    changed(session)
    if cb then
      cb(err)
    end
  end)
end

--- 下書きを追加する。即座にスレッドとして表示し、裏で送る。
---@param session PrViewer.Session
---@param pos PrViewer.DraftPosition
---@param body string
---@return PrViewer.Thread
function M.add(session, pos, body)
  local thread = new_local_thread(session, pos, body)
  table.insert(session.pr.threads, thread)
  changed(session)
  send(session, thread)
  return thread
end

--- 下書きの本文を変える。
---@param session PrViewer.Session
---@param thread PrViewer.Thread
---@param body string
function M.edit(session, thread, body)
  local comment = thread.comments[1]
  comment.body = body
  changed(session)
  if thread.sync ~= "synced" then
    -- まだサーバに無い: 次の送信に本文が乗る
    persist(session)
    return
  end
  transport.graphql(graphql.update_review_comment, { id = comment.id, body = body }, function(err)
    if err then
      vim.notify("pr-viewer.nvim: failed to update comment: " .. err, vim.log.levels.ERROR)
    end
  end)
end

--- 下書きを消す。
---@param session PrViewer.Session
---@param thread PrViewer.Thread
function M.delete(session, thread)
  for i, t in ipairs(session.pr.threads) do
    if t == thread then
      table.remove(session.pr.threads, i)
      break
    end
  end
  local was_synced = thread.sync == "synced"
  thread.sync = nil
  persist(session)
  changed(session)
  if was_synced then
    transport.graphql(graphql.delete_review_comment, { id = thread.comments[1].id }, function(err)
      if err then
        vim.notify(
          "pr-viewer.nvim: failed to delete comment on GitHub: " .. err,
          vim.log.levels.ERROR
        )
      end
    end)
  end
end

--- ローカルに退避した下書きを読み込んで再送する（open 時に呼ぶ）。
---@param session PrViewer.Session
function M.load_local(session)
  local data = storage.read_json(storage.draft_path(session.owner, session.repo, session.pr.number))
  if not data or not data.drafts then
    return
  end
  for _, d in ipairs(data.drafts) do
    local thread = new_local_thread(session, d, d.body, d.created_at)
    thread.local_id = d.local_id or thread.local_id
    thread.id = "local:" .. thread.local_id
    thread.comments[1].id = thread.id
    thread.sync = "local"
    table.insert(session.pr.threads, thread)
  end
  changed(session)
  M.resend(session)
end

--- sync == "local" の下書きをすべて再送する。全部終わったら cb(failed_count)。
---@param session PrViewer.Session
---@param cb? fun(failed: integer)
function M.resend(session, cb)
  local targets = {}
  for _, t in ipairs(session.pr.threads) do
    if t.pending and t.sync == "local" then
      targets[#targets + 1] = t
    end
  end
  if #targets == 0 then
    if cb then
      cb(0)
    end
    return
  end
  local remaining, failed = #targets, 0
  for _, t in ipairs(targets) do
    send(session, t, function(err)
      if err then
        failed = failed + 1
      end
      remaining = remaining - 1
      if remaining == 0 and cb then
        cb(failed)
      end
    end)
  end
end

--- 未送信の下書きがあるか。
---@param session PrViewer.Session
---@return boolean
function M.has_unsynced(session)
  for _, t in ipairs(session.pr.threads) do
    if t.pending and t.sync ~= "synced" then
      return true
    end
  end
  return false
end

--- レビューを送信する。ローカル退避分があれば先に再送し、残れば中止する。
---@param session PrViewer.Session
---@param event "APPROVE"|"REQUEST_CHANGES"|"COMMENT"
---@param body string?
---@param cb fun(err: string?)
function M.submit(session, event, body, cb)
  M.resend(session, function(failed)
    if failed > 0 or M.has_unsynced(session) then
      return cb(("%d draft(s) could not be sent; fix the connection and retry"):format(failed))
    end
    local function done(err, data)
      if err then
        return cb(err)
      end
      local review = data.submitPullRequestReview or data.addPullRequestReview
      local state = review and review.pullRequestReview.state or event
      for _, t in ipairs(session.pr.threads) do
        if t.pending then
          t.pending = false
          t.sync = nil
          for _, c in ipairs(t.comments) do
            c.review_state = state
          end
        end
      end
      session.pr.pending_review_id = nil
      session.pr.viewer_review_state = state
      persist(session)
      changed(session)
      cb(nil)
    end
    if body == "" then
      body = nil
    end
    if session.pr.pending_review_id then
      transport.graphql(graphql.submit_review, {
        review = session.pr.pending_review_id,
        event = event,
        body = body,
      }, done)
    else
      transport.graphql(graphql.add_review_with_event, {
        pr = session.pr.id,
        event = event,
        body = body,
        commit = session.pr.head_oid,
      }, done)
    end
  end)
end

return M
