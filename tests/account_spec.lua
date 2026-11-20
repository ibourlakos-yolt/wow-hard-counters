-- Character or account, per tile (HC-32, DESIGN §16.5): tile.who = "account" counts every character of the account.
local Env = require("env")

local MAIN, ALT = "Player-1-00000001", "Player-1-00000002"

local function setup(env, history)
  local HC = env.HC
  HC:RegisterPack("Test", { namespace = "t" })
  HC:RegisterCounter({ id = "t:gold", version = 1, measures = { "sum", "count" },
    dimensions = { { name = "source", cap = 8 } }, aggregations = { {}, { "source" } } })
  HC:RegisterCounter({ id = "t:items", version = 1, measures = { "sum", "count" },
    dimensions = { { name = "item", cap = 4096 } }, aggregations = { {}, { "item" } } })
  HC:RegisterCounter({ id = "t:owned", version = 1, kind = "stock", measures = { "last" } })
  Env.trackAll(env, "t:all", { "t:gold", "t:items", "t:owned", "hc:time.active" }, history or "off")
  local ALL = { "run", "session", "today", "lifetime" }
  HC:RegisterReading("t:gold", { title = "Gold", tracker = "t:all", counter = "t:gold", scopes = ALL })
  HC:RegisterReading("t:goldph", { title = "Gold/h", tracker = "t:all", counter = "t:gold", per = "activeHour", scopes = ALL })
  HC:RegisterReading("t:from", { title = "Gold from %s", tracker = "t:all", counter = "t:gold", param = { dim = "source" }, scopes = ALL })
  HC:RegisterReading("t:looted", { title = "%s looted", tracker = "t:all", counter = "t:items", param = { dim = "item", type = "item" }, scopes = ALL })
  HC:RegisterReading("t:owned", { title = "Owned", tracker = "t:all", counter = "t:owned", scopes = { "now" } })
end

local function start(env, history)
  env:load()
  setup(env, history)
  env:fire("ADDON_LOADED", "HardCounters")
  env.sv.HardCountersDB = _G.HardCountersDB
  env:fire("PLAYER_ENTERING_WORLD", true, false)
  local ns = env.ns
  ns.AddSlash = function() end
  ns.AddOptions = function() end
  for _, f in ipairs({ "UI/Widgets.lua", "UI/BoardModel.lua" }) do
    assert(loadfile(Env.ROOT .. "/" .. f))("HardCounters", ns)
  end
  env.M = ns.BoardModel
  env.history = history
  return env
end

local function boot(history) return start(Env.new({ guid = MAIN }), history) end

--- Log out and log in as `guid`, some time later.
local function login(env, guid, offline)
  env:fire("PLAYER_LOGOUT")
  local sv = { HardCountersDB = Env.svCopy(env.sv.HardCountersDB) }
  local r = Env.new({ t = env.t + (offline or 60), guid = guid, sv = sv, settings = Env.svCopy(env.ns.settings) })
  r.zone = env.zone
  return start(r, env.history)
end

local function tiles(env) return env.M.Store().list[#env.M.Store().list].tiles end

describe("a tile for the whole account", function()
  it("gives the board a second window every character counts into, next to the character's (DESIGN §16.8, a)", function()
    local env = boot()
    local M, HC = env.M, env.HC
    local b = M.Create(nil, { name = "Mine" })
    local own = M.AddReading(b, "t:gold")
    local all = M.AddReading(b, "t:gold")
    for k in pairs(env.sv.HardCountersDB.windows) do assert.is_nil(tostring(k):match("@account$")) end   -- not yet
    assert.is_true(M.SetWho(all, "account"))
    assert.is_false(M.SetWho(all, "account"))
    assert.truthy(env.sv.HardCountersDB.windows["b" .. b.wid .. "@account"])
    HC:Emit("t:gold", 40, "loot")
    env:advance(100)
    assert.are.equal(40, (M.TileValue(own, b)))
    assert.are.equal(40, (M.TileValue(all, b)))
    assert.are.equal("Gold \194\183 account", M.TileLabel(all, b))
    assert.are.equal("Gold", M.TileLabel(own, b))
    -- both windows start, pause and reset together
    M.ControlAll(b, "pause")
    assert.are.equal("paused", M.BoardWindow(b, true).state)
    M.ControlAll(b, "start")

    local alt = login(env, ALT, 3600)
    local ab = alt.M.Store().list[#alt.M.Store().list]
    local t = ab.tiles
    assert.are.equal(0, (alt.M.TileValue(t[1], ab)))           -- the alt's own window starts at 0
    assert.are.equal(40, (alt.M.TileValue(t[2], ab)))          -- the account's carries the main's 40
    alt.HC:Emit("t:gold", 7, "loot")
    alt:advance(50)
    assert.are.equal(7, (alt.M.TileValue(t[1], ab)))
    assert.are.equal(47, (alt.M.TileValue(t[2], ab)))
    local w = alt.M.TileWindow(t[2], ab)
    assert.is_true(w.account)
    assert.are.equal(150, alt.ns.Win.Elapsed(w))               -- both sessions, not the hour offline
    assert.are.equal(150, alt.ns.Win.Active(w))
    assert.are.equal(50, (select(2, alt.M.BoardState(ab))))    -- the clock is the character's window

    local main = login(alt, MAIN, 600)
    t = tiles(main)
    main.HC:Emit("t:gold", 3, "vendor")
    assert.are.equal(43, (main.M.TileValue(t[1])))             -- the main's own: 40 + 3
    assert.are.equal(50, (main.M.TileValue(t[2])))             -- everyone: 40 + 7 + 3
    -- back to "this character": the board's own window, the same period as the other tile
    assert.is_true(main.M.SetWho(t[2], nil))
    assert.are.equal(43, (main.M.TileValue(t[2])))
  end)

  it("with an argument, counts that member on every character (a big dimension is watched on each)", function()
    local env = boot()
    local M = env.M
    local b = M.Create(nil, { name = "Loot" })
    local t = M.AddReading(b, "t:looted", nil, nil, 14047)
    M.SetWho(t, "account")
    env.HC:Emit("t:items", 2, 14047)
    local alt = login(env, ALT)
    local ta = tiles(alt)[1]
    assert.are.equal(2, (alt.M.TileValue(ta)))
    alt.HC:Emit("t:items", 5, 14047)
    alt.HC:Emit("t:items", 9, 2589)
    assert.are.equal(7, (alt.M.TileValue(ta)))
    -- the account window kept the item on the alt before its base there: exact, no "since"
    assert.are.equal("14047 looted \194\183 account", alt.M.TileLabel(ta))
  end)

  it("asks storage for every character in the periods, and sums what each last had for 'now'", function()
    local env = boot("detailed")
    local HC = env.HC
    HC:Emit("t:gold", 25, "loot")
    HC:Observe("t:owned", 7000)
    env:advance(600)
    local alt = login(env, ALT)
    HC = alt.HC
    assert.is_nil((HC:Reading("t:owned", "now")))              -- this character: never observed
    assert.are.equal(7000, (HC:Reading("t:owned", "now", nil, "account")))
    HC:Emit("t:gold", 10, "loot")
    HC:Emit("t:gold", 4, "vendor")
    HC:Observe("t:owned", 300)
    alt:advance(1200)
    assert.are.equal(14, (HC:Reading("t:gold", "today")))
    assert.are.equal(39, (HC:Reading("t:gold", "today", nil, "account")))
    assert.are.equal(35, (HC:Reading("t:from", "lifetime", "loot", "account")))
    assert.are.equal(10, (HC:Reading("t:from", "lifetime", "loot")))
    assert.are.equal(300, (HC:Reading("t:owned", "now")))
    assert.are.equal(7300, (HC:Reading("t:owned", "now", nil, "account")))
    -- per hour over the account: everyone's gold over everyone's active time
    assert.are.equal(39 * 3600 / 1800, (HC:Reading("t:goldph", "today", nil, "account")))
    -- a tile says which it is
    local M = alt.M
    local t = M.AddReading(M.Create(nil, { name = "B" }), "t:gold", nil, "today")
    M.SetWho(t, "account")
    assert.are.equal(39, (M.TileValue(t)))
    assert.are.equal("Gold \194\183 today, account", M.TileLabel(t))
    for k in pairs(alt.sv.HardCountersDB.windows) do assert.is_nil(tostring(k):match("@account$")) end   -- no timer tile
    -- the login scope and the open run are whoever is playing: the same either way
    assert.are.equal(14, (HC:Reading("t:gold", "session", nil, "account")))
  end)
end)

describe("money between your own characters (FM-16)", function()
  it("knows this account's characters by name, this realm or another", function()
    local env = boot()
    local HC = env.HC
    assert.are.same({ name = "Tester", realm = "Test" }, env.sv.HardCountersDB.chars[MAIN])
    env.sv.HardCountersDB.chars[ALT] = { name = "Alty", realm = "Argent Dawn" }
    assert.is_true(HC:IsOwnCharacter("Tester"))
    assert.is_true(HC:IsOwnCharacter("Tester-Test"))
    assert.is_true(HC:IsOwnCharacter("Alty-ArgentDawn"))     -- mail and chat drop the realm's spaces
    assert.is_false(HC:IsOwnCharacter("Alty"))               -- no realm: this one, where there is no Alty
    assert.is_false(HC:IsOwnCharacter("Stranger"))
    assert.is_false(HC:IsOwnCharacter(nil))
  end)

  it("account-wide sums leave out the members a pack names; a character's own don't", function()
    local env = boot("daily")
    local M, HC = env.M, env.HC
    HC:ExcludeOnAccount("t:gold", "source", "alts")
    HC:ExcludeOnAccount("t:gold", "source", "alts")          -- once is enough
    assert.has_error(function() HC:ExcludeOnAccount("t:gold") end)
    local b = M.Create(nil, { name = "Gold" })
    local own = M.AddReading(b, "t:gold")
    local all = M.AddReading(b, "t:gold")
    M.SetWho(all, "account")
    local fromAlts = M.AddReading(b, "t:from", nil, nil, "alts")
    M.SetWho(fromAlts, "account")
    HC:Emit("t:gold", 100, "loot")
    HC:Emit("t:gold", 500, "alts")
    env:advance(60)
    assert.are.equal(600, (M.TileValue(own, b)))             -- per character it still counts (2026-11-15)
    assert.are.equal(100, (M.TileValue(all, b)))
    assert.are.equal(0, (M.TileValue(fromAlts, b)))
    assert.are.equal(600, (HC:Reading("t:gold", "session")))
    assert.are.equal(100, (HC:Reading("t:gold", "session", nil, "account")))
    assert.are.equal(600, (HC:Reading("t:gold", "today")))
    assert.are.equal(100, (HC:Reading("t:gold", "today", nil, "account")))
    assert.are.equal(500, (HC:Reading("t:from", "today", "alts")))
    assert.are.equal(0, (HC:Reading("t:from", "today", "alts", "account")))
  end)
end)
