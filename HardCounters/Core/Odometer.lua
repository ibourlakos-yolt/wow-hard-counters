-- Odometers and windows (DESIGN §16.1, §16.2; HC-29).
--
-- An odometer is a counter's running total for one character. It only grows, while the counter is active, and is
-- saved with the account's data, so it survives /reload and logout:
--   HardCountersDB.odo[characterKey][counterId] = { s = sum, n = count,            -- flows
--                                                   by = { dim = { member = sum } }, bn = { dim = members },
--                                                   rc = { bigDim = { member, ... } },  -- written last (HC-34)
--                                                   l = last value }                -- stocks
-- The emit path writes it (Registry.lua). It has nothing to do with history: a Live only counter has one too.
--
-- A window is a stretch of time with pauses. It holds no totals of its own, only bookmarks:
--   w.base      the odometers when the window last started counting (nil while it isn't counting)
--   w.baseChar  the character those odometers belong to
--   w.acc       what was banked at earlier boundaries: { [counterId] = { sum, count, by, start, stop } }
--   w.ids       optional set of counter ids; nil = every counter
--   w.board     a board's window (HC-41): it keeps the best single value per counter (w.max[counterId]) and notes
--               members of big dimensions that started being kept after its period began (w.late[counterId][member])
--   w.watch     big-dimension members its tiles show, { [counterId] = { [dim] = { [member] = true } } }: kept on
--               every character before the window takes a base there
-- A value over a window is acc + (odometer now - base). Any number of windows can be open at once: the run, the
-- login session ("session" scope) and, from HC-41, one per board (HC-30 had one per tile). Pausing banks the
-- difference and drops the base; resuming takes a new one. Offline nothing changes, so a window left counting at
-- logout is banked at the next login from the saved odometers of the character it was counting.
--
-- Plain data only: windows are saved (the open run in HardCountersDB.runs.open, the rest in HardCountersDB.windows).
local ADDON, ns = ...

local U, W = ns.U, ns.wow
local pairs, ipairs, type = pairs, ipairs, type

local Win = {}
ns.Win = Win

local function TIME() return ns.TIME_ID end

--- The saved odometers of a character (the table itself: internal).
local function odoOf(char)
  local all = ns.SV and ns.SV.odo
  return all and all[char] or nil
end

--- Bind ns.odo to the logged-in character's odometers (Engine.lua, once storage is attached).
function ns.BindOdometers()
  local SV = ns.SV
  SV.odo = type(SV.odo) == "table" and SV.odo or {}
  local key = ns.guid or "?"
  SV.odo[key] = type(SV.odo[key]) == "table" and SV.odo[key] or {}
  ns.odo = SV.odo[key]
end

local function wanted(w, id)
  local ids = w.ids
  return ids == nil or ids[id] == true
end

local attaching           -- the window taking a base right now (Win.Attach): not late for what it watches itself

--- A member of a big dimension starts being kept now: every board window of this character (and the account's)
--- whose period began earlier counted none of it so far, so its tiles say "since" (DESIGN §16.8). The odometer
--- member starts at 0, so a window counting now counts it exactly from here.
local function markLate(counterId, key)
  local all = ns.SV and ns.SV.windows
  if type(all) ~= "table" then return end
  local now = W.now()
  for _, w in pairs(all) do
    if type(w) == "table" and w.board and w ~= attaching and (w.char == ns.guid or w.account)
        and Win.Elapsed(w, now) > 0 then
      w.late = w.late or {}
      local m = w.late[counterId]
      if not m then m = {}; w.late[counterId] = m end
      if m[key] == nil then m[key] = now end
    end
  end
end

--- Have this character's odometer keep a total for one member of a big dimension (items), from now on. Small
--- dimensions keep every member anyway. Returns true if the member is (now) kept.
function ns.WatchMember(counterId, dim, key)
  local c = ns.counters[counterId]
  if not (c and c.dimIndex[dim] and ns.SV) then return false end
  if key == nil then return false end
  local big = false
  for _, d in ipairs(c.bigDims or {}) do if d == dim then big = true end end
  if not big then return true end
  local o = ns.odo[counterId]
  if not o then o = { s = 0, n = 0 }; ns.odo[counterId] = o end
  o.by = o.by or {}
  o.by[dim] = o.by[dim] or {}
  if o.by[dim][key] == nil then
    o.by[dim][key] = 0
    markLate(counterId, key)
  end
  return true
end

--- Members of a counter's dimension this character's odometer knows, as a list (unsorted; "other" and "none" left
--- out): what a picker can offer with history off.
function ns.OdoMembers(counterId, dim, out)
  out = out or {}
  local o = ns.odo[counterId]
  for _, t in ipairs({ o and o.by and o.by[dim], o and o.lb and o.lb[dim] }) do
    for k in pairs(t) do
      if k ~= "other" and k ~= "none" then
        local seen = false
        for i = 1, #out do if out[i] == k then seen = true; break end end
        if not seen then out[#out + 1] = k end
      end
    end
  end
  return out
end

--- The members of a big dimension this character wrote last, newest first (a copy; at most ns.RECENT_MEMBERS):
--- "recently looted" for an item picker (HC-34). Kept in the saved odometer, so a /reload or a login keeps them.
function ns.RecentMembers(counterId, dim, out)
  out = out or {}
  local o = ns.odo[counterId]
  local list = o and o.rc and o.rc[dim]
  if list then for i = 1, #list do out[#out + 1] = list[i] end end
  return out
end

--- A copy of the odometers a window needs.
local function baseline(w, char)
  local out = {}
  for id, o in pairs(odoOf(char) or {}) do
    if wanted(w, id) then
      local b = { s = o.s, n = o.n, l = o.l }
      if o.by and not w.noBy then
        b.by = {}
        for dim, m in pairs(o.by) do b.by[dim] = U.copy(m) end
      end
      out[id] = b
    end
  end
  return out
end

--- into[id] += (odometer - base), for every counter of the window. A counter with no base started from zero after
--- the window did. Stocks: start is the level at the base, stop the last one seen.
local function diffInto(w, into, withBy)
  local base = w.base
  local odo = base and odoOf(w.baseChar)
  if not odo then return end
  for id, o in pairs(odo) do
    if wanted(w, id) then
      local b = base[id]
      local d = into[id]
      if not d then d = {}; into[id] = d end
      if o.s then
        d.sum = (d.sum or 0) + o.s - (b and b.s or 0)
        d.count = (d.count or 0) + (o.n or 0) - (b and b.n or 0)
        if withBy and o.by and not w.noBy then
          d.by = d.by or {}
          for dim, m in pairs(o.by) do
            local mb = b and b.by and b.by[dim]
            local dd = d.by[dim]
            if not dd then dd = {}; d.by[dim] = dd end
            for k, v in pairs(m) do
              local x = v - (mb and mb[k] or 0)
              if x ~= 0 then dd[k] = (dd[k] or 0) + x end
            end
          end
        end
      end
      if o.l ~= nil then
        if d.start == nil then d.start = b and b.l end
        d.stop = o.l
      end
    end
  end
end

--- dst += src (deltas of the same shape).
local function addInto(dst, src)
  for id, s in pairs(src) do
    local d = dst[id]
    if not d then d = {}; dst[id] = d end
    if s.sum then d.sum = (d.sum or 0) + s.sum end
    if s.count then d.count = (d.count or 0) + s.count end
    if s.by then
      d.by = d.by or {}
      for dim, mb in pairs(s.by) do
        local dd = d.by[dim]
        if not dd then dd = {}; d.by[dim] = dd end
        for k, v in pairs(mb) do dd[k] = (dd[k] or 0) + v end
      end
    end
    if s.stop ~= nil then
      if d.start == nil then d.start = s.start end
      d.stop = s.stop
    end
    if s.lo ~= nil and (d.lo == nil or s.lo < d.lo) then d.lo = s.lo end
    if s.hi ~= nil and (d.hi == nil or s.hi > d.hi) then d.hi = s.hi end
  end
end
Win.AddInto = addInto

--- Is the window counting right now? (It has a base, on the logged-in character.)
function Win.Counting(w)
  return w.base ~= nil and w.baseChar == ns.guid
end

--- A new window, not counting yet. opts = { char = key or nil (nil: whoever is logged in), ids = set or nil,
--- noBy = true (no per-member totals: smaller), board = true (a board's window), watch = members to keep }.
function Win.New(opts)
  local now = W.now()
  return { start = now, state = "paused", pausedAt = now, pausedSeconds = 0, lastSeen = now, acc = {},
    char = opts and opts.char or nil, ids = opts and opts.ids or nil, noBy = opts and opts.noBy or nil,
    board = opts and opts.board or nil, watch = opts and opts.watch or nil }
end

--- Active seconds of a window (hc:time.active over it).
function Win.Active(w)
  return Win.Total(w, TIME(), "sum")
end

--- Freeze the window: like a pause, but the next start begins a new period (Win.Restart).
function Win.Stop(w)
  if w.state == "stopped" then return false end
  local now = W.now()
  if w.state == "running" then
    Win.Bank(w, nil, true)
  elseif w.pausedAt then
    w.pausedSeconds = (w.pausedSeconds or 0) + math.max(0, now - w.pausedAt)
  end
  w.state, w.pausedAt, w.stop = "stopped", nil, now
  return true
end

--- A frozen copy of what the window holds now: { start, stop, elapsed, active, deltas }. For records, and for the
--- "previous period" a reset or restart leaves behind.
function Win.Snapshot(w)
  local now = W.now()
  return { start = w.start, stop = w.stop or now, elapsed = Win.Elapsed(w, now), active = Win.Active(w),
    deltas = Win.Deltas(w, true), max = w.max and U.deepcopy(w.max) or nil, partial = w.ids ~= nil or nil }
end

--- A new period from zero, counting.
function Win.Restart(w)
  local now = W.now()
  -- the old base goes first: Attach flushes, and a flush folds the recent rate of every window still counting
  -- (ns.FoldRecent), which would seed it from the old period and read the new base as a loss
  w.base, w.baseChar = nil, nil
  w.acc, w.max, w.late, w.ew = {}, nil, nil, nil
  w.start, w.stop, w.pausedSeconds, w.pausedAt, w.lastSeen = now, nil, 0, nil, now
  w.state = "running"
  Win.Attach(w, true)
end

--- Start counting from the logged-in character's odometers (flushes in-memory seconds first unless flush = false).
function Win.Attach(w, flush)
  if flush ~= false then ns.FlushAll() end
  if w.watch then
    -- a member of a big dimension is kept only where somebody watches it: on this character too, before the base
    -- (an account window arriving on another character), so the window counts it from here, not "since"
    attaching = w
    for id, dims in pairs(w.watch) do
      for dim, keys in pairs(dims) do
        for key in pairs(keys) do ns.WatchMember(id, dim, key) end
      end
    end
    attaching = nil
  end
  w.base = baseline(w, ns.guid)
  w.baseChar = ns.guid
end

--- Bank what has accumulated since the base into w.acc (and into `also`, e.g. a run's current split), and stop
--- counting. Works for a base on another character: its odometers are saved. Returns true if there was a base.
function Win.Bank(w, also, flush)
  if not w.base then return false end
  if flush ~= false and w.baseChar == ns.guid then ns.FlushAll() end
  local d = {}
  diffInto(w, d, true)
  addInto(w.acc, d)
  if also then addInto(also, d) end
  w.base, w.baseChar = nil, nil
  return true
end

--- Start (or carry on) at time `now`: the paused stretch is added to the paused seconds.
function Win.Resume(w, now)
  now = now or W.now()
  if w.pausedAt then w.pausedSeconds = (w.pausedSeconds or 0) + math.max(0, now - w.pausedAt) end
  w.pausedAt = nil
  w.state = "running"
  w.lastSeen = now
  Win.Attach(w, true)
end

--- Pause at time t (default now): nothing is added until Resume.
function Win.Pause(w, t, flush, also)
  if w.state ~= "running" then return false end
  Win.Bank(w, also, flush)
  w.state = "paused"
  w.pausedAt = t or W.now()
  return true
end

--- Start over: nothing banked, a new base if it was counting, the clock at zero. A paused window stays paused; a
--- stopped one becomes paused at zero.
function Win.Reset(w)
  local now = W.now()
  local counting = w.base ~= nil
  w.base, w.baseChar = nil, nil   -- (as in Restart: the flush in Attach must not fold against the old base)
  w.acc, w.max, w.late, w.ew = {}, nil, nil, nil
  w.start, w.stop, w.pausedSeconds, w.lastSeen = now, nil, 0, now
  if w.state == "running" then
    w.pausedAt = nil
    if counting then Win.Attach(w, true) end
  else
    w.state = "paused"
    w.pausedAt = now
  end
end

--- Wall seconds the window has been running (pauses and time offline excluded).
function Win.Elapsed(w, now)
  now = now or W.now()
  local paused = (w.pausedSeconds or 0) + (w.pausedAt and math.max(0, now - w.pausedAt) or 0)
  return math.max(0, (w.stop or now) - w.start - paused)
end

--- A stock was observed at level v: every window counting on this character widens its lowest and highest level
--- (acc[id].lo, acc[id].hi; HC-27). The session, the open run and the board windows in use. Allocation only at a
--- window's first observation of a counter.
local function extend(w, id, v)
  if not (w.base ~= nil and w.baseChar == ns.guid and wanted(w, id)) then return end
  local a = w.acc[id]
  if not a then a = {}; w.acc[id] = a end
  if a.lo == nil or v < a.lo then a.lo = v end
  if a.hi == nil or v > a.hi then a.hi = v end
end

function ns.ObserveWindows(id, v)
  local all = ns.SV and ns.SV.windows
  local s = all and all.session
  if type(s) == "table" then extend(s, id, v) end
  local run = ns.OpenRun and ns.OpenRun()
  if run then extend(run, id, v) end
  local list = ns.maxWatch
  for i = 1, #list do extend(list[i], id, v) end
end

--- The lower (low) or higher of v and x; either may be nil.
local function further(v, x, low)
  if x == nil then return v end
  if v == nil or (low and x < v) or (not low and x > v) then return x end
  return v
end

--- One number of a window, without allocating. measure: "sum" (default) or "count"; for stocks "start", "stop" or
--- "last" (= stop). Flows are 0 when nothing was counted; a stock nobody has observed is nil.
function Win.Total(w, id, measure)
  local a = w.acc[id]
  local live = w.base ~= nil and w.baseChar == ns.guid
  if measure == nil or measure == "sum" or measure == "count" then
    local key = measure == "count" and "count" or "sum"
    local v = a and a[key] or 0
    if live then
      local o = ns.odo[id]
      if o and o.s then
        local b = w.base[id]
        if key == "sum" then v = v + o.s - (b and b.s or 0) else v = v + (o.n or 0) - (b and b.n or 0) end
      end
      if key == "sum" and id == TIME() and ns.PendingActive then v = v + ns.PendingActive() end
    end
    return v
  elseif measure == "start" then
    if a and a.start ~= nil then return a.start end
    local b = live and w.base[id]
    return b and b.l or nil
  elseif measure == "stop" or measure == "last" then
    if live then
      local o = ns.odo[id]
      if o and o.l ~= nil then return o.l end
    end
    return a and a.stop or nil
  elseif measure == "min" or measure == "max" then
    -- a stock's lowest or highest level over the window (HC-27): what was observed while it counted (acc.lo, acc.hi,
    -- ns.ObserveWindows), and the levels it started and stopped at, which held during the window too
    local low = measure == "min"
    local v = a and (low and a.lo or a.hi)
    if a then v = further(v, a.start, low); v = further(v, a.stop, low) end
    if live then
      local b = w.base[id]
      v = further(v, b and b.l, low)
      local o = ns.odo[id]
      v = further(v, o and o.l, low)
    end
    return v
  end
  return nil
end

--- One member's sum over a window (small dimensions kept by the odometer), without allocating.
function Win.MemberTotal(w, id, dim, member)
  local a = w.acc[id]
  local m = a and a.by and a.by[dim]
  local v = m and m[member] or 0
  if w.base ~= nil and w.baseChar == ns.guid then
    local o = ns.odo[id]
    local om = o and o.by and o.by[dim]
    if om and om[member] then
      local b = w.base[id]
      local bm = b and b.by and b.by[dim]
      v = v + om[member] - (bm and bm[member] or 0)
    end
  end
  return v
end

--- Every total of the window as a fresh table: { [counterId] = { sum, count, start, stop, by } }.
function Win.Deltas(w, withBy)
  local d = {}
  for id, x in pairs(w.acc) do
    d[id] = { sum = x.sum, count = x.count, start = x.start, stop = x.stop, lo = x.lo, hi = x.hi }
    if withBy and x.by then d[id].by = U.deepcopy(x.by) end
  end
  if w.base then
    diffInto(w, d, withBy)
    if w.baseChar == ns.guid and ns.PendingActive and wanted(w, TIME()) then
      local y = d[TIME()]
      if not y then y = {}; d[TIME()] = y end
      y.sum = (y.sum or 0) + ns.PendingActive()
    end
  end
  return d
end

--- At a real login: a window still counting was counting when the game closed. Bank it from the saved odometers
--- (offline nothing changes). Its clock stands still from when it was last seen until Win.Resume, which may be
--- much later (another character logs in first). Returns true if it was counting.
function Win.AtLogin(w, also)
  if not w.base then return false end
  local seen = w.lastSeen or W.now()
  Win.Bank(w, also, false)
  if w.state == "running" then w.pausedAt = seen end   -- still "running": it carries on by itself
  return true
end

---------------------------------------------------------------------------
-- The recent rate (DESIGN §16.9, HC-52): an exponentially weighted rate over a window with its own clock (a board's,
-- the open run, the session). Over the window's active seconds A, every gain is weighted exp(-(A - A_gain) / tau)
-- and so is every active second: S = the weighted gains, T = tau * (1 - exp(-A / tau)), rate = S / T. A big gain
-- fades instead of dropping off a cliff; early on T is small, so it is the plain average (no warm-up rule); AFK and
-- pauses freeze it (only active time decays it). Half-life 5 minutes, fixed (user, 2026-11-19).
--
-- Kept in the window, so it is saved and a /reload keeps it:
--   w.ew = { [counterId] = entry, c = { [counterId] = entry } (counts), m = { [counterId] = { [dim] = { [member] =
--            entry } } } }
--   entry = { s = S, x = the window's total when last folded in, a = A then, n = gains seen (members),
--             r = { the rate at each of the last 10 active minutes, oldest first }, ra = A at the last sample }
-- Folding is lazy: on a read, and every 15 s for whole counters of every counting window (ns.FoldRecent), so a gain
-- is dated at most 15 s late. A counter or member first seen in a window that already ran starts from that window's
-- average (S = total * T / A): no "since" marker, it converges within a few half-lives.
---------------------------------------------------------------------------

local exp = math.exp
local HALF_LIFE = 300
local TAU = HALF_LIFE / math.log(2)
ns.RECENT_HALF_LIFE = HALF_LIFE
ns.RECENT_MIN_GAINS = 5           -- settled: 5 active minutes (ns.RATE_SETTLE) and 5 gains (user, 2026-11-19)
local SAMPLES, SAMPLE_EVERY = 10, 60

local function weightOf(a) return TAU * (1 - exp(-a / TAU)) end

local function newEntry(x, a, n)
  local s = x
  if a > 0 then s = x * weightOf(a) / a end
  return { s = s, x = x, a = a, n = n or 0 }
end

--- Fold what the window gained since the entry was last folded, at active seconds a. A gain is dated in the middle
--- of that stretch (it came some time in it): unbiased on average, exact when folds follow the writes (a shown
--- board reads on every write).
local function fold(t, x, a)
  local d = a - t.a
  if d < -1e-3 or x < t.x - 1e-6 * (1 + math.abs(t.x)) then   -- (not a rounding at a pause: banking re-adds)
    -- the window's active time or total went back (a flow never does): the entry was folded against another
    -- period (a Reset before 0.2.1-beta1 saved such entries). Start it again from the window's average.
    local n = newEntry(x, a, t.n)
    t.s, t.x, t.a, t.r, t.ra = n.s, n.x, n.a, nil, nil
    return
  end
  local half = 1
  if d > 0 then
    local k = exp(-d / TAU)
    t.s = t.s * k
    t.a = a
    half = math.sqrt(k)
  end
  local g = x - t.x
  if g ~= 0 then
    t.s = t.s + g * half
    if g > 0 then t.n = (t.n or 0) + 1 end
    t.x = x
  end
end

--- Sample the entry's rate once per active minute (the hero's sparkline).
local function sample(t, a)
  if a - (t.ra or 0) < SAMPLE_EVERY or a < SAMPLE_EVERY then return end
  local r = t.r
  if not r then r = {}; t.r = r end
  if #r >= SAMPLES then table.remove(r, 1) end
  r[#r + 1] = t.s / weightOf(a) * 3600
  t.ra = a
end

local function entryOf(w, id, measure, dim, member, a)
  local e = w.ew
  if not e then e = {}; w.ew = e end
  if dim then
    local m = e.m
    if not m then m = {}; e.m = m end
    local mi = m[id]
    if not mi then mi = {}; m[id] = mi end
    local md = mi[dim]
    if not md then md = {}; mi[dim] = md end
    local t = md[member]
    local x = Win.MemberTotal(w, id, dim, member)
    if not t then t = newEntry(x, a); md[member] = t end
    return t, x
  end
  local tab = e
  if measure == "count" then
    tab = e.c
    if not tab then tab = {}; e.c = tab end
  end
  local t = tab[id]
  local x = Win.Total(w, id, measure == "count" and "count" or "sum")
  if not t then t = newEntry(x, a); tab[id] = t end
  return t, x
end

--- The recent rate per hour of a counter (or of one member of a small dimension) over a window, and the gains it
--- counts toward "settled" (a counter: the writes in the window; a member: the gains seen since it was first asked).
--- nil under one active minute, like per hour.
function Win.Recent(w, id, measure, dim, member)
  local a = Win.Active(w)
  local t, x = entryOf(w, id, measure, dim, member, a)
  fold(t, x, a)
  if a < 60 then return nil, 0 end
  local gains = dim and (t.n or 0) or Win.Total(w, id, "count")
  return t.s / weightOf(a) * 3600, gains
end

--- The last minutes of a counter's recent rate over a window, oldest first, into `out` (reused); nil with fewer
--- than two samples.
function Win.RecentSamples(w, id, out)
  local t = w.ew and w.ew[id]
  local r = t and t.r
  if not r or #r < 2 then return nil end
  for i = 1, #r do out[i] = r[i] end
  for i = #r + 1, #out do out[i] = nil end
  return out
end

--- Fold every flow of a counting window of this character (not the account's: no recent there), and sample.
local function foldWindow(w)
  if not (w.base ~= nil and w.baseChar == ns.guid) or w.account then return end
  local a = Win.Active(w)
  -- every active flow, written yet or not: its first gain is then dated, not spread over the window
  for id, c in pairs(ns.counters or {}) do
    if c.active and c.kind ~= "stock" and id ~= TIME() and wanted(w, id) then
      local t, x = entryOf(w, id, "sum", nil, nil, a)
      fold(t, x, a)
      sample(t, a)
    end
  end
end

function ns.FoldRecent()
  local all = ns.SV and ns.SV.windows
  if all then
    for _, w in pairs(all) do if type(w) == "table" then foldWindow(w) end end
  end
  local run = ns.OpenRun and ns.OpenRun()
  if run then foldWindow(run) end
end
ns.AddFlusher(ns.FoldRecent)     -- (a pause, a logout: what was gained is dated before the window stops)
ns.OnReady(function() ns.Every(15, ns.FoldRecent) end)

---------------------------------------------------------------------------
-- The login session: the window behind the "session" scope. A /reload carries on; a real login starts a new one.
---------------------------------------------------------------------------

local function windows()
  local SV = ns.SV
  SV.windows = type(SV.windows) == "table" and SV.windows or {}
  return SV.windows
end

local function newSession(seed)
  local w = Win.New({ char = ns.guid })
  w.state, w.pausedAt = "running", nil
  if seed then w.acc = seed end
  Win.Attach(w, false)
  windows().session = w
  return w
end

--- The session window of the logged-in character (made on the spot if a login didn't).
function ns.Session()
  if not ns.SV then return nil end
  local w = ns.SV.windows and ns.SV.windows.session
  if type(w) ~= "table" or w.char ~= ns.guid or not w.base then w = newSession() end
  return w
end

---------------------------------------------------------------------------
-- Saved windows by key (HC-41: one per board and character, "b<n>@<character>" in HardCountersDB.windows; HC-30
-- had one per tile, "t<n>@..."). A window survives logout (user, 2026-11-18): it is banked at the next login,
-- whoever logs in, and carries on at the next login of its own character. The time offline is not on its clock.
---------------------------------------------------------------------------

local Windows = {}
ns.SavedWindows = Windows        -- (ns.Windows is the window host, UI/Windows.lua)
local mine = {}          -- key -> window of the logged-in character (so the draw path builds no strings)
local shared = {}        -- key -> the account's window for that key
ns.maxWatch = {}         -- { window, ... }: the board windows in use; each keeps a best single value per counter

local function unwatch(w)
  local list = ns.maxWatch
  for i = #list, 1, -1 do if list[i] == w then table.remove(list, i) end end
end

--- The logged-in character's window for `key`, or nil; second value true when it was made just now. With `make`
--- (a function returning Win.New options) it is created and started when missing.
--- account = true: one window for the whole account ("<key>@account", DESIGN §16.5, HC-32). It counts whoever is
--- logged in: banked at each login like any window, then it carries on with that character's odometers, so its
--- value is the sum over characters of what each added while it ran.
function Windows.Get(key, make, account)
  local cache = account and shared or mine
  local w = cache[key]
  if w then return w, false end
  if not (ns.SV and ns.guid) then return nil end
  local all = windows()
  local full = key .. "@" .. (account and "account" or ns.guid)
  w = all[full]
  local made = false
  if type(w) ~= "table" then
    if not make then return nil end
    local opts = make() or {}
    opts.char = (not account) and ns.guid or nil
    w = Win.New(opts)
    w.account = account and true or nil
    all[full] = w
    Win.Resume(w)
    made = true
  end
  cache[key] = w
  if w.board then ns.maxWatch[#ns.maxWatch + 1] = w end
  return w, made
end

--- Forget a key's windows on every character (its board was deleted). onlyMine (HC-74: another character still has a
--- copy of the board, with the same timer number): only the logged-in character's window goes.
function Windows.Drop(key, onlyMine)
  unwatch(mine[key])
  local all = ns.SV and ns.SV.windows
  mine[key] = nil
  if onlyMine then
    if all and ns.guid then all[key .. "@" .. ns.guid] = nil end
    return
  end
  unwatch(shared[key])
  shared[key] = nil
  if not all then return end
  local prefix = key .. "@"
  for k in pairs(all) do
    if type(k) == "string" and k:sub(1, #prefix) == prefix then all[k] = nil end
  end
end

--- At a real login: bank every window that was left counting, then carry on with this character's running ones.
local function windowsAtLogin()
  for name, w in pairs(windows()) do
    if name ~= "session" and type(w) == "table" then
      Win.AtLogin(w)
      -- this character's windows carry on, and the account's (whoever logs in counts into those)
      if (w.char == ns.guid or w.account) and w.state == "running" and not w.base then Win.Resume(w) end
    end
  end
end

--- Engine.lua calls this at PLAYER_ENTERING_WORLD. oldMem: the pre-HC-29 login totals ({ s, n, l } per counter),
--- when a /reload brings in this code in the middle of a login: they carry over.
function ns.OnSession(isInitialLogin, oldMem)
  if not ns.SV then return end
  if isInitialLogin then windowsAtLogin() end
  local w = ns.SV.windows and ns.SV.windows.session
  if isInitialLogin or type(w) ~= "table" or w.char ~= ns.guid then
    local seed
    if type(oldMem) == "table" and not isInitialLogin then
      seed = {}
      for id, m in pairs(oldMem) do
        if type(m) == "table" then
          if (m.n or 0) > 0 then seed[id] = { sum = m.s or 0, count = m.n } end
          if m.l ~= nil and ns.odo[id] == nil then ns.odo[id] = { l = m.l } end
        end
      end
    end
    newSession(seed)
  end
end

-- HardCountersDB.windows is a flat map of saved windows (session, and one per board from HC-41). Each one that is
-- counting is dated at every flush (once a minute and at logout), so a login knows when it was last seen.
ns.AddFlusher(function()
  local all = ns.SV and ns.SV.windows
  if not all then return end
  local now = W.now()
  for _, w in pairs(all) do
    if type(w) == "table" and w.base and w.baseChar == ns.guid then w.lastSeen = now end
  end
end)
