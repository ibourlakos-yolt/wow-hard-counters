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
local trLast = { ok = false, gap = false, x = 0, y = 0, z = 0, m = 0, t = 0, carriedT = -1000 }
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

-- TR-6 (Traveler; agreed 2026-11-22, notes packs/Traveler/docs/DESIGN.md §0.2 a, c, d, §0.3): deaths, spacebar
-- jumps, forms, speed boosts and dungeons. Kept in HardCountersDiagDB.probes.tr6, apart from TR-5's counts (not run
-- yet when this was built). Game IDs (spell, aura, map, instance, form), game speeds, counts and yard buckets only:
-- never a coordinate, never a name (dungeon subzone texts are compared in memory and never saved).
local t6                                           -- P().tr6 once started
local T6_V = 1
local t6Fall = { on = false, t = 0, press = -1000, withPress = false, mounted = false }
local t6Rooms = {}                                 -- [instance ID] = { n = distinct subzone texts, [text] = true }: memory only
local t6LastSub = {}                               -- [instance ID] = the subzone text of the last sample: memory only
local t6InstT = 0                                  -- the time of the last instance sample (speed x time estimate)
local t6Death                                      -- the open death's notes, or nil
local t6Corpse = { d = nil, dSwap = nil, first = nil }
local t6Run = { v = nil }                          -- the latest plain run speed, out of combat
local T6_CAP = 200                                 -- distinct keys per table (casts, auras, speeds)

local function t6Inc(tbl, key, n)
  if tbl[key] == nil then
    tbl._n = (tbl._n or 0) + 1
    if tbl._n > T6_CAP then tbl._over = (tbl._over or 0) + 1; return end
  end
  tbl[key] = (tbl[key] or 0) + (n or 1)
end

local function t6Bucket(yd)
  if yd < 8 then return "<8" elseif yd < 40 then return "8-40" elseif yd < 100 then return "40-100"
  elseif yd < 200 then return "100-200" elseif yd < 400 then return "200-400" elseif yd < 800 then return "400-800"
  elseif yd < 1600 then return "800-1600" end
  return "1600+"
end

local function t6AirBucket(s)
  if s < 0.5 then return "<0.5" elseif s < 1 then return "0.5-1" elseif s < 2 then return "1-2"
  elseif s < 4 then return "2-4" end
  return "4+"
end

local function t6Plain(fn, ...)
  if type(fn) ~= "function" then return nil, "missing" end
  local ok, v = pcall(fn, ...)
  if not ok then return nil, "error" end
  if W.isSecret(v) then return nil, "secret" end
  return v, v == nil and "nil" or type(v)
end

-- The player's helpful aura spell IDs right now, sorted, as text ("" when none). Out of combat only (documented
-- secret when restricted); IDs only.
local function t6Auras()
  local ids = {}
  local get = G("C_UnitAuras.GetAuraDataByIndex")
  if type(get) == "function" then
    for i = 1, 40 do
      local ok, a = pcall(get, "player", i, "HELPFUL")
      if not ok or type(a) ~= "table" then break end
      local id = a.spellId
      if type(id) == "number" and not W.isSecret(id) then ids[#ids + 1] = id end
    end
  else
    local buff = G("UnitBuff")
    if type(buff) ~= "function" then return "noapi" end
    for i = 1, 40 do
      local r = { pcall(buff, "player", i) }
      if not r[1] or r[2] == nil then break end
      local id = r[11]
      if type(id) == "number" and not W.isSecret(id) then ids[#ids + 1] = id end
    end
  end
  table.sort(ids)
  return table.concat(ids, ",", 1, math.min(#ids, 16))
end

-- What the player is doing, in the words of the jump rules: taxi, swim, air (already falling), mounted, ground
local function t6Ctx()
  if t6Plain(_G.UnitOnTaxi, "player") == true then return "taxi" end
  if t6Plain(_G.IsSwimming) == true then return "swim" end
  if t6Plain(_G.IsFalling) == true then return "air" end
  if t6Plain(_G.IsMounted) == true then return "mounted" end
  return "ground"
end

local function t6Note(word)
  if not t6Death or #t6Death >= 24 then return end
  t6Death[#t6Death + 1] = word
end

-- (c) the secure post-hook on the jump key: presses by context; a press from the ground or a mount arms a take-off
local function t6Press()
  if not t6 then return end
  local ctx = t6Ctx()
  t6Inc(t6.presses, ctx)
  if ctx == "ground" or ctx == "mounted" then t6Fall.press = W.time() end
end

-- (c) take-offs and landings from IsFalling, every tick: a take-off within 0.75 s of a press is a jump, else a fall
local function t6Falling(now, falling, taxi, inCombat)
  if taxi then if falling then t6Inc(t6.air, "onTaxi") end return end
  if falling and not t6Fall.on then
    t6Fall.on, t6Fall.t = true, now
    t6Fall.withPress = now - t6Fall.press <= 0.75
    t6Fall.mounted = t6Plain(_G.IsMounted) == true
    t6Inc(t6.takeoffs, (t6Fall.withPress and "press" or "nopress") .. ":" .. (t6Fall.mounted and "mounted" or "foot"))
  elseif not falling and t6Fall.on then
    t6Fall.on = false
    local dur = now - t6Fall.t
    local kind = t6Fall.withPress and "jump" or "fall"
    t6Inc(t6.air, kind .. ":" .. t6AirBucket(dur))
    t6.airMax[kind] = math.max(t6.airMax[kind] or 0, dur)
    -- a long fall: which auras were up (Slow Fall, Levitate make it a float)
    if dur >= 2 and not inCombat then
      local auras = t6Auras()
      t6Inc(t6.longFallAuras, auras ~= "" and auras or "none")
    end
  end
end

-- (d) the shapeshift form, once a second: index, form ID and the form's spell, plain or secret, by combat
local function t6Form(inCombat)
  local fnF, fnId, fnInfo = _G.GetShapeshiftForm, _G.GetShapeshiftFormID, _G.GetShapeshiftFormInfo
  if type(fnF) ~= "function" and type(fnId) ~= "function" then t6Inc(t6.forms, "missing"); return nil end
  local idx, hi = t6Plain(fnF)
  local id, hid = t6Plain(fnId)
  local spell = "-"
  if type(idx) == "number" and idx > 0 and type(fnInfo) == "function" then
    local ok, _, _, _, sp = pcall(fnInfo, idx)
    spell = ok and (W.isSecret(sp) and "secret" or tostring(sp)) or "error"
  end
  local key = format("idx=%s id=%s spell=%s:%s", idx ~= nil and tostring(idx) or hi, id ~= nil and tostring(id) or hid,
    spell, inCombat and "in" or "out")
  t6Inc(t6.forms, key)
  return id or idx
end

-- (d) the speeds the game gives (out of combat: secret in it), snapshotted every 4 s by state, with the auras up
local function t6Speeds(inCombat, form, snapshot)
  local fn = _G.GetUnitSpeed
  if type(fn) ~= "function" then t6Inc(t6.speedAnswers, "missing"); return end
  local ok, cur, run, flight, swim = pcall(fn, "player")
  if not ok then t6Inc(t6.speedAnswers, "error"); return end
  if W.isSecret(run) or W.isSecret(cur) then t6Inc(t6.speedAnswers, inCombat and "secretIn" or "secretOut"); return end
  t6Inc(t6.speedAnswers, inCombat and "plainIn" or "plainOut")
  if type(run) == "number" then t6Run.v = run end
  if not snapshot or inCombat or type(run) ~= "number" then return end
  local state = t6Ctx()
  if form and form ~= 0 then state = state .. ":form" .. tostring(form) end
  local function num(v) return (type(v) == "number" and not W.isSecret(v)) and v or -1 end
  local key = format("%s run=%.2f flight=%.2f swim=%.2f", state, run, num(flight), num(swim))
  t6Inc(t6.speeds, key)
  if t6.speeds[key] then t6.speedAuras[key] = t6Auras() end
end

-- (d) is an aura readable in combat? the first helpful aura by index, and by spell ID (the last ID seen out of combat)
local t6AuraId
local function t6AuraProbe(inCombat)
  local side = inCombat and "in:" or "out:"
  local get = G("C_UnitAuras.GetAuraDataByIndex")
  if type(get) == "function" then
    local ok, a = pcall(get, "player", 1, "HELPFUL")
    local kind = not ok and "error" or W.isSecret(a) and "secret" or type(a)
    if ok and type(a) == "table" then
      if W.isSecret(a.spellId) then kind = "table:secretId"
      elseif type(a.spellId) == "number" and not inCombat then t6AuraId = a.spellId end
    end
    t6Inc(t6.auraIdx, side .. kind)
  else
    t6Inc(t6.auraIdx, side .. "missing")
  end
  local byId = G("C_UnitAuras.GetPlayerAuraBySpellID")
  if type(byId) ~= "function" then t6Inc(t6.auraById, side .. "missing"); return end
  if not t6AuraId then return end
  local ok, a = pcall(byId, t6AuraId)
  local kind = not ok and "error" or W.isSecret(a) and "secret" or type(a)
  if ok and type(a) == "table" and W.isSecret(a.spellId) then kind = "table:secretId" end
  t6Inc(t6.auraById, side .. kind)
end

-- §0.3: inside an instance, once a second: what answers, per instance ID (subzone text present or not, rooms by
-- distinct texts this session, map, map position, area IDs, UnitPosition), and GetUnitSpeed x time as the estimate
local function t6Instance(now, inCombat)
  local okI, kind = pcall(W.instanceType)
  if not okI or kind == nil or kind == "none" then t6InstT = 0; return end
  local fnI = _G.GetInstanceInfo
  local id = "?"
  if type(fnI) == "function" then
    local ok, _, _, _, _, _, _, _, iid = pcall(fnI)
    if ok and type(iid) == "number" and not W.isSecret(iid) then id = iid end
  end
  local e = t6.inst[id]
  if not e then
    if (t6.inst._n or 0) >= 40 then return end
    t6.inst._n = (t6.inst._n or 0) + 1
    e = { kind = tostring(kind) }
    t6.inst[id] = e
  end
  local function inc(k) e[k] = (e[k] or 0) + 1 end
  inc("ticks")
  if inCombat then inc("fight") end
  local sub = t6Plain(_G.GetSubZoneText)
  if type(sub) == "string" and sub ~= "" then
    inc("named")
    local set = t6Rooms[id]
    if not set then set = { n = 0 }; t6Rooms[id] = set end
    if not set[sub] then set[sub] = true; set.n = set.n + 1 end
    e.rooms = math.max(e.rooms or 0, set.n)
  else
    inc("empty")
  end
  if t6LastSub[id] ~= nil and t6LastSub[id] ~= sub then inc("subChanges") end
  t6LastSub[id] = sub or ""
  local map = t6Plain(G("C_Map.GetBestMapForUnit"), "player")
  if type(map) == "number" then
    inc("map"); e.mapId = map
    local p = t6Plain(G("C_Map.GetPlayerMapPosition"), map, "player")
    if p ~= nil then
      inc("mapPos")
      local ids = t6Plain(G("C_MapExplorationInfo.GetExploredAreaIDsAtPosition"), map, p)
      if type(ids) == "table" and #ids > 0 then inc("areaIds") end
    end
  end
  local fnPos = _G.UnitPosition
  if type(fnPos) == "function" then
    local ok, x = pcall(fnPos, "player")
    if ok and x ~= nil then inc(W.isSecret(x) and "posSecret" or "posPlain") end
  end
  local fn = _G.GetUnitSpeed
  if type(fn) == "function" then
    local ok, cur = pcall(fn, "player")
    if ok and W.isSecret(cur) then inc(inCombat and "speedSecretIn" or "speedSecretOut")
    elseif ok and type(cur) == "number" then
      inc(inCombat and "speedPlainIn" or "speedPlainOut")
      if cur > 0 then
        inc("moving")
        local dt = t6InstT > 0 and math.min(now - t6InstT, 2) or 0
        e.estYd = (e.estYd or 0) + cur * dt
      end
    end
  end
  t6InstT = now
end

-- (a) while a ghost, every second: the corpse position plain, nil or secret; its distance from the player both ways
-- round (UnitPosition's order against the world position's is unproven), kept in memory for the death's notes
local function t6Ghost()
  if t6Plain(_G.UnitIsGhost, "player") ~= true then return end
  local fn = G("C_DeathInfo.GetCorpseMapPosition")
  if type(fn) ~= "function" then t6Inc(t6.corpse, "missing"); return end
  local map = t6Plain(G("C_Map.GetBestMapForUnit"), "player")
  if type(map) ~= "number" then t6Inc(t6.corpse, "nomap"); return end
  local ok, p = pcall(fn, map)
  if not ok then t6Inc(t6.corpse, "error"); return end
  if W.isSecret(p) then t6Inc(t6.corpse, "secret"); return end
  if p == nil then t6Inc(t6.corpse, "nil"); return end
  t6Inc(t6.corpse, "plain")
  local toWorld = G("C_Map.GetWorldPosFromMapPos")
  if type(toWorld) ~= "function" then return end
  local okW, _, wp = pcall(toWorld, map, p)
  if not okW or type(wp) ~= "table" then t6Inc(t6.corpse, "noworld"); return end
  local wx, wy = wp.x, wp.y
  if type(wx) ~= "number" and type(wp.GetXY) == "function" then wx, wy = wp:GetXY() end
  local okP, px, py = pcall(_G.UnitPosition, "player")
  if not okP or type(px) ~= "number" or type(wx) ~= "number" or W.isSecret(px) or W.isSecret(wx) then return end
  local dx, dy, sx, sy = px - wx, py - wy, px - wy, py - wx
  t6Corpse.d, t6Corpse.dSwap = sqrt(dx * dx + dy * dy), sqrt(sx * sx + sy * sy)
  if not t6Corpse.first then t6Corpse.first = math.min(t6Corpse.d, t6Corpse.dSwap) end
end

-- (a) deaths: each event with the ghost flag, in order, for the last five deaths; jumps and loading screens while
-- dead or a ghost are noted in between (yards bucketed)
local DEATH_WORDS = { PLAYER_DEAD = "DEAD", PLAYER_ALIVE = "ALIVE", PLAYER_UNGHOST = "UNGHOST", CONFIRM_XP_LOSS = "XPLOSS",
  AREA_SPIRIT_HEALER_IN_RANGE = "SH_IN", AREA_SPIRIT_HEALER_OUT_OF_RANGE = "SH_OUT", CORPSE_IN_RANGE = "C_IN",
  CORPSE_OUT_OF_RANGE = "C_OUT", RESURRECT_REQUEST = "RES", LOADING_SCREEN_ENABLED = "LOAD" }
local function t6DeathEvent(event)
  if not t6 then return end
  local word = DEATH_WORDS[event]
  if not word then return end
  if word == "LOAD" then t6Note(word); return end
  local g = t6Plain(_G.UnitIsGhost, "player")
  local tag = word .. ":g" .. (g == true and "1" or g == false and "0" or "?")
  if word == "DEAD" then
    t6Death = { tag }
    t6Corpse.d, t6Corpse.dSwap, t6Corpse.first = nil, nil, nil
    return
  end
  if not t6Death then t6Inc(t6.deathStray, tag); return end
  t6Note(tag)
  if word == "UNGHOST" or (word == "ALIVE" and g == false) then
    if t6Corpse.d then
      t6Note("corpse=" .. t6Bucket(t6Corpse.d) .. "/" .. t6Bucket(t6Corpse.dSwap) .. " first=" .. t6Bucket(t6Corpse.first))
    end
    local list = t6.deaths
    list[#list + 1] = table.concat(t6Death, " ")
    while #list > 5 do table.remove(list, 1) end
    t6Death = nil
  end
end

-- (d) a plain cast: counted by spell ID; half a second later (out of combat) whether it changed the run speed and
-- left an aura of its ID (the boost and form lists come from these)
local function t6Cast(spellID, inCombat)
  if not t6 then return end
  t6Inc(inCombat and t6.castsIn or t6.casts, spellID)
  local before = t6Run.v
  if not W.after then return end
  W.after(0.5, function()
    local byId = G("C_UnitAuras.GetPlayerAuraBySpellID")
    local okC, c = pcall(W.inCombat)
    local nowIn = okC and c or false
    if type(byId) == "function" then
      local ok, a = pcall(byId, spellID)
      local kind = not ok and "error" or W.isSecret(a) and "secret" or type(a)
      t6Inc(t6.castAura, (nowIn and "in:" or "out:") .. kind)
      if kind == "table" then t6Inc(t6.castWithAura, spellID) end
    end
    if nowIn then return end
    local fn = _G.GetUnitSpeed
    local ok, _, run = pcall(fn, "player")
    if ok and type(run) == "number" and not W.isSecret(run) and type(before) == "number" and math.abs(run - before) > 0.05 then
      t6.speedCasts[spellID] = format("%.2f>%.2f", before, run)
    end
  end)
end

local function t6ZoneEvent()
  if not t6 then return end
  local okI, kind = pcall(W.instanceType)
  if okI and kind ~= nil and kind ~= "none" then t6Inc(t6.zoneEventsInside, tostring(kind)) end
end

local t6Ticks = 0
local function t6Tick(now, inCombat, falling, taxi)
  if not t6 then return end
  t6Ticks = t6Ticks + 1
  t6Falling(now, falling, taxi, inCombat)
  if t6Ticks % 4 ~= 0 then return end
  local form = t6Form(inCombat)
  t6Speeds(inCombat, form, t6Ticks % 16 == 0)
  if t6Ticks % 16 == 0 then t6AuraProbe(inCombat) end
  t6Instance(now, inCombat)
  t6Ghost()
end

local function startTr6(p)
  if type(p.tr6) ~= "table" or p.tr6.v ~= T6_V then p.tr6 = { v = T6_V } end
  t6 = p.tr6
  for _, k in ipairs({ "presses", "takeoffs", "air", "airMax", "longFallAuras", "forms", "speedAnswers", "speeds",
    "speedAuras", "auraIdx", "auraById", "inst", "corpse", "deaths", "deathStray", "casts", "castsIn", "castAura",
    "castWithAura", "speedCasts", "zoneEventsInside" }) do
    t6[k] = type(t6[k]) == "table" and t6[k] or {}
  end
  t6Fall.on, t6Death, t6InstT = false, nil, 0
  -- (c) the jump key: does the function exist, and does a secure post-hook take (this load's answer)
  if type(_G.JumpOrAscendStart) ~= "function" then t6.hook = "missing"
  elseif type(_G.hooksecurefunc) ~= "function" then t6.hook = "no hooksecurefunc"
  else
    local ok, err = pcall(_G.hooksecurefunc, "JumpOrAscendStart", function() pcall(t6Press) end)
    t6.hook = ok and "ok" or ("error:" .. tostring(err):sub(1, 60))
  end
end

-- TR-5: what the player was doing at a jump (flags read only then: jumps are rare)
local function trJumpCtx(inCombat)
  if inCombat then return "combat" end
  local fnM, fnS = _G.IsMounted, _G.IsSwimming
  local okM, mounted = false, nil
  if type(fnM) == "function" then okM, mounted = pcall(fnM) end
  if okM and mounted == true then return "mounted" end
  local okS, swim = false, nil
  if type(fnS) == "function" then okS, swim = pcall(fnS) end
  if okS and swim == true then return "swimming" end
  return "foot"
end

-- A jump: counted by kind and by context; the plain spell cast in the 5 s before it, if any (a hearth's cast ends
-- just before its loading screen; TR-1's 2 s window linked none)
local function trJump(kind, inCombat, yd)
  trCount("jump_" .. kind)
  if t6Death then t6Note("J:" .. kind .. ":" .. (yd and t6Bucket(yd) or "-")) end   -- TR-6: the release jump
  local ctx = kind .. ":" .. trJumpCtx(inCombat)
  trv.jumpCtx[ctx] = (trv.jumpCtx[ctx] or 0) + 1
  if trCast.id and W.time() - trCast.t <= 5 then
    local key = kind .. ":" .. tostring(trCast.id)
    trv.jumpSpells[key] = (trv.jumpSpells[key] or 0) + 1
  end
end

-- TR-5 (a): which numbers name a continent: UnitPosition's 4th value against GetInstanceInfo's instance ID
local function trMapIds(m)
  local fn = _G.GetInstanceInfo
  local inst = "?"
  if type(fn) == "function" then
    local ok, _, _, _, _, _, _, _, id = pcall(fn)
    if ok and type(id) == "number" and not W.isSecret(id) then inst = tostring(id) end
  end
  local key = "pos4=" .. tostring(m) .. " instance=" .. inst
  trv.mapIds[key] = (trv.mapIds[key] or 0) + 1
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
  local okT6 = pcall(t6Tick, now, inCombat, falling, taxi)
  if not okT6 then trCount("t6errors") end
  local fnPos = _G.UnitPosition
  if type(fnPos) ~= "function" then trCount("posMissing"); trLast.ok = false; return end
  local okP, x, y, z, m = pcall(fnPos, "player")
  if not okP then trCount("posError"); trLast.ok = false; return end
  if W.isSecret(x) or W.isSecret(y) or W.isSecret(m) then
    trCount(inCombat and "posSecretIn" or "posSecretOut"); trLast.ok = false; return
  end
  -- (TR-5 a) a nil read (a loading screen) keeps the last good position: the next read is compared across the gap
  if type(x) ~= "number" or type(y) ~= "number" then trCount("posNil"); trLast.gap = true; return end
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
      if trLast.gap then trCount("mapChangeAcrossGap") end
      trMapIds(m)
      trJump("map", inCombat)
    elseif dt > 0 then
      local dx, dy = x - trLast.x, y - trLast.y
      local d = sqrt(dx * dx + dy * dy)
      local v = d / dt
      -- carried: the position moves while your own speed is 0 (out of combat: speed is secret in combat)
      local carried = false
      if not taxi and v > 1 and not trLast.gap then
        local fnSpeed = _G.GetUnitSpeed
        if type(fnSpeed) == "function" then
          local okS, cur = pcall(fnSpeed, "player")
          carried = okS and type(cur) == "number" and not W.isSecret(cur) and cur == 0
        end
        if carried then trCount("carriedTicks"); trLast.carriedT = now end
      end
      if taxi then
        trCount("taxiTicks")
        if d > 0.5 then trCount("taxiMoved") end
        if d <= 200 and v > (trv.vmaxTaxi or 0) then trv.vmaxTaxi = v end
      elseif trLast.gap then
        -- (TR-5 a) same continent across a loading screen: a teleport (hearth, portal) if it moved, with its yards
        if d > 40 then
          trJump("gap", inCombat, d)
          trv.gapYdMax = math.max(trv.gapYdMax or 0, d)
          trv.gapYdSum = (trv.gapYdSum or 0) + d
        else
          trCount("gapStill")
        end
      elseif d > 40 then
        trJump("long", inCombat, d)                  -- (TR-5 b) any gap length: no more "speeds" of 744 yd/s
      elseif dt <= 0.6 and d >= 8 and v > 20 then
        if carried then trCount("jump_shortCarried") else trJump("short", inCombat, d) end   -- (TR-5 b) boats aren't blinks
      elseif d > 0 and v > (trv.vmaxOther or 0) then
        trv.vmaxOther = v
      end
    end
  end
  trLast.ok, trLast.gap, trLast.x, trLast.y, trLast.z, trLast.m, trLast.t = true, false, x, y, z, m, now
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
  if type(spellID) == "number" then
    trCast.id, trCast.t = spellID, W.time()
    pcall(t6Cast, spellID, inCombat)
  end
end
-- The player's area ID right now and whether its name is the subzone shown: id (or nil), "match" / "nomatch", and
-- whether the game shows a subzone at all. Names compared here, never kept.
local function trAreaNow()
  local best, pos = G("C_Map.GetBestMapForUnit"), G("C_Map.GetPlayerMapPosition")
  local at, info, sub = G("C_MapExplorationInfo.GetExploredAreaIDsAtPosition"), G("C_Map.GetAreaInfo"), G("GetSubZoneText")
  if type(at) ~= "function" or type(best) ~= "function" or type(pos) ~= "function" then return nil, "missing", false end
  local okS, subText = false, nil
  if type(sub) == "function" then okS, subText = pcall(sub) end
  local named = okS and type(subText) == "string" and not W.isSecret(subText) and subText ~= ""
  local okM, map = pcall(best, "player")
  if not okM or type(map) ~= "number" then return nil, "nomap", named end
  local okP, p = pcall(pos, map, "player")
  if not okP or p == nil then return nil, "nopos", named end
  local okA, ids = pcall(at, map, p)
  if not okA or type(ids) ~= "table" or #ids == 0 then return nil, "nil", named end
  local found
  for _, id in ipairs(ids) do
    if type(id) == "number" and type(info) == "function" then
      local okN, name = pcall(info, id)
      if okN and named and name == subText then found = id end
    end
  end
  if found then return found, "match", named end
  return ids[#ids], "nomatch", named
end

-- TR-5 (c): on every zone change, how often the area ID answers, split by whether a subzone is shown
local function travelArea()
  if not trv then return end
  local _, how, named = trAreaNow()
  local key = how .. (named and ":named" or ":unnamed")
  trv.areaAnswers[key] = (trv.areaAnswers[key] or 0) + 1
end

-- TR-5 (d): at a flight master, the taxi map's nodes by state (current, reachable, unreachable), and the legacy count
local function travelTaxiMap()
  if not trv then return end
  local all = G("C_TaxiMap.GetAllTaxiNodes")
  local mapFn = G("GetTaxiMapID")
  local map
  if type(mapFn) == "function" then
    local ok, m = pcall(mapFn)
    if ok and type(m) == "number" then map = m end
  end
  if not map then
    local best = G("C_Map.GetBestMapForUnit")
    if type(best) == "function" then
      local ok, m = pcall(best, "player")
      if ok and type(m) == "number" then map = m end
    end
  end
  local t = { opens = ((trv.taxiMap and trv.taxiMap.opens) or 0) + 1, map = map, taxiMapID = type(mapFn) == "function" }
  if type(all) == "function" and map then
    local ok, list = pcall(all, map)
    if ok and type(list) == "table" then
      t.n = #list
      for _, node in ipairs(list) do
        local st = type(node) == "table" and node.state
        local k = st == 0 and "current" or st == 1 and "reachable" or st == 2 and "unreachable" or "other"
        t[k] = (t[k] or 0) + 1
      end
    else
      t.n = ok and describe(list) or "error"
    end
  else
    t.n = "missing"
  end
  local num = G("NumTaxiNodes")
  if type(num) == "function" then
    local ok, n = pcall(num)
    t.legacy = ok and n or "error"
  end
  trv.taxiMap = t
end
ns.TravelTick, ns.TravelCast, ns.TravelArea, ns.TravelTaxiMap = travelTick, travelCast, travelArea, travelTaxiMap
ns.Tr6Press, ns.Tr6DeathEvent = t6Press, t6DeathEvent

-- TR-5 starts the counts afresh: TR-1's jump counts mixed boat ticks in (notes api-surface §2026-11-21 evening)
local TRAVEL_V = 5
local function startTravel(p)
  if type(p.travel) ~= "table" or p.travel.v ~= TRAVEL_V then p.travel = { v = TRAVEL_V } end
  trv = p.travel
  trv.flags = type(trv.flags) == "table" and trv.flags or {}
  trv.jumpSpells = type(trv.jumpSpells) == "table" and trv.jumpSpells or {}
  trv.jumpCtx = type(trv.jumpCtx) == "table" and trv.jumpCtx or {}
  trv.mapIds = type(trv.mapIds) == "table" and trv.mapIds or {}
  trv.areaAnswers = type(trv.areaAnswers) == "table" and trv.areaAnswers or {}
  trLast.ok, trLast.gap = false, false
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
  local function list(t)
    local out = {}
    for k, v in pairs(t or {}) do out[#out + 1] = tostring(k) .. "=" .. tostring(v) end
    table.sort(out)
    return table.concat(out, " ")
  end
  local spells = {}
  for k, v in pairs(trv.jumpSpells) do spells[#spells + 1] = k .. "=" .. v end
  table.sort(spells)
  -- TR-5: gaps, contexts, continent numbers, area answers, the last flight master
  local tm = trv.taxiMap
  spells[#spells + 1] = format("] TR-5: gap jumps=%d still=%d yd max/sum=%.0f/%.0f acrossGapMapChange=%d shortCarried=%d"
    .. " ctx[%s] mapIds[%s] areas[%s] taxiMap[%s",
    n("jump_gap"), n("gapStill"), n("gapYdMax"), n("gapYdSum"), n("mapChangeAcrossGap"), n("jump_shortCarried"),
    list(trv.jumpCtx), list(trv.mapIds), list(trv.areaAnswers), tm and list(tm) or "not opened")
  return "ok", format("ticks=%d avgms=%.3f pos plain out/in=%d/%d secret out/in=%d/%d nil=%d z zero/other/falling=%d/%d/%d"
    .. " taxi ticks/moved=%d/%d vmax taxi/other=%.1f/%.1f carried=%d mapChange=%d afterCarried=%d"
    .. " jumps short/long/map=%d/%d/%d cast plain out/in=%d/%d secret out/in=%d/%d spells[%s]"
    .. " flags(plainOut/secretOut/plainIn/secretIn) %s",
    n("ticks"), n("ticks") > 0 and n("ms") / n("ticks") or 0, n("posPlainOut"), n("posPlainIn"), n("posSecretOut"),
    n("posSecretIn"), n("posNil"), n("zZero"), n("zNonZero"), n("zMovesFalling"), n("taxiTicks"), n("taxiMoved"),
    n("vmaxTaxi"), n("vmaxOther"), n("carriedTicks"), n("mapChange"), n("mapChangeAfterCarried"), n("jump_short"),
    n("jump_long"), n("jump_map"), n("castPlainOut"), n("castPlainIn"), n("castSecretOut"), n("castSecretIn"),
    table.concat(spells, " "), table.concat(flags, " ")):sub(1, 2400)
end }

-- TR-6 rows: summaries of probes.tr6 (the tables themselves are in the saved file, whole)
local function t6List(t)
  local out = {}
  for k, v in pairs(t or {}) do
    if type(k) ~= "string" or k:sub(1, 1) ~= "_" then
      out[#out + 1] = tostring(k) .. "=" .. (type(v) == "number" and v % 1 ~= 0 and format("%.1f", v) or tostring(v))
    end
  end
  table.sort(out)
  if t and t._over then out[#out + 1] = "(+" .. t._over .. " over the cap)" end
  return table.concat(out, " ")
end

FUNCS[#FUNCS + 1] = { "TR-6 dungeons", function()
  if not t6 then return "missing", "not started" end
  local parts = {}
  for id, e in pairs(t6.inst) do
    if id ~= "_n" and type(e) == "table" then
      local function n(k) return e[k] or 0 end
      parts[#parts + 1] = format("inst=%s %s ticks=%d fight=%d sub named/empty=%d/%d rooms=%d changes=%d map=%d(%s)"
        .. " mapPos=%d areaIds=%d pos=%d/%d speed plainOut/secretOut/plainIn/secretIn=%d/%d/%d/%d moving=%d estYd=%.0f",
        tostring(id), tostring(e.kind), n("ticks"), n("fight"), n("named"), n("empty"), n("rooms"), n("subChanges"),
        n("map"), tostring(e.mapId or "-"), n("mapPos"), n("areaIds"), n("posPlain"), n("posSecret"), n("speedPlainOut"),
        n("speedSecretOut"), n("speedPlainIn"), n("speedSecretIn"), n("moving"), n("estYd"))
    end
  end
  table.sort(parts)
  if #parts == 0 then return "ok", "no instance sampled yet" end
  return "ok", (table.concat(parts, " | ") .. " | zone events inside: " .. t6List(t6.zoneEventsInside)):sub(1, 1200)
end }

FUNCS[#FUNCS + 1] = { "TR-6 forms and speeds", function()
  if not t6 then return "missing", "not started" end
  local fns = format("GetShapeshiftForm=%s GetShapeshiftFormID=%s GetShapeshiftFormInfo=%s GetPlayerAuraBySpellID=%s",
    describe(_G.GetShapeshiftForm), describe(_G.GetShapeshiftFormID), describe(_G.GetShapeshiftFormInfo),
    describe(G("C_UnitAuras.GetPlayerAuraBySpellID")))
  local speeds = {}
  for k, v in pairs(t6.speeds) do
    if k ~= "_n" and k ~= "_over" then speeds[#speeds + 1] = format("%s x%d [%s]", k, v, tostring(t6.speedAuras[k] or "")) end
  end
  table.sort(speeds)
  return "ok", format("%s | forms[%s] speedAnswers[%s] auraIdx[%s] auraById[%s] castAura[%s] speedCasts[%s]"
    .. " castWithAura[%s] casts=%d castsIn=%d | speeds: %s", fns, t6List(t6.forms), t6List(t6.speedAnswers),
    t6List(t6.auraIdx), t6List(t6.auraById), t6List(t6.castAura), t6List(t6.speedCasts), t6List(t6.castWithAura),
    t6.casts._n or 0, t6.castsIn._n or 0, table.concat(speeds, "; ")):sub(1, 2400)
end }

FUNCS[#FUNCS + 1] = { "TR-6 jumps", function()
  if not t6 then return "missing", "not started" end
  return "ok", format("JumpOrAscendStart=%s hook=%s presses[%s] takeoffs[%s] air[%s] airMax[%s] longFallAuras[%s]",
    describe(_G.JumpOrAscendStart), tostring(t6.hook), t6List(t6.presses), t6List(t6.takeoffs), t6List(t6.air),
    t6List(t6.airMax), t6List(t6.longFallAuras)):sub(1, 1200)
end }

FUNCS[#FUNCS + 1] = { "TR-6 deaths", function()
  if not t6 then return "missing", "not started" end
  return "ok", format("GetCorpseMapPosition=%s corpse[%s] stray[%s] open=%s deaths: %s",
    describe(G("C_DeathInfo.GetCorpseMapPosition")), t6List(t6.corpse), t6List(t6.deathStray),
    t6Death and table.concat(t6Death, " ") or "no", table.concat(t6.deaths, " || ")):sub(1, 1500)
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

-- TR-5 (c): the Exploration achievement category (its sub-categories: one per continent, one achievement per zone),
-- and whether the current subzone's area ID is a criterion's asset ID in one of them, so "x of y explored" and
-- visits share numbers; else whether a criterion has its name (compared, never kept). Category titles are client
-- strings and are kept; criterion names are not.
FUNCS[#FUNCS + 1] = { "TR-5 exploration", function()
  local list, cinfo, cnum, ainfo, crit = G("GetCategoryList"), G("GetCategoryInfo"), G("GetCategoryNumAchievements"),
    G("GetAchievementInfo"), G("GetAchievementCriteriaInfo")
  if type(list) ~= "function" or type(cinfo) ~= "function" or type(cnum) ~= "function" or type(ainfo) ~= "function" then
    return "missing", format("GetCategoryList=%s GetCategoryInfo=%s GetCategoryNumAchievements=%s GetAchievementInfo=%s",
      describe(list), describe(cinfo), describe(cnum), describe(ainfo))
  end
  local okL, cats = pcall(list)
  if not okL or type(cats) ~= "table" then return "error", "GetCategoryList: " .. describe(cats) end
  -- the category titled like the game's own string, else "Exploration"; and its children
  local wanted = G("ACHIEVEMENT_CATEGORY_EXPLORATION") or "Exploration"
  local root
  for _, id in ipairs(cats) do
    local okI, title, parent = pcall(cinfo, id)
    if okI and title == wanted and (parent == -1 or parent == nil or parent == 0) then root = id end
  end
  if not root then return "ok", format("%d categories, none titled %s", #cats, tostring(wanted)) end
  local area, how = trAreaNow()
  local sub = G("GetSubZoneText")
  local okS, subText = false, nil
  if type(sub) == "function" then okS, subText = pcall(sub) end
  local parts, total, assetHit, nameHit = {}, 0, nil, nil
  for _, id in ipairs(cats) do
    local okI, title, parent = pcall(cinfo, id)
    if okI and (id == root or parent == root) then
      local okN, n = pcall(cnum, id)
      n = okN and type(n) == "number" and n or 0
      total = total + n
      parts[#parts + 1] = format("%s=%d", tostring(title), n)
      for i = 1, math.min(n, 120) do
        local okA, achID = pcall(ainfo, id, i)
        if okA and type(achID) == "number" and type(crit) == "function" then
          local okC, numC = pcall(G("GetAchievementNumCriteria") or function() return 0 end, achID)
          for j = 1, (okC and type(numC) == "number" and math.min(numC, 60) or 0) do
            local r = { pcall(crit, achID, j) }
            if r[1] then
              if area and r[9] == area then assetHit = achID end
              if okS and subText ~= "" and r[2] == subText then nameHit = achID end
            end
          end
        end
      end
    end
  end
  return "ok", format("root=%d achievements=%d %s | area=%s (%s) assetMatch=%s nameMatch=%s", root, total,
    table.concat(parts, " "), tostring(area), tostring(how), tostring(assetHit or "no"), tostring(nameHit or "no")):sub(1, 700)
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
  -- TR-6: deaths (order and counts; the ghost flag at each is in probes.tr6.deaths) and shapeshift forms
  "PLAYER_DEAD", "PLAYER_ALIVE", "PLAYER_UNGHOST", "CONFIRM_XP_LOSS", "AREA_SPIRIT_HEALER_IN_RANGE",
  "AREA_SPIRIT_HEALER_OUT_OF_RANGE", "CORPSE_IN_RANGE", "CORPSE_OUT_OF_RANGE", "RESURRECT_REQUEST",
  "UPDATE_SHAPESHIFT_FORM", "UPDATE_SHAPESHIFT_FORMS",
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
  local okT6, errT6 = pcall(startTr6, p)
  if not okT6 then B.Log("warn", "Diag", "TR-6 probes failed to start: %s", tostring(errT6)) end
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
    if event == "ZONE_CHANGED" or event == "ZONE_CHANGED_INDOORS" or event == "ZONE_CHANGED_NEW_AREA" then pcall(travelArea) end
    if event == "TAXIMAP_OPENED" then pcall(travelTaxiMap) end
    if DEATH_WORDS[event] then pcall(t6DeathEvent, event) end
    if event == "ZONE_CHANGED" or event == "ZONE_CHANGED_INDOORS" or event == "ZONE_CHANGED_NEW_AREA" then pcall(t6ZoneEvent) end
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
  if ns.HC65Lines then ns.HC65Lines(out) end
  return table.concat(out, "\n")
end

---------------------------------------------------------------------------
-- HC-65 (DESIGN §17.7): the window probe before the main-window rebuild. `/hc diag ui` opens a test panel the size
-- of the Hard Counters window; nothing here runs before that. Its measurements go to HardCountersDiagDB.probes.hc65
-- (read from the saved file after /reload):
--   a. LargeSideTabButtonTemplate (on Forever a Frame with SidePanelTabButtonMixin, not a Button) creates, and
--      what it is made of; a column of 12 hangs off the panel's right edge, as on the profession window;
--   b. an icon texture on PanelTabButtonTemplate tabs stays beside its label through PanelTemplates_TabResize (the
--      template's OnShow and OnEvent), select and deselect: the three label options of DESIGN §17.2;
--   c. SetClampRectInsets keeps that column on screen: the panel placed flush right by SetPoint without and with
--      the insets, then every drag the player makes;
--   d. the run card (HardCountersRunCard: MEDIUM, no SetToplevel) against HardCountersMain: frame levels when the
--      card shows, on clicks on either, and whenever the order changes while this panel is open.
-- Geometry only (sizes, offsets, frame levels), never names or where the player is.
---------------------------------------------------------------------------
local UI_SIDE_TABS, UI_ICON, UI_GAP, UI_ROOM = 12, 16, 3, 4
local UI_W, UI_H = 640, 566          -- the Hard Counters window's size today (DESIGN §7.1)
local UI_ICONS = {
  "Interface\\Icons\\INV_Misc_Coin_01", "Interface\\Icons\\INV_Misc_Note_01", "Interface\\Icons\\Trade_Engineering",
  "Interface\\Icons\\INV_Misc_Bag_07", "Interface\\Icons\\INV_Misc_PocketWatch_01", "Interface\\Icons\\INV_Misc_Book_09",
  "Interface\\Icons\\INV_Misc_Map_01", "Interface\\Icons\\Spell_Nature_TimeStop", "Interface\\Icons\\INV_Misc_Gear_01",
  "Interface\\Icons\\Ability_Hunter_Pathfinding", "Interface\\Icons\\Spell_Holy_BorrowedTime",
  "Interface\\Icons\\INV_Misc_QuestionMark",
}
local UI_TABS = {     -- the bottom tabs, one per label option
  { label = "Overview", icon = UI_ICONS[2], mode = "icon and title" },
  { label = "Boards", icon = UI_ICONS[7], mode = "icon only" },
  { label = "Trackers", mode = "title only" },
  { label = "Runs", icon = UI_ICONS[5], mode = "icon and title" },
}
local TAB_RESIZE, TAB_SELECT, TAB_DESELECT = "PanelTemplates_TabResize", "PanelTemplates_SelectTab", "PanelTemplates_DeselectTab"
local uiPanel

local function hc65()
  local p = P()
  p.hc65 = type(p.hc65) == "table" and p.hc65 or {}
  return p.hc65
end

local function num(v) return type(v) == "number" and v or nil end
local function r1(v) return num(v) and math.floor(v * 10 + 0.5) / 10 or describe(v) end

-- a method that may be missing or fail: its results, or nil
local function m(obj, method, ...)
  local fn = type(obj) == "table" and obj[method]
  if type(fn) ~= "function" then return nil end
  local r = { pcall(fn, obj, ...) }
  if not r[1] then return nil end
  return select(2, unpack(r))
end

local function keepLast(list, item, n)
  list[#list + 1] = item
  while #list > n do table.remove(list, 1) end
end

-- measure once the layout has settled (geometry is resolved on the next frame)
local function later(fn)
  C_Timer.After(0.2, function()
    local ok, err = pcall(fn)
    if not ok then B.Log("warn", "Diag", "HC-65 probe: %s", tostring(err)) end
  end)
end

-- a. ---------------------------------------------------------------------

local function buildSideTabs(f)
  local a = { tabs = 0 }
  hc65().a = a
  f.sideTabs = {}
  local okT, first = pcall(CreateFrame, "Frame", nil, f, "LargeSideTabButtonTemplate")
  if not okT or type(first) ~= "table" then
    a.created, a.error = false, tostring(first):sub(1, 160)
    return
  end
  a.created = true
  a.objectType = m(first, "GetObjectType")
  a.mouseAtCreate = m(first, "IsMouseEnabled")
  a.parts, a.methods = {}, {}
  for _, k in ipairs({ "Background", "Icon", "Mask", "SelectedTexture", "TabGlow", "HighlightTexture" }) do
    a.parts[k] = type(first[k]) == "table"
  end
  for _, k in ipairs({ "SetChecked", "SetFillToInterior", "SetCustomOnMouseUpHandler", "OnEnter" }) do
    a.methods[k] = type(first[k]) == "function"
  end
  a.backgroundAtlas = m(first.Background, "GetAtlas")
  local atlasInfo = G("C_Texture.GetAtlasInfo")
  if type(atlasInfo) == "function" then
    local ok, info = pcall(atlasInfo, "common-sidetab")
    a.atlas = (ok and type(info) == "table") and { w = r1(info.width), h = r1(info.height) } or "none"
  end
  local tabs = { first }
  for _ = 2, UI_SIDE_TABS do
    local ok, t = pcall(CreateFrame, "Frame", nil, f, "LargeSideTabButtonTemplate")
    if ok and type(t) == "table" then tabs[#tabs + 1] = t end
  end
  local function pick(tab)
    for _, t in ipairs(tabs) do m(t, "SetChecked", t == tab) end
    a.clicks = (a.clicks or 0) + 1
    a.lastClicked = tab.hcIndex
  end
  for i, t in ipairs(tabs) do
    t.hcIndex = i
    t.tooltipText = (i == #tabs) and "Diagnostics" or ("Side tab " .. i)    -- the mixin's OnEnter shows it
    if type(t.Icon) == "table" then m(t.Icon, "SetTexture", UI_ICONS[(i - 1) % #UI_ICONS + 1]) end
    m(t, "SetFillToInterior", true)          -- as the profession window's tabs
    t:ClearAllPoints()
    if i == 1 then t:SetPoint("TOPLEFT", f, "TOPRIGHT", 0, -60)
    else t:SetPoint("TOPLEFT", tabs[i - 1], "BOTTOMLEFT", 0, -2) end
    if not m(t, "IsMouseEnabled") then m(t, "EnableMouse", true) end
    local onUp = function(self, button) if button == "LeftButton" then pick(self) end end
    if type(t.SetCustomOnMouseUpHandler) == "function" then t:SetCustomOnMouseUpHandler(onUp)
    else t:SetScript("OnMouseUp", onUp) end
  end
  m(first, "SetChecked", true)
  a.tabs = #tabs
  f.sideTabs = tabs
end

local function measureSide(f)
  local a = hc65().a
  local t = f.sideTabs and f.sideTabs[1]
  if not (a and t) then return end
  a.size = { w = r1(m(t, "GetWidth")), h = r1(m(t, "GetHeight")) }
  a.visible = m(t, "IsVisible")
  if type(t.Icon) == "table" then
    a.icon = { w = r1(m(t.Icon, "GetWidth")), h = r1(m(t.Icon, "GetHeight")), texture = tostring(m(t.Icon, "GetTexture")),
      visible = m(t.Icon, "IsVisible") }
  end
  -- how many sit beside the panel: tabs whose bottom is above the panel's bottom
  local bottom, fit = num(m(f, "GetBottom")), 0
  for _, x in ipairs(f.sideTabs) do
    local b = num(m(x, "GetBottom"))
    if bottom and b and b >= bottom then fit = fit + 1 end
  end
  a.fitBesidePanel, a.panelHeight = fit, r1(m(f, "GetHeight"))
end

-- b. ---------------------------------------------------------------------

-- Blizzard's OnShow / OnEvent resize the tab with the parent's tabPadding (nil here); this runs after them, as the
-- window host's sizeTab does, with room for the icon
local function sizeIconTab(b)
  local pad = UI_ROOM
  if b.hcIcon then pad = pad + UI_ICON + (b.hcLabel ~= "" and UI_GAP or 0) end
  pcall(G(TAB_RESIZE), b, pad)
  if type(b.Text) == "table" then b.Text:SetWidth(0) end
  b.hcResized = (b.hcResized or 0) + 1
end

local function selectBottom(f, pos)
  for i, b in ipairs(f.bottomTabs) do
    pcall(G(i == pos and TAB_SELECT or TAB_DESELECT), b)
    if b.hcIcon and b.hcLabel == "" then          -- icon only: follow the label's own offsets (selected sits lower)
      b.hcIcon:ClearAllPoints()
      b.hcIcon:SetPoint("CENTER", b, "CENTER", 0, i == pos and -3 or 2)
    end
  end
  f.bottomSelected = pos
end

local function measureBottom(f, when)
  local b65 = hc65().b
  if not (b65 and f.bottomTabs) then return end
  local out = {}
  for _, b in ipairs(f.bottomTabs) do
    local t, icon = b.Text, b.hcIcon
    local bl, br = num(m(b, "GetLeft")), num(m(b, "GetRight"))
    local r = { mode = b.hcMode, selected = f.bottomSelected == b.hcPos, w = r1(m(b, "GetWidth")), resized = b.hcResized }
    local ok = true
    if type(t) == "table" and b.hcLabel ~= "" then
      r.truncated = m(t, "IsTruncated")
      local tl, tr = num(m(t, "GetLeft")), num(m(t, "GetRight"))
      if tr and br then r.textToRight = r1(br - tr); ok = ok and br - tr >= 0 end
      if icon then
        local ir = num(m(icon, "GetRight"))
        if ir and tl then r.gap = r1(tl - ir); ok = ok and math.abs(tl - ir - UI_GAP) <= 1 end
      end
      ok = ok and not r.truncated
    end
    if icon then
      local il, ir = num(m(icon, "GetLeft")), num(m(icon, "GetRight"))
      if il and ir and bl and br then
        r.iconFromLeft, r.iconToRight = r1(il - bl), r1(br - ir)
        ok = ok and il >= bl and ir <= br
      end
      r.iconVisible = m(icon, "IsVisible")
    end
    r.ok = ok
    out[#out + 1] = r
  end
  b65[when] = out
end

local function buildBottomTabs(f)
  local b65 = { created = 0 }
  hc65().b = b65
  f.bottomTabs = {}
  if type(G(TAB_SELECT)) ~= "function" or type(G(TAB_RESIZE)) ~= "function" then
    b65.error = "PanelTemplates functions missing"
    return
  end
  local tabs = f.bottomTabs
  for i, def in ipairs(UI_TABS) do
    local ok, b = pcall(CreateFrame, "Button", "HardCountersDiagProbeTab" .. i, f, "PanelTabButtonTemplate")
    if ok and type(b) == "table" then
      local pos = #tabs + 1
      b.hcPos, b.hcTitle, b.hcMode = pos, def.label, def.mode
      b.hcLabel = def.mode == "icon only" and "" or def.label
      b:SetText(b.hcLabel)
      if def.icon then
        local icon = b:CreateTexture(nil, "ARTWORK")
        icon:SetSize(UI_ICON, UI_ICON)
        icon:SetTexture(def.icon)
        icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        if b.hcLabel ~= "" then
          -- the label moves right by half the icon, so icon and label stay centred together; Blizzard's
          -- select and deselect read these offsets
          icon:SetPoint("RIGHT", b.Text, "LEFT", -UI_GAP, 0)
          b.selectedTextX, b.deselectedTextX = (UI_ICON + UI_GAP) / 2, (UI_ICON + UI_GAP) / 2
        end
        b.hcIcon = icon
      end
      b:HookScript("OnShow", sizeIconTab)
      b:HookScript("OnEvent", sizeIconTab)
      if def.mode == "icon only" then          -- the title as a tooltip
        b:HookScript("OnEnter", function(self)
          local tip = G("GameTooltip")
          if type(tip) == "table" then tip:SetOwner(self, "ANCHOR_TOP"); tip:SetText(self.hcTitle); tip:Show() end
        end)
        b:HookScript("OnLeave", function()
          local tip = G("GameTooltip")
          if type(tip) == "table" then tip:Hide() end
        end)
      end
      b:SetScript("OnClick", function()
        selectBottom(f, pos)
        later(function() measureBottom(f, "afterClick") end)
      end)
      b:ClearAllPoints()
      if pos == 1 then b:SetPoint("TOPLEFT", f, "BOTTOMLEFT", 11, 2)
      else b:SetPoint("LEFT", tabs[pos - 1], "RIGHT", 3, 0) end
      tabs[pos] = b
      sizeIconTab(b)
    else
      b65.error = format("tab %d: %s", i, tostring(b):sub(1, 160))
    end
  end
  b65.created = #tabs
  selectBottom(f, 1)
end

-- c. ---------------------------------------------------------------------

local function clampState(f)
  local tab = f.sideTabs and f.sideTabs[1]
  local sr, fr, cr = num(m(UIParent, "GetRight")), num(m(f, "GetRight")), tab and num(m(tab, "GetRight"))
  local insets = { m(f, "GetClampRectInsets") }
  for i, v in ipairs(insets) do insets[i] = r1(v) end
  local r = { screenRight = r1(sr), panelRight = r1(fr), columnRight = r1(cr), insets = insets }
  if sr and cr then r.columnOnScreen = cr <= sr + 0.5 end
  if sr and fr then r.panelAtRightEdge = math.abs(sr - fr) < 1.5 end
  return r
end

local function flushRight(f)
  f:ClearAllPoints()
  f:SetPoint("RIGHT", UIParent, "RIGHT", 0, 0)
end

local function runClampTest(f)
  local c = hc65().c
  local tab = f.sideTabs and f.sideTabs[1]
  local colW = tab and num(m(tab, "GetWidth")) or 0
  c.columnWidth = r1(colW)
  m(f, "SetClampRectInsets", 0, 0, 0, 0)
  flushRight(f)
  later(function()
    c.plain = clampState(f)                          -- no insets: the column should hang off the screen
    m(f, "SetClampRectInsets", 0, colW, 0, 0)        -- the clamp rect reaches over the column
    flushRight(f)
    later(function()
      c.inset = clampState(f)                        -- with insets: did SetPoint get clamped?
      f:ClearAllPoints()
      f:SetPoint("CENTER", UIParent, "CENTER", -120, 0)
      -- hide and show: the tabs' OnShow resizes them again (ours after the template's own resize)
      f:Hide()
      f:Show()
      later(function()
        measureBottom(f, "afterReshow")
        B.Log("info", "Diag", "HC-65 probe measured; drag the panel against the right edge, then /reload to save")
      end)
    end)
  end)
end

-- d. ---------------------------------------------------------------------

local function maxLevel(frame, depth)
  local lvl = num(m(frame, "GetFrameLevel")) or 0
  if depth > 0 and type(frame.GetChildren) == "function" then
    for _, ch in ipairs({ frame:GetChildren() }) do
      if type(ch) == "table" then lvl = math.max(lvl, maxLevel(ch, depth - 1)) end
    end
  end
  return lvl
end

local function overlaps(a, b)
  local al, ar, at, ab = num(m(a, "GetLeft")), num(m(a, "GetRight")), num(m(a, "GetTop")), num(m(a, "GetBottom"))
  local bl, br, bt, bb = num(m(b, "GetLeft")), num(m(b, "GetRight")), num(m(b, "GetTop")), num(m(b, "GetBottom"))
  if not (al and ar and at and ab and bl and br and bt and bb) then return nil end
  return al < br and bl < ar and ab < bt and bb < at
end

-- where the card is against the window: above everything of the window, under the window frame itself, or between
local function cardOrder()
  local main, card = G("HardCountersMain"), G("HardCountersRunCard")
  if type(main) ~= "table" or type(card) ~= "table" then return nil end
  if not (m(main, "IsShown") and m(card, "IsShown")) then return nil end
  local cl, ml, mm = num(m(card, "GetFrameLevel")) or 0, num(m(main, "GetFrameLevel")) or 0, maxLevel(main, 3)
  local where = cl > mm and "card above window" or (cl < ml and "card under window" or "card between")
  return where, { cardLevel = cl, mainLevel = ml, mainTopLevel = mm, overlap = overlaps(card, main),
    cardToplevel = m(card, "IsToplevel"), cardStrata = m(card, "GetFrameStrata"), mainStrata = m(main, "GetFrameStrata") }
end

local function recordCard(why)
  local d = hc65().d
  local where, info = cardOrder()
  if not where then return end
  info.why, info.where, info.t = why, where, W.now()
  keepLast(d.events, info, 12)
  d.latest = where
end

-- hook the window and the card once each, when they exist (the card is made on the first click on a run)
local function hookCard()
  local d = hc65().d
  local main, card = G("HardCountersMain"), G("HardCountersRunCard")
  if type(main) == "table" and not main.hc65Hooked and type(main.HookScript) == "function" then
    main.hc65Hooked = true
    main:HookScript("OnMouseDown", function() later(function() recordCard("clicked the window") end) end)
  end
  if type(card) == "table" and not card.hc65Hooked and type(card.HookScript) == "function" then
    card.hc65Hooked = true
    card:HookScript("OnMouseDown", function() later(function() recordCard("clicked the card") end) end)
    card:HookScript("OnShow", function() later(function() recordCard("card shown") end) end)
  end
  d.hookedWindow, d.hookedCard = main and main.hc65Hooked or false, card and card.hc65Hooked or false
  -- any change of order while the panel is open (a click on the window's content raises it too)
  local where = cardOrder()
  if where and where ~= d.lastSeen then
    d.lastSeen = where
    recordCard("order changed")
  end
end

-- the panel ------------------------------------------------------------------

local function buildPanel()
  local okP, f = pcall(CreateFrame, "Frame", "HardCountersDiagUIProbe", UIParent, "ButtonFrameTemplate")
  local h = hc65()
  h.panelTemplate = okP and type(f) == "table"
  if not h.panelTemplate then
    f = CreateFrame("Frame", "HardCountersDiagUIProbe", UIParent)
    local bg = f:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.05, 0.05, 0.07, 0.92)
  end
  f:Hide()
  f:SetSize(UI_W, UI_H)
  f:SetFrameStrata("MEDIUM")
  f:SetToplevel(true)
  f:SetMovable(true)
  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetClampedToScreen(true)
  pcall(G("ButtonFrameTemplate_HidePortrait"), f)
  local title = "HC-65 probe (Hard Counters Diagnostics)"
  if type(f.SetTitle) ~= "function" or not pcall(f.SetTitle, f, title) then
    local tc = f.TitleContainer
    local tt = (type(tc) == "table" and tc.TitleText) or f.TitleText
    if type(tt) == "table" then tt:SetText(title) end
  end
  if type(f.CloseButton) == "table" then f.CloseButton:SetScript("OnClick", function() f:Hide() end) end
  tinsert(UISpecialFrames, "HardCountersDiagUIProbe")
  local text = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  text:SetPoint("TOPLEFT", 24, -72)
  text:SetWidth(UI_W - 48)
  text:SetJustifyH("LEFT")
  text:SetText("1. Hover a tab on the right (a tooltip?) and click two of them.\n\n"
    .. "2. Click each tab along the bottom. Hover the one with only an icon.\n\n"
    .. "3. Drag this panel by its title, hard against the right edge of the screen, and let go.\n\n"
    .. "4. With this panel still open: /hc, Runs tab, click a run (its card opens). Click the Hard Counters "
    .. "window's title bar, then the card's top strip.\n\n"
    .. "5. Take a screenshot (Print Screen), then /reload. The results are in the saved file.")
  f:SetScript("OnDragStart", function(self) self:StartMoving() end)
  f:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    later(function()
      local s = clampState(self)
      s.t = W.now()
      keepLast(hc65().c.drags, s, 6)
    end)
  end)
  local acc = 0
  f:SetScript("OnUpdate", function(_, elapsed)
    acc = acc + (elapsed or 0)
    if acc < 0.5 then return end
    acc = 0
    local ok, err = pcall(hookCard)
    if not ok then B.Log("warn", "Diag", "HC-65 card probe: %s", tostring(err)) end
  end)
  buildSideTabs(f)
  buildBottomTabs(f)
  return f
end

--- /hc diag ui: open the HC-65 probe panel (or close it). Each opening measures again.
function ns.ProbeUI()
  if uiPanel and uiPanel:IsShown() then uiPanel:Hide(); return false end
  local h = hc65()
  local version, build = W.build()
  h.t, h.client = W.now(), format("%s.%s", tostring(version), tostring(build))
  h.screen = { w = r1(m(UIParent, "GetWidth")), h = r1(m(UIParent, "GetHeight")), scale = r1(m(UIParent, "GetEffectiveScale")) }
  h.c = { drags = {} }
  h.d = { events = {} }
  h.opened = (h.opened or 0) + 1
  if not uiPanel then uiPanel = buildPanel() end
  uiPanel:ClearAllPoints()
  uiPanel:SetPoint("CENTER", UIParent, "CENTER", -120, 0)
  uiPanel:Show()
  later(function()
    measureSide(uiPanel)
    measureBottom(uiPanel, "atBuild")
    runClampTest(uiPanel)
  end)
  B.Log("info", "Diag", "HC-65 probe panel open (%s)", ns.contextLine())
  return true
end

-- the probe's results at the end of the Probes tab
local function dumpLines(v, ind, out, depth)
  local keys = {}
  for k in pairs(v) do keys[#keys + 1] = k end
  table.sort(keys, function(x, y) return tostring(x) < tostring(y) end)
  for _, k in ipairs(keys) do
    local x = v[k]
    if type(x) == "table" and depth < 5 then
      out[#out + 1] = ind .. tostring(k) .. ":"
      dumpLines(x, ind .. "  ", out, depth + 1)
    else
      out[#out + 1] = ind .. tostring(k) .. " = " .. tostring(x)
    end
  end
end

function ns.HC65Lines(out)
  local h = HardCountersDiagDB.probes and HardCountersDiagDB.probes.hc65
  out[#out + 1] = ""
  out[#out + 1] = "HC-65 WINDOW PROBE (/hc diag ui)"
  if type(h) ~= "table" then out[#out + 1] = "  not run"; return end
  dumpLines(h, "  ", out, 0)
end
