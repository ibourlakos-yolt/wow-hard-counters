-- Odometers and windows (HC-29, DESIGN §16.2): saved running totals per character, windows as baselines over them.
-- Everything here runs with history off (Live only): none of it may depend on storage.
local Env = require("env")

local function setup(HC)
  HC:RegisterPack("Test", { namespace = "t" })
  HC:RegisterCounter({ id = "t:gold", version = 1, measures = { "sum", "count" },
    dimensions = { { name = "source", cap = 8 } }, aggregations = { {}, { "source" } }, runBreakdowns = { "source" } })
  HC:RegisterCounter({ id = "t:plain", version = 1, measures = { "sum", "count" } })
  HC:RegisterCounter({ id = "t:owned", version = 1, kind = "stock", measures = { "last" } })
  HC:RegisterCounter({ id = "t:offc", version = 1 })
  HC:RegisterTracker("t:on", { title = "On", counters = { "t:gold", "t:plain", "t:owned", "hc:time.active" }, default = "on" })
  HC:RegisterTracker("t:off", { title = "Off", counters = { "t:offc" }, default = "off" })
  HC:RegisterReading("t:gold", { title = "Gold", tracker = "t:on", counter = "t:gold", scopes = { "run", "session" } })
  HC:RegisterReading("t:owned", { title = "Owned", tracker = "t:on", counter = "t:owned", scopes = { "now" } })
end

local function start(env, login)
  env:load()
  setup(env.HC)
  env.asked = {}
  env.ns.AskAboutRun = function(id) env.asked[#env.asked + 1] = id end
  env:fire("ADDON_LOADED", "HardCounters")
  env.sv.HardCountersDB = _G.HardCountersDB
  env:fire("PLAYER_ENTERING_WORLD", login, not login)
  return env
end

local function boot(opts) return start(Env.new(opts), true) end

local function again(env, opts)
  opts = opts or {}
  env:fire("PLAYER_LOGOUT")
  local sv = { HardCountersDB = Env.svCopy(env.sv.HardCountersDB) }
  local r = Env.new({ t = env.t + (opts.offline or 0), guid = opts.guid or env.guid, sv = sv, settings = env.ns.settings })
  r.zone = env.zone
  return start(r, opts.login and true or false)
end

describe("odometers", function()
  it("keep a running total per character across /reload and logout, with history off", function()
    local env = boot()
    local HC = env.HC
    assert.are.equal("off", HC:CounterState("t:gold").history)
    HC:Emit("t:gold", 100, "loot")
    HC:Emit("t:gold", 50, "vendor")
    HC:Observe("t:owned", 7000)
    assert.is_false(HC:Emit("t:offc", 5))                       -- its tracker is off: nothing counts
    local r = again(env)                                        -- /reload
    assert.are.equal(150, r.ns.odo["t:gold"].s)
    assert.are.equal(150, (r.HC:Reading("t:gold", "session")))    -- the login carries on
    r.HC:Emit("t:gold", 25, "loot")
    local l = again(r, { login = true, offline = 3600 })
    assert.are.equal(175, l.ns.odo["t:gold"].s)                 -- the odometer never starts over
    assert.are.equal(3, l.ns.odo["t:gold"].n)
    assert.are.same({ loot = 125, vendor = 50 }, l.ns.odo["t:gold"].by.source)
    assert.is_nil(l.ns.odo["t:offc"])
    assert.are.equal(0, (l.HC:Reading("t:gold", "session")))      -- the login scope does
    l.HC:Emit("t:gold", 10, "loot")
    assert.are.equal(10, (l.HC:Reading("t:gold", "session")))
    assert.are.equal(7000, (l.HC:Reading("t:owned", "now")))    -- a stock's last value is known before it is observed again
  end)

  it("are per character: an alt has its own, and the main's are untouched", function()
    local env = boot()
    env.HC:Emit("t:gold", 100, "loot")
    local alt = again(env, { login = true, guid = "Player-1-00000002" })
    assert.is_nil(alt.ns.odo["t:gold"])
    alt.HC:Emit("t:gold", 7, "loot")
    assert.are.equal(7, (alt.HC:Reading("t:gold", "session")))
    local all = alt.sv.HardCountersDB.odo
    assert.are.equal(100, all["Player-1-00000001"]["t:gold"].s)
    assert.are.equal(7, all["Player-1-00000002"]["t:gold"].s)
  end)

  it("send members past the cap to 'other'", function()
    local env = boot()
    for i = 1, 502 do env.HC:Emit("t:gold", 1, "m" .. i) end
    local by = env.ns.odo["t:gold"].by.source
    assert.are.equal(1, by.m500)
    assert.is_nil(by.m501)
    assert.are.equal(2, by.other)
    assert.are.equal(502, env.ns.odo["t:gold"].s)
  end)
end)

describe("windows", function()
  it("any number can be open at once, each with its own start and pauses", function()
    local env = boot()
    local HC, Win = env.HC, env.ns.Win
    HC:Emit("t:gold", 1000, "loot")                             -- before either window
    local a = Win.New()
    Win.Resume(a)
    HC:Emit("t:gold", 100, "loot")
    env:advance(120)
    local b = Win.New()
    Win.Resume(b)
    HC:Emit("t:gold", 30, "vendor")
    env:advance(60)
    assert.are.equal(130, Win.Total(a, "t:gold"))
    assert.are.equal(2, Win.Total(a, "t:gold", "count"))
    assert.are.equal(30, Win.Total(b, "t:gold"))
    assert.are.equal(180, Win.Total(a, "hc:time.active"))
    assert.are.equal(60, Win.Total(b, "hc:time.active"))
    assert.are.equal(100, Win.MemberTotal(a, "t:gold", "source", "loot"))
    assert.are.equal(0, Win.MemberTotal(b, "t:gold", "source", "loot"))
    assert.is_true(Win.Pause(a))
    HC:Emit("t:gold", 5, "loot")                                -- a is paused, b counts
    env:advance(300)
    assert.are.equal(130, Win.Total(a, "t:gold"))
    assert.are.equal(35, Win.Total(b, "t:gold"))
    Win.Resume(a)
    HC:Emit("t:gold", 1, "loot")
    env:advance(60)
    assert.are.equal(131, Win.Total(a, "t:gold"))
    assert.are.equal(101, Win.MemberTotal(a, "t:gold", "source", "loot"))
    assert.are.equal(240, Win.Total(a, "hc:time.active"))
    assert.are.equal(240, Win.Elapsed(a))
    assert.are.equal(420, Win.Elapsed(b))
    assert.are.same({ loot = 101, vendor = 30 }, Win.Deltas(a, true)["t:gold"].by.source)
    Win.Reset(b)
    assert.are.equal(0, Win.Total(b, "t:gold"))
    assert.are.equal(0, Win.Elapsed(b))
    HC:Emit("t:gold", 2, "loot")
    assert.are.equal(2, Win.Total(b, "t:gold"))
  end)

  it("can watch only some counters", function()
    local env = boot()
    local Win = env.ns.Win
    local w = Win.New({ ids = { ["t:plain"] = true } })
    Win.Resume(w)
    env.HC:Emit("t:gold", 9, "loot")
    env.HC:Emit("t:plain", 4)
    assert.are.equal(4, Win.Total(w, "t:plain"))
    assert.is_nil(w.base["t:gold"])
    assert.is_nil(Win.Deltas(w)["t:gold"])
  end)

  it("give a stock its level at the start and the last one seen", function()
    local env = boot()
    local Win = env.ns.Win
    local early = Win.New()
    Win.Resume(early)
    assert.is_nil(Win.Total(early, "t:owned", "stop"))           -- never observed: unknown, not 0
    env.HC:Observe("t:owned", 500)
    local w = Win.New()
    Win.Resume(w)
    env.HC:Observe("t:owned", 800)
    assert.are.equal(500, Win.Total(w, "t:owned", "start"))
    assert.are.equal(800, Win.Total(w, "t:owned", "last"))
    Win.Pause(w)
    env.HC:Observe("t:owned", 900)
    assert.are.equal(800, Win.Total(w, "t:owned", "stop"))
  end)

  it("a window left counting at logout is banked at the next login, without the time offline", function()
    local env = boot()
    local w = env.ns.Win.New()
    env.ns.Win.Resume(w)
    env.sv.HardCountersDB.windows.test = w
    env.HC:Emit("t:gold", 40, "loot")
    env:advance(100)
    local l = again(env, { login = true, offline = 5000 })
    local Win = l.ns.Win
    local w2 = l.sv.HardCountersDB.windows.test
    assert.is_false(Win.AtLogin(w2))                            -- the login already banked it
    assert.is_false(Win.Counting(w2))
    assert.are.equal(40, Win.Total(w2, "t:gold"))
    assert.are.equal(100, Win.Total(w2, "hc:time.active"))
    assert.are.equal(100, Win.Elapsed(w2))
    Win.Resume(w2)                                              -- survives logout: carries on
    l.HC:Emit("t:gold", 2, "loot")
    l:advance(50)
    assert.are.equal(42, Win.Total(w2, "t:gold"))
    assert.are.equal(150, Win.Elapsed(w2))
  end)
end)

describe("runs and the login scope on odometers", function()
  it("a run is exact across a logout with history off", function()
    local env = boot({ settings = { runAtLogin = "resume" } })
    local id = env.HC:StartRun("Live only")
    env.HC:Emit("t:gold", 40, "loot")
    env.HC:Emit("t:plain", 3)
    env:advance(90)
    local l = again(env, { login = true, offline = 7200 })
    assert.are.equal("running", l.HC:GetRun().state)
    l.HC:Emit("t:gold", 10, "vendor")
    l:advance(30)
    local rec = l.HC:GetRunRecord(l.HC:StopRun())
    assert.are.equal(id, rec.id)
    assert.are.equal(50, rec.deltas["t:gold"].sum)
    assert.are.same({ loot = 40, vendor = 10 }, rec.deltas["t:gold"].by.source)
    assert.are.equal(3, rec.deltas["t:plain"].sum)              -- no runTracked flag needed any more
    assert.are.equal(120, rec.activeSeconds)
    assert.are.equal(120, rec.elapsed)
  end)

  it("adopts the login totals and the open run of a build before HC-29", function()
    local env = boot()
    env.HC:Emit("t:gold", 5, "loot")
    env:fire("PLAYER_LOGOUT")
    local db = Env.svCopy(env.sv.HardCountersDB)
    -- what the old build had saved: no odometers or windows, login totals in login.mem, the run's open segment
    db.odo, db.windows = nil, nil
    db.login.mem = { ["t:gold"] = { s = 300, n = 4 }, ["t:owned"] = { s = 0, n = 0, l = 9000 } }
    db.runs = { nextId = 8, list = {}, open = { id = 7, char = env.guid, charName = "Tester", start = env.t - 600,
      state = "running", pausedSeconds = 0, lastSeen = env.t, live = {},
      acc = { ["t:gold"] = { sum = 100, count = 1, by = { source = { loot = 100 } } } },
      seg = { ["t:gold"] = { sum = 20, count = 2, by = { source = { vendor = 20 } } }, ["t:owned"] = { last = 9000 } },
      segStart = { ["t:gold"] = { sum = 1, count = 1 }, ["t:owned"] = { last = 8800 } },
      splits = { { start = env.t - 600, acc = { ["t:gold"] = { sum = 100, count = 1 } } } } } }
    local r = Env.new({ t = env.t, guid = env.guid, sv = { HardCountersDB = db }, settings = env.ns.settings })
    start(r, false)                                             -- the /reload that brings in the new code
    local HC = r.HC
    assert.are.equal(300, (HC:Reading("t:gold", "session")))
    assert.are.equal(9000, (HC:Reading("t:owned", "now")))
    assert.is_nil(r.sv.HardCountersDB.login.mem)
    assert.are.equal(120, HC:GetRunTotal("t:gold"))
    HC:Emit("t:gold", 7, "loot")
    assert.are.equal(307, (HC:Reading("t:gold", "session")))
    local rec = HC:GetRunRecord(HC:StopRun())
    assert.are.equal(7, rec.id)
    assert.are.equal(127, rec.deltas["t:gold"].sum)
    assert.are.equal(4, rec.deltas["t:gold"].count)
    assert.are.same({ loot = 107, vendor = 20 }, rec.deltas["t:gold"].by.source)
    assert.are.equal(8800, rec.deltas["t:owned"].start)
    assert.are.equal(9000, rec.deltas["t:owned"].stop)
    assert.are.same({}, r.errors)
  end)
end)
