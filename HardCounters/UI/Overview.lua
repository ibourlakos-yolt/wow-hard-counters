-- Overview (DESIGN §17.4, HC-67, HC-73; v8, the user 2026-11-25): the player's boards and tiles, the first tab of
-- the Hard Counters window, and the place where they are made. One framed panel per board (in the Boards tab's
-- order, an empty board too), headed by the board's name and status, a switch that puts the board on the HUD or keeps
-- it "Only here", and "+ Tile" (the reading picker, by tracker). Its tiles are cards in the board's order: the
-- tile's label, its number now, its scope. A tile kept off the HUD (while its board may be on it) has a dashed card.
-- There are no tiles without a board any more: "Window only" is gone (BoardModel v8 moved those to a board called
-- "Unsorted", whose panel says so).
-- Click a card: Edit (the same choices as on a board), On HUD (that tile), Move to board, Delete tile. Click a
-- board's name: that board's actions, as on its Boards tab row. New board... (top right) opens the New board dialog.
-- Search: a tile's label or its board's name. Cards refresh once a second while the tab is on screen; the tab is as
-- tall as its cards (the window scrolls it, HC-69).
-- luacheck: no max line length (tips and empty-state prose: one sentence, one string)
local ADDON, ns = ...

local HC, L, Wd = ns.HC, ns.L, ns.Widgets
local format, floor, max = string.format, math.floor, math.max

local ID = "overview"
local TOP_H, HEAD_H, CARD_H, CARD_MIN_W, GAP, PAD = 34, 26, 58, 176, 6, 8
local INSET, GROUP_GAP, LINE_H = 8, 10, 20       -- a board panel's inner margin, the space between groups, a text line
local MIN_W, MIN_H = 600, 360
local BOARD_ICON, TAB_ICON = "Interface\\Icons\\INV_Misc_Map_01", "Interface\\Icons\\INV_Misc_Note_01"
local DASH = "Interface\\AddOns\\HardCounters\\Media\\Dash"    -- 8x8, white where x < 5 and y < 5 (tools/draw-dash.py)
local content
local cards, panels = {}, {}
local search = ""
local contentH = MIN_H
local ticker

local M = function() return ns.BoardModel end
local Bo = function() return ns.Boards end

local refresh

---------------------------------------------------------------------------
-- Menus
---------------------------------------------------------------------------

local function confirm(text, fn) if Bo() and Bo().Confirm then Bo().Confirm(text, fn) else fn() end end

local function redrawBoard(b) if b and Bo() then Bo().Refresh(b.id, true) end end

local function cardMenu(anchor, e)
  local BM = M()
  local label = BM.TileLabel(e.tile, e.board)
  local items = { { text = label, title = true } }
  local edit = Bo() and Bo().TileSettingsItems(e.tile, e.board, anchor) or {}
  if #edit > 0 then items[#items + 1] = { text = L["Edit"], sub = edit } end
  -- on the HUD or only here: this tile's own switch (its board has one too)
  local onHud = BM.TileOnHud(e.tile)
  items[#items + 1] = { text = L["On HUD"], checked = onHud,
    tip = e.board.shown and L["Off: this tile stays on its board here, still counting, but is not drawn on screen."]
      or L["Its board is not on your HUD yet: this decides whether the tile is drawn once it is."],
    func = function()
      BM.SetTileOnHud(e.tile, not onHud)
      redrawBoard(e.board)
      refresh()
    end }
  local move = {}
  for _, b in ipairs(BM.MoveTargets(e.board)) do
    move[#move + 1] = { text = b.shown and b.name or format(L["%s (Only here)"], b.name), func = function()
      local from = e.board
      local p = BM.Place(e.raw, b)
      redrawBoard(from)
      if p and Bo() then Bo().Reveal(b, p) end
      refresh()
    end }
  end
  move[#move + 1] = { text = L["New board"], tip = L["A board of its own, named after the tile; not on your HUD until you put it there."],
    func = function()
      local from, i = BM.BoardOf(e.tile)
      if from then
        local shown = from.shown
        from.shown = false                          -- (MoveTo gives a new board its old board's place on the HUD)
        BM.MoveTo(from, i, nil)
        from.shown = shown
        redrawBoard(from)
      end
      refresh()
    end }
  items[#items + 1] = { text = L["Move to board"], sub = move }
  items[#items + 1] = { text = L["Delete tile"], func = function()
    confirm(format(L["Delete the tile %s? Your counts don't change."], label), function()
      local b = e.board
      BM.DeleteTile(e.id)
      redrawBoard(b)
      refresh()
    end)
  end }
  ns.Menu.Show(anchor, items)
end

--- A board's header, clicked: the board's own actions, as on its row in the Boards tab.
local function boardMenu(anchor, board)
  if ns.BoardMenu then ns.BoardMenu(board, anchor, function() refresh() end) end
end

---------------------------------------------------------------------------
-- Drawing
---------------------------------------------------------------------------

--- Four 1-pixel edges around f: solid (r, g, b, a), or dashed with the Dash texture (texture coordinates set by
--- sizeDashes as the frame's size changes).
local function edges(f, layer, dashed, r, g, b, a)
  local out = {}
  for i, side in ipairs({ "TOP", "BOTTOM", "LEFT", "RIGHT" }) do
    local t = f:CreateTexture(nil, layer)
    if dashed then
      t:SetTexture(DASH, "REPEAT", "REPEAT")
      if i <= 2 then t:SetHorizTile(true) else t:SetVertTile(true) end
      t:SetVertexColor(r, g, b, a)
    else
      t:SetColorTexture(r, g, b, a)
    end
    if i <= 2 then
      t:SetPoint(side .. "LEFT", f, side .. "LEFT", 0, 0)
      t:SetPoint(side .. "RIGHT", f, side .. "RIGHT", 0, 0)
      t:SetHeight(1)
    else
      t:SetPoint("TOP" .. side, f, "TOP" .. side, 0, 0)
      t:SetPoint("BOTTOM" .. side, f, "BOTTOM" .. side, 0, 0)
      t:SetWidth(1)
    end
    out[i] = t
  end
  return out
end

local function sizeDashes(d, w, h)
  d[1]:SetTexCoord(0, w / 8, 0, 0.5)
  d[2]:SetTexCoord(0, w / 8, 0, 0.5)
  d[3]:SetTexCoord(0, 0.5, 0, h / 8)
  d[4]:SetTexCoord(0, 0.5, 0, h / 8)
end

local function showAll(list, on) for _, t in ipairs(list) do t:SetShown(on) end end

local function newCard(i)
  local c = CreateFrame("Button", nil, content)
  c:SetHeight(CARD_H)
  c:SetFrameLevel(content:GetFrameLevel() + 3)     -- above the board panels
  c:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  c.bg = c:CreateTexture(nil, "BACKGROUND")
  c.bg:SetAllPoints()
  local hl = c:CreateTexture(nil, "HIGHLIGHT")
  hl:SetAllPoints()
  hl:SetColorTexture(1, 1, 1, 0.07)
  c.dash = edges(c, "BORDER", true, 0.6, 0.6, 0.6, 0.9)
  c.label = c:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  c.label:SetPoint("TOPLEFT", 8, -6)
  c.label:SetPoint("TOPRIGHT", -8, -6)
  c.label:SetJustifyH("LEFT")
  c.label:SetWordWrap(false)
  c.value = c:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
  c.value:SetPoint("LEFT", 8, 0)
  c.value:SetPoint("RIGHT", -8, 0)
  c.value:SetJustifyH("LEFT")
  c.value:SetWordWrap(false)
  c.foot = c:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  c.foot:SetPoint("BOTTOMLEFT", 8, 6)
  c.foot:SetPoint("BOTTOMRIGHT", -8, 6)
  c.foot:SetJustifyH("LEFT")
  c.foot:SetWordWrap(false)
  c:SetScript("OnClick", function(self) if self.entry then cardMenu(self, self.entry) end end)
  c:SetScript("OnEnter", function(self)
    local e = self.entry
    if not (e and GameTooltip) then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(M().TileLabel(e.tile, e.board), 1, 1, 1)
    local r = ns.readings[e.raw.reading]
    if r and r.description then GameTooltip:AddLine(r.description, 0.8, 0.8, 0.8, true) end
    local onHud = e.board.shown and M().TileOnHud(e.tile)
    GameTooltip:AddLine(onHud and format(L["On your HUD, on the board %s."], e.board.name)
      or (e.board.shown and L["Only here: its board is on your HUD, this tile is kept off it."]
        or format(L["Only here: the board %s is not on your HUD."], e.board.name)), 0.6, 0.8, 0.6, true)
    GameTooltip:AddLine(L["Click: edit, on or off the HUD, move, delete."], 0.5, 0.5, 0.5, true)
    GameTooltip:Show()
  end)
  c:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
  cards[i] = c
  return c
end

--- A heading: an icon, a gold title, a note after it. A Button, so a board's can be clicked.
local function newHeading(parent)
  local h = CreateFrame("Button", nil, parent)
  h:SetHeight(HEAD_H)
  h.icon = h:CreateTexture(nil, "ARTWORK")
  h.icon:SetSize(16, 16)
  h.icon:SetPoint("LEFT", 2, 0)
  h.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  h.text = h:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  h.text:SetPoint("LEFT", h.icon, "RIGHT", 6, 0)
  h.text:SetJustifyH("LEFT")
  h.note = h:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  h.note:SetPoint("LEFT", h.text, "RIGHT", 10, 0)
  h.note:SetJustifyH("LEFT")
  return h
end

local HUD_W, ADD_W = 84, 64

--- A board's panel: a darker frame with a solid border; on top its heading (click: the board's actions) and, at the
--- right, the tile count, "+ Tile" and the HUD switch (its text says where the board is: "On HUD" or "Only here").
local function newPanel(i)
  local p = CreateFrame("Frame", nil, content)
  p:SetFrameLevel(content:GetFrameLevel() + 1)
  local bg = p:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  bg:SetColorTexture(0, 0, 0, 0.35)
  edges(p, "BORDER", false, 0.45, 0.45, 0.5, 0.9)
  p.hud = Wd.Button(p, L["Only here"], HUD_W, function(self)
    local b = self.board
    if not b then return end
    b.shown = not b.shown
    if Bo() then
      Bo().Refresh(b.id, true)
      if b.shown then Bo().Flash(b.id) end
    end
    if ns.RefreshBoardsTab then ns.RefreshBoardsTab() end
    refresh()
  end)
  p.hud:SetFrameLevel(p:GetFrameLevel() + 2)
  p.hud:SetPoint("TOPRIGHT", -INSET, -4)
  Wd.Tip(p.hud, function(self)
    local b = self.board
    if b and b.shown then return L["This board is on your HUD (your screen while you play). Click: keep it only here, in this window. It keeps counting."] end
    return L["This board is only here, in this window. Click: put it on your HUD (your screen while you play)."]
  end)
  p.add = Wd.Button(p, L["+ Tile"], ADD_W, function(self)
    if self.board and Bo() then Bo().AddReadingMenu(self, self.board) end
  end)
  p.add:SetFrameLevel(p:GetFrameLevel() + 2)
  p.add:SetPoint("RIGHT", p.hud, "LEFT", -4, 0)
  Wd.Tip(p.add, function() return L["Add a number to this board: pick it by tracker. It appears here at once, and on your HUD when the board is there."] end)
  p.count = p:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  p.count:SetPoint("RIGHT", p.add, "LEFT", -8, 0)
  p.count:SetJustifyH("RIGHT")
  local h = newHeading(p)
  h:SetFrameLevel(p:GetFrameLevel() + 1)
  h:SetPoint("TOPLEFT", INSET, -2)
  h:SetPoint("TOPRIGHT", -(INSET + HUD_W + 4 + ADD_W + 76), -2)     -- (room for the count, + Tile and the switch)
  h.icon:SetTexture(BOARD_ICON)
  h:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  h:SetScript("OnClick", function(self) if self.board then boardMenu(self, self.board) end end)
  h:SetScript("OnEnter", function(self)
    if not (self.board and GameTooltip) then return end
    GameTooltip:SetOwner(self, "ANCHOR_TOPLEFT")
    GameTooltip:SetText(self.board.name, 1, 1, 1)
    GameTooltip:AddLine(L["Click: this board's actions (as in the Boards tab)."], 0.5, 0.5, 0.5, true)
    GameTooltip:Show()
  end)
  h:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
  p.head = h
  p.empty = p:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  p.empty:SetPoint("TOPLEFT", INSET + 2, -(2 + HEAD_H + 2))
  p.empty:SetText(L["No tiles on this board yet: + Tile adds one."])
  -- the "Unsorted" board's own line (BoardModel v8): where its tiles came from
  p.info = p:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  p.info:SetPoint("TOPLEFT", INSET + 2, -(2 + HEAD_H + 2))
  p.info:SetPoint("TOPRIGHT", -INSET, -(2 + HEAD_H + 2))
  p.info:SetJustifyH("LEFT")
  p.info:SetWordWrap(false)
  p.info:SetText(L["These tiles were on no board (\"Window only\"). Every tile has a board now: move them, put this board on your HUD, or delete them."])
  panels[i] = p
  return p
end

local function scopeWord(tile)
  local s = tile.scope
  if s == "run" then return L["board timer"] end
  return s and L[s] or ""
end

--- The card's number: the tile's value as on its board (its board's timer), or toward its target for a bar or gauge.
local function fill(c, e, dashed, w)
  local BM = M()
  c.label:SetText(BM.TileLabel(e.tile, e.board))
  local ok, v, text, settled, state = pcall(BM.TileValue, e.tile, e.board)
  if not ok then text, settled = "?", false end
  if ok and BM.NEEDS_TARGET[BM.TileDisplay(e.tile)] and BM.TileTarget(e.tile) then
    local okP, _, ptext = pcall(BM.Progress, e.tile, e.board)
    if okP and ptext then text = ptext end
  end
  c.value:SetText(text or "-")
  if settled == false or state == "missing" or type(v) ~= "number" then c.value:SetTextColor(0.6, 0.6, 0.6)
  else c.value:SetTextColor(1, 1, 1) end
  c.foot:SetText(dashed and (scopeWord(e.raw) .. "  \194\183 " .. L["Only here"]) or scopeWord(e.raw))
  -- on the HUD with its board: a filled card; kept off the HUD (the tile's own switch): a faint card, dashed border
  if dashed then
    c.bg:SetColorTexture(0.08, 0.08, 0.1, 0.35)
    sizeDashes(c.dash, w, CARD_H)
  else
    c.bg:SetColorTexture(0.1, 0.1, 0.12, 0.9)
  end
  showAll(c.dash, dashed)
  c.dashed = dashed
  c.entry = e
end

local function has(s) return type(s) == "string" and s:lower():find(search, 1, true) ~= nil end

local function matches(e)
  if search == "" then return true end
  return has(M().TileLabel(e.tile, e.board)) or (e.board and has(e.board.name)) or false
end

function refresh()
  if not (content and content:IsShown() and M()) then return end
  local BM = M()
  local w = content:GetWidth()
  if type(w) ~= "number" or w < MIN_W then w = MIN_W end
  local inner = w - 2 * PAD - 2 * INSET                            -- the cards' width, in a panel
  local cols = max(1, floor((inner + GAP) / (CARD_MIN_W + GAP)))
  local cardW = floor((inner - (cols - 1) * GAP) / cols)
  local groups = BM.TilesByBoard()
  local unsorted = BM.Store().unsorted
  local y, nc, np, any = -TOP_H, 0, 0, false

  --- lay out cards from (x0, y0) down; returns the height used
  local function grid(list, x0, y0)
    for k, e in ipairs(list) do
      nc = nc + 1
      local c = cards[nc] or newCard(nc)
      local col, row = (k - 1) % cols, floor((k - 1) / cols)
      c:ClearAllPoints()
      c:SetPoint("TOPLEFT", content, "TOPLEFT", x0 + col * (cardW + GAP), y0 - row * (CARD_H + GAP))
      c:SetWidth(cardW)
      fill(c, e, not BM.TileOnHud(e.tile), cardW)
      c:Show()
    end
    local rows = floor((#list + cols - 1) / cols)
    return rows * CARD_H + max(0, rows - 1) * GAP
  end

  for _, g in ipairs(groups) do
    local b, list = g.board, g.entries
    if search ~= "" and not has(b.name) then
      local keep = {}
      for _, e in ipairs(list) do if matches(e) then keep[#keep + 1] = e end end
      list = keep
    end
    if search == "" or #list > 0 or has(b.name) then
      any = true
      np = np + 1
      local p = panels[np] or newPanel(np)
      local h = p.head
      h.board, p.hud.board, p.add.board = b, b, b
      h.text:SetText(b.name)
      h.note:SetText((ns.BoardStatusText and ns.BoardStatusText(b)) or "")
      p.hud:SetText(b.shown and L["On HUD"] or L["Only here"])
      p.count:SetText(format(#g.entries == 1 and L["%d tile"] or L["%d tiles"], #g.entries))
      local top = 2 + HEAD_H + 2
      local info = b.id == unsorted and #g.entries > 0
      p.info:SetShown(info)
      if info then top = top + LINE_H end
      local body = #list > 0 and grid(list, PAD + INSET, y - top) or LINE_H
      p.empty:SetShown(#list == 0)
      if #list == 0 and search ~= "" then p.empty:SetText(L["No tile here matches the search."])
      else p.empty:SetText(L["No tiles on this board yet: + Tile adds one."]) end
      local ph = top + body + INSET
      p:ClearAllPoints()
      p:SetPoint("TOPLEFT", content, "TOPLEFT", PAD, y)
      p:SetPoint("TOPRIGHT", content, "TOPRIGHT", -PAD, y)
      p:SetHeight(ph)
      p:Show()
      y = y - ph - GROUP_GAP
    end
  end
  for i = np + 1, #panels do
    local p = panels[i]
    p:Hide()
    p.head.board, p.hud.board, p.add.board = nil, nil, nil
  end
  for i = nc + 1, #cards do cards[i]:Hide(); cards[i].entry = nil end
  -- a player who hasn't chosen packs yet is pointed at the Packs tab (once they have, the usual hint)
  content.hint:SetText((ns.Packs and not ns.Packs.Chosen()) and L["Packs tab: choose the packs you want"]
    or L["Click a tile or a board's name for its actions"])
  if #groups == 0 then
    content.empty:SetText(L["No boards yet. New board... (top right) makes your first one: a ready-made board, or an empty one to fill with + Tile. It stays here, in this window, until you put it on your HUD."])
    y = y - 3 * LINE_H
  else
    content.empty:SetText((search ~= "" and not any) and L["No tile or board matches the search."] or "")
  end
  -- the tab is as tall as its cards: the window scrolls it (HC-69)
  local h = max(MIN_H, floor(-y + PAD))
  if h ~= contentH then
    contentH = h
    ns.Windows.Relayout(ID)
  end
end
ns.RefreshOverview = refresh

local function build(f)
  content = f
  local s = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
  s:SetSize(200, 20)
  s:SetPoint("TOPLEFT", 14, -6)
  s:SetAutoFocus(false)
  s.hint = s:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  s.hint:SetPoint("LEFT", 2, 0)
  s.hint:SetText(L["Search your tiles or boards"])
  s:SetScript("OnTextChanged", function(self)
    local text = self:GetText() or ""
    self.hint:SetShown(text == "")
    search = text:lower()
    refresh()
  end)
  s:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  s:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
  f.search = s
  f.new = Wd.Button(f, L["New board..."], 110, function()
    if Bo() then Bo().OpenNewBoard() end
  end)
  f.new:SetPoint("TOPRIGHT", -8, -6)
  Wd.Tip(f.new, function() return L["Make a board: ready-made, empty, or a copy. It appears here; you choose whether it also goes on your HUD."] end)
  f.hint = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  f.hint:SetPoint("RIGHT", f.new, "LEFT", -10, 0)
  f.hint:SetText(L["Click a tile or a board's name for its actions"])
  f.empty = f:CreateFontString(nil, "OVERLAY", "GameFontDisable")
  f.empty:SetPoint("TOPLEFT", 20, -TOP_H - 4)
  f.empty:SetPoint("TOPRIGHT", -20, -TOP_H - 4)
  f.empty:SetJustifyH("LEFT")
  f:SetScript("OnSizeChanged", function() refresh() end)
end

ns.Windows.Register(ID, {
  title = L["Overview"], icon = TAB_ICON, tabOrder = 1,
  width = 720, height = 440, minWidth = MIN_W, minHeight = MIN_H,
  minSize = function() return MIN_W, contentH end,
  build = build,
  onShow = function()
    refresh()
    if ticker then ticker:Cancel() end
    ticker = C_Timer.NewTicker(1, refresh)
  end,
  onHide = function()
    if ticker then ticker:Cancel(); ticker = nil end
    if ns.Menu then ns.Menu.Hide() end
  end,
})

function ns.ShowOverview(show) ns.Windows.Show(ID, show) end
ns.OverviewCardMenu, ns.OverviewBoardMenu = cardMenu, boardMenu     -- (tests)
ns.OverviewPanels, ns.OverviewCards = panels, cards                  -- (tests)
ns.AddSlash("overview", function() ns.ShowOverview() end, L["your boards and their tiles: make them, put them on or off your HUD"])

-- a tile added or changed elsewhere (a board's menu, a pack's preset) shows here at the next second anyway; a
-- tracker switched on or off changes values at once
local owner = {}
HC.RegisterCallback(owner, "HC_TRACKERS_CHANGED", function() refresh() end)

-- This tab's help and tour (UI/Help.lua): change them with the tab.
local _ = ns.Help and ns.Help.Register(ID, {
  what = "Overview shows everything you follow: each board as a panel, each of its tiles as a card with its number now. It is also where boards and tiles are made. A board lives here first; it is on your HUD (your screen while you play) only when you put it there.",
  can = {
    "{New board...} (top right): a ready-made board, an empty one, or a copy. It starts here, off your HUD, unless you tick the HUD box.",
    "{+ Tile} on a board's panel: pick a number by tracker; it is added to that board at once.",
    "The switch beside it reads {On HUD} or {Only here}: click it to put the whole board on your screen or take it off.",
    "Click a card: {Edit} the tile, switch that one tile {On HUD} or off, {Move to board}, {Delete tile}.",
    "Click a board's name for its actions: rename, edit on screen, duplicate, delete.",
  },
  effect = "What is {On HUD} is drawn on your screen while you play; what is {Only here} keeps counting but stays in this window. A tile can be kept off the HUD while its board is on it: its card has a dashed border.",
  tour = {
    { title = "Boards are panels, tiles are cards", text = "Each framed panel is one of your boards; the cards in it are its tiles, with their numbers now. After the board's name you read where it is: on your HUD, or only here." },
    { title = "Make a board, add tiles", text = "{New board...} at the top right makes a board. On a board's panel, {+ Tile} lists every number you can add, by tracker. Nothing appears on your screen yet: it is all here." },
    { title = "On your HUD, or only here", text = "The button at the right of a board's panel says {On HUD} or {Only here}. Click it and the board goes on your screen, or comes off it. It counts either way." },
    { title = "One tile at a time", text = "Click a card for that tile's menu. {On HUD} there keeps a single tile off the screen while the rest of its board is shown: handy for a number you only check now and then." },
  },
})
