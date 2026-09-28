-- GraphQL レスポンスを内部モデルに変換する。どのモジュールにも依存しない純粋な層。
local M = {}

--- JSON の null（vim.NIL）を nil に落とす。transport は luanil で decode するが、生の table が来ても壊れないように。
---@generic T
---@param x T
---@return T?
local function val(x)
  if x == vim.NIL then
    return nil
  end
  return x
end

---@class PrViewer.Comment
---@field id string
---@field database_id integer?
---@field author string
---@field body string
---@field created_at string
---@field url string?
---@field review_state string?

---@class PrViewer.Thread
---@field id string
---@field path string
---@field line integer? outdated だと nil
---@field start_line integer?
---@field side "LEFT"|"RIGHT"
---@field start_side "LEFT"|"RIGHT"?
---@field resolved boolean
---@field outdated boolean
---@field comments PrViewer.Comment[]
---@field pending boolean 自分の pending review に属する下書きスレッド
---@field sync "synced"|"sending"|"local"? 下書きの送信状態（pending のときだけ）
---@field local_id string? ローカル退避用の識別子（pending のときだけ）

---@class PrViewer.File
---@field path string
---@field additions integer
---@field deletions integer
---@field change_type string ADDED|DELETED|MODIFIED|RENAMED|COPIED|CHANGED
---@field viewed "VIEWED"|"UNVIEWED"|"DISMISSED"

---@class PrViewer.PR
---@field id string
---@field number integer
---@field title string
---@field body string
---@field state string OPEN|CLOSED|MERGED
---@field is_draft boolean
---@field url string
---@field author string
---@field base_ref string
---@field base_oid string
---@field head_ref string
---@field head_oid string
---@field head_repo string?
---@field review_decision string?
---@field viewer_review_state string?
---@field viewer string ログイン中のユーザー
---@field pending_review_id string? 自分の pending review（下書きの入れ物）
---@field files PrViewer.File[]
---@field threads PrViewer.Thread[]
---@field files_cursor string? 続きがあるときだけ endCursor
---@field threads_cursor string?

---@param node table
---@return PrViewer.Comment
local function comment_from_node(node)
  return {
    id = node.id,
    database_id = node.databaseId,
    author = val(node.author) and node.author.login or "ghost",
    body = node.body or "",
    created_at = node.createdAt or "",
    url = node.url,
    review_state = val(node.pullRequestReview) and node.pullRequestReview.state or nil,
  }
end

---@param node table
---@return PrViewer.Thread
function M.thread_from_node(node)
  local comments = {}
  for _, c in ipairs(node.comments and node.comments.nodes or {}) do
    comments[#comments + 1] = comment_from_node(c)
  end
  local pending = #comments > 0
  for _, c in ipairs(comments) do
    if c.review_state ~= "PENDING" then
      pending = false
    end
  end
  return {
    id = node.id,
    path = node.path,
    line = val(node.line),
    start_line = val(node.startLine),
    side = val(node.diffSide) or "RIGHT",
    start_side = val(node.startDiffSide),
    resolved = node.isResolved == true,
    outdated = node.isOutdated == true,
    comments = comments,
    pending = pending,
    sync = pending and "synced" or nil,
  }
end

---@param node table
---@return PrViewer.File
function M.file_from_node(node)
  return {
    path = node.path,
    additions = node.additions or 0,
    deletions = node.deletions or 0,
    change_type = node.changeType or "MODIFIED",
    viewed = node.viewerViewedState or "UNVIEWED",
  }
end

--- ページの files / reviewThreads を pr に追記し、カーソルを更新する。
---@param pr PrViewer.PR
---@param node table pullRequest ノード
function M.merge_page(pr, node)
  if node.files then
    for _, f in ipairs(node.files.nodes or {}) do
      pr.files[#pr.files + 1] = M.file_from_node(f)
    end
    local info = node.files.pageInfo or {}
    pr.files_cursor = info.hasNextPage == true and val(info.endCursor) or nil
  end
  if node.reviewThreads then
    for _, t in ipairs(node.reviewThreads.nodes or {}) do
      pr.threads[#pr.threads + 1] = M.thread_from_node(t)
    end
    local info = node.reviewThreads.pageInfo or {}
    pr.threads_cursor = info.hasNextPage == true and val(info.endCursor) or nil
  end
end

--- `data` 直下（transport.graphql が返す形）から PR を組み立てる。
---@param data table
---@return PrViewer.PR
function M.from_graphql(data)
  local node = data and val(data.repository) and val(data.repository.pullRequest)
  if not node then
    error("pull request not found in GraphQL response", 0)
  end
  local pr = {
    id = node.id,
    number = node.number,
    title = node.title or "",
    body = node.body or "",
    state = node.state or "OPEN",
    is_draft = node.isDraft == true,
    url = node.url,
    author = val(node.author) and node.author.login or "ghost",
    base_ref = node.baseRefName,
    base_oid = node.baseRefOid,
    head_ref = node.headRefName,
    head_oid = node.headRefOid,
    head_repo = val(node.headRepository) and node.headRepository.nameWithOwner or nil,
    review_decision = val(node.reviewDecision),
    viewer_review_state = val(node.viewerLatestReview) and node.viewerLatestReview.state or nil,
    viewer = val(data.viewer) and data.viewer.login or "",
    pending_review_id = nil,
    files = {},
    threads = {},
  }
  local pending = val(node.pendingReviews)
  if pending and pending.nodes and pending.nodes[1] then
    pr.pending_review_id = pending.nodes[1].id
  end
  M.merge_page(pr, node)
  return pr
end

--- path -> threads の索引。
---@param pr PrViewer.PR
---@return table<string, PrViewer.Thread[]>
function M.threads_by_path(pr)
  local index = {}
  for _, t in ipairs(pr.threads) do
    index[t.path] = index[t.path] or {}
    table.insert(index[t.path], t)
  end
  return index
end

---@class PrViewer.Stats
---@field files integer
---@field viewed integer
---@field threads integer
---@field unresolved integer
---@field drafts integer

---@param pr PrViewer.PR
---@return PrViewer.Stats
function M.stats(pr)
  local s = { files = #pr.files, viewed = 0, threads = 0, unresolved = 0, drafts = 0 }
  for _, f in ipairs(pr.files) do
    if f.viewed == "VIEWED" then
      s.viewed = s.viewed + 1
    end
  end
  for _, t in ipairs(pr.threads) do
    if t.pending then
      s.drafts = s.drafts + 1
    else
      s.threads = s.threads + 1
      if not t.resolved then
        s.unresolved = s.unresolved + 1
      end
    end
  end
  return s
end

return M
