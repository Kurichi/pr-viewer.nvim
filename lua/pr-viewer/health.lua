-- :checkhealth pr-viewer
local M = {}

function M.check()
  local health = vim.health
  health.start("pr-viewer.nvim")

  if vim.fn.has("nvim-0.11") == 1 then
    health.ok("Neovim >= 0.11")
  else
    health.error("Neovim >= 0.11 is required")
  end

  local cfg = require("pr-viewer.config").get().gh
  if vim.fn.executable(cfg.cmd) ~= 1 then
    health.error(
      ("`%s` not found in PATH"):format(cfg.cmd),
      { "Install GitHub CLI: https://cli.github.com/" }
    )
    return
  end
  local version = vim.system({ cfg.cmd, "--version" }, { text = true }):wait()
  health.ok(("gh: %s"):format(vim.trim(vim.split(version.stdout or "", "\n")[1] or "")))

  local auth = vim.system({ cfg.cmd, "auth", "status" }, { text = true }):wait()
  if auth.code == 0 then
    health.ok("gh auth status: logged in")
  else
    health.error("gh is not authenticated", { "Run `gh auth login`" })
  end

  if vim.fn.executable("git") == 1 then
    health.ok("git found")
  else
    health.error("git not found in PATH (needed for local diff)")
  end
end

return M
