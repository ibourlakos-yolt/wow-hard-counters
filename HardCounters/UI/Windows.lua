-- Windows: every Hard Counters window, and any pack's, through one host (DESIGN §7.1). A window is a tab of the
-- shared "Hard Counters" frame, always: there is no pop-out (user, 2026-11-15, after popping every tab out left an
-- empty frame with no way back). Only a window that says dockable = false (a HUD, a popup) gets a frame of its own.
-- Hard Counters owns the chrome, so every window gets the same: Blizzard's panel frame (border, title, close,
-- inset), drag to move, Escape, BlizzMove (Ctrl+mouse wheel scales), raise on click, and its position and scale
-- saved under settings.windows[id]. The shared frame is not resizable and keeps one size for every tab (user,
-- 2026-11-23): its design size (DESIGN §17.2), wider only for a tab whose minimum width needs it, capped at the
-- screen; a tab taller than it scrolls. Hard Counters' own windows are icon tabs down the right edge, a pack's window (and
-- Diagnostics) a tab along the bottom (HC-69, swapped by the user 2026-11-24). A frame of its own keeps a resize grip and its saved size. A
-- HUD window (chrome = "hud") gets a plain dark frame instead.
--
-- Content never shows or hides itself: the host shows the content frame exactly while the window is on screen and
-- calls def.onShow / def.onHide on those changes, so a refresh ticker can follow them.
local ADDON, ns = ...

local HC, L, Wd = ns.HC, ns.L, ns.Widgets
local floor, max, min = math.floor, math.max, math.min
local format = string.format

local MAIN, MAIN_NAME = "_main", "HardCountersMain"
local MAX_W, MAX_H = 1600, 1200
-- The shared frame's design size (DESIGN §17.2, settled with the browser layout, HC-69): 780 wide for the browser,
-- 640 high so Character Stats (a 566-high body: every stat row) fits without scrolling. A tab taller than that scrolls; a wider one widens the panel.
-- (0.5.0, the user: the window and its text "should grow about 5-15%") 820 x 660, drawn at MAIN_SCALE by default:
-- about 13% wider and 11% taller on screen, every font 8% bigger, and 40 x 20 more room inside for details.
local MAIN_W, MAIN_H = 820, 660
local MAIN_SCALE = 1.08
-- Side tabs (LargeSideTabButtonTemplate on Forever, measured by the HC-65 probe): 55 square, the first 60 down,
-- 2 apart, hanging off the right edge. The plain fallback is smaller. Bottom tabs hang 30 under the frame.
local SIDE_W, SIDE_TOP, SIDE_GAP, SIDE_PLAIN = 55, 60, 2, 40
local ARROWS_H, TAB_HANG, SB_W = 26, 30, 12
local TAB_ICON, TAB_GAP = 16, 3
-- Tab labels (DESIGN §17.2): the player's choice for the bottom tabs; side tabs are always icons
local LABEL_MODES = { both = true, title = true, icon = true }
-- The addon's own icon (tools/draw-icon.py; same path as ## IconTexture): minimap button, compartment, Broker, portrait.
local ICON = "Interface\\AddOns\\HardCounters\\Media\\Icon"
ns.ICON = ICON

-- Blizzard panel chrome (ButtonFrameTemplate): title bar 24, the "attic" under it down to 60 when there's a
-- portrait; the inset sits 4 / 6 / 4 inside the border; content gets 4 more inside the inset.
local PANEL_TOP, PANEL_TOP_PORTRAIT = 24, 60
local INSET_L, INSET_R, INSET_B, PAD = 4, 6, 4, 4
-- the plain chrome (HUD windows, and the fallback if the template is missing)
local FLAT_TITLE, HEADER_H = 26, 26

local defs, order = {}, {}
local packIds = {}     -- id -> true: a pack's window (registered through the public API): a tab along the bottom
local entries = {}     -- id -> { content, host, body (current parent), visible }
local main
local Win = {}
ns.Windows = Win

local function safe(fn, ...)
  if not fn then return end
  local ok, err = pcall(fn, ...)
  if not ok and ns.Error then ns.Error(err) end
end

local function G(name) return rawget(_G, name) end
local function widget(v) return type(v) == "table" end
--- obj:method(...) if the client has it; true when it ran.
local function try(obj, method, ...)
  local fn = widget(obj) and obj[method]
  if type(fn) ~= "function" then return false end
  return (pcall(fn, obj, ...))
end

local function conf(id) return Wd.Conf(id, defs[id] and defs[id].migrate) end
local function canDock(id) return defs[id] and defs[id].dockable ~= false end

--- A tab of the shared frame: every window but those with dockable = false. def.docked and a saved
--- settings.windows[id].docked (from before 2026-11-15) are ignored.
local function isDocked(id) return canDock(id) and true or false end

local function bodyMin(id)
  local def = defs[id]
  if def.minSize then
    local w, h = def.minSize()
    return w or 200, h or 100
  end
  return def.minWidth or 200, def.minHeight or 100
end

local function fixedHeight(id)
  local def = defs[id]
  return def.fixedHeight and def.fixedHeight() or nil
end

local function clamp(v, lo, hi) return min(max(v, lo), hi) end

local function setEscape(name, on)
  for i = #UISpecialFrames, 1, -1 do
    if UISpecialFrames[i] == name then table.remove(UISpecialFrames, i) end
  end
  if on then tinsert(UISpecialFrames, name) end
end

local function dockedIds()
  local out = {}
  for _, id in ipairs(order) do if isDocked(id) then out[#out + 1] = id end end
  return out
end

-- (the user, 2026-11-24) the tabs swapped places: packs' windows along the bottom, Hard Counters' own down the
-- right edge. (0.4.0) Two of Hard Counters' own go along the bottom too, as "secondary" tabs (the user: the summary
-- "should be one of the secondary tabs at the bottom", and Options): def.place = "bottom", ordered by
-- def.bottomOrder: Overview (-100) first, the packs' windows (0) in load order, Options (900), Diagnostics (1000) last.

local function isBottom(id) return packIds[id] or (defs[id] and defs[id].place == "bottom") or false end

local function bottomOrder(id)
  local def = defs[id]
  if def and def.place == "bottom" and type(def.bottomOrder) == "number" then return def.bottomOrder end
  if id:match("^hcdiag:") then return 1000 end
  return 0
end

--- The tabs along the bottom: Overview, the packs' windows in load order, Options, Diagnostics last.
local function bottomIds()
  local out = {}
  for i, id in ipairs(order) do
    if isDocked(id) and isBottom(id) then out[#out + 1] = { id = id, i = i } end
  end
  table.sort(out, function(a, b)
    local oa, ob = bottomOrder(a.id), bottomOrder(b.id)
    if oa ~= ob then return oa < ob end
    return a.i < b.i
  end)
  for i, e in ipairs(out) do out[i] = e.id end
  return out
end

--- The packs' windows only (Diagnostics last): what the tutorial and the Guide call the packs' tabs.
local function packWindowIds()
  local out = {}
  for _, id in ipairs(bottomIds()) do if packIds[id] then out[#out + 1] = id end end
  return out
end

--- Hard Counters' own tabs down the right edge, in their fixed order (def.tabOrder: Boards, Explorer, Packs, Stints, Guide).
local function sideList()
  local out = {}
  for i, id in ipairs(order) do if isDocked(id) and not isBottom(id) then out[#out + 1] = { id = id, i = i } end end
  table.sort(out, function(a, b)
    local oa, ob = defs[a.id].tabOrder or 100, defs[b.id].tabOrder or 100
    if oa ~= ob then return oa < ob end
    return a.i < b.i
  end)
  for i, e in ipairs(out) do out[i] = e.id end
  return out
end

---------------------------------------------------------------------------
-- Visibility: content is shown exactly while its window is on screen
---------------------------------------------------------------------------

local function wantVisible(id)
  local e = entries[id]
  if not (e and e.content) then return false end
  if isDocked(id) then
    return (main and main:IsShown() and conf(MAIN).selected == id) and true or false
  end
  return (e.host and e.host:IsShown()) and true or false
end

local function sync(id)
  local e = entries[id]
  if not (e and e.content) then return end
  local v = wantVisible(id)
  if v == (e.visible or false) then return end
  e.visible = v
  if v then
    e.content:Show()
    safe(defs[id].onShow, e.content)
  else
    e.content:Hide()
    safe(defs[id].onHide, e.content)
  end
end

local attach   -- below; the shared frame's selected tab may not be built yet (it lands on a tab never opened)
local refreshHeader, refreshHelpButtons

local function syncAll()
  local sel = main and main:IsShown() and conf(MAIN).selected
  if sel and defs[sel] and isDocked(sel) then attach(sel) end
  for _, id in ipairs(order) do sync(id) end
  if refreshHeader then refreshHeader() end
end

---------------------------------------------------------------------------
-- Hosts: a frame with chrome and a body that content is parented to.
-- host.padW / host.padH: what the chrome adds around the body; saved sizes are the body's.
---------------------------------------------------------------------------

--- Blizzard's panel frame, or nil if this client lacks the template.
local function panelFrame(name)
  local ok, f = pcall(CreateFrame, "Frame", name, UIParent, "ButtonFrameTemplate")
  if ok and widget(f) and widget(f.Inset) and widget(f.CloseButton) then return f end
  if ok and widget(f) then f:Hide() end
  return nil
end

local function setTitle(f, text)
  f.hcTitleText = text                           -- (what it says, for tests and the tab tooltips)
  if try(f, "SetTitle", text) then return end
  local tc = f.TitleContainer
  local t = (widget(tc) and tc.TitleText) or f.TitleText
  if widget(t) then t:SetText(text) end
end

local function setPortrait(f, show)
  if show then
    if try(f, "SetPortraitToAsset", ICON) then return true end
    local pc = f.PortraitContainer
    local p = (widget(pc) and pc.portrait) or f.portrait
    if widget(p) and try(p, "SetTexture", ICON) then return true end
  end
  local hide = G("ButtonFrameTemplate_HidePortrait")
  if type(hide) == "function" then pcall(hide, f) end
  return false
end

--- opts = { title, portrait, hud, header, strata, fixedSize (no grip: layout alone sizes it), onSized(host) }
local function newHost(name, key, opts)
  local f = not opts.hud and panelFrame(name)
  local top
  if f then
    f.panel = true
    f.close = f.CloseButton
    local portrait = setPortrait(f, opts.portrait)
    setTitle(f, opts.title or "")
    top = portrait and PANEL_TOP_PORTRAIT or PANEL_TOP
    if opts.header and not portrait then top = top + HEADER_H end
    f.Inset:ClearAllPoints()
    f.Inset:SetPoint("TOPLEFT", INSET_L, -top)
    f.Inset:SetPoint("BOTTOMRIGHT", -INSET_R, INSET_B)
    f.body = CreateFrame("Frame", nil, f)
    f.body:SetPoint("TOPLEFT", f.Inset, "TOPLEFT", PAD, -PAD)
    f.body:SetPoint("BOTTOMRIGHT", f.Inset, "BOTTOMRIGHT", -PAD, PAD)
    f.padW, f.padH = INSET_L + INSET_R + 2 * PAD, top + INSET_B + 2 * PAD
    f.headerY = -(PANEL_TOP + 6)
  else
    f = CreateFrame("Frame", name, UIParent)
    local bg = f:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.05, 0.05, 0.07, 0.92)
    f.bg = bg
    top = opts.hud and 0 or FLAT_TITLE
    if opts.title and not opts.hud then
      f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
      f.title:SetPoint("TOPLEFT", 10, -8)
      f.title:SetText(opts.title)
    end
    if opts.header then top = top + HEADER_H end
    f.body = CreateFrame("Frame", nil, f)
    f.body:SetPoint("TOPLEFT", 0, -top)
    f.body:SetPoint("BOTTOMRIGHT", 0, 0)
    f.close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    f.close:SetPoint("TOPRIGHT", 2, 2)
    f.padW, f.padH = 0, top
    f.headerY = -(FLAT_TITLE + 3)
  end
  f:Hide()
  f:SetFrameStrata(opts.strata or "MEDIUM")
  f:SetToplevel(true)                 -- a click raises it above our other windows (no row highlight on top)
  f:SetMovable(true)
  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetClampedToScreen(true)
  f:SetScript("OnDragStart", function(self) if not conf(key).locked then self:StartMoving() end end)
  f:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    Wd.PinTopLeft(self)
    conf(key).pos = Wd.SavedPoint(self)
  end)
  -- above any content parented to the body, and never below the template's own levels: Blizzard's panel draws its
  -- border (NineSlice) high above the frame, and a close button lowered to the body's level vanished under the
  -- border art (run 3 screenshot, 2026-11-15: no close button on any window)
  local lvl = f.body:GetFrameLevel() + 20
  if f.panel then
    local border = widget(f.NineSlice) and f.NineSlice:GetFrameLevel() or 0
    lvl = max(lvl, f.close:GetFrameLevel(), border + 1)
  end
  f.close:SetFrameLevel(lvl)
  if opts.fixedSize then
    try(f, "SetResizable", false)
  else
    Wd.Grip(f, function() return not conf(key).locked end, opts.onSized, f.panel and 6 or 2)
    f.grip:SetFrameLevel(lvl)
  end
  Wd.PlaceAt(f, conf(key).pos)
  f:SetScale(conf(key).scale or (key == MAIN and MAIN_SCALE) or 1)
  f:SetScript("OnShow", function(self)
    self:Raise()
    syncAll()
  end)
  f:SetScript("OnHide", function(self)
    conf(key).scale = self:GetScale()      -- BlizzMove may have scaled it
    syncAll()
  end)
  Wd.BlizzMove(f, name)
  return f
end

--- After the grip: the body's size and the top-left point.
local function savedSize(key, fixed)
  return function(self)
    local c = conf(key)
    c.width = floor(self:GetWidth() - self.padW + 0.5)
    if not fixed or not fixed() then c.height = floor(self:GetHeight() - self.padH + 0.5) end
    c.pos = Wd.SavedPoint(self)
  end
end

--- The largest content that fits on screen in host h (its scale shrinks or grows the room), never below the minimum.
--- A size saved before the grip fix could be bigger than the screen (1333×1151, 2026-11-15).
local function screenMax(h, maxW, maxH, mw, mh)
  local s = h:GetScale()
  if type(s) ~= "number" or s <= 0 then s = 1 end
  local roomW = floor(UIParent:GetWidth() / s) - h.padW
  local roomH = floor(UIParent:GetHeight() / s) - h.padH
  return max(min(maxW, roomW), mw), max(min(maxH, roomH), mh)
end

local function layoutStandalone(id)
  local e = entries[id]
  local h = e and e.host
  if not h then return end
  local def, c = defs[id], conf(id)
  local mw, mh = bodyMin(id)
  local maxW, maxH = screenMax(h, def.maxWidth or MAX_W, def.maxHeight or MAX_H, mw, mh)
  local fh = fixedHeight(id)
  local pw, ph = h.padW, h.padH
  if fh then
    Wd.SetResizeBounds(h, mw + pw, fh + ph, maxW + pw, fh + ph)
  else
    Wd.SetResizeBounds(h, mw + pw, mh + ph, maxW + pw, maxH + ph)
  end
  if h.sizing then return end          -- the grip is held: the mouse decides the size
  local w = clamp(c.width or def.width or mw, mw, maxW)
  local bh = fh or clamp(c.height or def.height or mh, mh, maxH)
  h:SetSize(w + pw, bh + ph)
end

local function ensureHost(id)
  local e = entries[id]
  if e.host then return e.host end
  local def = defs[id]
  local name = def.frameName or ("HardCountersWindow_" .. id:gsub("[^%w]", "_"))
  local hud = def.chrome == "hud" or def.titleBar == false
  local h = newHost(name, id, {
    title = def.title, hud = hud, strata = def.strata,
    onSized = savedSize(id, function() return fixedHeight(id) end),
  })
  h.close:SetScript("OnClick", function() Win.Show(id, false); safe(def.onClose) end)
  setEscape(name, def.escape ~= false)
  e.host = h
  layoutStandalone(id)
  return h
end

---------------------------------------------------------------------------
-- The shared frame (DESIGN §17.2, swapped 2026-11-24): every pack's window, Diagnostics, and (0.4.0) Overview and
-- Options as tabs along the bottom (labelled as the player chose), Hard Counters' own (Boards, Explorer, Packs,
-- Stints, Guide) as icon tabs down the right edge (they hang off it and take no width; a column too long for the frame
-- scrolls), a header row (the open tab's one line, its help and tour, the Grand tour; a button per window that asks
-- for one, def.mainButton), and a body that scrolls a tab taller than the panel.
---------------------------------------------------------------------------

local function labelMode()
  local m = ns.settings and ns.settings.tabLabels
  return LABEL_MODES[m] and m or "both"
end

--- The clamp rect reaches over the side column and under the bottom tabs, so neither leaves the screen (HC-65:
--- SetClampRectInsets clamps both SetPoint and drags).
local function setClamp()
  local side = main.sideList and #main.sideList > 0
  local w = side and (main.sidePlain and SIDE_PLAIN + 2 or SIDE_W) or 0
  try(main, "SetClampRectInsets", 0, w, 0, (main.tabCount or 0) > 0 and -TAB_HANG or 0)
end

local function setScroll(off)
  off = clamp(floor((off or 0) + 0.5), 0, main.scrollMax or 0)
  main.scrollOff = off
  try(main.scroll, "SetVerticalScroll", off)
  main.scrollBar:SetOffset(off)
end

--- The selected tab's canvas: the body's size, or taller with a scroll bar when its minimum height needs more.
local function layoutCanvas()
  local sel = conf(MAIN).selected
  local bw, bh = main.bodyW or 0, main.bodyH or 0
  local mh = 0
  if sel and defs[sel] and isDocked(sel) then mh = select(2, bodyMin(sel)) end
  local over = max(0, floor(mh - bh + 0.5))
  main.scrollMax = over
  main.scroll:ClearAllPoints()
  main.scroll:SetPoint("TOPLEFT", main.body, "TOPLEFT", 0, 0)
  main.scroll:SetPoint("BOTTOMRIGHT", main.body, "BOTTOMRIGHT", over > 0 and -(SB_W + 4) or 0, 0)
  main.canvas:SetSize(max(bw - (over > 0 and SB_W + 4 or 0), 1), max(bh, mh))
  main.scrollBar:SetRange(over)
  try(main.scroll, "EnableMouseWheel", over > 0)
  setScroll(min(main.scrollOff or 0, over))
end

--- Not resizable, and one size whatever the tab (user, 2026-11-23: one panel, visually consistent): the design
--- size, wider only when a tab's minimum width needs it (width never scrolls), capped at the screen. A tab taller
--- than the body scrolls inside it.
local function layoutMain()
  if not main then return end
  local sel = conf(MAIN).selected
  local w, h = MAIN_W - main.padW, MAIN_H - main.padH
  for _, id in ipairs(dockedIds()) do w = max(w, (bodyMin(id))) end
  local pw, ph = main.padW, main.padH
  w, h = screenMax(main, w, h, 0, 0)
  -- Escape closes the frame unless its tab is a window that stays up
  setEscape(MAIN_NAME, not (sel and defs[sel] and defs[sel].escape == false))
  Wd.SetResizeBounds(main, w + pw, h + ph, w + pw, h + ph)
  main:SetSize(w + pw, h + ph)
  main.bodyW, main.bodyH = w, h
  layoutCanvas()
end

local SELECT, DESELECT, RESIZE = "PanelTemplates_SelectTab", "PanelTemplates_DeselectTab", "PanelTemplates_TabResize"
local TAB_ROOM = 4

-- room for the icon beside the label (HC-65: the icon sits TAB_GAP left of the label, both centred)
local function tabPad(b)
  local pad = TAB_ROOM
  if b.hcIconOn then pad = pad + TAB_ICON + ((b.hcText or "") ~= "" and TAB_GAP or 0) end
  return pad
end

-- Blizzard's PanelTemplates_TabResize (forever branch, 1.60.1) sets the label's width to exactly its
-- GetStringWidth(): in game a label wider than the side art's minimum lost its last letters to "..." (HC-59:
-- "Character S...", "Diagnost..."). Keep its sizing, add a little room (and the icon's), then leave the label
-- unconstrained (width 0, the template's own default). The tab's OnShow and OnEvent (DISPLAY_SIZE_CHANGED) resize it
-- again with no padding, so it is hooked.
local function sizeTab(b)
  pcall(G(RESIZE), b, tabPad(b))
  if type(b.Text) == "table" then b.Text:SetWidth(0) end
end

-- an icon-only tab's title as its tooltip (the template shows one only for a truncated label)
local function tabTip(self)
  if (self.hcText or "") ~= "" or not GameTooltip then return end
  GameTooltip:SetOwner(self, "ANCHOR_TOP")
  GameTooltip:SetText(self.hcTitle or "", 1, 1, 1)
  GameTooltip:Show()
  self.hcTipShown = true
end

local function tabTipOff(self)
  if self.hcTipShown and GameTooltip then GameTooltip:Hide() end
  self.hcTipShown = nil
end

local function newTab(i)
  local b
  if type(G(SELECT)) == "function" then
    local ok, t = pcall(CreateFrame, "Button", MAIN_NAME .. "Tab" .. i, main, "PanelTabButtonTemplate")
    if ok and widget(t) then
      b, t.blizzard = t, true
      b.hcIcon = b:CreateTexture(nil, "ARTWORK")
      b.hcIcon:SetSize(TAB_ICON, TAB_ICON)
      b.hcIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
      b:HookScript("OnShow", sizeTab)
      b:HookScript("OnEvent", sizeTab)
      b:HookScript("OnEnter", tabTip)
      b:HookScript("OnLeave", tabTipOff)
    end
  end
  if not b then
    b = Wd.Button(main, "", 80, nil)
    b:SetHeight(22)
  end
  return b
end

--- A bottom tab labelled as the player chose: icon and title, title only, or icon only (the title as its tooltip).
--- A window without an icon always shows its title; the plain fallback button shows titles only.
local function dressTab(b, id, selected)
  local def = defs[id]
  local title = def.title or id
  local mode = labelMode()
  local iconOn = b.blizzard and def.icon ~= nil and mode ~= "title" or false
  local text = (iconOn and mode == "icon") and "" or title
  b.hcTitle, b.hcText, b.hcIconOn = title, text, iconOn
  b:SetText(text)
  if not b.blizzard then
    local fs = b:GetFontString()
    b:SetWidth(max(floor((fs and fs:GetStringWidth() or 50) + 24), 60))
    b:SetEnabled(not selected)
    return
  end
  local shift = 0
  b.hcIcon:SetShown(iconOn)
  if iconOn then
    b.hcIcon:SetTexture(def.icon)
    b.hcIcon:ClearAllPoints()
    if text ~= "" then
      -- the label moves right by half the icon so both stay centred; Blizzard's select and deselect read these
      b.hcIcon:SetPoint("RIGHT", b.Text, "LEFT", -TAB_GAP, 0)
      shift = (TAB_ICON + TAB_GAP) / 2
    else
      b.hcIcon:SetPoint("CENTER", b, "CENTER", 0, selected and -3 or 2)    -- the label's own offsets
    end
  end
  b.selectedTextX, b.deselectedTextX = shift, shift
  sizeTab(b)
  pcall(G(selected and SELECT or DESELECT), b)
end

local layoutSide

local function sideTip(self)
  if self.blizzard or not GameTooltip then return end     -- the template shows its tooltipText itself
  GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
  GameTooltip:SetText(self.tooltipText or "", 1, 1, 1)
  GameTooltip:Show()
end

local function sideWheel(_, delta)
  main.sideOff = (main.sideOff or 0) - (delta or 0)
  layoutSide(false)
end

--- A side tab: Blizzard's LargeSideTabButtonTemplate (a Frame on Forever: clicks come through its mouse-up handler,
--- SetChecked shows the selected art; HC-65), or a plain icon button where the template is missing.
local function newSideTab(i)
  local ok, t = pcall(CreateFrame, "Frame", MAIN_NAME .. "Side" .. i, main, "LargeSideTabButtonTemplate")
  if ok and widget(t) and widget(t.Icon) and type(t.SetChecked) == "function" then
    t.blizzard = true
    try(t, "SetFillToInterior", true)            -- as the profession window's tabs
    if not t:IsMouseEnabled() then t:EnableMouse(true) end
    local function onUp(self, button, upInside)
      if button == "LeftButton" and upInside ~= false and self.hcId then Win.Show(self.hcId, true) end
    end
    if type(t.SetCustomOnMouseUpHandler) == "function" then t:SetCustomOnMouseUpHandler(onUp)
    else t:HookScript("OnMouseUp", onUp) end
  else
    if ok and widget(t) then t:Hide() end
    t = CreateFrame("Button", nil, main)
    t:SetSize(SIDE_PLAIN, SIDE_PLAIN)
    local bg = t:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.05, 0.05, 0.07, 0.92)
    t.Icon = t:CreateTexture(nil, "ARTWORK")
    t.Icon:SetPoint("TOPLEFT", 4, -4)
    t.Icon:SetPoint("BOTTOMRIGHT", -4, 4)
    t.Icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    t.sel = t:CreateTexture(nil, "OVERLAY")
    t.sel:SetAllPoints()
    t.sel:SetColorTexture(1, 0.82, 0, 0.25)
    local hl = t:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 1, 0.15)
    t:SetScript("OnClick", function(self) if self.hcId then Win.Show(self.hcId, true) end end)
    t:SetScript("OnEnter", sideTip)
    t:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
    main.sidePlain = true
  end
  t:EnableMouseWheel(true)
  t:SetScript("OnMouseWheel", sideWheel)
  return t
end

--- Place the side column: as many tabs as fit beside the frame; more than that and two arrows (and the mouse wheel
--- over the column) scroll it. reveal: scroll the selected tab into view.
function layoutSide(reveal)
  local ids = main.sideList or {}
  local plain = main.sidePlain
  local step = (plain and SIDE_PLAIN or SIDE_W) + SIDE_GAP
  local frameH = (main.bodyH or 0) + main.padH
  local n = #ids
  local fit = max(1, floor((frameH - SIDE_TOP + SIDE_GAP) / step))
  local over = n > fit
  if over then fit = max(1, floor((frameH - SIDE_TOP - ARROWS_H + SIDE_GAP) / step)) end
  local off = main.sideOff or 0
  local s = main.sideSelected
  if reveal and s then
    if s <= off then off = s - 1 elseif s > off + fit then off = s - fit end
  end
  off = clamp(off, 0, max(0, n - fit))
  main.sideOff, main.sideFit = off, fit
  for i, t in ipairs(main.sideTabs) do
    local slot = i - off
    if i <= n and slot >= 1 and slot <= fit then
      t:ClearAllPoints()
      t:SetPoint("TOPLEFT", main, "TOPRIGHT", plain and 2 or 0, -(SIDE_TOP + (slot - 1) * step))
      t:Show()
    else
      t:Hide()
    end
  end
  local a = main.sideArrows
  a:SetShown(over)
  if over then
    a:ClearAllPoints()
    a:SetPoint("TOPLEFT", main, "TOPRIGHT", 4, -(SIDE_TOP + fit * step))
    a.up:SetEnabled(off > 0)
    a.down:SetEnabled(off < n - fit)
  end
end

local function refreshTabs()
  if not main then return end
  local ids = dockedIds()
  local c = conf(MAIN)
  local bottom, side = bottomIds(), sideList()
  local found = false
  for _, id in ipairs(ids) do if id == c.selected then found = true end end
  if not found then c.selected = side[1] or bottom[1] end    -- (Boards first: Hard Counters' own, on the side since 2026-11-24)
  local prev
  for i, id in ipairs(bottom) do
    local b = main.tabs[i]
    if not b then
      b = newTab(i)
      main.tabs[i] = b
    end
    dressTab(b, id, id == c.selected)
    b:ClearAllPoints()
    if prev then b:SetPoint("LEFT", prev, "RIGHT", b.blizzard and 3 or 2, 0)
    else b:SetPoint("TOPLEFT", main, "BOTTOMLEFT", b.blizzard and 11 or 8, b.blizzard and 2 or 0) end
    b:SetScript("OnClick", function() Win.Show(id, true) end)
    b:Show()
    prev = b
  end
  for i = #bottom + 1, #main.tabs do main.tabs[i]:Hide() end
  main.tabCount = #bottom
  main.sideList, main.sideSelected = side, nil
  for i, id in ipairs(side) do
    local t = main.sideTabs[i]
    if not t then
      t = newSideTab(i)
      main.sideTabs[i] = t
    end
    local def = defs[id]
    t.hcId = id
    t.tooltipText = def.title or id
    t.Icon:SetTexture(def.icon or ICON)
    if t.blizzard then t:SetChecked(id == c.selected) else t.sel:SetShown(id == c.selected) end
    if id == c.selected then main.sideSelected = i end
  end
  layoutSide(true)
  refreshHelpButtons()
  setClamp()
  main.empty:SetShown(#ids == 0)
  -- (2026-11-24) Hard Counters' own tabs are icons now: the title says which one is open
  local sel = defs[c.selected]
  setTitle(main, sel and sel.title and format("%s: %s", L["Hard Counters"], sel.title) or L["Hard Counters"])
end

--- The open tab's name for the header (its title; "This tab" before any is open).
local function selTitle()
  local def = defs[conf(MAIN).selected]
  return def and def.title or L["This tab"]
end

--- The header follows the open tab (0.4.0): the tab's def.about on the left. (0.5.0, the user: "Collapse the
--- tutorial trio of action buttons into a Help that expands to current view help, current view tutorial, the grand
--- tutorial and the Guide") one Help button; its menu names the open tab.
function refreshHelpButtons()
  if not (main and main.help) then return end
  if main.about then
    local def = defs[conf(MAIN).selected]
    main.about:SetText(def and type(def.about) == "string" and L[def.about] or "")
  end
end
Win.RefreshHelpButtons = refreshHelpButtons

--- The Help button's menu: this tab's page and tutorial (greyed on a tab with no help: a pack that brought none),
--- the full tutorial, the Guide.
function Win.HelpItems()
  local sel = conf(MAIN).selected
  local has = ns.Help and ns.Help.For(sel) ~= nil
  local title = selTitle()
  local items = {
    { text = format(L['Help for "%s"'], title), disabled = not has, func = function() ns.Help.Show(nil) end,
      tip = L["One page on this tab: what it is, what you can do in it, and how that changes what you see while you play."] },
    { text = format(L['Tutorial for "%s"'], title), disabled = not has, func = function() ns.Help.Tour(nil, 1) end,
      tip = L["A few steps through this tab only: what is where, and what to click. The window stays open beside it."] },
  }
  if ns.Tutorial then
    items[#items + 1] = { text = L["Full tutorial"], func = function() ns.Tutorial.Show(1) end,
      tip = L["All of Hard Counters from its first step: the boards on your screen, a first board for your class, then this window tab by tab."] }
  end
  if defs.guide then
    items[#items + 1] = { text = L["Open the Guide"], disabled = sel == "guide", func = function() Win.Show("guide", true) end,
      tip = L["Everything the tutorials say, to read at your own pace."] }
  end
  return items
end

--- Header buttons: one per window with def.mainButton, right to left; their text says shown or not.
function refreshHeader()
  refreshHelpButtons()
  if not (main and main.header) then return end
  for id, b in pairs(main.header) do
    b:SetText((Win.IsShown(id) and L["Hide %s"] or L["Show %s"]):format(defs[id].mainButton))
    local fs = b:GetFontString()
    b:SetWidth(max(floor((fs and fs:GetStringWidth() or 60) + 24), 80))
  end
end

local function buildHeader()
  main.header = {}
  if not main.help and (ns.Help or ns.Tutorial) then
    main.help = Wd.Button(main, L["Help"], 70, function(self) ns.Menu.Show(self, Win.HelpItems()) end)
    main.help:SetHeight(22)
    main.help:SetPoint("TOPRIGHT", main.panel and -10 or -8, main.headerY)
    Wd.RichTip(main.help, function() return { title = L["Help"],
      text = format(L["The open tab's help page and tutorial (%s), the full tutorial, and the Guide."], selTitle()),
      click = L["Click: choose one."] } end)
    Wd.RightMenu(main.help, function() return Win.HelpItems() end)
    -- the open tab's one line, left of the button (0.4.0): two lines at most
    main.about = main:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    main.about:SetPoint("TOPLEFT", main, "TOPLEFT", main.panel and 66 or 10, main.headerY + 1)
    main.about:SetPoint("RIGHT", main.help, "LEFT", -10, 0)
    main.about:SetHeight(26)
    main.about:SetJustifyH("LEFT")
    main.about:SetJustifyV("MIDDLE")
    main.about:SetTextColor(0.85, 0.85, 0.85)
  end
  local prev = main.help
  for _, id in ipairs(order) do
    local def = defs[id]
    if def.mainButton then
      local b = Wd.Button(main, def.mainButton, 100, function() Win.Show(id, nil) end)
      b:SetHeight(22)
      b:ClearAllPoints()
      if prev then b:SetPoint("RIGHT", prev, "LEFT", -4, 0)
      else b:SetPoint("TOPRIGHT", main.panel and -10 or -8, main.headerY) end
      main.header[id] = b
      prev = b
    end
  end
  refreshHeader()
end

local function arrowButton(parent, dir, onClick)
  local b = CreateFrame("Button", nil, parent)
  b:SetSize(24, 24)
  local path = "Interface\\Buttons\\UI-ScrollBar-Scroll" .. dir .. "Button-"
  b:SetNormalTexture(path .. "Up")
  b:SetPushedTexture(path .. "Down")
  b:SetDisabledTexture(path .. "Disabled")
  b:SetHighlightTexture(path .. "Highlight", "ADD")
  b:SetScript("OnClick", onClick)
  return b
end

local function ensureMain()
  if main then return main end
  main = newHost(MAIN_NAME, MAIN, {
    title = L["Hard Counters"], portrait = true, header = true, fixedSize = true,
  })
  main.tabs, main.sideTabs = {}, {}
  -- content sits on a canvas in a scroll frame: a tab taller than the body scrolls (DESIGN §17.2)
  main.scroll = CreateFrame("ScrollFrame", nil, main.body)
  main.canvas = CreateFrame("Frame", nil, main.scroll)
  main.canvas:SetSize(1, 1)
  main.scroll:SetScrollChild(main.canvas)
  main.scroll:SetScript("OnMouseWheel", function(_, delta) setScroll((main.scrollOff or 0) - (delta or 0) * 40) end)
  main.scrollBar = Wd.VScroll(main.body, function(off) setScroll(off) end)
  main.scrollBar:SetPoint("TOPRIGHT", main.body, "TOPRIGHT", 0, 0)
  main.scrollBar:SetPoint("BOTTOMRIGHT", main.body, "BOTTOMRIGHT", 0, 0)
  main.sideArrows = CreateFrame("Frame", nil, main)
  main.sideArrows:SetSize(50, 24)
  main.sideArrows.up = arrowButton(main.sideArrows, "Up", function() sideWheel(nil, 1) end)
  main.sideArrows.up:SetPoint("LEFT", 0, 0)
  main.sideArrows.down = arrowButton(main.sideArrows, "Down", function() sideWheel(nil, -1) end)
  main.sideArrows.down:SetPoint("LEFT", main.sideArrows.up, "RIGHT", 2, 0)
  main.sideArrows:Hide()
  main.empty = Wd.Text(main.body, "GameFontDisable", "TOPLEFT", 12, -12, 280)
  main.empty:SetText(L["No windows yet."])
  main.close:SetScript("OnClick", function()
    local sel = conf(MAIN).selected
    if sel and defs[sel] and defs[sel].remember then conf(sel).shown = false end
    main:Hide()
  end)
  buildHeader()
  layoutMain()
  refreshTabs()
  -- (0.5.0, A3; the user: "when ctrl+k is entered the control should jump to search box") the window listens to keys
  -- and passes every one on to the game, except Ctrl+K when the open tab has a search box. Out of combat only: the
  -- game refuses to change a frame's key passing in a fight, so in combat Ctrl+K is the game's.
  if main.EnableKeyboard and main.SetPropagateKeyboardInput then
    pcall(main.EnableKeyboard, main, true)
    pcall(main.SetPropagateKeyboardInput, main, true)
    main:SetScript("OnKeyDown", function(self, key) Win.OnKey(self, key) end)
  end
  return main
end

--- The open tab's search box, or nil.
local function searchBox()
  local sel = conf(MAIN).selected
  local b = sel and ns.Browser and ns.Browser.For(Win.Content(sel))
  return b and b.searchBox or nil
end

--- A key pressed while the window is shown (A3): Ctrl+K puts the cursor in the open tab's search box.
function Win.OnKey(self, key)
  local ctrl = rawget(_G, "IsControlKeyDown")
  if key ~= "K" or not (ctrl and ctrl()) or not (ns.Browser and ns.Browser.SearchKeyOn()) or ns.wow.inCombat() then return end
  local box = searchBox()
  if not (box and box:IsShown()) then return end
  -- keep this one key from the game, then pass keys on again at once
  if pcall(self.SetPropagateKeyboardInput, self, false) then
    C_Timer.After(0, function() if not ns.wow.inCombat() then pcall(self.SetPropagateKeyboardInput, self, true) end end)
  end
  box:SetFocus()
  if box.HighlightText then box:HighlightText() end
  return true
end

---------------------------------------------------------------------------
-- Content
---------------------------------------------------------------------------

local function ensureContent(id)
  local e = entries[id]
  if e.content then return e.content end
  local body = isDocked(id) and ensureMain().canvas or ensureHost(id).body
  local f = CreateFrame("Frame", nil, body)
  f:SetAllPoints(body)
  f:Hide()
  e.content, e.body, e.visible = f, body, false
  safe(defs[id].build, f)
  return f
end

function attach(id)
  local e = entries[id]
  local content = ensureContent(id)
  local body = isDocked(id) and ensureMain().canvas or ensureHost(id).body
  if e.body ~= body then
    content:SetParent(body)
    content:ClearAllPoints()
    content:SetAllPoints(body)
    e.body = body
  end
end

---------------------------------------------------------------------------
-- Public (through HardCounters:RegisterWindow / ShowWindow / ...)
---------------------------------------------------------------------------

--- def = { title, build(content), onShow(content), onHide(content), onClose(), width, height, minWidth, minHeight,
---   minSize() -> w, h, fixedHeight() -> h|nil, maxWidth, maxHeight, dockable (false: a frame of its own, never a tab), mainButton, remember, escape,
---   chrome ("panel" | "hud"), strata, frameName, migrate(conf, settings), icon (texture path or file id: the tab's
---   icon), tabOrder (Hard Counters' own side tabs' order), about (one line on what happens in this tab, shown in the
---   header; 0.4.0), place ("bottom": one of Hard Counters' own along the bottom) and bottomOrder }. Sizes are the
---   content's (the host adds its chrome). side: a pack's window (HC:RegisterWindow): a tab along the bottom.
function Win.Register(id, def, side)
  if defs[id] then return false, "window already registered: " .. tostring(id) end
  if type(def) ~= "table" or type(def.build) ~= "function" then return false, "def.build(content) is required" end
  if def.icon ~= nil and type(def.icon) ~= "string" and type(def.icon) ~= "number" then
    return false, "def.icon must be a texture path or a file id"
  end
  if def.about ~= nil and type(def.about) ~= "string" then return false, "def.about must be a string (one line)" end
  defs[id] = def
  order[#order + 1] = id
  entries[id] = {}
  packIds[id] = side and true or nil
  if main then
    if def.mainButton then
      for _, b in pairs(main.header) do b:Hide() end
      buildHeader()
    end
    refreshTabs()
    layoutMain()                         -- a new tab may need a bigger panel
  end
  -- registered after login (a load-on-demand pack): restore it now
  if ns.ready and def.remember and conf(id).shown then Win.Show(id, true) end
  return true
end

function Win.IsShown(id) return entries[id] and entries[id].visible or false end

function Win.Show(id, show)
  local def = defs[id]
  if not def then return false end
  if show == nil then show = not Win.IsShown(id) end
  if def.remember then conf(id).shown = show and true or false end
  if show then
    attach(id)
    if isDocked(id) then
      if conf(MAIN).selected ~= id then main.scrollOff = 0 end     -- another tab starts at its top
      conf(MAIN).selected = id
      refreshTabs()
      layoutMain()
      main:Show()
    else
      layoutStandalone(id)
      entries[id].host:Show()
      entries[id].host:Raise()
    end
  elseif isDocked(id) then
    if main and main:IsShown() and conf(MAIN).selected == id then main:Hide() end
  elseif entries[id].host then
    entries[id].host:Hide()
  end
  syncAll()
  return true
end

function Win.Toggle(id) return Win.Show(id, nil) end

--- Pop-out is gone (2026-11-15): a window's place is fixed by def.dockable. True only when asked for the place it
--- already has; nothing moves.
function Win.SetDocked(id, docked)
  if not defs[id] then return false end
  return isDocked(id) == (docked and true or false)
end

function Win.IsDocked(id) return defs[id] and isDocked(id) or false end
function Win.CanDock(id) return canDock(id) and true or false end

--- Re-apply size bounds after a content change (e.g. the run panel's compact view).
function Win.Relayout(id)
  if not defs[id] then return end
  if isDocked(id) then
    if conf(MAIN).selected == id then layoutMain() end
  else
    layoutStandalone(id)
  end
end

function Win.ResetSize(id)
  local c = conf(id)
  c.width, c.height = nil, nil
  Win.Relayout(id)
end

function Win.SetScale(id, scale)
  conf(id).scale = scale
  local e = entries[id]
  if e and e.host then e.host:SetScale(scale) end
end

function Win.Scale(id)
  local e = entries[id]
  return (e and e.host and e.host:GetScale()) or conf(id).scale or 1
end

--- The shared frame: show, hide or toggle (nil). Shows the selected tab.
function Win.ShowMain(show)
  ensureMain()
  if show == nil then show = not main:IsShown() end
  if show then
    refreshTabs()
    local sel = conf(MAIN).selected
    if sel then Win.Show(sel, true) else layoutMain(); main:Show() end
  else
    main:Hide()
  end
  syncAll()
end

function Win.HasDocked() return #dockedIds() > 0 end
--- The packs' windows (and Diagnostics, last): the tabs along the bottom, in order. The tutorial and the Guide name them.
function Win.PackWindows() return packWindowIds() end
--- Every tab along the bottom, in order (Overview, the packs' windows, Options, Diagnostics).
function Win.BottomTabs() return bottomIds() end
--- The open tab of the shared window (its id), or nil before the window was ever built.
function Win.Selected() return main and conf(MAIN).selected or nil end
function Win.List() local out = {} for i, id in ipairs(order) do out[i] = id end return out end
function Win.Def(id) return defs[id] end
function Win.Content(id) return entries[id] and entries[id].content end
function Win.Host(id)
  if id == MAIN then return main end
  return entries[id] and entries[id].host
end

ns.OnReady(function()
  -- the pop-out choice saved before 2026-11-15 means nothing now: drop it
  local w = ns.settings and ns.settings.windows
  if type(w) == "table" then
    for _, c in pairs(w) do if type(c) == "table" then c.docked = nil end end
    -- nor does a size dragged before the shared frame stopped resizing (2026-11-23)
    if type(w[MAIN]) == "table" then w[MAIN].width, w[MAIN].height = nil, nil end
    -- (0.4.0) the tabs were renamed: the open tab saved under an old id opens its new home. "overview" and "boards"
    -- are ids in both schemes, so this runs once (tabsV)
    local m = w[MAIN]
    if type(m) == "table" and m.tabsV ~= 2 then
      local moved = { overview = "boards", boards = "explorer", trackers = "explorer", runs = "stints" }
      if m.selected and moved[m.selected] then m.selected = moved[m.selected] end
      m.tabsV = 2
    end
    -- (0.5.0) the window grew: a scale saved at 0.4's default (1, written at every logout) takes the new default;
    -- a scale the player chose stays. Once (sizeV).
    if type(m) == "table" and m.sizeV ~= 1 then
      if m.scale == nil or m.scale == 1 then m.scale = MAIN_SCALE; if main then main:SetScale(MAIN_SCALE); layoutMain() end end
      m.sizeV = 1
    end
  end
  for _, id in ipairs(order) do
    if defs[id].remember and conf(id).shown then Win.Show(id, true) end
  end
end)

-- keep BlizzMove (Ctrl+wheel) scales across sessions
ns.On("PLAYER_LOGOUT", function()
  if main then conf(MAIN).scale = main:GetScale() end
  for id, e in pairs(entries) do if e.host then conf(id).scale = e.host:GetScale() end end
end, "Windows")

---------------------------------------------------------------------------
-- Public API (docs/API.md §9). Pack window ids are namespaced, like counters: "hcfarm:ledger".
---------------------------------------------------------------------------

function HC:RegisterWindow(id, def)
  if type(id) ~= "string" or not id:match("^[%w_]+:[%w_.%-]+$") then
    return false, "window id must be namespaced, e.g. \"mypack:main\""
  end
  return Win.Register(id, def, true)          -- a pack's window: a tab along the bottom (swapped 2026-11-24)
end
function HC:ShowWindow(id, show) return Win.Show(id, show) end
function HC:ToggleWindow(id) return Win.Show(id, nil) end
function HC:IsWindowShown(id) return Win.IsShown(id) end
function HC:RelayoutWindow(id) return Win.Relayout(id) end

---------------------------------------------------------------------------
-- Options: the shared frame's scale (its size is fixed) and how its bottom tabs are labelled
---------------------------------------------------------------------------

ns.AddOptions("windows", function()
  local args = {}
  args.tabLabels = { type = "select", order = 80, name = L["Tab labels"],
    desc = L["The tabs along the bottom of the Hard Counters window. With icons only, hover a tab for its name."],
    values = { both = L["Icon and title"], title = L["Title only"], icon = L["Icon only"] },
    get = function() return labelMode() end,
    set = function(_, v) ns.settings.tabLabels = v; refreshTabs() end }
  args.searchKey = { type = "toggle", order = 85, width = "full", name = L["Ctrl+K jumps to the search box"],
    desc = L["While the Hard Counters window is open, Ctrl+K puts the cursor in the open tab's search box (the Explorer, Stints, Diagnostics). Not in combat: there it is the game's key."],
    get = function() return ns.Browser and ns.Browser.SearchKeyOn() end,
    set = function(_, v) if v then ns.settings.searchKey = nil else ns.settings.searchKey = false end end }
  args.scale = { type = "range", order = 90, name = L["Scale of the Hard Counters window"], min = 0.5, max = 2, step = 0.05,
    get = function() return (main and main:GetScale()) or conf(MAIN).scale or 1 end,
    set = function(_, v) conf(MAIN).scale = v; if main then main:SetScale(v); layoutMain() end end }
  return { type = "group", name = L["Windows"], inline = true, args = args }
end)

ns.AddSlash("windows", function() Win.ShowMain() end, L["open the Hard Counters window (also just /hc)"])
