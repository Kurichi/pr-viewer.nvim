local sync = require("pr-viewer.gh.sync")
local graphql = require("pr-viewer.gh.graphql")
local transport = require("pr-viewer.gh.transport")

--- gh を偽装し、送られた GraphQL 本文を記録する。respond で完了を制御できる。
local function fake_gh()
  local orig = transport._system
  local st = { calls = {}, restore = nil, auto = true, fail = false }
  transport._system = function(_, opts, on_exit)
    local body = vim.json.decode(opts.stdin)
    local call = { query = body.query, variables = body.variables }
    call.respond = function(fail)
      if fail then
        on_exit({ code = 1, stdout = "", stderr = "boom", signal = 0 })
      else
        on_exit({
          code = 0,
          stdout = '{"data":{"v0":{"clientMutationId":null}}}',
          stderr = "",
          signal = 0,
        })
      end
    end
    st.calls[#st.calls + 1] = call
    if st.auto then
      call.respond(st.fail)
    end
  end
  st.restore = function()
    transport._system = orig
  end
  return st
end

local function new_session()
  return {
    pr = {
      id = "PR_x",
      files = {
        { path = "a.lua", viewed = "VIEWED" },
        { path = "b.lua", viewed = "UNVIEWED" },
        { path = "c.lua", viewed = "UNVIEWED" },
      },
    },
  }
end

describe("pr-viewer.gh.graphql.mark_viewed_mutation", function()
  it("builds aliased mutations with variables", function()
    local q, v = graphql.mark_viewed_mutation("PR_1", {
      { path = "x/y.lua", viewed = true },
      { path = "z.txt", viewed = false },
    })
    assert.matches("mutation MarkViewed%(%$pr: ID!, %$p0: String!, %$p1: String!%)", q)
    assert.matches("v0: markFileAsViewed%(input: { pullRequestId: %$pr, path: %$p0 }%)", q)
    assert.matches("v1: unmarkFileAsViewed%(input: { pullRequestId: %$pr, path: %$p1 }%)", q)
    assert.are.same({ pr = "PR_1", p0 = "x/y.lua", p1 = "z.txt" }, v)
  end)
end)

describe("pr-viewer.gh.sync", function()
  local gh
  before_each(function()
    require("pr-viewer.config").setup({ sync = { debounce_ms = 30 } })
    gh = fake_gh()
  end)
  after_each(function()
    gh.restore()
  end)

  it("coalesces rapid toggles into one request with the final state", function()
    local s = new_session()
    sync.mark_viewed(s, "b.lua", true)
    sync.mark_viewed(s, "c.lua", true)
    sync.mark_viewed(s, "c.lua", false)
    sync.mark_viewed(s, "c.lua", true)
    sync.mark_viewed(s, "a.lua", false)
    assert.are.equal(0, #gh.calls)
    assert.is_true(sync.is_dirty(s))
    assert(vim.wait(500, function()
      return #gh.calls == 1
    end, 5))
    assert.are.same(
      { pr = "PR_x", p0 = "a.lua", p1 = "b.lua", p2 = "c.lua" },
      gh.calls[1].variables
    )
    assert.matches("v0: unmarkFileAsViewed", gh.calls[1].query)
    assert.matches("v1: markFileAsViewed", gh.calls[1].query)
    assert.matches("v2: markFileAsViewed", gh.calls[1].query)
    assert.is_false(sync.is_dirty(s))
  end)

  it("sends nothing when toggled back to the confirmed state", function()
    local s = new_session()
    sync.mark_viewed(s, "b.lua", true)
    sync.mark_viewed(s, "b.lua", false) -- サーバは UNVIEWED のまま
    vim.wait(120)
    assert.are.equal(0, #gh.calls)
  end)

  it("flush sends immediately", function()
    local s = new_session()
    sync.mark_viewed(s, "b.lua", true)
    sync.flush(s)
    assert.are.equal(1, #gh.calls)
  end)

  it("queues toggles made while a request is in flight", function()
    gh.auto = false
    local s = new_session()
    sync.mark_viewed(s, "b.lua", true)
    sync.flush(s)
    assert.are.equal(1, #gh.calls)
    sync.mark_viewed(s, "c.lua", true)
    sync.flush(s) -- in flight なので送らない
    assert.are.equal(1, #gh.calls)
    gh.calls[1].respond(false)
    assert(vim.wait(500, function()
      return #gh.calls == 2
    end, 5))
    assert.are.same({ pr = "PR_x", p0 = "c.lua" }, gh.calls[2].variables)
  end)

  it("rolls back to the confirmed state on failure", function()
    gh.fail = true
    local s = new_session()
    local rolled = {}
    sync.on_rollback(s, function(path, viewed)
      rolled[path] = viewed
    end)
    local notified
    local orig = vim.notify
    vim.notify = function(msg, level)
      notified = { msg = msg, level = level }
    end
    sync.mark_viewed(s, "b.lua", true)
    sync.mark_viewed(s, "a.lua", false)
    sync.flush(s)
    assert(vim.wait(500, function()
      return notified ~= nil
    end, 5))
    vim.notify = orig
    assert.are.same({ ["b.lua"] = false, ["a.lua"] = true }, rolled)
    assert.matches("failed to sync viewed", notified.msg)
    assert.are.equal(vim.log.levels.ERROR, notified.level)
    -- 失敗後に再トグルすれば、確定値との差分としてまた送られる
    gh.fail = false
    sync.mark_viewed(s, "b.lua", true)
    sync.flush(s)
    assert(vim.wait(500, function()
      return #gh.calls == 2
    end, 5))
    assert.are.same({ pr = "PR_x", p0 = "b.lua" }, gh.calls[2].variables)
  end)
end)
