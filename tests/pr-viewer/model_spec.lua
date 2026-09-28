local model = require("pr-viewer.model.pr")
local position = require("pr-viewer.model.position")
local H = require("tests.pr-viewer.helpers")

describe("pr-viewer.model.pr", function()
  local data = H.pr_data({ base = "b", head = "h" })

  it("converts a GraphQL response", function()
    local pr = model.from_graphql(data)
    assert.are.equal(7, pr.number)
    assert.are.equal("alice", pr.author)
    assert.are.equal("b", pr.base_oid)
    assert.are.equal(3, #pr.files)
    assert.are.equal("DELETED", pr.files[2].change_type)
    assert.are.equal(3, #pr.threads)
    assert.is_nil(pr.files_cursor)
    assert.is_nil(pr.threads_cursor)
    assert.are.equal("why b?\nsecond line", pr.threads[1].comments[1].body)
    assert.is_true(pr.threads[2].resolved)
  end)

  it("keeps the cursor only when there is a next page", function()
    local paged = H.pr_data({ base = "b", head = "h" }, {
      repository = {
        pullRequest = { files = { pageInfo = { hasNextPage = true, endCursor = "abc" } } },
      },
    })
    local pr = model.from_graphql(paged)
    assert.are.equal("abc", pr.files_cursor)
    model.merge_page(
      pr,
      { files = { pageInfo = { hasNextPage = false }, nodes = { { path = "d.lua" } } } }
    )
    assert.is_nil(pr.files_cursor)
    assert.are.equal(4, #pr.files)
    assert.are.equal("UNVIEWED", pr.files[4].viewed)
  end)

  it("indexes threads by path and computes stats", function()
    local pr = model.from_graphql(data)
    local by_path = model.threads_by_path(pr)
    assert.are.equal(2, #by_path["a.lua"])
    assert.are.equal(1, #by_path["c.lua"])
    local s = model.stats(pr)
    assert.are.same({ files = 3, viewed = 1, threads = 3, unresolved = 2, drafts = 0 }, s)
  end)

  it("errors on missing pull request", function()
    assert.has_error(function()
      model.from_graphql({ repository = { pullRequest = vim.NIL } })
    end)
  end)
end)

describe("pr-viewer.model.position", function()
  it("anchors only non-outdated threads", function()
    local pr = model.from_graphql(H.pr_data({ base = "b", head = "h" }))
    assert.are.same({ side = "RIGHT", line = 2, start_line = 2 }, position.anchor(pr.threads[1]))
    assert.is_nil(position.anchor(pr.threads[3]))
  end)

  it("finds threads covering a line on a side", function()
    local threads = {
      { id = "x", side = "RIGHT", line = 10, start_line = 8, outdated = false, comments = {} },
      { id = "y", side = "LEFT", line = 9, outdated = false, comments = {} },
    }
    assert.are.equal("x", position.threads_at(threads, "RIGHT", 9)[1].id)
    assert.are.equal(0, #position.threads_at(threads, "RIGHT", 11))
    assert.are.equal("y", position.threads_at(threads, "LEFT", 9)[1].id)
  end)
end)
