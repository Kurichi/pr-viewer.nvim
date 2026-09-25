-- headless テスト用の最小 init。`make test` / CI から `nvim --clean -u tests/minimal_init.lua` で読まれる。
local root = vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)))
local plenary = root .. "/.deps/plenary.nvim"

vim.opt.runtimepath:prepend(root)
vim.opt.runtimepath:prepend(plenary)
vim.opt.swapfile = false

vim.cmd("runtime plugin/plenary.vim")
