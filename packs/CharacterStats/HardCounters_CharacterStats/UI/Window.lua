-- The Character Stats window (DESIGN §6): a tab of the shared Hard Counters window listing every stat this
-- character uses, by section, with each section's on switch. `/hc stats` toggles it. Values come from the same
-- readings as the boards (HC:Reading(id, "now")); greyed with "(in combat)" when the game keeps them secret.
-- Only Hard Counters' public API.
local ADDON, ns = ...

local HC = HardCounters
if not (HC and ns.STATS and HC.Supports and HC:Supports("windows")) then return end

local ipairs, floor = ipairs, math.floor

local WINDOW = "hcstats:window"
ns.WINDOW = WINDOW
local HEAD_H, ROW_H, TOP, PAD = 22, 16, -8, 12
local WIDTH = 300
-- room for every section open and every row used: the window never needs a scroll bar
local HEIGHT = -TOP + #ns.TRACKERS * HEAD_H + #ns.STATS * ROW_H + 16

local win
local lines = {}

local function line(i)
  local l = lines[i]
  if l then return l end
  l = CreateFrame("Button", nil, win)
  l:SetHeight(ROW_H)
  l.name = l:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  l.name:SetPoint("LEFT", 0, 0)
  l.name:SetJustifyH("LEFT")
  l.value = l:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  l.value:SetPoint("RIGHT", 0, 0)
  l.value:SetJustifyH("RIGHT")
  l.button = CreateFrame("Button", nil, l, "UIPanelButtonTemplate")
  l.button:SetSize(70, 18)
  l.button:SetPoint("RIGHT", 0, 0)
  l.button:SetText("Turn on")
  l:SetScript("OnEnter", function(self)
    if not self.tip then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(self.tipTitle or "", 1, 1, 1)
    GameTooltip:AddLine(self.tip, 0.8, 0.8, 0.8, true)
    GameTooltip:Show()
  end)
  l:SetScript("OnLeave", function() GameTooltip:Hide() end)
  lines[i] = l
  return l
end

local function place(l, y, indent)
  l:ClearAllPoints()
  l:SetPoint("TOPLEFT", PAD + indent, y)
  l:SetPoint("TOPRIGHT", -PAD, y)
end

--- Redraw every line. Returns the number of lines used (for tests).
local function refresh()
  if not (win and win:IsShown()) then return 0 end
  local y, n = TOP, 0
  for _, t in ipairs(ns.TRACKERS) do
    local on = HC:IsTrackerOn(t.id)
    n = n + 1
    local h = line(n)
    place(h, y, 0)
    h:SetHeight(HEAD_H)
    h.name:SetFontObject("GameFontNormal")
    h.name:SetText(t.title)
    h.value:SetText("")
    h.button:SetShown(not on)
    h.button:SetScript("OnClick", function() HC:SetTrackerOn(t.id, true); refresh() end)
    h.tip, h.tipTitle = t.description, t.title
    h:Show()
    y = y - HEAD_H
    if on then
      for i, s in ipairs(ns.STATS) do
        local id = ns.IDS[i]
        if s[3] == t.id and HC:ReadingApplies(id) then
          local _, text, _, state = HC:Reading(id, "now")
          n = n + 1
          local l = line(n)
          place(l, y, 10)
          l:SetHeight(ROW_H)
          l.name:SetFontObject("GameFontHighlightSmall")
          l.button:Hide()
          local stale = state == "stale"
          -- in combat: the game's value handed straight to the font string where it is one value (CS-9)
          local lv, fmt
          if stale and HC.ReadingLive then lv, fmt = HC:ReadingLive(id) end
          if lv ~= nil then
            l.name:SetText(s[2])
            l.value:SetFormattedText(fmt, lv)
            l.value:SetTextColor(1, 1, 1)
          else
            l.name:SetText(stale and (s[2] .. "  (in combat)") or s[2])
            l.value:SetText(text or "-")
            if stale then l.value:SetTextColor(0.5, 0.5, 0.5) else l.value:SetTextColor(1, 1, 1) end
          end
          l.tip, l.tipTitle = s[7], s[2]
          l:Show()
          y = y - ROW_H
        end
      end
    end
  end
  for i = n + 1, #lines do lines[i]:Hide() end
  return n
end
ns.RefreshWindow = refresh

local function build(f)
  win = f
  local elapsed = 0
  -- while the window is open: twice a second (values are asked of the game, nothing is cached but the last read)
  f.tick = function(_, dt)
    elapsed = elapsed + (dt or 0)
    if elapsed < 0.5 then return end
    elapsed = 0
    refresh()
  end
end

HC:RegisterWindow(WINDOW, {
  title = "Character Stats",
  width = WIDTH, height = HEIGHT, minWidth = WIDTH, minHeight = floor(HEIGHT),
  build = build,
  onShow = function(f) f:SetScript("OnUpdate", f.tick); refresh() end,
  onHide = function(f) f:SetScript("OnUpdate", nil) end,
})

function ns.ToggleWindow() HC:ToggleWindow(WINDOW) end

if HC:Supports("slash") then
  HC:RegisterSlash("stats", function() ns.ToggleWindow() end, "the Character Stats window", "Character Stats")
end
