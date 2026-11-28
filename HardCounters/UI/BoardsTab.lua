-- The Boards tab (DESIGN §17.4, HC-67, HC-73; v8; renamed from "Overview" in 0.4.0, the user): the player's boards and
-- tiles, the first tab of the Hard Counters window, and the place where they are made. One framed panel per board (in
-- the boards' order, an empty board too), headed by the board's name, its status and its clock, then at the right its
-- tile count, "+ Tile" (the reading picker, by tracker), Pause or Start and Reset when the board is on its own timer
-- (0.4.0: the same as on the HUD), and the On HUD / Only here switch (a status pill, not a button: 0.4.0). Its tiles
-- are cards in the board's order: the tile's label, its number now (a bar or a gauge also as a thin strip toward its
-- target), its period. A tile kept off the HUD (while its board may be on it) has a dashed card.
-- Click a card: Edit (the same choices as on a board), On HUD (that tile), Move to board, Delete tile. Click a
-- board's name: every action of that board (UI/BoardCatalog.lua). New board... (top right) opens the New board dialog.
-- Under the last board a dashed panel says more boards can be made (0.4.0); a player who has chosen no packs is
-- reminded at the top. Search: a tile's label or its board's name. Cards refresh once a second while the tab is on
-- screen; the tab is as tall as its cards (the window scrolls it, HC-69). The panels' 1-pixel borders are drawn with
-- Widgets.Hairline (0.4.0: they vanished while scrolling at small UI scales).
-- luacheck: no max line length (tips and empty-state prose: one sentence, one string)
local ADDON, ns = ...

local HC, L, Wd = ns.HC, ns.L, ns.Widgets
local format, floor, max = string.format, math.floor, math.max

local ID = "boards"
local TOP_H, HEAD_H, CARD_H, CARD_MIN_W, GAP, PAD = 34, 26, 58, 176, 6, 8
local INSET, GROUP_GAP, LINE_H = 8, 10, 20       -- a board panel's inner margin, the space between groups, a text line
local MIN_W, MIN_H = 600, 360
local BOARD_ICON, TAB_ICON = "Interface\\Icons\\INV_Misc_Map_01", "Interface\\Icons\\INV_Misc_Map_01"
local NOTICE_H, FOOT_H = 30, 76                   -- the packs reminder at the top; the "more boards" panel at the end
local DISPLAY_CHIP = { bar = "bar", gauge = "gauge", odometer = "odometer", mix = "mix" }
local MIX_COLORS = { { 1, 0.82, 0 }, { 0.3, 0.8, 0.35 }, { 0.35, 0.6, 1 }, { 0.9, 0.4, 0.3 }, { 0.7, 0.5, 0.9 }, { 0.6, 0.6, 0.6 } }
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
  -- (0.5.0, G2) first: how its number is made
  items[#items + 1] = { text = L["How it's made"], tip = L["What it counts, over when, and how the number is worked out."],
    func = function() if ns.Synopsis then ns.Synopsis.Show(anchor, e.tile, e.board, "panel") end end }
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
    else
      t:SetPoint("TOP" .. side, f, "TOP" .. side, 0, 0)
      t:SetPoint("BOTTOM" .. side, f, "BOTTOM" .. side, 0, 0)
    end
    Wd.Hairline(t, i <= 2)
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
  c.label:SetPoint("TOPRIGHT", -44, -6)
  c.label:SetJustifyH("LEFT")
  c.label:SetWordWrap(false)
  c.value = c:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
  c.value:SetPoint("LEFT", 8, 3)
  c.value:SetPoint("RIGHT", -8, 3)
  c.value:SetJustifyH("LEFT")
  c.value:SetWordWrap(false)
  c.foot = c:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  c.foot:SetPoint("BOTTOMLEFT", 8, 6)
  c.foot:SetPoint("BOTTOMRIGHT", -8, 6)
  c.foot:SetJustifyH("LEFT")
  c.foot:SetWordWrap(false)
  -- (0.4.0) the tile's display on the card too: a chip naming it, and for a bar or a gauge a strip toward its
  -- target, for a mix one strip split by its parts (the user: "multiple display modes per tile in the overview layout")
  c.chip = c:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  c.chip:SetPoint("TOPRIGHT", -8, -7)
  c.chip:SetJustifyH("RIGHT")
  c.track = c:CreateTexture(nil, "ARTWORK")
  c.track:SetPoint("BOTTOMLEFT", 8, 19)
  c.track:SetPoint("BOTTOMRIGHT", -8, 19)
  c.track:SetHeight(4)
  c.track:SetColorTexture(1, 1, 1, 0.1)
  c.fill = c:CreateTexture(nil, "OVERLAY")
  c.fill:SetPoint("TOPLEFT", c.track, "TOPLEFT", 0, 0)
  c.fill:SetPoint("BOTTOMLEFT", c.track, "BOTTOMLEFT", 0, 0)
  c.parts = {}
  c:SetScript("OnClick", function(self) if self.entry then cardMenu(self, self.entry) end end)
  -- (0.5.0, G2) a small "?" at the top right: how the number is made, in a panel beside the card
  c.why = CreateFrame("Button", nil, c)
  c.why:SetSize(14, 14)
  c.why:SetPoint("TOPRIGHT", -4, -4)
  c.why:SetFrameLevel(c:GetFrameLevel() + 2)
  c.why.text = c.why:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  c.why.text:SetAllPoints()
  c.why.text:SetText("?")
  c.why:SetScript("OnEnter", function(self)
    self.text:SetTextColor(1, 0.82, 0)
    if GameTooltip then
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:SetText(L["How it's made"], 1, 1, 1)
      GameTooltip:AddLine(L["What it counts, over when, and how the number is worked out."], 0.8, 0.8, 0.8, true)
      GameTooltip:Show()
    end
  end)
  c.why:SetScript("OnLeave", function(self) self.text:SetTextColor(0.5, 0.5, 0.5); if GameTooltip then GameTooltip:Hide() end end)
  c.why:SetScript("OnClick", function(self)
    local e = self:GetParent().entry
    if e and ns.Synopsis then ns.Synopsis.Show(self:GetParent(), e.tile, e.board, "panel") end
  end)
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

local HUD_W, ADD_W, CLOCK_W = 84, 56, 54

--- A board's panel: a darker frame with a solid border; on top its heading (click: the board's actions) and, at the
--- right, the tile count, "+ Tile", Pause or Start and Reset (on its own timer), and the HUD switch: a status pill
--- whose lamp and word say where the board is ("On HUD" or "Only here").
local function newPanel(i)
  local p = CreateFrame("Frame", nil, content)
  p:SetFrameLevel(content:GetFrameLevel() + 1)
  local bg = p:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  bg:SetColorTexture(0, 0, 0, 0.35)
  edges(p, "BORDER", false, 0.45, 0.45, 0.5, 0.9)
  p.hud = Wd.Status(p, HUD_W, function(self)
    local b = self.board
    if not b then return end
    b.shown = not b.shown
    if Bo() then
      Bo().Refresh(b.id, true)
      if b.shown then Bo().Flash(b.id) end
    end
    if ns.RefreshExplorer then ns.RefreshExplorer() end
    refresh()
  end)
  p.hud:SetFrameLevel(p:GetFrameLevel() + 2)
  p.hud:SetPoint("TOPRIGHT", -INSET, -4)
  Wd.RichTip(p.hud, function(self)
    local b = self.board
    local on = b and b.shown
    return { title = L["On your HUD, or only here"], on = on and true or false,
      state = on and L["Now: on your HUD (your screen while you play)"] or L["Now: only here, in this window"],
      text = L["The board counts either way; this only decides whether it is drawn on your screen."],
      click = on and L["Click: keep it only here."] or L["Click: put it on your HUD."] }
  end)
  -- the board's clock, as on the HUD (0.4.0): Pause or Start, and Reset; only while the board is on its own timer
  p.reset = Wd.Button(p, L["Reset"], CLOCK_W, function(self)
    if self.board and Bo() then Bo().Control(self.board, "reset"); refresh() end
  end)
  p.reset:SetFrameLevel(p:GetFrameLevel() + 2)
  p.reset:SetPoint("RIGHT", p.hud, "LEFT", -4, 0)
  Wd.RichTip(p.reset, function() return { title = L["Reset"],
    text = L["The board's clock and its tiles start from zero. Real play since the last start is saved as a run first."],
    click = L["Click: reset now."] } end)
  p.pause = Wd.Button(p, L["Pause"], CLOCK_W, function(self)
    if self.board and Bo() then Bo().ToggleTimer(self.board); refresh() end
  end)
  p.pause:SetFrameLevel(p:GetFrameLevel() + 2)
  p.pause:SetPoint("RIGHT", p.reset, "LEFT", -4, 0)
  -- (D0) right-click the clock's buttons: every timer action (Stop, Save as stint...)
  local function timerItems(self) return self.board and Bo() and Bo().AllItems(self.board) or nil end
  Wd.RightMenu(p.pause, timerItems)
  Wd.RightMenu(p.reset, timerItems)
  Wd.RichTip(p.pause, function(self)
    local running = self.board and M().BoardState(self.board) == "running"
    return { title = L["The board's clock"], on = running and true or false,
      state = running and L["Now: running"] or L["Now: paused"],
      text = L["Its tiles count over this clock: pause it for a break, start it again when you are back."],
      click = running and L["Click: pause."] or L["Click: start."] }
  end)
  p.add = Wd.Button(p, L["+ Tile"], ADD_W, function(self)
    if self.board and Bo() then Bo().AddReadingMenu(self, self.board) end
  end)
  p.add:SetFrameLevel(p:GetFrameLevel() + 2)
  Wd.RichTip(p.add, function() return { title = L["+ Tile"],
    text = L["Add a number to this board, picked by tracker. It appears here at once, and on your HUD when the board is there; its tracker starts counting, with history."],
    click = L["Click: the list of numbers."] } end)
  p.count = p:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  p.count:SetPoint("RIGHT", p.add, "LEFT", -8, 0)
  p.count:SetJustifyH("RIGHT")
  local h = newHeading(p)
  h:SetFrameLevel(p:GetFrameLevel() + 1)
  h:SetPoint("TOPLEFT", INSET, -2)
  h:SetPoint("TOPRIGHT", -(INSET + HUD_W + 4 + 2 * (CLOCK_W + 4) + ADD_W + 54), -2)   -- (room for the controls)
  h.icon:SetTexture(BOARD_ICON)
  h:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  h:SetScript("OnClick", function(self) if self.board then boardMenu(self, self.board) end end)
  h:SetScript("OnEnter", function(self)
    if not (self.board and GameTooltip) then return end
    GameTooltip:SetOwner(self, "ANCHOR_TOPLEFT")
    GameTooltip:SetText(self.board.name, 1, 1, 1)
    GameTooltip:AddLine(L["Click: every action of this board."], 0.5, 0.5, 0.5, true)
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
  -- its display: the chip names it; a bar or a gauge with a target draws a strip toward it; a mix one strip in parts
  local disp = BM.TileDisplay(e.tile)
  c.chip:SetText(disp ~= "number" and L[DISPLAY_CHIP[disp] or disp] or "")
  local frac
  if ok and BM.NEEDS_TARGET[disp] then
    local okP, f = pcall(BM.Progress, e.tile, e.board)
    if okP then frac = f end
  end
  local inner = math.max(w - 16, 1)
  for _, t in ipairs(c.parts) do t:Hide() end
  if type(frac) == "number" then
    c.track:Show()
    c.fill:SetWidth(math.max(inner * frac, 1))
    c.fill:SetColorTexture(disp == "gauge" and 1 or 0.3, disp == "gauge" and 0.75 or 0.8, disp == "gauge" and 0.2 or 0.35, 0.9)
    c.fill:SetShown(frac > 0)
  elseif disp == "mix" and ok then
    local okM, parts = pcall(BM.MixParts, e.tile, e.board)
    c.fill:Hide()
    if okM and type(parts) == "table" and #parts > 0 then
      c.track:Show()
      local x = 0
      for i, p in ipairs(parts) do
        local t = c.parts[i]
        if not t then t = c:CreateTexture(nil, "OVERLAY"); t:SetHeight(4); c.parts[i] = t end
        local col = MIX_COLORS[(i - 1) % #MIX_COLORS + 1]
        t:SetColorTexture(col[1], col[2], col[3], 0.95)
        t:ClearAllPoints()
        t:SetPoint("BOTTOMLEFT", c.track, "BOTTOMLEFT", x, 0)
        local pw = math.max(inner * (p.frac or 0), 1)
        t:SetWidth(pw)
        t:Show()
        x = x + pw
      end
    else
      c.track:Hide()
    end
  else
    c.track:Hide()
    c.fill:Hide()
  end
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
  -- (0.4.0) no pack loaded beside the built-in one: a reminder above the boards. (0.4.0-beta2) Only what is loaded
  -- counts: packs installed through the game's AddOns list never ticked a box here, and the reminder was wrong.
  local P = ns.Packs
  local noPacks = P and P.LoadedCount() == 0
  content.notice:SetShown(noPacks and true or false)
  if noPacks then
    content.notice.text:SetText(L["Only gold and experience are counted: no pack is on. Packs add loot, reputation, fishing, your stats, travel."])
    content.notice:ClearAllPoints()
    content.notice:SetPoint("TOPLEFT", content, "TOPLEFT", PAD, y)
    content.notice:SetPoint("TOPRIGHT", content, "TOPRIGHT", -PAD, y)
    y = y - NOTICE_H - GROUP_GAP
  end

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
      h.board, p.hud.board, p.add.board, p.pause.board, p.reset.board = b, b, b, b, b
      h.text:SetText(b.name)
      local status = (ns.BoardStatusText and ns.BoardStatusText(b)) or ""
      local clock = Bo() and Bo().ClockText(b) or ""
      h.note:SetText(clock ~= "" and (status .. "   |cffc0c0c0" .. clock .. "|r") or status)
      p.hud:SetState(b.shown and L["On HUD"] or L["Only here"], b.shown and true or false)
      -- the clock's buttons, as on the HUD: only while the board is on its own timer (hidden, not greyed)
      local st = BM.BoardState(b)
      p.pause:SetShown(st ~= nil)
      p.reset:SetShown(st ~= nil)
      if st then p.pause:SetText(st == "running" and L["Pause"] or L["Start"]) end
      p.add:ClearAllPoints()
      p.add:SetPoint("RIGHT", st and p.pause or p.hud, "LEFT", -4, 0)
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
    p.head.board, p.hud.board, p.add.board, p.pause.board, p.reset.board = nil, nil, nil, nil, nil
  end
  for i = nc + 1, #cards do cards[i]:Hide(); cards[i].entry = nil end
  content.empty:ClearAllPoints()
  content.empty:SetPoint("TOPLEFT", content, "TOPLEFT", 20, y - 4)
  content.empty:SetPoint("TOPRIGHT", content, "TOPRIGHT", -20, y - 4)
  if search ~= "" and not any then
    content.empty:SetText(L["No tile or board matches the search."])
    y = y - 2 * LINE_H
  else
    content.empty:SetText("")
  end
  -- (0.4.0, the user: "at the end of the boards listing ... a section that briefly explains that they can add new or
  -- more boards there"): a dashed panel with the two ways; with no boards yet it is the whole page
  local foot = content.foot
  foot.title:SetText(#groups == 0 and L["No boards yet: make your first one"] or L["Add another board"])
  foot.text:SetText(#groups == 0
    and L["A board is a panel of tiles: the numbers you want while you play. Start from a ready-made one (Leveling, Farming, your class...) or an empty one, then add tiles with + Tile. It stays here until you put it on your HUD."]
    or L["Boards group your tiles: one for farming, one for a dungeon, one per goal. Make as many as you like; each has its own clock and its own place on your HUD."])
  foot:ClearAllPoints()
  foot:SetPoint("TOPLEFT", content, "TOPLEFT", PAD, y)
  foot:SetPoint("TOPRIGHT", content, "TOPRIGHT", -PAD, y)
  foot:SetHeight(FOOT_H)
  sizeDashes(foot.dash, math.max(w - 2 * PAD, 1), FOOT_H)
  foot:SetShown(search == "")
  if search == "" then y = y - FOOT_H - GROUP_GAP end
  -- the tab is as tall as its cards: the window scrolls it (HC-69)
  local h = max(MIN_H, floor(-y + PAD))
  if h ~= contentH then
    contentH = h
    ns.Windows.Relayout(ID)
  end
end
ns.RefreshBoards = refresh

--- A dashed panel with a title, a line of text and two buttons (the "more boards" footer).
local function newFooter(f)
  local p = CreateFrame("Frame", nil, f)
  p:SetFrameLevel(f:GetFrameLevel() + 1)
  local bg = p:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  bg:SetColorTexture(0, 0, 0, 0.18)
  p.dash = edges(p, "BORDER", true, 0.75, 0.65, 0.3, 0.8)
  p.title = p:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  p.title:SetPoint("TOPLEFT", 12, -8)
  p.text = p:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  p.text:SetPoint("TOPLEFT", 12, -26)
  p.text:SetPoint("TOPRIGHT", -250, -26)
  p.text:SetJustifyH("LEFT")
  p.text:SetJustifyV("TOP")
  p.text:SetHeight(42)
  p.ready = Wd.Button(p, L["Ready-made boards"], 130, function()
    if ns.ShowExplorer then ns.ShowExplorer(true, "presets") end
  end)
  p.ready:SetPoint("RIGHT", -12, 0)
  Wd.RichTip(p.ready, function() return { title = L["Ready-made boards"],
    text = L["The Explorer tab lists every ready-made board by activity and class, with its tiles."],
    click = L["Click: open the list."] } end)
  p.new = Wd.Button(p, L["New board..."], 104, function() if Bo() then Bo().OpenNewBoard() end end)
  p.new:SetPoint("RIGHT", p.ready, "LEFT", -6, 0)
  Wd.RichTip(p.new, function() return { title = L["New board..."],
    text = L["Make a board: ready-made, empty, or a copy. It appears here; you choose whether it also goes on your HUD."],
    click = L["Click: the New board dialog."] } end)
  Wd.RightMenu(p, function() return {
    { text = L["New board..."], func = function() if Bo() then Bo().OpenNewBoard() end end },
    { text = L["Ready-made boards"], func = function() if ns.ShowExplorer then ns.ShowExplorer(true, "presets") end end },
  } end)
  return p
end

--- The reminder about packs: a yellow strip with a button to the Packs tab.
local function newNotice(f)
  local n = CreateFrame("Frame", nil, f)
  n:SetHeight(NOTICE_H)
  n:SetFrameLevel(f:GetFrameLevel() + 1)
  local bg = n:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  bg:SetColorTexture(0.35, 0.27, 0.02, 0.45)
  n.text = n:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  n.text:SetPoint("LEFT", 10, 0)
  n.text:SetPoint("RIGHT", -130, 0)
  n.text:SetJustifyH("LEFT")
  n.go = Wd.Button(n, L["Choose packs"], 110, function() if ns.ShowPacks then ns.ShowPacks(true) end end)
  n.go:SetPoint("RIGHT", -8, 0)
  Wd.RichTip(n.go, function() return { title = L["Choose packs"],
    text = L["The Packs tab: tick the packs you want. They are loaded at the next reload."], click = L["Click: open it."] } end)
  Wd.RightMenu(n, function() return { { text = L["Choose packs"], func = function() if ns.ShowPacks then ns.ShowPacks(true) end end } } end)
  n:Hide()
  return n
end

local function build(f)
  content = f
  local s = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
  s:SetSize(200, 20)
  s:SetPoint("TOPLEFT", 14, -6)
  s:SetAutoFocus(false)
  s.hint = s:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  s.hint:SetPoint("LEFT", 2, 0)
  s.hint:SetText(L["Search your tiles or boards"])
  f.searchBox = s                                   -- (A3) Ctrl+K finds it
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
  Wd.RichTip(f.new, function() return { title = L["New board..."],
    text = L["Make a board: ready-made, empty, or a copy. It appears here; you choose whether it also goes on your HUD."],
    click = L["Click: the New board dialog."] } end)
  f.empty = f:CreateFontString(nil, "OVERLAY", "GameFontDisable")
  f.empty:SetJustifyH("LEFT")
  f.notice = newNotice(f)
  f.foot = newFooter(f)
  f:SetScript("OnSizeChanged", function() refresh() end)
end

ns.Windows.Register(ID, {
  title = L["Boards"], icon = TAB_ICON, tabOrder = 1,
  about = "Your boards and their tiles: make them, fill them, and choose what shows on your HUD.",
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

function ns.ShowBoards(show) ns.Windows.Show(ID, show) end
ns.BoardsCardMenu, ns.BoardsBoardMenu = cardMenu, boardMenu         -- (tests)
ns.BoardsPanels, ns.BoardsCards = panels, cards                     -- (tests)
ns.BoardsFooter = function() return content and content.foot end    -- (tests)
ns.AddSlash("boards", function() ns.ShowBoards() end, L["the Boards tab: your boards and their tiles, on or off your HUD"])

-- a tile added or changed elsewhere (a board's menu, a pack's preset) shows here at the next second anyway; a
-- tracker switched on or off changes values at once
local owner = {}
HC.RegisterCallback(owner, "HC_TRACKERS_CHANGED", function() refresh() end)

-- This tab's help and tour (UI/Help.lua): change them with the tab.
local _ = ns.Help and ns.Help.Register(ID, {
  what = "Boards shows everything you follow: each board as a panel, each of its tiles as a card with its number now. It is also where boards and tiles are made. A board lives here first; it is on your HUD (your screen while you play) only when you put it there.",
  can = {
    "{New board...} (top right, or the panel at the end): a ready-made board, an empty one, or a copy. It starts here, off your HUD, unless you tick the HUD box.",
    "{+ Tile} on a board's panel: pick a number by tracker; it is added to that board at once, and its tracker starts counting.",
    "The switch at the right reads {On HUD} (green) or {Only here} (grey): click it to put the whole board on your screen or take it off.",
    "{Pause} or {Start} and {Reset} work the board's clock, as on the board itself (when it counts on its own timer).",
    "Click a card: {Edit} the tile, switch that one tile {On HUD} or off, {Move to board}, {Delete tile}. Click a board's name for every action of that board.",
  },
  effect = "What is {On HUD} is drawn on your screen while you play; what is {Only here} keeps counting but stays in this window. A tile can be kept off the HUD while its board is on it: its card has a dashed border. A bar or a gauge shows its strip here too.",
  tour = {
    { title = "Boards are panels, tiles are cards", text = "Each framed panel is one of your boards; the cards in it are its tiles, with their numbers now. After the board's name you read where it is (on your HUD, or only here) and its clock." },
    { title = "Make a board, add tiles", text = "{New board...} at the top right makes a board; so does the panel at the end of the list. On a board's panel, {+ Tile} lists every number you can add, by tracker." },
    { title = "On your HUD, or only here", text = "The switch at the right of a board's panel says {On HUD} with a green lamp or {Only here} with a grey one. Click it and the board goes on your screen, or comes off it. It counts either way." },
    { title = "The clock, and one tile at a time", text = "{Pause} and {Reset} beside it work the board's clock. Click a card for that tile's menu: {On HUD} there keeps a single tile off the screen while the rest of its board is shown." },
  },
})
