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

---@param session PrViewer.Session
function M.close(session)
  require("pr-viewer.ui.layout").close(session)
end

return M
