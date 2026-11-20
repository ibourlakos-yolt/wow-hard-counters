-- Events and scheduler: one frame for every game event the engine listens to, and the only place polling
-- happens (DESIGN §3.2, PACKS §3 rule 3). Handlers get (event, ...) and are isolated with pcall, so one broken
-- handler can't stop the others. No allocation per event.
local ADDON, ns = ...

local pcall = pcall
local W = ns.wow

local frame = CreateFrame("Frame")
local handlers = {}  -- event -> array of { fn, origin }

local function dispatch(_, event, ...)
  local list = handlers[event]
  if not list then return end
  for i = 1, #list do
    local h = list[i]
    local ok, err = pcall(h[1], event, ...)
    if not ok then ns.Error(err, h[2]) end
  end
end
frame:SetScript("OnEvent", dispatch)

--- Listen to a game event. `origin` tags errors ("HC" or "Pack:<name>").
function ns.On(event, fn, origin)
  local list = handlers[event]
  if not list then
    list = {}
    handlers[event] = list
    frame:RegisterEvent(event)
  end
  list[#list + 1] = { fn, origin or "HC" }
end

--- Stop listening. Builds a new list (copy on write) so a handler can remove itself mid-dispatch.
function ns.Off(event, fn)
  local list = handlers[event]
  if not list then return end
  local new = {}
  for i = 1, #list do if list[i][1] ~= fn then new[#new + 1] = list[i] end end
  if #new == 0 then
    handlers[event] = nil
    frame:UnregisterEvent(event)
  else
    handlers[event] = new
  end
end

--- Fire our own handlers for an event (tests and the logout path use this). Not a game event.
ns.Dispatch = function(event, ...) dispatch(nil, event, ...) end

---------------------------------------------------------------------------
-- Scheduler: repeating jobs on C_Timer tickers, paused during loading screens unless `always`.
---------------------------------------------------------------------------

local jobs = {}
local loading = false
ns.loadingScreen = false

local Job = {}
Job.__index = Job

local function startJob(job)
  if job.ticker then job.ticker:Cancel() end
  job.ticker = W.newTicker(job.interval, job.cb)
end

local function stopJob(job)
  if job.ticker then job.ticker:Cancel(); job.ticker = nil end
end

--- Run fn every `interval` seconds. opts.always: keep running during loading screens. opts.origin: error tag.
function ns.Every(interval, fn, opts)
  local job = setmetatable({ interval = interval, fn = fn, always = opts and opts.always, origin = opts and opts.origin or "HC" }, Job)
  job.cb = function()
    local ok, err = pcall(fn)
    if not ok then ns.Error(err, job.origin) end
  end
  jobs[#jobs + 1] = job
  job.paused = opts and opts.paused or nil
  if not job.paused and (job.always or not loading) then startJob(job) end
  return job
end

function Job:SetInterval(interval)
  if interval == self.interval then return end
  self.interval = interval
  if self.ticker then startJob(self) end
end

--- Stop ticking until Resume (a poll source whose counters are all off).
function Job:Pause()
  self.paused = true
  stopJob(self)
end

function Job:Resume()
  if not self.paused then return end
  self.paused = nil
  if self.always or not loading then startJob(self) end
end

function Job:Cancel()
  stopJob(self)
  self.cancelled = true
  for i = #jobs, 1, -1 do if jobs[i] == self then table.remove(jobs, i) end end
end

function ns.SchedulerStats()
  local running, paused = 0, 0
  for _, j in ipairs(jobs) do if j.ticker then running = running + 1 else paused = paused + 1 end end   -- paused: loading screen or off
  return running, paused
end

ns.On("LOADING_SCREEN_ENABLED", function()
  loading = true
  ns.loadingScreen = true
  for _, j in ipairs(jobs) do if not j.always then stopJob(j) end end
end)

ns.On("LOADING_SCREEN_DISABLED", function()
  loading = false
  ns.loadingScreen = false
  for _, j in ipairs(jobs) do if not j.always and not j.ticker and not j.paused then startJob(j) end end
end)
