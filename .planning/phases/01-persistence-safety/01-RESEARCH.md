# Phase 1: Persistence Safety - Research

**Researched:** 2026-08-15
**Domain:** WotLK 3.3.5a SavedVariables validation, quarantine, and bootstrap behavior
**Confidence:** HIGH

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

#### Quarantine notification
- Show one non-blocking chat warning per login or reload; do not show a popup.
- Use warning severity because data is preserved but raid history is unavailable.
- The global quarantine warning is not repeated for every rejected operation. Individual operations still return their stable rejection reason.
- Keep the user-facing warning short: state that raid history is quarantined, include a stable reason category, and instruct the user to restore or correct SavedVariables and then `/reload`.

#### Degraded feature behavior
- Configuration, reserves, warnings, spammer, general UI, and other features that do not depend on raid history remain operational.
- Raid-history views may open, but they are read-only and must show an explicit unavailable/quarantine state rather than silently presenting a normal empty history.
- New raid sessions and every raid-history mutation are rejected while quarantined. Do not create a temporary, shadow, or replacement archive.
- Suspend raid-history replication and import while quarantined. Reserve synchronization and loot-distribution synchronization continue normally.

#### Diagnostic categories and privacy
- Expose three stable user-facing categories: unsupported/future archive format, corrupt archive structure, and invalid SavedVariable type.
- Show a concise localized message to the user. Keep validator detail in debug logging only.
- Diagnostics may include archive version/format and a stable error code.
- Diagnostics must never include archive contents, player names, loot records, or other persisted user data.
- Provide the quarantine warning in every currently supported locale.

#### Recovery behavior
- Recovery requires an external SavedVariables restore or deliberate correction followed by `/reload`; do not add an in-game repair command or destructive reset button.
- When the archive validates after reload, normal operation resumes automatically with no persisted quarantine flag and no extra confirmation.
- If the archive remains invalid, re-enter quarantine and emit the same single warning for the new session.
- Recovery guidance tells the user to back up the SavedVariables file first, restore a compatible value or deliberately remove only `RMA_Raids`, and then `/reload`.
- Never recommend deleting all RMA SavedVariables.

### Codex's Discretion
- Exact internal names for the transient quarantine state and the three stable diagnostic codes.
- Exact localized wording, provided it preserves the decisions above and existing localization conventions.
- The smallest existing UI pattern used to render the read-only quarantine state in raid-history views.
- Test fixture organization and assertion wording.

### Deferred Ideas (OUT OF SCOPE)
- Automatic repair, migration, peer recovery, and destructive reset tooling remain explicitly out of scope.
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| PERS-01 | Preserve unknown/future `RMA_Raids` through initialization | Separate nil-only creation from validation; no getter may normalize an existing invalid value. |
| PERS-02 | Explicit localized quarantine with unrelated features available | Consume normalization result in `ADDON_LOADED`, retain transient error state, and reuse the store guard. |
| PERS-03 | Regression coverage for valid, malformed, non-table, and future inputs | Extend the existing Lua raid-runtime harness and Python case registration. |
</phase_requirements>

## Summary

The existing architecture already contains most of the quarantine contract: `SavedVariables.NormalizeAfterLoad()` validates format-1 archives, `raidArchiveError` records the rejection, and `DBRaidStore` checks that error before exposing or mutating raid history. The destructive behavior is concentrated in `ensureRaidArchive()`, which is called during module load, `EnsureAll()`, `GetRaids()`, and normalization. Any fix limited only to `NormalizeAfterLoad()` is therefore incomplete.

The safe plan is to split fresh initialization from access. Only a nil `RMA_Raids` value may create the canonical archive. Every existing non-nil value must reach classification and validation unchanged. Bootstrap should treat a validation rejection as a degraded but successful addon initialization, record a transient category, emit one localized warning, and leave the existing store guard responsible for fail-closed history operations.

**Primary recommendation:** make archive creation nil-only, classify before structural validation, consume the normalization result in `ADDON_LOADED`, and extend the existing quarantine tests before changing behavior.

## Standard Stack

No new dependencies are required or permitted.

| Component | Existing owner | Purpose |
|-----------|----------------|---------|
| Lua 5.1 / WoW SavedVariables | Client + TOC | Loads and persists the six existing `RMA_*` globals. |
| `Database/SavedVariables.lua` | Database | Sole direct owner of SavedVariables initialization, validation state, and save preparation. |
| `Database/DBRaidValidator.lua` | Database | Canonical format-1 archive structural validation. |
| `Database/DBRaidStore.lua` | Database | Fail-closed raid-history read and mutation boundary. |
| `Init.lua` | Bootstrap | Converts normalization result into session state and one-time user notification. |
| Existing localization catalogs | Localization | User-facing warning text for enUS, ruRU, zhCN, esES, and frFR. |
| Python unittest + Lua harness | `tests/` | Runtime contract and static localization coverage. |

## Architecture Patterns

### 1. Nil-only creation, validation for every existing value

- Fresh install: `_G.RMA_Raids == nil` creates the canonical format-1 archive.
- Invalid type: preserve the original value, classify as invalid type, and quarantine.
- Table with unsupported `formatVersion`: preserve it, classify as unsupported/future format, and quarantine.
- Table with current format: run `ValidateArchive`; preserve and quarantine on structural rejection.

This keeps initialization, validation, and migration separate as required by project policy.

### 2. Transient quarantine state

Continue to derive quarantine from the current in-memory archive on every load. Do not persist a separate flag. `raidArchiveError` is already the store-level guard; a small transient category/state exposed through the existing owner is sufficient for bootstrap and views.

### 3. Degraded bootstrap is not a thrown bootstrap failure

The harness already distinguishes a thrown initialization failure from successful initialization. Quarantine should not throw: unrelated features must complete initialization and `State.initialized` should become true. The normalization return must still be inspected so the warning and degraded state are committed deliberately.

### 4. Existing fail-closed store boundary

`DBRaidStore` checks `GetRaidArchiveError()` before accessing `SavedVariables.GetRaids()`. Preserve this ordering. Do not distribute raw `_G.RMA_Raids` checks across controllers, services, or widgets.

## Don't Hand-Roll

| Problem | Do not build | Use instead |
|---------|--------------|-------------|
| Archive repair | Recursive best-effort normalization of unknown data | Preserve and quarantine. |
| Recovery UI | Reset popup, slash repair, or peer overwrite | External backup/restore plus `/reload`. |
| New persistence state | A seventh SavedVariable or persisted quarantine flag | Existing `RMA_Raids` plus transient runtime state. |
| Parallel archive | Temporary or shadow raid history | Reject history mutation while quarantined. |
| New validation framework | Duplicate schema/type checks in bootstrap | Existing raid validator and stable pre-validation categories. |
| New test framework | Separate Lua runner | Existing `tests/lua/runtime_harness.lua` and Python wrappers. |

## Common Pitfalls

### Getter-triggered destruction
**Risk:** changing `NormalizeAfterLoad()` while leaving `GetRaids()` or module-load `EnsureAll()` able to replace invalid data.
**Prevention:** audit every call to the archive initializer; test identity before and after initialization, getter access, and save preparation.

### Treating nil and invalid type identically
**Risk:** a fresh install and a corrupt string/number both become a new archive.
**Prevention:** only nil is fresh; every other invalid type is preserved and quarantined.

### Warning spam
**Risk:** each rejected store operation prints the global quarantine warning.
**Prevention:** emit once from successful bootstrap; operations return stable reasons without repeating the global message.

### Silent empty history
**Risk:** fail-closed reads look identical to a legitimate empty archive.
**Prevention:** expose transient quarantine state to existing history views using the smallest established unavailable-state pattern.

### Accidental save mutation
**Risk:** `PLAYER_LOGOUT` or preparation normalizes/replaces the invalid archive.
**Prevention:** `PrepareForSave()` must reject without mutation and tests must compare reference identity plus deep value.

### Localization contract breakage
**Risk:** adding only an English scalar key fails locale parity or leaves runtime fallback text.
**Prevention:** add matching scalar assignments in all five catalogs and run the focused localization contract tests.

### Over-broad feature disablement
**Risk:** a raid-history error prevents Reserves, Distribution, configuration, or general UI initialization.
**Prevention:** quarantine is a successful degraded bootstrap; only raid-history owners and consumers consult the archive error.

## Planning Guidance

Use two small plans rather than one cross-cutting plan:

1. **Archive safety and regression tests:** change the SavedVariables creation/validation contract and extend archive harness cases. This establishes PERS-01 and the data-safety portion of PERS-03.
2. **Degraded bootstrap, localization, and history presentation:** consume the result, emit the once-per-session warning, expose the unavailable state, suspend history sync/import, and add focused integration/localization tests. This completes PERS-02 and PERS-03.

The second plan should depend on the first because bootstrap behavior relies on stable error categories returned by the SavedVariables owner.

## Focused Verification

The environment currently lacks a `lua` executable, so Lua-backed cases may be blocked locally. Plans must still specify the intended focused and full commands and distinguish an unavailable runner from a product failure.

| Scope | Command |
|-------|---------|
| Archive runtime cases | `python -m unittest tests.test_raid_replication_behavior.RaidReplicationBehaviorTests -v` |
| Localization contract | `python -m unittest tests.test_localization_contract -v` |
| Full Python/Lua suite | `python -m unittest discover -s tests -p "test_*.py"` |
| TOC | `python .agents/skills/wow-addon-dev-wotlk-v335a/scripts/validate_toc.py "Raid Management Addon/Raid Management Addon.toc"` |
| Lua 5.1 | `python .agents/skills/wow-addon-dev-wotlk-v335a/scripts/lint_lua51.py "Raid Management Addon"` |
| `xpcall` | `python .agents/skills/wow-addon-dev-wotlk-v335a/scripts/scan_xpcall.py "Raid Management Addon"` |

## Open Questions

None requiring user input. Exact stable code names, localized wording, and the minimal history-view unavailable pattern remain within Codex discretion and can be resolved by the planner from existing conventions.

## Sources

### Primary (HIGH confidence)
- `.planning/phases/01-persistence-safety/01-CONTEXT.md` - locked behavior and recovery decisions.
- `Raid Management Addon/Database/SavedVariables.lua` - current destructive initializer, normalization result, and save guard.
- `Raid Management Addon/Database/DBRaidStore.lua` - existing quarantine guard.
- `Raid Management Addon/Init.lua` - bootstrap and logout integration.
- `tests/lua/harness/30_raid_runtime.lua` - existing bootstrap and quarantine coverage.
- `tests/test_raid_replication_behavior.py` - Python registration of archive cases.
- `tests/test_localization_contract.py` - locale parity and runtime-string contracts.
- `.agents/skills/wow-addon-dev-wotlk-v335a/SKILL.md` - WotLK 3.3.5a and Lua 5.1 constraints.

## Metadata

**Confidence breakdown:**
- Existing stack: HIGH - directly inspected local code and tests.
- Architecture: HIGH - ownership and call paths are explicit in current source.
- Pitfalls: HIGH - derived from the demonstrated defect and current callers.
- Runtime verification: MEDIUM - harness coverage exists, but the current environment lacks the Lua runner.

**Research date:** 2026-08-15
**Valid until:** Stable for this milestone unless the SavedVariables or bootstrap contracts change first.
