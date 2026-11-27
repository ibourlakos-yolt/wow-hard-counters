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

  it("opens from the window's Help button on every tab: help and tutorial for the open tab, the full tutorial, the Guide", function()
    UI.with(function(ctx)
      local ns = ctx.hc
      local Help, Win = ns.Help, ns.Windows
      ns.ShowBoards(true)
      local main = Win.Host("_main")
      -- (0.5.0) one Help button; its menu carries the open tab's name, and the tab's one line sits beside it
      assert.are.equal("Help", main.help:GetText())
      assert.is_nil(main.tour)
      assert.is_nil(main.tutorial)
      assert.truthy(main.about:GetText():find("Your boards", 1, true))
      assert.are.equal("boards", Win.Selected())
      local realShow, items = ns.Menu.Show, nil
      ns.Menu.Show = function(_, it) items = it end
      click(main.help)
      ns.Menu.Show = realShow
      local labels = {}
      for i, it in ipairs(items) do labels[i] = it.text end
      assert.are.same({ 'Help for "Boards"', 'Tutorial for "Boards"', "Full tutorial", "Open the Guide" }, labels)
      for _, l in ipairs(labels) do assert.is_nil(l:lower():find("tour", 1, true)) end
      items[1].func()
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
      -- another tab: the menu follows it; a tab's tutorial opens its tab
      ns.ShowExplorer(true)
      items = Win.HelpItems()
      assert.are.equal('Help for "Explorer"', items[1].text)
      items[2].func()
      assert.are.same({ "tour", "explorer", 1 }, { Help.State() })
      _G.SlashCmdList.HARDCOUNTERS("tutorial overview")
      assert.is_true(Win.IsShown("overview"))
      assert.are.same({ "tour", "overview", 1 }, { Help.State() })
      assert.are.equal('Tutorial for "Overview"', Win.HelpItems()[2].text)
      _G.SlashCmdList.HARDCOUNTERS("tour explorer")              -- the old command still answers
      assert.are.same({ "tour", "explorer", 1 }, { Help.State() })
      -- on the Guide, "Open the Guide" is greyed; right-click opens the same menu
      ns.ShowGuide(true)
      assert.is_true(Win.HelpItems()[4].disabled)
      ns.Menu.Show = function(_, it) items = it end
      main.help:GetScript("OnClick")(main.help, "RightButton")
      ns.Menu.Show = realShow
      assert.are.equal('Help for "Guide"', items[1].text)
      if ctx.farmer then
        _G.SlashCmdList.HARDCOUNTERS("tutorial ledger")
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
