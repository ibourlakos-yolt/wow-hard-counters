-- Runs: exact totals over the odometers, pause, splits, live tallies, /reload, logout, one per character, dungeons.
local Env = require("env")

local function setup(env)
  local HC = env.HC
  HC:RegisterPack("Test", { namespace = "t" })
  HC:RegisterCounter({ id = "t:gold", version = 1, measures = { "sum", "count", "max" },
    dimensions = { { name = "source", cap = 8 }, { name = "zone", cap = 64 } },
    aggregations = { {}, { "source" }, { "zone" } }, runTracked = true, runBreakdowns = { "source" } })
  HC:RegisterCounter({ id = "t:items", version = 1, measures = { "sum", "count" },
    dimensions = { { name = "item", cap = 4096 }, { name = "quality", cap = 8 } },
    aggregations = { {}, { "item" }, { "quality" } }, runTracked = true, runBreakdowns = { "quality" },
    runLive = { member = "item", cap = 3, max = true } })
  HC:RegisterCounter({ id = "t:owned", version = 1, kind = "stock", measures = { "last", "min", "max" }, runTracked = true })
  Env.trackAll(env, "t:all", { "t:gold", "t:items", "t:owned" })
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
  env:fire("PLAYER_LOGOUT")
  opts = opts or {}
  local sv = { HardCountersDB = Env.svCopy(env.sv.HardCountersDB) }
  local r = Env.new({ t = env.t + (opts.offline or 0), guid = opts.guid or env.guid, sv = sv, settings = env.settings })
  r.zone = env.zone
  r:load()
  setup(r)
  r.asked = {}
  r.ns.AskAboutRun = function(id, _label, _name, same) r.asked[#r.asked + 1] = { id = id, same = same } end
  r:fire("ADDON_LOADED", "HardCounters")
  r.sv.HardCountersDB = _G.HardCountersDB
  r:fire("PLAYER_ENTERING_WORLD", opts.login and true or false, not opts.login)
  return r
end

describe("runs", function()
  it("totals a run exactly, with breakdowns, active time, main zone, live items and the best drop", function()
    local env = boot()
    local HC = env.HC
    HC:Emit("t:gold", 999, "loot", 1429)            -- before the run: not counted
    HC:Observe("t:owned", 10000)
    local id = assert(HC:StartRun("Felwood"))
    assert.is_nil(HC:StartRun("again"))
    HC:Emit("t:gold", 120, "loot", 1429)
    HC:Emit("t:gold", 80, "vendor", 1429)
    HC:EmitCtx("t:items", 3, { source = "mob" }, 2589, 1)
    HC:EmitCtx("t:items", 1, { source = "chest" }, 4306, 2)
    HC:Emit("t:items", 2, 2589, 1)
    HC:Observe("t:owned", 10200)
    env:advance(600)
    local live = HC:GetRun({ breakdowns = true, live = true })
    assert.are.equal(200, live.totals["t:gold"].sum)
    assert.are.equal(600, live.activeSeconds)
    assert.are.equal(5, live.live["t:items"].m[2589])
    local recId = HC:StopRun()
    assert.are.equal(id, recId)
    assert.is_nil(HC:GetRun())
    local rec = HC:GetRunRecord(id)
    assert.are.equal("Felwood", rec.label)
    assert.are.equal(200, rec.deltas["t:gold"].sum)
    assert.are.equal(2, rec.deltas["t:gold"].count)
    assert.are.same({ loot = 120, vendor = 80 }, rec.deltas["t:gold"].by.source)
    assert.are.equal(6, rec.deltas["t:items"].sum)
    assert.are.same({ [1] = 5, [2] = 1 }, rec.deltas["t:items"].by.quality)
    assert.are.equal(10000, rec.deltas["t:owned"].start)
    assert.are.equal(10200, rec.deltas["t:owned"].stop)
    assert.are.equal(600, rec.activeSeconds)
    assert.are.equal(600, rec.elapsed)
    assert.are.equal(1429, rec.mainZone)
    assert.are.same({ [2589] = 5, [4306] = 1 }, rec.live["t:items"].m)
    assert.are.equal(3, rec.live["t:items"].max.v)
    assert.are.equal("mob", rec.live["t:items"].max.source)
    assert.are.equal(2589, rec.live["t:items"].max.member)
  end)

  it("caps live members, then counts the rest as 'other'", function()
    local env = boot()
    local HC = env.HC
    HC:StartRun()
    for item = 1, 5 do HC:Emit("t:items", 1, item, 1) end
    HC:Emit("t:items", 1, 2, 1)
    local run = HC:GetRun({ live = true })
    assert.are.same({ [1] = 1, [2] = 2, [3] = 1, other = 2 }, run.live["t:items"].m)
  end)

  it("excludes everything while paused, and the paused time", function()
    local env = boot()
    local HC = env.HC
    HC:StartRun()
    HC:Emit("t:gold", 100, "loot", 1)
    env:advance(300)
    assert.is_true(HC:PauseRun())
    HC:Emit("t:gold", 5000, "vendor", 1)           -- vendor trip: not part of the run
    HC:Emit("t:items", 9, 7, 1)
    env:advance(900)
    assert.are.equal(100, HC:GetRunTotal("t:gold"))
    assert.is_true(HC:ResumeRun())
    HC:Emit("t:gold", 50, "loot", 1)
    env:advance(300)
    local rec = HC:GetRunRecord(HC:StopRun())
    assert.are.equal(150, rec.deltas["t:gold"].sum)
    assert.is_nil(rec.deltas["t:gold"].by.source.vendor)
    assert.is_nil(rec.live["t:items"])
    assert.are.equal(600, rec.elapsed)
    assert.are.equal(900, rec.pausedSeconds)
    assert.are.equal(600, rec.activeSeconds)
  end)

  it("splits a run into sub-ranges that add up to the run", function()
    local env = boot()
    local HC = env.HC
    HC:StartRun("Two spots")
    HC:Emit("t:gold", 100, "loot", 1)
    env:advance(600)
    assert.are.equal(2, HC:SplitRun("Spot B"))
    HC:Emit("t:gold", 300, "loot", 2)
    env:advance(1200)
    local rec = HC:GetRunRecord(HC:StopRun())
    assert.are.equal(2, #rec.splits)
    assert.are.equal(100, rec.splits[1].deltas["t:gold"].sum)
    assert.are.equal(600, rec.splits[1].activeSeconds)
    assert.are.equal("Spot B", rec.splits[2].label)
    assert.are.equal(300, rec.splits[2].deltas["t:gold"].sum)
    assert.are.equal(1200, rec.splits[2].activeSeconds)
    assert.are.equal(400, rec.deltas["t:gold"].sum)
  end)

  it("survives /reload", function()
    local env = boot()
    env.HC:StartRun("Reload me")
    env.HC:Emit("t:gold", 70, "loot", 1)
    env.HC:Emit("t:items", 2, 2589, 1)
    env:advance(120)
    local r = reload(env)
    assert.are.equal("running", r.HC:GetRun().state)
    assert.are.equal(0, #r.asked)
    r.HC:Emit("t:gold", 30, "loot", 1)
    r.HC:Emit("t:items", 1, 2589, 1)
    r:advance(60)
    assert.are.equal(100, r.HC:GetRunTotal("t:gold"))
    local rec = r.HC:GetRunRecord(r.HC:StopRun())
    assert.are.equal(100, rec.deltas["t:gold"].sum)
    assert.are.equal(3, rec.live["t:items"].m[2589])
    assert.are.equal(180, rec.activeSeconds)
  end)

  it("survives logout: it carries on at the next login, without the time offline, and nobody is asked", function()
    local env = boot()
    env.HC:StartRun("Overnight")
    env.HC:Emit("t:gold", 40, "loot", 1)
    env:advance(130)                                -- lastSeen updated by the 60 s flushes and at logout
    local r = reload(env, { login = true, offline = 8 * 3600 })
    local run = r.HC:GetRun()
    assert.are.equal("running", run.state)
    assert.are.same({}, r.asked)
    assert.are.equal(130, run.elapsed)              -- offline time doesn't count
    assert.are.equal(40, r.HC:GetRunTotal("t:gold"))
    r.HC:Emit("t:gold", 10, "loot", 1)
    r:advance(60)
    local rec = r.HC:GetRunRecord(r.HC:StopRun())
    assert.are.equal(50, rec.deltas["t:gold"].sum)
    assert.are.equal(190, rec.elapsed)
    assert.are.equal(190, rec.activeSeconds)
  end)

  it("a run paused at logout stays paused", function()
    local env = boot()
    env.HC:StartRun("Paused")
    env.HC:Emit("t:gold", 40, "loot", 1)
    env:advance(60)
    env.HC:PauseRun()
    local r = reload(env, { login = true, offline = 3600 })
    assert.are.equal("paused", r.HC:GetRun().state)
    r.HC:Emit("t:gold", 999, "loot", 1)
    assert.are.equal(40, r.HC:GetRunTotal("t:gold"))
    assert.is_true(r.HC:ResumeRun())
    assert.are.equal(60, r.HC:GetRun().elapsed)
  end)

  it("is one per character: an alt has none and can start its own; the main's waits for the main", function()
    local env = boot()
    local mainId = env.HC:StartRun("Main")
    env.HC:Emit("t:gold", 40, "loot", 1)
    env:advance(60)
    local alt = reload(env, { login = true, guid = "Player-1-00000002", offline = 60 })
    assert.is_nil(alt.HC:GetRun())
    assert.are.same({}, alt.asked)
    alt.HC:Emit("t:gold", 999, "loot", 1)           -- never in the main's run
    local altId = assert(alt.HC:StartRun("Alt"))
    alt.HC:Emit("t:gold", 5, "loot", 1)
    alt:advance(600)
    local main = reload(alt, { login = true, guid = "Player-1-00000001", offline = 60 })
    local run = main.HC:GetRun()
    assert.are.equal(mainId, run.id)
    assert.are.equal("running", run.state)
    assert.are.equal(60, run.elapsed)               -- the alt's session isn't on its clock
    main.HC:Emit("t:gold", 1, "loot", 1)
    local rec = main.HC:GetRunRecord(main.HC:StopRun())
    assert.are.equal(41, rec.deltas["t:gold"].sum)
    local back = reload(main, { login = true, guid = "Player-1-00000002", offline = 60 })
    assert.are.equal(altId, back.HC:GetRun().id)
    assert.are.equal(5, back.HC:GetRunTotal("t:gold"))
  end)

  it("adopts the single open run of builds before HC-30", function()
    local env = boot()
    env.HC:StartRun("Old")
    env.HC:Emit("t:gold", 40, "loot", 1)
    env:fire("PLAYER_LOGOUT")
    local R = env.sv.HardCountersDB.runs
    R.open, R.opens = R.opens[env.guid], nil        -- how it was saved before
    R.open.askAtLogin = true
    local r = reload(env)
    assert.are.equal("Old", r.HC:GetRun().label)
    assert.is_nil(r.sv.HardCountersDB.runs.open)
    assert.are.equal(40, r.HC:GetRunTotal("t:gold"))
  end)

  it("records a dungeon by itself: in starts a run named after it, out saves it; short visits leave nothing", function()
    local env = boot()
    local HC = env.HC
    env.zone = 100036
    env:fire("ZONE_CHANGED_NEW_AREA")
    local run = assert(HC:GetRun())
    assert.is_true(run.auto)
    assert.are.equal(HC:ZoneName(100036), run.label)
    HC:Emit("t:gold", 70, "loot", 100036)
    env:advance(120)
    env.zone = 1429                                 -- out after two minutes: not worth a record
    env:fire("ZONE_CHANGED_NEW_AREA")
    assert.is_nil(HC:GetRun())
    assert.are.equal(0, #HC:Runs())
    env.zone = 100036
    env:fire("ZONE_CHANGED_NEW_AREA")
    HC:Emit("t:gold", 500, "loot", 100036)
    env:advance(900)
    local r = reload(env)                           -- a /reload inside: the same run
    assert.is_true(r.HC:GetRun().auto)
    r:advance(300)
    r.zone = 1429
    r:fire("ZONE_CHANGED_NEW_AREA")
    assert.is_nil(r.HC:GetRun())
    local rec = r.HC:Runs()[1]
    assert.are.equal(500, rec.deltas["t:gold"].sum)
    assert.are.equal(1200, rec.activeSeconds)
    assert.are.equal(100036, rec.mainZone)
    -- a run the player started is never touched, and the option switches it off
    r.HC:StartRun("mine")
    r.zone = 100033
    r:fire("ZONE_CHANGED_NEW_AREA")
    r.zone = 1429
    r:fire("ZONE_CHANGED_NEW_AREA")
    assert.are.equal("mine", r.HC:GetRun().label)
    r.HC:StopRun()
    r.ns.settings.autoInstanceRuns = false
    r.zone = 100033
    r:fire("ZONE_CHANGED_NEW_AREA")
    assert.is_nil(r.HC:GetRun())
  end)

  it("keeps the newest runs up to the cap, filters and deletes", function()
    local env = Env.new({ settings = { maxRuns = 3 } })
    env:load()
    setup(env)
    env:fire("ADDON_LOADED", "HardCounters")
    env.sv.HardCountersDB = _G.HardCountersDB
    local HC = env.HC
    for i = 1, 5 do HC:StartRun("r" .. i); env:advance(10); HC:StopRun() end
    local list = HC:Runs()
    assert.are.equal(3, #list)
    assert.are.equal("r5", list[1].label)
    assert.are.equal(1, #HC:Runs({ limit = 1 }))
    assert.are.equal(3, #HC:Runs({ character = "current" }))
    assert.are.equal(0, #HC:Runs({ character = "someone-else" }))
    assert.is_true(HC:DeleteRun(list[1].id))
    assert.are.equal(2, #HC:Runs())
    assert.is_true(HC:RenameRun(list[2].id, "renamed"))
    assert.are.equal("renamed", HC:GetRunRecord(list[2].id).label)
  end)

  it("hands out copies, never saved tables", function()
    local env = boot()
    env.HC:StartRun()
    env.HC:Emit("t:gold", 5, "loot", 1)
    local id = env.HC:StopRun()
    local rec = env.HC:GetRunRecord(id)
    rec.deltas["t:gold"].sum = 1e9
    assert.are.equal(5, env.HC:GetRunRecord(id).deltas["t:gold"].sum)
  end)

  it("fires run callbacks", function()
    local env = boot()
    local seen = {}
    local owner = {}
    env.HC.RegisterCallback(owner, "HC_RUN_STARTED", function(e, id) seen[#seen + 1] = e .. id end)
    env.HC.RegisterCallback(owner, "HC_RUN_STOPPED", function(e, id) seen[#seen + 1] = e .. id end)
    local id = env.HC:StartRun()
    env.HC:StopRun()
    assert.are.same({ "HC_RUN_STARTED" .. id, "HC_RUN_STOPPED" .. id }, seen)
  end)
end)
