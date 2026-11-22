-- Traveler's movement model (DESIGN §1, §0.2, §0.3): pure Lua, no game calls. Traveler.lua reads the game into a
-- sample four times a second and calls Step; the model decides the mode of each stretch, the jumps, legs, top
-- speeds, spacebar jumps and falls, deaths and flights, and reports them through `out` (the counters' writes).
-- Tested on its own with a fake position stream (tests/motion_spec.lua).
local ADDON, ns = ...

local M = {}
M.__index = M
ns.Motion = M

local sqrt = math.sqrt

M.LEG_STOP = 3          -- a stop longer than this ends a leg (§1.4)
M.LONG_JUMP = 40        -- more than this in one tick, whatever the gap: a teleport-class jump (§1.3)
M.SHORT_JUMP = 8        -- a blink or leap moves at least this far in one tick
M.SPEED_WINDOW = 2      -- top speed over windows of at least 2 s (no spikes)
M.PRESS_WINDOW = 0.75   -- a take-off this soon after a spacebar press is that jump
M.FALL_MIN = 1          -- falls shorter than this are steps and kerbs, not counted
M.CAST_WINDOW = 30      -- a teleport's spell before its loading screen (the cast, then the load)
M.BLINK_WINDOW = 1.5    -- a blink or leap's spell before its displacement
M.SUMMON_WINDOW = 120   -- a summon offered, then accepted
M.CARRIED_WINDOW = 15   -- a boat ride, then its crossing behind a loading screen
M.HEALER_WINDOW = 120   -- the spirit healer's dialog, then the resurrection
M.CORPSE_NEAR = 60      -- resurrected farther than this from the corpse: at the spirit healer
M.MAX_DT = 5            -- an estimate (no position) never spans more than this
M.RUN = 7               -- the 100% run speed (yd/s), until the game says the character's own

--- The ways of changing place that make records (legs, top speed): "under my own power" (§0.2 b), no jumps.
M.OWN = { walk = true, run = true, mounted = true, travelform = true, aquaticform = true, swim = true, dive = true,
  flying = true, ghost = true }
local RIDDEN = { taxi = true, carried = true, vehicle = true }
local FAST = { mounted = true, travelform = true, flying = true }

--- out: { move(mode, yd, sec, zone, estimated), jump(mode, yd, zone), leg(mode, yd, sec, zone),
---        speed(mode, v, zone), hop(kind, mode), air(kind, sec, mode), death(kind), flight(yd, sec) }
function M.new(out)
  return setmetatable({ out = out, run = M.RUN, ring = { 0, 0, 0 }, ri = 0 }, M)
end

---------------------------------------------------------------------------
-- Signals from events (Traveler.lua)
---------------------------------------------------------------------------

--- A spell of a known kind succeeded: "hearth", "teleport", "blink", "leap".
function M:Cast(kind, t)
  if kind == "blink" or kind == "leap" then
    self.blinkKind, self.blinkT = kind, t
  else
    self.castKind, self.castT = kind, t
  end
end

function M:Summon(t) self.summonT = t end
function M:XPLoss(t) self.xpLossT = t end
--- A loading screen started: the next position is across it (kept, not reset: §1.3, TR-5).
function M:Loading() self.gap = true end
--- The distance to the corpse while a ghost (yards), or nil when unknown.
function M:Corpse(d) self.corpseD = d end

--- The mode a spacebar press or a take-off belongs to: the leg's when moving on foot, else from the flags.
local function airMode(self, s)
  if s.ghost then return "ghost" end
  if s.form == "travel" then return "travelform" end
  if s.mounted then return "mounted" end
  local leg = self.leg
  if leg and (leg.mode == "walk" or leg.mode == "run") then return leg.mode end
  return "run"
end

--- A spacebar press (the secure post-hook on the jump action, §0.2 c). Counted only from the ground: not falling,
--- swimming or on a taxi. `s` holds the flags read at the press.
function M:Press(t, s)
  if s.falling or s.swim or s.taxi then return false end
  self.pressT = t
  local mode = airMode(self, s)
  self.out.hop("jump", mode)
  return true
end

---------------------------------------------------------------------------
-- Modes (§1.2)
---------------------------------------------------------------------------

--- v: the speed from position this tick (yd/s), nil when estimating (no position).
function M:Mode(s, v)
  if s.taxi then return "taxi" end
  if s.vehicle then return "vehicle" end
  if s.ghost then return "ghost" end
  if s.flying then return "flying" end
  if s.swim then
    if s.form == "aquatic" then return "aquaticform" end
    return s.dive and "dive" or "swim"
  end
  -- the position moves but you don't: a boat, a zeppelin, a lift (TR-1). Out of combat only (speed is secret in it)
  -- The tick you stop on looks the same (the game's speed is already 0, the position still moved since the last
  -- read), so one such tick right after moving belongs to the mode you were in; two in a row are a ride.
  if v and s.speed == 0 and v > 1 and not s.falling then
    local was = self.carriedCand
    self.carriedCand = true
    if not was and self.mode and self.mode ~= "carried" and self.movedT and s.t - self.movedT <= 1.5 then
      return self.mode
    end
    return "carried"
  end
  self.carriedCand = false
  if s.form == "travel" then return "travelform" end
  if s.mounted then return "mounted" end
  -- walk: slower than half the run speed (§0.2 d). Out of combat the game's own speed says it; in a fight only two
  -- slow ticks in a row do, so a start or a stop isn't called a walk
  local cur = s.speed or v
  local slow = cur ~= nil and cur > 0.3 and cur < self.run / 2
  if s.speed then return slow and "walk" or "run" end
  local was = self.slow
  self.slow = slow
  if slow and was then return "walk" end
  return "run"
end

local function maxSpeed(self, mode)
  if mode == "taxi" then return 80 end
  if RIDDEN[mode] then return 40 end
  local run = self.run > M.RUN and self.run or M.RUN
  if FAST[mode] then return run * 2.4 end
  return run * 1.8
end

---------------------------------------------------------------------------
-- Legs and top speed (§1.4)
---------------------------------------------------------------------------

function M:CloseLeg()
  local leg = self.leg
  if not leg then return end
  self.leg = nil
  if leg.yd >= 1 and M.OWN[leg.mode] then self.out.leg(leg.mode, leg.yd, leg.sec, leg.zone) end
end

local function moved(self, mode, d, dt, s)
  local t = s.t
  self.out.move(mode, d, dt, s.zone, false)
  local leg = self.leg
  if leg and leg.mode ~= mode then self:CloseLeg(); leg = nil end
  if not leg then
    leg = { mode = mode, yd = 0, sec = 0, zone = s.zone, wy = 0, ws = 0 }
    self.leg = leg
  end
  leg.yd, leg.sec, leg.last = leg.yd + d, leg.sec + dt, t
  leg.wy, leg.ws = leg.wy + d, leg.ws + dt
  if leg.ws >= M.SPEED_WINDOW then
    if M.OWN[mode] then self.out.speed(mode, leg.wy / leg.ws, s.zone) end
    leg.wy, leg.ws = 0, 0
  end
  if self.flight then self.flight.yd, self.flight.sec = self.flight.yd + d, self.flight.sec + dt end
  if mode == "carried" then self.carriedT = t end
  self.mode, self.movedT = mode, t
end

local function pushSpeed(self, v, t)
  local i = self.ri % 3 + 1
  self.ring[i], self.ri, self.speedT = v, i, t
end

--- The pack's own speed now (§4 "Speed now"): the median of the last three ticks' speeds, 0 after a second still.
--- Computed from position, so it is never secret, in combat too.
function M:SpeedNow(t)
  if not self.speedT or t - self.speedT > 1.5 then return 0 end
  local a, b, c = self.ring[1], self.ring[2], self.ring[3]
  if a > b then a, b = b, a end
  if b > c then b = c end
  return a > b and a or b
end

---------------------------------------------------------------------------
-- Jumps (§1.3): what caused a discontinuity
---------------------------------------------------------------------------

function M:Cause(t)
  if self.spiritT and t - self.spiritT <= M.CAST_WINDOW then self.spiritT = nil; return "spirit" end
  if self.castKind and t - self.castT <= M.CAST_WINDOW then
    local k = self.castKind
    self.castKind = nil
    return k
  end
  if self.summonT and t - self.summonT <= M.SUMMON_WINDOW then self.summonT = nil; return "summon" end
  if self.carriedT and t - self.carriedT <= M.CARRIED_WINDOW then self.carriedT = nil; return "transport" end
  return nil
end

local function jumped(self, mode, yd, zone)
  self:CloseLeg()
  self.mode = nil
  self.out.jump(mode, yd, zone)
end

---------------------------------------------------------------------------
-- Spacebar jumps and falls (§0.2 c): air time from the poll ("≈", 4 times a second)
---------------------------------------------------------------------------

local function air(self, s)
  local t = s.t
  if s.taxi or s.swim then self.airT = nil; return end
  if s.falling then
    if not self.airT then
      local pressed = self.pressT ~= nil and t - self.pressT <= M.PRESS_WINDOW
      self.airT = pressed and self.pressT or t
      self.airKind = pressed and "jump" or "fall"
      self.airMode = airMode(self, s)
      self.airFloat = false
    end
    if s.float then self.airFloat = true end
    return
  end
  if not self.airT then return end
  local sec, kind = t - self.airT, self.airKind
  self.airT = nil
  if kind == "jump" then
    self.out.air("jump", sec, self.airMode)                   -- counted at the press; its air time now
  elseif sec >= M.FALL_MIN then
    kind = self.airFloat and "float" or "fall"
    self.out.hop(kind, self.airMode)
    self.out.air(kind, sec, self.airMode)
  end
end

---------------------------------------------------------------------------
-- One tick
---------------------------------------------------------------------------

--- s: { t, x, y, cont (UnitPosition's 4th value), zone (the engine's zone key), inst (inside an instance), taxi,
--- vehicle, ghost, flying, swim, dive, mounted, form ("travel" | "aquatic" | nil), falling, float (a slow-fall aura,
--- out of combat), speed, run (GetUnitSpeed's current and run speed; nil when secret) }
function M:Step(s)
  local t = s.t
  if s.run and s.run > 0 then self.run = s.run end
  air(self, s)

  -- deaths (§1.6): the release is a spirit jump (the next discontinuity); the corpse run is ghost legs
  if s.ghost and not self.ghost then
    self.spiritT = t
    self:CloseLeg()
  elseif not s.ghost and self.ghost then
    self:CloseLeg()
    local healer = (self.xpLossT and t - self.xpLossT <= M.HEALER_WINDOW) or (self.corpseD and self.corpseD > M.CORPSE_NEAR)
    self.out.death(healer and "healer" or "corpse")
    self.xpLossT, self.corpseD = nil, nil
  end
  self.ghost = s.ghost
  if self.spiritT and t - self.spiritT > M.CAST_WINDOW then
    -- released with no jump seen (the graveyard was in sight): still a release
    self.spiritT = nil
    jumped(self, "spirit", 0, s.zone)
  end

  -- flights: from taking off to landing
  if s.taxi and not self.taxi then self.flight = { yd = 0, sec = 0 }
  elseif not s.taxi and self.taxi and self.flight then
    local f = self.flight
    self.flight = nil
    self.out.flight(f.yd, f.sec)
  end
  self.taxi = s.taxi

  -- into or out of an instance (§0.3): a jump, counted, no yards; inside there is no position
  local inst = s.inst and true or false
  if self.inst ~= nil and inst ~= self.inst then
    jumped(self, self:Cause(t) or "instance", 0, s.zone)
    self.x, self.gap = nil, false
  end
  self.inst = inst

  local lt = self.lt
  self.lt = t

  if not s.x then
    if inst and s.speed and lt and not self.gap then
      -- inside a dungeon: an estimate from the game's speed, out of combat only (§0.3)
      local dt = t - lt
      if dt > 0 and dt <= M.MAX_DT and s.speed > 0 then
        self:CloseLeg()
        local mode = self:Mode(s, nil)
        self.out.move(mode, s.speed * dt, dt, s.zone, true)
        self.mode, self.movedT = mode, t
        pushSpeed(self, s.speed, t)
      end
    elseif not inst then
      self.gap = true                                           -- a nil read outdoors: across a loading screen
    end
    return
  end

  if not self.x then
    self.x, self.y, self.cont, self.at, self.gap = s.x, s.y, s.cont, t, false
    return
  end

  local dx, dy = s.x - self.x, s.y - self.y
  local d = sqrt(dx * dx + dy * dy)
  local same = s.cont == self.cont
  local prevAt = self.at
  local dt = t - prevAt
  local gap = self.gap
  self.x, self.y, self.cont, self.at, self.gap = s.x, s.y, s.cont, t, false

  if gap or not same then
    -- across a loading screen or between continents: a jump when something moved us, else nothing (a /reload)
    local cause = self:Cause(t)
    if not same then
      jumped(self, cause or "jump", 0, s.zone)
    elseif cause or d > M.LONG_JUMP then
      jumped(self, cause or "jump", d, s.zone)
    end
    return
  end
  if dt <= 0 then return end

  if d < 0.1 then
    -- standing: a stop longer than LEG_STOP ends the leg
    local leg = self.leg
    if leg and leg.last and t - leg.last > M.LEG_STOP then self:CloseLeg(); self.mode = nil end
    return
  end

  -- a blink or leap just cast: checked before the mode, since a blink from a standstill looks like a boat (the
  -- game's speed 0 while the position moves)
  if self.blinkT and t - self.blinkT <= M.BLINK_WINDOW and d >= M.SHORT_JUMP and d <= M.LONG_JUMP and not s.taxi then
    self.blinkT = nil
    jumped(self, self.blinkKind, d, s.zone)
    return
  end
  local v = d / dt
  local mode = self:Mode(s, v)
  local limit = maxSpeed(self, mode) * dt * 1.5 + 2
  if d > limit and d > M.LONG_JUMP then
    jumped(self, self:Cause(t) or "jump", d, s.zone)
  elseif d > limit and d >= M.SHORT_JUMP and not RIDDEN[mode] then
    -- no blink or leap cast: a knockback or a correction from the server (TR-5 saw 12 for a paladin). Dropped
    self.noise = (self.noise or 0) + 1
  else
    -- Time moving: the whole tick, except on the tick you start (it may follow a 1 s still read) or stop on, where
    -- only part of it moved: there it is the yards at the speed you were going (the game's, else the last tick's)
    local sec = dt
    local started = self.movedT ~= prevAt
    local rate
    if s.speed == 0 and mode ~= "carried" then rate = self.lastV
    elseif started then rate = (s.speed and s.speed > 0) and s.speed or self.lastV end
    if rate and rate > 0 and d / rate < dt then sec = d / rate end
    self.lastV = (s.speed and s.speed > 0) and s.speed or d / sec
    pushSpeed(self, d / sec, t)
    moved(self, mode, d, sec, s)
  end
end

--- Logout (and /reload): the open leg is closed and written.
function M:Close()
  self:CloseLeg()
end

return M
