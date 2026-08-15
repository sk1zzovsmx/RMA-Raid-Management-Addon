---
phase: 01-persistence-safety
plan: 02
subsystem: bootstrap
tags: [savedvariables, quarantine, localization, lua-5.1, wotlk]

requires:
  - phase: 01-persistence-safety-01
    provides: Stable non-destructive archive classification and transient validator metadata
provides:
  - Successful degraded bootstrap for quarantined raid archives
  - One localized data-safe recovery warning per login or reload
  - Session-only quarantine category and format metadata with automatic recovery
  - History-unavailable and raid-sync-suspended labels for downstream consumers
affects: [01-03-history-quarantine, logger-history-ui, raid-history-sync]

tech-stack:
  added: []
  patterns: [bootstrap-derived quarantine state, localized stable-category diagnostics, debug-only validator detail]

key-files:
  created: []
  modified:
    - Raid Management Addon/Init.lua
    - Raid Management Addon/Localization/DiagnoseLog.en.lua
    - Raid Management Addon/Localization/localization.en.lua
    - Raid Management Addon/Localization/localization.ru.lua
    - Raid Management Addon/Localization/localization.zhCN.lua
    - Raid Management Addon/Localization/localization.es.lua
    - Raid Management Addon/Localization/localization.fr.lua
    - tests/lua/harness/30_raid_runtime.lua
    - tests/test_runtime_foundations_behavior.py
    - tests/test_localization_contract.py

key-decisions:
  - "Bootstrap stores only the stable archive category and optional format version in addon.State; validator detail remains debug-only."
  - "The quarantine warning is emitted only after degraded initialization commits successfully, so rejected history cannot disable unrelated features."

patterns-established:
  - "Degraded bootstrap: consume normalization result, derive session state, initialize normally, then warn once."
  - "Recovery: every successful normalization clears the transient quarantine state without persisting a flag."

requirements-completed: [PERS-02, PERS-03]

duration: 8min
completed: 2026-08-15
---

# Phase 1 Plan 2: Degraded Archive Bootstrap Summary

**Recoverable raid-history quarantine with successful addon startup, one localized warning, and automatic session-state clearing after a valid reload**

## Performance

- **Duration:** 8 min
- **Started:** 2026-08-15T01:41:00Z
- **Completed:** 2026-08-15T01:49:00Z
- **Tasks:** 2
- **Files modified:** 10

## Accomplishments

- Converted archive rejection during `ADDON_LOADED` into an explicit successful degraded state while Reserves and the remaining bootstrap callbacks continue.
- Added one warning with stable category, localized category label, backup guidance, deliberate `RMA_Raids`-only recovery, and `/reload` instructions across all five catalogs.
- Kept validator detail in the diagnostic channel and persisted no quarantine flag or replacement archive.
- Added regressions for all three categories, warning cardinality, diagnostic privacy, valid-load recovery, and locale parity.

## Task Commits

Each task was committed atomically:

1. **Task 1: Specify degraded bootstrap and localized diagnostic contracts** - `8b348f3` (test)
2. **Task 2: Wire transient quarantine and localized warning into ADDON_LOADED** - `a71e7ea` (fix)

## Files Created/Modified

- `Raid Management Addon/Init.lua` - Consumes normalization results, derives transient quarantine state, logs detail, and warns once after successful startup.
- `Raid Management Addon/Localization/DiagnoseLog.en.lua` - Adds the structured debug-only archive quarantine diagnostic.
- `Raid Management Addon/Localization/localization.*.lua` - Adds warning, category, history-unavailable, and sync-suspended strings in every supported locale.
- `tests/lua/harness/30_raid_runtime.lua` - Covers degraded initialization, unrelated callback completion, warning cardinality, privacy, and recovery.
- `tests/test_runtime_foundations_behavior.py` - Registers the focused bootstrap runtime case.
- `tests/test_localization_contract.py` - Enforces key parity, formatting, recovery guidance, and prohibition on deleting unrelated SavedVariables.

## Decisions Made

- Used `addon.State.raidArchiveQuarantine` only as session-derived bootstrap state; store consumers continue to use the existing `SavedVariables.GetRaidArchiveError()` boundary.
- Emitted the user warning after the protected bootstrap transaction succeeds, preventing a quarantine notice from being repeated by normal blocked history operations.
- Reused the existing SavedVariables getters from Plan 01-01; no additional persistence-owner API or schema change was needed.

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

- No Lua 5.1-compatible executable exists on `PATH` or in the bundled Codex runtime. Lua-backed unittest cases stop at the documented `lua command is not available on PATH` gate. The focused static localization suite and all WotLK/Lua source validators pass; runtime behavior still requires Lua 5.1 or in-game execution.

## User Setup Required

None - no external service configuration required.

## Verification

- Localization contract: 17 tests passed, including all five quarantine catalogs and placeholder parity.
- TOC validator: 0 errors, 0 warnings.
- Lua 5.1 validator: 137 addon files and 9 harness files clean.
- Variadic `xpcall` scanner: 137 addon files clean.
- XML handler scan: no layout script handlers.
- `git diff --check`: clean.
- Lua-backed bootstrap case: blocked only by the documented missing runner.

## Next Phase Readiness

- Logger/history UI can reuse `StrRaidHistoryQuarantined` and the existing SavedVariables category owner.
- Raid-history sync can reuse `RaidSyncStatusQuarantined` and fail closed without changing reserve or distribution synchronization.
- No implementation blocker remains for Plan 01-03.

## Self-Check: PASSED

- All required source, locale, and test files exist.
- Both task commits are present in Git history.
- The working tree was clean before creating plan metadata.

---
*Phase: 01-persistence-safety*
*Completed: 2026-08-15*
