-- HC-25: a zone key is a number from HC:ZoneKey() through storage, views, runs, records and context; text zone keys
-- saved before HC-25 are purged once at load (counters dropped, run records rewritten).
local Env = require("env")

local TIME = "hc:time.active"

local function setup(env, opts)
  local HC = env.HC
  HC:RegisterPack("Test", { namespace = "t" })
  HC:RegisterCounter({ id = "t:gold", version = 1, measures = { "sum", "count", "max" },
    dimensions = { { name = "source", cap = 8 }, { name = "zone", cap = 64 } },
    aggregations = { {}, { "source" }, { "zone" } }, context = { max = { "zone" } },
    runTracked = true, runBreakdowns = { "source", "zone" } })
  HC:RegisterCounter({ id = "t:clean", version = 1, measures = { "sum" },
    dimensions = { { name = "zone", cap = 64 } }, aggregations = { {}, { "zone" } } })
  local ids = { TIME, "t:gold", "t:clean" }
  if opts and opts.old then
    -- a counter of an older pack version: saved with text keys, not registered after the update (frozen)
    HC:RegisterCounter({ id = "t:old", version = 1, measures = { "sum" },
      dimensions = { { name = "zone", cap = 64 } }, aggregations = { {}, { "zone" } } })
    ids[#ids + 1] = "t:old"
  end
  Env.trackAll(env, "t:all", ids)
end

local function boot(env, opts)
  env:load()
  setup(env, opts)
  env:fire("ADDON_LOADED", "HardCounters")
  env.sv.HardCountersDB = _G.HardCountersDB
  env:fire("PLAYER_ENTERING_WORLD", not (opts and opts.reload), opts and opts.reload or false)
  return env
end

local function reload(env, opts)
  env:fire("PLAYER_LOGOUT")
  local sv = { HardCountersDB = Env.svCopy(env.sv.HardCountersDB) }
  if opts and opts.preHC25 then sv.HardCountersDB.migrations = nil end -- data saved by a build before HC-25
  local r = Env.new({ t = env.t, guid = env.guid, sv = sv, settings = Env.svCopy(env.settings) })
  r.zone = env.zone
  return boot(r, { reload = true, old = opts and opts.old })
end

local function lifetime(env, id, groupBy)
  return env.HC:Query({ counter = id, grain = "lifetime", groupBy = groupBy })
end

describe("zone keys are numbers end to end (HC-25)", function()
  it("from HC:ZoneKey() through views, per active hour, runs, records and context", function()
    local env = boot(Env.new())
    local HC = env.HC
    env.zone = 100036                               -- inside The Deadmines (100000 + instance ID 36)
    env:fire("ZONE_CHANGED_NEW_AREA")
    assert.are.equal(100036, HC:ZoneKey())
    local seen, owner = nil, {}
    HC.RegisterCallback(owner, "HC_NEW_RECORD", function(_, id, _, _, ctx) if id == "t:gold" then seen = ctx end end)
    local runId = assert(HC:StartRun("DM"))
    HC:Emit("t:gold", 40, "loot", HC:ZoneKey())
    env:advance(1)
    HC:Emit("t:gold", 500, "loot", HC:ZoneKey())   -- a new record: HC_NEW_RECORD with the zone in its context
    env:advance(599)
    env.zone = 1436
    env:fire("ZONE_CHANGED_NEW_AREA")
    HC:Emit("t:gold", 100, "loot", HC:ZoneKey())
    env:advance(60)
    HC:StopRun()

    local rows = assert(lifetime(env, "t:gold", "zone"))
    for _, r in ipairs(rows) do assert.are.equal("number", type(r.member), "view member " .. r.label) end
    local per = assert(HC:Query({ counter = "t:gold", grain = "lifetime", groupBy = "zone", per = "activeHour" }))
    local byZone = {}
    for _, r in ipairs(per) do byZone[r.member] = r.value end
    assert.are.equal(3240, byZone[100036])          -- 540 in 10 minutes
    assert.are.equal(6000, byZone[1436])            -- 100 in 1 minute

    local rec = HC:GetRunRecord(runId)
    assert.are.equal(100036, rec.mainZone)
    for k in pairs(rec.deltas[TIME].by.zone) do assert.are.equal("number", type(k)) end
    for k in pairs(rec.deltas["t:gold"].by.zone) do assert.are.equal("number", type(k)) end

    local max = assert(HC:Query({ counter = "t:gold", grain = "lifetime", measure = "max" }))
    assert.are.equal(100036, max.ctx and max.ctx.zone or (max[1] and max[1].ctx.zone))
    assert.are.equal(100036, seen and seen.zone)
  end)
end)

describe("purging text zone keys saved before HC-25", function()
  local function oldData()
    local env = boot(Env.new(), { old = true })
    local HC = env.HC
    env.zone = "The Deadmines"                      -- what W.zone() returned in instances before HC-13
    env:fire("ZONE_CHANGED_NEW_AREA")
    local id = assert(HC:StartRun("old"))
    HC:Emit("t:gold", 70, "loot", HC:ZoneKey())
    HC:Emit("t:old", 5, HC:ZoneKey())
    HC:Emit("t:clean", 9, 1429)                     -- only numbers: kept
    env:advance(300)
    env.zone = 1436
    env:fire("ZONE_CHANGED_NEW_AREA")
    env:advance(120)
    HC:StopRun()
    env.zone = "Shadowfang Keep"
    env:fire("ZONE_CHANGED_NEW_AREA")
    local open = assert(HC:StartRun("still open"))
    env:advance(60)
    env.zone = 1421
    env:fire("ZONE_CHANGED_NEW_AREA")
    env:advance(30)
    return env, id, open
  end

  it("drops counters with text zone members, keeps the rest, rewrites run records, once", function()
    local env, id, open = oldData()
    env.sv.HardCountersDB.runs.list[1].mainZone = "The Deadmines" -- what builds before HC-25 saved
    local r = reload(env, { preHC25 = true })        -- the update: t:old is no longer registered
    local HC, db = r.HC, r.ns.db

    assert.is_nil(db:Members("t:old", "zone"))       -- frozen and dropped
    assert.are.equal(0, assert(lifetime(r, "t:gold")).total or 0)
    for _, cid in ipairs({ TIME, "t:gold" }) do
      for _, m in ipairs(db:Members(cid, "zone") or {}) do assert.are.equal("number", type(m), cid) end
    end
    assert.are.equal(9, assert(lifetime(r, "t:clean")).total)

    local rec = HC:GetRunRecord(id)
    assert.are.equal(1436, rec.mainZone)            -- recomputed from what is left
    assert.are.same({ [1436] = 120 }, rec.deltas[TIME].by.zone)
    assert.are.same({}, rec.deltas["t:gold"].by.zone)
    assert.are.equal(70, rec.deltas["t:gold"].sum)  -- totals are kept: only zone keys go
    local run = assert(HC:GetRun({ breakdowns = true }))
    assert.are.equal(open, run.id)
    local zones = run.totals[TIME] and run.totals[TIME].by and run.totals[TIME].by.zone
    assert.truthy(zones and zones[1421], "the open run still has its numeric zone")
    for k in pairs(zones) do assert.are.equal("number", type(k)) end
    -- the drop happened mid-run: the run keeps its 90 active seconds and counts on from there, never backwards
    assert.are.equal(90, run.activeSeconds)
    r:advance(60)
    local after = assert(HC:GetRun({ breakdowns = true }))
    assert.are.equal(150, after.activeSeconds)
    for _, v in pairs(after.totals[TIME].by.zone) do assert.is_true(v > 0) end
    local stopped = HC:GetRunRecord(HC:StopRun())    -- stop closes the segment against storage: exact, not negative
    assert.are.equal(150, stopped.activeSeconds)
    assert.are.same({ [1421] = 90 }, stopped.deltas[TIME].by.zone)  -- 30 + 60; the 60 in "Shadowfang Keep" lost its key
    assert.is_true(r.sv.HardCountersDB.migrations.hc25)

    -- numbers written after the purge survive later loads: it runs once
    HC:Emit("t:gold", 40, "loot", HC:ZoneKey())
    local r2 = reload(r)
    assert.are.equal(40, assert(lifetime(r2, "t:gold")).total)
  end)

  it("does nothing on data without text keys", function()
    local env = boot(Env.new())
    env.HC:Emit("t:gold", 30, "loot", 1429)
    local r = reload(env, { preHC25 = true })
    assert.are.equal(30, assert(lifetime(r, "t:gold")).total)
    assert.is_true(r.sv.HardCountersDB.migrations.hc25)
  end)
end)
