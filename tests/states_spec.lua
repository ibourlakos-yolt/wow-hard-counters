-- Reading states for packs (HC-28): a reading that doesn't apply to this character ("inapplicable", listed apart),
-- and a value the pack marks as the last one read ("stale", shown greyed with the pack's word).
local Env = require("env")
local UI = require("ui_boot")

local function boot()
  local env = Env.new()
  env:boot()
  local HC = env.HC
  HC:RegisterPack("Test", { namespace = "t" })
  HC:RegisterCounter({ id = "t:owned", version = 1, kind = "stock", measures = { "last", "min", "max" } })
  Env.trackAll(env, "t:all", { "t:owned" })
  return env
end

describe("reading states (HC-28)", function()
  it("validates applies and stale", function()
    local env = boot()
    local HC = env.HC
    assert.has_error(function() HC:RegisterReading("t:x", { counter = "t:owned", scopes = { "now" }, applies = true }) end)
    assert.has_error(function() HC:RegisterReading("t:y", { counter = "t:owned", scopes = { "now" }, stale = "combat" }) end)
  end)

  it("a reading that doesn't apply has no value and says so; a failing rule leaves it listed", function()
    local env = boot()
    local HC = env.HC
    local canParry = false
    HC:RegisterReading("t:parry", { title = "Parry", scopes = { "now" }, compute = function() return 5 end,
      applies = function() return canParry end })
    HC:RegisterReading("t:broken", { title = "Broken", scopes = { "now" }, compute = function() return 1 end,
      applies = function() error("boom") end })
    local v, text, settled, state = HC:Reading("t:parry", "now")
    assert.is_nil(v)
    assert.are.equal("n/a", text)
    assert.is_true(settled)
    assert.are.equal("inapplicable", state)
    assert.is_false(HC:ReadingApplies("t:parry"))
    assert.is_false(HC:GetReading("t:parry").applies)
    canParry = true                                       -- a talent, a level: asked again at every read
    assert.are.equal(5, (HC:Reading("t:parry", "now")))
    assert.is_true(HC:GetReading("t:parry").applies)
    assert.is_true(HC:ReadingApplies("t:broken"))
    assert.are.equal(1, (HC:Reading("t:broken", "now")))
    assert.is_true(HC:ReadingApplies("t:nonesuch"))       -- no rule, no reading: nothing hides it
  end)

  it("a stale value is shown with the pack's word; it never hides a value that isn't there", function()
    local env = boot()
    local HC = env.HC
    local inCombat, last = false, nil
    HC:RegisterReading("t:ap", { title = "Attack power", scopes = { "now" },
      compute = function() return last end,
      stale = function() return inCombat, "in combat" end })
    HC:RegisterReading("t:owned", { title = "Owned", counter = "t:owned", scopes = { "now" },
      stale = function() return true end })
    local v, text, _, state, note = HC:Reading("t:ap", "now")
    assert.is_nil(v)
    assert.is_nil(state)                                  -- nothing read yet: no value, not "stale"
    last = 1234
    v, text, _, state, note = HC:Reading("t:ap", "now")
    assert.are.equal(1234, v)
    assert.is_nil(state)
    inCombat = true
    v, text, _, state, note = HC:Reading("t:ap", "now")
    assert.are.equal(1234, v)
    assert.are.equal("1,234", text)
    assert.are.equal("stale", state)
    assert.are.equal("in combat", note)
    -- a counter's reading can be stale too, with no word
    HC:Observe("t:owned", 50)
    v, _, _, state, note = HC:Reading("t:owned", "now")
    assert.are.equal(50, v)
    assert.are.equal("stale", state)
    assert.is_nil(note)
  end)
end)

describe("reading states on screen (HC-28)", function()
  it("tiles grey a stale value and name why; the lists put readings this character doesn't use last", function()
    UI.with(function(ctx)
      local HC, ns = ctx.HC, ctx.hc
      HC:RegisterPack("TestStates", { namespace = "ts" })
      HC:RegisterCounter({ id = "ts:c", version = 1 })
      HC:RegisterTracker("ts:stats", { title = "Stats", counters = { "ts:c" }, default = "on" })
      local inCombat = false
      HC:RegisterReading("ts:ap", { title = "Attack power", tracker = "ts:stats", scopes = { "now" }, order = 1,
        compute = function() return 1234 end, stale = function() return inCombat, "in combat" end })
      HC:RegisterReading("ts:parry", { title = "Parry", tracker = "ts:stats", scopes = { "now" }, order = 2,
        compute = function() return 5 end, applies = function() return false end })
      HC:RegisterReading("ts:dodge", { title = "Dodge", tracker = "ts:stats", scopes = { "now" }, order = 3,
        compute = function() return 7 end })

      local M, B = ns.BoardModel, ns.Boards
      local b = M.Create(nil, { name = "Stats" })
      local ap = M.AddReading(b, "ts:ap", "row")
      ap.scope = "now"
      local parry = M.AddReading(b, "ts:parry", "row")
      parry.scope = "now"
      B.Refresh(b.id, true)
      local f = B.Frame(b.id)
      local function rowOf(tile)
        for _, w in ipairs(f.rowFrames) do
          if w.row and b.tiles[w.row.tiles[1]] == tile then return w end
        end
      end
      assert.are.equal("1,234", rowOf(ap).value:GetText())
      assert.is_nil(rowOf(ap).label:GetText():find("in combat"))
      inCombat = true
      B.Refresh(b.id, true)
      assert.are.equal("1,234", rowOf(ap).value:GetText())
      assert.truthy(rowOf(ap).label:GetText():find("in combat", 1, true))
      assert.are.equal("n/a", rowOf(parry).value:GetText())

      -- the + menu: Parry under "Not used by this character", last in its tracker
      local shownMenu
      local realShow = ns.Menu.Show
      ns.Menu.Show = function(_, items) shownMenu = items end
      B.AddMenu(f.addBtn, b)
      ns.Menu.Show = realShow
      local stats
      for _, it in ipairs(shownMenu) do if it.text == "Stats" then stats = it.sub end end
      assert.truthy(stats)
      assert.are.equal("Attack power", stats[1].text)
      assert.are.equal("Dodge", stats[2].text)
      assert.are.equal("Not used by this character", stats[3].text)
      assert.are.equal("Parry", stats[3].sub[1].text)

      -- the Trackers tab: the same order in the selected tracker's detail pane, under a heading
      ns.ShowTrackers(true)
      local tf = ns.Windows.Content("trackers")
      tf:SetSize(762, 568)
      ns.TrackersBrowser:Select("ts:stats", "all")
      local d = ns.TrackersBrowser.detail
      local function itemIndex(pattern)
        for i, r in ipairs(d.items) do
          if r:IsShown() and (r.text:GetText() or ""):find(pattern) then return i, r end
        end
      end
      local iDodge = itemIndex("^Dodge ")
      local iHead = itemIndex("^Not used by this character$")
      local iParry = itemIndex("^Parry ")
      assert.truthy(iDodge and iHead and iParry)
      assert.is_true(iDodge < iHead and iHead < iParry)
      assert.are.same({}, ctx.env.errors)
    end)
  end)
end)

describe("what Character Stats' phase 1 needs from the engine (2026-11-19)", function()
  it("a tracker of live readings only: no counters, it switches its readings on and off", function()
    local env = Env.new()
    env:boot()
    local HC = env.HC
    HC:RegisterPack("TestLive", { namespace = "tl" })
    assert.has_error(function() HC:RegisterTracker("tl:bad", { title = "Bad" }) end)
    HC:RegisterTracker("tl:stats", { title = "Stats", counters = {}, default = "off" })
    HC:RegisterReading("tl:str", { title = "Strength", tracker = "tl:stats", scopes = { "now" }, compute = function() return 42 end })
    assert.is_true(HC:Supports("liveTrackers"))
    local _, text, _, state = HC:Reading("tl:str", "now")
    assert.are.equal("off", state)
    assert.are.equal("off", text)
    HC:SetTrackerOn("tl:stats", true)
    assert.are.equal(42, (HC:Reading("tl:str", "now")))
    assert.are.same({}, HC:GetTracker("tl:stats").counters)
  end)

  it("a pack registers a board preset; New board offers it; unknown readings are left out", function()
    local env = Env.new()
    env:boot()
    local ns, HC = env.ns, env.HC
    ns.AddSlash = function() end
    ns.AddOptions = function() end
    for _, f in ipairs({ "UI/Widgets.lua", "UI/BoardModel.lua" }) do
      assert(loadfile(Env.ROOT .. "/" .. f))("HardCounters", ns)
    end
    local M = ns.BoardModel
    HC:RegisterPack("TestPreset", { namespace = "tp" })
    HC:RegisterReading("tp:ap", { title = "Attack power", scopes = { "now" }, compute = function() return 1 end })
    assert.has_error(function() HC:RegisterBoardPreset("melee", { tiles = { { reading = "tp:ap" } } }) end)
    assert.has_error(function() HC:RegisterBoardPreset("tp:melee", { tiles = {} }) end)
    assert.has_error(function() HC:RegisterBoardPreset("tp:melee", { tiles = { { reading = "tp:ap", style = "huge" } } }) end)
    assert.are.equal("tp:melee", HC:RegisterBoardPreset("tp:melee", { name = "Melee",
      tiles = { { reading = "tp:ap", scope = "now", style = "hero" }, { reading = "tp:missing", scope = "now" } } }))
    HC:RegisterBoardPreset("tp:melee", { name = "Melee", tiles = { { reading = "tp:ap", scope = "now", style = "hero" },
      { reading = "tp:missing", scope = "now" } } })                     -- again: replaced, listed once
    local n = 0
    for _, k in ipairs(M.PRESET_ORDER) do if k == "tp:melee" then n = n + 1 end end
    assert.are.equal(1, n)
    local b = M.Create("tp:melee")
    assert.are.equal("Melee", b.name)
    assert.are.equal(1, #b.tiles)
    -- (a pack's `style` is still read, HC-51: hero is a large number with its extras)
    assert.are.same({ kind = "reading", reading = "tp:ap", scope = "now", display = "number", size = "large",
      extras = { sparkline = true, vsUsual = true } }, b.tiles[1])
  end)
end)

describe("live in combat by passing the value through (CS-9, 2026-11-19)", function()
  it("a stale now tile hands the game's value straight to its font string; bars and the API keep the stale value", function()
    UI.with(function(ctx)
      local HC, ns = ctx.HC, ctx.hc
      HC:RegisterPack("TestLiveIn", { namespace = "tli" })
      local secret = ctx.env:secretValue()
      local inCombat = false
      HC:RegisterReading("tli:dodge", { title = "Dodge", scopes = { "now" }, formatter = "percent",
        compute = function() return 5 end, stale = function() return inCombat, "in combat" end,
        live = function() return secret end })
      assert.has_error(function() HC:RegisterReading("tli:bad", { title = "Bad", scopes = { "now" },
        compute = function() return 1 end, live = 3 }) end)
      assert.is_true(HC:Supports("livePassThrough"))
      local M, B = ns.BoardModel, ns.Boards
      local b = M.Create(nil, { name = "Live" })
      local t = M.AddReading(b, "tli:dodge", "row")
      t.scope = "now"
      inCombat = true
      B.Refresh(b.id, true)
      local f = B.Frame(b.id)
      local w
      for _, rf in ipairs(f.rowFrames) do if rf.row and b.tiles[rf.row.tiles[1]] == t then w = rf end end
      local got = {}
      w.value.SetFormattedText = function(_, fmt, v) got.fmt, got.v = fmt, v end
      B.Refresh(b.id)
      assert.are.equal("%.1f%%", got.fmt)
      assert.are.equal(secret, got.v)
      assert.is_nil(w.label:GetText():find("in combat", 1, true))   -- it is live: no mark
      -- the API never hands out the secret: the stale value, marked
      local v, _, _, state = HC:Reading("tli:dodge", "now")
      assert.are.equal(5, v)
      assert.are.equal("stale", state)
      local lv, fmt = HC:ReadingLive("tli:dodge")
      assert.are.equal(secret, lv)
      assert.are.equal("%.1f%%", fmt)
      -- a bar needs arithmetic: no pass-through, the stale value and its mark
      M.SetTarget(t, "10")
      M.SetDisplay(t, "bar")
      B.Refresh(b.id, true)
      for _, rf in ipairs(f.rowFrames) do if rf.row and b.tiles[rf.row.tiles[1]] == t then w = rf end end
      assert.truthy(w.label:GetText():find("in combat", 1, true))
      assert.are.same({}, ctx.env.errors)
    end)
  end)
end)
