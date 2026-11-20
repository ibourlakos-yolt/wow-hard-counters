-- Widgets: small frame helpers shared by the displays (plain frames and long-standing templates only).
-- Also the pieces every window shares (UI/Windows.lua): saved placement, the resize grip, BlizzMove.
local ADDON, ns = ...

local W = {}
ns.Widgets = W

local floor = math.floor

--- Saved window state: settings.windows[key] = { pos, width, height, scale, locked, docked, shown }. Read at call
--- time (a profile switch replaces ns.settings). `seed(c, settings)` fills a new entry, e.g. from older keys.
function W.Conf(key, seed)
  local s = ns.settings
  s.windows = s.windows or {}
  local c = s.windows[key]
  if not c then
    c = {}
    s.windows[key] = c
    if seed then pcall(seed, c, s) end
  end
  return c
end

--- { point, x, y, relativePoint } of a frame's first anchor, for W.PlaceAt.
function W.SavedPoint(f)
  local point, _, rel, x, y = f:GetPoint(1)
  if not point then return nil end
  return { point, floor((x or 0) + 0.5), floor((y or 0) + 0.5), rel or point }
end

function W.PlaceAt(f, pos)
  f:ClearAllPoints()
  if type(pos) == "table" and pos[1] then f:SetPoint(pos[1], UIParent, pos[4] or pos[1], pos[2] or 0, pos[3] or 0)
  else f:SetPoint("CENTER") end
end

function W.SetResizeBounds(f, minW, minH, maxW, maxH)
  if f.SetResizeBounds then f:SetResizeBounds(minW, minH, maxW, maxH)
  elseif f.SetMinResize then
    f:SetMinResize(minW, minH)
    if f.SetMaxResize then f:SetMaxResize(maxW, maxH) end
  end
end

--- Pin a frame by its top-left corner (same place on screen). Sizing a frame anchored by its CENTER moves both
--- edges, so the window grew by twice the mouse movement and jumped on a slight drag (in-game, 2026-11-15).
function W.PinTopLeft(f)
  local left, top = f:GetLeft(), f:GetTop()
  if not (left and top) then return end
  f:ClearAllPoints()
  f:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top)
end

--- A resize grip in the bottom-right corner. canSize() may veto (a locked window); done(f) runs after a resize.
--- While the grip is held, f.sizing is true: layout code must not set the size then (it would fight the mouse).
function W.Grip(f, canSize, done, inset)
  f:SetResizable(true)
  inset = inset or 2
  local grip = CreateFrame("Button", nil, f)
  grip:SetSize(16, 16)
  grip:SetPoint("BOTTOMRIGHT", -inset, inset)
  grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
  grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
  grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
  grip:SetScript("OnMouseDown", function(_, button)
    if button ~= "LeftButton" or (canSize and not canSize()) then return end
    W.PinTopLeft(f)
    f.sizing = true
    f:StartSizing("BOTTOMRIGHT")
  end)
  grip:SetScript("OnMouseUp", function()
    if not f.sizing then return end
    f:StopMovingOrSizing()
    f.sizing = nil
    W.PinTopLeft(f)          -- StopMovingOrSizing may re-anchor; keep the saved point a top-left one
    if done then done(f) end
  end)
  f.grip = grip
  return grip
end

--- BlizzMove (if installed) moves a named frame and scales it with Ctrl+mouse wheel. Its API is optional and may
--- change: never let it break a window. Returns true if the registration call went through.
--- extra: more of BlizzMove's frame data. Boards pass NonDraggable: a draggable frame gets EnableMouse(true), mouse
--- hooks and a SetPoint hook that puts it back where BlizzMove last dragged it, which fought our own moving (a board
--- snapped back after a move by its name bar, 2026-11-20); NonDraggable keeps only Ctrl+wheel scaling.
function W.BlizzMove(f, name, extra)
  local api = rawget(_G, "BlizzMoveAPI")
  if not name or type(api) ~= "table" or type(api.RegisterAddOnFrames) ~= "function" then return false end
  local data = { FrameReference = f, Versions = { Forever = true, Mainline = true }, SilenceCompatabilityWarnings = true }
  for k, v in pairs(extra or {}) do data[k] = v end
  return (pcall(api.RegisterAddOnFrames, api, { [ADDON] = { [name] = data } }))
end

--- Make a plain window resizable, BlizzMove-aware and remembered under settings.windows[key]: position, size and
--- scale. onResize(f) runs after every size change. For popups that are not registered windows (copy box, run card).
function W.Remember(f, key, minW, minH, onResize)
  local c = W.Conf(key)
  W.SetResizeBounds(f, minW, minH, 2000, 1400)
  if c.width and c.height then f:SetSize(math.max(c.width, minW), math.max(c.height, minH)) end
  if c.pos then W.PlaceAt(f, c.pos) end
  if c.scale then f:SetScale(c.scale) end
  W.Grip(f, nil, function(self)
    local cc = W.Conf(key)
    cc.width, cc.height = floor(self:GetWidth() + 0.5), floor(self:GetHeight() + 0.5)
    cc.pos = W.SavedPoint(self)
  end)
  f:HookScript("OnDragStop", function(self) W.Conf(key).pos = W.SavedPoint(self) end)
  f:HookScript("OnHide", function(self) W.Conf(key).scale = self:GetScale() end)
  if onResize then f:SetScript("OnSizeChanged", onResize) end
  W.BlizzMove(f, f:GetName())
end

--- A movable dark window with a title and a close button. Position is saved under settings[posKey] when given.
function W.Window(name, width, height, title, posKey)
  local f = CreateFrame("Frame", name, UIParent)
  f:SetSize(width, height)
  f:SetFrameStrata("MEDIUM")
  f:SetMovable(true)
  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetClampedToScreen(true)
  f:SetScript("OnDragStart", function(self)
    if posKey and ns.settings[posKey .. "Locked"] then return end
    self:StartMoving()
  end)
  f:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    if posKey then
      local point, _, _, x, y = self:GetPoint(1)
      ns.settings[posKey] = { point, x, y }
    end
  end)
  local bg = f:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  bg:SetColorTexture(0.05, 0.05, 0.07, 0.9)
  f.bg = bg
  if title then
    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.title:SetPoint("TOPLEFT", 10, -8)
    f.title:SetText(title)
  end
  f.close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
  f.close:SetPoint("TOPRIGHT", 2, 2)
  W.Place(f, posKey)
  return f
end

function W.Place(f, posKey)
  f:ClearAllPoints()
  local pos = posKey and ns.settings[posKey]
  if type(pos) == "table" and pos[1] then f:SetPoint(pos[1], UIParent, pos[1], pos[2] or 0, pos[3] or 0)
  else f:SetPoint("CENTER") end
end

function W.Button(parent, text, width, onClick)
  local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  b:SetSize(width, 20)
  b:SetText(text)
  b:SetScript("OnClick", onClick)
  return b
end

--- Width from the button's text (plus padding), at least minW.
function W.FitWidth(b, minW, pad)
  local fs = b.GetFontString and b:GetFontString()
  local tw = fs and fs.GetStringWidth and fs:GetStringWidth()
  if type(tw) ~= "number" then tw = 0 end
  b:SetWidth(math.max(floor(tw + (pad or 24)), minW or 40))
end

function W.Text(parent, font, point, x, y, width, justify)
  local s = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlightSmall")
  s:SetPoint(point or "TOPLEFT", x or 0, y or 0)
  if width then s:SetWidth(width) end
  s:SetJustifyH(justify or "LEFT")
  return s
end

--- A tooltip on hover; textFn(frame) returns the text.
function W.Tip(frame, textFn)
  frame:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText(textFn(self), 1, 1, 1, 1, true)
    GameTooltip:Show()
  end)
  frame:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

--- Value of a run reading for a saved run record (same rules as HardCounters:RunReading for the open run).
--- calc: nil for the reading's default (DESIGN §16.9).
function W.RecordReading(r, rec, calc)
  local v
  calc = calc or ns.DefaultCalc(r)
  -- (a record has no recent rate: it is kept only while a window counts, HC-52; so no trend either)
  if not ns.CalcAllowed(r, calc) or calc == "recent" or calc == "trend" then return nil, ns.FormatReading(r, nil) end
  if r.compute then
    local ok, x = pcall(r.compute, function(id, _, c)
      local o = ns.readings[id]
      return o and (W.RecordReading(o, rec, c)) or nil
    end, "run", nil, calc)
    v = ok and type(x) == "number" and x or nil
  elseif r.best then
    local L = rec.live and rec.live[r.counter]
    v = L and L.max and L.max.v or nil
  else
    local d = rec.deltas and rec.deltas[r.counter]
    -- a record saved from tile windows (HC-30, before HC-41) holds only the counters they watched: no value, not 0
    if not d and rec.partial then return nil, ns.FormatReading(r, nil) end
    v = d and d[r.measure or "sum"] or 0
    if r.minus then
      local m = rec.deltas[r.minus]
      v = v - (m and m[r.measure or "sum"] or 0)
    end
    if calc == "perHour" then v = ns.U.perHour(v, rec.activeSeconds) end
  end
  return v, ns.FormatReading(r, v, calc)
end

--- The headline reading id: the player's choice, else the first reading marked headline, else the first one.
function W.HeadlineId()
  local chosen = ns.settings.runPanel and ns.settings.runPanel.headline
  if chosen and ns.readings[chosen] and ns.readings[chosen].scopeSet.run then return chosen end
  for _, id in ipairs(ns.readingOrder) do if ns.readings[id].headline then return id end end
  return ns.readingOrder[1]
end

--- r, g, b for a run reading's value: white, or grey while a rate hasn't settled (HC:RunReading's third value).
function W.ReadingColor(settled)
  if settled == false then return 0.5, 0.5, 0.5 end
  return 1, 1, 1
end
