-- /hc report: the field-feedback string (DESIGN §8.3).
--   !HCReport:1!d:<adler32 of the CBOR>:<Base64 of raw Deflate of CBOR>!End:HCReport:1!
-- Opt-in and visible: the player copies it from a text box; nothing is sent anywhere. Scrubbed: no character
-- names, realms, GUIDs or other players' data. The list of installed addons only with opts.addons.
-- Decode offline with tools\decode-report.ps1.
local ADDON, ns = ...

local W, HC, U = ns.wow, ns.HC, ns.U

ns.REPORT_PREFIX, ns.REPORT_SUFFIX = "!HCReport:1!", "!End:HCReport:1!"
ns.REPORT_MAX = 24000   -- characters; keeps the paste from freezing the text box

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
  return body
end

local function wrap(body)
  local b64, raw = W.encodeReport(body)
  return ns.REPORT_PREFIX .. "d:" .. U.adler32(raw) .. ":" .. b64 .. ns.REPORT_SUFFIX
end

--- The full report string, trimmed to REPORT_MAX (oldest warnings first, then the addon list).
function ns.BuildReport(opts)
  local body = ns.ReportBody(opts)
  local str = wrap(body)
  while #str > ns.REPORT_MAX do
    if #body.warn > 0 then
      table.remove(body.warn, 1)
    elseif body.addons then
      body.addons = nil
    elseif body.granary then
      body.granary = nil
    else
      break
    end
    body.truncated = true
    str = wrap(body)
  end
  return str
end
