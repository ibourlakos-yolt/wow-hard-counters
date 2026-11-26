-- Engine: attach LibGranaryDB at ADDON_LOADED, track "this login", run init hooks, flush at logout.
-- Hard Counters owns ONE LibGranaryDB root (DESIGN §4): HardCountersDB.__granary. Its own saved data sits next to
-- it under other keys (health, runs, login, odo, windows), which the library never touches.
local ADDON, ns = ...

local W, HC = ns.wow, ns.HC
local GDB = LibStub("LibGranaryDB-1.0")
ns.GDB = GDB
ns.ready = false

local readyFns = {}

--- Run fn once storage is attached (immediately if it already is).
function ns.OnReady(fn)
  if ns.ready then
    local ok, err = pcall(fn)
    if not ok then ns.Error(err) end
  else
    readyFns[#readyFns + 1] = fn
  end
end

local flushers = {}
--- Register a function that writes in-memory accumulators to storage (before run snapshots and at logout).
function ns.AddFlusher(fn) flushers[#flushers + 1] = fn end
function ns.FlushAll()
  for i = 1, #flushers do
    local ok, err = pcall(flushers[i])
    if not ok then ns.Error(err) end
  end
end

-- The logged-in character's odometers (Odometer.lua, DESIGN §16.2): one running total per counter, saved, written
-- by the emit path (Registry.lua). Bound to HardCountersDB.odo[character] once storage is attached; until then
-- nothing counts. The "session" scope is a window over them.
ns.odo = {}

local LOG_LEVEL = { error = "error", warn = "warn", info = "info", debug = "debug" }

local function attach()
  if type(HardCountersDB) ~= "table" then HardCountersDB = {} end
  local SV = HardCountersDB
  ns.SV = SV
  SV.health = type(SV.health) == "table" and SV.health or {}
  ns.AdoptHealth(SV.health)
  if ns.InitSettings then ns.InitSettings() end     -- UI/Options.lua (AceDB); tests set ns.settings directly
  ns.settings = ns.settings or {}

  local adapters = {}
  if W.granaryAdapters then for k, v in pairs(W.granaryAdapters) do adapters[k] = v end end
  adapters.logger = { log = function(level, msg) ns.Log(LOG_LEVEL[level] or "info", "LibGranaryDB", "%s", msg) end }
  -- (0.4.0) when the day ends: the player's hour (Options, History; 0 = midnight local time). Read here only, so a
  -- change takes effect at the next load; days already kept keep the boundary they were counted with.
  local dsh = tonumber(ns.globalSettings and ns.globalSettings.dayStartHour) or 0      -- (the account's: storage is)
  if dsh < 0 or dsh > 23 or dsh ~= math.floor(dsh) then dsh = 0 end
  local db = GDB:Attach(SV, { host = ADDON, region = W.region(), adapters = adapters, dayStartHour = dsh })
  ns.db = db
  local ro, why = db:IsReadOnly()
  if ro then ns.Log("warn", "HC", "storage is read-only: %s", tostring(why)) end
  ns.guid = W.playerGUID()
  -- (HC-74) has this character loaded Hard Counters before? Read before this login adds it to the list: a new
  -- character gets the starter board and no copy of 0.2's shared boards (UI/BoardModel.lua)
  ns.knownCharacter = type(SV.chars) == "table" and type(SV.chars[ns.guid]) == "table"
  db:SetEntity(ns.guid, W.entityInfo())
  ns.BindOdometers()

  db:RegisterCallback("OnNewExtreme", function(_, counterId, measure, value, ctx, previous)
    ns.Fire("HC_NEW_RECORD", counterId, measure, value, ctx and ns.U.fixCtx(ns.U.copy(ctx)), previous)
  end)
  db:RegisterCallback("OnBudget", function(_, counterId, action, detail)
    ns.Count("budgetActions")
    ns.Log("warn", "LibGranaryDB", "budget step on %s: %s %s", tostring(counterId), tostring(action), tostring(detail or ""))
  end)
  db:RegisterCallback("OnSecretRejected", function() ns.Count("libSecretRejected") end)
  db:RegisterCallback("OnBucketClosed", function(_, counterId, grain, key)
    ns.Fire("HC_PERIOD_CLOSED", counterId, grain, key)
  end)

  ns.Every(5, function() db:Tick() end)
  ns.ready = true
  for i = 1, #readyFns do
    local ok, err = pcall(readyFns[i])
    if not ok then ns.Error(err) end
  end
  readyFns = {}
end

local function onLoaded(event, name)
  if name ~= ADDON then return end
  ns.Off(event, onLoaded)
  attach()
end
ns.On("ADDON_LOADED", onLoaded)

---------------------------------------------------------------------------
-- "This login": from the real login to logout; a /reload carries on (decided 2026-11-14).
---------------------------------------------------------------------------

ns.On("PLAYER_ENTERING_WORLD", function(_, isInitialLogin)
  if not ns.SV then return end
  local L = ns.SV.login
  if isInitialLogin or type(L) ~= "table" or L.char ~= ns.guid then
    ns.SV.login = { t = W.now(), char = ns.guid }
    ns.isInitialLogin = true
  else
    ns.isInitialLogin = false
  end
  -- the "session" scope is a window over the odometers; L.mem is what builds before HC-29 kept (carried over once)
  ns.OnSession(ns.isInitialLogin, type(L) == "table" and L.mem or nil)
  ns.SV.login.mem = nil
  if ns.OnLoginState then ns.OnLoginState(ns.isInitialLogin) end
end)

---------------------------------------------------------------------------
-- Your characters (FM-16): name and realm per character key, written at every load, so a pack can tell your own
-- characters apart (mail between them). Nothing else is kept about them.
---------------------------------------------------------------------------

local function rememberCharacter()
  local ok, info = pcall(W.entityInfo)
  if not (ok and type(info) == "table" and type(info.name) == "string" and ns.guid) then return end
  ns.SV.chars = type(ns.SV.chars) == "table" and ns.SV.chars or {}
  local c = ns.SV.chars[ns.guid]
  if type(c) ~= "table" then c = {}; ns.SV.chars[ns.guid] = c end
  c.name, c.realm = info.name, type(info.realm) == "string" and info.realm or nil
end
ns.On("PLAYER_ENTERING_WORLD", function() if ns.SV then rememberCharacter() end end)

local function squash(realm) return (tostring(realm):gsub("[%s%-']", "")) end

--- Is `name` one of this account's characters that loaded Hard Counters? "Name" means this realm; "Name-Realm"
--- (the form mail and chat use across realms, spaces dropped) names the realm.
function HC:IsOwnCharacter(name)
  if type(name) ~= "string" or name == "" then return false end
  local base, realm = name:match("^([^%-]+)%-(.+)$")
  base = base or name
  if not realm then
    local ok, info = pcall(W.entityInfo)
    realm = ok and type(info) == "table" and info.realm or nil
  end
  for _, c in pairs(ns.SV and ns.SV.chars or {}) do
    if type(c) == "table" and c.name == base and (realm == nil or c.realm == nil or squash(c.realm) == squash(realm)) then
      return true
    end
  end
  return false
end

--- Epoch seconds (UTC) when "this login" began.
function HC:LoginStart()
  return ns.SV and ns.SV.login and ns.SV.login.t or nil
end

ns.On("PLAYER_LOGOUT", function()
  if not ns.ready then return end
  ns.FlushAll()   -- cheap: a few writes of in-memory seconds; nothing heavy at logout
end)
