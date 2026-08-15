# Phase 2: Locale-Independent Raid Recognition - Research

**Researched:** 2026-08-15
**Domain:** WotLK 3.3.5a raid-instance identity and exact localized encounter fallback
**Confidence:** HIGH for repository architecture and integration points; HIGH for the acquisition method and currently measured locale coverage; LOW for any non-English yell literal not yet extracted and verified at the mandatory checkpoint below

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

### Session identity and visible names
- Show and store the localized instance name supplied by the client for new raid sessions.
- Use canonical instance identity internally so clients with different locales treat the same supported raid as the same instance.
- Leave every historical session name unchanged; do not migrate or rewrite existing raid records.
- Logger output, exports, and other historical presentation continue to use the name already stored in each session.

### Map-ID priority and compatibility fallback
- A recognized map ID always determines admission and canonical identity. The localized instance name is informational and must not veto it.
- If the map ID is absent, zero, or unknown, accept only an exact canonical name already backed by an RMA raid dataset.
- When a recognized map ID conflicts with the displayed name, the map ID wins and the displayed name remains user-facing only.
- Unknown custom raids fail closed. Do not add generic sessions, user aliases, or automatic recognition outside the existing datasets.

### Unknown-instance behavior
- An unrecognized raid instance must not create or update a raid session and must not reuse the last recognized instance identity.
- Emit one concise localized warning for the relevant instance entry or zone change, not for every delayed/debounced recheck.
- Keep the normal warning non-technical. Put the received instance name and map ID in debug diagnostics only.
- If initially incomplete instance information becomes valid during the existing delayed checks, recognize it automatically without requiring another zone change or `/reload`.

### Localized boss-yell fallback
- Localize only the encounters already present in the English `BossYells` fallback. Adding fallback detection for more encounters is outside this phase.
- Match yell text exactly. Do not use substring, punctuation-insensitive, case-insensitive, pattern, or fuzzy matching.
- On non-English clients, accept both the exact English yell and the exact current-locale yell because private servers may send mixed-language creature text.
- Require the current canonical instance identity to match the encounter's expected raid before recording a yell-based boss kill, including text that is or may become ambiguous.
- Preserve the existing combat-log path as the primary signal; yell matching remains a narrow fallback for encounters whose completion signal is missing.

### Codex's Discretion
- Internal names and data shape used to carry canonical identity from instance recognition into Session and Roster owners.
- The smallest repository-consistent owner for localized exact yell mappings, provided locale catalogs remain translation owners and display strings never become admission gates.
- Exact localized warning wording and debug diagnostic templates.
- Test fixture organization, provided it covers Vanilla map IDs, a non-English instance name, all supported locale yell entries, exact matching, mixed English/localized input, and instance scoping.

### Deferred Ideas (OUT OF SCOPE)

- Configurable aliases for custom/private-server raids — new capability outside this corrective phase.
- Generic sessions for raids absent from RMA datasets — new product behavior outside the milestone.
- Adding yell fallbacks for encounters not already in the English table — separate detection expansion, not required for locale parity.
- Rewriting historical session zone names to canonical English values — deliberately rejected to avoid migration and presentation churn.
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| RAID-01 | RMA uses the canonical locale-independent instance resolver as the only operational admission gate for raid session and roster checks. | Remove both `L.RaidZones` gates and carry the resolver result from `Init.lua` into the Raid service as transient context. |
| RAID-02 | Supported Vanilla, Burning Crusade, and Wrath raid instances can start or update raid sessions independently of the client's localized instance name. | The existing map-ID table covers all three dataset generations; session creation keeps the display name while comparison uses the canonical key. |
| RAID-03 | Automated regression cases cover map-ID recognition for Vanilla raids and at least one non-English localized instance name. | Extend the existing Lua resolver and Init/session fixtures rather than introducing a test framework. |
| LOCL-01 | Boss encounters that depend on the monster-yell fallback remain recordable on each currently supported client locale, using localized exact text only where no locale-independent signal is available. | Represent the existing 15 English yell strings as metadata-backed exact fallbacks and add scalar translations for `ruRU`, `zhCN`, `esES`, and `frFR`. |
| LOCL-02 | Localization regression checks enforce complete fallback coverage without turning display-string tables into runtime raid-admission gates. | Extend scalar-catalog completeness tests and add a static/runtime assertion that Session and Roster do not reference `RaidZones`. |
</phase_requirements>

## Summary

The canonical resolver is already implemented and tested. `Modules/Dataset/LootSourcesData.lua:299` resolves a recognized map ID first, verifies that the mapped canonical key exists in the loaded raid datasets, and only then falls back to the normalized canonical dataset name. Its map table includes supported Vanilla, Burning Crusade, and Wrath raids. `Init.lua:832-900` already reads the eighth `GetInstanceInfo()` result, activates both instance-scoped dataset owners transactionally, and publishes `RaidInstanceRecognized(instanceName, instanceKey, instanceDiff)`.

The defect is downstream duplication. `Services/Raid/Session.lua:37-45` and `Services/Raid/Roster.lua:327-335` independently admit raids through `L.RaidZones[instanceName]`. That table contains English TBC/Wrath display names and no Vanilla list, so it rejects a successfully resolved localized or Vanilla raid. `Session.lua:137` also compares the persisted display name to the current localized display name, which can split one canonical raid when records cross locale boundaries. The fix should carry one transient context `{ displayName, instanceKey, difficulty }` from Init into the shared Raid service and use `instanceKey` for operational identity while leaving `raid.zone` unchanged for presentation.

Monster-yell fallback is a second bounded correction. `Init.lua:1115-1123` performs an exact English `L.BossYells[text]` lookup but checks only that some raid is current. The existing 15 strings cover 13 encounters in Naxxramas, Ulduar, Trial of the Crusader, Icecrown Citadel, and Ruby Sanctum. They need expected canonical instance metadata plus exact current-locale strings. English must remain accepted on non-English clients, and a wrong active instance must reject the same text.

**Primary recommendation:** implement two sequential plans: first make Init-resolved transient context the only Session/Roster admission and comparison input, including bounded retry and one-warning behavior; then add exact locale-aware, instance-scoped metadata to only the existing yell fallbacks.

## Standard Stack

### Core

| Component | Version / owner | Purpose | Why standard here |
|-----------|-----------------|---------|-------------------|
| WoW client API | WotLK 3.3.5a, build 12340 | `GetInstanceInfo`, zone and raid events, monster-yell event | Repository runtime target; map ID is the locale-independent client fact already consumed by Init. |
| Lua | 5.1.5 | Runtime implementation | Mandatory embedded language; all new syntax and helpers must remain Lua 5.1-compatible. |
| `LootSourcesData.ResolveInstanceKey` | Repository module | Map ID to canonical dataset key, with exact canonical-name fallback | Already authoritative and tested; no second resolver should be added. |
| `addon.State.raid` / Raid service transient state | Repository runtime state | Carry current canonical identity without persistence | Avoids SavedVariables schema and protocol changes while keeping display names stable. |
| Existing Python + Lua harness | `unittest` and `tests/lua/runtime_harness.lua` | Static contracts and behavior regressions | Existing coverage already loads the exact addon files with WotLK API stubs. |

### Supporting

| Component | Purpose | When to use |
|-----------|---------|-------------|
| `addon.L` scalar keys | Localized warning and exact current-locale yell literals | Player-facing text and locale-owned functional strings. |
| `addon.Diagnose` | Debug-only instance name and map-ID detail | Unknown-instance diagnostics; never use it as normal user-facing warning text. |
| Existing Raid timer mixin | Delayed settled-state checks | Preserve the existing bounded 0.3/0.8/1.5/2.5/3.5-second retry cadence. |
| `LootSourcesData.GetActiveInstanceKey` | Active canonical dataset identity | Scope boss-yell fallback and guard against stale identity after leaving/entering an unsupported raid. |

### No new dependencies

Do not add Ace, external localization libraries, encounter libraries, or a new test framework. This phase is a correction to existing coordination and static data.

## Current Architecture and Evidence

### Authoritative recognition path

1. `Init.lua:836` obtains `instanceName`, `instanceType`, `instanceDiff`, and `instanceMapId`.
2. `LootSourcesData.ResolveInstanceKey(instanceName, instanceMapId)` gives map ID priority and returns only a key backed by `RawSources`.
3. `Init.lua:843-869` activates LootSourcesData and IgnoredMobs as one transactional pair, restoring exact previous snapshots on a partial failure.
4. Only after activation, `Init.lua:892` publishes `RaidInstanceRecognized` with display name, canonical key, and difficulty.
5. The Session and Roster owners currently discard that fact and query `GetInstanceInfo()` plus `L.RaidZones` again.

The plan should retain steps 1-4 and remove step 5. Dataset activation success, not display-string membership, is the admission boundary.

### Canonical identity must remain transient

Persisting `instanceKey` into raid history would be a SavedVariables schema change and would flow into version-5 sync state. Neither is needed. Store only runtime context, for example:

```lua
-- Shape recommendation, not a required public API name.
raidState.activeInstance = {
	displayName = instanceName,
	instanceKey = instanceKey,
	difficulty = instanceDiff,
}
```

Set it only after canonical resolution and both dataset activations succeed. Clear it whenever the client is not in a recognized supported raid. Session creation continues to pass `displayName` as `zone`. Same-instance checks compare the previous runtime `instanceKey` with the new key; size/difficulty retain their current checks. If a current raid is first associated after reload/recovery and has no runtime key yet, bind the current recognized key rather than treating localized `raid.zone` as a different raid. Do not rewrite old `raid.zone` values.

### Delayed recognition must re-enter Init coordination

The existing Session retry callback currently calls `GetInstanceInfo()` and `L.RaidZones` directly. Replace that callback with a narrow Init-owned refresh callback (passed into the existing timer scheduler or exposed as an equally narrow coordinator method). Each retry must repeat the full resolver + transactional activation path, then update/clear the transient Raid context. It must not recursively schedule another retry batch.

This preserves timer ownership and cadence while allowing an initially missing/zero/unknown map ID to become valid during the same bounded checks. A captured first result is insufficient because it cannot observe the later map ID. Calling `Raid:Check` directly from a retry without activating the datasets is also insufficient.

### Roster should consume, not recognize

`UpdateRaidRoster()` may still ensure that the active recognized context has been checked before mutating roster state, but `Roster.lua` must not call `GetInstanceInfo`, `ResolveInstanceKey`, or `L.RaidZones`. It should call a Session/Raid method that consumes the context already committed by Init. If there is no current canonical context, it should not create/update a session and should continue its existing no-current-raid cleanup path.

### Unknown-instance warning boundary

Normal user warning belongs in `addon.L`, while received name/map ID belongs only in `addon.Diagnose`. Track the last warned unknown identity at the Init event boundary, not inside delayed checks. The minimal dedupe key is the received map ID plus display name; clear it after leaving raid or recognizing a supported raid so re-entry can warn again. Explicit entry/zone events may request a warning; delayed retries must not.

The current `RAID_INSTANCE_WELCOME` path calls `addon:warn(Diag.W.LogRaidUnmappedZone...)`, which exposes technical detail and does not include map ID. Replace it with:

- one concise localized scalar message via `addon:warn(L.<key>)`;
- one debug-only diagnostic containing `instanceName`, `instanceMapId`, and difficulty when debug is enabled;
- no warning from every `PLAYER_ENTERING_WORLD` delayed or Session timer callback.

### Exact boss-yell metadata

Keep locale catalogs as translation owners and preserve their scalar-only contract. Use one English definition table for the existing fallback set, where each definition carries:

```lua
{
	localeKey = "BossYellFourHorsemen",
	englishText = "...", -- owned by localization.en.lua
	boss = "Four Horsemen",
	instanceKey = "naxxramas",
}
```

The runtime resolver accepts `definition.englishText` or `L[definition.localeKey]` with direct equality only. It returns metadata only when `LootSourcesData.GetActiveInstanceKey() == definition.instanceKey`. Do not normalize case, punctuation, whitespace, or apostrophes. Do not add the commented Steelbreaker `Impossible...` fallback or any other encounter.

Expected canonical scope for the present definitions:

| Existing fallback | Expected `instanceKey` |
|-------------------|------------------------|
| Four Horsemen | `naxxramas` |
| Iron Council (2 texts), Hodir, Thorim, Freya, Mimiron, Algalon | `ulduar` |
| Faction Champions, Val'kyr Twins | `trial of the crusader` |
| Gunship Battle (2 texts), Blood Prince Council, Valithria Dreamwalker | `icecrown citadel` |
| Halion | `the ruby sanctum` |

The boss names are existing internal/persisted encounter labels and should not be translated as part of this phase.

## Localized Yell Evidence and Mandatory Acquisition Checkpoint

### Verified technical sources

Two maintained WotLK database projects provide a defensible path from an RMA fallback to client-derived localization data:

1. AzerothCore's versioned `creature_text.sql` identifies the creature/group/text row and its `BroadcastTextId` for the encounter lines. Its companion `creature_text_locale.sql` provides locale rows keyed by the same creature/group/text identity.
2. CMaNGOS `wotlk-db` explicitly targets client 3.3.5a build 12340. Its versioned `locales/BroadcastTextLocales.sql` stores locale text by broadcast-text ID. CMaNGOS issue #2331 documents `broadcast_text`/`broadcast_text_locale` as client-derived official text data and recommends using broadcast IDs instead of handwritten or copied web text.

This source chain is stronger than an addon translation or a web quote because it supplies a stable numeric join and provenance tied to the target client family. It still does not justify copying an uninspected literal: the executor must record the repository revision, key, locale, and exact extracted bytes.

### Stable lookup keys located

The following AzerothCore WotLK keys were located without copying their localized text into this document. The two Val'kyr creature rows share one broadcast ID.

| Fallback | Creature / group / text | BroadcastTextId |
|----------|-------------------------|-----------------|
| Four Horsemen completion relay | `15990 / 6 / 2` (same English text also occurs at `15990 / 18 / 0`) | `12986` |
| Iron Council - Brundir | `32857 / 5 / 0` | `34319` |
| Iron Council - Molgeim | `32927 / 5 / 0` | `34334` |
| Hodir | `32845 / 4 / 0` | `33484` |
| Thorim | `32865 / 9 / 0` | `33948` |
| Freya | `32906 / 3 / 0` | `33524` |
| Mimiron | `33350 / 13 / 0` | `34086` |
| Algalon | `32871 / 14 / 0` | `34013` |
| Faction Champions | `34996 / 12 / 0` | `35721` |
| Val'kyr Twins | `34496 / 8 / 0` and `34497 / 8 / 0` | `35741` |
| Gunship - Muradin | `36948 / 13 / 0` | `37705` |
| Gunship - Saurfang | `36939 / 12 / 0` | `37713` |
| Blood Prince Council | `37972 / 5 / 0` | `38005` |
| Valithria Dreamwalker | `36789 / 7 / 0` | `37852` |
| Halion | `39863 / 5 / 0` | `40065` |

A concrete discrepancy was found before implementation: RMA's current Algalon English fallback uses a period after “reply code”, while the keyed WotLK database row uses a hyphen. This proves that current RMA English text must not be treated as authority for locating or validating translations. The checkpoint must compare the exact source row and an observed event payload before deciding whether to correct an English literal.

### Measured direct-locale coverage

Inspection of AzerothCore's current versioned `creature_text_locale.sql` gives this coverage for the 15 fallback definitions:

| Locale | Direct creature-text rows located | Status |
|--------|-----------------------------------|--------|
| `zhCN` | 15 / 15 | Complete candidate set; still requires exact-byte extraction record and at least one in-game/event-payload validation. |
| `frFR` | 3 / 15 | Partial only: Algalon, Blood Prince Council, and Valithria keys were present. |
| `ruRU` | 0 / 15 | Not available from this direct table. |
| `esES` | 0 / 15 | Not available from this direct table. |

Absence from this table does not prove that the client lacks the translation. It means this source cannot support the missing RMA literals. CMaNGOS `BroadcastTextLocales.sql` is the next keyed source, not permission to translate the English sentence manually.

### Required checkpoint before Plan 02-02 implementation

Plan 02-02 must begin with an acquisition/verification checkpoint and must not edit runtime locale strings until it passes:

1. Pin the exact commit SHA of AzerothCore `azerothcore-wotlk` and CMaNGOS `wotlk-db` used for extraction.
2. For each table row above, extract `ruRU`, `zhCN`, `esES`, and `frFR` by `BroadcastTextId` from CMaNGOS `locales/BroadcastTextLocales.sql`; use the AzerothCore direct locale row as a second source when present.
3. Produce a temporary review matrix containing encounter, canonical instance, creature/group/text key, broadcast ID, locale, source SHA, source path, exact UTF-8 byte length, and a digest. The matrix is verification evidence, not addon runtime data and should not be packaged.
4. Reject any row where the two sources disagree, the locale is absent, the value is empty, or the value cannot be traced to the numeric key. Do not fill it with machine translation, Wowhead comments, modern-Classic text, or another addon's unsourced literal.
5. Resolve a rejected row only with another versioned client-derived 3.3.5 source or by capturing the exact `CHAT_MSG_MONSTER_YELL` payload on a 3.3.5a client of that locale. Record the client locale/build and byte digest.
6. Before accepting all 60 localized entries, test representative source strings containing apostrophes, ellipses, punctuation, and non-ASCII characters through the Lua harness without normalization. Then perform the Phase 4 in-game locale smoke check.

**Planning consequence:** the metadata/scoping code and its English behavior tests may be planned independently, but the task that adds all four non-English catalogs has a hard precondition: a complete 60/60 evidence matrix. If that matrix cannot be produced, Plan 02-02 is blocked rather than “completed” with guessed strings. This is a data-availability checkpoint, not a reason to weaken exact matching or silently fall back to English-only behavior.

## Recommended Plan Decomposition

### Plan 02-01: Canonical admission and stable runtime identity

1. Add failing behavior/static regressions for map-ID priority, localized Vanilla/Wrath admission with an empty `RaidZones`, display-name preservation, canonical same-instance comparison, Roster consumption, unknown fail-closed behavior, one warning, and delayed unknown-to-recognized recovery.
2. Update `Init.lua`, `Services/Raid/Session.lua`, and `Services/Raid/Roster.lua` so canonical context is carried from Init, cleared on unsupported/non-raid state, and used by both owners. Add one localized warning scalar to all five catalogs and one debug template to `DiagnoseLog.en.lua`.

Likely files:

- `Raid Management Addon/Init.lua`
- `Raid Management Addon/Services/Raid/Session.lua`
- `Raid Management Addon/Services/Raid/Roster.lua`
- `Raid Management Addon/Localization/DiagnoseLog.en.lua`
- all five `Raid Management Addon/Localization/localization.*.lua`
- `tests/lua/harness/30_raid_runtime.lua` and/or `40_inspect_foundations.lua`
- `tests/test_runtime_foundations_behavior.py`, `tests/test_inspect_dataset_behavior.py`
- `tests/test_localization_contract.py`

### Plan 02-02: Exact localized, instance-scoped yell fallback

1. Add completeness and behavior regressions first: every supported locale supplies every fallback scalar; English and current locale both match exactly; one-character/punctuation changes fail; wrong instance and no-current-raid fail; every existing definition has an expected canonical instance.
2. Convert only the existing 15 English fallback strings to metadata-backed definitions, add exact scalar translations in `ruRU`, `zhCN`, `esES`, and `frFR`, and update `CHAT_MSG_MONSTER_YELL` to require current raid plus matching active canonical instance.

Likely files:

- `Raid Management Addon/Localization/localization.en.lua`
- `Raid Management Addon/Localization/localization.ru.lua`
- `Raid Management Addon/Localization/localization.zhCN.lua`
- `Raid Management Addon/Localization/localization.es.lua`
- `Raid Management Addon/Localization/localization.fr.lua`
- `Raid Management Addon/Init.lua`
- `tests/lua/harness/40_inspect_foundations.lua`
- `tests/test_inspect_dataset_behavior.py`
- `tests/test_localization_contract.py`

No TOC change is required if the metadata resolver stays in `Init.lua` and definitions stay in the already loaded English catalog. If a small dedicated dataset module is chosen, it must load after all locale overrides and before runtime use; that extra file is not necessary for 15 fixed entries.

## Don't Hand-Roll

| Problem | Do not build | Use instead | Reason |
|---------|--------------|-------------|--------|
| Instance recognition | New name aliases, per-locale zone tables, or a second map table | `LootSourcesData.ResolveInstanceKey` | It already enforces map-ID priority and dataset-backed fail-closed behavior. |
| Canonical persistence | New SavedVariables field, migration, or sync payload member | Transient Raid runtime context | The requirement is operational identity, not historical-data conversion. |
| Yell matching | Fuzzy, substring, pattern, punctuation folding, or case folding | Direct string equality against English and current-locale exact strings | The locked decision prioritizes false-positive prevention. |
| Encounter expansion | New yells or generic boss detection | Existing combat-log path plus the current 15 fallback texts | New detection capability is explicitly deferred. |
| Locale infrastructure | AceLocale or copied `BossYells` tables in every locale file | Existing scalar `addon.L` keys | Preserves load order, current contracts, and minimal scope. |
| Retry scheduler | New `OnUpdate` poller or unbounded retry loop | Existing bounded Raid timer cadence | Event-driven and WotLK-compatible, with no permanent per-frame work. |

## Common Pitfalls

### 1. Passing a canonical key but still vetoing on display name

**Failure:** localized or Vanilla raids remain rejected because Session or Roster still checks `L.RaidZones` before consuming the key.

**Prevention:** add a static contract that proprietary runtime admission files contain no `RaidZones` reference and a behavior case with `addon.L.RaidZones = {}`.

### 2. Treating the localized display name as same-instance identity

**Failure:** an authority's English `raid.zone` and a French client's current display name cause a new raid session.

**Prevention:** compare the transient canonical key; use `displayName` only when creating/presenting the record. Do not compare or rewrite historical `zone` for admission.

### 3. Reusing stale canonical state

**Failure:** entering an unsupported raid leaves ICC active, allowing roster mutations or ICC yell fallbacks in the wrong zone.

**Prevention:** clear Raid context and both dataset owners together on non-raid/unrecognized results. Tests must transition recognized -> unknown and assert fail-closed behavior.

### 4. Retry observes new map ID but skips dataset activation

**Failure:** Session starts correctly but loot and ignored-mob datasets remain inactive or stale.

**Prevention:** delayed checks re-enter the same Init coordinator used by zone events; never call Session directly from raw `GetInstanceInfo()` data.

### 5. Warning spam from overlapping WoW events

**Failure:** `RAID_INSTANCE_WELCOME`, `ZONE_CHANGED_NEW_AREA`, `PLAYER_ENTERING_WORLD`, and delayed retries each warn for one entry.

**Prevention:** dedupe at Init using an unknown identity token, reset on recognized/non-raid transition, and pass an explicit no-warning mode to delayed checks.

### 6. Losing English fallback on a non-English client

**Failure:** locale override replaces the English exact text, so mixed-language private-server yells stop matching.

**Prevention:** retain English text in each definition and compare against both English and current-locale scalar values.

### 7. Ambiguous or short yell accepted outside its raid

**Failure:** a text such as a generic defeat line records the wrong boss in a different current raid.

**Prevention:** require active canonical instance equality before `Raid:AddBoss`; current raid existence alone is not sufficient.

### 8. Unverified translated punctuation

**Failure:** typographic apostrophes, ellipsis characters, spaces, or punctuation differ from the 3.3.5a client event payload, and exact matching silently fails.

**Prevention:** join the versioned AzerothCore/CMaNGOS data by the numeric keys in the acquisition section, preserve bytes exactly, and include in-game locale verification. Do not machine-translate functional strings and do not treat legacy addon catalogs as primary evidence.

## Test Strategy

### Focused resolver and admission cases

- map `409` with a French/non-English Molten Core display name resolves and creates a session while `L.RaidZones` is empty;
- at least one TBC map ID and map `631` prove the three expansion families use the same gate;
- a recognized map ID wins when the display name names another supported raid;
- nil/zero/unknown map ID accepts exact canonical dataset name only;
- unknown custom name remains rejected;
- the created `raid.zone` remains the received localized display name;
- changing only the localized display name while retaining the canonical key does not create a new session;
- Roster does not perform an independent localized-name admission.

### Unknown and retry cases

- recognized -> unsupported clears active canonical state and rejects Session/Roster updates;
- repeated delayed checks issue no repeated normal warning;
- overlapping entry events for the same unknown identity issue one warning;
- leave/re-enter permits one new warning;
- a fixture whose `GetInstanceInfo()` changes from missing/zero map ID to `631` during the bounded callbacks becomes recognized without a new zone event;
- normal warning contains no name/map ID; debug diagnostic contains both.

### Yell cases

- for each definition, metadata includes boss, locale key, English text, and expected instance;
- every supported non-English catalog declares every yell scalar key;
- exact localized text matches in its expected active instance;
- exact English text also matches with a non-English locale override;
- altered case, whitespace, punctuation, or substring does not match;
- exact text in the wrong active canonical instance does not call `AddBoss`;
- no current raid does not call `AddBoss`;
- `COMBAT_LOG_EVENT_UNFILTERED` delegation remains unchanged.

### Suggested focused commands

```powershell
python -m unittest tests.test_inspect_dataset_behavior tests.test_runtime_foundations_behavior tests.test_localization_contract
python -m unittest discover -s tests
py -3 .agents/skills/wow-addon-dev-wotlk-v335a/scripts/lint_lua51.py "Raid Management Addon"
py -3 .agents/skills/wow-addon-dev-wotlk-v335a/scripts/scan_xpcall.py "Raid Management Addon"
git diff --check
```

The Lua behavior cases require a Lua 5.1-compatible `lua` executable. The current project state records that this executable is unavailable in the present Codex environment, so Python tests that invoke the harness may remain environment-blocked; static localization contracts should still run.

## Open Questions

1. **Exact 3.3.5a yell bytes for every supported non-English locale**
   - Known: all 15 fallbacks now have numeric WotLK lookup keys. AzerothCore directly supplies a complete `zhCN` candidate set, a 3/15 `frFR` subset, and no direct `ruRU`/`esES` subset. CMaNGOS supplies a versioned 3.3.5a broadcast-locale dataset addressable by the located broadcast IDs.
   - Unclear: the complete CMaNGOS 60-row extraction and cross-source comparison have not been completed in this planning research, and an English punctuation discrepancy proves that similarity is not sufficient.
   - Recommendation: make the documented 60/60 evidence matrix a hard first checkpoint of Plan 02-02. Missing or conflicting rows block locale-data implementation and must not be guessed.

2. **Runtime-context field names**
   - Known: `addon.State.raid` is the established transient Raid state owner and is excluded from SavedVariables.
   - Recommendation: choose the smallest names consistent with existing Raid state; do not expose a new general identity abstraction or persist the context.

## Sources

### Primary (HIGH confidence)

- `Raid Management Addon/Modules/Dataset/LootSourcesData.lua:35-58,299-309` — supported map IDs, map-ID priority, dataset-backed fallback.
- `Raid Management Addon/Init.lua:832-900,928-992,1114-1124` — dataset activation, event coordination, delayed world-entry check, current yell handler.
- `Raid Management Addon/Services/Raid/Session.lua:37-45,76-143` — duplicated `RaidZones` gate, timer cadence, localized zone persistence and comparison.
- `Raid Management Addon/Services/Raid/Roster.lua:327-335,524-533` — duplicated roster gate and mutation entry point.
- `Raid Management Addon/Localization/localization.en.lua:962-1010` — English display-name table and 15 current yell strings.
- `Raid Management Addon/Raid Management Addon.toc` — English-first locale load order and module ordering.
- `tests/lua/harness/40_inspect_foundations.lua:1934-2027` — existing French ICC, localized Vanilla, canonical fallback, and shared dataset identity cases.
- `tests/test_localization_contract.py:580-633` — supported locales, scalar-key parity, and prohibition on per-locale display tables.
- `AGENTS.md` and `.agents/skills/wow-addon-dev-wotlk-v335a/SKILL.md` — binding WotLK 3.3.5a, Lua 5.1, ownership, localization, and no-`OnUpdate` constraints.

### Secondary (MEDIUM confidence)

- CurseForge Mizus RaidTracker project description — documents boss-kill tracking and historical locale support, useful only as provenance for locating WotLK-era functional strings: https://www.curseforge.com/wow/addons/mizusraidtracker
- Warcraft Wiki localization guidance — supports keeping locale strings in translation owners and avoiding localized names as identifiers: https://warcraft.wiki.gg/wiki/Localizing_an_addon

### Primary external technical sources (HIGH confidence for keyed acquisition)

- AzerothCore WotLK `creature_text.sql` — versioned creature text, sound, and BroadcastTextId joins: https://github.com/azerothcore/azerothcore-wotlk/blob/master/data/sql/base/db_world/creature_text.sql
- AzerothCore WotLK `creature_text_locale.sql` — directly measured locale coverage keyed by creature/group/text: https://github.com/azerothcore/azerothcore-wotlk/blob/master/data/sql/base/db_world/creature_text_locale.sql
- CMaNGOS WotLK database — explicitly targets client 3.3.5a build 12340: https://github.com/cmangos/wotlk-db
- CMaNGOS `BroadcastTextLocales.sql` — versioned locale rows keyed by broadcast ID: https://github.com/cmangos/wotlk-db/blob/master/locales/BroadcastTextLocales.sql
- CMaNGOS issue #2331 — technical provenance and rationale for client-derived broadcast text/locales over handwritten strings: https://github.com/cmangos/issues/issues/2331

## Metadata

**Confidence breakdown:**

- Standard stack: HIGH — fixed by repository and WotLK runtime policy.
- Canonical recognition architecture: HIGH — direct source and test evidence identifies the resolver and both duplicate gates.
- Retry/warning integration: HIGH — event and timer ownership are visible in current source; exact method names remain planner/executor discretion.
- Yell metadata/scoping: HIGH — current fallback set and missing scope are explicit.
- Non-English yell acquisition: HIGH — numeric joins, sources, measured direct coverage, and a fail-closed checkpoint are documented.
- Non-English yell literals: LOW until the 60/60 evidence matrix passes — no unverified literal is asserted in this research.

**Research date:** 2026-08-15
**Valid until:** stable for this repository revision; re-check if instance coordination, locale catalogs, or raid-session schema changes before execution.
