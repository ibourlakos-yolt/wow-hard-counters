-- Boards, the model (TRACKERS_AND_BOARDS §6, HC-18): data and decisions only, no frames (UI/Boards.lua draws).
-- A board is a vertical stack of tiles the player builds; it replaces the run panel and the live number.
--
--   charSettings.boards = { list = { <board>, ... }, nextId = n, seeded = true, runBoard = true, v = 7,
--                       tiles = { [tileId] = <reading tile> }, tileOrder = { tileId, ... }, nextTile = n }
-- Since v6 (HC-67, DESIGN §17.4) every reading tile lives in the collection (`tiles`) with an `id` (v7, HC-73: the
-- Overview tab groups tiles by their board, so they carry no section any more); a board's `tiles` list holds
-- placements, { ref = tileId, size = ... } (order and size
-- are the board's), plus its label and splits rows as before. At run time a placement reads and writes through to its
-- tile (see "The tile collection" below), so everything here reads `tile.scope` as it always did.
--   board = { id, name, preset, shown, mini, pos, scale, width, wid = n (its window, HC-41),
--             scope = nil (the board's timer) | "session" | "today" | ... (HC-55), held = true (its timer paused
--             because the board left it),
--             show = { combat = "show"|"fade"|"hide", instance = "show"|"hide", runOnly = bool, mouseoverFade = bool },
--             tiles = { { kind = "reading", reading = id, scope = "run", follow = true, display = "number",
--                         size = "large", extras = { sparkline = true, vsUsual = true } }, ... } }
--
-- A scope for the board (DESIGN §16.8, HC-55): a tile with `follow` takes the board's scope and moves with it; one
-- without keeps its own. `tile.scope` is always the scope the tile reads (a following tile's is kept in step), so
-- everything that reads a tile's scope reads it as before.
--
-- Tile kinds: reading, splits (the last split against the one before), label. The control row (state, name, clock,
-- Pause, Reset) is no tile since HC-41: it is drawn by itself on a full board with a tile on the board's timer.
-- A reading tile (DESIGN §16.9, HC-51) is reading × scope × who × calc × display × size, plus target, name, extras:
--   calc     which number: "total", "perHour" (nil: the reading's default; Core/Readings.lua)
--   display  drawn as: "number", "bar" (toward a target: the reading's own or the tile's; HC-33), "gauge" (a half
--            dial of dots toward the same target; HC-33). Without a target a bar or gauge draws as a line number.
--   size     how much room: "large" (the big number), "half" (pairs up in two columns), "line" (full width, one line)
--   extras   on a large number: sparkline (the counter's last 10 minutes), vsUsual ("+18% vs your average here")
-- HC-51 draws today's footprints only: bars and gauges are lines.
local ADDON, ns = ...

local HC, U = ns.HC, ns.U
local type, ipairs, pairs, tostring = type, ipairs, pairs, tostring
local format, floor, abs = string.format, math.floor, math.abs

local M = {}
ns.BoardModel = M

--- Displays, in menu order, with the sizes each draws and the calcs it accepts (DESIGN §16.9's table).
M.DISPLAY_ORDER = { "number", "bar", "gauge", "odometer", "mix" }
-- (HC-63) odometer: rolling digit wheels for a total, for counts and distances; mix: one bar split into a part per
-- member of the reading's small enum dimension (the tile's set when it has one), with each part's share
local ODO_FORMATTERS = { number = true, distance = true }
local function smallEnum(r)
  if not (r and r.param and r.param.type == "enum") then return false end
  local c = r.counter and ns.counters[r.counter]
  for _, d in ipairs(c and c.bigDims or {}) do if d == r.param.dim then return false end end
  return true
end
M.DISPLAYS = {
  number = { sizes = { "large", "half", "line" }, calcs = { total = true, perHour = true, recent = true, trend = true } },
  bar = { sizes = { "line" }, calcs = { total = true, perHour = true }, needsTarget = true },
  gauge = { sizes = { "line" }, calcs = { total = true, perHour = true, recent = true }, needsTarget = true },
  odometer = { sizes = { "line" }, calcs = { total = true },
    fits = function(r) return r ~= nil and ODO_FORMATTERS[r.formatter or "number"] == true end },
  mix = { sizes = { "line" }, calcs = { total = true }, fits = smallEnum },
}

--- Can the tile's reading be drawn with this display? (HC-63: an odometer counts, a mix needs members.)
function M.DisplayFits(tile, display)
  local d = M.DISPLAYS[display]
  if not d then return false end
  if not d.fits then return true end
  return d.fits(ns.readings[tile.reading]) and true or false
end
M.SIZE_ORDER = { "large", "half", "line" }
M.SIZES = { large = true, half = true, line = true }
--- sparkline: the last minutes; vsUsual: "+18% vs your average here" (past runs in this zone); trend (HC-53): a badge,
--- your pace now against this period's average (on a per hour or recent tile)
M.EXTRAS = { sparkline = true, vsUsual = true, trend = true }
--- Displays drawn toward a target: choosing one for a tile without a target asks for one first (HC-33, statement 17b).
M.NEEDS_TARGET = { bar = true, gauge = true }
--- The tile look before HC-51 (`style`), as display, size and extras. Packs' presets may still say `style`.
M.STYLE_MAP = {
  hero = { display = "number", size = "large", extras = { sparkline = true, vsUsual = true } },
  grid = { display = "number", size = "half" },
  row = { display = "number", size = "line" },
  bar = { display = "bar", size = "line" },
  gauge = { display = "gauge", size = "line" },
}
M.KINDS = { reading = true, splits = true, label = true }
local optsBuf = {}          -- HC:Reading's options, reused (M.TileValue runs at every redraw)
M.WIDTH = 260
M.MIN_WIDTH, M.MAX_WIDTH = 160, 600

---------------------------------------------------------------------------
-- The tile collection (DESIGN §17.4, HC-67). Every reading tile lives in charSettings.boards.tiles; a board holds
-- placements, { ref = <tile id>, size = <size> }. The user's rule (2026-11-23): "all of the tiles will be present
-- there and some of them will also be in the HUD": a tile is shared, never copied (copies drift apart), so edited
-- anywhere it shows the same on its board. A tile is on one board at most ("On HUD: <board>"); on none it is
-- "Window only". A placement reads every field but `size` from its tile and writes them there (a metatable, attached
-- at load and never saved). Labels and splits rows are layout, not numbers: they stay on their board as before.
---------------------------------------------------------------------------

local PLACEMENT = {}
local function liveTile(p)
  local B = ns.charSettings and ns.charSettings.boards
  local tiles = type(B) == "table" and B.tiles
  return type(tiles) == "table" and tiles[rawget(p, "ref")] or nil
end
PLACEMENT.__index = function(p, k)
  local t = liveTile(p)
  if t then return t[k] end
  return nil
end
PLACEMENT.__newindex = function(p, k, v)
  if k == "size" or k == "ref" or k == "off" then rawset(p, k, v); return end
  local t = liveTile(p)
  if t then t[k] = v else rawset(p, k, v) end
end

--- Is t a board's placement of a collection tile?
function M.IsPlacement(t) return getmetatable(t) == PLACEMENT end

--- The collection tile behind a placement, or t itself (a collection tile, a label, a splits row).
function M.TileOf(t)
  if getmetatable(t) == PLACEMENT then return liveTile(t) end
  return t
end

local function placement(id, size, off)
  return setmetatable({ ref = id, size = size, off = off and true or nil }, PLACEMENT)
end

--- Put a reading tile into the collection (its size and whether it is kept off the HUD stay with the board:
--- returned as its placement).
local function adopt(B, raw)
  B.nextTile = (B.nextTile or 0) + 1
  local id = "t" .. B.nextTile
  local size, off = raw.size, raw.off
  raw.size, raw.off, raw.id = nil, nil, id
  B.tiles[id] = raw
  B.tileOrder[#B.tileOrder + 1] = id
  return placement(id, size, off)
end

--- (v8) Is this tile drawn on its board's HUD frame? A placement with `off` stays on its board in the Overview
--- tab only ("Only here"), whether or not the board itself is on the HUD. Labels and splits rows are always drawn.
function M.TileOnHud(t) return not (type(t) == "table" and rawget(t, "off")) end

--- Put a board's tile on its HUD frame or keep it off (it stays on the board, counting, in the Overview tab).
function M.SetTileOnHud(t, on)
  if type(t) ~= "table" or getmetatable(t) ~= PLACEMENT then return false end
  rawset(t, "off", (not on) and true or nil)
  return true
end

--- What a board's HUD frame is laid out from: changes when a tile is added, removed or put on or off the HUD.
function M.LayoutKey(board)
  local n = 0
  for _, t in ipairs(board.tiles) do if rawget(t, "off") then n = n + 1 end end
  return #board.tiles * 1000 + n
end

--- Every board's reading tiles in the collection, every saved placement live again (a /reload drops the
--- metatables), placements of deleted tiles gone. Runs at each Store(): a pass over the tiles, cheap.
local function normalize(B)
  if type(B.tiles) ~= "table" then B.tiles = {} end
  if type(B.tileOrder) ~= "table" then B.tileOrder = {} end
  for _, b in ipairs(B.list) do
    if type(b) == "table" and type(b.tiles) == "table" then
      local i = 1
      while i <= #b.tiles do
        local t = b.tiles[i]
        local ref = type(t) == "table" and rawget(t, "ref") or nil
        if type(t) ~= "table" or (ref ~= nil and B.tiles[ref] == nil) then
          table.remove(b.tiles, i)                    -- its tile was deleted
        else
          if ref ~= nil then
            if getmetatable(t) ~= PLACEMENT then setmetatable(t, PLACEMENT) end
          elseif t.kind == "reading" then
            b.tiles[i] = adopt(B, t)
          end
          i = i + 1
        end
      end
    end
  end
end

---------------------------------------------------------------------------
-- Settings
---------------------------------------------------------------------------

-- Each character has its own boards (HC-74, the user 2026-11-24): `boards` lives in the character's settings
-- (AceDB's char namespace, ns.charSettings), no longer in the profile every character shared. 0.2's shared boards stay
-- in the profile, read only: a character that ran Hard Counters before (ns.knownCharacter) gets a copy of them at its
-- first load on this build, timers and all; a new character gets the Leveling board (M.Seed) and can copy any other
-- character's board, or those shared ones, from the New board dialog.

--- The shared boards of 0.2 (the profile's), or nil.
function M.SharedBoards()
  local legacy = ns.settings and ns.settings.boards
  if type(legacy) == "table" and type(legacy.list) == "table" then return legacy end
  return nil
end

local function firstStore()
  local legacy = M.SharedBoards()
  if legacy and ns.knownCharacter then
    local c = U.deepcopy(legacy)       -- (no metatables: placements are plain { ref, size } again)
    c.presets = nil                    -- your presets stay the account's (M.UserPresets)
    c.fromShared = true
    return c
  end
  return {}
end

function M.Store()
  if type(ns.charSettings) ~= "table" then ns.charSettings = {} end
  local s = ns.charSettings
  if type(s.boards) ~= "table" then s.boards = firstStore() end
  local B = s.boards
  if type(B.list) ~= "table" then B.list = {} end
  B.nextId = B.nextId or 1
  if (B.v or 1) < 2 then
    -- HC-41, per profile at its first use: tiles own no window any more (tile.wid goes; Migrations.lua drops the
    -- windows themselves) and the control row draws itself (tiles of kind "run" go). Every board starts its
    -- window from zero (user, 2026-11-18).
    for _, b in ipairs(B.list) do
      if type(b) == "table" and type(b.tiles) == "table" then
        for i = #b.tiles, 1, -1 do
          local t = b.tiles[i]
          if type(t) ~= "table" or t.kind == "run" then table.remove(b.tiles, i) else t.wid = nil end
        end
      end
    end
    B.v = 2
  end
  if B.v < 3 then
    -- HC-51 (DESIGN §16.9), per profile at its first use: `style` splits into display, size and extras, and tiles on
    -- the per-hour twins read their reading with the perHour calc. Values don't change.
    for _, b in ipairs(B.list) do
      if type(b) == "table" and type(b.tiles) == "table" then
        for _, t in ipairs(b.tiles) do
          if type(t) == "table" and t.kind == "reading" then M.ApplyStyle(t, t.style); M.FoldAlias(t) end
        end
      end
    end
    B.v = 3
  end
  if B.v < 4 then
    -- HC-49 (user, 2026-11-19): the "login" scope is "session" in the code too, with no alias
    for _, b in ipairs(B.list) do
      if type(b) == "table" and type(b.tiles) == "table" then
        for _, t in ipairs(b.tiles) do
          if type(t) == "table" and t.scope == "login" then t.scope = "session" end
        end
      end
    end
    B.v = 4
  end
  if B.v < 5 then
    -- HC-55 (user, 2026-11-20): boards have a scope, the board's timer for every board saved before; tiles on the
    -- board's timer follow the board, tiles on another scope keep theirs. Values don't change.
    for _, b in ipairs(B.list) do
      if type(b) == "table" and type(b.tiles) == "table" then
        for _, t in ipairs(b.tiles) do
          if type(t) == "table" and t.kind == "reading" and t.scope == "run" then t.follow = true end
        end
      end
    end
    B.v = 5
  end
  -- v6 (HC-67, user 2026-11-23): every board's reading tiles move into the collection, in board order; the board
  -- keeps placements (order and size). Settings only, no storage change; the values and the look don't change.
  -- normalize() does it, and keeps doing it for tiles added the old way.
  normalize(B)
  if B.v < 6 then B.v = 6 end
  if B.v < 7 then
    -- HC-73 (user, 2026-11-23): the Overview tab groups tiles by their board, Window only last; the free sections
    -- of v6 (a name on each tile, the list of names) go. Nothing on screen changes but the Overview tab.
    for _, t in pairs(B.tiles) do if type(t) == "table" then t.section = nil end end
    B.sections = nil
    B.v = 7
  end
  if B.v < 8 then
    -- v8 (the user, 2026-11-25): no tile without a board. Until now a tile taken off its board, or left behind by a
    -- deleted board, stayed in the Overview tab under "Window only"; nothing said how it got there. Those tiles move
    -- to a board of their own, "Unsorted", which is not on the HUD (as they were not); from there they can be moved,
    -- shown or deleted like any other. From v8 a board is on the HUD or "Only here", and so is each of its tiles
    -- (placement.off). The ready-made board "Run" is called "Farming".
    local placed = {}
    for _, b in ipairs(B.list) do
      for _, p in ipairs(b.tiles or {}) do
        local ref = type(p) == "table" and rawget(p, "ref")
        if ref then placed[ref] = true end
      end
      if b.preset == "run" and b.name == "Run" then
        local free = true
        for _, o in ipairs(B.list) do if o ~= b and (o.name or ""):lower() == "farming" then free = false end end
        if free then b.name = "Farming" end
      end
    end
    local loose = {}
    for _, id in ipairs(B.tileOrder) do if B.tiles[id] and not placed[id] then loose[#loose + 1] = id; placed[id] = true end end
    local strays = {}
    for id in pairs(B.tiles) do if not placed[id] then strays[#strays + 1] = id end end
    table.sort(strays)
    for _, id in ipairs(strays) do loose[#loose + 1] = id end
    if #loose > 0 then
      local name, n = "Unsorted", 1
      local function taken(x)
        for _, o in ipairs(B.list) do if (o.name or ""):lower() == x:lower() then return true end end
        return false
      end
      while taken(name) do n = n + 1; name = "Unsorted " .. n end
      local b = { id = "b" .. B.nextId, name = name, shown = false, mini = false, width = M.WIDTH, scale = 1,
        show = { combat = "show", instance = "show", runOnly = false, mouseoverFade = false }, scope = "session",
        tiles = {} }
      B.nextId = B.nextId + 1
      for _, id in ipairs(loose) do
        local t = B.tiles[id]
        b.tiles[#b.tiles + 1] = placement(id, t.lastSize)
        t.lastSize = nil
        if t.scope == "session" then t.follow = true end
      end
      B.list[#B.list + 1] = b
      B.unsorted = b.id                 -- (the Overview tab explains this board once)
    end
    B.v = 8
  end
  return B
end

--- Set a tile's display, size and extras from a `style` of before HC-51 (unknown or nil: a line number); the
--- `style` field goes.
function M.ApplyStyle(t, style)
  local m = M.STYLE_MAP[style] or M.STYLE_MAP.row
  t.style = nil
  t.display = t.display or m.display
  t.size = t.size or m.size
  if m.extras and t.extras == nil then t.extras = U.copy(m.extras) end
  return t
end

-- Hard Counters' own per-hour twins (DESIGN §16.9): known before Basics registers, so the migration needn't wait.
local TWINS = { ["hc:goldph"] = "hc:gold", ["hc:netph"] = "hc:net", ["hc:xpph"] = "hc:xpgained" }

--- A tile on an alias ("hc:goldph") reads its target with the alias's calc instead ("hc:gold", perHour). The
--- tile's own calc, if it has one, stays. Returns true when it changed.
function M.FoldAlias(t)
  if type(t) ~= "table" or t.kind ~= "reading" then return false end
  local r = ns.readings[t.reading]
  if r and r.foldInto and ns.readings[r.foldInto] then
    -- (2026-11-24) a reading merged into another: "Gold from Loot" is "Gold in" with the set { loot }, "Linen Cloth
    -- looted" is "Items looted" with the item. The tile's calc, display, size and name stay.
    t.reading = r.foldInto
    if r.foldArg == "set" then
      if t.arg ~= nil and type(t.arg) ~= "table" then t.arg = { t.arg } end
    elseif r.foldArg ~= "same" then
      t.arg = nil
    end
    return true
  end
  local target, calc
  if r and r.aliasOf then target, calc = r.aliasOf, r.defaultCalc
  elseif TWINS[t.reading] then target, calc = TWINS[t.reading], "perHour" end
  if not target then return false end
  t.reading = target
  if t.calc == nil then t.calc = calc end
  return true
end

--- Fold every saved tile on an alias (packs register theirs after the boards are read: FM-17's
--- hcfarm:vendorph). Cheap: a pass over the tiles.
function M.FoldAliases()
  local n = 0
  for _, t in pairs(M.Store().tiles) do           -- (v6: every reading tile is in the collection)
    if M.FoldAlias(t) then n = n + 1 end
  end
  return n
end

function M.Get(id)
  for _, b in ipairs(M.Store().list) do if b.id == id then return b end end
  return nil
end

local function newId()
  local B = M.Store()
  local id = "b" .. B.nextId
  B.nextId = B.nextId + 1
  return id
end

local function defaultShow()
  return { combat = "show", instance = "show", runOnly = false, mouseoverFade = false }
end

--- Does any tile read the board's timer (scope "run")? Then the board has a clock: the control row on a full board,
--- the dot and clock on the strip.
function M.UsesTimer(board)
  for _, t in ipairs(board.tiles) do if t.kind == "reading" and t.scope == "run" then return true end end
  return false
end

--- The board a tile is on, and its index there (a scan: callers that know it pass it). tile: a placement, a label or
--- splits row, or a collection tile (then the board that places it, if any).
function M.BoardOf(tile)
  local id = type(tile) == "table" and getmetatable(tile) ~= PLACEMENT and tile.kind == "reading" and rawget(tile, "id")
  for _, b in ipairs(M.Store().list) do
    for i, t in ipairs(b.tiles) do
      if t == tile or (id and rawget(t, "ref") == id) then return b, i end
    end
  end
  return nil
end

--- The scopes a board can have (HC-55): the tiles' own list, without `now` ("these scopes exist horizontally").
M.BOARD_SCOPES = { "run", "session", "today", "week", "month", "year", "lifetime" }
local BOARD_SCOPE_SET = {}
for _, s in ipairs(M.BOARD_SCOPES) do BOARD_SCOPE_SET[s] = true end

--- The board's scope: "run" (the board's timer, the default) or the one the player chose.
function M.BoardScope(board)
  local s = board and board.scope
  return BOARD_SCOPE_SET[s] and s or "run"
end

--- Default scope of a new tile (DESIGN §16.8, HC-55): the board's scope when the reading has it; else, on the board's
--- timer, session, else the reading's first; off the timer never the timer (it would have no Pause), so session,
--- else the reading's first other scope. board may be nil (the board's timer).
function M.DefaultScope(board, readingId)
  local r = ns.readings[readingId]
  if not r then return "session" end
  local bs = M.BoardScope(board)
  if r.scopeSet[bs] then return bs end
  if r.scopeSet.session then return "session" end
  if bs ~= "run" then
    for _, s in ipairs(r.scopes) do if s ~= "run" then return s end end
  end
  return r.scopes[1]
end

--- Put a following tile on its board's scope, or, when its reading hasn't that scope, on the nearest it has (it keeps
--- following, so it comes back when the board does; its label then names its own scope). Returns true when the
--- tile's scope changed.
local function follow(tile, board)
  if tile.kind ~= "reading" or not tile.follow or not ns.readings[tile.reading] then return false end
  local r = ns.readings[tile.reading]
  local bs = M.BoardScope(board)
  local s = tile.scope
  if r.scopeSet[bs] then s = bs
  elseif s == "run" or not r.scopeSet[s] then s = M.DefaultScope(board, tile.reading) end
  if s == tile.scope then return false end
  tile.scope = s
  M.FitCalc(tile)
  return true
end

---------------------------------------------------------------------------
-- The board is the clock (DESIGN §16.8, HC-41): a board has one window per character, "b<wid>@<character>" in
-- HardCountersDB.windows (Core/Odometer.lua), made the first time a tile needs it. It watches every counter, with the
-- per-member totals of small dimensions, so a tile moved between boards shows its new board's whole period at once.
-- A board with a tile for the whole account (HC-32) also has "b<wid>@account"; both start, pause and reset
-- together, and the clock shows the character's. Tiles with the "run" scope ("the board's timer") read it.
---------------------------------------------------------------------------

local Win = ns.Win
local keyOf = {}

local function winKey(wid)
  local k = keyOf[wid]
  if not k then k = "b" .. wid; keyOf[wid] = k end
  return k
end

--- The big-dimension members the board's tiles show, for one of its windows: { [counter] = { [dim] = { [m] = true } } }
--- (account = true: the account-wide tiles; else the character's). Nil when there are none.
local function watchOf(board, account)
  local out
  for _, t in ipairs(board.tiles) do
    local r = t.kind == "reading" and t.scope == "run" and t.arg ~= nil and ns.readings[t.reading]
    if r and r.param and not r.param.multi and ((t.who == "account") == (account and true or false)) then
      for _, id in ipairs({ r.counter or false, r.minus or false }) do
        local c = id and ns.counters[id]
        for _, d in ipairs(c and c.bigDims or {}) do
          if d == r.param.dim then
            out = out or {}
            out[id] = out[id] or {}
            out[id][d] = out[id][d] or {}
            out[id][d][t.arg] = true
          end
        end
      end
    end
  end
  return out
end

local function existing(board, account)
  return board.wid and ns.SavedWindows.Get(winKey(board.wid), nil, account) or nil
end

--- The board's window on this character (account = true: the account's), made and started when missing.
function M.BoardWindow(board, account)
  if not (ns.SV and ns.guid) then return nil end
  if not board.wid then
    -- numbered in the saved data, not in the profile: profiles share HardCountersDB.windows
    local SV = ns.SV
    SV.windowSeq = (SV.windowSeq or 0) + 1
    board.wid = SV.windowSeq
  end
  local w, made = ns.SavedWindows.Get(winKey(board.wid), function()
    return { board = true, watch = watchOf(board, account) }
  end, account)
  if made and account then
    -- the account window keeps step with the character's: paused or stopped when that one is
    local cw = existing(board, false)
    if cw and cw.state == "paused" then Win.Pause(w) elseif cw and cw.state == "stopped" then Win.Stop(w) end
  end
  return w
end

--- The board's windows on this character: its own, then the account's when one of its tiles counts the account.
function M.BoardWindows(board, out)
  out = out or {}
  if not M.UsesTimer(board) then return out end
  local w = M.BoardWindow(board)
  if w then out[#out + 1] = w end
  local aw = existing(board, true)
  if not aw then
    for _, t in ipairs(board.tiles) do
      if t.kind == "reading" and t.scope == "run" and t.who == "account" then aw = M.BoardWindow(board, true); break end
    end
  end
  if aw then out[#out + 1] = aw end
  return out
end

--- Keep what the board's tiles show (big-dimension members) on this character from now on, in both windows'
--- lists, so a later base (a login, an account window on another character) has them. A member kept for the first
--- time is "late" on windows whose period began earlier (Odometer.lua): the tile says since when.
local function watchTiles(board)
  if not (ns.ready and board.wid) then return end
  for _, account in ipairs({ false, true }) do
    local w = existing(board, account)
    if w then
      w.watch = watchOf(board, account)
      for id, dims in pairs(w.watch or {}) do
        for dim, keys in pairs(dims) do
          for key in pairs(keys) do ns.WatchMember(id, dim, key) end
        end
      end
    end
  end
end

--- The window a tile reads: its board's (the account's for an account tile), or nil (another scope, or its pack
--- isn't loaded). board: the tile's board when the caller knows it.
function M.TileWindow(tile, board)
  if tile.kind ~= "reading" or tile.scope ~= "run" or not ns.readings[tile.reading] then return nil end
  board = board or M.BoardOf(tile)
  if not board then return nil end
  return M.BoardWindow(board, tile.who == "account")
end

local function worthARecord(w)
  return Win.Active(w) >= ns.RECORD_MIN_ACTIVE
end

--- "start" | "pause" | "stop" | "reset" on one window. A reset or a new start after a stop keeps the period it
--- ends as w.prev when it had real play in it, so "Save as run" can still be chosen afterwards (never a prompt).
function M.Control(w, action)
  if not w then return false end
  if action == "pause" then return Win.Pause(w) end
  if action == "stop" then return Win.Stop(w) end
  if action == "start" then
    if w.state == "running" then return false end
    if w.state == "paused" then Win.Resume(w); return true end
    if worthARecord(w) then w.prev = Win.Snapshot(w) end
    Win.Restart(w)
    return true
  end
  if action == "reset" then
    if worthARecord(w) then w.prev = Win.Snapshot(w) end
    Win.Reset(w)
    return true
  end
  return false
end

--- What "Save as run" would save for a window: "now" (its current period has 5 active minutes), "prev" (the one a
--- start after a stop ended), or nil.
function M.Savable(w)
  if not w then return nil end
  if worthARecord(w) then return "now" end
  if w.prev then return "prev" end
  return nil
end

--- Is the board on its own timer with a tile reading it? Only then has it Pause, Reset and Save as run (HC-55: on
--- another scope they are hidden, not greyed).
function M.OnTimer(board)
  return M.BoardScope(board) == "run" and M.UsesTimer(board)
end

--- The board's state and clock for its control row and strip: its window's "running", "paused" or "stopped" and
--- active seconds (the character's window); nil when the board isn't on its timer or no tile reads it.
function M.BoardState(board)
  if not M.OnTimer(board) then return nil, 0 end
  local w = M.BoardWindow(board)
  if not w then return nil, 0 end
  return w.state, Win.Active(w)
end

--- The clock a board shows (HC-55): "timer", state, active seconds on its own timer; "session", the session's state,
--- its active seconds on the session scope (time played since login); nil on a calendar scope (no clock).
function M.BoardClock(board)
  local bs = M.BoardScope(board)
  if bs == "run" then
    local st, active = M.BoardState(board)
    if st then return "timer", st, active end
    return nil
  end
  if bs == "session" then
    local s = ns.Session and ns.Session()
    if s then return "session", s.state, Win.Active(s) end
  end
  return nil
end

--- Does the full board draw its header row? On its timer when a tile reads it (the control row, HC-41); on another
--- scope when any reading tile is on it (the scope shown once: "Leveling · session").
function M.HasHeader(board)
  local bs = M.BoardScope(board)
  if bs == "run" then return M.UsesTimer(board) end
  for _, t in ipairs(board.tiles) do if t.kind == "reading" and t.scope == bs then return true end end
  return false
end

--- Set the board's scope ("run" is its timer): every following tile moves with it. Leaving the timer pauses it (it
--- would count with nothing to show it); coming back resumes it if leaving paused it. Returns true when it changed.
function M.SetBoardScope(board, scope)
  if not BOARD_SCOPE_SET[scope] then return false end
  local old = M.BoardScope(board)
  if old == scope then return false end
  if old == "run" and M.UsesTimer(board) and M.BoardState(board) == "running" then
    for _, w in ipairs(M.BoardWindows(board)) do Win.Pause(w) end
    board.held = true
  end
  board.scope = scope ~= "run" and scope or nil
  for _, t in ipairs(board.tiles) do follow(t, board) end
  if scope == "run" and board.held then
    board.held = nil
    for _, w in ipairs(M.BoardWindows(board)) do if w.state == "paused" then Win.Resume(w) end end
  end
  if ns.ready and scope == "run" then watchTiles(board) end
  return true
end

--- What "Save as run" on the board would save ("now", "prev" or nil).
function M.BoardSavable(board)
  if not M.OnTimer(board) then return nil end
  return M.Savable(M.BoardWindow(board))
end

--- One record for the board: its window's period (every counter: not partial), named after the board. nowOnly:
--- not the previous period. Returns the record id.
function M.SaveBoard(board, nowOnly)
  if not M.OnTimer(board) then return nil end
  local w = M.BoardWindow(board)
  local which = M.Savable(w)
  if not which or (nowOnly and which ~= "now") then return nil end
  local snap = which == "now" and Win.Snapshot(w) or w.prev
  local id = ns.SaveWindowRecord(snap, board.name)
  if id and which == "prev" then w.prev = nil end
  return id
end

--- "start" | "pause" | "stop" | "reset" on the board's timer (both windows when it has an account one). "reset"
--- saves one record first when there was real play, then starts from zero, running. Returns the record id, if one
--- was saved.
function M.ControlAll(board, action)
  if not M.OnTimer(board) then return nil end
  local list = M.BoardWindows(board)
  if #list == 0 then return nil end
  if action == "reset" then
    local saved = M.SaveBoard(board, true)
    for _, w in ipairs(list) do w.prev = nil; Win.Restart(w) end
    return saved
  end
  for _, w in ipairs(list) do M.Control(w, action) end
  return nil
end

--- The time a tile's member started being counted on its window, when that was after the period began (a big
--- dimension's member nothing watched before, DESIGN §16.8); nil when the tile's number covers the whole period.
function M.LateSince(tile, board)
  local r = tile.kind == "reading" and tile.arg ~= nil and ns.readings[tile.reading]
  if not (r and r.param) or r.param.multi then return nil end
  local w = M.TileWindow(tile, board)
  local late = w and w.late
  if not late then return nil end
  local t
  for _, id in ipairs({ r.counter or false, r.minus or false }) do
    local x = id and late[id] and late[id][tile.arg]
    if x and (not t or x > t) then t = x end
  end
  return t
end

---------------------------------------------------------------------------
-- Presets (§6.4). Tiles whose reading isn't registered (a pack not installed) are left out when the preset is made.
-- Their tiles are on the board's timer, except `now` (HC-41, user 2026-11-18): the strip's dot pauses them.
---------------------------------------------------------------------------

--- A reading tile: display "number" unless given; size "line" unless given. A large number gets the sparkline and the
--- "vs your average here" line.
local function reading(id, scope, size, calc, display)
  local t = { kind = "reading", reading = id, scope = scope, calc = calc, display = display or "number", size = size or "line" }
  if t.size == "large" and t.display == "number" then t.extras = { sparkline = true, vsUsual = true } end
  return t
end

local PH = "perHour"
M.PRESETS = {
  -- (2026-11-25) "Farming": it was called "Run", a word that already means a saved stretch of play (the Runs tab);
  -- its key stays "run" (saved boards name it, /hc panel)
  run = { name = "Farming", mini = false, category = "activity", pack = "hc", tiles = {
    reading("hc:gold", "run", "large", PH),
    reading("hc:xpgained", "run", "half", PH), reading("hc:net", "run", "half", PH),
    reading("hc:gold", "run", "half"), reading("hcfarm:items", "run", "half"),
    reading("hcfarm:vendorph", "run", "half"), reading("hc:ttl", "run", "half"),
    { kind = "splits" },
    reading("hcfarm:best", "run", "line"),
  } },
  pocket = { name = "Pocket", mini = true, category = "activity", pack = "hc", tiles = {
    reading("hc:gold", "run", "large", PH),
    reading("hc:xpgained", "run", "half", PH), reading("hc:net", "run", "half", PH),
  } },
  leveling = { name = "Leveling", mini = false, category = "activity", pack = "hc", tiles = {
    reading("hc:xpgained", "run", "large", PH), reading("hc:xplevel", "now", "line", nil, "bar"),
    reading("hc:ttl", "run", "half"), reading("hc:rested", "now", "half"),
    reading("hc:xpgained", "run", "half"), reading("hc:gold", "run", "half", PH),
  } },
}
M.PRESET_ORDER = { "run", "pocket", "leveling" }

--- A pack's board preset (Character Stats' Caster, Melee, ...): `key` is namespaced like any id ("hcstats:caster");
--- def = { name, mini (bool), tiles = { { reading = id, scope = "now"|"run"|..., display = "number"|"bar"|"gauge",
--- size = "large"|"half"|"line", calc = "total"|"perHour", arg }, ... } }. A tile's `style` (before HC-51: hero, grid,
--- row, bar, gauge) is still read, through M.STYLE_MAP. A large number gets the sparkline and "vs your average here".
--- It is offered under New board after Hard Counters' own; tiles whose reading isn't registered are left out when
--- a board is made. Registering the same key again replaces it.
function HC:RegisterBoardPreset(key, def)
  if not U.validId(key) then error("HardCounters: RegisterBoardPreset: key must be \"namespace:name\", got " .. tostring(key), 2) end
  if type(def) ~= "table" or type(def.tiles) ~= "table" or #def.tiles == 0 then
    error("HardCounters: RegisterBoardPreset('" .. key .. "'): def.tiles must list its tiles", 2)
  end
  local tiles = {}
  for i, t in ipairs(def.tiles) do
    if type(t) ~= "table" or type(t.reading) ~= "string" then
      error("HardCounters: RegisterBoardPreset('" .. key .. "'): tile " .. i .. " needs a reading id", 2)
    end
    local function bad(what) error("HardCounters: RegisterBoardPreset('" .. key .. "'): tile " .. i .. " has an unknown " .. what, 3) end
    if t.style ~= nil and not M.STYLE_MAP[t.style] then bad("style") end
    if t.display ~= nil and not M.DISPLAYS[t.display] then bad("display") end
    if t.size ~= nil and not M.SIZES[t.size] then bad("size") end
    if t.calc ~= nil and not ns.CALCS[t.calc] then bad("calc") end
    if t.scope ~= nil and not ns.SCOPES[t.scope] then bad("scope") end
    local tile
    if t.style ~= nil and t.display == nil and t.size == nil then
      tile = M.ApplyStyle({ kind = "reading", reading = t.reading, scope = t.scope or "run", calc = t.calc }, t.style)
    else
      tile = reading(t.reading, t.scope or "run", t.size, t.calc, t.display)
    end
    if type(t.extras) == "table" then
      -- a list ({ "sparkline" }) or a set ({ sparkline = true }); unknown extras are dropped
      local ex = {}
      for k, v in pairs(t.extras) do
        local name = type(k) == "number" and v or (v and k)
        if M.EXTRAS[name] then ex[name] = true end
      end
      tile.extras = ex
    end
    tile.arg = type(t.arg) == "table" and ns.NormalizeSet(t.arg) or t.arg   -- (HC-60: a set, the pack's own copy)
    tiles[i] = tile
  end
  if def.category ~= nil and not M.CATEGORY_TITLE[def.category] then
    error("HardCounters: RegisterBoardPreset('" .. key .. "'): category must be activity, role or class", 2)
  end
  if def.class ~= nil and (type(def.class) ~= "string" or def.category ~= "class") then
    error("HardCounters: RegisterBoardPreset('" .. key .. "'): class (\"MAGE\", ...) goes with category = \"class\"", 2)
  end
  if def.category == "class" and def.class == nil then
    error("HardCounters: RegisterBoardPreset('" .. key .. "'): a class board names its class (\"MAGE\", ...)", 2)
  end
  if def.tip ~= nil and type(def.tip) ~= "string" then error("HardCounters: RegisterBoardPreset('" .. key .. "'): tip must be a string", 2) end
  if not M.PRESETS[key] then M.PRESET_ORDER[#M.PRESET_ORDER + 1] = key end
  M.PRESETS[key] = { name = type(def.name) == "string" and def.name:sub(1, 32) or key, mini = def.mini and true or false,
    tiles = tiles, pack = U.namespace(key), category = def.category, class = def.class, tip = def.tip }
  return key
end

--- (HC-57 a, 2026-11-24) The categories of presets Hard Counters owns, in menu order. A preset without one is
--- listed under its pack's title.
M.CATEGORY_ORDER = { "activity", "role", "class" }
M.CATEGORY_TITLE = { activity = "Activity", role = "Roles", class = "Classes" }

--- The character's class file name ("MAGE"), or nil.
function M.PlayerClass()
  return ns.wow and ns.wow.playerClass and ns.wow.playerClass() or nil
end

---------------------------------------------------------------------------
-- Names (HC-68, DESIGN §17.4): a board's name is required, at most 24 letters, and unique ignoring case, so
-- `/hc board <name>` is never ambiguous. A taken name suggests "<name> 2".
---------------------------------------------------------------------------

M.NAME_MAX = 24

--- Is the name used by a board other than `except`? (ignoring case and surrounding spaces)
function M.NameTaken(name, except)
  local n = (name or ""):match("^%s*(.-)%s*$"):lower()
  for _, b in ipairs(M.Store().list) do
    if b ~= except and (b.name or ""):lower() == n then return true end
  end
  return false
end

--- The name itself when free, else "<name> 2", "<name> 3", ... (cut so it stays within M.NAME_MAX).
function M.FreeName(base, except)
  base = ((base or ""):match("^%s*(.-)%s*$") or ""):sub(1, M.NAME_MAX)
  if base == "" then base = "Board" end
  if not M.NameTaken(base, except) then return base end
  for i = 2, 999 do
    local suffix = " " .. i
    local n = base:sub(1, M.NAME_MAX - #suffix) .. suffix
    if not M.NameTaken(n, except) then return n end
  end
  return base
end

--- Can a board (`board`, or a new one) take this name? true, or false and why: "empty", "long", "taken".
function M.CheckName(name, board)
  local n = (name or ""):match("^%s*(.-)%s*$")
  if n == "" then return false, "empty" end
  if #n > M.NAME_MAX then return false, "long" end
  if M.NameTaken(n, board) then return false, "taken" end
  return true
end

--- Rename a board under the same rules. Returns true, or false and why.
function M.Rename(board, name)
  local ok, why = M.CheckName(name, board)
  if not ok then return false, why end
  board.name = name:match("^%s*(.-)%s*$")
  return true
end

---------------------------------------------------------------------------
-- Presets of the player's own (HC-22, HC-68): a board saved as a preset, the same data a board's tiles are, kept in
-- settings.boardPresets = { list = { { key = "user:3", name, mini, scope, show, tiles } }, next = n }: the profile's,
-- so every character has them (HC-74; 0.2 kept them in the shared boards, `boards.presets`, moved here once).
---------------------------------------------------------------------------

local function userPresets()
  local s = ns.settings
  if type(s.boardPresets) ~= "table" then
    local legacy = M.SharedBoards()
    s.boardPresets = legacy and type(legacy.presets) == "table" and legacy.presets or { list = {}, next = 1 }
    if legacy then legacy.presets = nil end
  end
  if type(s.boardPresets.list) ~= "table" then s.boardPresets.list = {} end
  s.boardPresets.next = s.boardPresets.next or (#s.boardPresets.list + 1)
  return s.boardPresets
end

--- The player's presets, in order (their entries: change them through the calls below).
function M.UserPresets() return userPresets().list end

local function userPreset(key)
  for _, p in ipairs(userPresets().list) do if p.key == key then return p end end
  return nil
end
M.UserPreset = userPreset

--- A preset by key: Hard Counters' or a pack's (M.PRESETS), or one of the player's.
function M.Preset(key)
  if type(key) ~= "string" then return nil end
  return M.PRESETS[key] or userPreset(key)
end

--- A board's tiles as preset data: every field of its tiles (copies), the placements' sizes, no ids. from: the board's
--- own store when it is another character's (or 0.2's shared boards), whose placements are plain { ref, size }.
local function tileSpecs(board, from)
  local out = {}
  local tiles = (from or M.Store()).tiles
  for _, t in ipairs(board.tiles) do
    local ref = type(t) == "table" and rawget(t, "ref") or nil
    local raw = ref and type(tiles) == "table" and tiles[ref] or (ref == nil and t) or nil
    if type(raw) == "table" then
      local c = U.deepcopy(raw)
      c.id, c.lastSize, c.section, c.wid = nil, nil, nil, nil
      if ref then c.size, c.off = rawget(t, "size"), rawget(t, "off") end
      -- a store older than this build (0.2's shared boards, saved by beta1): the tile shapes migrations change
      if c.kind == "reading" then
        if c.style ~= nil then M.ApplyStyle(c, c.style) end
        if c.scope == "login" then c.scope = "session" end
      end
      out[#out + 1] = c
    end
  end
  return out
end

--- Save a board as a preset of the player's. Returns its key.
function M.SaveAsPreset(board, name)
  local P = userPresets()
  local key = "user:" .. P.next
  P.next = P.next + 1
  P.list[#P.list + 1] = { key = key, name = ((name ~= nil and name ~= "") and name or board.name):sub(1, 32),
    mini = board.mini and true or false, scope = board.scope, show = U.copy(board.show or defaultShow()),
    tiles = tileSpecs(board) }
  return key
end

function M.RenamePreset(key, name)
  local p = userPreset(key)
  if not p or type(name) ~= "string" or name == "" then return false end
  p.name = name:sub(1, 32)
  return true
end

function M.DeletePreset(key)
  local list = userPresets().list
  for i, p in ipairs(list) do if p.key == key then table.remove(list, i); return true end end
  return false
end

--- The presets in groups for the Boards tab and the New board dialog (HC-57 a, 2026-11-24): by category, Activity,
--- Roles, "Your class" (this character's class board), "Other classes" (`more = true`: a submenu); then presets
--- with no category under their pack's title; then "Your presets". { { title, keys = { key, ... }, more } }; empty
--- groups left out.
function M.PresetGroups()
  local groups, byTitle = {}, {}
  local function group(title)
    if not byTitle[title] then byTitle[title] = { title = title, keys = {} }; groups[#groups + 1] = byTitle[title] end
    return byTitle[title]
  end
  local myClass = M.PlayerClass()
  -- the fixed groups first, in order (left out below when empty)
  for _, t in ipairs({ "Activity", "Roles", "Your class", "Other classes" }) do group(t) end
  byTitle["Other classes"].more = true
  for _, key in ipairs(M.PRESET_ORDER) do
    local p = M.PRESETS[key]
    local title
    if p.category == "class" then title = (myClass and p.class == myClass) and "Your class" or "Other classes"
    elseif p.category then title = p.category == "role" and "Roles" or "Activity"
    else
      title = "Hard Counters"
      if p.pack then
        title = p.pack
        for _, pk in pairs(ns.packs or {}) do if pk.namespace == p.pack then title = pk.title or pk.name end end
      end
    end
    local g = group(title)
    g.keys[#g.keys + 1] = key
  end
  for i = #groups, 1, -1 do if #groups[i].keys == 0 then byTitle[groups[i].title] = nil; table.remove(groups, i) end end
  local mine = userPresets().list
  if #mine > 0 then
    local g = group("Your presets")
    for _, p in ipairs(mine) do g.keys[#g.keys + 1] = p.key end
  end
  return groups
end

--- A new board from a preset (Hard Counters', a pack's or the player's) or empty, added to the list. Its name is
--- opts.name or the preset's, made free ("Pocket 2"). A new board is not on the HUD (v8, the user 2026-11-25: it
--- lives in the Hard Counters window until the player puts it on screen) unless opts.shown. Returns it.
function M.Create(presetKey, opts)
  local p = M.Preset(presetKey)
  opts = opts or {}
  local b = { id = newId(), name = M.FreeName(opts.name or (p and p.name) or "Board"), preset = presetKey,
    shown = opts.shown and true or false,
    mini = p and p.mini or false, width = M.WIDTH, scale = 1, show = p and p.show and U.copy(p.show) or defaultShow(),
    scope = p and p.scope or nil, tiles = {} }
  local B = M.Store()
  if p then
    for _, t in ipairs(p.tiles) do
      if t.kind ~= "reading" or ns.readings[t.reading] then
        local c = U.copy(t)
        -- (the preset's own tables stay its own: two boards made from it must not share them)
        if type(c.extras) == "table" then c.extras = U.copy(c.extras) end
        if type(c.arg) == "table" then c.arg = U.copy(c.arg) end
        M.FoldAlias(c)                                -- a pack's preset may name an alias
        if c.kind == "reading" and c.scope == "run" then c.follow = true end   -- (HC-55) all but `now` follow the board
        -- (HC-67) a reading tile goes into the collection
        if c.kind == "reading" then c = adopt(B, c) end
        b.tiles[#b.tiles + 1] = c
      end
    end
  end
  B.list[#B.list + 1] = b
  return b
end

--- Delete a board and its tiles (v8: a tile has no life without a board; move the ones worth keeping to another
--- board first, the confirmation says so).
function M.Delete(id)
  local B = M.Store()
  for i, b in ipairs(B.list) do
    if b.id == id then
      -- its windows, on every character; only this character's while another character's copy of the board (made
      -- from 0.2's shared boards, HC-74) still uses that timer number
      if b.wid then ns.SavedWindows.Drop(winKey(b.wid), M.WidElsewhere(b.wid)) end
      table.remove(B.list, i)
      for _, p in ipairs(b.tiles) do
        if getmetatable(p) == PLACEMENT then M.DeleteTile(rawget(p, "ref")) end
      end
      return true
    end
  end
  return false
end

--- A copy of a board (HC-68: Duplicate, and the New board dialog's "Copy of a board"): its look, rules and scope,
--- and tiles of its own (new collection tiles, never shared: copies that edit together were rejected), a fresh
--- timer, placed at the centre. from: the store the board is in when it is another character's or 0.2's shared
--- boards (HC-74, M.OtherBoards). Not on the HUD unless `shown` (v8). Returns it.
function M.Duplicate(board, name, from, shown)
  local B = M.Store()
  if from == B then from = nil end
  local b = { id = newId(), name = M.FreeName(name or board.name), shown = shown and true or false, mini = board.mini and true or false,
    width = board.width or M.WIDTH, scale = 1, show = U.copy(board.show or defaultShow()), scope = board.scope, tiles = {} }
  for _, s in ipairs(tileSpecs(board, from)) do
    if s.kind == "reading" then
      if from then M.FoldAlias(s) end
      b.tiles[#b.tiles + 1] = adopt(B, s)
    else
      b.tiles[#b.tiles + 1] = s
    end
  end
  B.list[#B.list + 1] = b
  return b
end

---------------------------------------------------------------------------
-- Other characters' boards (HC-74): each character's own, and 0.2's shared ones, to copy from.
---------------------------------------------------------------------------

local function storeOk(B) return type(B) == "table" and type(B.list) == "table" and #B.list > 0 end

--- The boards this character can copy from: { { key, name (the character, or "Shared boards (0.2)"), store,
--- boards = { board, ... } } }, the other characters by name, then 0.2's shared boards when there are any.
function M.OtherBoards()
  local out = {}
  for key, cs in pairs(ns.allCharSettings or {}) do
    if key ~= ns.charKey and type(cs) == "table" and storeOk(cs.boards) then
      local name = type(key) == "string" and key:match("^(.-) %- ") or tostring(key)
      out[#out + 1] = { key = key, name = name ~= "" and name or tostring(key), store = cs.boards, boards = cs.boards.list }
    end
  end
  table.sort(out, function(a, b) return tostring(a.key) < tostring(b.key) end)
  local legacy = M.SharedBoards()
  if storeOk(legacy) then
    out[#out + 1] = { key = "shared", name = "Shared boards (0.2)", shared = true, store = legacy, boards = legacy.list }
  end
  return out
end

--- Does another character's store (or 0.2's shared boards) hold a board with this window number? Copies made from
--- the shared boards keep their timer's number, so the account's window may still be someone else's.
function M.WidElsewhere(wid)
  for _, o in ipairs(M.OtherBoards()) do
    for _, b in ipairs(o.boards) do if type(b) == "table" and b.wid == wid then return true end end
  end
  return false
end

---------------------------------------------------------------------------
-- First use and migration (§6.4): a new character gets the Leveling board, in front of them, and the account's
-- one-time introduction to the Hard Counters window (HC-74, the user 2026-11-24; before, every fresh install got the
-- Pocket board); a player of the old run panel or live number gets the Run / Pocket boards seeded from those
-- settings, once.
---------------------------------------------------------------------------

M.STARTER = "leveling"
M.STARTER_POS = { "CENTER", 280, 40, "CENTER" }   -- right of the character, in sight

function M.Seed()
  local B = M.Store()
  if B.seeded then return false end
  B.seeded = true
  local s = ns.settings
  local rp, wins = s.runPanel, s.windows
  local rpw = type(wins) == "table" and wins.runPanel or nil
  -- a run panel that was used: its window state exists (UI/Windows.lua wrote it), or the old position keys do
  local usedPanel = type(rpw) == "table" or s.runPanelPos ~= nil
  if not usedPanel and not ns.knownCharacter then
    -- (v8, the user 2026-11-25) a first setup puts nothing on the HUD: the starter board is in the Hard Counters
    -- window (Overview), "Only here", until the player puts it on screen; its place is ready for when they do
    local b = M.Create(M.STARTER)
    b.pos = U.copy(M.STARTER_POS)
    B.welcome = true                    -- UI/Welcome.lua shows the introduction once per account
    return true
  end
  if usedPanel then
    local b = M.Create("run")
    B.runBoard = true
    b.shown = not (type(rpw) == "table" and rpw.shown == false) and not (type(rp) == "table" and rp.shown == false)
    b.mini = type(rp) == "table" and rp.compact and true or false
    if type(rpw) == "table" then
      b.pos = U.copy(rpw.pos)
      if type(rpw.width) == "number" then b.width = math.max(M.MIN_WIDTH, math.min(M.MAX_WIDTH, rpw.width)) end
      b.scale = rpw.scale or 1
    elseif type(s.runPanelPos) == "table" then
      b.pos = { s.runPanelPos[1], s.runPanelPos[2] or 0, s.runPanelPos[3] or 0 }
    end
    -- the old headline choice becomes the hero, when it maps onto a reading that still exists
    local hl = type(rp) == "table" and rp.headline
    local map = { ["hcfarm:goldph"] = "hc:goldph", ["hcfarm:netph"] = "hc:netph", ["hcfarm:xpph"] = "hc:xpph",
      ["hcfarm:gold"] = "hc:gold" }
    hl = hl and (map[hl] or hl)
    if hl and ns.readings[hl] and ns.readings[hl].scopeSet.run then
      for _, t in ipairs(b.tiles) do
        if t.size == "large" then
          t.reading, t.calc = hl, nil
          M.FoldAlias(t)
        end
      end
    end
  end
  local ln = s.liveNumber
  local pocket = M.Create("pocket", { shown = true })   -- (a player from before boards: as it was)
  if type(ln) == "table" and type(s.liveNumberPos) == "table" then
    pocket.pos = { s.liveNumberPos[1], s.liveNumberPos[2] or 0, s.liveNumberPos[3] or 0 }
  end
  if usedPanel then pocket.shown = type(ln) == "table" and ln.shown and true or false end
  return true
end


---------------------------------------------------------------------------
-- Tiles
---------------------------------------------------------------------------

--- Add a reading tile (the [+] button, the Trackers window): a line number unless `look` says otherwise
--- ({ display, size, calc }, or a `style` of before HC-51). Returns the tile.
function M.AddReading(board, readingId, look, scope, arg)
  if not ns.readings[readingId] then return nil end
  local t = { kind = "reading", reading = readingId, scope = scope or M.DefaultScope(board, readingId), arg = arg }
  if t.scope == M.BoardScope(board) then t.follow = true end    -- (HC-55) on the board's scope: it follows the board
  if type(look) == "table" then
    t.display, t.size, t.calc = look.display, look.size, look.calc
    M.ApplyStyle(t, nil)
  else
    M.ApplyStyle(t, look)
  end
  M.FoldAlias(t)
  local B = M.Store()
  local p = adopt(B, t)                             -- (HC-67) into the collection, placed on this board
  board.tiles[#board.tiles + 1] = p
  if ns.ready and M.TileWindow(p, board) then watchTiles(board) end   -- the board's first such tile starts its window
  return p
end

function M.AddTile(board, kind, extra)
  if not M.KINDS[kind] or kind == "reading" then return nil end
  local t = { kind = kind }
  if extra then for k, v in pairs(extra) do t[k] = v end end
  board.tiles[#board.tiles + 1] = t
  return t
end

--- Delete tile i of the board: off the board and, for a reading tile, out of the collection (v8: no tile without a
--- board; to keep one off the screen, M.SetTileOnHud). Returns the tile.
function M.RemoveTile(board, i)
  local p = board.tiles[i]
  if not p then return nil end
  table.remove(board.tiles, i)
  if getmetatable(p) ~= PLACEMENT then return p end
  local t = liveTile(p)
  M.DeleteTile(rawget(p, "ref"))
  return t
end

---------------------------------------------------------------------------
-- The collection's own calls (the Overview tab, HC-67)
---------------------------------------------------------------------------

--- Every collection tile, in order: { { id, tile (its placement when it is on a board, else the tile), board,
--- raw (the collection tile) } }.
function M.CollectionTiles()
  local B = M.Store()
  local placed = {}
  for _, b in ipairs(B.list) do
    for _, p in ipairs(b.tiles) do
      local ref = rawget(p, "ref")
      if ref then placed[ref] = { b = b, p = p } end
    end
  end
  local out, seen = {}, {}
  local function add(id)
    local t = B.tiles[id]
    if not t or seen[id] then return end
    seen[id] = true
    local pl = placed[id]
    out[#out + 1] = { id = id, tile = pl and pl.p or t, board = pl and pl.b or nil, raw = t }
  end
  for _, id in ipairs(B.tileOrder) do add(id) end
  local strays = {}
  for id in pairs(B.tiles) do if not seen[id] then strays[#strays + 1] = id end end
  table.sort(strays)
  for _, id in ipairs(strays) do
    B.tileOrder[#B.tileOrder + 1] = id
    add(id)
  end
  return out
end

--- The collection tile by id.
function M.Tile(id) return M.Store().tiles[id] end

--- Move a collection tile to a board (at the end) from the board it is on: a tile is on exactly one board. It
--- takes the board's scope when it has the same one. Returns its placement.
function M.Place(tile, board)
  local t = M.TileOf(tile)
  local id = t and rawget(t, "id")
  if not (id and board) then return nil end
  local from, i = M.BoardOf(t)
  if from == board then return board.tiles[i] end
  if from then
    local p = M.MoveTo(from, i, board)
    return p
  end
  local p = placement(id, nil)             -- (a stray: v8 leaves none, but never lose one)
  board.tiles[#board.tiles + 1] = p
  if t.scope == M.BoardScope(board) then t.follow = true end
  if ns.ready and M.TileWindow(p, board) then watchTiles(board) end
  return p
end

--- Delete a tile for good: off its board and out of the collection. Returns true when it was there.
function M.DeleteTile(id)
  if type(id) == "table" then id = rawget(M.TileOf(id) or {}, "id") end
  local B = M.Store()
  if not (id and B.tiles[id]) then return false end
  for _, b in ipairs(B.list) do
    for i = #b.tiles, 1, -1 do if rawget(b.tiles[i], "ref") == id then table.remove(b.tiles, i) end end
  end
  B.tiles[id] = nil
  for i = #B.tileOrder, 1, -1 do if B.tileOrder[i] == id then table.remove(B.tileOrder, i) end end
  return true
end

--- The Overview tab's groups (HC-73): every board in list order (the Boards tab's), each with its tiles in the
--- board's order, an empty board too; then the tiles on no board, in collection order. Entries as CollectionTiles.
--- Returns groups = { { board, entries = { ... } }, ... }, loose = { ... }.
function M.TilesByBoard()
  local all = M.CollectionTiles()
  local byId = {}
  for _, e in ipairs(all) do byId[e.id] = e end
  local groups, loose = {}, {}
  for _, b in ipairs(M.Store().list) do
    local g = { board = b, entries = {} }
    for _, p in ipairs(b.tiles) do
      local e = byId[rawget(p, "ref") or false]
      if e and e.board == b then g.entries[#g.entries + 1] = e end
    end
    groups[#groups + 1] = g
  end
  for _, e in ipairs(all) do if not e.board then loose[#loose + 1] = e end end
  return groups, loose
end

function M.MoveTile(board, i, delta)
  local j = i + delta
  local t = board.tiles
  if not t[i] or not t[j] then return false end
  t[i], t[j] = t[j], t[i]
  return true
end

--- The boards a tile of `board` can move to: every other board, in list order.
function M.MoveTargets(board)
  local out = {}
  for _, b in ipairs(M.Store().list) do if b ~= board then out[#out + 1] = b end end
  return out
end

--- Move tile i of `board` to the end of `target` (nil: a new board named after the tile, shown and running). It
--- goes with its settings and owns no window: on the board's timer it reads its new board's period (DESIGN §16.8).
--- Returns the tile and the board it is on now.
function M.MoveTo(board, i, target)
  local tile = board.tiles[i]
  if not tile or target == board then return nil end
  if not target then
    local name = tile.kind == "reading" and M.TileTitle(tile) or tile.text or "Board"
    target = M.Create(nil, { name = name:sub(1, 32), shown = board.shown })   -- on the HUD when its old board is
  end
  table.remove(board.tiles, i)
  target.tiles[#target.tiles + 1] = tile
  -- (HC-55) a following tile takes its new board's scope; one on the timer can't keep it on a board off its timer
  if tile.kind == "reading" and tile.scope == "run" and M.BoardScope(target) ~= "run" then tile.follow = true end
  follow(tile, target)
  if ns.ready and M.TileWindow(tile, target) then watchTiles(target) end
  return tile, target
end

--- Change a tile's scope ("run" is the board's timer). The board's own scope makes the tile follow the board
--- (HC-55); any other is the tile's own.
function M.SetScope(tile, scope, board)
  if tile.kind ~= "reading" then return false end
  board = board or M.BoardOf(tile)
  tile.scope = scope
  tile.follow = (board and scope == M.BoardScope(board)) or nil
  M.FitCalc(tile)
  if ns.ready and board and M.TileWindow(tile, board) then watchTiles(board) end
  return true
end

--- (2026-11-24) Show one of the reading's unit twins instead (Traveler's speed in yd/s or % of run speed): the same
--- value, other units. Everything else about the tile stays. Returns true when it changed.
function M.SetReading(tile, readingId, board)
  if tile.kind ~= "reading" or tile.reading == readingId then return false end
  local ok = false
  for _, u in ipairs(ns.ReadingUnits(ns.readings[tile.reading]) or {}) do if u.id == readingId then ok = true end end
  if not ok then return false end
  tile.reading = readingId
  M.FitCalc(tile)
  board = board or M.BoardOf(tile)
  if ns.ready and board and M.TileWindow(tile, board) then watchTiles(board) end
  return true
end

---------------------------------------------------------------------------
-- Calc, display and size (DESIGN §16.9, HC-51). The tile menu's "Show as", Display and Size.
---------------------------------------------------------------------------

--- The tile's calc: its own, else its reading's default.
function M.TileCalc(tile)
  if tile.calc then return tile.calc end
  return ns.DefaultCalc(ns.readings[tile.reading])
end

function M.TileDisplay(tile)
  if not M.DISPLAYS[tile.display] then return "number" end
  -- a display the reading no longer fits (a pack changed it, or a preset said so) draws as a number
  if M.DISPLAYS[tile.display].fits and not M.DisplayFits(tile, tile.display) then return "number" end
  return tile.display
end
function M.TileSize(tile) return M.SIZES[tile.size] and tile.size or "line" end

--- Calcs the tile can pick: { { calc, ok, why } }, in menu order. Greyed, with why: "display" (a bar takes no
--- recent), "scope" (recent needs the board's timer or the session), "account" (recent is this character's),
--- "zone" (no recent for one zone).
function M.CalcChoices(tile)
  local out = {}
  local r = ns.readings[tile.reading]
  if not r then return out end
  local accepts = M.DISPLAYS[M.TileDisplay(tile)].calcs
  for _, c in ipairs(ns.ReadingCalcs(r)) do
    local ok, why = ns.CalcFits(r, c, tile.scope, tile.who, tile.arg)
    if ok and not accepts[c] then ok, why = false, "display" end
    out[#out + 1] = { calc = c, ok = ok, why = why }
  end
  return out
end

--- A tile whose calc no longer fits (its scope, who or display changed) falls back to per hour, else to the
--- reading's default. Returns true when it changed.
function M.FitCalc(tile)
  if tile.calc == nil then return false end
  local r = ns.readings[tile.reading]
  local function fits(c)
    return ns.CalcAllowed(r, c) and ns.CalcFits(r, c, tile.scope, tile.who, tile.arg) and M.DISPLAYS[M.TileDisplay(tile)].calcs[c]
  end
  if not r or fits(tile.calc) then return false end
  tile.calc = fits("perHour") and "perHour" or nil
  return true
end

--- Sizes the tile's display draws, in menu order.
function M.SizeChoices(tile)
  return M.DISPLAYS[M.TileDisplay(tile)].sizes
end

function M.SetCalc(tile, calc)
  local r = ns.readings[tile.reading]
  if tile.kind ~= "reading" or not ns.CalcAllowed(r, calc) then return false end
  if not M.DISPLAYS[M.TileDisplay(tile)].calcs[calc] or not ns.CalcFits(r, calc, tile.scope, tile.who, tile.arg) then return false end
  tile.calc = calc
  return true
end

--- A display that doesn't draw the tile's size takes its first size; one that doesn't take the tile's calc moves it
--- to per hour (a bar takes no recent: M.FitCalc).
function M.SetDisplay(tile, display)
  local d = M.DISPLAYS[display]
  if tile.kind ~= "reading" or not d or not M.DisplayFits(tile, display) then return false end
  tile.display = display
  local fits = false
  for _, s in ipairs(d.sizes) do if s == M.TileSize(tile) then fits = true end end
  if not fits then tile.size = d.sizes[1] end
  M.FitCalc(tile)
  return true
end

--- A large number gets the sparkline and "vs your average here" the first time (as the hero did).
function M.SetSize(tile, size)
  if tile.kind ~= "reading" or not M.SIZES[size] then return false end
  local fits = false
  for _, s in ipairs(M.SizeChoices(tile)) do if s == size then fits = true end end
  if not fits then return false end
  tile.size = size
  if size == "large" and tile.extras == nil then tile.extras = { sparkline = true, vsUsual = true } end
  return true
end

--- Switch an extra on or off. Returns true when it changed.
function M.SetExtra(tile, name, on)
  if tile.kind ~= "reading" or not M.EXTRAS[name] then return false end
  on = on and true or nil
  if (M.HasExtra(tile, name) or nil) == on then return false end
  tile.extras = type(tile.extras) == "table" and tile.extras or {}
  tile.extras[name] = on
  return true
end

--- Can the tile carry the trend badge? A large number shown per hour or recent, where trend fits (its scope, who).
function M.TrendBadgeFits(tile)
  local c = M.TileCalc(tile)
  if M.Footprint(tile) ~= "hero" or (c ~= "perHour" and c ~= "recent") then return false end
  local r = ns.readings[tile.reading]
  return ns.CalcAllowed(r, "trend") and ns.CalcFits(r, "trend", tile.scope, tile.who, tile.arg) and true or false
end

--- The trend badge's value (a %) and state ("up", "down", "flat"), or nil (off, doesn't fit, not settled yet).
function M.TrendBadge(tile, board)
  if not (M.HasExtra(tile, "trend") and M.TrendBadgeFits(tile)) then return nil end
  local v, _, settled = M.TileValue(tile, board, "trend")
  if type(v) ~= "number" or settled == false then return nil end
  return v, ns.TrendState(v)
end

--- Is the extra on? (Drawn only on a large number, and only where it applies: a stock has no sparkline.)
function M.HasExtra(tile, name)
  return type(tile.extras) == "table" and tile.extras[name] and true or false
end

--- Does reading r need history it hasn't got for scope s? (A calendar scope reads storage, §3.4.)
local function needsHistory(r, s)
  local g = ns.ScopeGrain(s)
  if not (g and r and r.counter) then return false end
  local c = ns.counters[r.counter]
  return not (c and ns.ServesGrain(c, g))
end

--- Scopes a tile can pick: { { scope, ok, why, board } } in order. Greyed ones need history (§3.4) or aren't
--- offered. With its board (HC-55): `board = true` marks the board's own scope (picking it makes the tile follow
--- the board), and off the board's timer the timer isn't offered (it would have no Pause). A collection tile that is
--- on no board (Window only, HC-67) has no timer to offer either.
function M.ScopeChoices(tile, board)
  local r = ns.readings[tile.reading]
  local out = {}
  if not r then return out end
  local windowOnly = false
  if not board and getmetatable(tile) ~= PLACEMENT and rawget(tile, "id") then
    board = M.BoardOf(tile)
    windowOnly = board == nil
  end
  local bs = board and M.BoardScope(board)
  for _, s in ipairs(r.scopes) do
    if not (s == "run" and (windowOnly or (bs and bs ~= "run"))) then
      local ok, why = true, nil
      if needsHistory(r, s) then ok, why = false, "needs history" end
      out[#out + 1] = { scope = s, ok = ok, why = why, board = (bs == s) or nil }
    end
  end
  return out
end

--- Scopes the board can take (HC-55): { { scope, ok, why, trackers } } in M.BOARD_SCOPES order. A calendar scope
--- is greyed ("needs history") while a following tile's reading has it but not its history; `trackers` lists those
--- trackers' ids (one click turns their history on).
function M.BoardScopeChoices(board)
  local out = {}
  for _, s in ipairs(M.BOARD_SCOPES) do
    local trackers, seen = {}, {}
    for _, t in ipairs(board.tiles) do
      local r = t.kind == "reading" and t.follow and ns.readings[t.reading]
      if r and r.scopeSet[s] and needsHistory(r, s) and r.tracker and not seen[r.tracker] then
        seen[r.tracker] = true
        trackers[#trackers + 1] = r.tracker
      end
    end
    local ok = #trackers == 0
    out[#out + 1] = { scope = s, ok = ok, why = not ok and "needs history" or nil, trackers = trackers }
  end
  return out
end

--- The boards the Trackers window's [+] can add to, the ones on screen first, then hidden ones, each in list order
--- (HC-36: with one board it adds there; with several the player picks; "the board last edited" is gone).
function M.AddTargets()
  local out, hidden = {}, {}
  for _, b in ipairs(M.Store().list) do
    if b.shown then out[#out + 1] = b else hidden[#hidden + 1] = b end
  end
  for _, b in ipairs(hidden) do out[#out + 1] = b end
  return out
end

---------------------------------------------------------------------------
-- Layout: rows of tiles (grid tiles pair up), heights from content (§6.1: no empty space)
---------------------------------------------------------------------------

M.HEIGHT = { run = 24, hero = 74, heroCompare = 88, grid = 34, row = 18, bar = 26, gauge = 38, splits = 18, label = 18,
  strip = 22, odometer = 44, mix = 40 }
--- (2026-11-25, Farmer's Fishing basket) a mix whose reading sets `mixList`: the bar, then one line per part (name,
--- amount, share) instead of the shares in one line. A fixed height (every part's line), so the board doesn't jump
--- as members appear.
M.MIX_LINE_H = 12
M.HEIGHT.mixList = 26 + M.MIX_LINE_H * 6 + 4

--- Does this mix tile list its parts one per line? (its reading's `mixList`)
function M.MixIsList(tile)
  local r = tile and ns.readings[tile.reading]
  return r ~= nil and r.mixList == true
end
M.PAD = 6

--- How a reading tile is drawn (the layout row's kind): "hero" (a large number), "grid" (a half number), "row" (a
--- line number), "bar", "gauge". HC-51 ships today's footprints only: a bar or gauge is a line whatever its size,
--- and without a target it is a line number (no empty bars or dials, HC-33, statement 17b).
function M.Footprint(tile)
  local d = M.TileDisplay(tile)
  if d == "odometer" or d == "mix" then return d end
  if M.NEEDS_TARGET[d] then
    if M.TileTarget(tile) then return d end
    return "row"
  end
  local s = M.TileSize(tile)
  if s == "large" then return "hero" elseif s == "half" then return "grid" end
  return "row"
end

--- { { kind = "run"|"hero"|"grid"|"row"|..., tiles = { i, j? }, h = px } } for a board's full view. The control row
--- ("run", no tile) comes first on a board with a tile on its timer (HC-41), or, off the timer, with a tile on the
--- board's scope (HC-55: the header shows the scope once), except in a mini board's flyout (opts.noControls: the
--- strip has the clock, and the flyout goes when the mouse leaves the strip).
function M.Layout(board, opts)
  local rows = {}
  if not (opts and opts.noControls) and M.HasHeader(board) then
    rows[1] = { kind = "run", tiles = {}, h = M.HEIGHT.run }
  end
  local i, t = 1, board.tiles
  -- (v8) a tile kept off the HUD ("Only here") takes no row; the next half tile on the HUD pairs up past it
  local function nextOn(j)
    while t[j] and rawget(t[j], "off") do j = j + 1 end
    return j
  end
  while i <= #t do
    local tile = t[i]
    local foot = tile.kind == "reading" and M.Footprint(tile)
    if rawget(tile, "off") then
      i = i + 1
    elseif foot == "grid" then
      local j = nextOn(i + 1)
      local nxt = t[j]
      if nxt and nxt.kind == "reading" and M.Footprint(nxt) == "grid" then
        rows[#rows + 1] = { kind = "grid", tiles = { i, j }, h = M.HEIGHT.grid }
        i = j + 1
      else
        rows[#rows + 1] = { kind = "grid", tiles = { i }, h = M.HEIGHT.grid }
        i = i + 1
      end
    elseif foot then
      local h = M.HEIGHT[foot]
      if foot == "hero" and opts and opts.compare and opts.compare[i] then h = M.HEIGHT.heroCompare end
      if foot == "mix" and M.MixIsList(tile) then h = M.HEIGHT.mixList end
      rows[#rows + 1] = { kind = foot, tiles = { i }, h = h }
      i = i + 1
    else
      rows[#rows + 1] = { kind = tile.kind, tiles = { i }, h = M.HEIGHT[tile.kind] or 18 }
      i = i + 1
    end
  end
  local h = M.PAD
  for _, r in ipairs(rows) do h = h + r.h end
  return rows, h + M.PAD
end

---------------------------------------------------------------------------
-- Visibility (§6.1): combat show / fade / hide, instances, only while a run is open, fade until moused over
---------------------------------------------------------------------------

--- shown (bool), alpha. state = { combat, instance, runOpen, mouseOver, editing }.
--- The third value says why a board is hidden: "off" (the player hid it), "runOnly", "instance" or "combat" (its
--- rules; the Boards tab names them, HC-68). state.peek (Show now, or its row hovered in the Boards tab) shows a board
--- whatever its rules, at full alpha, even one that is off.
function M.Visibility(board, state)
  if state.peek then return true, 1 end
  if state.editOwn then return true, 1 end       -- (v8) edited on its own: on screen meanwhile, even "Only here"
  if not board.shown then return false, 1, "off" end
  if state.editing then return true, 1 end
  local show = board.show or defaultShow()
  if show.runOnly and not state.runOpen then return false, 1, "runOnly" end
  if show.instance == "hide" and state.instance then return false, 1, "instance" end
  local alpha = 1
  if state.combat then
    if show.combat == "hide" then return false, 1, "combat" end
    if show.combat == "fade" then alpha = 0.35 end
  end
  if show.mouseoverFade and not state.mouseOver then alpha = math.min(alpha, 0.3) end
  return true, alpha
end

--- Seconds between redraws: 0.5 s while the board's clock runs (its control row or strip shows it: its timer, or the
--- session's on a session board), else 5 s.
function M.TickRate(board, running)
  if running and M.BoardClock(board) then return 0.5 end
  return 5
end

---------------------------------------------------------------------------
-- The hero's comparison line: "vs your average here" from the run list (HC's own saved runs, history-free)
---------------------------------------------------------------------------

M.COMPARE_MIN_RUNS = 3

--- Average of a run reading (with a calc: nil for its default) over past runs whose main zone is `zone` (nil when
--- fewer than COMPARE_MIN_RUNS).
function M.ZoneAverage(readingId, zone, runs, calc)
  local r = ns.readings[readingId]
  if not (r and r.scopeSet.run and zone) then return nil end
  runs = runs or HC:Runs({ character = "current", limit = 200 })
  local sum, n = 0, 0
  for _, rec in ipairs(runs) do
    if rec.mainZone == zone and (rec.activeSeconds or 0) >= ns.RATE_SETTLE then
      local v = ns.Widgets and ns.Widgets.RecordReading(r, rec, calc)
      if type(v) == "number" then sum = sum + v; n = n + 1 end
    end
  end
  if n < M.COMPARE_MIN_RUNS then return nil end
  return sum / n, n
end

--- "+18% vs your average here" (green, or red when below), from a value and an average; nil when either is missing
--- or the average 0. Plain ASCII signs: the game's default fonts lack arrow glyphs (only Latin-1 is safe).
function M.PctText(pct)
  local up = pct >= 0
  return format("%s%s%d%%|r", up and "|cff60ff60" or "|cffff6060", up and "+" or "-", floor(abs(pct) + 0.5))
end

function M.CompareText(v, avg)
  if type(v) ~= "number" or type(avg) ~= "number" or avg == 0 then return nil end
  local pct = (v - avg) / abs(avg) * 100
  return M.PctText(pct) .. " vs your average here", pct
end

---------------------------------------------------------------------------
-- The splits tile: the last split's headline rate against the one before (live: the open run's segments)
---------------------------------------------------------------------------

--- text or nil, from the open run's split count and the readings of the closed splits (records keep them at stop;
--- while the run is open only the current split's live value is known, so it compares with the run so far).
function M.SplitsText(readingId, calc)
  local run = HC:GetRun()
  local r = ns.readings[readingId]
  if not (run and r) then return nil end
  local o = optsBuf
  o.arg, o.who, o.calc = nil, nil, calc
  local v, text = HC:Reading(readingId, "run", o)
  if run.splitCount <= 1 then return format("Split 1   %s", text) end
  return format("Split %d   %s", run.splitCount, text), v
end

---------------------------------------------------------------------------
-- Mini strip (§6.3): "● 1g 9s/h  ▲18%  12:48"
---------------------------------------------------------------------------

--- The tile a board's strip and flyout headline show: its first large tile (the hero), else its first reading.
function M.HeroIndex(board)
  local first
  for i, t in ipairs(board.tiles) do
    if t.kind == "reading" and not rawget(t, "off") then
      if t.size == "large" then return i end
      first = first or i
    end
  end
  return first
end

--- Sparkline values for a reading's counter: `n` buckets of `seconds` each, oldest first, from the in-memory
--- rate window (liveRate counters only, never storage). Fills `out` (reused) and returns it, or nil.
function M.Sparkline(readingId, n, seconds, out)
  local r = ns.readings[readingId]
  local c = r and r.counter and ns.counters[r.counter]
  if not (c and c.rate) then return nil end
  out = out or {}
  local prev = 0
  local vals = {}
  for k = 1, n do
    local _, sum = c.rate:Rate(k * seconds)
    vals[k] = (sum or 0) - prev
    prev = sum or 0
  end
  -- vals[1] is the newest bucket: reverse into out
  for k = 1, n do out[k] = vals[n - k + 1] end
  return out
end

--- The hero's sparkline from the recent rate (HC-52): the tile's counter's rate at each of the last active minutes,
--- over the tile's window (the board's timer, the session or the open run). Fills `out` (reused); nil when that
--- window has fewer than two samples yet (then the old per-minute gains, M.Sparkline). `n` values, oldest first;
--- minutes not sampled yet are 0 on the left.
local samplesBuf = {}
function M.RecentSparkline(tile, board, n, out)
  local r = ns.readings[tile.reading]
  if not (r and r.counter) or tile.who == "account" then return nil end
  local w = M.TileWindow(tile, board)
  if not w then
    if tile.scope == "session" then w = ns.Session()
    elseif tile.scope == "run" then w = ns.OpenRun() end
  end
  if not w then return nil end
  local s = ns.Win.RecentSamples(w, r.counter, samplesBuf)
  if not s then return nil end
  local k = #s
  for i = 1, n do
    local j = k - n + i
    out[i] = j >= 1 and s[j] or 0
  end
  for i = n + 1, #out do out[i] = nil end
  return out
end

--- Bar heights for a sparkline (drawn as textures: the game's fonts lack block glyphs), scaled to the largest
--- bucket; an empty bucket keeps a 1 px stub so the line reads as a line. Fills `out` (reused) and returns it.
function M.SparkHeights(vals, maxH, out)
  out = out or {}
  if not vals then return out end
  local maxv = 0
  for _, v in ipairs(vals) do if v > maxv then maxv = v end end
  for i, v in ipairs(vals) do
    local h = maxv > 0 and floor(v / maxv * maxH + 0.5) or 0
    if h < 1 then h = 1 end
    out[i] = h
  end
  return out
end

--- A tile's title: its own name, else the reading's.
function M.TileTitle(tile)
  local r = ns.readings[tile.reading]
  return tile.name or (r and ns.ReadingTitle(r, tile.arg, M.TileCalc(tile))) or tostring(tile.reading)
end

--- A tile's label: its title, with the scope when it isn't the board's ("Gold/h · session" on a board on its timer;
--- the board shows its clock or scope once, HC-41, HC-55), ", account" / "· account" for the whole account, and
--- "(since 14:02)" when its member was counted only from then (M.LateSince).
local SCOPE_WORD = { run = "timer", session = "session", today = "today", week = "week", month = "month", year = "year",
  lifetime = "lifetime", now = "now" }
M.SCOPE_WORD = SCOPE_WORD
function M.TileLabel(tile, board)
  if tile.kind ~= "reading" then return tile.text or "" end
  local bs = M.BoardScope(board or M.BoardOf(tile))
  local word = tile.scope ~= bs and (SCOPE_WORD[tile.scope] or tostring(tile.scope)) or nil
  if tile.who == "account" then word = word and (word .. ", account") or "account" end
  local s = M.TileTitle(tile)
  local since = M.LateSince(tile, board)
  if since then s = s .. " (since " .. ns.wow.date("%H:%M", since) .. ")" end
  if word then s = s .. " \194\183 " .. word end
  return s
end

--- value, text, settled, state for a reading tile; "needs Farmer"-style text when its pack isn't loaded.
--- board: the tile's board when the caller knows it. calc: another calc than the tile's (the trend badge).
function M.TileValue(tile, board, calc)
  if not ns.readings[tile.reading] then return nil, "needs " .. (tostring(tile.reading):match("^([^:]+):") or "a pack"), true, "missing" end
  local w = M.TileWindow(tile, board)
  calc = calc or tile.calc
  if w then return ns.ReadingOver(tile.reading, w, tile.arg, tile.who, calc) end
  local o = optsBuf
  o.arg, o.who, o.calc = tile.arg, tile.who, calc
  return HC:Reading(tile.reading, tile.scope, o)
end

---------------------------------------------------------------------------
-- The odometer and the mix (HC-63)
---------------------------------------------------------------------------

M.ODO_MIN, M.ODO_MAX = 6, 9          -- wheels: at least 6 (zeros in front), at most 9 (past that: the text)

--- The odometer's wheels for a value: a string of digits, zero-padded to M.ODO_MIN; nil when it can't be shown on
--- wheels (no value, negative, or more than M.ODO_MAX digits).
function M.OdometerDigits(v)
  if type(v) ~= "number" or v < 0 or v ~= v then return nil end
  local s = format("%.0f", floor(v))
  if #s > M.ODO_MAX then return nil end
  if #s < M.ODO_MIN then s = string.rep("0", M.ODO_MIN - #s) .. s end
  return s
end

--- The unit the odometer writes after its wheels: "yd" for a distance, else none.
function M.OdometerUnit(tile)
  local r = ns.readings[tile.reading]
  return r and r.formatter == "distance" and "yd" or nil
end

M.MIX_PARTS = 5                      -- the largest parts, then "other"
local singles = {}                   -- member -> { member }: a one-member set, reused at every redraw
local mixBuf = {}

--- The mix's parts over the tile's scope, largest first: { { arg, label, v, frac }, ... } (at most M.MIX_PARTS, the
--- rest summed as one part with arg = false), and the total. Members: the tile's set (a set reading), else the
--- members counted so far. Parts at 0 are left out; nil when nothing counts yet. The returned table is reused.
function M.MixParts(tile, board)
  local r = ns.readings[tile.reading]
  if not smallEnum(r) then return nil end
  local members = {}
  if r.param.multi then
    members = M.TileSet(tile) or {}
  else
    for _, c in ipairs(M.MemberChoices(tile.reading, true)) do members[#members + 1] = c.arg end
  end
  local saved, savedCalc = tile.arg, tile.calc
  tile.calc = nil
  for i = #mixBuf, 1, -1 do mixBuf[i] = nil end
  local total = 0
  for _, m in ipairs(members) do
    local arg = m
    if r.param.multi then
      arg = singles[m]
      if not arg then arg = { m }; singles[m] = arg end
    end
    tile.arg = arg
    local v = M.TileValue(tile, board, "total")
    if type(v) == "number" and v > 0 then
      mixBuf[#mixBuf + 1] = { arg = m, label = ns.MemberLabel(r, m), v = v }
      total = total + v
    end
  end
  tile.arg, tile.calc = saved, savedCalc
  if total <= 0 then return nil end
  table.sort(mixBuf, function(a, b)
    if a.v ~= b.v then return a.v > b.v end
    return tostring(a.arg) < tostring(b.arg)
  end)
  if #mixBuf > M.MIX_PARTS + 1 then
    local rest = 0
    for i = #mixBuf, M.MIX_PARTS + 1, -1 do rest = rest + mixBuf[i].v; mixBuf[i] = nil end
    mixBuf[#mixBuf + 1] = { arg = false, label = "other", v = rest }
  end
  for _, p in ipairs(mixBuf) do p.frac = p.v / total end
  return mixBuf, total
end

---------------------------------------------------------------------------
-- Readings with a parameter (DESIGN 16.4, HC-31): the tile is the instance; tile.arg is the member it shows.
---------------------------------------------------------------------------

M.MEMBER_CHOICES = 40

--- Change a tile's argument. On the board's timer it shows the new member over the board's period (a big
--- dimension's member nothing kept before: from now, "since").
function M.SetArg(tile, arg, board)
  if tile.kind ~= "reading" then return false end
  local r = ns.readings[tile.reading]
  if r and r.param and r.param.multi and type(arg) == "table" then
    -- (HC-60) a set, kept sorted; the reading's default (or every listed member, when that is the default) is nil
    arg = ns.NormalizeSet(arg)
    if #arg == 0 then return false end
    local p = r.param
    if ns.SameSet(arg, p.defaultSet) or (not p.defaultSet and p.members and ns.SameSet(arg, ns.NormalizeSet(p.members))) then
      arg = nil
    end
  end
  tile.arg = arg
  M.FitCalc(tile)        -- (a set of some kinds has no recent rate: everything has)
  board = board or M.BoardOf(tile)
  if ns.ready and board and M.TileWindow(tile, board) then watchTiles(board) end
  return true
end

--- Members a picker can offer for a reading's parameter: { { arg, label }, ... } sorted by label, at most
--- MEMBER_CHOICES (more = true when there are more; `all`: no limit). From this character's odometer (works with
--- history off) and from storage when the counter keeps history.
function M.MemberChoices(readingId, all)
  local r = ns.readings[readingId]
  local out = {}
  if r and r.param and r.param.members and not r.param.multi then
    -- (2026-11-24) a fixed list of members (a spell school, a resistance): in the reading's order
    for _, k in ipairs(r.param.members) do out[#out + 1] = { arg = k, label = ns.MemberLabel(r, k) } end
    return out, false
  end
  if not (r and r.param and r.counter) then return out, false end
  local keys = ns.OdoMembers(r.counter, r.param.dim)
  local c = ns.counters[r.counter]
  local big = false
  for _, d in ipairs(c and c.bigDims or {}) do if d == r.param.dim then big = true end end
  -- (a big dimension's stored members can be thousands: its picker offers the recent ones instead, RecentChoices)
  if c and c.h and not big and ns.db and ns.db.Members then
    for _, k in ipairs(ns.db:Members(r.counter, r.param.dim) or {}) do
      local seen = false
      for i = 1, #keys do if keys[i] == k then seen = true; break end end
      if not seen then keys[#keys + 1] = k end
    end
  end
  for _, k in ipairs(keys) do out[#out + 1] = { arg = k, label = ns.MemberLabel(r, k) } end
  table.sort(out, function(a, b)
    if a.label ~= b.label then return a.label < b.label end
    return tostring(a.arg) < tostring(b.arg)
  end)
  if all then return out, false end
  local more = #out > M.MEMBER_CHOICES
  while #out > M.MEMBER_CHOICES do table.remove(out) end
  return out, more
end

---------------------------------------------------------------------------
-- A tile's filter (HC-60): a reading with param.multi sums a set of members; the tile keeps the set in tile.arg
-- (nil: the reading's default). Small dimensions only.
---------------------------------------------------------------------------

--- (2026-11-24) Does the tile read part of its counter: one member, or a set of some kinds (its own or the reading's
--- default)? Gold in reading every source is the whole counter: it keeps the sparkline and "vs your average here".
function M.ReadsPart(tile)
  if tile.arg ~= nil then return true end
  local r = tile.kind == "reading" and ns.readings[tile.reading]
  return r and r.param and r.param.multi and ns.ReadingSet(r, nil) ~= nil or false
end

--- Does the tile show a set reading?
function M.HasSet(tile)
  local r = tile and tile.kind == "reading" and ns.readings[tile.reading]
  return r and r.param and r.param.multi and true or false
end

--- The members the tile's checklist offers, in the reading's order (its param.members), else the ones counted so
--- far: { { arg, label }, ... }.
function M.SetChoices(readingId)
  local r = ns.readings[readingId]
  if not (r and r.param and r.param.multi) then return {} end
  if not r.param.members then return (M.MemberChoices(readingId, true)) end
  local out = {}
  for _, m in ipairs(r.param.members) do out[#out + 1] = { arg = m, label = ns.MemberLabel(r, m) } end
  return out
end

--- The members the tile reads now, as a set: its own, the reading's default, or every choice (everything).
function M.TileSet(tile)
  local r = ns.readings[tile.reading]
  if not (r and r.param and r.param.multi) then return nil end
  local set = ns.ReadingSet(r, tile.arg)
  if set then return set end
  local all = {}
  for _, c in ipairs(M.SetChoices(tile.reading)) do all[#all + 1] = c.arg end
  return ns.NormalizeSet(all)
end

--- Tick or untick one member of the tile's set. The last member stays (false): an empty filter counts nothing.
function M.ToggleMember(tile, member, board)
  local cur = M.TileSet(tile)
  if not cur then return false end
  local next, had = {}, false
  for _, m in ipairs(cur) do
    if m == member then had = true else next[#next + 1] = m end
  end
  if not had then next[#next + 1] = member end
  if #next == 0 then return false end
  return M.SetArg(tile, next, board)
end

---------------------------------------------------------------------------
-- Pickers (DESIGN 16.4, HC-34): what the player chooses from instead of typing an id.
---------------------------------------------------------------------------

M.FLAT_CHOICES = 20      -- a faction list up to this long is one menu; longer ones open by group

--- The members of a big dimension written last on this character, newest first: { { arg, label }, ... }
--- ("recently looted" for an item reading). Members a tile already watches come after them.
function M.RecentChoices(readingId)
  local r = ns.readings[readingId]
  local out = {}
  if not (r and r.param and r.counter) then return out end
  local keys = ns.RecentMembers(r.counter, r.param.dim)
  for _, k in ipairs(ns.OdoMembers(r.counter, r.param.dim)) do
    local seen = false
    for i = 1, #keys do if keys[i] == k then seen = true; break end end
    if not seen then keys[#keys + 1] = k end
  end
  for _, k in ipairs(keys) do out[#out + 1] = { arg = k, label = ns.MemberLabel(r, k) } end
  return out
end

--- The factions the game's reputation panel lists, for a faction reading: groups in the panel's order,
--- { { name = header or nil, list = { { arg = factionID, label = name }, ... } }, ... }, and their total. Members
--- counted so far that the panel doesn't list (a collapsed header, a faction keyed by name) come last, under
--- name = false. Empty without a faction API: the caller falls back to the members known so far.
function M.FactionChoices(readingId)
  local groups, byName, n, listed = {}, {}, 0, {}
  for _, f in ipairs(ns.wow.factions()) do
    if not listed[f.id] then
      listed[f.id] = true
      local key = f.group or ""
      local g = byName[key]
      if not g then g = { name = f.group, list = {} }; byName[key] = g; groups[#groups + 1] = g end
      g.list[#g.list + 1] = { arg = f.id, label = f.name }
      n = n + 1
    end
  end
  if n == 0 then return groups, 0 end
  local rest = {}
  for _, c in ipairs((M.MemberChoices(readingId))) do
    if not listed[c.arg] then rest[#rest + 1] = c end
  end
  if #rest > 0 then groups[#groups + 1] = { name = false, list = rest }; n = n + #rest end
  return groups, n
end

--- (HC-71) The character's skill lines for a skill reading, by the skill panel's headers, narrowed by the reading's
--- param.filter: { { name = header or nil, list = { { arg = skillLineID, label = name }, ... } }, ... }, and their
--- total. Lines under a header the player collapsed aren't listed by the game's fallback list.
function M.SkillChoices(readingId)
  local r = ns.readings[readingId]
  local groups, byName, n = {}, {}, 0
  local filter = r and r.param and r.param.filter
  for _, line in ipairs(ns.wow.skillLines()) do
    local keep = true
    if filter then
      local ok, yes = pcall(filter, line)
      keep = ok and yes and true or false
    end
    if keep then
      local key = line.group or ""
      local g = byName[key]
      if not g then g = { name = line.group, list = {} }; byName[key] = g; groups[#groups + 1] = g end
      g.list[#g.list + 1] = { arg = line.id, label = line.name }
      n = n + 1
    end
  end
  return groups, n
end

--- The readings that take an item (param.type "item"), in display order: what an item dropped on a board can
--- become.
function M.ItemReadings()
  local out = {}
  for _, rid in ipairs(ns.allReadingOrder) do
    local r = ns.readings[rid]
    if r.param and r.param.type == "item" then out[#out + 1] = rid end
  end
  return out
end

--- What dropping item `id` on a board offers: { { text, tile = the tile to change, or reading = id to add }, ... }.
--- Dropped on a tile that takes an item: "show it there" comes first.
function M.DropChoices(_board, tile, id)
  local out = {}
  local tr = tile and tile.kind == "reading" and ns.readings[tile.reading]
  if tr and tr.param and tr.param.type == "item" and tile.arg ~= id then
    out[#out + 1] = { tile = tile, text = ns.ReadingTitle(tr, id) }
  end
  for _, rid in ipairs(M.ItemReadings()) do
    out[#out + 1] = { reading = rid, text = ns.ReadingTitle(ns.readings[rid], id) }
  end
  return out
end

-- Parameter types whose members are always numbers: a typed name must become an id or nothing (HC-47: a name kept
-- as text matched no loot and read 0 for ever). Factions and enums may be keyed by text (Farmer keys a faction by
-- name when the game can't give its id), so text stays allowed there.
local NUMERIC_TYPES = { item = true, zone = true }

local function sameText(a, b) return a:lower() == b:lower() end

--- What the player typed for "Other..." on reading `readingId`, as a member: arg, or nil and why ("empty",
--- "unknown"). A number is taken as an id; a pasted item link gives its id; a name is matched
--- against the picker's own list (any case), then, for an item, asked of the game. For an item or a zone an
--- unmatched name is refused; for other types the text itself is the member.
function M.ResolveArg(readingId, text)
  text = type(text) == "string" and text:match("^%s*(.-)%s*$") or ""
  if text == "" then return nil, "empty" end
  local r = ns.readings[readingId]
  local kind = r and r.param and (r.param.type or "enum") or "enum"
  local linked = kind == "item" and text:match("item:(%d+)")
  if linked then return tonumber(linked) end
  local n = tonumber(text)
  if n then return n end
  local lists = {}
  if kind == "item" then
    lists[1] = M.RecentChoices(readingId)
  elseif kind == "faction" then
    for _, g in ipairs((M.FactionChoices(readingId))) do lists[#lists + 1] = g.list end
  end
  lists[#lists + 1] = M.MemberChoices(readingId, true)
  for _, list in ipairs(lists) do
    for _, c in ipairs(list) do
      if type(c.label) == "string" and sameText(c.label, text) then return c.arg end
    end
  end
  if kind == "item" then
    local id = ns.wow.itemIdByName(text)
    if id then return id end
  end
  if NUMERIC_TYPES[kind] then return nil, "unknown" end
  return text
end

---------------------------------------------------------------------------
-- Character or account, per tile (DESIGN 16.5, HC-32): tile.who = "account" counts every character.
---------------------------------------------------------------------------

--- who: "account" or nil (this character). On the board's timer the tile reads the other window of its board: the
--- account's is made with the board's first account tile (DESIGN §16.8, a), from zero.
function M.SetWho(tile, who, board)
  if tile.kind ~= "reading" then return false end
  who = who == "account" and "account" or nil
  if tile.who == who then return false end
  tile.who = who
  M.FitCalc(tile)
  board = board or M.BoardOf(tile)
  if ns.ready and board and M.TileWindow(tile, board) then watchTiles(board) end
  return true
end

---------------------------------------------------------------------------
-- Targets and bars (DESIGN 16.6, HC-33): a reading may have a natural target (XP to level); a tile may set its
-- own (a goal: 100 gold this session, 200 of an item). The bar style draws the value toward it.
---------------------------------------------------------------------------

--- The tile's target: its own, else the reading's (a natural target is a total's: XP to level is no per-hour
--- goal); nil when there is none.
function M.TileTarget(tile)
  if tile.kind ~= "reading" then return nil end
  if type(tile.target) == "number" and tile.target > 0 then return tile.target end
  if M.TileCalc(tile) ~= "total" then return nil end
  return ns.ReadingTarget(ns.readings[tile.reading], tile.arg)
end

--- Set the tile's own target from what the player typed ("" or 0 clears it). Money readings take gold.
function M.SetTarget(tile, text)
  if tile.kind ~= "reading" then return false end
  local n = tonumber(text)
  if not n or n <= 0 then tile.target = nil; return true end
  local r = ns.readings[tile.reading]
  if r and r.formatter == "money" then n = n * 10000 end
  if r and r.formatter == "speedpct" then n = n * ns.RUN_SPEED / 100 end   -- typed as a percentage, kept in yd/s
  tile.target = n
  return true
end

--- Progress of a tile toward its target: fraction 0..1 (nil without a target or a value), "143 / 200", done.
function M.Progress(tile, board)
  local target = M.TileTarget(tile)
  if not target then return nil end
  local v, text = M.TileValue(tile, board)
  if type(v) ~= "number" then return nil, text end
  local r = ns.readings[tile.reading]
  local frac = v / target
  if frac < 0 then frac = 0 elseif frac > 1 then frac = 1 end
  return frac, text .. " / " .. ns.FormatReading(r, target, M.TileCalc(tile)), v >= target
end

--- The readings on boards that are shown: a set of ids (for refresh events, ns.SetPlacedReadings).
function M.PlacedReadings()
  local set = {}
  for _, b in ipairs(M.Store().list) do
    if b.shown then
      for _, t in ipairs(b.tiles) do
        if t.kind == "reading" and t.reading then set[t.reading] = true end
      end
    end
  end
  return set
end
