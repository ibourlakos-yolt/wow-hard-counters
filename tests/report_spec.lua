-- The Report a problem tab (0.5.0, DESIGN §17.16 F1) and text to copy in the browser's detail pane (F2).
-- The report's note (body.note): carried, kept to one line of 200 letters, shed last, decoded by tools/decode_report.
local Env = require("env")
local UI = require("ui_boot")

local function click(b) b:GetScript("OnClick")(b, "LeftButton") end

describe("the report's note", function()
  it("carries the player's line on what went wrong, one line of 200 letters at most, and says so", function()
    local env = Env.new():boot()
    local ns = env.ns
    local _, body = ns.BuildReport({})
    assert.is_nil(body.note)
    _, body = ns.BuildReport({ note = "   " })
    assert.is_nil(body.note)
    _, body = ns.BuildReport({ note = "  Boards vanished\nafter a reload " })
    assert.are.equal("Boards vanished after a reload", body.note)
    local summary = table.concat(ns.ReportSummary(body), "\n")
    assert.truthy(summary:find("Your note on what went wrong", 1, true))
    -- 200 letters, not bytes: an accented letter is two bytes and is never cut in half
    assert.are.equal(200, #ns.ReportNote(string.rep("a", 250)))
    local accented = ns.ReportNote(string.rep("\195\169", 250))
    assert.are.equal(400, #accented)
    assert.truthy(accented:match("\195\169$"))
  end)

  it("sheds the note last, after the Diagnostics section", function()
    local env = Env.new():boot()
    local ns = env.ns
    ns.reportSection = function() return { v = 1, funcs = { GetMoney = { s = "ok" } } } end
    ns.wow.encodeReport = function(t)
      env.lastReportBody = t
      local n = 100
      if t.granary then n = n + 30000 end
      if t.diag then n = n + 30000 end
      if t.note then n = n + 100 end
      return string.rep("x", n), "raw"
    end
    local s, body = ns.BuildReport({ note = "it broke" })
    assert.is_true(#s <= ns.REPORT_MAX)
    assert.is_nil(body.diag)
    assert.are.equal("it broke", body.note)
    assert.is_true(body.truncated)
  end)

  it("prints the note when decoded, and every key the decoder doesn't know", function()
    package.path = "./?.lua;./tests/helpers/?.lua;" .. package.path
    local F = require("files")
    local saved = rawget(_G, "LibStub")
    rawset(_G, "LibStub", nil)
    rawset(_G, "strmatch", string.match)
    for _, p in ipairs((F.loadList("HardCounters/HardCounters.toc"))) do
      if p:match("Libs/LibStub/LibStub%.lua$") then dofile(p) end
    end
    for _, p in ipairs((F.loadList("HardCounters/HardCounters.toc"))) do
      if p:match("Libs/LibGranaryDB%-1%.0/") and not p:match("Adapters/WoW%.lua$") then dofile(p) end
    end
    local C = _G.LibStub("LibGranaryDB-1.0")._M.Codec
    rawset(_G, "LibStub", saved)
    local raw = C.cborEncode({ fmt = 1, hc = "0.5.0", note = "Boards vanished", later = "a key from a newer build" })
    local str = "!HCReport:1!n:" .. C.adler32(raw) .. ":" .. C.base64Encode(raw) .. "!End:HCReport:1!"
    local path = os.tmpname()
    local fh = assert(io.open(path, "wb"))
    fh:write("pasted: " .. str .. "\n")
    fh:close()
    local p = io.popen("lua5.1 tools/decode_report.lua '" .. path .. "' 2>&1")
    local out = p:read("*a")
    p:close()
    os.remove(path)
    assert.truthy(out:find("Note: Boards vanished", 1, true), out)
    assert.truthy(out:find("later = \"a key from a newer build\"", 1, true), out)
  end)
end)

describe("the Report a problem tab", function()
  it("is a tab along the bottom with the note, the ticks, what is in it and the text, selected", function()
    UI.with(function(ctx)
      local ns, Win = ctx.hc, ctx.hc.Windows
      assert.are.equal("bottom", Win.Def("report").place)
      assert.are.equal(950, Win.Def("report").bottomOrder)
      local f = ns.ShowReportBox()
      assert.are.equal(Win.Content("report"), f)
      assert.is_true(f:IsShown())
      -- selected on every rebuild: the fake client records nothing, so count the calls
      local lit = 0
      f.edit.HighlightText = function() lit = lit + 1 end
      -- the note: Enter (or leaving the box) puts it in the report; it stays until the next reload, never saved
      f.noteBox:SetText("Boards vanished\nafter a reload")
      f.noteBox:GetScript("OnEditFocusLost")(f.noteBox)
      assert.are.equal("Boards vanished after a reload", f.body.note)
      assert.truthy(f.summary:GetText():find("Your note on what went wrong", 1, true))
      assert.is_true(lit > 0)
      Win.ShowMain(false)
      ns.ShowReportBox()
      assert.are.equal("Boards vanished\nafter a reload", f.noteBox:GetText())
      assert.are.equal("Boards vanished after a reload", f.body.note)
      assert.is_nil(ns.settings.reportNote)
      -- read-only: typing puts the report back
      local text = f.text
      f.edit:SetText("junk")
      f.edit:GetScript("OnTextChanged")(f.edit, true)
      assert.are.equal(text, f.edit:GetText())
      -- Select all, and a right-click on the text offers it too
      lit = 0
      click(f.selectBtn)
      assert.are.equal(1, lit)
      local shown
      local realShow = ns.Menu.Show
      ns.Menu.Show = function(_, items) shown = items end
      f.edit:GetScript("OnMouseUp")(f.edit, "RightButton")
      ns.Menu.Show = realShow
      assert.are.equal(1, #shown)
      assert.are.equal("Select all", shown[1].text)
      lit = 0
      shown[1].func()
      assert.are.equal(1, lit)
      assert.truthy(f.size:GetText():find("characters", 1, true))
      assert.is_false(f.short:IsShown())
      -- shortened: said in amber at the bottom
      local realBuild = ns.BuildReport
      ns.BuildReport = function() return "!HCReport:1!short", { truncated = true, warn = {} } end
      ns.RebuildReport()
      assert.is_true(f.short:IsShown())
      ns.BuildReport = realBuild
      ns.RebuildReport()
      assert.is_false(f.short:IsShown())
      assert.are.same({}, ctx.env.errors)
    end)
  end)

  it("offers Diagnostics' checks, the log marker and its tab when it is loaded, and the Packs tab when not", function()
    UI.with(function(ctx)
      local ns, D, Win = ctx.hc, ctx.diag, ctx.hc.Windows
      local f = ns.ShowReportBox()
      assert.is_true(f.diagOn:IsShown())
      assert.is_false(f.diagOff:IsShown())
      local ran, marked = 0, 0
      local realRun, realMark = D.RunProbes, D.Marker
      D.RunProbes = function() ran = ran + 1 end
      D.Marker = function() marked = marked + 1; return "MARK #1" end
      local builds = 0
      local realBuild = ns.BuildReport
      ns.BuildReport = function(o) builds = builds + 1; return realBuild(o) end
      click(f.runBtn)
      assert.are.equal(1, ran)
      assert.are.equal(1, builds)                    -- the report is made again with the fresh checks
      click(f.markBtn)
      assert.are.equal(1, marked)
      D.RunProbes, D.Marker, ns.BuildReport = realRun, realMark, realBuild
      click(f.openBtn)
      assert.is_true(Win.IsShown("hcdiag:console"))
      -- without Diagnostics: one grey line and the way to the Packs tab
      local tools = ns.reportTools
      ns.reportTools = nil
      ns.ShowReportBox()
      assert.is_false(f.diagOn:IsShown())
      assert.is_true(f.diagOff:IsShown())
      click(f.packsBtn)
      assert.is_true(Win.IsShown("packs"))
      ns.reportTools = tools
      assert.are.same({}, ctx.env.errors)
    end)
  end)
end)

describe("text to copy in the browser's detail pane", function()
  it("takes the pane's place, selected and read-only, until Back to details or another row", function()
    UI.with(function(ctx)
      local ns = ctx.hc
      local parent = _G.CreateFrame("Frame", nil, _G.UIParent)
      parent:SetSize(700, 500)
      local rows = { { key = "r1", cells = { name = "One" } }, { key = "r2", cells = { name = "Two" } } }
      local br = ns.Browser.New(parent, {
        columns = { { key = "name", title = "Name" } },
        nodes = function() return { { key = "a", text = "A" }, { key = "b", text = "B" } } end,
        rows = function() return rows end,
        detail = function(row) return { title = "Detail " .. row.key, lines = {} } end,
      })
      br:Refresh()
      br:Select("r1")
      local t = br:ShowText("Copy me", "line one\nline two")
      assert.are.equal(br.textPane, t)
      assert.is_true(t:IsShown())
      assert.are.equal("Copy me", t.title:GetText())
      assert.are.equal("Back to details", t.back:GetText())
      t.edit:SetText("typed")
      t.edit:GetScript("OnTextChanged")(t.edit, true)
      assert.are.equal("line one\nline two", t.edit:GetText())
      br:Refresh()                                         -- the same row: it stays
      assert.is_true(t:IsShown())
      br:Select("r2")                                      -- another row: the details again
      assert.is_false(t:IsShown())
      assert.are.equal("Detail r2", br.detail.title:GetText())
      br:ShowText("Again", "x")
      click(t.back)
      assert.is_false(t:IsShown())
      br:ShowText("Again", "x")
      br.tree.rows[2]:GetScript("OnClick")(br.tree.rows[2])  -- another node
      assert.is_false(t:IsShown())
      assert.are.same({}, ctx.env.errors)
    end)
  end)
end)
