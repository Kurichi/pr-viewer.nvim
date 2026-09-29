-- ローカル git 操作。すべて vim.system で非同期、コールバックはメインループ上で呼ぶ。
-- docs/DESIGN.md D4: diff の中身は GitHub ではなくローカル git から取る。
local M = {}

---@param args string[]
---@param cwd string?
---@param cb fun(err: string?, stdout: string?, code: integer?)
function M.exec(args, cwd, cb)
  local cmd = { "git" }
  vim.list_extend(cmd, args)
  vim.system(cmd, { cwd = cwd, text = true }, function(out)
    vim.schedule(function()
      if out.code ~= 0 then
        local err = vim.trim(out.stderr or "")
        if err == "" then
          err = ("git %s exited with code %d"):format(args[1] or "", out.code)
        end
        cb(err, nil, out.code)
      else
        cb(nil, out.stdout or "", 0)
      end
    end)
  end)
end

--- カレントディレクトリのリポジトリルート。
---@param cb fun(err: string?, root: string?)
function M.root(cb)
  M.exec({ "rev-parse", "--show-toplevel" }, vim.uv.cwd(), function(err, out)
    cb(err, out and vim.trim(out) or nil)
  end)
end

---@param root string
---@param cb fun(err: string?, url: string?)
function M.remote_url(root, cb)
  M.exec({ "remote", "get-url", "origin" }, root, function(err, out)
    cb(err, out and vim.trim(out) or nil)
  end)
end

---@class PrViewer.Remote
---@field host string
---@field owner string
---@field repo string

--- remote URL から owner / repo を取り出す（純粋関数）。
---@param url string
---@return PrViewer.Remote?
function M.parse_remote(url)
  url = vim.trim(url):gsub("/+$", "")
  local host, owner, repo = url:match("^git@([^:]+):([^/]+)/(.+)$")
  if not host then
    host, owner, repo = url:match("^ssh://[^@/]+@([^/:]+):?%d*/([^/]+)/(.+)$")
  end
  if not host then
    host, owner, repo = url:match("^https?://([^/]+)/([^/]+)/(.+)$")
  end
  if not host then
    return nil
  end
  repo = repo:gsub("%.git$", "")
  return { host = host, owner = owner, repo = repo }
end

---@param root string
---@param oid string
---@param cb fun(has: boolean)
function M.has_commit(root, oid, cb)
  M.exec({ "cat-file", "-e", oid .. "^{commit}" }, root, function(err)
    cb(err == nil)
  end)
end

---@param root string
---@param refspecs string[]
---@param cb fun(err: string?)
function M.fetch(root, refspecs, cb)
  local args = { "fetch", "--no-tags", "origin" }
  vim.list_extend(args, refspecs)
  M.exec(args, root, function(err)
    cb(err)
  end)
end

---@param root string
---@param a string
---@param b string
---@param cb fun(err: string?, oid: string?)
function M.merge_base(root, a, b, cb)
  M.exec({ "merge-base", a, b }, root, function(err, out)
    cb(err, out and vim.trim(out) or nil)
  end)
end

---@param root string
---@param rev string
---@param cb fun(err: string?, oid: string?)
function M.rev_parse(root, rev, cb)
  local args = { "rev-parse", "--verify" }
  vim.list_extend(args, vim.split(rev, " ", { plain = true, trimempty = true }))
  M.exec(args, root, function(err, out)
    cb(err, out and vim.trim(out) or nil)
  end)
end

--- PR head 用の worktree を用意する（無ければ作り、あれば oid に合わせる）。
--- ユーザーの作業ツリーには触れない。LSP はこの worktree をルートとして付く。
---@param root string メインリポジトリ
---@param path string worktree のパス
---@param oid string チェックアウトするコミット
---@param cb fun(err: string?, path: string?)
function M.worktree_ensure(root, path, oid, cb)
  -- 手で消された worktree の登録を掃除してから判定する
  M.exec({ "worktree", "prune" }, root, function()
    if vim.uv.fs_stat(path .. "/.git") then
      M.rev_parse(path, "HEAD", function(err, head)
        if not err and head == oid then
          return cb(nil, path)
        end
        M.exec({ "checkout", "-q", "--detach", oid }, path, function(e)
          cb(e, path)
        end)
      end)
      return
    end
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    M.exec({ "worktree", "add", "--detach", path, oid }, root, function(e)
      cb(e, path)
    end)
  end)
end

--- `git show <rev>:<path>` の内容を行配列で返す。rev にファイルが無ければ空配列。
---@param root string
---@param rev string
---@param path string
---@param cb fun(err: string?, lines: string[]?)
function M.show(root, rev, path, cb)
  M.exec({ "show", rev .. ":" .. path }, root, function(err, out)
    if err then
      if
        err:find("does not exist in", 1, true) or err:find("exists on disk, but not in", 1, true)
      then
        return cb(nil, {})
      end
      return cb(err, nil)
    end
    local lines = vim.split(out, "\n", { plain = true })
    if lines[#lines] == "" then
      lines[#lines] = nil
    end
    cb(nil, lines)
  end)
end

return M
