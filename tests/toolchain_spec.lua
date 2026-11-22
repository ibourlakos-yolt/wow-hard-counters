-- Toolchain checks: TOC load lists resolve, versions agree, and the embedded LibGranaryDB is an exact copy.
local F = require("files")

-- Every addon folder tools\package.ps1 ships.
local ADDONS = {
  "HardCounters/HardCounters.toc",
  "HardCounters_Diagnostics/HardCounters_Diagnostics.toc",
  "packs/Farmer/HardCounters_Farmer/HardCounters_Farmer.toc",
  "packs/CharacterStats/HardCounters_CharacterStats/HardCounters_CharacterStats.toc",
  "packs/Traveler/HardCounters_Traveler/HardCounters_Traveler.toc",
}
local WEBSITE = "https://github.com/ibourlakos-yolt/wow-hard-counters"
-- The one CurseForge project the zip is uploaded to (all five folders ship in it).
local CURSE_PROJECT_ID = "1820964"
-- Lua files that carry the version as a string (tools\bump.ps1 writes them all).
local VERSION_SOURCES = {
  { "HardCounters/Core/Init.lua", 'HC%.VERSION = "([^"]+)"' },
  { "packs/Farmer/HardCounters_Farmer/Farmer.lua", 'ns%.VERSION = "([^"]+)"' },
  { "packs/CharacterStats/HardCounters_CharacterStats/Stats.lua", 'ns%.VERSION = "([^"]+)"' },
  { "packs/Traveler/HardCounters_Traveler/Traveler.lua", 'ns%.VERSION = "([^"]+)"' },
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

    it(toc .. ": links the public repo", function()
      assert.are.equal(WEBSITE, F.tocFields(toc)["X-Website"])
    end)

    it(toc .. ": names the CurseForge project (## X-Curse-Project-ID)", function()
      assert.are.equal(CURSE_PROJECT_ID, F.tocFields(toc)["X-Curse-Project-ID"])
    end)

    -- The client's AddOn list (Blizzard_AddOnList, forever branch, 1.60.1) nests an addon under the one whose
    -- folder name EXACTLY equals its ## Group; a wrong value drops it back to the top level.
    it(toc .. ": sits under Hard Counters in the AddOn list (## Group)", function()
      assert.are.equal("HardCounters", F.tocFields(toc).Group)
    end)

    -- Without ## IconTexture the AddOn list shows a red question mark; every shipped addon uses the main icon.
    it(toc .. ": shows the Hard Counters icon in the AddOn list (## IconTexture)", function()
      assert.are.equal("Interface\\AddOns\\HardCounters\\Media\\Icon", F.tocFields(toc).IconTexture)
    end)

    if toc ~= ADDONS[1] then
      it(toc .. ": needs Hard Counters (## Dependencies)", function()
        assert.are.equal("HardCounters", F.tocFields(toc).Dependencies)
      end)
    end
  end

  -- The addon icon: ## IconTexture and ns.ICON name the same file, inside the HardCounters folder that
  -- tools\package.ps1 zips whole, as a 64x64 uncompressed 32-bit TGA with an 8-bit alpha (tools/draw-icon.py).
  it("the icon file exists, ships, and is a TGA the client reads", function()
    local path = F.tocFields("HardCounters/HardCounters.toc").IconTexture
    assert.are.equal("Interface\\AddOns\\HardCounters\\Media\\Icon", path)
    local lua = F.read("HardCounters/UI/Windows.lua"):match('local ICON = "([^"]+)"')
    assert.are.equal(path, (lua:gsub("\\\\", "\\")))
    local tga = F.read((path:gsub("^Interface\\AddOns\\", ""):gsub("\\", "/")) .. ".tga")
    assert.is_truthy(tga, "the icon file is missing")
    local function u16(i) return tga:byte(i) + 256 * tga:byte(i + 1) end
    assert.are.equal(2, tga:byte(3), "image type: uncompressed true-colour")
    assert.are.equal(64, u16(13), "width")
    assert.are.equal(64, u16(15), "height")
    assert.are.equal(32, tga:byte(17), "bits per pixel")
    assert.are.equal(8, tga:byte(18) % 16, "alpha bits")
    assert.is_true(#tga >= 18 + tga:byte(1) + 64 * 64 * 4, "header, ID field and every pixel")
  end)

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
