-- GraphQL クエリ定義。
-- 「起動時に 1 回で全部取る」原則（docs/DESIGN.md D6）に従い、PR を開くのに必要な
-- 本体・変更ファイル・viewed 状態・既存スレッドを 1 クエリにまとめる。
-- ページングは first:100 を超えたときだけ、初回描画後に endCursor から追加取得する。
local M = {}

M.pull_request = [[
query PullRequest($owner: String!, $name: String!, $number: Int!, $filesCursor: String, $threadsCursor: String) {
  viewer { login }
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      id
      number
      title
      body
      state
      isDraft
      url
      author { login }
      baseRefName
      baseRefOid
      headRefName
      headRefOid
      headRepository { nameWithOwner }
      viewerLatestReview { id state }
      reviewDecision
      pendingReviews: reviews(first: 1, states: [PENDING]) { nodes { id } }
      files(first: 100, after: $filesCursor) {
        pageInfo { hasNextPage endCursor }
        nodes { path additions deletions changeType viewerViewedState }
      }
      reviewThreads(first: 100, after: $threadsCursor) {
        pageInfo { hasNextPage endCursor }
        nodes {
          id
          isResolved
          isOutdated
          isCollapsed
          path
          line
          startLine
          diffSide
          startDiffSide
          comments(first: 50) {
            nodes {
              id
              databaseId
              author { login }
              body
              createdAt
              url
              pullRequestReview { id state }
            }
          }
        }
      }
    }
  }
}
]]

-- スレッド 1 件分のフィールド。query と addPullRequestReviewThread の戻りで共有する
M.thread_fields = [[
  id
  isResolved
  isOutdated
  isCollapsed
  path
  line
  startLine
  diffSide
  startDiffSide
  comments(first: 50) {
    nodes {
      id
      databaseId
      author { login }
      body
      createdAt
      url
      pullRequestReview { id state }
    }
  }
]]

-- pending review を作る（下書きの入れ物。event を付けないと PENDING になる）
M.create_pending_review = [[
mutation CreatePendingReview($pr: ID!, $commit: GitObjectID) {
  addPullRequestReview(input: { pullRequestId: $pr, commitOID: $commit }) {
    pullRequestReview { id state }
  }
}
]]

-- pending review に下書きスレッドを追加する
M.add_review_thread = [[
mutation AddReviewThread(
  $review: ID!, $path: String!, $line: Int!, $side: DiffSide!,
  $startLine: Int, $startSide: DiffSide, $body: String!
) {
  addPullRequestReviewThread(input: {
    pullRequestReviewId: $review, path: $path, line: $line, side: $side,
    startLine: $startLine, startSide: $startSide, body: $body
  }) {
    thread {
]] .. M.thread_fields .. [[
    }
  }
}
]]

M.update_review_comment = [[
mutation UpdateReviewComment($id: ID!, $body: String!) {
  updatePullRequestReviewComment(input: { pullRequestReviewCommentId: $id, body: $body }) {
    pullRequestReviewComment { id body }
  }
}
]]

M.delete_review_comment = [[
mutation DeleteReviewComment($id: ID!) {
  deletePullRequestReviewComment(input: { id: $id }) {
    pullRequestReview { id }
  }
}
]]

-- pending review を送信する
M.submit_review = [[
mutation SubmitReview($review: ID!, $event: PullRequestReviewEvent!, $body: String) {
  submitPullRequestReview(input: { pullRequestReviewId: $review, event: $event, body: $body }) {
    pullRequestReview { id state }
  }
}
]]

-- pending review が無いまま approve 等だけ送る
M.add_review_with_event = [[
mutation AddReviewWithEvent($pr: ID!, $event: PullRequestReviewEvent!, $body: String, $commit: GitObjectID) {
  addPullRequestReview(input: { pullRequestId: $pr, event: $event, body: $body, commitOID: $commit }) {
    pullRequestReview { id state }
  }
}
]]

--- 複数ファイルの viewed 状態を 1 リクエストで更新する mutation を組み立てる。
--- alias（v0, v1, ...）で並べ、path は変数で渡す（文字列エスケープを避ける）。
---@param pr_id string PullRequest の node id
---@param items { path: string, viewed: boolean }[]
---@return string query
---@return table variables
function M.mark_viewed_mutation(pr_id, items)
  local decls = { "$pr: ID!" }
  local fields = {}
  local variables = { pr = pr_id }
  for i, item in ipairs(items) do
    local var = "p" .. (i - 1)
    decls[#decls + 1] = "$" .. var .. ": String!"
    variables[var] = item.path
    fields[#fields + 1] = ("  v%d: %s(input: { pullRequestId: $pr, path: $%s }) { clientMutationId }"):format(
      i - 1,
      item.viewed and "markFileAsViewed" or "unmarkFileAsViewed",
      var
    )
  end
  local query = ("mutation MarkViewed(%s) {\n%s\n}"):format(
    table.concat(decls, ", "),
    table.concat(fields, "\n")
  )
  return query, variables
end

return M
