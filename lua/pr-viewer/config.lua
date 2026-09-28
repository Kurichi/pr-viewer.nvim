local M = {}

---@class PrViewer.Config.Gh
---@field cmd string gh 実行ファイル
---@field timeout_ms integer 1 リクエストのタイムアウト

---@class PrViewer.Config.Sync
---@field debounce_ms integer 楽観的更新の裏同期をまとめる待ち時間

---@class PrViewer.Config.Diff
---@field use_local_fs boolean head をチェックアウト中なら右ペインに実ファイルを使う（LSP を効かせる）

---@class PrViewer.Config.Ui
---@field files_width integer ファイル一覧パネルの幅
---@field thread_width integer スレッド float の最大幅
---@field thread_height integer スレッド float の最大高さ

---@class PrViewer.Config
---@field gh PrViewer.Config.Gh
---@field sync PrViewer.Config.Sync
---@field diff PrViewer.Config.Diff
---@field ui PrViewer.Config.Ui
---@field keymaps table<string, string|false> バッファローカルキーマップ。false で無効化

---@type PrViewer.Config
M.defaults = {
  gh = {
    cmd = "gh",
    timeout_ms = 30000,
  },
  sync = {
    debounce_ms = 500,
  },
  diff = {
    use_local_fs = true,
  },
  ui = {
    files_width = 36,
    thread_width = 80,
    thread_height = 20,
  },
  -- <localleader> 前提（octo と同じ流儀）。docs/DESIGN.md「キーマップ」参照
  keymaps = {
    toggle_viewed = "<localleader><space>",
    next_file = "]f",
    prev_file = "[f",
    next_thread = "]t",
    prev_thread = "[t",
    show_thread = "K",
    open_file = "<CR>", -- ファイル一覧パネルのみ
    add_comment = "<localleader>c",
    reply = "<localleader>r",
    resolve = "<localleader>R",
    submit = "<localleader>s",
    list_threads = "<localleader>l",
    close = "q",
  },
}

---@type PrViewer.Config
local current = vim.deepcopy(M.defaults)

---@param opts? PrViewer.Config
function M.setup(opts)
  current = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  vim.validate("gh.cmd", current.gh.cmd, "string")
  vim.validate("gh.timeout_ms", current.gh.timeout_ms, "number")
  vim.validate("sync.debounce_ms", current.sync.debounce_ms, "number")
  vim.validate("diff.use_local_fs", current.diff.use_local_fs, "boolean")
  vim.validate("ui.files_width", current.ui.files_width, "number")
  vim.validate("ui.thread_width", current.ui.thread_width, "number")
  vim.validate("ui.thread_height", current.ui.thread_height, "number")
end

---@return PrViewer.Config
function M.get()
  return current
end

return M
