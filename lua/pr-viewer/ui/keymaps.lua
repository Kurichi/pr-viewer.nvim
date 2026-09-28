-- レビュー用バッファへのバッファローカルキーマップ。グローバルには張らない。
local config = require("pr-viewer.config")

local M = {}

---@param session PrViewer.Session
---@param buf integer
---@param extra? table<string, fun()> パネル固有の追加（open_file など）
function M.attach(session, buf, extra)
  if vim.b[buf].pr_viewer_bound then
    return
  end
  vim.b[buf].pr_viewer_bound = true
  session.bound_bufs[buf] = true

  local keys = config.get().keymaps
  local actions = require("pr-viewer.ui.actions")
  local map = function(name, fn, desc, modes)
    local lhs = keys[name]
    if lhs and lhs ~= "" then
      vim.keymap.set(modes or "n", lhs, function()
        fn(session)
      end, { buffer = buf, nowait = true, silent = true, desc = "pr-viewer: " .. desc })
    end
  end

  map("toggle_viewed", actions.toggle_viewed, "Toggle viewed")
  map("next_file", actions.next_file, "Next file")
  map("prev_file", actions.prev_file, "Previous file")
  map("next_thread", actions.next_thread, "Next thread")
  map("prev_thread", actions.prev_thread, "Previous thread")
  map("show_thread", actions.show_thread, "Show thread at cursor")
  map("add_comment", actions.add_comment, "Add draft comment", { "n", "x" })
  map("edit_comment", actions.edit_comment, "Edit draft comment")
  map("delete_comment", actions.delete_comment, "Delete draft comment")
  map("submit", actions.submit, "Submit review")
  map("close", actions.close, "Close PR view")
  for name, fn in pairs(extra or {}) do
    map(name, fn, (name:gsub("_", " ")))
  end
end

--- 実ファイルのバッファに残ったキーマップを外す。scratch は wipe されるので不要。
---@param session PrViewer.Session
function M.detach_all(session)
  local keys = config.get().keymaps
  for buf in pairs(session.bound_bufs) do
    if vim.api.nvim_buf_is_valid(buf) then
      for _, lhs in pairs(keys) do
        if lhs and lhs ~= "" then
          pcall(vim.keymap.del, "n", lhs, { buffer = buf })
          pcall(vim.keymap.del, "x", lhs, { buffer = buf })
        end
      end
      vim.b[buf].pr_viewer_bound = nil
    end
  end
  session.bound_bufs = {}
end

return M
