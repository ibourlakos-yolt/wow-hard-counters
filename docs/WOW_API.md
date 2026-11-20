# WoW API used by Hard Counters and Farmer (HC-5)

What the code actually calls, per file group. **Source of truth:** the `read_globals` lists in `.luacheckrc` here and
in `packs/Farmer/.luacheckrc`; lint fails on any game global not listed. When you add one there, add it here.
Behaviour verdicts live in [`api-surface.md`](api-surface.md); this file is the inventory.
Status: first in-game run read 2026-11-14 (outdoors only): Farmer's events and strings behave as expected, except
`MAIL_CLOSED`, which never fires; run 2's first session added dungeons (chat lines arrive). Verdicts per call are in [`api-surface.md`](api-surface.md). The LibGranaryDB adapter's own calls are verified: see
`../LibGranaryDB/docs/WOW_API.md`.

## Engine (`HardCounters/Core/`): only through `ns.wow` (`Core/WoW.lua`)

| API | Used for |
|---|---|
| `GetServerTime` | every stored timestamp (UTC epoch) |
| `GetTime`, `debugprofilestop` | active-time intervals, snapshot timing |
| `C_Timer.After`, `C_Timer.NewTicker` | the scheduler (the only polling path) |
| `issecretvalue` | the secret guard before any arithmetic or comparison |
| `geterrorhandler` | hand caught errors to BugSack without breaking the caller |
| `UnitGUID`, `UnitName`, `UnitClass`, `GetRealmName`, `UnitFactionGroup` (`"player"`) | LibGranaryDB entity |
| `GetBuildInfo`, `GetLocale`, `GetCurrentRegion` | report, reset-week fallback |
| `UnitIsAFK` | active time (secret-guarded: a secret flag counts as active) |
| `C_Map.GetBestMapForUnit`, `C_Map.GetMapInfo`, `Enum.UIMapType` | the zone key outdoors (0 when unknown; the zone text is no longer used, HC-25) |
| `IsInInstance`, `GetInstanceInfo` | the zone key inside instances: 100000 + instance ID (HC-13; the map API is nil there, run 3) |
| `InCombatLockdown` | diagnostics context |
| `C_AddOns.GetNumAddOns/GetAddOnInfo/IsAddOnLoaded` | opt-in addon list in `/hc report` |
| `C_EncodingUtil.SerializeCBOR/CompressString/EncodeBase64`, `Enum.CompressionMethod` | `/hc report` encoding |
| `hooksecurefunc` | hook sources (`RegisterSource` mode `"hook"`) |
| `GetCursorInfo`, `ClearCursor` | the item the cursor carries, dropped on a board (HC-34; ✅ probed 2026-11-18: `"item"`, id, link) |
| `C_Reputation.GetNumFactions`, `C_Reputation.GetFactionDataByIndex` | the faction picker's list (HC-34; ✅ probed 2026-11-18) |
| `C_Item.GetItemInfoInstant` (with a name) | an item name typed in "Other..." becomes its id (HC-47; ❓ on Forever, and only for items the client has seen) |
| `CreateFrame` (`Core/Events.lua`) | the one event frame |
| Events | `ADDON_LOADED`, `PLAYER_ENTERING_WORLD` (login vs reload), `PLAYER_LOGOUT`, `LOADING_SCREEN_ENABLED/DISABLED`, `PLAYER_FLAGS_CHANGED`, `ZONE_CHANGED`, `ZONE_CHANGED_NEW_AREA`, `ZONE_CHANGED_INDOORS` |

## UI (`HardCounters/UI/`)

`CreateFrame` (templates `UIPanelButtonTemplate`, `UIPanelCloseButton`, `UIPanelScrollFrameTemplate`), `UIParent`,
`UISpecialFrames`, `tinsert`, `DEFAULT_CHAT_FRAME`, `SlashCmdList`, `StaticPopupDialogs`, `StaticPopup_Show`,
`GameTooltip`, `C_Item.GetItemInfo` / `GetItemInfo`, `C_Item.RequestLoadItemDataByID`, `IsShiftKeyDown`, `GetCursorPosition` (which tile of a grid row was clicked; HC-30's Alt + right-click and its `IsAltKeyDown` / `MODIFIER_STATE_CHANGED` went with HC-41), the event `CURSOR_CHANGED` and the frame script `OnReceiveDrag` (an item dropped on a board, HC-34: the event fires on Forever, the drop is unseen), fonts
`GameFontNormal*`, `GameFontHighlight`, `GameFontHighlightSmall`, `GameFontDisableSmall`, `ChatFontNormal`; Ace3 (`AceDB`, `AceConfig`, `AceConfigDialog` →
Blizzard `Settings`), `LibDataBroker-1.1`.
Window host (`UI/Windows.lua`, every window and popup): frame `SetResizable`, `SetResizeBounds` (falls back to
`SetMinResize`/`SetMaxResize`), `StartSizing`, `StopMovingOrSizing`, `GetScale`/`SetScale`, `SetParent` +
`SetAllPoints` (content moves between its own frame and the shared frame's tab body), `SetFrameLevel`, the
`UI-ChatIM-SizeGrabber` textures, `UISpecialFrames` (Escape; entries added and removed as tabs change), `LockHighlight`
(the Ledger's selected period). Optional: `BlizzMoveAPI:RegisterAddOnFrames`, once per frame (read with `rawget`, called in
`pcall`; BlizzMove v3.8.8 is installed and lists Forever). ✅ Repeated registrations for one addon stick (run 2
evening: BlizzMove saved scales for both `HardCountersRunPanel` and `HardCountersMain`).
Panel chrome (2026-11-15, all ❓ until seen in game; each guarded, with a plain-frame fallback): `CreateFrame` with
`ButtonFrameTemplate` (children `Inset`, `CloseButton`, `NineSlice`, `PortraitContainer.portrait`,
`TitleContainer.TitleText`; methods `SetTitle`, `SetPortraitToAsset`), `ButtonFrameTemplate_HidePortrait`,
`PanelTabButtonTemplate` with `PanelTemplates_SelectTab` / `PanelTemplates_DeselectTab` / `PanelTemplates_TabResize`,
`SetToplevel`, `Raise`, `GetLeft`/`GetTop` (the grip re-anchors by the top-left corner before `StartSizing`).
Minimap button: `LibDBIcon-1.0` (minor 57; it lists Interface 16001), which uses `Minimap`, `GetMinimapShape` and the
addon compartment when present (`AddonCompartmentFrame:RegisterAddon`: the AddOns menu entry, HC-45; the menu
exists on Forever, user's screenshot 2026-11-18; our entry is ❓). Frame strata `LOW` for boards (HC-43).

## Diagnostics (`HardCounters_Diagnostics/`)

`CreateFrame`, `C_Timer`, `UIErrorsFrame`, `date`, `C_Map`. The probes read many more through `_G` lookups on
purpose (they test existence): see `Probes.lua` `FUNCS`, `EVENTS`, `STRINGS`. HC-42 (c), 2026-11-20: ❓
`EventRegistry:RegisterCallback("EditMode.Enter" / "EditMode.Exit")` and `EditModeManagerFrame:HookScript("OnShow" /
"OnHide")`, read through `_G` as well.

Since HC-42 the launcher (`UI/Broker.lua`) also reads `CreateFrame`, `UIParent` and `GetCursorPosition`: its
right-click menu opens at the cursor.

## Basics (`HardCounters/Basics/`, v2 M4)

| API | Used for |
|---|---|
| `GetMoney` | the money truth (diff), gold owned |
| `UnitXP`, `UnitXPMax`, `UnitLevel` | the XP truth (diff across one level-up); time to level |
| `GetXPExhaustion` | rested XP (probed in the Probes tab since v2 M0) |
| `GetTime`, `C_Timer.After` | the attributor timeout (5 s) |
| Events | `PLAYER_MONEY`, `PLAYER_XP_UPDATE`, `PLAYER_ENTERING_WORLD` (through `RegisterSource`) |

## Farmer (`packs/Farmer/HardCounters_Farmer/`)

| API | Used for |
|---|---|
| `GetMoney` | (moved to Basics, v2 M4) |
| `UnitXP`, `UnitXPMax`, `UnitLevel` | (moved to Basics, v2 M4) |
| `C_Item.GetItemInfo` / `GetItemInfo` | quality and vendor price at loot time |
| `C_Item.GetItemInfoInstant` / `GetItemInfoInstant` | class and subclass (farm category) |
| `GetInboxInvoiceInfo` | auction-house income from mail (seller invoices) |
| `GetInboxHeaderInfo`, `GetSendMailMoney` | FM-16: the sender of mail whose money is taken, the amount on the send form (own characters' mail books under `alts`) |
| `C_Reputation.GetNumFactions`, `C_Reputation.GetFactionDataByIndex` | faction name → ID |
| `GetTime`, `C_Timer.After` | attribution windows |
| Global strings | `LOOT_ITEM_SELF(_MULTIPLE)`, `YOU_LOOT_MONEY`, `LOOT_MONEY_SPLIT`, `GOLD/SILVER/COPPER_AMOUNT`, `COMBATLOG_XPGAIN_FIRSTPERSON(_UNNAMED)`, `FACTION_STANDING_INCREASED` |
| Hooks | `RepairAllItems`, `TakeInboxMoney`, `AutoLootMailItem`, `SendMail` (post-hooks through `RegisterSource`) |
| Events | `PLAYER_MONEY`, `CHAT_MSG_MONEY`, `CHAT_MSG_LOOT`, `GET_ITEM_INFO_RECEIVED`, `PLAYER_XP_UPDATE`, `CHAT_MSG_COMBAT_XP_GAIN`, `QUEST_TURNED_IN`, `CHAT_MSG_COMBAT_FACTION_CHANGE`, `PLAYER_ENTERING_WORLD`, `PLAYER_INTERACTION_MANAGER_FRAME_SHOW/HIDE` (with `Enum.PlayerInteractionType`), `MERCHANT_SHOW/CLOSED`, `MAIL_SHOW/CLOSED`, `AUCTION_HOUSE_SHOW/CLOSED`, `TRAINER_SHOW/CLOSED`, `TAXIMAP_OPENED/CLOSED`, `TRADE_SHOW/CLOSED` |
| UI | `CreateFrame` (the Ledger's content; Hard Counters hosts the window), `SlashCmdList` (the `/hcf` alias) |
