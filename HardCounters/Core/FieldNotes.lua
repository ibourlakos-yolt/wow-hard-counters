-- Field notes (0.4.0, the user: "can we automate the automatic probing and other info pulling at certain events for
-- players that have activated diagnostics packs or those who run non rc or fully released versions?").
-- On a pre-release build (a version with -dev, -alpha or -beta) or with Hard Counters: Diagnostics loaded, Hard
-- Counters writes a short note at a few moments of play: a login or reload, entering or leaving an instance, a level
-- gained, a caught error (the first few of a session), a logout. A note is counts and types only: the time, the
-- moment, the version, the zone key and instance type, combat, errors and warnings so far, trackers on and with
-- history, boards made and on the HUD. Never a value, a name or chat text. The newest NOTES_CAP stay in
-- HardCountersDB.field (a ring) and ride along in /hc report, so a tester's report says what happened when, without
-- them pressing anything. Diagnostics listens (the private bridge, D.OnFieldNote) and runs its probes at some of
-- these moments as well. Options, Diagnostics: "Automatic field notes" turns it off (or on, on a release).
local ADDON, ns = ...

local HC, W, Ring = ns.HC, ns.wow, ns.Ring

local NOTES_CAP = 40
local ERRORS_NOTED = 5                  -- caught errors noted per session (a loop of errors would fill the ring)
local F = {}
ns.FieldNotes = F

local store
local listeners = {}
local errorsNoted = 0
local lastInstance

--- The release channel of a version string: "dev", "alpha", "beta", "rc" or "release".
function F.Channel(version)
  local v = tostring(version or HC.VERSION or ""):lower()
  for _, ch in ipairs({ "dev", "alpha", "beta", "rc" }) do
    if v:find("%-" .. ch) then return ch end
  end
  return "release"
end

function F.PreRelease(version)
  local ch = F.Channel(version)
  return ch == "dev" or ch == "alpha" or ch == "beta"
end

local function diagLoaded() return W.addonLoaded and W.addonLoaded("HardCounters_Diagnostics") or false end
F.DiagnosticsLoaded = diagLoaded

--- On by default for a pre-release build or with Diagnostics loaded; the player's choice wins (globalSettings).
function F.Enabled()
  local g = ns.globalSettings
  if g and g.fieldNotes ~= nil then return g.fieldNotes and true or false end
  return F.PreRelease() or diagLoaded()
end

function F.SetEnabled(on)
  if ns.globalSettings then ns.globalSettings.fieldNotes = on and true or false end
end

--- What is noted: counts and types (no values, no names).
local function snapshot(moment, extra)
  local s = ns.health and ns.health.session or {}
  local trk, hist = 0, 0
  for _, t in ipairs(HC:Trackers()) do
    if t.on then trk = trk + 1 end
    if t.on and t.history ~= "off" then hist = hist + 1 end
  end
  local boards, shown = 0, 0
  local BM = ns.BoardModel
  if BM and ns.charSettings then
    local ok, B = pcall(BM.Store)
    if ok and type(B) == "table" and type(B.list) == "table" then
      boards = #B.list
      for _, b in ipairs(B.list) do if b.shown then shown = shown + 1 end end
    end
  end
  local okZ, zone = pcall(W.zone)
  local okI, inst = pcall(W.instanceType)
  local okC, combat = pcall(W.inCombat)
  return {
    t = W.now(), m = moment, v = HC.VERSION,
    z = okZ and zone or nil, i = okI and inst or nil, c = okC and combat or nil,
    e = s.errors or 0, w = s.warnings or 0, trk = trk, hist = hist, b = boards, bs = shown,
    run = HC:GetRun() ~= nil or nil, x = extra,
  }
end

--- Note a moment ("login", "reload", "enter", "leave", "level", "error", "logout"). Returns the note, or nil when
--- field notes are off. extra: a short string or number (an error's first 60 characters, a level).
function F.Note(moment, extra)
  if not (store and F.Enabled()) then return nil end
  local ok, note = pcall(snapshot, moment, extra)
  if not ok then return nil end
  Ring.push(store, note)
  for _, fn in ipairs(listeners) do pcall(fn, moment, note) end
  return note
end

--- The notes, oldest first (for /hc report and the Overview tab).
function F.List(max)
  return store and Ring.list(store, max) or {}
end

function F.Clear() if store then Ring.clear(store) end end

--- Private (the Diagnostics bridge): fn(moment, note) after each note.
function F.Listen(fn) listeners[#listeners + 1] = fn end

ns.OnReady(function()
  local SV = ns.SV
  if type(SV) ~= "table" then return end
  SV.field = Ring.adopt(SV.field, NOTES_CAP)
  store = SV.field
end)

ns.On("PLAYER_ENTERING_WORLD", function(_, isLogin, isReload)
  if not ns.ready then return end
  local okI, inst = pcall(W.instanceType)
  local inside = okI and inst ~= nil and inst ~= "none"
  if isLogin then F.Note("login")
  elseif isReload then F.Note("reload") end
  if inside and lastInstance ~= inst then F.Note("enter", inst)
  elseif not inside and lastInstance and lastInstance ~= "none" then F.Note("leave", lastInstance) end
  lastInstance = inside and inst or "none"
end, "FieldNotes")

ns.On("PLAYER_LEVEL_UP", function(_, level)
  if ns.ready then F.Note("level", type(level) == "number" and level or nil) end
end, "FieldNotes")

ns.On("PLAYER_LOGOUT", function() if ns.ready then F.Note("logout") end end, "FieldNotes")

-- a caught error (ns.Error): the first few of a session, with the start of its message (our own code's text)
local previousError = ns.Error
function ns.Error(err, origin)
  previousError(err, origin)
  if ns.ready and errorsNoted < ERRORS_NOTED then
    errorsNoted = errorsNoted + 1
    F.Note("error", tostring(err):gsub("^.-([^\\/]+%.lua:%d+:)", "%1"):sub(1, 60))
  end
end
