-- Init: the namespace and the public API object (the global `HardCounters`).
-- Every other file adds to `ns` (private) or to `HC` (public, documented in docs/API.md).
local ADDON, ns = ...

local HC = {}
ns.HC = HC
ns.ADDON = ADDON

HC.VERSION = "0.4.0-beta2"
HC.API_VERSION = 1      -- experimental until 2-3 packs have shipped against it (DESIGN §10)
HC.EXPERIMENTAL = true

if not ns.L then
  local AL = LibStub and LibStub("AceLocale-3.0", true)
  ns.L = AL and AL:GetLocale(ADDON, true) or setmetatable({}, { __index = function(_, k) return k end })
end

_G.HardCounters = HC
