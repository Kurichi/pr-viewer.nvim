-- PR ごとの状態（docs/DESIGN.md D5）。ui/* はここを通してだけデータに触る。
local async = require("pr-viewer.async")
local git = require("pr-viewer.git")
local graphql = require("pr-viewer.gh.graphql")
local model = require("pr-viewer.model.pr")
local position = require("pr-viewer.model.position")
local transport = require("pr-viewer.gh.transport")

local M = {}

---@class PrViewer.Target
---@field owner string?
---@field repo string?
---@field number integer? nil ならカレントブランチの PR

---@class PrViewer.ThreadAnchor
---@field file_index integer
---@field side "LEFT"|"RIGHT"
---@field line integer
---@field thread PrViewer.Thread

---@class PrViewer.Session
---@field owner string
---@field repo string
---@field pr PrViewer.PR
---@field git_root string
---@field merge_base string
---@field head_local boolean 作業ツリーの HEAD が PR の head と一致する
---@field file_index integer
---@field threads_by_path table<string, PrViewer.Thread[]>
---@field anchors PrViewer.ThreadAnchor[] file_index, line 順
---@field tab integer? ui/layout が設定する
---@field wins table<string, integer>? files / base / head
---@field bufs table<string, table<string, integer>> side -> path -> bufnr のキャッシュ
---@field bound_bufs table<integer, true> キーマップを張った実ファイルバッファ
---@field on_update fun()? 追加ページ取得後に ui が再描画するためのフック
---@field sync PrViewer.SyncState? gh/sync.lua が遅延初期化する
---@field on_threads_changed fun()? 下書きの追加・送信状態の変化後に ui が sign と一覧を描き直すフック
---@field _review_waiters fun(err: string?, id: string?)[]? drafts.lua が pending review 作成の直列化に使う

---@type table<integer, PrViewer.Session> tabpage -> session
M.by_tab = {}

--- `:PR open` の引数を解釈する。
---   123 / #123 / owner/repo#123 / https://github.com/owner/repo/pull/123
---@param arg string?
---@return PrViewer.Target?
---@return string? err
function M.parse_target(arg)
  if not arg or arg == "" then
    return {} -- カレントブランチ
  end
  local n = arg:match("^#?(%d+)$")
  if n then
    return { number = tonumber(n) }
  end
  local owner, repo, num = arg:match("^https?://[^/]+/([^/]+)/([^/]+)/pull/(%d+)")
  if owner then
    return { owner = owner, repo = repo, number = tonumber(num) }
  end
  owner, repo, num = arg:match("^([^/#]+)/([^/#]+)#(%d+)$")
  if owner then
    return { owner = owner, repo = repo, number = tonumber(num) }
  end
  return nil, ("cannot parse PR target: %q"):format(arg)
end

--- 索引（threads_by_path / anchors）を作り直す。ページ追加後にも呼ぶ。
---@param session PrViewer.Session
function M.reindex(session)
  session.threads_by_path = model.threads_by_path(session.pr)
  local file_index = {}
  for i, f in ipairs(session.pr.files) do
    file_index[f.path] = i
  end
  local anchors = {}
  for _, t in ipairs(session.pr.threads) do
    local a = position.anchor(t)
    local fi = file_index[t.path]
    if a and fi then
      anchors[#anchors + 1] = { file_index = fi, side = a.side, line = a.line, thread = t }
    end
  end
  table.sort(anchors, function(x, y)
    if x.file_index ~= y.file_index then
      return x.file_index < y.file_index
    end
    if x.line ~= y.line then
      return x.line < y.line
    end
    return x.side < y.side -- LEFT < RIGHT
  end)
  session.anchors = anchors
end

--- 最初に開くファイル: 未 viewed の先頭、なければ 1。
---@param session PrViewer.Session
---@return integer
function M.first_file_index(session)
  for i, f in ipairs(session.pr.files) do
    if f.viewed ~= "VIEWED" then
      return i
    end
  end
  return 1
end

---@param owner string
---@param repo string
---@param number integer
---@param cursors { files: string?, threads: string? }
---@param cb PrViewer.Callback
local function query_pr(owner, repo, number, cursors, cb)
  transport.graphql(graphql.pull_request, {
    owner = owner,
    name = repo,
    number = number,
    filesCursor = cursors.files,
    threadsCursor = cursors.threads,
  }, cb)
end

--- 100 件を超える files / threads を初回描画後に取り足す（レビューは止めない）。
---@param session PrViewer.Session
local function fetch_more(session)
  async.run(function()
    local pr = session.pr
    while pr.files_cursor or pr.threads_cursor do
      local data = async.must(async.await(function(cb)
        query_pr(
          session.owner,
          session.repo,
          pr.number,
          { files = pr.files_cursor, threads = pr.threads_cursor },
          cb
        )
      end))
      local node = data.repository.pullRequest
      -- 取り切った側は再取得しない（同じ先頭ページが返ってきて重複するため）
      if not pr.files_cursor then
        node.files = nil
      end
      if not pr.threads_cursor then
        node.reviewThreads = nil
      end
      model.merge_page(pr, node)
    end
    M.reindex(session)
    if session.on_update then
      session.on_update()
    end
  end, function(err)
    vim.notify("pr-viewer.nvim: failed to fetch remaining pages: " .. err, vim.log.levels.WARN)
  end)
end

--- PR を開く。GraphQL 1 回 + ローカル git（無いコミットだけ fetch）。
---@param target PrViewer.Target
---@param cb fun(err: string?, session: PrViewer.Session?)
function M.open(target, cb)
  async.run(function()
    local root = async.must(async.await(git.root))
    local owner, repo = target.owner, target.repo
    if not owner or not repo then
      local url = async.must(async.await(function(k)
        git.remote_url(root, k)
      end))
      local remote = git.parse_remote(url)
      if not remote then
        error(("cannot parse origin remote URL: %s"):format(url), 0)
      end
      owner, repo = remote.owner, remote.repo
    end

    local data
    if target.number then
      data = async.must(async.await(function(k)
        query_pr(owner, repo, target.number, {}, k)
      end))
    else
      local branch = async.must(async.await(function(k)
        git.rev_parse(root, "--abbrev-ref HEAD", k)
      end))
      if branch == "HEAD" then
        error("detached HEAD: pass a PR number or URL", 0)
      end
      data = async.must(async.await(function(k)
        transport.graphql(
          graphql.pull_request_by_branch,
          { owner = owner, name = repo, branch = branch },
          k
        )
      end))
      local nodes = data.repository
        and data.repository.pullRequests
        and data.repository.pullRequests.nodes
      if not nodes or #nodes == 0 then
        error(("no open pull request for branch %s"):format(branch), 0)
      end
    end
    local pr = model.from_graphql(data)

    local missing = false
    for _, oid in ipairs({ pr.base_oid, pr.head_oid }) do
      if not async.await(function(k)
        git.has_commit(root, oid, k)
      end) then
        missing = true
      end
    end
    if missing then
      -- refs/pull/N/head は fork からの PR でも取れる。base はブランチ名で取る
      async.must(async.await(function(k)
        git.fetch(root, { ("refs/pull/%d/head"):format(pr.number), pr.base_ref }, k)
      end))
    end

    local merge_base = async.must(async.await(function(k)
      git.merge_base(root, pr.base_oid, pr.head_oid, k)
    end))
    local _, head = async.await(function(k)
      git.rev_parse(root, "HEAD", k)
    end)

    ---@type PrViewer.Session
    local session = {
      owner = owner,
      repo = repo,
      pr = pr,
      git_root = root,
      merge_base = merge_base,
      head_local = (head == pr.head_oid),
      file_index = 0,
      threads_by_path = {},
      anchors = {},
      bufs = { base = {}, head = {} },
      bound_bufs = {},
    }
    M.reindex(session)
    session.file_index = M.first_file_index(session)
    -- 送信に失敗して退避していた下書きがあれば読み込んで再送する
    require("pr-viewer.drafts").load_local(session)

    vim.schedule(function()
      cb(nil, session)
    end)
    if pr.files_cursor or pr.threads_cursor then
      fetch_more(session)
    end
  end, function(err)
    cb(err, nil)
  end)
end

--- open な PR の一覧を取る（`:PR list`）。
---@param cb fun(err: string?, list: PrViewer.PRSummary?, remote: PrViewer.Remote?)
function M.list(cb)
  async.run(function()
    local root = async.must(async.await(git.root))
    local url = async.must(async.await(function(k)
      git.remote_url(root, k)
    end))
    local remote = git.parse_remote(url)
    if not remote then
      error(("cannot parse origin remote URL: %s"):format(url), 0)
    end
    local data = async.must(async.await(function(k)
      transport.graphql(graphql.pull_request_list, { owner = remote.owner, name = remote.repo }, k)
    end))
    local list = model.list_from_graphql(data)
    vim.schedule(function()
      cb(nil, list, remote)
    end)
  end, function(err)
    cb(err, nil, nil)
  end)
end

--- カレントタブのセッション。
---@return PrViewer.Session?
function M.current()
  return M.by_tab[vim.api.nvim_get_current_tabpage()]
end

return M
