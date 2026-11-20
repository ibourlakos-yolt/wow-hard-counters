-- Migrations: saved-data schema upgrades n -> n+1, run at Attach (SPEC §5.2, D13).
-- Schema 1 is the first schema, so there are no steps yet. Tests install a temporary step through
-- M.Migrations.steps to exercise the framework, the read-only path and migrate-then-query.
local lib = LibStub and LibStub("LibGranaryDB-1.0", true)
local M = lib and lib.__M
if not M then return end

local Mg = { steps = {} }
M.Migrations = Mg

--- Upgrade G from its schema to `target`. Returns true, report or false, err.
--- Each step runs inside pcall; on failure G is left as the failed step found it, and the caller
--- puts the db in read-only mode.
function Mg.run(db, G, target)
  local from = G.schema
  local report = { from = from, to = target, steps = {} }
  for n = from, target - 1 do
    local step = Mg.steps[n]
    if not step then return false, string.format("no migration from schema %d to %d", n, n + 1) end
    local ok, err = pcall(step, G, db)
    if not ok then return false, string.format("migration %d -> %d failed: %s", n, n + 1, tostring(err)) end
    G.schema = n + 1
    G.minReader = G.minReader or 1
    report.steps[#report.steps + 1] = n .. "->" .. (n + 1)
  end
  return true, report
end
