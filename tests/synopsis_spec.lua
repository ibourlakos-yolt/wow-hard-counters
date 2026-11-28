-- 0.5.0 (DESIGN §17.16): how a number is made (G2, G3), the HUD board's Hide tab (C2), its icons (C1), its look and
-- the tile menu's colour and moves (B3 to B6), and the HUD's words (C3).
require("bootstrap")
local UI = require("ui_boot")

local function click(b, button) b:GetScript("OnClick")(b, button or "LeftButton") end

describe("how a number is made", function()
  it("explains a tile line by line: what, from which counters, whose, over when, the number, the tracker", function()
    UI.with(function(ctx)
      local ns = ctx.hc
      local M = ns.BoardModel
      local b = M.Create(nil, { name = "Why", shown = true })
      local t = M.AddReading(b, "hc:gold", { calc = "perHour", size = "large" })
      ctx.env:advance(120)
      ctx.HC:Emit("hc:money.in", 500, "none", 1429)
      local out = M.Explain(t, b)
      local by = {}
      for _, l in ipairs(out) do by[l.label] = by[l.label] or l.text end
      assert.truthy(out.title)
      assert.truthy(by["Counted from"])
      assert.are.equal("this character", by["Whose"])
      assert.truthy(by["Period"]:find("the board's timer", 1, true))
      assert.truthy(by["The number"]:find("an hour", 1, true))
      assert.truthy(by["Tracker"])
      -- an unsettled rate says so, in amber
      local warned = false
      for _, l in ipairs(out) do if l.warn and l.text:find("still swings", 1, true) then warned = true end end
      assert.is_true(warned)
      -- a total and an account tile say what they are
      M.SetCalc(t, "total")
      out = M.Explain(t, b)
      for _, l in ipairs(out) do by[l.label] = l.text end
      assert.truthy(by["The number"]:find("over the period", 1, true))
      assert.are.same({}, ctx.env.errors)
    end)
  end)

  it("opens as a panel from the Boards tab and the Explorer, and as a tooltip on Alt+click on the HUD", function()
    UI.with(function(ctx)
      local ns = ctx.hc
      local B, M, S = ns.Boards, ns.BoardModel, ns.Synopsis
      local b = M.Create(nil, { name = "Click", shown = true })
      local t = M.AddReading(b, "hc:gold", { size = "half" })
      B.Refresh(b.id, true)
      S.Show(B.Frame(b.id), t, b, "panel")
      assert.is_true(S.IsShown("panel"))
      assert.truthy(S.Frame().title:GetText():find("How this number is made", 1, true))
      S.Hide()
      assert.is_false(S.IsShown())
      -- the HUD: Alt (the default) held over a board arms it for clicks; a click on a tile shows the tooltip
      assert.are.equal("ALT", B.InfoKey())
      ns.wow.modifierDown = function(key) return ctx.env.modifier == key end
      local f = B.Frame(b.id)
      f.IsMouseOver = function() return true end
      for _, w in ipairs(f.rowFrames) do w.IsMouseOver = function() return w.row.kind ~= "run" end end
      ctx.env.modifier = "ALT"
      B.Hover(1)
      assert.is_true(f.infoArmed)
      assert.is_true(f:IsMouseEnabled())
      f:GetScript("OnMouseUp")(f, "LeftButton")
      assert.is_true(S.IsShown("tip"))
      assert.are.equal(t, (S.Current()))
      assert.is_true(select(4, S.Current()))                     -- the HUD's: its board's poll may close it
      -- a mouse button down off its board closes it (clients without GLOBAL_MOUSE_DOWN)
      local realDown = _G.IsMouseButtonDown
      _G.IsMouseButtonDown = function() return true end
      f.IsMouseOver = function() return false end
      B.Hover(1)
      assert.is_false(S.IsShown())
      _G.IsMouseButtonDown = realDown
      f.IsMouseOver = function() return true end
      B.Hover(1)                                                 -- back over the board, Alt still held: armed again
      f:GetScript("OnMouseUp")(f, "LeftButton")
      assert.is_true(S.IsShown("tip"))
      -- the end of a move is not a click
      S.Hide()
      f.wasDragged = true
      f:GetScript("OnMouseUp")(f, "LeftButton")
      assert.is_false(S.IsShown())
      -- released: click-through again
      ctx.env.modifier = nil
      B.Hover(1)
      assert.is_nil(f.infoArmed)
      assert.is_false(f:IsMouseEnabled())
      -- off in Options: nothing arms
      ns.settings.boardInfoKey = "NONE"
      ctx.env.modifier = "ALT"
      B.Hover(1)
      assert.is_nil(f.infoArmed)
      assert.are.same({}, ctx.env.errors)
    end)
  end)
end)

describe("a HUD board in 0.5.0", function()
  it("has a Hide tab beside Edit that takes it off the HUD and says how to bring it back", function()
    UI.with(function(ctx)
      local ns = ctx.hc
      local B, M = ns.Boards, ns.BoardModel
      local b = M.Create(nil, { name = "Hideme", shown = true })
      M.AddReading(b, "hc:gold")
      B.Refresh(b.id, true)
      local f = B.Frame(b.id)
      f.IsMouseOver = function() return true end
      B.Hover(1)
      assert.is_true(f.hideHandle:IsShown())
      assert.are.equal("Hide", f.hideHandle.text:GetText())
      local said
      local realPrint = ns.Print
      ns.Print = function(fmt, ...) said = string.format(fmt, ...) end
      click(f.hideHandle)
      ns.Print = realPrint
      assert.is_false(b.shown)
      assert.truthy(said:find("/hc board hideme", 1, true))
      assert.are.same({}, ctx.env.errors)
    end)
  end)

  it("draws Pause and Reset as icons that still name their action, words when the option is off", function()
    UI.with(function(ctx)
      local ns = ctx.hc
      local B, M = ns.Boards, ns.BoardModel
      local b = M.Create(nil, { name = "Icons", shown = true })
      M.AddReading(b, "hc:gold")
      B.Refresh(b.id, true)
      local head = B.Frame(b.id).rowFrames[1]
      assert.are.equal("run", head.row.kind)
      assert.is_true(head.pause.isIcon)
      assert.are.equal("Pause", head.pause:GetText())
      click(head.pause)
      assert.are.equal("Resume", head.pause:GetText())
      ns.settings.boardButtonIcons = false
      B.RefreshAll(true)
      head = B.Frame(b.id).rowFrames[1]
      assert.is_nil(head.pause.isIcon)
      assert.are.equal("Resume", head.pause:GetText())
      assert.are.same({}, ctx.env.errors)
    end)
  end)

  it("has a Look menu, a tile colour, Move to top and bottom, and no 'here' in its menus", function()
    UI.with(function(ctx)
      local ns = ctx.hc
      local B, M = ns.Boards, ns.BoardModel
      local b = M.Create(nil, { name = "Looks", shown = true })
      local spare = M.Create(nil, { name = "Spare" })
      M.AddReading(b, "hc:gold")
      M.AddReading(b, "hc:xpgained")
      B.Refresh(b.id, true)
      local realShow, items = ns.Menu.Show, nil
      ns.Menu.Show = function(_, it) items = it end
      local function pick(list, text) for _, it in ipairs(list) do if it.text == text then return it end end end
      B.BoardMenu(B.Frame(b.id), b)
      local look = pick(items, "Look")
      assert.truthy(look)
      pick(pick(look.sub, "Opacity").sub, "60%").func()
      assert.are.equal(0.6, b.alpha)
      pick(look.sub, "Background opacity").sub[1].func()             -- None
      assert.are.equal(0, b.bgAlpha)
      B.TileMenu(B.Frame(b.id), b, 2)
      local colour = pick(items, "Colour")
      assert.truthy(colour)
      assert.truthy(colour.sub[1].text:find("The board's", 1, true))
      colour.sub[3].func()                                          -- Gold
      assert.are.equal("gold", M.TileColorKey(b.tiles[2]))
      B.TileMenu(B.Frame(b.id), b, 2)
      local move = pick(items, "Move...")                         -- (0.5.0-beta2) the moves in one submenu
      assert.is_nil(pick(items, "Move to top"))
      pick(move.sub, "Move to top").func()
      assert.are.equal("hc:xpgained", b.tiles[1].reading)
      B.TileMenu(B.Frame(b.id), b, 1)
      assert.truthy(pick(items, "Take this tile off the HUD"))
      assert.is_nil(pick(items, "Hide from HUD"))
      local moveTo = pick(pick(items, "Move...").sub, "Move to")
      local spareItem
      for _, it in ipairs(moveTo.sub) do if it.text:find("Spare", 1, true) then spareItem = it end end
      assert.truthy(spareItem.text:find("not on your HUD", 1, true))
      assert.is_nil(spareItem.text:find("here", 1, true))
      ns.Menu.Show = realShow
      local _ = spare
      assert.are.same({}, ctx.env.errors)
    end)
  end)
end)

describe("Ctrl+K in the Hard Counters window (0.5.0, A3)", function()
  it("puts the cursor in the open tab's search box, out of combat, when the option is on", function()
    UI.with(function(ctx)
      local ns = ctx.hc
      ns.ShowExplorer(true, "readings")
      local main = ns.Windows.Host("_main")
      local box = ns.ExplorerBrowser.searchBox
      local focused, passing = 0, nil
      box.SetFocus = function() focused = focused + 1 end
      main.SetPropagateKeyboardInput = function(_, v) passing = v end
      _G.IsControlKeyDown = function() return true end
      assert.truthy(main:GetScript("OnKeyDown"))
      main:GetScript("OnKeyDown")(main, "K")
      assert.are.equal(1, focused)
      assert.is_false(passing)                                     -- this key kept from the game
      main:GetScript("OnKeyDown")(main, "J")                       -- any other key: untouched
      assert.are.equal(1, focused)
      ns.settings.searchKey = false
      main:GetScript("OnKeyDown")(main, "K")
      assert.are.equal(1, focused)
      ns.settings.searchKey = nil
      ns.wow.inCombat = function() return true end                 -- in combat it is the game's
      main:GetScript("OnKeyDown")(main, "K")
      assert.are.equal(1, focused)
      _G.IsControlKeyDown = nil
      assert.are.same({}, ctx.env.errors)
    end)
  end)
end)

-- 0.5.0-beta2, the user: opening Options froze the window ("insecure scripts exceeded execution limit")
describe("the Options tab's container", function()
  it("keeps the tab's size, never sizes itself from its children, and lays out once per real change", function()
    UI.with(function(ctx)
      local ns = ctx.hc
      assert.is_true(ns.ShowOptionsTab(true))
      local c = ns.OptionsContainer()
      assert.truthy(c)
      assert.is_true(c.noAutoHeight)                             -- its children never resize it
      assert.are.equal(1, #ctx.aceOpens)
      local content = ns.Windows.Content("options")
      local layouts = 0
      local realLayout = c.DoLayout
      c.DoLayout = function(self)
        layouts = layouts + 1
        -- a layout that resizes the tab while it runs (what AceGUI's LayoutFinished did): no second layout
        content:GetScript("OnSizeChanged")(content)
        return realLayout and pcall(realLayout, self)
      end
      content:SetSize(701.4, 480.2)
      content:GetScript("OnSizeChanged")(content)
      assert.are.equal(1, layouts)
      assert.are.equal(701, c.hcW)
      content:SetSize(700.6, 480.4)                              -- the same whole size: nothing to do
      content:GetScript("OnSizeChanged")(content)
      assert.are.equal(1, layouts)
      content:SetSize(760, 480)
      content:GetScript("OnSizeChanged")(content)
      assert.are.equal(2, layouts)
      ns.ShowOptionsTab(false)
      assert.is_nil(ns.OptionsContainer())
      assert.is_nil(c.noAutoHeight)                              -- handed back to AceGUI's pool as it was lent
      assert.are.same({}, ctx.env.errors)
    end)
  end)
end)

-- 0.5.0-beta2, the user: "Alt+click on HUD tiles works fine. Change the off-HUD tile behaviour to match it"
describe("a card in the Boards tab", function()
  it("shows how its number is made on Alt+click, as on the HUD; a plain click is its menu; no ? button", function()
    UI.with(function(ctx)
      local ns = ctx.hc
      local S = ns.Synopsis
      ns.ShowBoards(true)
      local content = ns.Windows.Content("boards")
      content:SetSize(760, 560)
      ns.RefreshBoards()
      local card
      for _, c in ipairs(ns.BoardsTabCards()) do if c.entry and c:IsShown() then card = c; break end end
      assert.truthy(card, "a card")
      assert.is_nil(card.why)                                     -- the ? went
      ns.wow.modifierDown = function(key) return ctx.env.modifier == key end
      local realShow, menu = ns.Menu.Show, nil
      ns.Menu.Show = function(_, it) menu = it end
      ctx.env.modifier = "ALT"
      card:GetScript("OnClick")(card, "LeftButton")
      assert.is_true(S.IsShown("tip"))
      assert.is_nil(select(4, S.Current()))                       -- not the HUD's: the HUD's poll leaves it alone
      ns.Boards.Hover(1)
      assert.is_true(S.IsShown("tip"))
      assert.is_nil(menu)
      S.Hide()
      ctx.env.modifier = nil
      card:GetScript("OnClick")(card, "LeftButton")              -- a plain click: the card's menu
      ns.Menu.Show = realShow
      assert.truthy(menu)
      assert.is_false(S.IsShown())
      assert.are.same({}, ctx.env.errors)
    end)
  end)
end)
