-- The pure parts of the displays: readings computed from saved run records, and the summary card text.
local Env = require("env")

local function bootUI()
  local env = Env.new():boot()
  local ns = env.ns
  ns.AddSlash = function() end
  ns.AddOptions = function() end
  ns.Windows = { Register = function() return true end, Show = function() end }   -- the host is windows_spec's
  _G.CreateFrame = function() error("no frames in this test") end
  for _, f in ipairs({ "UI/Widgets.lua", "UI/Stints.lua" }) do
    assert(loadfile(Env.ROOT .. "/" .. f))("HardCounters", ns)
  end
  local HC = env.HC
  HC:RegisterPack("Test", { namespace = "t" })
  HC:RegisterCounter({ id = "t:gold", version = 1, measures = { "sum", "count" }, unit = "copper", formatter = "money",
    dimensions = { { name = "source", cap = 8 } }, aggregations = { {}, { "source" } }, runTracked = true, runBreakdowns = { "source" } })
  HC:RegisterCounter({ id = "t:items", version = 1, measures = { "sum" }, dimensions = { { name = "item", cap = 64 } },
    aggregations = { {}, { "item" } }, runTracked = true, runLive = { member = "item", cap = 50, max = true } })
  Env.trackAll(env, "t:all", { "t:gold", "t:items" })
  HC:RegisterReading("t:goldph", { title = "Gold/h", counter = "t:gold", per = "activeHour", scopes = { "run" }, formatter = "money",
    headline = true })
  HC:RegisterReading("t:best", { title = "Best", counter = "t:items", best = true, scopes = { "run" } })
  return env
end

describe("display helpers", function()
  it("computes the same readings from a saved record as from the open run", function()
    local env = bootUI()
    local HC, Wd = env.HC, env.ns.Widgets
    HC:StartRun("Test run")
    HC:Emit("t:gold", 3000, "loot")
    HC:Emit("t:items", 4, 2589)
    HC:Emit("t:items", 9, 4306)
    HC:SplitRun("B")
    HC:Emit("t:gold", 1000, "vendor")
    env:advance(1800)
    local liveGold = select(2, HC:RunReading("t:goldph"))
    local rec = HC:GetRunRecord(HC:StopRun())
    local v, text = Wd.RecordReading(env.ns.readings["t:goldph"], rec)
    assert.are.equal(8000, v)
    assert.are.equal("80s 0c/h", text)
    assert.are.equal(liveGold, text)
    assert.are.equal(9, (Wd.RecordReading(env.ns.readings["t:best"], rec)))
    assert.are.equal("t:goldph", Wd.HeadlineId())
  end)

  it("marks a run's rates unsettled for the first five active minutes, totals never", function()
    -- in game 2026-11-15: one 48c item after 99 s showed as 17s 37c/h on the big number
    local env = bootUI()
    local HC, ns = env.HC, env.ns
    HC:StartRun("Young")
    HC:Emit("t:gold", 69, "loot")
    HC:Emit("t:items", 1, 2589)
    env:advance(30)
    local v, text, settled = HC:RunReading("t:goldph")
    assert.is_nil(v)
    assert.are.equal("-", text)                       -- under a minute: no rate at all
    assert.is_false(settled)
    env:advance(70)
    v, text, settled = HC:RunReading("t:goldph")
    assert.truthy(v)
    assert.are.equal("/h", text:sub(-2))
    assert.is_false(settled)                          -- 100 s: shown, but grey
    assert.are.same({ 0.5, 0.5, 0.5 }, { ns.Widgets.ReadingColor(settled) })
    assert.is_true(select(3, HC:RunReading("t:best")))  -- not a rate: always settled
    env:advance(ns.RATE_SETTLE - 100)
    assert.is_true(select(3, HC:RunReading("t:goldph")))
    assert.are.same({ 1, 1, 1 }, { ns.Widgets.ReadingColor(true) })
  end)

  it("writes a summary card with readings, breakdowns, live tallies and splits", function()
    local env = bootUI()
    local HC = env.HC
    _G.GetItemInfo = function(id) return id == 2589 and "Linen Cloth" or nil end
    HC:StartRun("Card")
    HC:Emit("t:gold", 3000, "loot")
    HC:Emit("t:items", 4, 2589)
    HC:SplitRun("Second spot")
    env:advance(600)
    local rec = HC:GetRunRecord(HC:StopRun())
    local text = env.ns.RunSummaryText(rec)
    assert.truthy(text:find("Stint: Card", 1, true))                 -- (0.4.0: the player's word)
    assert.is_nil(text:find("Run", 1, true))
    assert.truthy(text:find("Gold/h", 1, true))
    assert.truthy(text:find("by source: loot 30s 0c", 1, true))
    assert.truthy(text:find("Linen Cloth x4", 1, true))
    assert.truthy(text:find("Second spot", 1, true))
  end)
end)
