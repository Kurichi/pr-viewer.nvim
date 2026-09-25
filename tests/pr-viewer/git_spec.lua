local git = require("pr-viewer.git")
local H = require("tests.pr-viewer.helpers")

local function sync(fn)
  local res
  fn(function(...)
    res = { ... }
  end)
  H.wait(function()
    return res ~= nil
  end)
  return unpack(res)
end

describe("pr-viewer.git.parse_remote", function()
  it("parses ssh, ssh://, and https forms", function()
    for _, url in ipairs({
      "git@github.com:Kurichi/pr-viewer.nvim.git",
      "ssh://git@github.com/Kurichi/pr-viewer.nvim.git",
      "ssh://git@github.com:22/Kurichi/pr-viewer.nvim",
      "https://github.com/Kurichi/pr-viewer.nvim",
      "https://github.com/Kurichi/pr-viewer.nvim.git/",
    }) do
      local r = git.parse_remote(url)
      assert.is_not_nil(r, url)
      assert.are.equal("github.com", r.host, url)
      assert.are.equal("Kurichi", r.owner, url)
      assert.are.equal("pr-viewer.nvim", r.repo, url)
    end
  end)

  it("returns nil for unknown forms", function()
    assert.is_nil(git.parse_remote("/local/path"))
  end)
end)

describe("pr-viewer.git (temp repo)", function()
  local repo
  before_each(function()
    repo = H.make_repo()
  end)

  it("has_commit / merge_base / rev_parse", function()
    assert.is_true(sync(function(cb)
      git.has_commit(repo.dir, repo.base, cb)
    end))
    assert.is_false(sync(function(cb)
      git.has_commit(repo.dir, string.rep("0", 40), cb)
    end))
    local err, mb = sync(function(cb)
      git.merge_base(repo.dir, repo.base, repo.head, cb)
    end)
    assert.is_nil(err)
    assert.are.equal(repo.base, mb)
    local _, head = sync(function(cb)
      git.rev_parse(repo.dir, "HEAD", cb)
    end)
    assert.are.equal(repo.head, head)
  end)

  it("show returns lines, and empty for a path missing at that rev", function()
    local err, lines = sync(function(cb)
      git.show(repo.dir, repo.base, "a.lua", cb)
    end)
    assert.is_nil(err)
    assert.are.same({ "local a = 1", "return a" }, lines)
    local err2, lines2 = sync(function(cb)
      git.show(repo.dir, repo.base, "c.lua", cb)
    end)
    assert.is_nil(err2)
    assert.are.same({}, lines2)
  end)
end)
