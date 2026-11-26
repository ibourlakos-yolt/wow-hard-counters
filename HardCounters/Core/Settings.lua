-- Settings defaults (pure data). AceDB owns HardCountersSettings (UI/Options.lua); statistics never live there.
-- Modules read ns.settings at call time, because a profile switch replaces the table.
local ADDON, ns = ...

ns.SETTINGS_DEFAULTS = {
  profile = {
    weekGrain = "week",        -- "week" (ISO, Monday) or "resetweek"; the UI's default "this week" (decided 2026-11-14)
    maxRuns = 500,             -- sessions (run records) kept; Options, History: 100 to 2000 (200 before 0.4.0; ~2.6 KB each)
    -- (0.4.0, the user: "the aggregating policy of older counts: make it configurable") how long the fine grains are
    -- kept before only their roll-ups remain (months, years, lifetime are always kept); Options, History
    historyDays = 90,          -- days of daily totals for a tracker whose history goes on without a choice (14 before)
    hourKeep = 48,             -- hours of hourly totals (Detailed): 24, 48, 168 (a week) or 336
    weekKeep = "2y",           -- weekly totals (Detailed): "1y", "2y", "5y"
    -- the run panel's and the live number's settings: boards (v2 M5) read them once, to seed the Run and Pocket boards
    -- (UI/BoardModel.lua Seed); nothing writes them any more. The panels themselves were deleted (HC-24).
    runPanel = { shown = true, locked = false, scale = 1, headline = nil, compact = false, width = nil, height = nil },
    runPanelPos = nil,
    windows = nil,             -- per window: { pos, width, height, scale, locked, shown }; "_main" = shared frame (no size: it follows its tab)
    liveNumber = { shown = false, locked = false, scale = 1, view = nil },
    liveNumberPos = nil,
    ldb = true,                -- publish LibDataBroker objects (Titan Panel, ElvUI, ...)
    -- LibDBIcon's: hide, minimapPos (UI/Minimap.lua). Its own default angle is 225 for every addon, so an undragged
    -- button there hides under another (BugSack's, 2026-11-15); start somewhere quieter.
    minimap = { hide = false, minimapPos = 290 },
    autoInstanceRuns = true,   -- entering an instance starts a run, leaving saves it (HC-2a, DESIGN §16.3)
    boardMoveKey = "CTRL",     -- held over a locked board on the HUD: drag it. "SHIFT", "CTRL", "ALT" or "NONE"
    tabLabels = "both",       -- the Hard Counters window's bottom tabs: "both" (icon and title), "title", "icon" (HC-69)
  },
}

--- A plain copy of the defaults' profile (tests and the fallback when AceDB is missing).
function ns.DefaultProfile()
  return ns.U.deepcopy(ns.SETTINGS_DEFAULTS.profile)
end
