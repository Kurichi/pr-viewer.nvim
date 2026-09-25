local transport = require("pr-viewer.gh.transport")

--- vim.system を差し替えて、gh の出力を偽装する
---@param out table {code, stdout, stderr}
---@return table captured 呼び出し時の cmd / opts
local function fake_system(out)
  local captured = {}
  transport._system = function(cmd, opts, on_exit)
    captured.cmd, captured.opts = cmd, opts
    on_exit({
      code = out.code or 0,
      stdout = out.stdout or "",
      stderr = out.stderr or "",
      signal = 0,
    })
  end
  return captured
end

--- 非同期コールバックの完了を待つ
local function wait_for(fn)
  local result
  fn(function(err, data)
    result = { err = err, data = data }
  end)
  assert(
    vim.wait(1000, function()
      return result ~= nil
    end),
    "callback was not called"
  )
  return result
end

describe("pr-viewer.gh.transport", function()
  before_each(function()
    require("pr-viewer.config").setup({})
  end)

  it("graphql passes query and variables via stdin and returns data", function()
    local captured = fake_system({ stdout = '{"data":{"viewer":{"login":"kurichi"}}}' })
    local res = wait_for(function(cb)
      transport.graphql("query { viewer { login } }", { a = 1 }, cb)
    end)
    assert.is_nil(res.err)
    assert.are.same({ viewer = { login = "kurichi" } }, res.data)
    assert.are.same({ "gh", "api", "graphql", "--input", "-" }, captured.cmd)
    local body = vim.json.decode(captured.opts.stdin)
    assert.are.equal("query { viewer { login } }", body.query)
    assert.are.same({ a = 1 }, body.variables)
  end)

  it("graphql surfaces errors array as err", function()
    fake_system({ stdout = '{"data":null,"errors":[{"message":"Could not resolve"}]}' })
    local res = wait_for(function(cb)
      transport.graphql("query { x }", nil, cb)
    end)
    assert.matches("Could not resolve", res.err)
  end)

  it("non-zero exit returns stderr with auth hint", function()
    fake_system({ code = 1, stderr = "To get started with GitHub CLI, please run:  gh auth login" })
    local res = wait_for(function(cb)
      transport.graphql("query { x }", nil, cb)
    end)
    assert.matches("gh auth login", res.err)
    assert.matches("hint", res.err)
  end)

  it("rest sends method and JSON body", function()
    local captured = fake_system({ stdout = "{}" })
    wait_for(function(cb)
      transport.rest("PUT", "repos/o/r/pulls/1/x", { viewed = true }, cb)
    end)
    assert.are.same(
      { "gh", "api", "-X", "PUT", "repos/o/r/pulls/1/x", "--input", "-" },
      captured.cmd
    )
    assert.are.same({ viewed = true }, vim.json.decode(captured.opts.stdin))
  end)
end)
