-- pr-viewer.nvim エントリポイント。
-- ここでは重い処理をせず、コマンド定義だけ行う（require は遅延）。
if vim.g.loaded_pr_viewer then
  return
end
vim.g.loaded_pr_viewer = true

if vim.fn.has("nvim-0.11") ~= 1 then
  vim.notify_once("pr-viewer.nvim requires Neovim >= 0.11", vim.log.levels.ERROR)
  return
end

vim.api.nvim_create_user_command("PR", function(cmd)
  require("pr-viewer.command").run(cmd)
end, {
  nargs = "*",
  complete = function(arg_lead, cmd_line, cursor_pos)
    return require("pr-viewer.command").complete(arg_lead, cmd_line, cursor_pos)
  end,
  desc = "pr-viewer.nvim: :PR <subcommand> [args]",
})
