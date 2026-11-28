-- The Explorer tab (0.4.0, the user: the Boards tab renamed "to Explorer or Browser or something more awesome",
-- with the tiles "included and categorized properly", and the Trackers tab's content browser and the visual toolkit
-- merged in, "the proper actions per board/tile"). One browser (UI/Browser.lua) over everything a player can count
-- and show, in four parts:
--   MY SETUP      Boards (UI/BoardCatalog.lua), Tiles (every tile of every board)
--   ADD           Ready-made boards (by group), Readings (every number, by its tracker's category), Displays (the
--                 five ways a tile can look: the visual toolkit)
--   WHAT IS COUNTED  Trackers (UI/Trackers.lua: on or off, history, size), Not loaded
--   OTHER CHARACTERS  their boards, to copy (once there are any)
-- The columns, the detail pane and the action bar follow the selected node. The list and the detail pane share
-- their height through the browser's splitter (saved under settings.windows.explorer). /hc explorer opens it;
-- /hc trackers opens it on Trackers.
-- luacheck: no max line length (tips and help: one sentence, one string)
local ADDON, ns = ...

local HC, L = ns.HC, ns.L
local format = string.format

local ID = "explorer"
local content, browser, ticker

local function BM() return ns.BoardModel end
local function Bo() return ns.Boards end
local function BC() return ns.BoardCatalog end
local function TC() return ns.TrackerCatalog end

local function matches(search, text)
  return search == "" or (type(text) == "string" and text:lower():find(search, 1, true) ~= nil)
end

local function refresh()
  if not (content and content:IsShown() and browser) then return end
  browser:Refresh()
end
ns.RefreshExplorer = refresh
ns.RefreshBoardsTab = refresh                 -- (its name until 0.4.0; board code still calls it)

local function refreshAll()
  if ns.RefreshBoards then ns.RefreshBoards() end
  refresh()
end

local function confirm(text, fn) if Bo() and Bo().Confirm then Bo().Confirm(text, fn) else fn() end end

---------------------------------------------------------------------------
-- Tiles: every tile of every board
---------------------------------------------------------------------------

local CALC_WORD = { total = "Total", perHour = "Per hour", recent = "Recent", trend = "Trend" }
local DISPLAY_WORD = { number = "Number", bar = "Bar", gauge = "Gauge", odometer = "Odometer", mix = "Mix" }
local SIZE_WORD = { large = "Big", largeHalf = "Big, half width", half = "Medium, half width", line = "Line",
  lineHalf = "Line, half width" }

local function scopeWord(scope)
  if scope == "run" then return L["board timer"] end
  return scope and L[scope] or ""
end

--- How a tile shows, in words: "Bar, per hour, today".
local function showsText(e)
  local M = BM()
  local parts = { L[DISPLAY_WORD[M.TileDisplay(e.tile)] or "Number"] }
  local calc = M.TileCalc(e.tile)
  if calc and calc ~= "total" then parts[#parts + 1] = L[CALC_WORD[calc] or calc]:lower() end
  parts[#parts + 1] = scopeWord(e.raw.scope)
  return table.concat(parts, ", ")
end

local function tileValue(e)
  local M = BM()
  local ok, v, text, settled = pcall(M.TileValue, e.tile, e.board)
  if not ok then return "?" end
  if M.NEEDS_TARGET[M.TileDisplay(e.tile)] and M.TileTarget(e.tile) then
    local okP, _, ptext = pcall(M.Progress, e.tile, e.board)
    if okP and ptext then text = ptext end
  end
  if settled == false or type(v) ~= "number" then return "|cff909090" .. (text or "-") .. "|r" end
  return text or "-"
end

local function tileEntries()
  local out = {}
  for _, g in ipairs(BM().TilesByBoard()) do
    for _, e in ipairs(g.entries) do out[#out + 1] = e end
  end
  return out
end

local function tileRows(search, node)
  local M, out = BM(), {}
  local only = type(node) == "string" and node:match("^tb:(.+)$")     -- (0.5.0) one board's tiles
  for _, e in ipairs(tileEntries()) do
    local label = M.TileLabel(e.tile, e.board)
    if (not only or (e.board and tostring(e.board.id) == only))
        and (matches(search, label) or matches(search, e.board and e.board.name)) then
      local onHud = M.TileOnHud(e.tile)
      out[#out + 1] = { key = "t:" .. tostring(e.id), entry = e, grey = not (onHud and e.board.shown),
        cells = { name = label, board = e.board and e.board.name or "", shows = showsText(e), now = tileValue(e) } }
    end
  end
  return out
end

--- The Edit, On HUD, Move to and Delete of a tile (as a card's menu in the Boards tab).
local function tileOnHud(e)
  local M = BM()
  local onHud = M.TileOnHud(e.tile)
  return { text = onHud and L["On HUD"] or L["Only here"], on = onHud and (e.board.shown and true or "warn") or false,
    func = function()
      M.SetTileOnHud(e.tile, not onHud)
      Bo().Refresh(e.board.id, true)
      refreshAll()
    end,
    tip = { title = L["This tile on your HUD"], on = onHud,
      state = onHud and (e.board.shown and L["Now: drawn with its board"] or L["Now: will show once its board is on your HUD"])
        or L["Now: kept off the HUD (it still counts)"],
      text = L["One tile can stay off the screen while the rest of its board is on it."],
      click = onHud and L["Click: keep it off the HUD."] or L["Click: draw it with its board."] } }
end

local function moveMenu(anchor, e)
  local M = BM()
  local items = { { text = L["Move to board"], title = true } }
  for _, b in ipairs(M.MoveTargets(e.board)) do
    items[#items + 1] = { text = b.shown and b.name or format(L["%s (Only here)"], b.name), func = function()
      local from = e.board
      local p = M.Place(e.raw, b)
      Bo().Refresh(from.id, true)
      if p then Bo().Reveal(b, p) end
      refreshAll()
    end }
  end
  items[#items + 1] = { text = L["New board"], tip = L["A board of its own, named after the tile; not on your HUD until you put it there."],
    func = function()
      local from, i = M.BoardOf(e.tile)
      if from then
        local shown = from.shown
        from.shown = false                          -- (MoveTo gives a new board its old board's place on the HUD)
        M.MoveTo(from, i, nil)
        from.shown = shown
        Bo().Refresh(from.id, true)
      end
      refreshAll()
    end }
  ns.Menu.Show(anchor, items)
end

--- (0.5.0-beta2) "Copy to board...": every board (the tile's own first), then a new one, not on the HUD.
local function copyMenu(anchor, e)
  local M = BM()
  local items = { { text = L["Copy to board"], title = true } }
  local function go(target)
    return function()
      local from, i = M.BoardOf(e.tile)
      if not from then return end
      local c, now = M.CopyTo(from, i, target, false)
      Bo().Refresh(from.id, true)
      if now and now ~= from then Bo().Refresh(now.id, true) end
      if now and target and c then Bo().Reveal(now, c) end
      refreshAll()
    end
  end
  for _, b in ipairs(M.CopyTargets(e.board)) do
    local text = b == e.board and format(L["%s (this board)"], b.name) or (b.shown and b.name or format(L["%s (Only here)"], b.name))
    items[#items + 1] = { text = text, func = go(b) }
  end
  items[#items + 1] = { text = L["New board"], tip = L["A board of its own with the copy, named after the tile; not on your HUD until you put it there."],
    func = go(nil) }
  ns.Menu.Show(anchor, items)
end

local function tileDetail(row)
  local M, e = BM(), row.entry
  local r = ns.readings[e.raw.reading]
  local lines = {}
  if r and r.description then lines[#lines + 1] = r.description end
  -- (0.5.0, G1) "why does it say that?" first: the value, then how it is made, line by line (BoardModel.Explain)
  local items = { { text = L["Now"], value = tileValue(e), big = true } }
  for _, l in ipairs(M.Explain(e.tile, e.board, {})) do
    if l.label ~= L["What"] then items[#items + 1] = { text = l.label, value = l.text, warn = l.warn, grey = false } end
  end
  items[#items + 1] = { text = L["Board"], value = e.board.name .. "  " .. (ns.BoardStatusText and (ns.BoardStatusText(e.board)) or "") }
  items[#items + 1] = { text = L["On your HUD"], status = tileOnHud(e) }
  items[#items + 1] = { text = L["Shows as"], value = showsText(e) }
  items[#items + 1] = { text = L["Displays it can take"], head = true }
  local cur = M.TileDisplay(e.tile)
  for _, d in ipairs(M.DISPLAY_ORDER) do
    if M.DisplayFits(e.tile, d) then
      items[#items + 1] = { text = L[DISPLAY_WORD[d]], grey = d ~= cur, value = d == cur and L["(this one)"] or nil,
        button = d ~= cur and { text = L["Use"], tip = format(L["Draw this tile as a %s."], L[DISPLAY_WORD[d]]:lower()),
          func = function()
            if M.NEEDS_TARGET[d] and not M.TileTarget(e.tile) then
              -- a bar or a gauge needs a target: the tile's own Display menu asks for one
              local edit = Bo().TileSettingsItems(e.tile, e.board, content)
              if #edit > 0 then ns.Menu.Show(content, edit) end
              return
            end
            M.SetDisplay(e.tile, d, e.board)
            Bo().Refresh(e.board.id, true)
            refreshAll()
          end } or nil }
    end
  end
  return { title = M.TileLabel(e.tile, e.board) .. "   |cff808080" .. (r and r.tracker and (HC:GetTracker(r.tracker) or {}).title or "") .. "|r",
    lines = lines, items = items }
end

local function tileActions(row)
  local M, e = BM(), row.entry
  local label = M.TileLabel(e.tile, e.board)
  local hud = tileOnHud(e)
  return {
    { text = L["Edit..."], func = function(btn)
        local edit = Bo().TileSettingsItems(e.tile, e.board, btn)
        if #edit > 0 then ns.Menu.Show(btn, edit) end
      end,
      tip = { title = L["Edit..."], text = L["Everything about this tile: what it counts, its period, total or per hour, number, bar or gauge, its size, its name."],
        click = L["Click: the tile's menu."] } },
    { text = hud.text, status = true, on = hud.on, func = hud.func, tip = hud.tip },
    { text = L["How it's made"], func = function(btn) if ns.Synopsis then ns.Synopsis.Show(btn, e.tile, e.board, "panel") end end,
      tip = { title = L["How it's made"], text = L["What it counts, over when, and how the number is worked out, in a small panel."] } },
    { text = L["Move to board..."], func = function(btn) moveMenu(btn, e) end,
      tip = { title = L["Move to board..."], text = L["Another board, or a new one of its own. It keeps its settings."] } },
    { text = L["Copy to board..."], more = true, func = function(btn) copyMenu(btn, e) end,
      tip = L["A copy of this tile, with its settings, on another board or this one. The original stays."] },
    { text = L["Delete tile"], more = true, tip = L["Delete this tile; your counts don't change."], func = function()
      confirm(format(L["Delete the tile %s? Your counts don't change."], label), function()
        local b = e.board
        M.DeleteTile(e.id)
        Bo().Refresh(b.id, true)
        refreshAll()
      end)
    end },
  }
end

---------------------------------------------------------------------------
-- Readings: every number Hard Counters can show
---------------------------------------------------------------------------

local function readingCategory(r)
  local t = r.tracker and ns.trackers[r.tracker]
  if not t then return L["Other"] end
  return TC().CategoryOf({ category = t.category, packTitle = t.packTitle })
end

--- How many tiles show each reading (by id).
local function placedCounts()
  local out = {}
  for _, e in ipairs(tileEntries()) do
    local id = e.raw.reading
    if id then out[id] = (out[id] or 0) + 1 end
  end
  return out
end

local function readingNodes()
  local byCat, cats, total = {}, {}, 0
  for _, rid in ipairs(ns.allReadingOrder or {}) do
    local c = readingCategory(ns.readings[rid])
    if not byCat[c] then byCat[c] = 0; cats[#cats + 1] = c end
    byCat[c] = byCat[c] + 1
    total = total + 1
  end
  local out = { { key = "readings", text = L["Readings"], count = total } }
  for _, c in ipairs(cats) do out[#out + 1] = { key = "rc:" .. c, text = L[c], count = byCat[c], indent = 1 } end
  return out
end

local function readingRows(node, search)
  local out, placed = {}, placedCounts()
  for _, rid in ipairs(ns.allReadingOrder or {}) do
    local r = ns.readings[rid]
    if node == "readings" or node == "rc:" .. readingCategory(r) then
      local title = TC().ListTitle(r)
      local t = r.tracker and HC:GetTracker(r.tracker)
      if matches(search, title) or matches(search, r.description) then
        local applies = ns.ReadingApplies(r) ~= false
        out[#out + 1] = { key = "r:" .. rid, reading = r, grey = not applies,
          cells = { name = title, tracker = t and (t.title .. (t.on and "" or "  |cff808080" .. L["(off)"] .. "|r")) or "",
            scopes = TC().ScopeChips(r), placed = placed[rid] and tostring(placed[rid]) or "" } }
      end
    end
  end
  return out
end

local function readingDetail(row)
  local r = row.reading
  local t = r.tracker and HC:GetTracker(r.tracker)
  local lines = {}
  if r.description then lines[#lines + 1] = r.description end
  if ns.ReadingApplies(r) == false then lines[#lines + 1] = "|cff808080" .. L["Not used by this character."] .. "|r" end
  local items = {
    { text = L["Tracker"], value = t and t.title or L["none"], status = t and {
      text = t.on and L["Counting"] or L["Not counting"], on = t.on,
      tip = { title = t.title, state = t.on and L["Now: on, counting"] or L["Now: off"], on = t.on,
        text = L["A tile of this reading switches its tracker on."], click = L["Click: open it under Trackers."] },
      func = function() browser:Select(t.id, "trackers") end } or nil },
    { text = L["Periods"], value = TC().ScopeChips(r) },
    { text = L["Grey periods need history; a tile placed turns daily history on."], grey = true },
  }
  -- (0.5.0, G1) "what is this number, and is it what I want before I add it?"
  local function ctitle(id) local c = id and ns.counters[id]; return c and c.title or id end
  local from
  if r.compute then
    local ins = {}
    for _, id in ipairs(r.inputs or {}) do local x = ns.readings[id]; ins[#ins + 1] = x and x.title or id end
    from = #ins > 0 and table.concat(ins, ", ") or L["worked out by its pack"]
  elseif r.live or not r.counter then
    from = L["read from the game, live"]
  else
    from = r.minus and format(L["%s less %s"], ctitle(r.counter), ctitle(r.minus)) or ctitle(r.counter)
  end
  table.insert(items, 1, { text = L["Counted from"], value = from })
  local calcs = {}
  for _, c in ipairs(ns.CALC_ORDER or {}) do
    if ns.CalcAllowed(r, c) then calcs[#calcs + 1] = L[({ total = "Total", perHour = "Per hour", recent = "Recent", trend = "Trend" })[c] or c] end
  end
  if #calcs > 0 then table.insert(items, 2, { text = L["Can show as"], value = table.concat(calcs, ", ") }) end
  local fits = {}
  local probe = { kind = "reading", reading = r.id }
  for _, d in ipairs(BM().DISPLAY_ORDER) do if BM().DisplayFits(probe, d) then fits[#fits + 1] = L[DISPLAY_WORD[d] or d] end end
  table.insert(items, 3, { text = L["Fits"], value = table.concat(fits, ", ") })
  if t and t.on and not r.param then
    local ok, _, text = pcall(HC.Reading, HC, r.id, "session", nil)
    if ok and text then table.insert(items, 1, { text = L["This session"], value = text }) end
  end
  local on = {}
  for _, e in ipairs(tileEntries()) do if e.raw.reading == r.id then on[#on + 1] = e end end
  items[#items + 1] = { text = format(L["On your boards (%d)"], #on), head = true }
  for _, e in ipairs(on) do items[#items + 1] = { text = BM().TileLabel(e.tile, e.board), value = e.board.name } end
  if #on == 0 then items[#items + 1] = { text = L["(on none yet)"], grey = true } end
  return { title = TC().ListTitle(r) .. "   |cff808080" .. (t and t.packTitle or "") .. "|r", lines = lines, items = items }
end

local function readingActions(row)
  local r = row.reading
  local acts = { { text = L["Add tile..."], func = function(btn) TC().AddToBoard(r.id, btn) end,
    tip = { title = L["Add tile..."], text = TC().AddTip(), click = L["Click: add it (you pick the board when you have several)."] } } }
  if r.tracker then
    acts[#acts + 1] = { text = L["Its tracker"], func = function() browser:Select(r.tracker, "trackers") end,
      tip = L["Show this reading's tracker under Trackers: on or off, its history, its size."] }
  end
  return acts
end

---------------------------------------------------------------------------
-- Displays: the visual toolkit
---------------------------------------------------------------------------

local DISPLAY_TEXT = {
  number = "The number itself, in five sizes: Big (with a small graph of the last minutes), Big half width, Medium half width, Line and Line half width. Takes Total, Per hour, Recent and Trend.",
  bar = "A bar filling toward a target: the next level, a skill's cap, or a target you type. Total or per hour.",
  gauge = "A dial toward a target, for a rate you want to keep up: total, per hour or recent.",
  odometer = "Rolling digits for a running total: counts and distances.",
  mix = "One bar split by kind: gold by source, loot by quality. For readings with a few members.",
}

local function displayRows(search)
  local M, out = BM(), {}
  local used = {}
  for _, e in ipairs(tileEntries()) do
    local d = M.TileDisplay(e.tile)
    used[d] = (used[d] or 0) + 1
  end
  for _, d in ipairs(M.DISPLAY_ORDER) do
    local name = L[DISPLAY_WORD[d]]
    if matches(search, name) then
      local spec = M.DISPLAYS[d]
      local sizes = {}
      for _, s in ipairs(spec.sizes) do sizes[#sizes + 1] = L[SIZE_WORD[s]] end
      out[#out + 1] = { key = "d:" .. d, display = d,
        cells = { name = name, sizes = table.concat(sizes, ", "), target = spec.needsTarget and L["yes"] or "",
          used = used[d] and tostring(used[d]) or "" } }
    end
  end
  return out
end

local function displayDetail(row)
  local M, d = BM(), row.display
  local spec = M.DISPLAYS[d]
  local calcs = {}
  for _, c in ipairs({ "total", "perHour", "recent", "trend" }) do if spec.calcs[c] then calcs[#calcs + 1] = L[CALC_WORD[c]] end end
  local items = {
    { text = L["Sizes"], value = row.cells.sizes },
    { text = L["Shows as"], value = table.concat(calcs, ", ") },
    { text = L["Needs a target"], value = spec.needsTarget and L["yes: the reading's own, or one you type"] or L["no"] },
  }
  local mine = {}
  for _, e in ipairs(tileEntries()) do if M.TileDisplay(e.tile) == d then mine[#mine + 1] = e end end
  items[#items + 1] = { text = format(L["Your tiles drawn this way (%d)"], #mine), head = true }
  for _, e in ipairs(mine) do items[#items + 1] = { text = M.TileLabel(e.tile, e.board), value = e.board.name } end
  if #mine == 0 then items[#items + 1] = { text = L["(none yet)"], grey = true } end
  return { title = row.cells.name, lines = { L[DISPLAY_TEXT[d]] }, items = items }
end

--- "Add a tile as a bar...": pick the board, then the reading (only the ones this display fits).
local function addAs(anchor, d)
  local M = BM()
  local look = { display = d, size = (M.DISPLAYS[d].sizes or {})[1] }
  local list = M.Store().list
  if #list == 0 then
    if ns.Print then ns.Print(L["Make a board first: the Boards tab, New board..."]) end
    return
  end
  if #list == 1 then return Bo().AddReadingMenu(anchor, list[1], look) end
  local items = { { text = L["Add to"], title = true } }
  for _, b in ipairs(list) do
    items[#items + 1] = { text = b.shown and b.name or format(L["%s (Only here)"], b.name),
      func = function() Bo().AddReadingMenu(anchor, b, look) end }
  end
  ns.Menu.Show(anchor, items)
end

local function displayActions(row)
  local name = row.cells.name
  return { { text = format(L["Add a tile as %s..."], name:lower()), func = function(btn) addAs(btn, row.display) end,
    tip = { title = format(L["Add a tile as %s..."], name:lower()), text = L["Pick a board, then a number this display can draw."] } } }
end

---------------------------------------------------------------------------
-- The composed provider
---------------------------------------------------------------------------

--- (0.5.0, the user: "the head categories should be entity oriented; i.e. Boards, readings/tiles, trackers, and then
--- per-character contents") heads by kind, each one clickable and folding: Boards (its ready-made ones under it),
--- Tiles (per board; the displays), Readings (per category), Trackers (per category; Not loaded), then one head per
--- other character. Captions that only grouped ("My setup", "Add", "What is counted") are gone.
local function nodes()
  local out = {}
  local function add(n, lv) n.level = lv; n.indent = nil; out[#out + 1] = n end
  for _, n in ipairs(BC().BoardNodes()) do add(n, 0) end
  for _, n in ipairs(BC().PresetNodes()) do add(n, (n.indent or 0) + 1) end
  local groups = BM().TilesByBoard()
  add({ key = "tiles", text = L["Tiles"], count = #tileEntries() }, 0)
  for _, g in ipairs(groups) do
    if g.board and #g.entries > 0 then add({ key = "tb:" .. tostring(g.board.id), text = g.board.name, count = #g.entries }, 1) end
  end
  add({ key = "displays", text = L["Displays"], count = #BM().DISPLAY_ORDER }, 1)
  for _, n in ipairs(readingNodes()) do add(n, n.indent or 0) end
  for _, n in ipairs(TC().Nodes()) do add(n, n.key == "unloaded" and 1 or (n.indent or 0)) end
  for _, n in ipairs(BC().OtherNodes()) do
    if n.key ~= "others" then add(n, 0) end                -- one head per other character
  end
  return out
end

local function kind(node)
  node = tostring(node)
  if node == "tiles" or node:sub(1, 3) == "tb:" then return "tiles" end
  if node == "readings" or node:sub(1, 3) == "rc:" then return "readings" end
  if node == "displays" then return "displays" end
  if TC().Owns(node) then return "trackers" end
  return "boards"
end

local function columns(node)
  local k = kind(node)
  if k == "tiles" then
    return { { key = "name", title = L["Name"] }, { key = "board", title = L["Board"], width = 120 },
      { key = "shows", title = L["Shows as"], width = 130 }, { key = "now", title = L["Now"], width = 80, align = "RIGHT" } }
  elseif k == "readings" then
    return { { key = "name", title = L["Name"] }, { key = "tracker", title = L["Tracker"], width = 120 },
      { key = "scopes", title = L["Periods"], width = 150 }, { key = "placed", title = L["Tiles"], width = 36, align = "RIGHT",
        sort = function(r) return tonumber(r.cells.placed) or 0 end } }
  elseif k == "displays" then
    return { { key = "name", title = L["Display"] }, { key = "sizes", title = L["Sizes"], width = 150 },
      { key = "target", title = L["Target"], width = 50 }, { key = "used", title = L["Tiles"], width = 40, align = "RIGHT" } }
  elseif k == "trackers" then
    return TC().Columns()
  end
  return BC().Columns(node)
end

local function rows(node, search)
  local k = kind(node)
  if k == "tiles" then return tileRows(search, node) end
  if k == "readings" then return readingRows(node, search) end
  if k == "displays" then return displayRows(search) end
  if k == "trackers" then return TC().Rows(node, search) end
  return BC().Rows(node, search)
end

local function detail(row)
  if row.entry then return tileDetail(row) end
  if row.reading then return readingDetail(row) end
  if row.display then return displayDetail(row) end
  if row.t or row.unloaded then return TC().Detail(row) end
  return BC().Detail(row)
end

local function actions(row)
  if not row then return {} end
  if row.entry then return tileActions(row) end
  if row.reading then return readingActions(row) end
  if row.display then return displayActions(row) end
  if row.t or row.unloaded then return TC().Actions(row) end
  return BC().Actions(row)
end

local function rowMenu(row, anchor)
  if row.board or row.other or row.preset then return BC().RowMenu(row, anchor) end
  local items = {}
  for _, a in ipairs(actions(row)) do
    items[#items + 1] = { text = a.text, disabled = a.disabled, checked = a.status and (a.on == true) or nil,
      tip = type(a.tip) == "string" and a.tip or (type(a.tip) == "table" and a.tip.text) or nil,
      func = function() a.func(anchor) end }
  end
  if #items > 0 then ns.Menu.Show(anchor, items) end
end

local function hover(row, on) if row.board then BC().Hover(row, on) end end

local function footer()
  local k = browser and kind(browser.node)
  if k == "trackers" then return TC().Footer() end
  return BC().Footer()
end

local EMPTY = {
  boards = "No boards yet. The Boards tab makes one: New board... A new board stays in this window until you put it on your HUD.",
  tiles = "No tiles yet: add one from Readings, a board's + Tile, or a ready-made board.",
}

local function build(f)
  content = f
  browser = ns.Browser.New(f, {
    columns = columns, nodes = nodes, rows = rows, detail = detail, actions = actions, footer = footer,
    rowMenu = rowMenu, hover = hover, splitKey = ID,
    -- (0.5.0) the tree folds like the AH's; Boards starts open, every other head folded
    foldKey = ID, foldDefault = function(key) return key ~= "boards" end,
    nodeMenu = function(node)
      -- (0.5.0, D3) New board left the Explorer's header; a right-click on Boards still offers it
      if node.key == "boards" then
        return { { text = L["New board..."], func = function() Bo().OpenNewBoard() end,
          tip = L["Make a board: ready-made, empty, or a copy."] } }
      end
      if kind(node.key) == "trackers" then return TC().Filters() end
      return nil
    end,
    filters = function() if kind(browser.node) == "trackers" then return TC().Filters() end return { { text = L["Filters apply to Trackers"], title = true } } end,
    filtersActive = function() return TC().FiltersActive() end,
    empty = function(node, search)
      if search ~= "" then return L["Nothing matches the search."] end
      local k = kind(node)
      if EMPTY[k] then return L[EMPTY[k]] end
      if k == "trackers" then return L["No trackers here (see Filters)."] end
      return L["Nothing here."]
    end,
    noSelection = L["Click a row for its details here and what you can do with it below."],
  })
  ns.ExplorerBrowser = browser
  ns.BoardsBrowser, ns.TrackersBrowser = browser, browser       -- (their names until 0.4.0: tests and older code)
end

ns.Windows.Register(ID, {
  title = L["Explorer"], icon = "Interface\\Icons\\INV_Misc_Spyglass_03", tabOrder = 2,
  about = "Find any board, tile, reading or tracker, yours or another character's, and act on it.",
  width = 720, height = 440, minWidth = 600, minHeight = 400,
  build = build,
  onShow = function()
    if TC() then TC().ReadSizes() end
    refresh()
    if ticker then ticker:Cancel() end
    ticker = C_Timer.NewTicker(1, refresh)              -- statuses, clocks and values change while you play
  end,
  onHide = function()
    if ticker then ticker:Cancel(); ticker = nil end
    if BC() then BC().Unhover() end
    if TC() then TC().OnHide() end
    if ns.Menu then ns.Menu.Hide() end
  end,
})

--- Open the Explorer (show nil toggles), on a node when given ("trackers", "presets", "tiles", ...).
function ns.ShowExplorer(show, node)
  if node and show == nil then show = true end
  ns.Windows.Show(ID, show)
  if node and browser then
    browser.node, browser.selected, browser.listOff = node, nil, 0
    refresh()
  end
end
ns.ShowBoardsTab = function(show) ns.ShowExplorer(show, show ~= false and "boards" or nil) end   -- (older callers)
ns.AddSlash("explorer", function() ns.ShowExplorer() end, L["the Explorer tab: every board, tile, ready-made board, reading, display and tracker"])

local owner = {}
HC.RegisterCallback(owner, "HC_TRACKERS_CHANGED", function() refresh() end)

-- This tab's help and tour (UI/Help.lua): change them with the tab.
local _ = ns.Help and ns.Help.Register(ID, {
  what = "The Explorer lists everything Hard Counters can count and show, in one place: your boards and tiles, the ready-made boards, every reading, the five displays, and the trackers behind them. Pick a kind on the left, a row in the middle; its details and what you can do with it come below.",
  can = {
    "{Boards} and {Tiles}: yours, with their status, clock and value now. Below a board: {+ Tile}, {Pause} or {Start}, {Reset}, its {On HUD} switch, {Edit on screen}, and {More...}.",
    "{Ready-made boards}, under {Boards}: pick one and {New board from it...}.",
    "A + beside a kind opens it, a - folds it; a right-click on a kind offers {Open all} and {Close all}.",
    "{Readings}: every number by category, with {Add tile...}; {Displays}: number, bar, gauge, odometer, mix, and the tiles that use each.",
    "{Trackers}: what is counted, with its {Counting} switch, {History...} and its size on disk; {Not loaded} lists data of packs you no longer use.",
    "Drag the bar between the list and the details to give either more room; hover a board's row to see where it is on screen.",
  },
  effect = "A switch here is the same as on the board itself: what is {On HUD} is drawn on your screen while you play, and a tracker that is off counts nothing. A tile you add switches its tracker on, with daily history.",
  tour = {
    { title = "Kinds on the left", text = "The list on the left is by kind: {Boards}, {Tiles}, {Readings}, {Trackers}, then your other characters. A + opens a kind; click one and the columns change with it.", before = function() ns.ShowExplorer(true, "boards") end },
    { title = "A row, its details, its actions", text = "Click a row: its details fill the lower half, with switches you can click (green: on), and the buttons at the bottom act on it. Rarer actions are under {More...}; a right-click on the row lists them all." },
    { title = "Add something", text = "Under {Readings}, pick a number and {Add tile...}; under {Tiles}, {Displays} adds a tile drawn as a bar or a gauge; under {Boards}, {Ready-made boards} and {New board from it...}.", before = function() ns.ShowExplorer(true, "readings") end },
    { title = "What is counted", text = "Under {Trackers}, each tracker says whether it is {Counting}, what history it keeps and what it takes on disk. {History...} chooses how much; placing a tile turns it on for you.", before = function() ns.ShowExplorer(true, "trackers") end },
  },
})
