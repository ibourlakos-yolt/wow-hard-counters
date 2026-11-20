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
