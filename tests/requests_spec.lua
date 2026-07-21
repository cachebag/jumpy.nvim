-- Add lua/ to package.path so require works outside Neovim
package.path = package.path .. ";lua/?.lua;lua/?/init.lua"

local requests = require("jumpy.requests")

describe("requests registry", function()
  before_each(function()
    requests._reset()
  end)

  it("assigns unique ids and counts in-flight requests", function()
    local a = requests.begin()
    local b = requests.begin()

    assert.are_not.equal(a, b)
    assert.are.equal(2, requests.count())

    requests.finish(a)
    assert.are.equal(1, requests.count())

    requests.finish(b)
    assert.are.equal(0, requests.count())
  end)

  it("treats unknown or finished ids as cancelled", function()
    assert.is_true(requests.is_cancelled(999))

    local id = requests.begin()
    assert.is_false(requests.is_cancelled(id))

    requests.finish(id)
    assert.is_true(requests.is_cancelled(id))
  end)

  it("tracks busy targets per request", function()
    local id = requests.begin({ targets = { ["/tmp/a.lua"] = true, ["/tmp/b.lua"] = true } })

    assert.is_true(requests.is_target_busy("/tmp/a.lua"))
    assert.is_true(requests.is_target_busy("/tmp/b.lua"))
    assert.is_false(requests.is_target_busy("/tmp/c.lua"))

    requests.finish(id)
    assert.is_false(requests.is_target_busy("/tmp/a.lua"))
  end)

  it("allows parallel requests on different targets", function()
    requests.begin({ targets = { ["/tmp/a.lua"] = true } })
    requests.begin({ targets = { ["/tmp/b.lua"] = true } })

    assert.are.equal(2, requests.count())
    assert.is_true(requests.is_target_busy("/tmp/a.lua"))
    assert.is_true(requests.is_target_busy("/tmp/b.lua"))
  end)

  it("cancel_all marks every request cancelled and frees targets", function()
    local a = requests.begin({ targets = { ["/tmp/a.lua"] = true } })
    local b = requests.begin({ targets = { ["/tmp/b.lua"] = true } })

    assert.are.equal(2, requests.cancel_all())

    assert.is_true(requests.is_cancelled(a))
    assert.is_true(requests.is_cancelled(b))
    assert.are.equal(0, requests.count())
    assert.is_false(requests.is_target_busy("/tmp/a.lua"))

    assert.are.equal(0, requests.cancel_all())
  end)
end)
