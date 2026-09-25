---@class PrViewer
local M = {}

--- ユーザー設定を適用する。lazy.nvim の `opts` からも呼ばれる。
--- 呼ばなくてもデフォルト設定で動く（`:PR` 実行時に遅延初期化）。
---@param opts? PrViewer.Config
function M.setup(opts)
  require("pr-viewer.config").setup(opts)
end

--- PR を開く。番号・URL 省略時はカレントブランチの PR。
--- M1 で実装予定（docs/DESIGN.md 参照）。
---@param target? string|integer PR 番号、URL、または nil
function M.open(target)
  local _ = target
  vim.notify(
    "pr-viewer.nvim: `open` is not implemented yet (see docs/DESIGN.md, M1)",
    vim.log.levels.WARN
  )
end

--- PR 一覧を picker で表示する。M4 で実装予定。
function M.list()
  vim.notify(
    "pr-viewer.nvim: `list` is not implemented yet (see docs/DESIGN.md, M4)",
    vim.log.levels.WARN
  )
end

return M
