-- Overview (DESIGN §17.4, HC-67): the player's own tiles, the first tab of the Hard Counters window. Every tile of
-- the collection (UI/BoardModel.lua: every reading tile lives there; boards hold references) as a card in the
-- sections the player names, with a search box. A card: the tile's label, its number now, and "On HUD: <board>" or
-- "Window only". Click or right-click: Edit (the same choices as on a board), Show on HUD or move to another board,
-- Take off HUD, Section, Delete tile. Add tile opens the Trackers tab, whose Add tile then adds here.
-- A section's title, right-clicked: Rename section. Cards refresh once a second while the tab is on screen; the tab
-- is as tall as its cards (the window scrolls it, HC-69).
local ADDON, ns = ...

local HC, L, Wd = ns.HC, ns.L, ns.Widgets
local format, floor, max = string.format, math.floor, math.max

local ID = "overview"
local TOP_H, HEAD_H, CARD_H, CARD_MIN_W, GAP, PAD = 34, 24, 58, 176, 6, 8
local MIN_W, MIN_H = 600, 360
local content
local cards, heads = {}, {}
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
local function askText(prompt, current, fn) if Bo() and Bo().AskText then Bo().AskText(prompt, current, fn) end end

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
    local b = BM.Create(nil, { name = (e.raw.section or L["Board"]):sub(1, 32) })
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
  local sec = {}
  local cur = e.raw.section or BM.DEFAULT_SECTION
  for _, s in ipairs(BM.Sections()) do
    sec[#sec + 1] = { text = s, checked = cur == s, func = function() BM.SetSection(e.raw, s); refresh() end }
  end
  sec[#sec + 1] = { text = L["New section..."], func = function()
    askText(L["Section name"], "", function(s) if s ~= "" then BM.SetSection(e.raw, s); refresh() end end)
  end }
  items[#items + 1] = { text = L["Section"], sub = sec }
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

local function sectionMenu(anchor, name)
  ns.Menu.Show(anchor, { { text = name, title = true }, { text = L["Rename section..."], func = function()
    askText(L["Section name"], name, function(s)
      if not M().RenameSection(name, s) and ns.Print and s ~= "" and s ~= name then
        ns.Print(L["There is already a section called %s."], s)
      end
      refresh()
    end)
  end } })
end

---------------------------------------------------------------------------
-- Drawing
---------------------------------------------------------------------------

local function newCard(i)
  local c = CreateFrame("Button", nil, content)
  c:SetHeight(CARD_H)
  c:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  local bg = c:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  bg:SetColorTexture(0.08, 0.08, 0.1, 0.85)
  local hl = c:CreateTexture(nil, "HIGHLIGHT")
  hl:SetAllPoints()
  hl:SetColorTexture(1, 1, 1, 0.07)
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
    GameTooltip:AddLine(L["Click: edit, show on HUD, section, delete."], 0.5, 0.5, 0.5, true)
    GameTooltip:Show()
  end)
  c:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
  cards[i] = c
  return c
end

local function newHead(i)
  local h = CreateFrame("Button", nil, content)
  h:SetHeight(HEAD_H)
  h:RegisterForClicks("RightButtonUp")
  h.text = h:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  h.text:SetPoint("LEFT", 2, 0)
  h.text:SetJustifyH("LEFT")
  h:SetScript("OnClick", function(self) if self.name then sectionMenu(self, self.name) end end)
  heads[i] = h
  return h
end

--- The card's number: the tile's value as on its board (its board's timer), or toward its target for a bar or gauge.
local function fill(c, e)
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
  if e.board then
    c.foot:SetText(format(L["On HUD: %s"], e.board.name) .. (e.board.shown and "" or (" (" .. L["hidden"] .. ")")))
    c.foot:SetTextColor(0.55, 0.85, 0.55)
  else
    c.foot:SetText(L["Window only"])
    c.foot:SetTextColor(0.5, 0.5, 0.5)
  end
  c.entry = e
end

local function matches(e)
  if search == "" then return true end
  local BM = M()
  local function has(s) return type(s) == "string" and s:lower():find(search, 1, true) ~= nil end
  return has(BM.TileLabel(e.tile, e.board)) or has(e.raw.section) or (e.board and has(e.board.name))
end

function refresh()
  if not (content and content:IsShown() and M()) then return end
  local BM = M()
  local w = content:GetWidth()
  if type(w) ~= "number" or w < MIN_W then w = MIN_W end
  local cols = max(1, floor((w - 2 * PAD + GAP) / (CARD_MIN_W + GAP)))
  local cardW = floor((w - 2 * PAD - (cols - 1) * GAP) / cols)
  local all = BM.CollectionTiles()
  local bySection = {}
  for _, e in ipairs(all) do
    if matches(e) then
      local s = e.raw.section or BM.DEFAULT_SECTION
      bySection[s] = bySection[s] or {}
      table.insert(bySection[s], e)
    end
  end
  local y, nc, nh = -TOP_H, 0, 0
  for _, s in ipairs(BM.Sections()) do
    local list = bySection[s]
    if list then
      nh = nh + 1
      local h = heads[nh] or newHead(nh)
      h:ClearAllPoints()
      h:SetPoint("TOPLEFT", content, "TOPLEFT", PAD, y)
      h:SetPoint("TOPRIGHT", content, "TOPRIGHT", -PAD, y)
      h.text:SetText(s .. "  |cff808080" .. #list .. "|r")
      h.name = s
      h:Show()
      y = y - HEAD_H
      for k, e in ipairs(list) do
        nc = nc + 1
        local c = cards[nc] or newCard(nc)
        local col = (k - 1) % cols
        if col == 0 and k > 1 then y = y - CARD_H - GAP end
        c:ClearAllPoints()
        c:SetPoint("TOPLEFT", content, "TOPLEFT", PAD + col * (cardW + GAP), y)
        c:SetWidth(cardW)
        fill(c, e)
        c:Show()
      end
      y = y - CARD_H - GAP - 4
    end
  end
  for i = nc + 1, #cards do cards[i]:Hide(); cards[i].entry = nil end
  for i = nh + 1, #heads do heads[i]:Hide() end
  if #all == 0 then
    content.empty:SetText(L["No tiles yet. Every number you put on a board is a tile, and lives here too.\n\n"
      .. "Add tile picks one from the Trackers tab; right-click a tile here to put it on a board (your HUD)."])
  elseif nc == 0 then
    content.empty:SetText(L["No tile matches the search."])
  else
    content.empty:SetText("")
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
  s.hint:SetText(L["Search your tiles"])
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
  Wd.Tip(f.add, function() return L["Pick a number in the Trackers tab: its Add tile puts it here."] end)
  f.hint = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  f.hint:SetPoint("RIGHT", f.add, "LEFT", -10, 0)
  f.hint:SetText(L["Click a tile to edit it or put it on a board"])
  f.empty = f:CreateFontString(nil, "OVERLAY", "GameFontDisable")
  f.empty:SetPoint("TOPLEFT", 20, -TOP_H - 20)
  f.empty:SetPoint("TOPRIGHT", -20, -TOP_H - 20)
  f.empty:SetJustifyH("LEFT")
  f:SetScript("OnSizeChanged", function() refresh() end)
end

ns.Windows.Register(ID, {
  title = L["Overview"], icon = "Interface\\Icons\\INV_Misc_Note_01", tabOrder = 1,
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
ns.OverviewCardMenu, ns.OverviewSectionMenu = cardMenu, sectionMenu     -- (tests)
ns.AddSlash("overview", function() ns.ShowOverview() end, L["your tiles: every number you placed, on a board or not"])

-- a tile added or changed elsewhere (a board's menu, a pack's preset) shows here at the next second anyway; a
-- tracker switched on or off changes values at once
local owner = {}
HC.RegisterCallback(owner, "HC_TRACKERS_CHANGED", function() refresh() end)
