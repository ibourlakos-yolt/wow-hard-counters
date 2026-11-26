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
      for _, id in ipairs({ "explorer", "stints", "hcdiag:console" }) do        -- (0.4.0: trackers is in the Explorer)
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
      for _, t in ipairs(main.sideTabs) do if t:IsShown() and t._checked then selected = selected + 1 end end   -- (Overview: a side tab)
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
      HC:RegisterWindow("t:long", counting({ title = "A rather long tab title" }))   -- a pack's: a bottom tab, no icon
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
      HC:ShowWindow("stints", true)
      local main = Win.Host("_main")
      assert.is_nil(main.grip)
      assert.are.same({ 780, 640 }, { main:GetWidth(), main:GetHeight() })
      assert.is_false(main.scrollBar:IsShown())                   -- nothing to scroll
      if ctx.charstats then                                         -- the 640 was chosen so every stat row fits
        HC:ShowWindow("hcstats:window", true)
        assert.is_false(main.scrollBar:IsShown(), "Character Stats fits without scrolling")
        HC:ShowWindow("stints", true)
      end
      HC:RegisterWindow("t:wide", counting({ width = 1000, height = 100, minWidth = 900, minHeight = 50 }))
      HC:RegisterWindow("t:tall", counting({ minWidth = 300, minHeight = 700 }))
      HC:ShowWindow("t:wide", true)
      local w, h = main:GetWidth(), main:GetHeight()
      assert.are.equal(900 + main.padW, w)                          -- the widest minimum: width never scrolls
      assert.are.equal(640, h)                                      -- the height stays the design height
      assert.are.same({ w, h, w, h }, main._bounds)                 -- min == max: the client can't size it either
      for _, id in ipairs({ "t:tall", "trackers", "stints", "hcdiag:console", "t:wide" }) do
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
      HC:ShowWindow("stints", true)
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
  it("puts packs' windows along the bottom and its own down the right edge, with icons and the label option (swapped 2026-11-24)", function()
    UI.with(function(ctx)
      local HC, ns = ctx.HC, ctx.hc
      local Win = ns.Windows
      Win.ShowMain(true)
      local main = Win.Host("_main")
      local function bottomIds()
        local out = {}
        for _, b in ipairs(main.tabs) do if b:IsShown() then out[#out + 1] = b.hcId or b.hcTitle end end
        return out
      end
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
      assert.are.same({ "boards", "explorer", "packs", "stints", "guide" }, sideIds())   -- (0.4.0)
      local bottom = bottomTitles()
      assert.are.equal("Overview", bottom[1])                       -- (0.4.0) Hard Counters' summary first
      assert.are.equal("Options", bottom[#bottom - 1])              -- and Options before Diagnostics
      assert.are.equal("Diagnostics", bottom[#bottom])              -- Diagnostics always last
      if ctx.farmer then assert.truthy(table.concat(bottom, " "):find("Ledger", 1, true)) end
      -- the open tab's name is in the title (its tab is an icon now)
      assert.truthy(main.hcTitleText:find("^Hard Counters: "))
      -- a window of ours sorts by its tabOrder down the side; a pack's window joins the bottom row before Diagnostics
      Win.Register("t:ours", counting({ title = "Ours", tabOrder = 2.7, icon = "Interface\\Icons\\INV_Misc_Map_01" }))
      HC:RegisterWindow("t:pack", counting({ title = "Pack", icon = 134400 }))
      assert.are.same({ "boards", "explorer", "t:ours", "packs", "stints", "guide" }, sideIds())
      bottom = bottomTitles()
      assert.are.equal("Diagnostics", bottom[#bottom])
      assert.are.equal("Options", bottom[#bottom - 1])
      assert.are.equal("Pack", bottom[#bottom - 2])                 -- (a pack's window: after the others, before Options)
      assert.are.same(Win.PackWindows()[#Win.PackWindows()], "hcdiag:console")
      local ours = main.sideTabs[3]                        -- (after Boards and Explorer)
      assert.are.equal("LargeSideTabButtonTemplate", ours._template)
      assert.are.equal("Ours", ours.tooltipText)
      assert.is_true(ours._fill)
      -- a click on a side tab (its mouse-up handler) opens that window and checks only its tab
      ours._onUp(ours, "LeftButton", true)
      assert.is_true(HC:IsWindowShown("t:ours"))
      assert.is_true(ours._checked)
      local checked = 0
      for _, t in ipairs(main.sideTabs) do if t._checked then checked = checked + 1 end end
      assert.are.equal(1, checked)
      for _, b in ipairs(main.tabs) do assert.is_false(b._selected and true or false) end
      assert.are.equal("Hard Counters: Ours", main.hcTitleText)
      -- the clamp reaches over the side column and under the bottom tabs (HC-65)
      assert.are.same({ 0, 55, 0, -30 }, main._clamp)
      -- labels (the bottom tabs): icon and title by default; icon only leaves the title to the tooltip
      local pack
      for _, b in ipairs(main.tabs) do if b.hcTitle == "Pack" then pack = b end end
      assert.are.equal("Pack", pack:GetText())
      assert.is_true(pack.hcIcon:IsShown())
      assert.are.equal((16 + 3) / 2, pack.selectedTextX)
      ns.settings.tabLabels = "icon"
      Win.Show("t:pack", true)
      assert.are.equal("", pack:GetText())
      assert.is_true(pack.hcIcon:IsShown())
      assert.are.equal(0, pack.selectedTextX)
      ns.settings.tabLabels = "title"
      Win.Show("t:pack", true)
      assert.are.equal("Pack", pack:GetText())
      assert.is_false(pack.hcIcon:IsShown())
      ns.settings.tabLabels = nil
      assert.truthy(bottomIds())
      -- a bad icon is refused
      assert.is_false((HC:RegisterWindow("t:badicon", counting({ icon = {} }))))
      assert.are.same({}, ctx.env.errors)
    end)
  end)

  -- more side tabs than fit beside the frame: arrows and the mouse wheel scroll the column, the selected one shows
  it("scrolls a side column too long for the frame and keeps the selected tab in view", function()
    UI.with(function(ctx)
      local HC, Win = ctx.HC, ctx.hc.Windows
      for i = 1, 14 do Win.Register("t:p" .. i, counting({ title = "P" .. i })) end   -- (ours: the side column)
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
      assert.are.equal("Farming", list[1].name)
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
      -- (2026-11-24) "Gold from" is folded into Gold in: the tile moves there, the source as its filter
      assert.are.equal("hc:gold", last.reading)
      assert.are.same({ "none" }, last.arg)
      assert.are.equal("Gold in: Unknown", M.TileTitle(last))
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
      -- New board: the + menu and the launcher open the New board dialog (HC-68); the presets list is kept
      local items = B.NewBoardItems()
      -- (HC-57) a submenu per group of presets, then Empty board
      local listed = 0
      for i = 1, #items - 1 do listed = listed + #items[i].sub end
      assert.are.equal(#M.PRESET_ORDER, listed)
      assert.are.equal("Empty board", items[#items].text)
      B.EditBoard(b.id, true)
      B.AddMenu(fb.addBtn, b)
      assert.is_true(ctx.hc.Menu.IsShown())
      ctx.hc.Menu.Hide()
      local launcher = B.LauncherItems()
      assert.are.same({ "New board...", "Boards tab", "Explorer tab", "Overview tab", "Stop editing boards" },
        { launcher[1].text, launcher[2].text, launcher[3].text, launcher[4].text, launcher[5].text })
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

describe("the Explorer's trackers", function()
  -- HC-66 (DESIGN §17.3, §17.4): the catalog on the shared browser; since 0.4.0 the "What is counted" part of the
  -- Explorer tab (DESIGN §17.15)
  it("shows trackers in a category tree, lists them with columns, details one, and adds a reading as a tile", function()
    UI.with(function(ctx)
      local HC, ns = ctx.HC, ctx.hc
      HC:RegisterPack("TestTrackers", { namespace = "tt", title = "Test pack" })
      HC:RegisterCounter({ id = "tt:c", version = 1 })
      HC:RegisterTracker("tt:big", { title = "Big", category = "Testing", counters = { "tt:c" }, default = "off",
        description = "A tracker for the test." })
      HC:RegisterReading("tt:n", { title = "Big number", tracker = "tt:big", counter = "tt:c", scopes = { "session" } })
      ns.ShowTrackers(true)
      assert.is_true(ns.Windows.IsShown("explorer"))
      assert.is_nil(ns.Windows.Def("trackers"))                -- (0.4.0) no Trackers tab of its own
      local f = ns.Windows.Content("explorer")
      f:SetSize(762, 568)                                -- anchored frames have no real size in the fake client
      ns.RefreshTrackers()
      local br = ns.TrackersBrowser
      assert.are.equal("trackers", br.node)
      local function nodeTexts()
        local out = {}
        for _, r in ipairs(br.tree.rows) do if r:IsShown() then out[#out + 1] = r.text:GetText() end end
        return out
      end
      local function nodeRow(pattern)
        for _, r in ipairs(br.tree.rows) do if r:IsShown() and r.text:GetText():find(pattern) then return r end end
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
      local function pill()
        for _, p in ipairs(br.actionPills) do if p:IsShown() then return p end end
      end
      -- the tree: the Trackers node (scrolled into view), then each category, counts beside them
      local nodes = table.concat(nodeTexts(), "|")
      assert.truthy(nodes:find("Trackers", 1, true))
      assert.truthy(nodes:find("Testing", 1, true))
      assert.truthy(nodes:find("WHAT IS COUNTED", 1, true))   -- (a caption)
      -- the list: Name, On, History, Size
      assert.are.same({ "Name", "On", "History", "Size" },
        { br.list.heads[1].text:GetText(), br.list.heads[2].text:GetText(), br.list.heads[3].text:GetText(), br.list.heads[4].text:GetText() })
      local gold = rowWith("^Gold")
      assert.truthy(gold)
      assert.truthy(gold.cells[2]:GetText():find("on", 1, true))
      -- (0.4.0) the Pocket board's tiles read Gold: its history went on at the login, Daily with the default days
      assert.truthy(gold.cells[3]:GetText():find("Daily", 1, true))
      assert.truthy(br.footer:GetText():find("History on for", 1, true))
      if ctx.farmer then
        local ledger = rowWith("^Ledger")
        assert.truthy(ledger.cells[1]:GetText():find("New"))
        assert.are.equal("needs daily", ledger.cells[3]:GetText())
      end
      -- nothing selected: a hint, and no actions
      assert.truthy(br.detail.text:GetText():find("Click a row", 1, true))
      assert.are.same({}, actionTexts())
      -- select Gold: its readings with Add tile, and its actions: the Counting switch (a pill), History..., More...
      gold:GetScript("OnClick")(gold, "LeftButton")
      assert.are.equal("hc:goldph", br.selected)
      assert.truthy(br.detail.title:GetText():find("^Gold"))
      assert.are.same({ "History..." }, actionTexts())
      assert.are.equal("Counting", pill():GetText())
      assert.is_true(br.moreBtn:IsShown())                     -- (Delete data is under More...)
      local goldItem
      for _, it in ipairs(br.detail.items) do
        if it:IsShown() and (it.text:GetText() or ""):find("^Gold in ") then goldItem = it end
      end
      assert.truthy(goldItem)                                        -- (HC-51: Gold/h is no row of its own)
      assert.are.equal("Add tile", goldItem.btn:GetText())
      -- HC-36: one board (Pocket on a fresh install): Add tile adds there at once; a board that is Only here stays so (v8)
      local BM = ns.BoardModel
      local board = BM.AddTargets()[1]
      assert.are.equal(1, #BM.AddTargets())
      local n = #board.tiles
      board.shown = false
      goldItem.btn:GetScript("OnClick")(goldItem.btn)
      assert.are.equal(n + 1, #board.tiles)
      assert.are.equal("hc:gold", board.tiles[#board.tiles].reading)
      assert.is_false(board.shown)
      board.shown = true
      -- several boards: a menu, boards on screen first, hidden ones marked, then "New board"
      local other = BM.Create(nil, { name = "Farm" })
      other.shown = false
      local shownMenu
      local realShow = ns.Menu.Show
      ns.Menu.Show = function(_, items) shownMenu = items end
      goldItem.btn:GetScript("OnClick")(goldItem.btn)
      ns.Menu.Show = realShow
      assert.are.equal(n + 1, #board.tiles)                          -- nothing added before a choice
      assert.are.equal("Farm (Only here)", shownMenu[3].text)
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
      menu[2].func()                                                 -- Keep history: off (it was on)
      assert.are.equal("off", HC:GetTracker("hc:goldph").history)
      assert.are.equal("Off", rowWith("^Gold").cells[3]:GetText())
      -- the Counting switch: the test tracker is off
      br:Select("tt:big")
      assert.are.equal("Not counting", pill():GetText())
      pill():GetScript("OnClick")(pill())
      assert.is_true(HC:GetTracker("tt:big").on)
      -- the tree narrows the list to a category
      nodeRow("^Testing"):GetScript("OnClick")(nodeRow("^Testing"))
      assert.truthy(rowWith("^Big"))
      assert.is_nil(rowWith("^Gold"))
      -- Filters: hide trackers that are on; the button says a filter is on
      nodeRow("^Trackers"):GetScript("OnClick")(nodeRow("^Trackers"))       -- back to every tracker
      local fmenu
      ns.Menu.Show = function(_, items) fmenu = items end
      br.filterBtn:GetScript("OnClick")(br.filterBtn)
      ns.Menu.Show = realShow
      local items = fmenu()
      assert.are.equal("On", items[2].text)
      items[2].func()
      assert.is_nil(rowWith("^Gold"))
      assert.are.equal("Filters *", br.filterBtn:GetText())
      items = fmenu()
      items[#items].func()                                           -- Show everything
      assert.truthy(rowWith("^Gold"))
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
      local unloaded = nodeRow("^Not loaded")
      unloaded:GetScript("OnClick")(unloaded)
      local old = rowWith("^hcold: Money out")
      assert.truthy(old, "named row")
      assert.truthy(old.cells[3]:GetText():find("pack not loaded", 1, true))
      old:GetScript("OnClick")(old, "LeftButton")
      assert.are.same({ "Delete" }, actionTexts())
      -- search: matches tracker titles and the titles of their readings
      nodeRow("^Trackers"):GetScript("OnClick")(nodeRow("^Trackers"))
      br:SetSearch("xp")
      assert.is_nil(rowWith("^Gold"))
      assert.truthy(rowWith("^Experience"))
      br:SetSearch("big number")
      assert.truthy(rowWith("^Big"))
      br:SetSearch("")
      ns.ShowExplorer(false)
      if ctx.farmer then assert.is_false(HC:GetTracker("hcfarm:ledger").new) end   -- seen once shown
      assert.are.same({}, ctx.env.errors)
    end)
  end)

  it("lists tiles, readings and displays, each with its own columns and actions; the splitter moves and is saved", function()
    UI.with(function(ctx)
      local ns = ctx.hc
      ns.ShowExplorer(true, "tiles")
      local f = ns.Windows.Content("explorer")
      f:SetSize(762, 568)
      local br = ns.ExplorerBrowser
      br:Refresh()
      assert.are.equal("Board", br.list.heads[2].text:GetText())
      local row = br.rowsData[1]
      assert.truthy(row and row.entry)                              -- the Pocket board's tiles
      br:Select(row.key)
      local acts = {}
      for _, b in ipairs(br.actionBtns) do if b:IsShown() then acts[#acts + 1] = b:GetText() end end
      assert.truthy(table.concat(acts, "|"):find("Edit...", 1, true))
      ns.ShowExplorer(true, "readings")
      assert.are.equal("Tracker", br.list.heads[2].text:GetText())
      assert.is_true(#br.rowsData > 5)
      ns.ShowExplorer(true, "displays")
      assert.are.equal(5, #br.rowsData)
      br:Select("d:bar")
      assert.truthy(br.detail.title:GetText():find("Bar", 1, true))
      -- the splitter: more room for the details, saved per window; double-click puts it back
      local before = br.detailH
      br:SetDetailHeight(before + 40)
      assert.are.equal(before + 40, ns.Widgets.Conf("explorer").detailH)
      br.splitter:GetScript("OnDoubleClick")(br.splitter)
      assert.is_nil(ns.Widgets.Conf("explorer").detailH)
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
describe("the Boards tab (the Overview before 0.4.0)", function()
  it("shows every board with its tiles, puts boards and tiles on or off the HUD, and makes, moves and deletes them", function()
    UI.with(function(ctx)
      local ns = ctx.hc
      local BM, Bo = ns.BoardModel, ns.Boards
      ns.ShowBoards(true)        -- (a new player lands on it; here the Explorer opened once for the packs' New trackers)
      local f = ns.Windows.Content("boards")
      f:SetSize(762, 568)
      ns.RefreshBoards()
      local pocket = BM.Store().list[1]                              -- a fresh install's Pocket board
      -- (HC-73) one framed panel per board, its cards filled; (v8) no "Window only" section
      local all = BM.CollectionTiles()
      assert.are.equal(#pocket.tiles, #all)
      assert.are.equal(pocket, all[1].board)
      local panel = ns.BoardsPanels[1]
      assert.is_true(panel:IsShown())
      assert.are.equal(pocket, panel.head.board)
      assert.are.equal("Pocket", panel.head.text:GetText())
      assert.truthy(panel.head.note:GetText():find("On HUD", 1, true))   -- its status, coloured as in the Boards tab
      assert.are.equal(#pocket.tiles .. " tiles", panel.count:GetText())
      assert.is_false(panel.empty:IsShown())
      assert.is_false(panel.info:IsShown())
      assert.is_nil(f.loose)
      local shownCards = 0
      for _, c in ipairs(ns.BoardsCards) do
        if c:IsShown() then
          shownCards = shownCards + 1
          assert.is_false(c.dashed)
          assert.are.equal("board timer", c.foot:GetText())         -- the scope
        end
      end
      assert.are.equal(#pocket.tiles, shownCards)
      -- the board's HUD switch: its text says where the board is; a click takes it off the HUD and back
      local bf = Bo.Frame(pocket.id)
      assert.are.equal("On HUD", panel.hud:GetText())
      assert.is_true(bf:IsShown())
      panel.hud:GetScript("OnClick")(panel.hud)
      assert.is_false(pocket.shown)
      assert.is_false(bf:IsShown())
      assert.are.equal("Only here", panel.hud:GetText())
      assert.truthy(panel.head.note:GetText():find("Only here", 1, true))
      panel.hud:GetScript("OnClick")(panel.hud)
      assert.is_true(pocket.shown)
      assert.is_true(bf:IsShown())
      -- the board's header: that board's actions, as in the Boards tab
      local realShow0 = ns.Menu.Show
      local got
      ns.Menu.Show = function(_, items) got = items end
      ns.BoardsBoardMenu(panel.head, pocket)
      local texts = {}
      for _, it in ipairs(got) do texts[#texts + 1] = it.text end
      assert.are.equal("Pocket", texts[1])
      for _, t in ipairs({ "On HUD", "Edit on screen", "Rename...", "Delete" }) do
        assert.truthy(table.concat(texts, "|"):find(t, 1, true), t)
      end
      -- + Tile: the reading picker for that board, by tracker; a pick adds the tile here
      got = nil
      panel.add:GetScript("OnClick")(panel.add)
      assert.truthy(got[1].title)
      assert.truthy(got[1].text:find("Pocket", 1, true))
      ns.Menu.Show = realShow0
      local n = #pocket.tiles
      Bo.AddReading(pocket, "hc:xpgained")
      assert.are.equal(n + 1, #pocket.tiles)
      local menus = {}
      local realShow, realConfirm = ns.Menu.Show, Bo.Confirm
      ns.Menu.Show = function(_, items) menus[#menus + 1] = type(items) == "function" and items() or items end
      Bo.Confirm = function(_, fn) fn() end
      local function menuFor(raw)
        for _, e in ipairs(BM.CollectionTiles()) do
          if e.raw == raw then ns.BoardsCardMenu(f, e); return menus[#menus], e end
        end
      end
      local function pick(m, text)
        for _, it in ipairs(m) do if it.text == text then return it end end
      end
      local gold = all[1].raw
      -- the card menu: Edit (the board's own settings), On HUD (the tile's switch), Move to board, Delete tile
      local m = menuFor(gold)
      for _, t in ipairs({ "Edit", "On HUD", "Move to board", "Delete tile" }) do assert.truthy(pick(m, t), t) end
      assert.is_nil(pick(m, "Take off HUD"))
      assert.is_true(pick(m, "On HUD").checked)
      local edit = {}
      for _, it in ipairs(pick(m, "Edit").sub) do edit[#edit + 1] = it.text end
      assert.truthy(table.concat(edit, "|"):find("Scope", 1, true))
      -- off the HUD: the tile stays on its board, its card dashed and marked; the HUD frame draws one row fewer
      n = #pocket.tiles
      local rowsBefore = #bf.rowFrames
      pocket.mini = false
      Bo.Refresh(pocket.id, true)
      rowsBefore = #bf.rowFrames
      pick(m, "On HUD").func()
      assert.are.equal(n, #pocket.tiles)
      assert.are.equal(pocket, (BM.BoardOf(gold)))
      assert.is_true(#bf.rowFrames < rowsBefore)
      ns.RefreshBoards()
      local dashed
      for _, c in ipairs(ns.BoardsCards) do if c:IsShown() and c.entry.raw == gold then dashed = c end end
      assert.is_true(dashed.dashed)
      assert.is_true(dashed.dash[1]:IsShown())
      assert.truthy(dashed.foot:GetText():find("Only here", 1, true))
      m = menuFor(gold)
      assert.is_false(pick(m, "On HUD").checked)
      pick(m, "On HUD").func()
      assert.are.equal(rowsBefore, #bf.rowFrames)
      -- New board... opens the dialog; a board made there is here at once, Only here, saying it is empty
      f.new:GetScript("OnClick")(f.new)
      local D = ns.BoardDialog
      assert.is_true(D.Frame():IsShown())
      assert.is_false(D.Rules().hud)
      D.Open({ empty = true })
      D.Frame().name:SetText("Spare")
      local empty = D.Create()
      assert.is_false(empty.shown)
      assert.is_false(Bo.IsEditing(empty.id))
      assert.are.equal(empty, ns.BoardsPanels[2].head.board)
      assert.is_true(ns.BoardsPanels[2].empty:IsShown())
      assert.are.equal("Only here", ns.BoardsPanels[2].hud:GetText())
      -- move a tile to it, and to a board of its own
      m = menuFor(gold)
      assert.are.equal("Spare (Only here)", pick(m, "Move to board").sub[1].text)
      pick(m, "Move to board").sub[1].func()
      assert.are.equal(empty, (BM.BoardOf(gold)))
      assert.are.equal(n - 1, #pocket.tiles)
      m = menuFor(gold)
      local boards = #BM.Store().list
      pick(pick(m, "Move to board").sub, "New board").func()
      assert.are.equal(boards + 1, #BM.Store().list)
      local own = BM.BoardOf(gold)
      assert.is_false(own.shown)
      -- delete a tile for good; delete a board with its tiles
      local count = #BM.CollectionTiles()
      m = menuFor(gold)
      pick(m, "Delete tile").func()
      assert.are.equal(count - 1, #BM.CollectionTiles())
      BM.Delete(own.id)
      BM.Delete(empty.id)
      ns.RefreshBoards()
      assert.is_false(ns.BoardsPanels[2]:IsShown())
      -- many tiles: the tab grows and the window scrolls it (HC-69)
      for _ = 1, 40 do BM.AddReading(pocket, "hc:gold") end
      ns.RefreshBoards()
      assert.is_true(ns.Windows.Host("_main").scrollMax > 0)
      -- the search narrows the cards
      f.search:SetText("zzz")
      f.search:GetScript("OnTextChanged")(f.search)
      assert.truthy(f.empty:GetText():find("matches the search", 1, true))
      assert.is_false(panel:IsShown())
      -- a board's name finds its whole panel
      f.search:SetText("pock")
      f.search:GetScript("OnTextChanged")(f.search)
      assert.is_true(panel:IsShown())
      assert.are.equal("", f.empty:GetText())
      f.search:SetText("")
      f.search:GetScript("OnTextChanged")(f.search)
      -- the panel at the end says more boards can be made; with no boards at all it says how to start (0.4.0)
      assert.truthy(f.foot:IsShown())
      assert.truthy(f.foot.title:GetText():find("Add another board", 1, true))
      while BM.Store().list[1] do BM.Delete(BM.Store().list[1].id) end
      Bo.RefreshAll(true)
      ns.RefreshBoards()
      assert.truthy(f.foot.title:GetText():find("No boards yet", 1, true))
      ns.Menu.Show, Bo.Confirm = realShow, realConfirm
      assert.are.same({}, ctx.env.errors)
    end)
  end)
end)

-- HC-68 (DESIGN §17.4, §17.6): the Boards tab, the New board dialog, the launcher and Options lined up
describe("the Boards tab and the New board dialog", function()
  it("lists boards with their status, finds one (hover, Show now, Reset position) and acts on it", function()
    UI.with(function(ctx)
      local ns = ctx.hc
      local BM, Bo = ns.BoardModel, ns.Boards
      ns.ShowExplorer(true, "boards")                        -- (0.4.0: the board list is the Explorer's)
      local f = ns.Windows.Content("explorer")
      f:SetSize(762, 568)
      ns.RefreshExplorer()
      local br = ns.BoardsBrowser
      local pocket = BM.Store().list[1]
      local function rowFor(pattern)
        for _, r in ipairs(br.list.rows) do
          if r:IsShown() and (r.cells[1]:GetText() or ""):find(pattern) then return r end
        end
      end
      local function actionTexts()
        local out = {}
        for _, b in ipairs(br.actionBtns) do if b:IsShown() then table.insert(out, 1, b:GetText()) end end
        return out
      end
      local nodes = {}
      for _, r in ipairs(br.tree.rows) do if r:IsShown() then nodes[#nodes + 1] = r.text:GetText() end end
      assert.are.equal("MY SETUP", nodes[1])                       -- (a caption)
      assert.truthy(nodes[2]:find("^Boards"))
      assert.truthy(nodes[3]:find("^Tiles"))
      assert.truthy(table.concat(nodes, "|"):find("Ready-made boards", 1, true))
      assert.truthy(table.concat(nodes, "|"):find("Activity", 1, true))   -- (HC-57: presets by category)
      local row = rowFor("^Pocket")
      assert.truthy(row)
      assert.truthy(row.cells[2]:GetText():find("On HUD", 1, true))
      assert.truthy(row.cells[1]:GetText():find("mini", 1, true))
      -- off: the status says so; hovering its row shows it only faintly (0.4.0), not raised, no flash
      pocket.shown = false
      Bo.Refresh(pocket.id, true)
      ns.RefreshExplorer()
      row = rowFor("^Pocket")
      assert.truthy(row.cells[2]:GetText():find("Only here", 1, true))
      local bf = Bo.Frame(pocket.id)
      assert.is_false(bf:IsShown())
      row:GetScript("OnEnter")(row)
      assert.is_true(bf:IsShown())
      assert.are.equal("LOW", bf:GetFrameStrata())
      assert.is_false(bf.hoverFlash:IsShown())
      row:GetScript("OnLeave")(row)
      assert.is_false(bf:IsShown())
      -- on the HUD: hovering raises it above the window and flashes it
      pocket.shown = true
      Bo.Refresh(pocket.id, true)
      row:GetScript("OnEnter")(row)
      assert.are.equal("HIGH", bf:GetFrameStrata())
      assert.is_true(bf.hoverFlash:IsShown())
      row:GetScript("OnLeave")(row)
      assert.are.equal("LOW", bf:GetFrameStrata())
      -- a rule names itself
      pocket.show.runOnly = true
      ns.RefreshExplorer()
      assert.truthy(rowFor("^Pocket").cells[2]:GetText():find("only during stints", 1, true))
      -- select it: + Tile, the clock, the On HUD switch, Edit on screen; the rest under More...
      row = rowFor("^Pocket")
      row:GetScript("OnClick")(row, "LeftButton")
      local acts = table.concat(actionTexts(), "|")
      for _, t in ipairs({ "+ Tile", "Edit on screen" }) do assert.truthy(acts:find(t, 1, true), t) end
      assert.is_nil(acts:find("Delete", 1, true))
      assert.is_true(br.moreBtn:IsShown())
      local pills = {}
      for _, p in ipairs(br.actionPills) do if p:IsShown() then pills[#pills + 1] = p:GetText() end end
      assert.are.same({ "On HUD" }, pills)
      Bo.ShowNow(pocket.id, 5)
      assert.is_true(bf:IsShown())
      ctx.env:advance(6)
      assert.is_false(bf:IsShown())
      pocket.show.runOnly = false
      -- Reset position: the centre, scale 1
      pocket.pos, pocket.scale = { "TOPLEFT", 3000, -3000, "BOTTOMLEFT" }, 0.2
      ns.RefreshExplorer()
      assert.truthy(rowFor("^Pocket").cells[2]:GetText():find("Tiny?", 1, true))
      Bo.ResetPosition(pocket)
      assert.are.same({ "CENTER", 0, 0, "CENTER" }, pocket.pos)
      assert.are.equal(1, pocket.scale)
      -- the detail: its rules, the command, the On HUD and Mini switches, its tiles with values
      ns.RefreshExplorer()
      assert.truthy(br.detail.text:GetText():find("/hc board pocket", 1, true))
      local miniItem = br.detail.items[2]
      assert.are.equal("Mini", miniItem.pill:GetText())
      miniItem.pill:GetScript("OnClick")(miniItem.pill)
      assert.is_false(pocket.mini)
      -- Save as preset (under More...): it appears under Ready-made boards ▸ Your presets
      local realAsk, realConfirm, realShow = Bo.AskText, Bo.Confirm, ns.Menu.Show
      Bo.AskText = function(_, _, fn) fn("Mine") end
      Bo.Confirm = function(_, fn) fn() end
      local more
      ns.Menu.Show = function(_, items) more = items end
      br.moreBtn:GetScript("OnClick")(br.moreBtn)
      ns.Menu.Show = realShow
      local function moreItem(text) for _, it in ipairs(more) do if it.text == text then return it end end end
      moreItem("Save as preset").func()
      assert.are.equal("Your presets", BM.PresetGroups()[#BM.PresetGroups()].title)
      -- (0.4.0) no All off HUD, All on HUD or Edit all: the header has New board... only
      assert.are.equal(1, #br.headerBtns)
      assert.are.equal("New board...", br.headerBtns[1]:GetText())
      -- Delete (under More...): its tiles go with it (v8)
      local n = #BM.CollectionTiles() - #pocket.tiles
      row = rowFor("^Pocket")
      row:GetScript("OnClick")(row, "LeftButton")
      ns.Menu.Show = function(_, items) more = items end
      br.moreBtn:GetScript("OnClick")(br.moreBtn)
      ns.Menu.Show = realShow
      moreItem("Delete").func()
      assert.is_nil(BM.Get(pocket.id))
      assert.are.equal(n, #BM.CollectionTiles())
      Bo.AskText, Bo.Confirm = realAsk, realConfirm
      ns.ShowExplorer(false)
      assert.are.same({}, ctx.env.errors)
    end)
  end)

  it("makes boards through the dialog: unique names, a start, on the HUD or not, rules; empty ones on the HUD open edited", function()
    UI.with(function(ctx)
      local ns = ctx.hc
      local BM, Bo, D = ns.BoardModel, ns.Boards, ns.BoardDialog
      local f = D.Open({ preset = "pocket" })
      assert.is_true(f:IsShown())
      assert.are.equal("DIALOG", f:GetFrameStrata())
      assert.are.equal("Pocket 2", f.name:GetText())               -- a fresh install has a Pocket board already
      assert.truthy(f.note:GetText():find("/hc board pocket 2", 1, true))
      -- a taken name: said, with a suggestion, and Create refuses
      f.name:SetText("pocket")
      f.name:GetScript("OnTextChanged")(f.name)
      assert.truthy(f.note:GetText():lower():find("try pocket 2", 1, true))
      local n = #BM.Store().list
      assert.is_nil(D.Create())
      assert.are.equal(n, #BM.Store().list)
      -- the start menu: presets in groups, then Empty board and Copy of a board
      local menu
      local realShow = ns.Menu.Show
      ns.Menu.Show = function(_, items) menu = items end
      f.start:GetScript("OnClick")(f.start)
      ns.Menu.Show = realShow
      assert.are.equal("Activity", menu[1].text)
      local texts = {}
      for _, it in ipairs(menu) do texts[#texts + 1] = it.text end
      local all = table.concat(texts, "|")
      assert.truthy(all:find("Empty board", 1, true))
      assert.truthy(all:find("Copy of a board", 1, true))
      -- a typed name stays when the start changes
      f.name:SetText("Farm")
      f.name:GetScript("OnTextChanged")(f.name)
      for _, it in ipairs(menu) do if it.text == "  Leveling" then it.func() end end
      assert.are.equal("Farm", f.name:GetText())
      -- Start from is a dropdown: its value on the left, an arrow on the right
      assert.truthy(f.start.arrow)
      assert.are.equal("Leveling", f.start:GetText())
      -- not on the HUD unless ticked (v8); its rules are greyed until then
      assert.is_false(D.Rules().hud)
      assert.is_false(D.Rules().hud)
      f.hud:GetScript("OnClick")(f.hud)
      assert.is_true(D.Rules().hud)
      -- rules: not in combat
      f.checks[1]:GetScript("OnClick")(f.checks[1])
      local b = D.Create()
      assert.truthy(b)
      assert.is_true(b.shown)
      assert.is_true(Bo.Frame(b.id):IsShown())
      assert.is_false(f:IsShown())
      assert.are.equal("Farm", b.name)
      assert.are.equal("leveling", b.preset)
      assert.are.equal("hide", b.show.combat)
      assert.are.same({ "CENTER", 0, 0, "CENTER" }, b.pos)
      assert.is_false(Bo.IsEditing(b.id))
      -- an empty board made for the HUD opens in edit mode; one made for the window only does not, and is not on screen
      D.Open({ empty = true, hud = true })
      local e = D.Create()
      assert.are.equal("Board", e.name)
      assert.is_true(Bo.IsEditing(e.id))
      Bo.SetEditing(false)
      D.Open({ empty = true })
      local w = D.Create()
      assert.is_false(w.shown)
      assert.is_false(Bo.IsEditing(w.id))
      assert.is_false(Bo.Frame(w.id):IsShown())
      -- Edit on screen shows an "Only here" board while it is edited
      Bo.EditBoard(w.id, true)
      assert.is_true(Bo.Frame(w.id):IsShown())
      Bo.EditBoard(w.id, false)
      assert.is_false(Bo.Frame(w.id):IsShown())
      -- a copy has tiles of its own
      D.Open({ copy = b })
      assert.are.equal("Farm 2", f.name:GetText())
      local c = D.Create()
      assert.are.equal(#b.tiles, #c.tiles)
      assert.are_not.equal(b.tiles[1].ref, c.tiles[1].ref)
      -- Rename keeps names unique
      assert.is_false(Bo.Rename(c, "farm"))
      assert.is_true(Bo.Rename(c, "Farm copy"))
      -- /hc board new: no name opens the dialog; a name makes an empty board at once; a taken one is refused
      f:Hide()
      _G.SlashCmdList.HARDCOUNTERS("board new")
      assert.is_true(f:IsShown())
      f:Hide()
      n = #BM.Store().list
      _G.SlashCmdList.HARDCOUNTERS("board new Herbs")
      assert.are.equal(n + 1, #BM.Store().list)
      assert.are.equal("Herbs", BM.Store().list[n + 1].name)
      _G.SlashCmdList.HARDCOUNTERS("board new herbs")
      assert.are.equal(n + 1, #BM.Store().list)
      Bo.SetEditing(false)
      -- the + menu and the launcher open the dialog
      f:Hide()
      local items
      ns.Menu.Show = function(_, it) items = it end
      Bo.AddMenu(Bo.Frame(b.id), b)
      ns.Menu.Show = realShow
      items[#items].func()
      assert.is_true(f:IsShown())
      assert.are.same({}, ctx.env.errors)
    end)
  end)
end)

-- HC-74 (the user, 2026-11-24): each character its own boards; a new one gets the Leveling board and, once per
-- account, the introduction; another character's boards can be copied
describe("a new character", function()
  -- another character of the account, as AceDB saved it: one board, a reading tile and a heading
  local function altSettings(global)
    return { global = global, char = { ["Alt - Elsewhere"] = { boards = { v = 7, nextId = 2, seeded = true, nextTile = 1,
      tileOrder = { "t1" },
      tiles = { t1 = { id = "t1", kind = "reading", reading = "hc:gold", scope = "session", display = "number", name = "Alt gold" } },
      list = { { id = "b1", name = "Farm", wid = 77, shown = true, mini = false, show = {},
        tiles = { { kind = "label", text = "Money" }, { ref = "t1", size = "half" } } } } } } } }
  end

  it("starts with no board and the introduction once; copies another character's board", function()
    UI.with(function(ctx)
      local ns = ctx.hc
      local BM = ns.BoardModel
      assert.is_false(ns.knownCharacter)
      local list = BM.Store().list
      assert.are.equal(0, #list)                                       -- (0.4.0) no board at a first setup
      assert.is_nil(ns.TutorialFrame())                                -- not behind the loading screen
      ctx.env:advance(3)
      local w = ns.TutorialFrame()
      assert.truthy(w)
      assert.is_true(w:IsShown())                                      -- the tour (tests/tutorial_spec.lua walks it)
      assert.is_true(ns.globalSettings.tutorialSeen)                  -- once per account
      assert.is_true(ns.globalSettings.introSeen)
      assert.is_nil(BM.Store().welcome)
      ns.Tutorial.Hide()
      assert.is_false(w:IsShown())
      -- the other character's board, in the Explorer, copied to this one
      ns.ShowExplorer(true, "others")
      ns.Windows.Content("explorer"):SetSize(762, 568)
      ns.RefreshExplorer()
      local br = ns.BoardsBrowser
      local nodes = {}
      for _, r in ipairs(br.tree.rows) do if r:IsShown() then nodes[#nodes + 1] = r.text:GetText() end end
      assert.truthy(table.concat(nodes, "|"):find("OTHER CHARACTERS", 1, true))        -- (a caption, 0.4.0)
      assert.truthy(table.concat(nodes, "|"):find("Alt", 1, true))
      br:Select("o:Alt - Elsewhere:1", "others")
      local copyBtn
      for _, b in ipairs(br.actionBtns) do if b:IsShown() and b:GetText() == "Copy to this character..." then copyBtn = b end end
      assert.truthy(copyBtn)
      copyBtn:GetScript("OnClick")(copyBtn)
      local choice = ns.BoardDialog.Choice()
      assert.are.equal("copy", choice.kind)
      assert.are.equal("Alt", choice.who)
      assert.truthy(ns.BoardDialog.Frame().start:GetText():find("(Alt)", 1, true))
      local b = ns.BoardDialog.Create()
      assert.are.equal("Farm", b.name)
      assert.are.equal(1, #BM.Store().list)
      assert.are.equal("label", b.tiles[1].kind)
      assert.are.equal("Alt gold", b.tiles[2].name)
      assert.is_nil(b.wid)                                             -- a timer of its own
      b.tiles[2].name = "My gold"                                     -- adjusted here, the alt's stays
      assert.are.equal("Alt gold", ns.allCharSettings["Alt - Elsewhere"].boards.tiles.t1.name)
      assert.are.same({}, ctx.env.errors)
    end, { newCharacter = true, settings = altSettings() })
  end)

  it("after the account's first one, gets a chat line saying where boards are made, no window", function()
    UI.with(function(ctx)
      local ns = ctx.hc
      local printed
      ns.Print = function(fmt) printed = fmt end
      ctx.env:advance(3)
      assert.is_nil(ns.TutorialFrame())
      assert.truthy(printed and printed:find("no boards yet", 1, true))
      assert.are.equal(0, #ns.BoardModel.Store().list)
      assert.are.same({}, ctx.env.errors)
    end, { newCharacter = true, settings = altSettings({ introSeen = true, tutorialSeen = true }) })
  end)

  it("a character Hard Counters knew keeps its boards; it gets the tour once, being older than the tour", function()
    UI.with(function(ctx)
      local ns = ctx.hc
      assert.is_true(ns.knownCharacter)
      ctx.env:advance(3)
      assert.is_true(ns.TutorialFrame():IsShown())
      assert.are.equal("Pocket", ns.BoardModel.Store().list[1].name)
    end)
    UI.with(function(ctx)
      local ns = ctx.hc
      ctx.env:advance(3)
      assert.is_nil(ns.TutorialFrame())                                -- an account that has seen it
    end, { settings = { global = { tutorialSeen = true } } })
  end)
end)
