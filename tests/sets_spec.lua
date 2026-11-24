-- A tile's filter (HC-60, agreed 2026-11-22 with the Traveler pack): a reading with param.multi sums a set of
-- members of a small dimension; the set is the tile's, else the reading's default, else everything.
local Env = require("env")

local MODES = { "walk", "run", "mounted", "swim", "taxi", "hearth" }
local PRESETS = {
  { name = "On foot", members = { "walk", "run" } },
  { name = "Everything but teleports", members = { "walk", "run", "mounted", "swim", "taxi" } },
  { name = "Everything", members = MODES },
}

local function setup(env, history)
  local HC = env.HC
  HC:RegisterPack("Test", { namespace = "t" })
  HC:RegisterCounter({ id = "t:dist", version = 1, measures = { "sum", "count" },
    dimensions = { { name = "mode", cap = 32 } }, aggregations = { {}, { "mode" } } })
  HC:RegisterCounter({ id = "t:time", version = 1, measures = { "sum" },
    dimensions = { { name = "mode", cap = 32 } }, aggregations = { {}, { "mode" } } })
  Env.trackAll(env, "t:all", { "t:dist", "t:time", "hc:time.active" }, history or "off")
  local ALL = { "run", "session", "today", "lifetime" }
  HC:RegisterReading("t:travelled", { title = "Distance travelled", tracker = "t:all", counter = "t:dist",
    formatter = "distance", scopes = ALL, param = { dim = "mode", multi = true, members = MODES, presets = PRESETS,
      default = "Everything but teleports", label = function(m) return m == "walk" and "Walking" or nil end } })
  HC:RegisterReading("t:moving", { title = "Time moving", tracker = "t:all", counter = "t:time", formatter = "duration",
    scopes = ALL, param = { dim = "mode", multi = true, members = MODES, presets = PRESETS, default = "Everything but teleports" } })
  HC:RegisterReading("t:any", { title = "Any %s", tracker = "t:all", counter = "t:dist", scopes = ALL,
    param = { dim = "mode", multi = true } })
  -- a computed reading over the same filter: filtered distance / filtered time
  HC:RegisterReading("t:avg", { title = "Average speed", tracker = "t:all", formatter = "speed", scopes = ALL,
    inputs = { "t:travelled", "t:moving" }, param = { dim = "mode", multi = true, members = MODES, presets = PRESETS,
      default = "Everything but teleports" },
    compute = function(get)
      local d, t = get("t:travelled"), get("t:moving")
      if not d or not t or t <= 0 then return nil end
      return d / t
    end })
end

local function start(env, history, ui)
  env:load()
  setup(env, history)
  env:fire("ADDON_LOADED", "HardCounters")
  env.sv.HardCountersDB = _G.HardCountersDB
  env:fire("PLAYER_ENTERING_WORLD", true, false)
  if ui then
    local ns = env.ns
    ns.AddSlash = function() end
    ns.AddOptions = function() end
    for _, f in ipairs({ "UI/Widgets.lua", "UI/BoardModel.lua" }) do
      assert(loadfile(Env.ROOT .. "/" .. f))("HardCounters", ns)
    end
    env.M = ns.BoardModel
  end
  return env
end

local function boot(history, ui) return start(Env.new(), history, ui) end

local function travel(HC)
  HC:Emit("t:dist", 100, "walk"); HC:Emit("t:time", 40, "walk")
  HC:Emit("t:dist", 700, "run"); HC:Emit("t:time", 100, "run")
  HC:Emit("t:dist", 1400, "mounted"); HC:Emit("t:time", 100, "mounted")
  HC:Emit("t:dist", 3000, "hearth")
end

describe("a tile's filter (sets of members)", function()
  it("validates set parameters", function()
    local env = boot()
    local HC = env.HC
    local function bad(param) return function() HC:RegisterReading("t:bad", { counter = "t:dist", param = param }) end end
    assert.has_error(bad({ dim = "mode", multi = "yes" }))
    assert.has_error(bad({ dim = "zone", type = "zone", multi = true }))
    assert.has_error(bad({ dim = "mode", multi = true, members = {} }))
    assert.has_error(bad({ dim = "mode", multi = true, presets = { { name = "x" } } }))
    assert.has_error(bad({ dim = "mode", multi = true, default = "No such preset" }))
    assert.has_error(bad({ dim = "mode", multi = true, default = 3 }))
    local p = HC:GetReading("t:travelled").param
    assert.is_true(p.multi)
    assert.are.equal("Everything but teleports", p.default)
    assert.are.same({ "run", "walk" }, p.presets[1].members)               -- sets are kept sorted
    assert.are.same(MODES, p.members)                                      -- the checklist keeps the pack's order
  end)

  it("sums the set over our windows: the default, a set asked for, everything", function()
    local env = boot()
    local HC, ns = env.HC, env.ns
    travel(HC)
    -- no set: the reading's default (everything but the hearth)
    local v, text, _, state = HC:Reading("t:travelled", "session")
    assert.is_nil(state)
    assert.are.equal(2200, v)
    assert.are.equal("2,200 yd", text)
    assert.are.equal(2200, (HC:Reading("t:travelled", "session", { arg = { "walk", "run", "mounted" } })))
    assert.are.equal(800, (HC:Reading("t:travelled", "session", { arg = { "run", "walk" } })))
    assert.are.equal(0, (HC:Reading("t:travelled", "session", { arg = { "swim" } })))   -- never written: 0 is true
    -- no default: everything, the counter's whole total
    assert.are.equal(5200, (HC:Reading("t:any", "session")))
    -- a computed reading sees the same filter: 2200 yd in 240 s
    assert.are.equal(2200 / 240, (HC:Reading("t:avg", "session")))
    assert.are.equal(800 / 140, (HC:Reading("t:avg", "session", { arg = { "walk", "run" } })))
    -- per hour divides by all active time
    env:advance(3600)
    assert.are.equal(800, (HC:Reading("t:travelled", "session", { arg = { "walk", "run" }, calc = "perHour" })))
    -- a set's recent rate and trend are not offered yet
    assert.are.equal("calc", select(4, HC:Reading("t:travelled", "session", { calc = "recent" })))
    assert.is_false((ns.CalcFits(ns.readings["t:travelled"], "trend", "session")))
    -- the open run
    HC:StartRun()
    HC:Emit("t:dist", 50, "run")
    assert.are.equal(50, (HC:Reading("t:travelled", "run", { arg = { "run" } })))
  end)

  it("names the set: the plain title for the default, a preset's name, labels, or a count", function()
    local env = boot()
    local ns = env.ns
    local r = ns.readings["t:travelled"]
    assert.are.equal("Distance travelled", ns.ReadingTitle(r, nil))
    assert.are.equal("Distance travelled: On foot", ns.ReadingTitle(r, ns.NormalizeSet({ "walk", "run" })))
    assert.are.equal("Distance travelled: Walking + swim", ns.ReadingTitle(r, ns.NormalizeSet({ "walk", "swim" })))
    assert.are.equal("Distance travelled: 4 kinds", ns.ReadingTitle(r, ns.NormalizeSet({ "walk", "swim", "taxi", "hearth" })))
    assert.are.equal("Everything but teleports", ns.MemberLabel(r, nil))
    assert.are.equal("Any everything", ns.ReadingTitle(ns.readings["t:any"], nil))
    assert.is_false(ns.NeedsArg(r))
    assert.is_true(ns.NeedsArg({ param = { dim = "x" } }))
  end)

  it("sums the set from storage, one cached query per member", function()
    local env = boot("detailed")
    local HC = env.HC
    travel(HC)
    assert.are.equal(2200, (HC:Reading("t:travelled", "today")))
    assert.are.equal(4400, (HC:Reading("t:travelled", "lifetime", { arg = { "mounted", "hearth" } })))
    assert.are.equal(5200, (HC:Reading("t:any", "lifetime")))
  end)

  it("keeps a tile's set on the board: presets, ticks, the default as nil, never empty", function()
    local env = boot(nil, true)
    local M, HC = env.M, env.HC
    local b = M.Create(nil, { name = "Trip" })
    local t = M.AddReading(b, "t:travelled")
    assert.is_nil(t.arg)                                                   -- no member to pick first
    assert.is_true(M.HasSet(t))
    assert.are.same({ "mounted", "run", "swim", "taxi", "walk" }, M.TileSet(t))
    assert.are.equal("Distance travelled", M.TileTitle(t))
    travel(HC)
    env:advance(65)
    assert.are.equal(2200, (M.TileValue(t)))
    -- a preset
    assert.is_true(M.SetArg(t, { "walk", "run" }, b))
    assert.are.same({ "run", "walk" }, t.arg)
    assert.are.equal(800, (M.TileValue(t)))
    assert.are.equal("Distance travelled: On foot", M.TileTitle(t))
    -- tick and untick
    M.ToggleMember(t, "mounted", b)
    assert.are.same({ "mounted", "run", "walk" }, t.arg)
    assert.are.equal(2200, (M.TileValue(t)))
    M.ToggleMember(t, "run", b); M.ToggleMember(t, "walk", b)
    assert.are.same({ "mounted" }, t.arg)
    assert.is_false(M.ToggleMember(t, "mounted", b))                       -- the last one stays
    assert.are.same({ "mounted" }, t.arg)
    -- back to the default's members: kept as nil, so the tile follows the reading's default
    M.SetArg(t, { "walk", "run", "mounted", "swim", "taxi" }, b)
    assert.is_nil(t.arg)
    -- the checklist: the reading's members in its order, labelled
    local choices = M.SetChoices("t:travelled")
    assert.are.equal(6, #choices)
    assert.are.equal("walk", choices[1].arg)
    assert.are.equal("Walking", choices[1].label)
    -- a reading with no member list offers the members counted so far
    local any = M.AddReading(b, "t:any")
    assert.are.equal(4, #M.SetChoices("t:any"))
    M.SetArg(any, { "hearth" }, b)
    assert.are.equal(3000, (M.TileValue(any)))
  end)

  it("offers the filter in the tile's menu: presets, then a checklist; adding needs no member first", function()
    local UI = require("ui_boot")
    UI.with(function(ctx)
      local HC, ns = ctx.HC, ctx.hc
      local M, B = ns.BoardModel, ns.Boards
      HC:RegisterReading("hc:testset", { title = "Kinds", scopes = { "session" }, compute = function(_, _, arg)
        return arg and #arg or -1
      end, param = { dim = "mode", multi = true, members = { "walk", "run", "swim" },
        presets = { { name = "On foot", members = { "walk", "run" } } }, default = "On foot" } })
      local b = M.Create(nil, { name = "Trip" })
      local t = M.AddReading(b, "hc:testset")
      t.scope = "session"
      B.Refresh(b.id, true)
      local f = B.Frame(b.id)
      local items
      local realShow = ns.Menu.Show
      ns.Menu.Show = function(_, it) items = it end
      B.TileMenu(f.rowFrames[1], b, 1)
      ns.Menu.Show = realShow
      local inc
      for _, it in ipairs(items) do if it.text and it.text:find("^Includes: ") then inc = it end end
      assert.truthy(inc)
      assert.are.equal("Includes: On foot", inc.text)
      local texts = {}
      for _, s in ipairs(inc.sub) do texts[#texts + 1] = s.text .. (s.checked and "*" or "") end
      assert.are.same({ "On foot*", "Or tick each:", "walk*", "run*", "swim" }, texts)
      inc.sub[5].func()                                     -- tick swim
      assert.are.same({ "run", "swim", "walk" }, t.arg)
      assert.are.equal(3, (M.TileValue(t)))
      inc.sub[1].func()                                     -- back to the preset, which is the default: nil
      assert.is_nil(t.arg)
      assert.are.same({}, ctx.env.errors)
    end)
  end)

  it("keeps a tile's set across a /reload", function()
    local env = boot(nil, true)
    local M, HC = env.M, env.HC
    local b = M.Create(nil, { name = "Trip" })
    local t = M.AddReading(b, "t:travelled")
    M.SetArg(t, { "run" }, b)
    travel(HC)
    env:fire("PLAYER_LOGOUT")
    local sv = { HardCountersDB = Env.svCopy(env.sv.HardCountersDB) }
    local r = start(Env.new({ t = env.t, guid = env.guid, sv = sv, settings = Env.svCopy(env.ns.settings),
      chars = Env.svCopy(env.chars) }), nil, true)
    local t2 = r.M.Store().list[#r.M.Store().list].tiles[1]
    assert.are.same({ "run" }, t2.arg)
    assert.are.equal("Distance travelled: run", r.M.TileTitle(t2))
    assert.are.equal(700, (r.M.TileValue(t2)))
  end)
end)
