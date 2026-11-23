-- The window host (UI/Windows.lua): windows on their own or as tabs of the shared frame, the visibility contract
-- (content shown exactly while on screen, onShow/onHide on changes), sizes, the run panel's migration and the
-- /hc command root. Under the fake client: it proves the bookkeeping, not how anything looks in game.
local UI = require("ui_boot")

local function counting(extra)
  local def = { title = "T", shows = 0, hides = 0 }
  def.build = function(f) def.content = f end
  def.onShow = function() def.shows = def.shows + 1 end
  def.onHide = function() def.hides = def.hides + 1 end
  for k, v in pairs(extra or {}) do def[k] = v end
  return def
end

local function inList(list, name)
  for _, v in ipairs(list) do if v == name then return true end end
  return false
end

describe("windows", function()
  it("opens every window as a tab, whatever it asks for, calling onShow/onHide only on changes", function()
    UI.with(function(ctx)
      local HC, Win = ctx.HC, ctx.hc.Windows
      local a = counting({ docked = false })            -- the old "on its own" flag: ignored since 2026-11-15
      assert.is_true(HC:RegisterWindow("t:a", a))
      assert.is_false(HC:IsWindowShown("t:a"))
      HC:ShowWindow("t:a", true)
      HC:ShowWindow("t:a", true)                       -- already shown: no second onShow
      assert.is_true(HC:IsWindowShown("t:a"))
      assert.are.equal(1, a.shows)
      assert.is_true(a.content:IsShown())
      local main = Win.Host("_main")
      assert.is_true(main:IsShown())
      assert.is_nil(Win.Host("t:a"))                    -- no frame of its own
      assert.are.equal(main.canvas, a.content:GetParent())     -- (HC-69: on the canvas that scrolls a tall tab)
      assert.are.equal("t:a", ctx.hc.settings.windows._main.selected)
      HC:ToggleWindow("t:a")
      assert.is_false(HC:IsWindowShown("t:a"))
      assert.are.equal(1, a.hides)
      assert.is_false(a.content:IsShown())
      -- there is no way out of the shared frame (HC-49 deleted SetWindowDocked)
      assert.is_nil(HC.SetWindowDocked)
      assert.is_true(Win.IsDocked("t:a"))
      HC:ShowWindow("t:a")
      assert.are.equal(main.canvas, a.content:GetParent())     -- (HC-69: on the canvas that scrolls a tall tab)
      assert.are.equal(2, a.shows)
    end)
  end)

  it("shows one tab at a time and closes them all with the shared frame", function()
    UI.with(function(ctx)
      local HC, Win = ctx.HC, ctx.hc.Windows
      local a, b = counting(), counting()
      HC:RegisterWindow("t:a", a)
      HC:RegisterWindow("t:b", b)
      HC:ShowWindow("t:a", true)
      HC:ShowWindow("t:b", true)
      assert.is_false(HC:IsWindowShown("t:a"))
      assert.is_true(HC:IsWindowShown("t:b"))
      assert.are.equal(1, a.hides)
      local main = Win.Host("_main")
      local shownTabs = 0
      for _, t in ipairs(main.sideTabs) do if t:IsShown() then shownTabs = shownTabs + 1 end end
      assert.is_true(shownTabs >= 2)                    -- pack windows are side tabs (plus diagnostics, ledger, stats)
      main.close._scripts.OnClick()
      assert.is_false(HC:IsWindowShown("t:b"))
      assert.are.equal(1, b.hides)
      -- /hc alone reopens it on the last tab
      _G.SlashCmdList.HARDCOUNTERS("")
      assert.is_true(HC:IsWindowShown("t:b"))
    end)
  end)

  -- run 3 (2026-11-15): every tab popped out left an empty Hard Counters window, and the Dock buttons that would
  -- bring them back didn't draw. The user: remove pop-out.
  it("has no pop-out: windows popped out before come back as tabs, and no Dock or Pop out button exists", function()
    local sv = { profiles = { Default = { windows = {
      trackers = { docked = false, scale = 1 }, runs = { docked = false }, ["hcdiag:console"] = { docked = false },
      ["hcfarm:ledger"] = { docked = false, scale = 1 }, _main = { selected = "runs" },
    } } } }
    UI.with(function(ctx)
      local HC, Win = ctx.HC, ctx.hc.Windows
      for id, c in pairs(ctx.hc.settings.windows) do assert.is_nil(c.docked, id) end   -- the old choice is dropped
      for _, id in ipairs({ "trackers", "runs", "hcdiag:console" }) do
        assert.is_true(Win.IsDocked(id), id)
        HC:ShowWindow(id, true)
        assert.is_true(HC:IsWindowShown(id), id)
        assert.is_nil(Win.Host(id), id)
      end
      local main = Win.Host("_main")
      assert.is_false(main.empty:IsShown())
      assert.is_nil(main.dockBtn)
      local tabs = 0
      for _, t in ipairs(main.tabs) do if t:IsShown() then tabs = tabs + 1 end end
      for _, t in ipairs(main.sideTabs) do if t:IsShown() then tabs = tabs + 1 end end
      assert.is_true(tabs >= 3)
      assert.are.same({}, ctx.env.errors)
    end, { settings = sv })
  end)

  it("enforces minimum sizes, saves the size after the grip, and fixes a height when asked", function()
    UI.with(function(ctx)
      local HC, Win = ctx.HC, ctx.hc.Windows
      local fixed = nil
      local c = counting({ dockable = false, minWidth = 300, minHeight = 200, fixedHeight = function() return fixed end })
      HC:RegisterWindow("t:c", c)
      ctx.hc.Widgets.Conf("t:c").width = 100           -- too small: clamped
      HC:ShowWindow("t:c", true)
      local host = Win.Host("t:c")
      local pw, ph = host.padW, host.padH               -- the chrome around the content
      assert.is_true(pw > 0 and ph > 0)
      assert.are.equal(300 + pw, host:GetWidth())
      assert.are.equal(200 + ph, host:GetHeight())
      host.grip._scripts.OnMouseDown(host.grip, "LeftButton")
      host:SetSize(420 + pw, 330 + ph)                  -- the player drags the grip
      host.grip._scripts.OnMouseUp()
      local saved = ctx.hc.settings.windows["t:c"]
      assert.are.equal(420, saved.width)                -- the content's size is saved
      assert.are.equal(330, saved.height)
      fixed = 90
      Win.Relayout("t:c")
      assert.are.equal(90 + ph, host:GetHeight())
      assert.are.equal(host._bounds[2], host._bounds[4])  -- min height == max height
      fixed = nil
      Win.Relayout("t:c")
      assert.are.equal(330 + ph, host:GetHeight())     -- the saved height is back
      Win.ResetSize("t:c")
      assert.are.equal(300 + pw, host:GetWidth())
    end)
  end)

  it("keeps Escape away from windows that stay up, a frame of their own or the selected tab", function()
    UI.with(function(ctx)
      local HC = ctx.HC
      HC:RegisterWindow("t:e", counting({ dockable = false }))   -- a popup: a frame of its own
      HC:RegisterWindow("t:s", counting({ escape = false }))       -- a tab that stays up
      HC:ShowWindow("t:e", true)
      HC:RegisterWindow("t:hud", counting({ dockable = false, escape = false, chrome = "hud",
        frameName = "HardCountersTestHud" }))
      HC:ShowWindow("t:hud", true)
      assert.is_true(inList(_G.UISpecialFrames, "HardCountersWindow_t_e"))
      assert.is_false(inList(_G.UISpecialFrames, "HardCountersTestHud"))
      HC:ShowWindow("t:s", true)
      assert.is_false(inList(_G.UISpecialFrames, "HardCountersMain"))
      HC:ToggleRunList()                                 -- another tab: Escape closes the frame again
      assert.is_true(inList(_G.UISpecialFrames, "HardCountersMain"))
    end)
  end)

  it("draws Blizzard's panel frame: border, portrait, inset, tabs along the bottom", function()
    UI.with(function(ctx)
      local HC, Win = ctx.HC, ctx.hc.Windows
      HC:RegisterWindow("t:a", counting({ dockable = false }))
      HC:ShowWindow("t:a", true)
      local host = Win.Host("t:a")
      assert.are.equal("ButtonFrameTemplate", host._template)
      assert.is_true(host.panel)
      assert.is_true(host._portraitHidden)               -- a window of its own: no portrait
      assert.are.equal(host.Inset, select(2, host.body:GetPoint(1)))   -- content sits inside the inset
      Win.ShowMain(true)
      local main = Win.Host("_main")
      assert.is_true(main.panel)
      assert.is_nil(main._portraitHidden)                -- the shared frame keeps its portrait (our icon)
      local tab = main.tabs[1]
      assert.are.equal("PanelTabButtonTemplate", tab._template)
      local point, rel, relPoint = tab:GetPoint(1)
      assert.are.same({ "TOPLEFT", main, "BOTTOMLEFT" }, { point, rel, relPoint })
      local selected = 0
      for _, t in ipairs(main.tabs) do if t:IsShown() and t._selected then selected = selected + 1 end end
      assert.are.equal(1, selected)
      -- run 3: the close button was lowered under the template's border art and never drew
      for _, f in ipairs({ host, main }) do
        assert.is_true(f.close:GetFrameLevel() > f.NineSlice:GetFrameLevel())
        assert.is_true(f.close:GetFrameLevel() > f.body:GetFrameLevel())
      end
      assert.are.same({}, ctx.env.errors)
    end)
  end)

  -- HC-59: Blizzard's resize sets the label's width to exactly its string width; in game a label wider than the side
  -- art's minimum then lost its last letters ("Character S...", "Diagnost..."). Labels are left unconstrained.
  it("never pins a tab's label to its exact width, including when the tab shows again (HC-59)", function()
    UI.with(function(ctx)
      local HC, Win = ctx.HC, ctx.hc.Windows
      -- PanelTemplates_TabResize as on the forever branch (1.60.1), without its absolute and maximum sizes
      _G.PanelTemplates_TabResize = function(tab, padding, _, minWidth)
        tab.Text:SetWidth(0)
        local textWidth = tab.Text:GetStringWidth()
        local width = textWidth + 20 + (padding or 0)
        minWidth = minWidth or (tab.Left:GetWidth() + tab.Right:GetWidth())
        if width < minWidth then width = minWidth; textWidth = width - 20 - (padding or 0) end
        tab.Text:SetWidth(textWidth)
        tab:SetWidth(width)
      end
      Win.Register("t:long", counting({ title = "A rather long tab title" }))   -- one of ours: a bottom tab, no icon
      Win.ShowMain(true)
      local main = Win.Host("_main")
      local long
      for _, tab in ipairs(main.tabs) do
        tab.Text.GetStringWidth = function() return 6 * #(tab:GetText() or "") end
        if tab:GetText() == "A rather long tab title" then long = tab end
      end
      HC:ShowWindow("t:long", true)                      -- redraws the tabs, now with the measuring label
      assert.truthy(long)
      assert.are.equal(6 * 23 + 20 + 4, long:GetWidth())  -- Blizzard's width, plus a little room
      for _, tab in ipairs(main.tabs) do
        if tab:IsShown() then assert.are.equal(0, tab.Text:GetWidth(), tab:GetText()) end
      end
      long:Hide()
      long:Show()                                        -- the template's OnShow resizes it again
      assert.are.equal(0, long.Text:GetWidth())
      long:GetScript("OnEvent")(long, "DISPLAY_SIZE_CHANGED")
      assert.are.equal(0, long.Text:GetWidth())
      assert.are.same({}, ctx.env.errors)
    end)
  end)

  it("falls back to its own plain frame on a client without those templates", function()
    UI.with(function(ctx)
      local HC, Win = ctx.HC, ctx.hc.Windows
      Win.ShowMain(true)
      local main = Win.Host("_main")
      assert.is_nil(main.panel)
      assert.truthy(main.bg)
      assert.is_true(#main.tabs > 0)
      HC:ShowWindow("hcdiag:console", true)
      assert.is_true(HC:IsWindowShown("hcdiag:console"))
      assert.are.same({}, ctx.env.errors)
    end, { client = { templates = false } })
  end)

  it("sizes from the top-left corner: the grip pins it there and layout keeps off while it is held", function()
    UI.with(function(ctx)
      local HC, Win = ctx.HC, ctx.hc.Windows
      HC:RegisterWindow("t:g", counting({ dockable = false, minWidth = 200, minHeight = 100 }))
      HC:ShowWindow("t:g", true)
      local host = Win.Host("t:g")
      assert.are.equal("CENTER", (host:GetPoint(1)))      -- placed by its centre the first time
      host._left, host._top = 200, 700
      host.grip._scripts.OnMouseDown(host.grip, "LeftButton")
      assert.are.same({ "TOPLEFT", _G.UIParent, "BOTTOMLEFT", 200, 700 }, { host:GetPoint(1) })
      assert.is_true(host.sizing)
      host:SetSize(640, 480)
      Win.Relayout("t:g")                                -- e.g. a content change mid-drag
      assert.are.equal(640, host:GetWidth())             -- the mouse keeps the size
      host.grip._scripts.OnMouseUp()
      assert.is_nil(host.sizing)
      local c = ctx.hc.settings.windows["t:g"]
      assert.are.same({ "TOPLEFT", 200, 700, "BOTTOMLEFT" }, c.pos)
      assert.are.equal(640 - host.padW, c.width)
      -- a locked window doesn't size
      c.locked = true
      host.grip._scripts.OnMouseDown(host.grip, "LeftButton")
      assert.is_nil(host.sizing)
    end)
  end)

  it("never opens a window of its own bigger than the screen, whatever size was saved", function()
    -- in game the old grip saved the shared window at 1333 x 1151 (2026-11-15)
    local sv = { profiles = { Default = { windows = { ["t:big"] = { width = 1333, height = 1400, scale = 0.9 } } } } }
    UI.with(function(ctx)
      local HC, Win = ctx.HC, ctx.hc.Windows
      HC:RegisterWindow("t:big", counting({ dockable = false }))
      HC:ShowWindow("t:big", true)
      local host = Win.Host("t:big")
      assert.is_true(host:GetWidth() <= math.floor(1920 / 0.9))
      assert.are.equal(math.floor(1080 / 0.9), host:GetHeight())   -- as tall as fits, no taller
      assert.are.equal(1333 + host.padW, host:GetWidth())         -- the width fits: kept
    end, { settings = sv })
  end)

  -- user, 2026-11-23: the Hard Counters window is not resizable
  -- and keeps one size for every tab: one panel, visually consistent
  -- HC-69 (DESIGN §17.2): the size is a design size, 780 x 640; a wider tab widens it, a taller one scrolls inside
  it("keeps the shared frame one size for every tab: the design size, wider for a wide tab, a tall tab scrolls", function()
    local sv = { profiles = { Default = { windows = { _main = { width = 1333, height = 1151, scale = 0.9 } } } } }
    UI.with(function(ctx)
      local HC, Win = ctx.HC, ctx.hc.Windows
      assert.is_nil(ctx.hc.settings.windows._main.width)          -- a dragged size from before is dropped
      assert.is_nil(ctx.hc.settings.windows._main.height)
      HC:ShowWindow("runs", true)
      local main = Win.Host("_main")
      assert.is_nil(main.grip)
      assert.are.same({ 780, 640 }, { main:GetWidth(), main:GetHeight() })
      assert.is_false(main.scrollBar:IsShown())                   -- nothing to scroll
      if ctx.charstats then                                         -- the 640 was chosen so every stat row fits
        HC:ShowWindow("hcstats:window", true)
        assert.is_false(main.scrollBar:IsShown(), "Character Stats fits without scrolling")
        HC:ShowWindow("runs", true)
      end
      HC:RegisterWindow("t:wide", counting({ width = 1000, height = 100, minWidth = 900, minHeight = 50 }))
      HC:RegisterWindow("t:tall", counting({ minWidth = 300, minHeight = 700 }))
      HC:ShowWindow("t:wide", true)
      local w, h = main:GetWidth(), main:GetHeight()
      assert.are.equal(900 + main.padW, w)                          -- the widest minimum: width never scrolls
      assert.are.equal(640, h)                                      -- the height stays the design height
      assert.are.same({ w, h, w, h }, main._bounds)                 -- min == max: the client can't size it either
      for _, id in ipairs({ "t:tall", "trackers", "runs", "hcdiag:console", "t:wide" }) do
        HC:ShowWindow(id, true)
        assert.are.same({ w, h }, { main:GetWidth(), main:GetHeight() }, id)
      end
      -- the tall tab: its canvas is its own height and the body scrolls it; another tab starts at its top
      HC:ShowWindow("t:tall", true)
      local bodyH = h - main.padH
      assert.are.equal(700, main.canvas:GetHeight())
      assert.is_true(main.scrollBar:IsShown())
      assert.are.equal(700 - bodyH, main.scrollMax)
      assert.are.equal(w - main.padW - 16, main.canvas:GetWidth())  -- room for the scroll bar
      main.scroll:GetScript("OnMouseWheel")(main.scroll, -1)
      assert.are.equal(40, main.scrollOff)
      assert.are.equal(40, main.scroll._vscroll)
      main.scroll:GetScript("OnMouseWheel")(main.scroll, -100)
      assert.are.equal(700 - bodyH, main.scrollOff)                -- never past the end
      HC:ShowWindow("runs", true)
      assert.are.equal(0, main.scrollOff)
      assert.is_false(main.scrollBar:IsShown())
      assert.are.equal(bodyH, main.canvas:GetHeight())
      -- even a very tall tab keeps the panel's height
      HC:RegisterWindow("t:huge", counting({ minWidth = 300, minHeight = 3000 }))
      assert.are.equal(640, main:GetHeight())
      assert.are.same({}, ctx.env.errors)
    end, { settings = sv })
  end)

  -- HC-69 (DESIGN §17.2): Hard Counters' own windows along the bottom in a fixed order, packs and Diagnostics as
  -- icon tabs down the right edge (Diagnostics last), the clamp reaching over both, labels as the player chose
  it("puts its own windows along the bottom and packs' down the right edge, with icons and the label option", function()
    UI.with(function(ctx)
      local HC, ns = ctx.HC, ctx.hc
      local Win = ns.Windows
      Win.ShowMain(true)
      local main = Win.Host("_main")
      local function bottomTitles()
        local out = {}
        for _, b in ipairs(main.tabs) do if b:IsShown() then out[#out + 1] = b.hcTitle end end
        return out
      end
      local function sideIds()
        local out = {}
        for _, t in ipairs(main.sideTabs) do if t:IsShown() then out[#out + 1] = t.hcId end end
        return out
      end
      assert.are.same({ "Overview", "Trackers", "Runs" }, bottomTitles())   -- (Overview since HC-67)
      local side = sideIds()
      assert.are.equal("hcdiag:console", side[#side])                -- Diagnostics always last
      if ctx.farmer then assert.truthy(table.concat(side, " "):find("hcfarm:ledger", 1, true)) end
      -- a window of ours sorts by its tabOrder; a pack's window joins the side column
      Win.Register("t:ours", counting({ title = "Ours", tabOrder = 2, icon = "Interface\\Icons\\INV_Misc_Map_01" }))
      HC:RegisterWindow("t:pack", counting({ title = "Pack", icon = 134400 }))
      assert.are.same({ "Overview", "Ours", "Trackers", "Runs" }, bottomTitles())
      side = sideIds()
      assert.are.equal("hcdiag:console", side[#side])
      assert.are.equal("t:pack", side[#side - 1])
      local packTab = main.sideTabs[#side - 1]
      assert.are.equal("LargeSideTabButtonTemplate", packTab._template)
      assert.are.equal("Pack", packTab.tooltipText)
      assert.is_true(packTab._fill)
      -- a click on a side tab (its mouse-up handler) opens that window and checks only its tab
      packTab._onUp(packTab, "LeftButton", true)
      assert.is_true(HC:IsWindowShown("t:pack"))
      assert.is_true(packTab._checked)
      local checked = 0
      for _, t in ipairs(main.sideTabs) do if t._checked then checked = checked + 1 end end
      assert.are.equal(1, checked)
      for _, b in ipairs(main.tabs) do assert.is_false(b._selected and true or false) end
      -- the clamp reaches over the side column and under the bottom tabs (HC-65)
      assert.are.same({ 0, 55, 0, -30 }, main._clamp)
      -- labels: icon and title by default; icon only leaves the title to the tooltip; title only hides the icon
      local trackers
      for _, b in ipairs(main.tabs) do if b.hcTitle == "Trackers" then trackers = b end end
      assert.are.equal("Trackers", trackers:GetText())
      assert.is_true(trackers.hcIcon:IsShown())
      assert.are.equal((16 + 3) / 2, trackers.selectedTextX)
      ns.settings.tabLabels = "icon"
      Win.Show("trackers", true)
      assert.are.equal("", trackers:GetText())
      assert.is_true(trackers.hcIcon:IsShown())
      assert.are.equal(0, trackers.selectedTextX)
      ns.settings.tabLabels = "title"
      Win.Show("trackers", true)
      assert.are.equal("Trackers", trackers:GetText())
      assert.is_false(trackers.hcIcon:IsShown())
      ns.settings.tabLabels = nil
      -- a bad icon is refused
      assert.is_false((HC:RegisterWindow("t:badicon", counting({ icon = {} }))))
      assert.are.same({}, ctx.env.errors)
    end)
  end)

  -- more side tabs than fit beside the frame: arrows and the mouse wheel scroll the column, the selected one shows
  it("scrolls a side column too long for the frame and keeps the selected tab in view", function()
    UI.with(function(ctx)
      local HC, Win = ctx.HC, ctx.hc.Windows
      for i = 1, 14 do HC:RegisterWindow("t:p" .. i, counting({ title = "P" .. i })) end
      HC:ShowWindow("t:p1", true)
      local main = Win.Host("_main")
      local fit = main.sideFit
      assert.is_true(fit < #main.sideList)
      assert.is_true(main.sideArrows:IsShown())
      local shown = 0
      for _, t in ipairs(main.sideTabs) do if t:IsShown() then shown = shown + 1 end end
      assert.are.equal(fit, shown)
      HC:ShowWindow("t:p14", true)                                 -- the selected tab scrolls into view
      local last
      for _, t in ipairs(main.sideTabs) do if t:IsShown() then last = t end end
      assert.are.equal("t:p14", last.hcId)
      main.sideTabs[1]:GetScript("OnMouseWheel")(main.sideTabs[1], 100)   -- back to the top
      assert.are.equal(0, main.sideOff)
      assert.are.same({}, ctx.env.errors)
    end)
  end)

  it("refuses bad window registrations", function()
    UI.with(function(ctx)
      local HC = ctx.HC
      assert.is_false((HC:RegisterWindow("plain", counting())))      -- not namespaced
      assert.is_false((HC:RegisterWindow("t:x", { title = "no build" })))
      assert.is_true((HC:RegisterWindow("t:x", counting())))
      assert.is_false((HC:RegisterWindow("t:x", counting())))         -- taken
      assert.is_true(HC:Supports("windows"))
    end)
  end)
end)

describe("boards on screen", function()
  it("take over the old run panel's settings once: a Run board in its place, compact as mini", function()
    local sv = { profiles = { Default = {
      runPanel = { compact = true, headline = "hcfarm:netph" },
      windows = { runPanel = { shown = true, width = 350, height = 260, scale = 1.2, pos = { "TOP", 10, -20, "TOP" } } },
    } } }
    UI.with(function(ctx)
      local B, M = ctx.hc.Boards, ctx.hc.BoardModel
      local list = M.Store().list
      assert.are.equal("Run", list[1].name)
      assert.is_true(list[1].mini)
      assert.are.equal(350, list[1].width)
      assert.are.equal("Pocket", list[2].name)
      assert.is_false(list[2].shown)
      local f = B.Frame(list[1].id)
      assert.truthy(f)
      assert.is_true(f:IsShown())
      assert.are.equal(1.2, f:GetScale())
      assert.is_true(f.strip:IsShown())                 -- mini: the one-line strip
      -- the hero, named (no value yet: "-"): a fresh strip read "- 0:09" with nothing saying what it counts
      assert.truthy(f.strip.text:GetText():find("Net gold/h|r -", 1, true))
      assert.is_nil(B.Frame(list[2].id) and B.Frame(list[2].id):IsShown() or nil)
      -- /hc panel full: the full board, its height following its tiles
      _G.SlashCmdList.HARDCOUNTERS("panel full")
      assert.is_false(list[1].mini)
      assert.is_false(f.strip:IsShown())
      assert.are.equal(f.fullH, f:GetHeight())
      assert.is_true(#f.rowFrames >= 4)
      _G.SlashCmdList.HARDCOUNTERS("panel")
      assert.is_false(list[1].shown)
      assert.is_false(f:IsShown())
      assert.are.same({}, ctx.env.errors)
    end, { settings = sv })
  end)

  it("show the Pocket board on a fresh install; the Run board's timer runs from its control row", function()
    UI.with(function(ctx)
      local B, M, HC = ctx.hc.Boards, ctx.hc.BoardModel, ctx.HC
      local list = M.Store().list
      assert.are.equal(1, #list)
      assert.are.equal("Pocket", list[1].name)
      assert.is_true(B.Frame(list[1].id):IsShown())
      -- HC-43: boards and their flyouts draw below our windows, whichever was clicked last
      local pocket = B.Frame(list[1].id)
      ctx.hc.Windows.ShowMain()
      assert.are.equal("MEDIUM", _G.HardCountersMain:GetFrameStrata())
      assert.are.equal("LOW", pocket:GetFrameStrata())
      pocket.strip:GetScript("OnEnter")(pocket.strip)  -- the mini board's flyout
      assert.are.equal("LOW", pocket.fly:GetFrameStrata())
      assert.is_true(pocket.fly:GetFrameLevel() > pocket:GetFrameLevel())
      HC:StartRun("first")                             -- a run brings no board with it any more (HC-30)
      assert.are.equal(1, #list)
      HC:StopRun()
      _G.SlashCmdList.HARDCOUNTERS("panel full")
      assert.are.equal(2, #list)
      local board = list[2]
      local run = B.Frame(board.id)
      assert.is_true(run:IsShown())
      assert.are.equal("running", (M.BoardState(board)))   -- its timer started when it was drawn
      assert.are.equal(0.5, run.tickRate)              -- the control row with a clock running: twice a second
      local row = run.rowFrames[1]                     -- drawn by itself: no tile of the board is the control row
      assert.are.equal("run", row.row.kind)
      assert.are.equal("Pause", row.pause:GetText())
      row.pause:GetScript("OnClick")(row.pause)        -- pause the board
      assert.are.equal("paused", (M.BoardState(board)))
      assert.are.equal("Resume", row.pause:GetText())
      assert.are.equal(5, run.tickRate)
      row.reset:GetScript("OnClick")(row.reset)        -- reset: from zero, running
      assert.are.equal("running", (M.BoardState(board)))
      assert.is_nil(B.TimerMenu)                       -- tiles have no timer of their own (HC-41)
      B.BoardMenu(run, board)
      assert.is_true(ctx.hc.Menu.IsShown())
      B.StripMenu(run.strip, board)
      -- Move to: a tile goes to a board of its own, which draws its own control row
      _G.SlashCmdList.HARDCOUNTERS("edit")
      B.TileMenu(run.rowFrames[2], board, 1)
      local n = #board.tiles
      local _, own = M.MoveTo(board, 1, nil)
      B.Refresh(board.id, true)
      B.Reveal(own, own.tiles[1])
      assert.are.equal(n - 1, #board.tiles)
      assert.are.equal("run", B.Frame(own.id).rowFrames[1].row.kind)
      _G.SlashCmdList.HARDCOUNTERS("edit")
      assert.are.same({}, ctx.env.errors)
    end)
  end)

  it("redraw tiles of readings a pack registers after the boards were drawn", function()
    -- the run panel's lesson (2026-11-15): drawn at Hard Counters' load, before Farmer's readings existed
    UI.with(function(ctx)
      local B, M, HC = ctx.hc.Boards, ctx.hc.BoardModel, ctx.HC
      local b = M.Store().list[1]
      b.mini = false
      b.tiles[#b.tiles + 1] = { kind = "reading", reading = "test:late", scope = "session", style = "row" }
      B.Refresh(b.id, true)
      local f = B.Frame(b.id)
      local last = f.rowFrames[#f.rowFrames]
      assert.are.equal("needs test", last.value:GetText())
      HC:RegisterPack("TestLate", { namespace = "test" })
      HC:RegisterReading("test:late", { title = "Late", counter = "hc:money.in", scopes = { "session" } })
      last = f.rowFrames[#f.rowFrames]
      assert.truthy(last.label:GetText():find("^Late"))
      assert.are.same({}, ctx.env.errors)
    end)
  end)

  it("edit mode: outlines, + and menus; locked boards let clicks through", function()
    UI.with(function(ctx)
      local B, M = ctx.hc.Boards, ctx.hc.BoardModel
      local b = M.Store().list[1]
      local f = B.Frame(b.id)
      assert.is_false(f:IsMouseEnabled())
      _G.SlashCmdList.HARDCOUNTERS("edit")
      assert.is_true(B.IsEditing())
      assert.is_true(f:IsMouseEnabled())
      assert.is_true(f.nameBar:IsShown())
      assert.is_false(f.strip:IsShown())                -- a mini board shows its tiles while editing
      B.AddMenu(f.addBtn, b)
      assert.is_true(ctx.hc.Menu.IsShown())
      B.AddReading(b, "hc:gold")
      assert.are.equal("hc:gold", b.tiles[#b.tiles].reading)
      assert.are.equal("run", b.tiles[#b.tiles].scope)   -- the board's timer
      B.TileMenu(f.rowFrames[1], b, 1)
      B.BoardMenu(f.nameBar, b)
      B.StripMenu(f.strip, b)
      B.NewBoardMenu(f)
      -- a reading with a parameter: pick the member, then the tile shows that one (HC-31)
      local picked
      B.MemberMenu(f.addBtn, "hc:goldfrom", function(arg) picked = arg end)
      assert.is_true(ctx.hc.Menu.IsShown())
      B.AddReading(b, "hc:goldfrom", nil, "none")
      local last = b.tiles[#b.tiles]
      assert.are.equal("none", last.arg)
      assert.are.equal("Gold from none", M.TileTitle(last))
      B.TileMenu(f.rowFrames[1], b, #b.tiles)
      -- HC-33: a bar toward a target draws; a write redraws boards on the next frame, at most 4 times a second
      local bar = M.AddReading(b, "hc:xplevel", "bar")
      M.SetTarget(bar, "400")
      B.Refresh(b.id, true)
      local row = f.rowFrames[#f.rowFrames]
      assert.are.equal("bar", row.row.kind)
      assert.truthy(row.value:GetText():find(" / 400", 1, true))
      assert.is_true(row.fill:IsShown())
      ctx.hc.dirty = false
      assert.is_false(B.OnFrame(1))
      ctx.HC:Emit("hc:money.in", 5, "none", 1429)
      assert.is_true(B.OnFrame(1))
      ctx.HC:Emit("hc:money.in", 5, "none", 1429)
      assert.is_false(B.OnFrame(0.1))                   -- too soon
      assert.is_true(B.OnFrame(0.2))
      assert.is_nil(picked)
      _G.SlashCmdList.HARDCOUNTERS("edit")
      assert.is_false(B.IsEditing())
      assert.is_true(f.strip:IsShown())                 -- back to the one-line strip ...
      assert.are.equal(0, #f.rowFrames)                 -- ... with none of the full view's rows left under it
      assert.is_false(f:IsMouseEnabled())
      assert.are.same({}, ctx.env.errors)
    end)
  end)

  -- HC-42 (playtest 2026-11-18, prioritized 2026-11-20): edit a board from the board; the toolbar is gone
  it("edits one board from its hover handle; Done and Escape leave; New board is in the menus", function()
    UI.with(function(ctx)
      local B, M = ctx.hc.Boards, ctx.hc.BoardModel
      local a = M.Store().list[1]
      a.mini = false
      B.Refresh(a.id, true)
      local fa = B.Frame(a.id)
      -- an empty new board opens for editing, on its own
      local b = B.NewBoard(nil)
      local fb = B.Frame(b.id)
      assert.is_true(B.IsEditing(b.id))
      assert.is_false(B.IsEditing(a.id))
      assert.is_true(fb:IsMouseEnabled())
      assert.is_false(fa:IsMouseEnabled())
      assert.is_true(fb.nameBar:IsShown())
      assert.is_true(fb.addBtn:IsShown())
      local esc = _G.HardCountersBoardEdit
      assert.is_true(esc:IsShown())                     -- Escape leaves: an invisible special frame
      assert.is_true(inList(_G.UISpecialFrames, "HardCountersBoardEdit"))
      -- Done on its name bar
      fb.nameBar.done:GetScript("OnClick")(fb.nameBar.done)
      assert.is_false(B.IsEditing())
      assert.is_false(fb:IsMouseEnabled())
      assert.is_false(esc:IsShown())
      -- the cursor over a locked full board shows its handle; its click edits that board only
      fa.IsMouseOver = function() return true end
      assert.are.equal(1, B.Hover(1))
      assert.is_true(fa.handle:IsShown())
      assert.is_nil(fb.handle)
      assert.is_nil(B.Hover(0.01))                      -- polled ten times a second, not every frame
      fa.handle:GetScript("OnClick")(fa.handle)
      assert.is_true(B.IsEditing(a.id))
      assert.is_false(B.IsEditing(b.id))
      assert.is_false(fa.handle:IsShown())              -- no handle on a board being edited
      assert.is_true(fa:IsMouseEnabled())
      assert.is_false(fb:IsMouseEnabled())
      assert.are.equal(0, B.Hover(1))
      -- Escape: the game hides the special frames
      esc:Hide()
      assert.is_false(B.IsEditing())
      assert.is_false(fa:IsMouseEnabled())
      -- the cursor leaves: the handle goes
      assert.are.equal(1, B.Hover(1))
      fa.IsMouseOver = function() return false end
      assert.are.equal(0, B.Hover(1))
      assert.is_false(fa.handle:IsShown())
      -- none in combat, none on a mini board (its strip's menu has "Edit this board")
      fa.IsMouseOver = function() return true end
      ctx.env:fire("PLAYER_REGEN_DISABLED")
      assert.are.equal(0, B.Hover(1))
      ctx.env:fire("PLAYER_REGEN_ENABLED")
      assert.are.equal(1, B.Hover(1))
      a.mini = true
      B.Refresh(a.id, true)
      assert.are.equal(0, B.Hover(1))
      assert.is_false(fa.handle:IsShown())
      -- /hc edit: every board; Done on any one ends it for all
      _G.SlashCmdList.HARDCOUNTERS("edit")
      assert.is_true(B.IsEditing(a.id) and B.IsEditing(b.id))
      fb.nameBar.done:GetScript("OnClick")(fb.nameBar.done)
      assert.is_false(B.IsEditing())
      -- /hc edit while one board is edited leaves edit mode
      B.EditBoard(b.id, true)
      _G.SlashCmdList.HARDCOUNTERS("edit")
      assert.is_false(B.IsEditing())
      -- New board: in the + menu and on the launcher's right-click (presets, then empty)
      local items = B.NewBoardItems()
      assert.are.equal(#M.PRESET_ORDER + 1, #items)
      B.EditBoard(b.id, true)
      B.AddMenu(fb.addBtn, b)
      assert.is_true(ctx.hc.Menu.IsShown())
      ctx.hc.Menu.Hide()
      local launcher = B.LauncherItems()
      assert.are.equal("New board", launcher[1].text)
      assert.are.equal("Stop editing boards", launcher[2].text)
      ctx.hc.LauncherClick("RightButton")
      assert.is_true(ctx.hc.Menu.IsShown())
      ctx.hc.Menu.Hide()
      -- a preset board doesn't open for editing
      local n = #M.Store().list
      local p = B.NewBoard(M.PRESET_ORDER[1])
      assert.are.equal(n + 1, #M.Store().list)
      assert.is_false(B.IsEditing(p.id))
      -- deleting a board being edited leaves its edit mode
      M.Delete(b.id)
      B.RefreshAll()
      assert.is_false(B.IsEditing())
      assert.is_false(esc:IsShown())
      assert.are.same({}, ctx.env.errors)
    end)
  end)

  -- HC-42 (c): Blizzard's Edit Mode, mirroring only (its callbacks reach addons: probe, 2026-11-20)
  it("mirrors Blizzard's Edit Mode: entering edits every board, leaving ends it, on the next frame", function()
    local saved = rawget(_G, "EventRegistry")
    local cbs = {}
    rawset(_G, "EventRegistry", { RegisterCallback = function(_, ev, fn)
      cbs[ev] = cbs[ev] or {}
      cbs[ev][#cbs[ev] + 1] = fn
    end })
    local function fire(ev) for _, fn in ipairs(cbs[ev] or {}) do fn() end end
    local ok, err = pcall(UI.with, function(ctx)
      local B, M = ctx.hc.Boards, ctx.hc.BoardModel
      assert.is_true(B.mirrorsEditMode)
      local trackersOpened = 0
      local show = ctx.hc.ShowTrackers
      ctx.hc.ShowTrackers = function(...) trackersOpened = trackersOpened + 1; return show(...) end
      local b = M.Store().list[1]
      fire("EditMode.Enter")
      assert.is_false(B.IsEditing())                    -- not inside Blizzard's call ...
      ctx.env:advance(0.1)
      assert.is_true(B.IsEditing(b.id))                 -- ... on the next frame
      assert.is_true(B.Frame(b.id):IsMouseEnabled())
      assert.are.equal(0, trackersOpened)               -- Edit Mode has its own panels up
      fire("EditMode.Exit")
      ctx.env:advance(0.1)
      assert.is_false(B.IsEditing())
      assert.is_false(B.Frame(b.id):IsMouseEnabled())
      -- leaving also ends a board edited on its own before
      B.EditBoard(b.id, true)
      fire("EditMode.Enter"); ctx.env:advance(0.1)
      fire("EditMode.Exit"); ctx.env:advance(0.1)
      assert.is_false(B.IsEditing())
      -- /hc edit still opens the Trackers window
      _G.SlashCmdList.HARDCOUNTERS("edit")
      assert.are.equal(1, trackersOpened)
      _G.SlashCmdList.HARDCOUNTERS("edit")
      assert.are.same({}, ctx.env.errors)
    end)
    rawset(_G, "EventRegistry", saved)
    if not ok then error(err, 0) end
  end)

  -- 2026-11-20: a board moved by its name bar snapped back. BlizzMove, registered as draggable, turned the board's
  -- mouse on and hooked SetPoint to put it back where it last dragged it. Boards register as NonDraggable now.
  it("registers boards with BlizzMove as NonDraggable, and they stay click-through", function()
    local saved = rawget(_G, "BlizzMoveAPI")
    local regs = {}
    rawset(_G, "BlizzMoveAPI", { RegisterAddOnFrames = function(_, t)
      for _, frames in pairs(t) do
        for name, data in pairs(frames) do
          regs[name] = data
          if not data.NonDraggable and not data.IgnoreMouse then data.FrameReference:EnableMouse(true) end  -- as BlizzMove does
        end
      end
    end })
    local ok, err = pcall(UI.with, function(ctx)
      local B, M = ctx.hc.Boards, ctx.hc.BoardModel
      local b = M.Store().list[1]
      local f = B.Frame(b.id)
      local data = regs[f:GetName()]
      assert.truthy(data)
      assert.is_true(data.NonDraggable)
      assert.is_nil(data.IgnoreMouseWheel)                -- Ctrl+wheel scaling stays
      assert.is_false(f:IsMouseEnabled())
      local nb = B.NewBoard(M.PRESET_ORDER[1])            -- a board made later: the same
      assert.is_true(regs[B.Frame(nb.id):GetName()].NonDraggable)
      assert.is_false(B.Frame(nb.id):IsMouseEnabled())
      assert.are.same({}, ctx.env.errors)
    end)
    rawset(_G, "BlizzMoveAPI", saved)
    if not ok then error(err, 0) end
  end)
end)

describe("a HUD window opened from a button on the Hard Counters window", function()
  it("stays a window of its own, never a tab", function()
    UI.with(function(ctx)
      local HC, Win = ctx.HC, ctx.hc.Windows
      HC:RegisterWindow("t:hud", { title = "HUD", chrome = "hud", dockable = false, mainButton = "test HUD",
        build = function() end })
      assert.is_false(Win.CanDock("t:hud"))
      assert.is_false(Win.SetDocked("t:hud", true))
      Win.ShowMain(true)
      local b = Win.Host("_main").header["t:hud"]
      assert.truthy(b)
      assert.are.equal("Show test HUD", b:GetText())
      b._scripts.OnClick()
      assert.is_true(Win.IsShown("t:hud"))
      assert.are.equal("Hide test HUD", b:GetText())
      assert.are.equal(0, Win.Host("t:hud").padH)       -- a HUD: no title bar
      assert.is_nil(Win.Host("t:hud").dockBtn)
      b._scripts.OnClick()
      assert.is_false(Win.IsShown("t:hud"))
      assert.are.same({}, ctx.env.errors)
    end)
  end)
end)

describe("/hc command root", function()
  it("takes pack subcommands, refuses taken or bad names, and lists them", function()
    UI.with(function(ctx)
      local HC = ctx.HC
      local got
      assert.is_true(HC:RegisterSlash("hello", function(rest) got = rest end, "say hello", "Test"))
      assert.is_false((HC:RegisterSlash("run", function() end)))
      assert.is_false((HC:RegisterSlash("Bad Name", function() end)))
      assert.is_false((HC:RegisterSlash("nofn")))
      _G.SlashCmdList.HARDCOUNTERS("hello a b")
      assert.are.equal("a b", got)
      _G.SlashCmdList.HARDCOUNTERS("HELLO")
      assert.are.equal("", got)
      if ctx.farmer then
        assert.is_false((HC:RegisterSlash("ledger", function() end)))   -- Farmer's
        _G.SlashCmdList.HARDCOUNTERS("ledger")
        assert.is_true(HC:IsWindowShown("hcfarm:ledger"))
        assert.is_nil(_G.SlashCmdList.HCFARMER)                         -- /hcf went with HC-49
        _G.SlashCmdList.HARDCOUNTERS("ledger")                          -- toggles it off
        assert.is_false(HC:IsWindowShown("hcfarm:ledger"))
      end
      _G.SlashCmdList.HARDCOUNTERS("diag")
      assert.is_true(HC:IsWindowShown("hcdiag:console"))
      assert.are.same({}, ctx.env.errors)
    end)
  end)
end)

describe("the Trackers window", function()
  -- HC-66 (DESIGN §17.3, §17.4): the catalog on the shared browser
  it("shows trackers in a category tree, lists them with columns, details one, and adds a reading as a tile", function()
    UI.with(function(ctx)
      local HC, ns = ctx.HC, ctx.hc
      HC:RegisterPack("TestTrackers", { namespace = "tt", title = "Test pack" })
      HC:RegisterCounter({ id = "tt:c", version = 1 })
      HC:RegisterTracker("tt:big", { title = "Big", category = "Testing", counters = { "tt:c" }, default = "off",
        description = "A tracker for the test." })
      HC:RegisterReading("tt:n", { title = "Big number", tracker = "tt:big", counter = "tt:c", scopes = { "session" } })
      ns.ShowTrackers(true)
      assert.is_true(ns.Windows.IsShown("trackers"))
      local f = ns.Windows.Content("trackers")
      f:SetSize(762, 568)                                -- anchored frames have no real size in the fake client
      ns.RefreshTrackers()
      local br = ns.TrackersBrowser
      local function nodeTexts()
        local out = {}
        for _, r in ipairs(br.tree.rows) do if r:IsShown() then out[#out + 1] = r.text:GetText() end end
        return out
      end
      local function rowWith(pattern)
        for _, r in ipairs(br.list.rows) do
          if r:IsShown() and (r.cells[1]:GetText() or ""):find(pattern) then return r end
        end
      end
      local function actionTexts()
        local out = {}
        for _, b in ipairs(br.actionBtns) do if b:IsShown() then table.insert(out, 1, b:GetText()) end end
        return out
      end
      -- the tree: all, then each category (Basics first), counts beside them
      local nodes = nodeTexts()
      assert.truthy(nodes[1]:find("^All trackers"))
      assert.truthy(nodes[2]:find("^Basics"))
      assert.truthy(table.concat(nodes, "|"):find("Testing", 1, true))
      -- the list: Name, On, History, Size
      assert.are.same({ "Name", "On", "History", "Size" },
        { br.list.heads[1].text:GetText(), br.list.heads[2].text:GetText(), br.list.heads[3].text:GetText(), br.list.heads[4].text:GetText() })
      local gold = rowWith("^Gold per hour")
      assert.truthy(gold)
      assert.truthy(gold.cells[2]:GetText():find("on", 1, true))
      assert.are.equal("Off", gold.cells[3]:GetText())               -- history off
      assert.truthy(br.footer:GetText():find("History on for 0 of"))
      if ctx.farmer then
        local ledger = rowWith("^Ledger")
        assert.truthy(ledger.cells[1]:GetText():find("New"))
        assert.are.equal("needs daily", ledger.cells[3]:GetText())
      end
      -- nothing selected: a hint, and no actions
      assert.truthy(br.detail.text:GetText():find("Click a tracker", 1, true))
      assert.are.same({}, actionTexts())
      -- select Gold per hour: its readings with Add tile, and its actions
      gold:GetScript("OnClick")(gold, "LeftButton")
      assert.are.equal("hc:goldph", br.selected)
      assert.truthy(br.detail.title:GetText():find("^Gold per hour"))
      assert.are.same({ "Turn off", "History...", "Delete data" }, actionTexts())
      local goldItem
      for _, it in ipairs(br.detail.items) do
        if it:IsShown() and (it.text:GetText() or ""):find("^Gold earned ") then goldItem = it end
      end
      assert.truthy(goldItem)                                        -- (HC-51: Gold/h is no row of its own)
      assert.are.equal("Add tile", goldItem.btn:GetText())
      -- HC-36: one board (Pocket on a fresh install): Add tile adds there at once; a hidden board is shown
      local BM = ns.BoardModel
      local board = BM.AddTargets()[1]
      assert.are.equal(1, #BM.AddTargets())
      local n = #board.tiles
      board.shown = false
      goldItem.btn:GetScript("OnClick")(goldItem.btn)
      assert.are.equal(n + 1, #board.tiles)
      assert.are.equal("hc:gold", board.tiles[#board.tiles].reading)
      assert.is_true(board.shown)
      -- several boards: a menu, boards on screen first, hidden ones marked, then "New board"
      local other = BM.Create(nil, { name = "Farm" })
      other.shown = false
      local shownMenu
      local realShow = ns.Menu.Show
      ns.Menu.Show = function(_, items) shownMenu = items end
      goldItem.btn:GetScript("OnClick")(goldItem.btn)
      ns.Menu.Show = realShow
      assert.are.equal(n + 1, #board.tiles)                          -- nothing added before a choice
      assert.are.equal("Farm (hidden)", shownMenu[3].text)
      assert.are.equal("New board", shownMenu[4].text)
      shownMenu[3].func()
      assert.are.equal("hc:gold", other.tiles[#other.tiles].reading)
      -- History...: Keep history, Advanced, Delete history (HC-48)
      local menu
      ns.Menu.Show = function(_, items) menu = type(items) == "function" and items() or items end
      local histBtn
      for _, b in ipairs(br.actionBtns) do if b:IsShown() and b:GetText() == "History..." then histBtn = b end end
      histBtn:GetScript("OnClick")(histBtn)
      ns.Menu.Show = realShow
      assert.are.same({ "History", "Keep history", "Advanced", "Delete history" },
        { menu[1].text, menu[2].text, menu[3].text, menu[4].text })
      menu[2].func()                                                 -- Keep history: on (Daily)
      assert.are.equal("daily", HC:GetTracker("hc:goldph").history)
      assert.truthy(rowWith("^Gold per hour").cells[3]:GetText():find("Daily", 1, true))
      assert.truthy(br.footer:GetText():find("History on for 1 of"))
      -- Turn on: the test tracker is off
      br:Select("tt:big")
      assert.are.same({ "Turn on", "History...", "Delete data" }, actionTexts())
      br.actionBtns[3]:GetScript("OnClick")(br.actionBtns[3])         -- (right to left: Turn on is the last made)
      assert.is_true(HC:GetTracker("tt:big").on)
      -- the tree narrows the list to a category
      local testing
      for _, r in ipairs(br.tree.rows) do if r:IsShown() and r.text:GetText():find("^Testing") then testing = r end end
      testing:GetScript("OnClick")(testing)
      assert.truthy(rowWith("^Big"))
      assert.is_nil(rowWith("^Gold per hour"))
      -- Filters: hide trackers that are on; the button says a filter is on
      br.tree.rows[1]:GetScript("OnClick")(br.tree.rows[1])        -- back to All trackers
      local fmenu
      ns.Menu.Show = function(_, items) fmenu = items end
      br.filterBtn:GetScript("OnClick")(br.filterBtn)
      ns.Menu.Show = realShow
      local items = fmenu()
      assert.are.equal("On", items[2].text)
      items[2].func()
      assert.is_nil(rowWith("^Gold per hour"))
      assert.are.equal("Filters *", br.filterBtn:GetText())
      items = fmenu()
      items[#items].func()                                           -- Show everything
      assert.truthy(rowWith("^Gold per hour"))
      assert.are.equal("Filters", br.filterBtn:GetText())
      -- sort by name, then descending
      br.list.heads[1]:GetScript("OnClick")(br.list.heads[1])
      local first = br.list.rows[1].cells[1]:GetText()
      br.list.heads[1]:GetScript("OnClick")(br.list.heads[1])
      assert.are_not.equal(first, br.list.rows[1].cells[1]:GetText())
      assert.truthy(br.list.heads[1].text:GetText():find(" v$"))
      -- "Not loaded" names data by title and pack, never by id (HC-48), with Delete
      ns.db:RegisterCounter({ id = "hcold:money.out", version = 1, kind = "flow", measures = { "sum" }, grains = { "lifetime" } })
      ns.db:Handle("hcold:money.out"):Add(5)
      ns.RefreshTrackers()
      local unloaded
      for _, r in ipairs(br.tree.rows) do if r:IsShown() and r.text:GetText():find("^Not loaded") then unloaded = r end end
      unloaded:GetScript("OnClick")(unloaded)
      local old = rowWith("^hcold: Money out")
      assert.truthy(old, "named row")
      assert.truthy(old.cells[3]:GetText():find("pack not loaded", 1, true))
      old:GetScript("OnClick")(old, "LeftButton")
      assert.are.same({ "Delete" }, actionTexts())
      -- search: matches tracker titles and the titles of their readings
      br.tree.rows[1]:GetScript("OnClick")(br.tree.rows[1])
      br:SetSearch("xp")
      assert.is_nil(rowWith("^Gold per hour"))
      assert.truthy(rowWith("^XP per hour"))
      br:SetSearch("big number")
      assert.truthy(rowWith("^Big"))
      br:SetSearch("")
      ns.ShowTrackers(false)
      if ctx.farmer then assert.is_false(HC:GetTracker("hcfarm:ledger").new) end   -- seen once shown
      assert.are.same({}, ctx.env.errors)
    end)
  end)
end)

describe("the Trackers tab", function()
  -- 2026-11-15 screenshot: "3 KB, 3 KB frozen" read as 6 KB; the frozen bytes are part of the total
  it("says how much of a tracker's size is frozen without counting it twice", function()
    UI.with(function(ctx)
      local text = ctx.hc.TrackerSizeText
      assert.are.equal("0 KB", text(0, 0))
      assert.are.equal("3 KB", text(3072, 0))
      assert.are.equal("3 KB frozen", text(3072, 3072))
      assert.are.equal("5 KB (3 KB frozen)", text(5120, 3072))
    end)
  end)
end)

-- HC-67 (DESIGN §17.4): the player's tiles, first tab of the window
describe("the Overview tab", function()
  it("shows every tile in its section, on a board or not, and edits, places, moves and deletes them", function()
    UI.with(function(ctx)
      local ns = ctx.hc
      local BM, Bo = ns.BoardModel, ns.Boards
      ns.ShowOverview(true)      -- (a new player lands on it; here the Trackers tab opened once for the packs' New trackers)
      local f = ns.Windows.Content("overview")
      f:SetSize(762, 568)
      ns.RefreshOverview()
      local pocket = BM.Store().list[1]                              -- a fresh install's Pocket board
      -- one card per tile, in the board's section, each knowing where it is
      local all = BM.CollectionTiles()
      assert.are.equal(#pocket.tiles, #all)
      assert.are.same({ "Pocket" }, BM.Sections())
      assert.are.equal(pocket, all[1].board)
      local menus = {}
      local realShow, realConfirm, realAsk = ns.Menu.Show, Bo.Confirm, Bo.AskText
      ns.Menu.Show = function(_, items) menus[#menus + 1] = type(items) == "function" and items() or items end
      Bo.Confirm = function(_, fn) fn() end
      local function menuFor(raw)
        for _, e in ipairs(BM.CollectionTiles()) do
          if e.raw == raw then ns.OverviewCardMenu(f, e); return menus[#menus], e end
        end
      end
      local function pick(m, text)
        for _, it in ipairs(m) do if it.text == text then return it end end
      end
      local gold = all[1].raw
      -- the card menu: Edit (the board's own settings), Move to board, Take off HUD, Section, Delete tile
      local m = menuFor(gold)
      for _, t in ipairs({ "Edit", "Move to board", "Take off HUD", "Section", "Delete tile" }) do assert.truthy(pick(m, t), t) end
      local edit = {}
      for _, it in ipairs(pick(m, "Edit").sub) do edit[#edit + 1] = it.text end
      assert.truthy(table.concat(edit, "|"):find("Scope", 1, true))
      -- take it off the HUD: Window only, the board one tile shorter, still in the collection
      local n = #pocket.tiles
      pick(m, "Take off HUD").func()
      assert.are.equal(n - 1, #pocket.tiles)
      local e
      m, e = menuFor(gold)
      assert.is_nil(e.board)
      assert.are.equal(n, #BM.CollectionTiles())
      assert.is_nil(pick(m, "Take off HUD"))
      for _, it in ipairs(pick(m, "Edit").sub) do assert.are_not.equal("Size", it.text) end   -- a size is the board's
      -- show it on the HUD again
      pick(m, "Show on HUD").sub[1].func()                              -- Pocket
      assert.are.equal(n, #pocket.tiles)
      assert.are.equal(pocket, (BM.BoardOf(gold)))
      -- a new section, then rename it from its title
      m = menuFor(gold)
      Bo.AskText = function(_, _, fn) fn("Farming") end
      local sec = pick(m, "Section").sub
      sec[#sec].func()                                                 -- New section...
      assert.are.equal("Farming", gold.section)
      Bo.AskText = function(_, _, fn) fn("Gold") end
      ns.OverviewSectionMenu(f, "Farming")
      pick(menus[#menus], "Rename section...").func()
      assert.are.equal("Gold", gold.section)
      Bo.AskText = realAsk
      -- Add tile opens Trackers, whose Add tile then adds to Overview, Window only
      f.add:GetScript("OnClick")(f.add)
      assert.is_true(ns.Windows.IsShown("trackers"))
      assert.is_true(ns.TrackersForOverview)
      ns.Windows.Content("trackers"):SetSize(762, 568)
      local br = ns.TrackersBrowser
      br:Select("hc:xpph", "all")
      local item
      for _, it in ipairs(br.detail.items) do if it:IsShown() and it.btn:IsShown() then item = it; break end end
      assert.truthy(item)
      n = #BM.CollectionTiles()
      local onBoard = #pocket.tiles
      item.btn:GetScript("OnClick")(item.btn)
      assert.are.equal(n + 1, #BM.CollectionTiles())
      assert.are.equal(onBoard, #pocket.tiles)                         -- not on a board
      local added = BM.CollectionTiles()[n + 1]
      assert.is_nil(added.board)
      assert.are.equal(BM.DEFAULT_SECTION, added.raw.section)
      ns.ShowOverview(true)
      assert.is_nil(ns.TrackersForOverview)                            -- only until the Trackers tab goes
      -- delete a tile for good
      m = menuFor(added.raw)
      pick(m, "Delete tile").func()
      assert.are.equal(n, #BM.CollectionTiles())
      -- many tiles: the tab grows and the window scrolls it (HC-69)
      for _ = 1, 40 do BM.NewTile("hc:gold") end
      ns.RefreshOverview()
      assert.is_true(ns.Windows.Host("_main").scrollMax > 0)
      -- the search narrows the cards
      f.search:SetText("zzz")
      f.search:GetScript("OnTextChanged")(f.search)
      assert.truthy(f.empty:GetText():find("No tile matches", 1, true))
      ns.Menu.Show, Bo.Confirm = realShow, realConfirm
      assert.are.same({}, ctx.env.errors)
    end)
  end)
end)
