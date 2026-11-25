-- The Boards tab (DESIGN §17.4, HC-68): the second tab of the Hard Counters window, on the shared browser. Tree:
-- "Your boards", then "Presets" with Hard Counters' own, each pack's and "Your presets". Your boards: Name, Status
-- (On HUD; On HUD, hidden: naming the rule; Only here; Off screen?), Tiles, Mini. Hovering a board's row shows that board, raised
-- above the window and flashing, until the pointer leaves. Actions follow the selection: Show or Hide, Show now
-- (whatever its rules, for a while), Edit on screen, Reset position (centre, scale 1), Duplicate (the New board
-- dialog, a copy), Save as preset, Delete; right-click adds Mini mode and Rename. At the top: New board..., Show all,
-- Hide all, Edit all. A preset: New board from it...; one of yours: Rename, Delete. Categories beyond the pack stay
-- HC-57 (proposed). "Other characters" (HC-74: every character has its own boards): each other character's boards
-- and 0.2's shared ones, to look at and Copy to this character... (the New board dialog).
local ADDON, ns = ...

local HC, L = ns.HC, ns.L
local format = string.format

local ID = "boards"
local content, browser, ticker

local function BM() return ns.BoardModel end
local function Bo() return ns.Boards end

local refresh

local function confirm(text, fn) if Bo() and Bo().Confirm then Bo().Confirm(text, fn) else fn() end end
local function askText(prompt, current, fn) if Bo() and Bo().AskText then Bo().AskText(prompt, current, fn) end end

local STATUS_COLOR = { shown = "|cff60ff60", faded = "|cff60ff60", off = "|cff808080", offscreen = "|cffff6060",
  tiny = "|cffff9040" }

local function matches(search, text)
  return search == "" or (type(text) == "string" and text:lower():find(search, 1, true) ~= nil)
end

local function groupOfKey()
  local out = {}
  for _, g in ipairs(BM().PresetGroups()) do for _, k in ipairs(g.keys) do out[k] = g.title end end
  return out
end

---------------------------------------------------------------------------
-- The provider
---------------------------------------------------------------------------

local function nodes()
  local M = BM()
  local out = { { key = "boards", text = L["Your boards"], count = #M.Store().list } }
  local groups, total = M.PresetGroups(), 0
  for _, g in ipairs(groups) do total = total + #g.keys end
  out[#out + 1] = { key = "presets", text = L["Presets"], count = total }
  for _, g in ipairs(groups) do out[#out + 1] = { key = "pg:" .. g.title, text = L[g.title], count = #g.keys, indent = 1 } end
  local others, n = M.OtherBoards(), 0
  if #others > 0 then
    for _, o in ipairs(others) do n = n + #o.boards end
    out[#out + 1] = { key = "others", text = L["Other characters"], count = n }
    for _, o in ipairs(others) do
      out[#out + 1] = { key = "oc:" .. tostring(o.key), text = o.shared and L[o.name] or o.name, count = #o.boards, indent = 1 }
    end
  end
  return out
end

--- A tile of another store, in words: its name, else its reading's title (as a preset's tiles are shown).
local function rawLabel(t, store)
  local ref = type(t) == "table" and rawget(t, "ref")
  local raw = ref and type(store.tiles) == "table" and store.tiles[ref] or t
  if type(raw) ~= "table" then return "?" end
  if raw.kind == "label" then return "[" .. (raw.text or "") .. "]" end
  if raw.kind == "splits" then return L["Splits"] end
  if type(raw.name) == "string" and raw.name ~= "" then return raw.name end
  local r = ns.readings[raw.reading]
  return r and ns.ReadingTitle(r, raw.arg, raw.calc) or tostring(raw.reading)
end

local function otherRows(node, search, out)
  for _, o in ipairs(BM().OtherBoards()) do
    if node == "others" or node == "oc:" .. tostring(o.key) then
      local who = o.shared and L[o.name] or o.name
      for i, b in ipairs(o.boards) do
        if type(b) == "table" and type(b.name) == "string" and (matches(search, b.name) or matches(search, who)) then
          out[#out + 1] = { key = "o:" .. tostring(o.key) .. ":" .. i, other = { board = b, store = o.store, who = who },
            cells = { name = b.name, status = "|cff808080" .. who .. "|r", tiles = tostring(#(b.tiles or {})),
              mini = b.mini and L["mini"] or "" } }
        end
      end
    end
  end
  return out
end

local function rows(node, search)
  local M, out = BM(), {}
  if node == "others" or tostring(node):sub(1, 3) == "oc:" then return otherRows(node, search, out) end
  if node == "boards" then
    for _, b in ipairs(M.Store().list) do
      if matches(search, b.name) then
        local status, why = ns.BoardStatusText(b)
        out[#out + 1] = { key = b.id, board = b, why = why,
          cells = { name = b.name, status = status,
            tiles = tostring(#b.tiles), mini = b.mini and L["mini"] or "" } }
      end
    end
    return out
  end
  local of = groupOfKey()
  for _, g in ipairs(M.PresetGroups()) do
    if node == "presets" or node == "pg:" .. g.title then
      for _, key in ipairs(g.keys) do
        local p = M.Preset(key)
        if p and matches(search, p.name) then
          out[#out + 1] = { key = "p:" .. key, preset = key, user = M.UserPreset(key) ~= nil,
            cells = { name = p.name, status = L[of[key] or ""], tiles = tostring(#p.tiles), mini = p.mini and L["mini"] or "" } }
        end
      end
    end
  end
  return out
end

local RULE_WORD = { show = "shows", fade = "fades", hide = "hides" }

local function detail(row)
  local M = BM()
  if row.other then
    local o = row.other
    local items = { { text = L["Its tiles"], head = true } }
    for _, t in ipairs(o.board.tiles or {}) do items[#items + 1] = { text = "  " .. rawLabel(t, o.store) } end
    return { title = o.board.name .. "   |cff808080" .. o.who .. "|r",
      lines = { L["Another character's board. Copy it to this character to use it here: the copy is yours to change,"
        .. " with its own timer."] },
      items = items }
  end
  if row.board then
    local b = row.board
    local show = b.show or {}
    local lines = {
      format(L["/hc board %s puts it on or off your HUD."], b.name:lower()),
      format(L["On the HUD: in combat it %s; in instances it %s%s%s."], L[RULE_WORD[show.combat or "show"]],
        L[RULE_WORD[show.instance or "show"]], show.runOnly and L["; only while a run is open"] or "",
        show.mouseoverFade and L["; faded until you hover it"] or ""),
    }
    local items = {
      { text = format(L["Mini mode: %s"], b.mini and L["on (one line)"] or L["off"]),
        button = { text = b.mini and L["Full"] or L["Mini"], func = function()
          b.mini = not b.mini
          Bo().Refresh(b.id, true)
          refresh()
        end } },
      { text = format(L["Name: %s"], b.name), button = { text = L["Rename..."], func = function()
        askText(L["Board name"], b.name, function(s) Bo().Rename(b, s); refresh() end)
      end } },
      { text = L["Its tiles"], head = true },
    }
    for _, t in ipairs(b.tiles) do
      local label = t.kind == "reading" and M.TileLabel(t, b) or (t.kind == "label" and ("[" .. (t.text or "") .. "]") or L["Splits"])
      local off = not M.TileOnHud(t)
      items[#items + 1] = { text = "  " .. label .. (off and ("  (" .. L["Only here"] .. ")") or ""), grey = off }
    end
    if #b.tiles == 0 then items[#items + 1] = { text = "  " .. L["(empty: + Tile in the Overview tab, or Edit on screen and its [+])"], grey = true } end
    return { title = b.name .. "   " .. row.cells.status, lines = lines, items = items }
  end
  local p = M.Preset(row.preset)
  if not p then return nil end
  local items = { { text = L["Its tiles"], head = true } }
  for _, t in ipairs(p.tiles) do
    local r = t.kind == "reading" and ns.readings[t.reading]
    local label = r and ns.ReadingTitle(r, t.arg, t.calc) or (t.kind == "label" and ("[" .. (t.text or "") .. "]"))
      or (t.kind == "splits" and L["Splits"]) or tostring(t.reading)
    items[#items + 1] = { text = "  " .. label, grey = t.kind == "reading" and not r }
  end
  return { title = p.name .. "   |cff808080" .. (row.cells.status or "") .. "|r",
    lines = { row.user and L["One of your presets: a board saved with Save as preset."]
      or L["New board from it makes a board with these tiles; numbers from a pack you don't have are left out."] },
    items = items }
end

local function boardActions(b)
  local editing = Bo().IsEditing(b.id)
  return {
    { text = b.shown and L["Take off HUD"] or L["Put on HUD"],
      tip = b.shown and L["It stays in this window (Only here), still counting."] or L["On your screen while you play."],
      func = function()
        b.shown = not b.shown
        Bo().Refresh(b.id, true)
        if b.shown then Bo().Flash(b.id) end
        if ns.RefreshOverview then ns.RefreshOverview() end
        refresh()
      end },
    { text = L["Show now"], tip = format(L["Shows it for %d seconds whatever its rules, with a flash: to find it."], Bo().SHOW_NOW),
      func = function() Bo().ShowNow(b.id); refresh() end },
    { text = editing and L["Stop editing"] or L["Edit on screen"],
      func = function() Bo().EditBoard(b.id, not editing); refresh() end },
    { text = L["Reset position"], tip = L["Back to the centre of the screen at its normal size."],
      func = function() Bo().ResetPosition(b); refresh() end },
    { text = L["Duplicate"], tip = L["A copy with tiles of its own (the New board dialog)."],
      func = function() Bo().OpenNewBoard({ copy = b }) end },
    { text = L["Save as preset"], tip = L["Keep this board's tiles and rules as a preset of yours, to make boards from."],
      func = function()
        askText(L["Preset name"], b.name, function(s)
          local key = BM().SaveAsPreset(b, s)
          if ns.Print then ns.Print(L["Saved as the preset %s (Boards tab, Presets)."], BM().Preset(key).name) end
          refresh()
        end)
      end },
    { text = L["Delete"], func = function()
      confirm(format(L["Delete the board %s and its tiles? Your counts don't change."], b.name), function()
        BM().Delete(b.id)
        Bo().RefreshAll()
        if ns.RefreshOverview then ns.RefreshOverview() end
        refresh()
      end)
    end },
  }
end

local function actions(row)
  if not row then return {} end
  if row.board then return boardActions(row.board) end
  if row.other then
    local o = row.other
    return { { text = L["Copy to this character..."], tip = L["A board of this character's own with the same tiles and rules."],
      func = function() Bo().OpenNewBoard({ copy = o.board, from = o.store, who = o.who }) end } }
  end
  local key = row.preset
  local acts = { { text = L["New board from it..."], func = function() Bo().OpenNewBoard({ preset = key }) end } }
  if row.user then
    acts[#acts + 1] = { text = L["Rename..."], func = function()
      askText(L["Preset name"], BM().Preset(key).name, function(s) BM().RenamePreset(key, s); refresh() end)
    end }
    acts[#acts + 1] = { text = L["Delete"], func = function()
      confirm(format(L["Delete your preset %s? Boards made from it stay."], BM().Preset(key).name), function()
        BM().DeletePreset(key)
        refresh()
      end)
    end }
  end
  return acts
end

--- Right-click on a board's row: its actions, plus Mini mode and Rename. after: called once an action ran (the
--- Overview tab's board header shows the same menu, HC-73).
local function rowMenu(row, anchor, after)
  local items = {}
  after = after or function() end
  for _, a in ipairs(actions(row)) do
    items[#items + 1] = { text = a.text, tip = a.tip, func = function() a.func(anchor); after() end }
  end
  if row.board then
    local b = row.board
    table.insert(items, 2, { text = L["Mini mode (one line)"], checked = b.mini, func = function()
      b.mini = not b.mini
      Bo().Refresh(b.id, true)
      refresh()
      after()
    end })
    table.insert(items, #items, { text = L["Rename..."], func = function()
      askText(L["Board name"], b.name, function(s) Bo().Rename(b, s); refresh(); after() end)
    end })
    if row.titled then table.insert(items, 1, { text = b.name, title = true }) end
  end
  if #items > 0 then ns.Menu.Show(anchor, items) end
end

--- A board's status in words, coloured as in the Boards tab, and why (Boards.Status).
local function statusText(b)
  local status, why = Bo().Status(b)
  return (STATUS_COLOR[why] or "|cffffd200") .. status .. "|r", why
end
ns.BoardStatusText = statusText
function ns.BoardMenu(b, anchor, after) rowMenu({ board = b, titled = true }, anchor, after) end

local function hover(row, on)
  if row.board and Bo() then Bo().Highlight(row.board.id, on) end
end

local function footer()
  local list = BM().Store().list
  local shown = 0
  for _, b in ipairs(list) do if b.shown then shown = shown + 1 end end
  return format(L["%d boards, %d on your HUD. Hover a board's row to see where it is (or would be) on screen."], #list, shown)
end

local function setAll(on)
  for _, b in ipairs(BM().Store().list) do b.shown = on end
  Bo().RefreshAll(true)
  if ns.RefreshOverview then ns.RefreshOverview() end
  refresh()
end

function refresh()
  if not (content and content:IsShown() and browser) then return end
  browser:Refresh()
  if content.editAll then content.editAll:SetText(Bo().IsEditing() and L["Stop editing"] or L["Edit all"]) end
end
ns.RefreshBoardsTab = refresh

local function build(f)
  content = f
  browser = ns.Browser.New(f, {
    columns = {
      { key = "name", title = L["Name"], sort = function(r) return r.cells.name:lower() end },
      { key = "status", title = L["Status"], width = 170 },
      { key = "tiles", title = L["Tiles"], width = 44, align = "RIGHT", sort = function(r) return tonumber(r.cells.tiles) or 0 end },
      { key = "mini", title = L["Mini"], width = 44 },
    },
    nodes = nodes, rows = rows, detail = detail, actions = actions, footer = footer, rowMenu = rowMenu, hover = hover,
    header = {
      { text = L["Edit all"], width = 90, tip = L["Every board in edit mode (Done on any one ends it)."], func = function()
        Bo().SetEditing(not Bo().IsEditing(), true)
        refresh()
      end },
      { text = L["All off HUD"], width = 90, tip = L["Every board only here, in this window: a clean screen. They keep counting."],
        func = function() setAll(false) end },
      { text = L["All on HUD"], width = 90, func = function() setAll(true) end },
      { text = L["New board..."], width = 100, func = function() Bo().OpenNewBoard() end },
    },
    empty = function(node, search)
      if search ~= "" then return L["Nothing matches the search."] end
      if node == "boards" then return L["No boards yet: New board... at the top right. A new board stays in this window until you put it on your HUD."] end
      return L["No presets here."]
    end,
    noSelection = L["Click a board for its tiles and what you can do with it. Hover its row to find it on screen."],
  })
  ns.BoardsBrowser = browser
  f.editAll = browser.headerBtns[1]                   -- its text follows edit mode
end

ns.Windows.Register(ID, {
  title = L["Boards"], icon = "Interface\\Icons\\INV_Misc_Map_01", tabOrder = 2,
  width = 720, height = 440, minWidth = 600, minHeight = 360,
  build = build,
  onShow = function()
    refresh()
    if ticker then ticker:Cancel() end
    ticker = C_Timer.NewTicker(1, refresh)              -- statuses change with combat, instances, runs
  end,
  onHide = function()
    if ticker then ticker:Cancel(); ticker = nil end
    for _, b in ipairs(BM().Store().list) do Bo().Highlight(b.id, false) end
    if ns.Menu then ns.Menu.Hide() end
  end,
})

function ns.ShowBoardsTab(show) ns.Windows.Show(ID, show) end
ns.AddSlash("boards", function() ns.ShowBoardsTab() end, L["the Boards tab: every board, on or off your HUD, find one, presets"])

local owner = {}
HC.RegisterCallback(owner, "HC_TRACKERS_CHANGED", function() refresh() end)
-- luacheck: push no max line length

-- This tab's help and tour (UI/Help.lua): change them with the tab.
local _ = ns.Help and ns.Help.Register(ID, {
  what = "The Boards tab is the list of this character's boards, the ready-made boards you can start from, and the boards of your other characters.",
  can = {
    "Hover a board's row: the board flashes where it is, or would be, on your screen.",
    "Click a board for its actions: {Put on HUD} or {Take off HUD}, {Show now}, {Edit on screen}, {Reset position}, {Duplicate}, {Save as preset}, {Delete}.",
    "{New board...} makes one; {Presets} on the left lists the ready-made boards by activity, role and class.",
    "{Other characters} (once you have several): copy a board from another character.",
    "{All off HUD} clears your screen in one click; the boards keep counting.",
  },
  effect = "The Status column says what you see while you play: {On HUD}, {Only here} (in this window only), or on the HUD but hidden by one of the board's own rules (in combat, in instances, only during runs).",
  tour = {
    { title = "Your boards, and where they are", text = "The list has one row per board. Status reads {On HUD} or {Only here}; when a board is on the HUD but hidden right now, it names the rule that hides it." },
    { title = "Find a board", text = "Hover a row and that board flashes on your screen, above this window. {Show now} keeps it visible for a few seconds whatever its rules; {Reset position} brings a lost board back to the centre." },
    { title = "Start from a ready-made board", text = "Click {Presets} in the tree on the left: Activity, Roles, your class. Pick one and use New board from it. A board you like can become a preset of your own with {Save as preset}." },
  },
})
-- luacheck: pop
