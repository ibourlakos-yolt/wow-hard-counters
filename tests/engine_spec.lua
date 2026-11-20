-- Engine: packs, counters, emit, sources, hc:time.active, phases, views.
local Env = require("env")

local function bootWithPack(opts)
  local env = Env.new(opts)
  env:load()
  local HC = env.HC
  env.pack = HC:RegisterPack("Test", { namespace = "t", version = "1.2.3" })
  HC:RegisterCounter({ id = "t:gold", version = 1, measures = { "sum", "count", "max" },
    dimensions = { { name = "source", cap = 8 }, { name = "zone", cap = 64 } },
    aggregations = { {}, { "source" }, { "zone" } }, context = { max = { "zone" } }, runTracked = true, runBreakdowns = { "source" } })
  Env.trackAll(env, "t:all", { "t:gold" })
  env:fire("ADDON_LOADED", "HardCounters")
  env.sv.HardCountersDB = _G.HardCountersDB
  env:fire("PLAYER_ENTERING_WORLD", true, false)
  return env
end

local function total(env, id, grain, measure, extra)
  local q = { counter = id, grain = grain or "lifetime", measure = measure }
  for k, v in pairs(extra or {}) do q[k] = v end
  local rows = assert(env.ns.db:Query(q))
  return rows.total
end

describe("registry", function()
  it("requires a pack for the namespace, reserves 'hc' and refuses taken namespaces", function()
    local env = Env.new():boot()
    local HC = env.HC
    assert.has_error(function() HC:RegisterCounter({ id = "nope:x", version = 1 }) end)
    assert.has_error(function() HC:RegisterPack("Bad", { namespace = "hc" }) end)
    HC:RegisterPack("A", { namespace = "aa" })
    assert.has_error(function() HC:RegisterPack("B", { namespace = "aa" }) end)
    assert.has_error(function() HC:RegisterCounter({ id = "aa:x", version = 1, accuracy = "guess" }) end)
  end)

  it("saves a pack's health counters under its namespace (readable after the session)", function()
    local env = bootWithPack()
    env.pack:Count("lootMoneyUnmatched", 25)
    env.pack:Count("lootMoneyUnmatched")
    assert.are.equal(26, env.pack.health.lootMoneyUnmatched)
    assert.are.equal(26, env.ns.health.saved["t:lootMoneyUnmatched"])
    assert.are.equal(26, _G.HardCountersDB.health.c["t:lootMoneyUnmatched"])
  end)

  it("attaches counters registered before storage, and emits", function()
    local env = bootWithPack()
    local HC = env.HC
    assert.is_true(HC:Emit("t:gold", 150, "loot", 1429))
    assert.is_true(HC:Emit("t:gold", 50, "quest", 1429))
    assert.are.equal(200, total(env, "t:gold"))
    assert.are.equal(2, total(env, "t:gold", "lifetime", "count"))
    assert.same({ "hc:time.active", "t:gold" }, HC:Counters())
    assert.are.equal("Test", HC:GetCounter("t:gold") and "Test" or nil)
  end)

  it("rejects secret values before storage and counts them", function()
    local env = bootWithPack()
    assert.is_false(env.HC:Emit("t:gold", env:secretValue(), "loot", 1))
    assert.are.equal(1, env.ns.health.session.secretsRejected)
    assert.is_false(env.HC:Readable(1, env:secretValue()))
    assert.is_true(env.HC:Readable(1, "x"))
  end)

  it("refuses emits to unknown counters without raising", function()
    local env = bootWithPack()
    assert.is_false(env.HC:Emit("t:nothing", 1))
    assert.are.equal(1, env.ns.health.session.emitUnknownCounter)
  end)

  it("validates run breakdowns against stored aggregation sets", function()
    local env = Env.new():boot()
    env.HC:RegisterPack("P", { namespace = "p" })
    assert.has_error(function()
      env.HC:RegisterCounter({ id = "p:x", version = 1, dimensions = { { name = "a", cap = 4 } }, aggregations = { {} },
        runTracked = true, runBreakdowns = { "a" } })
    end)
    assert.has_error(function()
      env.HC:RegisterCounter({ id = "p:y", version = 1, runLive = { member = "nope" } })
    end)
  end)

  it("isolates source handler errors and counts events", function()
    local env = bootWithPack()
    local HC, n = env.HC, 0
    HC:RegisterSource("t:money", { mode = "event", events = { "PLAYER_MONEY" }, handler = function() n = n + 1; if n == 2 then error("bad") end end })
    env:fire("PLAYER_MONEY"); env:fire("PLAYER_MONEY"); env:fire("PLAYER_MONEY")
    assert.are.equal(3, n)
    local s = env.ns.SourceStats()[1]
    assert.are.equal(3, s.events)
    assert.are.equal(1, s.errors)
    assert.are.equal("Pack:Test", env.ns.RecentWarnings()[1].origin)
  end)

  it("polls only through the scheduler, paused during loading screens", function()
    local env = bootWithPack()
    local n = 0
    env.HC:RegisterSource("t:poll", { mode = "poll", interval = 2, read = function() n = n + 1 end })
    env:advance(10)
    assert.are.equal(5, n)
    env:fire("LOADING_SCREEN_ENABLED"); env:advance(10); env:fire("LOADING_SCREEN_DISABLED")
    assert.are.equal(5, n)
    env.HC:SetSourceInterval("t:poll", 5)
    env:advance(10)
    assert.are.equal(7, n)
  end)
end)

describe("hc:time.active", function()
  it("counts active seconds by zone; excludes AFK and loading screens", function()
    local env = Env.new():boot()
    env:advance(300)                 -- 5 min active in 1429
    env.afk = true; env:fire("PLAYER_FLAGS_CHANGED", "player")
    env:advance(600)                 -- 10 min AFK
    env.afk = false; env:fire("PLAYER_FLAGS_CHANGED", "player")
    env:advance(120)                 -- 2 min active
    env:fire("LOADING_SCREEN_ENABLED"); env:advance(30); env:fire("LOADING_SCREEN_DISABLED")
    env.zone = 1411; env:fire("ZONE_CHANGED_NEW_AREA")
    env:advance(60)                  -- 1 min in 1411
    env.ns.FlushAll()
    assert.are.equal(480, total(env, "hc:time.active"))
    local rows = assert(env.ns.db:Query({ counter = "hc:time.active", grain = "lifetime", groupBy = "zone" }))
    local by = {}
    for _, r in ipairs(rows) do by[r.label] = r.value end
    assert.are.equal(420, by["1429"])               -- LibGranaryDB labels are strings (LG-16)
    assert.are.equal(60, by["1411"])
    local hrows = assert(env.HC:Query({ counter = "hc:time.active", grain = "lifetime", groupBy = "zone" }))
    assert.are.equal(1429, hrows[1].member)          -- Hard Counters adds the numeric member
  end)

  it("writes at most once a minute while idle-active, and reports pending seconds", function()
    local env = Env.new():boot()
    env:advance(30)
    assert.are.equal(30, env.ns.PendingActive())
    assert.is_nil(total(env, "hc:time.active"))
    env:advance(40)
    assert.are.equal(60, total(env, "hc:time.active"))
    assert.are.equal(10, env.ns.PendingActive())
  end)

  it("treats a secret AFK flag as active and counts it", function()
    local env = Env.new():boot()
    env.ns.wow.isAFK = function() return nil end
    env:fire("PLAYER_FLAGS_CHANGED", "player")
    assert.are.equal(1, env.ns.health.session.afkSecret)
    assert.is_true(env.HC:IsActive())
  end)

  it("flushes at logout", function()
    local env = Env.new():boot()
    env:advance(45)
    local r = env:reload()
    assert.are.equal(45, assert(r.ns.db:Query({ counter = "hc:time.active", grain = "lifetime" })).total)
  end)
end)

describe("phases", function()
  it("selects the latest phase that has started", function()
    local env = Env.new():boot()
    assert.are.equal("forever-launch", env.HC:CurrentPhase().id)
    assert.are.equal("forever-launch", env.ns.currentPhase)
    assert.are.equal("forever-dec9", env.ns.PhaseAt(env.ns.utc(2026, 12, 10)).id)
    assert.is_nil(env.ns.PhaseAt(0))
    env.HC:RegisterPhase("custom", "Mine", env.t - 10)
    assert.are.equal("custom", env.ns.currentPhase)
    assert.are.equal(3, #env.HC:Phases())
  end)
end)

describe("views", function()
  it("queries a registered view with overrides, and per active hour", function()
    local env = bootWithPack()
    local HC = env.HC
    HC:Emit("t:gold", 3000, "loot", 1429)
    env:advance(1800)
    HC:Emit("t:gold", 1000, "vendor", 1429)
    env.ns.FlushAll()
    HC:RegisterView("t:gold.perhour", { counter = "t:gold", per = "activeHour", grain = "day" })
    local rows = assert(HC:Query("t:gold.perhour"))
    assert.are.equal(8000, rows.total)      -- 4000 in half an hour
    assert.are.equal(1800, rows.activeSeconds)
    local bySource = assert(HC:Query({ counter = "t:gold", grain = "thisweek", groupBy = "source" }))
    assert.are.equal(4000, bySource.total)
    assert.are.equal("loot", bySource[1].label)
    local none, err = HC:Query("t:missing")
    assert.is_nil(none)
    assert.truthy(err:find("unknown view"))
  end)

  it("runs async views through the scheduler", function()
    local env = bootWithPack()
    env.HC:Emit("t:gold", 5, "loot", 1)
    local got
    env.HC:QueryAsync({ counter = "t:gold", grain = "lifetime" }, function(rows) got = rows end)
    assert.is_nil(got)
    env:advance(1)
    assert.are.equal(5, got.total)
  end)
end)
