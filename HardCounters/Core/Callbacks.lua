-- Callbacks: the public HC_* events through CallbackHandler-1.0 (DESIGN §10).
--   HardCounters.RegisterCallback(owner, "HC_RUN_STOPPED", function(event, runId) ... end)
--   HardCounters.UnregisterCallback(owner, "HC_RUN_STOPPED")
-- Payloads are plain values or copies; never saved tables.
local ADDON, ns = ...

local CBH = LibStub("CallbackHandler-1.0")
ns.callbacks = CBH:New(ns.HC, "RegisterCallback", "UnregisterCallback", "UnregisterAllCallbacks")

function ns.Fire(event, ...)
  ns.callbacks:Fire(event, ...)
end
