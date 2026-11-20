-- One-time migrations of saved data. Each runs once storage is attached and the counters are registered (this
-- file's OnReady comes after Registry's, Time's and Runs'), then marks HardCountersDB.migrations[name] = true.
local _, ns = ...

local type, pairs, ipairs = type, pairs, ipairs

---------------------------------------------------------------------------
-- HC-25 (user, 2026-11-15: "since we are committing to numeric ids, stick with that"): zone keys are numbers.
-- Builds before HC-13 saved the zone text where no map ID was known ("The Deadmines", "Shadowfang Keep"). Purge:
-- LibGranaryDB can't delete one member, so every counter whose "zone" dimension holds text is dropped whole
-- (DropCounter); run records and the open run lose their text zone keys (totals are kept) and get their main zone
-- again from what is left.
---------------------------------------------------------------------------

local BUCKETS = { other = true, none = true } -- LibGranaryDB's own buckets, not zone keys

--- Counters (registered or frozen) whose "zone" dimension holds a text member, sorted.
local function textZoneCounters(db)
  local out = {}
  local stats = db:Stats()
  for id in pairs(stats and stats.counters or {}) do
    if id:sub(1, 1) ~= "@" then
      local members = db:Members(id, "zone")
      if members then
        for _, m in ipairs(members) do
          if type(m) == "string" then out[#out + 1] = id; break end
        end
      end
    end
  end
  table.sort(out)
  return out
end

--- Remove text zone keys from a run structure: a `zone` field that is text goes, a `zone` table (a breakdown)
--- loses its text keys. Returns how many were removed.
local function scrubZones(t, depth)
  local n = 0
  if depth > 10 then return n end
  for k, v in pairs(t) do
    if k == "zone" then
      if type(v) == "string" then
        t[k] = nil
        n = n + 1
      elseif type(v) == "table" then
        for zk in pairs(v) do
          if type(zk) == "string" and not BUCKETS[zk] then v[zk] = nil; n = n + 1 end
        end
      end
    elseif type(v) == "table" then
      n = n + scrubZones(v, depth + 1)
    end
  end
  return n
end

local function scrubRuns(R)
  local n = 0
  for _, rec in ipairs(type(R.list) == "table" and R.list or {}) do
    if type(rec) == "table" then
      n = n + scrubZones(rec, 0)
      if rec.mainZone ~= nil and type(rec.mainZone) ~= "number" then
        rec.mainZone = type(rec.deltas) == "table" and ns.MainZone(rec.deltas) or nil
        n = n + 1
      end
    end
  end
  if type(R.open) == "table" then n = n + scrubZones(R.open, 0) end
  if type(R.opens) == "table" then n = n + scrubZones(R.opens, 0) end
  return n
end

local function hc25(SV, db)
  local ids = textZoneCounters(db)
  if #ids > 0 then
    ns.RebaseOpenRun(function()
      for _, id in ipairs(ids) do db:DropCounter(id) end
    end)
    ns.Log("info", "HC", "HC-25: dropped %d counters with text zone keys: %s", #ids, table.concat(ids, ", "))
  end
  local n = type(SV.runs) == "table" and scrubRuns(SV.runs) or 0
  -- odometers and windows (HC-29) hold per-zone totals too; a key gone from both sides drops out of every window
  if type(SV.odo) == "table" then n = n + scrubZones(SV.odo, 0) end
  if type(SV.windows) == "table" then n = n + scrubZones(SV.windows, 0) end
  if n > 0 then ns.Log("info", "HC", "HC-25: removed %d text zone keys from runs", n) end
end

---------------------------------------------------------------------------
-- HC-41 (user, 2026-11-18: "the board is the clock"; start fresh): tiles no longer own windows. Their saved windows
-- ("t<n>@<character>" and "t<n>@account", HC-30) are dropped, on every character; boards make their own
-- ("b<n>@..."), from zero. The tiles' own fields (tile.wid, tiles of kind "run") go per profile, at the profile's
-- first use (UI/BoardModel.lua, M.Store). Nothing is saved as a run on the way.
---------------------------------------------------------------------------

local function hc41(SV)
  local all = type(SV.windows) == "table" and SV.windows or nil
  if not all then return end
  local n = 0
  for k in pairs(all) do
    if type(k) == "string" and k:match("^t%d+@") then all[k] = nil; n = n + 1 end
  end
  if n > 0 then ns.Log("info", "HC", "HC-41: dropped %d tile windows (boards keep one window each now)", n) end
end

---------------------------------------------------------------------------

local MIGRATIONS = {
  { name = "hc25", run = hc25, ready = function(db) return type(db.Members) == "function" end },
  { name = "hc41", run = hc41, ready = function() return true end },
}

ns.OnReady(function()
  local SV, db = ns.SV, ns.db
  if not (SV and db) or db:IsReadOnly() then return end  -- read-only: try again at a later load
  SV.migrations = type(SV.migrations) == "table" and SV.migrations or {}
  for _, m in ipairs(MIGRATIONS) do
    if not SV.migrations[m.name] and m.ready(db) then
      m.run(SV, db)
      SV.migrations[m.name] = true
    end
  end
end)
