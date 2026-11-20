-- Chat parsers built from client strings (FM-4) and the item category classifier.
local S = require("strings")

local function loadParse()
  local ns = {}
  assert(loadfile("HardCounters_Farmer/Parse.lua"))("HardCounters_Farmer", ns)
  return ns.Parse
end

describe("Parse", function()
  local P = loadParse()
  local pf = S.patternFrom()

  for _, loc in ipairs({ "enUS", "xxXX" }) do
    describe(loc, function()
      local G = S[loc]
      local t = P.build(G, pf)
      local function fmt(key, ...) return G[key]:format(...) end

      it("parses own loot, single and stacked", function()
        assert.are.same({ 2589, 1 }, { P.loot(t, fmt("LOOT_ITEM_SELF", S.link(2589, "Linen Cloth"))) })
        assert.are.same({ 2589, 7 }, { P.loot(t, fmt("LOOT_ITEM_SELF_MULTIPLE", S.link(2589, "Linen Cloth"), 7)) })
        assert.is_nil(P.loot(t, "Someone receives loot: " .. S.link(1, "x") .. "."))
        assert.is_nil(P.loot(t, nil))
      end)

      it("parses looted money in the client's units", function()
        local text = G.GOLD_AMOUNT:format(1) .. ", " .. G.SILVER_AMOUNT:format(2) .. ", " .. G.COPPER_AMOUNT:format(3)
        assert.are.equal(10203, P.money(t, fmt("YOU_LOOT_MONEY", text)))
        assert.are.equal(500, P.money(t, fmt("LOOT_MONEY_SPLIT", G.SILVER_AMOUNT:format(5))))
        assert.is_nil(P.money(t, "something else"))
      end)

      it("parses XP lines, with or without a rested suffix", function()
        assert.are.same({ 150, "kill" }, { P.xp(t, fmt("COMBATLOG_XPGAIN_FIRSTPERSON", "Kobold", 150)) })
        assert.are.same({ 150, "kill" }, { P.xp(t, fmt("COMBATLOG_XPGAIN_FIRSTPERSON", "Kobold", 150) .. " (+75 exp Rested bonus)") })
        assert.are.same({ 40, "other" }, { P.xp(t, fmt("COMBATLOG_XPGAIN_FIRSTPERSON_UNNAMED", 40)) })
      end)

      it("parses reputation increases", function()
        assert.are.same({ "Timbermaw Hold", 25 }, { P.rep(t, fmt("FACTION_STANDING_INCREASED", "Timbermaw Hold", 25)) })
      end)
    end)
  end

  it("classifies items into stable farm categories", function()
    assert.are.equal("junk", P.category(4, 1, 0))                 -- grey armor is junk
    assert.are.equal("cloth", P.category(7, 5, 1))
    assert.are.equal("herb", P.category(7, 9, 1))
    assert.are.equal("metal", P.category(7, 7, 1))
    assert.are.equal("tradegoods", P.category(7, 99, 1))
    assert.are.equal("gear", P.category(4, 2, 2))
    assert.are.equal("junk", P.category(15, 0, 1))
    assert.are.equal("misc", P.category(15, 4, 1))
    assert.are.equal("other", P.category(nil, nil, 1))
    assert.are.equal("reptoken", P.category(15, 0, 0, { [12345] = "reptoken" }, 12345))
    assert.is_true(#P.CATEGORIES <= 32)
  end)
end)
