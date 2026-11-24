-- Diagnostics core: the full log (ring of 2,000 lines), snapshots into our own SavedVariable, the marker.
-- Uses only HardCounters._diag (a private bridge for this companion addon), never saved tables of the engine.
local ADDON, ns = ...

local HC = HardCounters
local B = HC and HC._diag
ns.B = B
if not B then return end

local format, date = string.format, date
local LOG_CAP, SNAP_CAP = 2000, 20

ns.lines = { cap = LOG_CAP, head = 0, n = 0, items = {} }
ns.levelRank = { error = 1, warn = 2, info = 3, debug = 4 }
ns.minLevel = 4

local function push(store, item)
  local head = store.head % store.cap + 1
  store.items[head] = item
  store.head = head
  if store.n < store.cap then store.n = store.n + 1 end
end

local function list(store, max)
  local out, n, cap = {}, store.n, store.cap
  local take = (max and max < n) and max or n
  local first = store.head - take + 1
  for i = 0, take - 1 do out[#out + 1] = store.items[(first + i - 1) % cap + 1] end
  return out
end
ns.list = list

local function clock(t) return date("%H:%M:%S", t) end
ns.clock = clock

function ns.AddLine(t, level, origin, msg)
  push(ns.lines, { t = t, level = level, origin = origin, msg = msg })
  if ns.OnNewLine then ns.OnNewLine() end
end

function ns.LogText()
  local out = {}
  for _, l in ipairs(list(ns.lines)) do
    if (ns.levelRank[l.level] or 3) <= ns.minLevel then
      out[#out + 1] = format("%s %-5s [%s] %s", clock(l.t), l.level:upper(), l.origin or "?", l.msg)
    end
  end
  return table.concat(out, "\n")
end

local function contextLine()
  local c = B.Context()
  return format("zone=%s instance=%s combat=%s", tostring(c.zone), tostring(c.instance), tostring(c.combat))
end
ns.contextLine = contextLine

--- Write the current tab's text to HardCountersDiagDB.snapshots (newest last, 20 kept). Read after /reload.
function ns.Snapshot(tab, text)
  local db = HardCountersDiagDB
  db.snapshots = db.snapshots or {}
  local s = db.snapshots
  local version, build = B.Wow.build()
  s[#s + 1] = { t = B.Wow.now(), tab = tab, context = contextLine(), client = format("%s.%s", tostring(version), tostring(build)),
    text = text }
  while #s > SNAP_CAP do table.remove(s, 1) end
  B.Log("info", "Diag", "snapshot #%d of %s saved (readable after /reload)", #s, tab)
  return #s
end

--- "MARK #n hh:mm:ss" in the log and on screen, to match a screenshot to log lines.
function ns.Marker()
  local db = HardCountersDiagDB
  db.marker = (db.marker or 0) + 1
  local text = format("MARK #%d %s", db.marker, clock(B.Wow.now()))
  B.Log("info", "Diag", "%s %s", text, contextLine())
  if UIErrorsFrame then UIErrorsFrame:AddMessage(text, 1, 0.82, 0) end
  return text
end

local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:SetScript("OnEvent", function(self, _, name)
  if name ~= ADDON then return end
  self:UnregisterEvent("ADDON_LOADED")
  if type(HardCountersDiagDB) ~= "table" then HardCountersDiagDB = {} end
  -- earlier warnings from the engine's tier-1 ring, then everything live
  for _, w in ipairs(B.RecentWarnings()) do push(ns.lines, { t = w.t, level = w.level, origin = w.origin, msg = w.msg }) end
  B.SetLogSink(ns.AddLine)
  B.Log("info", "Diag", "diagnostics loaded (%s)", contextLine())
  if ns.StartProbes then ns.StartProbes() end
  -- (HC-61) the probes ride along in /hc report (Probes.lua loads after this file: looked up at the call)
  if B.SetReportSection then B.SetReportSection(function() return ns.ReportSection and ns.ReportSection() end) end
end)
