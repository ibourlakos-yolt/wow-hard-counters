-- The bar feed (LibDataBroker-1.1): Titan Panel, ElvUI, ChocolateBar, Bazooka (DESIGN §7).
-- One "Hard Counters" object: text = the open run's headline (else Gold/h this session); tooltip = run state, active
-- time, the headline, today's net when gold has history, and the click hints (TRACKERS_AND_BOARDS §6.6); click
-- opens the Hard Counters window, shift-click shows or hides the boards, ctrl-click edits them, right-click the
-- options (the minimap button, UI/Minimap.lua, does the same). Plus one data object per view registered with
-- feed = true. Updated every 5 s and on run events.
local ADDON, ns = ...

local HC, L, U, Wd = ns.HC, ns.L, ns.U, ns.Widgets
local LDB = LibStub("LibDataBroker-1.1", true)
if not LDB then return end

local main
local feeds = {}

--- A view's total as display text (its formatter, "/h" for per-hour views). The live number's, before boards.
local function formatValue(view, v)
  if v == nil then return "-" end
  local def = HC:GetView(view) or {}
  local c = def.counter and ns.counters[def.counter]
  local f = def.formatter or (c and c.formatter)
  local text = ns.FormatValue(f, v)
  if def.per == "activeHour" then text = text .. "/h" end
  return text
end
ns.FormatViewValue = formatValue

local function mainText()
  local hid = Wd.HeadlineId()
  if HC:GetRun() and hid then
    local _, text, settled = HC:RunReading(hid)
    if text and settled == false then return "|cff808080" .. text .. "|r" end
    return text or "-"
  end
  if ns.readings["hc:goldph"] then
    local v, text, _, st = HC:Reading("hc:goldph", "session")
    if st == nil and v ~= nil then return text end
  end
  return L["Hard Counters"]
end

local function update()
  if not main then return end
  local ok, text = pcall(mainText)
  main.text = ok and text or "?"
  for id, obj in pairs(feeds) do
    local rows = HC:Query(id)
    obj.text = ns.FormatViewValue(id, rows and rows.total)
  end
end
ns.UpdateBroker = update

local function tooltip(tt, onMinimap)
  tt:AddLine(L["Hard Counters"])
  local run = HC:GetRun()
  -- Trimmed (HC-16, TRACKERS_AND_BOARDS §6.6): the whole run panel here covered Questie's tracker. Run state and
  -- active time, the headline, the hints; boards are where the numbers live.
  if run then
    local active, _, state = HC:GetRunClock()
    tt:AddDoubleLine(run.label or ("#" .. run.id), state, 1, 1, 1, 1, 0.82, 0)
    tt:AddDoubleLine(L["active"], U.duration(active), 0.8, 0.8, 0.8, 1, 1, 1)
    local hid = Wd.HeadlineId()
    if hid then
      local _, text, settled = HC:RunReading(hid)
      local r, g, b = Wd.ReadingColor(settled)
      tt:AddDoubleLine(ns.readings[hid].title, text or "-", 0.8, 0.8, 0.8, r, g, b)
    end
  else
    tt:AddLine(L["no run open"], 0.7, 0.7, 0.7)
  end
  -- today's net, only when gold keeps daily history (no history: no "today")
  if ns.readings["hc:net"] then
    local v, text, _, st = HC:Reading("hc:net", "today")
    if st == nil and v ~= nil then tt:AddDoubleLine(L["Net gold today"], text, 0.8, 0.8, 0.8, 1, 1, 1) end
  end
  tt:AddLine(" ")
  -- on the minimap button the hint says where it can be hidden (HC-45); the AddOns menu shares this tooltip
  tt:AddLine(onMinimap
    and L["Click: Hard Counters window. Shift-click: boards. Ctrl-click: edit every board. Right-click: new board, options (you can hide this button there)."]
    or L["Click: Hard Counters window. Shift-click: boards. Ctrl-click: edit every board. Right-click: new board, options."],
    0.5, 0.5, 0.5, true)
end

-- The right-click menu opens at the cursor: the AddOns menu's entry closes its menu on click, so it can't anchor one
local cursorAnchor
local function atCursor()
  if not cursorAnchor then
    cursorAnchor = CreateFrame("Frame", nil, UIParent)
    cursorAnchor:SetSize(1, 1)
  end
  local x, y
  if GetCursorPosition then x, y = GetCursorPosition() end
  local s = UIParent:GetEffectiveScale()
  cursorAnchor:ClearAllPoints()
  cursorAnchor:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", (x or 0) / s, (y or 0) / s)
  return cursorAnchor
end

--- Shared by the bar feed, the minimap button and its AddOns-menu entry. onMinimap: the minimap button itself.
function ns.LauncherTooltip(tt, onMinimap)
  local ok, err = pcall(tooltip, tt, onMinimap)
  if not ok then ns.Error(err) end
end

function ns.LauncherClick(button)
  if button == "RightButton" then
    -- HC-42 b: new board, edit, options (it opened Options alone before)
    if ns.Boards and ns.Menu then ns.Menu.Show(atCursor(), ns.Boards.LauncherItems()) else ns.OpenOptions() end
  elseif IsShiftKeyDown() then ns.ToggleBoards()
  elseif IsControlKeyDown() and ns.Boards then ns.Boards.SetEditing(not ns.Boards.IsEditing())
  else ns.Windows.ShowMain() end
end

local function create()
  main = LDB:NewDataObject("Hard Counters", {
    type = "data source", text = L["Hard Counters"], label = L["Hard Counters"],
    icon = ns.ICON,
    OnClick = function(_, button) ns.LauncherClick(button) end,
    OnTooltipShow = ns.LauncherTooltip,
  })
  for _, id in ipairs(HC:Views()) do
    local def = HC:GetView(id)
    if def.feed then
      feeds[id] = LDB:NewDataObject("HC: " .. (def.title or id), { type = "data source", text = "-", label = def.title or id,
        icon = ns.ICON })
    end
  end
  update()
  ns.Every(5, update)
end

-- Packs register their views while loading; create the objects once the player is in the world.
local created = false
ns.On("PLAYER_ENTERING_WORLD", function()
  if created or not ns.ready or not ns.settings.ldb then return end
  created = true
  create()
end)

local owner = {}
for _, ev in ipairs({ "HC_RUN_STARTED", "HC_RUN_STOPPED", "HC_RUN_PAUSED", "HC_RUN_RESUMED" }) do
  HC.RegisterCallback(owner, ev, function() update() end)
end
