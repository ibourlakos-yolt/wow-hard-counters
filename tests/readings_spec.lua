-- Readings (HC-17, TRACKERS_AND_BOARDS §5): one API over run, login, storage and now scopes; computed readings.
local Env = require("env")

local function setup(env)
  local HC = env.HC
  HC:RegisterPack("Test", { namespace = "t" })
  HC:RegisterCounter({ id = "t:gold", version = 1, measures = { "sum", "count" },
    dimensions = { { name = "source", cap = 8 } }, aggregations = { {}, { "source" } }, runTracked = true })
  HC:RegisterCounter({ id = "t:spent", version = 1, measures = { "sum", "count" }, runTracked = true })
  HC:RegisterCounter({ id = "t:owned", version = 1, kind = "stock", measures = { "last", "min", "max" } })
  HC:RegisterCounter({ id = "t:lean", version = 1, measures = { "sum", "count" }, grains = { "lifetime" } })
  Env.trackAll(env, "t:all", { "t:gold", "t:spent", "t:owned", "t:lean" })
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

local function reload(env, opts)
  opts = opts or {}
  env:fire("PLAYER_LOGOUT")
  local sv = { HardCountersDB = Env.svCopy(env.sv.HardCountersDB) }
  local r = Env.new({ t = env.t + (opts.offline or 0), guid = env.guid, sv = sv, settings = env.settings })
  r.zone = env.zone
  r:load()
  setup(r)
  r:fire("ADDON_LOADED", "HardCounters")
  r.sv.HardCountersDB = _G.HardCountersDB
  r:fire("PLAYER_ENTERING_WORLD", opts.login and true or false, not opts.login)
  return r
end

local function readings(HC)
  HC:RegisterReading("t:goldph", { title = "Gold/h", counter = "t:gold", per = "activeHour", formatter = "money",
    scopes = { "run", "session", "today", "week", "lifetime" }, headline = true, order = 10,
    description = "Gold per active hour" })
  HC:RegisterReading("t:net", { title = "Net", counter = "t:gold", minus = "t:spent", formatter = "money",
    scopes = { "session", "today" }, order = 11 })
  HC:RegisterReading("t:owned", { title = "Owned", counter = "t:owned", scopes = { "now", "today" }, formatter = "money" })
  HC:RegisterReading("t:lean", { title = "Lean", counter = "t:lean", scopes = { "session", "today", "lifetime" } })
  -- a computed reading: hours to earn 1g at the current rate
  HC:RegisterReading("t:eta", { title = "To 1g", scopes = { "run", "session" }, formatter = "duration",
    inputs = { "t:goldph" },
    compute = function(get)
      local ph = get("t:goldph")
      if not ph or ph <= 0 then return nil end
      return 10000 / ph * 3600
    end })
end

describe("readings", function()
  it("validates definitions", function()
    local env = boot()
    local HC = env.HC
    assert.has_error(function() HC:RegisterReading("t:x", { title = "x" }) end)                       -- no counter
    assert.has_error(function() HC:RegisterReading("t:x", { counter = "t:gold", scopes = { "forever" } }) end)
    assert.has_error(function() HC:RegisterReading("t:x", { counter = "t:gold", per = "minute" }) end)
    assert.has_error(function() HC:RegisterReading("t:x", { counter = "t:gold", best = true, scopes = { "session" } }) end)
    assert.has_error(function() HC:RegisterReading("bad", { counter = "t:gold" }) end)
    assert.has_error(function() HC:RegisterReading("t:x", { counter = "t:gold", formatter = "miles" }) end)
  end)

  -- TR-10 (the Traveler decisions, 2026-11-22): distance in yards only; speed as yd/s or as a percentage of 7 yd/s
  it("formats distance and speed: yards, yd/s, and percent of the 100% run speed", function()
    local env = boot()
    local HC, ns = env.HC, env.ns
    HC:RegisterReading("t:dist", { title = "Distance", counter = "t:gold", formatter = "distance",
      scopes = { "session" } })
    HC:RegisterReading("t:speed", { title = "Speed", counter = "t:gold", formatter = "speed", scopes = { "session" } })
    HC:RegisterReading("t:speedpct", { title = "Speed %", counter = "t:gold", formatter = "speedpct", scopes = { "session" } })
    local r = ns.readings
    assert.are.equal("12,345 yd", ns.FormatReading(r["t:dist"], 12345.4))
    assert.are.equal("12,345 yd/h", ns.FormatReading(r["t:dist"], 12345.4, "perHour"))
    assert.are.equal("7.0 yd/s", ns.FormatReading(r["t:speed"], 7))
    assert.are.equal("100%", ns.FormatReading(r["t:speedpct"], 7))
    assert.are.equal("115%", ns.FormatReading(r["t:speedpct"], 8.05))     -- the paladin's Pursuit of Justice, rank 2
    assert.are.equal("-", ns.FormatReading(r["t:speedpct"], nil))
    -- the value read through the API carries the text
    env.HC:Emit("t:gold", 250, "loot")
    local v, text = HC:Reading("t:dist", "session")
    assert.are.equal(250, v)
    assert.are.equal("250 yd", text)
    -- live pass-through formats: yards and yd/s pass straight through; a percentage needs arithmetic, so none
    assert.are.equal("%.0f yd", ns.LiveFormat(r["t:dist"]))
    assert.are.equal("%.1f yd/s", ns.LiveFormat(r["t:speed"]))
    assert.is_nil(ns.LiveFormat(r["t:speedpct"]))
    -- counters and views use the same texts
    assert.are.equal("1,234 yd", ns.FormatValue("distance", 1234))
    assert.are.equal("-", ns.FormatValue("distance", nil))
  end)

  it("reads the login scope from memory, through a /reload, and starts over at a new login", function()
    local env = boot()
    readings(env.HC)
    env.HC:Emit("t:gold", 6000, "loot")
    env.HC:Emit("t:spent", 1000)
    env:advance(1800)
    local v, text, settled = env.HC:Reading("t:goldph", "session")
    assert.are.equal(12000, v)
    assert.are.equal("1g 20s 0c/h", text)
    assert.is_true(settled)
    assert.are.equal(5000, (env.HC:Reading("t:net", "session")))
    -- /reload: the login carries on
    local r = reload(env)
    readings(r.HC)
    r.HC:Emit("t:gold", 2000, "loot")
    assert.are.equal(7000, (r.HC:Reading("t:net", "session")))
    r:advance(600)
    assert.are.equal(8000 * 3600 / 2400, (r.HC:Reading("t:goldph", "session")))
    -- a new login starts at zero
    local l = reload(r, { login = true, offline = 3600 })
    readings(l.HC)
    assert.are.equal(0, (l.HC:Reading("t:net", "session")))
    local v2, _, settled2 = l.HC:Reading("t:goldph", "session")
    assert.is_nil(v2)
    assert.is_false(settled2)
  end)

  it("reads storage scopes from open buckets and says when history is missing", function()
    local env = boot()
    readings(env.HC)
    env.HC:Emit("t:gold", 3600, "loot")
    env.HC:Emit("t:lean", 5)
    env:advance(3600)
    assert.are.equal(3600, (env.HC:Reading("t:goldph", "today")))
    assert.are.equal(3600, (env.HC:Reading("t:goldph", "lifetime")))
    assert.are.equal(5, (env.HC:Reading("t:lean", "lifetime")))
    local v, text, _, state = env.HC:Reading("t:lean", "today")
    assert.is_nil(v)
    assert.are.equal("-", text)
    assert.are.equal("needs history", state)
    local _, _, _, s2 = env.HC:Reading("t:lean", "week")
    assert.are.equal("scope", s2)                  -- not offered at all
  end)

  it("reads a stock's current value with the now scope", function()
    local env = boot()
    readings(env.HC)
    assert.is_nil((env.HC:Reading("t:owned", "now")))
    env.HC:Observe("t:owned", 12345)
    assert.are.equal(12345, (env.HC:Reading("t:owned", "now")))
    assert.are.equal(12345, (env.HC:Reading("t:owned", "today")))
    local r = reload(env)
    readings(r.HC)
    assert.are.equal(12345, (r.HC:Reading("t:owned", "now")))
  end)

  it("serves the run scope and keeps RunReading working; RegisterRunReading is gone (HC-49)", function()
    local env = boot()
    local HC = env.HC
    readings(HC)
    assert.is_nil(HC.RegisterRunReading)
    HC:RegisterReading("t:old", { title = "Old", counter = "t:gold", per = "activeHour", scopes = { "run" }, formatter = "money" })
    assert.has_error(function() HC:RegisterReading("t:hour", { counter = "t:gold", per = "hour" }) end)
    assert.has_error(function() HC:RegisterReading("t:login", { counter = "t:gold", scopes = { "login" } }) end)   -- no alias
    local _, _, _, state = HC:Reading("t:goldph", "run")
    assert.are.equal("norun", state)
    assert.is_nil(HC:RunReading("t:goldph"))
    HC:StartRun("R")
    HC:Emit("t:gold", 5000, "loot")
    env:advance(3600)
    assert.are.equal(5000, (HC:Reading("t:goldph", "run")))
    assert.are.equal(5000, (HC:RunReading("t:old")))
    assert.are.equal("50s 0c/h", select(2, HC:RunReading("t:old")))
    assert.same({ "run" }, HC:GetReading("t:old").scopes)
    assert.are.equal("activeHour", HC:GetReading("t:old").per)
    -- the run list's readings: those with a run scope
    local ids = {}
    for _, r in ipairs(HC:RunReadings()) do ids[#ids + 1] = r.id end
    assert.same({ "t:goldph", "t:eta", "t:old" }, ids)
    assert.are.equal(4, #HC:Readings({ scope = "session" }))
  end)

  it("computes readings from other readings, per scope", function()
    local env = boot()
    local HC = env.HC
    readings(HC)
    assert.is_nil((HC:Reading("t:eta", "session")))
    HC:Emit("t:gold", 5000, "loot")
    env:advance(3600)
    local v, text = HC:Reading("t:eta", "session")
    assert.are.equal(7200, v)
    assert.are.equal("2:00:00", text)
    assert.is_true(HC:GetReading("t:eta").computed)
    -- a compute that errors gives no value, never an error
    HC:RegisterReading("t:boom", { title = "Boom", compute = function() error("bad") end })
    local _, _, _, state = HC:Reading("t:boom", "session")
    assert.are.equal("error", state)
  end)
end)
