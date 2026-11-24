-- A new character's first login (HC-74, the user 2026-11-24): M.Seed gives it the Leveling board, in front of it,
-- and marks `boards.welcome`. Here, once per account, a small window next to that board introduces the Hard Counters
-- window (the central panel: Overview, Boards, Trackers, Runs) and how to copy another character's boards. Later new
-- characters get one chat line instead. DIALOG strata, like the New board dialog; Escape closes it.
local ADDON, ns = ...

local L, Wd = ns.L, ns.Widgets

local Welcome = {}
ns.Welcome = Welcome

local f

local function text()
  return L["The Leveling board on the right is this character's own: its numbers, live. Right-click it to edit it,"
    .. " hide it or add numbers."] .. "\n\n"
    .. L["Everything else is in the Hard Counters window (the minimap button, or /hc):"] .. "\n"
    .. "  - " .. L["Overview: every number you follow, board by board"] .. "\n"
    .. "  - " .. L["Boards: show, hide and find your boards; make new ones"] .. "\n"
    .. "  - " .. L["Trackers: what is counted, and numbers to add"] .. "\n"
    .. "  - " .. L["Runs: your recorded runs and dungeons"] .. "\n\n"
    .. L["Each character has its own boards. To use another character's: Boards, New board..., Start from,"
    .. " Copy of a board. Then change it as you like."]
end

local function build()
  local ok
  ok, f = pcall(CreateFrame, "Frame", "HardCountersWelcome", UIParent, "ButtonFrameTemplate")
  if not ok or type(f) ~= "table" then
    f = CreateFrame("Frame", "HardCountersWelcome", UIParent)
    local bg = f:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.05, 0.05, 0.07, 0.95)
  end
  f:Hide()
  f:SetSize(400, 300)
  f:SetPoint("CENTER", UIParent, "CENTER", -140, 40)
  f:SetFrameStrata("DIALOG")
  f:SetToplevel(true)
  f:EnableMouse(true)
  f:SetMovable(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", function(self) self:StartMoving() end)
  f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
  f:SetClampedToScreen(true)
  local hide = rawget(_G, "ButtonFrameTemplate_HidePortrait")
  if type(hide) == "function" then pcall(hide, f) end
  if type(f.SetTitle) == "function" then pcall(f.SetTitle, f, L["Welcome to Hard Counters"])
  elseif type(f.TitleContainer) == "table" and type(f.TitleContainer.TitleText) == "table" then
    f.TitleContainer.TitleText:SetText(L["Welcome to Hard Counters"])
  end
  if type(f.CloseButton) == "table" then f.CloseButton:SetScript("OnClick", function() f:Hide() end) end
  tinsert(UISpecialFrames, "HardCountersWelcome")              -- Escape closes it
  f.body = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  f.body:SetPoint("TOPLEFT", 20, -36)
  f.body:SetPoint("TOPRIGHT", -20, -36)
  f.body:SetJustifyH("LEFT")
  f.body:SetJustifyV("TOP")
  f.body:SetSpacing(2)
  f.body:SetText(text())
  f.open = Wd.Button(f, L["Open the window"], 140, function()
    f:Hide()
    if ns.ShowOverview then ns.ShowOverview(true) end
  end)
  f.open:SetPoint("BOTTOMRIGHT", -112, 10)
  f.ok = Wd.Button(f, L["Got it"], 90, function() f:Hide() end)
  f.ok:SetPoint("BOTTOMRIGHT", -16, 10)
end

--- Show the introduction now (also `/hc welcome`, to read it again).
function Welcome.Show()
  if not f then build() end
  f:Show()
  f:Raise()
  return f
end

--- After a login: a new character's starter board was just made (boards.welcome). The account's first one gets the
--- introduction; later ones a chat line. Returns "window", "line" or nil.
function Welcome.Check()
  local M = ns.BoardModel
  if not (M and ns.charSettings) then return nil end
  M.Seed()
  local B = M.Store()
  if not B.welcome then return nil end
  B.welcome = nil
  local G = ns.globalSettings or {}
  if not G.introSeen then
    G.introSeen = true
    Welcome.Show()
    return "window"
  end
  if ns.Print then
    ns.Print(L["A Leveling board for this character. To copy another character's board: /hc boards, New board..."])
  end
  return "line"
end

ns.On("PLAYER_ENTERING_WORLD", function()
  if not ns.ready then return end
  -- after the loading screen, so it isn't lost behind it
  C_Timer.After(2, function() Welcome.Check() end)
end, "Welcome")

ns.AddSlash("welcome", function() Welcome.Show() end, L["the introduction to Hard Counters, again"])
ns.WelcomeFrame = function() return f end           -- (tests)
