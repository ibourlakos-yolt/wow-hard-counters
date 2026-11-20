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
