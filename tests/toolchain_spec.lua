-- Toolchain checks: TOC load lists resolve, versions agree, and the embedded LibGranaryDB is an exact copy.
local F = require("files")

-- Every addon folder tools\package.ps1 ships.
local ADDONS = {
  "HardCounters/HardCounters.toc",
  "HardCounters_Diagnostics/HardCounters_Diagnostics.toc",
  "packs/Farmer/HardCounters_Farmer/HardCounters_Farmer.toc",
  "packs/CharacterStats/HardCounters_CharacterStats/HardCounters_CharacterStats.toc",
}
-- Lua files that carry the version as a string (tools\bump.ps1 writes them all).
local VERSION_SOURCES = {
  { "HardCounters/Core/Init.lua", 'HC%.VERSION = "([^"]+)"' },
  { "packs/Farmer/HardCounters_Farmer/Farmer.lua", 'ns%.VERSION = "([^"]+)"' },
  { "packs/CharacterStats/HardCounters_CharacterStats/Stats.lua", 'ns%.VERSION = "([^"]+)"' },
}

describe("toolchain", function()
  it("runs on PUC Lua 5.1, never LuaJIT", function()
    assert.are.equal("Lua 5.1", _VERSION)
    assert.is_nil(rawget(_G, "jit"))
  end)

  for _, toc in ipairs(ADDONS) do
    it(toc .. ": every file it loads exists", function()
      local files, missing = F.loadList(toc)
      assert.are.same({}, missing)
      assert.is_true(#files > 0)
    end)

    it(toc .. ": targets Interface 16001", function()
      assert.are.equal("16001", F.tocFields(toc).Interface)
    end)

    it(toc .. ": says its license", function()
      assert.are.equal("MIT", F.tocFields(toc)["X-License"])
      assert.is_truthy(F.tocFields(toc)["X-AI-Assisted"], "the AI-assistance note (README, How it's made)")
    end)
  end

  it("one version everywhere: every shipped TOC and every VERSION string (tools\\bump.ps1)", function()
    local v = F.tocFields("HardCounters/HardCounters.toc").Version
    assert.is_truthy(v)
    for _, toc in ipairs(ADDONS) do
      assert.are.equal(v, F.tocFields(toc).Version, toc)
    end
    for _, s in ipairs(VERSION_SOURCES) do
      assert.are.equal(v, F.read(s[1]):match(s[2]), s[1])
    end
  end)

  it("embedded LibGranaryDB-1.0 is an exact copy of ../LibGranaryDB (run tools\\sync-libs.ps1)", function()
    local src, dst = "../LibGranaryDB/LibGranaryDB-1.0", "HardCounters/Libs/LibGranaryDB-1.0"
    if not F.isDir(src) then
      pending("../LibGranaryDB not present")
      return
    end
    local a, b = F.tree(src), F.tree(dst)
    assert.are.same(a, b)
    for _, rel in ipairs(a) do
      assert.are.equal(F.read(src .. "/" .. rel), F.read(dst .. "/" .. rel), rel .. " differs")
    end
  end)

  it("the embedded LibGranaryDB has API_VERSION >= 2 (item caps of 4096)", function()
    local src = F.read("HardCounters/Libs/LibGranaryDB-1.0/LibGranaryDB-1.0.lua")
    assert.is_true(tonumber(src:match("lib%.API_VERSION = (%d+)")) >= 2)
  end)
end)
