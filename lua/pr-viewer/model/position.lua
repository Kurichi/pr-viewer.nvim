-- スレッドの位置 (path, side, line) と表示上の位置の対応。
-- GitHub の line は「そのスレッドが付いた時点の side 側ファイルの行番号」で、outdated なら nil。
local M = {}

---@class PrViewer.Anchor
---@field side "LEFT"|"RIGHT"
---@field line integer
---@field start_line integer

---@param thread PrViewer.Thread
---@return PrViewer.Anchor?
function M.anchor(thread)
  if thread.outdated or not thread.line then
    return nil
  end
  return {
    side = thread.side,
    line = thread.line,
    start_line = thread.start_line or thread.line,
  }
end

--- side 側の line 行にかかっているスレッドを返す。
---@param threads PrViewer.Thread[]
---@param side "LEFT"|"RIGHT"
---@param line integer
---@return PrViewer.Thread[]
function M.threads_at(threads, side, line)
  local found = {}
  for _, t in ipairs(threads) do
    local a = M.anchor(t)
    if a and a.side == side and line >= a.start_line and line <= a.line then
      found[#found + 1] = t
    end
  end
  return found
end

return M
