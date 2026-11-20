-- The Ledger window (DESIGN §4.1, the "Look" layer): income by source, spending by sink, net, gold owned, gold per
-- active hour; for today, this week, month, year or lifetime; this character or the account.
-- A Hard Counters window ("hcfarm:ledger"): a tab of the shared Hard Counters window by default, or on its own;
-- Hard Counters gives it the frame, resizing, BlizzMove and the saved size. /hc ledger toggles it.
-- Only Hard Counters' public API. Small dimensions (≤ 16 members, open buckets), so plain Query is fine here.
local ADDON, ns = ...

local HC = HardCounters
if not (HC and ns.ID and HC.Supports and HC:Supports("windows")) then return end

local ID = ns.ID
local WINDOW = "hcfarm:ledger"
local format, floor, max = string.format, math.floor, math.max
local PERIODS = {
  { key = "day", label = "Today" }, { key = "thisweek", label = "This week" }, { key = "month", label = "This month" },
  { key = "year", label = "This year" }, { key = "lifetime", label = "Lifetime" },
}
local LABELS = {
  loot = "Loot", quest = "Quests", vendor = "Vendor", mail = "Mail", ah = "Auction house", trade = "Trade",
  other = "Other", repair = "Repairs", training = "Training", travel = "Travel", none = "Unknown",
  alts = "Your characters",
}
local INFERRED = { vendor = true, mail = true, ah = true, trade = true, repair = true, training = true, travel = true }
local ROWS, ROW_H = 10, 16
-- layout (pixels from the top of the content). The period buttons and the Character/Account toggle share one row
-- (FM-13: the toggle floated alone above Spending); the totals follow the last used row (they sat under 10 fixed
-- slots, most of them empty).
local BTN_Y, HEAD_Y = -6, -32
local ROWS_Y = -50
local BTN_W, BTN_STEP, SCOPE_W = 76, 78, 84
local function totalY(used) return ROWS_Y - math.max(used, 1) * ROW_H - 8 end
local MIN_W, MIN_H = 12 + #PERIODS * BTN_STEP + 8 + SCOPE_W + 12, -totalY(ROWS) + 100

local win
local state = { period = 1, account = false }

local function q(view, overrides)
  local rows = HC:Query(view, overrides)
  return rows
end

--- The account view leaves money between your own characters out (FM-16): it moved, nobody earned or spent it.
--- Drops the "alts" row from `rows` and takes it off the total, in place.
local function withoutAlts(rows)
  if not rows then return rows end
  for i = #rows, 1, -1 do
    if rows[i].label == "alts" then
      rows.total = (rows.total or 0) - (rows[i].value or 0)
      table.remove(rows, i)
    end
  end
  return rows
end
ns.LedgerWithoutAlts = withoutAlts

local function fill(col, rows)
  for i = 1, ROWS do
    local r = rows and rows[i]
    local line = col[i]
    if r then
      local name = LABELS[r.label] or tostring(r.label)
      if INFERRED[r.label] then name = name .. "*" end
      line.name:SetText(name)
      line.value:SetText(HC:FormatMoney(r.value))
    else
      line.name:SetText("")
      line.value:SetText("")
    end
  end
end

local TRACKER = "hcfarm:ledger"

local function refresh()
  if not (win and win:IsShown()) then return end
  -- off (Farmer's trackers start off): one line and a button in place of the numbers (TRACKERS_AND_BOARDS §2.2)
  local on = not HC.IsTrackerOn or HC:IsTrackerOn(TRACKER)
  win.offPanel:SetShown(not on)
  if not on then return end
  local p = PERIODS[state.period]
  local o = { grain = p.key, entity = state.account and "account" or nil }
  local inc = q("hcfarm:ledger.in", o)
  local out = q("hcfarm:ledger.out", o)
  if state.account then inc, out = withoutAlts(inc), withoutAlts(out) end
  fill(win.inCol, inc)
  fill(win.outCol, out)
  win.used = math.min(ROWS, math.max(inc and #inc or 0, out and #out or 0))
  ns.PlaceLedgerTotals(win)
  local tin, tout = inc and inc.total or 0, out and out.total or 0
  win.inTotal:SetText("In: " .. HC:FormatMoney(tin))
  win.outTotal:SetText("Out: " .. HC:FormatMoney(tout))
  local net = tin - tout
  win.net:SetText(format("Net: %s%s|r", net >= 0 and "|cff60ff60+" or "|cffff6060", HC:FormatMoney(net)))
  local owned = q({ counter = ID.owned, measure = "last", grain = p.key, entity = o.entity })
  local twa = q({ counter = ID.owned, measure = "twa", grain = p.key, entity = o.entity })
  win.owned:SetText(format("Gold owned: %s   (time-weighted %s)", HC:FormatMoney(owned and owned.total),
    HC:FormatMoney(twa and twa.total)))
  local ph = q("hcfarm:goldph.today", o)
  win.rate:SetText(format("Gold per active hour: %s   (active %s)", ph and ph.total and HC:FormatMoney(ph.total) or "-",
    HC:FormatDuration(ph and ph.activeSeconds or 0)))
  -- the chosen period looks selected (lit, white text), not disabled (FM-13: it read as greyed out)
  for i, b in ipairs(win.periodBtns) do
    local fs = b:GetFontString()
    if i == state.period then
      b:LockHighlight()
      if fs then fs:SetTextColor(1, 1, 1) end
    else
      b:UnlockHighlight()
      if fs then fs:SetTextColor(1, 0.82, 0) end
    end
  end
  win.scopeBtn:SetText(state.account and "Account" or "Character")
end
ns.RefreshLedger = refresh

local function column(parent)
  local col = {}
  for i = 1, ROWS do
    col[i] = {
      name = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"),
      value = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"),
    }
    col[i].name:SetJustifyH("LEFT")
    col[i].value:SetJustifyH("RIGHT")
  end
  return col
end

--- Income on the left half, spending on the right half; both follow the width.
local function place(f)
  local half = floor((max(f:GetWidth(), MIN_W) - 24) / 2)
  local xs = { 12, 12 + half }
  for c, col in ipairs({ f.inCol, f.outCol }) do
    local x = xs[c]
    f.heads[c]:ClearAllPoints()
    f.heads[c]:SetPoint("TOPLEFT", x, HEAD_Y)
    for i, line in ipairs(col) do
      local y = ROWS_Y - (i - 1) * ROW_H
      line.name:ClearAllPoints()
      line.name:SetPoint("TOPLEFT", x, y)
      line.name:SetWidth(half - 112)
      line.value:ClearAllPoints()
      line.value:SetPoint("TOPLEFT", x + half - 112, y)
      line.value:SetWidth(100)
    end
  end
  f.totalsX2 = xs[2]
  ns.PlaceLedgerTotals(f)
end

--- The totals block sits under the last used row.
function ns.PlaceLedgerTotals(f)
  local y = totalY(f.used or ROWS)
  f.inTotal:ClearAllPoints()
  f.inTotal:SetPoint("TOPLEFT", 12, y)
  f.outTotal:ClearAllPoints()
  f.outTotal:SetPoint("TOPLEFT", f.totalsX2 or 12, y)
  f.net:ClearAllPoints()
  f.net:SetPoint("TOPLEFT", 12, y - 22)
  f.owned:ClearAllPoints()
  f.owned:SetPoint("TOPLEFT", 12, y - 46)
  f.rate:ClearAllPoints()
  f.rate:SetPoint("TOPLEFT", 12, y - 62)
end

local function build(f)
  win = f
  f.periodBtns = {}
  for i, p in ipairs(PERIODS) do
    local b = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    b:SetSize(BTN_W, 20)
    b:SetPoint("TOPLEFT", 12 + (i - 1) * BTN_STEP, BTN_Y)
    b:SetText(p.label)
    b:SetScript("OnClick", function() state.period = i; refresh() end)
    f.periodBtns[i] = b
  end
  f.scopeBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  f.scopeBtn:SetSize(SCOPE_W, 20)
  f.scopeBtn:SetPoint("TOPRIGHT", -12, BTN_Y)
  f.scopeBtn:SetScript("OnClick", function() state.account = not state.account; refresh() end)

  f.heads = {}
  for c, text in ipairs({ "Income", "Spending" }) do
    f.heads[c] = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.heads[c]:SetText(text)
  end
  f.inCol = column(f)
  f.outCol = column(f)
  f.inTotal = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  f.outTotal = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  f.net = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  f.owned = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  f.rate = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  local note = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  note:SetPoint("BOTTOMRIGHT", -24, 8)
  note:SetText("* inferred from open windows")
  -- the "off" panel covers the numbers while the Ledger tracker is off
  local off = CreateFrame("Frame", nil, f)
  off:SetAllPoints(f)
  off:SetFrameLevel(f:GetFrameLevel() + 10)
  off:EnableMouse(true)
  local bg = off:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  bg:SetColorTexture(0.05, 0.05, 0.07, 1)
  local line = off:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  line:SetPoint("TOPLEFT", 16, -20)
  line:SetPoint("RIGHT", off, "RIGHT", -16, 0)
  line:SetJustifyH("LEFT")
  line:SetText("The Ledger is off.")
  local tip = off:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  tip:SetPoint("TOPLEFT", line, "BOTTOMLEFT", 0, -8)
  tip:SetPoint("RIGHT", off, "RIGHT", -16, 0)
  tip:SetJustifyH("LEFT")
  tip:SetText("Turning it on keeps daily history for money in and out (Hard Counters' gold counters), so it can show "
    .. "today, this week, month, year and lifetime by source. History starts now: nothing before today can be "
    .. "filled in. About 20 KB a month.")
  local btn = CreateFrame("Button", nil, off, "UIPanelButtonTemplate")
  btn:SetSize(120, 22)
  btn:SetPoint("TOPLEFT", tip, "BOTTOMLEFT", 0, -12)
  btn:SetText("Turn it on")
  btn:SetScript("OnClick", function() HC:SetTrackerOn(TRACKER, true); refresh() end)
  off:Hide()
  f.offPanel = off
  place(f)
  f:SetScript("OnSizeChanged", place)
end

if HC.RegisterCallback then
  HC.RegisterCallback(ns, "HC_TRACKERS_CHANGED", function() refresh() end)
end

HC:RegisterWindow(WINDOW, {
  title = "Ledger",
  width = MIN_W + 20, height = MIN_H, minWidth = MIN_W, minHeight = MIN_H,
  build = build, onShow = refresh,
})

function ns.ToggleLedger() HC:ToggleWindow(WINDOW) end

local function command(msg)
  msg = (msg or ""):lower():gsub("%s+", "")
  if msg == "runs" and HC.ToggleRunList then HC:ToggleRunList() else ns.ToggleLedger() end
end

HC:RegisterSlash("ledger", command, "show or hide Farmer's Ledger", "Farmer")
