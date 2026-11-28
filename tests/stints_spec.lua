-- Stints (0.4.0): the player's word for a kept run. The API's stint names over the run functions, the records read
-- in place, and the Stints tab on the shared browser: tree, columns, the detail at the bottom, actions, the header's
-- Start stint / Stop and keep, /hc stints and /hc stint (with /hc runs and /hc run kept unlisted).
local Env = require("env")
local UI = require("ui_boot")

local function boot()
  local env = Env.new()
  env:load()
  env.HC:RegisterPack("Test", { namespace = "t" })
  env.HC:RegisterCounter({ id = "t:gold", version = 1, measures = { "sum", "count" }, runTracked = true })
  Env.trackAll(env, "t:all", { "t:gold" })
  env:fire("ADDON_LOADED", "HardCounters")
  env.sv.HardCountersDB = _G.HardCountersDB
  env:fire("PLAYER_ENTERING_WORLD", true, false)
  return env
end

local function click(b) b:GetScript("OnClick")(b, "LeftButton") end

describe("stints", function()
  it("has the stint names of the run API: the same functions under the player's word", function()
    local env = boot()
    local HC, ns = env.HC, env.ns
    assert.is_true(HC:Supports("stints"))
    local id = assert(HC:StartStint("Felwood"))
    assert.are.equal(id, HC:GetStint().id)
    assert.is_nil(HC:StartStint("again"))
    HC:Emit("t:gold", 120)
    assert.is_true(HC:PauseStint())
    assert.is_true(HC:ResumeStint())
    assert.are.equal(2, HC:SplitStint("B"))
    env:advance(60)
    assert.are.equal(id, HC:StopStint())
    assert.is_nil(HC:GetStint())
    assert.are.equal(120, HC:GetStintRecord(id).deltas["t:gold"].sum)
    assert.are.equal(1, #HC:Stints())
    assert.is_true(HC:RenameStint(id, "Renamed"))
    assert.are.equal("Renamed", HC:Stints({ character = "current" })[1].label)
    -- the tab reads the kept records in place: no copy per refresh (HC:Stints hands out copies)
    local rows = ns.StintRows()
    assert.are.equal(env.sv.HardCountersDB.runs.list[1], rows[1])
    assert.are_not.equal(rows[1], HC:Stints()[1])
    assert.is_true(HC:DeleteStint(id))
    assert.are.equal(0, #HC:Stints())
    assert.are.equal(0, #ns.StintRows())
    HC:StartStint()
    assert.truthy(HC:DiscardStint())
    assert.is_nil(HC:GetStint())
  end)

  it("is a tab on the shared browser: places, the detail at the bottom, actions, Start stint and Stop and keep", function()
    local sv = { profiles = { Default = { windows = { _main = { selected = "runs" }, runs = { scale = 1 } } } } }
    UI.with(function(ctx)
      local HC, ns, env = ctx.HC, ctx.hc, ctx.env
      local Win = ns.Windows
      -- the tab was "runs" before 0.4.0: a window left on it opens on Stints (unless a pack's new trackers open
      -- their tab at this login, as they do here), and the old tab's settings are dropped
      assert.are_not.equal("runs", ns.settings.windows._main.selected)
      assert.is_nil(ns.settings.windows.runs)
      local def = Win.Def("stints")
      assert.are.equal("Stints", def.title)
      assert.are.equal(4, def.tabOrder)
      assert.truthy(def.about)
      assert.is_nil(Win.Def("runs"))
      -- two stints in two places, one of them with a split
      local zone = 1429
      ns.wow.zone = function() return zone end
      env:fire("ZONE_CHANGED_NEW_AREA")
      local a = assert(HC:StartStint("Goldshire"))
      HC:SplitStint("Second half")
      env:advance(600)
      HC:StopStint()
      zone = 1436
      env:fire("ZONE_CHANGED_NEW_AREA")
      local b = assert(HC:StartStint())
      env:advance(400)
      HC:StopStint()
      -- the tab
      _G.SlashCmdList.HARDCOUNTERS("stints")
      assert.is_true(Win.IsShown("stints"))
      local content = Win.Content("stints")
      content:SetSize(762, 568)
      local br = ns.StintsBrowser
      ns.RefreshRunList()
      local keys = {}
      for _, n in ipairs(br.nodesData) do keys[#keys + 1] = n.key end
      assert.are.same({ "all", "char", "places", "z:1429", "z:1436" }, keys)
      assert.are.equal(2, br.nodesData[1].count)
      assert.are.equal(1, br.nodesData[4].count)
      assert.are.equal(2, #br.rowsData)
      assert.are.equal(b, br.rowsData[1].key)                         -- newest first
      local row = br.rowsData[2]
      assert.are.equal("Goldshire", row.cells.name)
      assert.are.equal(HC:ZoneName(1429), row.cells.where)
      assert.are.equal("10:00", row.cells.active)
      assert.are.equal("Stint #" .. b, br.rowsData[1].cells.name)  -- no name: its number
      -- a place in the tree narrows the list
      br.node = "z:1436"
      br:Refresh()
      assert.are.equal(1, #br.rowsData)
      assert.are.equal(b, br.rowsData[1].key)
      -- ns.ShowRunCard (the card of 0.3): the tab with that stint selected, its detail at the bottom
      ns.ShowRunCard(HC:GetStintRecord(a))
      assert.are.equal("all", br.node)
      assert.are.equal(a, br.selected)
      local d = br.detail
      assert.truthy(d.title:GetText():find("Goldshire", 1, true))
      assert.truthy(d.text:GetText():find("Active 10:00", 1, true))
      assert.truthy(d.text:GetText():find("in " .. HC:ZoneName(1429), 1, true))
      local info = br.spec.detail(br:SelectedRow())
      local heads, values = {}, {}
      for _, it in ipairs(info.items) do
        if it.head then heads[#heads + 1] = it.text end
        if it.value then values[#values + 1] = it.value end
      end
      assert.are.equal("Splits", heads[#heads])
      assert.is_true(#values > 0)                                       -- two columns: label and value
      -- the actions: Rename..., Copy as text, Delete (each with a tip)
      local acts = br.spec.actions(br:SelectedRow())
      local names = {}
      for _, x in ipairs(acts) do names[#names + 1] = x.text; assert.truthy(x.tip, x.text) end
      assert.are.same({ "Rename...", "Copy as text", "Delete" }, names)
      ns.Boards.AskText = function(_, current, fn) assert.are.equal("Goldshire", current); fn("Westfall loop") end
      acts[1].func()
      assert.are.equal("Westfall loop", HC:GetStintRecord(a).label)
      br.spec.actions(br:SelectedRow())[2].func()                     -- (0.5.0) in the detail pane, not a window
      assert.truthy(br.textPane.title:GetText():find("Westfall loop", 1, true))
      assert.truthy(br.textPane.edit:GetText():find("Stint: Westfall loop", 1, true))
      assert.truthy(br.footer:GetText():find("2 stints kept", 1, true))
      ns.Boards.Confirm = function(_, fn) fn() end
      br.spec.actions(br:SelectedRow())[3].func()
      assert.is_nil(HC:GetStintRecord(a))
      assert.are.equal(1, #br.rowsData)                               -- HC_RUN_DELETED refreshed it
      assert.is_nil(br.selected)
      -- the header: Start stint, then Stop and keep while one is open
      local head = br.headerBtns[1]
      assert.are.equal("Start stint", head:GetText())
      click(head)
      assert.truthy(HC:GetStint())
      assert.are.equal("Stop and keep", head:GetText())
      env:advance(30)
      click(head)
      assert.is_nil(HC:GetStint())
      assert.are.equal("Start stint", head:GetText())
      assert.are.equal(2, #br.rowsData)
      -- the chat line: /hc stint, and the names before 0.4.0 still work unlisted
      _G.SlashCmdList.HARDCOUNTERS("stint start Mine")
      assert.are.equal("Mine", HC:GetStint().label)
      _G.SlashCmdList.HARDCOUNTERS("run stop")
      assert.is_nil(HC:GetStint())
      _G.SlashCmdList.HARDCOUNTERS("runs")
      assert.is_false(Win.IsShown("stints"))
      local listed = {}
      for _, c in ipairs(ns.SlashList()) do listed[c.name] = true end
      assert.is_true(listed.stints and listed.stint)
      assert.is_nil(listed.runs or listed.run)
      assert.are.same({}, env.errors)
    end, { settings = sv })
  end)
end)
