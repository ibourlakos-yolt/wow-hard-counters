-- Help and tab tours, the Packs tab, moving a locked board (the user, 2026-11-25).
-- Every tab of the Hard Counters window has a Help page and a tour of its own (UI/Help.lua), registered beside the
-- tab's code. This spec is what keeps them in step with the UI: it fails when a registered window has no help, and
-- when a {name} in a help text (the exact text of a button, menu item or tab) is no longer a string in any Lua file
-- of the addons.
require("bootstrap")
local UI = require("ui_boot")
local F = require("files")

local function click(b) b:GetScript("OnClick")(b) end
local SEEN = { settings = { global = { tutorialSeen = true } } }

--- Every Lua source of the addons, as one string.
local function sources()
  local p = io.popen("find HardCounters HardCounters_Diagnostics packs -name '*.lua' -not -path '*/Libs/*' -not -path '*/tests/*'")
  local out = {}
  for path in p:lines() do out[#out + 1] = F.read(path) end
  p:close()
  return table.concat(out, "\n")
end

describe("help and tab tours", function()
  it("every tab has a Help page and a tour, and every {name} in them is a text the UI still has", function()
    UI.with(function(ctx)
      local ns = ctx.hc
      local Help, Win = ns.Help, ns.Windows
      assert.are.same({}, Help.Missing())
      local src = sources()
      local n = 0
      for _, id in ipairs(Win.List()) do
        local def = Help.For(id)
        assert.is_nil(Help.Check(def), id)
        for _, text in ipairs(Help.Texts(def)) do
          for _, name in ipairs(Help.Names(text)) do
            n = n + 1
            assert.truthy(src:find('"' .. name .. '"', 1, true), id .. ": {" .. name .. "} is not a text in the UI any more")
          end
        end
      end
      assert.is_true(n > 40)
      assert.are.same({}, ctx.env.errors)
    end, SEEN)
  end)

  it("refuses an incomplete definition, and a pack's help for a window it didn't register", function()
    UI.with(function(ctx)
      local ns, HC = ctx.hc, ctx.HC
      local Help = ns.Help
      local ok = { what = "w", can = { "a", "b" }, effect = "e", tour = { { title = "t", text = "x" }, { title = "t", text = "y" } } }
      assert.is_nil(Help.Check(ok))
      assert.truthy(Help.Check({ what = "w", can = { "a" }, effect = "e", tour = ok.tour }))
      assert.truthy(Help.Check({ what = "w", can = ok.can, effect = "e", tour = { ok.tour[1] } }))
      assert.truthy(Help.Check({ can = ok.can, effect = "e", tour = ok.tour }))
      assert.is_false((HC:RegisterWindowHelp("nopack:nowhere", ok)))
      assert.are.same({ "New board...", "+ Tile" }, Help.Names("{New board...} then {+ Tile}"))
      assert.truthy(Help.Render("{Help} me"):find("|cffffd200Help|r me", 1, true))
    end, SEEN)
  end)

  it("opens from the window's header on every tab: <tab> help for the open tab, <tab> tour through its steps", function()
    UI.with(function(ctx)
      local ns = ctx.hc
      local Help, Win = ns.Help, ns.Windows
      ns.ShowBoards(true)
      local main = Win.Host("_main")
      -- (0.4.0) the buttons carry the open tab's name, and its one line sits beside them
      assert.are.equal("Boards help", main.help:GetText())
      assert.are.equal("Boards tour", main.tour:GetText())
      assert.are.equal("Grand tour", main.tutorial:GetText())
      assert.truthy(main.about:GetText():find("Your boards", 1, true))
      assert.are.equal("boards", Win.Selected())
      click(main.help)
      local f = Help.Frame()
      assert.is_true(f:IsShown())
      assert.are.same({ "help", "boards", 1 }, { Help.State() })
      assert.truthy(f.body:GetText():find("What you can do here", 1, true))
      assert.truthy(f.body:GetText():find("How it changes your play", 1, true))
      assert.truthy(f.body:GetText():find("|cffffd200New board...|r", 1, true))
      -- from the Help page into the tour, step by step; Finish closes it
      click(f.act)
      assert.are.same({ "tour", "boards", 1 }, { Help.State() })
      local steps = #Help.For("boards").tour
      assert.are.equal("Step 1 of " .. steps, f.count:GetText())
      for _ = 2, steps do click(f.next) end
      assert.are.equal("Finish", f.next:GetText())
      click(f.back)
      assert.are.equal(steps - 1, (select(3, Help.State())))
      click(f.next)
      click(f.next)
      assert.is_false(f:IsShown())
      -- another tab: the buttons follow it; a tour opens its tab
      ns.ShowExplorer(true)
      assert.are.equal("Explorer help", main.help:GetText())
      click(main.tour)
      assert.are.same({ "tour", "explorer", 1 }, { Help.State() })
      _G.SlashCmdList.HARDCOUNTERS("tour overview")
      assert.is_true(Win.IsShown("overview"))
      assert.are.same({ "tour", "overview", 1 }, { Help.State() })
      assert.are.equal("Overview tour", main.tour:GetText())
      if ctx.farmer then
        _G.SlashCmdList.HARDCOUNTERS("tour ledger")
        assert.are.equal("hcfarm:ledger", (select(2, Help.State())))
      end
      Help.Hide()
      assert.are.same({}, ctx.env.errors)
    end, SEEN)
  end)
end)

describe("the Packs tab", function()
  -- (the window tests run Core/WoW.lua's own adapters over the fake client: the game's AddOn list is stubbed here)
  local function addons(ctx, farmerLoaded)
    local W, env = ctx.hc.wow, ctx.env
    W.packAddons = function() return env.packAddons end
    W.setAddonEnabled = function(name, on)
      env.addonEnabled = env.addonEnabled or {}
      env.addonEnabled[name] = on and true or false
      for _, a in ipairs(env.packAddons) do if a.name == name then a.enabled = on and true or false end end
      return true
    end
    W.reload = function() env.reloads = (env.reloads or 0) + 1 end
    ctx.env.packAddons = {
      { name = "HardCounters_Farmer", title = "Hard Counters: Farmer", notes = "Count what you farm.", enabled = farmerLoaded,
        loaded = farmerLoaded },
      { name = "HardCounters_Traveler", title = "Hard Counters: Traveler", notes = "Count how you travel.", enabled = false,
        loaded = false },
    }
  end

  it("takes a tick as the choice: the game is told at once, a pack to load waits for a reload (0.4.0)", function()
    UI.with(function(ctx)
      if not ctx.farmer then return end
      local ns, HC = ctx.hc, ctx.HC
      local P = ns.Packs
      addons(ctx, false)
      assert.is_false(P.Chosen())                            -- nothing ticked, nothing loaded
      ns.ShowBoards(true)
      local boards = ns.Windows.Content("boards")
      boards:SetSize(720, 440)
      ns.RefreshBoards()
      assert.is_true(boards.notice:IsShown())                -- the Boards tab reminds of the Packs tab
      addons(ctx, true)
      assert.is_true(P.Chosen())                             -- (0.4.0-beta2) a loaded pack is a choice (the AddOns list)
      ns.RefreshBoards()
      assert.is_false(boards.notice:IsShown())               -- and no reminder, though no box was ever ticked
      local list = P.List()
      assert.are.equal("Hard Counters Basic", list[1].title)
      assert.is_true(list[1].builtin)
      assert.are.equal("Farmer", list[2].title)
      assert.is_true(#list[2].trackers > 0)
      assert.are.equal(0, list[2].on)                        -- a pack's trackers are off until chosen
      -- the tab: a row per pack; ticking Traveler too
      ns.ShowPacks(true)
      local f = ns.Windows.Content("packs")
      f:SetSize(762, 568)
      P.Refresh()
      assert.is_true(P.Rows[3]:IsShown())
      assert.truthy(P.Rows[2].state:GetText():find("On", 1, true))
      assert.truthy(P.Rows[3].state:GetText():find("Off", 1, true))
      click(P.Rows[3].check)
      assert.truthy(P.Rows[3].state:GetText():find("after a reload", 1, true))
      -- the tick alone counts (the user, 2026-11-25): the game is told at once and Reload now is offered
      assert.is_true(ctx.env.addonEnabled.HardCounters_Traveler)
      assert.is_true(ns.globalSettings.packsPending.HardCounters_Traveler)
      assert.is_true(f.reload:IsShown())
      assert.is_true(P.Chosen())                             -- (0.4.0) the tick is the choice; no Use these packs
      assert.is_nil(f.apply)
      -- Farmer is loaded, but its trackers wait for a tile of theirs (ns.ActivateTracker)
      for _, t in ipairs(HC:Trackers()) do
        if t.pack == "Farmer" and not t.needsHistory then assert.is_false(t.on) end
      end
      -- Traveler is not: the game is told, the tab asks for a reload and offers it
      assert.is_true(ctx.env.addonEnabled.HardCounters_Traveler)
      assert.is_true(ns.globalSettings.packsPending.HardCounters_Traveler)
      assert.is_true(f.reload:IsShown())
      assert.truthy(f.note:GetText():find("Reload", 1, true))
      assert.truthy(f.history:GetText():find("daily history", 1, true))
      click(f.reload)
      assert.are.equal(1, ctx.env.reloads)
      -- P.Use (the slash path) applies the ticks and leaves trackers alone
      local first = list[2].trackers[1].id
      P.Use()
      assert.is_false(HC:IsTrackerOn(first))
      -- unticking a loaded pack: off for the next load at the click itself, a reload asked; ticking it back undoes it
      click(P.Rows[2].check)
      assert.is_false(ctx.env.addonEnabled.HardCounters_Farmer)
      assert.is_true(f.reload:IsShown())
      assert.truthy(P.Rows[2].state:GetText():find("off after a reload", 1, true))
      click(P.Rows[2].check)
      assert.is_true(ctx.env.addonEnabled.HardCounters_Farmer)
      assert.is_nil(P.Rows[2].state:GetText():find("after a reload", 1, true))   -- (Traveler still waits for one)
      assert.are.same({}, ctx.env.errors)
    end, SEEN)
  end)

  it("reads through (0.5.0 E3): versions, why a pack can't load, a warning before unticking, a row menu, Tools last", function()
    UI.with(function(ctx)
      if not ctx.farmer then return end
      local ns, HC = ctx.hc, ctx.HC
      local P = ns.Packs
      addons(ctx, true)
      local env = ctx.env
      env.packAddons[1].version = HC.VERSION
      env.packAddons[2].version = "0.1.0-alpha1"                -- one of ours, older than Hard Counters
      env.packAddons[#env.packAddons + 1] = { name = "HardCounters_Diagnostics", title = "Hard Counters: Diagnostics",
        notes = "The dev console.", enabled = true, loaded = false, version = HC.VERSION }
      env.packAddons[#env.packAddons + 1] = { name = "HardCounters_Zoo", title = "Hard Counters: Zoo", notes = "Pets.",
        enabled = true, loaded = false, missing = true, reason = "DEP_MISSING", deps = { "HardCounters", "LibPet" },
        needs = { "LibPet" }, version = "1.0" }
      table.sort(env.packAddons, function(a, b) return a.title < b.title end)
      local list = P.List()
      assert.are.equal("Diagnostics", list[#list].title)        -- a tool: last, whatever its name
      assert.is_true(list[#list].tool)
      assert.are.equal(HC.VERSION, list[1].version)             -- Basic is Hard Counters' own
      assert.are.equal(1, P.CompareVersions("0.5.0-beta1", "0.4.0-beta2"))
      assert.are.equal(-1, P.CompareVersions("0.5.0-beta1", "0.5.0"))
      assert.are.equal(-1, P.CompareVersions("0.5.0-alpha1", "0.5.0-beta1"))
      assert.are.equal(0, P.CompareVersions("0.4.0-beta2", "0.4.0-beta2"))
      ns.ShowPacks(true)
      local f = ns.Windows.Content("packs")
      f:SetSize(762, 568)
      P.Refresh()
      assert.truthy(f.intro:GetText():find("Your ticks are for this character.", 1, true))
      local byTitle = {}
      for _, r in ipairs(P.Rows) do if r.pack then byTitle[r.pack.title] = r end end
      assert.truthy(byTitle["Hard Counters Basic"].state:GetText():find("trackers counting", 1, true))
      assert.truthy(byTitle.Farmer.state:GetText():find("trackers counting", 1, true))
      assert.truthy(byTitle.Farmer.title:GetText():find(HC.VERSION, 1, true))
      assert.is_nil(byTitle.Farmer.title:GetText():find("older", 1, true))
      assert.truthy(byTitle.Traveler.title:GetText():find("older than Hard Counters", 1, true))
      assert.is_nil(byTitle.Zoo.title:GetText():find("older", 1, true))        -- another author's: its own version
      assert.truthy(byTitle.Zoo.state:GetText():find("Can't load: needs LibPet", 1, true))
      assert.is_true(f.tools:IsShown())
      -- the row's tooltip has the whole notes and the version
      _G.GameTooltip.lines = {}
      _G.GameTooltip.AddLine = function(self, s) self.lines[#self.lines + 1] = s end
      byTitle.Farmer:GetScript("OnEnter")(byTitle.Farmer)
      local tip = table.concat(_G.GameTooltip.lines, "\n")
      assert.truthy(tip:find("Count what you farm.", 1, true))
      assert.truthy(tip:find("Version " .. HC.VERSION, 1, true))
      -- its menu: right-click or "..."
      local items = P.RowItems(byTitle.Farmer.pack)
      local texts = {}
      for i, it in ipairs(items) do texts[i] = it.text end
      assert.are.same({ "Farmer", "Turn off", "Its trackers", "Its ready-made boards" }, texts)
      assert.is_false(items[3].disabled)
      assert.is_false(items[4].disabled)                        -- the Fishing basket, under Activity
      byTitle.Farmer:GetScript("OnMouseUp")(byTitle.Farmer, "RightButton")
      assert.is_true(ns.Menu.IsShown())
      ns.Menu.Hide()
      items[3].func()                                           -- Its trackers: the Explorer, searched by the pack
      assert.is_true(ns.Windows.IsShown("explorer"))
      assert.are.equal("trackers", ns.ExplorerBrowser.node)
      assert.are.equal("farmer", ns.ExplorerBrowser.search)
      local rows = ns.TrackerCatalog.Rows("trackers", "farmer")
      assert.is_true(#rows > 0)
      for _, r in ipairs(rows) do assert.are.equal("Farmer", r.t.packTitle) end
      items[4].func()
      assert.are.equal("pg:Activity", ns.ExplorerBrowser.node)
      local trav = P.RowItems(byTitle.Traveler.pack)            -- not loaded: its trackers and boards greyed
      assert.is_true(trav[3].disabled)
      assert.is_true(trav[4].disabled)
      ns.ShowPacks(true)
      -- unticking a pack whose readings are on tiles asks first
      local n0 = P.TilesUsing(byTitle.Farmer.pack)
      local b = ns.BoardModel.Create(nil, { name = "Loot" })
      ns.Boards.AddReading(b, "hcfarm:items")
      local n, space = P.TilesUsing(byTitle.Farmer.pack)
      assert.are.equal(n0 + 1, n)
      assert.are.equal("hcfarm", space)
      local asked, answer
      ns.Boards.Confirm = function(text, fn) asked, answer = text, fn end
      click(byTitle.Farmer.check)
      assert.truthy(asked:find(n .. " tiles on your boards use Farmer", 1, true))
      assert.truthy(asked:find("'needs hcfarm'", 1, true))
      assert.is_nil((ctx.env.addonEnabled or {}).HardCounters_Farmer)   -- not yet: the answer decides
      answer()
      assert.is_false(ctx.env.addonEnabled.HardCounters_Farmer)
      assert.are.same({}, ctx.env.errors)
    end, SEEN)
  end)

  it("after the reload, a pack turned on in the tab is noted loaded; its trackers wait for its tiles (0.4.0)", function()
    UI.with(function(ctx)
      if not ctx.farmer then return end
      local ns, HC = ctx.hc, ctx.HC
      addons(ctx, true)
      ctx.env:advance(3)
      local done = ns.Packs.FinishPending()
      local on = 0
      for _, t in ipairs(HC:Trackers()) do if t.pack == "Farmer" and t.on and not t.needsHistory then on = on + 1 end end
      assert.are.equal(0, on)
      -- a tile of Farmer's on a board: its tracker goes on, with daily history
      local b = ns.BoardModel.Create(nil, { name = "Loot" })
      ns.Boards.AddReading(b, "hcfarm:items")
      local r = ns.readings["hcfarm:items"]
      assert.is_true(HC:IsTrackerOn(r.tracker))
      assert.are.equal("daily", HC:GetTracker(r.tracker).history)
      assert.is_true(type(done) == "table")
      assert.is_nil(ns.globalSettings.packsPending.HardCounters_Farmer)
      assert.are.same({}, ctx.env.errors)
    end, { settings = { global = { tutorialSeen = true, packsPending = { HardCounters_Farmer = true } } } })
  end)
end)

describe("a locked board on the HUD", function()
  it("shows Move and Edit tabs at opposite corners on hover, and drags by the Move tab or with the move key held", function()
    UI.with(function(ctx)
      local ns = ctx.hc
      local B, M = ns.Boards, ns.BoardModel
      ns.wow.modifierDown = function(key) return ctx.env.modifier == key end
      local b = M.Store().list[1]
      b.mini = false
      B.Refresh(b.id, true)
      local f = B.Frame(b.id)
      assert.is_true(f:IsShown())
      f.IsMouseOver = function() return true end
      assert.are.equal(1, B.Hover(1))
      assert.is_true(f.handle:IsShown())
      assert.is_true(f.moveHandle:IsShown())
      assert.are.equal("Edit", f.handle.text:GetText())
      assert.are.equal("Move", f.moveHandle.text:GetText())
      assert.are.equal("BOTTOMRIGHT", (f.handle:GetPoint(1)))            -- above the right corner
      assert.are.equal("BOTTOMLEFT", (f.moveHandle:GetPoint(1)))        -- above the left one: never side by side
      -- the Move tab drags the board; the place is saved
      f.moveHandle:GetScript("OnDragStart")(f.moveHandle)
      assert.is_true(f.dragging)
      f.moveHandle:GetScript("OnDragStop")(f.moveHandle)
      assert.is_nil(f.dragging)
      assert.truthy(b.pos)
      -- the move key (Ctrl unless changed): held over the board, the board itself drags; released, click-through again
      assert.are.equal("CTRL", B.MoveKey())
      assert.are.equal("Ctrl", B.MoveKeyWord())
      assert.is_nil(f.moveArmed)
      ctx.env.modifier = "CTRL"
      B.Hover(1)
      assert.is_true(f.moveArmed)
      assert.truthy(f:GetScript("OnDragStart"))
      ctx.env.modifier = nil
      B.Hover(1)
      assert.is_nil(f.moveArmed)
      assert.is_nil(f:GetScript("OnDragStart"))
      -- (the user, 2026-11-25: the board stuck to the cursor) a board that was edited once is redrawn through its
      -- edit chrome: a redraw while it is armed or dragged must leave the drag scripts and the mouse alone
      B.EditBoard(b.id, true)
      B.EditBoard(b.id, false)
      assert.truthy(f.nameBar)
      ctx.env.modifier = "CTRL"
      B.Hover(1)
      assert.is_true(f.moveArmed)
      f:GetScript("OnDragStart")(f)
      assert.is_true(f.dragging)
      B.Refresh(b.id)
      B.Refresh(b.id, true)
      assert.truthy(f:GetScript("OnDragStop"))
      ctx.env.modifier = nil                              -- the key let go before the button: still dragging
      B.Hover(1)
      assert.is_true(f.dragging)
      assert.truthy(f:GetScript("OnDragStop"))
      f:GetScript("OnDragStop")(f)
      assert.is_nil(f.dragging)
      B.Hover(1)
      assert.is_nil(f.moveArmed)
      assert.is_nil(f:GetScript("OnDragStart"))
      -- a drag whose end never arrived: the next poll with the button up ends it
      ctx.env.modifier = "CTRL"
      B.Hover(1)
      f:GetScript("OnDragStart")(f)
      local realDown = _G.IsMouseButtonDown
      _G.IsMouseButtonDown = function() return false end
      B.Hover(1)
      assert.is_nil(f.dragging)
      _G.IsMouseButtonDown = realDown
      ctx.env.modifier = nil
      B.Hover(1)
      -- another key by choice; none at all
      ns.settings.boardMoveKey = "ALT"
      ctx.env.modifier = "SHIFT"
      B.Hover(1)
      assert.is_nil(f.moveArmed)
      ctx.env.modifier = "ALT"
      B.Hover(1)
      assert.is_true(f.moveArmed)
      ns.settings.boardMoveKey = "NONE"
      B.Hover(1)
      assert.is_nil(f.moveArmed)
      assert.is_nil(B.MoveKeyWord())
      -- not while the board is edited: edit mode has its own dragging
      ns.settings.boardMoveKey = "SHIFT"
      ctx.env.modifier = "SHIFT"
      B.EditBoard(b.id, true)
      B.Hover(1)
      assert.is_nil(f.moveArmed)
      assert.is_false(f.moveHandle:IsShown())
      B.EditBoard(b.id, false)
      assert.are.same({}, ctx.env.errors)
    end, SEEN)
  end)
end)
