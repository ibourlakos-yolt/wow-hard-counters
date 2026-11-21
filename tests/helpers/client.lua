-- A permissive fake client for load smoke tests: frames accept any method, unknown globals resolve to a stub and
-- are recorded. It proves files load and windows build without nil errors; it proves nothing about how they look.
local C = {}

local frameMethods = {
  -- anchors are remembered (the grip re-anchors by the top-left corner); none set reads as CENTER
  SetPoint = function(self, point, rel, relPoint, x, y)
    if type(rel) == "number" or rel == nil and relPoint == nil then rel, relPoint, x, y = nil, point, rel, relPoint end
    if type(relPoint) == "number" then relPoint, x, y = point, relPoint, x end
    self._points = self._points or {}
    self._points[#self._points + 1] = { point, rel, relPoint or point, x or 0, y or 0 }
  end,
  ClearAllPoints = function(self) self._points = {} end,
  GetPoint = function(self, i)
    local pt = self._points and self._points[i or 1]
    if not pt then return "CENTER", nil, "CENTER", 0, 0 end
    return pt[1], pt[2], pt[3], pt[4], pt[5]
  end,
  GetNumPoints = function(self) return self._points and #self._points or 1 end,
  GetLeft = function(self) return self._left or 100 end,
  GetTop = function(self) return self._top or 500 end,
  IsShown = function(self) return self._shown end,
  -- as in game: OnShow fires only when a hidden frame is shown (frames are created shown)
  Show = function(self) local was = self._shown; self._shown = true; local f = self._scripts.OnShow; if not was and f then f(self) end end,
  Hide = function(self) local was = self._shown; self._shown = false; local f = self._scripts.OnHide; if was and f then f(self) end end,
  SetScript = function(self, k, fn) self._scripts[k] = fn end,
  GetScript = function(self, k) return self._scripts[k] end,
  HookScript = function(self, k, fn) self._scripts[k] = fn end,
  CreateFontString = function(self) local r = C.frame(self._client); r._parent = self; return r end,
  CreateTexture = function(self) local r = C.frame(self._client); r._parent = self; return r end,
  RegisterEvent = function(self, e) self._events[e] = true; self._client.frames[self] = true end,
  UnregisterEvent = function(self, e) self._events[e] = nil end,
  IsEventRegistered = function(self, e) return self._events[e] end,
  GetVerticalScrollRange = function() return 0 end,
  -- sizes, scale and parent are remembered (window tests read them back); unset sizes read as before
  SetSize = function(self, w, h) self._w, self._h = w, h end,
  SetWidth = function(self, w) self._w = w end, SetHeight = function(self, h) self._h = h end,
  GetWidth = function(self) return self._w or 100 end, GetHeight = function(self) return self._h or 20 end,
  SetResizeBounds = function(self, ...) self._bounds = { ... } end,
  SetScale = function(self, s) self._scale = s end,
  GetScale = function(self) return self._scale or 1 end,
  SetParent = function(self, p) self._parent = p end,
  GetParent = function(self) return self._parent end,
  SetShown = function(self, v) if v then self:Show() else self:Hide() end end,
  GetText = function(self) return self._text end,
  SetText = function(self, t) self._text = t end,
  GetName = function(self) return self._name end,
  -- frame levels are remembered (the panel template puts its border and close button high, as in game)
  SetFrameLevel = function(self, l) self._level = l end,
  GetFrameLevel = function(self) return self._level or 1 end,
  SetFrameStrata = function(self, s) self._strata = s end,
  GetFrameStrata = function(self) return self._strata or "MEDIUM" end,
  -- mouse: boards are click-through unless edited (v2 M5)
  EnableMouse = function(self, v) self._mouse = v and true or false end,
  IsMouseEnabled = function(self) return self._mouse or false end,
  GetStringWidth = function() return 50 end,
  GetEffectiveScale = function() return 1 end,
}

function C.frame(client, name)
  local f = { _scripts = {}, _events = {}, _shown = true, _client = client, _name = name }
  return setmetatable(f, { __index = function(_, k)
    if frameMethods[k] then return frameMethods[k] end
    -- widget methods are PascalCase; anything else is an addon's own field, nil until set (as on real frames)
    if type(k) ~= "string" or not k:match("^%u") then return nil end
    -- unknown getters hand back a child object (GetNormalTexture, GetFontString, ...); everything else does nothing
    if type(k) == "string" and (k:match("^Get") or k:match("^Create")) then return function() return C.frame(client) end end
    return function() end
  end })
end

--- Install fake globals; returns the client (with .missing: names of unknown globals that were read).
function C.install(env, opts)
  local client = { frames = {}, missing = {} }
  local G = _G
  -- Blizzard templates the window host uses: their child frames exist, as in game (opts.templates = false: a
  -- client without them, for the fallback)
  local templates = not (opts and opts.templates == false)
  G.CreateFrame = function(_, name, parent, template)
    local f = C.frame(client, name)
    f._parent = parent
    f._template = template
    if templates and template == "ButtonFrameTemplate" then
      f.Inset, f.CloseButton, f.NineSlice = C.frame(client), C.frame(client), C.frame(client)
      f.NineSlice._level, f.CloseButton._level = 500, 510   -- the border art sits high above the frame
      f.PortraitContainer = { portrait = C.frame(client) }
      f.TitleContainer = { TitleText = C.frame(client) }
    end
    if templates and template == "PanelTabButtonTemplate" then
      f.Text, f.Left, f.Right = C.frame(client), C.frame(client), C.frame(client)
      f.Left._w, f.Right._w = 20, 20                    -- the side art, the tab's minimum width
    end
    if name then G[name] = f end
    return f
  end
  if templates then
    G.PanelTemplates_SelectTab = function(tab) tab._selected = true end
    G.PanelTemplates_DeselectTab = function(tab) tab._selected = false end
    G.PanelTemplates_TabResize = function() end
    G.ButtonFrameTemplate_HidePortrait = function(f) f._portraitHidden = true end
  end
  G.Minimap = C.frame(client, "Minimap")
  G.UIParent = C.frame(client, "UIParent")
  G.UIParent._w, G.UIParent._h = 1920, 1080          -- the screen windows must fit on
  G.UISpecialFrames, G.StaticPopupDialogs, G.SlashCmdList = {}, {}, {}
  G.StaticPopup_Show = function() end
  G.DEFAULT_CHAT_FRAME = { AddMessage = function() end }
  G.UIErrorsFrame = { AddMessage = function() end }
  G.tinsert, G.tremove, G.wipe = table.insert, table.remove, function(t) for k in pairs(t) do t[k] = nil end return t end
  G.strsplit = function(sep, s) local out = {} for p in (s .. sep):gmatch("(.-)" .. sep:gsub("%p", "%%%0")) do out[#out + 1] = p end return unpack(out) end
  G.format, G.strfind, G.strsub, G.strlen = string.format, string.find, string.sub, string.len
  G.gsub, G.strlower, G.strupper = string.gsub, string.lower, string.upper
  G.IsShiftKeyDown = function() return false end
  G.GetLocale = function() return "enUS" end
  G.GetBuildInfo = function() return "1.60.1", "70938", "", 16001 end
  G.GameFontHighlightSmall, G.GameFontNormalSmall, G.ChatFontNormal = {}, {}, {}
  G.GetItemInfo = function() return nil end
  G.GetItemInfoInstant = function(id) return id, nil, nil, nil, nil, 7, 5 end
  G.GetRealmName = function() return "Realm" end
  G.UnitName = function() return "Tester" end
  G.UnitClass = function() return "Mage", "MAGE", 8 end
  G.UnitRace = function() return "Human", "Human", 1 end
  G.UnitFactionGroup = function() return "Alliance" end
  G.UnitGUID = function() return env.guid end
  G.GetCurrentRegion = function() return 3 end
  G.IsInInstance = function() return false, "none" end
  G.InCombatLockdown = function() return false end
  G.UnitIsAFK = function() return false end
  G.GetInboxInvoiceInfo = function() return nil end
  G.Enum = { UIMapType = { Micro = 5, Orphan = 6 }, CompressionMethod = { Deflate = 0 } }
  G.C_Map = { GetBestMapForUnit = function() return 1429 end, GetMapInfo = function(id) return { mapID = id, name = "Map", mapType = 3, parentMapID = 0 } end }
  G.C_AddOns = { GetNumAddOns = function() return 0 end }
  G.C_EncodingUtil = { SerializeCBOR = function() return "cbor" end, CompressString = function(s) return s end, EncodeBase64 = function(s) return s end }
  G.C_DateAndTime = { GetSecondsUntilWeeklyReset = function() return 3600 end }
  G.C_Reputation = { GetNumFactions = function() return 0 end }
  G.C_Item = { GetItemInfo = function() return nil end, GetItemInfoInstant = function(id) return id, nil, nil, nil, nil, 7, 5 end,
    RequestLoadItemDataByID = function() end }
  -- WoW's xpcall passes extra arguments to the function (PUC Lua 5.1's doesn't); Ace relies on it
  local xp = xpcall
  G.xpcall = function(f, h, ...)
    local n, args = select("#", ...), { ... }
    return xp(function() return f(unpack(args, 1, n)) end, h)
  end
  client.restoreXpcall = function() G.xpcall = xp end
  G.Settings = {
    RegisterCanvasLayoutCategory = function(_, name) return { ID = name } end,
    RegisterCanvasLayoutSubcategory = function(_, _, name) return { ID = name } end,
    RegisterAddOnCategory = function() end,
    GetCategory = function(id) return { ID = id } end,
  }
  G.GetMoney = function() return 1000 end
  G.UnitXP = function() return 0 end
  G.UnitXPMax = function() return 1000 end
  G.UnitLevel = function() return 20 end
  for _, k in ipairs({ "LOOT_ITEM_SELF", "LOOT_ITEM_SELF_MULTIPLE", "YOU_LOOT_MONEY", "LOOT_MONEY_SPLIT", "GOLD_AMOUNT",
    "SILVER_AMOUNT", "COPPER_AMOUNT", "COMBATLOG_XPGAIN_FIRSTPERSON", "COMBATLOG_XPGAIN_FIRSTPERSON_UNNAMED",
    "FACTION_STANDING_INCREASED" }) do G[k] = "%s %d" end
  client.restore = function() setmetatable(G, nil); client.restoreXpcall() end
  -- unknown globals read as nil (like an API this client lacks) and are recorded for review
  setmetatable(G, { __index = function(_, k)
    client.missing[k] = true
    return nil
  end })
  local _ = env
  return client
end

return C
