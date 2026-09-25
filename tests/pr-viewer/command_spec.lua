local command = require("pr-viewer.command")

describe("pr-viewer.command", function()
  it("completes subcommand names", function()
    assert.are.same({ "health" }, command.complete("h", "PR h", 4))
    assert.are.same({ "health", "list", "open" }, command.complete("", "PR ", 3))
  end)

  it("does not complete after a subcommand", function()
    assert.are.same({}, command.complete("", "PR open ", 8))
  end)

  it("reports unknown subcommand", function()
    local msgs = {}
    local orig = vim.notify
    vim.notify = function(msg, level)
      msgs[#msgs + 1] = { msg = msg, level = level }
    end
    command.run({ fargs = { "nope" } })
    vim.notify = orig
    assert.matches("unknown subcommand", msgs[1].msg)
    assert.are.equal(vim.log.levels.ERROR, msgs[1].level)
  end)
end)
