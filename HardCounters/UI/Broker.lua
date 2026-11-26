-- The bar feed (LibDataBroker-1.1): Titan Panel, ElvUI, ChocolateBar, Bazooka (DESIGN §7).
-- One "Hard Counters" object: text = the open stint's headline (else Gold/h this session); tooltip (0.4.0) = a live
-- dashboard: this session, the stint, the boards on the HUD with their first tiles, today's net, what needs a look
-- (Shift: everything), and the click hints (TRACKERS_AND_BOARDS §6.6); click
-- opens the Hard Counters window, shift-click shows or hides the boards, ctrl-click edits them, right-click the
-- options (the minimap button, UI/Minimap.lua, does the same). Plus one data object per view registered with
-- feed = true. Updated every 5 s and on run events.
local ADDON, ns = ...

local HC, L, U, Wd = ns.HC, ns.L, ns.U, ns.Widgets
local format = string.format
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

-- (0.4.0, the user: "a more dynamic and interesting tooltip for the minimap button") A live dashboard, short by
-- default (HC-16: the old full run panel here covered Questie's tracker): the version, this session, the open stint
-- with its headline, up to three boards on your HUD with their first two tiles and their clocks, today's net gold,
-- and what needs a look. Hold Shift for the long form: every board with every tile, the trackers and their history.
-- It redraws once a second while it is up, and at once when Shift is pressed or let go.
local SHORT_BOARDS, SHORT_TILES, LONG_LINES = 3, 2, 40
local GREY, DIM = { 0.5, 0.5, 0.5 }, { 0.8, 0.8, 0.8 }

local function boardLines(tt, long)
  local M, Bo = ns.BoardModel, ns.Boards
  if not (M and Bo and ns.charSettings) then return end
  local list = M.Store().list
  local onHud, lines = {}, 0
  for _, b in ipairs(list) do if b.shown or long then onHud[#onHud + 1] = b end end
  if #list == 0 then
    tt:AddLine(L["No boards yet: right-click, New board..."], GREY[1], GREY[2], GREY[3])
    return
  end
  if #onHud == 0 then
    tt:AddLine(format(L["%d boards, none on your HUD"], #list), GREY[1], GREY[2], GREY[3])
    return
  end
  for i, b in ipairs(onHud) do
    if not long and i > SHORT_BOARDS then
      tt:AddLine(format(L["+%d more (hold Shift)"], #onHud - SHORT_BOARDS), GREY[1], GREY[2], GREY[3])
      break
    end
    local clock = Bo.ClockText(b) or ""
    tt:AddDoubleLine(b.shown and b.name or (b.name .. "  |cff808080" .. L["only here"] .. "|r"), clock, 1, 0.82, 0, 0.8, 0.8, 0.8)
    local n = 0
    for _, t in ipairs(b.tiles) do
      if t.kind == "reading" and M.TileOnHud(t) then
        n = n + 1
        if not long and n > SHORT_TILES then break end
        local ok, v, text, settled = pcall(M.TileValue, t, b)
        local r, g, bl = Wd.ReadingColor(ok and settled)
        if not ok or type(v) ~= "number" then r, g, bl = 0.6, 0.6, 0.6 end
        tt:AddDoubleLine("   " .. M.TileLabel(t, b), ok and text or "?", DIM[1], DIM[2], DIM[3], r, g, bl)
        lines = lines + 1
        if lines >= LONG_LINES then return end
      end
    end
  end
end

local function tooltip(tt, onMinimap)
  local long = IsShiftKeyDown and IsShiftKeyDown()
  tt:AddDoubleLine(L["Hard Counters"], tostring(HC.VERSION or ""), 1, 0.82, 0, 0.5, 0.5, 0.5)
  local s = ns.Session and ns.Session()
  local active = s and ns.Win and ns.Win.Active and ns.Win.Active(s)
  if active then tt:AddDoubleLine(L["This session"], format(L["%s active"], U.duration(active)), DIM[1], DIM[2], DIM[3], 1, 1, 1) end
  local run = HC:GetRun()
  if run then
    local ra, _, state = HC:GetRunClock()
    tt:AddDoubleLine(format(L["Stint: %s"], run.label or ("#" .. run.id)), (state == "running" and L["running"] or L["paused"]) .. " " .. U.duration(ra),
      1, 1, 1, state == "running" and 0.4 or 1, state == "running" and 1 or 0.82, state == "running" and 0.4 or 0)
    local hid = Wd.HeadlineId()
    if hid then
      local _, text, settled = HC:RunReading(hid)
      local r, g, b = Wd.ReadingColor(settled)
      tt:AddDoubleLine("   " .. ns.readings[hid].title, text or "-", DIM[1], DIM[2], DIM[3], r, g, b)
    end
  else
    tt:AddLine(L["No stint open"], GREY[1], GREY[2], GREY[3])
  end
  tt:AddLine(" ")
  boardLines(tt, long)
  -- today's net, only when gold keeps daily history (no history: no "today")
  if ns.readings["hc:net"] then
    local v, text, _, st = HC:Reading("hc:net", "today")
    if st == nil and v ~= nil then tt:AddDoubleLine(L["Net gold today"], text, DIM[1], DIM[2], DIM[3], 1, 1, 1) end
  end
  -- what needs a look (the Overview tab's list)
  local warn = {}
  if ns.OverviewEntries then
    local ok, list = pcall(ns.OverviewEntries)
    if ok then for _, e in ipairs(list) do if e.on == "warn" then warn[#warn + 1] = e end end end
  end
  if #warn > 0 then
    tt:AddLine(" ")
    if long then
      for _, e in ipairs(warn) do tt:AddDoubleLine("! " .. (e.label or ""), e.value or "", 1, 0.75, 0.1, 0.8, 0.8, 0.8) end
    else
      local one, many = L["! 1 thing needs a look (Overview tab; hold Shift)"], L["! %d things need a look (Overview tab; hold Shift)"]
      tt:AddLine(format(#warn == 1 and one or many, #warn), 1, 0.75, 0.1)
    end
  end
  if long then
    local on, hist = 0, 0
    for _, t in ipairs(HC:Trackers()) do
      if t.on then on = on + 1 end
      if t.on and t.history ~= "off" then hist = hist + 1 end
    end
    tt:AddLine(" ")
    tt:AddDoubleLine(L["Trackers counting"], format(L["%d, history kept by %d"], on, hist), DIM[1], DIM[2], DIM[3], 1, 1, 1)
  end
  tt:AddLine(" ")
  -- on the minimap button the hint says where it can be hidden (HC-45); the AddOns menu shares this tooltip
  tt:AddLine(onMinimap
    and L["Click: Hard Counters window. Shift-click: boards on or off. Ctrl-click: edit every board. Right-click: menu (you can hide this button in Options)."]
    or L["Click: Hard Counters window. Shift-click: boards on or off. Ctrl-click: edit every board. Right-click: menu."],
    GREY[1], GREY[2], GREY[3], true)
  if not long then tt:AddLine(L["Hold Shift for every board and tile."], GREY[1], GREY[2], GREY[3]) end
end

-- The tooltip stays live: while it is up for us (same tooltip, same owner), it is rebuilt once a second and when a
-- modifier key changes. Nothing runs while it is down.
local live = { tt = nil, owner = nil, onMinimap = false, acc = 0 }
local liveFrame
local function rebuild()
  local tt = live.tt
  if not (tt and tt.IsShown and tt:IsShown() and tt.GetOwner and tt:GetOwner() == live.owner) then
    live.tt = nil
    if liveFrame then liveFrame:Hide() end
    return
  end
  tt:ClearLines()
  local ok, err = pcall(tooltip, tt, live.onMinimap)
  if not ok then ns.Error(err) end
  tt:Show()
end
local function watch(tt, onMinimap)
  if not (CreateFrame and tt and tt.GetOwner) then return end
  live.tt, live.owner, live.onMinimap, live.acc = tt, tt:GetOwner(), onMinimap, 0
  if not liveFrame then
    liveFrame = CreateFrame("Frame")
    liveFrame:SetScript("OnUpdate", function(_, elapsed)
      live.acc = live.acc + (elapsed or 0)
      if live.acc >= 1 then live.acc = 0; rebuild() end
    end)
    liveFrame:SetScript("OnEvent", function() rebuild() end)
    pcall(liveFrame.RegisterEvent, liveFrame, "MODIFIER_STATE_CHANGED")
  end
  liveFrame:Show()
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
  watch(tt, onMinimap)
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
