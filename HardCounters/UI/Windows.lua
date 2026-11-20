-- Windows: every Hard Counters window, and any pack's, through one host (DESIGN §7.1). A window is a tab of the
-- shared "Hard Counters" frame, always: there is no pop-out (user, 2026-11-15, after popping every tab out left an
-- empty frame with no way back). Only a window that says dockable = false (a HUD, a popup) gets a frame of its own.
-- Hard Counters owns the chrome, so every window gets the same: Blizzard's panel frame (border, title, close,
-- inset), drag to move, resize grip, Escape, BlizzMove (Ctrl+mouse wheel scales), raise on click, and its
-- position, size and scale saved under settings.windows[id]. A HUD window (chrome = "hud") gets a plain dark frame
-- instead.
--
-- Content never shows or hides itself: the host shows the content frame exactly while the window is on screen and
-- calls def.onShow / def.onHide on those changes, so a refresh ticker can follow them.
local ADDON, ns = ...

local HC, L, Wd = ns.HC, ns.L, ns.Widgets
local floor, max, min = math.floor, math.max, math.min

local MAIN, MAIN_NAME = "_main", "HardCountersMain"
local MAX_W, MAX_H = 1600, 1200
local MAIN_MIN_W = 340                 -- portrait, title, header buttons
local ICON = "Interface\\Icons\\INV_Misc_PocketWatch_01"
ns.ICON = ICON

-- Blizzard panel chrome (ButtonFrameTemplate): title bar 24, the "attic" under it down to 60 when there's a
-- portrait; the inset sits 4 / 6 / 4 inside the border; content gets 4 more inside the inset.
local PANEL_TOP, PANEL_TOP_PORTRAIT = 24, 60
local INSET_L, INSET_R, INSET_B, PAD = 4, 6, 4, 4
-- the plain chrome (HUD windows, and the fallback if the template is missing)
local FLAT_TITLE, HEADER_H = 26, 26

local defs, order = {}, {}
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
local refreshHeader

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

--- opts = { title, portrait, hud, header, strata, onSized(host) }
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
  Wd.Grip(f, function() return not conf(key).locked end, opts.onSized, f.panel and 6 or 2)
  f.grip:SetFrameLevel(lvl)
  Wd.PlaceAt(f, conf(key).pos)
  f:SetScale(conf(key).scale or 1)
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
-- The shared frame: a tab per docked window along the bottom (like the character panel), and a header row with
-- a button per window that asks for one (def.mainButton: the run panel)
---------------------------------------------------------------------------

local function layoutMain()
  if not main then return end
  local c, sel = conf(MAIN), conf(MAIN).selected
  local mw, mh = 300, 120
  if sel and defs[sel] then mw, mh = bodyMin(sel) end
  mw = max(mw, MAIN_MIN_W - main.padW)
  local pw, ph = main.padW, main.padH
  local maxW, maxH = screenMax(main, MAX_W, MAX_H, mw, mh)
  Wd.SetResizeBounds(main, mw + pw, mh + ph, maxW + pw, maxH + ph)
  -- Escape closes the frame unless its tab is a window that stays up
  setEscape(MAIN_NAME, not (sel and defs[sel] and defs[sel].escape == false))
  if main.sizing then return end
  local w = clamp(c.width or (sel and defs[sel].width) or mw, mw, maxW)
  local h = clamp(c.height or (sel and defs[sel].height) or mh, mh, maxH)
  main:SetSize(w + pw, h + ph)
end

local SELECT, DESELECT, RESIZE = "PanelTemplates_SelectTab", "PanelTemplates_DeselectTab", "PanelTemplates_TabResize"

local function newTab(i)
  local b
  if type(G(SELECT)) == "function" then
    local ok, t = pcall(CreateFrame, "Button", MAIN_NAME .. "Tab" .. i, main, "PanelTabButtonTemplate")
    if ok and widget(t) then b, t.blizzard = t, true end
  end
  if not b then
    b = Wd.Button(main, "", 80, nil)
    b:SetHeight(22)
  end
  return b
end

local function refreshTabs()
  if not main then return end
  local ids = dockedIds()
  local c = conf(MAIN)
  local found = false
  for _, id in ipairs(ids) do if id == c.selected then found = true end end
  if not found then c.selected = ids[1] end
  local prev
  for i, id in ipairs(ids) do
    local b = main.tabs[i]
    if not b then
      b = newTab(i)
      main.tabs[i] = b
    end
    b:SetText(defs[id].title or id)
    b:ClearAllPoints()
    if prev then b:SetPoint("LEFT", prev, "RIGHT", b.blizzard and 3 or 2, 0)
    else b:SetPoint("TOPLEFT", main, "BOTTOMLEFT", b.blizzard and 11 or 8, b.blizzard and 2 or 0) end
    if b.blizzard then
      pcall(G(RESIZE), b, 0)
      pcall(G(id == c.selected and SELECT or DESELECT), b)
    else
      local fs = b:GetFontString()
      b:SetWidth(max(floor((fs and fs:GetStringWidth() or 50) + 24), 60))
      b:SetEnabled(id ~= c.selected)
    end
    b:SetScript("OnClick", function() Win.Show(id, true) end)
    b:Show()
    prev = b
  end
  for i = #ids + 1, #main.tabs do main.tabs[i]:Hide() end
  main.empty:SetShown(#ids == 0)
end

--- Header buttons: one per window with def.mainButton, right to left; their text says shown or not.
function refreshHeader()
  if not (main and main.header) then return end
  for id, b in pairs(main.header) do
    b:SetText((Win.IsShown(id) and L["Hide %s"] or L["Show %s"]):format(defs[id].mainButton))
    local fs = b:GetFontString()
    b:SetWidth(max(floor((fs and fs:GetStringWidth() or 60) + 24), 80))
  end
end

local function buildHeader()
  main.header = {}
  local prev
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

local function ensureMain()
  if main then return main end
  main = newHost(MAIN_NAME, MAIN, {
    title = L["Hard Counters"], portrait = true, header = true,
    onSized = savedSize(MAIN),
  })
  main.tabs = {}
  main.empty = Wd.Text(main.body, "GameFontDisable", "TOPLEFT", 12, -12, 280)
  main.empty:SetText(L["No windows yet."])
  main.close:SetScript("OnClick", function()
    local sel = conf(MAIN).selected
    if sel and defs[sel] and defs[sel].remember then conf(sel).shown = false end
    main:Hide()
  end)
  buildHeader()
  refreshTabs()
  layoutMain()
  return main
end

---------------------------------------------------------------------------
-- Content
---------------------------------------------------------------------------

local function ensureContent(id)
  local e = entries[id]
  if e.content then return e.content end
  local body = isDocked(id) and ensureMain().body or ensureHost(id).body
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
  local body = isDocked(id) and ensureMain().body or ensureHost(id).body
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
---   chrome ("panel" | "hud"), strata, frameName, migrate(conf, settings) }. Sizes are the content's (the host
---   adds its chrome).
function Win.Register(id, def)
  if defs[id] then return false, "window already registered: " .. tostring(id) end
  if type(def) ~= "table" or type(def.build) ~= "function" then return false, "def.build(content) is required" end
  defs[id] = def
  order[#order + 1] = id
  entries[id] = {}
  if main then
    if def.mainButton then
      for _, b in pairs(main.header) do b:Hide() end
      buildHeader()
    end
    refreshTabs()
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
  return Win.Register(id, def)
end
function HC:ShowWindow(id, show) return Win.Show(id, show) end
function HC:ToggleWindow(id) return Win.Show(id, nil) end
function HC:IsWindowShown(id) return Win.IsShown(id) end
function HC:RelayoutWindow(id) return Win.Relayout(id) end

---------------------------------------------------------------------------
-- Options: the shared frame's scale and size
---------------------------------------------------------------------------

ns.AddOptions("windows", function()
  local args = {}
  args.scale = { type = "range", order = 90, name = L["Scale of the Hard Counters window"], min = 0.5, max = 2, step = 0.05,
    get = function() return (main and main:GetScale()) or conf(MAIN).scale or 1 end,
    set = function(_, v) conf(MAIN).scale = v; if main then main:SetScale(v) end end }
  args.reset = { type = "execute", order = 91, name = L["Reset its size"],
    func = function() local c = conf(MAIN); c.width, c.height = nil, nil; layoutMain() end }
  return { type = "group", name = L["Windows"], inline = true, args = args }
end)

ns.AddSlash("windows", function() Win.ShowMain() end, L["open the Hard Counters window (also just /hc)"])
