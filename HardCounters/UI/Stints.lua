-- The Stints tab (0.4.0; the run list and its summary card before): stretches of play you kept, on the shared
-- browser (UI/Browser.lua) like the Boards and Trackers tabs. "Stint" is the player's word (the design lead, 0.4.0:
-- "a stint is a stretch of play you kept"); the code, the saved data (HardCountersDB.runs), the tile scope "run" and
-- the HC_RUN_* callbacks keep "run", so nothing saved moves. Tree: All stints, This character, Places (one per main
-- zone). List: When, Name, Where, Active, the headline reading. Detail, at the bottom as on the other tabs: the
-- stint's numbers, its counts with their top breakdowns, what dropped, the best single values, its splits. Actions:
-- Rename..., Copy as text, Delete; at the top right, Start stint or Stop and keep. /hc stints opens it.
local ADDON, ns = ...

local HC, L, U, Wd, Win = ns.HC, ns.L, ns.U, ns.Widgets, ns.Windows
local format, date = string.format, ns.wow.date
local ID = "stints"
local DOT = " \194\183 "                    -- a middle dot (Latin-1: the game's default fonts have it)
local GREY = "|cff808080"
local TOP_LOOT = 15                          -- members of a live tally in the detail (the copied text has them all)
local TOP_BY = 3                             -- members of a breakdown in the detail

local content, browser
-- names looked up once: a refresh names every row's place. Zones are forgotten at each refresh (an instance's name
-- is learned when you first enter it); an item is kept once the client knows it.
local zoneNames, itemNames = {}, {}

---------------------------------------------------------------------------
-- Names and numbers
---------------------------------------------------------------------------

local function itemName(id)
  if type(id) ~= "number" then return tostring(id) end
  if itemNames[id] then return itemNames[id] end
  local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
  local name = getInfo and getInfo(id)
  if not name then
    -- not cached by the client yet: asked for, and named on a later look (never kept as "item 1234")
    if C_Item and C_Item.RequestLoadItemDataByID then C_Item.RequestLoadItemDataByID(id) end
    return "item " .. id
  end
  itemNames[id] = name
  return name
end

local function zoneName(key)
  if key == nil then return "" end
  local n = zoneNames[key]
  if not n then n = HC:ZoneName(key) or tostring(key); zoneNames[key] = n end
  return n
end

--- A member of a counter's dimension in words: items and zones by name, the overflow buckets in brackets.
local function memberName(dim, key)
  if key == "other" then return L["(other)"] end
  if key == "none" then return L["(none)"] end
  if dim == "item" then return itemName(key) end
  if dim == "zone" and type(key) == "number" then return zoneName(key) end
  return tostring(key)
end

local function fmtValue(counterId, v)
  local c = ns.counters[counterId]
  return ns.FormatValue(c and c.formatter, v)
end

local function counterTitle(cid)
  local c = ns.counters[cid]
  return c and c.title or tostring(cid)
end

--- A map's keys sorted by value, biggest first (ties by key, so the order never jumps between refreshes).
local function topKeys(m)
  local keys = {}
  for k in pairs(m) do keys[#keys + 1] = k end
  table.sort(keys, function(a, b)
    if m[a] ~= m[b] then return m[a] > m[b] end
    return tostring(a) < tostring(b)
  end)
  return keys
end

--- The live tallies' counters in the registry's order (pairs() would shuffle them between refreshes), then those of
--- packs not loaded now, by id.
local function liveIds(rec)
  local out, seen, rest = {}, {}, {}
  if type(rec.live) ~= "table" then return out end
  for _, cid in ipairs(ns.counterOrder) do
    if rec.live[cid] then out[#out + 1] = cid; seen[cid] = true end
  end
  for cid in pairs(rec.live) do if not seen[cid] then rest[#rest + 1] = tostring(cid) end end
  table.sort(rest)
  for _, cid in ipairs(rest) do out[#out + 1] = cid end
  return out
end

local function stintName(rec) return rec.label or format(L["Stint #%d"], rec.id or 0) end

local function whenText(rec) return date("%Y-%m-%d %H:%M", rec.start or 0) end

--- "2026-11-26 14:02 - 15:20" (the end's date only when it is another day).
local function rangeText(rec)
  local stop = rec.stop or rec.start or 0
  local sameDay = date("%Y-%m-%d", rec.start or 0) == date("%Y-%m-%d", stop)
  return whenText(rec) .. " - " .. date(sameDay and "%H:%M" or "%Y-%m-%d %H:%M", stop)
end

local function headline()
  local hid = Wd.HeadlineId()
  return hid and ns.readings[hid]
end

---------------------------------------------------------------------------
-- The summary as text (Copy as text; also read by other code)
---------------------------------------------------------------------------

--- A counter's breakdowns (rec.deltas[cid].by) by dimension name (pairs() would shuffle them).
local function dimsOf(d)
  local dims = {}
  for dim in pairs(d.by or {}) do dims[#dims + 1] = dim end
  table.sort(dims)
  return dims
end

local function liveMember(cid)
  local c = ns.counters[cid]
  return c and c.runLive and c.runLive.member
end

--- A best single value's thing in words ("Linen Cloth"), or nil: its item, else its member when that is an item.
local function bestWhat(cid, best)
  local what = best.item or (liveMember(cid) == "item" and type(best.member) == "number" and best.member) or nil
  return what and itemName(what) or nil
end

--- Every number of a kept stint as plain text.
function ns.RunSummaryText(rec)
  local out = {}
  out[#out + 1] = format(L["Stint: %s"], stintName(rec)) .. (rec.charName and ("  (" .. rec.charName .. ")") or "")
  out[#out + 1] = format(L["%s   active %s, elapsed %s%s"], rangeText(rec), U.duration(rec.activeSeconds),
    U.duration(rec.elapsed), rec.mainZone and ("   " .. format(L["in %s"], zoneName(rec.mainZone))) or "")
  out[#out + 1] = ""
  for _, id in ipairs(ns.readingOrder) do
    local _, text = Wd.RecordReading(ns.readings[id], rec)
    out[#out + 1] = format("  %-24s %s", ns.readings[id].title, text)
  end
  out[#out + 1] = ""
  for _, cid in ipairs(ns.counterOrder) do
    local d = rec.deltas and rec.deltas[cid]
    local c = ns.counters[cid]
    if d and c and cid ~= ns.TIME_ID and ((d.sum and d.sum ~= 0) or d.stop ~= nil) then
      if c.kind == "stock" then
        out[#out + 1] = format("%s: %s -> %s", c.title, fmtValue(cid, d.start or 0), fmtValue(cid, d.stop or 0))
      else
        out[#out + 1] = format("%s: %s", c.title, fmtValue(cid, d.sum or 0))
        for _, dim in ipairs(dimsOf(d)) do
          local m = d.by[dim]
          local keys = topKeys(m)
          local parts = {}
          for i = 1, math.min(#keys, 6) do
            parts[#parts + 1] = format("%s %s", memberName(dim, keys[i]), fmtValue(cid, m[keys[i]]))
          end
          if #parts > 0 then out[#out + 1] = "    " .. format(L["by %s: %s"], dim, table.concat(parts, ", ")) end
        end
      end
    end
  end
  for _, cid in ipairs(liveIds(rec)) do
    local Lv, member = rec.live[cid], liveMember(cid)
    if Lv.m then
      local keys = topKeys(Lv.m)
      out[#out + 1] = ""
      out[#out + 1] = format(L["%s (%d kinds):"], counterTitle(cid), #keys)
      for i = 1, #keys do
        out[#out + 1] = format("    %s x%s", memberName(member, keys[i]), U.number(Lv.m[keys[i]]))
      end
    end
    if Lv.max then
      local what = bestWhat(cid, Lv.max)
      out[#out + 1] = format(L["Best %s: %s%s"], counterTitle(cid), fmtValue(cid, Lv.max.v), what and (" (" .. what .. ")") or "")
    end
  end
  if rec.splits then
    out[#out + 1] = ""
    out[#out + 1] = L["Splits"] .. ":"
    local r = headline()
    for i, sp in ipairs(rec.splits) do
      local text = r and select(2, Wd.RecordReading(r, sp)) or "-"
      out[#out + 1] = format("  %d. %-16s %s  %s", i, sp.label or "", format(L["active %s"], U.duration(sp.activeSeconds)),
        text)
    end
  end
  return table.concat(out, "\n")
end

---------------------------------------------------------------------------
-- The provider (UI/Browser.lua's spec)
---------------------------------------------------------------------------

--- The kept records, read in place (Core/Runs.lua: no copies; never written here).
local function records() return ns.StintRows and ns.StintRows() or {} end

--- The zone of a "z:<key>" node (zone keys are numbers, HC-25), else nil.
local function nodeZone(node) return type(node) == "string" and tonumber(node:match("^z:(.+)$")) or nil end

local function inNode(rec, node)
  if node == "char" then return rec.char == ns.guid end
  if node == "places" then return rec.mainZone ~= nil end
  local z = nodeZone(node)
  if z then return rec.mainZone == z end
  return true
end

local function nodes()
  local list = records()
  local mine, placed, byZone, zones = 0, 0, {}, {}
  for _, rec in ipairs(list) do
    if rec.char == ns.guid then mine = mine + 1 end
    local z = rec.mainZone
    if z ~= nil then
      placed = placed + 1
      if not byZone[z] then byZone[z] = 0; zones[#zones + 1] = z end
      byZone[z] = byZone[z] + 1
    end
  end
  -- the places you went most first, then by name (then by key: two maps can share a name)
  table.sort(zones, function(a, b)
    if byZone[a] ~= byZone[b] then return byZone[a] > byZone[b] end
    local na, nb = zoneName(a), zoneName(b)
    if na ~= nb then return na < nb end
    return tostring(a) < tostring(b)
  end)
  local out = {
    { key = "all", text = L["All stints"], count = #list },
    { key = "char", text = L["This character"], count = mine },
    { key = "places", text = L["Places"], count = placed },
  }
  for _, z in ipairs(zones) do
    out[#out + 1] = { key = "z:" .. tostring(z), text = zoneName(z), count = byZone[z], indent = 1 }
  end
  return out
end

local function matches(search, ...)
  if search == "" then return true end
  for i = 1, select("#", ...) do
    local s = select(i, ...)
    if type(s) == "string" and s:lower():find(search, 1, true) then return true end
  end
  return false
end

local function rows(node, search)
  local out, r = {}, headline()
  for _, rec in ipairs(records()) do
    if inNode(rec, node) then
      local name, where, when = stintName(rec), zoneName(rec.mainZone), whenText(rec)
      if matches(search, name, where, when, rec.charName) then
        local v, text
        if r then v, text = Wd.RecordReading(r, rec) end
        out[#out + 1] = { key = rec.id, rec = rec, headV = type(v) == "number" and v or nil, cells = {
          when = when, name = name, where = where, active = U.duration(rec.activeSeconds), head = text or "" } }
      end
    end
  end
  return out
end

--- One item of the detail: a label and its value (the browser draws the value right-aligned; `text` alone still
--- reads as the label).
local function item(text, value, grey) return { text = text, value = value, grey = grey } end

local function numberItems(rec, items)
  local n = #items
  items[#items + 1] = { text = L["Numbers"], head = true }
  for _, id in ipairs(ns.readingOrder) do
    local r = ns.readings[id]
    local v, text = Wd.RecordReading(r, rec)
    -- (every run reading of every tracker is in the order: only the ones this stint gave a number say anything)
    if type(v) == "number" and v ~= 0 then items[#items + 1] = item("  " .. r.title, text) end
  end
  if #items == n + 1 then items[#items] = nil end
end

local function countItems(rec, items)
  local n = #items
  items[#items + 1] = { text = L["Counts"], head = true }
  for _, cid in ipairs(ns.counterOrder) do
    local d = rec.deltas and rec.deltas[cid]
    local c = ns.counters[cid]
    if d and c and cid ~= ns.TIME_ID and ((d.sum and d.sum ~= 0) or d.stop ~= nil) then
      if c.kind == "stock" then
        local span = format("%s -> %s", fmtValue(cid, d.start or 0), fmtValue(cid, d.stop or 0))
        items[#items + 1] = item("  " .. c.title, span)
      else
        items[#items + 1] = item("  " .. c.title, fmtValue(cid, d.sum or 0))
        -- its top breakdowns under it, grey: where the total came from
        for _, dim in ipairs(dimsOf(d)) do
          local m = d.by[dim]
          local keys = topKeys(m)
          for i = 1, math.min(#keys, TOP_BY) do
            local label = "      " .. format(L["by %s: %s"], dim, memberName(dim, keys[i]))
            items[#items + 1] = item(label, fmtValue(cid, m[keys[i]]), true)
          end
        end
      end
    end
  end
  if #items == n + 1 then items[#items] = nil end
end

local function liveItems(rec, items)
  local best = {}
  for _, cid in ipairs(liveIds(rec)) do
    local Lv, member = rec.live[cid], liveMember(cid)
    if Lv.m then
      local keys = topKeys(Lv.m)
      items[#items + 1] = { text = format(L["%s (%d kinds)"], counterTitle(cid), #keys), head = true }
      for i = 1, math.min(#keys, TOP_LOOT) do
        items[#items + 1] = item("  " .. memberName(member, keys[i]), "x" .. U.number(Lv.m[keys[i]]))
      end
      if #keys > TOP_LOOT then
        items[#items + 1] = item("  " .. format(L["and %d more (Copy as text has them all)"], #keys - TOP_LOOT), nil, true)
      end
    end
    if Lv.max then
      local what = bestWhat(cid, Lv.max)
      best[#best + 1] = item("  " .. counterTitle(cid), fmtValue(cid, Lv.max.v) .. (what and ("  (" .. what .. ")") or ""))
    end
  end
  if #best > 0 then
    items[#items + 1] = { text = L["Best"], head = true }
    for _, b in ipairs(best) do items[#items + 1] = b end
  end
end

local function splitItems(rec, items)
  if not rec.splits then return end
  items[#items + 1] = { text = L["Splits"], head = true }
  local r = headline()
  for i, sp in ipairs(rec.splits) do
    local text = r and select(2, Wd.RecordReading(r, sp)) or ""
    local value = format("%s  %s", format(L["active %s"], U.duration(sp.activeSeconds)), text)
    items[#items + 1] = item(format("  %d. %s", i, sp.label or ""), value)
  end
end

local function detail(row)
  local rec = row.rec
  local parts = { format(L["Active %s"], U.duration(rec.activeSeconds)), format(L["elapsed %s"], U.duration(rec.elapsed)) }
  if (rec.pausedSeconds or 0) >= 60 then parts[#parts + 1] = format(L["paused %s"], U.duration(rec.pausedSeconds)) end
  if rec.mainZone ~= nil then parts[#parts + 1] = format(L["in %s"], zoneName(rec.mainZone)) end
  if rec.charName then parts[#parts + 1] = rec.charName end
  local lines = { table.concat(parts, DOT) }
  if rec.partial then
    lines[#lines + 1] = GREY .. L["Kept from tiles that watched some counters only: the others have no number here."]
      .. "|r"
  end
  local items = {}
  numberItems(rec, items)
  countItems(rec, items)
  liveItems(rec, items)
  splitItems(rec, items)
  return { title = stintName(rec) .. "   " .. GREY .. rangeText(rec) .. "|r", lines = lines, items = items }
end

local refresh

local function confirm(text, fn)
  if ns.Boards and ns.Boards.Confirm then ns.Boards.Confirm(text, fn) else fn() end
end

local function askText(prompt, current, fn)
  if ns.Boards and ns.Boards.AskText then ns.Boards.AskText(prompt, current, fn) end
end

local function actions(row)
  if not row then return {} end
  local rec = row.rec
  return {
    { text = L["Rename..."], tip = L["Give this stint a name of your own (a dungeon names its stint after itself)."],
      func = function()
        askText(L["Stint name"], rec.label or "", function(s) HC:RenameRun(rec.id, s); refresh() end)
      end },
    { text = L["Copy as text"], tip = L["Every number of this stint as plain text, to paste anywhere."],
      func = function() ns.ShowCopyBox(format(L["Stint: %s"], stintName(rec)), ns.RunSummaryText(rec)) end },
    { text = L["Delete"], tip = L["Removes this record only: your counters, history and boards don't change."],
      func = function()
        confirm(format(L["Delete the stint %s? Your counts don't change."], stintName(rec)), function()
          HC:DeleteRun(rec.id)                        -- HC_RUN_DELETED refreshes the tab
        end)
      end },
  }
end

local function footer()
  local maxKept = (ns.settings and ns.settings.maxRuns) or 500
  return format(L["%d stints kept (Options: up to %d)"], #records(), maxKept)
end

--- The header button: Start stint, or Stop and keep while one is open (dungeons open their own). A refusal (storage
--- read-only) is said in chat in the player's words, as /hc stint says it.
local function startStop()
  local ok, err
  if HC:GetRunClock() then ok, err = HC:StopRun() else ok, err = HC:StartRun() end
  if not ok and ns.Print then ns.Print("|cffff6060%s|r", ns.StintReason and ns.StintReason(err) or tostring(err)) end
  refresh()
end

local function startStopTip()
  local active, elapsed, state = HC:GetRunClock()
  if not active then
    return L["Starts a stint now: everything counted from here is in it until Stop and keep. Dungeons start their own."]
  end
  local run = HC:GetRun()
  return format(L["Ends the open stint (%s: %s, active %s, elapsed %s) and keeps it in this list."],
    run and (run.label or format(L["Stint #%d"], run.id)) or "", L[state or ""], U.duration(active), U.duration(elapsed))
end

function refresh()
  if not (content and content:IsShown() and browser) then return end
  for k in pairs(zoneNames) do zoneNames[k] = nil end
  local r = headline()
  browser.spec.columns[5].title = r and r.title or ""       -- the headline may have changed (Options)
  local btn = browser.headerBtns[1]
  if btn then btn:SetText(HC:GetRunClock() and L["Stop and keep"] or L["Start stint"]) end
  browser:Refresh()
end
ns.RefreshRunList = refresh

local function build(f)
  content = f
  browser = ns.Browser.New(f, {
    columns = {
      { key = "when", title = L["When"], width = 100, sort = function(row) return row.rec.start or 0 end },
      { key = "name", title = L["Name"] },
      { key = "where", title = L["Where"], width = 120 },
      { key = "active", title = L["Active"], width = 56, align = "RIGHT",
        sort = function(row) return row.rec.activeSeconds or 0 end },
      -- the headline reading (Wd.HeadlineId: the player's choice); its title is set at each refresh
      { key = "head", title = "", width = 84, align = "RIGHT", sort = function(row) return row.headV or -math.huge end },
    },
    nodes = nodes, rows = rows, detail = detail, actions = actions, footer = footer,
    header = {
      { text = L["Start stint"], width = 110, func = startStop, tip = startStopTip },
    },
    empty = function(node, search)
      if search ~= "" then return L["Nothing matches the search."] end
      if node == "all" then
        return L["No stints yet: walk into a dungeon, or use Start stint at the top right."]
      end
      return L["No stints here."]
    end,
    noSelection = L["Click a stint for its numbers: totals, per hour, what dropped, its best and its splits."],
  })
  ns.StintsBrowser = browser
end

Win.Register(ID, {
  title = L["Stints"], icon = "Interface\\Icons\\INV_Misc_PocketWatch_01", tabOrder = 4,
  about = L["Stretches of play you kept, each with its numbers: dungeons, farming rounds, board timers."],
  width = 720, height = 440, minWidth = 600, minHeight = 360,
  build = build, onShow = function() refresh() end,
  onHide = function() if ns.Menu then ns.Menu.Hide() end end,
})

function ns.ToggleRunList() Win.Show(ID, nil) end
function ns.ShowStints(show) Win.Show(ID, show) end
function HC:ToggleRunList() ns.ToggleRunList() end
function HC:ToggleStints() ns.ToggleRunList() end

--- The Stints tab with that record selected (the floating summary card of 0.3 went: the detail is in the tab).
function ns.ShowRunCard(rec)
  if type(rec) ~= "table" or rec.id == nil then return end
  Win.Show(ID, true)
  if not browser then return end
  browser:Select(rec.id, "all")
  if browser.selected ~= rec.id and browser.search ~= "" then  -- hidden by the search: clear it, select again
    browser:SetSearch("")
    browser:Select(rec.id, "all")
  end
  for i, row in ipairs(browser.rowsData) do
    if row.key == rec.id then
      local n = browser:VisibleRows()
      if i <= browser.listOff or i > browser.listOff + n then browser:ScrollList(i - 1, true) end
      break
    end
  end
end

-- The tab was "runs" before 0.4.0: a window last left on it opens on it again; its old settings mean nothing now.
ns.OnReady(function()
  local w = ns.settings and ns.settings.windows
  if type(w) ~= "table" then return end
  if type(w._main) == "table" and w._main.selected == "runs" then w._main.selected = ID end
  w.runs = nil
end)

local owner = {}
HC.RegisterCallback(owner, "HC_RUN_STARTED", function() refresh() end)
HC.RegisterCallback(owner, "HC_RUN_STOPPED", function() refresh() end)
HC.RegisterCallback(owner, "HC_RUN_DELETED", function() refresh() end)

ns.AddSlash("stints", function() ns.ToggleRunList() end, L["the Stints tab: stretches of play you kept, with their numbers"])
ns.AddSlash("runs", function() ns.ToggleRunList() end)              -- (its name before 0.4.0; not listed)
-- luacheck: push no max line length

-- This tab's help and tour (UI/Help.lua): change them with the tab.
local _ = ns.Help and ns.Help.Register(ID, {
  what = "A stint is a stretch of play you kept, with its numbers: how long you were active, the gold, the XP, what dropped. This tab lists the stints kept on this account, newest first.",
  can = {
    "Click a stint: its {Numbers}, {Counts}, what dropped, its {Best} single values and its {Splits} fill the bottom of the tab.",
    "{Rename...} it, {Copy as text} to paste it anywhere, or {Delete} it.",
    "{Start stint} at the top right starts one by hand and {Stop and keep} saves it; dungeons record themselves. /hc stint start and /hc stint stop do the same from the chat line.",
    "{This character} and {Places} on the left narrow the list; the search box finds a stint by name, place or date.",
  },
  effect = "Stints are your yardstick: a big per-hour tile on a board compares what you do now with your past stints in the same place. Deleting a stint only removes that record; your counters and history are untouched.",
  tour = {
    { title = "One row per stint", text = "Each row is a stint: {When} it started, its {Name}, {Where} you spent most of it and how long you were {Active}; the last column is your headline number. A dungeon names its stint after itself." },
    { title = "Where stints come from", text = "Three ways: walk into a dungeon (it records itself and keeps the stint when you leave), a board with a timer of its own (its menu keeps the stretch its clock counted), or {Start stint} here and {Stop and keep} when you are done." },
    { title = "Look inside one", text = "Click a stint and its numbers fill the bottom of the tab: per hour and totals, what dropped, the best single values, the splits. {Copy as text} puts all of it in a box to paste anywhere." },
  },
})
-- luacheck: pop
