-- Money and XP attribution: every ordering of the truth (state diff) and its signals.
local function load()
  local ns = {}
  assert(loadfile("HardCounters_Farmer/Attribution.lua"))("HardCounters_Farmer", ns)
  return ns
end

describe("money attribution", function()
  local ns = load()
  local got
  local function new()
    got = {}
    return ns.NewMoneyAttributor(function(dir, amount, source) got[#got + 1] = dir .. ":" .. source .. ":" .. amount end)
  end

  it("loot: chat before the money change", function()
    local a = new()
    a:LootMessage(500, 10)
    a:Delta(500, 10.2)
    assert.are.same({ "in:loot:500" }, got)
  end)

  it("loot: money change before the chat (held, then claimed)", function()
    local a = new()
    a:Delta(500, 10)
    assert.are.same({}, got)
    a:LootMessage(500, 10.3)
    assert.are.same({ "in:loot:500" }, got)
  end)

  it("an unexplained gain becomes 'other' after the window", function()
    local a = new()
    a:Delta(700, 10)
    assert.is_true(a:Expire(11))
    assert.is_false(a:Expire(12.5))
    assert.are.same({ "in:other:700" }, got)
  end)

  it("counts loot messages that no money change claimed", function()
    local a = new()
    a:LootMessage(300, 10)
    a:Expire(13)
    assert.are.equal(300, a.unmatchedLoot)
  end)

  it("splits a gain between loot and what else is open", function()
    local a = new()
    a:SetOpen("merchant", true)
    a:LootMessage(100, 10)
    a:Delta(350, 10.1)
    assert.are.same({ "in:loot:100", "in:vendor:250" }, got)
  end)

  it("names spending from open windows and marks", function()
    local a = new()
    a:Mark("repair", 20)
    a:Delta(-1000, 20.5)
    a:SetOpen("merchant", true)
    a:Delta(-50, 30)
    a:SetOpen("merchant", false)
    a:SetOpen("trainer", true)
    a:Delta(-900, 40)
    a:SetOpen("trainer", false)
    a:SetOpen("taxi", true)
    a:Delta(-120, 50)
    a:SetOpen("taxi", false)
    a:Delta(-5, 60)
    assert.are.same({ "out:repair:1000", "out:vendor:50", "out:training:900", "out:travel:120", "out:other:5" }, got)
  end)

  it("quest rewards and auction-house mail", function()
    local a = new()
    a:Mark("quest", 5)
    a:Delta(2000, 5.5)
    a:Mark("mailTake", 9, "ah")
    a:Delta(80000, 9.5)
    a:SetOpen("mail", true)
    a:Delta(100, 30)
    assert.are.same({ "in:quest:2000", "in:ah:80000", "in:mail:100" }, got)
  end)

  it("money mailed between your own characters: spent by the sender, earned by the receiver", function()
    -- user's decision 2026-11-15 (DESIGN §4.1): both sides count, no filtering by sender
    local sender = new()
    sender:SetOpen("mail", true)
    sender:Delta(-5030, 10)                            -- 50s sent plus 30c postage: one money change
    assert.are.same({ "out:mail:5030" }, got)
    local receiver = new()
    receiver:SetOpen("mail", true)
    receiver:Mark("mailTake", 20, "mail")
    receiver:Delta(5000, 20.2)
    assert.are.same({ "in:mail:5000" }, got)
  end)

  it("FM-16: money between your own characters has its own source and sink; postage stays mail", function()
    local sender = new()
    sender:SetOpen("mail", true)
    sender:Mark("mailSend", 10, 5000)                  -- 50s to one of your own characters
    sender:Delta(-5030, 10.3)
    assert.are.same({ "out:alts:5000", "out:mail:30" }, got)
    sender:Mark("mailSend", 20, 0)                     -- to anyone else: all of it is mail, as before
    sender:Delta(-1030, 20.1)
    assert.are.same({ "out:alts:5000", "out:mail:30", "out:mail:1030" }, got)
    sender:Delta(-30, 40)                              -- long after: an open mailbox still says mail
    assert.are.same("out:mail:30", got[4])
    local receiver = new()
    receiver:SetOpen("mail", true)
    receiver:Mark("mailTake", 50, "alts")
    receiver:Delta(5000, 50.2)
    assert.are.same({ "in:alts:5000" }, got)
  end)
end)

describe("XP attribution", function()
  local ns = load()
  local got
  local function new()
    got = {}
    return ns.NewXPAttributor(function(amount, source) got[#got + 1] = source .. ":" .. amount end)
  end

  it("kill line before or after the XP change", function()
    local a = new()
    a:Hint("kill", 1)
    a:Delta(150, 1.1)
    a:Delta(150, 5)
    a:Hint("kill", 5.2)
    assert.are.same({ "kill:150", "kill:150" }, got)
  end)

  it("quest beats kill; unexplained XP is 'other' after the window", function()
    local a = new()
    a:Hint("kill", 1)
    a:Hint("quest", 1)
    a:Delta(900, 1.5)
    a:Delta(40, 10)
    a:Expire(13)
    assert.are.same({ "quest:900", "other:40" }, got)
  end)

  it("computes XP across one level-up, even when UnitLevel lags", function()
    assert.are.equal(50, ns.XPDelta(100, 1000, 10, 150, 10))
    assert.are.equal(150, ns.XPDelta(950, 1000, 10, 100, 11))
    assert.are.equal(150, ns.XPDelta(950, 1000, 10, 100, 10))   -- level not updated yet
    assert.are.equal(0, ns.XPDelta(950, 1000, 10, 100, 13))     -- several levels: don't guess
    assert.are.equal(0, ns.XPDelta(nil, 1000, 10, 100, 10))
  end)
end)
