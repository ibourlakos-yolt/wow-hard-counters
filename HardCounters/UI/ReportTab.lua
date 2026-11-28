-- The Report a problem tab (0.5.0, DESIGN §17.16 F1; the user, 2026-11-28: "Detach report material (content and
-- actions) from diagnostics. Create a secondary tab that handles report stuff; this should be enabled by default for
-- all releases regardless of diagnostics pack status ... Eliminate the separate panel with the garbled report text,
-- it should just appear in the new view"). A tab along the bottom, between Options and Diagnostics, always there.
--   left    what went wrong (an optional line, carried as body.note), the three ticks, what is in it, and with
--           Diagnostics loaded its helpers (run the checks, mark the log) and its console; without it, the Packs tab
--   right   the report to copy: read-only (typing puts it back), all selected on show and after every rebuild
--   bottom  Select all, the Ctrl+C hint, the size, "Shortened to fit" when the report was cut
-- The ticks start as they always did at each show (class and addon list on, name and realm off; the user,
-- 2026-11-25) and are never saved. The note lasts until the next reload, never saved either. The text is
-- ns.BuildReport's (Core/Report.lua); Diagnostics' helpers come through the bridge (ns.reportTools,
-- Core/DiagBridge.lua). ns.ShowReportBox(opts) opens the tab: /hc report, the Overview, Diagnostics' Report button.
local ADDON, ns = ...

local L, Wd = ns.L, ns.Widgets
local format, max = string.format, math.max

local ID = "report"
local PAD, LEFT_W, GAP, MIN_W, MIN_H = 12, 250, 14, 600, 420
local OPTS = { "class", "addons", "name" }
local AMBER = { 1, 0.75, 0.1 }
local content
local note = ""             -- the player's note: kept until the next reload, never saved
local pending, shows = nil, 0

--- The ticks at a show: class and the addon list on, the name off. opts can only tick more (a caller can't untick
--- what the player is shown ticked).
local function defaults(opts)
  local o = { class = true, addons = true }
  if type(opts) == "table" then
    for _, k in ipairs(OPTS) do if opts[k] then o[k] = true end end
  end
  return o
end

local function selectAll()
  if not content then return end
  content.edit:SetFocus()
  content.edit:HighlightText()
end

--- Build the report again from the ticks and the note, and select it.
local function rebuild()
  local f = content
  if not (f and f.opts) then return end
  f.opts.note = note ~= "" and note or nil
  local ok, str, body = pcall(ns.BuildReport, f.opts)
  if not ok then
    ns.Error(str)
    str, body = "", nil
    f.summary:SetText(L["could not build the report (see BugSack)"])
  else
    f.summary:SetText(L["What is in it:"] .. "\n- " .. table.concat(ns.ReportSummary(body), "\n- "))
  end
  for _, k in ipairs(OPTS) do f.checks[k]:SetChecked(f.opts[k] and true or false) end
  f.body, f.text = body, str
  f.edit:SetText(str)
  f.size:SetText(format(L["%s characters"], ns.U.number(#str, 0)))
  f.short:SetShown(body and body.truncated and true or false)
  local tools = ns.reportTools
  f.diagOn:SetShown(tools ~= nil)
  f.diagOff:SetShown(tools == nil)
  selectAll()
end
ns.RebuildReport = rebuild                                         -- (tests)

-- the note leaves its box (Enter, a click elsewhere, the tab closing): keep it, rebuild if it changed
local function commitNote()
  if not content then return end
  local t = content.noteBox:GetText() or ""
  if t == note then return end
  note = t
  if content:IsShown() then rebuild() end
end

local function check(parent, label)
  local ok, c = pcall(CreateFrame, "CheckButton", nil, parent, "UICheckButtonTemplate")
  if not ok or type(c) ~= "table" then
    c = CreateFrame("CheckButton", nil, parent)
    c:SetNormalTexture("Interface\\Buttons\\UI-CheckBox-Up")
    c:SetCheckedTexture("Interface\\Buttons\\UI-CheckBox-Check")
  end
  c:SetSize(24, 24)
  c.label = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  c.label:SetPoint("LEFT", c, "RIGHT", 2, 0)
  c.label:SetText(label)
  return c
end

-- a right-click menu opens where the pointer is, not under the whole text box
local function cursorAnchor(f)
  local a = f.cursor
  if not a then
    a = CreateFrame("Frame", nil, f)
    a:SetSize(1, 1)
    f.cursor = a
  end
  local x, y = 0, 0
  if GetCursorPosition then x, y = GetCursorPosition() end
  local s = UIParent:GetEffectiveScale()
  if type(s) ~= "number" or s <= 0 then s = 1 end
  a:ClearAllPoints()
  a:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", (x or 0) / s, (y or 0) / s)
  return a
end

local function textWidth(f)
  local w = f:GetWidth()
  if type(w) ~= "number" then w = MIN_W end
  return max(w - (PAD + LEFT_W + GAP) - 40, 200)
end

local function build(f)
  content = f
  f.opts, f.checks = defaults(), {}

  f.intro = Wd.Text(f, "GameFontHighlightSmall", "TOPLEFT", PAD, -10)
  f.intro:SetPoint("TOPRIGHT", -PAD, -10)
  f.intro:SetText(L["This makes a text for whoever asked you for a report. Hard Counters sends nothing: you copy the "
    .. "text and paste it yourself. Pasted into a GitHub issue it is public. Your class and your list of addons are "
    .. "in it unless you untick them; your character's name and realm only if you tick that box."])

  -- left: the note, the ticks, what is in it
  f.noteLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  f.noteLabel:SetPoint("TOPLEFT", f.intro, "BOTTOMLEFT", 0, -12)
  f.noteLabel:SetText(L["What went wrong? (optional)"])
  local nb = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
  nb:SetSize(LEFT_W - 10, 20)
  nb:SetPoint("TOPLEFT", f.noteLabel, "BOTTOMLEFT", 6, -4)
  nb:SetAutoFocus(false)
  nb:SetMaxLetters(ns.REPORT_NOTE_MAX)
  nb:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
  nb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  nb:SetScript("OnEditFocusLost", commitNote)
  Wd.RichTip(nb, function() return { title = L["What went wrong?"],
    text = L["A line in your own words: what you did, what you expected. It goes in the report as you write it."],
    click = L["Enter or a click elsewhere puts it in the report."] } end)
  f.noteBox = nb

  local labels = { name = L["Include my character's name"], class = L["Include my character's class"],
    addons = L["Include my addon list"] }
  local prev = nb
  for i, k in ipairs(OPTS) do
    local c = check(f, labels[k])
    c:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", i == 1 and -6 or 0, i == 1 and -8 or 0)
    c:SetScript("OnClick", function()
      f.opts[k] = not f.opts[k] or nil
      rebuild()
    end)
    f.checks[k] = c
    prev = c
  end

  f.summary = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  f.summary:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", 0, -8)
  f.summary:SetWidth(LEFT_W)
  f.summary:SetJustifyH("LEFT")

  -- left, at the bottom: Diagnostics' helpers when it is loaded, else where to turn it on
  local on = CreateFrame("Frame", nil, f)
  on:SetSize(LEFT_W, 74)
  on:SetPoint("BOTTOMLEFT", PAD, 10)
  local function tool(text, y, name, tipText, after)
    local b = Wd.Button(on, text, 170, function()
      local tools = ns.reportTools
      if not (tools and tools[name]) then return end
      local ok, err = pcall(tools[name])
      if not ok then ns.Error(err) end
      if after then after() end
    end)
    b:SetHeight(22)
    b:SetPoint("TOPLEFT", 0, y)
    Wd.RichTip(b, function() return { title = text, text = tipText } end)
    return b
  end
  f.runBtn = tool(L["Run the checks first"], 0, "runChecks",
    L["Diagnostics checks the game's API now, so the report carries fresh results."], rebuild)
  f.markBtn = tool(L["Mark the log now"], -26, "mark",
    L["Click just before you make the problem happen again, then come back and copy."])
  f.openBtn = tool(L["Open Diagnostics"], -52, "open", L["The Diagnostics tab: the log, live values, storage and the checks."])
  f.diagOn = on

  local off = CreateFrame("Frame", nil, f)
  off:SetSize(LEFT_W, 60)
  off:SetPoint("BOTTOMLEFT", PAD, 10)
  local offText = Wd.Text(off, "GameFontDisableSmall", "TOPLEFT", 0, 0, LEFT_W)
  offText:SetText(L["Diagnostics is off: the report is shorter. The Packs tab turns it on."])
  local packs = Wd.Button(off, L["Packs"], 90, function() if ns.ShowPacks then ns.ShowPacks(true) end end)
  packs:SetPoint("BOTTOMLEFT", 0, 0)
  Wd.RichTip(packs, function() return { title = L["Packs"],
    text = L["Tick Diagnostics in the Packs tab: a report then carries the game's API checks."] } end)
  f.diagOff, f.packsBtn = off, packs

  -- right: the report, read-only, on a dark ground
  local bg = f:CreateTexture(nil, "BACKGROUND")
  bg:SetPoint("TOPLEFT", f.noteLabel, "TOPLEFT", LEFT_W + GAP - 4, 4)
  bg:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -PAD, 36)
  bg:SetColorTexture(0, 0, 0, 0.3)
  local scroll = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", f.noteLabel, "TOPLEFT", LEFT_W + GAP, 0)
  scroll:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -PAD - 22, 40)
  local edit = CreateFrame("EditBox", nil, scroll)
  edit:SetMultiLine(true)
  edit:SetMaxLetters(0)
  edit:SetAutoFocus(false)
  edit:SetFontObject(ChatFontNormal)
  edit:SetWidth(textWidth(f))
  edit:SetScript("OnEscapePressed", function(self) self:ClearFocus(); ns.Windows.ShowMain(false) end)
  edit:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
  edit:SetScript("OnMouseUp", function(self, button)
    if button == "RightButton" then
      ns.Menu.Show(cursorAnchor(f), { { text = L["Select all"], func = selectAll } })
    else
      self:HighlightText()
    end
  end)
  -- keep the text as built: typing into the box doesn't change what gets copied
  edit:SetScript("OnTextChanged", function(self, userInput)
    if userInput and f.text then self:SetText(f.text); self:HighlightText() end
  end)
  scroll:SetScrollChild(edit)
  f.scroll, f.edit = scroll, edit

  -- bottom: Select all, the hint, the size
  f.selectBtn = Wd.Button(f, L["Select all"], 90, selectAll)
  f.selectBtn:SetPoint("BOTTOMLEFT", PAD + LEFT_W + GAP, 10)
  Wd.RichTip(f.selectBtn, function() return { title = L["Select all"],
    text = L["Selects the whole report. Then Ctrl+C copies it, and you paste it where you report the problem."] } end)
  f.hint = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  f.hint:SetPoint("LEFT", f.selectBtn, "RIGHT", 8, 0)
  f.hint:SetText(L["Ctrl+C copies."])
  f.size = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  f.size:SetPoint("BOTTOMRIGHT", -PAD, 14)
  f.short = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  f.short:SetPoint("RIGHT", f.size, "LEFT", -12, 0)
  f.short:SetText(L["Shortened to fit"])
  f.short:SetTextColor(AMBER[1], AMBER[2], AMBER[3])
  f.short:Hide()

  f:SetScript("OnSizeChanged", function(self) edit:SetWidth(textWidth(self)) end)
end

ns.Windows.Register(ID, {
  title = L["Report a problem"], icon = "Interface\\Icons\\INV_Letter_15", place = "bottom", bottomOrder = 950,
  about = "Make the text to paste when you report a problem. Nothing is sent: you copy it.",
  width = 720, height = 480, minWidth = MIN_W, minHeight = MIN_H,
  build = build,
  onShow = function(f)
    shows = shows + 1
    f.opts = defaults(pending)
    pending = nil
    f.noteBox:SetText(note)
    f.edit:SetWidth(textWidth(f))
    rebuild()
  end,
  onHide = function(f)
    f.noteBox:ClearFocus()           -- (keeps the note: the box's focus-lost handler)
    f.edit:ClearFocus()
  end,
})

--- Open the Report a problem tab (/hc report, the Overview, Diagnostics' Report button) and return its content
--- frame: opts (the ticks and the note), checks, edit, summary, size, text, body. (The user, 2026-11-25) Class and
--- the addon list start ticked at every opening: they are what makes a tester's report readable (a probe result
--- means one thing on a mage, another on a warrior; a conflict needs the addon list) and neither names anyone. The
--- character's name and realm start unticked. All three are boxes the player sees and can change before copying;
--- nothing is saved between openings. The tab's first lines, README and the CurseForge page say so: change them
--- together.
function ns.ShowReportBox(opts)
  pending = opts
  local before = shows
  ns.Windows.Show(ID, true)
  if content and shows == before then         -- already on screen (no OnShow): start over the same way
    content.opts = defaults(opts)
    rebuild()
  end
  pending = nil
  return content
end

-- This tab's help and tutorial (UI/Help.lua): change them with the tab.
-- luacheck: push no max line length
local _ = ns.Help and ns.Help.Register(ID, {
  what = "Report a problem makes the text to paste when you report a problem with Hard Counters: to a friend who asked, or into a bug report on GitHub. It is there with or without Diagnostics; with Diagnostics loaded the report also carries its checks of the game's API.",
  can = {
    "Say in a line what went wrong (optional): it goes in the report as you write it.",
    "Choose what goes in: {Include my character's class} and {Include my addon list} start ticked, {Include my character's name} does not. They start that way every time and are never saved.",
    "Read what the report holds under What is in it, then {Select all} and press Ctrl+C. A right-click on the text offers {Select all} too.",
    "With Diagnostics loaded: {Run the checks first} for fresh results, and {Mark the log now} just before you make the problem happen again.",
  },
  effect = "Nothing here changes your play or leaves your computer. The report is text you copy and paste yourself; whatever you paste into a public bug report is public.",
  tour = {
    { title = "Say what happened, tick what may go in", text = "Write a line on what went wrong if you like, then tick or untick your class, your addon list and your name. The report on the right is made again at each change." },
    { title = "Select all, Ctrl+C, paste", text = "{Select all} selects the whole report; Ctrl+C copies it. Paste it into the bug report or the message to whoever asked, with what you did and what you expected." },
  },
})
-- luacheck: pop
