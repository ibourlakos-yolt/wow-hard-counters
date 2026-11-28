-- The Overview tab (0.4.0, the user: "a summary page for all of the entities of concern and their status given the
-- current user and account's choices ... one of the secondary tabs at the bottom"). Not the Overview of 0.2 to 0.3
-- (that one is the Boards tab now, UI/BoardsTab.lua). One page, read top to bottom, refreshed once a second while it
-- is on screen:
--   the head line   version and its channel (beta, release...), the character, the profile
--   Needs a look    only what is true now, each with the one click that fixes it: no pack chosen, a pack waiting for a
--                   reload, tiles whose tracker is off, a board on the HUD but off screen or tiny, storage read-only,
--                   a pre-release build without Diagnostics
--   Packs, Trackers, Boards, Stint, This session, History and storage, Diagnostics: a line each (a board each), its
--                   state as a lamp (green: on, grey: off, amber: needs a look), and one action that goes there
-- Read-only lamps are W.Status pills that don't click; the switches that do (a board's On HUD) are the same pills as
-- in the Boards tab. Everything here is also somewhere else: this page only gathers it.
-- luacheck: no max line length (prose: one sentence, one string)
local ADDON, ns = ...

local HC, L, Wd = ns.HC, ns.L, ns.Widgets
local format, floor, max = string.format, math.floor, math.max

local ID = "overview"
local ROW_H, HEAD_H, PAD, MIN_W, MIN_H = 22, 26, 10, 600, 360
local LABEL_W, PILL_W = 170, 120
local content, ticker
local rows, heads = {}, {}
local contentH = MIN_H
local sizes, sizesAt = nil, 0

local function BM() return ns.BoardModel end
local function Bo() return ns.Boards end

---------------------------------------------------------------------------
-- Rows: a label, a lamp with a word, a value, one action
---------------------------------------------------------------------------

local function newRow(i)
  local r = CreateFrame("Frame", nil, content)
  r:SetHeight(ROW_H)
  r.label = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  r.label:SetPoint("LEFT", 16, 0)
  r.label:SetWidth(LABEL_W)
  r.label:SetJustifyH("LEFT")
  r.label:SetWordWrap(false)
  r.pill = Wd.Status(r, PILL_W, nil)
  r.pill:SetHeight(18)
  r.pill:SetPoint("LEFT", 16 + LABEL_W + 6, 0)
  r.value = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  r.value:SetJustifyH("LEFT")
  r.value:SetWordWrap(false)
  r.btn = Wd.Button(r, "", 90, nil)
  r.btn:SetHeight(20)
  r.btn:SetPoint("RIGHT", -6, 0)
  -- (D0) right-click anywhere on the row: its one action
  Wd.RightMenu(r, function(self)
    local b = self.btn
    local click = b:IsShown() and b:GetScript("OnClick")
    if not click then return nil end
    return { { text = self.label:GetText() or "", title = true }, { text = b:GetText() or "", func = function() click(b) end } }
  end)
  rows[i] = r
  return r
end

local function newHead(i)
  local h = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  h:SetJustifyH("LEFT")
  heads[i] = h
  return h
end

--- The page as a list of entries: { head = text } or { label, state, on, value, action = { text, func, tip }, tip,
--- switch = func (the pill clicks) }.
local function entries()
  local out = {}
  local function head(text) out[#out + 1] = { head = text } end
  local function row(e) out[#out + 1] = e end
  local M = BM()

  -- warnings first: what needs a look, with the click that fixes it
  local warn = {}
  local P = ns.Packs
  local packs = P and P.List() or {}
  if P and not P.Chosen() then
    warn[#warn + 1] = { label = L["No packs chosen"], value = L["only gold and experience are counted"],
      action = { text = L["Packs"], func = function() ns.ShowPacks(true) end, tip = L["The Packs tab: tick the packs you want."] } }
  end
  for _, p in ipairs(packs) do
    if not p.builtin and not p.missing and p.enabled ~= p.loaded then
      warn[#warn + 1] = { label = format(L["%s waits for a reload"], L[p.title]), value = p.loaded and L["off after a reload"] or L["on after a reload"],
        action = { text = L["Reload now"], func = function() ns.wow.reload() end, tip = L["Reloads the interface (the same as /reload): a few seconds, nothing is lost."] } }
    end
  end
  local offTiles, offTrackers = 0, {}
  if M and ns.charSettings then
    for _, b in ipairs(M.Store().list) do
      for _, t in ipairs(b.tiles) do
        local r = t.kind == "reading" and ns.readings[t.reading]
        if r and r.tracker and not HC:IsTrackerOn(r.tracker) then
          offTiles = offTiles + 1
          offTrackers[r.tracker] = true
        end
      end
      local _, why = Bo().Status(b)
      if b.shown and (why == "offscreen" or why == "tiny") then
        warn[#warn + 1] = { label = format(L["%s may be lost"], b.name), value = why == "tiny" and L["very small"] or L["off the screen"],
          action = { text = L["Reset position"], func = function() Bo().ResetPosition(b) end, tip = L["Back to the centre of the screen at its normal size."] } }
      end
    end
  end
  if offTiles > 0 then
    warn[#warn + 1] = { label = format(L["%d tiles show nothing"], offTiles), value = L["their tracker is switched off"],
      action = { text = L["Turn them on"], func = function()
        for tid in pairs(offTrackers) do ns.ActivateTracker(tid, true) end
      end, tip = L["Switch those trackers back on, with daily history unless you chose otherwise."] } }
  end
  if ns.db and ns.db:IsReadOnly() then
    warn[#warn + 1] = { label = L["Storage is read-only"], value = L["nothing new is saved this session"],
      action = { text = L["Report..."], func = function() if ns.ShowReportBox then ns.ShowReportBox() end end, tip = L["The Report a problem tab: a report to paste in a bug report."] } }
  end
  local F = ns.FieldNotes
  if F and F.PreRelease() and not F.DiagnosticsLoaded() then
    warn[#warn + 1] = { label = L["A test version without Diagnostics"], value = L["reports say less than they could"],
      action = { text = L["Packs"], func = function() ns.ShowPacks(true) end, tip = L["Tick Diagnostics in the Packs tab: a bug report then carries the game's API checks."] } }
  end
  if #warn > 0 then
    head(L["Needs a look"] .. format(" (%d)", #warn))
    for _, w in ipairs(warn) do w.state, w.on = L["look"], "warn"; row(w) end
  end

  -- packs
  head(L["Packs"])
  for _, p in ipairs(packs) do
    local on = p.loaded and true or false
    row({ label = L[p.title], state = p.builtin and L["built in"] or (p.missing and L["can't load"] or (on and L["loaded"] or L["off"])),
      on = p.missing and "warn" or on,
      value = (#p.trackers > 0) and format(L["%d of %d trackers counting"], p.on, #p.trackers) or "" })
  end
  row({ label = L["Choose packs"], value = "", action = { text = L["Packs"], func = function() ns.ShowPacks(true) end, tip = L["The Packs tab: tick the packs you want."] } })

  -- trackers
  local ts = HC:Trackers()
  local on, hist = 0, 0
  for _, t in ipairs(ts) do
    if t.on then on = on + 1 end
    if t.on and t.history ~= "off" then hist = hist + 1 end
  end
  head(L["Trackers"])
  local bytes = sizes and sizes.total or nil
  row({ label = L["Counting"], state = format("%d / %d", on, #ts), on = on > 0,
    value = format(L["history kept by %d%s"], hist, bytes and format(L[", %s on disk"], ns.FormatKB and ns.FormatKB(bytes) or tostring(bytes)) or ""),
    action = { text = L["Explorer"], func = function() ns.ShowTrackers(true) end, tip = L["Every tracker in the Explorer: switch one, change its history, see its size."] } })

  -- boards
  head(L["Boards"])
  local list = (M and ns.charSettings) and M.Store().list or {}
  local shown, tiles = 0, 0
  for _, b in ipairs(list) do
    if b.shown then shown = shown + 1 end
    tiles = tiles + #b.tiles
  end
  row({ label = format(L["%d boards, %d tiles"], #list, tiles), state = format(L["%d on HUD"], shown), on = shown > 0,
    value = #list == 0 and L["none yet: New board... makes one"] or "",
    action = { text = #list == 0 and L["New board..."] or L["Boards"], func = function()
      if #list == 0 then Bo().OpenNewBoard() else ns.ShowBoards(true) end
    end, tip = #list == 0 and L["The New board dialog: ready-made, empty, or a copy."] or L["The Boards tab: every board with its tiles."] } })
  for _, b in ipairs(list) do
    local status = ns.BoardStatusText and (ns.BoardStatusText(b)) or ""
    row({ label = "  " .. b.name, state = b.shown and L["On HUD"] or L["Only here"], on = b.shown and true or false,
      value = status .. "   " .. (Bo().ClockText(b) or ""),
      switch = function() b.shown = not b.shown; Bo().Refresh(b.id, true); if b.shown then Bo().Flash(b.id) end end,
      tip = { title = b.name, state = b.shown and L["Now: on your HUD (your screen while you play)"] or L["Now: only here, in this window"], on = b.shown,
        click = b.shown and L["Click: keep it only here."] or L["Click: put it on your HUD."] } })
  end

  -- the stint (a run: HC:GetRun)
  head(L["Run"])
  local run = HC:GetRun()
  local sum = ns.RunSummary and ns.RunSummary() or {}
  local limit = (ns.settings and ns.settings.maxRuns) or 500
  if run then
    local active, _, state = HC:GetRunClock()
    row({ label = run.label or ("#" .. tostring(run.id)), state = state == "running" and L["running"] or L["paused"], on = state == "running",
      value = ns.U.duration(active or 0),
      action = { text = L["Stop and keep"], func = function() HC:StopRun() end, tip = L["End the run and keep it in the Runs tab."] } })
  else
    row({ label = L["No run open"], state = L["none"], on = false, value = L["dungeons start one by themselves"],
      action = { text = L["Start run"], func = function() HC:StartRun() end, tip = L["Start a run now: everything counted until you stop it is kept with it."] } })
  end
  row({ label = L["Runs kept"], value = format(L["%d (the newest %d are kept: Options, History)"], sum.kept or 0, limit),
    action = { text = L["Runs"], func = function() if ns.ShowStints then ns.ShowStints(true) elseif ns.ToggleRunList then ns.ToggleRunList() end end,
      tip = L["The Runs tab: every run kept, with its numbers."] } })

  -- this session
  head(L["This session"])
  local s = ns.Session and ns.Session()
  local active = s and ns.Win and ns.Win.Active and ns.Win.Active(s) or 0
  row({ label = L["Active since you logged in"], state = HC:IsActive() and L["active"] or L["away"], on = HC:IsActive(),
    value = ns.U.duration(active) })

  -- history and storage
  head(L["History and storage"])
  local st = ns.settings or {}
  local dsh = (ns.globalSettings and tonumber(ns.globalSettings.dayStartHour)) or 0
  row({ label = L["Days kept, day by day"], value = format(L["%d days for a tracker you didn't set"], ns.DefaultHistoryDays()) })
  row({ label = L["Hours and weeks (Detailed)"], value = format(L["%d hours, %s of weeks"], ns.HOUR_KEEP[st.hourKeep] and st.hourKeep or 48,
    ({ ["1y"] = L["one year"], ["2y"] = L["two years"], ["5y"] = L["five years"] })[st.weekKeep or "2y"] or "2y") })
  row({ label = L["The day ends at"], value = dsh == 0 and L["midnight (local time)"] or format("%02d:00", dsh) })
  row({ label = L["\"This week\" means"], value = st.weekGrain == "resetweek" and L["weekly reset to reset"] or L["Monday to Sunday"],
    action = { text = L["Options"], func = function() ns.OpenOptions() end, tip = L["The Options tab: what is kept and for how long."] } })

  -- diagnostics
  head(L["Diagnostics"])
  local diag = F and F.DiagnosticsLoaded()
  row({ label = L["Diagnostics pack"], state = diag and L["loaded"] or L["off"], on = diag and true or false,
    value = F and format(L["version channel: %s"], F.Channel()) or "" })
  local notes = F and F.List() or {}
  row({ label = L["Automatic field notes"], state = (F and F.Enabled()) and L["on"] or L["off"], on = F and F.Enabled() or false,
    value = format(L["%d noted"], #notes),
    action = { text = L["Report..."], func = function() if ns.ShowReportBox then ns.ShowReportBox() end end,
      tip = L["The Report a problem tab (/hc report): a text to paste in a bug report. It lists what it holds; nothing leaves your computer by itself."] } })
  return out
end

---------------------------------------------------------------------------
-- Drawing
---------------------------------------------------------------------------

local function refresh()
  if not (content and content:IsShown()) then return end
  local now = ns.wow.time()
  if not sizes or now - sizesAt > 10 then                    -- db:Stats() is not free: every ten seconds
    local okS, _, total = pcall(ns.CounterSizes)
    sizes, sizesAt = { total = okS and type(total) == "table" and total.bytes or nil }, now
  end
  content.head:SetText(format(L["Hard Counters %s (%s)  \194\183  %s  \194\183  profile %s"], tostring(HC.VERSION),
    ns.FieldNotes and ns.FieldNotes.Channel() or "?", tostring(ns.charKey or "?"),
    ns.settingsDB and ns.settingsDB.GetCurrentProfile and ns.settingsDB:GetCurrentProfile() or "Default"))
  local list = entries()
  local y, nr, nh = -34, 0, 0
  for _, e in ipairs(list) do
    if e.head then
      nh = nh + 1
      local h = heads[nh] or newHead(nh)
      h:ClearAllPoints()
      h:SetPoint("TOPLEFT", content, "TOPLEFT", PAD, y - 6)
      h:SetText(e.head)
      h:Show()
      y = y - HEAD_H
    else
      nr = nr + 1
      local r = rows[nr] or newRow(nr)
      r:ClearAllPoints()
      r:SetPoint("TOPLEFT", content, "TOPLEFT", PAD, y)
      r:SetPoint("TOPRIGHT", content, "TOPRIGHT", -PAD, y)
      r.label:SetText(e.label or "")
      r.value:ClearAllPoints()
      if e.state then
        r.pill:SetState(e.state, e.on)
        r.pill:SetEnabled(e.switch ~= nil)
        r.pill:SetScript("OnClick", e.switch and function() e.switch(); refresh() end or nil)
        if e.tip then Wd.RichTip(r.pill, function() return e.tip end)
        else r.pill:SetScript("OnEnter", nil); r.pill:SetScript("OnLeave", nil) end
        r.pill:Show()
        r.value:SetPoint("LEFT", r.pill, "RIGHT", 8, 0)
      else
        r.pill:Hide()
        r.value:SetPoint("LEFT", r.label, "RIGHT", 6, 0)
      end
      r.value:SetPoint("RIGHT", r.btn, "LEFT", -8, 0)
      r.value:SetText(e.value or "")
      local a = e.action
      if a then
        r.btn:SetText(a.text)
        Wd.FitWidth(r.btn, 80, 24)
        r.btn:SetScript("OnClick", function() a.func(); refresh() end)
        Wd.RichTip(r.btn, function() return { title = a.text, text = a.tip } end)
        r.btn:Show()
      else
        r.btn:Hide()
      end
      r:Show()
      y = y - ROW_H
    end
  end
  for i = nr + 1, #rows do rows[i]:Hide() end
  for i = nh + 1, #heads do heads[i]:Hide() end
  local h = max(MIN_H, floor(-y + PAD))
  if h ~= contentH then
    contentH = h
    ns.Windows.Relayout(ID)
  end
end
ns.RefreshSummary = refresh

local function build(f)
  content = f
  f.head = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  f.head:SetPoint("TOPLEFT", PAD + 2, -10)
  f.head:SetPoint("TOPRIGHT", -PAD, -10)
  f.head:SetJustifyH("LEFT")
  f:SetScript("OnSizeChanged", function() refresh() end)
end

ns.Windows.Register(ID, {
  title = L["Overview"], icon = "Interface\\Icons\\INV_Misc_Note_01", place = "bottom", bottomOrder = -100,
  about = "Where everything stands for this character: packs, trackers, boards, runs, history, warnings.",
  width = 720, height = 440, minWidth = MIN_W, minHeight = MIN_H,
  minSize = function() return MIN_W, contentH end,
  build = build,
  onShow = function()
    sizes = nil
    refresh()
    if ticker then ticker:Cancel() end
    ticker = C_Timer.NewTicker(1, refresh)
  end,
  onHide = function()
    if ticker then ticker:Cancel(); ticker = nil end
  end,
})

function ns.ShowOverview(show) ns.Windows.Show(ID, show) end
ns.OverviewEntries = entries                                     -- (tests)
ns.AddSlash("overview", function() ns.ShowOverview() end, L["the Overview tab: where everything stands, and what needs a look"])

-- This tab's help and tour (UI/Help.lua): change them with the tab.
local _ = ns.Help and ns.Help.Register(ID, {
  what = "The Overview is one page on where everything stands for this character: your packs, the trackers counting, your boards and whether they are on your HUD, the open run, this session, how much history is kept, and Diagnostics.",
  can = {
    "Read {Needs a look} first: it appears only when something is off, each line with the button that fixes it.",
    "A lamp tells each state: green on, grey off, amber needs a look. A board's lamp is also its switch: click it to put that board on your HUD or take it off.",
    "Each line has a button to the tab where you change it: {Packs}, {Explorer}, {Boards}, {Runs}, {Options}.",
  },
  effect = "Nothing here works differently from the other tabs: this page only gathers what they say, so a quick look tells you whether Hard Counters is counting what you expect.",
  tour = {
    { title = "Needs a look", text = "When something is off (no packs chosen, a board lost off screen, tiles whose tracker is off) it is listed at the top, amber, with the one click that fixes it." },
    { title = "Everything else, one line each", text = "Packs, trackers, boards, the run, this session, history and Diagnostics. The button at the end of a line opens the tab where it is changed." },
  },
})
