-- The run list and the summary card (Look layer). Newest first: date, label, duration, the headline reading.
-- Click a run for its summary: totals and rates, splits, top live tallies (e.g. items looted), best record.
-- /hc runs toggles it. The list is a window of UI/Windows.lua ("runs": a tab of the Hard Counters window by
-- default); the card is a resizable popup of its own.
local ADDON, ns = ...

local HC, L, U, Wd, Win = ns.HC, ns.L, ns.U, ns.Widgets, ns.Windows
local format, date, floor, max = string.format, ns.wow.date, math.floor, math.max
local ROW_H, TOP, BOTTOM = 18, 24, 26
local ID = "runs"

local list, card
local runs = {}
local offset = 0

local function itemName(id)
  if type(id) ~= "number" then return tostring(id) end
  local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
  local name = getInfo and getInfo(id)
  if not name and C_Item and C_Item.RequestLoadItemDataByID then C_Item.RequestLoadItemDataByID(id) end
  return name or ("item " .. id)
end

local function memberName(counterId, key)
  local c = ns.counters[counterId]
  if c and (c.runLive and c.runLive.member == "item") then return itemName(key) end
  if counterId == ns.TIME_ID or (c and c.dimIndex and c.dimIndex.zone and type(key) == "number") then return HC:ZoneName(key) end
  return tostring(key)
end

local function fmtValue(counterId, v)
  local c = ns.counters[counterId]
  local f = c and c.formatter
  if f == "money" then return U.money(v) elseif f == "duration" then return U.duration(v) end
  return U.number(v)
end

--- The summary card as text (shown in a window and copyable).
function ns.RunSummaryText(rec)
  local out = {}
  out[#out + 1] = format("%s  %s", rec.label or ("Run #" .. rec.id), rec.charName and ("(" .. rec.charName .. ")") or "")
  out[#out + 1] = format("%s - %s   active %s, elapsed %s%s", date("%Y-%m-%d %H:%M", rec.start), date("%H:%M", rec.stop),
    U.duration(rec.activeSeconds), U.duration(rec.elapsed), rec.mainZone and ("   in " .. HC:ZoneName(rec.mainZone)) or "")
  out[#out + 1] = ""
  for _, id in ipairs(ns.readingOrder) do
    local _, text = Wd.RecordReading(ns.readings[id], rec)
    out[#out + 1] = format("  %-24s %s", ns.readings[id].title, text)
  end
  out[#out + 1] = ""
  for _, cid in ipairs(ns.counterOrder) do
    local d = rec.deltas[cid]
    local c = ns.counters[cid]
    if d and c and cid ~= ns.TIME_ID and ((d.sum and d.sum ~= 0) or d.stop ~= nil) then
      if c.kind == "stock" then
        out[#out + 1] = format("%s: %s -> %s", c.title, fmtValue(cid, d.start or 0), fmtValue(cid, d.stop or 0))
      else
        out[#out + 1] = format("%s: %s", c.title, fmtValue(cid, d.sum or 0))
        for dim, m in pairs(d.by or {}) do
          local keys = {}
          for k in pairs(m) do keys[#keys + 1] = k end
          table.sort(keys, function(a, b) return m[a] > m[b] end)
          local parts = {}
          for i = 1, math.min(#keys, 6) do parts[#parts + 1] = format("%s %s", memberName(cid, keys[i]), fmtValue(cid, m[keys[i]])) end
          if #parts > 0 then out[#out + 1] = format("    by %s: %s", dim, table.concat(parts, ", ")) end
        end
      end
    end
  end
  for cid, Lv in pairs(rec.live or {}) do
    if Lv.m then
      local keys = {}
      for k in pairs(Lv.m) do keys[#keys + 1] = k end
      table.sort(keys, function(a, b) return Lv.m[a] > Lv.m[b] end)
      out[#out + 1] = ""
      out[#out + 1] = format("%s (%d kinds):", ns.counters[cid] and ns.counters[cid].title or cid, #keys)
      for i = 1, math.min(#keys, 15) do out[#out + 1] = format("    %s x%s", memberName(cid, keys[i]), U.number(Lv.m[keys[i]])) end
    end
    if Lv.max then
      out[#out + 1] = format("Best %s: %s%s", ns.counters[cid] and ns.counters[cid].title or cid, fmtValue(cid, Lv.max.v),
        Lv.max.item and (" (" .. itemName(Lv.max.item) .. ")") or "")
    end
  end
  if rec.splits then
    out[#out + 1] = ""
    out[#out + 1] = L["Splits"] .. ":"
    local hid = Wd.HeadlineId()
    for i, sp in ipairs(rec.splits) do
      local _, text = "", "-"
      if hid then _, text = Wd.RecordReading(ns.readings[hid], sp) end
      out[#out + 1] = format("  %d. %-16s active %s  %s", i, sp.label or "", U.duration(sp.activeSeconds), text)
    end
  end
  return table.concat(out, "\n")
end

local function showCard(rec)
  if not card then
    card = Wd.Window("HardCountersRunCard", 460, 360, nil, nil)
    local scroll = CreateFrame("ScrollFrame", nil, card, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 10, -28)
    scroll:SetPoint("BOTTOMRIGHT", -30, 34)
    local edit = CreateFrame("EditBox", nil, scroll)
    edit:SetMultiLine(true)
    edit:SetMaxLetters(0)
    edit:SetAutoFocus(false)
    edit:SetFontObject(GameFontHighlightSmall)
    edit:SetWidth(400)
    edit:SetScript("OnEscapePressed", function(self) self:ClearFocus(); card:Hide() end)
    edit:SetScript("OnTextChanged", function(self, user) if user then self:SetText(card.text or "") end end)
    scroll:SetScrollChild(edit)
    card.edit = edit
    card.title = Wd.Text(card, "GameFontNormal", "TOPLEFT", 10, -8, 380)
    card.del = Wd.Button(card, L["Delete"], 70, function()
      if card.rec then HC:DeleteRun(card.rec.id); card:Hide(); ns.RefreshRunList() end
    end)
    card.del:SetPoint("BOTTOMLEFT", 8, 8)
    card.copy = Wd.Button(card, L["Select all"], 80, function() card.edit:SetFocus(); card.edit:HighlightText() end)
    card.copy:SetPoint("LEFT", card.del, "RIGHT", 4, 0)
    Wd.Remember(card, "runCard", 300, 200, function(self) edit:SetWidth(max(self:GetWidth() - 60, 100)) end)
    tinsert(UISpecialFrames, "HardCountersRunCard")
  end
  card.rec = rec
  card.text = ns.RunSummaryText(rec)
  card.title:SetText(L["Run summary"])
  card.edit:SetText(card.text)
  card:Show()
end

--- Rows that fit the current height, created on first use; they stretch with the width.
local function visibleRows()
  local n = max(floor((list:GetHeight() - TOP - BOTTOM) / ROW_H), 1)
  for i = #list.rows + 1, n do
    local row = CreateFrame("Button", nil, list)
    row:SetHeight(ROW_H)
    row:SetPoint("TOPLEFT", 10, -TOP - (i - 1) * ROW_H)
    row:SetPoint("TOPRIGHT", -10, -TOP - (i - 1) * ROW_H)
    row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    row.text = Wd.Text(row, "GameFontHighlightSmall", "LEFT", 0, 0)
    row.text:SetPoint("RIGHT")
    row:SetScript("OnClick", function(self) if self.rec then showCard(self.rec) end end)
    list.rows[i] = row
  end
  return n
end

local function refresh()
  if not (list and list:IsShown()) then return end
  runs = HC:Runs()
  local hid = Wd.HeadlineId()
  local r = hid and ns.readings[hid]
  list.header:SetText(format("%-17s %-18s %8s  %s", L["When"], L["Run"], L["Active"], r and r.title or ""))
  local visible = visibleRows()
  if offset > max(0, #runs - visible) then offset = max(0, #runs - visible) end
  for i, row in ipairs(list.rows) do
    local rec = i <= visible and runs[i + offset] or nil
    if rec then
      local _, text = "", ""
      if r then _, text = Wd.RecordReading(r, rec) end
      row.text:SetText(format("%-17s %-18s %8s  %s", date("%Y-%m-%d %H:%M", rec.start), (rec.label or ("#" .. rec.id)):sub(1, 18),
        U.duration(rec.activeSeconds), text))
      row.rec = rec
      row:Show()
    else
      row.rec = nil
      row:Hide()
    end
  end
  list.count:SetText(format(L["%d runs kept"], #runs))
end
ns.RefreshRunList = refresh

local function build(f)
  list = f
  f.header = Wd.Text(f, "GameFontNormalSmall", "TOPLEFT", 10, -6)
  f.header:SetPoint("TOPRIGHT", -10, -6)
  f.rows = {}
  f:EnableMouseWheel(true)
  f:SetScript("OnMouseWheel", function(_, delta)
    offset = max(0, offset - delta * 3)
    refresh()
  end)
  f.count = Wd.Text(f, "GameFontDisableSmall", "BOTTOMLEFT", 10, 10, 300)
  f:SetScript("OnSizeChanged", refresh)
end

Win.Register(ID, {
  title = L["Runs"], width = 480, height = 300, minWidth = 380, minHeight = 160,
  build = build, onShow = refresh,
  migrate = function(c, s)
    if type(s.runListPos) == "table" and s.runListPos[1] then c.pos = { s.runListPos[1], s.runListPos[2] or 0, s.runListPos[3] or 0 } end
  end,
})

function ns.ToggleRunList() Win.Show(ID, nil) end
function HC:ToggleRunList() ns.ToggleRunList() end

local owner = {}
HC.RegisterCallback(owner, "HC_RUN_STOPPED", function() refresh() end)
HC.RegisterCallback(owner, "HC_RUN_DELETED", function() refresh() end)

ns.AddSlash("runs", function() ns.ToggleRunList() end, L["show the run list"])
