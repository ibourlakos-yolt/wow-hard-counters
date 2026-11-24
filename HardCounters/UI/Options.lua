-- Options: AceDB profiles for settings and an AceConfig panel in the game's options (DESIGN §15 Q4).
-- v1 is toggles and a few choices (UI rule: simple on the surface, deep on demand). Ace types never leave this file.
local ADDON, ns = ...

local L = ns.L
local optionGroups = {}   -- extra groups added by other UI files: ns.AddOptions(key, group or function() -> group)

function ns.AddOptions(key, group)
  optionGroups[key] = group
end

local function refresh()
  ns.settings = ns.settingsDB.profile
  if ns.OnSettingsChanged then ns.OnSettingsChanged() end
end

local function options()
  local s = function() return ns.settings end
  local args = {
    general = {
      type = "group", name = L["General"], order = 1, inline = true,
      args = {
        weekGrain = {
          type = "select", order = 1, name = L["\"This week\" means"],
          values = { week = L["Monday to Sunday (ISO week)"], resetweek = L["Weekly reset to reset"] },
          get = function() return s().weekGrain end,
          set = function(_, v) s().weekGrain = v; refresh() end,
        },
        ldb = {
          type = "toggle", order = 2, name = L["Data broker feed"], width = "full",
          desc = L["Show Hard Counters in Titan Panel, ElvUI and other data broker displays (needs /reload to remove)."],
          get = function() return s().ldb end,
          set = function(_, v) s().ldb = v; refresh() end,
        },
        autoInstanceRuns = {
          type = "toggle", order = 3, name = L["Record dungeon runs by themselves"], width = "full",
          desc = L["Entering an instance starts a run named after it; leaving saves it to the Runs tab "
            .. "(5 active minutes or more). Runs you start yourself are never touched."],
          get = function() return s().autoInstanceRuns ~= false end,
          set = function(_, v) s().autoInstanceRuns = v and true or false end,
        },
      },
    },
  }
  local order = 10
  for key, group in pairs(optionGroups) do
    if type(group) == "function" then group = group() end   -- built at each open (e.g. the list of windows)
    group.order = group.order or order
    order = order + 1
    args[key] = group
  end
  return { type = "group", name = L["Hard Counters"], args = args }
end

function ns.InitSettings()
  local AceDB = LibStub("AceDB-3.0", true)
  if not AceDB then
    ns.settings = ns.DefaultProfile()
    ns.charSettings, ns.globalSettings, ns.allCharSettings, ns.charKey = {}, {}, {}, "?"
    return
  end
  ns.settingsDB = AceDB:New("HardCountersSettings", ns.SETTINGS_DEFAULTS, true)
  ns.settings = ns.settingsDB.profile
  -- (HC-74) boards are the character's own: AceDB's per-character table ("Name - Realm"), every character's
  -- (for copying a board from another one) and the account's (one-time notes)
  ns.charSettings = ns.settingsDB.char
  ns.globalSettings = ns.settingsDB.global
  ns.allCharSettings = ns.settingsDB.sv.char or {}
  ns.charKey = ns.settingsDB.keys and ns.settingsDB.keys.char or "?"
  ns.settingsDB.RegisterCallback(ns, "OnProfileChanged", refresh)
  ns.settingsDB.RegisterCallback(ns, "OnProfileCopied", refresh)
  ns.settingsDB.RegisterCallback(ns, "OnProfileReset", refresh)

  local AceConfig = LibStub("AceConfig-3.0", true)
  local AceConfigDialog = LibStub("AceConfigDialog-3.0", true)
  local AceDBOptions = LibStub("AceDBOptions-3.0", true)
  if AceConfig and AceConfigDialog then
    AceConfig:RegisterOptionsTable(ADDON, options)
    AceConfigDialog:AddToBlizOptions(ADDON, L["Hard Counters"])
    if AceDBOptions then
      AceConfig:RegisterOptionsTable(ADDON .. "_Profiles", AceDBOptions:GetOptionsTable(ns.settingsDB))
      AceConfigDialog:AddToBlizOptions(ADDON .. "_Profiles", L["Profiles"], L["Hard Counters"])
    end
  end
end

--- A standalone AceConfig window: works whether or not Settings.OpenToCategory is allowed on this client (12.x
--- changed it). The same panel is also listed in the game's options under AddOns.
function ns.OpenOptions()
  local AceConfigDialog = LibStub("AceConfigDialog-3.0", true)
  if AceConfigDialog then AceConfigDialog:Open(ADDON) end
end

ns.AddSlash("options", function() ns.OpenOptions() end, L["open the options"])
