-- The Guide tab (the user, 2026-11-24): the last of Hard Counters' own tabs, the manual inside the game. Pages down
-- the left (Start here, Concepts, Boards, Tiles, The window, Trackers and history, Stints, Packs, Commands, For
-- addon authors), the chosen page's text on the right in a scroll frame of its own. (0.4.0: its Run the tutorial
-- button went; the window's Grand tour button is on every tab.) The Commands page is built from the live /hc
-- registry (ns.SlashList), so a pack's commands are listed with the pack's name; the Packs page names the packs loaded now. /hc guide [page] opens it.
-- Plain frames only: buttons, one font string, a scroll frame and Widgets.VScroll.
-- luacheck: no max line length (pages of prose: one sentence, one string)
local ADDON, ns = ...

local HC, L, Wd = ns.HC, ns.L, ns.Widgets
local format, floor, max, min = string.format, math.floor, math.max, math.min

local ID = "guide"
local LEFT_W, TOP_H, ROW_H = 170, 30, 24
local REPO = "github.com/ibourlakos-yolt/wow-hard-counters"

local content, current
local Guide = {}
ns.Guide = Guide

local function gold(s) return "|cffffd200" .. s .. "|r" end
local function grey(s) return "|cff909090" .. s .. "|r" end
local function head(s) return "\n" .. gold(s) end
local function item(s) return "  - " .. s end
local function term(name, text) return item(gold(name) .. ": " .. text) end
local function join(t) return table.concat(t, "\n") end

---------------------------------------------------------------------------
-- The pages. Each text() is called when the page is shown: lists (commands, packs) are live.
---------------------------------------------------------------------------

local function commandLines()
  local out = { item(gold("/hc") .. " - " .. L["open the Hard Counters window"] .. " " .. grey(L["(/hardcounters is the same command)"])) }
  for _, c in ipairs(ns.SlashList and ns.SlashList() or {}) do
    -- (a help line's "|" between choices would start an escape code in a font string: doubled, it draws as one)
    local help = c.help:gsub("|", "||")
    out[#out + 1] = item(gold("/hc " .. c.name) .. " - " .. help .. (c.owner and ("  " .. grey("(" .. c.owner .. ")")) or ""))
  end
  out[#out + 1] = item(gold("/hc help") .. " - " .. L["this list, in the chat window"])
  return out
end

local PACK_WORDS = {
  hc = "Gold in and out (by source, if you like), net gold, gold owned, XP gained, XP this level, rested XP, time to level, your level. Always on. The Pocket, Leveling and Farming boards.",
  hcfarm = "What you farm: the money Ledger by source, items looted (all, or one item) and their vendor value, your best drop, reputation gained (all, or one faction), In bags: an item, Standing progress: a faction, and what you fish (each catch, its share, the fish in your bags, your casts, the ones that got away, the catch rate and the wait for a bite). The Fishing basket board.",
  hcstats = "Your character sheet as readings: attributes, melee, ranged, spell and defense stats, weapon damage, speed and skills, resistances, durability, item level. A board for each class and role.",
  hctravel = "How you travel: distance on foot, mounted, swimming, by flight and by boat, time moving, average and top speed, speed now, jumps, falls, corpse runs, flights. The Trip and Flight log boards.",
}

local function packLines()
  local out = {}
  for _, name in ipairs(ns.packOrder or {}) do
    local pk = ns.packs[name]
    local words = PACK_WORDS[pk.namespace or ""]
    out[#out + 1] = term(tostring(pk.title or name), words and L[words] or L["a pack by another author"])
  end
  if #out == 0 then out[1] = item(grey(L["(no pack has registered yet)"])) end
  return out
end

local function add(out, t) for _, s in ipairs(t) do out[#out + 1] = s end end

local PAGES = {
  { key = "start", title = L["Start here"], text = function()
    return join({
      gold(L["Hard Counters"]),
      L["Put any number you care about on your screen: gold per hour, XP to level, how many of an item you have looted, your reputation toward the next standing, your crit chance. Pick it, put it on a board, done. History, records and rates are there when you want them and out of the way when you don't."],
      head(L["New here?"]),
      format(L["%s (top right of this window, on every tab) is a short tour: the boards on your screen, a first board for your class, then this window tab by tab. It showed by itself the first time you logged in with it."], gold(L["Grand tour"])),
      head(L["In a hurry"]),
      item(format(L["%s opens this window. So do the minimap button and the game's AddOns menu."], gold("/hc"))),
      item(L["Boards tab: New board... makes a board, + Tile on it adds a number (and starts its tracker, with history), its On HUD switch puts it on your screen."]),
      item(L["Hover a board on screen: Edit above its right corner changes it, Move above its left corner drags it."]),
      item(L["Packs tab: tick the packs you want, then reload."]),
      item(L["Explorer tab: every reading, board, tile and tracker; pick one and act on it below."]),
      item(L["Overview tab (along the bottom): where everything stands, and what needs a look."]),
      head(L["Good to know"]),
      item(L["Nothing leaves your computer: addons have no network access. /hc report only shows text for you to copy. It lists what it holds; your class and your addon list are in it unless you untick them, your character's name and realm only if you tick the box."]),
      item(L["In combat the game hides many character stats from addons. Single-value stats keep updating; the rest show their last value, marked in combat, until the fight ends."]),
      item(L["This is a beta: a new version may reset saved data, and its changelog says so when it does."]),
    })
  end },

  { key = "concepts", title = L["Concepts"], text = function()
    return join({
      gold(L["The words Hard Counters uses"]),
      term(L["Reading"], L["one number Hard Counters can show: Gold in, XP gained, Items looted, Crit chance, Distance travelled."]),
      term(L["Tile"], L["one reading shown your way. You choose its period, how it is worked out and how it looks."]),
      term(L["Board"], L["a panel of tiles on your screen (a HUD). You can have as many as you like; each character has its own."]),
      term(L["Tracker"], L["a group of readings that is counted together and can be switched off together: Gold, Experience, Loot, Reputation..."]),
      term(L["History"], L["what a tracker keeps between sessions, when you turn it on: totals by day, week, month and for ever."]),
      term(L["Stint"], L["a stretch of play saved with its numbers: a dungeon, a farming hour."]),
      term(L["Pack"], L["an addon that gives Hard Counters more readings: Farmer, Character Stats, Traveler, or someone else's."]),
      head(L["A tile's period (Scope)"]),
      term(L["The board's timer"], L["since the board's clock was started or reset. The default: pause it for a break, reset it for a new start."]),
      term(L["Session"], L["since you logged in."]),
      term(L["Today, this week, this month, this year, lifetime"], L["calendar periods. They need the tracker's history on."]),
      term(L["Now"], L["a value that just is, such as your level, your gold or a stat."]),
      head(L["How it is worked out (Show as)"]),
      term(L["Total"], L["everything counted over the period."]),
      term(L["Per hour"], L["the total divided by your active hours in the period. Time away from the keyboard doesn't count."]),
      term(L["Recent"], L["your pace now, per hour: the last few minutes count most."]),
      term(L["Trend"], L["your pace now against your average over the period: faster, slower or on pace."]),
      head(L["How it looks (Display, Size)"]),
      term(L["Number"], L["the number itself: Big (with a small graph of the last minutes), Half width or Line."]),
      term(L["Bar, Gauge"], L["filling toward a target: the next level, a skill's cap, or a target you type."]),
      term(L["Odometer, Mix"], L["rolling digits for a total; one bar split by kind (gold by source, say)."]),
    })
  end },

  { key = "boards", title = L["Boards"], text = function()
    return join({
      gold(L["Boards: the panels on your screen"]),
      L["A board is made in this window (the Boards tab) and stays there, Only here, until you put it on your HUD: its On HUD switch in the Boards tab, the box in the New board dialog, or /hc board <name>. On the HUD it is locked while you play: it is text, and clicks go through it to the world. Only its clock's buttons take clicks."],
      head(L["Moving a board"]),
      item(L["Hover it: a Move tab shows above its left corner. Drag that tab and the board follows."]),
      item(L["Or hold Ctrl and drag the board itself. Options, Boards: choose Shift or Alt instead, or switch the key off."]),
      head(L["Changing a board"]),
      item(L["Hover it and click the gold Edit tab above its right corner (not in combat). Done on its name bar, or Escape, ends it."]),
      item(L["/hc edit edits every board at once. So does ctrl-click on the minimap button, and opening the game's own Edit Mode."]),
      item(L["While editing: drag the name bar to move it, drag its side grip for the width, [+] to add a tile, right-click a tile to change it."]),
      item(L["Right-click the name bar for the board's menu: Scope, Mini mode, Visibility, Rename, Take off the HUD, Delete."]),
      head(L["The board is the clock"]),
      item(L["Every board has one timer, and its tiles count over it. Its buttons start and pause it; the board's menu also has Stop, Reset and Save as stint. The Boards tab has Pause and Reset too."]),
      item(L["Reset starts from zero. If there was real play since the last start, it is saved as a stint first."]),
      item(L["The timer survives a logout: a board carries on where it stopped."]),
      item(L["Want one tile on a clock of its own? Its menu, Move to, New board."]),
      item(L["A board can count a fixed period instead (its menu, Scope): this session, today, this week... The header then says which, and the clock's buttons go."]),
      head(L["When a board shows"]),
      item(L["Its menu, Visibility: show, fade or hide in combat; show or hide in instances; only while a stint is open; faded until the mouse is over it."]),
      item(L["Mini mode folds a board into one line. Hover it to see the whole board; click it to pause or start its clock; right-click it for its menu."]),
      item(format(L["%s puts one on your HUD or takes it off, from the chat line."], gold("/hc board <name>"))),
      head(L["More boards"]),
      item(L["New board... (the Boards and Explorer tabs, a right-click on the minimap button, /hc board new) starts from a ready-made board, an empty one, or a copy. Tick Put it on my HUD there, or leave it for later."]),
      item(L["Ready-made boards come grouped: Activity (Leveling, Pocket, Farming, Trip...), Your class, Other classes."]),
      item(L["A board you like can be saved as a preset of your own (Explorer tab, a board, More...), to make others from, on any character."]),
      item(L["Each character has its own boards. Explorer tab, Other characters: copy one over."]),
      head(L["Lost a board?"]),
      item(L["Explorer tab, Boards: hover its row and it shows on screen (faintly if it is not on your HUD). Show now shows it whatever its rules; Reset position brings it back to the centre. The Overview tab lists a board that seems lost."]),
    })
  end },

  { key = "tiles", title = L["Tiles"], text = function()
    return join({
      gold(L["Tiles: one number each"]),
      L["Add one with a board's [+] (while editing), or from the Explorer (Readings, Add tile...). The tile's tracker starts counting, with daily history. With the Farmer pack you can also drag an item from your bags onto a board to count it."],
      head(L["A tile's menu (right-click it while editing, or click its card in the Boards tab)"]),
      term(L["What it counts"], L["some readings take a choice: which sources of gold, which item, which faction, which school, which weapon skill."]),
      term(L["Counts"], L["this character, or the whole account."]),
      term(L["Scope"], L["its period: follow the board, or one of its own."]),
      term(L["Show as"], L["Total, Per hour, Recent or Trend."]),
      term(L["Display"], L["Number, Bar, Gauge, Odometer or Mix. A bar or a gauge asks for a target if the reading has none."]),
      term(L["Size"], L["Big, Half width (two side by side) or Line."]),
      term(L["Units"], L["for readings that have two, such as a speed in yards a second or as a percentage of run speed."]),
      term(L["Trend badge"], L["a small arrow and words on a big per-hour tile: faster, slower, on pace."]),
      term(L["Rename, Move up, Move down, Move to"], L["its own name, its place, or another board."]),
      head(L["Reading a tile"]),
      item(L["A per-hour number is grey until about five active minutes have passed: before that, one drop swings it. Under a minute it shows a dash."]),
      item(L["A greyed stat marked in combat is its value from before the fight: the game hides it until the fight ends."]),
      item(L["n/a means the reading doesn't apply to this character (a mana stat on a warrior)."]),
      item(L["(since 14:02) after an item or a faction means it was first counted then, later than the board's period began."]),
      head(L["Other things a board can hold"]),
      item(L["Heading: a line of text to group tiles. Splits: the laps of the open stint."]),
      head(L["Off the screen"]),
      item(L["Every tile is on a board, but not every tile has to be on your screen. In the Boards tab, a tile's menu has On HUD: off, it stays on its board in the window, still counting. A whole board can be Only here the same way. On a board on your HUD, a tile's menu has Hide from HUD."]),
    })
  end },

  { key = "window", title = L["The window"], text = function()
    local packs = {}
    local Win = ns.Windows
    for _, id in ipairs(Win.PackWindows()) do packs[#packs + 1] = Win.Def(id).title or id end
    return join({
      gold(L["The Hard Counters window"]),
      format(L["%s, the minimap button and the game's AddOns menu open it. It is one window with tabs; Escape closes it, its title bar drags it."], gold("/hc")),
      head(L["Hard Counters' own tabs (the icons down the right edge)"]),
      term(L["Boards"], L["your boards as panels, their tiles as cards with their numbers now. Make boards and tiles here; put them on or off your HUD; pause or reset their clocks."]),
      term(L["Explorer"], L["everything in one place: boards, tiles, ready-made boards, readings, displays, trackers and their history, other characters' boards."]),
      term(L["Packs"], L["choose the packs you want."]),
      term(L["Stints"], L["your saved stretches of play and dungeons, newest first. Click one for its details."]),
      term(L["Guide"], L["this."]),
      head(L["Along the bottom"]),
      term(L["Overview"], L["where everything stands for this character, and what needs a look."]),
      term(L["Options"], L["every setting (also /hc options)."]),
      head(L["The packs' tabs (along the bottom too)"]),
      #packs > 0 and item(format(L["Here now: %s."], table.concat(packs, ", "))) or item(grey(L["(none loaded)"])),
      item(L["Options has Tab labels for them: icon and title, title only, or icon only."]),
      head(L["The top of the window"]),
      item(L["Under the title, one line says what the open tab is for."]),
      item(L["Grand tour: the tour of all of Hard Counters, from its first step."]),
      item(L["Beside it, named after the open tab (Boards help, Boards tour): one page on that tab (what it is, what you can do there, how it changes your play), and a few steps through it alone. /hc tour <tab> does the same."]),
      head(L["Buttons and switches"]),
      item(L["A red-and-gold button does something (New board..., Reset, Delete). A dark pill with a lamp is a switch that shows a state: green on, grey off, amber needs a look; click it to change it (On HUD / Only here, Counting / Not counting)."]),
      head(L["The minimap button"]),
      item(L["Click: this window. Shift-click: all your boards on or off the HUD. Ctrl-click: edit every board. Right-click: New board..., the Boards, Explorer and Overview tabs, Options. Its tooltip is live: your session, the open stint, your boards' numbers; hold Shift for all of them."]),
      item(format(L["%s shows or hides the button. The AddOns menu entry is always there."], gold("/hc minimap"))),
      item(L["Titan Panel, ElvUI and other data broker bars get a Hard Counters feed with the same clicks."]),
      head(L["Options"]),
      item(format(L["%s opens the Options tab (also the game's options under AddOns): what This week means, the data broker feed, recording dungeons, boards, tab labels, the window's scale, history and storage, when the day ends, profiles."], gold("/hc options"))),
      item(L["With the BlizzMove addon, Ctrl + mouse wheel scales the window and any board."]),
    })
  end },

  { key = "history", title = L["Trackers and history"], text = function()
    return join({
      gold(L["Trackers: what is counted"]),
      L["Every reading belongs to a tracker. The Explorer tab lists them under Trackers, by category, with a switch for each."],
      item(L["Off: nothing in it is counted, and it costs nothing. Switch off what you don't care about."]),
      item(L["On: its readings count for your boards, for this session and for runs."]),
      item(L["Click a tracker for its readings, each with the periods it can show and Add tile."]),
      head(L["History: on with your tiles"]),
      L["When you place a tile, its tracker goes on with daily history (unless you chose otherwise). Without history Hard Counters keeps nothing beyond what your boards show and the stints you saved. With it, a tracker's totals are kept between sessions, and its tiles can count today, this week, this month, this year and lifetime, for this character or the whole account."],
      item(L["Explorer tab, Trackers, select one, History...: Keep history is the one switch."]),
      item(L["Advanced chooses how much: Lifetime (one running total), Daily (day by day, for 14 to 365 days) or Detailed (hours too)."]),
      item(L["Options, History: the days kept for a tracker you didn't set, how long hours and weeks are kept, and when your day ends. Older days still count in their month, year and lifetime."]),
      item(L["The Size column says what each tracker's history takes on disk. Delete history frees it; your boards' numbers don't change."]),
      item(format(L["From the chat line: %s lists the trackers, %s turns one's history on."], gold("/hc track"), gold("/hc track 1 history on"))),
      head(L["Not loaded"]),
      item(L["Data on disk from a pack that isn't loaded now is listed under Not loaded, by name, with Delete."]),
      head(L["This week"]),
      item(L["Options: Monday to Sunday, or from weekly reset to weekly reset."]),
    })
  end },

  { key = "stints", title = L["Stints"], text = function()
    return join({
      gold(L["Stints: stretches of play you kept"]),
      L["A stint is a record: when, how long (active time, without the breaks), and what every counter gained in it."],
      head(L["Three ways to get one"]),
      item(L["Dungeons record themselves: entering an instance starts a stint named after it, leaving saves it when it had five active minutes or more. Options turns this off."]),
      item(L["A board: its menu, Save as stint, saves the stretch its clock has counted. Resetting a board saves one too when there was real play."]),
      item(format(L["The chat line: %s, then %s. In between, %s, %s and %s (a lap)."], gold("/hc stint start [label]"), gold("/hc stint stop"),
        gold("pause"), gold("resume"), gold("split [label]"))),
      head(L["Looking at them"]),
      item(L["The Stints tab lists them newest first: when, name, where, active time and a headline number."]),
      item(L["Click a stint: below the list, its numbers, counts, top tallies such as items looted, its best and its splits. Rename, Copy as text or Delete it there."]),
      item(L["A Big number tile can say how you are doing against your average in the same zone, from your past stints there."]),
      item(L["A board can show only while a stint is open (its menu, Visibility). Options, History: how many stints are kept."]),
    })
  end },

  { key = "packs", title = L["Packs"], text = function()
    local out = {
      gold(L["Packs: where the numbers come from"]),
      L["Hard Counters itself is the engine, the boards and this window. Packs give it readings. One download brings several. The Packs tab is where you choose: tick the ones you want. A pack's tracker goes on, with history, when you place one of its tiles. A pack you untick is not loaded any more after a reload (the tab has a Reload now button)."],
      head(L["Loaded on this character"]),
    }
    add(out, packLines())
    add(out, {
      head(L["Diagnostics"]),
      item(L["A companion for finding problems: a log, live values, storage use and checks of the game's API. With it loaded, /hc report carries those checks, which helps most in a bug report. Untick it in the Packs tab if you don't want it."]),
      head(L["What a pack adds"]),
      item(L["Trackers and readings (Explorer tab), ready-made boards (New board...), sometimes a tab along the bottom of this window and a /hc command."]),
      item(L["Tiles from a pack that isn't loaded are left out, not lost: they come back with the pack."]),
    })
    return join(out)
  end },

  { key = "commands", title = L["Commands"], text = function()
    local out = {
      gold(L["Slash commands"]),
      L["Everything hangs off one command, /hc. This list is live: packs add their own, named in grey."],
      "",
    }
    add(out, commandLines())
    add(out, {
      head(L["Examples"]),
      item(gold("/hc board") .. " - " .. L["list your boards with their numbers"]),
      item(gold("/hc board leveling") .. " - " .. L["the board called Leveling on or off your HUD (or /hc board 2, by its number)"]),
      item(gold("/hc board new") .. " - " .. L["the New board dialog"]),
      item(gold("/hc board new pocket") .. " - " .. L["a board from a ready-made one: farming, pocket or leveling"]),
      item(gold("/hc board new Herbs") .. " - " .. L["an empty board called Herbs, open for editing"]),
      item(gold("/hc board mini 2") .. " - " .. L["board 2 in or out of mini mode"]),
      item(gold("/hc board reset") .. " - " .. L["delete every board of this character and start again (it asks first)"]),
      item(gold("/hc stint start Strat") .. " - " .. L["start a stint with a label; /hc stint stop saves it"]),
      item(gold("/hc stint") .. " - " .. L["the open stint's status"]),
      item(gold("/hc track") .. " - " .. L["list the trackers with their numbers"]),
      item(gold("/hc track 2 off") .. " - " .. L["switch tracker 2 off"]),
      item(gold("/hc track 2 history daily 30") .. " - " .. L["keep 30 days of daily history for tracker 2"]),
      item(gold("/hc guide commands") .. " - " .. L["this page"]),
    })
    return join(out)
  end },

  { key = "authors", title = L["For addon authors"], text = function()
    local api = HC and HC.API_VERSION
    return join({
      gold(L["Building on Hard Counters"]),
      format(L["The global %s is a public API for other addons: a pack registers what it counts and Hard Counters does the storage, the periods, the boards and the windows. It is experimental%s: it may still change, so probe a feature with HardCounters:Supports(name) before using it."],
        gold("HardCounters"), api and format(" (API_VERSION %s)", tostring(api)) or ""),
      head(L["The calls, in the order a pack uses them"]),
      term("RegisterPack", L["your pack and its namespace (\"mypack\"): every id you register starts with it."]),
      term("RegisterCounter", L["something counted: its measures and what it is split by (zone, source, item...)."]),
      term("RegisterSource, Emit", L["the game events you listen to, and the call that adds to a counter."]),
      term("RegisterTracker", L["a group of your counters with one on switch and one history choice."]),
      term("RegisterReading", L["one number for boards, with its periods, formatter, optional target and choice."]),
      term("RegisterBoardPreset", L["a ready-made board of your readings, under Activity or Classes."]),
      term("RegisterWindow", L["a tab along the bottom of this window; Hard Counters gives it the frame, Escape, the saved place."]),
      term("Query, Reading", L["read totals back: by period, by member, for a character or the account."]),
      term("StartRun, StopRun, callbacks", L["runs, and events such as HC_RUN_STOPPED or HC_TRACKERS_CHANGED."]),
      head(L["The slash command API"]),
      L["A pack never registers a slash command of its own for its Hard Counters features. It adds a subcommand under /hc:"],
      "",
      "  " .. gold("HardCounters:RegisterSlash(name, fn, help, owner)"),
      "",
      item(L["name: lowercase letters and digits. /hc <name> [text] then calls fn(text) with whatever follows the name."]),
      item(L["help: one line for /hc help and this Guide's Commands page; owner: your pack's name, shown beside it."]),
      item(L["It returns true, or false and a reason: a name already taken by Hard Counters or another pack is refused."]),
      item(L["Check HardCounters:Supports(\"slash\") first if you support old versions."]),
      "",
      grey("  HardCounters:RegisterSlash(\"fish\", function(rest)"),
      grey("    MyPack.Toggle(rest)"),
      grey("  end, \"show or hide the fishing log\", \"My pack\")"),
      head(L["Rules of the house"]),
      item(L["Only the public API: never read Hard Counters' saved tables."]),
      item(L["Never do arithmetic on a value the game marks secret in combat: HardCounters:Readable(value) tells."]),
      item(L["Count, never keep content: no chat text, no other players' names."]),
      head(L["Where to read more"]),
      item(format(L["%s: the API reference, with a pack in 30 lines."], gold(REPO .. " /docs/API.md"))),
      item(format(L["%s: the pack contract. The Farmer, Character Stats and Traveler packs in the same repository are worked examples, MIT licensed."], gold("/docs/PACKS.md"))),
    })
  end },
}

local function pageIndex(key)
  key = (key or ""):lower()
  for i, p in ipairs(PAGES) do if p.key == key or p.title:lower() == key then return i end end
  return nil
end

---------------------------------------------------------------------------
-- The frame
---------------------------------------------------------------------------

local function setScroll(off)
  local f = content
  off = max(0, min(floor((off or 0) + 0.5), f.range or 0))
  f.off = off
  f.scroll:SetVerticalScroll(off)
  f.bar:SetOffset(off)
end

--- Wrap the text to the pane's width and work out how far it scrolls.
local function layout()
  local f = content
  if not f then return end
  local w, h = f.scroll:GetWidth(), f.scroll:GetHeight()
  if type(w) ~= "number" or w < 50 then w = 520 end
  if type(h) ~= "number" or h < 50 then h = 400 end
  f.text:SetWidth(w - 8)
  local th = f.text.GetStringHeight and f.text:GetStringHeight()
  if type(th) ~= "number" then th = 0 end
  f.child:SetSize(w, max(th + 12, 1))
  f.range = max(0, floor(th + 12 - h + 0.5))
  f.bar:SetRange(f.range)
  setScroll(min(f.off or 0, f.range))
end

local function show(i)
  local f = content
  current = i
  for n, b in ipairs(f.pages) do
    if n == i then b:LockHighlight() else b:UnlockHighlight() end
  end
  f.text:SetText(PAGES[i].text())
  f.off = 0
  layout()
end

local function build(f)
  content = f
  f.pages = {}
  for i, p in ipairs(PAGES) do
    local b = Wd.Button(f, p.title, LEFT_W, function() show(i) end)
    Wd.RichTip(b, function() return { title = p.title, text = L["Open this page of the Guide."], click = format(L["Also from chat: /hc guide %s"], p.key) } end)
    b:SetHeight(ROW_H - 2)
    b:SetPoint("TOPLEFT", 4, -(TOP_H + 4 + (i - 1) * ROW_H))
    f.pages[i] = b
  end
  f.title = Wd.Text(f, "GameFontNormal", "TOPLEFT", 8, -9)
  f.title:SetText(L["Guide: what Hard Counters is and what you can do with it"])
  f.scroll = CreateFrame("ScrollFrame", nil, f)
  f.scroll:SetPoint("TOPLEFT", LEFT_W + 16, -(TOP_H + 4))
  f.scroll:SetPoint("BOTTOMRIGHT", -18, 6)
  f.child = CreateFrame("Frame", nil, f.scroll)
  f.child:SetSize(1, 1)
  f.scroll:SetScrollChild(f.child)
  f.scroll:EnableMouseWheel(true)
  f.scroll:SetScript("OnMouseWheel", function(_, delta) setScroll((f.off or 0) - (delta or 0) * 48) end)
  f.text = f.child:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  f.text:SetPoint("TOPLEFT", 4, -4)
  f.text:SetJustifyH("LEFT")
  f.text:SetJustifyV("TOP")
  f.text:SetSpacing(3)
  f.bar = Wd.VScroll(f, setScroll)
  f.bar:SetPoint("TOPRIGHT", -2, -(TOP_H + 4))
  f.bar:SetPoint("BOTTOMRIGHT", -2, 6)
  f:SetScript("OnSizeChanged", layout)
  show(current or 1)
end

ns.Windows.Register(ID, {
  title = L["Guide"], icon = "Interface\\Icons\\INV_Misc_QuestionMark", tabOrder = 5,
  about = "The long read: how Hard Counters works, its words, its commands.",
  width = 720, height = 440, minWidth = 600, minHeight = 360,
  build = build,
  onShow = function()
    show(current or 1)                                  -- (the live lists: commands, packs)
    C_Timer.After(0, layout)                            -- once the pane has its size
  end,
})

--- Open the Guide (show nil toggles), on a page when given: its key ("commands") or its title.
function Guide.Show(showIt, page)
  local i = pageIndex(page)
  if i then current = i end
  if i and showIt == nil then showIt = true end
  ns.Windows.Show(ID, showIt)
  if i and content then show(i) end
end
function Guide.Pages() return PAGES end
function Guide.Page() return current and PAGES[current].key or nil end
function Guide.Content() return content end
ns.ShowGuide = Guide.Show

ns.AddSlash("guide", function(rest)
  local page = (rest or ""):match("^%s*(.-)%s*$")
  Guide.Show(page ~= "" and true or nil, page)
end, L["the Guide tab: concepts, how-tos, every command (add a page: /hc guide commands)"])

-- This tab's help and tour (UI/Help.lua): change them with the tab.
local _ = ns.Help and ns.Help.Register(ID, {
  what = "The Guide is the manual: the words Hard Counters uses, boards and tiles in depth, trackers and history, runs, the packs, every /hc command, and where addon authors start.",
  can = {
    "Pick a page on the left; scroll the text with the mouse wheel.",
    "{Grand tour} (top right of the window, on every tab) starts the general tour again, from its first step.",
    "Open a page straight from chat: /hc guide commands.",
  },
  effect = "Nothing here changes your game: it is for reading. The {Commands} page is built from what is loaded, so it also lists the commands of your packs.",
  tour = {
    { title = "Pages on the left", text = "Each entry on the left is a page. {Concepts} is the place to start; {Boards} and {Tiles} go into every choice a board and a tile have." },
    { title = "Three kinds of help", text = "The {Grand tour} button (top right, on every tab) is the general tour. The two beside it are named after the open tab: its tour walks through that tab only, its help sums it up on one page. The Guide is the long form of all three." },
  },
})
