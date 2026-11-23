-- Overview (DESIGN §17.4, HC-67, HC-73): the player's own tiles, the first tab of the Hard Counters window. Every tile
-- of the collection (UI/BoardModel.lua: every reading tile lives there; boards hold references) as a card, grouped by
-- where it is: one framed panel per board (in the Boards tab's order, its tiles in the board's order; an empty board
-- too), headed by the board's name, its status in the Boards tab's colours and its tile count; then the tiles on no
-- board, unframed under "Window only", with dashed cards. A card: the tile's label, its number now, its scope.
-- Click a card: Edit (the same choices as on a board), Show on HUD or move to another board, Take off HUD, Delete
-- tile. Click a board's header: that board's actions, as on its Boards tab row. Add tile opens the Trackers tab,
-- whose Add tile then adds here (Window only). Search: a tile's label or its board's name. Cards refresh once a
-- second while the tab is on screen; the tab is as tall as its cards (the window scrolls it, HC-69).
local ADDON, ns = ...

local HC, L, Wd = ns.HC, ns.L, ns.Widgets
local format, floor, max = string.format, math.floor, math.max

local ID = "overview"
local TOP_H, HEAD_H, CARD_H, CARD_MIN_W, GAP, PAD = 34, 26, 58, 176, 6, 8
local INSET, GROUP_GAP, LINE_H = 8, 10, 20       -- a board panel's inner margin, the space between groups, a text line
local MIN_W, MIN_H = 600, 360
local BOARD_ICON, LOOSE_ICON = "Interface\\Icons\\INV_Misc_Map_01", "Interface\\Icons\\INV_Misc_Note_01"
local DASH = "Interface\\AddOns\\HardCounters\\Media\\Dash"    -- 8x8, white where x < 5 and y < 5 (tools/draw-dash.py)
local content
local cards, panels = {}, {}
local loose                                       -- the Window only heading
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
  -- on the HUD: a board, or another one (a tile is on one board at most)
  local hud = {}
  for _, b in ipairs(BM.AddTargets()) do
    hud[#hud + 1] = { text = b.shown and b.name or format(L["%s (hidden)"], b.name), checked = e.board == b, func = function()
      if e.board == b then return end
      local from = e.board
      local p = BM.Place(e.raw, b)
      redrawBoard(from)
      if p and Bo() then Bo().Reveal(b, p) end
      refresh()
    end }
  end
  hud[#hud + 1] = { text = L["New board"], func = function()
    local from = e.board
    local b = BM.Create(nil, { name = L["Board"] })
    local p = BM.Place(e.raw, b)
    redrawBoard(from)
    if p and Bo() then Bo().Reveal(b, p) end
    refresh()
  end }
  items[#items + 1] = { text = e.board and L["Move to board"] or L["Show on HUD"], sub = hud }
  if e.board then
    items[#items + 1] = { text = L["Take off HUD"], tip = L["It stays here, Window only."], func = function()
      local b, i = BM.BoardOf(e.tile)
      if b then BM.RemoveTile(b, i); redrawBoard(b) end
      refresh()
    end }
  end
  items[#items + 1] = { text = L["Delete tile"], func = function()
    local where = e.board and format(L[" and the board %s"], e.board.name) or ""
    confirm(format(L["Delete the tile %s? It leaves the Overview tab%s. Your counts don't change."], label, where), function()
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
    GameTooltip:AddLine(e.board and format(L["On the board %s."], e.board.name)
      or L["Window only: tracked here, not on screen."], 0.6, 0.8, 0.6, true)
    GameTooltip:AddLine(L["Click: edit, show on HUD, delete."], 0.5, 0.5, 0.5, true)
    GameTooltip:Show()
  end)
  c:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
  cards[i] = c
  return c
end

--- A heading: an icon, a gold title, a note after it, a count on the right. A Button, so a board's can be clicked.
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
  h.count = h:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  h.count:SetPoint("RIGHT", -4, 0)
  h.count:SetJustifyH("RIGHT")
  return h
end

--- A board's panel: a darker frame with a solid border, its heading on top (click: the board's actions).
local function newPanel(i)
  local p = CreateFrame("Frame", nil, content)
  p:SetFrameLevel(content:GetFrameLevel() + 1)
  local bg = p:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  bg:SetColorTexture(0, 0, 0, 0.35)
  edges(p, "BORDER", false, 0.45, 0.45, 0.5, 0.9)
  local h = newHeading(p)
  h:SetFrameLevel(p:GetFrameLevel() + 1)
  h:SetPoint("TOPLEFT", INSET, -2)
  h:SetPoint("TOPRIGHT", -INSET, -2)
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
  p.empty:SetText(L["No numbers on this board."])
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
  c.foot:SetText(scopeWord(e.raw))
  -- on a board: a filled card inside its panel; Window only: a faint card with a dashed border
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
  local inner = w - 2 * PAD - 2 * INSET                            -- the cards' width, in a panel and below
  local cols = max(1, floor((inner + GAP) / (CARD_MIN_W + GAP)))
  local cardW = floor((inner - (cols - 1) * GAP) / cols)
  local groups, rest = BM.TilesByBoard()
  local y, nc, np, any = -TOP_H, 0, 0, false

  --- lay out cards from (x0, y0) down; returns the height used
  local function grid(list, x0, y0, dashed)
    for k, e in ipairs(list) do
      nc = nc + 1
      local c = cards[nc] or newCard(nc)
      local col, row = (k - 1) % cols, floor((k - 1) / cols)
      c:ClearAllPoints()
      c:SetPoint("TOPLEFT", content, "TOPLEFT", x0 + col * (cardW + GAP), y0 - row * (CARD_H + GAP))
      c:SetWidth(cardW)
      fill(c, e, dashed, cardW)
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
      h.board = b
      h.text:SetText(b.name)
      h.note:SetText((ns.BoardStatusText and ns.BoardStatusText(b)) or "")
      h.count:SetText(format(#g.entries == 1 and L["%d tile"] or L["%d tiles"], #g.entries))
      local top = 2 + HEAD_H + 2
      local body = #list > 0 and grid(list, PAD + INSET, y - top, false) or LINE_H
      p.empty:SetShown(#list == 0)
      if #list == 0 and search ~= "" then p.empty:SetText(L["No tile here matches the search."])
      else p.empty:SetText(L["No numbers on this board."]) end
      local ph = top + body + INSET
      p:ClearAllPoints()
      p:SetPoint("TOPLEFT", content, "TOPLEFT", PAD, y)
      p:SetPoint("TOPRIGHT", content, "TOPRIGHT", -PAD, y)
      p:SetHeight(ph)
      p:Show()
      y = y - ph - GROUP_GAP
    end
  end
  for i = np + 1, #panels do panels[i]:Hide(); panels[i].head.board = nil end

  -- the tiles on no board: unframed, last; always there without a search, so its line says what the tab is for
  local list = {}
  for _, e in ipairs(rest) do if matches(e) then list[#list + 1] = e end end
  any = any or #list > 0
  local showLoose = search == "" or #list > 0
  loose:SetShown(showLoose)
  loose.empty:SetShown(showLoose and #list == 0)
  if showLoose then
    loose:ClearAllPoints()
    loose:SetPoint("TOPLEFT", content, "TOPLEFT", PAD + INSET, y - 2)
    loose:SetPoint("TOPRIGHT", content, "TOPRIGHT", -PAD - INSET, y - 2)
    loose.count:SetText(#rest > 0 and format(#rest == 1 and L["%d tile"] or L["%d tiles"], #rest) or "")
    y = y - 2 - HEAD_H - 4
    if #list > 0 then
      y = y - grid(list, PAD + INSET, y, true)
    else
      y = y - LINE_H
    end
  end
  for i = nc + 1, #cards do cards[i]:Hide(); cards[i].entry = nil end
  content.empty:SetText((search ~= "" and not any) and L["No tile matches the search."] or "")
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
  f.add = Wd.Button(f, L["Add tile"], 100, function()
    ns.TrackersForOverview = true                       -- (Trackers' Add tile then adds here; until it closes)
    if ns.ShowTrackers then ns.ShowTrackers(true) end
  end)
  f.add:SetPoint("TOPRIGHT", -8, -6)
  Wd.Tip(f.add, function() return L["Pick a number in the Trackers tab: its Add tile puts it here, Window only."] end)
  f.hint = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  f.hint:SetPoint("RIGHT", f.add, "LEFT", -10, 0)
  f.hint:SetText(L["Click a tile to edit or move it"])
  f.empty = f:CreateFontString(nil, "OVERLAY", "GameFontDisable")
  f.empty:SetPoint("TOPLEFT", 20, -TOP_H - 4)
  f.empty:SetPoint("TOPRIGHT", -20, -TOP_H - 4)
  f.empty:SetJustifyH("LEFT")
  loose = newHeading(f)
  loose.icon:SetTexture(LOOSE_ICON)
  loose.text:SetText(L["Window only"])
  loose.note:SetText(L["tracked here, not on screen"])
  loose.note:SetFontObject("GameFontDisableSmall")
  loose.empty = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  loose.empty:SetPoint("TOPLEFT", loose, "BOTTOMLEFT", 2, -4)
  loose.empty:SetText(L["None yet. Add tile puts a number here without putting it on screen."])
  f.loose = loose
  f:SetScript("OnSizeChanged", function() refresh() end)
end

ns.Windows.Register(ID, {
  title = L["Overview"], icon = LOOSE_ICON, tabOrder = 1,
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
ns.AddSlash("overview", function() ns.ShowOverview() end, L["your tiles: by board, and the ones on no board"])

-- a tile added or changed elsewhere (a board's menu, a pack's preset) shows here at the next second anyway; a
-- tracker switched on or off changes values at once
local owner = {}
HC.RegisterCallback(owner, "HC_TRACKERS_CHANGED", function() refresh() end)
