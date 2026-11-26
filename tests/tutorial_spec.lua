-- The tutorial and the Guide tab (the user, 2026-11-24): the tour shows once per account at the first login that
-- hasn't run it, walks the boards on screen, a first board for the character's class and the Hard Counters window
-- tab by tab; the window's Grand tour button (0.4.0; "Tutorial" before) and /hc tutorial run it again. The Guide tab is
-- the manual: its Commands page lists the live /hc registry.
require("bootstrap")
local UI = require("ui_boot")

local function click(b) b:GetScript("OnClick")(b) end
local SEEN = { settings = { global = { tutorialSeen = true } } }

describe("the tutorial", function()
  it("shows at the first login that hasn't run it, once per account, and walks every step", function()
    UI.with(function(ctx)
      local ns = ctx.hc
      local T, Win, BM = ns.Tutorial, ns.Windows, ns.BoardModel
      assert.is_nil(ns.TutorialFrame())                       -- not behind the loading screen
      ctx.env:advance(3)
      local f = ns.TutorialFrame()
      assert.is_true(f:IsShown())
      assert.is_true(ns.globalSettings.tutorialSeen)
      local n, total = T.Step()
      assert.are.equal(1, n)
      assert.are.equal(11, total)
      assert.are.equal("Step 1 of 11", f.count:GetText())
      for _, s in ipairs({ "reading", "tile", "board", "Hard Counters window", "/hc tutorial" }) do
        assert.truthy(f.body:GetText():find(s, 1, true), s)
      end
      -- 2: the boards on screen; a new character has none (0.4.0): the step says so and points at the next one
      click(f.next)
      assert.are.equal(0, #BM.Store().list)
      assert.truthy(f.body:GetText():find("none yet", 1, true))
      assert.truthy(f.body:GetText():find("Edit", 1, true))
      -- 3: the class board (the fake client's character is a mage; Character Stats registers one per class)
      click(f.next)
      if ctx.charstats then
        local key, p = T.ClassPreset()
        assert.are.equal("MAGE", p.class)
        assert.is_true(f.act:IsShown())
        assert.are.equal("Make my " .. p.name .. " board", f.act:GetText())
        local before = #BM.Store().list
        click(f.act)
        local list = BM.Store().list
        assert.are.equal(before + 1, #list)
        local b = list[#list]
        assert.are.equal(key, b.preset)
        assert.is_true(#b.tiles > 0)
        assert.are.equal("HIGH", ns.Boards.Frame(b.id):GetFrameStrata())     -- it flashes
        assert.are.equal("Show it", f.act:GetText())                        -- made once: now it only shows it
        click(f.act)
        assert.are.equal(before + 1, #BM.Store().list)
      else
        assert.are.equal("New board...", f.act:GetText())
      end
      -- 4 to 9: the window, opened by the tour on each of Hard Counters' own tabs (0.4.0: Boards, Explorer, Packs,
      -- Stints, then Overview and Options along the bottom)
      for _, tab in ipairs({ "boards", "boards", "explorer", "packs", "stints", "overview" }) do
        click(f.next)
        assert.is_true(Win.IsShown(tab), tab)
        assert.is_false(f.act:IsShown())
      end
      assert.are.equal(Win.Host("_main"), (select(2, f:GetPoint(1))))        -- beside the window
      -- 10: the packs' tabs, by name
      click(f.next)
      for _, id in ipairs(Win.PackWindows()) do
        assert.truthy(f.body:GetText():find(Win.Def(id).title, 1, true), id)
      end
      -- 11: the Guide tab; Finish closes the tour
      click(f.next)
      assert.is_true(Win.IsShown("guide"))
      assert.are.equal("Finish", f.next:GetText())
      click(f.back)
      assert.are.equal(10, (T.Step()))
      click(f.next)
      click(f.next)
      assert.is_false(f:IsShown())
      assert.are.same({}, ctx.env.errors)
    end, { newCharacter = true })
    -- the next login of that account: no tour
    UI.with(function(ctx)
      ctx.env:advance(3)
      assert.is_nil(ctx.hc.TutorialFrame())
    end, { newCharacter = true, settings = { global = { tutorialSeen = true } } })
  end)

  it("a step about the screen moves the window out of the way; closing stops the flashing", function()
    UI.with(function(ctx)
      local ns = ctx.hc
      local T, Win = ns.Tutorial, ns.Windows
      Win.ShowMain(true)
      T.Show(2)
      assert.is_false(Win.Host("_main"):IsShown())
      local b = ns.BoardModel.Store().list[1]
      assert.are.equal("HIGH", ns.Boards.Frame(b.id):GetFrameStrata())
      T.Hide()
      assert.are.equal(ns.Boards.STRATA, ns.Boards.Frame(b.id):GetFrameStrata())
      assert.are.same({}, ctx.env.errors)
    end, SEEN)
  end)

  it("runs again from the window's Grand tour button and /hc tutorial", function()
    UI.with(function(ctx)
      local ns = ctx.hc
      local T, Win = ns.Tutorial, ns.Windows
      ctx.env:advance(3)
      assert.is_nil(ns.TutorialFrame())
      Win.ShowMain(true)
      local main = Win.Host("_main")
      assert.are.equal("Grand tour", main.tutorial:GetText())
      click(main.tutorial)
      local f = ns.TutorialFrame()
      assert.is_true(f:IsShown())
      assert.are.equal(1, (T.Step()))                          -- from its first step
      T.Go(5)
      T.Hide()
      ns.ShowGuide(true)
      assert.is_nil(ns.Guide.Content().tutorial)               -- (0.4.0) the Guide's own button went
      _G.SlashCmdList.HARDCOUNTERS("tutorial")
      assert.is_true(f:IsShown())
      T.Hide()
      _G.SlashCmdList.HARDCOUNTERS("welcome")                  -- (its name in 0.2.2)
      assert.is_true(f:IsShown())
      assert.are.same({}, ctx.env.errors)
    end, SEEN)
  end)

  it("waits for the end of a fight", function()
    UI.with(function(ctx)
      local ns = ctx.hc
      local fighting = true
      _G.InCombatLockdown = function() return fighting end
      ctx.env:advance(3)
      assert.is_nil(ns.TutorialFrame())
      assert.is_nil(ns.globalSettings.tutorialSeen)
      fighting = false
      ctx.env:advance(11)
      assert.is_true(ns.TutorialFrame():IsShown())
    end)
  end)

  it("without the panel templates it still builds", function()
    UI.with(function(ctx)
      local f = ctx.hc.Tutorial.Show(1)
      assert.is_true(f:IsShown())
      ctx.hc.Tutorial.Go(10)
      assert.are.same({}, ctx.env.errors)
    end, { client = { templates = false }, settings = { global = { tutorialSeen = true } } })
  end)
end)

describe("the Guide tab", function()
  it("is the last of Hard Counters' own tabs, with a page for each subject", function()
    UI.with(function(ctx)
      local ns = ctx.hc
      local G, Win = ns.Guide, ns.Windows
      ns.ShowGuide(true)
      assert.is_true(Win.IsShown("guide"))
      assert.are.equal(5, Win.Def("guide").tabOrder)
      local f = G.Content()
      assert.are.equal("start", G.Page())
      local keys = {}
      for i, p in ipairs(G.Pages()) do
        keys[i] = p.key
        click(f.pages[i])
        assert.are.equal(p.key, G.Page())
        local text = f.text:GetText()
        assert.is_true(type(text) == "string" and #text > 200, p.key)
      end
      assert.are.same({ "start", "concepts", "boards", "tiles", "window", "history", "stints", "packs", "commands", "authors" }, keys)
      assert.are.same({}, ctx.env.errors)
    end, SEEN)
  end)

  it("lists every /hc command, a pack's with its name, and the slash command API", function()
    UI.with(function(ctx)
      local ns = ctx.hc
      ctx.HC:RegisterSlash("fish", function() end, "the fishing log", "My pack")
      _G.SlashCmdList.HARDCOUNTERS("guide commands")
      assert.is_true(ns.Windows.IsShown("guide"))
      assert.are.equal("commands", ns.Guide.Page())
      local text = ns.Guide.Content().text:GetText()
      for _, c in ipairs(ns.SlashList()) do
        assert.truthy(text:find("/hc " .. c.name, 1, true), c.name)
      end
      for _, s in ipairs({ "/hc tutorial", "/hc guide", "/hc board", "/hc stint", "/hc track", "/hc report", "/hc fish", "My pack",
        "/hc help", "/hardcounters" }) do
        assert.truthy(text:find(s, 1, true), s)
      end
      assert.is_nil(text:find("/hc welcome", 1, true))         -- (the old name works, unlisted)
      _G.SlashCmdList.HARDCOUNTERS("guide authors")
      text = ns.Guide.Content().text:GetText()
      assert.truthy(text:find("HardCounters:RegisterSlash(name, fn, help, owner)", 1, true))
      _G.SlashCmdList.HARDCOUNTERS("guide packs")
      text = ns.Guide.Content().text:GetText()
      assert.truthy(text:find("Hard Counters Basic", 1, true))
      assert.are.same({}, ctx.env.errors)
    end, SEEN)
  end)
end)
