-- The real WoW adapter (Core/WoW.lua) with stubbed game globals: zone keys (HC-13).
local function load(game)
  local saved = {}
  local globals = {
    C_Timer = { After = function() end, NewTicker = function() end },
    issecretvalue = function() return false end,
    Enum = { UIMapType = { Micro = 5, Orphan = 6 } },
    C_Map = {
      GetBestMapForUnit = function() return game.map end,
      GetMapInfo = function(id) return game.maps and game.maps[id] or { mapType = 3, name = "Map " .. id } end,
    },
    IsInInstance = function() return game.instance ~= nil, game.instance or "none" end,
    GetInstanceInfo = function()
      if not game.instance then return "Eastern Kingdoms", "none", 0, "", 0, 0, false, 0 end
      return game.name, game.instance, 1, "Normal", 5, 0, false, game.id
    end,
  }
  for k, v in pairs(globals) do saved[k] = rawget(_G, k); rawset(_G, k, v) end
  local ns = { SV = {} }
  assert(loadfile("HardCounters/Core/WoW.lua"))("HardCounters", ns)
  for k in pairs(globals) do rawset(_G, k, saved[k]) end
  -- the adapter reads globals at call time for these; keep the stubs reachable through upvalues by re-setting
  return ns, globals
end

describe("zone keys (HC-13, HC-25)", function()
  it("key instances by 100000 + their instance ID, remember their names, and keep map IDs outdoors", function()
    local game = { map = 1453 }
    local ns, globals = load(game)
    for k, v in pairs(globals) do rawset(_G, k, v) end
    local W = ns.wow
    assert.are.equal(1453, W.zone())
    game.map, game.instance, game.id, game.name = nil, "party", 36, "Deadmines"
    assert.are.equal(100036, W.zone())
    assert.are.equal("Deadmines", W.mapName(100036))
    assert.are.equal("Instance 33", W.mapName(100033))
    assert.are.equal(36 + W.INSTANCE_BASE, W.zone())
    game.map = 291                                     -- even when the map API answers inside, the instance key wins
    assert.are.equal(100036, W.zone())
    game.instance, game.map = nil, nil
    assert.are.equal(0, W.zone())                      -- neither known: 0, never the zone text (HC-25)
    assert.are.equal(W.ZONE_UNKNOWN, W.zone())
    assert.are.equal("Unknown zone", W.mapName(0))
    assert.are.equal("Map 1453", W.mapName(1453))
    for k in pairs(globals) do rawset(_G, k, nil) end
  end)
end)
