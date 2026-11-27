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
  -- a popup shares MEDIUM with the Hard Counters window and Blizzard's panels: the one clicked last is on top
  -- (DESIGN §17.5). Without it the run card stayed under the window (HC-65 probe, 2026-11-23).
  f:SetToplevel(true)
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

--- An action button: Blizzard's red-and-gold panel button. It does something when clicked (New board..., Delete,
--- Reset). A state the player can switch is a W.Status instead (0.4.0, the user: "Only here / On HUD is not an action
--- button; it's a status button. We have to differentiate them visually").
function W.Button(parent, text, width, onClick)
  local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  b:SetSize(width, 20)
  b:SetText(text)
  b:SetScript("OnClick", onClick)
  return b
end

--- Right-click opens a menu (0.5.0, the user: "right-click is the player's best friend"): itemsFn(frame) returns
--- ns.Menu items (or nil for no menu). On a Button the left click keeps its OnClick: call this after setting it.
--- On any other frame it takes OnMouseUp, keeping one set before. W.rightMenus counts the frames given a menu.
W.rightMenus = 0
function W.RightMenu(frame, itemsFn)
  if not (frame and itemsFn) then return frame end
  W.rightMenus = W.rightMenus + 1
  local function open(self)
    local ok, items = pcall(itemsFn, self)
    if not ok then if ns.Error then ns.Error(items) end return end
    if type(items) == "table" and #items > 0 and ns.Menu then ns.Menu.Show(self, items) end
  end
  frame.hcRightMenu = open
  local okT, objType = pcall(frame.GetObjectType, frame)
  if okT and (objType == "Button" or objType == "CheckButton") then
    frame:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    local orig = frame:GetScript("OnClick")
    frame:SetScript("OnClick", function(self, button, ...)
      if button == "RightButton" then open(self) elseif orig then orig(self, button, ...) end
    end)
  else
    frame:EnableMouse(true)
    local orig = frame:GetScript("OnMouseUp")
    frame:SetScript("OnMouseUp", function(self, button, ...)
      if button == "RightButton" then open(self) elseif orig then orig(self, button, ...) end
    end)
  end
  return frame
end

--- A tooltip in the house style (0.4.0: every action and status button has one): a white title, a body, then the
--- state in colour (status buttons) and a grey "Click: ..." line. spec(frame) -> { title, text, state, on, click }.
function W.RichTip(frame, spec)
  frame:SetScript("OnEnter", function(self)
    if not GameTooltip then return end
    local ok, s = pcall(spec, self)
    if not ok or type(s) ~= "table" then return end
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText(s.title or "", 1, 1, 1, 1, true)
    if s.state then
      local r, g, b = 0.6, 0.6, 0.6
      if s.on == true then r, g, b = 0.4, 1, 0.4 elseif s.on == "warn" then r, g, b = 1, 0.82, 0 end
      GameTooltip:AddLine(s.state, r, g, b, true)
    end
    if s.text then GameTooltip:AddLine(s.text, 0.85, 0.85, 0.85, true) end
    if s.click then GameTooltip:AddLine(s.click, 0.5, 0.5, 0.5, true) end
    GameTooltip:Show()
  end)
  frame:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
end

local STATUS_ON, STATUS_OFF, STATUS_WARN = { 0.25, 0.85, 0.35 }, { 0.5, 0.5, 0.5 }, { 1, 0.75, 0.1 }

--- A status button: it shows a state and switches it when clicked (On HUD / Only here, a tracker on or off). Not a
--- Blizzard button: a dark flat pill with a coloured lamp on the left (green: on, grey: off, amber: needs
--- attention), the state's word beside it and a thin border in the lamp's colour, so it reads as a switch, never as
--- an action. b:SetState(text, on) sets both (on: true, false or "warn"); onClick(self) does the switching.
function W.Status(parent, width, onClick)
  local b = CreateFrame("Button", nil, parent)
  b:SetSize(width, 20)
  b.bg = b:CreateTexture(nil, "BACKGROUND")
  b.bg:SetAllPoints()
  b.bg:SetColorTexture(0.06, 0.06, 0.08, 0.9)
  b.edges = {}
  for i, side in ipairs({ "TOP", "BOTTOM", "LEFT", "RIGHT" }) do
    local t = b:CreateTexture(nil, "BORDER")
    if i <= 2 then
      t:SetPoint(side .. "LEFT", b, side .. "LEFT", 0, 0)
      t:SetPoint(side .. "RIGHT", b, side .. "RIGHT", 0, 0)
    else
      t:SetPoint("TOP" .. side, b, "TOP" .. side, 0, 0)
      t:SetPoint("BOTTOM" .. side, b, "BOTTOM" .. side, 0, 0)
    end
    W.Hairline(t, i <= 2)
    b.edges[i] = t
  end
  b.lamp = b:CreateTexture(nil, "ARTWORK")
  b.lamp:SetSize(8, 8)
  b.lamp:SetPoint("LEFT", 7, 0)
  b.lamp:SetTexture("Interface\\Buttons\\WHITE8X8")
  b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  b.text:SetPoint("LEFT", b.lamp, "RIGHT", 6, 0)
  b.text:SetPoint("RIGHT", -6, 0)
  b.text:SetJustifyH("LEFT")
  b.text:SetWordWrap(false)
  local hl = b:CreateTexture(nil, "HIGHLIGHT")
  hl:SetAllPoints()
  hl:SetColorTexture(1, 1, 1, 0.08)
  b.isStatus = true
  function b.SetState(self, text, on)
    self.stateText, self.stateOn = text, on
    self.text:SetText(text or "")
    local c = on == "warn" and STATUS_WARN or (on and STATUS_ON or STATUS_OFF)
    self.lamp:SetVertexColor(c[1], c[2], c[3], 1)
    for _, t in ipairs(self.edges) do t:SetColorTexture(c[1], c[2], c[3], on and 0.7 or 0.45) end
    self.text:SetTextColor(on and 1 or 0.75, on and 1 or 0.75, on and 1 or 0.75)
  end
  -- (Wd.FitWidth and the tests read it like a button's)
  function b.SetText(self, text) self:SetState(text, self.stateOn) end
  function b.GetText(self) return self.stateText end
  function b.GetFontString(self) return self.text end
  b:SetScript("OnClick", onClick)
  b:SetState("", false)
  return b
end

--- A 1-pixel line that stays 1 pixel (0.4.0: the Boards tab's panel borders vanished while scrolling and the gaps
--- between panels looked uneven). A 1-unit texture is less than a screen pixel when the UI scale is small, so the
--- pixel grid rounds it to 0 or 1 pixel depending on where a scroll leaves it. PixelUtil (where the client has it)
--- sizes it in physical pixels, at least one. horizontal: a height, else a width.
function W.Hairline(t, horizontal)
  local PU = rawget(_G, "PixelUtil")
  local set = PU and (horizontal and PU.SetHeight or PU.SetWidth)
  if type(set) ~= "function" or not pcall(set, t, 1, 1) then
    if horizontal then t:SetHeight(1) else t:SetWidth(1) end
  end
  return t
end

--- A button that looks like a dropdown: a dark field with the chosen value on the left and a down arrow on the
--- right (plain frames: the client's dropdown templates differ between clients). onClick(self) opens its menu
--- (ns.Menu.Show(self, items)); SetText sets the chosen value.
function W.Dropdown(parent, width, onClick)
  local b = CreateFrame("Button", nil, parent)
  b:SetSize(width, 22)
  local bg = b:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  bg:SetColorTexture(0, 0, 0, 0.55)
  b.edges = {}
  for i, side in ipairs({ "TOP", "BOTTOM", "LEFT", "RIGHT" }) do
    local t = b:CreateTexture(nil, "BORDER")
    t:SetColorTexture(0.45, 0.45, 0.5, 0.9)
    if i <= 2 then
      t:SetPoint(side .. "LEFT", b, side .. "LEFT", 0, 0)
      t:SetPoint(side .. "RIGHT", b, side .. "RIGHT", 0, 0)
      t:SetHeight(1)
    else
      t:SetPoint("TOP" .. side, b, "TOP" .. side, 0, 0)
      t:SetPoint("BOTTOM" .. side, b, "BOTTOM" .. side, 0, 0)
      t:SetWidth(1)
    end
    b.edges[i] = t
  end
  local hl = b:CreateTexture(nil, "HIGHLIGHT")
  hl:SetAllPoints()
  hl:SetColorTexture(1, 1, 1, 0.08)
  b.arrow = b:CreateTexture(nil, "ARTWORK")
  b.arrow:SetSize(20, 20)
  b.arrow:SetPoint("RIGHT", -1, 0)
  b.arrow:SetTexture("Interface\\ChatFrame\\UI-ChatIcon-ScrollDown-Up")
  b.value = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  b.value:SetPoint("LEFT", 8, 0)
  b.value:SetPoint("RIGHT", b.arrow, "LEFT", -2, 0)
  b.value:SetJustifyH("LEFT")
  b.value:SetWordWrap(false)
  b.SetText = function(self, text) self.value:SetText(text) end
  b.GetText = function(self) return self.value:GetText() end
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

--- A slim vertical scroll bar for a pooled list (no scroll template: they differ between clients). Plain Slider.
--- onScroll(offset) runs when the player drags it; bar:SetRange(maxOffset) and bar:SetOffset(n) never call it.
--- Hidden while there is nothing to scroll. Read the offset from the callback, never from GetValue.
function W.VScroll(parent, onScroll)
  local s = CreateFrame("Slider", nil, parent)
  s:SetWidth(12)
  s:SetOrientation("VERTICAL")
  s:SetValueStep(1)
  if s.SetObeyStepOnDrag then s:SetObeyStepOnDrag(true) end
  local track = s:CreateTexture(nil, "BACKGROUND")
  track:SetAllPoints()
  track:SetColorTexture(0, 0, 0, 0.35)
  s:SetThumbTexture("Interface\\Buttons\\UI-ScrollBar-Knob")
  s.max, s.quiet = 0, false
  s:SetScript("OnValueChanged", function(self, value)
    if self.quiet then return end
    if type(value) == "number" and onScroll then onScroll(floor(value + 0.5)) end
  end)
  function s.SetRange(self, maxOffset)
    self.max = math.max(0, maxOffset or 0)
    self.quiet = true
    self:SetMinMaxValues(0, math.max(self.max, 0))
    self.quiet = false
    self:SetShown(self.max > 0)
  end
  function s.SetOffset(self, n)
    self.quiet = true
    self:SetValue(n or 0)
    self.quiet = false
  end
  s:SetRange(0)
  return s
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
