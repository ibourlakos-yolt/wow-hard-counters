-- /hc and /hardcounters: the one command root. Subcommands register themselves with ns.AddSlash(name, fn, help);
-- packs and the Diagnostics companion add theirs through HardCounters:RegisterSlash (e.g. /hc ledger, /hc diag).
-- /hc alone opens the Hard Counters window when it has tabs, else lists the commands.
local ADDON, ns = ...

local HC, L = ns.HC, ns.L
local commands, order = {}, {}

function ns.Print(msg, ...)
  if select("#", ...) > 0 then msg = msg:format(...) end
  DEFAULT_CHAT_FRAME:AddMessage("|cffffd200Hard Counters|r: " .. tostring(msg))
end

function ns.AddSlash(name, fn, help, owner)
  if not commands[name] then order[#order + 1] = name end
  commands[name] = { fn = fn, help = help, owner = owner }
end

local function help()
  ns.Print(L["commands:"])
  DEFAULT_CHAT_FRAME:AddMessage("  /hc - " .. L["open the Hard Counters window"])
  for _, name in ipairs(order) do
    local c = commands[name]
    if c.help then
      DEFAULT_CHAT_FRAME:AddMessage("  /hc " .. name .. " - " .. c.help .. (c.owner and (" |cff808080(" .. c.owner .. ")|r") or ""))
    end
  end
end

--- Run "/hc <msg>" (also used by the old per-addon commands, which forward here).
function ns.RunSlash(msg)
  msg = (msg or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if msg == "" then
    if ns.Windows and ns.Windows.HasDocked() then ns.Windows.ShowMain() else help() end
    return
  end
  local cmd, rest = msg:match("^(%S+)%s*(.*)$")
  local c = cmd and commands[cmd:lower()]
  if not c then help(); return end
  local ok, err = pcall(c.fn, rest or "")
  if not ok then ns.Error(err) end
end

--- Public: a pack's subcommand, /hc <name> [args]. fn(rest) gets the text after the name. A name already taken
--- (by Hard Counters or another pack) is refused: returns false, reason.
function HC:RegisterSlash(name, fn, helpText, owner)
  if type(name) ~= "string" or not name:match("^%l[%l%d]*$") then return false, "name must be lowercase letters and digits" end
  if type(fn) ~= "function" then return false, "fn(rest) is required" end
  if commands[name] then return false, "/hc " .. name .. " is taken" end
  ns.AddSlash(name, fn, helpText, owner or "pack")
  return true
end

ns.AddSlash("report", function(rest)
  local addons = rest == "addons"
  local ok, s = pcall(ns.BuildReport, { addons = addons })
  if not ok then ns.Error(s); ns.Print(L["could not build the report (see BugSack)"]); return end
  ns.ShowCopyBox(L["Hard Counters report"] .. (addons and (" " .. L["(with addon list)"]) or ""), s)
end, L["copy a diagnostics report (add 'addons' to include your addon list)"])

ns.AddSlash("help", help)

SLASH_HARDCOUNTERS1 = "/hc"
SLASH_HARDCOUNTERS2 = "/hardcounters"
SlashCmdList.HARDCOUNTERS = ns.RunSlash
