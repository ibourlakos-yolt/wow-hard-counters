-- Browser (DESIGN §17.3): one widget for every catalog tab, in the spirit of the Auction House. A category tree on
-- the left; a search box and a Filters menu on top (a casual player needs only the search and the tree); a list
-- with sortable columns and a scroll bar; a detail pane for the selected row; an action bar whose buttons follow
-- the selection. The Trackers tab uses it (HC-66), Diagnostics' probes will (HC-70). Plain frames and pooled rows:
-- no list or dropdown templates, which differ between clients.
--
--   local b = ns.Browser.New(contentFrame, spec)   -- then b:Refresh() whenever the data changed
--
-- spec (every function is called at each refresh; the provider owns its data and its filters):
--   columns    { { key, title, width (nil: the one that takes the rest), align, sort = fn(row) -> value } }
--   nodes()    -> { { key, text, count } }: the tree; the first one is selected at first
--   rows(nodeKey, search) -> { { key, cells = { [colKey] = text }, grey } }: already filtered by the provider
--   filters()  -> Menu items (keepOpen ones redraw in place), or nil: no Filters button at all
--   filtersActive() -> true when a filter hides something (the button says so)
--   detail(row) -> { title, lines = { text }, items = { { text, tip, grey, button = { text, func(btn), tip } } } }
--   actions(row) -> { { text, func(btn), disabled, tip } } (row may be nil: nothing selected)
--   header     { { text, func(btn), width, tip } }: buttons at the top right (e.g. Edit boards)
--   footer()   -> text at the bottom left
--   empty(nodeKey, search) -> the list's text when no row matches; noSelection: the detail pane's text then
--   hover(row, on)  -> the pointer entered (on) or left a row (the Boards tab flashes that board, HC-68)
--   rowMenu(row, anchor) -> right-click on a row; without it the row's actions as a menu
local ADDON, ns = ...

local L, Wd = ns.L, ns.Widgets
local floor, max, min = math.floor, math.max, math.min

local Browser = {}
ns.Browser = Browser

local TOP_H, TREE_W, ROW_H, HEAD_H, DETAIL_H, BAR_H, SB_W, GAP = 30, 150, 18, 18, 160, 26, 12, 6
local ITEM_H = 20
local GREY, WHITE, GOLD = { 0.5, 0.5, 0.5 }, { 1, 1, 1 }, { 1, 0.82, 0 }

local function num(v, default) return type(v) == "number" and v or default end

local function color(fs, c) fs:SetTextColor(c[1], c[2], c[3]) end

local function tip(frame, text)
  if not text then return end
  frame:SetScript("OnEnter", function(self)
    if not GameTooltip then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(type(text) == "function" and text() or text, 1, 1, 1, 1, true)
    GameTooltip:Show()
  end)
  frame:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
end

local function panel(parent, alpha)
  local f = CreateFrame("Frame", nil, parent)
  local bg = f:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  bg:SetColorTexture(0, 0, 0, alpha or 0.25)
  return f
end

local B = {}
B.__index = B

---------------------------------------------------------------------------
-- Building
---------------------------------------------------------------------------

function Browser.New(parent, spec)
  local b = setmetatable({ parent = parent, spec = spec, node = nil, search = "", sortKey = nil, sortDesc = false,
    selected = nil, listOff = 0, treeOff = 0, detailOff = 0, rowsData = {}, nodesData = {} }, B)

  -- top: search, Filters, the provider's header buttons
  local s = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
  s:SetSize(TREE_W - 10, 20)
  s:SetPoint("TOPLEFT", 12, -5)
  s:SetAutoFocus(false)
  s.hint = s:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  s.hint:SetPoint("LEFT", 2, 0)
  s.hint:SetText(L["Search"])
  s:SetScript("OnTextChanged", function(self)
    local text = (self:GetText() or "")
    self.hint:SetShown(text == "")
    b.search = text:lower()
    b.listOff = 0
    b:Refresh()
  end)
  s:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  s:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
  b.searchBox = s

  if spec.filters then
    b.filterBtn = Wd.Button(parent, L["Filters"], 80, function(self)
      ns.Menu.Show(self, function() return spec.filters() end)
    end)
    b.filterBtn:SetPoint("LEFT", s, "RIGHT", 8, 0)
  end
  local prev
  b.headerBtns = {}
  for _, h in ipairs(spec.header or {}) do
    local hb = Wd.Button(parent, h.text, h.width or 100, function(self) h.func(self) end)
    if prev then hb:SetPoint("RIGHT", prev, "LEFT", -4, 0) else hb:SetPoint("TOPRIGHT", -8, -5) end
    tip(hb, h.tip)
    b.headerBtns[#b.headerBtns + 1] = hb
    prev = hb
  end

  -- the tree
  local tree = panel(parent, 0.3)
  tree:SetPoint("TOPLEFT", 4, -TOP_H)
  tree:SetPoint("BOTTOMLEFT", 4, BAR_H + GAP)
  tree:SetWidth(TREE_W)
  tree.rows = {}
  tree:EnableMouseWheel(true)
  tree:SetScript("OnMouseWheel", function(_, delta) b.treeOff = b.treeOff - delta; b:DrawTree() end)
  b.tree = tree

  -- the list: column headers, pooled rows, a scroll bar
  local list = panel(parent, 0.15)
  list:SetPoint("TOPLEFT", tree, "TOPRIGHT", GAP, 0)
  list:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -4, BAR_H + GAP + DETAIL_H + GAP)
  list.rows, list.heads = {}, {}
  list:EnableMouseWheel(true)
  list:SetScript("OnMouseWheel", function(_, delta) b:ScrollList(b.listOff - delta * 3) end)
  list.bar = Wd.VScroll(list, function(off) b:ScrollList(off, true) end)
  list.bar:SetPoint("TOPRIGHT", list, "TOPRIGHT", 0, -HEAD_H)
  list.bar:SetPoint("BOTTOMRIGHT", list, "BOTTOMRIGHT", 0, 0)
  list.empty = list:CreateFontString(nil, "OVERLAY", "GameFontDisable")
  list.empty:SetPoint("TOP", 0, -HEAD_H - 20)
  for i, col in ipairs(spec.columns) do
    local h = CreateFrame("Button", nil, list)
    h:SetHeight(HEAD_H)
    h.text = h:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    h.text:SetAllPoints()
    h.text:SetJustifyH(col.align or "LEFT")
    local hl = h:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 1, 0.08)
    h:SetScript("OnClick", function()
      if b.sortKey == col.key then b.sortDesc = not b.sortDesc else b.sortKey, b.sortDesc = col.key, false end
      b:Refresh()
    end)
    list.heads[i] = h
  end
  b.list = list

  -- the detail pane
  local d = panel(parent, 0.3)
  d:SetPoint("TOPLEFT", list, "BOTTOMLEFT", 0, -GAP)
  d:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -4, BAR_H + GAP)
  d.title = d:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  d.title:SetPoint("TOPLEFT", 8, -6)
  d.title:SetPoint("TOPRIGHT", -8, -6)
  d.title:SetJustifyH("LEFT")
  d.text = d:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  d.text:SetPoint("TOPLEFT", d.title, "BOTTOMLEFT", 0, -4)
  d.text:SetPoint("TOPRIGHT", d.title, "BOTTOMRIGHT", 0, -4)
  d.text:SetJustifyH("LEFT")
  d.text:SetJustifyV("TOP")
  d.items = {}
  d:EnableMouseWheel(true)
  d:SetScript("OnMouseWheel", function(_, delta) b.detailOff = b.detailOff - delta; b:DrawDetail() end)
  b.detail = d

  -- the action bar
  b.footer = parent:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  b.footer:SetPoint("BOTTOMLEFT", 10, 10)
  b.footer:SetJustifyH("LEFT")
  b.actionBtns = {}

  parent:HookScript("OnSizeChanged", function() b:Refresh() end)
  return b
end

---------------------------------------------------------------------------
-- Geometry (the content frame is sized by the window host; the fake client gives anchored frames no size)
---------------------------------------------------------------------------

function B:ListWidth()
  local w = num(self.parent:GetWidth(), 600)
  return max(w - 4 - TREE_W - GAP - 4, 100)
end

function B:VisibleRows()
  local h = num(self.parent:GetHeight(), 400)
  local listH = h - TOP_H - (BAR_H + GAP + DETAIL_H + GAP)
  return max(1, floor((listH - HEAD_H) / ROW_H))
end

function B:TreeRows()
  local h = num(self.parent:GetHeight(), 400)
  return max(1, floor((h - TOP_H - BAR_H - GAP - 8) / ROW_H))
end

function B:DetailRows(textLines)
  return max(1, floor((DETAIL_H - 28 - textLines * 13) / ITEM_H))
end

---------------------------------------------------------------------------
-- Drawing
---------------------------------------------------------------------------

function B:DrawTree()
  local tree, nodes = self.tree, self.nodesData
  local n = self:TreeRows()
  self.treeOff = max(0, min(self.treeOff, #nodes - n))
  for i = 1, n do
    local node = nodes[self.treeOff + i]
    local r = tree.rows[i]
    if not r then
      r = CreateFrame("Button", nil, tree)
      r:SetHeight(ROW_H)
      r:SetPoint("TOPLEFT", 2, -4 - (i - 1) * ROW_H)
      r:SetPoint("TOPRIGHT", -2, -4 - (i - 1) * ROW_H)
      r.sel = r:CreateTexture(nil, "BACKGROUND")
      r.sel:SetAllPoints()
      r.sel:SetColorTexture(1, 0.82, 0, 0.18)
      local hl = r:CreateTexture(nil, "HIGHLIGHT")
      hl:SetAllPoints()
      hl:SetColorTexture(1, 1, 1, 0.08)
      r.text = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      r.text:SetPoint("LEFT", 6, 0)
      r.text:SetPoint("RIGHT", -4, 0)
      r.text:SetJustifyH("LEFT")
      r.text:SetWordWrap(false)
      r:EnableMouseWheel(true)
      r:SetScript("OnMouseWheel", function(_, delta) self.treeOff = self.treeOff - delta; self:DrawTree() end)
      tree.rows[i] = r
    end
    if node then
      local on = node.key == self.node
      r.text:SetPoint("LEFT", 6 + 10 * (node.indent or 0), 0)
      r.text:SetText(node.count and (node.text .. "  |cff808080" .. node.count .. "|r") or node.text)
      color(r.text, on and GOLD or (node.grey and GREY or WHITE))
      r.sel:SetShown(on)
      r.key = node.key
      r:SetScript("OnClick", function()
        self.node, self.listOff, self.selected = node.key, 0, nil
        self:Refresh()
      end)
      r:Show()
    else
      r:Hide()
    end
  end
  for i = n + 1, #tree.rows do tree.rows[i]:Hide() end
end

--- Column x offsets and widths: fixed ones as given, the flexible one takes the rest.
function B:Columns()
  local cols, total, flex = self.spec.columns, self:ListWidth() - SB_W - 8, nil
  local used = 0
  for _, c in ipairs(cols) do if c.width then used = used + c.width + 6 else flex = c end end
  local out, x = {}, 6
  for i, c in ipairs(cols) do
    local w = c.width or max(total - used - 6, 60)
    out[i] = { x = x, w = w, col = c }
    x = x + w + 6
  end
  return out, flex
end

function B:DrawList()
  local list, rows = self.list, self.rowsData
  local cols = self:Columns()
  for i, c in ipairs(cols) do
    local h = list.heads[i]
    h:ClearAllPoints()
    h:SetPoint("TOPLEFT", list, "TOPLEFT", c.x, 0)
    h:SetWidth(c.w)
    local mark = ""
    if self.sortKey == c.col.key then mark = self.sortDesc and " v" or " ^" end
    h.text:SetText((c.col.title or "") .. mark)
  end
  local n = self:VisibleRows()
  local maxOff = max(0, #rows - n)
  self.listOff = max(0, min(self.listOff, maxOff))
  list.bar:SetRange(maxOff)
  list.bar:SetOffset(self.listOff)
  for i = 1, n do
    local row = rows[self.listOff + i]
    local r = list.rows[i]
    if not r then
      r = CreateFrame("Button", nil, list)
      r:SetHeight(ROW_H)
      r:RegisterForClicks("LeftButtonUp", "RightButtonUp")
      r.sel = r:CreateTexture(nil, "BACKGROUND")
      r.sel:SetAllPoints()
      r.sel:SetColorTexture(1, 0.82, 0, 0.18)
      local hl = r:CreateTexture(nil, "HIGHLIGHT")
      hl:SetAllPoints()
      hl:SetColorTexture(1, 1, 1, 0.08)
      r.cells = {}
      r:EnableMouseWheel(true)
      r:SetScript("OnMouseWheel", function(_, delta) self:ScrollList(self.listOff - delta * 3) end)
      list.rows[i] = r
    end
    r:ClearAllPoints()
    r:SetPoint("TOPLEFT", list, "TOPLEFT", 0, -HEAD_H - (i - 1) * ROW_H)
    r:SetPoint("TOPRIGHT", list, "TOPRIGHT", -SB_W - 2, -HEAD_H - (i - 1) * ROW_H)
    if row then
      for j, c in ipairs(cols) do
        local fs = r.cells[j]
        if not fs then
          fs = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
          fs:SetWordWrap(false)
          r.cells[j] = fs
        end
        fs:ClearAllPoints()
        fs:SetPoint("LEFT", r, "LEFT", c.x, 0)
        fs:SetWidth(c.w)
        fs:SetJustifyH(c.col.align or "LEFT")
        fs:SetText(row.cells[c.col.key] or "")
        color(fs, row.grey and GREY or WHITE)
        fs:Show()
      end
      r.sel:SetShown(row.key == self.selected)
      r.row = row
      if self.spec.hover then
        r:SetScript("OnEnter", function(btn) if btn.row then self.spec.hover(btn.row, true) end end)
        r:SetScript("OnLeave", function(btn) if btn.row then self.spec.hover(btn.row, false) end end)
      end
      r:SetScript("OnClick", function(btn, button)
        self.selected = row.key
        self.detailOff = 0
        self:Draw()
        if button == "RightButton" then self:RowMenu(row, btn) end
      end)
      r:Show()
    else
      r.row = nil
      r:Hide()
    end
  end
  for i = n + 1, #list.rows do list.rows[i]:Hide() end
  list.empty:SetText(#rows == 0 and (self.spec.empty and self.spec.empty(self.node, self.search) or L["Nothing here."]) or "")
end

--- Right-click on a row: its actions as a menu (the same as the action bar).
function B:RowMenu(row, anchor)
  if self.spec.rowMenu then return self.spec.rowMenu(row, anchor) end
  local acts = self.spec.actions and self.spec.actions(row) or {}
  if #acts == 0 or not ns.Menu then return end
  local items = {}
  for _, a in ipairs(acts) do
    items[#items + 1] = { text = a.text, disabled = a.disabled, tip = a.tip, func = function() a.func(anchor) end }
  end
  ns.Menu.Show(anchor, items)
end

function B:SelectedRow()
  for _, row in ipairs(self.rowsData) do if row.key == self.selected then return row end end
  return nil
end

function B:DrawDetail()
  local d, row = self.detail, self:SelectedRow()
  local info = row and self.spec.detail and self.spec.detail(row) or nil
  if not info then
    d.title:SetText("")
    d.text:SetText(self.spec.noSelection or "")
    for _, it in ipairs(d.items) do it:Hide() end
    return
  end
  d.title:SetText(info.title or "")
  local lines = info.lines or {}
  d.text:SetText(table.concat(lines, "\n"))
  local textLines = 0
  for _, l in ipairs(lines) do textLines = textLines + 1 + floor(#l / 110) end
  local items = info.items or {}
  local n = self:DetailRows(textLines)
  self.detailOff = max(0, min(self.detailOff, #items - n))
  local top = -10 - 14 - textLines * 13 - 4
  for i = 1, n do
    local item = items[self.detailOff + i]
    local r = d.items[i]
    if not r then
      r = CreateFrame("Frame", nil, d)
      r:SetHeight(ITEM_H)
      r.text = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      r.text:SetPoint("LEFT", 0, 0)
      r.text:SetJustifyH("LEFT")
      r.text:SetWordWrap(false)
      r.btn = Wd.Button(r, "", 80, nil)
      r.btn:SetHeight(18)
      r.btn:SetPoint("RIGHT", 0, 0)
      r.text:SetPoint("RIGHT", r.btn, "LEFT", -8, 0)
      r:EnableMouse(true)
      r:EnableMouseWheel(true)
      r:SetScript("OnMouseWheel", function(_, delta) self.detailOff = self.detailOff - delta; self:DrawDetail() end)
      d.items[i] = r
    end
    r:ClearAllPoints()
    r:SetPoint("TOPLEFT", d, "TOPLEFT", 16, top - (i - 1) * ITEM_H)
    r:SetPoint("TOPRIGHT", d, "TOPRIGHT", -8, top - (i - 1) * ITEM_H)
    if item then
      r.text:SetText(item.text or "")
      color(r.text, item.grey and GREY or (item.head and GOLD or WHITE))
      tip(r, item.tip)
      if not item.tip then r:SetScript("OnEnter", nil); r:SetScript("OnLeave", nil) end
      local bt = item.button
      if bt then
        r.btn:SetText(bt.text)
        Wd.FitWidth(r.btn, 70, 20)
        r.btn:SetScript("OnClick", function(btn) bt.func(btn) end)
        tip(r.btn, bt.tip)
        r.btn:SetEnabled(not bt.disabled)
        r.btn:Show()
      else
        r.btn:Hide()
      end
      r:Show()
    else
      r:Hide()
    end
  end
  for i = n + 1, #d.items do d.items[i]:Hide() end
  if #items > n then
    d.title:SetText((info.title or "") .. "   |cff808080" .. L["(mouse wheel: more)"] .. "|r")
  end
end

function B:DrawActions()
  local row = self:SelectedRow()
  local acts = self.spec.actions and self.spec.actions(row) or {}
  local prev
  for i = #acts, 1, -1 do                        -- right to left, so they read left to right
    local a = acts[i]
    local k = #acts - i + 1
    local btn = self.actionBtns[k]
    if not btn then
      btn = Wd.Button(self.parent, "", 90, nil)
      btn:SetHeight(22)
      self.actionBtns[k] = btn
    end
    btn:ClearAllPoints()
    if prev then btn:SetPoint("RIGHT", prev, "LEFT", -4, 0) else btn:SetPoint("BOTTOMRIGHT", self.parent, "BOTTOMRIGHT", -6, 4) end
    btn:SetText(a.text)
    Wd.FitWidth(btn, 80, 24)
    btn:SetEnabled(not a.disabled)
    btn:SetScript("OnClick", function(b2) a.func(b2) end)
    tip(btn, a.tip)
    if not a.tip then btn:SetScript("OnEnter", nil); btn:SetScript("OnLeave", nil) end
    btn:Show()
    prev = btn
  end
  for k = #acts + 1, #self.actionBtns do self.actionBtns[k]:Hide() end
  self.footer:SetText(self.spec.footer and self.spec.footer() or "")
  if prev then self.footer:SetPoint("RIGHT", prev, "LEFT", -8, 0) end
end

function B:Draw()
  self:DrawTree()
  self:DrawList()
  self:DrawDetail()
  self:DrawActions()
end

---------------------------------------------------------------------------
-- Data
---------------------------------------------------------------------------

local function sortValue(col, row)
  local v
  if col.sort then v = col.sort(row) else v = row.cells[col.key] end
  if type(v) == "string" then v = v:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):lower() end
  return v
end

--- Rebuild the tree and the rows from the provider, keep the node and the selection when they still exist.
function B:Refresh()
  if not self.parent:IsShown() then return end
  local spec = self.spec
  self.nodesData = spec.nodes and spec.nodes() or {}
  local found = false
  for _, node in ipairs(self.nodesData) do if node.key == self.node then found = true end end
  if not found then self.node = self.nodesData[1] and self.nodesData[1].key or nil end
  local rows = spec.rows(self.node, self.search) or {}
  if self.sortKey then
    local col
    for _, c in ipairs(spec.columns) do if c.key == self.sortKey then col = c end end
    if col then
      for i, r in ipairs(rows) do r._i = i end
      local desc = self.sortDesc
      table.sort(rows, function(a, b)
        local va, vb = sortValue(col, a), sortValue(col, b)
        if va ~= vb and va ~= nil and vb ~= nil and type(va) == type(vb) then
          if desc then return va > vb end
          return va < vb
        end
        return a._i < b._i
      end)
    end
  end
  self.rowsData = rows
  local keep = false
  for _, r in ipairs(rows) do if r.key == self.selected then keep = true end end
  if not keep then self.selected = nil end
  if self.filterBtn then
    local active = spec.filtersActive and spec.filtersActive()
    self.filterBtn:SetText(active and (L["Filters"] .. " *") or L["Filters"])
  end
  self:Draw()
end

function B:ScrollList(off, fromBar)
  self.listOff = off
  if fromBar then
    local n = self:VisibleRows()
    self.listOff = max(0, min(off, #self.rowsData - n))
  end
  self:DrawList()
end

--- Select a row by key (and its tree node when given); the detail pane and the actions follow.
function B:Select(key, nodeKey)
  if nodeKey then self.node = nodeKey end
  self.selected = key
  self.detailOff = 0
  self:Refresh()
end

function B:SetSearch(text)
  self.searchBox:SetText(text or "")
  local h = self.searchBox:GetScript("OnTextChanged")
  if h then h(self.searchBox) end
end
