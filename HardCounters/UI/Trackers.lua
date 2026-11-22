-- The Trackers window (TRACKERS_AND_BOARDS §7, HC-19): the catalog, the on/off switchboard and the storage panel in
-- one. A tab of the shared Hard Counters window; /hc trackers. Per pack: each tracker with on/off, its history
-- (one switch, HC-48: "History on/off"; right-click: Advanced = Lifetime / Daily with days / Detailed, and Delete)
-- and its size on disk; expanded, its readings with their scopes and
-- a [+] that puts one on a board (the only one, or the one picked: HC-36). At the bottom, "Not loaded": data on disk that nothing registered
-- this session, with Delete. The one-time "New" behaviour: a pack's new trackers are marked New, and the window
-- opens once by itself when a new pack's trackers appear.
-- Rows are a virtual list (a pool of row frames, the mouse wheel moves the offset): no scroll template needed.
local ADDON, ns = ...

local HC, L, Wd = ns.HC, ns.L, ns.Widgets
local format, floor, max, min = string.format, math.floor, math.max, math.min

local ID = "trackers"
local ROW_H, TOP_Y, FOOT_H = 20, -34, 22
local SIZE_W = 110                     -- the size column: "12 KB (3 KB frozen)"
local content
local expanded = {}         -- tracker id -> true
local scroll = 0
local entries = {}          -- the list's rows, rebuilt on refresh
local sizes, sizeTotal = {}, nil
local filter = ""

local TIP_LIVE = "No history: these numbers cover this session and your runs, and reset when you log out. Turn on "
  .. "history to keep daily totals, see today and this week, and compare with earlier days. About 20 KB a month."
local HISTORY_TIP = {
  off = "Live only: this session and your runs. Nothing on disk.",
  lifetime = "All-time totals and records.",
  daily = "Today, this week, month, year and lifetime, and the Ledger. Days are kept for the number of days you choose.",
  detailed = "All of Daily plus the last 48 hours by hour.",
}

---------------------------------------------------------------------------
-- Formatting
---------------------------------------------------------------------------

local function kb(bytes)
  if not bytes or bytes <= 0 then return "0 KB" end
  if bytes < 1024 then return "<1 KB" end
  local k = bytes / 1024
  if k >= 1024 then return format("%.1f MB", k / 1024) end
  return format("%d KB", floor(k + 0.5))
end
ns.FormatKB = kb

--- A tracker's size: bytes on disk, of which `frozen` are frozen (HC:TrackerSize). "3 KB, 3 KB frozen" read as 6 KB
--- in game (2026-11-15): say "3 KB frozen" when all of it is, "5 KB (3 KB frozen)" when part of it is.
function ns.TrackerSizeText(bytes, frozen)
  if not frozen or frozen <= 0 then return kb(bytes) end
  if frozen >= (bytes or 0) then return format("%s %s", kb(frozen), L["frozen"]) end
  return format("%s (%s %s)", kb(bytes), kb(frozen), L["frozen"])
end

--- The history button's words (HC-48: one switch, "History on" / "History off"; the preset is in its tooltip).
local function historyLabel(t)
  if not t.on and t.needsHistory then return format(L["needs %s history"], t.needsHistory) end
  if t.history == "off" then return L["History off"] end
  return L["History on"]
end

--- The preset a tracker keeps, in words ("Daily, 14 days").
local function presetText(t)
  if t.history == "daily" then return format(L["Daily, %d days"], t.days) end
  if t.history == "lifetime" then return L["Lifetime"] end
  if t.history == "detailed" then return L["Detailed"] end
  return L["Off (Live only)"]
end
ns.HistoryPresetText = presetText

--- Bytes of a tracker's counters in some grains (for "Delete the daily part"), from db:Stats() sizes.
local function partBytes(t, grains)
  local n = 0
  for _, cid in ipairs(t.counters) do
    local s = sizes[cid]
    if s and s.grains then
      for _, g in ipairs(grains) do n = n + (s.grains[g] or 0) end
    end
  end
  return n
end

---------------------------------------------------------------------------
-- Actions (with the confirmations §2.2 and §3.3 ask for)
---------------------------------------------------------------------------

local function confirm(text, fn)
  if ns.Boards and ns.Boards.Confirm then ns.Boards.Confirm(text, fn) else fn() end
end

local refresh

local function switch(t, on)
  if on then
    local function go()
      HC:SetTrackerOn(t.id, true)
      if t.needsHistory and ns.Print then
        ns.Print(L["%s keeps %s history; it starts now: nothing before today can be filled in."], t.title, t.needsHistory)
      end
      refresh()
    end
    if t.needsHistory and t.chosenHistory ~= t.needsHistory then
      confirm(format(L["%s keeps %s history for its counters (about 20 KB a month). Turn it on?"], t.title, t.needsHistory), go)
    else
      go()
    end
    return
  end
  local impact = HC:TrackerOffImpact(t.id) or { readings = {}, keptBy = {} }
  local msg = format(L["Turn %s off?"], t.title)
  if #impact.readings > 0 then msg = msg .. "\n" .. L["It also stops:"] .. " " .. table.concat(impact.readings, ", ") .. "." end
  if #impact.keptBy > 0 then msg = msg .. "\n" .. format(L["%s keeps its shared counters running."], table.concat(impact.keptBy, ", ")) end
  msg = msg .. "\n" .. L["Nothing is deleted: switching it on again carries on."]
  confirm(msg, function() HC:SetTrackerOn(t.id, false); refresh() end)
end

local function setHistory(t, preset, days)
  local before = ns.HISTORY_PRESETS[t.history] or 0
  HC:SetTrackerHistory(t.id, preset, days)
  local after = ns.HISTORY_PRESETS[preset] or 0
  if after > before and ns.Print then ns.Print(L["History starts now; nothing before today can be filled in."]) end
  refresh()
end

local function deleteHistory(t, part)
  local bytes
  if part == "hourly" then bytes = partBytes(t, { "hour" })
  elseif part == "daily" then bytes = partBytes(t, { "day", "week", "resetweek" })
  else bytes = HC:TrackerSize(t.id, sizes) end
  local what = part == "hourly" and L["hourly"] or part == "daily" and L["daily"] or L["all the"]
  local shared = HC:TrackerOffImpact(t.id)
  local msg = format(L["Delete %s of %s history for %s? This can't be undone."], kb(bytes), what, t.title)
  if shared and #shared.keptBy > 0 then
    msg = msg .. "\n" .. format(L["Its counters are shared with %s: that loses it too."], table.concat(shared.keptBy, ", "))
  end
  confirm(msg, function()
    local freed = HC:DeleteTrackerHistory(t.id, part)
    if ns.Print then ns.Print(L["Deleted %s."], kb(freed)) end
    refresh()
  end)
end

--- The "Keep history" switch (HC-48): on brings back the last preset (Daily by default), off freezes what was kept.
--- A tracker that needs history (the Ledger) can't be switched off while it is on: it says so instead.
local function toggleHistory(t)
  if t.history ~= "off" then
    if t.on and t.needsHistory then
      if ns.Print then ns.Print(L["%s needs %s history: it stays on while %s is on."], t.title, t.needsHistory, t.title) end
      return
    end
    HC:SetTrackerKeepHistory(t.id, false)
    if ns.Print then ns.Print(L["%s: history off. What was kept stays on disk (Delete history removes it)."], t.title) end
    refresh()
    return
  end
  HC:SetTrackerKeepHistory(t.id, true)
  if ns.Print then ns.Print(L["History starts now; nothing before today can be filled in."]) end
  refresh()
end

--- Right-click on the history button: the switch, Advanced (the presets and the days) and Delete.
local function historyMenu(anchor, t)
  local need = t.needsHistory and ns.HISTORY_PRESETS[t.needsHistory] or 0
  local items = { { text = L["History"], title = true } }
  items[#items + 1] = { text = L["Keep history"], checked = t.history ~= "off", disabled = t.on and need > 0,
    tip = t.on and need > 0 and format(L["%s needs %s."], t.title, t.needsHistory) or nil,
    func = function() toggleHistory(t) end }
  local advanced = {}
  local function item(text, preset, days)
    local lvl = ns.HISTORY_PRESETS[preset]
    local checked = t.chosenHistory == preset and (preset ~= "daily" or not days or t.days == days)
    advanced[#advanced + 1] = { text = text, checked = checked, disabled = lvl < need,
      tip = HISTORY_TIP[preset] .. (lvl < need and ("\n" .. format(L["%s needs %s."], t.title, t.needsHistory)) or ""),
      func = function() setHistory(t, preset, days) end }
  end
  item(L["Lifetime"], "lifetime")
  for _, d in ipairs(ns.HISTORY_DAYS) do item(format(L["Daily, %d days"], d), "daily", d) end
  item(L["Detailed"], "detailed")
  items[#items + 1] = { text = L["Advanced"], sub = advanced }
  items[#items + 1] = { text = L["Delete history"], sub = {
    { text = format(L["All of it (%s)"], kb(HC:TrackerSize(t.id, sizes))), func = function() deleteHistory(t, nil) end },
    { text = format(L["The hourly part (%s)"], kb(partBytes(t, { "hour" }))), func = function() deleteHistory(t, "hourly") end },
    { text = format(L["The daily part (%s)"], kb(partBytes(t, { "day", "week", "resetweek" }))),
      func = function() deleteHistory(t, "daily") end },
  } }
  ns.Menu.Show(anchor, items)
end

--- A reading's title for lists: one with a parameter reads "... rep" until a member is picked.
local function listTitle(r) return (r.title:gsub("%%s", "...")) end

--- The [+] beside a reading (HC-36): with one board it adds there; with several a menu lists them, the ones on
--- screen first, then "New board"; with none it makes one. A hidden board is shown and the new tile flashes once.
--- getBoard is called only when the tile is really added (a cancelled pick leaves no empty board behind).
local function addToBoard(readingId, anchor)
  if not (ns.BoardModel and ns.Boards) then return end
  local BM = ns.BoardModel
  local r = ns.readings[readingId]
  local function newBoard() return BM.Create(nil, { name = L["Board"] }) end
  local function addTo(getBoard)
    local function add(arg)
      local board = getBoard()
      ns.Boards.AddReading(board, readingId, nil, arg, function(tile)
        ns.Boards.Reveal(board, tile)
        if ns.Print and r then
          ns.Print(L["%s added to the board %s (/hc edit to arrange it)."], ns.ReadingTitle(r, arg), board.name)
        end
      end)
    end
    -- a reading with a parameter (DESIGN 16.4): pick the member first
    if ns.NeedsArg(r) and anchor then ns.Boards.MemberMenu(anchor, readingId, add) else add() end
  end
  local targets = BM.AddTargets()
  if #targets == 0 then return addTo(newBoard) end
  if #targets == 1 or not anchor then return addTo(function() return targets[1] end) end
  local items = { { text = L["Add to"], title = true } }
  for _, b in ipairs(targets) do
    items[#items + 1] = { text = b.shown and b.name or format(L["%s (hidden)"], b.name),
      func = function() addTo(function() return b end) end }
  end
  items[#items + 1] = { text = L["New board"], func = function() addTo(newBoard) end }
  ns.Menu.Show(anchor, items)
end

--- The [+]'s tooltip names where it adds (HC-36), never "the board you last edited".
local function addTip()
  local targets = ns.BoardModel and ns.BoardModel.AddTargets() or {}
  if #targets == 0 then return L["Add to a new board"] end
  if #targets == 1 then return format(L["Add to %s"], targets[1].name) end
  return L["Add to a board (pick which)"]
end

---------------------------------------------------------------------------
-- The list
---------------------------------------------------------------------------

local function matches(text)
  return filter == "" or (text and text:lower():find(filter, 1, true) ~= nil)
end

local function scopeChips(r)
  local parts = {}
  for _, s in ipairs(r.scopes) do
    local g = ns.ScopeGrain(s)
    local ok = true
    if g and r.counter then
      local c = ns.counters[r.counter]
      ok = c and ns.ServesGrain(c, g) or false
    end
    parts[#parts + 1] = ok and s or ("|cff707070" .. s .. "\194\183|r")    -- "·" marks "needs history"
  end
  return table.concat(parts, "  ")
end

local function rebuild()
  entries = {}
  local trackers = HC:Trackers()
  local byPack, packs = {}, {}
  for _, t in ipairs(trackers) do
    local key = t.packTitle or "Hard Counters"
    if not byPack[key] then byPack[key] = {}; packs[#packs + 1] = key end
    local list = byPack[key]
    list[#list + 1] = t
  end
  for _, key in ipairs(packs) do
    local list = byPack[key]
    local anyNew = false
    for _, t in ipairs(list) do if t.new then anyNew = true end end
    local shown = {}
    for _, t in ipairs(list) do
      local readings = HC:Readings({ tracker = t.id })
      local hit = matches(t.title)
      for _, r in ipairs(readings) do if matches(listTitle(r)) then hit = true end end
      if hit then shown[#shown + 1] = { t = t, readings = readings } end
    end
    if #shown > 0 then
      entries[#entries + 1] = { kind = "pack", text = key, new = anyNew }
      for _, s in ipairs(shown) do
        entries[#entries + 1] = { kind = "tracker", t = s.t }
        if expanded[s.t.id] or filter ~= "" then
          -- (HC-28) readings this character doesn't use come last, under a heading of their own
          local unusedHead = false
          for pass = 1, 2 do
            for _, r in ipairs(s.readings) do
              if (r.applies ~= false) == (pass == 1)
                  and (filter == "" or matches(listTitle(r)) or matches(s.t.title)) then
                if pass == 2 and not unusedHead then
                  entries[#entries + 1] = { kind = "subhead", text = L["Not used by this character"] }
                  unusedHead = true
                end
                entries[#entries + 1] = { kind = "reading", r = r }
              end
            end
          end
        end
      end
    end
  end
  local unloaded = HC:UnloadedCounters()
  if #unloaded > 0 and filter == "" then
    entries[#entries + 1] = { kind = "pack", text = L["Not loaded"], note = L["data on disk that no addon uses this session"] }
    for _, u in ipairs(unloaded) do
      -- (HC-48) never the raw id: "Farmer: Money out (no longer used)"
      entries[#entries + 1] = { kind = "unloaded", id = u.id, bytes = u.bytes,
        name = format("%s: %s", u.pack, u.title), why = L[u.why] }
    end
  end
end

local function rowFrame(i)
  local rows = content.rows
  local b = rows[i]
  if b then return b end
  b = CreateFrame("Button", nil, content.list)
  b:SetHeight(ROW_H)
  b:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)
  b:SetPoint("TOPRIGHT", 0, -(i - 1) * ROW_H)
  b.hl = b:CreateTexture(nil, "HIGHLIGHT")
  b.hl:SetAllPoints()
  b.hl:SetColorTexture(1, 1, 1, 0.06)
  b.title = b:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  b.title:SetJustifyH("LEFT")
  b.title:SetWordWrap(false)
  b.badge = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  b.size = b:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  b.size:SetJustifyH("RIGHT")
  b.size:SetPoint("RIGHT", -6, 0)
  b.size:SetWidth(SIZE_W)          -- a fixed column, so the buttons line up and never sit on the size text
  b.size:SetWordWrap(false)
  b.onBtn = Wd.Button(b, "", 44, nil)
  b.onBtn:SetHeight(18)
  b.histBtn = Wd.Button(b, "", 96, nil)
  b.histBtn:SetHeight(18)
  b.histBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  b.plus = Wd.Button(b, "+", 24, nil)
  b.plus:SetHeight(18)
  b.plus:SetPoint("RIGHT", -6, 0)
  b.del = Wd.Button(b, L["Delete"], 60, nil)
  b.del:SetHeight(18)
  b.del:SetPoint("RIGHT", -70, 0)
  b.scopes = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  b.scopes:SetJustifyH("LEFT")
  b.scopes:SetWordWrap(false)
  b:EnableMouseWheel(true)
  b:SetScript("OnMouseWheel", function(_, delta) content:GetScript("OnMouseWheel")(content, delta) end)
  rows[i] = b
  return b
end

local function hideParts(b)
  b.onBtn:Hide(); b.histBtn:Hide(); b.plus:Hide(); b.del:Hide(); b.scopes:Hide(); b.badge:SetText(""); b.size:SetText("")
  b:SetScript("OnClick", nil)
  b:SetScript("OnEnter", nil)
  b:SetScript("OnLeave", nil)
end

local function drawEntry(b, e)
  hideParts(b)
  b.title:ClearAllPoints()
  if e.kind == "pack" then
    b.title:SetPoint("LEFT", 4, 0)
    b.title:SetWidth(0)
    b.title:SetFontObject("GameFontNormal")
    b.title:SetText(e.text)
    b.badge:ClearAllPoints()
    b.badge:SetPoint("LEFT", b.title, "RIGHT", 8, 0)
    b.badge:SetText(e.new and ("|cff60ff60" .. L["New"] .. "|r") or (e.note and ("|cff808080" .. e.note .. "|r") or ""))
  elseif e.kind == "subhead" then
    b.title:SetPoint("LEFT", 34, 0)
    b.title:SetWidth(0)
    b.title:SetFontObject("GameFontDisableSmall")
    b.title:SetText(e.text)
  elseif e.kind == "tracker" then
    local t = e.t
    b.title:SetFontObject("GameFontHighlight")
    b.title:SetPoint("LEFT", 14, 0)
    b.title:SetWidth(0)
    b.title:SetText((expanded[t.id] and "-  " or "+  ") .. t.title .. (t.new and ("  |cff60ff60" .. L["New"] .. "|r") or ""))
    b:SetScript("OnClick", function() expanded[t.id] = not expanded[t.id]; refresh() end)
    b:SetScript("OnEnter", function(self)
      if not t.description then return end
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:SetText(t.title, 1, 1, 1)
      GameTooltip:AddLine(t.description, 0.8, 0.8, 0.8, true)
      GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    b.histBtn:ClearAllPoints()
    b.histBtn:SetPoint("RIGHT", -(SIZE_W + 12), 0)
    b.histBtn:SetText(historyLabel(t))
    Wd.FitWidth(b.histBtn, 96, 20)   -- "needs daily history" overflowed a fixed 96 (run 3 screenshot)
    -- (HC-48) a click switches history on or off; right-click: Advanced (how much, how long) and Delete
    b.histBtn:SetScript("OnClick", function(self, button)
      if button == "RightButton" then historyMenu(self, t) elseif not t.on and t.needsHistory then switch(t, true)
      else toggleHistory(t) end
    end)
    Wd.Tip(b.histBtn, function()
      if not t.on and t.needsHistory then return format(L["Click to turn %s on: it keeps %s history."], t.title, t.needsHistory) end
      local hint = "\n|cff808080" .. L["Click: history on or off. Right-click: how much and how long (Advanced), Delete."] .. "|r"
      if t.history == "off" then return L[TIP_LIVE] .. hint end
      return format(L["Keeping history: %s. %s"], presetText(t), L[HISTORY_TIP[t.history] or ""]) .. hint
    end)
    -- a tracker of live readings only (no counters) keeps nothing: no history button
    local live = #(t.counters or {}) == 0
    b.histBtn:SetShown(not live)
    -- the switch sits left of the history button, the title left of the switch
    b.onBtn:ClearAllPoints()
    if live then b.onBtn:SetPoint("RIGHT", -(SIZE_W + 12), 0) else b.onBtn:SetPoint("RIGHT", b.histBtn, "LEFT", -4, 0) end
    b.onBtn:SetText(t.on and L["on"] or L["off"])
    b.onBtn:SetScript("OnClick", function() switch(t, not t.on) end)
    b.onBtn:Show()
    b.title:SetPoint("RIGHT", b.onBtn, "LEFT", -8, 0)
    local bytes, frozen = HC:TrackerSize(t.id, sizes)
    b.size:SetText(ns.TrackerSizeText(bytes, frozen))
  elseif e.kind == "reading" then
    local r = e.r
    b.title:SetFontObject("GameFontHighlightSmall")
    b.title:SetPoint("LEFT", 34, 0)
    b.title:SetWidth(120)
    b.title:SetText(listTitle(r))
    b.scopes:ClearAllPoints()
    b.scopes:SetPoint("LEFT", b.title, "RIGHT", 8, 0)
    b.scopes:SetPoint("RIGHT", b, "RIGHT", -36, 0)
    b.scopes:SetText(scopeChips(r))
    b.scopes:Show()
    b:SetScript("OnEnter", function(self)
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:SetText(listTitle(r), 1, 1, 1)
      if r.description then GameTooltip:AddLine(r.description, 0.8, 0.8, 0.8, true) end
      GameTooltip:AddLine(L["Grey scopes need history (the tracker's History button)."], 0.5, 0.5, 0.5, true)
      GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    b.plus:SetScript("OnClick", function() addToBoard(r.id, b.plus) end)
    Wd.Tip(b.plus, addTip)
    b.plus:Show()
  elseif e.kind == "unloaded" then
    b.title:SetFontObject("GameFontHighlightSmall")
    b.title:SetPoint("LEFT", 14, 0)
    b.title:SetWidth(0)
    b.title:SetText(e.name .. "  |cff808080(" .. e.why .. ")|r")
    b.title:SetPoint("RIGHT", b.del, "LEFT", -8, 0)
    b.size:SetText(kb(e.bytes))
    b:SetScript("OnEnter", function(self)
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:SetText(e.name, 1, 1, 1)
      GameTooltip:AddLine(e.why == L["pack not loaded"]
        and L["Saved data of an addon that isn't loaded this session. Enable the addon again and it carries on; Delete removes it."]
        or L["Saved data the addon no longer uses (an older version's). Nothing will read it again; Delete removes it."],
        0.8, 0.8, 0.8, true)
      GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    b.del:SetScript("OnClick", function()
      confirm(format(L["Delete %s of %s? No addon uses it this session. This can't be undone."], kb(e.bytes), e.name), function()
        local freed = HC:DeleteCounterData(e.id)
        if ns.Print then ns.Print(L["Deleted %s."], kb(freed)) end
        refresh()
      end)
    end)
    b.del:Show()
  end
end

local function visibleRows()
  local h = content.list:GetHeight() or 200
  return max(1, floor(h / ROW_H))
end

function refresh()
  if not (content and content:IsShown()) then return end
  sizes, sizeTotal = ns.CounterSizes()
  rebuild()
  local n = visibleRows()
  scroll = max(0, min(scroll, #entries - n))
  for i = 1, n do
    local e = entries[scroll + i]
    local b = rowFrame(i)
    if e then
      local ok, err = pcall(drawEntry, b, e)
      if not ok then ns.Error(err) end
      b:Show()
    else
      b:Hide()
    end
  end
  for i = n + 1, #content.rows do content.rows[i]:Hide() end
  -- footer: "History on for 2 of 9 trackers · 180 KB on disk" (§3.4)
  local on, total = 0, 0
  for _, t in ipairs(HC:Trackers()) do
    total = total + 1
    if t.on and t.history ~= "off" then on = on + 1 end
  end
  content.foot:SetText(format(L["History on for %d of %d trackers \194\183 %s on disk"], on, total,
    kb(sizeTotal and sizeTotal.bytes or 0)) .. (#entries > n and ("   " .. L["(mouse wheel: more)"]) or ""))
end
ns.RefreshTrackers = refresh

local function build(f)
  content = f
  f.rows = {}
  f.search = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
  f.search:SetSize(160, 20)
  f.search:SetPoint("TOPLEFT", 12, -6)
  f.search:SetAutoFocus(false)
  f.search:SetScript("OnTextChanged", function(self)
    filter = (self:GetText() or ""):lower()
    scroll = 0
    refresh()
  end)
  f.search:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  f.searchHint = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  f.searchHint:SetPoint("LEFT", f.search, "RIGHT", 6, 0)
  f.searchHint:SetText(L["search"])
  f.edit = Wd.Button(f, L["Edit boards"], 100, function() if ns.Boards then ns.Boards.SetEditing(true) end end)
  f.edit:SetPoint("TOPRIGHT", -8, -6)
  f.list = CreateFrame("Frame", nil, f)
  f.list:SetPoint("TOPLEFT", 6, TOP_Y)
  f.list:SetPoint("BOTTOMRIGHT", -6, FOOT_H + 4)
  f.foot = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  f.foot:SetPoint("BOTTOMLEFT", 10, 8)
  f.foot:SetPoint("BOTTOMRIGHT", -10, 8)
  f.foot:SetJustifyH("LEFT")
  f:EnableMouseWheel(true)
  f:SetScript("OnMouseWheel", function(_, delta)
    scroll = max(0, scroll - delta * 3)
    refresh()
  end)
  f:SetScript("OnSizeChanged", function() refresh() end)
end

--- The window shown with New trackers marks them seen when it closes (the badge has done its job).
local function onHide()
  for _, t in ipairs(HC:Trackers()) do if t.new then HC:MarkTrackerSeen(t.id) end end
  if ns.Menu then ns.Menu.Hide() end
end

ns.Windows.Register(ID, {
  title = L["Trackers"], width = 560, height = 420, minWidth = 480, minHeight = 240,
  build = build, onShow = function() refresh() end, onHide = onHide,
})

function ns.ShowTrackers(show) ns.Windows.Show(ID, show) end
function HC:ToggleTrackers() ns.Windows.Show(ID, nil) end

ns.AddSlash("trackers", function() ns.ShowTrackers() end, L["choose what Hard Counters counts, and how much history it keeps"])

local owner = {}
HC.RegisterCallback(owner, "HC_TRACKERS_CHANGED", function() refresh() end)
HC.RegisterCallback(owner, "HC_HISTORY_DELETED", function() refresh() end)

-- First use: the tip about history, once (§3.4); a new pack's trackers: the window opens once, marked New (§2.3)
ns.On("PLAYER_ENTERING_WORLD", function(_, isInitialLogin, isReload)
  if not ns.ready or not ns.settings then return end
  local s = ns.settings
  s.tips = type(s.tips) == "table" and s.tips or {}
  if not s.tips.history and ns.Print then
    s.tips.history = true
    ns.Print(L["Hard Counters keeps nothing on disk until you ask: Gold and XP per hour count this session and your runs. "
      .. "/hc trackers to switch trackers on and choose their history."])
  end
  if not (isInitialLogin or isReload) then return end
  s.trackersAnnounced = type(s.trackersAnnounced) == "table" and s.trackersAnnounced or {}
  local fresh = false
  for _, t in ipairs(HC:Trackers()) do
    if t.new and not s.trackersAnnounced[t.id] then
      s.trackersAnnounced[t.id] = true
      fresh = true
    end
  end
  if fresh then ns.ShowTrackers(true) end
end, "Trackers")
