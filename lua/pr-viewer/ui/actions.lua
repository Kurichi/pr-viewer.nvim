-- キーマップから呼ばれる操作。session を受け取り ui/* を組み合わせる。
local position = require("pr-viewer.model.position")

local M = {}

---@param session PrViewer.Session
---@param delta integer
local function move_file(session, delta)
  local idx = session.file_index + delta
  if idx < 1 or idx > #session.pr.files then
    vim.notify(
      ("pr-viewer.nvim: no %s file"):format(delta > 0 and "next" or "previous"),
      vim.log.levels.INFO
    )
    return
  end
  require("pr-viewer.ui.diff").show(session, idx)
end

function M.next_file(session)
  move_file(session, 1)
end

function M.prev_file(session)
  move_file(session, -1)
end

--- 現在位置を anchors と同じ順序で比較できるキーにする。
---@param session PrViewer.Session
---@return integer file_index, integer line, string side
local function current_key(session)
  local diff = require("pr-viewer.ui.diff")
  local side = diff.current_side(session)
  if not side then
    -- files パネルにいるときは現在ファイルの先頭扱い
    return session.file_index, 0, "LEFT"
  end
  return session.file_index, vim.api.nvim_win_get_cursor(0)[1], side
end

---@param a PrViewer.ThreadAnchor
---@param fi integer
---@param line integer
---@param side string
---@return integer -1 | 0 | 1
local function compare(a, fi, line, side)
  if a.file_index ~= fi then
    return a.file_index < fi and -1 or 1
  end
  if a.line ~= line then
    return a.line < line and -1 or 1
  end
  if a.side ~= side then
    return a.side < side and -1 or 1
  end
  return 0
end

---@param session PrViewer.Session
---@param anchor PrViewer.ThreadAnchor
local function jump(session, anchor)
  local thread = require("pr-viewer.ui.thread")
  local function go()
    local win = anchor.side == "LEFT" and session.wins.base or session.wins.head
    if not vim.api.nvim_win_is_valid(win) then
      return
    end
    vim.api.nvim_set_current_win(win)
    local count = vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(win))
    vim.api.nvim_win_set_cursor(win, { math.min(anchor.line, count), 0 })
    local threads = session.threads_by_path[anchor.thread.path] or {}
    thread.show(position.threads_at(threads, anchor.side, anchor.line), { focus = false })
  end
  if anchor.file_index ~= session.file_index then
    require("pr-viewer.ui.diff").show(session, anchor.file_index, go)
  else
    go()
  end
end

---@param session PrViewer.Session
---@param delta 1|-1
local function move_thread(session, delta)
  local anchors = session.anchors
  if #anchors == 0 then
    vim.notify("pr-viewer.nvim: no threads", vim.log.levels.INFO)
    return
  end
  local fi, line, side = current_key(session)
  local target
  if delta > 0 then
    for _, a in ipairs(anchors) do
      if compare(a, fi, line, side) > 0 then
        target = a
        break
      end
    end
  else
    for i = #anchors, 1, -1 do
      if compare(anchors[i], fi, line, side) < 0 then
        target = anchors[i]
        break
      end
    end
  end
  if not target then
    vim.notify(
      ("pr-viewer.nvim: no %s thread"):format(delta > 0 and "next" or "previous"),
      vim.log.levels.INFO
    )
    return
  end
  jump(session, target)
end

function M.next_thread(session)
  move_thread(session, 1)
end

function M.prev_thread(session)
  move_thread(session, -1)
end

--- カーソル行のスレッドを float で表示。
---@param session PrViewer.Session
function M.show_thread(session)
  local diff = require("pr-viewer.ui.diff")
  local side = diff.current_side(session)
  local file = session.pr.files[session.file_index]
  if not side or not file then
    return
  end
  local line = vim.api.nvim_win_get_cursor(0)[1]
  local threads = position.threads_at(session.threads_by_path[file.path] or {}, side, line)
  if #threads == 0 then
    vim.notify("pr-viewer.nvim: no thread on this line", vim.log.levels.INFO)
    return
  end
  require("pr-viewer.ui.thread").show(threads, { focus = true })
end

--- viewed をトグルする。表示は即座に変え、API 同期は gh/sync.lua が裏でまとめる（D7）。
--- files パネルではカーソル行のファイル、diff ペインでは表示中のファイルが対象。
---@param session PrViewer.Session
function M.toggle_viewed(session)
  local files = require("pr-viewer.ui.files")
  local in_panel = vim.api.nvim_get_current_win() == session.wins.files
  local idx = in_panel and files.index_at_cursor(session) or session.file_index
  local file = idx and session.pr.files[idx]
  if not file then
    return
  end
  local viewed = file.viewed ~= "VIEWED"
  file.viewed = viewed and "VIEWED" or "UNVIEWED"
  files.render(session)
  require("pr-viewer.gh.sync").mark_viewed(session, file.path, viewed)

  if viewed and not in_panel and require("pr-viewer.config").get().ui.advance_on_viewed then
    for i = idx + 1, #session.pr.files do
      if session.pr.files[i].viewed ~= "VIEWED" then
        require("pr-viewer.ui.diff").show(session, i)
        return
      end
    end
  end
end

--- カーソル行（visual なら範囲）の位置を DraftPosition にする。
---@param session PrViewer.Session
---@return PrViewer.DraftPosition?
local function position_at_cursor(session)
  local diff = require("pr-viewer.ui.diff")
  local side = diff.current_side(session)
  local file = session.pr.files[session.file_index]
  if not side or not file then
    vim.notify("pr-viewer.nvim: move the cursor into a diff pane first", vim.log.levels.INFO)
    return nil
  end
  local mode = vim.fn.mode()
  local first, last = vim.api.nvim_win_get_cursor(0)[1], nil
  if mode == "v" or mode == "V" or mode == "\22" then
    local a, b = vim.fn.getpos("v")[2], vim.fn.getpos(".")[2]
    first, last = math.min(a, b), math.max(a, b)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
  end
  return {
    path = file.path,
    side = side,
    line = last or first,
    start_line = last and last ~= first and first or nil,
    start_side = last and last ~= first and side or nil,
  }
end

--- カーソル行の自分の下書きを 1 件返す（複数なら最初）。
---@param session PrViewer.Session
---@return PrViewer.Thread?
local function draft_at_cursor(session)
  local diff = require("pr-viewer.ui.diff")
  local side = diff.current_side(session)
  local file = session.pr.files[session.file_index]
  if not side or not file then
    return nil
  end
  local line = vim.api.nvim_win_get_cursor(0)[1]
  for _, t in ipairs(position.threads_at(session.threads_by_path[file.path] or {}, side, line)) do
    if t.pending then
      return t
    end
  end
  vim.notify("pr-viewer.nvim: no draft comment on this line", vim.log.levels.INFO)
  return nil
end

--- 下書きコメントを追加する（normal: カーソル行、visual: 範囲）。
---@param session PrViewer.Session
function M.add_comment(session)
  local pos = position_at_cursor(session)
  if not pos then
    return
  end
  local where = pos.start_line and ("%s:%d-%d"):format(pos.path, pos.start_line, pos.line)
    or ("%s:%d"):format(pos.path, pos.line)
  require("pr-viewer.ui.thread").input({ title = "Comment " .. where }, function(body)
    if body then
      require("pr-viewer.drafts").add(session, pos, body)
    end
  end)
end

---@param session PrViewer.Session
function M.edit_comment(session)
  local thread = draft_at_cursor(session)
  if not thread then
    return
  end
  local initial = vim.split(thread.comments[1].body, "\n", { plain = true })
  require("pr-viewer.ui.thread").input({ title = "Edit comment", initial = initial }, function(body)
    if body then
      require("pr-viewer.drafts").edit(session, thread, body)
    end
  end)
end

---@param session PrViewer.Session
function M.delete_comment(session)
  local thread = draft_at_cursor(session)
  if not thread then
    return
  end
  require("pr-viewer.drafts").delete(session, thread)
end

--- レビューを送信する。event を選び、本文を入力してから 1 リクエストで送る。
---@param session PrViewer.Session
function M.submit(session)
  local drafts = require("pr-viewer.drafts")
  local stats = require("pr-viewer.model.pr").stats(session.pr)
  local events = {
    {
      label = ("Comment (%d draft%s)"):format(stats.drafts, stats.drafts == 1 and "" or "s"),
      event = "COMMENT",
    },
    { label = "Approve", event = "APPROVE" },
    { label = "Request changes", event = "REQUEST_CHANGES" },
  }
  vim.ui.select(events, {
    prompt = ("Submit review for #%d"):format(session.pr.number),
    format_item = function(item)
      return item.label
    end,
  }, function(choice)
    if not choice then
      return
    end
    require("pr-viewer.ui.thread").input({ title = "Review body (optional)" }, function(body)
      drafts.submit(session, choice.event, body or "", function(err)
        if err then
          vim.notify("pr-viewer.nvim: submit failed: " .. err, vim.log.levels.ERROR)
        else
          vim.notify(
            ("pr-viewer.nvim: review submitted (%s)"):format(choice.event),
            vim.log.levels.INFO
          )
        end
      end)
    end)
  end)
end

---@param session PrViewer.Session
function M.close(session)
  require("pr-viewer.ui.layout").close(session)
end

return M
