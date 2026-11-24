-- WoW: the engine's adapter over game globals. Engine files call ns.wow.* instead of game functions, so
-- busted can swap this table for fakes. UI files (UI/*) use frame APIs directly.
local ADDON, ns = ...

local W = {}
ns.wow = W

W.now = GetServerTime                 -- UTC epoch seconds: every stored timestamp uses this
W.time = GetTime                      -- monotonic seconds (float), for durations
W.ms = debugprofilestop
W.date = date
W.after = C_Timer.After
W.newTicker = C_Timer.NewTicker
W.locale = GetLocale
W.granaryAdapters = nil               -- nil in game: LibGranaryDB uses its own WoW adapters

local issecret = issecretvalue
function W.isSecret(v)
  if issecret then return issecret(v) and true or false end
  return false
end

function W.errorHandler()
  return geterrorhandler()
end

function W.playerGUID() return UnitGUID("player") end

--- Post-hook a global function (secure hooks only: they never taint the original).
function W.hook(name, fn) hooksecurefunc(name, fn) end

function W.entityInfo()
  local _, class = UnitClass("player")
  return { name = UnitName("player"), realm = GetRealmName(), class = class, faction = UnitFactionGroup("player") }
end

--- The character's class file name ("MAGE"), or nil (HC-57: the New board dialog lists your class board first).
function W.playerClass()
  local ok, _, class = pcall(UnitClass, "player")
  if not ok or W.isSecret(class) or type(class) ~= "string" then return nil end
  return class
end

--- version, build number, interface number
function W.build()
  local version, build, _, interface = GetBuildInfo()
  return version, build, interface
end

--- "US" or "EU": LibGranaryDB's fallback weekly-reset anchor (in game it reads C_DateAndTime first).
function W.region()
  local r = GetCurrentRegion and GetCurrentRegion()
  return r == 1 and "US" or "EU"
end

--- true/false, or nil when the game returns a secret boolean (Accountant Classic crashed on exactly this).
function W.isAFK()
  local v = UnitIsAFK("player")
  if W.isSecret(v) then return nil end
  return v and true or false
end

--- Instance zone keys (HC-13, decided by the user 2026-11-15): inside an instance the map API gives nothing
--- (run 3: nil in The Deadmines and Shadowfang Keep), so the key is INSTANCE_BASE + GetInstanceInfo()'s instance
--- ID (Deadmines 36 -> 100036). Instance IDs overlap map IDs, hence the offset; numbers keep keys language-free.
--- Names for display are remembered while inside (HardCountersDB.instanceNames[instanceID]).
local INSTANCE_BASE = 100000
W.INSTANCE_BASE = INSTANCE_BASE
--- The zone key where neither the instance nor the map API answers (no map has ID 0).
local ZONE_UNKNOWN = 0
W.ZONE_UNKNOWN = ZONE_UNKNOWN

local function instanceKey()
  local inInstance, kind = IsInInstance()
  if W.isSecret(inInstance) or W.isSecret(kind) or not inInstance or kind == "none" then return nil end
  local name, _, _, _, _, _, _, instanceID = GetInstanceInfo()
  if W.isSecret(instanceID) or type(instanceID) ~= "number" or instanceID <= 0 then return nil end
  if type(name) == "string" and name ~= "" and not W.isSecret(name) and ns.SV then
    ns.SV.instanceNames = type(ns.SV.instanceNames) == "table" and ns.SV.instanceNames or {}
    ns.SV.instanceNames[instanceID] = name
  end
  return INSTANCE_BASE + instanceID
end

--- The player's zone key, always a number (HC-25): inside an instance its instance key (above); otherwise the best
--- map, climbed out of micro-dungeons and orphan maps so caves count toward their zone; ZONE_UNKNOWN (0) where
--- neither is known (never the zone text: keys stay language-free and one type).
local MICRO, ORPHAN = 5, 6
if Enum and Enum.UIMapType then MICRO, ORPHAN = Enum.UIMapType.Micro or 5, Enum.UIMapType.Orphan or 6 end
function W.zone()
  local ik = instanceKey()
  if ik then return ik end
  local id = C_Map.GetBestMapForUnit("player")
  if W.isSecret(id) then id = nil end
  local guard = 0
  while id and guard < 8 do
    local info = C_Map.GetMapInfo(id)
    if not info or (info.mapType ~= MICRO and info.mapType ~= ORPHAN) or not info.parentMapID or info.parentMapID == 0 then
      break
    end
    id, guard = info.parentMapID, guard + 1
  end
  if type(id) == "number" then return id end
  return ZONE_UNKNOWN
end

function W.mapName(id)
  if type(id) ~= "number" then return id end
  if id == ZONE_UNKNOWN then return ns.L and ns.L["Unknown zone"] or "Unknown zone" end
  if id > INSTANCE_BASE then
    local names = ns.SV and ns.SV.instanceNames
    local iid = id - INSTANCE_BASE
    return names and names[iid] or ("Instance " .. iid)
  end
  local info = C_Map.GetMapInfo(id)
  return info and info.name or tostring(id)
end

function W.instanceType()
  local inInstance, kind = IsInInstance()
  return inInstance and kind or "none"
end

function W.inCombat() return InCombatLockdown() and true or false end

---------------------------------------------------------------------------
-- Pickers for readings with a parameter (DESIGN §16.4, HC-34). Probed on Forever 2026-11-18 (api-surface):
-- GetCursorInfo() gives "item", id, link for a held item; C_Reputation lists factions by index.
---------------------------------------------------------------------------

--- The item id the cursor carries (picked up from a bag), or nil.
function W.cursorItem()
  if not GetCursorInfo then return nil end
  local kind, id = GetCursorInfo()
  if W.isSecret(kind) or W.isSecret(id) then return nil end
  if kind == "item" and type(id) == "number" then return id end
  return nil
end

--- The item id for a typed item name, or nil. The game answers only for items it has seen (cached); unverified on
--- Forever (HC-47).
function W.itemIdByName(name)
  local get = C_Item and C_Item.GetItemInfoInstant
  if not (get and type(name) == "string" and name ~= "") then return nil end
  local ok, id = pcall(get, name)
  if not ok or W.isSecret(id) or type(id) ~= "number" or id <= 0 then return nil end
  return id
end

--- Put what the cursor carries back where it came from.
function W.clearCursor()
  if ClearCursor then ClearCursor() end
end

--- The factions the reputation panel lists, in its order: { { id = factionID, name = text, group = header name or
--- nil }, ... }. Factions under a collapsed header aren't listed by the game (expanding it would change the
--- player's panel: we don't). Empty when the client has no such API.
function W.factions()
  local out = {}
  local R = C_Reputation
  if not (R and R.GetNumFactions and R.GetFactionDataByIndex) then return out end
  local n = R.GetNumFactions()
  if W.isSecret(n) or type(n) ~= "number" then return out end
  local group
  for i = 1, n do
    local ok, d = pcall(R.GetFactionDataByIndex, i)
    if ok and type(d) == "table" and not W.isSecret(d.name) and type(d.name) == "string" and d.name ~= "" then
      local header = d.isHeader and not W.isSecret(d.isHeader)
      if header then group = d.name end
      local id = d.factionID
      if (not header or d.isHeaderWithRep) and not W.isSecret(id) and type(id) == "number" and id > 0 then
        out[#out + 1] = { id = id, name = d.name, group = group }
      end
    end
  end
  return out
end

--- (HC-71) The character's skill lines, in the skill panel's order: { { id = skillLineID, name, group = header name
--- or nil }, ... }. From C_SkillInfo's visible list (GetNumSkillLines / GetSkillLineInfo, as Character Stats reads
--- them): lines under a header the player collapsed aren't listed (expanding it would change the player's panel).
--- Empty when the client has no such API. Unprobed as a list on Forever (Character Stats reads lines by id).
function W.skillLines()
  local out = {}
  local S = C_SkillInfo
  if not (type(S) == "table" and type(S.GetNumSkillLines) == "function" and type(S.GetSkillLineInfo) == "function") then
    return out
  end
  local ok, n = pcall(S.GetNumSkillLines)
  if not ok or W.isSecret(n) or type(n) ~= "number" then return out end
  local group
  for i = 1, n do
    local okLine, d = pcall(S.GetSkillLineInfo, i)
    if okLine and type(d) == "table" and not W.isSecret(d.name) and type(d.name) == "string" and d.name ~= "" then
      local header = d.isHeader and not W.isSecret(d.isHeader)
      if header then
        group = d.name
      elseif not W.isSecret(d.skillID) and type(d.skillID) == "number" and d.skillID > 0 then
        out[#out + 1] = { id = d.skillID, name = d.name, group = group }
      end
    end
  end
  return out
end

--- A skill line's name by id (by id where the client offers it, else from the visible list), or nil.
function W.skillName(id)
  local S = C_SkillInfo
  if type(id) ~= "number" or type(S) ~= "table" then return nil end
  if type(S.GetSkillLineInfoByID) == "function" then
    local ok, d = pcall(S.GetSkillLineInfoByID, id)
    if ok and type(d) == "table" and not W.isSecret(d.name) and type(d.name) == "string" and d.name ~= "" then return d.name end
  end
  for _, line in ipairs(W.skillLines()) do if line.id == id then return line.name end end
  return nil
end

--- Installed addons (names and loaded state), only for the opt-in part of /hc report.
function W.addonList()
  local out = {}
  local n = C_AddOns.GetNumAddOns()
  for i = 1, n do
    local name = C_AddOns.GetAddOnInfo(i)
    if name and C_AddOns.IsAddOnLoaded(i) then out[#out + 1] = name end
  end
  return out
end

--- Encode a table for /hc report: CBOR, then raw Deflate, then Base64 (as LibGranaryDB exports, verified in game).
function W.encodeReport(t)
  local cbor = C_EncodingUtil.SerializeCBOR(t)
  local z = C_EncodingUtil.CompressString(cbor, Enum.CompressionMethod.Deflate)
  return C_EncodingUtil.EncodeBase64(z), cbor
end
