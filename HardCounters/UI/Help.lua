-- Help and tab tours (the user, 2026-11-25): every tab of the Hard Counters window has a Help page (what the tab
-- is, what you can do in it, how that changes what you see while you play) and a short tour of its own, apart from
-- the general tutorial (UI/Welcome.lua). Both open from the window's Help button, on every tab (0.5.0: one button,
-- its menu "Help for "<tab>"", "Tutorial for "<tab>"", "Full tutorial", "Open the Guide"); also /hc tutorial <tab>.
-- Players read "tutorial" (0.5.0, the user: "avoid the word tour"); the code keeps tour (def.tour, Help.Tour).
--
-- A tab's help lives beside the tab's code, so the two change together: the file that registers the window calls
--   ns.Help.Register(id, def)          (Hard Counters' own tabs)
--   HardCounters:RegisterWindowHelp(id, def)   (a pack's window; docs/API.md §9)
-- def = { what = "one paragraph: what this tab is",
--         can = { "one thing you can do here", ... },         -- at least two
--         effect = "one paragraph: how it changes your play",
--         tour = { { title = "...", text = "...", before = function() ... end }, ... } }   -- at least two steps
-- Keeping them true (the user: "may need to keep on track with future changes"): a name in braces, {New board...},
-- is the exact text of a button, menu item or tab; it is drawn in gold, and tests/help_spec.lua fails when no Lua
-- file of the addons has that text as a string any more (a renamed button with its help unchanged) or when a
-- registered window has no help. Ground rule, as for the tutorial: a change to a tab is checked against its help.
-- luacheck: no max line length (prose)
local ADDON, ns = ...

local HC, L, Wd = ns.HC, ns.L, ns.Widgets
local format = string.format

local Help = {}
ns.Help = Help

local defs = {}
local W, H = 440, 430
local TOP, BOTTOM = 62, 76             -- above the text (title, heading) and below it (the buttons)
local f, mode, cur, step = nil, "help", nil, 1

local function str(v) return type(v) == "string" and v ~= "" end

--- nil when def is a complete help definition, else what is wrong with it.
function Help.Check(def)
  if type(def) ~= "table" then return "def must be a table" end
  if not str(def.what) then return "def.what (what this tab is) is required" end
  if type(def.can) ~= "table" or #def.can < 2 then return "def.can must list at least two things you can do" end
  for _, c in ipairs(def.can) do if not str(c) then return "def.can holds strings" end end
  if not str(def.effect) then return "def.effect (how it changes your play) is required" end
  if type(def.tour) ~= "table" or #def.tour < 2 then return "def.tour needs at least two steps" end
  for _, s in ipairs(def.tour) do
    if type(s) ~= "table" or not str(s.title) or not str(s.text) then return "a tour step needs a title and a text" end
    if s.before ~= nil and type(s.before) ~= "function" then return "a tour step's before must be a function" end
  end
  return nil
end

--- Register a window's help and tour. Returns true, or false and why. Registering again replaces it.
function Help.Register(id, def)
  local why = Help.Check(def)
  if why then return false, why end
  defs[id] = def
  if ns.Windows and ns.Windows.RefreshHelpButtons then ns.Windows.RefreshHelpButtons() end
  return true
end

function Help.For(id) return defs[id] end

--- The registered windows that have no help (tests: must be empty).
function Help.Missing()
  local out = {}
  for _, id in ipairs(ns.Windows and ns.Windows.List() or {}) do
    if not defs[id] then out[#out + 1] = id end
  end
  return out
end

--- Every {name} in a text, in order.
function Help.Names(text)
  local out = {}
  for name in tostring(text or ""):gmatch("{(.-)}") do out[#out + 1] = name end
  return out
end

--- Every text of a definition (for the names check).
function Help.Texts(def)
  local out = { def.what, def.effect }
  for _, c in ipairs(def.can) do out[#out + 1] = c end
  for _, s in ipairs(def.tour) do out[#out + 1] = s.title; out[#out + 1] = s.text end
  return out
end

local function gold(s) return "|cffffd200" .. s .. "|r" end

--- A text for the screen: translated, its {names} in gold.
function Help.Render(text)
  return (L[text]:gsub("{(.-)}", function(name) return gold(L[name]) end))
end

local function tabTitle(id)
  local def = ns.Windows and ns.Windows.Def(id)
  return def and def.title or tostring(id)
end

---------------------------------------------------------------------------
-- The window: one frame, two uses (the Help page, the tour's steps)
---------------------------------------------------------------------------

local function setTitle(text)
  if type(f.SetTitle) == "function" then pcall(f.SetTitle, f, text)
  elseif type(f.TitleContainer) == "table" and type(f.TitleContainer.TitleText) == "table" then
    f.TitleContainer.TitleText:SetText(text)
  elseif f.plainTitle then f.plainTitle:SetText(text) end
end

local function place()
  if f.moved then return end
  f:ClearAllPoints()
  local m = ns.Windows and ns.Windows.Host("_main")
  if m and m:IsShown() then f:SetPoint("TOPRIGHT", m, "TOPLEFT", -6, 0)
  else f:SetPoint("CENTER", UIParent, "CENTER", -140, 40) end
end

local function render()
  local def = defs[cur]
  if not def then f:Hide(); return end
  local title = tabTitle(cur)
  if mode == "tour" then
    local s = def.tour[step]
    if s.before then
      local ok, err = pcall(s.before)
      if not ok and ns.Error then ns.Error(err) end
    end
    setTitle(format(L["Hard Counters: tutorial for %s"], title))
    f.head:SetText(L[s.title])
    f.body:SetText(Help.Render(s.text))
    f.count:SetText(format(L["Step %d of %d"], step, #def.tour))
    f.back:Show()
    f.back:SetEnabled(step > 1)
    f.next:SetText(step == #def.tour and L["Finish"] or L["Next"])
    f.act:SetText(L["Help for this tab"])
  else
    setTitle(format(L["Hard Counters: %s help"], title))
    f.head:SetText(title)
    local out = { Help.Render(def.what), "", gold(L["What you can do here"]) }
    for _, c in ipairs(def.can) do out[#out + 1] = "  - " .. Help.Render(c) end
    out[#out + 1] = ""
    out[#out + 1] = gold(L["How it changes your play"])
    out[#out + 1] = Help.Render(def.effect)
    f.body:SetText(table.concat(out, "\n"))
    f.count:SetText("")
    f.back:Hide()
    f.next:SetText(L["Close"])
    f.act:SetText(L["Take this tab's tutorial"])
  end
  Wd.FitWidth(f.act, 140, 32)
  -- as tall as its text needs (a Help page with many bullets), never shorter than H
  local th = f.body.GetStringHeight and f.body:GetStringHeight()
  f:SetHeight(math.max(H, (type(th) == "number" and th or 0) + TOP + BOTTOM))
  place()
  f:Raise()
end

local function build()
  local ok
  ok, f = pcall(CreateFrame, "Frame", "HardCountersHelp", UIParent, "ButtonFrameTemplate")
  if not ok or type(f) ~= "table" then
    f = CreateFrame("Frame", "HardCountersHelp", UIParent)
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
  if type(f.CloseButton) == "table" then f.CloseButton:SetScript("OnClick", function() f:Hide() end) end
  tinsert(UISpecialFrames, "HardCountersHelp")                 -- Escape closes it
  f.head = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  f.head:SetPoint("TOPLEFT", 20, -36)
  f.head:SetPoint("TOPRIGHT", -20, -36)
  f.head:SetJustifyH("LEFT")
  f.body = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  f.body:SetPoint("TOPLEFT", 20, -TOP)
  f.body:SetPoint("TOPRIGHT", -20, -TOP)
  f.body:SetJustifyH("LEFT")
  f.body:SetJustifyV("TOP")
  f.body:SetSpacing(2)
  -- the other use of this window: from the Help page to the tour, from a tour step to the Help page
  f.act = Wd.Button(f, "", 160, function()
    if mode == "tour" then Help.Show(cur) else Help.Tour(cur, 1) end
  end)
  f.act:SetHeight(24)
  f.act:SetPoint("BOTTOMLEFT", 16, 36)
  f.count = Wd.Text(f, "GameFontDisableSmall", "BOTTOMLEFT", 18, 15)
  f.next = Wd.Button(f, L["Next"], 90, function()
    if mode == "tour" then Help.Tour(cur, step + 1) else f:Hide() end
  end)
  f.next:SetPoint("BOTTOMRIGHT", -16, 10)
  f.back = Wd.Button(f, L["Back"], 80, function() Help.Tour(cur, step - 1) end)
  f.back:SetPoint("RIGHT", f.next, "LEFT", -6, 0)
  Wd.RichTip(f.next, function() return { title = f.next:GetText(), text = mode == "tour" and L["The next step of this tab's tutorial (Finish on the last one)."] or L["Close this page."] } end)
  Wd.RichTip(f.back, function() return { title = L["Back"], text = L["The step before."] } end)
  Wd.RichTip(f.act, function() return { title = f.act:GetText(), text = mode == "tour" and L["This tab's help page: what it is, what you can do, how it changes your play."] or L["A few steps through this tab, opening it as it goes."] } end)
end

--- The Help page of a window (nil: the open tab's). Returns the frame, or nil when that window has no help.
function Help.Show(id)
  id = id or (ns.Windows and ns.Windows.Selected())
  if not defs[id] then return nil end
  if not f then build() end
  mode, cur, step = "help", id, 1
  f:Show()
  render()
  return f
end

--- A window's tour at step n (nil: the open tab's, from its first step; past the last step it ends). The tour opens
--- the Hard Counters window on that tab.
function Help.Tour(id, n)
  id = id or (ns.Windows and ns.Windows.Selected())
  local def = defs[id]
  if not def then return nil end
  if not f then build() end
  n = n or 1
  if n > #def.tour then f:Hide(); return nil end
  mode, cur, step = "tour", id, math.max(1, n)
  if ns.Windows and not ns.Windows.IsShown(id) then ns.Windows.Show(id, true) end
  f:Show()
  render()
  return f
end

function Help.Hide() if f then f:Hide() end end
function Help.Frame() return f end
function Help.State() return mode, cur, step end

--- Public (docs/API.md §9): the help and the tour of a pack's window, shown by the Help and Tab tour buttons while
--- that tab is open. Returns true, or false and why.
function HC:RegisterWindowHelp(id, def)
  if type(id) ~= "string" or not (ns.Windows and ns.Windows.Def(id)) then return false, "register the window first" end
  return Help.Register(id, def)
end

--- A window by a typed word: its id ("boards", "hcfarm:ledger") or its title ("ledger", "character stats").
local function find(word)
  word = (word or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
  if word == "" then return ns.Windows and ns.Windows.Selected() end
  for id in pairs(defs) do
    if id:lower() == word or tabTitle(id):lower() == word or id:lower():match(":(.+)$") == word then return id end
  end
  return nil
end

--- /hc tutorial <tab> (and the old /hc tour, unlisted): that tab's tutorial. True when it found the tab; with no
--- name, the open tab's. An unknown name prints the tab names.
function Help.TutorialByName(rest)
  local id = find(rest)
  if id and defs[id] then Help.Tour(id, 1); return true end
  local names = {}
  for k in pairs(defs) do names[#names + 1] = tabTitle(k):lower() end
  table.sort(names)
  ns.Print(L["/hc tutorial <tab>: %s"], table.concat(names, ", "))
  return false
end
ns.AddSlash("tour", function(rest) Help.TutorialByName(rest) end)
