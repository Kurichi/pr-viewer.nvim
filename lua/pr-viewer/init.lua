---@class PrViewer
local M = {}

--- ユーザー設定を適用する。lazy.nvim の `opts` からも呼ばれる。
--- 呼ばなくてもデフォルト設定で動く（`:PR` 実行時に遅延初期化）。
---@param opts? PrViewer.Config
function M.setup(opts)
  require("pr-viewer.config").setup(opts)
end

--- PR を開く。GraphQL 1 回 + ローカル git で 2 ペイン diff を出す。
---@param target? string PR 番号、`owner/repo#N`、URL。省略時はカレントブランチの PR
function M.open(target)
  local session = require("pr-viewer.session")
  local spec, err = session.parse_target(target)
  if not spec then
    vim.notify("pr-viewer.nvim: " .. err, vim.log.levels.ERROR)
    return
  end
  vim.notify(
    spec.number and ("pr-viewer.nvim: fetching #%d..."):format(spec.number)
      or "pr-viewer.nvim: fetching PR for the current branch...",
    vim.log.levels.INFO
  )
  session.open(spec, function(open_err, s)
    if open_err or not s then
      vim.notify("pr-viewer.nvim: " .. tostring(open_err), vim.log.levels.ERROR)
      return
    end
    require("pr-viewer.ui.layout").open(s)
  end)
end

--- open な PR を picker で選んで開く。
function M.list()
  require("pr-viewer.session").list(function(err, list)
    if err or not list then
      vim.notify("pr-viewer.nvim: " .. tostring(err), vim.log.levels.ERROR)
      return
    end
    if #list == 0 then
      vim.notify("pr-viewer.nvim: no open pull requests", vim.log.levels.INFO)
      return
    end
    vim.ui.select(list, {
      prompt = "Open pull request",
      format_item = function(pr)
        local flags = {}
        if pr.is_draft then
          flags[#flags + 1] = "draft"
        end
        if pr.review_decision then
          flags[#flags + 1] = pr.review_decision:lower():gsub("_", " ")
        end
        return ("#%-5d %s  @%s  %s%s"):format(
          pr.number,
          pr.title,
          pr.author,
          pr.head_ref,
          #flags > 0 and ("  [" .. table.concat(flags, ", ") .. "]") or ""
        )
      end,
    }, function(choice)
      if choice then
        M.open(tostring(choice.number))
      end
    end)
  end)
end

return M
