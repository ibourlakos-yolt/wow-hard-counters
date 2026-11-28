-- Synopsis (0.5.0, DESIGN §17.16 G2 and G3; the user: "a details mini action that pops up a synopsis mini window ...
-- of how each value came to be", and on the HUD "a tooltip ... dismissable on clicking anywhere else"): one frame,
-- two modes, drawing BoardModel.Explain's lines.
--
--   ns.Synopsis.Show(anchor, tile, board, "panel")  -- in the Hard Counters window: a close button, a click outside
--                                                    -- or Escape closes it
--   ns.Synopsis.Show(anchor, tile, board, "tip")    -- on the HUD: no button, takes no mouse; any click closes it
--
-- It redraws once a second while shown. Our own frame, not GameTooltip: on the HUD the next unit under the mouse
-- would write over GameTooltip.
local ADDON, ns = ...

local L, Wd = ns.L, ns.Widgets
local floor, max = math.floor, math.max

local S = {}
ns.Synopsis = S

local W, PAD, LABEL_W, LINE_GAP = 340, 10, 92, 3
local TIP_LIFE = 30                -- a tooltip goes by itself after this many seconds
local f, catcher, ticker, events
local cur = { tile = nil, board = nil, mode = nil, anchor = nil, since = 0 }

local function hairEdges(frame, r, g, b, a)
  for i, side in ipairs({ "TOP", "BOTTOM", "LEFT", "RIGHT" }) do
    local t = frame:CreateTexture(nil, "BORDER")
    t:SetColorTexture(r, g, b, a)
    if i <= 2 then
      t:SetPoint(side .. "LEFT", frame, side .. "LEFT", 0, 0)
      t:SetPoint(side .. "RIGHT", frame, side .. "RIGHT", 0, 0)
    else
      t:SetPoint("TOP" .. side, frame, "TOP" .. side, 0, 0)
      t:SetPoint("BOTTOM" .. side, frame, "BOTTOM" .. side, 0, 0)
    end
    Wd.Hairline(t, i <= 2)
  end
end

local function line(i)
  local ln = f.lines[i]
  if ln then return ln end
  ln = {}
  ln.label = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  ln.label:SetWidth(LABEL_W)
  ln.label:SetJustifyH("LEFT")
  ln.label:SetJustifyV("TOP")
  ln.text = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  ln.text:SetWidth(W - 2 * PAD - LABEL_W - 6)
  ln.text:SetJustifyH("LEFT")
  ln.text:SetJustifyV("TOP")
  ln.text:SetWordWrap(true)
  f.lines[i] = ln
  return ln
end

local function build()
  if f then return f end
  f = CreateFrame("Frame", "HardCountersSynopsis", UIParent)
  f:SetSize(W, 120)
  f:SetClampedToScreen(true)
  f:Hide()
  local bg = f:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  bg:SetColorTexture(0.05, 0.05, 0.07, 0.96)
  hairEdges(f, 0.6, 0.5, 0.2, 0.9)
  f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  f.title:SetPoint("TOPLEFT", PAD, -PAD)
  f.title:SetPoint("TOPRIGHT", -30, -PAD)
  f.title:SetJustifyH("LEFT")
  f.title:SetWordWrap(false)
  f.value = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
  f.value:SetPoint("TOPLEFT", f.title, "BOTTOMLEFT", 0, -3)
  f.value:SetJustifyH("LEFT")
  f.close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
  f.close:SetPoint("TOPRIGHT", 2, 2)
  f.close:SetScript("OnClick", function() S.Hide() end)
  f.lines = {}
  -- Escape closes the panel (the tooltip takes no keys)
  if UISpecialFrames then tinsert(UISpecialFrames, "HardCountersSynopsis") end
  f:SetScript("OnHide", function()
    if catcher then catcher:Hide() end
    if ticker then ticker:Cancel(); ticker = nil end
    if events then pcall(events.UnregisterEvent, events, "GLOBAL_MOUSE_DOWN") end
    cur.tile, cur.board, cur.mode, cur.anchor = nil, nil, nil, nil
  end)
  return f
end

--- Fill the frame from the tile's lines; its height follows them.
local function draw()
  if not (f and cur.tile) then return end
  local out = ns.BoardModel.Explain(cur.tile, cur.board)
  f.title:SetText(cur.mode == "panel" and (L["How this number is made"] .. ": " .. (out.title or "")) or (out.title or ""))
  f.value:SetText(out.value or "")
  local y = -PAD - 16 - 20 - 6
  for i, l in ipairs(out) do
    local ln = line(i)
    ln.label:ClearAllPoints()
    ln.label:SetPoint("TOPLEFT", PAD, y)
    ln.text:ClearAllPoints()
    ln.text:SetPoint("TOPLEFT", PAD + LABEL_W + 6, y)
    ln.label:SetText(l.label or "")
    ln.text:SetText(l.text or "")
    if l.warn then ln.text:SetTextColor(1, 0.75, 0.3) else ln.text:SetTextColor(0.9, 0.9, 0.9) end
    ln.label:Show(); ln.text:Show()
    local h = ln.text.GetStringHeight and ln.text:GetStringHeight()
    y = y - max(12, type(h) == "number" and h or 12) - LINE_GAP
  end
  for i = #out + 1, #f.lines do f.lines[i].label:Hide(); f.lines[i].text:Hide() end
  f:SetHeight(floor(-y + PAD))
end

--- Beside the anchor, toward the screen's centre.
local function place(anchor)
  f:ClearAllPoints()
  local x = anchor and anchor.GetCenter and select(1, anchor:GetCenter())
  local half = (UIParent:GetWidth() or 1024) / 2
  if type(x) == "number" and x > half then f:SetPoint("TOPRIGHT", anchor, "TOPLEFT", -6, 0)
  else f:SetPoint("TOPLEFT", anchor or UIParent, anchor and "TOPRIGHT" or "CENTER", 6, 0) end
end

--- Show how tile's number is made. mode "panel" (the window) or "tip" (the HUD).
function S.Show(anchor, tile, board, mode)
  if not (tile and tile.kind == "reading") then return end
  build()
  mode = mode == "tip" and "tip" or "panel"
  cur.tile, cur.board, cur.mode, cur.anchor, cur.since = tile, board, mode, anchor, ns.wow.time()
  f.close:SetShown(mode == "panel")
  f:EnableMouse(mode == "panel")
  if mode == "panel" then
    f:SetFrameStrata("DIALOG")
    if not catcher then
      -- a click anywhere outside closes the panel (the pattern of UI/Menu.lua)
      catcher = CreateFrame("Button", nil, UIParent)
      catcher:SetAllPoints(UIParent)
      catcher:SetFrameStrata("DIALOG")
      catcher:SetFrameLevel(1)
      catcher:RegisterForClicks("AnyUp")
      catcher:SetScript("OnClick", function() S.Hide() end)
    end
    catcher:Show()
    f:SetFrameLevel(catcher:GetFrameLevel() + 5)
  else
    f:SetFrameStrata("TOOLTIP")
    if catcher then catcher:Hide() end
    -- any click closes the tooltip: GLOBAL_MOUSE_DOWN where the client has it (a click catcher over the world
    -- would eat a camera turn or a target click); Boards.Hover's poll covers a client without it
    if not events then
      events = CreateFrame("Frame")
      events:SetScript("OnEvent", function() S.Hide() end)
    end
    pcall(events.RegisterEvent, events, "GLOBAL_MOUSE_DOWN")
  end
  place(anchor)
  draw()
  f:Show()
  if not ticker then
    ticker = C_Timer.NewTicker(1, function()
      if cur.mode == "tip" and ns.wow.time() - cur.since > TIP_LIFE then S.Hide(); return end
      draw()
    end)
  end
end

function S.Hide() if f and f:IsShown() then f:Hide() end end
function S.IsShown(mode) return f ~= nil and f:IsShown() and (mode == nil or cur.mode == mode) end
function S.Current() return cur.tile, cur.board, cur.mode end
function S.Frame() return f end
function S.Redraw() draw() end
