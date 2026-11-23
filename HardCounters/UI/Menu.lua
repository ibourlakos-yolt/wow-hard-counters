-- Menu: a small popup menu of our own (right-click on a board tile or strip, the [+] reading picker). Plain frames
-- only: no dependence on the client's dropdown templates, which differ between clients. One menu at a time; a
-- click outside, Escape or a choice closes it.
--
--   ns.Menu.Show(anchorFrame, { { text = "Scope", sub = { ... } }, { text = "Remove", func = fn },
--     { text = "today (needs history)", disabled = true }, { text = "Run", checked = true, func = fn } })
local ADDON, ns = ...

local Menu = {}
ns.Menu = Menu

local ROW_H, PAD, MIN_W = 18, 6, 140
local levels = {}          -- [1] = the menu, [2] = an open submenu
local catcher              -- full-screen click catcher behind the menu

local function hideFrom(level)
  for i = #levels, level, -1 do
    local f = levels[i]
    if f then f:Hide() end
    levels[i] = nil
  end
  if level <= 1 and catcher then catcher:Hide() end
end

function Menu.Hide() hideFrom(1) end
function Menu.IsShown() return levels[1] ~= nil and levels[1]:IsShown() end

local pool = {}
local function frameFor(level)
  local f = pool[level]
  if f then return f end
  f = CreateFrame("Frame", "HardCountersMenu" .. level, UIParent)
  f:SetFrameStrata("FULLSCREEN_DIALOG")
  f:SetFrameLevel(10 + level * 5)
  f:EnableMouse(true)
  f:SetClampedToScreen(true)
  local bg = f:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  bg:SetColorTexture(0.06, 0.06, 0.08, 0.96)
  f.rows = {}
  f:Hide()
  if level == 1 then tinsert(UISpecialFrames, f:GetName()) end    -- Escape closes it
  f:SetScript("OnHide", function() if level == 1 then hideFrom(2); if catcher then catcher:Hide() end end end)
  pool[level] = f
  return f
end

local function row(f, i)
  local b = f.rows[i]
  if b then return b end
  b = CreateFrame("Button", nil, f)
  b:SetHeight(ROW_H)
  b:SetPoint("TOPLEFT", PAD, -PAD - (i - 1) * ROW_H)
  b:SetPoint("TOPRIGHT", -PAD, -PAD - (i - 1) * ROW_H)
  b.hl = b:CreateTexture(nil, "HIGHLIGHT")
  b.hl:SetAllPoints()
  b.hl:SetColorTexture(1, 1, 1, 0.12)
  b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  b.text:SetPoint("LEFT", 14, 0)
  b.text:SetPoint("RIGHT", -12, 0)
  b.text:SetJustifyH("LEFT")
  b.check = b:CreateTexture(nil, "OVERLAY")         -- a texture: the game's fonts lack most symbol glyphs
  b.check:SetSize(12, 12)
  b.check:SetPoint("LEFT", 0, 0)
  b.check:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")
  b.arrow = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  b.arrow:SetPoint("RIGHT", -2, 0)
  b.arrow:SetText(">")
  f.rows[i] = b
  return b
end

local show
local function fill(level, anchor, items, side)
  local f = frameFor(level)
  local w = MIN_W
  for i, item in ipairs(items) do
    local b = row(f, i)
    b.text:SetText(item.text or "")
    local tw = b.text.GetStringWidth and b.text:GetStringWidth() or 0
    if type(tw) == "number" and tw + 40 > w then w = tw + 40 end
    b.check:SetShown(item.checked and true or false)
    b.arrow:SetShown(item.sub ~= nil)
    if item.disabled or item.title then b.text:SetTextColor(0.5, 0.5, 0.5) else b.text:SetTextColor(1, 1, 1) end
    if item.title then b.text:SetTextColor(1, 0.82, 0) end
    b:SetScript("OnEnter", function(self)
      hideFrom(level + 1)
      if item.sub and not item.disabled then show(level + 1, self, item.sub, "RIGHT") end
      if item.tip and GameTooltip then
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(item.tip, 1, 1, 1, 1, true)
        GameTooltip:Show()
      end
    end)
    b:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
    b:SetScript("OnClick", function()
      if item.title or item.sub then return end
      if item.disabled and not item.onDisabled then return end
      -- a checkbox in a list of them (the Filters menu): the menu stays up and redraws from its builder
      if item.keepOpen and level == 1 then
        if item.func then
          local ok, err = pcall(item.func)
          if not ok and ns.Error then ns.Error(err) end
        end
        if Menu.builder then fill(1, anchor, Menu.builder()) end
        return
      end
      Menu.Hide()
      local fn = item.disabled and item.onDisabled or item.func
      if fn then
        local ok, err = pcall(fn)
        if not ok and ns.Error then ns.Error(err) end
      end
    end)
    b:Show()
  end
  for i = #items + 1, #f.rows do f.rows[i]:Hide() end
  f:SetSize(w, #items * ROW_H + 2 * PAD)
  f:ClearAllPoints()
  if side == "RIGHT" then f:SetPoint("TOPLEFT", anchor, "TOPRIGHT", 2, PAD)
  else f:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -2) end
  f:Show()
  levels[level] = f
end
show = fill

--- Show a menu under `anchor` (a frame). items: { text, func, disabled, onDisabled, checked, title, tip, sub,
--- keepOpen }, or a function returning them: then a keepOpen item's click runs it and the menu redraws in place.
function Menu.Show(anchor, items)
  Menu.Hide()
  Menu.builder = type(items) == "function" and items or nil
  if Menu.builder then items = Menu.builder() end
  if type(items) ~= "table" or #items == 0 then return end
  if not catcher then
    catcher = CreateFrame("Button", nil, UIParent)
    catcher:SetAllPoints(UIParent)
    catcher:SetFrameStrata("FULLSCREEN_DIALOG")
    catcher:SetFrameLevel(1)
    catcher:RegisterForClicks("AnyUp")
    catcher:SetScript("OnClick", function() Menu.Hide() end)
  end
  catcher:Show()
  fill(1, anchor, items)
end
