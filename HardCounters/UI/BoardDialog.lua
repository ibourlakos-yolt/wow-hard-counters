-- The New board dialog (DESIGN §17.4, HC-68). Every way to make a board opens it: the Boards tab, the launcher, a
-- board's [+] menu, Options, `/hc board new` without a name. Fields: Name (required, at most 24 letters, unique
-- ignoring case: a taken name suggests "<name> 2"; it shows the `/hc board` command that will toggle it), Start from
-- (presets by pack, your presets, Empty board, Copy of a board: its own tiles, not shared; this character's boards,
-- then each other character's and 0.2's shared ones, HC-74), Show it (in combat, in
-- instances, only during runs: the board's own rules). Create puts the board at the centre of the screen with one
-- flash; an empty board opens in edit mode. Enter creates, Escape cancels. DIALOG strata, above everything of ours
-- but menus.
local ADDON, ns = ...

local L, Wd = ns.L, ns.Widgets
local format = string.format

local Dialog = {}
ns.BoardDialog = Dialog

local f
-- { kind = "preset", key } | { kind = "empty" } | { kind = "copy", board, from = its store, who = its character }
-- (from and who only for another character's board or 0.2's shared ones)
local choice = { kind = "empty" }
local nameTouched = false               -- the player typed a name: picking a start no longer replaces it
local rules = { combat = true, instance = true, runOnly = false }

local function BM() return ns.BoardModel end

local WHY = {
  empty = "A board needs a name.",
  long = "At most 24 letters.",
  taken = "Another board has this name. Try %s.",
}

local function trim(s) return ((s or ""):match("^%s*(.-)%s*$")) end

local function startText()
  if choice.kind == "empty" then return L["Empty board"] end
  if choice.kind == "copy" then
    local s = format(L["Copy of %s"], choice.board.name)
    return choice.who and (s .. " (" .. choice.who .. ")") or s
  end
  local p = BM().Preset(choice.key)
  return p and p.name or "?"
end

local function suggested()
  if choice.kind == "copy" then return choice.board.name end
  if choice.kind == "preset" then
    local p = BM().Preset(choice.key)
    if p then return p.name end
  end
  return L["Board"]
end

--- The name's state under the field: the command that will toggle the board, or why it can't be created.
local function validate()
  local name = f.name:GetText() or ""
  local ok, why = BM().CheckName(name)
  if ok then
    f.note:SetText(format(L["/hc board %s will show or hide it."], trim(name):lower()))
    f.note:SetTextColor(0.6, 0.6, 0.6)
  else
    local msg = L[WHY[why] or "?"]
    if why == "taken" then msg = format(msg, BM().FreeName(name)) end
    f.note:SetText(msg)
    f.note:SetTextColor(1, 0.4, 0.4)
  end
  f.create:SetEnabled(ok)
  return ok
end

local function setName(text)
  f.quiet = true
  f.name:SetText(text)
  f.quiet = false
  validate()
end

local function setChoice(c)
  choice = c
  f.start:SetText(startText())
  if not nameTouched then setName(BM().FreeName(suggested())) else validate() end
end

local function startItems()
  local items = {}
  for _, g in ipairs(BM().PresetGroups()) do
    items[#items + 1] = { text = L[g.title], title = true }
    for _, key in ipairs(g.keys) do
      local p = BM().Preset(key)
      items[#items + 1] = { text = "  " .. p.name, checked = choice.kind == "preset" and choice.key == key,
        func = function() setChoice({ kind = "preset", key = key }) end }
    end
  end
  items[#items + 1] = { text = L["Other"], title = true }
  items[#items + 1] = { text = "  " .. L["Empty board"], checked = choice.kind == "empty",
    tip = L["Opens for editing: add numbers with its [+]"], func = function() setChoice({ kind = "empty" }) end }
  local copies = {}
  local function isChosen(b) return choice.kind == "copy" and choice.board == b end
  for _, b in ipairs(BM().Store().list) do
    copies[#copies + 1] = { text = b.name, checked = isChosen(b), func = function() setChoice({ kind = "copy", board = b }) end }
  end
  -- (HC-74) another character's boards, or 0.2's shared ones: a copy of your own, to change as you like
  for _, o in ipairs(BM().OtherBoards()) do
    local who = o.shared and L[o.name] or o.name
    local sub = {}
    for _, b in ipairs(o.boards) do
      if type(b) == "table" and type(b.name) == "string" then
        sub[#sub + 1] = { text = b.name, checked = isChosen(b),
          func = function() setChoice({ kind = "copy", board = b, from = o.store, who = who }) end }
      end
    end
    if #sub > 0 then copies[#copies + 1] = { text = who, sub = sub } end
  end
  if #copies > 0 then
    items[#items + 1] = { text = "  " .. L["Copy of a board"], sub = copies,
      tip = L["Its tiles, as copies of their own: changing one board doesn't change the other."] }
  end
  return items
end

local function check(parent, label, y, key)
  local ok, c = pcall(CreateFrame, "CheckButton", nil, parent, "UICheckButtonTemplate")
  if not ok or type(c) ~= "table" then
    c = CreateFrame("CheckButton", nil, parent)
    c:SetNormalTexture("Interface\\Buttons\\UI-CheckBox-Up")
    c:SetCheckedTexture("Interface\\Buttons\\UI-CheckBox-Check")
  end
  c:SetSize(24, 24)
  c:SetPoint("TOPLEFT", 100, y)
  c.label = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  c.label:SetPoint("LEFT", c, "RIGHT", 2, 0)
  c.label:SetText(label)
  c.key = key
  c:SetScript("OnClick", function(self)
    rules[self.key] = not rules[self.key]
    self:SetChecked(rules[self.key])
  end)
  return c
end

local function create()
  if not validate() then return nil end
  local name = trim(f.name:GetText())
  local M = BM()
  local b
  if choice.kind == "copy" and choice.board then b = M.Duplicate(choice.board, name, choice.from)
  else b = M.Create(choice.kind == "preset" and choice.key or nil, { name = name }) end
  b.show = b.show or {}
  local fade = b.show.combat == "fade"
  b.show.combat = rules.combat and (fade and "fade" or "show") or "hide"
  b.show.instance = rules.instance and "show" or "hide"
  b.show.runOnly = rules.runOnly and true or false
  b.pos = { "CENTER", 0, 0, "CENTER" }
  b.shown = true
  f:Hide()
  if ns.Boards then ns.Boards.Created(b, choice.kind == "empty") end
  return b
end
Dialog.Create = create

local function build()
  local ok
  ok, f = pcall(CreateFrame, "Frame", "HardCountersNewBoard", UIParent, "ButtonFrameTemplate")
  if not ok or type(f) ~= "table" then
    f = CreateFrame("Frame", "HardCountersNewBoard", UIParent)
    local bg = f:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.05, 0.05, 0.07, 0.95)
  end
  f:Hide()
  f:SetSize(380, 250)
  f:SetPoint("CENTER", UIParent, "CENTER", 0, 80)
  f:SetFrameStrata("DIALOG")
  f:SetToplevel(true)
  f:EnableMouse(true)
  f:SetMovable(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", function(self) self:StartMoving() end)
  f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
  f:SetClampedToScreen(true)
  local hide = rawget(_G, "ButtonFrameTemplate_HidePortrait")
  if type(hide) == "function" then pcall(hide, f) end
  if type(f.SetTitle) == "function" then pcall(f.SetTitle, f, L["New board"])
  elseif type(f.TitleContainer) == "table" and type(f.TitleContainer.TitleText) == "table" then
    f.TitleContainer.TitleText:SetText(L["New board"])
  end
  if type(f.CloseButton) == "table" then f.CloseButton:SetScript("OnClick", function() f:Hide() end) end
  tinsert(UISpecialFrames, "HardCountersNewBoard")             -- Escape cancels

  local function label(text, y)
    local s = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    s:SetPoint("TOPLEFT", 20, y)
    s:SetText(text)
    return s
  end
  label(L["Name"], -40)
  f.name = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
  f.name:SetSize(220, 20)
  f.name:SetPoint("TOPLEFT", 106, -36)
  f.name:SetAutoFocus(false)
  f.name:SetMaxLetters(BM().NAME_MAX)
  f.name:SetScript("OnTextChanged", function(self)
    if not f.quiet then nameTouched = true end
    validate()
  end)
  f.name:SetScript("OnEnterPressed", function() create() end)
  f.name:SetScript("OnEscapePressed", function() f:Hide() end)
  f.note = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  f.note:SetPoint("TOPLEFT", 100, -60)
  f.note:SetWidth(260)
  f.note:SetJustifyH("LEFT")
  label(L["Start from"], -88)
  f.start = Wd.Button(f, "", 226, function(self) ns.Menu.Show(self, startItems()) end)
  f.start:SetPoint("TOPLEFT", 100, -84)
  label(L["Show it"], -120)
  f.checks = {
    check(f, L["in combat"], -116, "combat"),
    check(f, L["in instances"], -138, "instance"),
    check(f, L["only while a run is open"], -160, "runOnly"),
  }
  f.create = Wd.Button(f, L["Create"], 90, function() create() end)
  f.create:SetPoint("BOTTOMRIGHT", -16, 14)
  f.cancel = Wd.Button(f, L["Cancel"], 90, function() f:Hide() end)
  f.cancel:SetPoint("RIGHT", f.create, "LEFT", -6, 0)
  f:SetScript("OnHide", function() if ns.Menu then ns.Menu.Hide() end end)
end

--- Open the dialog. opts: { preset = key } or { copy = board, from = its store, who = its character's name } to start
--- from; nil: the first of Hard Counters' presets. The name starts as the start's name, made free.
function Dialog.Open(opts)
  opts = opts or {}
  if not f then build() end
  nameTouched = false
  rules.combat, rules.instance, rules.runOnly = true, true, false
  for _, c in ipairs(f.checks) do c:SetChecked(rules[c.key]) end
  if opts.copy then
    setChoice({ kind = "copy", board = opts.copy, from = opts.from, who = opts.who })
  elseif opts.empty then
    setChoice({ kind = "empty" })
  else
    local key = opts.preset
    if not (key and BM().Preset(key)) then key = BM().PRESET_ORDER[1] end
    setChoice(key and { kind = "preset", key = key } or { kind = "empty" })
  end
  f:Show()
  f:Raise()
  f.name:SetFocus()
  f.name:HighlightText()
  return f
end

function Dialog.Frame() return f end
function Dialog.Choice() return choice end
