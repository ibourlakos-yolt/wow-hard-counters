# Embedded libraries

Loaded by `embeds.xml`. **Never edit files in this folder.** To update one, replace the whole folder from its source
and update the table below.

| Library | Version | Source | Licence |
|---|---|---|---|
| LibStub | minor 2 | Ace3 `Release-r1403` | public domain |
| CallbackHandler-1.0 | from Ace3 `Release-r1403` | https://github.com/WoWUIDev/Ace3 (tag `Release-r1403`, downloaded 2026-11-14) | Ace3 BSD (`Ace3-LICENSE.txt`) |
| AceDB-3.0, AceDBOptions-3.0 | Ace3 `Release-r1403` | same | same |
| AceGUI-3.0 (needed by AceConfigDialog) | Ace3 `Release-r1403` | same | same |
| AceConfig-3.0 (+ Registry, Cmd, Dialog) | Ace3 `Release-r1403` | same | same |
| AceLocale-3.0 | Ace3 `Release-r1403` | same | same |
| LibDataBroker-1.1 | minor 4 | https://github.com/tekkub/libdatabroker-1-1 `master` (`LibDataBroker-1.1.lua`, 3,139 bytes, downloaded 2026-11-14) | none stated in the file or repo; embedded as most addons do (accepted by the user, 2026-11-20) |
| LibDBIcon-1.0 | minor 57 (tag `v12.1.2`; its TOC lists Interface 16001) | https://repos.wowace.com/wow/libdbicon-1-0/tags/v12.1.2/LibDBIcon-1.0/ (`LibDBIcon-1.0.lua` 20,532 bytes, `lib.xml`; downloaded 2026-11-15 with the user's OK) | "All Rights Reserved" (its TOC); embedded as most addons do (accepted by the user, 2026-11-20) |
| LibGranaryDB-1.0 | r5 (MINOR 5) | `../../../LibGranaryDB/LibGranaryDB-1.0`, copied by `tools\sync-libs.ps1`; `tests/toolchain_spec.lua` fails if this copy differs | Yolt Labs, MIT (the repo's `LICENSE`) |

Left out of Ace3 on purpose: AceAddon, AceEvent, AceTimer, AceHook, AceBucket, AceComm, AceSerializer, AceTab and
AceConsole. Hard Counters has its own small event, timer and slash-command code. AceConfigCmd loads AceConsole only
for chat commands, which we don't register.

Not embedded yet: LibSharedMedia-3.0. Its upstream is WowAce, not GitHub; ask before downloading it (DESIGN §11).
