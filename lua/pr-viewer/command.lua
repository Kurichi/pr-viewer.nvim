-- `:PR <subcommand> [args]` のディスパッチ。
-- サブコマンドは表駆動にして、補完も同じ表から生成する。
local M = {}

---@class PrViewer.Subcommand
---@field run fun(args: string[], cmd: table)
---@field desc string

---@type table<string, PrViewer.Subcommand>
M.subcommands = {
  open = {
    desc = "Open a pull request (number, URL, or current branch)",
    run = function(args)
      require("pr-viewer").open(args[1])
    end,
  },
  list = {
    desc = "List pull requests",
    run = function()
      require("pr-viewer").list()
    end,
  },
  health = {
    desc = "Run :checkhealth pr-viewer",
    run = function()
      vim.cmd("checkhealth pr-viewer")
    end,
  },
}

---@param cmd table nvim_create_user_command のコールバック引数
function M.run(cmd)
  local args = cmd.fargs or {}
  local name = table.remove(args, 1)
  if not name then
    -- 引数なしはカレントブランチの PR を開く（最頻出操作を最短にする）
    name = "open"
  end
  local sub = M.subcommands[name]
  if not sub then
    vim.notify(("pr-viewer.nvim: unknown subcommand %q"):format(name), vim.log.levels.ERROR)
    return
  end
  sub.run(args, cmd)
end

---@param arg_lead string
---@param cmd_line string
---@return string[]
function M.complete(arg_lead, cmd_line, _)
  -- "PR " の直後だけサブコマンド名を補完する
  local words = vim.split(vim.trim(cmd_line), "%s+")
  if #words > 2 or (#words == 2 and cmd_line:sub(-1) == " ") then
    return {}
  end
  local names = vim.tbl_keys(M.subcommands)
  table.sort(names)
  return vim.tbl_filter(function(name)
    return vim.startswith(name, arg_lead)
  end, names)
end

return M
