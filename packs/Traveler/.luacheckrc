-- luacheck config for Hard Counters: Traveler. Game globals are listed per file group; a new one can't slip in.
std = "lua51"
max_line_length = 160
codes = true
ignore = {
  "212/self",
  "211/_.*",
  "212/_.*",
  "21[12]/ADDON",
}
exclude_files = { "dist/**", ".luarocks/**" }

-- The movement model: pure, no game globals at all.
files["HardCounters_Traveler/Motion.lua"] = { read_globals = {} }

-- Traveler.lua reads the game through _G (guarded, every call may be missing on this client), apart from these.
files["HardCounters_Traveler/Traveler.lua"] = {
  read_globals = { "HardCounters", "GetTime", "_G" },
}

files["tests/**"] = { std = "+busted", ignore = { "311" }, globals = { "_G" } }
