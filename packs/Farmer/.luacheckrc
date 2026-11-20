-- luacheck config for Hard Counters: Farmer. Game globals are listed per file group; a new one can't slip in.
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

-- Pure modules: no game globals at all.
files["HardCounters_Farmer/Parse.lua"] = { read_globals = {} }
files["HardCounters_Farmer/Attribution.lua"] = { read_globals = {} }

files["HardCounters_Farmer/Farmer.lua"] = {
  read_globals = { "HardCounters", "Enum", "C_Item", "GetItemInfo", "GetItemInfoInstant", "GetItemCount", "GetTime",
    "C_Timer", "GetInboxInvoiceInfo", "GetInboxHeaderInfo", "GetSendMailMoney", "C_Reputation" },
}
files["HardCounters_Farmer/UI/**"] = {
  read_globals = { "HardCounters", "CreateFrame" },   -- Hard Counters hosts the window (frame, Escape, BlizzMove)
  globals = { "SLASH_HCFARMER1", "SLASH_HCFARMER2", "SlashCmdList" },
}

files["tests/**"] = { std = "+busted", ignore = { "311" }, globals = { "_G" } }
