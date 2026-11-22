-- Boards, the model (TRACKERS_AND_BOARDS §6, HC-18): data and decisions only, no frames (UI/Boards.lua draws).
-- A board is a vertical stack of tiles the player builds; it replaces the run panel and the live number.
--
--   settings.boards = { list = { <board>, ... }, nextId = n, seeded = true, runBoard = true, v = 5 }
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
M.DISPLAY_ORDER = { "number", "bar", "gauge" }
M.DISPLAYS = {
  number = { sizes = { "large", "half", "line" }, calcs = { total = true, perHour = true, recent = true, trend = true } },
  bar = { sizes = { "line" }, calcs = { total = true, perHour = true }, needsTarget = true },
  gauge = { sizes = { "line" }, calcs = { total = true, perHour = true, recent = true }, needsTarget = true },
}
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
-- Settings
---------------------------------------------------------------------------

function M.Store()
  local s = ns.settings
  if type(s.boards) ~= "table" then s.boards = {} end
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
  for _, b in ipairs(M.Store().list) do
    for _, t in ipairs(type(b.tiles) == "table" and b.tiles or {}) do
      if M.FoldAlias(t) then n = n + 1 end
    end
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

--- The board a tile is on (a scan: callers that know it pass it).
function M.BoardOf(tile)
  for _, b in ipairs(M.Store().list) do
    for _, t in ipairs(b.tiles) do if t == tile then return b end end
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
  run = { name = "Run", mini = false, tiles = {
    reading("hc:gold", "run", "large", PH),
    reading("hc:xpgained", "run", "half", PH), reading("hc:net", "run", "half", PH),
    reading("hc:gold", "run", "half"), reading("hcfarm:items", "run", "half"),
    reading("hcfarm:vendorph", "run", "half"), reading("hc:ttl", "run", "half"),
    { kind = "splits" },
    reading("hcfarm:best", "run", "line"),
  } },
  pocket = { name = "Pocket", mini = true, tiles = {
    reading("hc:gold", "run", "large", PH),
    reading("hc:xpgained", "run", "half", PH), reading("hc:net", "run", "half", PH),
  } },
  leveling = { name = "Leveling", mini = false, tiles = {
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
  if not M.PRESETS[key] then M.PRESET_ORDER[#M.PRESET_ORDER + 1] = key end
  M.PRESETS[key] = { name = type(def.name) == "string" and def.name:sub(1, 32) or key, mini = def.mini and true or false,
    tiles = tiles, pack = U.namespace(key) }
  return key
end

--- A new board from a preset (or empty), added to the list. Returns it.
function M.Create(presetKey, opts)
  local p = presetKey and M.PRESETS[presetKey]
  opts = opts or {}
  local b = { id = newId(), name = opts.name or (p and p.name) or "Board", preset = presetKey, shown = true,
    mini = p and p.mini or false, width = M.WIDTH, scale = 1, show = defaultShow(), tiles = {} }
  if p then
    for _, t in ipairs(p.tiles) do
      if t.kind ~= "reading" or ns.readings[t.reading] then
        local c = U.copy(t)
        M.FoldAlias(c)                                -- a pack's preset may name an alias
        if c.kind == "reading" and c.scope == "run" then c.follow = true end   -- (HC-55) all but `now` follow the board
        b.tiles[#b.tiles + 1] = c
      end
    end
  end
  local list = M.Store().list
  list[#list + 1] = b
  return b
end

function M.Delete(id)
  local list = M.Store().list
  for i, b in ipairs(list) do
    if b.id == id then
      if b.wid then ns.SavedWindows.Drop(winKey(b.wid)) end   -- its windows, on every character
      table.remove(list, i)
      return true
    end
  end
  return false
end

---------------------------------------------------------------------------
-- First use and migration (§6.4): a fresh install shows the Pocket board; a player of the old run panel or live
-- number gets the Run / Pocket boards seeded from those settings, once. The Run board appears with the first run.
---------------------------------------------------------------------------

function M.Seed()
  local B = M.Store()
  if B.seeded then return false end
  B.seeded = true
  local s = ns.settings
  local rp, wins = s.runPanel, s.windows
  local rpw = type(wins) == "table" and wins.runPanel or nil
  -- a run panel that was used: its window state exists (UI/Windows.lua wrote it), or the old position keys do
  local usedPanel = type(rpw) == "table" or s.runPanelPos ~= nil
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
  local pocket = M.Create("pocket")
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
  board.tiles[#board.tiles + 1] = t
  if ns.ready and M.TileWindow(t, board) then watchTiles(board) end   -- the board's first such tile starts its window
  return t
end

function M.AddTile(board, kind, extra)
  if not M.KINDS[kind] or kind == "reading" then return nil end
  local t = { kind = kind }
  if extra then for k, v in pairs(extra) do t[k] = v end end
  board.tiles[#board.tiles + 1] = t
  return t
end

function M.RemoveTile(board, i)
  if not board.tiles[i] then return nil end
  return table.remove(board.tiles, i)
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
    target = M.Create(nil, { name = name:sub(1, 32) })
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

---------------------------------------------------------------------------
-- Calc, display and size (DESIGN §16.9, HC-51). The tile menu's "Show as", Display and Size.
---------------------------------------------------------------------------

--- The tile's calc: its own, else its reading's default.
function M.TileCalc(tile)
  if tile.calc then return tile.calc end
  return ns.DefaultCalc(ns.readings[tile.reading])
end

function M.TileDisplay(tile) return M.DISPLAYS[tile.display] and tile.display or "number" end
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
    local ok, why = ns.CalcFits(r, c, tile.scope, tile.who)
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
    return ns.CalcAllowed(r, c) and ns.CalcFits(r, c, tile.scope, tile.who) and M.DISPLAYS[M.TileDisplay(tile)].calcs[c]
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
  if not M.DISPLAYS[M.TileDisplay(tile)].calcs[calc] or not ns.CalcFits(r, calc, tile.scope, tile.who) then return false end
  tile.calc = calc
  return true
end

--- A display that doesn't draw the tile's size takes its first size; one that doesn't take the tile's calc moves it
--- to per hour (a bar takes no recent: M.FitCalc).
function M.SetDisplay(tile, display)
  local d = M.DISPLAYS[display]
  if tile.kind ~= "reading" or not d then return false end
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
  return ns.CalcAllowed(r, "trend") and ns.CalcFits(r, "trend", tile.scope, tile.who) and true or false
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
--- the board), and off the board's timer the timer isn't offered (it would have no Pause).
function M.ScopeChoices(tile, board)
  local r = ns.readings[tile.reading]
  local out = {}
  if not r then return out end
  local bs = board and M.BoardScope(board)
  for _, s in ipairs(r.scopes) do
    if not (s == "run" and bs and bs ~= "run") then
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
  strip = 22 }
M.PAD = 6

--- How a reading tile is drawn (the layout row's kind): "hero" (a large number), "grid" (a half number), "row" (a
--- line number), "bar", "gauge". HC-51 ships today's footprints only: a bar or gauge is a line whatever its size,
--- and without a target it is a line number (no empty bars or dials, HC-33, statement 17b).
function M.Footprint(tile)
  local d = M.TileDisplay(tile)
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
  while i <= #t do
    local tile = t[i]
    local foot = tile.kind == "reading" and M.Footprint(tile)
    if foot == "grid" then
      local nxt = t[i + 1]
      if nxt and nxt.kind == "reading" and M.Footprint(nxt) == "grid" then
        rows[#rows + 1] = { kind = "grid", tiles = { i, i + 1 }, h = M.HEIGHT.grid }
        i = i + 2
      else
        rows[#rows + 1] = { kind = "grid", tiles = { i }, h = M.HEIGHT.grid }
        i = i + 1
      end
    elseif foot then
      local h = M.HEIGHT[foot]
      if foot == "hero" and opts and opts.compare and opts.compare[i] then h = M.HEIGHT.heroCompare end
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
function M.Visibility(board, state)
  if not board.shown then return false, 1 end
  if state.editing then return true, 1 end
  local show = board.show or defaultShow()
  if show.runOnly and not state.runOpen then return false, 1 end
  if show.instance == "hide" and state.instance then return false, 1 end
  local alpha = 1
  if state.combat then
    if show.combat == "hide" then return false, 1 end
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
    if t.kind == "reading" then
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
