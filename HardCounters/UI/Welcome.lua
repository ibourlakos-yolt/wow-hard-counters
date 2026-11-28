-- The tutorial (the user, 2026-11-24; it replaces HC-74's one-page welcome window). A small window of steps, Back
-- and Next, that walks through Hard Counters where it is: the boards on screen (the first one flashes), a first
-- board for the character's class (one click makes it, from Character Stats' class preset), then the Hard Counters
-- window, opened by the tour on each of its tabs in turn (0.4.0: Boards, Explorer, Packs, Stints, Overview and Options,
-- the packs' tabs, Guide). Since 2026-11-25 nothing is on the HUD at a first setup: the boards step says so, the class-board step
-- puts that one board on screen (the player's click), and the Packs step is where a new player chooses packs.
-- It shows by itself once per account, at the first login that hasn't run it (`ns.globalSettings.tutorialSeen`,
-- set when it opens: closing it early counts), and again from the window's Grand tour button (0.4.0; "Tutorial"
-- before) and /hc tutorial. A new character on an account that has seen it gets HC-74's chat line.
-- DIALOG strata, like the New board dialog; Escape closes it. Everything it says at length is in the Guide tab.
-- luacheck: no max line length (steps of prose: one sentence, one string)
local ADDON, ns = ...

local L, Wd = ns.L, ns.Widgets
local format = string.format

local Tutorial = {}
ns.Tutorial = Tutorial
ns.Welcome = Tutorial                   -- (its name before the tour)

local W, H = 440, 430
local HOME = { "CENTER", -140, 40 }                    -- left of the starter board (BoardModel.STARTER_POS)
local CLASS_POS = { "CENTER", -500, 40, "CENTER" }     -- the class board: left of the tour, in sight
local MAIN = "_main"

local f, step = nil, 1
local lit                               -- the board the tour is flashing
local made                              -- the board the tour made (its id)
local STEPS

local function BM() return ns.BoardModel end
local function Bo() return ns.Boards end
local function gold(s) return "|cffffd200" .. s .. "|r" end
local function lines(...) return table.concat({ ... }, "\n") end
local function bullet(s) return "  - " .. s end

--- Flash one board (whatever its rules hide), and stop flashing the one before.
local function light(id)
  local B = Bo()
  if not B then lit = nil; return end
  if lit and lit ~= id then B.Highlight(lit, false) end
  lit = id
  if id then B.Highlight(id, true, true) end              -- (full: the tour reveals a board not on the HUD too)
end

local function mainHost() return ns.Windows and ns.Windows.Host(MAIN) or nil end
local function mainShown() local m = mainHost(); return m and m:IsShown() and true or false end
local function hideMain() if mainShown() then ns.Windows.ShowMain(false) end end
local function showTab(id) return ns.Windows and ns.Windows.Show(id, true) or false end

--- The board the tour points at: the first one on screen, else the first.
local function firstBoard()
  local M = BM()
  if not (M and ns.charSettings) then return nil end
  local list = M.Store().list
  for _, b in ipairs(list) do if b.shown then return b end end
  return list[1]
end

--- This character's class board among the presets (Character Stats registers one per class): key, preset; or nil.
function Tutorial.ClassPreset()
  local M = BM()
  local class = M and M.PlayerClass()
  if not class then return nil end
  for _, key in ipairs(M.PRESET_ORDER) do
    local p = M.PRESETS[key]
    if p.category == "class" and p.class == class then return key, p end
  end
  return nil
end

--- The board this character already has from that preset (the tour's own first).
local function classBoard(key)
  local M = BM()
  local b = made and M.Get(made) or nil
  if b then return b end
  for _, x in ipairs(M.Store().list) do if x.preset == key then return x end end
  return nil
end

--- Make the class board, left of the tour, flashing. Returns it (nil without a class preset).
function Tutorial.MakeClassBoard()
  local key = Tutorial.ClassPreset()
  if not key then return nil end
  local b = BM().Create(key, { shown = true })      -- (the player's click: "makes it and puts it on your HUD")
  b.pos = ns.U.copy(CLASS_POS)
  made = b.id
  if Bo() then Bo().Created(b) end
  return b
end

---------------------------------------------------------------------------
-- The steps: { title, text() -> string, hud (the window out of the way), tab (the window, on this tab),
--   board() -> a board to flash, action() -> { text, func, disabled } or nil }
---------------------------------------------------------------------------

local PACK_WORDS = {
  hcfarm = "where your gold came from and where it went, by day, week or month",
  hcstats = "your character sheet, stat by stat, each one ready to put on a board",
  hcdiag = "for finding problems: the log, live values and checks of the game's API",
}

local function packLines()
  local out = {}
  local Win = ns.Windows
  for _, id in ipairs(Win and Win.PackWindows() or {}) do
    local def = Win.Def(id)
    local words = PACK_WORDS[id:match("^([%w_]+):") or ""]
    out[#out + 1] = bullet(gold(def.title or id) .. (words and (": " .. L[words]) or ""))
  end
  return out
end

STEPS = {
  { title = L["Welcome to Hard Counters"],
    text = function()
      return lines(
        L["Hard Counters puts the numbers you care about on your screen: gold per hour, XP to level, what you loot, your stats."],
        "",
        L["Four words are all you need:"],
        bullet(format(L["A %s is one number, such as Gold in or Crit chance."], gold(L["reading"]))),
        bullet(format(L["A %s shows one reading your way: a number, a bar, a gauge."], gold(L["tile"]))),
        bullet(format(L["A %s is a small panel of tiles that stays on screen while you play."], gold(L["board"]))),
        bullet(format(L["The %s is where you find, make and change all of it."], gold(L["Hard Counters window"]))),
        "",
        format(L["This tutorial has %d short steps. Close it whenever you like: the Guide tab of the window keeps everything it says, and /hc tutorial starts it again."], #STEPS))
    end },

  { title = L["Boards: the numbers on your screen"], hud = true, board = firstBoard,
    text = function()
      local b = firstBoard()
      local first
      if not b then
        first = L["A board is a panel of tiles on your screen. This character has none yet: the next step makes one."]
      elseif b.shown then
        first = format(L["The flashing panel is a board, called %s. It is this character's own: every character has its own boards."], gold(b.name))
      else
        first = format(L["The flashing panel is a board, called %s. It is flashing for this tutorial only: a new board is not on your screen until you put it there (the Boards tab, its %s switch)."], gold(b.name), gold(L["On HUD"]))
      end
      local key = ns.Boards and ns.Boards.MoveKeyWord()
      return lines(
        first,
        "",
        L["On your screen a board is locked: clicks go through it to the world."],
        bullet(format(L["Hover a board: two small tabs show above it. %s, above its left corner, drags it."], gold(L["Move"]))
          .. (key and (" " .. format(L["So does holding %s and dragging the board itself."], gold(key))) or "")),
        bullet(format(L["%s, above its right corner, opens it for changes; Done or Escape ends it."], gold(L["Edit"]))),
        bullet(format(L["While editing, %s adds a tile, and a right-click on a tile changes it: total or per hour, number, bar or gauge, its size, this character or the whole account."], gold("[+]"))),
        bullet(L["The buttons on a board are its clock. Its tiles count since the clock started: pause it, reset it, or save the stretch as a run."]),
        bullet(L["A right-click on the name bar opens the board's menu: mini mode (one line), when it shows (combat, instances), what period it counts."]))
    end },

  { title = L["Your first board"], hud = true,
    board = function()
      local key = Tutorial.ClassPreset()
      return key and classBoard(key) or nil
    end,
    text = function()
      local key, p = Tutorial.ClassPreset()
      if not key then
        return lines(
          L["Hard Counters has ready-made boards: Leveling, Pocket and Farming for gold and XP, and with the Character Stats pack one for each role and each class."],
          "",
          L["Character Stats isn't loaded on this character (the Packs tab turns it on), so there is no class board to offer. New board... lists the ready-made boards you do have, or starts an empty one."])
      end
      local b = classBoard(key)
      if b then
        return lines(
          format(L["This character has its class board: %s, flashing now. Its stats are live, and most keep updating in combat."], gold(b.name)),
          "",
          L["Try what the last step said: hover it, drag it by its Move tab, click Edit, right-click a tile."],
          "",
          L["Playing one role? New board... has a closer fit under Roles (tank, healer, melee, ranged, caster)."])
      end
      return lines(
        format(L["Hard Counters has a ready-made board for every class. Yours is %s: the stats this class uses, live."], gold(p.name)),
        "",
        L["The button below makes it and puts it on your HUD, left of this window. It is yours to change: move it, drop tiles you don't want, add others, or take it off the screen again."],
        "",
        L["Playing one role? New board... has a closer fit under Roles (tank, healer, melee, ranged, caster)."])
    end,
    action = function()
      local key, p = Tutorial.ClassPreset()
      local B = Bo()
      if not key then
        return { text = L["New board..."], func = function() if B then B.OpenNewBoard() end end }
      end
      local b = classBoard(key)
      if b then
        return { text = L["Show it"], func = function() if B then B.ShowNow(b.id, 8) end end }
      end
      return { text = format(L["Make my %s board"], p.name), func = function() Tutorial.MakeClassBoard() end }
    end },

  { title = L["The Hard Counters window"], tab = "boards",
    text = function()
      return lines(
        format(L["This is the Hard Counters window. %s opens it; so do the minimap button and the game's AddOns menu."], gold("/hc")),
        "",
        bullet(L["The icon tabs down its right edge are Hard Counters' own: Boards, Explorer, Packs, Stints and Guide. Hover one for its name."]),
        bullet(L["The tabs along the bottom: Overview (where everything stands), the packs' own tabs, Options, Report a problem, and Diagnostics when it is on."]),
        bullet(L["Under the title, one line says what the open tab is for."]),
        bullet(format(L["At the top right, on every tab: %s. It has a page and a short tutorial for the open tab, this tutorial again, and the Guide."],
          gold(L["Help"]))),
        "",
        L["The next steps open each tab in turn. It opened on the first one: Boards."])
    end },

  { title = L["Boards: make them, choose what is on screen"], tab = "boards",
    text = function()
      return lines(
        L["The Boards tab shows each of your boards as a panel and each tile as a card with its number now. This is where boards and tiles are made; nothing goes on your screen until you say so."],
        "",
        bullet(format(L["%s (top right, or the panel at the end of the list) makes a board: ready-made, empty, or a copy."], gold(L["New board..."]))),
        bullet(format(L["%s on a board's panel adds a number to it: its tracker starts counting, with history."], gold(L["+ Tile"]))),
        bullet(format(L["The switch at its right says %s (green lamp) or %s (grey): click it to put that board on your screen, or take it off. It counts either way."], gold(L["On HUD"]), gold(L["Only here"]))),
        bullet(format(L["%s and %s work the board's clock, as on the board itself."], gold(L["Pause"]), gold(L["Reset"]))),
        bullet(L["Click a card for that tile's menu; click a board's name for every action of that board."]))
    end },

  { title = L["Explorer: everything, in one place"], tab = "explorer",
    text = function()
      return lines(
        L["The Explorer lists everything Hard Counters can count and show: your boards and tiles, the ready-made boards, every reading, the five displays, and the trackers that count them."],
        "",
        bullet(L["The list on the left is by kind: Boards, Tiles, Readings, Trackers, then your other characters. A + opens a kind; a row in the middle shows its details below, and what you can do with it along the bottom."]),
        bullet(format(L["%s (under Boards): start from one with New board from it..."], gold(L["Ready-made boards"]))),
        bullet(format(L["%s: every number by category, with Add tile...; %s: number, bar, gauge, odometer, mix."], gold(L["Readings"]), gold(L["Displays"]))),
        bullet(format(L["%s: on or off, how much history each keeps, and its size on disk."], gold(L["Trackers"]))),
        bullet(L["Hover a board's row: it shows where it is on screen (faintly, if it is not on your HUD)."]))
    end },

  { title = L["Packs: choose what you want"], tab = "packs",
    text = function()
      local chosen = ns.Packs and ns.Packs.Chosen()
      return lines(
        L["Packs are where the numbers come from: Farmer counts loot, vendor value, reputation and your fishing catch; Character Stats your stats; Traveler distance and speed. Gold and experience are built in."],
        "",
        bullet(L["Tick the packs you want: the game is told at once."]),
        bullet(format(L["When a pack has to be loaded or unloaded the tab shows %s: a few seconds, nothing is lost (/reload does the same)."], gold(L["Reload now"]))),
        bullet(L["A pack's numbers count as soon as you place one of its tiles: its tracker is switched on for you, with daily history."]),
        "",
        chosen and L["You have chosen your packs already; change your mind here any time."]
          or L["Do it now if you like: this window stays open, and the tutorial waits."])
    end },

  { title = L["Stints: stretches you kept"], tab = "stints",
    text = function()
      return lines(
        L["A stint is a stretch of play saved with its numbers: how long, how much gold and XP, what dropped."],
        "",
        bullet(L["Dungeons record themselves: walk in, and when you leave the stint is here."]),
        bullet(L["Any board can save its clock's stretch as a stint (its menu: Save as stint)."]),
        bullet(format(L["%s and %s do it from the chat line."], gold("/hc stint start"), gold("/hc stint stop"))),
        bullet(L["Click a stint for its details below the list. A big number on a board compares itself with your past stints in the same zone."]))
    end },

  { title = L["Overview and Options, along the bottom"], tab = "overview",
    text = function()
      return lines(
        L["The Overview tab is where everything stands for this character: packs, trackers, boards and whether they are on your HUD, the open stint, how much history is kept. Anything that needs a look is listed first, amber, with the click that fixes it."],
        "",
        bullet(L["Options (along the bottom too) holds every setting: the window, boards, history and storage, profiles. /hc options opens it."]),
        bullet(L["Options, History: how many stints are kept, how many days, hours and weeks of history, and when your day ends (midnight by default)."]))
    end },

  { title = L["The packs' tabs"],
    text = function()
      local packs = packLines()
      local out = { L["Packs add readings, and some add a tab of their own along the bottom of this window. On this character:"], "" }
      if #packs == 0 then out[#out + 1] = bullet(L["(none loaded: the Packs tab turns the packs on)"]) end
      for _, s in ipairs(packs) do out[#out + 1] = s end
      out[#out + 1] = ""
      out[#out + 1] = L["Farmer counts loot, vendor value, reputation and your fishing catch; Character Stats your stats; Traveler distance and speed. A pack with no tab still adds its numbers to the Explorer and its ready-made boards to New board..."]
      out[#out + 1] = ""
      out[#out + 1] = L["Don't want one? Untick it in the Packs tab. Options: the Tab labels choice (icon, title or both)."]
      return table.concat(out, "\n")
    end },

  { title = L["Guide: all of this, any time"], tab = "guide",
    text = function()
      return lines(
        L["That's the tutorial. The Guide tab has what it said and more: the concepts, boards and tiles in depth, history, stints, the packs, every /hc command, and where pack authors start."],
        "",
        bullet(format(L["%s, at the top of this window on every tab: %s starts this tutorial again (so does %s); the two above it are about the open tab only, its help page and its own short tutorial."], gold(L["Help"]), gold(L["Full tutorial"]), gold("/hc tutorial"))),
        bullet(format(L["%s lists every command. When something breaks, the %s tab along the bottom (or %s) makes a report to paste."], gold("/hc help"), gold(L["Report a problem"]), gold("/hc report"))),
        "",
        L["Now play: your boards count while you do."])
    end },
}

---------------------------------------------------------------------------
-- The window
---------------------------------------------------------------------------

--- Beside the Hard Counters window while it is open, else left of the starter board; left alone once dragged.
local function place()
  if f.moved then return end
  f:ClearAllPoints()
  local m = mainShown() and mainHost()
  if m then f:SetPoint("TOPRIGHT", m, "TOPLEFT", -6, 0)
  else f:SetPoint(HOME[1], UIParent, HOME[1], HOME[2], HOME[3]) end
end

local function setTitle(text)
  if type(f.SetTitle) == "function" then pcall(f.SetTitle, f, text)
  elseif type(f.TitleContainer) == "table" and type(f.TitleContainer.TitleText) == "table" then
    f.TitleContainer.TitleText:SetText(text)
  elseif f.plainTitle then f.plainTitle:SetText(text) end
end

local function render()
  local s = STEPS[step]
  if s.tab then showTab(s.tab) elseif s.hud then hideMain() end
  light(s.board and (s.board() or {}).id or nil)
  f.head:SetText(s.title)
  f.body:SetText(s.text())
  f.count:SetText(format(L["Step %d of %d"], step, #STEPS))
  f.back:SetEnabled(step > 1)
  f.next:SetText(step == #STEPS and L["Finish"] or L["Next"])
  local a = s.action and s.action() or nil
  f.act:SetShown(a ~= nil)
  if a then
    f.act:SetText(a.text)
    Wd.FitWidth(f.act, 140, 32)
    f.act:SetEnabled(not a.disabled)
    f.actFunc = a.func
  end
  place()
  f:Raise()
end

local function build()
  local ok
  ok, f = pcall(CreateFrame, "Frame", "HardCountersTutorial", UIParent, "ButtonFrameTemplate")
  if not ok or type(f) ~= "table" then
    f = CreateFrame("Frame", "HardCountersTutorial", UIParent)
    local bg = f:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.05, 0.05, 0.07, 0.95)
    f.plainTitle = Wd.Text(f, "GameFontNormal", "TOP", 0, -8)
    local x = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    x:SetPoint("TOPRIGHT", 2, 2)
    f.CloseButton = x
  end
  f:Hide()
  f:SetSize(W, H)
  f:SetFrameStrata("DIALOG")
  f:SetToplevel(true)
  f:EnableMouse(true)
  f:SetMovable(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", function(self) self:StartMoving() end)
  f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing(); self.moved = true end)
  f:SetClampedToScreen(true)
  local hide = rawget(_G, "ButtonFrameTemplate_HidePortrait")
  if type(hide) == "function" then pcall(hide, f) end
  setTitle(L["Hard Counters: tutorial"])
  if type(f.CloseButton) == "table" then f.CloseButton:SetScript("OnClick", function() f:Hide() end) end
  tinsert(UISpecialFrames, "HardCountersTutorial")             -- Escape closes it
  f.head = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  f.head:SetPoint("TOPLEFT", 20, -36)
  f.head:SetPoint("TOPRIGHT", -20, -36)
  f.head:SetJustifyH("LEFT")
  f.body = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  f.body:SetPoint("TOPLEFT", 20, -62)
  f.body:SetPoint("TOPRIGHT", -20, -62)
  f.body:SetJustifyH("LEFT")
  f.body:SetJustifyV("TOP")
  f.body:SetSpacing(2)
  f.act = Wd.Button(f, "", 160, function()
    if f.actFunc then f.actFunc() end
    render()                                                   -- (the step's text and button follow what it did)
  end)
  f.act:SetHeight(24)
  f.act:SetPoint("BOTTOM", 0, 40)
  f.count = Wd.Text(f, "GameFontDisableSmall", "BOTTOMLEFT", 18, 15)
  f.next = Wd.Button(f, L["Next"], 90, function() Tutorial.Go(step + 1) end)
  f.next:SetPoint("BOTTOMRIGHT", -16, 10)
  f.back = Wd.Button(f, L["Back"], 80, function() Tutorial.Go(step - 1) end)
  f.back:SetPoint("RIGHT", f.next, "LEFT", -6, 0)
  Wd.RichTip(f.next, function() return { title = f.next:GetText(), text = L["The next step of the tutorial (Finish closes it; /hc tutorial starts it again)."] } end)
  Wd.RichTip(f.back, function() return { title = L["Back"], text = L["The step before."] } end)
  Wd.RichTip(f.act, function() return { title = f.act:GetText(), text = L["Does what this step describes; the tutorial stays open."] } end)
  -- (hidden above before this is set: closing stops the flashing, and never runs at build)
  f:SetScript("OnHide", function() light(nil) end)
end

--- Show step n (past the last one: the tour ends).
function Tutorial.Go(n)
  if not f then build() end
  if n > #STEPS then f:Hide(); return end
  step = math.max(1, n)
  f:Show()
  render()
end

--- Start the tour (step 1, or n). The window's Grand tour button, /hc tutorial.
function Tutorial.Show(n)
  if ns.globalSettings then ns.globalSettings.tutorialSeen = true end
  Tutorial.Go(n or 1)
  return f
end

function Tutorial.Hide() if f then f:Hide() end end
function Tutorial.Step() return step, #STEPS end
function Tutorial.Steps() return STEPS end

--- After a login: the account's first login that hasn't run the tour gets it (a character Hard Counters already
--- knew too: the tour is newer than they are). After that a new character (M.Seed set boards.welcome; it starts
--- with no board, 0.4.0) gets a chat line saying where boards are made. Returns "window", "line", "later" (in combat: asked again shortly) or nil.
function Tutorial.Check()
  local M = BM()
  if not (M and ns.charSettings) then return nil end
  M.Seed()
  local G = ns.globalSettings or {}
  if not G.tutorialSeen then
    if ns.wow and ns.wow.inCombat and ns.wow.inCombat() then
      C_Timer.After(10, function() Tutorial.Check() end)
      return "later"
    end
    M.Store().welcome = nil
    G.introSeen = true                  -- (HC-74's flag, for a build before the tour)
    Tutorial.Show(1)
    return "window"
  end
  local B = M.Store()
  if not B.welcome then return nil end
  B.welcome = nil
  if ns.Print then
    ns.Print(L["This character has no boards yet: /hc, the Boards tab, New board... makes one (ready-made, empty, or a copy of another character's). (/hc tutorial: the tutorial again)"])
  end
  return "line"
end

ns.On("PLAYER_ENTERING_WORLD", function()
  if not ns.ready then return end
  -- after the loading screen, so it isn't lost behind it
  C_Timer.After(2, function() Tutorial.Check() end)
end, "Welcome")

-- (0.5.0) /hc tutorial <tab>: that tab's own tutorial; no name: the full one
ns.AddSlash("tutorial", function(rest)
  if rest and rest:match("%S") and ns.Help and ns.Help.TutorialByName then ns.Help.TutorialByName(rest); return end
  Tutorial.Show(1)
end, L["the full tutorial of Hard Counters: boards, the window and its tabs, your first board (/hc tutorial <tab>: one tab's)"])
ns.AddSlash("welcome", function() Tutorial.Show(1) end)        -- (its name in 0.2.2; not listed)
ns.TutorialFrame = function() return f end                     -- (tests)
