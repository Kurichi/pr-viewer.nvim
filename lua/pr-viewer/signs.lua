-- スレッドの sign / virtual text（extmark）。review.nvim の signs.lua を PR スレッド向けに簡略化して移植。
local position = require("pr-viewer.model.position")

local M = {}

M.ns = vim.api.nvim_create_namespace("pr_viewer_threads")

local hl_defined = false
local function ensure_highlights()
  if hl_defined then
    return
  end
  hl_defined = true
  vim.api.nvim_set_hl(0, "PrViewerThread", { link = "DiagnosticWarn", default = true })
  vim.api.nvim_set_hl(0, "PrViewerThreadResolved", { link = "DiagnosticOk", default = true })
  vim.api.nvim_set_hl(0, "PrViewerDraft", { link = "DiagnosticInfo", default = true })
  vim.api.nvim_set_hl(0, "PrViewerDraftLocal", { link = "DiagnosticError", default = true })
  vim.api.nvim_set_hl(0, "PrViewerVirtText", { link = "Comment", default = true })
  vim.api.nvim_set_hl(0, "PrViewerFileViewed", { link = "Comment", default = true })
  vim.api.nvim_set_hl(0, "PrViewerFileCurrent", { link = "Title", default = true })
  vim.api.nvim_set_hl(0, "PrViewerHeader", { link = "Title", default = true })
  vim.api.nvim_set_hl(0, "PrViewerMuted", { link = "Comment", default = true })
end
M.ensure_highlights = ensure_highlights

---@param thread PrViewer.Thread
---@return string
local function summary(thread)
  local first = thread.comments[1]
  if not first then
    return ""
  end
  local line = vim.split(first.body, "\n", { plain = true })[1] or ""
  if #line > 60 then
    line = line:sub(1, 57) .. "..."
  end
  local extra = #thread.comments > 1 and (" (+%d)"):format(#thread.comments - 1) or ""
  local prefix = ""
  if thread.pending then
    prefix = ({ synced = "[draft] ", sending = "[sending] ", ["local"] = "[local, unsent] " })[thread.sync]
      or "[draft] "
  end
  return ("%s@%s: %s%s"):format(prefix, first.author, line, extra)
end

--- buf（side 側のファイル）にスレッドの印を付け直す。
---@param buf integer
---@param threads PrViewer.Thread[]
---@param side "LEFT"|"RIGHT"
function M.place(buf, threads, side)
  ensure_highlights()
  vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
  local line_count = vim.api.nvim_buf_line_count(buf)
  for _, t in ipairs(threads) do
    local a = position.anchor(t)
    if a and a.side == side then
      local row = math.min(a.line, line_count) - 1
      if row >= 0 then
        local hl, sign = "PrViewerThread", "●"
        if t.pending then
          hl = t.sync == "local" and "PrViewerDraftLocal" or "PrViewerDraft"
          sign = t.sync == "local" and "!" or "✎"
        elseif t.resolved then
          hl, sign = "PrViewerThreadResolved", "✓"
        end
        vim.api.nvim_buf_set_extmark(buf, M.ns, row, 0, {
          sign_text = sign,
          sign_hl_group = hl,
          virt_text = { { " " .. summary(t), "PrViewerVirtText" } },
          virt_text_pos = "eol",
        })
      end
    end
  end
end

---@param buf integer
function M.clear(buf)
  if vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
  end
end

return M
