---@class PrViewer
local M = {}

--- ユーザー設定を適用する。lazy.nvim の `opts` からも呼ばれる。
--- 呼ばなくてもデフォルト設定で動く（`:PR` 実行時に遅延初期化）。
---@param opts? PrViewer.Config
function M.setup(opts)
  require("pr-viewer.config").setup(opts)
end

--- PR を開く。GraphQL 1 回 + ローカル git で 2 ペイン diff を出す。
---@param target? string PR 番号、`owner/repo#N`、または URL
function M.open(target)
  local session = require("pr-viewer.session")
  local spec, err = session.parse_target(target)
  if not spec then
    vim.notify("pr-viewer.nvim: " .. err, vim.log.levels.ERROR)
    return
  end
  vim.notify(("pr-viewer.nvim: fetching #%d..."):format(spec.number), vim.log.levels.INFO)
  session.open(spec, function(open_err, s)
    if open_err or not s then
      vim.notify("pr-viewer.nvim: " .. tostring(open_err), vim.log.levels.ERROR)
      return
    end
    require("pr-viewer.ui.layout").open(s)
  end)
end

--- PR 一覧を picker で表示する。M4 で実装予定。
function M.list()
  vim.notify(
    "pr-viewer.nvim: `list` is not implemented yet (see docs/DESIGN.md, M4)",
    vim.log.levels.WARN
  )
end

return M
