-- Probes: check the WoW APIs, events and strings Hard Counters and Farmer depend on, with context (instance type,
-- combat). Results go to HardCountersDiagDB.probes; after /reload they are read from the SavedVariables file and
-- turned into verdicts in HardCounters/docs/api-surface.md (DESIGN §8.5).
-- Privacy: counts, types and secretness only. No chat text, no amounts of money, no coordinates, no names.
local ADDON, ns = ...

local B = ns.B
if not B then return end

local format, type, tostring, pcall, select = string.format, type, tostring, pcall, select
local W = B.Wow

local function P() return HardCountersDiagDB.probes end

local function describe(v)
  if W.isSecret(v) then return "secret" end
  if v == nil then return "nil" end
  return type(v)
end

local function exists(v) return v ~= nil and "ok" or "missing", describe(v) end

local function call(fn, ...)
  if type(fn) ~= "function" then return "missing", "not a function" end
  local r = { pcall(fn, ...) }
  if not r[1] then return "error", tostring(r[2]):sub(1, 120) end
  local parts = {}
  for i = 2, math.min(#r, 12) do parts[#parts + 1] = describe(r[i]) end
  return "ok", table.concat(parts, ",")
end

local function G(path)
  local v = _G
  for part in path:gmatch("[^%.]+") do
    if type(v) ~= "table" then return nil end
    v = v[part]
  end
  return v
end

-- Global strings the chat parsers are built from (client strings, not personal data): their values are stored.
local STRINGS = {
  "LOOT_ITEM_SELF", "LOOT_ITEM_SELF_MULTIPLE", "LOOT_ITEM_PUSHED_SELF", "LOOT_ITEM_PUSHED_SELF_MULTIPLE",
  "LOOT_ITEM_CREATED_SELF", "LOOT_ITEM_CREATED_SELF_MULTIPLE", "LOOT_ITEM", "LOOT_ITEM_MULTIPLE",
  "YOU_LOOT_MONEY", "LOOT_MONEY_SPLIT", "LOOT_MONEY_SPLIT_GUILD", "YOU_LOOT_MONEY_GUILD",
  "COMBATLOG_XPGAIN_FIRSTPERSON", "COMBATLOG_XPGAIN_FIRSTPERSON_UNNAMED", "COMBATLOG_XPGAIN_EXHAUSTION1",
  "COMBATLOG_XPGAIN_QUEST", "FACTION_STANDING_INCREASED", "FACTION_STANDING_DECREASED",
  "FACTION_STANDING_INCREASED_BONUS", "GOLD_AMOUNT", "SILVER_AMOUNT", "COPPER_AMOUNT", "ERR_INV_FULL",
  "ERR_QUEST_REWARD_MONEY_S", "ERR_QUEST_REWARD_EXP_I",
}

local FUNCS = {
  { "issecretvalue", function() return exists(G("issecretvalue")) end },
  { "canaccessvalue", function() return exists(G("canaccessvalue")) end },
  { "C_Secrets", function() return exists(G("C_Secrets")) end },
  -- it takes a restriction type (run 2: "Usage: ...IsAddOnRestrictionActive(type)"); ask about each one the client lists
  { "C_RestrictedActions.IsAddOnRestrictionActive", function()
    local fn = G("C_RestrictedActions.IsAddOnRestrictionActive")
    if type(fn) ~= "function" then return "missing", "not a function" end
    local types = G("Enum.AddOnRestrictionType")
    if type(types) ~= "table" then
      local status, detail = call(fn, 0)
      return status, "no Enum.AddOnRestrictionType; type 0: " .. detail
    end
    local names = {}
    for name in pairs(types) do names[#names + 1] = name end
    table.sort(names)
    local parts = {}
    for _, name in ipairs(names) do
      local ok, v = pcall(fn, types[name])
      parts[#parts + 1] = format("%s=%s", tostring(name), ok and describe(v) .. (v == true and ":true" or "") or "error")
    end
    return "ok", table.concat(parts, " "):sub(1, 200)
  end },
  { "C_DamageMeter", function() return exists(G("C_DamageMeter")) end },
  { "GetLootSourceInfo", function() return exists(G("GetLootSourceInfo")) end },
  { "GetItemInfo(2589)", function() return call(G("GetItemInfo") or G("C_Item.GetItemInfo"), 2589) end },
  { "GetItemInfoInstant(2589)", function()
    local fn = G("GetItemInfoInstant") or G("C_Item.GetItemInfoInstant")
    if type(fn) ~= "function" then return "missing", "" end
    local ok, id, _, _, equip, _, classID, subclassID = pcall(fn, 2589)
    if not ok then return "error", tostring(id) end
    return "ok", format("id=%s class=%s subclass=%s equip=%s", tostring(id), tostring(classID), tostring(subclassID), tostring(equip))
  end },
  { "C_Item.GetItemQualityByID", function() return exists(G("C_Item.GetItemQualityByID")) end },
  { "C_Map.GetBestMapForUnit", function()
    local ok, v = pcall(C_Map.GetBestMapForUnit, "player")
    if not ok then return "error", tostring(v) end
    if W.isSecret(v) then return "secret", "" end
    return "ok", tostring(v) -- a map ID, not personal
  end },
  -- run 2: no usable map ID inside The Deadmines (HC-13): what does the instance API give instead?
  { "GetInstanceInfo", function()
    local fn = G("GetInstanceInfo")
    if type(fn) ~= "function" then return "missing", "" end
    local ok, name, kind, difficultyID, _, maxPlayers, _, _, instanceID = pcall(fn)
    if not ok then return "error", tostring(name) end
    if W.isSecret(instanceID) or W.isSecret(kind) then return "secret", "" end
    return "ok", format("type=%s id=%s difficulty=%s max=%s name=%s", tostring(kind), tostring(instanceID),
      tostring(difficultyID), tostring(maxPlayers), tostring(name))
  end },
  { "UnitPosition(player)", function() return call(G("UnitPosition"), "player") end },
  { "GetUnitSpeed(player)", function() return call(G("GetUnitSpeed"), "player") end },
  { "UnitIsAFK(player)", function() return call(G("UnitIsAFK"), "player") end },
  { "GetMoney", function() return call(G("GetMoney")) end },
  { "UnitXP/UnitXPMax", function()
    local a, da = call(G("UnitXP"), "player")
    local _, db = call(G("UnitXPMax"), "player")
    return a, da .. " / " .. db
  end },
  { "C_Reputation.GetNumFactions", function() return call(G("C_Reputation.GetNumFactions")) end },
  { "C_Reputation.GetFactionDataByIndex", function() return exists(G("C_Reputation.GetFactionDataByIndex")) end },
  { "GetFactionInfo (legacy)", function() return exists(G("GetFactionInfo")) end },
  { "Screenshot (not called)", function() return exists(G("Screenshot")) end },
  { "C_AddOnProfiler", function() return exists(G("C_AddOnProfiler")) end },
  { "C_DateAndTime.GetSecondsUntilWeeklyReset", function() return call(G("C_DateAndTime.GetSecondsUntilWeeklyReset")) end },
  { "GetCurrentRegion", function()
    local ok, v = pcall(G("GetCurrentRegion"))
    return ok and "ok" or "error", tostring(v)
  end },
  { "C_Container.GetContainerNumFreeSlots(0)", function() return call(G("C_Container.GetContainerNumFreeSlots"), 0) end },
  { "Item.CreateFromItemID", function() return exists(G("Item.CreateFromItemID")) end },
  { "WOW_PROJECT_ID", function() return "ok", tostring(G("WOW_PROJECT_ID")) end },
  { "C_PlayerInteractionManager", function() return exists(G("C_PlayerInteractionManager")) end },
  { "Enum.PlayerInteractionType (Merchant,MailInfo,Auctioneer,Trainer,TaxiNode,TradePartner)", function()
    local t = G("Enum.PlayerInteractionType")
    if type(t) ~= "table" then return "missing", describe(t) end
    return "ok", format("%s,%s,%s,%s,%s,%s", tostring(t.Merchant), tostring(t.MailInfo), tostring(t.Auctioneer),
      tostring(t.Trainer), tostring(t.TaxiNode), tostring(t.TradePartner))
  end },
  -- Basics (HC-21): rested XP
  { "GetXPExhaustion", function() return call(G("GetXPExhaustion")) end },
}

-- CS-1 (Character Stats): which stat APIs exist on Forever and what they return (types and secretness only), in and
-- out of combat. { label, global name, args... }. Spell schools: 2 holy, 3 fire, 4 nature, 5 frost, 6 shadow, 7 arcane.
local STAT_FUNCS = {
  { "UnitStat(player,1)", "UnitStat", "player", 1 }, { "UnitStat(player,5)", "UnitStat", "player", 5 },
  { "UnitAttackPower", "UnitAttackPower", "player" }, { "UnitRangedAttackPower", "UnitRangedAttackPower", "player" },
  { "UnitDamage", "UnitDamage", "player" }, { "UnitRangedDamage", "UnitRangedDamage", "player" },
  { "UnitAttackSpeed", "UnitAttackSpeed", "player" }, { "UnitAttackBothHands", "UnitAttackBothHands", "player" },
  { "GetCritChance", "GetCritChance" }, { "GetRangedCritChance", "GetRangedCritChance" },
  { "GetSpellCritChance(3)", "GetSpellCritChance", 3 }, { "GetHitModifier", "GetHitModifier" },
  { "GetSpellHitModifier", "GetSpellHitModifier" }, { "GetSpellBonusDamage(3)", "GetSpellBonusDamage", 3 },
  { "GetSpellBonusDamage(6)", "GetSpellBonusDamage", 6 }, { "GetSpellBonusHealing", "GetSpellBonusHealing" },
  { "GetSpellPenetration", "GetSpellPenetration" }, { "UnitSpellHaste", "UnitSpellHaste", "player" },
  { "GetHaste", "GetHaste" }, { "GetExpertise", "GetExpertise" }, { "GetArmorPenetration", "GetArmorPenetration" },
  { "GetManaRegen", "GetManaRegen" }, { "UnitArmor", "UnitArmor", "player" }, { "UnitDefense", "UnitDefense", "player" },
  { "GetDodgeChance", "GetDodgeChance" }, { "GetParryChance", "GetParryChance" }, { "GetBlockChance", "GetBlockChance" },
  { "GetShieldBlock", "GetShieldBlock" }, { "UnitResistance(player,2)", "UnitResistance", "player", 2 },
  { "GetCombatRating(1)", "GetCombatRating", 1 }, { "GetCombatRatingBonus(1)", "GetCombatRatingBonus", 1 },
  { "GetAverageItemLevel", "GetAverageItemLevel" }, { "GetInventoryItemDurability(1)", "GetInventoryItemDurability", 1 },
  { "UnitHealthMax", "UnitHealthMax", "player" }, { "UnitPowerMax", "UnitPowerMax", "player" },
  { "GetUnitSpeed", "GetUnitSpeed", "player" },
}
for _, s in ipairs(STAT_FUNCS) do
  local name, args = s[2], { select(3, unpack(s)) }
  FUNCS[#FUNCS + 1] = { "CS-1 " .. s[1], function() return call(G(name), unpack(args)) end }
end

-- CS-8 (Character Stats): UnitDefense and UnitAttackBothHands are absent (run 3). Do the skill lines list weapon skills
-- and Defence? Records the headers with their visible line counts (client strings, not personal) and Defence's
-- rank types; a collapsed header hides its lines, and the probe never expands one (that changes the UI).
FUNCS[#FUNCS + 1] = { "CS-8 skill lines", function()
  local num, info = G("GetNumSkillLines"), G("GetSkillLineInfo")
  if type(num) ~= "function" or type(info) ~= "function" then
    return "missing", format("GetNumSkillLines=%s GetSkillLineInfo=%s", describe(num), describe(info))
  end
  local ok, n = pcall(num)
  if not ok then return "error", tostring(n):sub(1, 120) end
  if W.isSecret(n) then return "secret", "count" end
  local parts, defence, header, count = {}, "not listed", nil, 0
  local function close() if header then parts[#parts + 1] = format("%s(%d)", header, count) end end
  for i = 1, math.min(tonumber(n) or 0, 80) do
    local okI, name, isHeader, _, rank, _, _, maxRank = pcall(info, i)
    if okI and type(name) == "string" and not W.isSecret(name) then
      if isHeader then
        close(); header, count = name, 0
      else
        count = count + 1
        if name == (G("DEFENSE") or "Defense") then defence = describe(rank) .. "/" .. describe(maxRank) end
      end
    end
  end
  close()
  return "ok", format("n=%s defence=%s %s", tostring(n), defence, table.concat(parts, ",")):sub(1, 240)
end }

-- HC-34 (pickers for player-made readings): can an item in the bags be counted, is there a faction list with
-- standings, and what does the cursor carry when the player holds an item? Shapes and types only, never names or
-- amounts. To probe the cursor: pick an item up from a bag, then /hc diag probes while holding it.
FUNCS[#FUNCS + 1] = { "HC-34 GetItemCount", function()
  local fn = G("C_Item.GetItemCount") or G("GetItemCount")
  if type(fn) ~= "function" then return "missing", "C_Item.GetItemCount and GetItemCount" end
  local which = G("C_Item.GetItemCount") and "C_Item" or "global"
  local s1, d1 = call(fn, 6948)                      -- Hearthstone: every character has one
  local s2, d2 = call(fn, 6948, true)                -- with the bank
  return s1, format("%s plain=%s bank=%s/%s", which, tostring(d1), tostring(s2), tostring(d2))
end }
FUNCS[#FUNCS + 1] = { "HC-34 faction list", function()
  local num, byIndex, byId = G("C_Reputation.GetNumFactions"), G("C_Reputation.GetFactionDataByIndex"), G("C_Reputation.GetFactionDataByID")
  local legacy = format("legacy GetNumFactions=%s GetFactionInfo=%s", describe(G("GetNumFactions")), describe(G("GetFactionInfo")))
  if type(num) ~= "function" or type(byIndex) ~= "function" then
    return "missing", format("C_Reputation: num=%s byIndex=%s byID=%s; %s", describe(num), describe(byIndex), describe(byId), legacy)
  end
  local ok, n = pcall(num)
  if not ok then return "error", tostring(n):sub(1, 120) end
  if W.isSecret(n) then return "secret", "count" end
  -- the field names and types of the first faction that is not a header (API field names, nothing personal)
  local fields = "no entry"
  for i = 1, math.min(tonumber(n) or 0, 40) do
    local okI, d = pcall(byIndex, i)
    if okI and type(d) == "table" and not d.isHeader then
      local keys = {}
      for k, v in pairs(d) do if type(k) == "string" then keys[#keys + 1] = k .. ":" .. describe(v) end end
      table.sort(keys)
      fields = table.concat(keys, " ")
      break
    end
  end
  return "ok", format("n=%s byID=%s; %s; %s", tostring(n), describe(byId), legacy, fields):sub(1, 400)
end }
FUNCS[#FUNCS + 1] = { "HC-34 cursor", function()
  local fn = G("GetCursorInfo")
  if type(fn) ~= "function" then return "missing", "GetCursorInfo" end
  local r = { pcall(fn) }
  if not r[1] then return "error", tostring(r[2]):sub(1, 120) end
  -- the kind is a client word ("item", "spell", "money"...): kept; the rest by type only
  local kind = r[2]
  local parts = {}
  for i = 3, math.min(#r, 6) do parts[#parts + 1] = describe(r[i]) end
  local kindText = (type(kind) == "string" and not W.isSecret(kind)) and kind or describe(kind)
  return "ok", format("kind=%s rest=%s ClearCursor=%s", kindText, table.concat(parts, ","), describe(G("ClearCursor")))
end }

-- CS-8 (b), the user's choice 2026-11-19: Forever has no skill-line API. Do its combat ratings carry weapon skill
-- or Defence (the TBC-era CR_* indices), and does any global or C_ namespace have a skill function? Ratings: the
-- indices that read non-zero, by number, and the CR_* constants the client defines; never the values themselves.
local RATING_NAMES = { "CR_WEAPON_SKILL", "CR_DEFENSE_SKILL", "CR_DODGE", "CR_PARRY", "CR_BLOCK", "CR_HIT_MELEE",
  "CR_CRIT_MELEE", "CR_WEAPON_SKILL_RANGED", "CR_WEAPON_SKILL_MAINHAND", "CR_WEAPON_SKILL_OFFHAND", "CR_EXPERTISE" }
FUNCS[#FUNCS + 1] = { "CS-8 ratings", function()
  local rating, bonus = G("GetCombatRating"), G("GetCombatRatingBonus")
  if type(rating) ~= "function" then return "missing", "GetCombatRating" end
  local consts = {}
  for _, name in ipairs(RATING_NAMES) do
    local v = G(name)
    consts[#consts + 1] = name:sub(4) .. "=" .. (type(v) == "number" and tostring(v) or describe(v))
  end
  local nonzero = {}
  for i = 1, 32 do
    local ok, v = pcall(rating, i)
    local okB, b = false, nil
    if type(bonus) == "function" then okB, b = pcall(bonus, i) end
    local hit = (ok and type(v) == "number" and not W.isSecret(v) and v ~= 0)
      or (okB and type(b) == "number" and not W.isSecret(b) and b ~= 0)
    if hit then nonzero[#nonzero + 1] = tostring(i) end
  end
  return "ok", format("nonzero=[%s] %s", table.concat(nonzero, ","), table.concat(consts, " ")):sub(1, 400)
end }
local skillFuncs                                  -- the scan of _G runs once per session (tens of thousands of keys)
FUNCS[#FUNCS + 1] = { "CS-8 skill functions", function()
  if not skillFuncs then
    local found = {}
    local function wanted(name) return name:find("[Ss]kill") or name:find("Defen[cs]e") end
    for k, v in pairs(_G) do
      if type(k) == "string" then
        if type(v) == "function" and wanted(k) then
          found[#found + 1] = k
        elseif type(v) == "table" and k:sub(1, 2) == "C_" then
          for fk, fv in pairs(v) do
            if type(fk) == "string" and type(fv) == "function" and wanted(fk) then found[#found + 1] = k .. "." .. fk end
          end
        end
      end
    end
    table.sort(found)
    skillFuncs = format("%d: %s", #found, table.concat(found, " ")):sub(1, 600)
  end
  return "ok", skillFuncs
end }

-- CS-8 (b), second step (2026-11-19 files): the scan found a C_SkillInfo namespace (GetNumSkillLines, Expand and
-- CollapseSkillHeader, ...), which run 3's global-only check missed. Its function names in full, then the skill
-- lines it lists: the shape of one entry (field names and types), headers with their line counts, Defense's rank
-- types. Client strings and types only; it never expands a header (that changes the UI).
FUNCS[#FUNCS + 1] = { "CS-8 C_SkillInfo", function()
  local ns2 = G("C_SkillInfo")
  if type(ns2) ~= "table" then return "missing", "C_SkillInfo" end
  local names = {}
  for k, v in pairs(ns2) do if type(k) == "string" and type(v) == "function" then names[#names + 1] = k end end
  table.sort(names)
  local out = { "fns=" .. table.concat(names, ",") }
  local num = ns2.GetNumSkillLines
  local info = ns2.GetSkillLineInfo or ns2.GetSkillLineInfoByIndex or ns2.GetSkillLineDataByIndex
  if type(num) ~= "function" or type(info) ~= "function" then
    out[#out + 1] = "no count or no per-line call"
    return "ok", table.concat(out, " "):sub(1, 900)
  end
  local ok, n = pcall(num)
  if not ok then return "error", tostring(n):sub(1, 120) end
  if W.isSecret(n) then return "secret", "count" end
  out[#out + 1] = "n=" .. tostring(n)
  local shape, header, count, defence = nil, nil, 0, "not listed"
  local parts = {}
  local function close() if header then parts[#parts + 1] = format("%s(%d)", header, count) end end
  for i = 1, math.min(tonumber(n) or 0, 80) do
    local r = { pcall(info, i) }
    if r[1] then
      local name, isHeader, rank, maxRank
      if type(r[2]) == "table" then
        local d = r[2]
        if not shape then
          local keys = {}
          for k, v in pairs(d) do if type(k) == "string" then keys[#keys + 1] = k .. ":" .. describe(v) end end
          table.sort(keys)
          shape = "table{" .. table.concat(keys, " ") .. "}"
        end
        name, isHeader = d.skillName or d.name, d.isHeader or d.header
        rank, maxRank = d.skillRank or d.rank, d.skillMaxRank or d.maxRank
      else
        if not shape then
          local t = {}
          for k = 2, math.min(#r, 12) do t[#t + 1] = describe(r[k]) end
          shape = "returns{" .. table.concat(t, ",") .. "}"
        end
        name, isHeader, rank, maxRank = r[2], r[3], r[5], r[8]
      end
      if type(name) == "string" and not W.isSecret(name) then
        if isHeader then
          close(); header, count = name, 0
        else
          count = count + 1
          if name == (G("DEFENSE") or "Defense") then defence = describe(rank) .. "/" .. describe(maxRank) end
        end
      end
    end
  end
  close()
  out[#out + 1] = "shape=" .. tostring(shape)
  out[#out + 1] = "defence=" .. defence
  out[#out + 1] = table.concat(parts, ",")
  return "ok", table.concat(out, " "):sub(1, 900)
end }

-- CS-9: can a stat that is secret in combat be shown by handing it unchanged to a font string or a status bar
-- (DESIGN §3.3)? Tried on a hidden frame, never shown. Out of combat the values aren't secret and it says so; the
-- automatic run in the first fight of each login answers it. Whether it *draws* (or taints) is for BugGrabber and
-- the eye: this records only whether each call raised an error and what GetText gives back.
local passFrame
FUNCS[#FUNCS + 1] = { "CS-9 pass-through", function()
  local ap, crit = G("UnitAttackPower"), G("GetCritChance")
  if type(ap) ~= "function" and type(crit) ~= "function" then return "missing", "UnitAttackPower and GetCritChance" end
  local v
  if type(ap) == "function" then
    local ok, base = pcall(ap, "player")
    if ok and W.isSecret(base) then v = base end
  end
  if v == nil and type(crit) == "function" then
    local ok, c = pcall(crit)
    if ok and W.isSecret(c) then v = c end
  end
  if v == nil then return "ok", "not secret now (out of combat?)" end
  if not passFrame then
    passFrame = CreateFrame("Frame", nil, UIParent)
    passFrame:Hide()
    passFrame.fs = passFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    passFrame.bar = CreateFrame("StatusBar", nil, passFrame)
  end
  local fs, bar = passFrame.fs, passFrame.bar
  local parts = {}
  local function try(label, fn, ...)
    local ok, err = pcall(fn, ...)
    parts[#parts + 1] = label .. "=" .. (ok and "ok" or ("error:" .. tostring(err):sub(1, 60)))
  end
  try("SetText", fs.SetText, fs, v)
  local okT, text = pcall(fs.GetText, fs)
  parts[#parts + 1] = "GetText=" .. (okT and describe(text) or "error")
  try("SetFormattedText", fs.SetFormattedText, fs, "%d", v)
  try("SetMinMaxValues", bar.SetMinMaxValues, bar, 0, 100000)
  try("SetValue", bar.SetValue, bar, v)
  return "ok", table.concat(parts, " ")
end }

-- FM-16: own-character mail. Farmer reads the sender of the mail whose money is taken and the amount on the send
-- form when SendMail is called. Existence only (the mailbox needn't be open).
FUNCS[#FUNCS + 1] = { "FM-16 mail API", function()
  local names = { "GetInboxHeaderInfo", "SendMail", "GetSendMailMoney", "GetSendMailPrice", "TakeInboxMoney" }
  local parts, missing = {}, 0
  for _, n in ipairs(names) do
    local d = describe(G(n))
    if d ~= "function" then missing = missing + 1 end
    parts[#parts + 1] = n .. "=" .. d
  end
  return missing == 0 and "ok" or "missing", table.concat(parts, " ")
end }

-- HC-42 (c): Blizzard's Edit Mode exists on Forever (a Questie taint stack, 2026-11-17). Do its callbacks reach an
-- addon? We listen to EventRegistry's "EditMode.Enter" / "EditMode.Exit" and, as a fallback, hook the manager
-- frame's OnShow / OnHide; each fire is counted in HardCountersDiagDB.probes.editMode (saved at once, so opening
-- and closing Edit Mode, then /reload, answers it) and this row is run again. Nothing of ours reacts to it yet.
local editMode   -- P().editMode once the DB is ready
local function editModeFired(kind)
  if not editMode then return end
  editMode[kind] = (editMode[kind] or 0) + 1
  editMode[kind .. "T"] = W.now()
  local okC, c = pcall(W.inCombat)
  if okC and c then editMode.inCombat = (editMode.inCombat or 0) + 1 end
  if ns.RunProbe then pcall(ns.RunProbe, "HC-42 Edit Mode") end
end

local function hookEditMode()
  if not editMode or editMode.hook == "ok" then return end
  local mgr = G("EditModeManagerFrame")
  if type(mgr) ~= "table" or type(mgr.HookScript) ~= "function" then editMode.hook = "no frame"; return end
  local ok, err = pcall(function()
    mgr:HookScript("OnShow", function() editModeFired("show") end)
    mgr:HookScript("OnHide", function() editModeFired("hide") end)
  end)
  editMode.hook = ok and "ok" or ("error:" .. tostring(err):sub(1, 60))
end

local function listenEditMode()
  if not editMode then return end
  local reg = G("EventRegistry")
  if type(reg) ~= "table" or type(reg.RegisterCallback) ~= "function" then
    editMode.reg = "no EventRegistry"
  else
    local owner = {}
    local ok, err = pcall(function()
      reg:RegisterCallback("EditMode.Enter", function() editModeFired("enter") end, owner)
      reg:RegisterCallback("EditMode.Exit", function() editModeFired("exit") end, owner)
    end)
    editMode.reg = ok and "ok" or ("error:" .. tostring(err):sub(1, 60))
  end
  hookEditMode()
end

FUNCS[#FUNCS + 1] = { "HC-42 Edit Mode", function()
  local e = editMode or {}
  local detail = format("EventRegistry=%s EditModeManagerFrame=%s registered=%s hooked=%s enter=%d exit=%d show=%d hide=%d inCombat=%d",
    describe(G("EventRegistry")), describe(G("EditModeManagerFrame")), tostring(e.reg), tostring(e.hook),
    e.enter or 0, e.exit or 0, e.show or 0, e.hide or 0, e.inCombat or 0)
  if e.reg ~= "ok" and e.hook ~= "ok" then return "missing", detail end
  return "ok", detail
end }

-- TR-1 (Traveler, a proposed pack; notes packs/Traveler/docs/DESIGN.md): what the client gives for travel. A sampler
-- reads the position 4 times a second and keeps counts only, in HardCountersDiagDB.probes.travel, summed across
-- loads: never a coordinate, never a name. It answers: does the position move on a taxi; are boats a ride or a
-- loading screen (moving while your own speed is 0); is positionZ a height; which state flags are secret in
-- combat; which spell IDs come right before a jump (blink, hearth); what a 0.25 s poll costs.
local TR_TICK = 0.25
local trv                                          -- P().travel once started
local trLast = { ok = false, x = 0, y = 0, z = 0, m = 0, t = 0, carriedT = -1000 }
local trCast = { id = nil, t = -1000 }             -- the latest plain spell ID the player cast
local TR_FLAGS = { "IsMounted", "IsSwimming", "IsSubmerged", "IsFlying", "IsFalling", "UnitOnTaxi", "UnitInVehicle",
  "UnitIsGhost", "GetPlayerFacing" }
local TR_UNIT_ARG = { UnitOnTaxi = true, UnitInVehicle = true, UnitIsGhost = true }
local sqrt = math.sqrt

local function trCount(key, n) trv[key] = (trv[key] or 0) + (n or 1) end

-- One flag: count plain / secret / missing, split by combat. Returns the value when plain.
local function trFlag(name, inCombat)
  local fn = _G[name]
  local f = trv.flags[name]
  if not f then f = {}; trv.flags[name] = f end
  if type(fn) ~= "function" then f.missing = (f.missing or 0) + 1; return nil end
  local ok, v
  if TR_UNIT_ARG[name] then ok, v = pcall(fn, "player") else ok, v = pcall(fn) end
  local key
  if not ok then key = "error"
  elseif W.isSecret(v) then key = inCombat and "secretIn" or "secretOut"
  else key = inCombat and "plainIn" or "plainOut" end
  f[key] = (f[key] or 0) + 1
  if ok and not W.isSecret(v) then return v end
  return nil
end

local function trJump(kind)
  trCount("jump_" .. kind)
  if trCast.id and W.time() - trCast.t <= 2 then
    local key = kind .. ":" .. tostring(trCast.id)
    trv.jumpSpells[key] = (trv.jumpSpells[key] or 0) + 1
  end
end

local trTicks = 0
local function travelTick()
  if not trv then return end
  local t0 = W.ms()
  trTicks = trTicks + 1
  local now = W.time()
  local okC, inCombat = pcall(W.inCombat)
  inCombat = okC and inCombat or false
  -- the flags once a second (every 4th tick); taxi and falling every tick (they decide this tick's numbers)
  if trTicks % 4 == 0 then
    for i = 1, #TR_FLAGS do trFlag(TR_FLAGS[i], inCombat) end
  end
  local fnTaxi, fnFall = _G.UnitOnTaxi, _G.IsFalling
  local okT, taxi = false, nil
  if type(fnTaxi) == "function" then okT, taxi = pcall(fnTaxi, "player") end
  taxi = okT and not W.isSecret(taxi) and taxi or false
  local okF, falling = false, nil
  if type(fnFall) == "function" then okF, falling = pcall(fnFall) end
  falling = okF and not W.isSecret(falling) and falling or false
  local fnPos = _G.UnitPosition
  if type(fnPos) ~= "function" then trCount("posMissing"); trLast.ok = false; return end
  local okP, x, y, z, m = pcall(fnPos, "player")
  if not okP then trCount("posError"); trLast.ok = false; return end
  if W.isSecret(x) or W.isSecret(y) or W.isSecret(m) then
    trCount(inCombat and "posSecretIn" or "posSecretOut"); trLast.ok = false; return
  end
  if type(x) ~= "number" or type(y) ~= "number" then trCount("posNil"); trLast.ok = false; return end
  trCount(inCombat and "posPlainIn" or "posPlainOut")
  if type(z) == "number" and not W.isSecret(z) then
    if z == 0 then trCount("zZero") else trCount("zNonZero") end
    if falling and trLast.ok and z ~= trLast.z then trCount("zMovesFalling") end
  end
  if trLast.ok then
    local dt = now - trLast.t
    if m ~= trLast.m then
      trCount("mapChange")
      if now - trLast.carriedT <= 10 then trCount("mapChangeAfterCarried") end
      trJump("map")
    elseif dt > 0 then
      local dx, dy = x - trLast.x, y - trLast.y
      local d = sqrt(dx * dx + dy * dy)
      local v = d / dt
      if taxi then
        trCount("taxiTicks")
        if d > 0.5 then trCount("taxiMoved") end
        if d <= 200 and v > (trv.vmaxTaxi or 0) then trv.vmaxTaxi = v end
      end
      if dt <= 0.6 and d >= 8 and d <= 40 and v > 20 and not taxi then trJump("short")
      elseif dt <= 0.6 and d > 40 and not taxi then trJump("long")
      elseif not taxi and d > 0 and v > (trv.vmaxOther or 0) then trv.vmaxOther = v end
      -- carried: the position moves while your own speed is 0 (out of combat: speed is secret in combat)
      if not taxi and v > 1 and d <= 40 then
        local fnSpeed = _G.GetUnitSpeed
        if type(fnSpeed) == "function" then
          local okS, cur = pcall(fnSpeed, "player")
          if okS and type(cur) == "number" and not W.isSecret(cur) and cur == 0 then
            trCount("carriedTicks"); trLast.carriedT = now
          end
        end
      end
    end
  end
  trLast.ok, trLast.x, trLast.y, trLast.z, trLast.m, trLast.t = true, x, y, z, m, now
  trCount("ticks")
  trv.ms = (trv.ms or 0) + (W.ms() - t0)
end

-- UNIT_SPELLCAST_SUCCEEDED (player): spell ID plain or secret, in and out of combat; a plain one is remembered for 2 s
local function travelCast(unit, _, spellID)
  if not trv or unit ~= "player" then return end
  local okC, inCombat = pcall(W.inCombat)
  inCombat = okC and inCombat or false
  if W.isSecret(spellID) then trCount(inCombat and "castSecretIn" or "castSecretOut"); return end
  trCount(inCombat and "castPlainIn" or "castPlainOut")
  if type(spellID) == "number" then trCast.id, trCast.t = spellID, W.time() end
end
ns.TravelTick, ns.TravelCast = travelTick, travelCast   -- for the tests

local function startTravel(p)
  p.travel = type(p.travel) == "table" and p.travel or {}
  trv = p.travel
  trv.flags = type(trv.flags) == "table" and trv.flags or {}
  trv.jumpSpells = type(trv.jumpSpells) == "table" and trv.jumpSpells or {}
  trLast.ok = false
  if W.newTicker then W.newTicker(TR_TICK, function() local ok = pcall(travelTick); if not ok then trCount("errors") end end) end
end

FUNCS[#FUNCS + 1] = { "TR-1 movement", function()
  if not trv then return "missing", "sampler not started" end
  local function n(k) return trv[k] or 0 end
  local flags = {}
  for _, name in ipairs(TR_FLAGS) do
    local f = trv.flags[name] or {}
    flags[#flags + 1] = format("%s=%d/%d/%d/%d%s", name, f.plainOut or 0, f.secretOut or 0, f.plainIn or 0,
      f.secretIn or 0, (f.missing or f.error) and "/x" or "")
  end
  local spells = {}
  for k, v in pairs(trv.jumpSpells) do spells[#spells + 1] = k .. "=" .. v end
  table.sort(spells)
  return "ok", format("ticks=%d avgms=%.3f pos plain out/in=%d/%d secret out/in=%d/%d nil=%d z zero/other/falling=%d/%d/%d"
    .. " taxi ticks/moved=%d/%d vmax taxi/other=%.1f/%.1f carried=%d mapChange=%d afterCarried=%d"
    .. " jumps short/long/map=%d/%d/%d cast plain out/in=%d/%d secret out/in=%d/%d spells[%s]"
    .. " flags(plainOut/secretOut/plainIn/secretIn) %s",
    n("ticks"), n("ticks") > 0 and n("ms") / n("ticks") or 0, n("posPlainOut"), n("posPlainIn"), n("posSecretOut"),
    n("posSecretIn"), n("posNil"), n("zZero"), n("zNonZero"), n("zMovesFalling"), n("taxiTicks"), n("taxiMoved"),
    n("vmaxTaxi"), n("vmaxOther"), n("carriedTicks"), n("mapChange"), n("mapChangeAfterCarried"), n("jump_short"),
    n("jump_long"), n("jump_map"), n("castPlainOut"), n("castPlainIn"), n("castSecretOut"), n("castSecretIn"),
    table.concat(spells, " "), table.concat(flags, " ")):sub(1, 1200)
end }

-- TR-1 (e): subzones as numbers. The area IDs at the player's map position, and whether one of them is named like
-- the subzone and the zone the game shows (compared here, never stored).
FUNCS[#FUNCS + 1] = { "TR-1 area IDs", function()
  local best, pos = G("C_Map.GetBestMapForUnit"), G("C_Map.GetPlayerMapPosition")
  local at, info = G("C_MapExplorationInfo.GetExploredAreaIDsAtPosition"), G("C_Map.GetAreaInfo")
  if type(at) ~= "function" then return "missing", "C_MapExplorationInfo.GetExploredAreaIDsAtPosition" end
  if type(best) ~= "function" or type(pos) ~= "function" then return "missing", "C_Map position calls" end
  local okM, map = pcall(best, "player")
  if not okM or type(map) ~= "number" then return "ok", "no map here (instance?)" end
  local okP, p = pcall(pos, map, "player")
  if not okP or p == nil then return "ok", "no map position" end
  local okA, ids = pcall(at, map, p)
  if not okA then return "error", tostring(ids):sub(1, 120) end
  if type(ids) ~= "table" then return "ok", "ids=" .. describe(ids) end
  local sub, zone = G("GetSubZoneText"), G("GetZoneText")
  local okS, subText = false, nil
  if type(sub) == "function" then okS, subText = pcall(sub) end
  local okZ, zoneText = false, nil
  if type(zone) == "function" then okZ, zoneText = pcall(zone) end
  local list, subMatch, zoneMatch = {}, "no", "no"
  for i, id in ipairs(ids) do
    if i <= 8 then list[#list + 1] = describe(id) == "number" and tostring(id) or describe(id) end
    if type(info) == "function" and type(id) == "number" then
      local okN, name = pcall(info, id)
      if okN and type(name) == "string" and not W.isSecret(name) then
        if okS and name == subText then subMatch = "yes" end
        if okZ and name == zoneText then zoneMatch = "yes" end
      end
    end
  end
  return "ok", format("map=%d n=%d ids=%s subzoneMatch=%s zoneMatch=%s subzoneEmpty=%s", map, #ids,
    table.concat(list, ","), subMatch, zoneMatch, tostring(okS and subText == ""))
end }

-- TR-1 (f): "x of y subzones explored" needs a total. Exploration achievements list a zone's subzones as criteria:
-- are they readable here? Counts and types only (criteria are subzone names). 776 Explore Elwynn Forest, 42 Explore
-- Eastern Kingdoms, 43 Explore Kalimdor (Retail and Classic IDs; Forever's may differ).
FUNCS[#FUNCS + 1] = { "TR-1 exploration achievements", function()
  local infoA, numC, crit = G("GetAchievementInfo"), G("GetAchievementNumCriteria"), G("GetAchievementCriteriaInfo")
  if type(numC) ~= "function" or type(crit) ~= "function" then
    return "missing", format("GetAchievementInfo=%s GetAchievementNumCriteria=%s GetAchievementCriteriaInfo=%s",
      describe(infoA), describe(numC), describe(crit))
  end
  local parts = {}
  for _, id in ipairs({ 776, 42, 43 }) do
    local okN, n = pcall(numC, id)
    if not okN or type(n) ~= "number" or W.isSecret(n) then
      parts[#parts + 1] = format("%d=%s", id, okN and describe(n) or "error")
    else
      local done, shape, ctype = 0, nil, nil
      for i = 1, math.min(n, 60) do
        local r = { pcall(crit, id, i) }
        if r[1] then
          if r[4] == true then done = done + 1 end
          if not shape then
            local t = {}
            for k = 2, math.min(#r, 12) do t[#t + 1] = describe(r[k]) end
            shape = table.concat(t, ",")
            ctype = type(r[3]) == "number" and not W.isSecret(r[3]) and tostring(r[3]) or describe(r[3])
          end
        end
      end
      parts[#parts + 1] = format("%d=n:%d done:%d type:%s shape:%s", id, n, done, tostring(ctype), tostring(shape))
    end
  end
  return "ok", table.concat(parts, " | "):sub(1, 600)
end }

-- TR-1 (g): flight points known, for the zone and its continent (C_TaxiMap.GetTaxiNodesForMap: all nodes of a map,
-- each with isUndiscovered). Counts and the node ID's type only.
local function continentOf(map)
  local getInfo = G("C_Map.GetMapInfo")
  local CONTINENT = G("Enum.UIMapType.Continent") or 2
  for _ = 1, 8 do
    if type(getInfo) ~= "function" or type(map) ~= "number" then return nil end
    local ok, mi = pcall(getInfo, map)
    if not ok or type(mi) ~= "table" then return nil end
    if mi.mapType == CONTINENT then return map end
    map = mi.parentMapID
  end
  return nil
end
FUNCS[#FUNCS + 1] = { "TR-1 taxi nodes", function()
  local nodes, best = G("C_TaxiMap.GetTaxiNodesForMap"), G("C_Map.GetBestMapForUnit")
  if type(nodes) ~= "function" then return "missing", "C_TaxiMap.GetTaxiNodesForMap" end
  if type(best) ~= "function" then return "missing", "C_Map.GetBestMapForUnit" end
  local okM, map = pcall(best, "player")
  if not okM or type(map) ~= "number" then return "ok", "no map here (instance?)" end
  local function count(m)
    if not m then return "none" end
    local ok, list = pcall(nodes, m)
    if not ok then return "error" end
    if type(list) ~= "table" then return describe(list) end
    local undiscovered, idType = 0, "none"
    for i, node in ipairs(list) do
      if type(node) == "table" then
        if node.isUndiscovered == true then undiscovered = undiscovered + 1 end
        if i == 1 then idType = describe(node.nodeID) end
      end
    end
    return format("%d:n=%d undiscovered=%d nodeID=%s", m, #list, undiscovered, idType)
  end
  return "ok", format("zone %s; continent %s", count(map), count(continentOf(map)))
end }

-- Events: count fires per instance type; first fires record argument types and secretness.
local EVENTS = {
  "CHAT_MSG_MONEY", "CHAT_MSG_LOOT", "CHAT_MSG_COMBAT_XP_GAIN", "CHAT_MSG_COMBAT_FACTION_CHANGE", "CHAT_MSG_SYSTEM",
  "PLAYER_MONEY", "PLAYER_XP_UPDATE", "PLAYER_LEVEL_UP", "UPDATE_FACTION", "QUEST_TURNED_IN",
  "LOOT_READY", "LOOT_OPENED", "LOOT_CLOSED", "MERCHANT_SHOW", "MERCHANT_CLOSED", "MAIL_SHOW", "MAIL_CLOSED",
  "AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED", "TRAINER_SHOW", "TRAINER_CLOSED", "TAXIMAP_OPENED", "TAXIMAP_CLOSED",
  "TRADE_SHOW", "TRADE_CLOSED", "PLAYER_INTERACTION_MANAGER_FRAME_SHOW", "PLAYER_INTERACTION_MANAGER_FRAME_HIDE",
  "UI_ERROR_MESSAGE", "ADDON_RESTRICTION_STATE_CHANGED", "PLAYER_FLAGS_CHANGED", "ZONE_CHANGED_NEW_AREA",
  "GET_ITEM_INFO_RECEIVED", "BAG_UPDATE_DELAYED", "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED",
  "LOADING_SCREEN_ENABLED", "LOADING_SCREEN_DISABLED", "PLAYER_ENTERING_WORLD",
  -- CS-1: stat events (not unit events)
  "PLAYER_EQUIPMENT_CHANGED", "COMBAT_RATING_UPDATE", "SPELL_POWER_CHANGED", "SKILL_LINES_CHANGED",
  -- HC-30 / HC-34: Alt + right-click on a tile, and dropping an item on one
  "MODIFIER_STATE_CHANGED", "CURSOR_CHANGED",
  "UPDATE_INVENTORY_DURABILITY",
  -- TR-1 (Traveler): discoveries, summons, subzone changes, taxi start and end (control lost and gained)
  "MAP_EXPLORATION_UPDATED", "TAXI_NODE_STATUS_CHANGED", "CONFIRM_SUMMON", "ZONE_CHANGED", "ZONE_CHANGED_INDOORS",
  "PLAYER_CONTROL_LOST", "PLAYER_CONTROL_GAINED",
}
-- CS-1: unit stat events, for the player only (RegisterUnitEvent where the client has it; UNIT_AURA fires for every
-- unit around you otherwise)
local UNIT_EVENTS = {
  "UNIT_STATS", "UNIT_AURA", "UNIT_ATTACK_POWER", "UNIT_RANGED_ATTACK_POWER", "UNIT_ATTACK_SPEED", "UNIT_DAMAGE",
  "UNIT_RESISTANCES", "UNIT_MAXHEALTH", "UNIT_MAXPOWER", "UNIT_SPELLCAST_SUCCEEDED",
}
for _, ev in ipairs(UNIT_EVENTS) do EVENTS[#EVENTS + 1] = ev end
local IS_UNIT_EVENT = {}
for _, ev in ipairs(UNIT_EVENTS) do IS_UNIT_EVENT[ev] = true end

-- Chat events whose text we test against patterns built from the client's own strings (match yes/no only).
local CHAT_PATTERNS = {
  -- self lines first; then crafted items and other players' loot (2026-11-14: 177 of 307 loot lines matched nothing)
  CHAT_MSG_LOOT = { "LOOT_ITEM_SELF_MULTIPLE", "LOOT_ITEM_SELF", "LOOT_ITEM_PUSHED_SELF_MULTIPLE", "LOOT_ITEM_PUSHED_SELF",
    "LOOT_ITEM_CREATED_SELF_MULTIPLE", "LOOT_ITEM_CREATED_SELF", "LOOT_ITEM_MULTIPLE", "LOOT_ITEM" },
  CHAT_MSG_MONEY = { "YOU_LOOT_MONEY", "LOOT_MONEY_SPLIT" },
  CHAT_MSG_COMBAT_XP_GAIN = { "COMBATLOG_XPGAIN_FIRSTPERSON", "COMBATLOG_XPGAIN_FIRSTPERSON_UNNAMED" },
  CHAT_MSG_COMBAT_FACTION_CHANGE = { "FACTION_STANDING_INCREASED", "FACTION_STANDING_DECREASED" },
}
-- Lines that carry a suffix after the formatted part ("(+75 exp Rested bonus)"): match without the end anchor, as
-- Farmer's parser does.
local OPEN_END = { CHAT_MSG_COMBAT_XP_GAIN = true, CHAT_MSG_COMBAT_FACTION_CHANGE = true }
-- Events whose first argument is a small enum worth counting (interaction type: which window).
local COUNT_ARG1 = { PLAYER_INTERACTION_MANAGER_FRAME_SHOW = true, PLAYER_INTERACTION_MANAGER_FRAME_HIDE = true }

local compiled = {}
local function patternsFor(event)
  local names = CHAT_PATTERNS[event]
  if not names then return nil end
  if not compiled[event] then
    local list = {}
    for _, name in ipairs(names) do
      local p = HardCounters:ChatPattern(G(name))
      if p and OPEN_END[event] then p = p:gsub("%$$", "") end
      if p then list[#list + 1] = { name, p } end
    end
    compiled[event] = list
  end
  return compiled[event]
end

local SIG_SAMPLES = 3

local function recordEvent(event, ...)
  local e = P().events[event]
  if not e then e = { fires = {}, samples = 0, secretArgs = 0, matched = {}, unmatched = 0 }; P().events[event] = e end
  local inst = W.instanceType()
  e.fires[inst] = (e.fires[inst] or 0) + 1
  local n = select("#", ...)
  local anySecret = false
  for i = 1, n do if W.isSecret((select(i, ...))) then anySecret = true; break end end
  if anySecret then e.secretArgs = e.secretArgs + 1 end
  if e.samples < SIG_SAMPLES then
    e.samples = e.samples + 1
    local parts = {}
    for i = 1, math.min(n, 8) do parts[#parts + 1] = describe((select(i, ...))) end
    e.sig = table.concat(parts, ",")
  end
  if COUNT_ARG1[event] then
    local a1 = ...
    if type(a1) == "number" and not W.isSecret(a1) then
      e.arg1 = e.arg1 or {}
      e.arg1[a1] = (e.arg1[a1] or 0) + 1
    end
  end
  local pats = patternsFor(event)
  local msg = ...
  if pats and type(msg) == "string" and not W.isSecret(msg) then
    local hit
    for _, p in ipairs(pats) do
      if msg:match(p[2]) then hit = p[1]; break end
    end
    if hit then e.matched[hit] = (e.matched[hit] or 0) + 1 else e.unmatched = e.unmatched + 1 end
    -- FM-9: which fields of our own looted item links are filled (field numbers only, never the link)
    if event == "CHAT_MSG_LOOT" and hit then
      local link = msg:match("|H(item:[^|]+)|h")
      if link then
        local filled, i = {}, 0
        for field in (link .. ":"):gmatch("([^:]*):") do
          i = i + 1
          if i > 1 and field ~= "" then filled[#filled + 1] = tostring(i - 1) end
        end
        local shape = table.concat(filled, ",")
        P().links[shape] = (P().links[shape] or 0) + 1
      end
    end
  end
end

-- Loading-screen heartbeat: does addon code run (OnUpdate frames) during loading screens?
local heart = CreateFrame("Frame")
local framesDuring = 0
heart:Hide()
heart:SetScript("OnUpdate", function() framesDuring = framesDuring + 1 end)

local function onLoading(event)
  local L = P().loading
  if event == "LOADING_SCREEN_ENABLED" then
    framesDuring = 0
    heart:Show()
  else
    heart:Hide()
    L.screens = (L.screens or 0) + 1
    L.lastFrames = framesDuring
    if framesDuring > (L.maxFrames or 0) then L.maxFrames = framesDuring end
    if framesDuring > 0 then L.withFrames = (L.withFrames or 0) + 1 end
  end
end

--- Run one function probe and keep its result (the newest 5 per probe). Returns its status.
local function runOne(pr, t, ctx)
  local success, status, detail = pcall(pr[2])
  if not success then status, detail = "error", tostring(status) end
  local funcs = P().funcs
  local h = funcs[pr[1]] or {}
  funcs[pr[1]] = h
  h[#h + 1] = { t = t, status = status, detail = detail, ctx = ctx }
  while #h > 5 do table.remove(h, 1) end
  return status
end

--- Run one function probe by name now (a probe whose answer comes from an event: HC-42's Edit Mode).
function ns.RunProbe(name)
  for _, pr in ipairs(FUNCS) do
    if pr[1] == name then return runOne(pr, W.now(), ns.contextLine()) end
  end
  return nil
end

--- Run the function probes now, with context; keeps the newest 5 results per probe.
function ns.RunProbes()
  local ctx = ns.contextLine()
  local t = W.now()
  local ok, fail = 0, 0
  for _, pr in ipairs(FUNCS) do
    if runOne(pr, t, ctx) == "ok" then ok = ok + 1 else fail = fail + 1 end
  end
  local strings = P().strings
  for _, name in ipairs(STRINGS) do
    local v = G(name)
    strings[name] = type(v) == "string" and v or ("<" .. describe(v) .. ">")
  end
  P().lastRun = { t = t, ctx = ctx, ok = ok, other = fail }
  B.Log("info", "Diag", "probes: %d ok, %d not ok (%s); /reload to save", ok, fail, ctx)
  return ok, fail
end

function ns.StartProbes()
  local db = HardCountersDiagDB
  db.probes = type(db.probes) == "table" and db.probes or {}
  local p = db.probes
  p.funcs, p.events, p.strings = p.funcs or {}, p.events or {}, p.strings or {}
  p.loading, p.links, p.missingEvents = p.loading or {}, p.links or {}, p.missingEvents or {}
  -- HC-42 (c): counts carry across loads; how it registered is this load's
  p.editMode = type(p.editMode) == "table" and p.editMode or {}
  editMode = p.editMode
  editMode.reg, editMode.hook = nil, nil
  local okE, errE = pcall(listenEditMode)
  if not okE then B.Log("warn", "Diag", "Edit Mode probe failed: %s", tostring(errE)) end
  local okT, errT = pcall(startTravel, p)
  if not okT then B.Log("warn", "Diag", "travel sampler failed to start: %s", tostring(errT)) end
  local f = CreateFrame("Frame")
  for _, ev in ipairs(EVENTS) do
    local ok
    if IS_UNIT_EVENT[ev] and f.RegisterUnitEvent then ok = pcall(f.RegisterUnitEvent, f, ev, "player")
    else ok = pcall(f.RegisterEvent, f, ev) end
    if not ok then p.missingEvents[ev] = true end
  end
  local autoRan, combatRan = false, false
  f:SetScript("OnEvent", function(_, event, ...)
    local ok, err = pcall(recordEvent, event, ...)
    if not ok then B.Log("warn", "Diag", "probe %s failed: %s", event, tostring(err)) end
    if event == "LOADING_SCREEN_ENABLED" or event == "LOADING_SCREEN_DISABLED" then onLoading(event) end
    if event == "UNIT_SPELLCAST_SUCCEEDED" then pcall(travelCast, ...) end
    if event == "PLAYER_ENTERING_WORLD" then pcall(hookEditMode) end   -- the manager frame may load late
    -- CS-1: are stat values secret in combat? Run the probes once per login/reload a moment into the first fight.
    if event == "PLAYER_REGEN_DISABLED" and not combatRan then
      combatRan = true
      B.Wow.after(2, function()
        local okRun, errRun = pcall(ns.RunProbes)
        if not okRun then B.Log("warn", "Diag", "combat probe run failed: %s", tostring(errRun)) end
      end)
    end
    -- the first in-game run never pressed "Run probes": run the function probes once per login/reload by themselves
    -- ... and again on each entry into an instance (run 2: nobody pressed it inside the dungeon either)
    local inside = false
    if event == "PLAYER_ENTERING_WORLD" then
      local okI, kind = pcall(B.Wow.instanceType)
      inside = okI and kind ~= nil and kind ~= "none"
    end
    if event == "PLAYER_ENTERING_WORLD" and (not autoRan or inside) then
      autoRan = true
      B.Wow.after(10, function()
        local okRun, errRun = pcall(ns.RunProbes)
        if not okRun then B.Log("warn", "Diag", "automatic probe run failed: %s", tostring(errRun)) end
      end)
    end
  end)
end

function ns.ProbesText()
  local p = HardCountersDiagDB.probes
  if not p then return "probes not started" end
  local out = {}
  local lr = p.lastRun
  out[#out + 1] = lr and format("last run %s: %d ok, %d not ok (%s)", ns.clock(lr.t), lr.ok, lr.other, lr.ctx)
    or "function probes not run yet: press Run probes"
  out[#out + 1] = ""
  out[#out + 1] = "FUNCTIONS"
  for _, pr in ipairs(FUNCS) do
    local h = p.funcs[pr[1]]
    local r = h and h[#h]
    out[#out + 1] = format("  %-44s %s", pr[1], r and (r.status .. "  " .. tostring(r.detail)) or "-")
  end
  out[#out + 1] = ""
  out[#out + 1] = "EVENTS (fires by instance type; arg types of the latest sample)"
  for _, ev in ipairs(EVENTS) do
    local e = p.events[ev]
    if p.missingEvents[ev] then
      out[#out + 1] = format("  %-34s MISSING (RegisterEvent failed)", ev)
    elseif e then
      local fires = {}
      for k, v in pairs(e.fires) do fires[#fires + 1] = k .. "=" .. v end
      table.sort(fires)
      local m = {}
      for k, v in pairs(e.matched) do m[#m + 1] = k .. "=" .. v end
      out[#out + 1] = format("  %-34s %s  sig=%s%s%s", ev, table.concat(fires, " "), tostring(e.sig),
        e.secretArgs > 0 and ("  SECRET x" .. e.secretArgs) or "",
        (#m > 0 or e.unmatched > 0) and ("  matched{" .. table.concat(m, " ") .. "} unmatched=" .. e.unmatched) or "")
      if e.arg1 then
        local a = {}
        for k, v in pairs(e.arg1) do a[#a + 1] = tostring(k) .. "=" .. v end
        table.sort(a)
        out[#out] = out[#out] .. "  arg1{" .. table.concat(a, " ") .. "}"
      end
    else
      out[#out + 1] = format("  %-34s (not seen)", ev)
    end
  end
  local L = p.loading
  out[#out + 1] = ""
  out[#out + 1] = format("LOADING SCREENS: %d seen, %d with OnUpdate frames during them, max %d frames",
    L.screens or 0, L.withFrames or 0, L.maxFrames or 0)
  out[#out + 1] = "ITEM LINK FIELDS FILLED (field numbers after the item ID: count)"
  for shape, n in pairs(p.links) do out[#out + 1] = format("  [%s]: %d", shape, n) end
  out[#out + 1] = ""
  out[#out + 1] = "GLOBAL STRINGS"
  for _, name in ipairs(STRINGS) do out[#out + 1] = format("  %-38s %s", name, tostring(p.strings[name] or "-")) end
  return table.concat(out, "\n")
end
