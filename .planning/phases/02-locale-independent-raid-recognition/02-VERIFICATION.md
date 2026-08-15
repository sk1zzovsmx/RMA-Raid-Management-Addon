---
phase: 02-locale-independent-raid-recognition
verified: 2026-08-15T10:05:24Z
status: passed
score: 12/12 must-haves verified
human_approved: true
human_approved_at: 2026-08-15T10:05:24Z
human_verification:
  - test: "Run the registered Phase 2 Lua cases with a Lua 5.1-compatible executable"
    expected: "Canonical admission, stale-context rejection, bounded retry recovery, and exact scoped yell cases all pass."
    why_human: "No lua or luajit executable is available in the current environment; static validators cannot execute the WoW-oriented behavior harness."
  - test: "Enter supported Vanilla, Burning Crusade, and Wrath raids on localized WotLK 3.3.5a clients"
    expected: "Map ID admits the raid regardless of display language, the localized name remains visible/stored, and changing only locale does not replace the session."
    why_human: "Only a live client/server can confirm its GetInstanceInfo payloads and persisted UI presentation."
  - test: "Enter an initially unresolved raid and let the existing delayed checks settle"
    expected: "One localized warning appears, no retry spam occurs, stale context is cleared, and a later valid map ID is recognized automatically."
    why_human: "WoW event ordering and private-server map-ID timing require live observation."
  - test: "Trigger each required English and localized monster yell in its expected and a wrong raid"
    expected: "Exact English/current-locale text records the boss only in the expected canonical raid; altered text and wrong/no raid context do nothing; combat-log detection remains operational."
    why_human: "Static source provenance cannot prove the byte payload emitted by a particular private server."
---

# Phase 2: Locale-Independent Raid Recognition Verification Report

**Phase Goal:** Supported raids and fallback encounters are recognized independently of English display strings on every currently supported client locale.
**Verified:** 2026-08-15T10:05:24Z
**Status:** passed
**Re-verification:** No - initial verification

## Goal Achievement

### Observable Truths

The 15 plan-level truths are consolidated below where they describe the same runtime contract.

| # | Truth | Status | Evidence |
|---|---|---|---|
| 1 | One canonical resolver owns raid recognition and map ID has priority over display text. | VERIFIED | `Init.lua:834-895` is the only runtime caller of `ResolveInstanceKey`; `LootSourcesData.lua:299-309` resolves a supported map ID before the dataset-name fallback. Repository search found no second runtime caller. |
| 2 | Session and Roster do not independently admit through `RaidZones`, `GetInstanceInfo`, or another resolver. | VERIFIED | `Session.lua:121-157` consumes `GetRecognizedInstanceContext`; `Roster.lua:327-335` consumes the same Raid context. Both files contain none of the prohibited recognition symbols; focused static ownership tests pass. |
| 3 | Vanilla, TBC, and Wrath share the canonical map-ID path, including localized/conflicting names. | VERIFIED | Resolver map table includes the three generations (`LootSourcesData.lua:37-60`). Harness case `localized_raid_identity_uses_instance_map_id` covers 409, 532, 631, a French name, map-ID/name conflict, canonical fallback, and unknown fail-closed behavior. |
| 4 | Canonical identity is transient while localized session names and historical records remain unchanged. | VERIFIED | `Session.lua:26-28,85-118` keeps context/binding in local runtime state; creation passes `context.zone` while same-instance comparison uses `context.instanceKey` (`Session.lua:167-201`). No persistence, TOC, or wire files changed. |
| 5 | Unknown/non-raid transitions clear active datasets and Raid context rather than reusing stale identity. | VERIFIED | `Init.lua:843-893` commits only after both dataset activations and clears both owners plus Raid context otherwise; Roster rejects mutation without context at `Roster.lua:327-335,526-536`. |
| 6 | Unknown raid warning is localized, non-technical, and deduplicated while technical fields remain debug-only. | VERIFIED | `Init.lua:953-987` keys transient dedupe by received map ID/name, uses `L.MsgRaidInstanceUnsupported`, and sends name/map/difficulty only through `Diag.D.LogRaidUnknownInstance`. All five catalogs pass the warning contract. |
| 7 | Existing bounded retries re-enter Init coordination and can recover later-valid instance data without polling. | VERIFIED | `Session.lua:24-25,129-143` retains the five bounded delays; callbacks invoke the Init-owned refresh at `Init.lua:995-996`. Static coordinator/no-independent-recognition checks pass; no added `OnUpdate` was found. |
| 8 | All 15 fallback definitions have exact ruRU, zhCN, esES, and frFR source evidence. | VERIFIED | Fresh evidence gate reports `accepted=60 unique=60 missing=0 conflicts=0 invalid=0`; every row carries numeric key, pinned source revision/path, UTF-8 length, digest, and resolution status in `02-YELL-EVIDENCE.md`. |
| 9 | Runtime catalogs reproduce the accepted 60 payloads byte-for-byte and remain scalar-only. | VERIFIED | `test_yell_catalogs_match_evidence_bytes`, definition parity, locale load-order, scalar parity, and scalar-only ownership tests all pass. Locale files contain no `RaidZones`, `BossYells`, or `BossYellDefinitions` tables. |
| 10 | English and current-locale exact texts remain separately available with one canonical raid scope per definition. | VERIFIED | `localization.en.lua:989-1021` owns 15 English scalars and definitions with `localeKey`, `englishText`, `boss`, and `instanceKey`; four locale files override only the scalar keys. |
| 11 | Monster-yell handling accepts only exact English/current-locale text in the expected active raid and rejects wrong/no context. | VERIFIED | `Init.lua:1178-1198` requires a current raid, exact active instance equality, and direct string equality only. The table-driven harness covers all 15 definitions across four non-English locales plus case/space/punctuation/substring and wrong/no-raid negatives. Live execution remains listed under human verification because Lua 5.1 is unavailable here. |
| 12 | Combat-log boss detection remains unchanged and primary. | VERIFIED | `Init.lua:1201-1206` remains direct delegation to `raidService:COMBAT_LOG_EVENT_UNFILTERED(...)`; the focused static contract passes and the Lua harness preserves argument-count/value assertions. |

**Score:** 12/12 consolidated must-haves verified in source and available static checks.

### Required Artifacts

| Artifact | Expected | Status | Details |
|---|---|---|---|
| `Raid Management Addon/Init.lua` | Sole resolver coordination, retry boundary, exact scoped yell handler | VERIFIED | Substantive and wired to dataset owners, Raid service, localization, and events. |
| `Raid Management Addon/Services/Raid/Session.lua` | Transient canonical context and bounded checks | VERIFIED | Context is local-only; canonical comparison and localized creation are wired into `Check`. |
| `Raid Management Addon/Services/Raid/Roster.lua` | Shared-context roster admission | VERIFIED | Rejects before mutation when recognized context is absent. |
| `Raid Management Addon/Modules/Dataset/LootSourcesData.lua` | Canonical map-ID resolver and active instance identity | VERIFIED | Existing resolver remains authoritative and dataset-backed. |
| Five `Localization/localization.*.lua` catalogs | English definitions plus exact supported-locale scalar overrides | VERIFIED | Definition count 15; 60 non-English payloads pass digest parity. |
| `Localization/DiagnoseLog.en.lua` | Debug-only unknown-instance details | VERIFIED | Wired only to debug output at the Init boundary. |
| `02-YELL-EVIDENCE.md` | Auditable 60/60 locale matrix | VERIFIED | Fresh parser reports no missing, conflict, or invalid row. |
| Focused Python/Lua tests | Admission, retry, locale, exact-match, and scope regressions | VERIFIED | Static tests execute; behavior cases are substantive and registered, but need a Lua 5.1 runner. |

### Key Link Verification

| From | To | Via | Status | Details |
|---|---|---|---|---|
| `Init.lua` | `LootSourcesData.lua` | `ResolveInstanceKey(instanceName, instanceMapId)` | WIRED | Sole runtime recognition call. |
| `Init.lua` | Raid Session owner | `CommitRecognizedInstanceContext` / `ClearRecognizedInstanceContext` | WIRED | Commit follows successful dual activation; all failure/non-raid paths clear. |
| `Session.lua` | `Roster.lua` | Shared Raid namespace/context methods | WIRED | Roster calls `GetRecognizedInstanceContext` and `Check`, with no parallel resolver. |
| `Session.lua` | `Init.lua` | `ScheduleInstanceChecks(refreshRaidInstanceFromRetry)` | WIRED | Delayed callbacks re-read and reactivate through Init without recursive scheduling. |
| `02-YELL-EVIDENCE.md` | Locale catalogs | UTF-8 length/SHA-256 test contract | WIRED | All 60 runtime values equal their accepted evidence rows. |
| `Init.lua` | `BossYellDefinitions` and active dataset key | Direct equality plus canonical instance gate | WIRED | Current raid and expected active key are required before `AddBoss`. |

### Requirements Coverage

| Requirement | Source Plans | Status | Evidence |
|---|---|---|---|
| RAID-01 | 02-01 | SATISFIED | One Init-owned resolver call; Session/Roster consume one transient context and have no display-name gate. |
| RAID-02 | 02-01, 02-02 | SATISFIED | Map table spans all expansions; localized name is presentation-only; stale/unknown state clears and delayed recognition recovers. |
| RAID-03 | 02-01, 02-02 | SATISFIED | Registered cases cover Vanilla 409, TBC 532, Wrath 631, non-English names, conflict priority, warning/retry behavior. |
| LOCL-01 | 02-03, 02-04, 02-05 | SATISFIED | 60/60 evidence-backed scalars and 15 exact English/current-locale, instance-scoped definitions/handler. |
| LOCL-02 | 02-01, 02-02, 02-04, 02-05 | SATISFIED | Digest/completeness tests pass; locale tables are scalar-only; Session/Roster have no `RaidZones` dependency. |

No Phase 2 requirement is orphaned.

### Validation Evidence

- Focused Phase 2 static contract selection: 12 passed.
- Full test discovery: 505 discovered, 111 passed, 393 blocked solely by the missing Lua runtime, 1 skipped. The blocked cases are an environment limitation, not evidence of product failure or success.
- TOC validator: 0 errors, 0 warnings.
- Lua 5.1 syntax: 137 addon files and 10 Lua harness files clean.
- Variadic `xpcall` scan: 137 addon files clean.
- Evidence gate: `accepted=60 unique=60 missing=0 conflicts=0 invalid=0`.
- `git diff --check`: clean.

### Scope and Anti-Pattern Review

- Phase diff changes no `Database/*`, `Libs/*`, or TOC file and adds no SavedVariables field, addon-message prefix, protocol version, or wire payload.
- No new dependency, locale library, encounter definition, custom-raid alias, persisted canonical identity, polling `OnUpdate`, fuzzy matching, normalization helper, placeholder, TODO, or blocker anti-pattern was found in the changed runtime surface.
- `L.RaidZones` remains as legacy English presentation data in `localization.en.lua`, but it has no operational Session/Roster admission consumer.
- GSD artifact/key-link helper could not parse the nested `must_haves` frontmatter and reported that parser limitation; artifacts and links were therefore verified directly against source and tests above.

### Human Verification Approved

The user approved the four runtime checks on 2026-08-15: Lua 5.1 behavior execution, localized Vanilla/TBC/Wrath admission, unknown-to-recognized retry behavior, and exact instance-scoped English/localized monster-yell handling.

#### 1. Lua 5.1 behavior harness

**Test:** Put a Lua 5.1-compatible `lua` executable on PATH and run the full discovery suite.
**Expected:** The registered canonical admission, retry, stale-context, and exact-yell cases pass without changing the static results.
**Why human/environment:** This Codex environment has neither `lua` nor `luajit`.

#### 2. Localized raid entry and persistence

**Test:** On supported localized 3.3.5a clients, enter representative Vanilla, TBC, and Wrath raids, then reload or switch client locale where practical.
**Expected:** Admission follows map ID; the client-localized name is displayed/stored; an existing session is not replaced solely because its visible name differs.
**Why human:** Live API payloads, UI presentation, and reload behavior are not observable statically.

#### 3. Unknown-to-recognized transition

**Test:** Exercise a server entry where map ID is initially missing/zero and later settles, including overlapping zone/world events.
**Expected:** One localized warning, no retry spam, no stale Session/Roster mutation, and automatic recognition within the bounded retry window.
**Why human:** Event timing and server behavior are external to the harness environment.

#### 4. Localized monster-yell smoke test

**Test:** Capture/trigger each required locale payload and English fallback in the correct raid, then repeat representative texts in a wrong raid and with a one-byte variation.
**Expected:** Only exact English/current-locale payloads in the expected active raid record the boss; combat-log detection continues normally.
**Why human:** Private-server emitted bytes may differ from the pinned client-derived sources despite static digest parity.

### Gaps Summary

No implementation gap was demonstrated by source wiring, complete evidence, static contracts, compatibility validators, or the approved runtime verification. Phase 2 satisfies RAID-01 through RAID-03 and LOCL-01 through LOCL-02.

---

_Verified: 2026-08-15T10:05:24Z_
_Verifier: Codex (gsd-verifier)_
