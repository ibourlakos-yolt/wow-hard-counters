-- Decode a !HCReport:1! string offline (lua5.1 in WSL, from the repo root), and the !GranaryDBReport:1! inside it.
-- Input: any file containing the string (a paste, or a SavedVariables file). Inflate uses WSL's python3 zlib,
-- because neither addon has a pure-Lua inflate (in game C_EncodingUtil does it). Native output is raw Deflate.
-- Usage: lua5.1 tools/decode_report.lua <file>     (Windows: tools\decode-report.ps1 <file>)
package.path = "./?.lua;./tests/helpers/?.lua;" .. package.path

rawset(_G, "strmatch", string.match)
local F = require("files")
local files = F.loadList("HardCounters/HardCounters.toc")
for _, p in ipairs(files) do
  if p:match("Libs/LibGranaryDB%-1%.0/") and not p:match("Adapters/WoW%.lua$") then dofile(p) end
  if p:match("Libs/LibStub/LibStub%.lua$") then dofile(p) end
end
local GDB = LibStub("LibGranaryDB-1.0")
local M = GDB._M

local path = arg[1]
if not path then io.stderr:write("usage: lua5.1 tools/decode_report.lua <file>\n"); os.exit(2) end
local fh = assert(io.open(path, "rb"))
local text = fh:read("*a")
fh:close()

local function inflate(payload)
  local zin, zout = os.tmpname(), os.tmpname()
  local w = assert(io.open(zin, "wb")); w:write(payload); w:close()
  local cmd = string.format("python3 -c \"import sys,zlib;open(sys.argv[2],'wb').write(zlib.decompress(open(sys.argv[1],'rb').read(),-15))\" '%s' '%s'",
    zin, zout)
  local okExec = os.execute(cmd)
  local r = io.open(zout, "rb")
  local raw = r and r:read("*a")
  if r then r:close() end
  os.remove(zin); os.remove(zout)
  if okExec ~= 0 or not raw or raw == "" then return nil, "inflate failed (needs python3 in WSL)" end
  return raw
end

local function decode(str, name)
  local c, cs, b64 = str:match("^!" .. name .. ":1!([dn]):(%x+):([%w%+/=]*)!End")
  if not c then return nil, "not a " .. name .. " string" end
  local payload = M.Codec.base64Decode(b64)
  if not payload then return nil, "bad base64" end
  local raw = payload
  if c == "d" then
    local err
    raw, err = inflate(payload)
    if not raw then return nil, err end
  end
  if M.Codec.adler32(raw) ~= cs then return nil, "checksum mismatch" end
  local body, derr = M.Codec.cborDecode(raw, { maxDepth = 10, maxString = 65536, maxItems = 50000 })
  if type(body) ~= "table" then return nil, "corrupt: " .. tostring(derr) end
  return body
end

local function dump(v, ind)
  if type(v) ~= "table" then return type(v) == "string" and string.format("%q", v) or tostring(v) end
  local keys = {}
  for k in pairs(v) do keys[#keys + 1] = k end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  local out = { "{" }
  for _, k in ipairs(keys) do out[#out + 1] = ind .. "  " .. tostring(k) .. " = " .. dump(v[k], ind .. "  ") end
  out[#out + 1] = ind .. "}"
  return table.concat(out, "\n")
end

local str = text:match("!HCReport:1![%w%+/=:]*!End:HCReport:1!")
if not str then io.stderr:write("no !HCReport:1! string in " .. path .. "\n"); os.exit(1) end
local body, err = decode(str, "HCReport")
if not body then io.stderr:write(err .. "\n"); os.exit(1) end
local granary = body.granary
body.granary = granary and "(decoded below)" or nil
print("HCReport")
print(dump(body, ""))
if type(granary) == "string" then
  local g, gerr = decode(granary, "GranaryDBReport")
  print("\nGranaryDBReport")
  print(g and dump(g, "") or ("could not decode: " .. tostring(gerr)))
end
