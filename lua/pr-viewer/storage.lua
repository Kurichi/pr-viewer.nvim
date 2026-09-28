-- ローカル退避用の JSON 読み書き（review.nvim の storage.lua から移植）。
-- 送信に失敗した下書きだけをここに置く。正常時は GitHub の pending review が唯一の保存先。
local M = {}

---@param owner string
---@param repo string
---@param number integer
---@return string
function M.draft_path(owner, repo, number)
  local dir = require("pr-viewer.config").get().storage_dir
    or (vim.fn.stdpath("state") .. "/pr-viewer")
  return ("%s/%s/%s/%d.json"):format(dir, owner, repo, number)
end

---@param path string
---@return table?
function M.read_json(path)
  local f = io.open(path, "r")
  if not f then
    -- 書き込み途中で落ちた .tmp があれば拾う
    f = io.open(path .. ".tmp", "r")
    if not f then
      return nil
    end
  end
  local content = f:read("*a")
  f:close()
  local ok, data = pcall(vim.json.decode, content, { luanil = { object = true, array = true } })
  if not ok then
    return nil
  end
  return data
end

--- tmp に書いてから rename する（途中で落ちても壊れたファイルを残さない）。
---@param path string
---@param data table
function M.write_json(path, data)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local tmp = path .. ".tmp"
  local f = assert(io.open(tmp, "w"))
  f:write(vim.json.encode(data))
  f:close()
  assert(vim.uv.fs_rename(tmp, path))
end

---@param path string
function M.remove(path)
  vim.uv.fs_unlink(path)
  vim.uv.fs_unlink(path .. ".tmp")
end

return M
