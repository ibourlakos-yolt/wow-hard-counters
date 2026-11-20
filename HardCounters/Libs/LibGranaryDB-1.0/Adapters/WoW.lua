-- WoW adapters: the game's globals behind the adapter interfaces (SPEC §4). Loaded only in game
-- (via lib.xml); tests never load this file. Each adapter wraps only what the library uses.
-- Verified on Forever (Interface 16001, build 1.60.1.70938) by the in-game selftest: C_DateAndTime
-- weekly reset, C_EncodingUtil CBOR / raw Deflate / Base64, issecretvalue, raw binary strings in
-- SavedVariables. Tests load this file with mocked globals (tests/wow_adapter_spec.lua).
local lib = LibStub and LibStub("LibGranaryDB-1.0", true)
local M = lib and lib.__M
if not M then return end
if type(GetServerTime) ~= "function" then return end -- not in WoW

local type, pcall = type, pcall

M.wowAdapters = function()
  local A = {}

  A.clock = {
    now = function() return GetServerTime() end,
    preciseMs = function() return debugprofilestop() end,
  }

  A.calendar = {
    -- date() allocates a table; it's only called when an hour boundary passes.
    fields = function(t, utc)
      local d = date(utc and "!*t" or "*t", t)
      return d.year, d.month, d.day, d.hour, d.min, d.sec
    end,
    resetAnchor = function(region)
      local api = C_DateAndTime and C_DateAndTime.GetSecondsUntilWeeklyReset
      if type(api) == "function" then
        local ok, secs = pcall(api)
        if ok and type(secs) == "number" and secs > 0 and secs <= 604800 then
          -- GetServerTime() + secs is the *next* reset; using it raw made every current week key -1
          -- (found in game, r1). Normalize so the anchor is the same in every session.
          return M.Adapters.normalizeAnchor(GetServerTime() + secs)
        end
      end
      return M.Adapters.RESET_ANCHORS[region] or M.Adapters.RESET_ANCHORS.EU
    end,
  }

  local EU = C_EncodingUtil
  if type(EU) == "table" and type(EU.SerializeCBOR) == "function" then
    A.serializer = {
      encode = function(v) return EU.SerializeCBOR(v) end,
      -- imports never use this: they always go through the pure decoder with limits
      decode = function(s)
        local ok, v = pcall(EU.DeserializeCBOR, s)
        if ok then return v end
        return nil, "cbor: " .. tostring(v)
      end,
    }
  end
  if type(EU) == "table" and type(EU.CompressString) == "function" and type(EU.DecompressString) == "function"
    and type(Enum) == "table" and Enum.CompressionMethod and Enum.CompressionMethod.Deflate then
    local DEFLATE = Enum.CompressionMethod.Deflate
    A.compressor = {
      name = "deflate",
      compress = function(s) return EU.CompressString(s, DEFLATE) end,
      decompress = function(s)
        local ok, out = pcall(EU.DecompressString, s, DEFLATE)
        if ok and type(out) == "string" then return out end
        return nil
      end,
    }
  end
  if type(EU) == "table" and type(EU.EncodeBase64) == "function" and type(EU.DecodeBase64) == "function" then
    A.encoder = {
      encode = function(s) return EU.EncodeBase64(s) end,
      decode = function(s)
        local ok, out = pcall(EU.DecodeBase64, s)
        if ok and type(out) == "string" then return out end
        return nil, "bad base64"
      end,
    }
  end

  A.scheduler = {
    after = function(sec, fn) C_Timer.After(sec, fn) end,
  }

  if type(issecretvalue) == "function" then
    A.secret = { isSecret = function(v) return issecretvalue(v) == true end }
  end

  A.errors = {
    handle = function(err)
      local h = geterrorhandler and geterrorhandler()
      if h then h(err) end
    end,
  }

  A.env = {
    gameVersion = function() return (GetBuildInfo()) end,
  }

  return A
end
