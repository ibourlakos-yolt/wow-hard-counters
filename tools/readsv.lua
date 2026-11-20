-- Reads a COPY of a saved-variables file (never the game's own: they aren't valid UTF-8, never edit them).
-- Lua 5.1 in WSL:
--   lua5.1 tools/readsv.lua <copy> <dotted.path|""> [depth]   dump a path to a depth (default 2)
--   lua5.1 tools/readsv.lua <copy> --times [since]            Diagnostics probe times, local (+0200): load times
--   lua5.1 tools/readsv.lua <copy> --sizes                    rough size of each part of HardCountersDB
-- Path parts that are numbers index arrays; keys with dots can't be reached (dump the parent).
local file, path, opt = arg[1], arg[2] or "", arg[3]
assert(file, "usage: lua5.1 tools/readsv.lua <copy> <path|--times|--sizes> [depth|since]")
local env = {}
local chunk = assert(loadfile(file))
setfenv(chunk, env)
chunk()

local OFFSET = 7200 -- the user's clock is UTC+2

local function size(v)
  local n = 0
  local function walk(x)
    if type(x) == "table" then
      for k, y in pairs(x) do n = n + #tostring(k) + 6 walk(y) end
    else
      n = n + #tostring(x) + 4
    end
  end
  walk(v)
  return n
end

local function sortedKeys(t)
  local ks = {}
  for k in pairs(t) do ks[#ks + 1] = k end
  table.sort(ks, function(a, b)
    if type(a) == type(b) then return a < b end
    return type(a) == "number"
  end)
  return ks
end

if path == "--sizes" then
  local DB = assert(env.HardCountersDB, "no HardCountersDB in this file")
  for _, k in ipairs(sortedKeys(DB)) do print(k, size(DB[k])) end
  if type(DB.windows) == "table" then
    for _, k in ipairs(sortedKeys(DB.windows)) do print("windows." .. k, size(DB.windows[k])) end
  end
  return
end

if path == "--times" then
  local since = tonumber(opt) or 0
  local seen = {}
  local function walk(t, d)
    if d > 4 then return end
    for _, v in pairs(t) do
      if type(v) == "table" then
        walk(v, d + 1)
      elseif type(v) == "number" and v > 1.7e9 and v < 2e9 and v >= since then
        local s = math.floor(v)
        seen[s] = (seen[s] or 0) + 1
      end
    end
  end
  walk(assert(env.HardCountersDiagDB, "no HardCountersDiagDB in this file"), 0)
  local ts = {}
  for t in pairs(seen) do ts[#ts + 1] = t end
  table.sort(ts)
  for _, t in ipairs(ts) do print(t, os.date("!%Y-%m-%d %H:%M:%S", t + OFFSET), seen[t]) end
  return
end

local depth = tonumber(opt or "2")
local node = env
for part in path:gmatch("[^%.]+") do
  node = node[tonumber(part) or part]
  if node == nil then print("nil at " .. part) return end
end

local function dump(t, ind, d)
  if type(t) ~= "table" then print(ind .. tostring(t)) return end
  for _, k in ipairs(sortedKeys(t)) do
    local v = t[k]
    if type(v) == "table" then
      local n = 0
      for _ in pairs(v) do n = n + 1 end
      if d > 1 then
        print(ind .. tostring(k) .. " = {" .. n .. "}")
        dump(v, ind .. "  ", d - 1)
      else
        print(ind .. tostring(k) .. " = {" .. n .. " keys}")
      end
    else
      print(ind .. tostring(k) .. " = " .. tostring(v))
    end
  end
end
dump(node, "", depth)
