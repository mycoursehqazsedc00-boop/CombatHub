# CombatHub

Shared combat event dispatcher, GUID/spell cache, and adapter coordinator for Vanilla WoW 1.12 / Turtle WoW addons.

## Client DLL Mods

| Mod | Role in CombatHub | Status |
|---|---|---|
| **Nampower** (`GetNampowerVersion`) | Primary structured combat events (`SPELL_DAMAGE_EVENT_*`, `AUTO_ATTACK_*`, `SPELL_HEAL_*`, `UNIT_PET_GUID`, etc.) and spell/GUID resolution | Optional |
| **SuperWoW** (`SUPERWOW_VERSION`) | `UNIT_CASTEVENT`, `SpellInfo`, and GUID fallback via `UnitExists` | Optional |
| **ClassicAPI** (`CLASSIC_API_VERSION`) | `COMBAT_LOG_EVENT_UNFILTERED` support | Optional |
| **WeirdUtils (`dpslog`)** (`GetWeirdUtilsVersion("dpslog")`) | `COMBAT_LOG_EVENT_UNFILTERED` support | Optional |

## Supported Addons

`CombatHub` coordinates combat event listening via non-invasive external adapters so upstream addon code remains untouched and easy to merge:

| Addon | Adapter File | Subscribed Events | Filter Policy | Purpose |
|---|---|---|---|---|
| **KLHThreatMeter** | `Code\KTM_CombatHub.lua` | `COMBAT_LOG_EVENT_UNFILTERED` or Nampower `*_SELF` + `UNIT_CASTEVENT` | `"self"` | Feeds self threat events without duplicate listeners |
| **GreedMeter** | `Parser\Adapter_CombatHub.lua` | Nampower combat, heal, dispel, aura/CC, shield, environmental, `UNIT_DIED`, roster events | `nil` (raid-wide) | Shares single Nampower event stream across the raid |
| **EavesDrop** | `EavesDrop_CombatHub.lua` | `COMBAT_LOG_EVENT_UNFILTERED` or Nampower `*_SELF`/`*_OTHER`, `UNIT_DIED`, pet/world events | `"self_or_pet"` for `*_OTHER`; `nil` for `*_SELF` | Drops irrelevant raid-wide `*_OTHER` traffic before addon parsing |
| **vampify** | `capture\combathub.lua` | `SPELL_DAMAGE_EVENT_SELF`, `AUTO_ATTACK_SELF`, `SPELL_GO_SELF` + dynamic incoming events | `"self"` | Routes damage and optional incoming watch/perhit through one hub |

> **Note:** `BigWigs` and `ChronicleCompanion` are intentionally left untouched and run independently without interference.

## Features

- **Single Reference-Counted Listener:** `CombatHubFrame` only registers a WoW/DLL event when at least one active subscriber requests it.
- **Filtered Dispatch:** Drops non-self/non-pet events (`*_OTHER`) at the hub before invoking consumer handlers (`EavesDrop`, `KLHThreatMeter`, `vampify`).
- **Shared GUID & Spell Caches:** Bounded caches (`800` GUIDs, `600` spells) with `CombatHub:ResolveUnitName(guid)` and `CombatHub:ResolveSpell(spellId)` to avoid redundant C-API lookups.
- **Zero-Touch Fallback:** If `CombatHub` is disabled or removed, all supported addons automatically run their original event listeners unchanged.
- **Slash Commands:**
  - `/chub` or `/combathub` — Show active mods, hub event count, dispatched/filtered counts, cache sizes, and connected subscribers.
  - `/chub trace` — Toggle debug trace logging.
  - `/chub clear` — Clear GUID and spell caches and refresh self/pet GUIDs.
