-- Pure helpers: formatting, checksums, chat patterns, ring buffer.
local function loadPure(file, ns)
  ns = ns or {}
  assert(loadfile("HardCounters/Core/" .. file))("HardCounters", ns)
  return ns
end

describe("Util", function()
  local U = loadPure("Util.lua").U

  it("formats durations", function()
    assert.are.equal("0:00", U.duration(nil))
    assert.are.equal("1:05", U.duration(65))
    assert.are.equal("1:02:05", U.duration(3725))
    assert.are.equal("0:00", U.duration(-5))
  end)

  it("formats numbers and money", function()
    assert.are.equal("1,234,567", U.number(1234567))
    assert.are.equal("-1,000", U.number(-1000))
    assert.are.equal("12.50", U.number(12.5, 2))
    assert.are.equal("12g 34s 56c", U.money(123456))
    assert.are.equal("1,234g 0s 0c", U.money(12340000))
    assert.are.equal("5s 3c", U.money(503))
    assert.are.equal("7c", U.money(7))
    assert.are.equal("-1s 0c", U.money(-100))
  end)

  it("per hour needs at least a minute", function()
    assert.is_nil(U.perHour(100, 59))
    assert.are.equal(3600, U.perHour(60, 60))
  end)

  it("computes Adler-32 like zlib", function()
    assert.are.equal("11e60398", U.adler32("Wikipedia"))
    assert.are.equal("00000001", U.adler32(""))
  end)

  it("builds anchored chat patterns from client format strings", function()
    local p = U.patternFrom("You receive loot: %sx%d.")
    assert.are.equal("^You receive loot: (.-)x(%d+)%.$", p)
    local item, n = ("You receive loot: |cff9d9d9d|Hitem:2589::::::::1:::::::|h[Linen Cloth]|h|rx3."):match(p)
    assert.are.equal("3", n)
    assert.truthy(item:find("item:2589", 1, true))
    assert.are.equal("^Your (.-) reputation has increased by (%d+)%.$", U.patternFrom("Your %s reputation has increased by %d."))
    assert.are.equal("^(.-) dies, you gain (%d+) experience%.$", U.patternFrom("%1$s dies, you gain %2$d experience."))
    assert.is_nil(U.patternFrom(nil))
  end)

  it("validates namespaced ids", function()
    assert.is_true(U.validId("hcfarm:money.in"))
    assert.is_true(U.validId("hc:time.active"))
    assert.is_false(U.validId("noprefix"))
    assert.is_false(U.validId("a:b c"))
    assert.are.equal("hcfarm", U.namespace("hcfarm:loot.items"))
  end)

  it("deep copies plain data", function()
    local t = { a = { b = 1 } }
    local c = U.deepcopy(t)
    c.a.b = 2
    assert.are.equal(1, t.a.b)
  end)
end)

describe("Ring", function()
  local Ring = loadPure("Ring.lua").Ring

  it("keeps the newest items, oldest first", function()
    local r = Ring.new(3)
    for _, v in ipairs({ "a", "b", "c", "d", "e" }) do Ring.push(r, v) end
    assert.are.same({ "c", "d", "e" }, Ring.list(r))
    assert.are.same({ "d", "e" }, Ring.list(r, 2))
  end)

  it("adopts saved stores and repairs bad ones", function()
    local r = Ring.new(3)
    Ring.push(r, 1); Ring.push(r, 2)
    assert.are.equal(r, Ring.adopt(r, 3))
    local bigger = Ring.adopt(r, 5)
    assert.are.same({ 1, 2 }, Ring.list(bigger))
    local smaller = Ring.adopt({ cap = 5, head = 4, n = 4, items = { 1, 2, 3, 4 } }, 2)
    assert.are.same({ 3, 4 }, Ring.list(smaller))
    assert.are.same({}, Ring.list(Ring.adopt("junk", 4)))
  end)

  it("clears", function()
    local r = Ring.new(2)
    Ring.push(r, 1)
    Ring.clear(r)
    assert.are.same({}, Ring.list(r))
  end)
end)
