-- 左端のファイル一覧パネル。
local signs = require("pr-viewer.signs")
local model = require("pr-viewer.model.pr")

local M = {}

M.HEADER_LINES = 4
M.ns = vim.api.nvim_create_namespace("pr_viewer_files")

---@param session PrViewer.Session
---@return integer buf
function M.create(session)
  local buf = vim.api.nvim_create_buf(false, true)
  pcall(vim.api.nvim_buf_set_name, buf, ("pr-viewer://%d/files"):format(session.pr.number))
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "pr-viewer-files"
  M.render(session, buf)
  require("pr-viewer.ui.keymaps").attach(session, buf, {
    open_file = function(s)
      local idx = M.index_at_cursor(s)
      if idx then
        require("pr-viewer.ui.diff").show(s, idx)
      end
    end,
  })
  return buf
end

---@param f PrViewer.File
---@param threads PrViewer.Thread[]
---@return string
local function file_line(f, threads)
  local mark = f.viewed == "VIEWED" and "✓" or " "
  local n_threads, n_drafts = 0, 0
  for _, t in ipairs(threads) do
    if t.pending then
      n_drafts = n_drafts + 1
    else
      n_threads = n_threads + 1
    end
  end
  local badge = (n_threads > 0 and (" ●%d"):format(n_threads) or "")
    .. (n_drafts > 0 and (" ✎%d"):format(n_drafts) or "")
  local kind = ({ ADDED = "A", DELETED = "D", RENAMED = "R" })[f.change_type] or " "
  return ("%s %s %s  +%d -%d%s"):format(mark, kind, f.path, f.additions, f.deletions, badge)
end

---@param session PrViewer.Session
---@param buf? integer 省略時は session.wins.files のバッファ
function M.render(session, buf)
  buf = buf or (session.wins and vim.api.nvim_win_get_buf(session.wins.files))
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  signs.ensure_highlights()
  local pr = session.pr
  local stats = model.stats(pr)
  local state = pr.is_draft and "DRAFT" or pr.state
  local lines = {
    ("#%d %s"):format(pr.number, pr.title),
    ("@%s  %s ← %s  %s  [head: %s]"):format(
      pr.author,
      pr.base_ref,
      pr.head_ref,
      state,
      session.head_local and "local" or (session.worktree_root and "worktree" or "git show")
    ),
    ("viewed %d/%d · threads %d (%d open)"):format(
      stats.viewed,
      stats.files,
      stats.threads,
      stats.unresolved
    ),
    string.rep("─", 200),
  }
  for _, f in ipairs(pr.files) do
    lines[#lines + 1] = file_line(f, session.threads_by_path[f.path] or {})
  end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
  vim.api.nvim_buf_set_extmark(buf, M.ns, 0, 0, { line_hl_group = "PrViewerHeader" })
  vim.api.nvim_buf_set_extmark(buf, M.ns, 1, 0, { line_hl_group = "PrViewerMuted" })
  vim.api.nvim_buf_set_extmark(buf, M.ns, 2, 0, { line_hl_group = "PrViewerMuted" })
  vim.api.nvim_buf_set_extmark(buf, M.ns, 3, 0, { line_hl_group = "PrViewerMuted" })
  for i, f in ipairs(pr.files) do
    local row = M.HEADER_LINES + i - 1
    if i == session.file_index then
      vim.api.nvim_buf_set_extmark(buf, M.ns, row, 0, { line_hl_group = "PrViewerFileCurrent" })
    elseif f.viewed == "VIEWED" then
      vim.api.nvim_buf_set_extmark(buf, M.ns, row, 0, { line_hl_group = "PrViewerFileViewed" })
    end
  end
end

--- files ウィンドウのカーソルを現在のファイルに合わせる。
---@param session PrViewer.Session
function M.sync_cursor(session)
  local win = session.wins and session.wins.files
  if win and vim.api.nvim_win_is_valid(win) and session.file_index > 0 then
    pcall(vim.api.nvim_win_set_cursor, win, { M.HEADER_LINES + session.file_index, 0 })
  end
end

---@param session PrViewer.Session
---@return integer?
function M.index_at_cursor(session)
  local win = session.wins and session.wins.files
  if not win or vim.api.nvim_get_current_win() ~= win then
    return nil
  end
  local row = vim.api.nvim_win_get_cursor(win)[1]
  local idx = row - M.HEADER_LINES
  if idx >= 1 and idx <= #session.pr.files then
    return idx
  end
  return nil
end

return M
