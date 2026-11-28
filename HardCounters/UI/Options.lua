-- Options: AceDB profiles for settings and an AceConfig panel in the game's options (DESIGN §15 Q4).
-- v1 is toggles and a few choices (UI rule: simple on the surface, deep on demand). Ace types never leave this file.
local ADDON, ns = ...

local L = ns.L
local format = string.format
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
          type = "toggle", order = 3, name = L["Record dungeons as runs by themselves"], width = "full",
          desc = L["Entering an instance starts a run named after it; leaving saves it to the Runs tab "
            .. "(5 active minutes or more). Runs you start yourself are never touched."],
          get = function() return s().autoInstanceRuns ~= false end,
          set = function(_, v) s().autoInstanceRuns = v and true or false end,
        },
      },
    },
    -- luacheck: push no max line length
    -- (0.4.0, the user: how generous the run history can be, and "the aggregating policy of older counts: make them
    -- configurable") how much is kept, and for how long before only the roll-ups remain
    history = {
      type = "group", name = L["History"], order = 2, inline = true,
      args = {
        maxRuns = {
          type = "select", order = 1, name = L["Runs kept"],
          desc = L["The newest runs kept in the Runs tab; older ones are dropped. About 2.6 KB each: 500 take about 1.3 MB. Lowering it drops the oldest when the next one is saved."],
          values = { [100] = "100", [200] = "200", [500] = "500", [1000] = "1000", [2000] = "2000" },
          sorting = { 100, 200, 500, 1000, 2000 },
          get = function() return s().maxRuns or 500 end,
          set = function(_, v) s().maxRuns = v end,
        },
        historyDays = {
          type = "select", order = 2, name = L["Days kept, day by day"],
          desc = L["When a tracker's history goes on without your choice of days (a tile placed, Keep history), it keeps this many days of daily totals. Older days still count in their month, year and lifetime totals. A tracker's own choice (History..., Advanced) wins."],
          values = { [14] = L["14 days"], [30] = L["30 days"], [90] = L["90 days"], [365] = L["365 days"] },
          sorting = { 14, 30, 90, 365 },
          get = function() return ns.DefaultHistoryDays() end,
          set = function(_, v) s().historyDays = v; if ns.Reconcile then ns.Reconcile() end end,
        },
        hourKeep = {
          type = "select", order = 3, name = L["Hours kept, hour by hour (Detailed)"],
          desc = L["A tracker with Detailed history keeps its hourly totals this long; older hours count in their day."],
          values = { [24] = L["24 hours"], [48] = L["48 hours"], [168] = L["a week"], [336] = L["two weeks"] },
          sorting = { 24, 48, 168, 336 },
          get = function() return ns.HOUR_KEEP[s().hourKeep] and s().hourKeep or 48 end,
          set = function(_, v) s().hourKeep = v; if ns.Reconcile then ns.Reconcile() end end,
        },
        weekKeep = {
          type = "select", order = 4, name = L["Weeks kept, week by week (Detailed)"],
          desc = L["A tracker with Detailed history keeps its weekly totals this long; older weeks count in their month and year."],
          values = { ["1y"] = L["one year"], ["2y"] = L["two years"], ["5y"] = L["five years"] },
          sorting = { "1y", "2y", "5y" },
          get = function() return ns.WEEK_KEEP[s().weekKeep] and s().weekKeep or "2y" end,
          set = function(_, v) s().weekKeep = v; if ns.Reconcile then ns.Reconcile() end end,
        },
        dayStart = {
          type = "select", order = 5, name = L["The day ends at"], width = "double",
          desc = L["When \"today\" turns into yesterday, in your computer's local time. Midnight by default; a night player may prefer 4:00 or 6:00. For the whole account; it takes effect at the next /reload or login, and days already kept stay as they were counted."],
          values = function()
            local v = {}
            for h = 0, 23 do v[h] = h == 0 and L["Midnight (local time)"] or format("%02d:00", h) end
            return v
          end,
          sorting = { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23 },
          get = function() return (ns.globalSettings and tonumber(ns.globalSettings.dayStartHour)) or 0 end,
          set = function(_, v)
            if not ns.globalSettings then return end
            ns.globalSettings.dayStartHour = v ~= 0 and v or nil
            if ns.Print then ns.Print(L["The day now ends at %s, from the next /reload or login."], v == 0 and L["midnight"] or format("%02d:00", v)) end
          end,
        },
      },
    },
    diagnostics = {
      type = "group", name = L["Diagnostics"], order = 3, inline = true,
      args = {
        fieldNotes = {
          type = "toggle", order = 1, name = L["Automatic field notes"], width = "full",
          desc = L["At a login, a reload, entering or leaving an instance, a level gained, an error and a logout, Hard Counters notes the moment with a few counts (errors, trackers on, boards on the HUD; never a value or a name). The last 40 go into /hc report. On by default for test versions (alpha, beta) and with Diagnostics loaded."],
          get = function() return ns.FieldNotes and ns.FieldNotes.Enabled() or false end,
          set = function(_, v) if ns.FieldNotes then ns.FieldNotes.SetEnabled(v) end end,
        },
      },
    },
    -- luacheck: pop
  }
  -- (0.4.0) three tabs, the same in the Options tab of the Hard Counters window and in the game's AddOns options:
  -- General (the groups every UI file adds: boards, the window, the minimap button), History, Profiles
  local general = { general = args.general, diagnostics = args.diagnostics }
  local order = 10
  local keys = {}
  for key in pairs(optionGroups) do keys[#keys + 1] = key end
  table.sort(keys)                                            -- (a stable order: pairs() has none)
  for _, key in ipairs(keys) do
    local group = optionGroups[key]
    if type(group) == "function" then group = group() end   -- built at each open (e.g. the list of windows)
    group.order = group.order or order
    order = order + 1
    general[key] = group
  end
  args.diagnostics.order = 90
  local tabs = {
    main = { type = "group", name = L["General"], order = 1, args = general },
    history = { type = "group", name = L["History"], order = 2, args = { history = args.history } },
  }
  local AceDBOptions = LibStub and LibStub("AceDBOptions-3.0", true)
  if AceDBOptions and ns.settingsDB then
    tabs.profiles = AceDBOptions:GetOptionsTable(ns.settingsDB)
    tabs.profiles.order, tabs.profiles.name = 3, L["Profiles"]
  end
  return { type = "group", name = L["Hard Counters"], childGroups = "tab", args = tabs }
end
ns.OptionsTable = options                                        -- (tests)

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
  if AceConfig and AceConfigDialog then
    AceConfig:RegisterOptionsTable(ADDON, options)
    AceConfigDialog:AddToBlizOptions(ADDON, L["Hard Counters"])   -- (Profiles is one of its tabs since 0.4.0)
  end
end

--- The options: the Options tab of the Hard Counters window (0.4.0, the user: "it should no longer be displayed in a
--- separate window"; UI/OptionsTab.lua). Before the window exists (a load error), AceConfig's own window. The same
--- panel is also listed in the game's options under AddOns.
function ns.OpenOptions()
  if ns.ShowOptionsTab and ns.ShowOptionsTab(true) then return end
  local AceConfigDialog = LibStub("AceConfigDialog-3.0", true)
  if AceConfigDialog then AceConfigDialog:Open(ADDON) end
end

ns.AddSlash("options", function() ns.OpenOptions() end, L["the Options tab: every setting"])
