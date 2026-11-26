-- The Packs tab (the user, 2026-11-25): where a player chooses which packs they want, inside the Hard Counters
-- window instead of the game's AddOns list. A pack is an addon of the Hard Counters group (Farmer, Character Stats,
-- Traveler, Diagnostics; any other author's with `## Group: HardCounters`); Hard Counters Basic (gold and XP) is
-- built in and always on. One row per pack: a tick, its name, what it adds, its state. A tick tells the game at once
-- (C_AddOns.EnableAddOn / DisableAddOn for this character): a pack is loaded or unloaded only at a reload, so Reload
-- now shows as soon as a tick differs from what is loaded (a /reload by hand does the same).
-- (0.4.0) "Use these packs" is gone: its only job was to switch a pack's trackers on, and a tracker now goes on, with
-- daily history, when a tile of it is placed (Core/Trackers.lua ActivateTracker). A tick is the choice:
-- `globalSettings.packsChosen` is set by it; until then the Boards tab and the tutorial's packs step remind a new
-- player of this tab.
-- Unverified in game (2026-11-25): EnableAddOn / DisableAddOn by folder name for one character, and ReloadUI from
-- our own button's click. Both are wrapped (Core/WoW.lua): a refused call leaves the row saying "use the game's
-- AddOns list".
-- luacheck: no max line length (prose)
local ADDON, ns = ...

local HC, L, Wd = ns.HC, ns.L, ns.Widgets
local format = string.format

local ID = "packs"
local ROW_H, TOP_H, PAD = 46, 54, 12
local MIN_W, MIN_H = 600, 360

local Packs = {}
ns.Packs = Packs

local content
local rows = {}
local ticks = {}                 -- addon folder -> the tick as the player set it in this tab (nil: its state)
local contentH = MIN_H
local refresh

local function G() return ns.globalSettings or {} end

--- The trackers a pack's addon brought: by the pack's name ("HardCounters_Farmer" registers the pack "Farmer").
local function trackersOf(folder)
  local out = {}
  for _, t in ipairs(HC:Trackers()) do
    if t.pack and ("HardCounters_" .. t.pack) == folder then out[#out + 1] = t end
  end
  return out
end

--- The packs: Hard Counters Basic first (built in), then the group's addons by title.
--- { { name (folder; nil for Basic), title, notes, enabled, loaded, builtin, missing, trackers = { tracker, ... },
---     on = how many of them are on } }
function Packs.List()
  local out = {}
  local basic = { title = "Hard Counters Basic", notes = "Gold and experience: in, out, per hour, time to level. Built in, always on.",
    enabled = true, loaded = true, builtin = true, trackers = {} }
  for _, t in ipairs(HC:Trackers()) do if t.pack == "Basic" or t.pack == nil then basic.trackers[#basic.trackers + 1] = t end end
  out[1] = basic
  for _, a in ipairs(ns.wow.packAddons and ns.wow.packAddons() or {}) do
    a.title = (a.title or a.name):gsub("^Hard Counters:%s*", "")
    a.trackers = a.loaded and trackersOf(a.name) or {}
    out[#out + 1] = a
  end
  for _, p in ipairs(out) do
    p.on = 0
    for _, t in ipairs(p.trackers) do if t.on then p.on = p.on + 1 end end
  end
  return out
end

--- Switch on the trackers of a loaded pack that the player never switched themselves (`chosen` is nil), with
--- history as it is (off unless they chose otherwise). Returns how many it switched on.
function Packs.TrackersOn(folder)
  local n = 0
  for _, t in ipairs(trackersOf(folder)) do
    if not t.on and not t.chosen then
      HC:SetTrackerOn(t.id, true)
      n = n + 1
    end
  end
  return n
end

--- Apply a choice: want = { [folder] = true|false } (a pack left out keeps its state). Returns
--- { on = 0 (0.4.0: trackers go on with their tiles, ns.ActivateTracker), reload = true when the game must reload for it, failed = { folder, ... } }.
function Packs.Apply(want)
  local g = G()
  local res = { on = 0, reload = false, failed = {} }
  g.packsPending = type(g.packsPending) == "table" and g.packsPending or {}
  for _, p in ipairs(Packs.List()) do
    local w = p.name and want[p.name]
    if w ~= nil then
      if w and p.loaded then
        if not p.enabled then ns.wow.setAddonEnabled(p.name, true) end     -- (it was switched off for the next load)
      elseif w and not p.loaded then
        if ns.wow.setAddonEnabled(p.name, true) then
          g.packsPending[p.name] = true
          res.reload = true
        else
          res.failed[#res.failed + 1] = p.name
        end
      elseif not w and (p.loaded or p.enabled) then
        if ns.wow.setAddonEnabled(p.name, false) then
          g.packsPending[p.name] = nil
          if p.loaded then res.reload = true end
        else
          res.failed[#res.failed + 1] = p.name
        end
      end
    end
  end
  g.packsChosen = true
  return res
end

--- A pack ticked or unticked: the game is told now (this character, from the next load). A pack to load is noted so
--- its trackers go on after the reload. Returns true when the game took it.
function Packs.SetWanted(p, want)
  if not p or not p.name then return false end
  local g = G()
  g.packsPending = type(g.packsPending) == "table" and g.packsPending or {}
  local ok = ns.wow.setAddonEnabled(p.name, want)
  ticks[p.name] = want and true or false
  g.packsChosen = true                          -- (0.4.0) a tick is the choice
  if ok then
    g.packsPending[p.name] = (want and not p.loaded) and true or nil
  end
  if content then
    content.applied = true
    content.message = (not ok) and format(L["The game refused for %s: use its AddOns list (Escape, AddOns) instead."], p.title)
      or ((want ~= p.loaded) and L["Reload to finish: the game loads or unloads packs only then."] or nil)
  end
  return ok
end

--- After a load: the packs the player turned on in this tab and that are loaded now (0.4.0: their trackers go on
--- when a tile of theirs is placed). Returns their titles, for one chat line.
function Packs.FinishPending()
  local g = G()
  local done = {}
  if type(g.packsPending) ~= "table" then return done end
  for _, p in ipairs(Packs.List()) do
    if p.name and g.packsPending[p.name] and p.loaded then
      g.packsPending[p.name] = nil
      done[#done + 1] = p.title
    end
  end
  return done
end

--- Has the player chosen packs: a tick in this tab, or (0.4.0-beta2) a pack already loaded, as it is for anyone who
--- installed packs through the game's AddOns list before this tab existed.
function Packs.Chosen() return G().packsChosen == true or Packs.LoadedCount() > 0 end

--- How many packs beside the built-in one are loaded now (Diagnostics not counted: it adds no numbers).
function Packs.LoadedCount()
  local n = 0
  for _, p in ipairs(Packs.List()) do
    if not p.builtin and p.loaded and p.name ~= "HardCounters_Diagnostics" then n = n + 1 end
  end
  return n
end

local HISTORY = "A pack's numbers count as soon as you place one of its tiles (+ Tile on a board, or a ready-made board): its tracker is switched on for you, with daily history, so today, this week and this month work at once. How much history is kept, and for how long: {Options}, History. A tracker by tracker: the {Explorer} tab, Trackers."

---------------------------------------------------------------------------
-- The tab
---------------------------------------------------------------------------

local function wanted(p)
  if p.builtin then return true end
  local t = ticks[p.name]
  if t ~= nil then return t end
  return p.enabled and not p.missing
end

local function stateText(p)
  if p.builtin then return format(L["Always on \194\183 %d of %d trackers on"], p.on, #p.trackers) end
  if p.missing then return "|cffff6060" .. L["Can't load (something it needs is missing)"] .. "|r" end
  local w = wanted(p)
  if p.loaded and w then
    if #p.trackers == 0 then return "|cff60ff60" .. L["On"] .. "|r" end
    return "|cff60ff60" .. L["On"] .. "|r \194\183 " .. format(L["%d of %d trackers on"], p.on, #p.trackers)
  end
  if p.loaded and not w then return "|cffffd200" .. L["On now; off after a reload"] .. "|r" end
  if not p.loaded and w then
    return p.enabled and ("|cffffd200" .. L["On after a reload"] .. "|r") or ("|cffffd200" .. L["Off now; on after a reload"] .. "|r")
  end
  return "|cff808080" .. L["Off"] .. "|r"
end

--- Does any tick differ from what is loaded? (Then Reload now shows.)
local function needsReload(list)
  for _, p in ipairs(list) do
    if not p.builtin and not p.missing and wanted(p) ~= p.loaded then return true end
  end
  return false
end

local function newRow(i)
  local r = CreateFrame("Frame", nil, content)
  r:SetHeight(ROW_H)
  local bg = r:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  bg:SetColorTexture(0, 0, 0, i % 2 == 0 and 0.18 or 0.32)
  local ok, c = pcall(CreateFrame, "CheckButton", nil, r, "UICheckButtonTemplate")
  if not ok or type(c) ~= "table" then
    c = CreateFrame("CheckButton", nil, r)
    c:SetNormalTexture("Interface\\Buttons\\UI-CheckBox-Up")
    c:SetCheckedTexture("Interface\\Buttons\\UI-CheckBox-Check")
  end
  c:SetSize(26, 26)
  c:SetPoint("LEFT", 6, 0)
  c:SetScript("OnClick", function(self)
    local p = self.pack
    if not p or p.builtin or p.missing then self:SetChecked(p and p.builtin or false); return end
    -- (the user, 2026-11-25: unticked a pack, /reload, and it was still there: the tick alone must count)
    -- The game is told at once, so a /reload by hand is enough (0.4.0: the tick is the whole choice).
    Packs.SetWanted(p, not wanted(p))
    refresh()
  end)
  r.check = c
  r.title = r:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  r.title:SetPoint("TOPLEFT", 40, -7)
  r.title:SetJustifyH("LEFT")
  r.state = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  r.state:SetPoint("TOPRIGHT", -10, -8)
  r.state:SetJustifyH("RIGHT")
  r.notes = r:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  r.notes:SetPoint("TOPLEFT", 40, -25)
  r.notes:SetPoint("TOPRIGHT", -10, -25)
  r.notes:SetJustifyH("LEFT")
  r.notes:SetWordWrap(false)
  rows[i] = r
  return r
end

function refresh()
  if not (content and content:IsShown()) then return end
  local list = Packs.List()
  local y = -TOP_H
  for i, p in ipairs(list) do
    local r = rows[i] or newRow(i)
    r:ClearAllPoints()
    r:SetPoint("TOPLEFT", content, "TOPLEFT", PAD, y)
    r:SetPoint("TOPRIGHT", content, "TOPRIGHT", -PAD, y)
    r.check.pack = p
    r.check:SetChecked(wanted(p))
    r.check:SetEnabled(not (p.builtin or p.missing))
    r.title:SetText(L[p.title])
    r.notes:SetText(p.notes and L[p.notes] or "")
    r.state:SetText(stateText(p))
    r:Show()
    y = y - ROW_H - 2
  end
  for i = #list + 1, #rows do rows[i]:Hide() end
  if #list == 1 then
    content.none:SetText(L["No packs found beside Hard Counters. They come in the same download: Farmer, Character Stats, Traveler."])
    y = y - 22
  else
    content.none:SetText("")
  end
  local pending = needsReload(list)
  content.reload:ClearAllPoints()
  content.reload:SetPoint("TOPLEFT", content, "TOPLEFT", PAD, y - 8)
  content.reload:SetShown(pending)
  content.note:ClearAllPoints()
  if pending then content.note:SetPoint("LEFT", content.reload, "RIGHT", 10, 0)
  else content.note:SetPoint("TOPLEFT", content, "TOPLEFT", PAD + 2, y - 13) end
  content.note:SetPoint("RIGHT", content, "RIGHT", -PAD, 0)
  content.note:SetText(content.message or (pending and L["Your ticks differ from what is loaded: reload to finish."]
    or (Packs.Chosen() and "" or L["Tick the packs you want: the game is told at once."])))
  y = y - 8 - 24 - 12
  content.history:ClearAllPoints()
  content.history:SetPoint("TOPLEFT", content, "TOPLEFT", PAD + 2, y)
  content.history:SetPoint("TOPRIGHT", content, "TOPRIGHT", -PAD - 2, y)
  content.history:SetText(ns.Help and ns.Help.Render(HISTORY) or L[HISTORY])
  local hh = content.history.GetStringHeight and content.history:GetStringHeight()
  y = y - ((type(hh) == "number" and hh > 0) and hh or 48) - 8
  content.toTrackers:ClearAllPoints()
  content.toTrackers:SetPoint("TOPLEFT", content, "TOPLEFT", PAD, y)
  y = y - 24
  local h = math.max(MIN_H, math.floor(-y + PAD))
  if h ~= contentH then
    contentH = h
    ns.Windows.Relayout(ID)
  end
end
Packs.Refresh = refresh

--- Apply every tick as it stands (the slash command and tests; the tab applies each tick as it is clicked).
function Packs.Use()
  local want = {}
  for _, p in ipairs(Packs.List()) do
    if p.name and not p.missing then want[p.name] = wanted(p) end
  end
  local res = Packs.Apply(want)
  for k in pairs(ticks) do ticks[k] = nil end
  local parts = {}
  if res.reload then parts[#parts + 1] = L["Reload to finish: the game loads or unloads packs only then."] end
  if #res.failed > 0 then
    parts[#parts + 1] = format(L["The game refused for %s: use its AddOns list (Escape, AddOns) instead."], table.concat(res.failed, ", "))
  end
  if #parts == 0 then parts[1] = L["Done: nothing needed changing."] end
  if content then
    content.applied = true
    content.message = table.concat(parts, " ")
  end
  if ns.Print then ns.Print(table.concat(parts, " ")) end
  refresh()
  if ns.RefreshBoards then ns.RefreshBoards() end
  return res
end

local function build(f)
  content = f
  f.intro = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  f.intro:SetPoint("TOPLEFT", PAD + 2, -8)
  f.intro:SetPoint("TOPRIGHT", -PAD - 2, -8)
  f.intro:SetJustifyH("LEFT")
  f.intro:SetText(L["Packs add numbers to Hard Counters. Tick the ones you want; untick the ones you don't: they cost nothing once unloaded."])
  f.none = f:CreateFontString(nil, "OVERLAY", "GameFontDisable")
  f.none:SetPoint("TOPLEFT", PAD + 2, -(TOP_H + ROW_H + 8))
  f.none:SetJustifyH("LEFT")
  f.reload = Wd.Button(f, L["Reload now"], 110, function() ns.wow.reload() end)
  f.reload:SetHeight(24)
  Wd.RichTip(f.reload, function() return { title = L["Reload now"],
    text = L["Reloads the interface (the same as /reload): a few seconds, nothing is lost. The game loads or unloads packs only then."],
    click = L["Click: reload."] } end)
  f.reload:Hide()
  f.note = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  f.note:SetJustifyH("LEFT")
  f.history = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  f.history:SetJustifyH("LEFT")
  f.history:SetSpacing(2)
  f.toTrackers = Wd.Button(f, L["Open the Explorer on Trackers"], 200, function() if ns.ShowTrackers then ns.ShowTrackers(true) end end)
  Wd.RichTip(f.toTrackers, function() return { title = L["Open the Explorer on Trackers"],
    text = L["Every tracker of every pack: on or off, its history, its size on disk."], click = L["Click: open it."] } end)
  f:SetScript("OnSizeChanged", function() refresh() end)
end

ns.Windows.Register(ID, {
  title = L["Packs"], icon = "Interface\\Icons\\INV_Misc_Bag_08", tabOrder = 3,
  about = "Choose which packs feed Hard Counters; a pack you untick is not loaded at all.",
  width = 720, height = 440, minWidth = MIN_W, minHeight = MIN_H,
  minSize = function() return MIN_W, contentH end,
  build = build,
  onShow = function()
    if content then content.message = nil end
    refresh()
  end,
})

function ns.ShowPacks(show) ns.Windows.Show(ID, show) end
Packs.Rows = rows                                             -- (tests)
ns.AddSlash("packs", function() ns.ShowPacks() end, L["the Packs tab: choose the packs you want"])

local _ = ns.Help and ns.Help.Register(ID, {
  what = "Packs are the add-ons that give Hard Counters its numbers: Farmer for loot, money and fishing, Character Stats for your character sheet, Traveler for distance and speed. This tab is where you choose which ones you want.",
  can = {
    "Tick or untick a pack: the game is told at once, and {Reload now} appears, since it loads or unloads a pack only at a reload (typing /reload does the same).",
    "Read each pack's state on the right: on, off, or waiting for a reload, and how many of its trackers are on.",
    "{Open the Explorer on Trackers} to see every tracker, switch one off, or change how much history it keeps.",
  },
  effect = "A pack you keep adds its readings to + Tile and its ready-made boards to {New board...}; its trackers start counting, with daily history, the moment you place one of its tiles. A pack you untick is not loaded at all: no memory, no work in the background. Nothing here deletes saved history.",
  tour = {
    { title = "One row per pack", text = "Each row is a pack: its name, what it adds, and on the right whether it is on. Hard Counters Basic (gold and experience) is built in and always on." },
    { title = "Tick, then reload", text = "Tick the packs you want and untick the others: each tick counts at once. If a pack has to be loaded or unloaded, {Reload now} appears: click it, or type /reload later." },
    { title = "Then place its tiles", text = "A pack's numbers count once you place one of its tiles: + Tile on a board, or a ready-made board. Its tracker goes on by itself, with daily history; {Options} says how long history is kept." },
  },
})

-- after a load: finish what the player chose here before the reload
ns.On("PLAYER_ENTERING_WORLD", function()
  if not ns.ready then return end
  C_Timer.After(1, function()
    local done = Packs.FinishPending()
    if #done > 0 and ns.Print then
      ns.Print(L["%s: loaded. Its numbers are in + Tile and New board...: a tile placed starts its tracker, with history."], table.concat(done, ", "))
    end
    refresh()
  end)
end, "Packs")

local owner = {}
HC.RegisterCallback(owner, "HC_TRACKERS_CHANGED", function() refresh() end)
