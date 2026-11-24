-- /hc report: the field-feedback string (DESIGN §8.3; HC-61 for the Diagnostics section and the opt-ins).
--   !HCReport:1!d:<adler32 of the CBOR>:<Base64 of raw Deflate of CBOR>!End:HCReport:1!
-- Opt-in and visible: the player copies it from a text box; nothing is sent anywhere. Scrubbed: no character
-- names, realms, GUIDs or other players' data, unless the player ticks "name" or "class" in the report window
-- (opts.name, opts.class: read when the report is built, never saved). The list of installed addons only with
-- opts.addons. With HardCounters_Diagnostics loaded, its probe results ride along (body.diag: types, counts, statuses
-- and game IDs, never coordinates, names or chat text). Decode offline with tools\decode-report.ps1.
local ADDON, ns = ...

local W, HC, U = ns.wow, ns.HC, ns.U

ns.REPORT_PREFIX, ns.REPORT_SUFFIX = "!HCReport:1!", "!End:HCReport:1!"
ns.REPORT_MAX = 24000   -- characters; keeps the paste from freezing the text box

-- (HC-61) the Diagnostics section: a function set by HardCounters_Diagnostics through the private bridge, returning a
-- table; parts of it are dropped in this order when the report is over its cap, then the whole section
ns.reportSection = nil
local DIAG_DROP = { "samplers", "events", "strings" }

--- The report body as a plain table (pure apart from the adapters it reads).
function ns.ReportBody(opts)
  opts = opts or {}
  local GDB = ns.GDB
  local version, build, interface = W.build()
  local body = {
    fmt = 1,
    hc = HC.VERSION, api = HC.API_VERSION, at = W.now(),
    lib = GDB and { minor = GDB.MINOR, api = GDB.API_VERSION, schema = GDB.SCHEMA } or nil,
    client = { version = version, build = build, interface = interface, locale = W.locale() },
    health = { session = U.copy(ns.health.session), lifetime = U.copy(ns.health.saved) },
    warn = {},
    packs = ns.PackSummaries and ns.PackSummaries() or {},
    counters = ns.CounterCount and ns.CounterCount() or 0,
    runs = ns.RunSummary and ns.RunSummary() or nil,
    readOnly = ns.db and (ns.db:IsReadOnly()) or nil,
  }
  for _, w in ipairs(ns.RecentWarnings(50)) do
    body.warn[#body.warn + 1] = { w.t, w.level, w.origin, w.msg }
  end
  if GDB and ns.db then
    local ok, s = pcall(GDB.BuildReport, GDB)
    body.granary = ok and s or ("BuildReport failed: " .. tostring(s))
  end
  if opts.addons then body.addons = W.addonList() end
  if opts.name or opts.class then
    local okI, info = pcall(W.entityInfo)
    info = okI and type(info) == "table" and info or {}
    body.who = {
      name = opts.name and info.name or nil, realm = opts.name and info.realm or nil,
      class = opts.class and info.class or nil,
    }
  end
  if ns.reportSection then
    local ok, d = pcall(ns.reportSection)
    body.diag = ok and d or ("Diagnostics section failed: " .. tostring(d))
  end
  return body
end

local function wrap(body)
  local b64, raw = W.encodeReport(body)
  return ns.REPORT_PREFIX .. "d:" .. U.adler32(raw) .. ":" .. b64 .. ns.REPORT_SUFFIX
end

-- the next thing to leave an over-size report: oldest warnings, the addon list, the storage report, then the
-- Diagnostics section's parts (samplers, events, strings) and last the section itself
local function shed(body)
  if #body.warn > 0 then table.remove(body.warn, 1); return true end
  if body.addons then body.addons = nil; return true end
  if body.granary then body.granary = nil; return true end
  if type(body.diag) == "table" then
    for _, k in ipairs(DIAG_DROP) do
      if body.diag[k] ~= nil then body.diag[k] = nil; return true end
    end
  end
  if body.diag then body.diag = nil; return true end
  return false
end

--- The full report string, trimmed to REPORT_MAX. Returns the string and the body it encodes (for the summary).
function ns.BuildReport(opts)
  local body = ns.ReportBody(opts)
  local str = wrap(body)
  while #str > ns.REPORT_MAX and shed(body) do
    body.truncated = true
    str = wrap(body)
  end
  return str, body
end

local function count(t)
  local n = 0
  if type(t) == "table" then for _ in pairs(t) do n = n + 1 end end
  return n
end

--- What a report holds, in plain lines for the report window (HC-61: the player sees what they are pasting).
function ns.ReportSummary(body)
  local L = ns.L
  local out = {}
  local c = body.client or {}
  out[#out + 1] = string.format(L["Versions: Hard Counters %s, game client %s (%s), %s"], tostring(body.hc),
    tostring(c.version), tostring(c.build), tostring(c.locale))
  out[#out + 1] = string.format(L["Error and warning counts, and the last %d warnings"], #(body.warn or {}))
  out[#out + 1] = string.format(L["%d packs, %d counters, %d saved runs (no amounts)"], count(body.packs),
    body.counters or 0, body.runs and body.runs.kept or 0)
  if body.granary then out[#out + 1] = L["Storage health (sizes and counts, no values)"] end
  if type(body.diag) == "table" then
    local d = body.diag
    local parts = { string.format(L["%d API checks"], count(d.funcs)) }
    if d.events then parts[#parts + 1] = string.format(L["%d game events"], count(d.events)) end
    if d.strings then parts[#parts + 1] = L["client strings"] end
    if d.samplers then parts[#parts + 1] = L["travel and movement counts (zone, map and spell IDs; no positions)"] end
    out[#out + 1] = L["Diagnostics: "] .. table.concat(parts, ", ")
  elseif body.diag then
    out[#out + 1] = tostring(body.diag)
  else
    out[#out + 1] = L["Diagnostics: not loaded (enable Hard Counters: Diagnostics for a fuller report)"]
  end
  if body.addons then out[#out + 1] = string.format(L["Your addon list (%d addons)"], #body.addons) end
  local who = body.who
  if who and who.name then
    out[#out + 1] = string.format(L["Your character: %s-%s"], tostring(who.name), tostring(who.realm))
  end
  if who and who.class then out[#out + 1] = string.format(L["Your class: %s"], tostring(who.class)) end
  if not (who and (who.name or who.class)) then out[#out + 1] = L["No character name, realm or class"] end
  if body.truncated then out[#out + 1] = L["Shortened to fit: the oldest parts were left out"] end
  return out
end
