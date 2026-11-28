-- Merged readings and what they need (2026-11-24, HardCountersNotes spec "Basic pack, merged readings, ..."):
-- an optional member (none: the whole total), a set reading's recent rate when it reads everything, readings folded
-- into another (saved tiles move), unit twins, presets by category, the skill picker, the builtin pack.
local Env = require("env")

local function setup(env)
  local HC = env.HC
  HC:RegisterPack("Test", { namespace = "t" })
  HC:RegisterCounter({ id = "t:items", version = 1, measures = { "sum", "count" },
    dimensions = { { name = "item", cap = 64 } }, aggregations = { {}, { "item" } } })
  HC:RegisterCounter({ id = "t:money", version = 1, measures = { "sum", "count" },
    dimensions = { { name = "source", cap = 16 } }, aggregations = { {}, { "source" } } })
  Env.trackAll(env, "t:all", { "t:items", "t:money", "hc:time.active" }, "off")
  local ALL = { "run", "session", "today", "lifetime" }
  HC:RegisterReading("t:looted", { title = "Items looted", tracker = "t:all", counter = "t:items", scopes = ALL,
    param = { dim = "item", type = "item", optional = true, anyLabel = "any item" } })
  HC:RegisterReading("t:one", { title = "%s looted", tracker = "t:all", counter = "t:items", scopes = ALL,
    param = { dim = "item", type = "item" }, foldInto = "t:looted", foldArg = "same" })
  HC:RegisterReading("t:gold", { title = "Gold in", tracker = "t:all", counter = "t:money", scopes = ALL,
    param = { dim = "source", multi = true, members = { "loot", "quest", "vendor" } } })
  HC:RegisterReading("t:from", { title = "Gold from %s", tracker = "t:all", counter = "t:money", scopes = ALL,
    param = { dim = "source" }, foldInto = "t:gold", foldArg = "set" })
  HC:RegisterReading("t:bags", { title = "%s in bags", pickTitle = "In bags: pick an item", tracker = "t:all",
    scopes = { "now" }, param = { dim = "item", type = "item" }, compute = function(_, _, arg) return arg and 3 or nil end })
  HC:RegisterReading("t:speed", { title = "Speed", unitLabel = "yd/s", tracker = "t:all", scopes = { "now" },
    formatter = "speed", compute = function() return 7 end })
  HC:RegisterReading("t:speedpct", { title = "Speed (%)", unitOf = "t:speed", unitLabel = "% of run speed",
    tracker = "t:all", scopes = { "now" }, formatter = "speedpct", compute = function() return 7 end })
end

local function boot(ui)
  local env = Env.new()
  env:load()
  setup(env)
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

describe("merged readings", function()
  it("reads an optional member's whole total without one, and one member with it", function()
    local env = boot()
    local HC, ns = env.HC, env.ns
    HC:Emit("t:items", 3, 2589); HC:Emit("t:items", 2, 2592)
    assert.are.equal(5, (HC:Reading("t:looted", "session")))
    assert.are.equal(3, (HC:Reading("t:looted", "session", 2589)))
    local r = ns.readings["t:looted"]
    assert.is_false(ns.NeedsArg(r))
    assert.is_true(ns.ReadsWhole(r))
    assert.are.equal("Items looted", ns.ReadingTitle(r, nil))
    assert.are.equal("Items looted: 2589", ns.ReadingTitle(r, 2589))
    assert.are.equal("any item", ns.MemberLabel(r, nil))
    -- a required member still needs one, and its list name says what to pick (HC-39 d)
    assert.are.equal("noarg", select(4, HC:Reading("t:one", "session")))
    assert.are.equal("In bags: pick an item", ns.ReadingTitle(ns.readings["t:bags"], nil))
    assert.are.equal("2589 in bags", ns.ReadingTitle(ns.readings["t:bags"], 2589))
  end)

  it("keeps recent and trend for a set reading that reads everything, not for some kinds", function()
    local env = boot()
    local ns = env.ns
    local r = ns.readings["t:gold"]
    assert.is_true((ns.CalcFits(r, "recent", "session", nil, nil)))
    assert.is_true((ns.CalcFits(r, "trend", "session", nil, nil)))
    assert.is_false((ns.CalcFits(r, "recent", "session", nil, { "loot" })))
    assert.are_not.equal("calc", select(4, env.HC:Reading("t:gold", "session", { calc = "recent" })))
    assert.are.equal("calc", select(4, env.HC:Reading("t:gold", "session", { calc = "recent", arg = { "loot" } })))
  end)

  it("hides folded readings and unit twins from the catalog, and lists whole-total readings in runs", function()
    local env = boot()
    local ns = env.ns
    local inAll, inRuns = {}, {}
    for _, id in ipairs(ns.allReadingOrder) do inAll[id] = true end
    for _, id in ipairs(ns.readingOrder) do inRuns[id] = true end
    assert.is_nil(inAll["t:one"]); assert.is_nil(inAll["t:from"]); assert.is_nil(inAll["t:speedpct"])
    assert.is_true(inAll["t:looted"]); assert.is_true(inAll["t:gold"]); assert.is_true(inAll["t:speed"])
    assert.is_true(inRuns["t:looted"]); assert.is_true(inRuns["t:gold"])
    assert.is_nil(inRuns["t:one"])
    -- still readable by id (packs and the run list may ask)
    env.HC:Emit("t:items", 4, 7)
    assert.are.equal(4, (env.HC:Reading("t:one", "session", 7)))
    assert.is_true(env.HC:GetReading("t:one").hidden)
  end)

  it("moves saved tiles off a folded reading: the member as is, or as a set", function()
    local env = boot(true)
    local M = env.M
    local a = { kind = "reading", reading = "t:one", arg = 2589, scope = "session", calc = "perHour" }
    assert.is_true(M.FoldAlias(a))
    assert.are.equal("t:looted", a.reading)
    assert.are.equal(2589, a.arg)
    assert.are.equal("perHour", a.calc)                                   -- its look stays
    local g = { kind = "reading", reading = "t:from", arg = "loot", scope = "session" }
    assert.is_true(M.FoldAlias(g))
    assert.are.equal("t:gold", g.reading)
    assert.are.same({ "loot" }, g.arg)
    assert.is_false(M.FoldAlias(g))                                       -- once
  end)

  it("switches a tile between unit twins, keeping the rest", function()
    local env = boot(true)
    local M, ns = env.M, env.ns
    local units = ns.ReadingUnits(ns.readings["t:speedpct"])
    assert.are.equal(2, #units)
    assert.are.equal("t:speed", units[1].id)
    assert.are.equal("% of run speed", units[2].label)
    assert.is_nil(ns.ReadingUnits(ns.readings["t:looted"]))
    local b = M.Create(nil, { name = "Trip" })
    local t = M.AddReading(b, "t:speed", nil, "now")
    t.size = "half"
    assert.is_true(M.SetReading(t, "t:speedpct", b))
    assert.are.equal("t:speedpct", t.reading)
    assert.are.equal("half", t.size)
    assert.is_false(M.SetReading(t, "t:looted", b))                      -- not a twin
  end)
end)

describe("presets by category (HC-57)", function()
  it("groups Activity, your class, the other classes in a submenu, Roles, packs without one by title", function()
    local env = boot(true)
    local M, HC = env.M, env.HC
    env.ns.wow.playerClass = function() return "MAGE" end
    local tile = { { reading = "t:looted" } }
    local titles, by = {}, {}
    local function groups()
      titles, by = {}, {}
      for _, g in ipairs(M.PresetGroups()) do titles[#titles + 1] = g.title; by[g.title] = g end
    end
    HC:RegisterBoardPreset("t:mage", { name = "Mage (Caster)", category = "class", class = "MAGE", role = "caster", tiles = tile })
    HC:RegisterBoardPreset("t:rogue", { name = "Rogue", category = "class", class = "ROGUE", tiles = tile })
    HC:RegisterBoardPreset("t:misc", { name = "Misc", tiles = tile })
    groups()
    assert.are.same({ "Activity", "Your class", "Other classes", "Test" }, titles)   -- (0.5.0) no role boards: no Roles
    -- another author's role board is still taken, listed after the classes
    HC:RegisterBoardPreset("t:tank", { name = "Tank", category = "role", tiles = tile })
    groups()
    assert.are.same({ "Activity", "Your class", "Other classes", "Roles", "Test" }, titles)
    assert.are.same({ "run", "pocket", "leveling" }, by.Activity.keys)
    assert.are.same({ "t:mage" }, by["Your class"].keys)
    assert.is_true(by["Other classes"].more)
    assert.are.equal("caster", M.Preset("t:mage").role)          -- (0.5.0) stored; nothing reads it yet
    assert.are.same({ "activity", "class", "role" }, M.CATEGORY_ORDER)
    assert.are.equal("Warlock", M.ClassWord("WARLOCK"))
    assert.has_error(function() HC:RegisterBoardPreset("t:x", { name = "X", category = "dungeon", tiles = tile }) end)
    assert.has_error(function() HC:RegisterBoardPreset("t:y", { name = "Y", category = "class", tiles = tile }) end)
    assert.has_error(function()
      HC:RegisterBoardPreset("t:z", { name = "Z", category = "class", class = "MAGE", role = "dps", tiles = tile })
    end)
  end)
end)

describe("the skill picker (HC-71)", function()
  it("lists the skill lines by header, narrowed by the reading's filter", function()
    local env = boot(true)
    local M, HC, ns = env.M, env.HC, env.ns
    local lines = {
      { name = "Weapon Skills", isHeader = true }, { name = "Swords", skillID = 43 }, { name = "Unarmed", skillID = 162 },
      { name = "Professions", isHeader = true }, { name = "Fishing", skillID = 356 },
    }
    _G.C_SkillInfo = { GetNumSkillLines = function() return #lines end, GetSkillLineInfo = function(i) return lines[i] end }
    HC:RegisterReading("t:skill", { title = "Weapon skill", tracker = "t:all", scopes = { "now" },
      param = { dim = "skill", type = "skill", filter = function(l) return l.group == "Weapon Skills" end },
      compute = function(_, _, arg) return arg end })
    local groups, n = M.SkillChoices("t:skill")
    assert.are.equal(2, n)
    assert.are.equal("Weapon Skills", groups[1].name)
    assert.are.equal("Unarmed", groups[1].list[2].label)
    assert.are.equal("Weapon skill: Swords", ns.ReadingTitle(ns.readings["t:skill"], 43))
    _G.C_SkillInfo = nil
    assert.has_error(function()
      HC:RegisterReading("t:bad", { title = "X", tracker = "t:all", scopes = { "now" }, compute = function() end,
        param = { dim = "x", filter = function() end } })
    end)
  end)
end)

describe("the builtin pack", function()
  it("registers Hard Counters Basic with the hc namespace, first in the pack list", function()
    local env = boot()
    local ns = env.ns
    local p = ns.RegisterBuiltinPack("Basic", { title = "Hard Counters Basic" })
    assert.are.equal("hc", p.namespace)
    assert.are.equal("Basic", ns.PackSummaries()[1].name)
    assert.has_error(function() env.HC:RegisterPack("Other", { namespace = "hc" }) end)
  end)
end)
