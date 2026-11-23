-- Console: the dev console window. Tabs: Log, Live, Storage, Probes. Buttons: Refresh, Snapshot, Copy, Marker,
-- Run probes, Level. The text area is a read-only edit box, so the Copy button is just "select all".
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

local function refresh()
  if not (win and win:IsShown()) then return end
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
  bottom("Copy", 60, function() edit:SetFocus(); edit:HighlightText() end)
  bottom("Marker", 70, function() ns.Marker(); refresh() end)
  bottom("Run probes", 90, function() ns.RunProbes(); current = "Probes"; refresh() end)
  bottom("Report", 70, function() B.ShowCopyBox("Hard Counters report", B.BuildReport({})) end)
  f.levelBtn = bottom("Level: all", 90, function()
    ns.minLevel = ns.minLevel % 4 + 1
    refresh()
  end)
  bottom("Clear log", 80, function() ns.lines.head, ns.lines.n = 0, 0; ns.lines.items = {}; refresh() end)
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
    title = "Diagnostics",                              -- a tab of the Hard Counters window, like every window
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
