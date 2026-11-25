-- The odometer and the mix (HC-63, decided 2026-11-22 for the Traveler pack): rolling digit wheels for a total, and
-- one bar split into a part per member of a small enum dimension.
local Env = require("env")
local UI = require("ui_boot")

local MODES = { "walk", "run", "mounted", "swim", "taxi", "hearth", "ghost", "blink" }

local function boot()
  local env = Env.new()
  env:load()
  local HC = env.HC
  HC:RegisterPack("Test", { namespace = "t" })
  HC:RegisterCounter({ id = "t:dist", version = 1, measures = { "sum", "count" },
    dimensions = { { name = "mode", cap = 32 } }, aggregations = { {}, { "mode" } } })
  HC:RegisterCounter({ id = "t:items", version = 1, measures = { "sum", "count" },
    dimensions = { { name = "item", cap = 4096 } }, aggregations = { {}, { "item" } } })
  Env.trackAll(env, "t:all", { "t:dist", "t:items", "hc:time.active" }, "off")
  HC:RegisterReading("t:travelled", { title = "Distance", tracker = "t:all", counter = "t:dist", formatter = "distance",
    scopes = { "session" }, param = { dim = "mode", multi = true, members = MODES,
      presets = { { name = "No teleports", members = { "walk", "run", "mounted", "swim", "taxi", "ghost", "blink" } } },
      default = "No teleports" } })
  HC:RegisterReading("t:bymode", { title = "%s distance", tracker = "t:all", counter = "t:dist", scopes = { "session" },
    param = { dim = "mode" } })
  HC:RegisterReading("t:total", { title = "All", tracker = "t:all", counter = "t:dist", scopes = { "session" } })
  HC:RegisterReading("t:looted", { title = "%s looted", tracker = "t:all", counter = "t:items", scopes = { "session" },
    param = { dim = "item", type = "item" } })
  HC:RegisterReading("t:gold", { title = "Gold", tracker = "t:all", counter = "t:dist", formatter = "money", scopes = { "session" } })
  env:fire("ADDON_LOADED", "HardCounters")
  env.sv.HardCountersDB = _G.HardCountersDB
  env:fire("PLAYER_ENTERING_WORLD", true, false)
  local ns = env.ns
  ns.AddSlash = function() end
  ns.AddOptions = function() end
  for _, f in ipairs({ "UI/Widgets.lua", "UI/BoardModel.lua" }) do
    assert(loadfile(Env.ROOT .. "/" .. f))("HardCounters", ns)
  end
  env.M = ns.BoardModel
  return env
end

describe("the odometer", function()
  it("turns a total into wheels: zero-padded, at most nine, never negative", function()
    local M = boot().M
    assert.are.equal("000042", M.OdometerDigits(42.9))
    assert.are.equal("1234567", M.OdometerDigits(1234567))
    assert.are.equal("999999999", M.OdometerDigits(999999999))
    assert.is_nil(M.OdometerDigits(1000000000))            -- ten digits: the text instead
    assert.is_nil(M.OdometerDigits(-1))
    assert.is_nil(M.OdometerDigits(nil))
  end)

  it("is offered for counts and distances, the total only; a mix for readings with a small enum parameter", function()
    local env = boot()
    local M = env.M
    local b = M.Create(nil, { name = "Trip", shown = true })
    local d = M.AddReading(b, "t:travelled")
    local all = M.AddReading(b, "t:total")
    local gold = M.AddReading(b, "t:gold")
    local loot = M.AddReading(b, "t:looted", nil, nil, 2589)
    assert.is_true(M.DisplayFits(d, "odometer"))
    assert.is_true(M.DisplayFits(all, "odometer"))
    assert.is_false(M.DisplayFits(gold, "odometer"))       -- money has its own units
    assert.is_true(M.DisplayFits(d, "mix"))
    assert.is_false(M.DisplayFits(all, "mix"))             -- no parameter: nothing to split by
    assert.is_false(M.DisplayFits(loot, "mix"))            -- a big dimension: too many members
    assert.is_false(M.SetDisplay(gold, "odometer"))
    assert.is_true(M.SetDisplay(d, "odometer"))
    assert.are.equal("odometer", M.Footprint(d))
    assert.are.equal("yd", M.OdometerUnit(d))
    assert.is_nil(M.OdometerUnit(all))
    -- the total only: a per hour tile moves to the total
    all.calc = "perHour"
    M.SetDisplay(all, "odometer")
    assert.is_nil(all.calc)
    local _, h = M.Layout(b)
    assert.is_true(h > M.HEIGHT.odometer)
  end)
end)

describe("the mix", function()
  it("splits the tile's set into parts, largest first, then other; a one-member reading splits by what it counted", function()
    local env = boot()
    local M, HC = env.M, env.HC
    local b = M.Create(nil, { name = "Trip", shown = true })
    local d = M.AddReading(b, "t:travelled", { display = "mix" })
    d.scope = "session"
    assert.is_nil(M.MixParts(d, b))                        -- nothing counted yet
    local amounts = { walk = 100, run = 700, mounted = 1400, swim = 50, taxi = 2000, ghost = 30, blink = 20, hearth = 3000 }
    for m, v in pairs(amounts) do HC:Emit("t:dist", v, m) end
    local parts, total = M.MixParts(d, b)
    assert.are.equal(4300, total)                          -- the default set: no hearth
    assert.are.equal(6, #parts)                            -- five parts and "other"
    assert.are.equal("taxi", parts[1].arg)
    assert.are.equal(2000 / 4300, parts[1].frac)
    assert.are.equal("mounted", parts[2].arg)
    assert.is_false(parts[6].arg)                          -- ghost 30 + blink 20
    assert.are.equal(50, parts[6].v)
    -- the tile's own set
    M.SetArg(d, { "walk", "run" }, b)
    parts, total = M.MixParts(d, b)
    assert.are.equal(800, total)
    assert.are.equal(2, #parts)
    assert.are.equal("run", parts[1].arg)
    assert.are.same({ "run", "walk" }, d.arg)              -- the tile's set is put back
    -- a one-member reading: every member counted so far
    local one = M.AddReading(b, "t:bymode", { display = "mix" }, nil, "walk")
    one.scope = "session"
    parts, total = M.MixParts(one, b)
    assert.are.equal(7300, total)
    assert.are.equal("hearth", parts[1].arg)
    assert.are.equal("walk", one.arg)
  end)
end)

describe("drawing the odometer and the mix", function()
  it("sets the wheels, rolls a digit that changes, and writes the mix's shares", function()
    UI.with(function(ctx)
      local HC, ns, env = ctx.HC, ctx.hc, ctx.env
      local M, B = ns.BoardModel, ns.Boards
      local value = 1234
      HC:RegisterReading("hc:testodo", { title = "Distance", scopes = { "session" }, formatter = "distance",
        compute = function() return value end })
      local shares = { walk = 30, run = 60, swim = 10 }
      HC:RegisterReading("hc:testmix", { title = "By mode", scopes = { "session" }, compute = function(_, _, arg)
        if not arg then return 100 end
        local s = 0
        for _, m in ipairs(arg) do s = s + (shares[m] or 0) end
        return s
      end, param = { dim = "mode", multi = true, members = { "walk", "run", "swim" } } })
      local b = M.Create(nil, { name = "Trip", shown = true })
      local odo = M.AddReading(b, "hc:testodo", { display = "odometer" })
      odo.scope = "session"
      local mix = M.AddReading(b, "hc:testmix", { display = "mix" })
      mix.scope = "session"
      B.Refresh(b.id, true)
      local f = B.Frame(b.id)
      local w = f.rowFrames[1]
      assert.are.equal("odometer", w.row.kind)
      local function wheels()
        local s = ""
        for _, wh in ipairs(w.wheels) do if wh:IsShown() then s = s .. tostring(wh.digit) end end
        return s
      end
      assert.are.equal("001234", wheels())
      assert.are.equal("4", w.wheels[6].cur:GetText())
      assert.are.equal("yd", w.unit:GetText())
      assert.are.equal("", w.value:GetText())
      -- a change rolls: the new digit comes in, then takes the wheel's place
      value = 1235
      B.Refresh(b.id)
      assert.are.equal("001235", wheels())
      assert.is_true(w.wheels[6].nxt:IsShown())
      assert.are.equal("5", w.wheels[6].nxt:GetText())
      local step = w:GetScript("OnUpdate")
      assert.truthy(step)
      env.t = env.t + 0.1; step(w)
      assert.is_true(w.wheels[6].nxt:IsShown())
      env.t = env.t + 0.5; step(w)
      assert.are.equal("5", w.wheels[6].cur:GetText())
      assert.is_false(w.wheels[6].nxt:IsShown())
      assert.is_nil(w:GetScript("OnUpdate"))
      -- too many digits for the wheels: the text
      value = 12345678901
      B.Refresh(b.id)
      assert.are.equal("", wheels())
      assert.are.equal("12,345,678,901 yd", w.value:GetText())
      -- the mix: its shares, largest first
      local mw = f.rowFrames[2]
      assert.are.equal("mix", mw.row.kind)
      local legend = mw.legend:GetText():gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
      assert.are.equal("run 60%  walk 30%  swim 10%", legend)
      -- the Display menu offers only what fits
      local items
      local realShow = ns.Menu.Show
      ns.Menu.Show = function(_, it) items = it end
      B.TileMenu(w, b, 1)
      ns.Menu.Show = realShow
      local names = {}
      for _, it in ipairs(items) do
        if it.text == "Display" then for _, s in ipairs(it.sub) do names[#names + 1] = s.text end end
      end
      assert.are.same({ "Number", "Bar", "Gauge", "Odometer" }, names)
      assert.are.same({}, ctx.env.errors)
    end)
  end)
end)
