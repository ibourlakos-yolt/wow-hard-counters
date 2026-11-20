-- Attribution: where a money or XP change came from (DESIGN §4.1). The state diff (GetMoney, UnitXP) is the truth;
-- the signals around it name the source. Pure: time comes in as an argument, results go out through `emit`, so
-- there is no allocation per event and busted can test every ordering.
--
-- Event order isn't known yet (FM-5 probes it): CHAT_MSG_MONEY may come before or after PLAYER_MONEY. So a gain
-- that nothing explains yet is HELD for WINDOW seconds; a loot message in that time claims it, otherwise it becomes
-- "other". Every source but loot and quest is inferred from open windows, and labelled as inferred in the UI.
local ADDON, ns = ...

local min = math.min
local WINDOW = 2

ns.ATTR_WINDOW = WINDOW

---------------------------------------------------------------------------
-- Money
---------------------------------------------------------------------------

local Money = {}
Money.__index = Money

--- emit(direction "in"|"out", copper, source)
function ns.NewMoneyAttributor(emit)
  return setmetatable({ emit = emit, open = {}, markT = {}, markSource = {}, lootPending = 0, lootT = 0,
    held = 0, heldT = 0, unmatchedLoot = 0, lootClaimed = 0 }, Money)
end

--- A window opened or closed: "merchant", "mail", "ah", "trainer", "taxi", "trade".
function Money:SetOpen(kind, on)
  self.open[kind] = on and true or nil
end

--- Forget every open window (loading screens close them all).
function Money:CloseAll()
  for k in pairs(self.open) do self.open[k] = nil end
end

--- A one-off signal: "repair" (RepairAllItems), "quest" (QUEST_TURNED_IN with money), "mailTake" (source "ah"|"mail"|
--- "alts": money from one of your own characters, FM-16), "mailSend" (source: the copper sent to one of your own
--- characters, 0 for anyone else; the rest of what leaves, postage, stays "mail").
function Money:Mark(kind, t, source)
  self.markT[kind] = t
  self.markSource[kind] = source
end

local function recent(self, kind, t)
  local mt = self.markT[kind]
  return mt and t - mt <= WINDOW
end

--- CHAT_MSG_MONEY said we looted `amount`.
function Money:LootMessage(amount, t)
  if self.held > 0 and t - self.heldT <= WINDOW then
    local take = min(self.held, amount)
    self.emit("in", take, "loot")
    self.lootClaimed = self.lootClaimed + take
    self.held = self.held - take
    amount = amount - take
  end
  if amount > 0 then
    if t - self.lootT > WINDOW then self.lootPending = 0 end
    self.lootPending = self.lootPending + amount
    self.lootT = t
  end
end

--- PLAYER_MONEY: the money changed by d (copper, signed).
function Money:Delta(d, t)
  if d > 0 then
    if self.lootPending > 0 and t - self.lootT <= WINDOW then
      local take = min(d, self.lootPending)
      self.emit("in", take, "loot")
      self.lootClaimed = self.lootClaimed + take
      self.lootPending = self.lootPending - take
      d = d - take
      if d <= 0 then return end
    end
    if recent(self, "quest", t) then self.markT.quest = nil; self.emit("in", d, "quest"); return end
    if recent(self, "mailTake", t) then
      self.markT.mailTake = nil   -- one take, one money change
      self.emit("in", d, self.markSource.mailTake or "mail")
      return
    end
    local o = self.open
    if o.mail then self.emit("in", d, "mail"); return end
    if o.merchant then self.emit("in", d, "vendor"); return end
    if o.trade then self.emit("in", d, "trade"); return end
    if self.held == 0 then self.heldT = t end
    self.held = self.held + d
  elseif d < 0 then
    local a = -d
    local o = self.open
    if recent(self, "repair", t) then self.markT.repair = nil; self.emit("out", a, "repair")
    elseif recent(self, "mailSend", t) then
      -- FM-16: money sent to one of your own characters has its own sink, so account-wide totals can leave it out
      self.markT.mailSend = nil
      local own = self.markSource.mailSend
      if type(own) == "number" and own > 0 then
        local take = min(a, own)
        self.emit("out", take, "alts")
        a = a - take
      end
      if a > 0 then self.emit("out", a, "mail") end
    elseif o.merchant then self.emit("out", a, "vendor")
    elseif o.ah then self.emit("out", a, "ah")
    elseif o.trainer then self.emit("out", a, "training")
    elseif o.taxi then self.emit("out", a, "travel")
    elseif o.mail then self.emit("out", a, "mail")
    elseif o.trade then self.emit("out", a, "trade")
    else self.emit("out", a, "other") end
  end
end

--- Release held gains as "other" and forget unclaimed loot messages once the window has passed.
--- Returns true while something is still waiting (call again later).
function Money:Expire(t)
  if self.held > 0 and t - self.heldT > WINDOW then
    self.emit("in", self.held, "other")
    self.held = 0
  end
  if self.lootPending > 0 and t - self.lootT > WINDOW then
    self.unmatchedLoot = self.unmatchedLoot + self.lootPending
    self.lootPending = 0
  end
  return self.held > 0 or self.lootPending > 0
end

---------------------------------------------------------------------------
-- XP: the UnitXP diff is the truth; a kill line or QUEST_TURNED_IN names the source.
---------------------------------------------------------------------------

local XP = {}
XP.__index = XP

function ns.NewXPAttributor(emit)
  return setmetatable({ emit = emit, hintT = {}, held = 0, heldT = 0 }, XP)
end

--- A source signal: "kill" (chat), "quest" (QUEST_TURNED_IN xp > 0), "other" (an unnamed XP line).
function XP:Hint(kind, t)
  if self.held > 0 and t - self.heldT <= WINDOW then
    self.emit(self.held, kind)
    self.held = 0
    return
  end
  self.hintT[kind] = t
end

local ORDER = { "quest", "kill", "other" }

function XP:Delta(d, t)
  if d <= 0 then return end
  for i = 1, #ORDER do
    local k = ORDER[i]
    local ht = self.hintT[k]
    if ht and t - ht <= WINDOW then
      self.hintT[k] = nil
      self.emit(d, k)
      return
    end
  end
  if self.held == 0 then self.heldT = t end
  self.held = self.held + d
end

function XP:Expire(t)
  if self.held > 0 and t - self.heldT > WINDOW then
    self.emit(self.held, "other")
    self.held = 0
  end
  return self.held > 0
end

--- XP gained between two readings, across at most one level-up (the previous level's max is known).
function ns.XPDelta(lastXP, lastMax, lastLevel, xp, level)
  if not (lastXP and lastMax and lastLevel and xp and level) then return 0 end
  if level == lastLevel then
    -- XP never goes down within a level; a drop means a ding that UnitLevel hasn't caught up with yet
    if xp < lastXP then return (lastMax - lastXP) + xp end
    return xp - lastXP
  elseif level == lastLevel + 1 then
    local d = (lastMax - lastXP) + xp
    return d > 0 and d or 0
  end
  return 0 -- several levels at once (or a level reset): unknown, don't guess
end
