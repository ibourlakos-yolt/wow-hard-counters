-- luacheck config for Hard Counters. WoW globals are allowed only where listed, per file group, so a new game call
-- can't slip in unnoticed. When you add one, add a row to docs/WOW_API.md (HC-5).
std = "lua51"
max_line_length = 160
codes = true
ignore = {
  "212/self",   -- unused self in methods
  "211/_.*",    -- unused locals prefixed with _
  "212/_.*",    -- unused args prefixed with _
  "21[12]/ADDON", -- the addon name vararg (local ADDON, ns = ...) is often unused
}
exclude_files = {
  "dist/**",
  ".luarocks/**",
  "HardCounters/Libs/**",     -- third-party and embedded libraries, kept verbatim
  "packs/**",                  -- each pack lints with its own .luacheckrc (packs/<Pack>/tools/lint.ps1)
  "SavedVariables/**",        -- junction to WoW's SavedVariables (tools/link-sv.ps1), git-ignored
}

local AL = { "LibStub" }

files["HardCounters/Locale/**"] = { read_globals = AL }
files["HardCounters/Core/**"] = { read_globals = {} }   -- engine files: no game globals unless listed below
files["HardCounters/Core/Init.lua"] = { read_globals = AL, globals = { "HardCounters" } }
files["HardCounters/Core/Callbacks.lua"] = { read_globals = AL }
files["HardCounters/Core/Events.lua"] = { read_globals = { "CreateFrame" } }
files["HardCounters/Core/Engine.lua"] = { read_globals = AL, globals = { "HardCountersDB" } }
-- The engine's adapter: every game function the engine calls goes through ns.wow (Core/WoW.lua).
files["HardCounters/Core/WoW.lua"] = {
  read_globals = {
    "GetServerTime", "GetTime", "debugprofilestop", "date", "C_Timer", "GetLocale", "issecretvalue", "geterrorhandler",
    "UnitGUID", "UnitClass", "UnitName", "GetRealmName", "UnitFactionGroup", "GetBuildInfo", "GetCurrentRegion",
    "UnitIsAFK", "Enum", "C_Map", "IsInInstance", "GetInstanceInfo", "InCombatLockdown", "C_AddOns",
    "C_EncodingUtil",
    "hooksecurefunc", "GetCursorInfo", "ClearCursor", "C_Reputation", "C_Item", "C_SkillInfo",
  },
}

-- UI files use frame APIs directly.
-- Basics (HC-21): a module written against the public API only, like a pack.
files["HardCounters/Basics/**"] = {
  read_globals = { "HardCounters", "GetTime", "GetMoney", "UnitXP", "UnitXPMax", "UnitLevel", "GetXPExhaustion", "C_Timer" },
}

files["HardCounters/UI/CopyBox.lua"] = { read_globals = { "CreateFrame", "UIParent", "ChatFontNormal", "UISpecialFrames", "tinsert" } }
files["HardCounters/UI/Slash.lua"] = {
  read_globals = { "DEFAULT_CHAT_FRAME" },
  globals = { "SLASH_HARDCOUNTERS1", "SLASH_HARDCOUNTERS2", "SlashCmdList" },
}
files["HardCounters/UI/Options.lua"] = { read_globals = AL }
files["HardCounters/UI/RunCommands.lua"] = { read_globals = { "StaticPopup_Show" }, globals = { "StaticPopupDialogs" } }
files["HardCounters/UI/Widgets.lua"] = { read_globals = { "CreateFrame", "UIParent", "GameTooltip" } }
files["HardCounters/UI/Windows.lua"] = { read_globals = { "CreateFrame", "UIParent", "UISpecialFrames", "tinsert", "GameTooltip" } }
files["HardCounters/UI/Stints.lua"] = { read_globals = { "C_Item", "GetItemInfo" } }
files["HardCounters/UI/Broker.lua"] = {
  read_globals = { "LibStub", "IsShiftKeyDown", "IsControlKeyDown", "CreateFrame", "UIParent", "GetCursorPosition" },
}
-- Boards (v2 M5): the model is pure; the frames and menus use frame APIs and static popups.
files["HardCounters/UI/BoardModel.lua"] = { read_globals = {} }
files["HardCounters/UI/Menu.lua"] = { read_globals = { "CreateFrame", "UIParent", "UISpecialFrames", "tinsert", "GameTooltip" } }
files["HardCounters/UI/Trackers.lua"] = { read_globals = { "CreateFrame", "GameTooltip" } }
files["HardCounters/UI/Browser.lua"] = { read_globals = { "CreateFrame", "GameTooltip", "GetCursorPosition", "ChatFontNormal" } }
files["HardCounters/UI/ReportTab.lua"] = { read_globals = { "CreateFrame", "UIParent", "ChatFontNormal", "GetCursorPosition" } }
files["HardCounters/UI/Help.lua"] = { read_globals = { "CreateFrame", "UIParent", "UISpecialFrames", "tinsert" } }
files["HardCounters/UI/Packs.lua"] = { read_globals = { "CreateFrame", "C_Timer" } }
files["HardCounters/UI/Overview.lua"] = { read_globals = { "CreateFrame", "C_Timer" } }
files["HardCounters/UI/OptionsTab.lua"] = { read_globals = { "C_Timer" } }
files["HardCounters/UI/Explorer.lua"] = { read_globals = { "C_Timer" } }
files["HardCounters/UI/BoardCatalog.lua"] = { read_globals = {} }
files["HardCounters/UI/BoardDialog.lua"] = { read_globals = { "CreateFrame", "UIParent", "UISpecialFrames", "tinsert" } }
files["HardCounters/UI/BoardsTab.lua"] = { read_globals = { "CreateFrame", "GameTooltip", "C_Timer" } }
files["HardCounters/UI/Guide.lua"] = { read_globals = { "CreateFrame", "C_Timer" } }
files["HardCounters/UI/Welcome.lua"] = { read_globals = { "CreateFrame", "UIParent", "UISpecialFrames", "tinsert", "C_Timer" } }
files["HardCounters/UI/Boards.lua"] = {
  read_globals = { "CreateFrame", "UIParent", "C_Timer", "UISpecialFrames", "tinsert", "StaticPopup_Show", "YES", "NO", "OKAY",
    "CANCEL", "GetCursorPosition" },
  globals = { "StaticPopupDialogs" },
}
files["HardCounters/UI/Minimap.lua"] = { read_globals = { "LibStub" } }

files["HardCounters_Diagnostics/**"] = {
  read_globals = { "HardCounters", "CreateFrame", "date", "UIErrorsFrame", "C_Timer", "UIParent", "GameFontHighlightSmall",
    "UISpecialFrames", "tinsert", "C_Map" },
  globals = { "HardCountersDiagDB", "SLASH_HCDIAG1", "SlashCmdList" },
}

files["tools/**"] = { read_globals = { "LibStub" } }

-- Tests run under busted / plain Lua 5.1.
files["tests/**"] = { std = "+busted", ignore = { "311" } } -- tests reuse result variables
