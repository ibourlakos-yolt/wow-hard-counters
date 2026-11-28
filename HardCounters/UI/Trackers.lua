-- The tracker catalog (TRACKERS_AND_BOARDS §7, HC-19, HC-66; DESIGN §17.4): the on/off switchboard and the storage
-- panel. It was the Trackers tab; since 0.4.0 it is the "What is counted" part of the Explorer tab (UI/Explorer.lua),
-- which composes this provider; /hc trackers opens it there. Tree: Trackers by category, then "Not loaded" (data on
-- disk that nothing registered this session, with Delete). List: Name, On, History, Size. Detail: the selected
-- tracker's readings with their scopes and Add tile (the only board, or the one picked: HC-36). Actions: the
-- Counting / Not counting switch, History... (Keep history, Advanced = Lifetime / Daily with days / Detailed, Delete
-- history: HC-48), Delete data (under More...). The one-time "New"
-- behaviour: a pack's new trackers are marked New, and the window opens once by itself when a new pack's trackers
-- appear.
local ADDON, ns = ...

local HC, L = ns.HC, ns.L
local format, floor = string.format, math.floor

local sizes, sizeTotal = {}, nil

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

--- Add tile beside a reading (HC-36; v8): with one board it adds there; with several a menu lists them, the ones on
--- the HUD first, then "New board"; with none it makes one. The tile goes on the board; the board goes on the HUD
--- only by the player's own switch (v8: a board that is "Only here" stays so, and the chat line says where the tile
--- is). getBoard is called only when the tile is really added (a cancelled pick leaves no empty board behind).
local function addToBoard(readingId, anchor, given)
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
          if board.shown then
            ns.Print(L["%s added to the board %s, on your HUD (hover it, Edit, to arrange it)."], ns.ReadingTitle(r, arg), board.name)
          else
            ns.Print(L["%s added to the board %s. It is in the Boards tab; the board is not on your HUD."], ns.ReadingTitle(r, arg), board.name)
          end
        end
      end)
    end
    -- a reading with a parameter (DESIGN 16.4): pick the member first, unless the caller named it (HC:AddTile)
    if given ~= nil then add(given)
    elseif ns.NeedsArg(r) and anchor then ns.Boards.MemberMenu(anchor, readingId, add) else add() end
  end
  local targets = BM.AddTargets()
  if #targets == 0 then return addTo(newBoard) end
  if #targets == 1 or not anchor then return addTo(function() return targets[1] end) end
  local items = { { text = L["Add to"], title = true } }
  for _, b in ipairs(targets) do
    items[#items + 1] = { text = b.shown and b.name or format(L["%s (Only here)"], b.name),
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
-- The tab: the shared browser (DESIGN §17.3, §17.4; HC-66). The tree is the trackers' categories (Basics, Farming,
-- Travel, Character, ...) plus "Not loaded"; the list's columns are Name, On, History, Size; the detail pane lists
-- the selected tracker's readings, each with Add tile; the action bar: Turn on or off, History..., Delete data.
-- Trackers this character has no use for show grey. Right-click on a row: the same actions as a menu.
---------------------------------------------------------------------------

local F = { on = true, off = true, history = false, here = false, packs = {} }   -- the Filters menu; packs: hidden

local function packOf(t) return t.packTitle or "Hard Counters" end
local function categoryOf(t) return t.category or packOf(t) end
local function liveOnly(t) return #(t.counters or {}) == 0 end

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

--- A tracker this character has no use for: every reading it offers says so (HC-28's `applies`).
local function usable(readings)
  if #readings == 0 then return true end
  for _, r in ipairs(readings) do if r.applies ~= false then return true end end
  return false
end

local function passes(t, readings)
  if t.on and not F.on then return false end
  if not t.on and not F.off then return false end
  if F.history and t.history == "off" then return false end
  if F.here and not usable(readings) then return false end
  if F.packs[packOf(t)] then return false end
  return true
end

local function searchHit(search, t, readings)
  if search == "" then return true end
  local function has(s) return type(s) == "string" and s:lower():find(search, 1, true) ~= nil end
  -- (0.5.0) and its pack's title: the Packs tab's "Its trackers" searches by it
  if has(t.title) or has(t.description) or has(t.packTitle) then return true end
  for _, r in ipairs(readings) do if has(listTitle(r)) then return true end end
  return false
end

--- Every tracker with its readings (the tree, the rows and the detail all read this).
local function catalog()
  local out = {}
  for _, t in ipairs(HC:Trackers()) do out[#out + 1] = { t = t, readings = HC:Readings({ tracker = t.id }) } end
  return out
end

local function nodes()
  local byCat, cats, total = {}, {}, 0
  for _, e in ipairs(catalog()) do
    if passes(e.t, e.readings) then
      local c = categoryOf(e.t)
      if not byCat[c] then byCat[c] = 0; cats[#cats + 1] = c end
      byCat[c] = byCat[c] + 1
      total = total + 1
    end
  end
  local out = { { key = "trackers", text = L["Trackers"], count = total } }
  for _, c in ipairs(cats) do out[#out + 1] = { key = "tc:" .. c, text = L[c], count = byCat[c], indent = 1 } end
  local unloaded = HC:UnloadedCounters()
  if #unloaded > 0 then out[#out + 1] = { key = "unloaded", text = L["Not loaded"], count = #unloaded, grey = true } end
  return out
end

local function historyCell(t)
  if liveOnly(t) then return "|cff808080" .. L["live only"] .. "|r" end
  if not t.on and t.needsHistory then return format(L["needs %s"], t.needsHistory) end
  if t.history == "off" then return L["Off"] end
  return presetText(t)
end

local function rows(node, search)
  local out = {}
  if node == "unloaded" then
    for _, u in ipairs(HC:UnloadedCounters()) do
      -- (HC-48) never the raw id: "Farmer: Money out (no longer used)"
      local name = format("%s: %s", u.pack, u.title)
      if search == "" or name:lower():find(search, 1, true) then
        out[#out + 1] = { key = "u:" .. u.id, unloaded = u, name = name, bytes = u.bytes, grey = true,
          cells = { name = name, on = "", history = L[u.why], size = kb(u.bytes) } }
      end
    end
    return out
  end
  for _, e in ipairs(catalog()) do
    local t = e.t
    if (node == "trackers" or node == "tc:" .. categoryOf(t)) and passes(t, e.readings) and searchHit(search, t, e.readings) then
      local bytes, frozen = HC:TrackerSize(t.id, sizes)
      out[#out + 1] = { key = t.id, t = t, readings = e.readings, bytes = bytes or 0, grey = not usable(e.readings),
        cells = {
          name = t.title .. (t.new and ("  |cff60ff60" .. L["New"] .. "|r") or ""),
          on = t.on and ("|cff60ff60" .. L["on"] .. "|r") or L["off"],
          history = historyCell(t),
          size = liveOnly(t) and "" or ns.TrackerSizeText(bytes, frozen),
        } }
    end
  end
  return out
end

local function detail(row)
  if row.unloaded then
    local u = row.unloaded
    return { title = row.name, lines = {
      u.why == "pack not loaded"
        and L["Saved data of an addon that isn't loaded this session. Enable the addon again and it carries on; Delete removes it."]
        or L["Saved data the addon no longer uses (an older version's). Nothing will read it again; Delete removes it."],
      format(L["%s on disk."], kb(u.bytes)) } }
  end
  local t = row.t
  local lines = {}
  if t.description then lines[#lines + 1] = t.description end
  local state = { t.on and L["On"] or L["Off"] }
  if liveOnly(t) then
    state[#state + 1] = L["live numbers only: nothing kept on disk"]
  else
    state[#state + 1] = format(L["history: %s"], t.history == "off" and L["off (this session and your runs)"] or presetText(t))
    state[#state + 1] = format(L["%s on disk"], ns.TrackerSizeText(HC:TrackerSize(t.id, sizes)))
  end
  lines[#lines + 1] = table.concat(state, "  \194\183  ")
  if not usable(row.readings) then lines[#lines + 1] = "|cff808080" .. L["Not used by this character."] .. "|r" end
  -- (0.5.0, G1) "what does it cost me and what do I get": who uses it
  local BM = ns.BoardModel
  if BM and BM.TilesByBoard then
    local mine, tiles, boards = {}, 0, 0
    for _, r in ipairs(row.readings) do mine[r.id] = true end
    for _, g in ipairs(BM.TilesByBoard()) do
      local n = 0
      for _, e in ipairs(g.entries) do if e.raw and mine[e.raw.reading] then n = n + 1 end end
      if n > 0 then tiles, boards = tiles + n, boards + 1 end
    end
    lines[#lines + 1] = tiles > 0 and format(L["Used by %d tile(s) on %d board(s)."], tiles, boards)
      or ("|cff808080" .. L["No tile uses it: it could be off."] .. "|r")
  end
  -- its readings, the ones this character doesn't use last under a heading of their own (HC-28)
  local items, unusedHead = {}, false
  for pass = 1, 2 do
    for _, r in ipairs(row.readings) do
      if (r.applies ~= false) == (pass == 1) then
        if pass == 2 and not unusedHead then
          items[#items + 1] = { text = L["Not used by this character"], grey = true }
          unusedHead = true
        end
        items[#items + 1] = { text = listTitle(r) .. "     " .. scopeChips(r), grey = pass == 2, reading = r.id,
          tip = (r.description and (r.description .. "\n") or "") .. L["Grey scopes need history (History...)."],
          button = { text = L["Add tile"], func = function(btn) addToBoard(r.id, btn) end, tip = addTip } }
      end
    end
  end
  if #items == 0 then items[1] = { text = L["No numbers to show."], grey = true } end
  return { title = t.title .. "   |cff808080" .. packOf(t) .. "|r", lines = lines, items = items }
end

local function actions(row)
  if not row then return {} end
  if row.unloaded then
    local u = row.unloaded
    return { { text = L["Delete"], tip = L["Delete this data: no addon uses it this session."], func = function()
      confirm(format(L["Delete %s of %s? No addon uses it this session. This can't be undone."], kb(u.bytes), row.name), function()
        local freed = HC:DeleteCounterData(u.id)
        if ns.Print then ns.Print(L["Deleted %s."], kb(freed)) end
        refresh()
      end)
    end } }
  end
  local t = row.t
  -- (0.4.0) on or off is a state: a status pill, not a button that says "Turn on"
  local acts = { { text = t.on and L["Counting"] or L["Not counting"], status = true, on = t.on,
    func = function() switch(t, not t.on) end,
    tip = { title = t.title, state = t.on and L["Now: on, counting"] or L["Now: off, counting nothing"], on = t.on,
      text = (not t.on and t.needsHistory) and format(L["Switched on, it keeps %s history."], t.needsHistory)
        or L["Off, it counts nothing and costs nothing; a tile placed from it switches it back on."],
      click = t.on and L["Click: switch it off (it asks first)."] or L["Click: switch it on."] } } }
  if not liveOnly(t) then
    acts[#acts + 1] = { text = L["History..."], func = function(btn) historyMenu(btn, t) end,
      tip = { title = L["History..."], state = t.history == "off" and L["Now: no history"] or format(L["Now: %s"], presetText(t)),
        on = t.history ~= "off",
        text = t.history == "off" and L[TIP_LIVE] or L[HISTORY_TIP[t.history] or ""],
        click = L["Click: Keep history or not, how much and how long (Advanced), Delete history."] } }
    acts[#acts + 1] = { text = L["Delete data"], disabled = (row.bytes or 0) <= 0, func = function() deleteHistory(t, nil) end,
      more = true, tip = L["Delete everything this tracker has kept on disk."] }
  end
  return acts
end

local function filterItems()
  local items = {
    { text = L["Show trackers that are"], title = true },
    { text = L["On"], checked = F.on, keepOpen = true, func = function() F.on = not F.on; refresh() end },
    { text = L["Off"], checked = F.off, keepOpen = true, func = function() F.off = not F.off; refresh() end },
    { text = L["Only"], title = true },
    { text = L["With history on"], checked = F.history, keepOpen = true, func = function() F.history = not F.history; refresh() end },
    { text = L["Used by this character"], checked = F.here, keepOpen = true, func = function() F.here = not F.here; refresh() end },
  }
  local packs, seen = {}, {}
  for _, t in ipairs(HC:Trackers()) do
    local p = packOf(t)
    if not seen[p] then seen[p] = true; packs[#packs + 1] = p end
  end
  if #packs > 1 then
    items[#items + 1] = { text = L["From"], title = true }
    for _, p in ipairs(packs) do
      items[#items + 1] = { text = p, checked = not F.packs[p], keepOpen = true,
        func = function() F.packs[p] = (not F.packs[p]) or nil; refresh() end }
    end
  end
  items[#items + 1] = { text = L["Show everything"], keepOpen = true,
    func = function() F.on, F.off, F.history, F.here, F.packs = true, true, false, false, {}; refresh() end }
  return items
end

local function filtersActive()
  return not F.on or not F.off or F.history or F.here or next(F.packs) ~= nil
end

-- "History on for 2 of 9 trackers · 180 KB on disk" (§3.4)
local function footer()
  local on, total = 0, 0
  for _, t in ipairs(HC:Trackers()) do
    total = total + 1
    if t.on and t.history ~= "off" then on = on + 1 end
  end
  return format(L["History on for %d of %d trackers \194\183 %s on disk"], on, total, kb(sizeTotal and sizeTotal.bytes or 0))
end

function refresh()
  sizes, sizeTotal = ns.CounterSizes()
  if ns.RefreshExplorer then ns.RefreshExplorer() end
end
ns.RefreshTrackers = refresh

---------------------------------------------------------------------------
-- (0.4.0) The Trackers tab is gone: its catalog is the Explorer's "What is counted" part (UI/Explorer.lua). This
-- file is the provider the Explorer composes, plus what stays: the first-use line and the one-time opening when a
-- new pack's trackers appear.
---------------------------------------------------------------------------

local T = {}
ns.TrackerCatalog = T
T.Nodes, T.Rows, T.Detail, T.Actions, T.Filters, T.FiltersActive, T.Footer = nodes, rows, detail, actions, filterItems,
  filtersActive, footer
T.AddToBoard, T.AddTip, T.ScopeChips, T.ListTitle, T.CategoryOf = addToBoard, addTip, scopeChips, listTitle, categoryOf
function T.Owns(node)
  node = tostring(node)
  return node == "trackers" or node == "unloaded" or node:sub(1, 3) == "tc:"
end
function T.Columns()
  return {
    { key = "name", title = L["Name"], sort = function(r) return (r.t and r.t.title or r.name or ""):lower() end },
    { key = "on", title = L["On"], width = 36, sort = function(r) return r.t and (r.t.on and 1 or 0) or -1 end },
    { key = "history", title = L["History"], width = 110,
      sort = function(r) return r.t and (ns.HISTORY_PRESETS[r.t.history] or 0) or -1 end },
    { key = "size", title = L["Size"], width = 100, align = "RIGHT", sort = function(r) return r.bytes or 0 end },
  }
end
--- Sizes on disk are read when the Explorer shows (db:Stats() is not free).
function T.ReadSizes() sizes, sizeTotal = ns.CounterSizes() end
--- The Explorer closed: New trackers are marked seen (the badge has done its job).
function T.OnHide()
  for _, t in ipairs(HC:Trackers()) do if t.new then HC:MarkTrackerSeen(t.id) end end
end

--- The trackers, in the Explorer (nil toggles; on: always shows).
function ns.ShowTrackers(show)
  if ns.ShowExplorer then ns.ShowExplorer(show, "trackers") end
end
function HC:ToggleTrackers() ns.ShowTrackers(nil) end

--- (0.5.0, public) The Explorer on Trackers, one tracker selected (a pack window's "Its tracker"; the Packs tab).
--- A search, when given, filters the list instead (the Packs tab: a pack's title).
function ns.ShowTracker(id, search)
  ns.ShowTrackers(true)
  local b = ns.ExplorerBrowser
  if not b then return end
  if b.SetSearch then b:SetSearch(search or "") end
  if id and b.Select then b:Select(id, "trackers") end
end
function HC:ShowTracker(id) ns.ShowTracker(id) end

--- (0.5.0, public) A tile of a reading on a board, as the Explorer's Add tile... does (docs/API.md §7).
function HC:AddTile(readingId, anchor, arg)
  if type(readingId) ~= "string" or not ns.readings[readingId] then return end
  addToBoard(readingId, anchor, arg)
end

ns.AddSlash("trackers", function() ns.ShowTrackers(true) end, L["what Hard Counters counts and how much history it keeps (in the Explorer tab)"])

local owner = {}
HC.RegisterCallback(owner, "HC_TRACKERS_CHANGED", function() refresh() end)
HC.RegisterCallback(owner, "HC_HISTORY_DELETED", function() refresh() end)

-- First use: a line about history, once (§3.4); a new pack's trackers: the Explorer opens once on them, marked New
-- (§2.3)
ns.On("PLAYER_ENTERING_WORLD", function(_, isInitialLogin, isReload)
  if not ns.ready or not ns.settings then return end
  local s = ns.settings
  s.tips = type(s.tips) == "table" and s.tips or {}
  if not s.tips.history and ns.Print then
    s.tips.history = true
    ns.Print(L["A tile you place switches its tracker on, with daily history. The Explorer tab (/hc explorer) lists "
      .. "every tracker, what it keeps and what it takes on disk."])
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
