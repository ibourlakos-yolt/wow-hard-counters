-- Load smoke test: all three addons (with Ace3, LibDataBroker and LibGranaryDB) load in TOC order under a
-- permissive fake client, log in, and every window builds and refreshes without a Lua error. It doesn't prove
-- anything looks right; that's the in-game checklist's job.
local UI = require("ui_boot")

describe("load smoke test", function()
  it("loads, logs in, and builds every window", function()
    local ctx = UI.with(function(ctx)
      local env, nsHC, nsDiag, nsFarm, HC = ctx.env, ctx.hc, ctx.diag, ctx.farm, ctx.HC
      assert.is_true(nsHC.ready)
      -- every window and slash command path; boards (v2 M5) replace the run panel and the live number
      local B, M = nsHC.Boards, nsHC.BoardModel
      local pocket = M.Store().list[1]
      assert.are.equal("Pocket", pocket.name)
      -- a visible board redraws on its own ticker (the old panel's lesson: not only on run events)
      assert.is_truthy(B.Frame(pocket.id).ticker)
      -- HC-34: an item on the cursor makes boards take the drop; letting go of it over one puts it back in the
      -- bag and offers the readings that take an item (Farmer's), or says there are none
      local pf = B.Frame(pocket.id)
      assert.is_false(pf:IsMouseEnabled())
      assert.is_false(B.DropItem(pf, pocket, nil))                    -- nothing carried: an ordinary click
      local held, cleared = 2589, 0
      rawset(_G, "GetCursorInfo", function() if held then return "item", held, "link" end end)
      rawset(_G, "ClearCursor", function() held = nil; cleared = cleared + 1 end)
      env:fire("CURSOR_CHANGED")
      assert.is_true(pf:IsMouseEnabled())
      pf.strip:GetScript("OnClick")(pf.strip, "LeftButton")
      assert.are.equal(1, cleared)
      assert.are.equal(ctx.farmer and true or false, nsHC.Menu.IsShown())
      nsHC.Menu.Hide()
      env:fire("CURSOR_CHANGED")
      assert.is_false(pf:IsMouseEnabled())                            -- click-through again
      rawset(_G, "GetCursorInfo", nil)
      rawset(_G, "ClearCursor", nil)
      if ctx.farmer then
        -- the pickers build their menus: factions from the game's list, items from recent loot
        B.MemberMenu(pf, "hcfarm:repwith", function() end)
        B.MemberMenu(pf, "hcfarm:looted", function() end)
        B.MemberMenu(pf, "hcfarm:inbags", function() end)
        nsHC.Menu.Hide()
      end
      assert(HC:StartRun("smoke"))
      B.RefreshAll()
      HC:SplitRun()
      HC:PauseRun()
      B.RefreshAll(true)
      HC:ResumeRun()
      env:advance(5)
      HC:StopRun()
      for _, b in ipairs(M.Store().list) do b.mini = not b.mini end
      B.RefreshAll(true)
      for _, b in ipairs(M.Store().list) do b.mini = not b.mini end
      B.RefreshAll(true)
      nsHC.ToggleRunList()
      nsHC.RefreshRunList()
      -- HC-65: the run card opened under the Hard Counters window; it now raises on click and on every opening
      local rec = HC:Runs()[1]
      nsHC.ShowRunCard(rec)
      local card = _G.HardCountersRunCard
      assert.is_true(card:IsToplevel())
      local raised = card._raised
      nsHC.ShowRunCard(rec)
      assert.are.equal(raised + 1, card._raised)
      nsHC.ShowCopyBox("t", nsHC.BuildReport({}))
      nsHC.UpdateBroker()
      nsHC.LauncherTooltip({ AddLine = function() end, AddDoubleLine = function() end })
      for _, cmd in ipairs({ "", "help", "run", "run start x", "run split", "run pause", "run resume", "run stop", "runs",
        "panel compact", "panel full", "panel", "live", "board", "board new leveling", "board mini 1", "board 1", "edit",
        "edit", "track", "track 1 off", "track 1 on", "track 1 history daily 30", "track 1 history off", "windows", "diag",
        "diag mark", "diag probes", "diag snap", "diag", "ledger", "ledger", "nonsense" }) do
        _G.SlashCmdList.HARDCOUNTERS(cmd)
      end
      -- the older per-addon commands still work, as aliases
      _G.SlashCmdList.HCDIAG("")
      _G.SlashCmdList.HCDIAG("mark")
      nsDiag.Refresh()
      if nsFarm.ToggleLedger then
        nsFarm.ToggleLedger()
        nsFarm.RefreshLedger()
        _G.SlashCmdList.HARDCOUNTERS("ledger")
        assert.is_nil(_G.SlashCmdList.HCFARMER)                      -- /hcf went with HC-49
      end
      -- every window opened (each a tab, or its own frame when it can't be one)
      for _, id in ipairs(nsHC.Windows.List()) do
        nsHC.Windows.Show(id, true)
      end
      env:advance(10)
      env:fire("PLAYER_LOGOUT")
      assert.are.same({}, env.errors)
    end)
    -- globals our files read that the fake client doesn't define (Ace's are expected); printed for review
    local names = {}
    for k in pairs(ctx.client.missing) do names[#names + 1] = k end
    table.sort(names)
    print("\n  unknown globals read during the smoke test: " .. table.concat(names, ", "))
  end)

  -- run 2 (2026-11-15): the probe called IsAddOnRestrictionActive() without its type argument and got an error
  -- Character Stats (its repo next to this one): the pack loads, its window lists every section, a section turns
  -- on from the window, and its presets build boards that draw
  it("loads Character Stats: its window, its trackers and presets", function()
    UI.with(function(ctx)
      if not ctx.charstats then return end
      local HC, cs, nsHC = ctx.HC, ctx.stats, ctx.hc
      assert.truthy(cs.STATS and cs.RefreshWindow)
      HC:ShowWindow(cs.WINDOW, true)
      local n = cs.RefreshWindow()
      assert.are.equal(#cs.TRACKERS, n)                              -- all off: one heading each
      HC:SetTrackerOn("hcstats:defence", true)
      assert.is_true(cs.RefreshWindow() > n)
      _G.SlashCmdList.HARDCOUNTERS("stats")
      local M, B = nsHC.BoardModel, nsHC.Boards
      for _, key in ipairs({ "hcstats:caster", "hcstats:melee", "hcstats:hunter", "hcstats:tank" }) do
        local b = M.Create(key)
        B.Refresh(b.id, true)
      end
      assert.are.same({}, ctx.env.errors)
    end)
  end)

  it("probes the add-on restriction check once per restriction type", function()
    local saved = { rawget(_G, "C_RestrictedActions"), rawget(_G, "Enum") }
    local ok, err = pcall(UI.with, function(ctx)
      rawset(_G, "Enum", setmetatable({ AddOnRestrictionType = { Combat = 0, Encounter = 1 } },
        { __index = saved[2] }))
      rawset(_G, "C_RestrictedActions", { IsAddOnRestrictionActive = function(kind)
        if kind == nil then error("Usage: local active = C_RestrictedActions.IsAddOnRestrictionActive(type)") end
        return kind == 1
      end })
      ctx.diag.RunProbes()
      local r = _G.HardCountersDiagDB.probes.funcs["C_RestrictedActions.IsAddOnRestrictionActive"]
      local last = r[#r]
      assert.are.equal("ok", last.status)
      assert.are.equal("Combat=boolean Encounter=boolean:true", last.detail)
    end)
    rawset(_G, "C_RestrictedActions", saved[1])
    rawset(_G, "Enum", saved[2])
    if not ok then error(err, 0) end
  end)

  -- CS-8: UnitDefense is absent on Forever (run 3); do the skill lines list Defence and weapon skills?
  it("probes the skill lines: headers with line counts, Defence's rank types", function()
    local lines = {
      { "Class Skills", true }, { "Holy", false, 5, 5 },
      { "Weapon Skills", true }, { "Maces", false, 40, 60 }, { "Swords", false, 12, 60 },
      { "Defense", false, 55, 60 },
    }
    local saved = { rawget(_G, "GetNumSkillLines"), rawget(_G, "GetSkillLineInfo") }
    local ok, err = pcall(UI.with, function(ctx)
      rawset(_G, "GetNumSkillLines", function() return #lines end)
      rawset(_G, "GetSkillLineInfo", function(i)
        local l = lines[i]
        return l[1], l[2], true, l[3] or 0, 0, 0, l[4] or 0
      end)
      ctx.diag.RunProbes()
      local r = _G.HardCountersDiagDB.probes.funcs["CS-8 skill lines"]
      assert.are.equal("ok", r[#r].status)
      assert.are.equal("n=6 defence=number/number Class Skills(1),Weapon Skills(3)", r[#r].detail)
      rawset(_G, "GetSkillLineInfo", nil)
      ctx.diag.RunProbes()
      r = _G.HardCountersDiagDB.probes.funcs["CS-8 skill lines"]
      assert.are.equal("missing", r[#r].status)
    end)
    rawset(_G, "GetNumSkillLines", saved[1])
    rawset(_G, "GetSkillLineInfo", saved[2])
    if not ok then error(err, 0) end
  end)

  -- CS-8 (b), CS-9, FM-16 (2026-11-19): ratings by index, a scan for skill functions, passing a secret straight
  -- through, the mail calls Farmer reads
  it("probes ratings, skill functions, pass-through of a secret and the mail API", function()
    local names = { "GetCombatRating", "GetCombatRatingBonus", "CR_DEFENSE_SKILL", "GetWeaponSkillRank", "C_Fake",
      "UnitAttackPower", "GetInboxHeaderInfo", "SendMail", "GetSendMailMoney", "GetSendMailPrice", "TakeInboxMoney" }
    local saved = {}
    for _, n in ipairs(names) do saved[n] = rawget(_G, n) end
    local ok, err = pcall(UI.with, function(ctx)
      rawset(_G, "GetCombatRating", function(i) return i == 2 and 15 or 0 end)
      rawset(_G, "GetCombatRatingBonus", function(i) return i == 9 and 1.5 or 0 end)
      rawset(_G, "CR_DEFENSE_SKILL", 2)
      rawset(_G, "GetWeaponSkillRank", function() end)
      rawset(_G, "C_Fake", { GetSkillInfo = function() end, Other = function() end })
      for _, n in ipairs({ "GetInboxHeaderInfo", "SendMail", "GetSendMailMoney", "GetSendMailPrice", "TakeInboxMoney" }) do
        rawset(_G, n, function() end)
      end
      local secret = false
      rawset(_G, "UnitAttackPower", function() return secret and ctx.env:secretValue() or 1200, 0, 0 end)
      ctx.diag.RunProbes()
      local function last(label)
        local r = _G.HardCountersDiagDB.probes.funcs[label]
        return r and r[#r]
      end
      local r = last("CS-8 ratings")
      assert.are.equal("ok", r.status)
      assert.truthy(r.detail:find("nonzero=[2,9]", 1, true))
      assert.truthy(r.detail:find("DEFENSE_SKILL=2", 1, true))
      assert.truthy(r.detail:find("WEAPON_SKILL=nil", 1, true))
      r = last("CS-8 skill functions")
      assert.truthy(r.detail:find("C_Fake.GetSkillInfo", 1, true))
      assert.truthy(r.detail:find("GetWeaponSkillRank", 1, true))
      assert.is_nil(r.detail:find("C_Fake.Other", 1, true))
      r = last("CS-9 pass-through")
      assert.are.equal("not secret now (out of combat?)", r.detail)
      secret = true
      ctx.diag.RunProbes()
      r = last("CS-9 pass-through")
      assert.are.equal("ok", r.status)
      assert.truthy(r.detail:find("SetText=", 1, true))
      assert.truthy(r.detail:find("SetValue=", 1, true))
      r = last("FM-16 mail API")
      assert.are.equal("ok", r.status)
      assert.are.same({}, ctx.env.errors)
    end)
    for _, n in ipairs(names) do rawset(_G, n, saved[n]) end
    if not ok then error(err, 0) end
  end)

  -- TR-1 (Traveler, proposed): the movement sampler keeps counts, never coordinates; the area, achievement and taxi
  -- probes record counts, IDs and types, never names
  it("probes travel: position on taxi, blinks, carried, map changes, combat; area IDs, achievements, taxi nodes", function()
    local names = { "UnitPosition", "UnitOnTaxi", "IsFalling", "GetUnitSpeed", "IsMounted", "IsSwimming", "C_Map",
      "C_MapExplorationInfo", "C_TaxiMap", "GetSubZoneText", "GetZoneText", "GetAchievementNumCriteria",
      "GetAchievementCriteriaInfo", "GetAchievementInfo" }
    local saved = {}
    for _, n in ipairs(names) do saved[n] = rawget(_G, n) end
    local ok, err = pcall(UI.with, function(ctx)
      local env, D = ctx.env, ctx.diag
      local BASE = 4321.25                                  -- a coordinate that must never reach the saved file
      local pos = { BASE, BASE, 0, 0 }
      local taxi, speed, combat, secretPos = false, 7, false, false
      rawset(_G, "UnitPosition", function()
        if secretPos then return env:secretValue(), env:secretValue(), 0, 0 end
        if pos[1] == nil then return nil, nil, nil, 34 end
        return pos[1], pos[2], pos[3], pos[4]
      end)
      rawset(_G, "UnitOnTaxi", function() return taxi end)
      rawset(_G, "IsFalling", function() return false end)
      rawset(_G, "GetUnitSpeed", function() if combat then return env:secretValue() end return speed, 7, 7, 4.7 end)
      rawset(_G, "IsMounted", function() if combat then return env:secretValue() end return false end)
      rawset(_G, "IsSwimming", nil)
      D.B.Wow.inCombat = function() return combat end
      local function step(dx, dt)
        env.t = env.t + (dt or 0.25)
        if pos[1] then pos[1] = pos[1] + (dx or 0) end
        D.TravelTick()
      end
      step(0)                                              -- the first read: a baseline
      step(1.75); step(1.75); step(1.75)                   -- running, 7 yd/s
      taxi = true; step(8); taxi = false                   -- a taxi tick that moves, 32 yd/s
      D.TravelCast("player", "guid", 1953); step(20)       -- a blink right after a plain cast
      speed = 0; step(2); speed = 7                        -- carried: moving at 8 yd/s with your own speed 0
      env.t = env.t + 3; pos[4] = 1; step(0)               -- a continent change 3 s later
      combat = true; step(1.75)
      D.TravelCast("player", "guid", env:secretValue())
      secretPos = true; step(0); secretPos = false
      combat = false; pos[1] = nil; step(0)                -- inside an instance: no position
      local trv = _G.HardCountersDiagDB.probes.travel
      assert.are.equal(1, trv.taxiTicks)
      assert.are.equal(1, trv.taxiMoved)
      assert.are.equal(32, trv.vmaxTaxi)
      assert.are.equal(1, trv.jump_short)
      assert.are.equal(1, trv.jumpSpells["short:1953"])
      assert.are.equal(1, trv.carriedTicks)
      assert.are.equal(1, trv.mapChange)
      assert.are.equal(1, trv.mapChangeAfterCarried)
      assert.are.equal(1, trv.posPlainIn)
      assert.are.equal(1, trv.posSecretIn)
      assert.are.equal(1, trv.posNil)
      assert.are.equal(1, trv.castPlainOut)
      assert.are.equal(1, trv.castSecretIn)
      assert.is_true(trv.zZero > 0)
      assert.is_true(trv.flags.IsMounted.plainOut > 0)
      assert.is_true(trv.flags.IsSwimming.missing > 0)
      -- area IDs: numbers kept, names only compared
      rawset(_G, "C_Map", {
        GetBestMapForUnit = function() return 1429 end,
        GetPlayerMapPosition = function() return { x = 0.4, y = 0.6 } end,
        GetAreaInfo = function(id) return id == 87 and "Goldshire" or "Elwynn Forest" end,
        GetMapInfo = function(m) return m == 1429 and { mapType = 3, parentMapID = 13 } or { mapType = 2 } end,
      })
      rawset(_G, "C_MapExplorationInfo", { GetExploredAreaIDsAtPosition = function() return { 12, 87 } end })
      rawset(_G, "GetSubZoneText", function() return "Goldshire" end)
      rawset(_G, "GetZoneText", function() return "Elwynn Forest" end)
      rawset(_G, "C_TaxiMap", { GetTaxiNodesForMap = function(m)
        if m == 1429 then return { { nodeID = 2, isUndiscovered = false }, { nodeID = 5, isUndiscovered = true } } end
        return { { nodeID = 2 }, { nodeID = 5, isUndiscovered = true }, { nodeID = 9 } }
      end })
      rawset(_G, "GetAchievementNumCriteria", function(id) if id == 776 then return 3 end end)
      rawset(_G, "GetAchievementCriteriaInfo", function(_, i) return "Goldshire", 43, i <= 2, 0, 1 end)
      ctx.diag.RunProbes()
      local function last(label)
        local r = _G.HardCountersDiagDB.probes.funcs[label]
        return r and r[#r]
      end
      local r = last("TR-1 movement")
      assert.are.equal("ok", r.status)
      assert.truthy(r.detail:find("taxi ticks/moved=1/1", 1, true))
      assert.truthy(r.detail:find("short:1953=1", 1, true))
      r = last("TR-1 area IDs")
      assert.are.equal("map=1429 n=2 ids=12,87 subzoneMatch=yes zoneMatch=yes subzoneEmpty=false", r.detail)
      r = last("TR-1 taxi nodes")
      assert.are.equal("zone 1429:n=2 undiscovered=1 nodeID=number; continent 13:n=3 undiscovered=1 nodeID=number",
        r.detail)
      r = last("TR-1 exploration achievements")
      assert.truthy(r.detail:find("776=n:3 done:2 type:43 shape:string,number,boolean,number,number", 1, true))
      assert.truthy(r.detail:find("42=nil", 1, true))
      -- privacy: no coordinate and no name anywhere in what the probes keep
      local function scan(v)
        if type(v) == "number" then assert.is_true(v < 4000, "a coordinate was kept: " .. v)
        elseif type(v) == "string" then
          assert.is_nil(v:find("4321", 1, true))
          assert.is_nil(v:find("Goldshire", 1, true))
          assert.is_nil(v:find("Elwynn", 1, true))
        elseif type(v) == "table" then for k, x in pairs(v) do scan(k); scan(x) end end
      end
      scan(trv)
      for label, h in pairs(_G.HardCountersDiagDB.probes.funcs) do
        if label:find("^TR%-1") then scan(h[#h].detail) end
      end
      assert.are.same({}, env.errors)
    end)
    for _, n in ipairs(names) do rawset(_G, n, saved[n]) end
    if not ok then error(err, 0) end
  end)

  -- TR-5: across loading screens (teleports with their spell, continent numbers), boat ticks aren't blinks, any jump
  -- over 40 yards is long, area answers on zone changes, the flight master's nodes, the Exploration category
  it("probes travel, second round: gaps, carried, contexts, area answers, taxi map, exploration", function()
    local names = { "UnitPosition", "UnitOnTaxi", "GetUnitSpeed", "IsMounted", "IsSwimming", "GetInstanceInfo", "C_Map",
      "C_MapExplorationInfo", "GetSubZoneText", "GetTaxiMapID", "C_TaxiMap", "NumTaxiNodes", "GetCategoryList",
      "GetCategoryInfo", "GetCategoryNumAchievements", "GetAchievementInfo", "GetAchievementNumCriteria",
      "GetAchievementCriteriaInfo" }
    local saved = {}
    for _, n in ipairs(names) do saved[n] = rawget(_G, n) end
    local ok, err = pcall(UI.with, function(ctx)
      local env, D = ctx.env, ctx.diag
      local pos = { 1000, 1000, 0, 0 }
      local speed, inst = 7, 0
      rawset(_G, "UnitPosition", function()
        if pos[1] == nil then return nil, nil, nil, 34 end
        return pos[1], pos[2], pos[3], pos[4]
      end)
      rawset(_G, "UnitOnTaxi", function() return false end)
      rawset(_G, "GetUnitSpeed", function() return speed, 7, 7, 4.7 end)
      rawset(_G, "IsMounted", function() return false end)
      rawset(_G, "IsSwimming", function() return false end)
      rawset(_G, "GetInstanceInfo", function() return "World", "none", 0, "", 0, 0, false, inst end)
      local function step(dx, dt)
        env.t = env.t + (dt or 0.25)
        if pos[1] then pos[1] = pos[1] + (dx or 0) end
        D.TravelTick()
      end
      local trv = _G.HardCountersDiagDB.probes.travel
      assert.are.equal(5, trv.v)
      -- HardCountersDiagDB outlives a boot within one test run (the TR-1 test's counts are in it): wipe in place,
      -- the sampler holds this same table
      for k in pairs(trv) do trv[k] = nil end
      trv.v, trv.flags, trv.jumpSpells, trv.jumpCtx, trv.mapIds, trv.areaAnswers = 5, {}, {}, {}, {}, {}
      step(0); step(1.75)
      D.TravelCast("player", "guid", 8690)                 -- a hearth: the cast ends, then the loading screen
      env.t = env.t + 1
      local x = pos[1]; pos[1] = nil; step(0); step(0)     -- two nil reads
      pos[1] = x + 500; step(0)                            -- same continent, 500 yards on
      assert.are.equal(1, trv.jump_gap)
      assert.are.equal(1, trv.jumpSpells["gap:8690"])
      assert.are.equal(500, trv.gapYdMax)
      assert.are.equal(1, trv.jumpCtx["gap:foot"])
      env.t = env.t + 10
      pos[1] = nil; step(0); pos[1] = 50; pos[4] = 1; inst = 1; step(0)   -- a boat to the other continent
      assert.are.equal(1, trv.mapChangeAcrossGap)
      assert.are.equal(1, trv.mapIds["pos4=1 instance=1"])
      speed = 0; step(9); speed = 7                        -- a boat tick past 8 yards: not a blink
      assert.are.equal(1, trv.jump_shortCarried)
      assert.is_nil(trv.jump_short)
      step(300, 1.0)                                       -- 300 yards over a 1 s gap: long, not a speed
      assert.are.equal(1, trv.jump_long)
      assert.is_true((trv.vmaxOther or 0) < 100)
      -- area answers on zone changes
      rawset(_G, "C_Map", {
        GetBestMapForUnit = function() return 1429 end,
        GetPlayerMapPosition = function() return { x = 0.4, y = 0.6 } end,
        GetAreaInfo = function(id) return id == 87 and "Goldshire" or "Elwynn Forest" end,
        GetMapInfo = function() return { mapType = 3, parentMapID = 13 } end,
      })
      local ids = { 87 }
      rawset(_G, "C_MapExplorationInfo", { GetExploredAreaIDsAtPosition = function() return ids end })
      local subText = "Goldshire"
      rawset(_G, "GetSubZoneText", function() return subText end)
      D.TravelArea()
      ids, subText = nil, ""; D.TravelArea()
      assert.are.equal(1, trv.areaAnswers["match:named"])
      assert.are.equal(1, trv.areaAnswers["nil:unnamed"])
      ids, subText = { 87 }, "Goldshire"
      -- the flight master's map
      rawset(_G, "GetTaxiMapID", function() return 1414 end)
      rawset(_G, "C_TaxiMap", { GetAllTaxiNodes = function(m)
        assert.are.equal(1414, m)
        return { { state = 0 }, { state = 1 }, { state = 1 }, { state = 2 } }
      end })
      rawset(_G, "NumTaxiNodes", function() return 4 end)
      D.TravelTaxiMap()
      assert.are.same({ opens = 1, map = 1414, taxiMapID = true, n = 4, current = 1, reachable = 2, unreachable = 1,
        legacy = 4 }, trv.taxiMap)
      -- the Exploration category
      rawset(_G, "GetCategoryList", function() return { 92, 97, 14777 } end)
      rawset(_G, "GetCategoryInfo", function(id)
        if id == 97 then return "Exploration", -1 elseif id == 14777 then return "Eastern Kingdoms", 97 end
        return "General", -1
      end)
      rawset(_G, "GetCategoryNumAchievements", function(id) return id == 14777 and 2 or 0 end)
      rawset(_G, "GetAchievementInfo", function(_, i) return i == 1 and 776 or 777 end)
      rawset(_G, "GetAchievementNumCriteria", function(id) return id == 776 and 2 or 0 end)
      rawset(_G, "GetAchievementCriteriaInfo", function(_, j)
        return j == 2 and "Goldshire" or "Northshire", 43, true, 0, 1, "", 0, j == 2 and 87 or 9
      end)
      ctx.diag.RunProbes()
      local r = _G.HardCountersDiagDB.probes.funcs["TR-5 exploration"]
      r = r[#r]
      assert.are.equal("ok", r.status)
      assert.are.equal("root=97 achievements=2 Exploration=0 Eastern Kingdoms=2 | area=87 (match) assetMatch=776"
        .. " nameMatch=776", r.detail)
      r = _G.HardCountersDiagDB.probes.funcs["TR-1 movement"]
      assert.truthy(r[#r].detail:find("TR-5: gap jumps=1", 1, true))
      -- privacy: no name kept
      local function scan(v)
        if type(v) == "string" then
          assert.is_nil(v:find("Goldshire", 1, true)); assert.is_nil(v:find("Northshire", 1, true))
        elseif type(v) == "table" then for k, y in pairs(v) do scan(k); scan(y) end end
      end
      scan(trv)
      scan(_G.HardCountersDiagDB.probes.funcs["TR-5 exploration"])
      assert.are.same({}, env.errors)
    end)
    for _, n in ipairs(names) do rawset(_G, n, saved[n]) end
    if not ok then error(err, 0) end
  end)

  -- TR-6: spacebar jumps through the secure hook, falls and their auras, forms, speeds and the casts that change them,
  -- auras in combat, a dungeon (rooms by text, never stored; speed x time), and a death with its corpse run
  it("probes TR-6: jumps, falls, forms, speeds, auras, a dungeon and a death", function()
    local names = { "JumpOrAscendStart", "IsFalling", "UnitPosition", "UnitOnTaxi", "GetUnitSpeed", "IsMounted",
      "IsSwimming", "UnitIsGhost", "GetShapeshiftForm", "GetShapeshiftFormID", "GetShapeshiftFormInfo", "C_UnitAuras",
      "GetInstanceInfo", "GetSubZoneText", "C_Map", "C_MapExplorationInfo", "C_DeathInfo" }
    local saved = {}
    for _, n in ipairs(names) do saved[n] = rawget(_G, n) end
    rawset(_G, "JumpOrAscendStart", function() end)       -- before the boot: the hook is set at login
    local ok, err = pcall(UI.with, function(ctx)
      local env, D = ctx.env, ctx.diag
      local BASE = 4321.25                                  -- coordinates that must never reach the saved file
      local pos = { BASE, BASE, 0, 0 }
      local falling, combat, ghost, inst, form = false, false, false, nil, 0
      local cur, run, sub = 0, 7, ""
      rawset(_G, "UnitPosition", function()
        if inst then return nil, nil, nil, inst end
        return pos[1], pos[2], pos[3], pos[4]
      end)
      rawset(_G, "IsFalling", function() return falling end)
      rawset(_G, "UnitOnTaxi", function() return false end)
      rawset(_G, "IsMounted", function() return false end)
      rawset(_G, "IsSwimming", function() return false end)
      rawset(_G, "UnitIsGhost", function() return ghost end)
      rawset(_G, "GetUnitSpeed", function()
        if combat then return env:secretValue(), env:secretValue(), env:secretValue(), env:secretValue() end
        return cur, run, 4.72, 4.72
      end)
      rawset(_G, "GetShapeshiftForm", function() if combat then return env:secretValue() end return form end)
      rawset(_G, "GetShapeshiftFormID", function() if form == 0 then return nil end return 3 end)
      rawset(_G, "GetShapeshiftFormInfo", function(i) return "icon", true, true, i == 3 and 783 or 0 end)
      rawset(_G, "C_UnitAuras", {
        GetAuraDataByIndex = function(_, i)
          if i > 1 then return nil end
          return { spellId = combat and env:secretValue() or 130 }
        end,
        GetPlayerAuraBySpellID = function(id)
          if combat then return env:secretValue() end
          if id == 2983 or id == 130 then return { spellId = id } end
          return nil
        end,
      })
      rawset(_G, "GetInstanceInfo", function() return "X", inst and "party" or "none", 1, "", 5, 0, false, inst or 0 end)
      rawset(_G, "GetSubZoneText", function() return sub end)
      D.B.Wow.inCombat = function() return combat end
      D.B.Wow.instanceType = function() return inst and "party" or "none" end
      local function step(n, dx)
        for _ = 1, n or 1 do
          env.t = env.t + 0.25
          pos[1] = pos[1] + (dx or 0)
          D.TravelTick()
        end
      end
      local t6 = _G.HardCountersDiagDB.probes.tr6
      assert.are.equal(1, t6.v)
      assert.are.equal("ok", t6.hook)
      for _, v in pairs(t6) do if type(v) == "table" then for k in pairs(v) do v[k] = nil end end end
      step(2)
      -- (c) a spacebar jump: the hooked press, then 0.75 s in the air; a fall of 2.5 s with Slow Fall's aura up
      env:callHook("JumpOrAscendStart")
      assert.are.equal(1, t6.presses.ground)
      falling = true; step(3); falling = false; step(1)
      assert.are.equal(1, t6.takeoffs["press:foot"])
      assert.are.equal(1, t6.air["jump:0.5-1"])
      step(4)
      falling = true; step(10); falling = false; step(1)
      assert.are.equal(1, t6.takeoffs["nopress:foot"])
      assert.are.equal(1, t6.air["fall:2-4"])
      assert.are.equal(1, t6.longFallAuras["130"])
      -- (d) a form, plain out of combat; speeds by state with the auras up; auras and forms in combat
      form = 3; step(16); form = 0
      assert.is_true((t6.forms["idx=3 id=3 spell=783:out"] or 0) > 0)
      local key = "ground:form3 run=7.00 flight=4.72 swim=4.72"
      assert.are.equal(1, t6.speeds[key])
      assert.are.equal("130", t6.speedAuras[key])
      combat = true; step(16); combat = false
      assert.is_true((t6.forms["idx=secret id=nil spell=-:in"] or 0) > 0)
      assert.is_true((t6.speedAnswers.secretIn or 0) > 0)
      assert.are.equal(1, t6.auraIdx["in:table:secretId"])
      assert.are.equal(1, t6.auraById["in:secret"])
      -- §0.3 a dungeon: no position; two rooms by text; speed x time out of combat, secret in a fight
      rawset(_G, "C_Map", { GetBestMapForUnit = function() return nil end })
      inst, cur = 36, 7
      sub = "The Goblin Foundry"; step(4)
      sub = "Mast Room"; step(4)
      combat = true; step(4); combat = false
      local e = t6.inst[36]
      assert.are.equal("party", e.kind)
      assert.are.equal(3, e.ticks)
      assert.are.equal(2, e.rooms)
      assert.are.equal(3, e.named)
      assert.are.equal(1, e.subChanges)
      assert.are.equal(7, e.estYd)
      assert.are.equal(1, e.speedSecretIn)
      assert.is_nil(e.map)
      inst, cur, sub = nil, 0, ""
      step(4)
      -- (a) a death outdoors: the release jump, the ghost's corpse distance (both orders), the end of the corpse run
      env:fire("PLAYER_DEAD")
      step(1, 300)                                         -- the release: 300 yards in one tick
      ghost = true
      env:fire("PLAYER_ALIVE")
      rawset(_G, "C_Map", {
        GetBestMapForUnit = function() return 1429 end,
        GetMapInfo = function() return { mapType = 3, parentMapID = 13 } end,
        GetWorldPosFromMapPos = function() return 0, { x = BASE + 3, y = BASE + 300 } end,
      })
      rawset(_G, "C_DeathInfo", { GetCorpseMapPosition = function() return { x = 0.5, y = 0.5 } end })
      step(4)
      assert.is_true((t6.corpse.plain or 0) > 0)
      ghost = false
      env:fire("PLAYER_UNGHOST")
      local d = t6.deaths[1]
      assert.truthy(d:find("^DEAD:g0 J:long:200%-400 ALIVE:g1 UNGHOST:g0 corpse=400%-800/<8 first=<8$"), d)
      env:fire("PLAYER_ALIVE")                             -- outside a death: counted as stray
      assert.are.equal(1, t6.deathStray["ALIVE:g0"])
      -- (d) Sprint: its aura half a second later and the run speed it changed (out of combat)
      D.TravelCast("player", "guid", 2983)
      run = 9.8
      env:advance(0.5)
      assert.are.equal(1, t6.casts[2983])
      assert.are.equal(1, t6.castWithAura[2983])
      assert.are.equal("7.00>9.80", t6.speedCasts[2983])
      -- the rows
      ctx.diag.RunProbes()
      local function last(label)
        local r = _G.HardCountersDiagDB.probes.funcs[label]
        return r and r[#r]
      end
      local r = last("TR-6 dungeons")
      assert.are.equal("ok", r.status)
      assert.truthy(r.detail:find("inst=36 party ticks=3 fight=1 sub named/empty=3/0 rooms=2 changes=1", 1, true), r.detail)
      r = last("TR-6 jumps")
      assert.truthy(r.detail:find("JumpOrAscendStart=function hook=ok presses[ground=1]", 1, true), r.detail)
      r = last("TR-6 forms and speeds")
      assert.truthy(r.detail:find("speedCasts[2983=7.00>9.80]", 1, true), r.detail)
      r = last("TR-6 deaths")
      assert.truthy(r.detail:find("GetCorpseMapPosition=function", 1, true), r.detail)
      -- privacy: no coordinate and no subzone text anywhere in what the probes keep
      local function scan(v)
        if type(v) == "number" then assert.is_true(v < 4000, "a coordinate was kept: " .. v)
        elseif type(v) == "string" then
          assert.is_nil(v:find("4321", 1, true)); assert.is_nil(v:find("4324", 1, true))
          assert.is_nil(v:find("Goblin", 1, true)); assert.is_nil(v:find("Mast", 1, true))
        elseif type(v) == "table" then for k, x in pairs(v) do scan(k); scan(x) end end
      end
      scan(t6)
      for label, h in pairs(_G.HardCountersDiagDB.probes.funcs) do
        if label:find("^TR%-6") then scan(h[#h].detail) end
      end
      assert.are.same({}, env.errors)
    end)
    for _, n in ipairs(names) do rawset(_G, n, saved[n]) end
    if not ok then error(err, 0) end
  end)

  -- HC-42 (c): do Blizzard's Edit Mode callbacks reach an addon? Counted as they fire, saved at once
  it("probes Edit Mode: EventRegistry's Enter/Exit and the manager frame's show/hide, hooked late", function()
    local savedR, savedM = rawget(_G, "EventRegistry"), rawget(_G, "EditModeManagerFrame")
    local cbs = {}
    rawset(_G, "EventRegistry", { RegisterCallback = function(_, ev, fn) cbs[ev] = fn end })
    rawset(_G, "EditModeManagerFrame", nil)
    local ok, err = pcall(UI.with, function(ctx)
      local function last()
        local r = _G.HardCountersDiagDB.probes.funcs["HC-42 Edit Mode"]
        return r and r[#r]
      end
      assert.is_function(cbs["EditMode.Enter"])
      assert.is_function(cbs["EditMode.Exit"])
      local em = _G.HardCountersDiagDB.probes.editMode
      assert.are.equal("ok", em.reg)
      -- the manager frame shows up later: hooked at the next loading screen's end
      local mgr = _G.CreateFrame("Frame")
      rawset(_G, "EditModeManagerFrame", mgr)
      ctx.env:fire("PLAYER_ENTERING_WORLD", false, true)
      assert.are.equal("ok", em.hook)
      cbs["EditMode.Enter"]()
      mgr:GetScript("OnShow")(mgr)
      cbs["EditMode.Exit"]()
      assert.are.equal(1, em.enter)
      assert.are.equal(1, em.exit)
      assert.are.equal(1, em.show)
      local r = last()
      assert.are.equal("ok", r.status)
      assert.truthy(r.detail:find("registered=ok hooked=ok enter=1 exit=1 show=1 hide=0", 1, true))
      assert.are.same({}, ctx.env.errors)
    end)
    rawset(_G, "EventRegistry", savedR)
    rawset(_G, "EditModeManagerFrame", savedM)
    if not ok then error(err, 0) end
  end)

  it("probes C_SkillInfo: its functions, one entry's shape, headers with counts, Defense's rank (CS-8 b)", function()
    local saved = rawget(_G, "C_SkillInfo")
    local lines = {
      { skillName = "Weapon Skills", isHeader = true }, { skillName = "Bows", skillRank = 100, skillMaxRank = 300 },
      { skillName = "Defense", skillRank = 150, skillMaxRank = 300 },
    }
    local ok, err = pcall(UI.with, function(ctx)
      rawset(_G, "C_SkillInfo", { GetNumSkillLines = function() return #lines end,
        GetSkillLineInfo = function(i) return lines[i] end, ExpandSkillHeader = function() end })
      ctx.diag.RunProbes()
      local r = _G.HardCountersDiagDB.probes.funcs["CS-8 C_SkillInfo"]
      r = r[#r]
      assert.are.equal("ok", r.status)
      assert.truthy(r.detail:find("fns=ExpandSkillHeader,GetNumSkillLines,GetSkillLineInfo", 1, true))
      assert.truthy(r.detail:find("n=3", 1, true))
      assert.truthy(r.detail:find("defence=number/number", 1, true))
      assert.truthy(r.detail:find("Weapon Skills(2)", 1, true))
      assert.truthy(r.detail:find("shape=table{isHeader:boolean skillName:string}", 1, true))
    end)
    rawset(_G, "C_SkillInfo", saved)
    if not ok then error(err, 0) end
  end)

  -- Playtest 2026-11-18: "on" for Gold per hour asked "Turn Gold per hour off? It also stops: ... Gold from %s ..."
  -- and the game's popup, which formats its text with SetFormattedText(text, text_arg1, text_arg2), raised
  -- "bad argument #2 ... (string expected, got nil)".
  it("shows a confirm or prompt with a % in it as plain text", function()
    local saved = rawget(_G, "StaticPopup_Show")
    local shown
    local ok, err = pcall(UI.with, function(ctx)
      rawset(_G, "StaticPopup_Show", function(which, a1, a2)
        shown = string.format(_G.StaticPopupDialogs[which].text, a1, a2)   -- as the game does: errors on a stray %s
      end)
      local HC, B = ctx.HC, ctx.hc.Boards
      local impact = HC:TrackerOffImpact("hc:goldph")
      local list = table.concat(impact.readings, ", ")
      assert.is_truthy(list:find("Gold from ...", 1, true))           -- display titles, not "Gold from %s"
      assert.is_nil(list:find("%", 1, true))
      for _, msg in ipairs({ "Turn Gold per hour off?\nIt also stops: Gold from %s, Spent on %s.", "Delete 50% run?" }) do
        B.Confirm(msg, function() end)
        assert.are.equal(msg, shown)
      end
    end)
    rawset(_G, "StaticPopup_Show", saved)
    if not ok then error(err, 0) end
  end)

  -- HC-55: a board on the session or a calendar scope draws its header (no Pause or Reset), its strip and its menus
  it("draws a board off its timer: the scope once, the session's clock, no Pause or Reset", function()
    UI.with(function(ctx)
      local HC, B, M = ctx.HC, ctx.hc.Boards, ctx.hc.BoardModel
      local b = B.NewBoard("leveling")
      local f = B.Frame(b.id)
      B.BoardMenu(f, b)
      local items = B.ScopeItems(b)
      assert.are.equal(#M.BOARD_SCOPES, #items)
      assert.is_true(items[3].disabled)                               -- today: no history yet
      items[2].func()                                                 -- session
      assert.are.equal("session", M.BoardScope(b))
      local head = f.rowFrames[1]
      assert.are.equal("run", head.row.kind)
      assert.is_false(head.pause:IsShown())
      assert.is_false(head.reset:IsShown())
      assert.are.equal("Leveling \194\183 session", head.name:GetText())
      B.TileMenu(f, b, 1)
      b.mini = true
      B.Refresh(b.id, true)
      f.strip:GetScript("OnClick")(f.strip, "LeftButton")              -- the dot pauses nothing off the timer
      assert.are.equal("session", M.BoardScope(b))
      b.mini = false
      HC:SetTrackerHistory("hc:xpph", "daily")
      HC:SetTrackerHistory("hc:goldph", "daily")
      B.ScopeItems(b)[3].func()                                       -- today
      head = f.rowFrames[1]
      assert.are.equal("Leveling \194\183 today", head.name:GetText())
      assert.are.equal("", head.clock:GetText())
      B.ScopeItems(b)[1].func()                                       -- back on the board's timer
      assert.is_true(f.rowFrames[1].pause:IsShown())
      ctx.hc.Menu.Hide()
      assert.are.same({}, ctx.env.errors)
    end)
  end)
end)
