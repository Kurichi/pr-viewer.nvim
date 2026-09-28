-- テスト用ヘルパー: 一時 git リポジトリと GraphQL レスポンスの雛形
local H = {}

---@param dir string
---@param rel string
---@param content string
function H.write(dir, rel, content)
  vim.fn.mkdir(vim.fs.dirname(dir .. "/" .. rel), "p")
  local f = assert(io.open(dir .. "/" .. rel, "w"))
  f:write(content)
  f:close()
end

--- base -> head の 2 コミットを持つリポジトリを作る。
---   base: a.lua, b.txt
---   head: a.lua を変更、b.txt を削除、c.lua を追加
---@return { dir: string, base: string, head: string, git: fun(...: string): string }
function H.make_repo()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local function git(...)
    local cmd = {
      "git",
      "-C",
      dir,
      "-c",
      "user.name=t",
      "-c",
      "user.email=t@example.com",
      "-c",
      "commit.gpgsign=false",
    }
    vim.list_extend(cmd, { ... })
    local out = vim.system(cmd, { text = true }):wait()
    assert(out.code == 0, out.stderr)
    return vim.trim(out.stdout)
  end
  git("init", "-q", "--template=", "-b", "main")
  git("remote", "add", "origin", "git@github.com:owner/repo.git")
  H.write(dir, "a.lua", "local a = 1\nreturn a\n")
  H.write(dir, "b.txt", "old\n")
  git("add", "-A")
  git("commit", "-q", "-m", "base")
  local base = git("rev-parse", "HEAD")
  H.write(dir, "a.lua", "local a = 1\nlocal b = 2\nreturn a + b\n")
  os.remove(dir .. "/b.txt")
  H.write(dir, "c.lua", "return {}\n")
  git("add", "-A")
  git("commit", "-q", "-m", "head")
  local head = git("rev-parse", "HEAD")
  return { dir = dir, base = base, head = head, git = git }
end

--- transport.graphql が返す `data` の形（repository.pullRequest）。
---@param repo { base: string, head: string }
---@param overrides? table
---@return table
function H.pr_data(repo, overrides)
  local data = {
    viewer = { login = "kurichi" },
    repository = {
      pullRequest = {
        id = "PR_1",
        number = 7,
        title = "Add b",
        body = "",
        state = "OPEN",
        isDraft = false,
        url = "https://github.com/owner/repo/pull/7",
        author = { login = "alice" },
        baseRefName = "main",
        baseRefOid = repo.base,
        headRefName = "feat",
        headRefOid = repo.head,
        headRepository = { nameWithOwner = "owner/repo" },
        viewerLatestReview = vim.NIL,
        reviewDecision = vim.NIL,
        pendingReviews = { nodes = {} },
        files = {
          pageInfo = { hasNextPage = false, endCursor = vim.NIL },
          nodes = {
            {
              path = "a.lua",
              additions = 2,
              deletions = 1,
              changeType = "MODIFIED",
              viewerViewedState = "VIEWED",
            },
            {
              path = "b.txt",
              additions = 0,
              deletions = 1,
              changeType = "DELETED",
              viewerViewedState = "UNVIEWED",
            },
            {
              path = "c.lua",
              additions = 1,
              deletions = 0,
              changeType = "ADDED",
              viewerViewedState = "UNVIEWED",
            },
          },
        },
        reviewThreads = {
          pageInfo = { hasNextPage = false, endCursor = vim.NIL },
          nodes = {
            {
              id = "T_right",
              isResolved = false,
              isOutdated = false,
              isCollapsed = false,
              path = "a.lua",
              line = 2,
              startLine = vim.NIL,
              diffSide = "RIGHT",
              startDiffSide = vim.NIL,
              comments = {
                nodes = {
                  {
                    id = "C1",
                    databaseId = 1,
                    author = { login = "bob" },
                    body = "why b?\nsecond line",
                    createdAt = "2026-09-01T00:00:00Z",
                    url = "u",
                    pullRequestReview = { id = "R1", state = "COMMENTED" },
                  },
                  {
                    id = "C2",
                    databaseId = 2,
                    author = { login = "alice" },
                    body = "because",
                    createdAt = "2026-09-02T00:00:00Z",
                    url = "u",
                    pullRequestReview = { id = "R1", state = "COMMENTED" },
                  },
                },
              },
            },
            {
              id = "T_left",
              isResolved = true,
              isOutdated = false,
              isCollapsed = true,
              path = "a.lua",
              line = 1,
              startLine = vim.NIL,
              diffSide = "LEFT",
              startDiffSide = vim.NIL,
              comments = {
                nodes = {
                  {
                    id = "C3",
                    databaseId = 3,
                    author = { login = "bob" },
                    body = "old line",
                    createdAt = "2026-09-01T00:00:00Z",
                  },
                },
              },
            },
            {
              id = "T_outdated",
              isResolved = false,
              isOutdated = true,
              isCollapsed = false,
              path = "c.lua",
              line = vim.NIL,
              startLine = vim.NIL,
              diffSide = "RIGHT",
              startDiffSide = vim.NIL,
              comments = {
                nodes = {
                  {
                    id = "C4",
                    databaseId = 4,
                    author = { login = "bob" },
                    body = "gone",
                    createdAt = "2026-09-01T00:00:00Z",
                  },
                },
              },
            },
          },
        },
      },
    },
  }
  return vim.tbl_deep_extend("force", data, overrides or {})
end

--- transport._system を差し替え、GraphQL に固定レスポンスを返す。呼び出し回数を数える。
---@param data table
---@return { calls: integer, restore: fun() }
function H.fake_gh(data)
  local transport = require("pr-viewer.gh.transport")
  local orig = transport._system
  local state = { calls = 0 }
  transport._system = function(_, _, on_exit)
    state.calls = state.calls + 1
    on_exit({ code = 0, stdout = vim.json.encode({ data = data }), stderr = "", signal = 0 })
  end
  state.restore = function()
    transport._system = orig
  end
  return state
end

---@param cond fun(): boolean
---@param ms? integer
function H.wait(cond, ms)
  assert(vim.wait(ms or 5000, cond, 10), "timed out waiting for condition")
end

return H
