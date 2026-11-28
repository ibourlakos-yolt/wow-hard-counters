-- The board catalog (DESIGN §17.4, HC-68; 0.4.0): what the Explorer tab (UI/Explorer.lua) shows of boards. It was
-- the Boards tab of 0.2 to 0.3, a browser of its own; the Explorer now composes it with the tiles, readings, displays
-- and trackers. Three parts:
--   * this character's boards: Name, Status (On HUD; On HUD, hidden: naming the rule; Only here; Off screen?),
--     Tiles, Clock. Hovering a board's row shows it on screen (a board that is Only here only as a faint outline,
--     UI/Boards.lua Highlight). Actions: + Tile, Pause or Start and Reset (on its own timer), the On HUD switch,
--     Edit on screen; More...: Show now, Reset position, Save as stint, Mini mode, Rename, Duplicate, Save as preset,
--     Delete.
--   * ready-made boards ("Presets" before 0.4.0) by group: Hard Counters' own, each pack's, "Your presets".
--   * "Other characters" (HC-74: every character has its own boards): each other character's boards and 0.2's shared
--     ones, to look at and Copy to this character... (the New board dialog).
-- (0.4.0, the user) "All on HUD", "All off HUD" and "Edit all" are gone: a board is switched one at a time; editing
-- every board stays on /hc edit and the minimap button's ctrl-click.
local ADDON, ns = ...

local HC, L = ns.HC, ns.L
local format, floor = string.format, math.floor

local C = {}
ns.BoardCatalog = C

local function BM() return ns.BoardModel end
local function Bo() return ns.Boards end
local function refresh() if ns.RefreshExplorer then ns.RefreshExplorer() end end
local function refreshAll()
  if ns.RefreshBoards then ns.RefreshBoards() end
  refresh()
end

local function confirm(text, fn) if Bo() and Bo().Confirm then Bo().Confirm(text, fn) else fn() end end
local function askText(prompt, current, fn) if Bo() and Bo().AskText then Bo().AskText(prompt, current, fn) end end

local STATUS_COLOR = { shown = "|cff60ff60", faded = "|cff60ff60", off = "|cff808080", offscreen = "|cffff6060",
  tiny = "|cffff9040" }

local function matches(search, text)
  return search == "" or (type(text) == "string" and text:lower():find(search, 1, true) ~= nil)
end
C.Matches = matches

local function groupOfKey()
  local out = {}
  for _, g in ipairs(BM().PresetGroups()) do for _, k in ipairs(g.keys) do out[k] = g.title end end
  return out
end

--- A board's status in words, coloured, and why (Boards.Status).
local function statusText(b)
  local status, why = Bo().Status(b)
  return (STATUS_COLOR[why] or "|cffffd200") .. status .. "|r", why
end
ns.BoardStatusText = statusText

---------------------------------------------------------------------------
-- Tree nodes
---------------------------------------------------------------------------

function C.BoardNodes()
  return { { key = "boards", text = L["Boards"], count = #BM().Store().list } }
end

function C.PresetNodes()
  local groups, total = BM().PresetGroups(), 0
  for _, g in ipairs(groups) do total = total + #g.keys end
  local out = { { key = "presets", text = L["Ready-made boards"], count = total } }
  for _, g in ipairs(groups) do out[#out + 1] = { key = "pg:" .. g.title, text = L[g.title], count = #g.keys, indent = 1 } end
  return out
end

function C.OtherNodes()
  local out = {}
  local others, n = BM().OtherBoards(), 0
  if #others == 0 then return out end
  for _, o in ipairs(others) do n = n + #o.boards end
  out[#out + 1] = { key = "others", text = L["All of them"], count = n }
  for _, o in ipairs(others) do
    out[#out + 1] = { key = "oc:" .. tostring(o.key), text = o.shared and L[o.name] or o.name, count = #o.boards, indent = 1 }
  end
  return out
end

function C.Owns(node)
  node = tostring(node)
  return node == "boards" or node == "presets" or node == "others" or node:sub(1, 3) == "pg:" or node:sub(1, 3) == "oc:"
end

function C.Columns(node)
  if node == "boards" then
    return {
      { key = "name", title = L["Name"], sort = function(r) return r.cells.name:lower() end },
      { key = "status", title = L["Status"], width = 150 },
      { key = "tiles", title = L["Tiles"], width = 40, align = "RIGHT", sort = function(r) return tonumber(r.cells.tiles) or 0 end },
      { key = "clock", title = L["Clock"], width = 110 },
    }
  end
  local preset = node == "presets" or tostring(node):sub(1, 3) == "pg:"
  return {
    { key = "name", title = L["Name"], sort = function(r) return r.cells.name:lower() end },
    { key = "status", title = preset and L["Group"] or L["Character"], width = 150 },
    { key = "tiles", title = L["Tiles"], width = 40, align = "RIGHT", sort = function(r) return tonumber(r.cells.tiles) or 0 end },
    { key = "clock", title = "", width = 60 },
  }
end

---------------------------------------------------------------------------
-- Rows
---------------------------------------------------------------------------

--- A tile of another store, in words: its name, else its reading's title (as a preset's tiles are shown).
local function rawLabel(t, store)
  local ref = type(t) == "table" and rawget(t, "ref")
  local raw = ref and type(store.tiles) == "table" and store.tiles[ref] or t
  if type(raw) ~= "table" then return "?" end
  if raw.kind == "label" then return "[" .. (raw.text or "") .. "]" end
  if raw.kind == "splits" then return L["Splits"] end
  if type(raw.name) == "string" and raw.name ~= "" then return raw.name end
  local r = ns.readings[raw.reading]
  return r and ns.ReadingTitle(r, raw.arg, raw.calc) or tostring(raw.reading)
end

local function otherRows(node, search, out)
  for _, o in ipairs(BM().OtherBoards()) do
    if node == "others" or node == "oc:" .. tostring(o.key) then
      local who = o.shared and L[o.name] or o.name
      for i, b in ipairs(o.boards) do
        if type(b) == "table" and type(b.name) == "string" and (matches(search, b.name) or matches(search, who)) then
          out[#out + 1] = { key = "o:" .. tostring(o.key) .. ":" .. i, other = { board = b, store = o.store, who = who },
            cells = { name = b.name, status = "|cff808080" .. who .. "|r", tiles = tostring(#(b.tiles or {})),
              clock = b.mini and L["mini"] or "" } }
        end
      end
    end
  end
  return out
end

function C.Rows(node, search)
  local M, out = BM(), {}
  if node == "others" or tostring(node):sub(1, 3) == "oc:" then return otherRows(node, search, out) end
  if node == "boards" then
    for _, b in ipairs(M.Store().list) do
      if matches(search, b.name) then
        local status, why = statusText(b)
        out[#out + 1] = { key = b.id, board = b, why = why,
          cells = { name = b.name .. (b.mini and ("  |cff808080" .. L["mini"] .. "|r") or ""), status = status,
            tiles = tostring(#b.tiles), clock = (Bo().ClockText(b)) } }
      end
    end
    return out
  end
  local of = groupOfKey()
  for _, g in ipairs(M.PresetGroups()) do
    if node == "presets" or node == "pg:" .. g.title then
      for _, key in ipairs(g.keys) do
        local p = M.Preset(key)
        if p and matches(search, p.name) then
          -- (0.5.0) the Group column says the class of a class board
          local grp = p.class and L[M.ClassWord(p.class)] or L[of[key] or ""]
          out[#out + 1] = { key = "p:" .. key, preset = key, user = M.UserPreset(key) ~= nil,
            cells = { name = p.name, status = grp, tiles = tostring(#p.tiles), clock = p.mini and L["mini"] or "" } }
        end
      end
    end
  end
  return out
end

---------------------------------------------------------------------------
-- Detail
---------------------------------------------------------------------------

local RULE_WORD = { show = "shows", fade = "fades", hide = "hides" }

--- A board's On HUD switch (a status pill), for the detail pane and the action bar.
local function hudSwitch(b)
  return { text = b.shown and L["On HUD"] or L["Only here"], on = b.shown and true or false,
    func = function()
      b.shown = not b.shown
      Bo().Refresh(b.id, true)
      if b.shown then Bo().Flash(b.id) end
      refreshAll()
    end,
    tip = { title = L["On your HUD, or only here"], state = b.shown and L["Now: on your HUD (your screen while you play)"]
      or L["Now: only here, in this window"], on = b.shown,
      text = L["It counts either way; this only decides whether it is drawn on your screen."],
      click = b.shown and L["Click: keep it only here."] or L["Click: put it on your HUD."] } }
end
C.HudSwitch = hudSwitch

function C.Detail(row)
  local M = BM()
  if row.other then
    local o = row.other
    local items = { { text = L["Its tiles"], head = true } }
    for _, t in ipairs(o.board.tiles or {}) do items[#items + 1] = { text = rawLabel(t, o.store) } end
    return { title = o.board.name .. "   |cff808080" .. o.who .. "|r",
      lines = { L["Another character's board. Copy it to this character to use it here: the copy is yours to change, with its own timer."] },
      items = items }
  end
  if row.board then
    -- (0.5.0, G1) "why isn't it on my screen?" and "what is on it": where it is and its clock first, then its rules
    -- as switches (they were one sentence to decode), its look, its tiles with their sizes, what it was made from
    local b = row.board
    local show = b.show or {}
    local clock = Bo().ClockText(b)
    local lines = { clock ~= "" and format("%s \194\183 %s", row.cells.status or "", clock) or (row.cells.status or "") }
    local function setShow(k, v) b.show = b.show or {}; b.show[k] = v; Bo().Refresh(b.id); refreshAll() end
    local COMBAT_NEXT = { show = "fade", fade = "hide", hide = "show" }
    local combat = show.combat or "show"
    local items = {
      { text = L["Where"], value = row.cells.status, status = hudSwitch(b) },
      { text = L["In combat"], status = { text = L[RULE_WORD[combat]], on = combat == "show" or (combat == "fade" and "warn") or false,
        func = function() setShow("combat", COMBAT_NEXT[combat]) end,
        tip = { title = L["In combat"], state = format(L["Now: it %s"], L[RULE_WORD[combat]]), on = combat == "show",
          text = L["Shows, fades to half its opacity, or hides while you fight."], click = L["Click: the next one."] } } },
      { text = L["In instances"], status = { text = L[RULE_WORD[show.instance == "hide" and "hide" or "show"]],
        on = show.instance ~= "hide", func = function() setShow("instance", show.instance == "hide" and "show" or "hide") end,
        tip = { title = L["In instances"], text = L["Shows or hides in dungeons and raids."], click = L["Click: switch."] } } },
      { text = L["Only during a stint"], status = { text = show.runOnly and L["Yes"] or L["No"], on = show.runOnly and "warn" or false,
        func = function() setShow("runOnly", not show.runOnly) end,
        tip = { title = L["Only during a stint"], text = L["Yes: on your HUD only while a stint is open (a dungeon, or one you started)."],
          click = L["Click: switch."] } } },
      { text = L["Faded until hovered"], status = { text = show.mouseoverFade and L["Yes"] or L["No"], on = show.mouseoverFade and "warn" or false,
        func = function() setShow("mouseoverFade", not show.mouseoverFade) end,
        tip = { title = L["Faded until hovered"], text = L["Yes: at half its opacity until the mouse is over it."], click = L["Click: switch."] } } },
      { text = L["Look"], value = format("%d%% \194\183 %s %d%% \194\183 %s %d%%", floor(M.BoardAlpha(b) * 100 + 0.5),
          L[M.BG_NAME[M.BgKey(b) or ""] or "Custom"], floor(select(4, M.BoardBg(b)) * 100 + 0.5), L["scale"], floor((b.scale or 1) * 100 + 0.5)),
        button = { text = L["Change"], func = function(btn) ns.Menu.Show(btn, Bo().LookItems(b)) end,
          tip = L["Opacity, background, the numbers' colour and scale on your HUD."] } },
      { text = L["Mini mode (one line)"], status = { text = b.mini and L["Mini"] or L["Full"], on = b.mini and true or false,
        func = function() b.mini = not b.mini; Bo().Refresh(b.id, true); refreshAll() end,
        tip = { title = L["Mini mode"], state = b.mini and L["Now: one line"] or L["Now: the full board"], on = b.mini,
          text = L["Mini mode folds the board into one line on your HUD; hover it there to see it whole."],
          click = L["Click: switch."] } } },
    }
    if clock ~= "" then items[#items + 1] = { text = L["Clock"], value = clock } end
    items[#items + 1] = { text = format(L["Its tiles (%d)"], #b.tiles), head = true }
    local SW = Bo().SIZE_NAME or {}
    for _, t in ipairs(b.tiles) do
      local label = t.kind == "reading" and M.TileLabel(t, b) or (t.kind == "label" and ("[" .. (t.text or "") .. "]") or L["Splits"])
      if t.kind == "reading" then label = label .. "  |cff808080" .. L[SW[M.TileSize(t)] or ""] .. "|r" end
      local value = ""
      if t.kind == "reading" then
        local ok, _, text = pcall(M.TileValue, t, b)
        value = ok and text or "?"
      end
      local onHud = M.TileOnHud(t)
      items[#items + 1] = { text = label, value = value, grey = not onHud,
        status = t.kind == "reading" and { text = onHud and L["On HUD"] or L["Only here"], on = onHud and b.shown or (onHud and "warn") or false,
          func = function() M.SetTileOnHud(t, not onHud); Bo().Refresh(b.id, true); refreshAll() end,
          tip = { title = label, state = onHud and (b.shown and L["Now: drawn with its board"] or L["Now: will show once its board is on your HUD"])
            or L["Now: kept off the HUD (it still counts)"], on = onHud,
            click = onHud and L["Click: keep this tile off the HUD."] or L["Click: draw this tile with its board."] } } or nil }
    end
    if #b.tiles == 0 then items[#items + 1] = { text = L["(empty: + Tile below adds one)"], grey = true } end
    local p = b.preset and M.Preset(b.preset)
    if p then items[#items + 1] = { text = L["Made from"], value = p.name } end
    items[#items + 1] = { text = format(L["/hc board %s puts it on or off your HUD from the chat line."], b.name:lower()), grey = true }
    return { title = b.name .. "   " .. row.cells.status, lines = lines, items = items }
  end
  local p = M.Preset(row.preset)
  if not p then return nil end
  -- (0.5.0, G1) "what would I get?": each tile with its size and its value now where the reading is loaded
  local items = { { text = format(L["Its tiles (%d)"], #p.tiles), head = true } }
  local SW, missing = Bo().SIZE_NAME or {}, 0
  for _, t in ipairs(p.tiles) do
    local r = t.kind == "reading" and ns.readings[t.reading]
    local label = r and ns.ReadingTitle(r, t.arg, t.calc) or (t.kind == "label" and ("[" .. (t.text or "") .. "]"))
      or (t.kind == "splits" and L["Splits"]) or tostring(t.reading)
    local value
    if r then
      local ok, _, text = pcall(HC.Reading, HC, t.reading, "session", { arg = t.arg, calc = t.calc })
      value = (L[SW[t.size or "line"] or ""] or "") .. (ok and text and ("  " .. text) or "")
    elseif t.kind == "reading" then
      missing = missing + 1
      value = L["(its pack is not loaded)"]
    end
    items[#items + 1] = { text = label, grey = t.kind == "reading" and not r, value = value }
  end
  local lines = { row.user and L["One of your presets: a board saved with Save as preset."]
    or L["New board from it makes a board with these tiles, its trackers counting; numbers from a pack you don't have are left out."] }
  if p.tip then lines[#lines + 1] = L[p.tip] end
  if missing > 0 then lines[#lines + 1] = "|cff808080" .. format(L["%d of them need a pack that is not loaded."], missing) .. "|r" end
  return { title = p.name .. "   |cff808080" .. (row.cells.status or "") .. "|r", lines = lines, items = items }
end

---------------------------------------------------------------------------
-- Actions
---------------------------------------------------------------------------

local function boardActions(b)
  local M = BM()
  local editing = Bo().IsEditing(b.id)
  local acts = {
    { text = L["+ Tile"], func = function(btn) Bo().AddReadingMenu(btn, b) end,
      tip = { title = L["+ Tile"], text = L["Add a number to this board, picked by tracker. Its tracker starts counting, with history."],
        click = L["Click: the list of numbers."] } },
  }
  local st = M.BoardState(b)
  if st then
    acts[#acts + 1] = { text = st == "running" and L["Pause"] or L["Start"], func = function() Bo().ToggleTimer(b); refreshAll() end,
      tip = { title = L["The board's clock"], state = st == "running" and L["Now: running"] or L["Now: paused"], on = st == "running",
        text = L["Its tiles count over this clock: pause it for a break."], click = st == "running" and L["Click: pause."] or L["Click: start."] } }
    acts[#acts + 1] = { text = L["Reset"], func = function() Bo().Control(b, "reset"); refreshAll() end,
      tip = { title = L["Reset"], text = L["The clock and its tiles start from zero. Real play since the last start is saved as a stint first."] } }
  end
  local hud = hudSwitch(b)
  acts[#acts + 1] = { text = hud.text, status = true, on = hud.on, func = hud.func, tip = hud.tip }
  acts[#acts + 1] = { text = editing and L["Editing"] or L["Edit on screen"], status = editing and true or nil, on = editing,
    func = function() Bo().EditBoard(b.id, not editing); refresh() end,
    tip = { title = L["Edit on screen"], state = editing and L["Now: open for changes on your screen"] or nil, on = editing,
      text = L["Opens the board on your screen for changes: move it, size it, add, remove and change tiles."],
      click = editing and L["Click: done editing."] or L["Click: edit it (not in combat)."] } }
  local more = {
    { text = L["Show now"], tip = format(L["Shows it for %d seconds whatever its rules, with a flash: to find it."], Bo().SHOW_NOW),
      func = function() Bo().ShowNow(b.id); refresh() end },
    { text = L["Reset position"], tip = L["Back to the centre of the screen at its normal size."],
      func = function() Bo().ResetPosition(b); refresh() end },
    { text = L["Save as stint"], tip = L["Keep what its clock counted so far as a stint (the Stints tab)."],
      func = function() Bo().SaveBoard(b); refresh() end, disabled = not st },
    { text = L["Look"], sub = Bo().LookItems(b), func = function() end,
      tip = L["Opacity, background, the numbers' colour and scale on your HUD."] },
    { text = b.mini and L["Full board"] or L["Mini mode (one line)"], tip = L["One line on your HUD, or the whole board."],
      func = function() b.mini = not b.mini; Bo().Refresh(b.id, true); refreshAll() end },
    { text = L["Rename..."], func = function() askText(L["Board name"], b.name, function(s) Bo().Rename(b, s); refreshAll() end) end },
    { text = L["Duplicate"], tip = L["A copy with tiles of its own (the New board dialog)."],
      func = function() Bo().OpenNewBoard({ copy = b }) end },
    { text = L["Save as preset"], tip = L["Keep this board's tiles and rules as a ready-made board of yours, to make boards from."],
      func = function()
        askText(L["Preset name"], b.name, function(s)
          local key = BM().SaveAsPreset(b, s)
          if ns.Print then ns.Print(L["Saved as the preset %s (Explorer tab, Ready-made boards)."], BM().Preset(key).name) end
          refresh()
        end)
      end },
    { text = L["Delete"], tip = L["Delete the board and its tiles; your counts don't change."], func = function()
      confirm(format(L["Delete the board %s and its tiles? Your counts don't change."], b.name), function()
        BM().Delete(b.id)
        Bo().RefreshAll()
        refreshAll()
      end)
    end },
  }
  for _, a in ipairs(more) do a.more = true; acts[#acts + 1] = a end
  return acts
end
C.BoardActions = boardActions

function C.Actions(row)
  if not row then return {} end
  if row.board then return boardActions(row.board) end
  if row.other then
    local o = row.other
    return { { text = L["Copy to this character..."], tip = L["A board of this character's own with the same tiles and rules."],
      func = function() Bo().OpenNewBoard({ copy = o.board, from = o.store, who = o.who }) end } }
  end
  local key = row.preset
  local acts = { { text = L["New board from it..."], tip = L["The New board dialog, starting from this one: name it, choose whether it goes on your HUD."],
    func = function() Bo().OpenNewBoard({ preset = key }) end } }
  if row.user then
    acts[#acts + 1] = { text = L["Rename..."], tip = L["Rename this preset of yours."], func = function()
      askText(L["Preset name"], BM().Preset(key).name, function(s) BM().RenamePreset(key, s); refresh() end)
    end }
    acts[#acts + 1] = { text = L["Delete"], tip = L["Delete this preset; boards made from it stay."], func = function()
      confirm(format(L["Delete your preset %s? Boards made from it stay."], BM().Preset(key).name), function()
        BM().DeletePreset(key)
        refresh()
      end)
    end }
  end
  return acts
end

--- A board's menu (right-click on its row, a click on a board's name in the Boards tab): every action, titled.
--- after: called once an action ran.
function ns.BoardMenu(b, anchor, after)
  after = after or function() end
  local items = { { text = b.name, title = true } }
  for _, a in ipairs(boardActions(b)) do
    items[#items + 1] = { text = a.status and (a.on and "|cff60ff60" .. a.text .. "|r" or a.text) or a.text,
      tip = type(a.tip) == "string" and a.tip or (type(a.tip) == "table" and a.tip.text) or nil,
      disabled = a.disabled, sub = a.sub, func = function() a.func(anchor); after() end }
  end
  ns.Menu.Show(anchor, items)
end

function C.RowMenu(row, anchor)
  if row.board then return ns.BoardMenu(row.board, anchor) end
  local items = {}
  for _, a in ipairs(C.Actions(row)) do
    items[#items + 1] = { text = a.text, tip = type(a.tip) == "string" and a.tip or nil, func = function() a.func(anchor) end }
  end
  if #items > 0 then ns.Menu.Show(anchor, items) end
end

function C.Hover(row, on)
  if row.board and Bo() then Bo().Highlight(row.board.id, on) end
end

function C.Footer()
  local list = BM().Store().list
  local shown = 0
  for _, b in ipairs(list) do if b.shown then shown = shown + 1 end end
  return format(L["%d boards, %d on your HUD. Hover a row to see where it is on screen."], #list, shown)
end

--- Stop every hover flash (the Explorer closed).
function C.Unhover()
  for _, b in ipairs(BM().Store().list) do Bo().Highlight(b.id, false) end
end

local _ = HC
