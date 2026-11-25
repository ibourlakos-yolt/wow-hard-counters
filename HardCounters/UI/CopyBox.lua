-- CopyBox: a text box that selects everything on show, for Ctrl+A, Ctrl+C (WoW has no clipboard API).
-- Used by /hc report and by HardCounters_Diagnostics. Built without templates beyond the standard close button
-- and scroll frame, which exist on every client.
local ADDON, ns = ...

local box

local function build()
  local f = CreateFrame("Frame", "HardCountersCopyBox", UIParent)
  f:SetSize(640, 420)
  f:SetPoint("CENTER")
  f:SetFrameStrata("DIALOG")
  f:SetMovable(true)
  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving)
  f:SetScript("OnDragStop", f.StopMovingOrSizing)
  f:SetClampedToScreen(true)

  local bg = f:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  bg:SetColorTexture(0.05, 0.05, 0.07, 0.92)

  f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  f.title:SetPoint("TOPLEFT", 12, -10)

  f.hint = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  f.hint:SetPoint("BOTTOMLEFT", 12, 8)
  f.hint:SetText(ns.L["Ctrl+A, Ctrl+C to copy. Esc closes."])

  local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", 2, 2)

  local scroll = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", 12, -32)
  scroll:SetPoint("BOTTOMRIGHT", -32, 26)

  local edit = CreateFrame("EditBox", nil, scroll)
  edit:SetMultiLine(true)
  edit:SetMaxLetters(0)
  edit:SetAutoFocus(false)
  edit:SetFontObject(ChatFontNormal)
  edit:SetWidth(580)
  edit:SetScript("OnEscapePressed", function() f:Hide() end)
  edit:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
  edit:SetScript("OnMouseUp", function(self) self:HighlightText() end)
  -- keep the text as given: typing into the box doesn't change what gets copied
  edit:SetScript("OnTextChanged", function(self, userInput)
    if userInput and f.text then self:SetText(f.text); self:HighlightText() end
  end)
  scroll:SetScrollChild(edit)
  f.edit = edit

  -- resizable, BlizzMove-aware, remembered (ns.Widgets loads after this file, but before anything shows the box)
  ns.Widgets.Remember(f, "copyBox", 360, 200, function(self) edit:SetWidth(math.max(self:GetWidth() - 60, 100)) end)
  tinsert(UISpecialFrames, "HardCountersCopyBox")
  return f
end

function ns.ShowCopyBox(title, text)
  box = box or build()
  box.title:SetText(title or ns.L["Hard Counters"])
  box.text = text or ""
  box.edit:SetText(box.text)
  box:Show()
  box.edit:SetFocus()
  box.edit:HighlightText()
end

---------------------------------------------------------------------------
-- The report window (HC-61): what the report is for, what is in it, the opt-ins, then the string to copy.
-- The opt-ins start off every time the window opens and are never saved (anonymous by default).
---------------------------------------------------------------------------

local report
local REPORT_OPTS = { "name", "class", "addons" }

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

local function refreshReport(f)
  local ok, str, body = pcall(ns.BuildReport, f.opts)
  if not ok then
    ns.Error(str)
    str = ""
    f.summary:SetText(ns.L["could not build the report (see BugSack)"])
  else
    f.summary:SetText(ns.L["What is in it:"] .. "\n- " .. table.concat(ns.ReportSummary(body), "\n- "))
  end
  for _, k in ipairs(REPORT_OPTS) do f.checks[k]:SetChecked(f.opts[k] and true or false) end
  f.text = str
  f.edit:SetText(str)
  f.size:SetText(string.format(ns.L["%s characters"], ns.U.number(#str, 0)))
  f.edit:SetFocus()
  f.edit:HighlightText()
end

local function buildReport()
  local L = ns.L
  local f = CreateFrame("Frame", "HardCountersReportBox", UIParent)
  f:SetSize(640, 520)
  f:SetPoint("CENTER")
  f:SetFrameStrata("DIALOG")
  f:SetToplevel(true)
  f:SetMovable(true)
  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving)
  f:SetScript("OnDragStop", f.StopMovingOrSizing)
  f:SetClampedToScreen(true)

  local bg = f:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  bg:SetColorTexture(0.05, 0.05, 0.07, 0.95)

  f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  f.title:SetPoint("TOPLEFT", 12, -10)
  f.title:SetText(L["Hard Counters report"])

  local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", 2, 2)

  f.intro = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  f.intro:SetPoint("TOPLEFT", 12, -32)
  f.intro:SetWidth(612)
  f.intro:SetJustifyH("LEFT")
  f.intro:SetText(L["This report helps fix and improve Hard Counters. The addon sends nothing: you copy the text "
    .. "below and paste it to whoever asked for it. Pasted into a GitHub issue it is public. It includes your "
    .. "character's class and the list of addons you have installed unless you untick them below; your character's "
    .. "name and realm only if you tick that box. Zone, map and spell IDs in it can hint at where you play. The "
    .. "lines under this one say what this report holds."])

  f.summary = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  f.summary:SetPoint("TOPLEFT", f.intro, "BOTTOMLEFT", 0, -8)
  f.summary:SetWidth(612)
  f.summary:SetJustifyH("LEFT")

  f.opts, f.checks = {}, {}
  local labels = { name = L["Include my character's name"], class = L["Include my character's class"],
    addons = L["Include my addon list"] }
  local x = 0
  for _, k in ipairs(REPORT_OPTS) do
    local c = check(f, labels[k])
    c:SetPoint("TOPLEFT", f.summary, "BOTTOMLEFT", x, -8)
    c:SetScript("OnClick", function()
      f.opts[k] = not f.opts[k] or nil
      refreshReport(f)
    end)
    f.checks[k] = c
    x = x + 205
  end

  f.hint = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  f.hint:SetPoint("BOTTOMLEFT", 12, 8)
  f.hint:SetText(L["Ctrl+A, Ctrl+C to copy. Esc closes."])
  f.size = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  f.size:SetPoint("BOTTOMRIGHT", -12, 8)

  local scroll = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", f.checks.name, "BOTTOMLEFT", 0, -6)
  scroll:SetPoint("BOTTOMRIGHT", -32, 26)
  local edit = CreateFrame("EditBox", nil, scroll)
  edit:SetMultiLine(true)
  edit:SetMaxLetters(0)
  edit:SetAutoFocus(false)
  edit:SetFontObject(ChatFontNormal)
  edit:SetWidth(580)
  edit:SetScript("OnEscapePressed", function() f:Hide() end)
  edit:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
  edit:SetScript("OnMouseUp", function(self) self:HighlightText() end)
  edit:SetScript("OnTextChanged", function(self, userInput)
    if userInput and f.text then self:SetText(f.text); self:HighlightText() end
  end)
  scroll:SetScrollChild(edit)
  f.edit = edit

  tinsert(UISpecialFrames, "HardCountersReportBox")
  return f
end

--- Open the report window. (The user, 2026-11-25) Class and the addon list start ticked at every opening: they are
--- what makes a tester's report readable (a probe result means one thing on a mage, another on a warrior; a
--- conflict needs the addon list) and neither names anyone. The character's name and realm start unticked. All
--- three are boxes the player sees and can change before copying; nothing is saved between openings. The window's
--- first lines, README and the CurseForge page say so: change them together.
function ns.ShowReportBox(_opts)
  report = report or buildReport()
  report.opts = { class = true, addons = true }
  report:Show()
  refreshReport(report)
  return report
end
