# Phase 2: Locale-Independent Raid Recognition - Context

**Gathered:** 2026-08-15
**Status:** Ready for planning

<domain>
## Phase Boundary

Make the existing canonical instance resolver the only operational admission source for supported Vanilla, Burning Crusade, and Wrath raid session creation and roster updates. Preserve localized display names while comparing raid identity independently of client language. Complete the existing monster-yell fallback for every supported locale without making localized display-string tables into raid-admission gates.

This phase does not add custom raids, configurable aliases, generic raid sessions, new boss-detection capabilities, historical-data migrations, wire-format changes, or broad localization restructuring.

</domain>

<decisions>
## Implementation Decisions

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

</decisions>

<specifics>
## Specific Ideas

- A French client in Icecrown Citadel and an English client in the same raid may display different zone names but must share the canonical `icecrown citadel` identity.
- A localized Molten Core name with map ID `409` must be admitted even though Vanilla raids are absent from the old English `L.RaidZones` table.
- Map-ID/name disagreement is not an error when the map ID is recognized; this avoids localized or private-server display text becoming a hidden second gate.
- User-facing history remains locally readable and stable because canonical identity is operational metadata, not a reason to rewrite stored display names.

</specifics>

<code_context>
## Existing Code Insights

### Reusable Assets
- `Modules/Dataset/LootSourcesData.lua`: already owns `ResolveInstanceKey(instanceName, instanceMapId)`, maps supported Vanilla/TBC/Wrath map IDs to canonical dataset keys, and retains a canonical-name fallback when no useful map ID is available.
- `Init.lua`: `refreshActiveInstanceDatasets()` already reads the eighth `GetInstanceInfo()` return, resolves the canonical instance key, activates loot/ignored-mob datasets, and schedules raid checks only after recognition.
- `Modules/Dataset/LootSources/{Vanilla,BurningCrusade,Wrath}.lua`: existing dataset keys define the supported raid universe; unknown custom instances remain outside scope.
- `tests/lua/harness/40_inspect_foundations.lua`: already proves French ICC map-ID resolution, localized Molten Core map-ID resolution, canonical English fallback, and fail-closed unknown instances.
- `Services/Raid/Session.lua` and `Services/Raid/Roster.lua`: existing check and delayed-check paths can consume the recognized context once their independent name-table gates are removed.

### Established Patterns
- `Init.lua` is the authoritative instance-entry coordinator and emits `RaidInstanceRecognized` only after both dataset owners activate successfully.
- `Services/Raid/Session.lua:runLiveRaidInstanceCheck()` and `Services/Raid/Roster.lua:checkCurrentRaidInstance()` currently repeat `L.RaidZones[instanceName]` admission, which rejects localized names and Vanilla raids despite successful canonical resolution.
- `Services/Raid/Session.lua` currently stores the received `instanceName` as the session zone. That visible behavior should remain while canonical identity governs admission/comparison.
- English localization loads first; supported locale catalogs currently contain scalar translations only, and localization tests explicitly reject copying `L.RaidZones` or `L.BossYells` wholesale into locale files.
- `Init.lua:CHAT_MSG_MONSTER_YELL` currently performs an exact lookup in `L.BossYells` and checks only for a current raid; it does not scope the yell to a canonical instance.

### Integration Points
- Carry the result of `LootSourcesData.ResolveInstanceKey()` from `Init.lua` into the Session and Roster operational checks rather than asking either service to recognize localized display strings independently.
- Preserve the localized `instanceName` for new session presentation while using the resolved key for same-instance decisions.
- Keep the canonical-name fallback inside `LootSourcesData`; do not recreate `RaidZones` admission tables in services or locale files.
- Replace repeated unknown-zone warnings from delayed checks with one localized entry/change warning and debug-only name/map-ID detail at the `Init.lua` coordination boundary.
- Extend the yell fallback with exact supported-locale text and expected canonical instance metadata, then gate the existing `Raid:AddBoss` call on the active recognized instance.
- Extend existing Lua harnesses and localization/static contracts rather than adding a new test framework.

</code_context>

<deferred>
## Deferred Ideas

- Configurable aliases for custom/private-server raids — new capability outside this corrective phase.
- Generic sessions for raids absent from RMA datasets — new product behavior outside the milestone.
- Adding yell fallbacks for encounters not already in the English table — separate detection expansion, not required for locale parity.
- Rewriting historical session zone names to canonical English values — deliberately rejected to avoid migration and presentation churn.

</deferred>

---

*Phase: 02-locale-independent-raid-recognition*
*Context gathered: 2026-08-15*
