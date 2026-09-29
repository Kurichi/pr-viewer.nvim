-- タブページ 1 枚に「ファイル一覧 | base | head」を並べる。
local config = require("pr-viewer.config")
local keymaps = require("pr-viewer.ui.keymaps")
local session_mod = require("pr-viewer.session")
local signs = require("pr-viewer.signs")

local M = {}

local augroup = vim.api.nvim_create_augroup("pr_viewer_layout", { clear = true })

---@param win integer
---@param opts table<string, any>
local function set_win_opts(win, opts)
  for k, v in pairs(opts) do
    vim.api.nvim_set_option_value(k, v, { win = win, scope = "local" })
  end
end

---@param session PrViewer.Session
function M.open(session)
  local ui = config.get().ui
  vim.cmd.tabnew()
  local tab = vim.api.nvim_get_current_tabpage()
  local files_win = vim.api.nvim_get_current_win()
  -- tabnew が作った空バッファは files バッファで置き換える（置き換え後に wipe される）
  local files_buf = require("pr-viewer.ui.files").create(session)
  vim.api.nvim_win_set_buf(files_win, files_buf)

  local base_win = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), false, {
    split = "right",
    win = files_win,
  })
  local head_win = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), false, {
    split = "right",
    win = base_win,
  })
  vim.api.nvim_win_set_width(files_win, ui.files_width)

  set_win_opts(files_win, {
    number = false,
    relativenumber = false,
    signcolumn = "no",
    cursorline = true,
    wrap = false,
    winfixwidth = true,
    foldcolumn = "0",
    list = false,
  })
  for _, w in ipairs({ base_win, head_win }) do
    set_win_opts(w, { signcolumn = "yes", wrap = false })
  end

  session.tab = tab
  session.wins = { files = files_win, base = base_win, head = head_win }
  session_mod.by_tab[tab] = session
  require("pr-viewer.gh.sync").on_rollback(session, function(path, viewed)
    for _, f in ipairs(session.pr.files) do
      if f.path == path then
        f.viewed = viewed and "VIEWED" or "UNVIEWED"
      end
    end
    require("pr-viewer.ui.files").render(session)
  end)
  session.on_threads_changed = function()
    if not session.tab or not vim.api.nvim_tabpage_is_valid(session.tab) then
      return
    end
    require("pr-viewer.ui.files").render(session)
    require("pr-viewer.ui.diff").refresh_signs(session)
  end
  session.on_update = function()
    require("pr-viewer.ui.files").render(session)
    if session.file_index > 0 then
      require("pr-viewer.ui.diff").show(session, session.file_index)
    end
  end
  vim.api.nvim_tabpage_set_var(tab, "pr_viewer", session.pr.number)

  -- gd などで head ペインに別ファイルが開かれても q / ]f が効くようにする
  vim.api.nvim_create_autocmd("BufWinEnter", {
    group = augroup,
    callback = function(ev)
      if session_mod.by_tab[tab] == session and vim.api.nvim_get_current_win() == head_win then
        keymaps.attach(session, ev.buf)
      end
    end,
  })

  vim.api.nvim_create_autocmd("TabClosed", {
    group = augroup,
    callback = function(ev)
      if
        tonumber(ev.file)
        and session_mod.by_tab[tab] == session
        and not vim.api.nvim_tabpage_is_valid(tab)
      then
        M.cleanup(session)
      end
    end,
  })

  require("pr-viewer.ui.diff").show(session, session.file_index, function()
    if vim.api.nvim_win_is_valid(head_win) then
      vim.api.nvim_set_current_win(head_win)
    end
  end)
end

--- タブが閉じた後の後始末（キーマップ・scratch バッファ・登録解除）。
---@param session PrViewer.Session
function M.cleanup(session)
  keymaps.detach_all(session)
  for _, side in ipairs({ "base", "head" }) do
    for path, buf in pairs(session.bufs[side]) do
      if vim.api.nvim_buf_is_valid(buf) then
        if vim.bo[buf].buftype == "nofile" then
          pcall(vim.api.nvim_buf_delete, buf, { force = true })
        else
          signs.clear(buf)
        end
      end
      session.bufs[side][path] = nil
    end
  end
  if session.tab then
    session_mod.by_tab[session.tab] = nil
  end
  session.tab, session.wins = nil, nil
end

---@param session PrViewer.Session
function M.close(session)
  require("pr-viewer.ui.thread").close()
  -- 送信待ちの viewed 変更は待たずに送る
  require("pr-viewer.gh.sync").flush(session)
  local tab = session.tab
  if tab and vim.api.nvim_tabpage_is_valid(tab) then
    for _, w in ipairs({ session.wins.base, session.wins.head }) do
      if vim.api.nvim_win_is_valid(w) then
        vim.api.nvim_win_call(w, function()
          vim.cmd.diffoff()
        end)
      end
    end
    if #vim.api.nvim_list_tabpages() == 1 then
      -- 最後のタブは閉じられないので、代わりに空バッファにする
      vim.cmd.enew()
      vim.cmd.only()
    else
      vim.cmd.tabclose({ args = { tostring(vim.api.nvim_tabpage_get_number(tab)) } })
    end
  end
  M.cleanup(session)
end

return M
