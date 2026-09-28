-- 2 ペイン diff（docs/DESIGN.md D4）。左 = merge-base の内容、右 = 実ファイル or head の内容。
local async = require("pr-viewer.async")
local config = require("pr-viewer.config")
local git = require("pr-viewer.git")
local keymaps = require("pr-viewer.ui.keymaps")
local signs = require("pr-viewer.signs")

local M = {}

---@param session PrViewer.Session
---@param side "base"|"head"
---@param path string
---@param lines string[]
---@return integer buf
local function scratch_buf(session, side, path, lines)
  local buf = vim.api.nvim_create_buf(false, true)
  pcall(
    vim.api.nvim_buf_set_name,
    buf,
    ("pr-viewer://%d/%s/%s"):format(session.pr.number, side, path)
  )
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  local ft = vim.filetype.match({ filename = path, buf = buf })
  if ft then
    vim.bo[buf].filetype = ft
  end
  return buf
end

--- base 側バッファ（キャッシュあり）。coroutine 内で呼ぶ。
---@param session PrViewer.Session
---@param file PrViewer.File
---@return integer
local function base_buf(session, file)
  local cached = session.bufs.base[file.path]
  if cached and vim.api.nvim_buf_is_valid(cached) then
    return cached
  end
  local lines = {}
  if file.change_type ~= "ADDED" then
    -- TODO(M5): RENAMED は旧パスが必要。GraphQL の files には無いので git で引く
    lines = async.must(async.await(function(cb)
      git.show(session.git_root, session.merge_base, file.path, cb)
    end))
  end
  local buf = scratch_buf(session, "base", file.path, lines)
  session.bufs.base[file.path] = buf
  return buf
end

--- head 側バッファ。HEAD が PR head と一致していれば実ファイル（LSP が効く）。
---@param session PrViewer.Session
---@param file PrViewer.File
---@return integer
local function head_buf(session, file)
  local cached = session.bufs.head[file.path]
  if cached and vim.api.nvim_buf_is_valid(cached) then
    return cached
  end
  local abs = session.git_root .. "/" .. file.path
  if
    config.get().diff.use_local_fs
    and session.head_local
    and file.change_type ~= "DELETED"
    and vim.uv.fs_stat(abs)
  then
    local buf = vim.fn.bufadd(abs)
    vim.fn.bufload(buf)
    vim.bo[buf].buflisted = true
    session.bufs.head[file.path] = buf
    return buf
  end
  local lines = {}
  if file.change_type ~= "DELETED" then
    lines = async.must(async.await(function(cb)
      git.show(session.git_root, session.pr.head_oid, file.path, cb)
    end))
  end
  local buf = scratch_buf(session, "head", file.path, lines)
  session.bufs.head[file.path] = buf
  return buf
end

---@param session PrViewer.Session
---@return boolean
local function alive(session)
  return session.tab ~= nil
    and vim.api.nvim_tabpage_is_valid(session.tab)
    and vim.api.nvim_win_is_valid(session.wins.base)
    and vim.api.nvim_win_is_valid(session.wins.head)
end

--- idx 番目のファイルを両ペインに表示する。
---@param session PrViewer.Session
---@param idx integer
---@param cb? fun()
function M.show(session, idx, cb)
  local file = session.pr.files[idx]
  if not file or not alive(session) then
    return
  end
  session.file_index = idx
  async.run(function()
    local b = base_buf(session, file)
    local h = head_buf(session, file)
    if not alive(session) then
      return
    end
    local wins = session.wins
    for _, w in ipairs({ wins.base, wins.head }) do
      vim.api.nvim_win_call(w, function()
        vim.cmd.diffoff()
      end)
    end
    vim.api.nvim_win_set_buf(wins.base, b)
    vim.api.nvim_win_set_buf(wins.head, h)
    for _, w in ipairs({ wins.base, wins.head }) do
      vim.api.nvim_win_call(w, function()
        vim.cmd.diffthis()
      end)
    end
    local threads = session.threads_by_path[file.path] or {}
    signs.place(b, threads, "LEFT")
    signs.place(h, threads, "RIGHT")
    keymaps.attach(session, b)
    keymaps.attach(session, h)

    -- 最初の変更箇所へ
    vim.api.nvim_win_call(wins.head, function()
      vim.api.nvim_win_set_cursor(wins.head, { 1, 0 })
      pcall(vim.cmd.normal, { "]c", bang = true })
    end)

    local files = require("pr-viewer.ui.files")
    files.render(session)
    files.sync_cursor(session)
    if cb then
      cb()
    end
  end)
end

--- 現在のウィンドウがどちらの side か。files パネルなら nil。
---@param session PrViewer.Session
---@return "LEFT"|"RIGHT"?
function M.current_side(session)
  local win = vim.api.nvim_get_current_win()
  if win == session.wins.base then
    return "LEFT"
  elseif win == session.wins.head then
    return "RIGHT"
  end
  return nil
end

return M
