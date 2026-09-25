-- GraphQL クエリ定義。
-- 「起動時に 1 回で全部取る」原則（docs/DESIGN.md D6）に従い、PR を開くのに必要な
-- 本体・変更ファイル・viewed 状態・既存スレッドを 1 クエリにまとめる。
-- ページングは first:100 を超えたときだけ、初回描画後に endCursor から追加取得する。
local M = {}

M.pull_request = [[
query PullRequest($owner: String!, $name: String!, $number: Int!, $filesCursor: String, $threadsCursor: String) {
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

return M
