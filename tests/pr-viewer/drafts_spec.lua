local drafts = require("pr-viewer.drafts")
local storage = require("pr-viewer.storage")
local transport = require("pr-viewer.gh.transport")
local H = require("tests.pr-viewer.helpers")

--- クエリの種類ごとに応答を切り替える偽装 gh。
local function fake_gh()
  local orig = transport._system
  local st = { calls = {}, restore = nil, mode = "ok" } -- mode: ok | network_error | rejected
  local counter = 0
  transport._system = function(_, opts, on_exit)
    local body = vim.json.decode(opts.stdin)
    local kind = body.query:match("mutation (%w+)") or body.query:match("query (%w+)") or "?"
    st.calls[#st.calls + 1] = { kind = kind, variables = body.variables }
    if st.mode == "network_error" then
      return on_exit({ code = 1, stdout = "", stderr = "dial tcp: connection refused", signal = 0 })
    end
    if kind == "AddReviewThread" and body.variables.review == "REV_stale" then
      return on_exit({
        code = 1,
        stdout = "",
        stderr = "gh: Could not resolve to a node with the global id of 'REV_stale'.",
        signal = 0,
      })
    end
    if st.mode == "rejected" and kind == "AddReviewThread" then
      return on_exit({
        code = 0,
        stdout = '{"data":null,"errors":[{"message":"Line could not be resolved"}]}',
        stderr = "",
        signal = 0,
      })
    end
    counter = counter + 1
    local data
    if kind == "CreatePendingReview" then
      data = { addPullRequestReview = { pullRequestReview = { id = "REV_1", state = "PENDING" } } }
    elseif kind == "AddReviewThread" then
      local v = body.variables
      data = {
        addPullRequestReviewThread = {
          thread = {
            id = "T_srv" .. counter,
            isResolved = false,
            isOutdated = false,
            path = v.path,
            line = v.line,
            startLine = v.startLine,
            diffSide = v.side,
            startDiffSide = v.startSide,
            comments = {
              nodes = {
                {
                  id = "C_srv" .. counter,
                  databaseId = counter,
                  author = { login = "kurichi" },
                  body = v.body,
                  createdAt = "2026-09-28T00:00:00Z",
                  pullRequestReview = { id = "REV_1", state = "PENDING" },
                },
              },
            },
          },
        },
      }
    elseif kind == "SubmitReview" then
      data =
        { submitPullRequestReview = { pullRequestReview = { id = "REV_1", state = "APPROVED" } } }
    elseif kind == "AddReviewWithEvent" then
      data =
        { addPullRequestReview = { pullRequestReview = { id = "REV_2", state = "COMMENTED" } } }
    else
      data = {}
    end
    on_exit({ code = 0, stdout = vim.json.encode({ data = data }), stderr = "", signal = 0 })
  end
  st.restore = function()
    transport._system = orig
  end
  st.count = function(kind)
    local n = 0
    for _, c in ipairs(st.calls) do
      if c.kind == kind then
        n = n + 1
      end
    end
    return n
  end
  return st
end

local function new_session(storage_dir)
  require("pr-viewer.config").setup({ storage_dir = storage_dir })
  local pr = require("pr-viewer.model.pr").from_graphql(H.pr_data({ base = "b", head = "h" }))
  local s = {
    owner = "owner",
    repo = "repo",
    pr = pr,
    threads_by_path = {},
    anchors = {},
    bufs = { base = {}, head = {} },
    bound_bufs = {},
    file_index = 1,
    changed = 0,
  }
  s.on_threads_changed = function()
    s.changed = s.changed + 1
  end
  require("pr-viewer.session").reindex(s)
  return s
end

local function settle(cond)
  assert(vim.wait(2000, cond, 5), "timed out")
end

describe("pr-viewer.drafts", function()
  local gh, dir
  before_each(function()
    gh = fake_gh()
    dir = vim.fn.tempname()
  end)
  after_each(function()
    gh.restore()
  end)

  it("adds a draft optimistically and syncs it to a pending review", function()
    local s = new_session(dir)
    local before = #s.pr.threads
    local t = drafts.add(s, { path = "a.lua", side = "RIGHT", line = 3 }, "looks wrong")
    -- 即座にスレッドとして見える
    assert.are.equal(before + 1, #s.pr.threads)
    assert.is_true(t.pending)
    assert.are.equal("sending", t.sync)
    assert.are.equal("kurichi", t.comments[1].author)
    assert.is_not_nil(s.threads_by_path["a.lua"][3])
    settle(function()
      return t.sync == "synced"
    end)
    assert.are.equal("T_srv2", t.id) -- 1 回目の counter は CreatePendingReview
    assert.are.equal("REV_1", s.pr.pending_review_id)
    assert.are.equal(1, gh.count("CreatePendingReview"))
    assert.are.equal(1, gh.count("AddReviewThread"))
    assert.are.same(
      { review = "REV_1", path = "a.lua", line = 3, side = "RIGHT", body = "looks wrong" },
      gh.calls[2].variables
    )
    assert.is_nil(storage.read_json(storage.draft_path("owner", "repo", 7)))
  end)

  it("creates the pending review only once for concurrent adds", function()
    local s = new_session(dir)
    local t1 = drafts.add(s, { path = "a.lua", side = "RIGHT", line = 1 }, "one")
    local t2 = drafts.add(
      s,
      { path = "a.lua", side = "LEFT", line = 2, start_line = 1, start_side = "LEFT" },
      "two"
    )
    settle(function()
      return t1.sync == "synced" and t2.sync == "synced"
    end)
    assert.are.equal(1, gh.count("CreatePendingReview"))
    assert.are.equal(2, gh.count("AddReviewThread"))
    assert.are.equal(1, gh.calls[3].variables.startLine)
  end)

  it("keeps the draft locally on a network error and resends later", function()
    gh.mode = "network_error"
    local s = new_session(dir)
    local msgs = {}
    local orig = vim.notify
    vim.notify = function(msg)
      msgs[#msgs + 1] = msg
    end
    local t = drafts.add(s, { path = "a.lua", side = "RIGHT", line = 3 }, "keep me")
    settle(function()
      return t.sync == "local"
    end)
    vim.notify = orig
    assert.matches("kept locally", msgs[1])
    assert.is_true(drafts.has_unsynced(s))
    local saved = storage.read_json(storage.draft_path("owner", "repo", 7))
    assert.are.equal(1, #saved.drafts)
    assert.are.equal("keep me", saved.drafts[1].body)
    assert.are.equal(t.local_id, saved.drafts[1].local_id)

    -- 新しいセッション（次回 open）で読み込まれて再送される
    gh.mode = "ok"
    local s2 = new_session(dir)
    drafts.load_local(s2)
    local restored
    for _, th in ipairs(s2.pr.threads) do
      if th.local_id == t.local_id then
        restored = th
      end
    end
    assert.is_not_nil(restored)
    settle(function()
      return restored.sync == "synced"
    end)
    assert.is_nil(storage.read_json(storage.draft_path("owner", "repo", 7)))
    assert.is_false(drafts.has_unsynced(s2))
  end)

  it("discards a draft GitHub rejects", function()
    gh.mode = "rejected"
    local s = new_session(dir)
    local before = #s.pr.threads
    local msgs = {}
    local orig = vim.notify
    vim.notify = function(msg)
      msgs[#msgs + 1] = msg
    end
    drafts.add(s, { path = "a.lua", side = "RIGHT", line = 99 }, "nope")
    settle(function()
      return #s.pr.threads == before
    end)
    vim.notify = orig
    assert.matches("rejected by GitHub", msgs[1])
    assert.is_nil(storage.read_json(storage.draft_path("owner", "repo", 7)))
  end)

  it("edits and deletes synced drafts on GitHub", function()
    local s = new_session(dir)
    local t = drafts.add(s, { path = "a.lua", side = "RIGHT", line = 3 }, "v1")
    settle(function()
      return t.sync == "synced"
    end)
    drafts.edit(s, t, "v2")
    assert.are.equal("v2", t.comments[1].body)
    settle(function()
      return gh.count("UpdateReviewComment") == 1
    end)
    assert.are.same({ id = "C_srv2", body = "v2" }, gh.calls[#gh.calls].variables)
    local n = #s.pr.threads
    drafts.delete(s, t)
    assert.are.equal(n - 1, #s.pr.threads)
    settle(function()
      return gh.count("DeleteReviewComment") == 1
    end)
    assert.are.same({ id = "C_srv2" }, gh.calls[#gh.calls].variables)
    -- 最後の下書きを消すと GitHub は pending review も消すので、id を持ち続けない
    settle(function()
      return s.pr.pending_review_id == nil
    end)
  end)

  it("submits the pending review in one request and clears draft state", function()
    local s = new_session(dir)
    local t = drafts.add(s, { path = "a.lua", side = "RIGHT", line = 3 }, "please")
    settle(function()
      return t.sync == "synced"
    end)
    local result
    drafts.submit(s, "APPROVE", "LGTM", function(err)
      result = { err = err }
    end)
    settle(function()
      return result ~= nil
    end)
    assert.is_nil(result.err)
    assert.are.equal(1, gh.count("SubmitReview"))
    assert.are.same(
      { review = "REV_1", event = "APPROVE", body = "LGTM" },
      gh.calls[#gh.calls].variables
    )
    assert.is_false(t.pending)
    assert.are.equal("APPROVED", t.comments[1].review_state)
    assert.is_nil(s.pr.pending_review_id)
    assert.are.equal("APPROVED", s.pr.viewer_review_state)
  end)

  it("submits without drafts via addPullRequestReview", function()
    local s = new_session(dir)
    local result
    drafts.submit(s, "COMMENT", "", function(err)
      result = { err = err }
    end)
    settle(function()
      return result ~= nil
    end)
    assert.is_nil(result.err)
    assert.are.equal(1, gh.count("AddReviewWithEvent"))
    assert.are.same({ pr = "PR_1", event = "COMMENT", commit = "h" }, gh.calls[#gh.calls].variables)
  end)

  it("recreates the pending review when the cached id is stale", function()
    local s = new_session(dir)
    s.pr.pending_review_id = "REV_stale" -- ブラウザで消された想定
    local t = drafts.add(s, { path = "a.lua", side = "RIGHT", line = 3 }, "again")
    settle(function()
      return t.sync == "synced"
    end)
    assert.are.equal(1, gh.count("CreatePendingReview"))
    assert.are.equal(2, gh.count("AddReviewThread")) -- stale で 1 回失敗、作り直して成功
    assert.are.equal("REV_1", s.pr.pending_review_id)
  end)

  it("submits via addPullRequestReview when the pending review has no drafts left", function()
    local s = new_session(dir)
    local t = drafts.add(s, { path = "a.lua", side = "RIGHT", line = 3 }, "tmp")
    settle(function()
      return t.sync == "synced"
    end)
    drafts.delete(s, t)
    settle(function()
      return s.pr.pending_review_id == nil
    end)
    local result
    drafts.submit(s, "COMMENT", "just a comment", function(err)
      result = { err = err }
    end)
    settle(function()
      return result ~= nil
    end)
    assert.is_nil(result.err)
    assert.are.equal(0, gh.count("SubmitReview"))
    assert.are.equal(1, gh.count("AddReviewWithEvent"))
  end)

  it("refuses to submit while drafts are stuck locally", function()
    gh.mode = "network_error"
    local s = new_session(dir)
    local orig = vim.notify
    vim.notify = function() end
    local t = drafts.add(s, { path = "a.lua", side = "RIGHT", line = 3 }, "stuck")
    settle(function()
      return t.sync == "local"
    end)
    local result
    drafts.submit(s, "APPROVE", "", function(err)
      result = { err = err }
    end)
    settle(function()
      return result ~= nil
    end)
    vim.notify = orig
    assert.matches("could not be sent", result.err)
    assert.are.equal(0, gh.count("SubmitReview"))
    assert.is_true(t.pending)
  end)
end)
