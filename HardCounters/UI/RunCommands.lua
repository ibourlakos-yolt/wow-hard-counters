-- /hc stint start|stop|pause|resume|split|status (0.4.0: "stint" is the player's word; /hc run, its name before, is
-- kept unlisted). (The login question about a stint left open went with HC-30: stints carry on.)
local ADDON, ns = ...

local HC, L, U = ns.HC, ns.L, ns.U

-- HC:StartRun and the others give their reasons in the API's words (Core/Runs.lua keeps "run"): the chat line says
-- them in the player's
local REASON = {
  ["a run is already open"] = "a run is already open: /hc run stop keeps it",
  ["no open run"] = "no run open: /hc run start [name]",
  ["the run is not running"] = "the run is paused already",
  ["the run is not paused"] = "the run is not paused",
  ["storage not ready"] = "not ready yet: try again in a moment",
  ["storage is read-only"] = "nothing can be kept this session: Hard Counters' storage is read-only",
}

local function status()
  local run = HC:GetRun()
  if not run then ns.Print(L["no run open. /hc run start [name]"]); return end
  ns.Print(L["run #%d %s: %s, active %s, elapsed %s, %d split(s)"], run.id, run.label or "", L[run.state],
    U.duration(run.activeSeconds), U.duration(run.elapsed), run.splitCount)
end

--- The API's reason for a refusal, in the player's words (the Stints tab's header button says them too).
function ns.StintReason(err)
  return REASON[err] and L[REASON[err]] or tostring(err)
end

local function report(ok, err, okMsg)
  if ok then ns.Print(okMsg) else ns.Print("|cffff6060" .. ns.StintReason(err) .. "|r") end
end

local function stint(rest)
  local cmd, arg = (rest or ""):match("^(%S*)%s*(.*)$")
  cmd = (cmd or ""):lower()
  if cmd == "start" then
    local id, err = HC:StartRun(arg)
    report(id, err, id and L["run started"] .. (arg ~= "" and (": " .. arg) or ""))
  elseif cmd == "stop" then
    local id, err = HC:StopRun()
    report(id, err, L["run stopped and kept (the Runs tab)"])
  elseif cmd == "pause" then
    local ok, err = HC:PauseRun()
    report(ok, err, L["run paused"])
  elseif cmd == "resume" then
    local ok, err = HC:ResumeRun()
    report(ok, err, L["run resumed"])
  elseif cmd == "split" then
    local n, err = HC:SplitRun(arg)
    report(n, err, n and (L["split"] .. " " .. n) or "")
  else
    status()
  end
end

-- (0.5.0, H1) "run" again; "stint" (0.4's word) still answers, unlisted
ns.AddSlash("run", stint, L["a run by hand: start [name] | stop (keeps it) | pause | resume | split [name] | status"])
ns.AddSlash("stint", stint)                   -- (its name in 0.4; not listed)

---------------------------------------------------------------------------
-- /hc track: trackers from the chat line (HC-19). The Trackers window (/hc trackers) is the main way; this is the
-- quick one, and the one that works without any window.
---------------------------------------------------------------------------

local function findTracker(key)
  local list = HC:Trackers()
  local n = tonumber(key)
  if n then return list[n] end
  for _, t in ipairs(list) do if t.id == key or t.title:lower() == key:lower() then return t end end
  return nil
end

ns.AddSlash("track", function(rest)
  local key, cmd, arg, days = (rest or ""):match("^(%S*)%s*(%S*)%s*(%S*)%s*(%S*)")
  if not key or key == "" then
    for i, t in ipairs(HC:Trackers()) do
      ns.Print("%d. %s [%s] %s: %s%s", i, t.title, t.on and L["on"] or L["off"], L["history"], t.history,
        t.history == "daily" and (" " .. t.days .. "d") or "")
    end
    ns.Print(L["/hc track <number> on | off | history on|off|lifetime|daily [14|30|90|365]|detailed"])
    return
  end
  local t = findTracker(key)
  if not t then ns.Print(L["no such tracker: %s"], key); return end
  cmd = cmd:lower()
  if cmd == "on" or cmd == "off" then
    HC:SetTrackerOn(t.id, cmd == "on")
    ns.Print("%s: %s", t.title, cmd == "on" and L["on"] or L["off"])
  elseif cmd == "history" and arg == "on" then
    HC:SetTrackerKeepHistory(t.id, true)                -- (HC-48) the switch: the last preset, else daily
    ns.Print("%s: %s %s", t.title, L["history"], HC:GetTracker(t.id).history)
  elseif cmd == "history" and ns.HISTORY_PRESETS[arg] then
    local d = tonumber(days)
    local ok, err = pcall(HC.SetTrackerHistory, HC, t.id, arg, d)
    if ok then ns.Print("%s: %s %s", t.title, L["history"], arg) else ns.Print("|cffff6060%s|r", tostring(err)) end
  else
    ns.Print(L["/hc track <number> on | off | history on|off|lifetime|daily [14|30|90|365]|detailed"])
  end
end, L["list trackers, switch one on or off, choose its history"])
