-- Traveler's movement model on its own (Motion.lua): a fake position stream, what it reports.
local function load()
  local ns = {}
  assert(loadfile("HardCounters_Traveler/Motion.lua"))("HardCounters_Traveler", ns)
  return ns.Motion
end

--- A model with a recording `out`, and a stream helper that walks the player along x.
local function rig()
  local M = load()
  local log = { move = {}, jump = {}, leg = {}, speed = {}, hop = {}, air = {}, death = {}, flight = {} }
  local out = {
    move = function(mode, yd, sec, zone, est) log.move[#log.move + 1] = { mode, yd, sec, zone, est } end,
    jump = function(mode, yd, zone) log.jump[#log.jump + 1] = { mode, yd, zone } end,
    leg = function(mode, yd, sec, zone) log.leg[#log.leg + 1] = { mode, yd, sec, zone } end,
    speed = function(mode, v) log.speed[#log.speed + 1] = { mode, v } end,
    hop = function(kind, mode) log.hop[#log.hop + 1] = { kind, mode } end,
    air = function(kind, sec, mode) log.air[#log.air + 1] = { kind, sec, mode } end,
    death = function(kind) log.death[#log.death + 1] = kind end,
    flight = function(yd, sec) log.flight[#log.flight + 1] = { yd, sec } end,
  }
  local m = M.new(out)
  local w = { t = 100, x = 0, y = 0, cont = 0, zone = 1429, speed = 0, run = 7 }
  --- Step `n` ticks of `dt` seconds, moving `v` yd/s along x; `flags` are set on every tick.
  function w.go(n, dt, v, flags)
    for _ = 1, n do
      w.t = w.t + dt
      w.x = w.x + v * dt
      local s = { t = w.t, x = w.x, y = w.y, cont = w.cont, zone = w.zone, speed = w.speed, run = w.run }
      for k, val in pairs(flags or {}) do s[k] = val end
      if s.speed == "v" then s.speed = v end
      if s.nopos then s.x, s.y, s.cont = nil, nil, nil end
      m:Step(s)
    end
  end
  return m, log, w, M
end

local function sum(list, mode)
  local yd, sec = 0, 0
  for _, e in ipairs(list) do if e[1] == mode then yd, sec = yd + e[2], sec + (e[3] or 0) end end
  return yd, sec
end

describe("Traveler's movement model", function()
  it("books running, walking and mounted stretches by mode, out of combat from the game's speed", function()
    local m, log, w = rig()
    w.go(1, 0.25, 0)                                       -- the first read: an anchor, nothing booked
    w.go(40, 0.25, 7, { speed = "v" })                     -- 10 s running
    w.go(40, 0.25, 2.5, { speed = "v" })                   -- 10 s walking
    w.go(20, 0.5, 14, { speed = "v", mounted = true })     -- 10 s mounted
    local run, runT = sum(log.move, "run")
    local walk, walkT = sum(log.move, "walk")
    local mount = sum(log.move, "mounted")
    assert.is_true(math.abs(run - 70) < 1e-6 and math.abs(runT - 10) < 1e-6)
    assert.is_true(math.abs(walk - 25) < 1e-6 and math.abs(walkT - 10) < 1e-6)
    assert.is_true(math.abs(mount - 140) < 1e-6)
    -- two legs closed by the mode changes; top speed per 2 s window
    assert.are.equal(2, #log.leg)
    assert.are.same("run", log.leg[1][1])
    assert.is_true(math.abs(log.leg[1][2] - 70) < 1e-6)
    assert.is_true(#log.speed >= 10)
    m:Close()
    assert.are.equal(3, #log.leg)
    assert.are.same("mounted", log.leg[3][1])
  end)

  it("in a fight (speed secret) calls a walk only after two slow ticks", function()
    local _, log, w = rig()
    w.go(1, 0.25, 0, { speed = false })
    w.go(1, 0.25, 2.5, { speed = false })                  -- one slow tick: a start, still "run"
    w.go(4, 0.25, 2.5, { speed = false })
    assert.are.same("run", log.move[1][1])
    assert.are.same("walk", log.move[#log.move][1])
  end)

  it("ends a leg after a stop of more than 3 s, and keeps it through a short one", function()
    local _, log, w = rig()
    w.go(1, 0.25, 0)
    w.go(8, 0.25, 7, { speed = "v" })
    w.go(8, 0.25, 0)                                        -- 2 s still: same leg
    w.go(8, 0.25, 7, { speed = "v" })
    assert.are.equal(0, #log.leg)
    w.go(20, 0.25, 0)                                       -- 5 s still: the leg ends
    assert.are.equal(1, #log.leg)
    assert.is_true(math.abs(log.leg[1][2] - 28) < 1e-6)
  end)

  it("names a blink by its spell, drops a jump with no spell, and counts a hearth across a loading screen", function()
    local m, log, w = rig()
    w.go(1, 0.25, 0)
    m:Cast("blink", w.t)
    w.go(1, 0.25, 80)                                       -- 20 yards in one tick, just after Blink
    assert.are.same({ "blink", 20, 1429 }, log.jump[1])
    w.go(1, 0.25, 60, { speed = false })                    -- 15 yards in a fight, no spell: a knockback, dropped
    assert.are.equal(1, #log.jump)
    assert.are.equal(1, m.noise)
    m:Cast("hearth", w.t)
    w.t = w.t + 10
    m:Loading()
    w.x = w.x + 3000
    w.go(1, 0.25, 0)
    assert.are.same("hearth", log.jump[2][1])
    assert.is_true(math.abs(log.jump[2][2] - 3000) < 1e-6)
  end)

  it("counts a continent change as a jump with no yards, and a /reload as nothing", function()
    local m, log, w = rig()
    w.go(1, 0.25, 0)
    m:Loading()
    w.go(1, 0.25, 4)                                        -- back where we were: a reload or a short load
    assert.are.equal(0, #log.jump)
    m:Loading()
    w.cont = 1
    w.go(1, 0.25, 0)
    assert.are.same({ "jump", 0, 1429 }, log.jump[1])
  end)

  it("splits a boat into the ride (carried) and the crossing (transport)", function()
    local m, log, w = rig()
    w.go(1, 1, 0)
    w.go(30, 1, 30, { speed = 0 })                          -- standing on a moving boat
    local ride = sum(log.move, "carried")
    assert.is_true(math.abs(ride - 900) < 1e-6)
    assert.are.equal(0, #log.speed)                         -- no top speed from a boat
    m:Loading()
    w.cont = 1
    w.go(1, 1, 0)
    assert.are.same({ "transport", 0, 1429 }, log.jump[1])
  end)

  it("measures a flight from take-off to landing", function()
    local _, log, w = rig()
    w.go(1, 1, 0)
    w.go(60, 1, 30, { taxi = true })
    w.go(1, 1, 0)
    assert.are.equal(1, #log.flight)
    assert.is_true(math.abs(log.flight[1][1] - 1800) < 1e-6)
    assert.is_true(math.abs(sum(log.move, "taxi") - 1800) < 1e-6)
  end)

  it("estimates distance inside a dungeon out of combat, and counts the doors", function()
    local _, log, w = rig()
    w.go(4, 0.25, 7, { speed = "v" })
    w.zone = 100036
    w.go(1, 0.25, 0, { inst = true, nopos = true })         -- in: a door
    assert.are.same({ "instance", 0, 100036 }, log.jump[1])
    w.go(8, 0.25, 7, { inst = true, nopos = true, speed = "v" })
    w.go(8, 0.25, 7, { inst = true, nopos = true, speed = false })    -- a fight: nothing
    local est = 0
    for _, e in ipairs(log.move) do if e[5] then est = est + e[2] end end
    assert.is_true(math.abs(est - 14) < 1e-6)
    w.zone = 1429
    w.go(1, 0.25, 0)                                        -- out
    assert.are.same("instance", log.jump[2][1])
  end)

  it("counts spacebar jumps at the press, from the ground only, and falls of a second or more", function()
    local m, log, w = rig()
    w.go(1, 0.25, 0)
    assert.is_true(m:Press(w.t, {}))
    w.go(3, 0.25, 0, { falling = true })
    w.go(1, 0.25, 0)
    assert.are.same({ "jump", "run" }, log.hop[1])
    assert.are.equal("jump", log.air[1][1])
    assert.is_false(m:Press(w.t, { falling = true }))       -- pressed again in mid-air: not a jump
    assert.is_false(m:Press(w.t, { swim = true }))
    assert.is_true(m:Press(w.t, { mounted = true }))
    assert.are.same({ "jump", "mounted" }, log.hop[2])
    w.t = w.t + 5
    w.go(2, 0.25, 0, { falling = true })                    -- a step down: 0.5 s, not counted
    w.go(1, 0.25, 0)
    w.go(6, 0.25, 0, { falling = true })                    -- off a ledge: 1.5 s
    w.go(1, 0.25, 0)
    w.go(8, 0.25, 0, { falling = true, float = true })      -- Slow Fall
    w.go(1, 0.25, 0)
    assert.are.same({ "fall", "run" }, log.hop[3])
    assert.are.same({ "float", "run" }, log.hop[4])
    assert.are.equal(4, #log.hop)
  end)

  it("makes a death a spirit jump, ghost distance and a corpse run; at the spirit healer, a healer visit", function()
    local m, log, w = rig()
    w.go(1, 0.25, 0)
    w.go(1, 0.25, 0, { ghost = true })                      -- released
    m:Loading()
    w.x = w.x + 300
    w.go(1, 0.25, 0, { ghost = true })
    assert.are.same({ "spirit", 300, 1429 }, log.jump[1])
    w.go(40, 0.25, 7, { ghost = true, speed = "v" })
    m:Corpse(5)
    w.go(1, 0.25, 0)                                        -- alive at the corpse
    assert.are.same({ "corpse" }, log.death)
    assert.is_true(math.abs(sum(log.move, "ghost") - 70) < 1e-6)
    assert.are.same("ghost", log.leg[1][1])
    w.go(1, 0.25, 0, { ghost = true })
    m:Loading()
    w.x = w.x + 300
    w.go(1, 0.25, 0, { ghost = true })
    m:XPLoss(w.t)
    w.go(1, 0.25, 0)
    assert.are.same({ "corpse", "healer" }, log.death)
  end)

  it("books the tick you stop on (speed already 0, position still moved) to the mode you were in, not a boat", function()
    local _, log, w = rig()
    w.go(1, 0.25, 0)
    w.go(8, 0.25, 7, { speed = "v" })
    w.go(1, 0.25, 4, { speed = 0 })                         -- stopping: part of the tick still moved
    w.go(4, 0.25, 0)
    assert.are.equal(0, sum(log.move, "carried"))
    assert.is_true(math.abs(sum(log.move, "run") - 15) < 1e-6)
  end)

  it("gives Speed now from position, and 0 once still", function()
    local m, _, w = rig()
    w.go(1, 0.25, 0)
    w.go(4, 0.25, 7, { speed = false })
    assert.is_true(math.abs(m:SpeedNow(w.t) - 7) < 1e-6)
    assert.are.equal(0, m:SpeedNow(w.t + 2))
  end)
end)
