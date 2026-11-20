-- Util: error discipline, logging, small helpers. Pure Lua 5.1.
local lib = LibStub and LibStub("LibGranaryDB-1.0", true)
local M = lib and lib.__M
if not M then return end

local format, type, error, tostring, pairs, next = string.format, type, error, tostring, pairs, next
local floor = math.floor

local U = {}
M.U = U

M.TAG = "[LibGranaryDB r" .. M.MINOR .. "]"
U.HUGE = math.huge

--- Misuse by the host: raise at `level`, counted from the function that calls misuse.
--- level 1 = the caller of misuse, 2 = its caller (normally the host's line), and so on.
function U.misuse(level, fmt, ...)
  local msg = select("#", ...) > 0 and format(fmt, ...) or fmt
  error(M.MAJOR .. ": " .. msg, level + 1)
end

--- Build the tagged INTERNAL message (DESIGN §10.1).
function U.internalMessage(what)
  return format("%s r%d INTERNAL: %s (schema %d) - please report", M.MAJOR, M.MINOR, tostring(what), M.SCHEMA)
end

--- Log through the db's logger adapter, tagged.
function U.log(db, level, msg)
  local logger = db and db._ad and db._ad.logger
  if logger then
    local ok = pcall(logger.log, level, M.TAG .. " " .. msg)
    return ok
  end
end

--- Record a warning in the db's health record (last 20), the log and the in-memory list.
function U.warn(db, msg)
  U.log(db, "warn", msg)
  local G = db and db._G
  if G and G.meta then
    local w = G.meta.warn
    if type(w) ~= "table" then w = {}; G.meta.warn = w end
    w[#w + 1] = msg
    while #w > 20 do table.remove(w, 1) end
  end
end

--- Report an internal failure: tag, log, keep in the health record; optionally go read-only.
function U.internal(db, what, goReadOnly)
  local msg = U.internalMessage(what)
  U.warn(db, msg)
  if goReadOnly and db then
    db._ro = true
    db._roReason = db._roReason or msg
  end
  return msg
end

local warnedDeprecations = {}
--- Deprecation warning, once per session per name.
function U.deprecated(db, name, replacement)
  if warnedDeprecations[name] then return end
  warnedDeprecations[name] = true
  U.log(db, "warn", format("%s is deprecated; use %s instead", name, replacement))
end

--- Bump a persisted stats counter.
function U.stat(db, key, n)
  local s = db._stats
  s[key] = (s[key] or 0) + (n or 1)
end

function U.isInteger(v)
  return type(v) == "number" and v == floor(v) and v > -9007199254740992 and v < 9007199254740992
end

function U.isFinite(v)
  return type(v) == "number" and v == v and v ~= U.HUGE and v ~= -U.HUGE
end

function U.copy(t, depth)
  if type(t) ~= "table" then return t end
  depth = depth or 0
  if depth > 20 then error("copy: too deep") end
  local r = {}
  for k, v in pairs(t) do r[k] = U.copy(v, depth + 1) end
  return r
end

--- Sorted array of a table's keys (numbers first, then strings).
function U.sortedKeys(t)
  local ks = {}
  for k in pairs(t) do ks[#ks + 1] = k end
  table.sort(ks, function(a, b)
    local ta, tb = type(a), type(b)
    if ta ~= tb then return ta < tb end
    return a < b
  end)
  return ks
end

function U.isEmpty(t) return t == nil or next(t) == nil end

function U.count(t)
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  return n
end

--- Is `t` a sequence 1..n with no other keys?
function U.isArray(t)
  local n = #t
  local c = 0
  for k in pairs(t) do
    if type(k) ~= "number" or k < 1 or k > n or k ~= floor(k) then return false end
    c = c + 1
  end
  return c == n
end

--- Parse a retention spec ("48h", "90d", "2y", "12w", "6m") into a number of periods of `grain`.
local SECONDS = { h = 3600, d = 86400, w = 604800, m = 2629746, y = 31556952 }
local GRAIN_SECONDS = { hour = 3600, day = 86400, week = 604800, resetweek = 604800, month = 2629746, year = 31556952 }
function U.retentionPeriods(spec, grain)
  if type(spec) == "number" then
    if spec >= 1 and spec == floor(spec) then return spec end
    return nil
  end
  if type(spec) ~= "string" then return nil end
  local n, unit = spec:match("^(%d+)([hdwmy])$")
  if not n then return nil end
  local gs = GRAIN_SECONDS[grain]
  if not gs then return nil end
  local periods = floor(tonumber(n) * SECONDS[unit] / gs + 0.5)
  if periods < 1 then periods = 1 end
  return periods
end
