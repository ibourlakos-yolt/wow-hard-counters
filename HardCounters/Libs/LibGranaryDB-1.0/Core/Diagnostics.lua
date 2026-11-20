-- Diagnostics: Stats, the !GranaryDBReport string, SelfTest and Bench (DESIGN §10.1, SPEC §6).
-- The library exposes diagnostics but never shows them: no printing, no slash commands.
local lib = LibStub and LibStub("LibGranaryDB-1.0", true)
local M = lib and lib.__M
if not M then return end

local type, pairs, ipairs, tostring, pcall = type, pairs, ipairs, tostring, pcall
local format, sort = string.format, table.sort

local D = {}
M.Diag = D

D.REPORT_PREFIX, D.REPORT_SUFFIX = "!GranaryDBReport:1!", "!End:GranaryDBReport:1!"
D.REPORT_MAX = 8192

local STAT_KEYS = { "rejectedSecrets", "rejectedInvalid", "otherOverflow", "lateDropped", "readOnlyDrops", "packs",
  "bucketsClosed", "migrations", "maintenance", "budget", "drops" }

function D.dbStats(db)
  local per, total = M.Maint.estimate(db)
  local counters = {}
  for id, acc in pairs(per) do
    -- r3: bytes per grain name, and frozen bytes (all of an unregistered counter; a registered one's undeclared grains)
    local grains = {}
    for gid, b in pairs(acc.byGrain or {}) do
      local name = M.Cal.GRAINS[gid]
      if name then grains[name] = b end
    end
    counters[id] = { entries = acc.entries, bytes = acc.bytes, tuples = acc.tuples, open = acc.open,
      pending = acc.pending, chunks = acc.chunks, registered = db._counters[id] ~= nil,
      frozenBytes = M.Maint.frozenBytes(db, id, acc), grains = grains }
  end
  local stats = {}
  for _, k in ipairs(STAT_KEYS) do stats[k] = db._stats[k] or 0 end
  local warnings = {}
  local w = db._G.meta and db._G.meta.warn or {}
  for i = math.max(1, #w - 9), #w do warnings[#warnings + 1] = w[i] end
  return {
    lib = { major = M.MAJOR, minor = M.MINOR, api = lib.API_VERSION, schema = M.SCHEMA },
    host = db._host,
    dataSchema = db._G.schema,
    readOnly = db._ro and true or false,
    reason = db._roReason,
    counters = counters,
    total = total,
    budget = { maxEntries = db._opts.maxEntries, maxBytes = db._opts.maxBytes, actions = db._stats.budget or 0 },
    stats = stats,
    warnings = warnings,
    lastMaintenance = db._G.meta and db._G.meta.last and db._G.meta.last.maint,
  }
end

function D.libStats()
  local dbs = {}
  for _, db in ipairs(lib.__dbs or {}) do
    if not db._detached then dbs[db._host] = D.dbStats(db) end
  end
  return { lib = { major = M.MAJOR, minor = M.MINOR, api = lib.API_VERSION, schema = M.SCHEMA }, dbs = dbs }
end

---------------------------------------------------------------------------
-- Report
---------------------------------------------------------------------------
local function summary(db)
  local s = D.dbStats(db)
  local n = 0
  for id in pairs(s.counters) do
    if id:sub(1, 1) ~= "@" then n = n + 1 end -- host counters only, not @wall/@active
  end
  return {
    host = db._host, schema = s.dataSchema, ro = s.readOnly, reason = s.reason and s.reason:sub(1, 200) or nil,
    counters = n, entries = s.total.entries, bytes = s.total.bytes, stats = s.stats,
    warn = s.warnings,
  }
end

local function holder(dbs)
  if dbs[1] then return dbs[1] end
  return { _ad = M.Adapters.resolve(nil) }
end

function D.buildReport(dbs, now)
  local body = { fmt = 1, lib = M.MINOR, api = lib.API_VERSION, schema = M.SCHEMA, at = now or 0, hosts = {} }
  for _, db in ipairs(dbs) do body.hosts[#body.hosts + 1] = summary(db) end
  local h = holder(dbs)
  local str = M.Exchange.wrap(h, body, D.REPORT_PREFIX, D.REPORT_SUFFIX)
  -- size cap: drop warnings first, then whole hosts
  while #str > D.REPORT_MAX do
    local trimmed = false
    for _, hs in ipairs(body.hosts) do
      if hs.warn and #hs.warn > 0 then table.remove(hs.warn, 1); trimmed = true; break end
    end
    if not trimmed then
      if #body.hosts == 0 then break end
      table.remove(body.hosts)
      body.truncated = true
    end
    str = M.Exchange.wrap(h, body, D.REPORT_PREFIX, D.REPORT_SUFFIX)
  end
  return str
end

function D.parseReport(str)
  local h = holder(lib.__dbs or {})
  local raw, err = M.Exchange.unwrap(h, str, D.REPORT_PREFIX, D.REPORT_SUFFIX, "GranaryDBReport")
  if not raw then return nil, err end
  local body, derr = M.Codec.cborDecode(raw, { maxDepth = 8, maxString = 65536, maxItems = 20000 })
  if type(body) ~= "table" then return nil, "corrupt report: " .. tostring(derr) end
  if body.fmt ~= 1 or type(body.hosts) ~= "table" then return nil, "not a report body" end
  return body
end

---------------------------------------------------------------------------
-- SelfTest: quick checks against whatever adapters are active (real WoW ones in game)
---------------------------------------------------------------------------
local function deepEqual(a, b, depth)
  depth = depth or 0
  if depth > 20 then return false end
  if type(a) ~= type(b) then return false end
  if type(a) ~= "table" then return a == b end
  for k, v in pairs(a) do if not deepEqual(v, b[k], depth + 1) then return false end end
  for k in pairs(b) do if a[k] == nil then return false end end
  return true
end
D.deepEqual = deepEqual

function D.selfTest(opts)
  opts = opts or {}
  local results = {}
  local allOk = true
  local ad, aerr = M.Adapters.resolve(opts.adapters)
  local function check(name, fn)
    local ok, good, msg = pcall(fn)
    if not ok then good, msg = false, "error: " .. tostring(good) end
    results[#results + 1] = { name = name, ok = good and true or false, msg = msg }
    if not good then allOk = false end
  end
  if not ad then
    results[1] = { name = "adapters", ok = false, msg = aerr }
    return false, results
  end
  check("adapters", function()
    local names = {}
    for name in pairs(M.Adapters.REQUIRED) do if ad[name] then names[#names + 1] = name end end
    sort(names)
    return true, (M.wowAdapters and "WoW adapters" or "pure-Lua adapters") .. ": " .. table.concat(names, ",")
      .. "; compressor=" .. tostring(ad.compressor.name)
  end)
  check("checksum", function()
    local v = M.Codec.adler32("Wikipedia")
    return v == "11e60398", "adler32(Wikipedia)=" .. v
  end)
  check("calendar-arithmetic", function()
    local d = M.Cal.daysFromCivil(2026, 11, 13)
    local y, m, dd = M.Cal.civilFromDays(d)
    local leap = M.Cal.daysFromCivil(2024, 3, 1) - M.Cal.daysFromCivil(2024, 2, 28)
    return d == 20770 and y == 2026 and m == 11 and dd == 13 and leap == 2, "2026-11-13 -> day " .. d
  end)
  check("calendar-fields", function()
    local t = ad.clock.now()
    local y, mo, d, h, mi, s = ad.calendar.fields(t, false)
    local uy, umo, ud, uh = ad.calendar.fields(t, true)
    local ok = type(y) == "number" and y >= 2020 and mo >= 1 and mo <= 12 and d >= 1 and d <= 31 and h >= 0 and h <= 23
      and type(mi) == "number" and type(s) == "number" and type(uy) == "number"
    return ok, format("local %04d-%02d-%02d %02d:%02d, utc %04d-%02d-%02d %02d", y, mo, d, h, mi, uy, umo, ud, uh)
  end)
  check("reset-anchor", function()
    local a = ad.calendar.resetAnchor(opts.region or "EU")
    local wd = (math.floor(a / 86400) + 4) % 7 -- 0 = Sunday
    local secs = a % 86400
    local names = { [0] = "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" }
    -- the anchor must be canonical (within the first week, on a whole minute) or keys drift between sessions
    local ok = type(a) == "number" and a >= 0 and a < 604800 and a % 60 == 0
    return ok, format("weekly reset anchor: %s %02d:%02d UTC (%s, %s)", names[wd], math.floor(secs / 3600),
      math.floor(secs % 3600 / 60), M.wowAdapters and "WoW" or "default", tostring(a))
  end)
  check("serializer", function()
    local sample = { a = 1, b = { 1, 2, 3.5, -7 }, c = "x\0y", d = true, e = 1e15, f = -0.125 }
    local s = ad.serializer.encode(sample)
    local back, err = M.Codec.cborDecode(s)
    if not deepEqual(sample, back) then return false, "native encode -> pure decode mismatch: " .. tostring(err) end
    local s2 = M.Codec.cborEncode(sample)
    local back2 = ad.serializer.decode(s2)
    return deepEqual(sample, back2), "round trip ok (" .. #s .. " bytes)"
  end)
  check("compressor", function()
    if ad.compressor.name == "none" then return true, "none (no compression available)" end
    local text = string.rep("GDB1,2,s.n;#20405;1,12.5,1;", 50)
    local z = ad.compressor.compress(text)
    local back = ad.compressor.decompress(z)
    return back == text, format("%s: %d -> %d bytes", ad.compressor.name, #text, #z)
  end)
  check("encoder", function()
    local bin = {}
    for i = 0, 255 do bin[#bin + 1] = string.char(i) end
    bin = table.concat(bin)
    local e = ad.encoder.encode(bin)
    local same = e == M.Codec.base64Encode(bin)
    return ad.encoder.decode(e) == bin and same, same and "base64 identical to the pure-Lua encoder" or "differs from pure-Lua base64"
  end)
  check("secret-guard", function()
    local f = ad.secret.isSecret
    return f(1) == false and f("x") == false and f(nil) == false, "isSecret(plain values) == false"
  end)
  check("end-to-end", function()
    local root = {}
    local tad = {}
    for k, v in pairs(ad) do tad[k] = v end
    tad.scheduler = { after = function() end }
    tad.logger = { log = function() end }
    tad.callbacks = { Fire = function() end }
    local db = lib:Attach(root, { host = "SelfTest", adapters = tad, autoMaintenance = false })
    db:RegisterCounter({ id = "selftest:flow", version = 1, measures = { "sum", "count", "max" },
      dimensions = { { name = "mode", cap = 4 } }, aggregations = { {}, { "mode" } },
      grains = { "hour", "day", "week", "resetweek", "month", "lifetime" } })
    local h = db:Handle("selftest:flow")
    local t = ad.clock.now()
    for i = 1, 100 do h:AddAt(t, i % 7, i % 2 == 0 and "a" or "b") end
    local rows = db:Query({ counter = "selftest:flow", grain = "day", groupBy = "mode" })
    local total = rows and rows.total
    db:RunMaintenance()
    local str = db:Export({ counters = { "selftest:flow" }, grains = { "day", "lifetime" } })
    local id, ierr = db:Import(str or "", { label = "selftest" })
    local rows2 = id and db:Query({ counter = "selftest:flow", grain = "lifetime", dataset = id })
    local ok = total == 297 and rows2 and rows2.total == 297
    db:Detach()
    return ok, format("total=%s imported=%s %s", tostring(total), tostring(rows2 and rows2.total), tostring(ierr or ""))
  end)
  return allOk, results
end

---------------------------------------------------------------------------
-- Bench: a short benchmark any host can call (also `/granary bench` in the dev addon)
---------------------------------------------------------------------------
function D.bench(opts)
  opts = opts or {}
  local n = opts.writes or 20000
  local ad = M.Adapters.resolve(opts.adapters)
  local tad = {}
  for k, v in pairs(ad) do tad[k] = v end
  tad.scheduler = { after = function() end }
  tad.callbacks = { Fire = function() end }
  local fixedT = ad.clock.now()
  tad.clock = { now = function() return fixedT end, preciseMs = ad.clock.preciseMs }
  local root = {}
  local db = lib:Attach(root, { host = "Bench", adapters = tad, autoMaintenance = false })
  db:RegisterCounter({ id = "bench:simple", version = 1, measures = { "sum", "count" },
    grains = { "day", "week", "month", "year", "lifetime" } })
  db:RegisterCounter({ id = "bench:wide", version = 1, measures = { "sum", "count", "max" },
    dimensions = { { name = "mode", cap = 8 }, { name = "zone", cap = 40 } },
    aggregations = { {}, { "mode" }, { "zone" } },
    grains = { "hour", "day", "week", "month", "year", "phase", "lifetime" } })
  local hs, hw = db:Handle("bench:simple"), db:Handle("bench:wide")
  local modes = { "foot", "mount", "swim", "fly" }
  local zones = {}
  for i = 1, 20 do zones[i] = "Zone" .. i end
  -- warm up (interning, buckets)
  for i = 1, 200 do hs:Add(1); hw:Add(i, modes[i % 4 + 1], zones[i % 20 + 1]) end
  local clock = ad.clock.preciseMs
  local res = { writes = n }
  collectgarbage("collect")
  local kb0 = collectgarbage("count")
  local t0 = clock()
  for _ = 1, n do hs:Add(1.5) end
  local t1 = clock()
  for i = 1, n do hw:Add(i, modes[i % 4 + 1], zones[i % 20 + 1]) end
  local t2 = clock()
  local kb1 = collectgarbage("count")
  res.simpleMs, res.wideMs = t1 - t0, t2 - t1
  res.simpleUsPerWrite = (t1 - t0) * 1000 / n
  res.wideUsPerWrite = (t2 - t1) * 1000 / n
  res.allocKB = kb1 - kb0
  local q0 = clock()
  for _ = 1, 50 do db:Query({ counter = "bench:wide", grain = "day", groupBy = "zone", top = 10 }) end
  res.queryMs = (clock() - q0) / 50
  db:Detach()
  return res
end
