-- Console: the dev console window. Tabs: Log, Live, Storage, Probes. Buttons: Refresh, Snapshot, Copy, Marker,
-- Run probes, Level. The text area is a read-only edit box, so the Copy button is just "select all". Probes is a
-- browser since HC-70 (below).
-- /hc diag toggles it (/hcdiag is an alias); /hc diag mark drops a marker; /hc diag snap snapshots the current tab.
local ADDON, ns = ...

local B = ns.B
if not B then return end

local format = string.format
local win, current = nil, "Log"
local TABS = { "Log", "Live", "Storage", "Probes" }
local LEVEL_NAMES = { [1] = "errors", [2] = "warn+", [3] = "info+", [4] = "all" }

local function liveText()
  local out = {}
  local run = B.Run()
  if run then
    out[#out + 1] = format("RUN #%d %q %s, active %s, elapsed %s", run.id, run.label or "", run.state,
      HardCounters:FormatDuration(run.activeSeconds), HardCounters:FormatDuration(run.elapsed))
  else
    out[#out + 1] = "no open run"
  end
  local rs = B.RunSummary()
  if rs then out[#out + 1] = format("%d runs kept", rs.kept or 0) end
  local running, paused = B.SchedulerStats()
  out[#out + 1] = format("scheduler: %d jobs running, %d paused", running, paused)
  out[#out + 1] = ""
  out[#out + 1] = format("%-34s %-6s %16s %16s %10s", "COUNTER", "KIND", "TODAY", "LIFETIME", "PENDING")
  for _, r in ipairs(B.LiveRows()) do
    out[#out + 1] = format("%-34s %-6s %16s %16s %10s", r.id, r.kind, tostring(r.today or "-"), tostring(r.lifetime or "-"),
      r.pending and format("%.1f", r.pending) or "")
  end
  out[#out + 1] = ""
  out[#out + 1] = "SOURCES"
  for _, s in ipairs(B.Sources()) do
    out[#out + 1] = format("  %-30s %-14s events=%d errors=%d last=%s", s.id, s.mode, s.events, s.errors,
      s.last and ns.clock(s.last) or "-")
  end
  local session, saved = B.Health()
  out[#out + 1] = ""
  out[#out + 1] = "HEALTH (this login / lifetime)"
  local keys = {}
  for k in pairs(saved) do keys[#keys + 1] = k end
  table.sort(keys)
  for _, k in ipairs(keys) do out[#out + 1] = format("  %-28s %8d %10d", k, session[k] or 0, saved[k]) end
  return table.concat(out, "\n")
end

local function dump(v, ind, out, depth)
  if type(v) ~= "table" or depth > 4 then out[#out + 1] = ind .. tostring(v); return end
  local keys = {}
  for k in pairs(v) do keys[#keys + 1] = k end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  for _, k in ipairs(keys) do
    local x = v[k]
    if type(x) == "table" then
      out[#out + 1] = ind .. tostring(k) .. ":"
      dump(x, ind .. "  ", out, depth + 1)
    else
      out[#out + 1] = ind .. tostring(k) .. " = " .. tostring(x)
    end
  end
end

local function storageText()
  local st = B.StorageStats()
  if not st then return "storage not attached yet" end
  local out = { "LibGranaryDB db:Stats()" }
  dump(st, "  ", out, 0)
  return table.concat(out, "\n")
end

local function textFor(tab)
  if tab == "Log" then return ns.LogText() end
  if tab == "Live" then return liveText() end
  if tab == "Storage" then return storageText() end
  if tab == "Probes" then return ns.ProbesText() end
  return ""
end

---------------------------------------------------------------------------
-- The Probes view (HC-70, DESIGN §17.4; the playtest's note #7, decided 2026-11-23): the shared browser over
-- ns.ProbeList(). Tree by kind; columns Name, Feature, Status, Last run; Filters by status and feature; the detail
-- pane holds what the probe kept (a function's last 5 runs, newest first); actions Run (functions and strings),
-- Copy, Clear history; at the top Run all, Copy all, Clear all. Without the browser (an older Hard Counters) the
-- Probes view stays the text it was.
---------------------------------------------------------------------------

local KIND_NODES = { { "function", "Functions" }, { "event", "Events" }, { "string", "Global strings" }, { "sampler", "Samplers" } }
local STATUS_COLOR = { ok = "|cff60ff60", missing = "|cffff6060", error = "|cffff6060", changed = "|cffffd200",
  secret = "|cffc080ff", ["never fired"] = "|cff808080", ["not run yet"] = "|cff808080" }
local hideStatus, hideFeature = {}, {}         -- the Filters menu: statuses and features hidden
local probesBrowser

local function shownRecord(rec, search)
  if hideStatus[rec.status] or hideFeature[rec.feature] then return false end
  if search == "" then return true end
  return rec.name:lower():find(search, 1, true) ~= nil or rec.feature:lower():find(search, 1, true) ~= nil
end

local probeSpec = {
  columns = {
    { key = "name", title = "Name" },
    { key = "feature", title = "Feature", width = 64 },
    { key = "status", title = "Status", width = 90 },
    { key = "last", title = "Last run", width = 64, sort = function(r) return r.rec.last or 0 end },
  },
  nodes = function()
    local list = ns.ProbeList()
    local n, by = 0, {}
    for _, rec in ipairs(list) do
      if shownRecord(rec, "") then n = n + 1; by[rec.kind] = (by[rec.kind] or 0) + 1 end
    end
    local out = { { key = "all", text = "All probes", count = n } }
    for _, k in ipairs(KIND_NODES) do out[#out + 1] = { key = k[1], text = k[2], count = by[k[1]] or 0, indent = 1 } end
    return out
  end,
  rows = function(node, search)
    local out = {}
    for _, rec in ipairs(ns.ProbeList()) do
      if (node == "all" or node == rec.kind) and shownRecord(rec, search) then
        out[#out + 1] = { key = rec.key, rec = rec, grey = rec.status == "not run yet",
          cells = { name = rec.name, feature = rec.feature, status = (STATUS_COLOR[rec.status] or "") .. rec.status .. "|r",
            last = rec.last and ns.clock(rec.last) or "" } }
      end
    end
    return out
  end,
  filters = function()
    local items = { { text = "Status", title = true } }
    for _, s in ipairs(ns.PROBE_STATUSES) do
      items[#items + 1] = { text = s, checked = not hideStatus[s], keepOpen = true,
        func = function() hideStatus[s] = (not hideStatus[s]) or nil; if probesBrowser then probesBrowser:Refresh() end end }
    end
    local features, seen = {}, {}
    for _, rec in ipairs(ns.ProbeList()) do
      if not seen[rec.feature] then seen[rec.feature] = true; features[#features + 1] = rec.feature end
    end
    table.sort(features)
    items[#items + 1] = { text = "Feature", title = true }
    for _, f in ipairs(features) do
      items[#items + 1] = { text = f, checked = not hideFeature[f], keepOpen = true,
        func = function() hideFeature[f] = (not hideFeature[f]) or nil; if probesBrowser then probesBrowser:Refresh() end end }
    end
    items[#items + 1] = { text = "Show everything", keepOpen = true, func = function()
      hideStatus, hideFeature = {}, {}
      if probesBrowser then probesBrowser:Refresh() end
    end }
    return items
  end,
  filtersActive = function() return next(hideStatus) ~= nil or next(hideFeature) ~= nil end,
  detail = function(row)
    local rec = row.rec
    local items = {}
    for _, l in ipairs(ns.ProbeLines(rec)) do items[#items + 1] = { text = l, tip = l } end
    if #items == 0 then items[1] = { text = "nothing kept yet", grey = true } end
    return { title = rec.name, lines = { format("%s  \194\183  %s  \194\183  %s%s|r", rec.kind, rec.feature,
      STATUS_COLOR[rec.status] or "", rec.status) }, items = items }
  end,
  actions = function(row)
    if not row then return {} end
    local rec = row.rec
    local acts = {}
    if rec.runnable then
      acts[#acts + 1] = { text = "Run", tip = "Run this probe now, with the context (zone, instance, combat).",
        func = function() ns.RunProbeRecord(rec); if probesBrowser then probesBrowser:Refresh() end end }
    end
    acts[#acts + 1] = { text = "Copy", tip = "This probe as text, to paste to Claude.",
      func = function() B.ShowCopyBox(rec.name, ns.ProbeText(rec)) end }
    acts[#acts + 1] = { text = "Clear history", tip = "Forget what this probe kept (saved at the next /reload).",
      func = function()
        B.Confirm(format("Clear what the probe %s kept?", rec.name), function()
          ns.ClearProbe(rec)
          if probesBrowser then probesBrowser:Refresh() end
        end)
      end }
    return acts
  end,
  header = {
    { text = "Clear all", width = 80, func = function()
      B.Confirm("Clear what every probe kept? The samplers start again from nothing.", function()
        ns.ClearProbes()
        if probesBrowser then probesBrowser:Refresh() end
      end)
    end },
    { text = "Copy all", width = 80, func = function() B.ShowCopyBox("Probes", ns.ProbesText()) end },
    { text = "Run all", width = 80, func = function() ns.RunProbes(); if probesBrowser then probesBrowser:Refresh() end end },
  },
  footer = function()
    local p = HardCountersDiagDB.probes
    local lr = p and p.lastRun
    return lr and format("last run %s: %d ok, %d not ok", ns.clock(lr.t), lr.ok, lr.other) or "function probes not run yet"
  end,
  empty = function() return "No probe matches (see Filters)." end,
  noSelection = "Click a probe for what it kept. Run all checks every function probe now.",
}

local function refresh()
  if not (win and win:IsShown()) then return end
  -- (HC-70) the Probes view is the browser; the others are text
  local browse = current == "Probes" and win.probes ~= nil
  if win.probes then win.probes:SetShown(browse) end
  win.scroll:SetShown(not browse)
  if browse then
    for name, b in pairs(win.tabs) do b:SetEnabled(name ~= current) end
    win.levelBtn:SetText("Level: " .. LEVEL_NAMES[ns.minLevel])
    probesBrowser:Refresh()
    return
  end
  local ok, text = pcall(textFor, current)
  if not ok then text = "error building " .. current .. ": " .. tostring(text) end
  win.text = text
  win.edit:SetText(text)
  for name, b in pairs(win.tabs) do b:SetEnabled(name ~= current) end
  win.levelBtn:SetText("Level: " .. LEVEL_NAMES[ns.minLevel])
  if current == "Log" then win.scroll:SetVerticalScroll(win.scroll:GetVerticalScrollRange()) end
end
ns.Refresh = refresh

local function button(parent, text, w, onClick)
  local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  b:SetSize(w, 22)
  b:SetText(text)
  b:SetScript("OnClick", onClick)
  return b
end

-- A Hard Counters window ("hcdiag:console"): on its own by default, or a tab of the Hard Counters window.
-- Hard Counters owns the frame (title, close, BlizzMove; a tab of the shared window, at 760 x 450); this builds the content.
local function build(f)
  win = f
  f.tabs = {}
  local x = 12
  for _, name in ipairs(TABS) do
    local b = button(f, name, 80, function() current = name; refresh() end)
    b:SetPoint("TOPLEFT", x, -4)
    f.tabs[name] = b
    x = x + 84
  end

  local scroll = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", 12, -32)
  scroll:SetPoint("BOTTOMRIGHT", -32, 40)
  local edit = CreateFrame("EditBox", nil, scroll)
  edit:SetMultiLine(true)
  edit:SetMaxLetters(0)
  edit:SetAutoFocus(false)
  edit:SetFontObject(GameFontHighlightSmall)
  edit:SetWidth(700)
  edit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  edit:SetScript("OnTextChanged", function(self, userInput) if userInput then self:SetText(f.text or "") end end)
  scroll:SetScrollChild(edit)
  f.scroll, f.edit = scroll, edit
  f:SetScript("OnSizeChanged", function(self) edit:SetWidth(math.max(self:GetWidth() - 60, 200)) end)

  local bx = 12
  local function bottom(text, w, fn)
    local b = button(f, text, w, fn)
    b:SetPoint("BOTTOMLEFT", bx, 10)
    bx = bx + w + 4
    return b
  end
  bottom("Refresh", 70, refresh)
  bottom("Snapshot", 80, function() ns.Snapshot(current, textFor(current)); refresh() end)
  bottom("Copy", 60, function()
    if current == "Probes" and f.probes then B.ShowCopyBox("Probes", ns.ProbesText()) else edit:SetFocus(); edit:HighlightText() end
  end)
  bottom("Marker", 70, function() ns.Marker(); refresh() end)
  bottom("Run probes", 90, function() ns.RunProbes(); current = "Probes"; refresh() end)
  bottom("Report", 70, function()
    if B.ShowReport then B.ShowReport({}) else B.ShowCopyBox("Hard Counters report", (B.BuildReport({}))) end
  end)
  f.levelBtn = bottom("Level: all", 90, function()
    ns.minLevel = ns.minLevel % 4 + 1
    refresh()
  end)
  bottom("Clear log", 80, function() ns.lines.head, ns.lines.n = 0, 0; ns.lines.items = {}; refresh() end)

  -- (HC-70) the Probes view: the shared browser between the view buttons and the bottom row
  if B.NewBrowser then
    local pf = CreateFrame("Frame", nil, f)
    pf:SetPoint("TOPLEFT", 0, -30)
    pf:SetPoint("BOTTOMRIGHT", 0, 36)
    pf:Hide()
    probesBrowser = B.NewBrowser(pf, probeSpec)
    if probesBrowser then f.probes = pf; ns.ProbesBrowser = probesBrowser end
  end
end

-- refresh Live once a second while the window is on screen; Log refreshes when lines arrive (throttled)
local function onShow(f)
  if f.ticker then f.ticker:Cancel() end
  f.ticker = C_Timer.NewTicker(1, function() if current == "Live" then refresh() end end)
  refresh()
end

local function onHide(f)
  if f.ticker then f.ticker:Cancel(); f.ticker = nil end
end

local WINDOW = "hcdiag:console"
local hasWindows = HardCounters.Supports and HardCounters:Supports("windows")
if hasWindows then
  HardCounters:RegisterWindow(WINDOW, {
    title = "Diagnostics",                              -- a side tab of the Hard Counters window, always last
    icon = "Interface\\Icons\\Trade_Engineering",
    about = "The dev console: log, live values, storage and probes. For bug reports and the curious.",
    width = 760, height = 450, minWidth = 640, minHeight = 240,   -- 640: the row of bottom buttons
    build = build, onShow = onShow, onHide = onHide,
  })
end

local pendingLog = false
ns.OnNewLine = function()
  if current ~= "Log" or not (win and win:IsShown()) or pendingLog then return end
  pendingLog = true
  C_Timer.After(0.5, function() pendingLog = false; refresh() end)
end

local function command(msg)
  msg = (msg or ""):lower():gsub("%s+", "")
  if msg == "mark" then ns.Marker()
  elseif msg == "snap" then ns.Snapshot(current, textFor(current))
  elseif msg == "probes" then ns.RunProbes()
  elseif hasWindows then HardCounters:ToggleWindow(WINDOW) end
end

if HardCounters.RegisterSlash then
  HardCounters:RegisterSlash("diag", command, "diagnostics console; mark | snap | probes", "Diagnostics")
end
-- the older command, kept as an alias of /hc diag
SLASH_HCDIAG1 = "/hcdiag"
SlashCmdList.HCDIAG = command
-- luacheck: push no max line length

-- This tab's help and tour (Hard Counters' Help and Tab tour buttons): change them with the tab.
if HardCounters.RegisterWindowHelp then
  HardCounters:RegisterWindowHelp(WINDOW, {
    what = "Diagnostics is the console for finding problems: what Hard Counters logged, its live values, what storage holds, and probes that check the game's API on this client.",
    can = {
      "Switch between {Log}, {Live}, {Storage} and {Probes} with the buttons on top.",
      "In {Probes}: {Run all} runs every check now, {Copy all} gives them as text to paste into a bug report.",
      "/hc diag mark drops a marker in the log just before you reproduce a problem; /hc report makes the report to paste.",
    },
    effect = "You only need this when something looks wrong or someone asks you for a report. It changes nothing about what is counted; turning the pack off in the Packs tab costs you nothing in play.",
    tour = {
      { title = "Four views", text = "{Log} is what happened, newest last. {Live} is the engine's state now. {Storage} is what is saved and how big it is. {Probes} checks which game functions answer on this client." },
      { title = "When something breaks", text = "Type /hc diag mark, do the thing that goes wrong, then /hc report: it packs the log, your settings' shape and the probes into one string to paste where you report the bug. No names unless you tick them." },
    },
  })
end
-- luacheck: pop
