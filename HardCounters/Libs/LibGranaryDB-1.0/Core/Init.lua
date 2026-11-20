-- Init: wire the public objects. Metatables live on the library table so they survive a MINOR
-- upgrade within a session; existing db objects then pick up the new methods, and their runtime
-- indexes are rebuilt from saved data (the saved tables are the source of truth).
local lib = LibStub and LibStub("LibGranaryDB-1.0", true)
local M = lib and lib.__M
if not M then return end

lib.__dbs = lib.__dbs or {}
lib.__dbMeta = lib.__dbMeta or {}
lib.__handleMeta = lib.__handleMeta or {}
lib.__dbMeta.__index = M.DB
lib.__handleMeta.__index = M.Handle

-- Upgrade path: an older copy attached roots earlier this session.
if M.oldMinor then
  for _, db in ipairs(lib.__dbs) do
    local ok, err = pcall(function()
      db._lru = db._lru or M.Pack.newLRU(32)
      db._qcache, db._impCache = db._qcache or {}, db._impCache or {}
      db._closedQ = db._closedQ or {}
      db._flushFn = function() M.Store.flush(db) end
      for id, rc in pairs(db._counters) do
        local d = rc.saved and rc.saved.def and rc.saved.def.d
        local nd = d and M.Registry.validate(d, rc.internal)
        if nd then
          local nrc = M.Store.buildRuntime(db, nd, rc.saved, rc.internal)
          db._counters[id] = nrc
          local h = db._handles[id]
          if h then h.rc, h.ce, h.ceEpoch = nrc, nil, -1 end
        end
      end
    end)
    if not ok then M.U.internal(db, "upgrade to r" .. M.MINOR .. " failed: " .. tostring(err), true) end
  end
end

-- Private access for this repo's tests and dev tools only. Not part of the API.
lib._M = M
lib.__M = nil
