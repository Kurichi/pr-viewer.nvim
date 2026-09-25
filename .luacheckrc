std = "luajit"
cache = true
codes = true
max_line_length = 120

globals = { "vim" }

-- LuaJIT / Neovim で未使用引数 (`_`) を警告しない
ignore = {
  "212/_.*", -- unused argument starting with _
}

files["tests/**/*.lua"] = {
  globals = { "describe", "it", "before_each", "after_each", "assert", "pending" },
}
