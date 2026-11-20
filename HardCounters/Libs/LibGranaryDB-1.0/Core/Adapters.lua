-- Adapters: every outside dependency (clock, calendar, codecs, scheduler, callbacks, secret guard,
-- logger, error handler, game version) sits behind one of these. Pure-Lua defaults live here; the
-- WoW implementations live in Adapters/WoW.lua and are only loaded in game.
local lib = LibStub and LibStub("LibGranaryDB-1.0", true)
local M = lib and lib.__M
if not M then return end

local type, pairs = type, pairs
local floor = math.floor

local A = {}
M.Adapters = A

-- Required functions per adapter (adapters wrap only what the library uses).
A.REQUIRED = {
  clock = { "now", "preciseMs" },
  calendar = { "fields", "resetAnchor" },
  serializer = { "encode", "decode" },
  compressor = { "compress", "decompress" },
  encoder = { "encode", "decode" },
  scheduler = { "after" },
  callbacks = { "Fire" },
  secret = { "isSecret" },
  logger = { "log" },
  errors = { "handle" },
  env = { "gameVersion" },
}

A.RESET_ANCHORS = {
  EU = 532800, -- 1970-01-07 (Wednesday) 04:00 UTC
  US = 486000, -- 1970-01-06 (Tuesday) 15:00 UTC
}

--- Turn any weekly reset time (past or future) into the canonical anchor in [0, 604800): the reset's
--- position within the week, rounded to the nearest minute. resetweek keys are floor((t - anchor) / week),
--- so the anchor must not depend on when it was read, or keys from different sessions would not line up.
--- Rounding absorbs the second or two between GetServerTime() and GetSecondsUntilWeeklyReset().
function A.normalizeAnchor(resetTime)
  local m = floor(resetTime / 60 + 0.5) * 60
  return m % 604800
end

--- UTC civil fields from epoch seconds, by arithmetic (no os.date).
function A.utcFields(t)
  local days = floor(t / 86400)
  local secs = t - days * 86400
  local y, mo, d = M.Cal.civilFromDays(days)
  local h = floor(secs / 3600)
  local mi = floor((secs - h * 3600) / 60)
  return y, mo, d, h, mi, secs - h * 3600 - mi * 60
end

local function osAvailable() return type(os) == "table" and type(os.time) == "function" end

function A.defaults()
  local d = {}
  d.clock = {
    now = function() return osAvailable() and os.time() or 0 end,
    preciseMs = function() return osAvailable() and os.clock() * 1000 or 0 end,
  }
  d.calendar = {
    fields = function(t, utc)
      if utc or not osAvailable() then return A.utcFields(t) end
      local tt = os.date("*t", t)
      return tt.year, tt.month, tt.day, tt.hour, tt.min, tt.sec
    end,
    resetAnchor = function(region) return A.RESET_ANCHORS[region] or A.RESET_ANCHORS.EU end,
  }
  d.serializer = {
    encode = function(v) return M.Codec.cborEncode(v) end,
    decode = function(s, limits) return M.Codec.cborDecode(s, limits) end,
  }
  d.compressor = {
    name = "none",
    compress = function(s) return s end,
    decompress = function(s) return s end,
  }
  d.encoder = {
    encode = function(s) return M.Codec.base64Encode(s) end,
    decode = function(s) return M.Codec.base64Decode(s) end,
  }
  -- Without an event loop nothing runs later: tasks are queued and run by `pump()`.
  -- Hosts outside WoW call db:RunMaintenance() themselves; tests use a manual scheduler.
  local queue = {}
  d.scheduler = {
    after = function(_sec, fn) queue[#queue + 1] = fn end,
    pump = function()
      local q = queue
      queue = {}
      for i = 1, #q do q[i]() end
      return #q
    end,
  }
  d.callbacks = nil -- built per db (see Init)
  d.secret = { isSecret = function() return false end }
  d.logger = { log = function() end }
  d.errors = { handle = function(err) M.lastError = err end }
  d.env = { gameVersion = function() return "offline" end }
  return d
end

--- Merge host overrides over WoW adapters (in game) over pure defaults; validate.
--- Returns the adapter table, or nil and an error message naming the problem.
function A.resolve(overrides)
  local ad = A.defaults()
  local wow = M.wowAdapters and M.wowAdapters()
  if wow then
    for name, impl in pairs(wow) do ad[name] = impl end
  end
  if overrides ~= nil then
    if type(overrides) ~= "table" then return nil, "opts.adapters must be a table" end
    for name, impl in pairs(overrides) do
      if not A.REQUIRED[name] then return nil, "unknown adapter '" .. tostring(name) .. "'" end
      if type(impl) ~= "table" then return nil, "adapter '" .. name .. "' must be a table" end
      ad[name] = impl
    end
  end
  for name, fns in pairs(A.REQUIRED) do
    local impl = ad[name]
    if impl ~= nil then
      for i = 1, #fns do
        if type(impl[fns[i]]) ~= "function" then
          return nil, "adapter '" .. name .. "' is missing function '" .. fns[i] .. "'"
        end
      end
    end
  end
  if ad.compressor and type(ad.compressor.name) ~= "string" then
    return nil, "adapter 'compressor' needs a string field 'name' ('none' or e.g. 'deflate')"
  end
  return ad
end

--- A minimal callback registry, CallbackHandler-like, used when the host passes none.
function A.newRegistry(onError)
  local reg = { events = {} }
  function reg.Register(event, fn, owner)
    local list = reg.events[event]
    if not list then list = {}; reg.events[event] = list end
    list[owner or fn] = fn
  end
  function reg.Unregister(event, owner)
    local list = reg.events[event]
    if list then list[owner] = nil end
  end
  function reg.Fire(event, ...)
    local list = reg.events[event]
    if not list then return end
    for _, fn in pairs(list) do
      local ok, err = pcall(fn, event, ...)
      if not ok and onError then onError(err) end
    end
  end
  return reg
end
