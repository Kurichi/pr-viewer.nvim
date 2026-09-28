local threads = require("pr-viewer.threads")
local transport = require("pr-viewer.gh.transport")
local H = require("tests.pr-viewer.helpers")

local function fake_gh()
  local orig = transport._system
  local st = { calls = {}, fail = false }
  transport._system = function(_, opts, on_exit)
    local body = vim.json.decode(opts.stdin)
    local kind = body.query:match("mutation (%w+)") or "?"
    st.calls[#st.calls + 1] = { kind = kind, variables = body.variables }
    if st.fail then
      return on_exit({ code = 1, stdout = "", stderr = "boom", signal = 0 })
    end
    local data
    if kind == "AddThreadReply" then
      data = {
        addPullRequestReviewThreadReply = {
          comment = {
            id = "C_reply",
            databaseId = 99,
            author = { login = "kurichi" },
            body = body.variables.body,
            createdAt = "2026-09-28T00:00:00Z",
            pullRequestReview = { id = "R9", state = "COMMENTED" },
          },
        },
      }
    else
      data =
        { resolveReviewThread = { thread = { id = body.variables.thread, isResolved = true } } }
    end
    on_exit({ code = 0, stdout = vim.json.encode({ data = data }), stderr = "", signal = 0 })
  end
  st.restore = function()
    transport._system = orig
  end
  return st
end

local function new_session()
  local pr = require("pr-viewer.model.pr").from_graphql(H.pr_data({ base = "b", head = "h" }))
  local s = { owner = "o", repo = "r", pr = pr, threads_by_path = {}, anchors = {}, changed = 0 }
  s.on_threads_changed = function()
    s.changed = s.changed + 1
  end
  require("pr-viewer.session").reindex(s)
  return s
end

local function settle(cond)
  assert(vim.wait(2000, cond, 5), "timed out")
end

describe("pr-viewer.threads", function()
  local gh
  before_each(function()
    gh = fake_gh()
  end)
  after_each(function()
    gh.restore()
  end)

  it("reply appends optimistically and adopts the server comment", function()
    local s = new_session()
    local t = s.pr.threads[1]
    local n = #t.comments
    local done
    threads.reply(s, t, "agreed", function(err)
      done = { err = err }
    end)
    assert.are.equal(n + 1, #t.comments)
    assert.are.equal("kurichi", t.comments[n + 1].author)
    assert.are.equal("SENDING", t.comments[n + 1].review_state)
    settle(function()
      return done ~= nil
    end)
    assert.is_nil(done.err)
    assert.are.equal("C_reply", t.comments[n + 1].id)
    assert.are.equal("COMMENTED", t.comments[n + 1].review_state)
    assert.are.same({ thread = "T_right", body = "agreed" }, gh.calls[1].variables)
  end)

  it("reply is removed again when the request fails", function()
    gh.fail = true
    local s = new_session()
    local t = s.pr.threads[1]
    local n = #t.comments
    local orig = vim.notify
    local msg
    vim.notify = function(m)
      msg = m
    end
    local done
    threads.reply(s, t, "oops", function(err)
      done = { err = err }
    end)
    settle(function()
      return done ~= nil
    end)
    vim.notify = orig
    assert.are.equal(n, #t.comments)
    assert.matches("failed to reply", msg)
  end)

  it("toggle_resolved flips immediately and calls the right mutation", function()
    local s = new_session()
    local t = s.pr.threads[1] -- unresolved
    local done
    threads.toggle_resolved(s, t, function(err)
      done = { err = err }
    end)
    assert.is_true(t.resolved)
    settle(function()
      return done ~= nil
    end)
    assert.are.equal("ResolveThread", gh.calls[1].kind)
    threads.toggle_resolved(s, t)
    assert.is_false(t.resolved)
    settle(function()
      return #gh.calls == 2
    end)
    assert.are.equal("UnresolveThread", gh.calls[2].kind)
  end)

  it("toggle_resolved reverts on failure and refuses drafts", function()
    gh.fail = true
    local s = new_session()
    local t = s.pr.threads[1]
    local orig = vim.notify
    vim.notify = function() end
    local done
    threads.toggle_resolved(s, t, function(err)
      done = { err = err }
    end)
    settle(function()
      return done ~= nil
    end)
    assert.is_false(t.resolved)
    t.pending = true
    local refused
    threads.toggle_resolved(s, t, function(err)
      refused = err
    end)
    vim.notify = orig
    assert.are.equal("pending", refused)
    assert.are.equal(1, #gh.calls)
  end)
end)
