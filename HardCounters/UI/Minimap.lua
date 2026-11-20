-- Minimap button (LibDBIcon-1.0, embedded 2026-11-15): click opens the Hard Counters window, shift-click shows or
-- hides the run panel, right-click opens the options; the tooltip is the bar feed's. LibDBIcon keeps the button's
-- place on the minimap edge and "hidden" in settings.minimap. It isn't an LDB feed of its own (no extra entry in
-- Titan Panel and the like): the launcher table goes to LibDBIcon only.
local ADDON, ns = ...

local L = ns.L
local DBI = LibStub and LibStub("LibDBIcon-1.0", true)
if not DBI then return end

local NAME = "HardCounters"

-- The same launcher is also an entry in the game's AddOns menu (HC-45, always on, no option): LibDBIcon puts it
-- there when the settings table says showInCompartment. That entry is named NAME ("HardCounters"), as LibDBIcon
-- labels it; it shares the tooltip, which tells the two apart by its owner.
local launcher = {
  type = "launcher", label = L["Hard Counters"], icon = ns.ICON,
  OnClick = function(_, button) ns.LauncherClick(button) end,
  OnTooltipShow = function(tt)
    local owner = tt.GetOwner and tt:GetOwner()
    ns.LauncherTooltip(tt, owner ~= nil and owner == DBI:GetMinimapButton(NAME))
  end,
}

local DEFAULT_POS = 290    -- not LibDBIcon's 225, where every undragged button lands (see Core/Settings.lua)

local function db()
  local s = ns.settings
  if type(s.minimap) ~= "table" then s.minimap = {} end
  if s.minimap.minimapPos == nil then s.minimap.minimapPos = DEFAULT_POS end
  s.minimap.showInCompartment = true
  return s.minimap
end

local function inMenu() return DBI.IsButtonCompartmentAvailable and DBI:IsButtonCompartmentAvailable() end

local function setShown(show)
  db().hide = not show
  if show then DBI:Show(NAME) else DBI:Hide(NAME) end
  if not show then
    ns.Print(inMenu() and L["Minimap button hidden. Hard Counters is still in the AddOns menu, or type /hc minimap."]
      or L["Minimap button hidden. Type /hc minimap to bring it back."])
  end
end

ns.OnReady(function()
  local ok, err = pcall(DBI.Register, DBI, NAME, launcher, db())
  if not ok then ns.Error(err) end
end)

-- a profile switch replaces ns.settings: point the button at the new profile's place
local previous = ns.OnSettingsChanged
function ns.OnSettingsChanged()
  if previous then previous() end
  if DBI:IsRegistered(NAME) then pcall(DBI.Refresh, DBI, NAME, db()) end
end

ns.AddOptions("minimap", {
  type = "group", name = L["Minimap button"], inline = true,
  args = {
    shown = { type = "toggle", order = 1, name = L["Show the minimap button"],
      get = function() return not db().hide end, set = function(_, v) setShown(v) end },
  },
})

ns.AddSlash("minimap", function() setShown(db().hide and true or false) end, L["show or hide the minimap button"])
