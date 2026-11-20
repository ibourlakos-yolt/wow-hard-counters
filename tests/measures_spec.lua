-- Min, max and avg as reading measures (HC-27): a stock's lowest and highest level over our windows (session, the
-- open run, a board's timer) and over storage periods; a flow's average write.
local Env = require("env")

local function setup(env)
  local HC = env.HC
  HC:RegisterPack("Test", { namespace = "t" })
  HC:RegisterCounter({ id = "t:owned", version = 1, kind = "stock", measures = { "last", "min", "max" } })
  HC:RegisterCounter({ id = "t:gold", version = 1, measures = { "sum", "count" } })
  Env.trackAll(env, "t:all", { "t:owned", "t:gold" })
  HC:RegisterReading("t:low", { title = "Lowest", counter = "t:owned", measure = "min",
    scopes = { "run", "session", "today", "lifetime" } })
  HC:RegisterReading("t:high", { title = "Highest", counter = "t:owned", measure = "max",
    scopes = { "run", "session", "today", "lifetime" } })
  HC:RegisterReading("t:avg", { title = "Average", counter = "t:gold", measure = "avg", scopes = { "run", "session", "today" } })
end

local function boot(opts)
  local env = Env.new(opts)
  env:load()
  setup(env)
  env:fire("ADDON_LOADED", "HardCounters")
  env.sv.HardCountersDB = _G.HardCountersDB
  env:fire("PLAYER_ENTERING_WORLD", true, false)
  return env
end

local function reload(env)
  env:fire("PLAYER_LOGOUT")
  local sv = { HardCountersDB = Env.svCopy(env.sv.HardCountersDB) }
  local r = Env.new({ t = env.t, guid = env.guid, sv = sv, settings = env.settings })
  r:load()
  setup(r)
  r:fire("ADDON_LOADED", "HardCounters")
  r.sv.HardCountersDB = _G.HardCountersDB
  r:fire("PLAYER_ENTERING_WORLD", false, true)
  return r
end

local function val(HC, id, scope) return (HC:Reading(id, scope)) end

describe("min, max and avg (HC-27)", function()
  it("validates the measure", function()
    local env = boot()
    assert.has_error(function() env.HC:RegisterReading("t:bad", { counter = "t:owned", measure = "median" }) end)
  end)

  it("a stock's lowest and highest level this session, through a /reload", function()
    local env = boot()
    local HC = env.HC
    assert.is_nil(val(HC, "t:low", "session"))              -- never observed: unknown, not 0
    HC:Observe("t:owned", 500)
    HC:Observe("t:owned", 200)
    HC:Observe("t:owned", 900)
    HC:Observe("t:owned", 600)
    assert.are.equal(200, val(HC, "t:low", "session"))
    assert.are.equal(900, val(HC, "t:high", "session"))
    local r = reload(env)
    assert.are.equal(200, val(r.HC, "t:low", "session"))
    assert.are.equal(900, val(r.HC, "t:high", "session"))
    r.HC:Observe("t:owned", 100)
    assert.are.equal(100, val(r.HC, "t:low", "session"))
    -- storage periods: the library's own min and max
    assert.are.equal(100, val(r.HC, "t:low", "today"))
    assert.are.equal(900, val(r.HC, "t:high", "lifetime"))
  end)

  it("a window that starts counts the level it starts at; pauses keep what was seen", function()
    local env = boot()
    local HC = env.HC
    HC:Observe("t:owned", 700)
    HC:StartRun("Farm")
    assert.are.equal(700, val(HC, "t:low", "run"))        -- the level when the run began held during it
    HC:Observe("t:owned", 750)
    assert.are.equal(750, val(HC, "t:high", "run"))
    HC:PauseRun()
    HC:Observe("t:owned", 10)                             -- while paused: not the run's
    assert.are.equal(700, val(HC, "t:low", "run"))
    HC:ResumeRun()                                        -- it resumes at 10: that level is in the run now
    assert.are.equal(10, val(HC, "t:low", "run"))
    local id = HC:StopRun()
    local rec = HC:GetRunRecord(id)
    assert.are.equal(10, rec.deltas["t:owned"].lo)
    assert.are.equal(750, rec.deltas["t:owned"].hi)
  end)

  it("a flow's average write over our windows and storage", function()
    local env = boot()
    local HC = env.HC
    assert.is_nil(val(HC, "t:avg", "session"))              -- no write: no average
    HC:Emit("t:gold", 100)
    HC:Emit("t:gold", 300)
    assert.are.equal(200, val(HC, "t:avg", "session"))
    assert.are.equal(200, val(HC, "t:avg", "today"))
  end)

  it("ObserveCtx keeps a context with a stock's record (HC-26); same guards as Observe", function()
    local env = Env.new()
    env:load()
    local HC = env.HC
    HC:RegisterPack("Test", { namespace = "t" })
    HC:RegisterCounter({ id = "t:ap", version = 1, kind = "stock", measures = { "last", "max" },
      dimensions = { { name = "zone", cap = 40 } }, aggregations = { {}, { "zone" } }, context = { max = { "zone", "buffs" } } })
    Env.trackAll(env, "t:all", { "t:ap" })
    env:fire("ADDON_LOADED", "HardCounters")
    env.sv.HardCountersDB = _G.HardCountersDB
    env:fire("PLAYER_ENTERING_WORLD", true, false)
    local ctx = { buffs = 0 }
    ctx.buffs = 2
    assert.is_true(HC:ObserveCtx("t:ap", 900, ctx, 1429))
    ctx.buffs = 6
    assert.is_true(HC:ObserveCtx("t:ap", 1500, ctx, 1583))
    ctx.buffs = 1
    assert.is_true(HC:ObserveCtx("t:ap", 1200, ctx, 1429))
    local rows = HC:Query({ counter = "t:ap", measure = "max", grain = "lifetime", groupBy = "zone" })
    local row
    for _, r in ipairs(rows) do if r.member == 1583 then row = r end end
    assert.are.equal(1500, row and row.value)
    assert.truthy(row and row.ctx)
    assert.are.equal("6", tostring(row.ctx.buffs))           -- (context comes back as stored: text)
    assert.are.equal("1583", tostring(row.ctx.zone))
    assert.are.equal(1200, env.ns.odo["t:ap"].l)          -- the odometer keeps the last level, as Observe does
    assert.is_false(HC:ObserveCtx("t:ap", env:secretValue(), ctx, 1429))
    assert.is_false(HC:ObserveCtx("t:none", 1, ctx))
  end)

  it("a board's timer keeps them; the account's has no single level, so no min or max", function()
    local env = boot()
    local ns = env.ns
    ns.AddSlash = function() end
    ns.AddOptions = function() end
    for _, f in ipairs({ "UI/Widgets.lua", "UI/BoardModel.lua" }) do
      assert(loadfile(Env.ROOT .. "/" .. f))("HardCounters", ns)
    end
    local M, HC = ns.BoardModel, env.HC
    HC:Observe("t:owned", 400)
    local b = M.Create(nil, { name = "B" })
    local low = M.AddReading(b, "t:low", "row")
    local high = M.AddReading(b, "t:high", "row")
    assert.are.equal("run", low.scope)                    -- the board's timer
    assert.are.equal(400, (M.TileValue(low, b)))
    HC:Observe("t:owned", 300)
    HC:Observe("t:owned", 450)
    assert.are.equal(300, (M.TileValue(low, b)))
    assert.are.equal(450, (M.TileValue(high, b)))
    M.SetWho(high, "account", b)
    assert.is_nil((M.TileValue(high, b)))
  end)
end)
