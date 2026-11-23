-- Boards, the frames (TRACKERS_AND_BOARDS §6, HC-18): on-screen HUDs the player builds from tiles. They replace
-- the run panel and the live number (deleted in HC-24, 2026-11-15, after the user saw boards working; git history
-- has them). The model and every decision live in UI/BoardModel.lua.
--
-- Locked by default: a board is text, clicks pass through to the world, except the control row's buttons and the
-- mini strip. Edit mode shows outlines, name bars (with Done), width grips and [+], lets boards move, and opens a
-- tile's options on right-click. It is per board (HC-42): hovering a full board shows a small Edit handle above it
-- that edits that board only; /hc edit, ctrl-click on the launcher and Options edit every board. Escape leaves.
--
-- The board is the clock (DESIGN §16.8, HC-41): one timer per board. The control row (drawn by itself on a full
-- board with a tile on the board's timer), the strip's dot and the board's menu start, pause, stop, reset and save
-- it; tiles have no timer of their own. To pause one tile, move it to a board of its own (its menu: Move to).
-- A board has a scope (HC-55, its menu: Scope): the timer by default; on session or a calendar scope the header
-- names the scope once and Pause, Reset and Save as run are hidden.
-- Cost: one ticker per visible board (0.5 s while its clock runs, else 5 s); hidden boards cost nothing; ticks read
-- windows over the odometers and open buckets only.
local ADDON, ns = ...

local HC, L, U, Wd, M = ns.HC, ns.L, ns.U, ns.Widgets, ns.BoardModel
local format, floor, max = string.format, math.floor, math.max

local frames = {}           -- board id -> frame
local editAll = false       -- every board is edited (/hc edit, ctrl-click on the launcher, Options)
local editIds = {}          -- board id -> true: a board edited on its own (its hover handle, HC-42)
local holding = false      -- the cursor carries an item: boards take the drop (HC-34)
local escaper               -- an invisible frame in UISpecialFrames, shown while editing: Escape leaves edit mode
local state = { combat = false, instance = false, runOpen = false, mouseOver = false, editing = false }
local compareCache = {}     -- reading .. zone -> average or false
local sparkBuf, sparkH = {}, {}
local SPARK_N, SPARK_W, SPARK_H = 10, 6, 12
local GAUGE_N, GAUGE_R, GAUGE_DOT = 13, 22, 4   -- the gauge: dots on a half circle, left of its text (HC-33)
local WHEEL_W, WHEEL_H, WHEEL_GAP, ROLL_S = 14, 20, 2, 0.3   -- the odometer's wheels and how long a digit rolls (HC-63)
-- the mix's colours, part by part (largest first); "other" is grey
local MIX_RGB = { { 1, 0.82, 0 }, { 0.25, 0.65, 1 }, { 0.38, 1, 0.38 }, { 1, 0.45, 0.3 }, { 0.75, 0.5, 1 } }
local MIX_OTHER = { 0.55, 0.55, 0.55 }

local DOT_RUN, DOT_PAUSE, DOT_NONE = { 0.38, 1, 0.38 }, { 1, 0.82, 0 }, { 0.5, 0.5, 0.5 }
local NAMEBAR_H, ADD_H = 18, 20

local Boards = {}
ns.Boards = Boards

---------------------------------------------------------------------------
-- Small helpers
---------------------------------------------------------------------------

local function text(parent, font, justify)
  local s = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlightSmall")
  s:SetJustifyH(justify or "LEFT")
  s:SetWordWrap(false)
  return s
end

local function valueColor(fs, settled, stateWord)
  if stateWord == "off" or stateWord == "missing" or stateWord == "needs history" or stateWord == "stale"
      or stateWord == "inapplicable" then fs:SetTextColor(0.5, 0.5, 0.5)
  elseif settled == false then fs:SetTextColor(0.5, 0.5, 0.5)
  else fs:SetTextColor(1, 1, 1) end
end

-- trend (HC-53): green up, red down, white inside the dead band (neutral)
local TREND_RGB = { up = { 0.38, 1, 0.38 }, down = { 1, 0.38, 0.38 }, flat = { 1, 1, 1 } }
-- arrows are textures: the game's default fonts have no arrow glyphs (unverified on Forever: checklist part R)
local ARROW = { up = "Interface\\Buttons\\Arrow-Up-Up", down = "Interface\\Buttons\\Arrow-Down-Up" }

local function valueText(textValue, st)
  if st == "needs history" then return "needs history" end
  if st == "norun" then return "-" end
  return textValue or "-"
end

local STATE_DOT = { running = DOT_RUN, paused = DOT_PAUSE, stopped = DOT_NONE }

--- Is this board in edit mode? (Every board, or this one on its own.)
local function isEditing(board) return editAll or (board ~= nil and editIds[board.id] == true) end
local function anyEditing() return editAll or next(editIds) ~= nil end

--- Do a board's tiles take clicks? In edit mode, or while the cursor carries an item to drop on one.
local function clickable(f) return isEditing(f.board) or holding end

--- Mouse on or off for a board's frame and rows, as the mode asks (boards are click-through otherwise).
local function setMouse(f)
  f:EnableMouse(clickable(f))
  for _, w in ipairs(f.rowFrames or {}) do w:EnableMouse(clickable(f)) end
end

--- Start, pause, stop or reset a board's timer; says so when a reset saved a record.
local function controlAll(board, action)
  local saved = M.ControlAll(board, action)
  if saved and ns.Print then ns.Print(L["%s: saved as run #%d (the Runs tab)"], board.name, saved) end
  Boards.RefreshAll()
end

--- The control row's and the strip's main click: pause if anything runs, else start.
local function toggleAll(board)
  local st = M.BoardState(board)
  if st == nil then return end
  controlAll(board, st == "running" and "pause" or "start")
end

local function saveBoard(board)
  local id = M.SaveBoard(board)
  if ns.Print then
    if id then ns.Print(L["%s: saved as run #%d (the Runs tab)"], board.name, id)
    else ns.Print(L["Nothing to save yet: a run needs 5 active minutes."]) end
  end
  Boards.RefreshAll()
end

local function compareFor(board, i)
  local tile = board.tiles[i]
  if not (tile and tile.kind == "reading" and M.Footprint(tile) == "hero" and M.HasExtra(tile, "vsUsual")
    and tile.scope == "run") or tile.arg ~= nil or M.HasSet(tile) or tile.who == "account" then return nil end
  local zone = HC:ZoneKey()
  local calc = M.TileCalc(tile)
  if calc == "recent" then calc = "perHour" end   -- past runs have no recent rate: their per hour
  if calc == "trend" then return nil end          -- a % against the average already: nothing to compare it with
  local key = tostring(tile.reading) .. "@" .. tostring(zone) .. "@" .. tostring(calc)
  local avg = compareCache[key]
  if avg == nil then
    avg = M.ZoneAverage(tile.reading, zone, nil, calc) or false
    compareCache[key] = avg
  end
  return avg or nil
end

local function compareMap(board)
  local out = {}
  for i in ipairs(board.tiles) do if compareFor(board, i) then out[i] = true end end
  return out
end

---------------------------------------------------------------------------
-- Tile widgets (built per layout; a layout change rebuilds the board's rows)
---------------------------------------------------------------------------

local function runControls(w, board)
  local function btn(label, fn)
    local b = Wd.Button(w, label, 40, fn)
    b:SetHeight(18)
    local fs = b:GetFontString()
    if fs and fs.SetFontObject then fs:SetFontObject("GameFontHighlightSmall") end
    return b
  end

  w.reset = btn(L["Reset"], function() controlAll(board, "reset") end)
  w.reset:SetPoint("RIGHT", w, "RIGHT", -4, 0)
  w.pause = btn(L["Pause"], function() toggleAll(board) end)
  w.pause:SetWidth(52)
  w.pause:SetPoint("RIGHT", w.reset, "LEFT", -2, 0)
  Wd.Tip(w.pause, function() return L["Pause or start this board's timer: every tile on it. Nothing counts while paused"] end)
  Wd.Tip(w.reset, function()
    return L["Start this board's timer again from zero. With 5 active minutes or more the period that ends is saved as a run"]
  end)
end

local function buildRow(f, row, y)
  local board = f.board
  local w = CreateFrame("Frame", nil, f)
  w:SetPoint("TOPLEFT", 0, y)
  w:SetPoint("TOPRIGHT", 0, y)
  w:SetHeight(row.h)
  w.row = row
  if row.kind == "run" then
    w.dot = w:CreateTexture(nil, "OVERLAY")
    w.dot:SetSize(8, 8)
    w.dot:SetPoint("LEFT", 8, 0)
    w.dot:SetColorTexture(0.5, 0.5, 0.5, 1)
    w.name = text(w, "GameFontNormal")
    w.name:SetPoint("LEFT", w.dot, "RIGHT", 6, 0)
    w.clock = text(w, "GameFontHighlight", "RIGHT")
    runControls(w, board)
    w.clock:SetPoint("RIGHT", w.pause, "LEFT", -6, 0)
    w.name:SetPoint("RIGHT", w.clock, "LEFT", -4, 0)
  elseif row.kind == "hero" then
    w.label = text(w, "GameFontNormalSmall")
    w.label:SetPoint("TOPLEFT", 10, -4)
    w.label:SetPoint("TOPRIGHT", -10, -4)
    w.value = text(w, "GameFontNormalHuge")
    w.value:SetPoint("TOPLEFT", w.label, "BOTTOMLEFT", 0, -2)
    -- the sparkline: bar textures (the game's fonts have no block glyphs), the last 10 minutes, oldest left
    w.spark = CreateFrame("Frame", nil, w)
    w.spark:SetSize(SPARK_N * SPARK_W, SPARK_H)
    w.spark:SetPoint("TOPLEFT", w.value, "BOTTOMLEFT", 0, -3)
    w.bars = {}
    for k = 1, SPARK_N do
      local bar = w.spark:CreateTexture(nil, "ARTWORK")
      bar:SetWidth(SPARK_W - 1)
      bar:SetPoint("BOTTOMLEFT", (k - 1) * SPARK_W, 0)
      bar:SetColorTexture(1, 0.82, 0, 0.7)
      bar:SetHeight(1)
      w.bars[k] = bar
    end
    -- the trend badge (HC-53): an arrow and the trend in words (HC-54) beside the big number
    w.trendArrow = w:CreateTexture(nil, "OVERLAY")
    w.trendArrow:SetSize(14, 14)
    w.trendArrow:SetPoint("LEFT", w.value, "RIGHT", 6, 0)
    w.trendArrow:Hide()
    w.trend = text(w, "GameFontHighlight")
    w.trend:SetPoint("LEFT", w.trendArrow, "RIGHT", 1, 0)
    w.compare = text(w, "GameFontHighlightSmall")
    w.compare:SetPoint("TOPLEFT", w.spark, "BOTTOMLEFT", 0, -3)
    w.compare:SetPoint("RIGHT", -10, 0)
    local edge = w:CreateTexture(nil, "BORDER")
    edge:SetPoint("TOPLEFT", 4, -2)
    edge:SetPoint("BOTTOMLEFT", 4, 2)
    edge:SetWidth(2)
    edge:SetColorTexture(1, 0.82, 0, 0.8)
  elseif row.kind == "bar" then
    -- a row over a track: the value toward the target (the reading's own, or the tile's)
    w.label = text(w, "GameFontHighlightSmall")
    w.label:SetPoint("TOPLEFT", 10, -3)
    w.value = text(w, "GameFontHighlightSmall", "RIGHT")
    w.value:SetPoint("TOPRIGHT", -10, -3)
    w.label:SetPoint("RIGHT", w.value, "LEFT", -6, 0)
    w.track = w:CreateTexture(nil, "BACKGROUND")
    w.track:SetPoint("BOTTOMLEFT", 10, 3)
    w.track:SetPoint("BOTTOMRIGHT", -10, 3)
    w.track:SetHeight(6)
    w.track:SetColorTexture(1, 1, 1, 0.12)
    w.fill = w:CreateTexture(nil, "ARTWORK")
    w.fill:SetPoint("BOTTOMLEFT", 10, 3)
    w.fill:SetHeight(6)
    w.fill:SetWidth(1)
    w.fill:SetColorTexture(1, 0.82, 0, 0.85)
  elseif row.kind == "gauge" then
    -- a half dial of dots toward the target, the title and value beside it (HC-33). Plain squares, no rotation, no art
    -- (the needle of HC-12's speedometer needs art: parked)
    local textX = 10 + 2 * GAUGE_R + 10
    w.label = text(w, "GameFontHighlightSmall")
    w.label:SetPoint("TOPLEFT", textX, -5)
    w.label:SetPoint("TOPRIGHT", -10, -5)
    w.value = text(w, "GameFontHighlight")
    w.value:SetPoint("TOPLEFT", w.label, "BOTTOMLEFT", 0, -3)
    w.value:SetPoint("RIGHT", -10, 0)
    w.dots = {}
    for k = 1, GAUGE_N do
      local a = math.pi * (1 - (k - 1) / (GAUGE_N - 1))           -- from the left (180 degrees) to the right (0)
      local dot = w:CreateTexture(nil, "ARTWORK")
      dot:SetSize(GAUGE_DOT, GAUGE_DOT)
      local dx, dy = 10 + GAUGE_R + GAUGE_R * math.cos(a), 7 + GAUGE_R * math.sin(a)
      dot:SetPoint("CENTER", w, "BOTTOMLEFT", floor(dx + 0.5), floor(dy + 0.5))
      dot:SetColorTexture(1, 1, 1, 0.12)
      w.dots[k] = dot
    end
  elseif row.kind == "odometer" then
    -- (HC-63) digit wheels under the title; a digit that changes rolls up into place. Plain squares and the game's
    -- own font, no art; each wheel clips its two digits (the one leaving and the one coming)
    w.label = text(w, "GameFontHighlightSmall")
    w.label:SetPoint("TOPLEFT", 10, -3)
    w.label:SetPoint("TOPRIGHT", -10, -3)
    w.value = text(w, "GameFontHighlight")              -- states and values too long for the wheels
    w.value:SetPoint("BOTTOMLEFT", 10, 5)
    w.wheels = {}
    for k = 1, ns.BoardModel.ODO_MAX do
      local wheel = CreateFrame("Frame", nil, w)
      wheel:SetSize(WHEEL_W, WHEEL_H)
      wheel:SetPoint("BOTTOMLEFT", 10 + (k - 1) * (WHEEL_W + WHEEL_GAP), 4)
      if wheel.SetClipsChildren then wheel:SetClipsChildren(true) end
      local bg = wheel:CreateTexture(nil, "BACKGROUND")
      bg:SetAllPoints()
      bg:SetColorTexture(0, 0, 0, 0.55)
      wheel.cur = text(wheel, "GameFontHighlightLarge", "CENTER")
      wheel.cur:SetPoint("CENTER", 0, 0)
      wheel.nxt = text(wheel, "GameFontHighlightLarge", "CENTER")
      wheel.nxt:SetPoint("CENTER", 0, -WHEEL_H)
      wheel.nxt:Hide()
      wheel:Hide()
      w.wheels[k] = wheel
    end
    w.unit = text(w, "GameFontHighlightSmall")
  elseif row.kind == "mix" then
    -- (HC-63) one bar split into a part per member, largest first, the shares written under it
    w.label = text(w, "GameFontHighlightSmall")
    w.label:SetPoint("TOPLEFT", 10, -3)
    w.value = text(w, "GameFontHighlightSmall", "RIGHT")
    w.value:SetPoint("TOPRIGHT", -10, -3)
    w.label:SetPoint("RIGHT", w.value, "LEFT", -6, 0)
    w.track = w:CreateTexture(nil, "BACKGROUND")
    w.track:SetPoint("TOPLEFT", 10, -18)
    w.track:SetPoint("TOPRIGHT", -10, -18)
    w.track:SetHeight(7)
    w.track:SetColorTexture(1, 1, 1, 0.12)
    w.parts = {}
    for k = 1, ns.BoardModel.MIX_PARTS + 1 do
      local p = w:CreateTexture(nil, "ARTWORK")
      p:SetHeight(7)
      p:Hide()
      w.parts[k] = p
    end
    w.legend = text(w, "GameFontDisableSmall")
    w.legend:SetPoint("TOPLEFT", 10, -28)
    w.legend:SetPoint("TOPRIGHT", -10, -28)
  elseif row.kind == "grid" then
    w.cells = {}
    for c = 1, 2 do
      local cell = {}
      cell.label = text(w, "GameFontDisableSmall")
      cell.value = text(w, "GameFontHighlight")
      w.cells[c] = cell
    end
    w:SetScript("OnSizeChanged", function(self)
      local half = floor((self:GetWidth() - 20) / 2)
      for c, cell in ipairs(self.cells) do
        local x = 10 + (c - 1) * (half + 4)
        cell.label:ClearAllPoints()
        cell.label:SetPoint("TOPLEFT", x, -3)
        cell.label:SetWidth(half)
        cell.value:ClearAllPoints()
        cell.value:SetPoint("TOPLEFT", x, -16)
        cell.value:SetWidth(half)
      end
    end)
    w:GetScript("OnSizeChanged")(w)
  else
    w.label = text(w, row.kind == "label" and "GameFontNormalSmall" or "GameFontHighlightSmall")
    w.label:SetPoint("LEFT", 10, 0)
    w.value = text(w, "GameFontHighlightSmall", "RIGHT")
    w.value:SetPoint("RIGHT", -10, 0)
    w.label:SetPoint("RIGHT", w.value, "LEFT", -6, 0)
  end
  local function tileAt(self)
    local i = self.row.tiles[1]
    if self.row.tiles[2] and GetCursorPosition and self.GetLeft and self:GetLeft() then
      -- a grid row holds two tiles: the one under the cursor
      local x = GetCursorPosition() / (self.GetEffectiveScale and self:GetEffectiveScale() or 1)
      if x > self:GetLeft() + self:GetWidth() / 2 then i = self.row.tiles[2] end
    end
    return i
  end
  -- an item from the bags dropped on the tile (dragged here, or carried and clicked): HC-34
  w:SetScript("OnReceiveDrag", function(self) Boards.DropItem(self, board, tileAt(self)) end)
  -- edit mode: right-click a tile for its options (the control row: the board's)
  w:SetScript("OnMouseUp", function(self, button)
    local i = tileAt(self)
    if Boards.DropItem(self, board, i) then return end
    if button ~= "RightButton" or not isEditing(f.board) then return end
    if i then Boards.TileMenu(self, board, i) else Boards.BoardMenu(self, board) end
  end)
  w:EnableMouse(clickable(f))
  return w
end

local function clearRows(f)
  for _, w in ipairs(f.rowFrames or {}) do w:Hide(); w:SetParent(nil) end
  f.rowFrames = {}
end

--- Rebuild the rows of a full-view frame (a board, or a mini board's flyout) for the board's tiles.
local function layoutFull(f)
  local board = f.board
  clearRows(f)
  local rows, h = M.Layout(board, { compare = compareMap(board), noControls = f.isFlyout })
  local y = -M.PAD
  for _, row in ipairs(rows) do
    f.rowFrames[#f.rowFrames + 1] = buildRow(f, row, y)
    y = y - row.h
  end
  if #rows == 0 then
    f.empty = f.empty or text(f, "GameFontDisableSmall")
    f.empty:SetPoint("TOPLEFT", 10, -M.PAD - 2)
    f.empty:SetText(L["Empty board: Edit (/hc edit), then +"])
    f.empty:Show()
    h = h + 18
  elseif f.empty then
    f.empty:Hide()
  end
  f.fullH = h
  f.layoutKey = #board.tiles
end

---------------------------------------------------------------------------
-- Drawing values
---------------------------------------------------------------------------

local function drawReading(board, i, fsLabel, fsValue)
  local tile = board.tiles[i]
  local v, t, settled, st, note = M.TileValue(tile, board)
  local label = M.TileLabel(tile, board)             -- after the value: reading a member may mark it "since"
  -- (CS-9) a stale value the game still gives, as a secret: handed straight to the font string, never touched.
  -- Only a plain number tile of the character's current value: bars, gauges and account sums need arithmetic.
  local live, fmt
  if st == "stale" and tile.scope == "now" and tile.who ~= "account" and M.TileDisplay(tile) == "number" then
    local r = ns.readings[tile.reading]
    fmt = ns.LiveFormat(r)
    live = fmt and ns.ReadingLive(r, tile.arg)
  end
  if live ~= nil then
    fsLabel:SetText(label)
    fsValue:SetFormattedText(fmt, live)
    valueColor(fsValue, true, nil)
    return "live", v
  end
  if st == "stale" and note then label = label .. " \194\183 " .. note end   -- the pack's word: "in combat"
  fsLabel:SetText(label)
  fsValue:SetText(valueText(t, st))
  valueColor(fsValue, settled, st)
  if st == nil and settled ~= false and M.TileCalc(tile) == "trend" then
    local c = TREND_RGB[ns.TrendState(v)]
    if c then fsValue:SetTextColor(c[1], c[2], c[3]) end
  end
  return st, v
end

-- (HC-63) the odometer's roll: every wheel whose digit changed moves its old digit up and the new one in from below
local function rollStep(self)
  local now = ns.wow.time()
  local busy = false
  for _, wheel in ipairs(self.wheels) do
    if wheel.t0 then
      local p = (now - wheel.t0) / ROLL_S
      if p >= 1 or not wheel:IsShown() then
        wheel.t0 = nil
        wheel.cur:SetText(wheel.digit)
        wheel.cur:SetPoint("CENTER", 0, 0)
        wheel.nxt:Hide()
        wheel.nxt:SetPoint("CENTER", 0, -WHEEL_H)
      else
        busy = true
        local off = floor(p * WHEEL_H + 0.5)
        wheel.cur:SetPoint("CENTER", 0, off)
        wheel.nxt:SetPoint("CENTER", 0, off - WHEEL_H)
      end
    end
  end
  if not busy then self:SetScript("OnUpdate", nil) end
end

local function rollTo(w, wheel, d)
  if wheel.digit == d then return end
  local first = wheel.digit == nil
  wheel.digit = d
  if first then wheel.cur:SetText(d); return end   -- the first draw sets the wheels without rolling
  if wheel.t0 then wheel.cur:SetText(wheel.nxt:GetText() or d) end   -- a roll still going: start from its digit
  wheel.nxt:SetText(d)
  wheel.nxt:Show()
  wheel.t0 = ns.wow.time()
  w:SetScript("OnUpdate", rollStep)
end

local function drawOdometer(w, board, i)
  local tile = board.tiles[i]
  local st, v = drawReading(board, i, w.label, w.value)
  local digits = (st == nil or st == "stale") and M.OdometerDigits(v)
  local n = digits and #digits or 0
  for k, wheel in ipairs(w.wheels) do
    if k <= n then
      rollTo(w, wheel, digits:sub(k, k))
      wheel:Show()
    else
      wheel:Hide()
      wheel.digit, wheel.t0 = nil, nil
    end
  end
  if digits then
    w.value:SetText("")                                -- the wheels say it; the text stays for states and long values
    w.unit:ClearAllPoints()
    w.unit:SetPoint("BOTTOMLEFT", 10 + n * (WHEEL_W + WHEEL_GAP) + 2, 7)
    w.unit:SetText(M.OdometerUnit(tile) or "")
  else
    w.unit:SetText("")
  end
end

local function hexColor(c) return format("|cff%02x%02x%02x", floor(c[1] * 255), floor(c[2] * 255), floor(c[3] * 255)) end

local function drawMix(w, board, i)
  local tile = board.tiles[i]
  local st = drawReading(board, i, w.label, w.value)
  local parts = st == nil and M.MixParts(tile, board) or nil
  local full = (w.GetWidth and w:GetWidth() or 0) - 20
  local x, legend = 0, {}
  for k, tex in ipairs(w.parts) do
    local p = parts and parts[k]
    if p then
      local c = p.arg == false and MIX_OTHER or MIX_RGB[k] or MIX_OTHER
      legend[#legend + 1] = format("%s%s|r %d%%", hexColor(c), p.arg == false and L["other"] or p.label, floor(p.frac * 100 + 0.5))
      if full > 0 then
        local wpx = k == #parts and (full - x) or floor(full * p.frac + 0.5)   -- the last part takes the rounding
        wpx = max(1, wpx)
        tex:ClearAllPoints()
        tex:SetPoint("TOPLEFT", w.track, "TOPLEFT", x, 0)
        tex:SetWidth(wpx)
        tex:SetColorTexture(c[1], c[2], c[3], 0.9)
        tex:Show()
        x = x + wpx
      else
        tex:Hide()
      end
    else
      tex:Hide()
    end
  end
  w.track:SetShown(parts ~= nil)
  if parts then w.legend:SetText(table.concat(legend, "  "))
  elseif st == nil then w.legend:SetText(L["Nothing counted yet"])
  else w.legend:SetText("") end
end
Boards.DrawMix, Boards.DrawOdometer = drawMix, drawOdometer   -- (tests)

local function drawRow(w, board)
  local row = w.row
  local i = row.tiles[1]
  local tile = board.tiles[i]
  if row.kind == "run" then
    -- the board's timer: state, clock, Pause, Reset. Off the timer (HC-55): the board's scope once ("Leveling ·
    -- session"), the session's clock on session, no clock on a calendar scope, no Pause or Reset (hidden, not greyed).
    local kind, st, active = M.BoardClock(board)
    local timer = kind == "timer"
    w.pause:SetShown(timer)
    w.reset:SetShown(timer)
    w.clock:ClearAllPoints()
    if timer then w.clock:SetPoint("RIGHT", w.pause, "LEFT", -6, 0) else w.clock:SetPoint("RIGHT", w, "RIGHT", -8, 0) end
    local c = STATE_DOT[st] or DOT_NONE
    w.dot:SetColorTexture(c[1], c[2], c[3], 1)
    w.dot:SetShown(kind ~= nil)
    local bs = M.BoardScope(board)
    if timer then
      w.name:SetText(st == "running" and board.name or (board.name .. "  (" .. L[st] .. ")"))
      w.clock:SetText(U.duration(active))
      w.pause:SetText(st == "running" and L["Pause"] or (st == "paused" and L["Resume"] or L["Start"]))
    elseif bs ~= "run" then
      w.name:SetText(board.name .. " \194\183 " .. L[M.SCOPE_WORD[bs] or bs])
      w.clock:SetText(kind and U.duration(active) or "")
    else
      w.name:SetText(L["no timers on this board"])
      w.clock:SetText("")
    end
  elseif row.kind == "hero" then
    local st, v = drawReading(board, i, w.label, w.value)
    -- (HC-52) the recent rate at each of the last active minutes; until two are sampled, gains per minute
    local vals = not st and tile.arg == nil and not M.HasSet(tile) and M.HasExtra(tile, "sparkline")
      and (M.RecentSparkline(tile, board, SPARK_N, sparkBuf) or M.Sparkline(tile.reading, SPARK_N, 60, sparkBuf))
    w.spark:SetShown(vals and true or false)
    if vals then
      M.SparkHeights(vals, SPARK_H, sparkH)
      for k = 1, SPARK_N do w.bars[k]:SetHeight(sparkH[k] or 1) end
    end
    local avg = compareFor(board, i)
    w.compare:SetText(avg and M.CompareText(v, avg) or "")    -- the board's period against past runs here
    local tv, ts = M.TrendBadge(tile, board)
    if tv then
      local c = TREND_RGB[ts]
      w.trend:SetText(ns.TrendText(tv))
      w.trend:SetTextColor(c[1], c[2], c[3])
      if ARROW[ts] then
        w.trendArrow:SetTexture(ARROW[ts])
        -- the arrow art is gold: grey it first so the tint matches the words (red on gold drew orange, 2026-11-20)
        if w.trendArrow.SetDesaturated then w.trendArrow:SetDesaturated(true) end
        w.trendArrow:SetVertexColor(c[1], c[2], c[3])
        w.trendArrow:Show()
      else
        w.trendArrow:Hide()
      end
    else
      w.trend:SetText("")
      w.trendArrow:Hide()
    end
  elseif row.kind == "grid" then
    for c, cell in ipairs(w.cells) do
      local idx = row.tiles[c]
      if idx then drawReading(board, idx, cell.label, cell.value)
      else cell.label:SetText(""); cell.value:SetText("") end
    end
  elseif row.kind == "bar" then
    drawReading(board, i, w.label, w.value)
    local frac, ptext, done = M.Progress(tile, board)
    if frac then
      w.value:SetText(ptext)
      local full = (w.GetWidth and w:GetWidth() or 0) - 20
      w.fill:SetWidth(max(1, floor(max(0, full) * frac + 0.5)))
      if done then w.fill:SetColorTexture(0.38, 1, 0.38, 0.9) else w.fill:SetColorTexture(1, 0.82, 0, 0.85) end
      w.fill:Show()
    else
      w.fill:Hide()                                   -- no target now (a reading's own went away): no empty bar
    end
    w.track:SetShown(frac ~= nil)
  elseif row.kind == "gauge" then
    drawReading(board, i, w.label, w.value)
    local frac, ptext, done = M.Progress(tile, board)
    if ptext and frac then w.value:SetText(ptext) end
    local lit = frac and floor(frac * GAUGE_N + 0.5) or 0
    for k = 1, GAUGE_N do
      local dot = w.dots[k]
      if k > lit then dot:SetColorTexture(1, 1, 1, 0.12)
      elseif done then dot:SetColorTexture(0.38, 1, 0.38, 0.9)
      else dot:SetColorTexture(1, 0.82, 0, 0.85) end
    end
  elseif row.kind == "odometer" then
    drawOdometer(w, board, i)
  elseif row.kind == "mix" then
    drawMix(w, board, i)
  elseif row.kind == "row" then
    drawReading(board, i, w.label, w.value)
  elseif row.kind == "splits" then
    local hero = M.HeroIndex(board)
    local ht = hero and board.tiles[hero]
    local s = M.SplitsText(ht and ht.reading or "hc:goldph", ht and ht.calc)
    w.label:SetText(s or L["Splits: start a run"])
    w.value:SetText("")
  elseif row.kind == "label" then
    w.label:SetText(tile.text or L["Heading"])
    w.value:SetText("")
  end
end

local STRIP_LABEL = "|cffa8a8a8"

--- The strip's text and the state its dot shows (only on the board's timer: the dot pauses nothing else, HC-55).
local function stripText(board)
  local parts = {}
  local kind, st, active = M.BoardClock(board)
  local bs = M.BoardScope(board)
  local hi = M.HeroIndex(board)
  if hi then
    local tile = board.tiles[hi]
    local v, t, _, vst = M.TileValue(tile, board)
    -- the hero's name first, dimmed: a fresh Pocket board read "- 0:09" and nothing said what it counts (2026-11-22)
    parts[#parts + 1] = STRIP_LABEL .. M.TileLabel(tile, board) .. "|r " .. valueText(t, vst)
    local avg = compareFor(board, hi)
    local _, pct = M.CompareText(v, avg)
    if pct then parts[#parts + 1] = M.PctText(pct) end
  else
    parts[#parts + 1] = board.name
  end
  if kind == "timer" then
    parts[#parts + 1] = st == "running" and U.duration(active) or L[st]
  elseif kind == "session" then
    parts[#parts + 1] = U.duration(active)
  elseif bs ~= "run" then
    parts[#parts + 1] = L[M.SCOPE_WORD[bs] or bs]
  end
  return table.concat(parts, "  "), kind == "timer" and st or nil
end

local function refreshFull(f)
  local board = f.board
  if f.layoutKey ~= #board.tiles then
    layoutFull(f)
    f:SetHeight(f.fullH)
  end
  for _, w in ipairs(f.rowFrames) do
    local ok, err = pcall(drawRow, w, board)
    if not ok then ns.Error(err) end
  end
end

local function refreshStrip(f)
  local s, st = stripText(f.board)
  f.strip.text:SetText(s)
  if st then
    local c = STATE_DOT[st] or DOT_NONE
    f.strip.dot:SetColorTexture(c[1], c[2], c[3], 1)
    f.strip.dot:Show()
  else
    f.strip.dot:Hide()
  end
end

---------------------------------------------------------------------------
-- Board frames
---------------------------------------------------------------------------

local function savePos(f)
  Wd.PinTopLeft(f)
  f.board.pos = Wd.SavedPoint(f)
end

-- Boards draw below our windows (HC-43): a board is on-screen numbers, like unit frames, so it sits in LOW, and the
-- Hard Counters window (MEDIUM) is always above it, clicked or not. Blizzard's panels and bags (MEDIUM) are too.
-- The flyout stays in LOW, above its own board.
Boards.STRATA = "LOW"
local FLYOUT_LEVELS = 20

local function newFullFrame(name, board)
  local f = CreateFrame("Frame", name, UIParent)
  f.board = board
  f:SetFrameStrata(Boards.STRATA)
  f:SetClampedToScreen(true)
  f.bg = f:CreateTexture(nil, "BACKGROUND")
  f.bg:SetAllPoints()
  f.bg:SetColorTexture(0.04, 0.04, 0.06, 0.72)
  f.rowFrames = {}
  return f
end

local function ensureFlyout(f)
  if f.fly then return f.fly end
  local fly = newFullFrame(nil, f.board)
  fly.isFlyout = true                                    -- no control row: the strip has the clock
  fly:SetFrameLevel(f:GetFrameLevel() + FLYOUT_LEVELS)   -- above its board and the board's tiles, below our windows
  fly:Hide()
  f.fly = fly
  return fly
end

local function showFlyout(f)
  local fly = ensureFlyout(f)
  fly.board = f.board
  fly:SetWidth(f.board.width or M.WIDTH)
  fly.layoutKey = nil
  refreshFull(fly)
  fly:ClearAllPoints()
  local top = f:GetTop() or 0
  local half = (UIParent:GetHeight() or 768) / 2
  if top > half then fly:SetPoint("TOPLEFT", f, "BOTTOMLEFT", 0, -2) else fly:SetPoint("BOTTOMLEFT", f, "TOPLEFT", 0, 2) end
  fly:Show()
end

local function buildStrip(f)
  local s = CreateFrame("Button", nil, f)
  s:SetAllPoints(f)
  s:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  s.dot = s:CreateTexture(nil, "OVERLAY")
  s.dot:SetSize(8, 8)
  s.dot:SetPoint("LEFT", 6, 0)
  s.text = text(s, "GameFontHighlight")
  s.text:SetPoint("LEFT", 20, 0)
  s.text:SetPoint("RIGHT", -6, 0)
  s:SetScript("OnReceiveDrag", function(self) Boards.DropItem(self, f.board, nil) end)
  s:SetScript("OnClick", function(self, button)
    if Boards.DropItem(self, f.board, nil) then return end     -- an item carried here: not a pause
    if isEditing(f.board) then return end
    if button == "RightButton" then Boards.StripMenu(self, f.board); return end
    -- the strip pauses or starts the board's timer (§6.3, DESIGN §16.8)
    toggleAll(f.board)
  end)
  s:SetScript("OnEnter", function() if not isEditing(f.board) then showFlyout(f) end end)
  s:SetScript("OnLeave", function() if f.fly then f.fly:Hide() end end)
  f.strip = s
end

local function buildEditChrome(f)
  local board = f.board
  local bar = CreateFrame("Button", nil, f)
  bar:SetHeight(NAMEBAR_H)
  bar:SetPoint("BOTTOMLEFT", f, "TOPLEFT", 0, 0)
  bar:SetPoint("BOTTOMRIGHT", f, "TOPRIGHT", 0, 0)
  bar:RegisterForClicks("RightButtonUp")
  local bg = bar:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  bg:SetColorTexture(0.25, 0.19, 0.03, 0.9)
  -- Done leaves edit mode: this board's own, or every board's when all are edited (HC-42: the toolbar is gone)
  bar.done = Wd.Button(bar, L["Done"], 46, function() Boards.Done(f.board) end)
  bar.done:SetHeight(NAMEBAR_H - 2)
  bar.done:SetPoint("RIGHT", bar, "RIGHT", -1, 0)
  Wd.Tip(bar.done, function()
    return editAll and L["Stop editing boards (Escape does it too)"] or L["Stop editing this board (Escape does it too)"]
  end)
  bar.text = text(bar, "GameFontNormalSmall")
  bar.text:SetPoint("LEFT", 6, 0)
  bar.text:SetPoint("RIGHT", bar.done, "LEFT", -4, 0)
  bar:SetScript("OnClick", function(self) Boards.BoardMenu(self, f.board) end)
  bar:RegisterForDrag("LeftButton")
  bar:SetScript("OnDragStart", function() f:StartMoving() end)
  bar:SetScript("OnDragStop", function() f:StopMovingOrSizing(); savePos(f) end)
  f.nameBar = bar
  local add = Wd.Button(f, "+", 40, function(self) Boards.AddMenu(self, f.board) end)
  add:SetHeight(ADD_H)
  add:SetPoint("TOP", f, "BOTTOM", 0, -2)
  Wd.Tip(add, function() return L["Add a reading, splits or a heading"] end)
  f.addBtn = add
  -- the grip changes the width only: the height always follows the tiles (§6.1)
  Wd.Grip(f, function() return isEditing(f.board) end, function(self)
    board.width = floor(max(M.MIN_WIDTH, math.min(M.MAX_WIDTH, self:GetWidth())) + 0.5)
    savePos(self)
    Boards.Refresh(board.id, true)
  end, 1)
end

local function setEditChrome(f, on)
  if not f.nameBar then buildEditChrome(f) end
  f.nameBar:SetShown(on)
  f.addBtn:SetShown(on and not f.board.mini)
  f.grip:SetShown(on and not f.board.mini)
  f.nameBar.text:SetText(f.board.name .. (f.board.mini and ("  " .. L["(mini)"]) or "") .. "  \194\183 " .. L["right-click: options"])
  f:SetMovable(true)
  if on then
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) self:StartMoving() end)
    f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing(); savePos(self) end)
    f.bg:SetColorTexture(0.10, 0.08, 0.02, 0.85)
  else
    f:SetScript("OnDragStart", nil)
    f:SetScript("OnDragStop", nil)
    f.bg:SetColorTexture(0.04, 0.04, 0.06, 0.72)
  end
  if on and f.handle then f.handle:Hide() end
  setMouse(f)
end

-- The edit handle (HC-42 a): a small "Edit" tab above a full board's top-right corner, shown while the cursor is
-- over the board. Boards are click-through, so they get no OnEnter: Boards.Hover polls IsMouseOver ten times a
-- second instead (a handle that always took the mouse would eat clicks and camera drags on its spot). The handle
-- itself takes clicks only while it is shown. Not on mini boards (their strip's menu has "Edit this board"), not in
-- combat, not while the board is edited.
local HANDLE_W, HANDLE_H = 40, 16

local function ensureHandle(f)
  if f.handle then return f.handle end
  local h = CreateFrame("Button", nil, f)
  h:SetSize(HANDLE_W, HANDLE_H)
  h:SetPoint("BOTTOMRIGHT", f, "TOPRIGHT", 0, 0)
  h:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  local bg = h:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  bg:SetColorTexture(0.25, 0.19, 0.03, 0.9)
  h.text = text(h, "GameFontNormalSmall", "CENTER")
  h.text:SetAllPoints()
  h.text:SetText(L["Edit"])
  h:SetScript("OnClick", function() Boards.EditBoard(f.board.id, true) end)
  Wd.Tip(h, function() return L["Edit this board: add, remove, restyle and move its numbers"] end)
  h:Hide()
  f.handle = h
  return h
end

--- Can this board show its handle now?
local function handleFits(f)
  return f:IsShown() and not f.board.mini and not isEditing(f.board) and not state.combat
end

local HOVER_GAP = 0.1
local sinceHover = HOVER_GAP

--- Show or hide each board's edit handle by where the cursor is. Returns how many handles are shown (tests).
function Boards.Hover(elapsed)
  sinceHover = sinceHover + (elapsed or 0)
  if sinceHover < HOVER_GAP then return nil end
  sinceHover = 0
  local shown = 0
  for _, f in pairs(frames) do
    local over = false
    if handleFits(f) then
      over = (f.IsMouseOver and f:IsMouseOver()) or (f.handle and f.handle:IsShown() and f.handle:IsMouseOver()) or false
    end
    if over then
      local h = ensureHandle(f)
      if not h:IsShown() then h:Show() end
      shown = shown + 1
    elseif f.handle and f.handle:IsShown() then
      f.handle:Hide()
    end
  end
  return shown
end

local function ensureFrame(board)
  local f = frames[board.id]
  if f then f.board = board; return f end
  f = newFullFrame("HardCountersBoard_" .. board.id, board)
  buildStrip(f)
  -- an item dropped beside the tiles (the board's padding, an empty board)
  f:SetScript("OnReceiveDrag", function(self) Boards.DropItem(self, self.board, nil) end)
  f:SetScript("OnMouseUp", function(self) Boards.DropItem(self, self.board, nil) end)
  f:Hide()
  -- BlizzMove only scales a board (Ctrl+wheel in edit mode): moving is ours (name bar, frame drag), and a draggable
  -- registration made boards take the mouse and snap back to BlizzMove's last drag spot (2026-11-20)
  Wd.BlizzMove(f, f:GetName(), { NonDraggable = true })
  f:EnableMouse(isEditing(board) or holding)          -- after registering: click-through unless edited
  frames[board.id] = f
  return f
end

local function applyGeometry(f)
  local b = f.board
  Wd.PlaceAt(f, b.pos or { "TOP", 0, -120, "TOP" })
  f:SetScale(b.scale or 1)
  f:SetWidth(b.width or M.WIDTH)
end

--- Redraw one board: visibility, mode, values. rebuild = true re-lays its rows (tiles or width changed).
function Boards.Refresh(id, rebuild)
  local board = M.Get(id)
  local f = frames[id]
  if not board then
    if f then f:Hide(); if f.fly then f.fly:Hide() end end
    if editIds[id] then editIds[id] = nil; Boards.SyncEscape() end   -- a board deleted while edited
    return
  end
  f = ensureFrame(board)
  local editingThis = isEditing(board)
  state.editing = editingThis
  state.runOpen = HC:GetRun() ~= nil            -- "only while a run is open": a dungeon run, or /hc run start
  state.mouseOver = f:IsShown() and f.IsMouseOver and f:IsMouseOver() or false
  local shown, alpha = M.Visibility(board, state)
  if not shown then
    if f:IsShown() then f:Hide() end
    if f.fly then f.fly:Hide() end
    Boards.Tick(f, nil)
    return
  end
  if rebuild or not f.placed then
    applyGeometry(f)
    f.placed = true
    f.layoutKey = nil
  end
  f:SetAlpha(alpha)
  if board.mini and not editingThis then
    -- switching to the strip: the full view's rows go. (Not keyed on layoutKey: a rebuild has just cleared it, which
    -- left the rows on screen under the strip after leaving edit mode.)
    if #f.rowFrames > 0 then clearRows(f) end
    f.layoutKey = nil
    f:SetHeight(M.HEIGHT.strip)
    f.strip:Show()
    refreshStrip(f)
  else
    f.strip:Hide()
    if f.fly then f.fly:Hide() end
    refreshFull(f)
    f:SetHeight(f.fullH)
    -- the grip changes the width only
    Wd.SetResizeBounds(f, M.MIN_WIDTH, f.fullH, M.MAX_WIDTH, f.fullH)
  end
  if editingThis or f.nameBar then setEditChrome(f, editingThis) end
  if not f:IsShown() then f:Show() end
  Boards.Tick(f, M.TickRate(board, select(2, M.BoardClock(board)) == "running"))
end

--- One ticker per visible board, at its rate; nil stops it.
function Boards.Tick(f, rate)
  if f.tickRate == rate and (rate == nil or f.ticker) then return end
  if f.ticker then f.ticker:Cancel(); f.ticker = nil end
  f.tickRate = rate
  if rate then
    local id = f.board.id
    f.ticker = C_Timer.NewTicker(rate, function() Boards.Refresh(id) end)
  end
end

function Boards.RefreshAll(rebuild)
  if ns.settings and ns.SetPlacedReadings then ns.SetPlacedReadings(M.PlacedReadings()) end   -- refresh events
  if not ns.settings then return end
  local seen = {}
  for _, b in ipairs(M.Store().list) do
    seen[b.id] = true
    local ok, err = pcall(Boards.Refresh, b.id, rebuild)
    if not ok then ns.Error(err) end
  end
  for id, f in pairs(frames) do
    if not seen[id] then
      f:Hide()
      if f.fly then f.fly:Hide() end
      Boards.Tick(f, nil)
      if editIds[id] then editIds[id] = nil; Boards.SyncEscape() end   -- deleted while edited
    end
  end
end

--- For tests and the smoke test.
function Boards.Frame(id) return frames[id] end
--- Any board in edit mode (no id), or that board (an id).
function Boards.IsEditing(id)
  if id == nil then return anyEditing() end
  return editAll or editIds[id] == true
end

---------------------------------------------------------------------------
-- Edit mode (per board since HC-42; the "Editing boards" toolbar is gone)
---------------------------------------------------------------------------

-- Escape leaves edit mode: an invisible frame in UISpecialFrames, shown while any board is edited. The game hides
-- the shown special frames on Escape; hiding it ends edit mode everywhere.
local function ensureEscaper()
  if escaper then return escaper end
  local e = CreateFrame("Frame", "HardCountersBoardEdit", UIParent)
  e:SetSize(1, 1)
  e:SetPoint("TOP", 0, 0)
  e:Hide()                                             -- created shown: hide before the handler is set
  e:SetScript("OnHide", function() if anyEditing() then Boards.SetEditing(false) end end)
  tinsert(UISpecialFrames, "HardCountersBoardEdit")
  escaper = e
  return e
end

function Boards.SyncEscape()
  local e = ensureEscaper()
  if anyEditing() then
    if not e:IsShown() then e:Show() end
  elseif e:IsShown() then
    e:Hide()
  end
end

--- Every board in edit mode, or none (off also ends boards edited on their own). /hc edit, the launcher, Options.
--- noTrackers: don't open the Trackers window (Blizzard's Edit Mode: its own panels are already on screen).
function Boards.SetEditing(on, noTrackers)
  on = on and true or false
  if editAll == on and (on or next(editIds) == nil) then return end
  editAll = on
  if not on then for k in pairs(editIds) do editIds[k] = nil end end
  if ns.Menu then ns.Menu.Hide() end
  Boards.SyncEscape()
  Boards.RefreshAll(true)
  if on and not noTrackers and ns.ShowTrackers and not (ns.settings.boards and ns.settings.boards.noTrackersWithEdit) then
    ns.ShowTrackers(true)                             -- the Trackers window opens beside them (§6.2)
  end
end

-- HC-42 (c): Blizzard's Edit Mode, mirroring only. Entering it puts every board in edit mode, leaving it ends edit
-- mode on every board (also one edited before). Its EventRegistry callbacks reach addons on Forever (probe, 2026-11-20:
-- once per visit; the manager frame shows and hides twice, so not that). Our work runs on the next frame, outside
-- Blizzard's call, so nothing of ours runs inside its secure code path.
function Boards.OnBlizzardEditMode(entering)
  if entering then Boards.SetEditing(true, true) else Boards.SetEditing(false) end
end

local function mirrorLater(entering)
  return function()
    C_Timer.After(0, function()
      local ok, err = pcall(Boards.OnBlizzardEditMode, entering)
      if not ok then ns.Error(err) end
    end)
  end
end

local function listenEditMode()
  local reg = rawget(_G, "EventRegistry")
  if type(reg) ~= "table" or type(reg.RegisterCallback) ~= "function" then return false end
  local owner = {}
  return (pcall(function()
    reg:RegisterCallback("EditMode.Enter", mirrorLater(true), owner)
    reg:RegisterCallback("EditMode.Exit", mirrorLater(false), owner)
  end))
end
Boards.mirrorsEditMode = listenEditMode()   -- false on a client without EventRegistry: nothing mirrors

--- One board in edit mode or out of it (HC-42 a: its hover handle, the strip's menu, Done on its name bar). The
--- Trackers window doesn't open for one board: its [+] adds readings.
function Boards.EditBoard(id, on)
  on = on and true or nil
  if editIds[id] == on then return end
  editIds[id] = on
  if ns.Menu then ns.Menu.Hide() end
  Boards.SyncEscape()
  Boards.Refresh(id, true)
end

--- Done on a board's name bar: leaves its own edit mode, or everyone's when every board is edited.
function Boards.Done(board)
  if editAll then Boards.SetEditing(false) else Boards.EditBoard(board.id, false) end
end

---------------------------------------------------------------------------
-- Menus (right-click a tile, a board's name bar, the strip; the + button)
---------------------------------------------------------------------------

-- The game formats a popup's text (SetFormattedText(text, text_arg1, text_arg2)), so our message goes in as the
-- argument of a fixed "%s", never as the format: a "%" in it ("Gold from %s", a board named "50%") raised a Lua
-- error (playtest 2026-11-18).
local function confirm(textMsg, fn)
  StaticPopupDialogs.HARDCOUNTERS_CONFIRM = StaticPopupDialogs.HARDCOUNTERS_CONFIRM or {
    button1 = YES or "Yes", button2 = NO or "No", timeout = 0, whileDead = true, hideOnEscape = true,
  }
  local d = StaticPopupDialogs.HARDCOUNTERS_CONFIRM
  d.text = "%s"
  d.OnAccept = function() fn() end
  StaticPopup_Show("HARDCOUNTERS_CONFIRM", tostring(textMsg or ""))
end
Boards.Confirm = confirm

local function askText(prompt, current, fn)
  StaticPopupDialogs.HARDCOUNTERS_TEXT = StaticPopupDialogs.HARDCOUNTERS_TEXT or {
    button1 = OKAY or "OK", button2 = CANCEL or "Cancel", hasEditBox = true, timeout = 0, whileDead = true,
    hideOnEscape = true,
  }
  local d = StaticPopupDialogs.HARDCOUNTERS_TEXT
  d.text = "%s"                                        -- the prompt is the argument, as in confirm()
  d.OnShow = function(self)
    local eb = self.editBox or self.EditBox
    if eb then eb:SetText(current or ""); eb:HighlightText() end
  end
  d.OnAccept = function(self)
    local eb = self.editBox or self.EditBox
    fn(eb and eb:GetText() or "")
  end
  d.EditBoxOnEnterPressed = function(eb) local p = eb:GetParent(); d.OnAccept(p); p:Hide() end
  StaticPopup_Show("HARDCOUNTERS_TEXT", tostring(prompt or ""))
end
Boards.AskText = askText

--- A board just added to from elsewhere (the Trackers window, HC-36): shown if it was hidden, and the new tile
--- flashes once (on a mini board, its strip). Nothing flashes when the board's own rules hide it (combat, ...).
function Boards.Reveal(board, tile)
  if not board.shown then board.shown = true end
  Boards.Refresh(board.id, true)
  local f = frames[board.id]
  if not (f and f:IsShown()) then return end
  local target = f.strip and f.strip:IsShown() and f.strip
  if not target then
    for _, w in ipairs(f.rowFrames or {}) do
      for _, i in ipairs(w.row and w.row.tiles or {}) do
        if board.tiles[i] == tile then target = w end
      end
    end
  end
  if not target then return end
  local fl = target.flash
  if not fl then
    fl = target:CreateTexture(nil, "OVERLAY")
    fl:SetAllPoints()
    fl:SetColorTexture(1, 0.82, 0, 0.35)
    target.flash = fl
  end
  fl:Show()
  C_Timer.After(0.6, function() fl:Hide() end)
end

--- Adding a reading whose tracker is off asks first (§7: "never silently"). onAdded(tile), when given, runs once
--- the tile is there (not when the player says no).
local function addReading(board, rid, look, arg, onAdded)
  local r = ns.readings[rid]
  if not r then return end
  local function add()
    local tile = M.AddReading(board, rid, look, nil, arg)
    Boards.Refresh(board.id, true)
    if ns.RefreshOverview then ns.RefreshOverview() end   -- (HC-67) a new tile is in the collection too
    if onAdded and tile then onAdded(tile) end
  end
  local t = r.tracker and HC:GetTracker(r.tracker)
  if t and not t.on then
    confirm(format(L["Turn on %s? %s"], t.title, t.description or ""), function()
      HC:SetTrackerOn(r.tracker, true)
      add()
    end)
  else
    add()
  end
end
Boards.AddReading = addReading

--- Pick the member for a reading with a parameter (DESIGN §16.4, HC-34). By its type: a faction from the game's
--- reputation list (by group when it is long); an item from the ones looted last (or drag one from the bags onto
--- a board: Boards.DropItem); anything else from the members counted so far. "Other..." takes a typed name or id.
--- fn(arg) gets the choice.
function Boards.MemberMenu(anchor, rid, fn, current)
  local r = ns.readings[rid]
  if not (r and r.param) then return end
  local items = { { text = ns.ReadingTitle(r, nil), title = true } }
  local function pick(c)
    return { text = c.label, checked = current ~= nil and c.arg == current, func = function() fn(c.arg) end }
  end
  local kind, done = r.param.type, false
  if kind == "faction" then
    local groups, n = M.FactionChoices(rid)
    done = n > 0                                       -- no faction API: the members counted so far, below
    for _, g in ipairs(groups) do
      if n <= M.FLAT_CHOICES or not g.name then
        for _, c in ipairs(g.list) do items[#items + 1] = pick(c) end
      else
        local sub = {}
        for _, c in ipairs(g.list) do sub[#sub + 1] = pick(c) end
        items[#items + 1] = { text = g.name, sub = sub }
      end
    end
  elseif kind == "item" then
    done = true
    local recent = M.RecentChoices(rid)
    if #recent > 0 then items[#items + 1] = { text = L["Recent:"], disabled = true } end
    for _, c in ipairs(recent) do items[#items + 1] = pick(c) end
    items[#items + 1] = { text = L["Or drag an item from your bags onto a board"], disabled = true }
  end
  if not done then
    local choices, more = M.MemberChoices(rid)
    for _, c in ipairs(choices) do items[#items + 1] = pick(c) end
    if #choices == 0 then
      items[#items + 1] = { text = L["Nothing counted yet: play a little, or type one"], disabled = true }
    elseif more then
      items[#items + 1] = { text = L["(more: type one)"], disabled = true }
    end
  end
  items[#items + 1] = { text = L["Other..."], func = function()
    local ask = kind == "item" and L["%s: which item? (its id, or its exact name)"]
      or L["%s: which one? (a name, or an id number)"]
    askText(format(ask, ns.ReadingTitle(r, nil)), "", function(s)
      local arg, why = M.ResolveArg(rid, s)
      if arg ~= nil then
        fn(arg)
      elseif why == "unknown" and kind == "item" then
        ns.Print(L["No item called \"%s\" that the game knows yet: type its id, or drag the item from your bags onto a board."], s)
      elseif why == "unknown" then
        ns.Print(L["No zone called \"%s\" among the ones counted so far: pick one from the list."], s)
      end
    end)
  end }
  ns.Menu.Show(anchor, items)
end

--- The cursor carries an item from the bags and let go of it over a board (HC-34): the item goes back to its bag
--- and becomes a tile. On a tile still waiting for its item it is set at once; otherwise a menu offers every
--- reading that takes an item ("Add: Linen Cloth looted"), and, on a tile that shows another item, to show this
--- one there. i: the tile's index, or nil (the strip, the board's edge). Returns true when there was an item.
function Boards.DropItem(anchor, board, i)
  local id = ns.wow.cursorItem()
  if not id then return false end
  ns.wow.clearCursor()
  local tile = i and board.tiles[i] or nil
  local choices = M.DropChoices(board, tile, id)
  if #choices == 0 then
    if ns.Print then ns.Print(L["No reading takes an item yet (the Farmer pack's Loot readings do)."]) end
    return true
  end
  local function act(c)
    return function()
      if c.tile then
        M.SetArg(c.tile, id, board)
        Boards.Refresh(board.id, true)
      else
        addReading(board, c.reading, nil, id)
      end
    end
  end
  if choices[1].tile and tile.arg == nil then
    act(choices[1])()
    return true
  end
  local items = { { text = ns.MemberLabel(ns.readings[M.ItemReadings()[1]], id), title = true } }
  for _, c in ipairs(choices) do
    items[#items + 1] = { text = format(c.tile and L["This tile: %s"] or L["Add: %s"], c.text), func = act(c) }
  end
  ns.Menu.Show(anchor, items)
  return true
end

local function readingItems(board, look, anchor)
  local byTracker, order, unused = {}, {}, {}
  for _, rid in ipairs(ns.allReadingOrder) do
    local r = ns.readings[rid]
    local tid = r.tracker or "other"
    if not byTracker[tid] then byTracker[tid] = {}; order[#order + 1] = tid end
    local list = byTracker[tid]
    if not ns.ReadingApplies(r) then
      -- (HC-28) not used by this character: last, in a submenu of their own, still addable (another character)
      unused[tid] = unused[tid] or {}
      list = unused[tid]
    end
    if ns.NeedsArg(r) then
      -- a reading with a parameter: choose the member next (a set reading starts with its default: HC-60)
      list[#list + 1] = { text = ns.ReadingTitle(r, nil), tip = r.description, func = function()
        Boards.MemberMenu(anchor, rid, function(arg) addReading(board, rid, look, arg) end)
      end }
    else
      list[#list + 1] = { text = r.title, tip = r.description, func = function() addReading(board, rid, look) end }
    end
  end
  local items = {}
  for _, tid in ipairs(order) do
    local t = HC:GetTracker(tid)
    local label = t and (t.title .. (t.on and "" or ("  |cff808080" .. L["(off)"] .. "|r"))) or L["Other"]
    local sub = byTracker[tid]
    if unused[tid] then sub[#sub + 1] = { text = L["Not used by this character"], sub = unused[tid] } end
    items[#items + 1] = { text = label, sub = sub }
  end
  return items
end

function Boards.AddMenu(anchor, board)
  local items = readingItems(board, nil, anchor)
  items[#items + 1] = { text = L["Splits"], func = function() M.AddTile(board, "splits"); Boards.Refresh(board.id, true) end }
  items[#items + 1] = { text = L["Heading"], func = function()
    askText(L["Heading text"], "", function(s)
      M.AddTile(board, "label", { text = s ~= "" and s:sub(1, 40) or L["Heading"] })
      Boards.Refresh(board.id, true)
    end)
  end }
  -- HC-42 b: "New board" lives here now (and on the launcher's right-click and in Options), not on a toolbar
  items[#items + 1] = { text = L["New board"], sub = Boards.NewBoardItems(),
    tip = L["Another board: from a preset, or empty to fill yourself"] }
  ns.Menu.Show(anchor, items)
end

--- "Move to": the other boards, then a new one (DESIGN §16.8). The tile keeps its settings; on the board's timer it
--- reads its new board's period.
local function moveItems(board, i)
  local sub = {}
  local function go(target)
    return function()
      local _, now = M.MoveTo(board, i, target)
      Boards.Refresh(board.id, true)
      if now then Boards.Reveal(now, now.tiles[#now.tiles]) end
    end
  end
  for _, b in ipairs(M.MoveTargets(board)) do
    sub[#sub + 1] = { text = b.name .. (b.shown and "" or ("  |cff808080" .. L["(hidden)"] .. "|r")), func = go(b) }
  end
  sub[#sub + 1] = { text = L["New board"], tip = L["A board of its own, with its own timer: to pause this tile alone."],
    func = go(nil) }
  return sub
end

-- The words of the tile menu's Show as, Display and Size (HC-51; the names are the user's call in HC-39(e))
local CALC_NAME = { total = "Total", perHour = "Per hour", recent = "Recent", trend = "Trend" }
local CALC_TIP = { total = "Everything counted over the period.", perHour = "The total divided by your active hours in the period (AFK doesn't count).",
  recent = "Your pace now: per hour, with the last few minutes counting most (half of it is the last 5 minutes).",
  trend = "Your pace now against your average over this period: faster, slower, or on pace (within 10%)." }
local CALC_WHY = { display = "not on this display", scope = "needs the board's timer or session", account = "this character only",
  zone = "not for one zone" }
local DISPLAY_NAME = { number = "Number", bar = "Bar", gauge = "Gauge", odometer = "Odometer", mix = "Mix" }
local DISPLAY_TIP = { number = "The number itself.", bar = "A bar filling toward a target.",
  gauge = "A half dial of dots filling toward a target.",
  odometer = "Rolling digits, like a car's odometer. The total only.",
  mix = "One bar split by kind: each part's share of the total, largest first." }
local SIZE_NAME = { large = "Big", half = "Half width", line = "Line" }
local SIZE_TIP = { large = "A big number with the last 10 minutes and how you usually do here.",
  half = "Two side by side.", line = "One line, full width." }

--- A reading tile's settings (what it counts, its scope, calc, display, size, target, name) as menu items: the
--- board's tile menu and the Overview tab's Edit (HC-67) share them. board: the tile's board, or nil for a tile that
--- is Window only (then no Size: a size is the board's). A choice redraws the board and the Overview tab.
function Boards.TileSettingsItems(tile, board, anchor)
  local items = {}
  local function done()
    if board then Boards.Refresh(board.id, true) end
    if ns.RefreshOverview then ns.RefreshOverview() end
  end
  if tile.kind == "reading" then
    items[#items + 1] = { text = L["Counts"], sub = {
      { text = L["this character"], checked = tile.who ~= "account",
        func = function() M.SetWho(tile, nil, board); done() end },
      { text = L["the whole account"], checked = tile.who == "account",
        tip = L["Every character of this account. The board's timer counts whoever is logged in; periods need history "
          .. "on each character; amounts you own are the sum of what each last had."],
        func = function() M.SetWho(tile, "account", board); done() end },
    } }
    local rdef = ns.readings[tile.reading]
    if rdef and rdef.param and rdef.param.multi then
      -- (HC-60) the tile's filter: the reading's presets, then a checklist of its members
      local sub, cur = {}, M.TileSet(tile)
      local inSet = {}
      for _, m in ipairs(cur or {}) do inSet[m] = true end
      for _, ps in ipairs(rdef.param.presets or {}) do
        sub[#sub + 1] = { text = ps.name, checked = ns.SameSet(ps.members, cur), func = function()
          M.SetArg(tile, ps.members, board); done()
        end }
      end
      local choices = M.SetChoices(tile.reading)
      if #choices > 0 and #sub > 0 then sub[#sub + 1] = { text = L["Or tick each:"], disabled = true } end
      for _, c in ipairs(choices) do
        sub[#sub + 1] = { text = c.label, checked = inSet[c.arg] or false, func = function()
          if not M.ToggleMember(tile, c.arg, board) then ns.Print(L["A filter keeps at least one kind."]) end
          done()
        end }
      end
      if #sub == 0 then sub[1] = { text = L["Nothing counted yet"], disabled = true } end
      items[#items + 1] = { text = format(L["Includes: %s"], ns.MemberLabel(rdef, tile.arg)), sub = sub }
    elseif rdef and rdef.param then
      items[#items + 1] = { text = format(L["Showing: %s (change)"], ns.MemberLabel(rdef, tile.arg)), func = function()
        Boards.MemberMenu(anchor, tile.reading, function(arg) M.SetArg(tile, arg, board); done() end, tile.arg)
      end }
    end
    local scopes = {}
    for _, c in ipairs(M.ScopeChoices(tile, board)) do
      local word = c.scope == "run" and L["the board's timer"] or c.scope
      -- (HC-55) the board's own scope: picking it makes the tile follow the board
      if c.board and c.scope ~= "run" then word = word .. "  (" .. L["the board's"] .. ")" end
      local item = { text = word .. (c.ok and "" or ("  (" .. L["needs history"] .. ")")), checked = tile.scope == c.scope,
        func = function() M.SetScope(tile, c.scope, board); done() end, disabled = not c.ok }
      if not c.ok then
        local r = ns.readings[tile.reading]
        local tr = r and r.tracker and HC:GetTracker(r.tracker)
        item.onDisabled = tr and function()
          confirm(format(L["Turn on daily history for %s? History starts now; nothing before today can be filled in."],
            tr.title), function()
            HC:SetTrackerHistory(tr.id, "daily")
            M.SetScope(tile, c.scope, board)
            done()
          end)
        end or nil
      end
      scopes[#scopes + 1] = item
    end
    items[#items + 1] = { text = L["Scope"], sub = scopes }
    -- (HC-51, DESIGN §16.9) which number, drawn how, how big. Names are placeholders until HC-39(e).
    local calcs = {}
    local curCalc = M.TileCalc(tile)
    for _, c in ipairs(M.CalcChoices(tile)) do
      calcs[#calcs + 1] = { text = L[CALC_NAME[c.calc] or c.calc] .. (c.ok and "" or ("  (" .. L[CALC_WHY[c.why] or "not here"] .. ")")),
        tip = L[CALC_TIP[c.calc] or ""], checked = curCalc == c.calc, disabled = not c.ok,
        func = function() M.SetCalc(tile, c.calc); done() end }
    end
    if #calcs > 1 then items[#items + 1] = { text = L["Show as"], sub = calcs } end
    local displays = {}
    local curDisplay = M.TileDisplay(tile)
    for _, d in ipairs(M.DISPLAY_ORDER) do
      displays[#displays + 1] = { text = L[DISPLAY_NAME[d]], tip = L[DISPLAY_TIP[d]], checked = curDisplay == d, func = function()
        if M.NEEDS_TARGET[d] and not M.TileTarget(tile) then
          -- no empty bars or dials (statement 17b): ask what toward; cancelling keeps the old display
          local money = ns.readings[tile.reading] and ns.readings[tile.reading].formatter == "money"
          local ask = money and L["%s toward (gold):"] or L["%s toward:"]
          askText(format(ask, L[DISPLAY_NAME[d]]), "", function(typed)
            M.SetTarget(tile, typed)
            if M.TileTarget(tile) then M.SetDisplay(tile, d) end
            done()
          end)
          return
        end
        M.SetDisplay(tile, d)
        done()
      end }
      -- (HC-63) only the displays that fit the reading (an odometer counts, a mix needs members)
      if not M.DisplayFits(tile, d) then displays[#displays] = nil end
    end
    items[#items + 1] = { text = L["Display"], sub = displays }
    local sizeList = M.SizeChoices(tile)
    if board and #sizeList > 1 then
      local sizes = {}
      local curSize = M.TileSize(tile)
      for _, s in ipairs(sizeList) do
        sizes[#sizes + 1] = { text = L[SIZE_NAME[s]], tip = L[SIZE_TIP[s]], checked = curSize == s,
          func = function() M.SetSize(tile, s); done() end }
      end
      items[#items + 1] = { text = L["Size"], sub = sizes }
    end
    if M.TrendBadgeFits(tile) then
      items[#items + 1] = { text = L["Trend badge"], checked = M.HasExtra(tile, "trend"),
        tip = L["Beside the big number: your pace now against this period's average (green up, red down)."],
        func = function() M.SetExtra(tile, "trend", not M.HasExtra(tile, "trend")); done() end }
    end
    local tgt = M.TileTarget(tile)
    local tdef = ns.readings[tile.reading]
    items[#items + 1] = { text = tgt and format(L["Target: %s (change)"], ns.FormatReading(tdef or {}, tgt, M.TileCalc(tile))) or L["Set a target..."],
      tip = L["A goal for this tile. The bar and gauge displays draw the number toward it."], func = function()
        local money = tdef and tdef.formatter == "money"
        askText(money and L["Target in gold (empty: none)"] or L["Target (empty: none)"], "", function(s)
          M.SetTarget(tile, s)
          done()
        end)
      end }
    items[#items + 1] = { text = L["Rename"], func = function()
      askText(L["Tile name (empty: the reading's)"], tile.name or "", function(s)
        tile.name = s ~= "" and s:sub(1, 40) or nil
        done()
      end)
    end }
  end
  return items
end

function Boards.TileMenu(anchor, board, i)
  local tile = board.tiles[i]
  if not tile then return end
  local items = Boards.TileSettingsItems(tile, board, anchor)
  if tile.kind == "label" then
    items[#items + 1] = { text = L["Rename"], func = function()
      askText(L["Heading text"], tile.text or "", function(s) tile.text = s:sub(1, 40); Boards.Refresh(board.id, true) end)
    end }
  end
  items[#items + 1] = { text = L["Move up"], disabled = i == 1, func = function() M.MoveTile(board, i, -1); Boards.Refresh(board.id, true) end }
  items[#items + 1] = { text = L["Move down"], disabled = i == #board.tiles,
    func = function() M.MoveTile(board, i, 1); Boards.Refresh(board.id, true) end }
  items[#items + 1] = { text = L["Move to"], sub = moveItems(board, i) }
  -- (HC-67) a reading tile leaves the board but stays in the collection (the Overview tab); a heading just goes
  local reading = tile.kind == "reading"
  items[#items + 1] = { text = reading and L["Remove from board"] or L["Remove"],
    tip = reading and L["It stays in the Overview tab (Window only), from where you can put it back."] or nil,
    func = function()
      M.RemoveTile(board, i)
      Boards.Refresh(board.id, true)
      if ns.RefreshOverview then ns.RefreshOverview() end
    end }
  ns.Menu.Show(anchor, items)
end

local function showItems(board)
  local s = board.show
  local function set(k, v) return function() s[k] = v; Boards.Refresh(board.id) end end
  return {
    { text = L["In combat"], sub = {
      { text = L["show"], checked = s.combat == "show", func = set("combat", "show") },
      { text = L["fade"], checked = s.combat == "fade", func = set("combat", "fade") },
      { text = L["hide"], checked = s.combat == "hide", func = set("combat", "hide") },
    } },
    { text = L["In instances"], sub = {
      { text = L["show"], checked = s.instance ~= "hide", func = set("instance", "show") },
      { text = L["hide"], checked = s.instance == "hide", func = set("instance", "hide") },
    } },
    { text = L["Only while a run is open"], checked = s.runOnly, func = set("runOnly", not s.runOnly) },
    { text = L["Faded until the mouse is over it"], checked = s.mouseoverFade, func = set("mouseoverFade", not s.mouseoverFade) },
  }
end

--- The board's timer: Pause / Resume / Start again, Stop, Reset, Save as run (empty when no tile is on it).
function Boards.AllItems(board)
  local items = {}
  local st = M.BoardState(board)
  if not st then return items end
  if st == "running" then
    items[#items + 1] = { text = L["Pause"], func = function() controlAll(board, "pause") end }
  else
    items[#items + 1] = { text = st == "paused" and L["Resume"] or L["Start again from zero"],
      func = function() controlAll(board, "start") end }
  end
  items[#items + 1] = { text = L["Stop (freeze the numbers)"], disabled = st == "stopped",
    func = function() controlAll(board, "stop") end }
  items[#items + 1] = { text = L["Reset (from zero)"], func = function() controlAll(board, "reset") end }
  local which = M.BoardSavable(board)
  items[#items + 1] = { text = which == "prev" and L["Save the last period as a run"] or L["Save as run"],
    disabled = not which, tip = L["One record in the Runs tab for this board: every counter. Needs 5 active minutes."],
    func = function() saveBoard(board) end }
  return items
end

local SCOPE_MENU_TIP = {
  run = "Its own clock, with Pause, Reset and Save as run.",
  session = "Since you logged in on this character.",
}

--- The board's scope (HC-55): following tiles move with it; tiles set to another scope keep theirs. A calendar
--- scope whose tiles keep no history is greyed; clicking it offers to turn their history on.
function Boards.ScopeItems(board)
  local items = {}
  local cur = M.BoardScope(board)
  for _, c in ipairs(M.BoardScopeChoices(board)) do
    local word = c.scope == "run" and L["the board's timer"] or L[c.scope]
    local item = { text = word .. (c.ok and "" or ("  (" .. L["needs history"] .. ")")), checked = cur == c.scope,
      tip = SCOPE_MENU_TIP[c.scope] and L[SCOPE_MENU_TIP[c.scope]] or nil, disabled = not c.ok,
      func = function() M.SetBoardScope(board, c.scope); Boards.RefreshAll(true) end }
    if not c.ok then
      local titles = {}
      for _, id in ipairs(c.trackers) do
        local tr = HC:GetTracker(id)
        titles[#titles + 1] = tr and tr.title or id
      end
      item.onDisabled = function()
        confirm(format(L["Turn on daily history for %s? History starts now; nothing before today can be filled in."],
          table.concat(titles, ", ")), function()
          for _, id in ipairs(c.trackers) do HC:SetTrackerHistory(id, "daily") end
          M.SetBoardScope(board, c.scope)
          Boards.RefreshAll(true)
        end)
      end
    end
    items[#items + 1] = item
  end
  return items
end

function Boards.BoardMenu(anchor, board)
  local items = { { text = board.name, title = true } }
  for _, item in ipairs(Boards.AllItems(board)) do items[#items + 1] = item end
  items[#items + 1] = { text = L["Scope"], sub = Boards.ScopeItems(board) }
  for _, item in ipairs({
    { text = L["Mini mode (one line)"], checked = board.mini, func = function()
      board.mini = not board.mini
      Boards.Refresh(board.id, true)
    end },
    { text = L["Visibility"], sub = showItems(board) },
    { text = L["Rename"], func = function()
      askText(L["Board name"], board.name, function(s) if s ~= "" then board.name = s:sub(1, 32); Boards.Refresh(board.id, true) end end)
    end },
    { text = L["Hide this board"], func = function() board.shown = false; Boards.Refresh(board.id) end },
    { text = L["Delete this board"], func = function()
      confirm(format(L["Delete the board %s? Its tiles stay in the Overview tab; your counts don't change."], board.name), function()
        M.Delete(board.id)
        Boards.RefreshAll()
      end)
    end },
  }) do items[#items + 1] = item end
  ns.Menu.Show(anchor, items)
end

function Boards.StripMenu(anchor, board)
  local items = Boards.AllItems(board)
  items[#items + 1] = { text = L["Full board"], func = function() board.mini = false; Boards.Refresh(board.id, true) end }
  items[#items + 1] = { text = L["Edit this board"], func = function() Boards.EditBoard(board.id, true) end }
  ns.Menu.Show(anchor, items)
end

--- A new board from a preset, or an empty one (presetKey nil), which opens in edit mode: it has nothing to show
--- until the player adds to it.
function Boards.NewBoard(presetKey)
  local b = presetKey and M.Create(presetKey) or M.Create(nil, { name = L["Board"] })
  if not presetKey and b then editIds[b.id] = true; Boards.SyncEscape() end
  Boards.RefreshAll(true)
  return b
end

--- The presets, then "Empty board" (the + menu's and the launcher's "New board" submenu).
function Boards.NewBoardItems()
  local items = {}
  for _, key in ipairs(M.PRESET_ORDER) do
    items[#items + 1] = { text = M.PRESETS[key].name, func = function() Boards.NewBoard(key) end }
  end
  items[#items + 1] = { text = L["Empty board"], tip = L["Opens for editing: add numbers with its [+]"],
    func = function() Boards.NewBoard(nil) end }
  return items
end

function Boards.NewBoardMenu(anchor) ns.Menu.Show(anchor, Boards.NewBoardItems()) end

--- The launcher's right-click (minimap button, AddOns menu, a bar's feed; HC-42 b): new board, edit, options.
function Boards.LauncherItems()
  local items = { { text = L["New board"], sub = Boards.NewBoardItems() } }
  if anyEditing() then
    items[#items + 1] = { text = L["Stop editing boards"], func = function() Boards.SetEditing(false) end }
  else
    items[#items + 1] = { text = L["Edit every board"], func = function() Boards.SetEditing(true) end }
  end
  items[#items + 1] = { text = L["Options"], func = function() if ns.OpenOptions then ns.OpenOptions() end end }
  return items
end

---------------------------------------------------------------------------
-- Showing boards (commands, launcher)
---------------------------------------------------------------------------

local function findBoard(key)
  local list = M.Store().list
  local n = tonumber(key)
  if n then return list[n] end
  key = (key or ""):lower()
  for _, b in ipairs(list) do if b.name:lower() == key or (b.preset or "") == key then return b end end
  return nil
end

--- Show or hide a board by preset key, creating it from the preset if the player has none.
function Boards.TogglePreset(key, show)
  local b = findBoard(key)
  if not b then
    b = M.Create(key)
    if key == "run" then M.Store().runBoard = true end
    show = true
  end
  if show == nil then show = not b.shown end
  b.shown = show and true or false
  Boards.Refresh(b.id, true)
  return b
end

--- All boards on or off (the launcher's shift-click).
function Boards.ToggleAll()
  local list = M.Store().list
  local any = false
  for _, b in ipairs(list) do if b.shown then any = true end end
  for _, b in ipairs(list) do b.shown = not any end
  if #list == 0 then Boards.TogglePreset("pocket", true) end
  Boards.RefreshAll(true)
end
ns.ToggleBoards = Boards.ToggleAll

ns.AddSlash("board", function(rest)
  local cmd, arg = (rest or ""):match("^(%S*)%s*(.*)$")
  local list = M.Store().list
  if cmd == "" then
    for i, b in ipairs(list) do
      ns.Print("%d. %s%s%s", i, b.name, b.shown and "" or (" (" .. L["hidden"] .. ")"), b.mini and (" (" .. L["mini"] .. ")") or "")
    end
    ns.Print(L["/hc board <n> | new run|pocket|leveling | mini <n> | reset"])
  elseif cmd == "new" then
    local key = M.PRESETS[arg] and arg or nil
    M.Create(key, { name = (not key and arg ~= "") and arg or nil })
    Boards.RefreshAll()
  elseif cmd == "mini" then
    local b = findBoard(arg ~= "" and arg or "1")
    if b then b.mini = not b.mini; Boards.Refresh(b.id, true) end
  elseif cmd == "reset" then
    confirm(L["Delete every board and start again from the Pocket board?"], function()
      local B = M.Store()
      while B.list[1] do M.Delete(B.list[1].id, true) end   -- their windows and their tiles go with them
      B.list, B.seeded, B.runBoard, B.lastEdited = {}, nil, nil, nil   -- lastEdited: an old field (HC-36)
      M.Seed()
      Boards.RefreshAll(true)
    end)
  else
    local b = findBoard(cmd)
    if b then b.shown = not b.shown; Boards.Refresh(b.id, true) else ns.Print(L["no such board: %s"], cmd) end
  end
end, L["list boards, show or hide one, add one from a preset"])

ns.AddSlash("edit", function() Boards.SetEditing(not anyEditing()) end, L["edit every board (Escape or Done to leave)"])
-- the commands of the panels boards replace (§6.4)
ns.AddSlash("panel", function(rest)
  local arg = (rest or ""):lower():match("^%s*(%S*)")
  local b = Boards.TogglePreset("run", (arg == "compact" or arg == "full") and true or nil)
  if arg == "compact" or arg == "full" then b.mini = arg == "compact"; Boards.Refresh(b.id, true) end
end, L["show or hide the Run board (compact | full: its mini mode)"])
ns.AddSlash("live", function() Boards.TogglePreset("pocket") end, L["show or hide the Pocket board"])
function ns.ShowRunPanel(show) Boards.TogglePreset("run", show) end
function HC:ToggleRunPanel() Boards.TogglePreset("run") end

---------------------------------------------------------------------------
-- Events: login, runs, combat, zones, readings, profiles
---------------------------------------------------------------------------

local function updateState()
  state.combat = ns.wow.inCombat()
  local kind = ns.wow.instanceType()
  state.instance = kind ~= nil and kind ~= "none"
end

ns.On("PLAYER_ENTERING_WORLD", function()
  if not ns.ready then return end
  M.Seed()
  updateState()
  Boards.RefreshAll(true)
end, "Boards")
ns.On("PLAYER_REGEN_DISABLED", function() state.combat = true; Boards.RefreshAll() end, "Boards")
ns.On("PLAYER_REGEN_ENABLED", function() state.combat = false; Boards.RefreshAll() end, "Boards")

local owner = {}
local function onRun(event)
  if event == "HC_RUN_STOPPED" then compareCache = {} end
  Boards.RefreshAll()
end
for _, ev in ipairs({ "HC_RUN_STARTED", "HC_RUN_STOPPED", "HC_RUN_PAUSED", "HC_RUN_RESUMED", "HC_RUN_SPLIT" }) do
  HC.RegisterCallback(owner, ev, onRun)
end
HC.RegisterCallback(owner, "HC_ZONE_CHANGED", function() compareCache = {}; updateState(); Boards.RefreshAll() end)
HC.RegisterCallback(owner, "HC_TRACKERS_CHANGED", function() Boards.RefreshAll() end)

-- packs register readings after Hard Counters drew its boards (the run panel's "install a pack" lesson)
local previousReadings = ns.OnReadingsChanged
function ns.OnReadingsChanged()
  if previousReadings then previousReadings() end
  if ns.ready and ns.settings and ns.settings.boards then
    M.FoldAliases()          -- a pack's alias (HC-51): its saved tiles read the target with the alias's calc
    Boards.RefreshAll(true)
  end
end

-- a profile switch replaces ns.settings: other boards
local previous = ns.OnSettingsChanged
function ns.OnSettingsChanged()
  if previous then previous() end
  if not ns.ready then return end
  for _, f in pairs(frames) do f:Hide(); if f.fly then f.fly:Hide() end; Boards.Tick(f, nil); f.placed = nil end
  M.Seed()
  Boards.RefreshAll(true)
end

-- BlizzMove (Ctrl+wheel) scales are kept
ns.On("PLAYER_LOGOUT", function()
  if not ns.settings or type(ns.settings.boards) ~= "table" then return end
  for id, f in pairs(frames) do
    local b = M.Get(id)
    if b and f.GetScale then b.scale = f:GetScale() end
  end
end, "Boards")

---------------------------------------------------------------------------
-- Options
---------------------------------------------------------------------------

ns.AddOptions("boards", function()
  local args = {
    intro = { type = "description", order = 0, fontSize = "medium",
      name = L["Boards are your on-screen numbers. Hover a board and click Edit above it to change it; /hc edit edits every board."] },
    edit = { type = "execute", order = 1, name = L["Edit every board"], func = function() Boards.SetEditing(true) end },
    -- HC-42 b: "New board" moved here from the old edit toolbar
    new = { type = "select", order = 2, name = L["New board"],
      desc = L["Another board: from a preset, or empty to fill yourself"],
      values = function()
        local v = { [""] = L["Empty board"] }
        for _, key in ipairs(M.PRESET_ORDER) do v[key] = M.PRESETS[key].name end
        return v
      end,
      get = function() return nil end,
      set = function(_, key) Boards.NewBoard(key ~= "" and key or nil) end },
  }
  for i, b in ipairs(M.Store().list) do
    args["shown" .. i] = { type = "toggle", order = 10 + i * 2, name = format(L["Show %s"], b.name),
      get = function() return b.shown end, set = function(_, v) b.shown = v; Boards.Refresh(b.id, true) end }
    args["mini" .. i] = { type = "toggle", order = 11 + i * 2, name = L["mini mode"],
      get = function() return b.mini end, set = function(_, v) b.mini = v; Boards.Refresh(b.id, true) end }
  end
  return { type = "group", name = L["Boards"], inline = true, args = args }
end)

-- An item on the cursor: boards take the drop without edit mode (HC-34), and go click-through again when the
-- cursor is empty. (CURSOR_CHANGED fires on Forever: probed 2026-11-18. If it ever doesn't, edit mode still makes
-- tiles take the drop.)
ns.On("CURSOR_CHANGED", function()
  local now = ns.wow.cursorItem() ~= nil
  if now == holding then return end
  holding = now
  for _, f in pairs(frames) do setMouse(f) end
end, "Boards")

-- Values redraw when they change (DESIGN 16.6, HC-33): a write marks ns.dirty (Registry.lua, and the refresh
-- events of computed readings); the next frame redraws the boards, at most four times a second. Tickers stay for
-- rates and clocks, which move without a write.
local DIRTY_GAP = 0.25
local sinceDraw = DIRTY_GAP

--- One frame passed. Returns true when it redrew.
function Boards.OnFrame(elapsed)
  sinceDraw = sinceDraw + (elapsed or 0)
  if not ns.dirty or sinceDraw < DIRTY_GAP then return false end
  ns.dirty = false
  sinceDraw = 0
  for id in pairs(frames) do
    local ok, err = pcall(Boards.Refresh, id)
    if not ok then ns.Error(err) end
  end
  return true
end

local hoverBroken = false
local watcher = CreateFrame("Frame")
watcher:SetScript("OnUpdate", function(_, elapsed)
  Boards.OnFrame(elapsed)
  if hoverBroken then return end
  local ok, err = pcall(Boards.Hover, elapsed)   -- the edit handles (HC-42): ten times a second
  if not ok then hoverBroken = true; ns.Error(err) end   -- once, not every frame; edit mode stays on /hc edit
end)
