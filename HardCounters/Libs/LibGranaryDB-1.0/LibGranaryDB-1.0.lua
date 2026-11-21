-- LibGranaryDB-1.0: an embeddable, pure-Lua 5.1 data-cube library for World of Warcraft addons.
-- Measures over dimensions and time, pre-aggregated on write, bounded, versioned and exportable.
-- This file registers the library with LibStub. The remaining files of THIS copy fill in `lib.__M`
-- and Core/Init.lua wires everything up. If an equal or newer copy is already loaded, every file
-- of this copy returns immediately.

local MAJOR, MINOR = "LibGranaryDB-1.0", 5
local lib, oldMinor = LibStub:NewLibrary(MAJOR, MINOR)
if not lib then return end

lib.MAJOR = MAJOR
lib.MINOR = MINOR
lib.API_VERSION = 4 -- 2: dimension caps up to 4096, 16384 tuples per counter; 3: DropCounter, removed = "keep"; 4: Members, row.member
lib.SCHEMA = 1
lib.__M = { lib = lib, MAJOR = MAJOR, MINOR = MINOR, oldMinor = oldMinor, SCHEMA = 1, FORMAT = 1 }
