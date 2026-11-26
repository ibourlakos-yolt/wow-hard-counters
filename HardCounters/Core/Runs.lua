-- Runs (DESIGN §5.1, §16.1, §16.3): a window with a name that leaves a record. One open per character: started by
-- hand (/hc run start), or by itself on entering an instance (HC-30). Records also come from a board's window
-- ("Save as run", ns.SaveWindowRecord, HC-41): every counter, no item lists.
--
-- The run is a window over the odometers (Odometer.lua, HC-29): its totals are what was banked at earlier
-- boundaries (run.acc) plus the odometers now minus the run's base. Every active counter is in it, with or
-- without history; nothing is read from storage. Pause banks and drops the base, resume takes a new one. Splits are
-- named sub-ranges cut at the same boundaries: each bank also goes into the current split.
--
-- Live-tracked detail (things subtraction can't give): per-member tallies of big dimensions (Farmer's item list)
-- and the run's best single value with context, for counters declaring runLive. Bounded (cap per counter, then
-- "other"). Fed by the emit path while the run is running.
--
-- Storage: HardCountersDB.runs = { opens = { [character] = <run> }, list = { newest first }, nextId }. Not in
-- LibGranaryDB. An open run is saved continuously, so it survives /reload, and logout too (user, 2026-11-18): it
-- is banked at the next login and carries on when its own character logs in; the time offline is not on its clock.
-- Nobody is asked anything. (Builds before HC-30 kept one run for the account in runs.open.)
local ADDON, ns = ...

local HC, U, W, Win = ns.HC, ns.U, ns.wow, ns.Win
local pairs, ipairs, type, select, tostring, error = pairs, ipairs, type, select, tostring, error

local TOP_KEEP, SPLIT_TOP_KEEP = 25, 10
local TIME = ns.TIME_ID

local function store()
  local SV = ns.SV
  SV.runs = type(SV.runs) == "table" and SV.runs or {}
  local R = SV.runs
  R.list = type(R.list) == "table" and R.list or {}
  R.nextId = R.nextId or 1
  R.opens = type(R.opens) == "table" and R.opens or {}
  if type(R.open) == "table" then                    -- the single open run of builds before HC-30
    local key = R.open.char or "?"
    if not R.opens[key] then R.opens[key] = R.open end
  end
  R.open = nil
  return R
end

--- The logged-in character's open run (the saved table: internal).
local function openRun()
  if not (ns.SV and ns.guid) then return nil end
  return store().opens[ns.guid]
end
ns.OpenRun = openRun

--- Active seconds under which a window or an automatic run is not worth a record (DESIGN §16.3).
ns.RECORD_MIN_ACTIVE = 300

---------------------------------------------------------------------------
-- Records
---------------------------------------------------------------------------

--- Keep the `n` largest members (by absolute value); the rest are summed into "other".
local function trimTop(m, n)
  local keys = {}
  for k in pairs(m) do keys[#keys + 1] = k end
  if #keys <= n then return U.copy(m) end
  table.sort(keys, function(x, y)
    local ax, ay = math.abs(m[x]), math.abs(m[y])
    if ax ~= ay then return ax > ay end
    return tostring(x) < tostring(y)
  end)
  local out = {}
  for i = 1, n do out[keys[i]] = m[keys[i]] end
  local rest = 0
  for i = n + 1, #keys do rest = rest + m[keys[i]] end
  if rest ~= 0 then out.other = (out.other or 0) + rest end
  return out
end

local function trimmedDeltas(d, n)
  local out = {}
  for id, x in pairs(d) do
    local y = { sum = x.sum, count = x.count, start = x.start, stop = x.stop }
    if x.start ~= nil or x.stop ~= nil or x.lo ~= nil then
      -- a stock's lowest and highest level over the record (HC-27): seen while it counted, or where it began or ended
      local lo, hi = x.lo, x.hi
      for i = 1, 2 do
        local l = i == 1 and x.start or x.stop
        if l ~= nil then
          if lo == nil or l < lo then lo = l end
          if hi == nil or l > hi then hi = l end
        end
      end
      y.lo, y.hi = lo, hi
    end
    if x.by then
      y.by = {}
      for dim, mb in pairs(x.by) do y.by[dim] = trimTop(mb, n) end
    end
    out[id] = y
  end
  return out
end

--- The zone with the most active seconds (zone keys are numbers, HC-25; the "other" bucket never wins).
local function mainZone(d)
  local t = d[TIME] and d[TIME].by and d[TIME].by.zone
  if not t then return nil end
  local best, bv
  for k, v in pairs(t) do if type(k) == "number" and (not bv or v > bv) then best, bv = k, v end end
  return best
end
ns.MainZone = mainZone

---------------------------------------------------------------------------
-- Live tallies (fed by the emit path)
---------------------------------------------------------------------------

--- Called by Registry after a successful Emit/EmitCtx on a runLive counter.
ns.runEmitHook = function(c, v, ctx, ...)
  -- every board window counting now keeps its own best per counter (w.max[counterId], DESIGN §16.8)
  if c.runLive.max then
    local watch = ns.maxWatch
    for i = 1, #watch do
      local w = watch[i]
      if w.base and w.baseChar == ns.guid then
        local m = w.max
        if not m then m = {}; w.max = m end
        local cur = m[c.id]
        if not cur or v > cur.v then m[c.id] = { v = v, t = W.now(), zone = ns.currentZone } end
      end
    end
  end
  local run = openRun()
  if not run or not run.base then return end
  local rl = c.runLive
  local L = run.live[c.id]
  if not L then L = { m = {}, n = 0 }; run.live[c.id] = L end
  local key
  if rl.memberIdx then
    key = select(rl.memberIdx, ...)
    if key == nil then key = "none" end
    local cur = L.m[key]
    if cur == nil and L.n >= rl.cap then
      key = "other"
      cur = L.m.other
    end
    if cur == nil then L.n = L.n + 1 end
    L.m[key] = (cur or 0) + v
  end
  if rl.max and (not L.max or v > L.max.v) then
    local rec = { v = v, t = W.now(), member = key, zone = ns.currentZone }
    if ctx then for k, x in pairs(ctx) do if rec[k] == nil and type(x) ~= "table" then rec[k] = x end end end
    L.max = rec
    ns.Fire("HC_RUN_RECORD", c.id, v)
  end
end

---------------------------------------------------------------------------
-- Run lifecycle
---------------------------------------------------------------------------

local function curSplit(run) return run.splits[#run.splits].acc end

--- A run saved by a build before HC-29 kept its open segment as live sums (run.seg) over a storage snapshot
--- (run.segStart). Fold the sums into the run and carry on over the odometers.
local function adoptOldRun(run)
  if run.seg == nil and run.segStart == nil then return end
  if run.state == "running" then
    local d = {}
    for id, s in pairs(type(run.seg) == "table" and run.seg or {}) do
      local a = type(run.segStart) == "table" and run.segStart[id]
      d[id] = { sum = s.sum, count = s.count, by = s.by, start = a and a.last or nil, stop = s.last }
    end
    Win.AddInto(run.acc, d)
    Win.AddInto(curSplit(run), d)
    if run.char == ns.guid then Win.Attach(run, false) end
  end
  run.seg, run.segStart = nil, nil
end

ns.OnReady(function()
  local run = openRun()
  if run then adoptOldRun(run) end
end)

local function fail(msg) return nil, msg end

local function cleanLabel(label)
  return (type(label) == "string" and label ~= "") and label:sub(1, 64) or nil
end

--- Put a record at the head of the run list (capped) and tell everyone.
local function keep(R, rec)
  table.insert(R.list, 1, rec)
  local max = (ns.settings and ns.settings.maxRuns) or 500
  while #R.list > max do table.remove(R.list) end
  ns.Fire("HC_RUN_STOPPED", rec.id)
end

--- Save a record from a window's snapshot (Win.Snapshot): a board's "Save as run". A board's window watches every
--- counter, so the record has them all (rec.partial only for a window that watched some: snap.partial), with the
--- best single values it kept, but no item lists (HC-2(c)). Returns the record id.
function ns.SaveWindowRecord(snap, label)
  if not (ns.ready and type(snap) == "table") then return nil end
  local R = store()
  local id = R.nextId
  R.nextId = id + 1
  local info = W.entityInfo()
  local rec = {
    id = id, label = cleanLabel(label), char = ns.guid, charName = info.name, partial = snap.partial or nil,
    start = snap.start, stop = snap.stop, elapsed = snap.elapsed or 0, activeSeconds = snap.active or 0,
    deltas = trimmedDeltas(snap.deltas or {}, TOP_KEEP), live = {},
  }
  for cid, m in pairs(type(snap.max) == "table" and snap.max or {}) do rec.live[cid] = { max = U.copy(m) } end
  rec.pausedSeconds = math.max(0, (rec.stop or rec.start) - rec.start - rec.elapsed)
  rec.mainZone = mainZone(rec.deltas) or (type(ns.currentZone) == "number" and ns.currentZone or nil)
  keep(R, rec)
  return id
end

--- Start a run. Returns the run id, or nil and a reason (a run is already open; storage not ready; read-only).
function HC:StartRun(label)
  if not ns.ready then return fail("storage not ready") end
  if ns.db:IsReadOnly() then return fail("storage is read-only") end
  local R = store()
  local cur = R.opens[ns.guid]
  if cur and cur.auto then
    -- the player starts a run inside a dungeon: the automatic one ends here (saved if it is worth a record)
    if Win.Active(cur) >= ns.RECORD_MIN_ACTIVE then HC:StopRun() else HC:DiscardRun() end
    cur = nil
  end
  if cur then return fail("a run is already open") end
  local now = W.now()
  local id = R.nextId
  R.nextId = id + 1
  local info = W.entityInfo()
  local run = {
    id = id, label = (type(label) == "string" and label ~= "") and label:sub(1, 64) or nil,
    char = ns.guid, charName = info.name, start = now, state = "running",
    pausedSeconds = 0, lastSeen = now, acc = {}, live = {},
    splits = { { start = now, acc = {} } },
  }
  Win.Attach(run, true)
  R.opens[ns.guid] = run
  ns.Fire("HC_RUN_STARTED", id)
  return id
end

--- Pause the open run: its clock stops and nothing is added until ResumeRun.
function HC:PauseRun()
  local run = openRun()
  if not run then return fail("no open run") end
  if not Win.Pause(run, W.now(), true, curSplit(run)) then return fail("the run is not running") end
  ns.Fire("HC_RUN_PAUSED", run.id, "manual")
  return true
end

function HC:ResumeRun()
  local run = openRun()
  if not run then return fail("no open run") end
  if run.state ~= "paused" then return fail("the run is not paused") end
  Win.Resume(run, W.now())
  ns.Fire("HC_RUN_RESUMED", run.id)
  return true
end

--- End the current split and start a new one (labels are optional: "Spot 2", "After reset").
function HC:SplitRun(label)
  local run = openRun()
  if not run then return fail("no open run") end
  local now = W.now()
  local counting = Win.Bank(run, curSplit(run), true)
  local cur = run.splits[#run.splits]
  cur.stop = now
  run.splits[#run.splits + 1] = { start = now, acc = {}, label = (type(label) == "string" and label ~= "") and label:sub(1, 64) or nil }
  if counting then Win.Attach(run, false) end
  ns.Fire("HC_RUN_SPLIT", run.id, #run.splits)
  return #run.splits
end

--- Stop the open run and save its record (newest first, the list is capped). Returns the run id.
function HC:StopRun()
  local R = store()
  local run = R.opens[ns.guid]
  if not run then return fail("no open run") end
  local now = W.now()
  if run.state == "running" then
    Win.Bank(run, curSplit(run), true)
  elseif run.pausedAt then
    run.pausedSeconds = run.pausedSeconds + math.max(0, now - run.pausedAt)
  end
  run.splits[#run.splits].stop = now
  local rec = {
    id = run.id, label = run.label, char = run.char, charName = run.charName,
    start = run.start, stop = now, pausedSeconds = run.pausedSeconds,
    deltas = trimmedDeltas(run.acc, TOP_KEEP), live = U.deepcopy(run.live),
  }
  rec.elapsed = math.max(0, now - run.start - run.pausedSeconds)
  rec.activeSeconds = run.acc[TIME] and run.acc[TIME].sum or 0
  rec.mainZone = mainZone(run.acc)
  if #run.splits > 1 then
    rec.splits = {}
    for i, sp in ipairs(run.splits) do
      rec.splits[i] = { label = sp.label, start = sp.start, stop = sp.stop,
        activeSeconds = sp.acc[TIME] and sp.acc[TIME].sum or 0, deltas = trimmedDeltas(sp.acc, SPLIT_TOP_KEEP) }
    end
  end
  R.opens[ns.guid] = nil
  keep(R, rec)
  return rec.id
end

--- Close the open run without a record (an automatic run too short to be worth one). Returns its id.
function HC:DiscardRun()
  local R = store()
  local run = R.opens[ns.guid]
  if not run then return fail("no open run") end
  R.opens[ns.guid] = nil
  ns.Fire("HC_RUN_DELETED", run.id)
  return run.id
end

---------------------------------------------------------------------------
-- Reading runs (copies only)
---------------------------------------------------------------------------

--- The open run (a live copy), or nil. opts.breakdowns: include per-member breakdowns; opts.live: include the
--- live-tracked tallies (item lists can be long: don't ask for them every frame).
function HC:GetRun(opts)
  local run = openRun()
  if not run then return nil end
  opts = opts or {}
  local now = W.now()
  local d = Win.Deltas(run, opts.breakdowns)
  local out = {
    id = run.id, label = run.label, char = run.char, charName = run.charName, start = run.start, state = run.state,
    elapsed = Win.Elapsed(run, now), activeSeconds = d[TIME] and d[TIME].sum or 0, totals = d, splitCount = #run.splits,
    isCurrentCharacter = run.char == ns.guid, auto = run.auto and true or false,
  }
  if opts.live then out.live = U.deepcopy(run.live) end
  if opts.live == nil then
    -- small summary of live records: the best value per counter
    out.best = {}
    for id, L in pairs(run.live) do if L.max then out.best[id] = U.copy(L.max) end end
  end
  return out
end

--- One live number from the open run, without allocating: measure "sum" (default) or "count"; for stocks "start"
--- or "stop" (nil when the stock was never observed). Returns nil when no run is open.
function HC:GetRunTotal(counterId, measure)
  local run = openRun()
  if not run then return nil end
  return Win.Total(run, counterId, measure)
end

--- Active seconds and wall seconds of the open run (cheap; for stopwatch displays).
function HC:GetRunClock()
  local run = openRun()
  if not run then return nil end
  return Win.Total(run, TIME, "sum"), Win.Elapsed(run, W.now()), run.state
end

local function matches(rec, filter)
  if not filter then return true end
  if filter.character then
    local want = filter.character == "current" and ns.guid or filter.character
    if rec.char ~= want then return false end
  end
  if filter.since and rec.start < filter.since then return false end
  return true
end

--- Past run records, newest first (copies). filter = { character = "current"|<key>, since = epoch, limit = n }.
function HC:Runs(filter)
  local out = {}
  if not ns.SV then return out end
  local limit = filter and filter.limit
  for _, rec in ipairs(store().list) do
    if matches(rec, filter) then
      out[#out + 1] = U.deepcopy(rec)
      if limit and #out >= limit then break end
    end
  end
  return out
end

local NONE = {}

--- (0.4.0, the Stints tab) The kept records themselves, newest first: no copies, so a refresh of the tab costs no
--- deep copy of up to maxRuns records (HC:Runs hands out copies for everyone else). Internal and read-only: write
--- through RenameRun and DeleteRun, never into these tables.
function ns.StintRows()
  if not ns.SV then return NONE end
  return store().list
end

function HC:GetRunRecord(id)
  if not ns.SV then return nil end
  for _, rec in ipairs(store().list) do if rec.id == id then return U.deepcopy(rec) end end
  return nil
end

function HC:DeleteRun(id)
  if not ns.SV then return false end
  local list = store().list
  for i, rec in ipairs(list) do
    if rec.id == id then
      table.remove(list, i)
      ns.Fire("HC_RUN_DELETED", id)
      return true
    end
  end
  return false
end

function HC:RenameRun(id, label)
  if type(label) ~= "string" then error("HardCounters: RenameRun(id, label): label must be a string", 2) end
  label = label ~= "" and label:sub(1, 64) or nil
  local run = openRun()
  if run and run.id == id then run.label = label; return true end
  for _, rec in ipairs(ns.SV and store().list or {}) do
    if rec.id == id then rec.label = label; return true end
  end
  return false
end

function ns.RunSummary()
  if not ns.SV then return nil end
  local R = store()
  local run = R.opens[ns.guid]
  return { open = run ~= nil, state = run and run.state or nil, kept = #R.list }
end

---------------------------------------------------------------------------
-- The same API in the player's word (0.4.0): the UI says "stint", a stretch of play you kept. The saved data, the
-- tile scope "run" and the HC_RUN_* callbacks keep their names. Wrappers rather than copies, so a pack hooking
-- StartRun sees StartStint calls too.
---------------------------------------------------------------------------

function HC:StartStint(label) return self:StartRun(label) end
function HC:PauseStint() return self:PauseRun() end
function HC:ResumeStint() return self:ResumeRun() end
function HC:SplitStint(label) return self:SplitRun(label) end
function HC:StopStint() return self:StopRun() end
function HC:DiscardStint() return self:DiscardRun() end
function HC:GetStint(opts) return self:GetRun(opts) end
function HC:Stints(filter) return self:Runs(filter) end
function HC:GetStintRecord(id) return self:GetRunRecord(id) end
function HC:DeleteStint(id) return self:DeleteRun(id) end
function HC:RenameStint(id, label) return self:RenameRun(id, label) end


---------------------------------------------------------------------------
-- Login, logout, /reload
---------------------------------------------------------------------------

ns.AddFlusher(function()
  local run = openRun()
  if run and run.state == "running" and run.base then run.lastSeen = W.now() end
end)

---------------------------------------------------------------------------
-- Dungeon runs by themselves (HC-2a, DESIGN 16.3): entering an instance starts a run named after it, leaving
-- stops and saves it. A run the player started is never touched. Too short (under RECORD_MIN_ACTIVE) leaves no
-- record. Never outdoors: junk runs would fill the list.
---------------------------------------------------------------------------

local function finishAuto(run)
  if Win.Active(run) >= ns.RECORD_MIN_ACTIVE then HC:StopRun() else HC:DiscardRun() end
end

local function instanceCheck()
  if not ns.ready or (ns.settings and ns.settings.autoInstanceRuns == false) then return end
  local z = ns.currentZone
  local inside = type(z) == "number" and z > (W.INSTANCE_BASE or 100000)
  local run = openRun()
  if run and run.auto and run.auto ~= z then
    finishAuto(run)
    run = nil
  end
  if inside and not run then
    local id = HC:StartRun(HC:ZoneName(z))
    local started = id and openRun()
    if started then started.auto = z end
  end
end

HC.RegisterCallback({}, "HC_ZONE_CHANGED", instanceCheck)

-- PLAYER_ENTERING_WORLD after the Engine's handler (which sets ns.isInitialLogin). A /reload carries on.
ns.On("PLAYER_ENTERING_WORLD", function()
  if not ns.ready then return end
  if ns.isInitialLogin then
    -- offline nothing changes: bank every run left counting from its character's saved odometers
    for _, run in pairs(store().opens) do
      if type(run) == "table" and type(run.splits) == "table" then Win.AtLogin(run, curSplit(run)) end
    end
    local run = openRun()
    if run and run.state == "running" and not run.base then Win.Resume(run) end
  end
  instanceCheck()
end)

--- Call fn, which may drop stored data (HC-25's purge). Runs no longer read storage (HC-29): nothing to protect.
function ns.RebaseOpenRun(fn)
  return fn()
end
