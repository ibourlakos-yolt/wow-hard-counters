-- Trackers, derived activation and history (HC-19, TRACKERS_AND_BOARDS §2, §3): counters run only when a tracker
-- that is on needs them; history is off by default (Live only); lowering history or switching off freezes data;
-- only Delete removes it.
local Env = require("env")

local function setup(HC, opts)
  opts = opts or {}
  HC:RegisterPack("Test", { namespace = "t" })
  HC:RegisterCounter({ id = "t:gold", version = 1, measures = { "sum", "count" },
    dimensions = { { name = "source", cap = 8 } }, aggregations = { {}, { "source" } }, runTracked = true,
    runBreakdowns = { "source" } })
  HC:RegisterCounter({ id = "t:spent", version = 1, measures = { "sum", "count" }, runTracked = true })
  HC:RegisterCounter({ id = "t:owned", version = 1, kind = "stock", measures = { "last", "min", "max" }, runTracked = true })
  HC:RegisterCounter({ id = "t:orphan", version = 1 })
  HC:RegisterTracker("t:goldph", { title = "Gold per hour", counters = { "t:gold", "t:spent", "t:owned" }, default = "on" })
  HC:RegisterTracker("t:ledger", { title = "Ledger", counters = { "t:gold", "t:spent" }, default = "off", needsHistory = "daily" })
  HC:RegisterReading("t:goldph", { title = "Gold/h", tracker = "t:goldph", counter = "t:gold", per = "activeHour",
    scopes = { "run", "session", "today" }, formatter = "money" })
  if opts.sources then
    opts.env.fired = { ev = 0, poll = 0, hook = 0 }
    HC:RegisterSource("t:money", { mode = "event", events = { "PLAYER_MONEY" }, feeds = { "t:gold" },
      handler = function() opts.env.fired.ev = opts.env.fired.ev + 1 end })
    HC:RegisterSource("t:poll", { mode = "poll", interval = 1, feeds = { "t:spent" },
      read = function() opts.env.fired.poll = opts.env.fired.poll + 1 end })
    HC:RegisterSource("t:hook", { mode = "hook", hook = "RepairAllItems", feeds = { "t:spent" },
      handler = function() opts.env.fired.hook = opts.env.fired.hook + 1 end })
  end
end

local function boot(opts)
  opts = opts or {}
  local env = Env.new(opts)
  env:load()
  setup(env.HC, { sources = opts.sources, env = env })
  env:fire("ADDON_LOADED", "HardCounters")
  env.sv.HardCountersDB = _G.HardCountersDB
  env:fire("PLAYER_ENTERING_WORLD", true, false)
  return env
end

local function reload(env, opts)
  opts = opts or {}
  env:fire("PLAYER_LOGOUT")
  local sv = { HardCountersDB = Env.svCopy(env.sv.HardCountersDB) }
  local r = Env.new({ t = env.t + (opts.offline or 0), guid = env.guid, sv = sv, settings = env.ns.settings })
  r.zone = env.zone
  r:load()
  setup(r.HC, { sources = opts.sources, env = r })
  r:fire("ADDON_LOADED", "HardCounters")
  r.sv.HardCountersDB = _G.HardCountersDB
  r:fire("PLAYER_ENTERING_WORLD", opts.login and true or false, not opts.login)
  return r
end

local function lifetime(env, id)
  local rows = env.ns.db:Query({ counter = id, grain = "lifetime" })
  return rows and rows.total
end

describe("trackers", function()
  it("start from their defaults: packs' off, the starters on, history off", function()
    local env = boot()
    local HC = env.HC
    assert.is_true(HC:IsTrackerOn("t:goldph"))
    assert.is_false(HC:IsTrackerOn("t:ledger"))
    local t = HC:GetTracker("t:ledger")
    assert.is_true(t.new)
    assert.are.equal("daily", t.history)            -- what it would keep: it needs daily history
    local g = HC:GetTracker("t:goldph")
    assert.are.equal("off", g.history)
    assert.same({ active = true, history = "off", days = 14, stored = false }, HC:CounterState("t:gold"))
    assert.is_false(HC:CounterState("t:orphan").active)
    assert.is_true(HC:CounterState(env.ns.TIME_ID).active)
    assert.are.equal(1, env.ns.health.session.counterWithoutTracker)
    assert.has_error(function() HC:RegisterTracker("t:x", { counters = "t:gold" }) end)   -- ({} is allowed: live readings only)
    assert.has_error(function() HC:RegisterTracker("zz:x", { counters = { "t:gold" } }) end)
  end)

  it("count Live only counters in memory: login and runs, across /reload, without storage", function()
    local env = boot()
    local HC = env.HC
    assert.is_true(HC:Emit("t:gold", 3000, "loot"))
    assert.is_nil(lifetime(env, "t:gold"))            -- nothing on disk
    HC:Observe("t:owned", 4800)
    local id = HC:StartRun("Live")
    HC:Emit("t:gold", 1000, "loot")
    HC:Emit("t:spent", 200)
    HC:Observe("t:owned", 5000)
    env:advance(1800)
    HC:PauseRun()
    HC:Emit("t:gold", 9999, "loot")                   -- paused: not in the run
    HC:ResumeRun()
    HC:Emit("t:gold", 500, "vendor")
    HC:Observe("t:owned", 5500)
    env:advance(1800)
    assert.are.equal(1500, HC:GetRunTotal("t:gold"))
    local r = reload(env)
    r.HC:Emit("t:gold", 100, "loot")
    assert.are.equal(1600, r.HC:GetRunTotal("t:gold"))
    assert.are.equal(3000 + 1000 + 9999 + 500 + 100, (r.HC:Reading("t:goldph", "session") and r.ns.Win.Total(r.ns.Session(), "t:gold")))
    local _, _, _, state = r.HC:Reading("t:goldph", "today")
    assert.are.equal("needs history", state)
    -- a logout pauses the run; the next login stops it: Live only totals come from the run's own sums
    local l = reload(r, { login = true, offline = 600 })
    l.HC:ResumeRun()
    l.HC:Emit("t:gold", 50, "loot")
    local rec = l.HC:GetRunRecord(l.HC:StopRun())
    assert.are.equal(id, rec.id)
    assert.are.equal(1650, rec.deltas["t:gold"].sum)
    assert.are.same({ loot = 1150, vendor = 500 }, rec.deltas["t:gold"].by.source)
    assert.are.equal(200, rec.deltas["t:spent"].sum)
    assert.are.equal(4800, rec.deltas["t:owned"].start)
    assert.are.equal(5500, rec.deltas["t:owned"].stop)
    assert.is_true(rec.activeSeconds >= 3600)
    assert.are.equal(50, l.ns.Win.Total(l.ns.Session(), "t:gold"))   -- the new login started over
  end)

  it("switching off stops counting at once, quietly, and readings say off", function()
    local env = boot()
    local HC = env.HC
    HC:SetTrackerOn("t:goldph", false)
    assert.is_false(HC:CounterState("t:gold").active)
    assert.is_false(HC:Emit("t:gold", 100, "loot"))
    assert.is_nil(env.ns.health.session.emitUnknownCounter)
    local _, text, _, state = HC:Reading("t:goldph", "session")
    assert.are.equal("off", state)
    assert.are.equal("off", text)
    assert.is_false(HC:CounterState(env.ns.TIME_ID).active)   -- no tracker on: not even active time
    HC:SetTrackerOn("t:goldph", true)
    assert.is_true(HC:Emit("t:gold", 100, "loot"))
  end)

  it("a counter shared by two trackers stays on, and keeps the most history either asks for", function()
    local env = boot()
    local HC = env.HC
    HC:SetTrackerOn("t:ledger", true)              -- needs daily history
    assert.is_false(HC:GetTracker("t:ledger").new)
    local st = HC:CounterState("t:gold")
    assert.are.equal("daily", st.history)
    assert.is_true(st.stored)
    assert.are.equal("off", HC:CounterState("t:owned").history)
    assert.are.equal("daily", HC:CounterState(env.ns.TIME_ID).history)
    HC:Emit("t:gold", 700, "loot")
    env:advance(3600)
    assert.are.equal(700, (HC:Reading("t:goldph", "today")))
    local impact = HC:TrackerOffImpact("t:goldph")
    assert.same({ "Ledger" }, impact.keptBy)
    HC:SetTrackerOn("t:goldph", false)
    assert.is_true(HC:CounterState("t:gold").active)
    assert.is_false(HC:CounterState("t:owned").active)
  end)

  it("raises, lowers and resumes history; only Delete removes data", function()
    local env = boot()
    local HC = env.HC
    HC:SetTrackerHistory("t:goldph", "daily", 30)
    HC:Emit("t:gold", 100, "loot")
    env:advance(86400)
    HC:Emit("t:gold", 200, "loot")
    assert.are.equal(300, lifetime(env, "t:gold"))
    assert.are.equal(200, (HC:Reading("t:goldph", "today") and env.ns.RawValue("t:gold", "sum", "today")))
    -- lowered to lifetime: the days are frozen, not deleted
    HC:SetTrackerHistory("t:goldph", "lifetime")
    assert.are.equal("lifetime", HC:CounterState("t:gold").history)
    HC:Emit("t:gold", 50, "loot")
    env.ns.db:RunMaintenance()
    local e = _G.HardCountersDB.__granary.c["t:gold"].e[env.guid]
    assert.truthy(e.o[2] or next(e.k[2] or {}) or (e.q[2] and #e.q[2] > 0), "day data kept")
    -- off: Live only from now on; storage keeps its lifetime
    HC:SetTrackerHistory("t:goldph", "off")
    assert.is_false(HC:CounterState("t:gold").stored)
    HC:Emit("t:gold", 1, "loot")
    local r = reload(env)
    assert.is_false(r.HC:CounterState("t:gold").stored)
    assert.truthy(r.sv.HardCountersDB.__granary.c["t:gold"], "frozen, not deleted")
    -- raised again: resumes with a gap
    r.HC:SetTrackerHistory("t:goldph", "daily")
    assert.are.equal(350, lifetime(r, "t:gold"))
    r.HC:Emit("t:gold", 10, "loot")
    assert.are.equal(360, lifetime(r, "t:gold"))
    -- Delete
    assert.is_true(r.HC:DeleteTrackerHistory("t:goldph") > 0)
    assert.are.equal(0, lifetime(r, "t:gold") or 0)
    r.HC:Emit("t:gold", 5, "loot")
    assert.are.equal(5, lifetime(r, "t:gold"))
  end)

  it("lists data nothing registered this session and deletes it", function()
    local env = boot()
    env.HC:SetTrackerHistory("t:goldph", "lifetime")
    env.HC:Emit("t:gold", 100, "loot")
    -- a session where the pack registers a different counter set: t:gold is on disk, unregistered, in no tracker
    env:fire("PLAYER_LOGOUT")
    local sv = { HardCountersDB = Env.svCopy(env.sv.HardCountersDB) }
    local r = Env.new({ t = env.t, guid = env.guid, sv = sv, settings = env.ns.settings })
    r:load()
    r:fire("ADDON_LOADED", "HardCounters")
    r.sv.HardCountersDB = _G.HardCountersDB
    r:fire("PLAYER_ENTERING_WORLD", false, true)
    local function listed()
      local out = {}
      for _, e in ipairs(r.HC:UnloadedCounters()) do out[e.id] = e.bytes end
      return out
    end
    assert.is_true((listed()["t:gold"] or 0) > 0)
    assert.truthy(listed()["t:spent"])               -- registered last session, never written: still on disk
    assert.is_true(r.HC:DeleteCounterData("t:gold") > 0)
    assert.is_nil(listed()["t:gold"])
    assert.are.equal(0, r.HC:DeleteCounterData("t:gold"))
  end)

  -- HC-48 (DESIGN §16.7.3): history is one switch; the presets are Advanced
  it("switches history on and off in one step: on brings back the last preset, Daily by default", function()
    local env = boot()
    local HC = env.HC
    assert.are.equal("off", HC:GetTracker("t:goldph").history)
    assert.is_true(HC:SetTrackerKeepHistory("t:goldph", true))
    assert.are.equal("daily", HC:GetTracker("t:goldph").history)
    assert.are.equal(14, HC:GetTracker("t:goldph").days)
    assert.is_true(HC:CounterState("t:gold").stored)
    HC:SetTrackerKeepHistory("t:goldph", false)
    assert.are.equal("off", HC:GetTracker("t:goldph").history)
    assert.is_false(HC:CounterState("t:gold").stored)
    HC:SetTrackerHistory("t:goldph", "detailed")        -- Advanced
    HC:SetTrackerKeepHistory("t:goldph", false)
    HC:SetTrackerKeepHistory("t:goldph", true)
    assert.are.equal("detailed", HC:GetTracker("t:goldph").history)
    HC:SetTrackerHistory("t:goldph", "daily", 90)
    HC:SetTrackerHistory("t:goldph", "off")             -- (/hc track ... history off: the same switch)
    HC:SetTrackerKeepHistory("t:goldph", true)
    assert.are.equal("daily", HC:GetTracker("t:goldph").history)
    assert.are.equal(90, HC:GetTracker("t:goldph").days)
    -- a choice saved before HC-48 (no `last`) comes back too
    env.ns.settings.trackers["t:goldph"] = { on = true, history = "lifetime" }
    HC:SetTrackerKeepHistory("t:goldph", false)
    HC:SetTrackerKeepHistory("t:goldph", true)
    assert.are.equal("lifetime", HC:GetTracker("t:goldph").history)
    -- the Ledger keeps what it needs whatever the switch says
    HC:SetTrackerOn("t:ledger", true)
    HC:SetTrackerKeepHistory("t:ledger", false)
    assert.are.equal("daily", HC:GetTracker("t:ledger").history)
    assert.is_false(HC:SetTrackerKeepHistory("nope:x", true))
  end)

  it("names data on disk by its title and pack, never its id, with why nothing reads it", function()
    local env = Env.new({})
    env:load()
    local HC = env.HC
    setup(HC)
    HC:RegisterCounter({ id = "t:loot", version = 1, title = "Looted items", measures = { "sum" } })
    HC:RegisterTracker("t:loot", { title = "Loot", counters = { "t:loot" }, default = "on" })
    env:fire("ADDON_LOADED", "HardCounters")
    env.sv.HardCountersDB = _G.HardCountersDB
    env:fire("PLAYER_ENTERING_WORLD", true, false)
    HC:SetTrackerHistory("t:goldph", "lifetime")
    HC:SetTrackerHistory("t:loot", "lifetime")
    HC:Emit("t:gold", 100, "loot")
    HC:Emit("t:loot", 3)
    local names = _G.HardCountersDB.names
    assert.same({ t = "Looted items", p = "Test" }, names["t:loot"])
    assert.same({ p = "Test" }, names["t:gold"])            -- untitled: named from its id later
    env:fire("PLAYER_LOGOUT")
    -- next session: the pack isn't loaded at all
    local sv = { HardCountersDB = Env.svCopy(env.sv.HardCountersDB) }
    local r = Env.new({ t = env.t, guid = env.guid, sv = sv, settings = env.ns.settings })
    r:load()
    r:fire("ADDON_LOADED", "HardCounters")
    r.sv.HardCountersDB = _G.HardCountersDB
    r:fire("PLAYER_ENTERING_WORLD", false, true)
    local by = {}
    for _, e in ipairs(r.HC:UnloadedCounters()) do by[e.id] = e end
    assert.are.equal("Looted items", by["t:loot"].title)
    assert.are.equal("Test", by["t:loot"].pack)
    assert.are.equal("pack not loaded", by["t:loot"].why)
    assert.are.equal("Gold", by["t:gold"].title)
    -- counters stored before names were kept: from the id and the known packs; a loaded pack: "no longer used"
    r.sv.HardCountersDB.names = nil
    r.ns.SV.names = nil
    assert.same({ "Money out", "Farmer", "pack not loaded" }, { r.ns.CounterName("hcfarm:money.out") })
    assert.same({ "Loot", "t", "pack not loaded" }, { r.ns.CounterName("t:loot") })   -- an unknown pack: its namespace
    r.HC:RegisterPack("Test", { namespace = "t" })
    assert.same({ "Loot", "Test", "no longer used" }, { r.ns.CounterName("t:loot") })
    assert.are.equal("no longer used", select(3, r.ns.CounterName("hc:money.old")))
  end)

  it("switches sources with their counters: events unregistered, polls paused, hooks ignored", function()
    local env = boot({ sources = true })
    local HC = env.HC
    env:fire("PLAYER_MONEY")
    env:advance(3)
    env:callHook("RepairAllItems")
    assert.are.equal(1, env.fired.ev)
    assert.is_true(env.fired.poll >= 2)
    assert.are.equal(1, env.fired.hook)
    HC:SetTrackerOn("t:goldph", false)
    local polls = env.fired.poll
    env:fire("PLAYER_MONEY")
    env:advance(3)
    env:callHook("RepairAllItems")
    assert.are.equal(1, env.fired.ev)
    assert.are.equal(polls, env.fired.poll)
    assert.are.equal(1, env.fired.hook)
    HC:SetTrackerOn("t:goldph", true)
    env:fire("PLAYER_MONEY")
    assert.are.equal(2, env.fired.ev)
  end)

  it("keeps choices per profile", function()
    local env = boot()
    local HC = env.HC
    HC:SetTrackerOn("t:ledger", true)
    local first = env.ns.settings
    env.ns.settings = env.ns.DefaultProfile()        -- a profile switch replaces the settings table
    env.ns.OnSettingsChanged()
    assert.is_false(HC:IsTrackerOn("t:ledger"))
    assert.are.equal("off", HC:CounterState("t:gold").history)
    env.ns.settings = first
    env.ns.OnSettingsChanged()
    assert.is_true(HC:IsTrackerOn("t:ledger"))
  end)
end)
