-- RateWindow: an in-memory ring buffer for live rates ("gold per hour over the last 10 minutes"),
-- optionally counting only host-reported active time (DESIGN §8.3). Never saved. Allocation-free
-- after creation.
local lib = LibStub and LibStub("LibGranaryDB-1.0", true)
local M = lib and lib.__M
if not M then return end

local floor = math.floor

local RW = {}
RW.__index = RW
M.RateWindow = RW

--- opts: slots (default 600), slotSeconds (default 1), now (function returning seconds; default os.time/GetTime-like).
function RW.New(_, opts)
  opts = opts or {}
  local slots = opts.slots or 600
  local slotSeconds = opts.slotSeconds or 1
  if type(slots) ~= "number" or slots < 1 or slots > 86400 or slots ~= floor(slots) then
    M.U.misuse(2, "RateWindow: 'slots' must be an integer 1..86400")
  end
  if type(slotSeconds) ~= "number" or slotSeconds <= 0 then M.U.misuse(2, "RateWindow: 'slotSeconds' must be > 0") end
  if opts.now ~= nil and type(opts.now) ~= "function" then M.U.misuse(2, "RateWindow: 'now' must be a function") end
  local self = setmetatable({
    n = slots, w = slotSeconds, vals = {}, act = {}, head = nil, lastT = nil, active = false, created = nil,
    now = opts.now or function() return os and os.time and os.time() or 0 end,
  }, RW)
  for i = 1, slots do self.vals[i] = 0; self.act[i] = 0 end
  return self
end

function RW:_advance(t)
  local w, n = self.w, self.n
  local slot = floor(t / w)
  if not self.head then
    self.head, self.lastT, self.created = slot, t, t
    return
  end
  if t < self.lastT then t = self.lastT; slot = floor(t / w) end
  -- distribute active time from lastT to t across slots
  if self.active then
    local s = self.lastT
    if t - s > n * w then s = t - n * w end -- older time falls out of the ring anyway
    while s < t do
      local sslot = floor(s / w)
      local send = (sslot + 1) * w
      if send > t then send = t end
      if slot - sslot < n then
        local idx = sslot % n + 1
        if sslot > self.head then -- slot not yet cleared: it will be below, so add after clearing
          self:_clear(sslot)
        end
        self.act[idx] = self.act[idx] + (send - s)
      end
      s = send
    end
  end
  if slot > self.head then self:_clear(slot) end
  self.lastT = t
end

function RW:_clear(slot)
  local n = self.n
  local from = self.head + 1
  if slot - from >= n then from = slot - n + 1 end
  for s = from, slot do
    local idx = s % n + 1
    self.vals[idx] = 0
    self.act[idx] = 0
  end
  self.head = slot
end

--- Add a value at time t (default now).
function RW:Add(v, t)
  if type(v) ~= "number" or v ~= v then return false end
  t = t or self.now()
  self:_advance(t)
  local idx = floor(t / self.w) % self.n + 1
  if floor(t / self.w) <= self.head - self.n then return false end
  self.vals[idx] = self.vals[idx] + v
  return true
end

function RW:SetActive(on, t)
  t = t or self.now()
  self:_advance(t)
  self.active = on and true or false
end

--- Rate per second over the last `window` seconds (default: the whole ring).
--- activeOnly: divide by active seconds instead of wall seconds. Returns rate, sum, seconds.
function RW:Rate(window, t, activeOnly)
  t = t or self.now()
  self:_advance(t)
  local w, n = self.w, self.n
  local k = window and floor(window / w + 0.5) or n
  if k < 1 then k = 1 end
  if k > n then k = n end
  local sum, act = 0, 0
  for s = self.head - k + 1, self.head do
    local idx = s % n + 1
    sum = sum + self.vals[idx]
    act = act + self.act[idx]
  end
  local seconds
  if activeOnly then
    seconds = act
  else
    seconds = k * w
    local lived = t - (self.created or t)
    if lived < seconds then seconds = lived end
  end
  if seconds <= 0 then return 0, sum, 0 end
  return sum / seconds, sum, seconds
end
