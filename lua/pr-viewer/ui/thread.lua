-- スレッドを読むための float（M1 は読み取り専用。M3 で入力を足す）。
local config = require("pr-viewer.config")

local M = {}

---@type integer?
local current_win

function M.close()
  if current_win and vim.api.nvim_win_is_valid(current_win) then
    vim.api.nvim_win_close(current_win, true)
  end
  current_win = nil
end

---@param threads PrViewer.Thread[]
---@return string[]
function M.render(threads)
  local lines = {}
  for i, t in ipairs(threads) do
    if i > 1 then
      lines[#lines + 1] = ""
    end
    local flags = {}
    if t.resolved then
      flags[#flags + 1] = "resolved"
    end
    if t.outdated then
      flags[#flags + 1] = "outdated"
    end
    if t.pending then
      flags[#flags + 1] = t.sync == "local" and "draft, unsent" or "draft"
    end
    local where = t.line and ("%s:%d"):format(t.path, t.line) or t.path
    lines[#lines + 1] = ("### %s%s"):format(
      where,
      #flags > 0 and (" [" .. table.concat(flags, ", ") .. "]") or ""
    )
    for _, c in ipairs(t.comments) do
      lines[#lines + 1] = ("**@%s** %s"):format(c.author, c.created_at:sub(1, 10))
      for _, l in ipairs(vim.split(c.body, "\n", { plain = true })) do
        lines[#lines + 1] = l
      end
      lines[#lines + 1] = ""
    end
    if lines[#lines] == "" then
      lines[#lines] = nil
    end
  end
  return lines
end

--- カーソル位置に float を出す。
---@param threads PrViewer.Thread[]
---@param opts? { focus: boolean } focus=false なら CursorMoved で自動で閉じる
function M.show(threads, opts)
  opts = opts or {}
  M.close()
  if #threads == 0 then
    return
  end
  local ui = config.get().ui
  local lines = M.render(threads)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "markdown"

  local width = 0
  for _, l in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l))
  end
  width = math.max(20, math.min(width + 1, ui.thread_width, vim.o.columns - 4))
  local height = math.min(#lines, ui.thread_height, vim.o.lines - 4)

  local win = vim.api.nvim_open_win(buf, opts.focus ~= false, {
    relative = "cursor",
    row = 1,
    col = 0,
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = (" %d thread%s "):format(#threads, #threads > 1 and "s" or ""),
    title_pos = "left",
  })
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  current_win = win

  for _, k in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", k, M.close, { buffer = buf, nowait = true, desc = "Close thread" })
  end

  if opts.focus == false then
    local origin = vim.api.nvim_get_current_buf()
    vim.api.nvim_create_autocmd({ "CursorMoved", "BufLeave", "WinScrolled" }, {
      buffer = origin,
      once = true,
      callback = function()
        if current_win == win then
          M.close()
        end
      end,
    })
  end
end

--- 本文入力用の float。確定は <C-s>（insert/normal）か normal の <CR>、中止は q / <Esc>。
--- review.nvim の ui.add_comment から入力部分だけを移植した。
---@param opts { title: string, initial?: string[] }
---@param cb fun(body: string?) 中止なら nil
function M.input(opts, cb)
  M.close()
  local ui = config.get().ui
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, opts.initial or {})
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "markdown"

  local width = math.max(40, math.min(ui.thread_width, vim.o.columns - 4))
  local height = math.min(12, vim.o.lines - 4)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "cursor",
    row = 1,
    col = 0,
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = " " .. opts.title .. " (<C-s> submit, q cancel) ",
    title_pos = "left",
  })
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  current_win = win

  local finished = false
  local function finish(body)
    if finished then
      return
    end
    finished = true
    M.close()
    cb(body)
  end
  local function submit()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local body = vim.trim(table.concat(lines, "\n"))
    if body == "" then
      finish(nil)
    else
      finish(body)
    end
  end
  vim.keymap.set({ "n", "i" }, "<C-s>", submit, { buffer = buf, nowait = true, desc = "Submit" })
  vim.keymap.set("n", "<CR>", submit, { buffer = buf, nowait = true, desc = "Submit" })
  for _, k in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", k, function()
      finish(nil)
    end, { buffer = buf, nowait = true, desc = "Cancel" })
  end
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    once = true,
    callback = function()
      finish(nil)
    end,
  })
  if not opts.initial or #opts.initial == 0 then
    vim.cmd.startinsert()
  end
end

return M
