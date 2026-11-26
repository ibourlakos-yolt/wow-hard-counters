-- Browser (DESIGN §17.3): one widget for every catalog tab, in the spirit of the Auction House. A category tree on
-- the left; a search box and a Filters menu on top (a casual player needs only the search and the tree); a list
-- with sortable columns and a scroll bar; a detail pane for the selected row; an action bar whose buttons follow
-- the selection. The Explorer, the Stints tab and Diagnostics' probes use it. Plain frames and pooled rows: no list or
-- dropdown templates, which differ between clients.
-- (0.4.0) Columns may change with the tree's node (the Explorer lists boards, tiles, readings and trackers in one
-- tree); a node can be a grey caption that only groups the ones under it; the list and the detail pane share their
-- height through a splitter the player drags (its place is saved per window); a detail item can hold a value on
-- the right and a status pill; an action can be a status pill too, and actions past the bar's room go under More....
--
--   local b = ns.Browser.New(contentFrame, spec)   -- then b:Refresh() whenever the data changed
--
-- spec (every function is called at each refresh; the provider owns its data and its filters):
--   columns    { { key, title, width (nil: the one that takes the rest), align, sort = fn(row) -> value } }, or
--              function(nodeKey) -> such a list (the sort resets when the set changes)
--   nodes()    -> { { key, text, count, indent, grey, head } }: the tree (head: a caption, not clickable); the first
--              clickable one is selected at first
--   rows(nodeKey, search) -> { { key, cells = { [colKey] = text }, grey } }: already filtered by the provider
--   filters()  -> Menu items (keepOpen ones redraw in place), or nil: no Filters button at all
--   filtersActive() -> true when a filter hides something (the button says so)
--   detail(row) -> { title, lines = { text }, items = { { text, value, tip, grey, head,
--                    button = { text, func(btn), tip, disabled }, status = { text, on, func(btn), tip } } } }
--   actions(row) -> { { text, func(btn), disabled, tip, status (a pill: on = true/false/"warn"), more (under More...) } }
--   header     { { text, func(btn), width, tip } }: buttons at the top right (e.g. New board...)
--   footer()   -> text at the bottom left
--   empty(nodeKey, search) -> the list's text when no row matches; noSelection: the detail pane's text then
--   hover(row, on)  -> the pointer entered (on) or left a row (the Explorer shows that board, HC-68)
--   rowMenu(row, anchor) -> right-click on a row; without it the row's actions as a menu
--   splitKey   -> where the splitter's place is saved (settings.windows[splitKey].detailH); nil: not saved
local ADDON, ns = ...

local L, Wd = ns.L, ns.Widgets
local floor, max, min = math.floor, math.max, math.min

local Browser = {}
ns.Browser = Browser

local TOP_H, TREE_W, ROW_H, HEAD_H, BAR_H, SB_W, GAP = 30, 150, 18, 18, 26, 12, 6
local DETAIL_H, DETAIL_MIN, LIST_MIN_ROWS, SPLIT_H = 200, 90, 4, 6
local ITEM_H, LINE_H = 20, 13
local GREY, WHITE, GOLD, CAPTION = { 0.5, 0.5, 0.5 }, { 1, 1, 1 }, { 1, 0.82, 0 }, { 0.62, 0.62, 0.66 }
local MORE_W = 74

local function num(v, default) return type(v) == "number" and v or default end

local function color(fs, c) fs:SetTextColor(c[1], c[2], c[3]) end

--- A tooltip: a string, or a function returning one, or a RichTip spec table.
local function tip(frame, text)
  if not text then
    frame:SetScript("OnEnter", nil)
    frame:SetScript("OnLeave", nil)
    return
  end
  frame:SetScript("OnEnter", function(self)
    if not GameTooltip then return end
    local t = type(text) == "function" and text() or text
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    if type(t) == "table" then
      GameTooltip:SetText(t.title or "", 1, 1, 1, 1, true)
      if t.state then GameTooltip:AddLine(t.state, t.on and 0.4 or 0.6, t.on and 1 or 0.6, t.on and 0.4 or 0.6, true) end
      if t.text then GameTooltip:AddLine(t.text, 0.85, 0.85, 0.85, true) end
      if t.click then GameTooltip:AddLine(t.click, 0.5, 0.5, 0.5, true) end
    else
      GameTooltip:SetText(t or "", 1, 1, 1, 1, true)
    end
    GameTooltip:Show()
  end)
  frame:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
end
Browser.Tip = tip

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
    selected = nil, listOff = 0, treeOff = 0, detailOff = 0, rowsData = {}, nodesData = {}, cols = {} }, B)
  local saved = spec.splitKey and Wd.Conf(spec.splitKey).detailH
  b.detailH = num(saved, DETAIL_H)

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
    tip(b.filterBtn, function() return { title = L["Filters"], text = L["Narrow the list: what to show, what to leave out."],
      click = L["Click: the filter menu (a * on the button: something is hidden)."] } end)
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
  list.rows, list.heads = {}, {}
  list:EnableMouseWheel(true)
  list:SetScript("OnMouseWheel", function(_, delta) b:ScrollList(b.listOff - delta * 3) end)
  list.bar = Wd.VScroll(list, function(off) b:ScrollList(off, true) end)
  list.bar:SetPoint("TOPRIGHT", list, "TOPRIGHT", 0, -HEAD_H)
  list.bar:SetPoint("BOTTOMRIGHT", list, "BOTTOMRIGHT", 0, 0)
  list.empty = list:CreateFontString(nil, "OVERLAY", "GameFontDisable")
  list.empty:SetPoint("TOP", 0, -HEAD_H - 20)
  b.list = list

  -- the detail pane
  local d = panel(parent, 0.3)
  d.title = d:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  d.title:SetPoint("TOPLEFT", 8, -6)
  d.title:SetPoint("TOPRIGHT", -8, -6)
  d.title:SetJustifyH("LEFT")
  d.text = d:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  d.text:SetPoint("TOPLEFT", d.title, "BOTTOMLEFT", 0, -4)
  d.text:SetPoint("TOPRIGHT", d.title, "BOTTOMRIGHT", 0, -4)
  d.text:SetJustifyH("LEFT")
  d.text:SetJustifyV("TOP")
  d.text:SetSpacing(1)
  d.items = {}
  d:EnableMouseWheel(true)
  d:SetScript("OnMouseWheel", function(_, delta) b.detailOff = b.detailOff - delta; b:DrawDetail() end)
  b.detail = d

  -- the splitter between them (0.4.0, the user: the detail pane "takes a bit too small vertical space while the
  -- catalog pane above it takes a bit too much"): drag it; double-click puts it back
  local sp = CreateFrame("Button", nil, parent)
  sp:SetHeight(SPLIT_H)
  local grip = sp:CreateTexture(nil, "ARTWORK")
  grip:SetPoint("CENTER")
  grip:SetSize(40, 2)
  grip:SetColorTexture(0.6, 0.6, 0.6, 0.6)
  local hl = sp:CreateTexture(nil, "HIGHLIGHT")
  hl:SetAllPoints()
  hl:SetColorTexture(1, 0.82, 0, 0.18)
  sp:RegisterForClicks("LeftButtonUp")
  sp:SetScript("OnMouseDown", function(self)
    local _, y = GetCursorPosition()
    self.dragY, self.dragH = (y or 0) / max(self:GetEffectiveScale(), 0.01), b.detailH
    self:SetScript("OnUpdate", function()
      local _, cy = GetCursorPosition()
      cy = (cy or 0) / max(self:GetEffectiveScale(), 0.01)
      b:SetDetailHeight(self.dragH + (cy - self.dragY), true)
    end)
  end)
  sp:SetScript("OnMouseUp", function(self)
    self:SetScript("OnUpdate", nil)
    b:SetDetailHeight(b.detailH)                -- saved
  end)
  sp:SetScript("OnDoubleClick", function() b:SetDetailHeight(DETAIL_H) end)
  tip(sp, function() return { title = L["Splitter"], text = L["Drag up or down: more room for the list or for the details below."],
    click = L["Double-click: back to the usual split."] } end)
  b.splitter = sp

  -- the action bar
  b.footer = parent:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  b.footer:SetPoint("BOTTOMLEFT", 10, 10)
  b.footer:SetJustifyH("LEFT")
  b.footer:SetWordWrap(false)
  b.actionBtns, b.actionPills = {}, {}

  b:Layout()
  parent:HookScript("OnSizeChanged", function() b:Layout(); b:Refresh() end)
  return b
end

---------------------------------------------------------------------------
-- Geometry (the content frame is sized by the window host; the fake client gives anchored frames no size)
---------------------------------------------------------------------------

--- The detail pane's height within its bounds: at least DETAIL_MIN, and the list keeps LIST_MIN_ROWS rows.
function B:ClampDetail(h)
  local total = num(self.parent:GetHeight(), 400) - TOP_H - (BAR_H + GAP) - GAP - SPLIT_H
  local most = max(DETAIL_MIN, total - HEAD_H - LIST_MIN_ROWS * ROW_H)
  return floor(min(max(h, DETAIL_MIN), most) + 0.5)
end

function B:SetDetailHeight(h, dragging)
  self.detailH = self:ClampDetail(h)
  if not dragging and self.spec.splitKey then
    Wd.Conf(self.spec.splitKey).detailH = self.detailH ~= DETAIL_H and self.detailH or nil
  end
  self:Layout()
  self:Draw()
end

function B:Layout()
  local list, d, sp = self.list, self.detail, self.splitter
  local dh = self:ClampDetail(self.detailH)
  list:ClearAllPoints()
  list:SetPoint("TOPLEFT", self.tree, "TOPRIGHT", GAP, 0)
  list:SetPoint("BOTTOMRIGHT", self.parent, "BOTTOMRIGHT", -4, BAR_H + GAP + dh + SPLIT_H)
  sp:ClearAllPoints()
  sp:SetPoint("TOPLEFT", list, "BOTTOMLEFT", 0, 0)
  sp:SetPoint("TOPRIGHT", list, "BOTTOMRIGHT", 0, 0)
  d:ClearAllPoints()
  d:SetPoint("TOPLEFT", sp, "BOTTOMLEFT", 0, 0)
  d:SetPoint("BOTTOMRIGHT", self.parent, "BOTTOMRIGHT", -4, BAR_H + GAP)
  self.layoutDH = dh
end

function B:ListWidth()
  local w = num(self.parent:GetWidth(), 600)
  return max(w - 4 - TREE_W - GAP - 4, 100)
end

function B:VisibleRows()
  local h = num(self.parent:GetHeight(), 400)
  local listH = h - TOP_H - (BAR_H + GAP + (self.layoutDH or self.detailH) + SPLIT_H)
  return max(1, floor((listH - HEAD_H) / ROW_H))
end

function B:TreeRows()
  local h = num(self.parent:GetHeight(), 400)
  return max(1, floor((h - TOP_H - BAR_H - GAP - 8) / ROW_H))
end

function B:DetailRows(textH)
  return max(1, floor(((self.layoutDH or self.detailH) - 28 - textH) / ITEM_H))
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
      r.hl = r:CreateTexture(nil, "HIGHLIGHT")
      r.hl:SetAllPoints()
      r.hl:SetColorTexture(1, 1, 1, 0.08)
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
      if node.head then
        -- a caption: small capitals in grey, no count, not clickable
        r.text:SetText(node.text:upper())
        color(r.text, CAPTION)
        r.sel:Hide()
        r.hl:SetShown(false)
        r:SetScript("OnClick", nil)
      else
        r.text:SetText(node.count and (node.text .. "  |cff808080" .. node.count .. "|r") or node.text)
        color(r.text, on and GOLD or (node.grey and GREY or WHITE))
        r.sel:SetShown(on)
        r.hl:SetShown(true)
        r:SetScript("OnClick", function()
          self.node, self.listOff, self.selected = node.key, 0, nil
          self:Refresh()
        end)
      end
      r.key = node.key
      r:Show()
    else
      r:Hide()
    end
  end
  for i = n + 1, #tree.rows do tree.rows[i]:Hide() end
end

--- The column set of the current node.
function B:ColumnSpec()
  local c = self.spec.columns
  if type(c) == "function" then c = c(self.node) end
  return c or {}
end

--- Column x offsets and widths: fixed ones as given, the flexible one takes the rest.
function B:Columns()
  local cols, total = self:ColumnSpec(), self:ListWidth() - SB_W - 8
  local used = 0
  for _, c in ipairs(cols) do if c.width then used = used + c.width + 6 end end
  local out, x = {}, 6
  for i, c in ipairs(cols) do
    local w = c.width or max(total - used - 6, 60)
    out[i] = { x = x, w = w, col = c }
    x = x + w + 6
  end
  return out
end

function B:Head(i)
  local list = self.list
  local h = list.heads[i]
  if h then return h end
  h = CreateFrame("Button", nil, list)
  h:SetHeight(HEAD_H)
  h.text = h:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  h.text:SetAllPoints()
  local hl = h:CreateTexture(nil, "HIGHLIGHT")
  hl:SetAllPoints()
  hl:SetColorTexture(1, 1, 1, 0.08)
  h:SetScript("OnClick", function(btn)
    local key = btn.colKey
    if self.sortKey == key then self.sortDesc = not self.sortDesc else self.sortKey, self.sortDesc = key, false end
    self:Refresh()
  end)
  tip(h, function() return { title = h.text:GetText() or "", click = L["Click: sort by this column; again: the other way."] } end)
  list.heads[i] = h
  return h
end

function B:DrawList()
  local list, rows = self.list, self.rowsData
  local cols = self:Columns()
  for i, c in ipairs(cols) do
    local h = self:Head(i)
    h.colKey = c.col.key
    h:ClearAllPoints()
    h:SetPoint("TOPLEFT", list, "TOPLEFT", c.x, 0)
    h:SetWidth(c.w)
    h.text:SetJustifyH(c.col.align or "LEFT")
    local mark = ""
    if self.sortKey == c.col.key then mark = self.sortDesc and " v" or " ^" end
    h.text:SetText((c.col.title or "") .. mark)
    h:Show()
  end
  for i = #cols + 1, #list.heads do list.heads[i]:Hide() end
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
      for j = #cols + 1, #r.cells do r.cells[j]:Hide() end
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
    items[#items + 1] = { text = a.text, disabled = a.disabled, checked = a.status and (a.on == true) or nil,
      tip = type(a.tip) == "string" and a.tip or nil, func = function() a.func(anchor) end }
  end
  ns.Menu.Show(anchor, items)
end

function B:SelectedRow()
  for _, row in ipairs(self.rowsData) do if row.key == self.selected then return row end end
  return nil
end

--- A detail row: its text, a value on the right, and a button or a status pill at the far right.
local function detailItem(self, d, i)
  local r = CreateFrame("Frame", nil, d)
  r:SetHeight(ITEM_H)
  r.text = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  r.text:SetPoint("LEFT", 0, 0)
  r.text:SetJustifyH("LEFT")
  r.text:SetWordWrap(false)
  r.value = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  r.value:SetJustifyH("RIGHT")
  r.value:SetWordWrap(false)
  r.btn = Wd.Button(r, "", 80, nil)
  r.btn:SetHeight(18)
  r.btn:SetPoint("RIGHT", 0, 0)
  r.pill = Wd.Status(r, 90, nil)
  r.pill:SetHeight(18)
  r.pill:SetPoint("RIGHT", 0, 0)
  r:EnableMouse(true)
  r:EnableMouseWheel(true)
  r:SetScript("OnMouseWheel", function(_, delta) self.detailOff = self.detailOff - delta; self:DrawDetail() end)
  d.items[i] = r
  return r
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
  -- the text's real height where the client gives it (it wraps), else a guess by length
  local textH = d.text.GetStringHeight and d.text:GetStringHeight()
  if type(textH) ~= "number" or textH <= 0 or #lines == 0 then
    textH = 0
    for _, l in ipairs(lines) do textH = textH + LINE_H * (1 + floor(#l / 110)) end
  end
  local items = info.items or {}
  local n = self:DetailRows(textH)
  self.detailOff = max(0, min(self.detailOff, #items - n))
  local top = -10 - 14 - textH - 4
  for i = 1, n do
    local item = items[self.detailOff + i]
    local r = d.items[i] or detailItem(self, d, i)
    r:ClearAllPoints()
    r:SetPoint("TOPLEFT", d, "TOPLEFT", item and item.head and 8 or 16, top - (i - 1) * ITEM_H)
    r:SetPoint("TOPRIGHT", d, "TOPRIGHT", -8, top - (i - 1) * ITEM_H)
    if item then
      r.text:SetText(item.text or "")
      color(r.text, item.grey and GREY or (item.head and GOLD or WHITE))
      tip(r, item.tip)
      local right                                  -- what the value sits left of
      local bt, st = item.button, item.status
      if st then
        r.btn:Hide()
        r.pill:SetState(st.text, st.on)
        Wd.FitWidth(r.pill, 70, 30)
        r.pill:SetScript("OnClick", function(p) if st.func then st.func(p) end end)
        r.pill:SetEnabled(st.func ~= nil and not st.disabled)
        tip(r.pill, st.tip)
        r.pill:Show()
        right = r.pill
      elseif bt then
        r.pill:Hide()
        r.btn:SetText(bt.text)
        Wd.FitWidth(r.btn, 70, 20)
        r.btn:SetScript("OnClick", function(btn) bt.func(btn) end)
        tip(r.btn, bt.tip)
        r.btn:SetEnabled(not bt.disabled)
        r.btn:Show()
        right = r.btn
      else
        r.btn:Hide()
        r.pill:Hide()
      end
      r.value:ClearAllPoints()
      if right then r.value:SetPoint("RIGHT", right, "LEFT", -10, 0) else r.value:SetPoint("RIGHT", r, "RIGHT", -2, 0) end
      r.value:SetText(item.value or "")
      color(r.value, item.grey and GREY or WHITE)
      r.text:ClearAllPoints()
      r.text:SetPoint("LEFT", 0, 0)
      if item.value and item.value ~= "" then
        r.text:SetPoint("RIGHT", r.value, "LEFT", -8, 0)
      elseif right then
        r.text:SetPoint("RIGHT", right, "LEFT", -8, 0)
      else
        r.text:SetPoint("RIGHT", r, "RIGHT", 0, 0)
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

local function placeRight(btn, prev, parent)
  btn:ClearAllPoints()
  if prev then btn:SetPoint("RIGHT", prev, "LEFT", -4, 0) else btn:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -6, 4) end
end

function B:DrawActions()
  local row = self:SelectedRow()
  local all = self.spec.actions and self.spec.actions(row) or {}
  local shown, more = {}, {}
  for _, a in ipairs(all) do if a.more then more[#more + 1] = a else shown[#shown + 1] = a end end
  local prev, nb, np = nil, 0, 0
  -- More... (rightmost): the actions that don't need a button of their own, as a menu
  if #more > 0 then
    if not self.moreBtn then
      self.moreBtn = Wd.Button(self.parent, L["More..."], MORE_W, nil)
      self.moreBtn:SetHeight(22)
      tip(self.moreBtn, function() return { title = L["More..."], text = L["The other things you can do with the selected row."],
        click = L["Click: a menu of them (a right-click on the row shows every action)."] } end)
    end
    local m = self.moreBtn
    placeRight(m, nil, self.parent)
    m:SetScript("OnClick", function(btn)
      local items = {}
      for _, a in ipairs(more) do
        items[#items + 1] = { text = a.text, disabled = a.disabled, tip = type(a.tip) == "string" and a.tip or nil,
          func = function() a.func(btn) end }
      end
      ns.Menu.Show(btn, items)
    end)
    m:Show()
    prev = m
  elseif self.moreBtn then
    self.moreBtn:Hide()
  end
  for i = #shown, 1, -1 do                       -- right to left, so they read left to right
    local a = shown[i]
    local btn
    if a.status then
      np = np + 1
      btn = self.actionPills[np]
      if not btn then
        btn = Wd.Status(self.parent, 90, nil)
        btn:SetHeight(22)
        self.actionPills[np] = btn
      end
      btn:SetState(a.text, a.on)
      Wd.FitWidth(btn, 80, 34)
    else
      nb = nb + 1
      btn = self.actionBtns[nb]
      if not btn then
        btn = Wd.Button(self.parent, "", 90, nil)
        btn:SetHeight(22)
        self.actionBtns[nb] = btn
      end
      btn:SetText(a.text)
      Wd.FitWidth(btn, 80, 24)
    end
    placeRight(btn, prev, self.parent)
    btn:SetEnabled(not a.disabled)
    btn:SetScript("OnClick", function(b2) a.func(b2) end)
    tip(btn, a.tip)
    btn:Show()
    prev = btn
  end
  for k = nb + 1, #self.actionBtns do self.actionBtns[k]:Hide() end
  for k = np + 1, #self.actionPills do self.actionPills[k]:Hide() end
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
  self:Layout()                                -- (the window may have sized the tab since the last draw)
  local spec = self.spec
  self.nodesData = spec.nodes and spec.nodes() or {}
  local found, first = false, nil
  for _, node in ipairs(self.nodesData) do
    if not node.head then
      first = first or node.key
      if node.key == self.node then found = true end
    end
  end
  if not found then self.node = first end
  -- a node chosen from code (the Explorer opened on Trackers) scrolls into view in the tree
  if self.node ~= self.shownNode then
    self.shownNode = self.node
    for i, node in ipairs(self.nodesData) do
      if node.key == self.node then
        local n = self:TreeRows()
        if i <= self.treeOff or i > self.treeOff + n then self.treeOff = max(0, i - 2) end
        break
      end
    end
  end
  local cols = self:ColumnSpec()
  local has = false
  for _, c in ipairs(cols) do if c.key == self.sortKey then has = true end end
  if not has then self.sortKey, self.sortDesc = nil, false end      -- (another node, another set of columns)
  local rows = spec.rows(self.node, self.search) or {}
  if self.sortKey then
    local col
    for _, c in ipairs(cols) do if c.key == self.sortKey then col = c end end
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

--- Select a row by key (and its tree node when given); the detail pane and the actions follow. The list scrolls to it.
function B:Select(key, nodeKey)
  if nodeKey then self.node = nodeKey end
  self.selected = key
  self.detailOff = 0
  self:Refresh()
  for i, r in ipairs(self.rowsData) do
    if r.key == key then
      local n = self:VisibleRows()
      if i <= self.listOff or i > self.listOff + n then self:ScrollList(max(0, i - 1), true) end
      break
    end
  end
end

function B:SetSearch(text)
  self.searchBox:SetText(text or "")
  local h = self.searchBox:GetScript("OnTextChanged")
  if h then h(self.searchBox) end
end
