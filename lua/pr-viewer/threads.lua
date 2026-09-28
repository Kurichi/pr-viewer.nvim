-- 既存スレッドへの操作（返信・resolve）。どちらも楽観的更新（docs/DESIGN.md D7）。
-- 返信は pending review に入れず即公開する（会話は待たせない。下書きにしたいコメントは ,c）。
local graphql = require("pr-viewer.gh.graphql")
local model = require("pr-viewer.model.pr")
local transport = require("pr-viewer.gh.transport")

local M = {}

---@param session PrViewer.Session
local function changed(session)
  require("pr-viewer.session").reindex(session)
  if session.on_threads_changed then
    session.on_threads_changed()
  end
end

--- スレッドに返信する。即座に末尾へ足し、失敗したら取り消す。
---@param session PrViewer.Session
---@param thread PrViewer.Thread
---@param body string
---@param cb? fun(err: string?)
function M.reply(session, thread, body, cb)
  ---@type PrViewer.Comment
  local comment = {
    id = "local:reply",
    author = session.pr.viewer,
    body = body,
    created_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    review_state = "SENDING",
  }
  table.insert(thread.comments, comment)
  changed(session)
  transport.graphql(
    graphql.add_thread_reply,
    { thread = thread.id, body = body },
    function(err, data)
      if err then
        for i, c in ipairs(thread.comments) do
          if c == comment then
            table.remove(thread.comments, i)
            break
          end
        end
        vim.notify("pr-viewer.nvim: failed to reply: " .. err, vim.log.levels.ERROR)
      else
        local node = data.addPullRequestReviewThreadReply.comment
        local server = model.thread_from_node({ comments = { nodes = { node } } }).comments[1]
        for k, v in pairs(server) do
          comment[k] = v
        end
      end
      changed(session)
      if cb then
        cb(err)
      end
    end
  )
end

--- resolve / unresolve をトグルする。即座に表示を変え、失敗したら戻す。
---@param session PrViewer.Session
---@param thread PrViewer.Thread
---@param cb? fun(err: string?)
function M.toggle_resolved(session, thread, cb)
  if thread.pending then
    vim.notify(
      "pr-viewer.nvim: drafts cannot be resolved (submit the review first)",
      vim.log.levels.INFO
    )
    if cb then
      cb("pending")
    end
    return
  end
  local target = not thread.resolved
  thread.resolved = target
  changed(session)
  local query = target and graphql.resolve_thread or graphql.unresolve_thread
  transport.graphql(query, { thread = thread.id }, function(err)
    if err then
      thread.resolved = not target
      vim.notify(
        ("pr-viewer.nvim: failed to %s thread: %s"):format(target and "resolve" or "unresolve", err),
        vim.log.levels.ERROR
      )
      changed(session)
    end
    if cb then
      cb(err)
    end
  end)
end

return M
