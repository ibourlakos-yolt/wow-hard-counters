-- The Options tab (0.4.0, the user: "attach it to the secondary tabs at the bottom; it should be a facsimile of the
-- options menu from /hc options; it should no longer be displayed in a separate window"). The very panel /hc options
-- opened (UI/Options.lua's AceConfig table: General, History, Profiles), drawn inside this tab: AceConfigDialog feeds
-- a container it is given (AceConfigDialog-3.0.lua, Open with a container: it releases the container's children,
-- marks it custom and redraws it after each change). The container is an AceGUI SimpleGroup laid over the tab's
-- frame, made when the tab shows and released when it hides (AceGUI pools its widgets). A change made elsewhere (a
-- profile switch, a slash command) redraws it through AceConfigRegistry's ConfigTableChange.
-- Without AceGUI (tests, a broken install) the tab says so and /hc options falls back to nothing worse.
local ADDON, ns = ...

local L = ns.L
local floor = math.floor

local ID = "options"
local content, container, pending, sizing
local MIN_W, MIN_H = 600, 420

local function libs()
  local LS = rawget(_G, "LibStub")
  if not LS then return nil end
  return LS("AceGUI-3.0", true), LS("AceConfigDialog-3.0", true), LS("AceConfigRegistry-3.0", true)
end

--- The container takes the tab's size, once per real change. (0.5.0-beta2, the user: opening Options froze the window
--- and BugSack logged "insecure scripts exceeded execution limit", ten times.) A SimpleGroup sizes itself to its
--- children (LayoutFinished), which made AceGUI lay the panel out again, which sized the group again: a loop that
--- never settles once heights come back a fraction off (the window draws at scale 1.08 since 0.5.0, and the pixel grid
--- rounds). The container now keeps the tab's size (noAutoHeight), whole numbers only, and a size call made while
--- one runs is dropped.
local function size()
  if sizing or not (container and content) then return end
  local w, h = content:GetWidth(), content:GetHeight()
  if type(w) ~= "number" or type(h) ~= "number" or w <= 0 or h <= 0 then return end
  w, h = floor(w + 0.5), floor(h + 0.5)
  if container.hcW == w and container.hcH == h then return end
  container.hcW, container.hcH = w, h
  sizing = true
  container:SetWidth(w)
  container:SetHeight(h)
  if container.DoLayout then
    local ok, err = pcall(container.DoLayout, container)
    if not ok and ns.Error then ns.Error(err) end
  end
  sizing = false
end

local function open()
  local GUI, ACD = libs()
  if not (content and GUI and ACD) then
    if content then content.none:Show() end
    return false
  end
  content.none:Hide()
  if not container then
    local ok, g = pcall(GUI.Create, GUI, "SimpleGroup")
    if not ok or type(g) ~= "table" then content.none:Show(); return false end
    container = g
    -- never sized by its children: the tab sizes it (see size())
    if container.SetAutoAdjustHeight then container:SetAutoAdjustHeight(false) else container.noAutoHeight = true end
    container.hcW, container.hcH = nil, nil
    container:SetLayout("Fill")
    container.frame:SetParent(content)
    container.frame:ClearAllPoints()
    container.frame:SetPoint("TOPLEFT", content, "TOPLEFT", 0, 0)
    container.frame:Show()
  end
  size()
  local ok, err = pcall(ACD.Open, ACD, ADDON, container)
  if not ok and ns.Error then ns.Error(err) end
  return ok
end

local function close()
  local GUI = libs()
  if container then
    -- AceGUI pools its widgets for every addon: hand the group back as it was lent
    container.noAutoHeight, container.hcW, container.hcH = nil, nil, nil
    if GUI then pcall(GUI.Release, GUI, container) end
  end
  container = nil
  sizing = false
end

--- (tests) the AceGUI container while the tab is shown.
function ns.OptionsContainer() return container end

local function build(f)
  content = f
  f.none = f:CreateFontString(nil, "OVERLAY", "GameFontDisable")
  f.none:SetPoint("TOPLEFT", 16, -16)
  f.none:SetPoint("TOPRIGHT", -16, -16)
  f.none:SetJustifyH("LEFT")
  -- luacheck: push no max line length
  f.none:SetText(L["The options need the Ace3 libraries that come with Hard Counters; they did not load. The game's options (Escape, Options, AddOns) may still list them."])
  -- luacheck: pop
  f.none:Hide()
  f:SetScript("OnSizeChanged", size)
end

ns.Windows.Register(ID, {
  title = L["Options"], icon = "Interface\\Icons\\INV_Misc_Wrench_01", place = "bottom", bottomOrder = 900,
  about = "Every setting in one place: the window, boards, history and storage, profiles.",
  width = 720, height = 480, minWidth = MIN_W, minHeight = MIN_H,
  build = build,
  onShow = function() open() end,
  onHide = function() close() end,
})

--- Show the Options tab; true when it is there to show.
function ns.ShowOptionsTab(show)
  return ns.Windows.Show(ID, show) and true or false
end

-- a change made elsewhere (a profile switch, a slash command): redraw on the next frame while the tab is shown
local _, _, ACR = libs()
if ACR and ACR.RegisterCallback then
  ACR.RegisterCallback(ns, "ConfigTableChange", function(_, app)
    if app ~= ADDON or not (content and content:IsShown()) or pending then return end
    pending = true
    C_Timer.After(0, function() pending = false; if content and content:IsShown() then open() end end)
  end)
end

-- This tab's help and tour (UI/Help.lua): change them with the tab.
-- luacheck: push no max line length
local _ = ns.Help and ns.Help.Register(ID, {
  what = "Options holds every setting of Hard Counters, the same as /hc options and the game's own options under AddOns: the window, boards and the move key, the minimap button, history and storage, Diagnostics, and profiles.",
  can = {
    "{General}: what \"this week\" means, the data broker feed, dungeon runs, the move key for boards, tab labels, the window's scale, the minimap button, automatic field notes.",
    "{History}: how many runs are kept, how many days, hours and weeks of history, and when your day ends.",
    "{Profiles}: share settings between characters, or keep one set each.",
  },
  effect = "A setting applies at once, except the hour the day ends, which waits for the next reload or login (the option says so). Boards stay each character's own whatever the profile.",
  tour = {
    { title = "Three tabs inside", text = "{General} for how things look and behave, {History} for what is kept and for how long, {Profiles} for sharing settings between characters." },
    { title = "Hover for the why", text = "Every option explains itself when you hover it: what it changes and what it costs on disk." },
  },
})
-- luacheck: pop
