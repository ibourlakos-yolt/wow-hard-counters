-- File helpers for toolchain tests: read files, list trees, expand TOC and XML load lists.
local lfs = require("lfs")
local F = {}

function F.read(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

function F.exists(path)
  return lfs.attributes(path, "mode") ~= nil
end

function F.isDir(path)
  return lfs.attributes(path, "mode") == "directory"
end

--- Every file under `root`, as paths relative to it (forward slashes), sorted.
function F.tree(root)
  local out = {}
  local function walk(dir, rel)
    for name in lfs.dir(dir) do
      if name ~= "." and name ~= ".." then
        local full, r = dir .. "/" .. name, (rel == "" and name or rel .. "/" .. name)
        if F.isDir(full) then walk(full, r) else out[#out + 1] = r end
      end
    end
  end
  walk(root, "")
  table.sort(out)
  return out
end

local function dirname(p) return p:match("^(.*)/[^/]*$") or "." end

--- The Lua files a TOC loads, in order, expanding XML <Script>/<Include> recursively.
--- Returns the list and a list of missing paths.
function F.loadList(tocPath)
  local base = dirname(tocPath)
  local files, missing = {}, {}
  local function addXml(xmlPath)
    local xml = F.read(xmlPath)
    if not xml then missing[#missing + 1] = xmlPath; return end
    xml = xml:gsub("<!%-%-.-%-%->", "")
    local dir = dirname(xmlPath)
    for tag, path in xml:gmatch('<(%a+) file="([^"]+)"') do
      local full = dir .. "/" .. path:gsub("\\", "/")
      if tag == "Script" then
        if F.exists(full) then files[#files + 1] = full else missing[#missing + 1] = full end
      elseif tag == "Include" then
        addXml(full)
      end
    end
  end
  for line in (F.read(tocPath) or ""):gmatch("[^\r\n]+") do
    if not line:match("^%s*#") and line:match("%S") then
      local full = base .. "/" .. line:gsub("\\", "/"):gsub("%s+$", "")
      if full:match("%.xml$") then addXml(full)
      elseif F.exists(full) then files[#files + 1] = full
      else missing[#missing + 1] = full end
    end
  end
  return files, missing
end

--- "## Key: value" fields of a TOC.
function F.tocFields(tocPath)
  local t = {}
  for k, v in (F.read(tocPath) or ""):gmatch("##%s*([%w%-_]+)%s*:%s*([^\r\n]*)") do t[k] = v end
  return t
end

return F
