-- enUS strings (the default locale). Other locales are out of scope for v1.
local ADDON, ns = ...
local AL = LibStub and LibStub("AceLocale-3.0", true)
local L = AL and AL:NewLocale(ADDON, "enUS", true, true)
if not L then
  -- outside the game (tests): keys read back as themselves
  ns.L = ns.L or setmetatable({}, { __index = function(_, k) return k end })
  return
end

L["Hard Counters"] = true
L["Unknown zone"] = true
