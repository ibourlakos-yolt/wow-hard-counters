-- Tier-1 diagnostics: health counters, the warning ring, error isolation, /hc report.
local Env = require("env")

describe("tier-1 diagnostics", function()
  it("boots: storage attached, entity set, login recorded", function()
    local env = Env.new():boot()
    local ns = env.ns
    assert.is_true(ns.ready)
    assert.truthy(ns.db)
    assert.truthy(env.sv.HardCountersDB.__granary)
    assert.are.equal(env.t, env.HC:LoginStart())
  end)

  it("'this login' survives /reload but not a new login", function()
    local env = Env.new():boot()
    local start = env.HC:LoginStart()
    env:advance(600)
    local r = env:reload()
    assert.are.equal(start, r.HC:LoginStart())
    r:advance(60)
    local l = r:reload({ login = true, offline = 3600 })
    assert.are.equal(l.t, l.HC:LoginStart())
  end)

  it("keeps warnings in a bounded ring that survives /reload", function()
    local env = Env.new():boot()
    for i = 1, 205 do env.ns.Log("warn", "HC", "warning %d", i) end
    local w = env.ns.RecentWarnings()
    assert.are.equal(200, #w)
    assert.are.equal("warning 6", w[1].msg)
    local r = env:reload()
    local w2 = r.ns.RecentWarnings()
    assert.are.equal(200, #w2)
    assert.are.equal("warning 205", w2[200].msg)
  end)

  it("drops info and debug without a sink, forwards everything with one", function()
    local env = Env.new():boot()
    local ns = env.ns
    ns.Log("info", "HC", "quiet %d", 1)
    assert.are.equal(0, #ns.RecentWarnings())
    local got = {}
    ns.SetLogSink(function(_, level, origin, msg) got[#got + 1] = level .. "|" .. origin .. "|" .. msg end)
    ns.Log("debug", "Pack:Farmer", "loud %s", "x")
    assert.are.same({ "debug|Pack:Farmer|loud x" }, got)
    ns.Log("warn", "HC", "bad format %d", "notanumber")
    assert.truthy(got[2]:find("bad log arguments", 1, true))
  end)

  it("counts health per login and lifetime", function()
    local env = Env.new():boot()
    env.ns.Count("secretsRejected", 2)
    local r = env:reload()
    r.ns.Count("secretsRejected")
    assert.are.equal(1, r.ns.health.session.secretsRejected)
    assert.are.equal(3, r.ns.health.saved.secretsRejected)
  end)

  it("isolates a failing event handler: others still run, the error is counted and handed on", function()
    local env = Env.new():boot()
    local ns = env.ns
    local ran = false
    ns.On("BAG_UPDATE_DELAYED", function() error("boom") end, "Pack:Test")
    ns.On("BAG_UPDATE_DELAYED", function() ran = true end)
    env:fire("BAG_UPDATE_DELAYED")
    assert.is_true(ran)
    assert.are.equal(1, ns.health.session.errorsCaught)
    assert.are.equal(1, #env.errors)
    local w = ns.RecentWarnings()
    assert.are.equal("Pack:Test", w[#w].origin)
  end)

  it("pauses scheduler jobs during loading screens", function()
    local env = Env.new():boot()
    local ns = env.ns
    local n = 0
    ns.Every(1, function() n = n + 1 end)
    env:advance(3)
    assert.are.equal(3, n)
    env:fire("LOADING_SCREEN_ENABLED")
    env:advance(5)
    assert.are.equal(3, n)
    env:fire("LOADING_SCREEN_DISABLED")
    env:advance(2)
    assert.are.equal(5, n)
  end)

  it("builds a scrubbed, versioned report", function()
    local env = Env.new():boot()
    env.ns.Log("warn", "HC", "something odd")
    local s = env.ns.BuildReport({})
    assert.truthy(s:match("^!HCReport:1!d:%x%x%x%x%x%x%x%x:BASE64!End:HCReport:1!$"))
    local body = env.lastReportBody
    assert.are.equal(1, body.fmt)
    assert.are.equal(env.HC.VERSION, body.hc)
    assert.are.equal(2, body.lib.minor >= 2 and 2 or body.lib.minor)
    assert.are.equal("something odd", body.warn[#body.warn][4])
    assert.truthy(body.granary:match("^!GranaryDBReport:1!"))
    assert.is_nil(body.addons)
    -- no names, realms or GUIDs anywhere in the body
    local function scan(v)
      if type(v) == "string" then
        assert.is_nil(v:find("Tester", 1, true))
        assert.is_nil(v:find(env.guid, 1, true))
      elseif type(v) == "table" then
        for k, x in pairs(v) do scan(k); scan(x) end
      end
    end
    scan({ body.hc, body.client, body.health, body.warn, body.packs, body.runs })
    env.ns.BuildReport({ addons = true })
    assert.are.same({ "HardCounters", "Other" }, env.lastReportBody.addons)
  end)

  -- HC-61: anonymous by default; name (with realm) and class only when asked for, each on its own
  it("leaves out the character unless name or class is asked for", function()
    local env = Env.new():boot()
    local _, body = env.ns.BuildReport({})
    assert.is_nil(body.who)
    local summary = table.concat(env.ns.ReportSummary(body), "\n")
    assert.truthy(summary:find("No character name, realm or class", 1, true))
    _, body = env.ns.BuildReport({ class = true })
    assert.are.same({ class = "MAGE" }, body.who)
    _, body = env.ns.BuildReport({ name = true })
    assert.are.same({ name = "Tester", realm = "Test" }, body.who)
    summary = table.concat(env.ns.ReportSummary(body), "\n")
    assert.truthy(summary:find("Your character: Tester-Test", 1, true))
    assert.is_nil(summary:find("No character name", 1, true))
  end)

  -- HC-61: the Diagnostics section rides along; a failing one doesn't break the report
  it("carries the Diagnostics section when one is set, and survives it failing", function()
    local env = Env.new():boot()
    local ns = env.ns
    local _, body = ns.BuildReport({})
    assert.is_nil(body.diag)
    assert.truthy(table.concat(ns.ReportSummary(body), "\n"):find("Diagnostics: not loaded", 1, true))
    ns.reportSection = function() return { v = 1, funcs = { GetMoney = { s = "ok" } }, events = {}, strings = {}, samplers = {} } end
    _, body = ns.BuildReport({})
    assert.are.equal("ok", body.diag.funcs.GetMoney.s)
    assert.truthy(table.concat(ns.ReportSummary(body), "\n"):find("Diagnostics: 1 API checks", 1, true))
    ns.reportSection = function() error("boom") end
    local s
    s, body = ns.BuildReport({})
    assert.truthy(s:match("^!HCReport:1!"))
    assert.truthy(tostring(body.diag):find("Diagnostics section failed", 1, true))
  end)

  -- HC-61: over the cap, the storage report goes before the probes, and the probes' parts go samplers first
  it("sheds the storage report, then the probes' samplers, events and strings, keeping the API checks", function()
    local env = Env.new():boot()
    local ns = env.ns
    ns.reportSection = function()
      return { v = 1, funcs = { GetMoney = { s = "ok" } }, events = { E = 1 }, strings = { S = "x" }, samplers = { travel = {} } }
    end
    local W = ns.wow
    local function size(t)
      local n = 100
      if t.granary then n = n + 9000 end
      if type(t.diag) == "table" then
        if t.diag.samplers then n = n + 9000 end
        if t.diag.events then n = n + 9000 end
        if t.diag.strings then n = n + 3000 end
        n = n + 5000
      end
      return n
    end
    W.encodeReport = function(t) env.lastReportBody = t; return string.rep("x", size(t)), "raw" end
    local s, body = ns.BuildReport({})
    assert.is_true(#s <= ns.REPORT_MAX)
    assert.is_true(body.truncated)
    assert.is_nil(body.granary)
    assert.is_nil(body.diag.samplers)
    assert.truthy(body.diag.events)          -- 100 + 9000 + 3000 + 5000 fits once the samplers are gone
    assert.truthy(body.diag.funcs.GetMoney)
    assert.truthy(table.concat(ns.ReportSummary(body), "\n"):find("Shortened to fit", 1, true))
  end)

  it("trims the report to its size cap, oldest warnings first", function()
    local env = Env.new():boot()
    local ns = env.ns
    for i = 1, 60 do ns.Log("warn", "HC", "w%d", i) end
    local W = ns.wow
    W.encodeReport = function(t)
      env.lastReportBody = t
      local n = 0
      for _, w in ipairs(t.warn) do n = n + #w[4] + 5000 end
      return string.rep("x", n), "raw"
    end
    local s = ns.BuildReport({})
    assert.is_true(#s <= ns.REPORT_MAX)
    assert.is_true(env.lastReportBody.truncated)
    assert.are.equal("w60", env.lastReportBody.warn[#env.lastReportBody.warn][4])
  end)
end)
