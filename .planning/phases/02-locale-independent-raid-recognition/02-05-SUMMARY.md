---
phase: 02-locale-independent-raid-recognition
plan: 05
subsystem: raid-runtime
tags: [wotlk-335a, lua-51, localization, monster-yell, canonical-identity]

requires:
  - phase: 02-locale-independent-raid-recognition
    provides: evidence-bound yell definitions and transient canonical raid context
provides:
  - Exact English and current-locale yell fallback matching for all 15 existing definitions
  - Active canonical instance and current-raid gates before boss recording
  - Table-driven localized, negative-text, scope, transition, and combat-log regressions
affects: [phase-4-localized-smoke-test, raid-encounter-detection]

tech-stack:
  added: []
  patterns: [exact scalar equality, canonical instance scope, narrow event fallback]

key-files:
  created: []
  modified:
    - Raid Management Addon/Init.lua
    - tests/lua/harness/40_inspect_foundations.lua
    - tests/test_inspect_dataset_behavior.py
    - tests/test_localization_contract.py

key-decisions:
  - "Monster-yell fallback accepts only direct equality with the English definition or current-locale scalar in the definition's active canonical raid."
  - "Combat-log detection remains an unchanged direct delegation; yell matching stays a narrow fallback."

patterns-established:
  - "Scoped fallback: a current raid and exact active canonical instance are mandatory before Raid:AddBoss."
  - "Locale parity tests reuse the loaded English definition metadata and scalar-only locale overrides."

requirements-completed: [LOCL-01, LOCL-02]

duration: 8min
completed: 2026-08-15
---

# Phase 2 Plan 5: Exact scoped boss-yell fallback Summary

**All 15 existing yell fallbacks now accept only byte-exact English or current-locale text inside their active canonical raid, without changing combat-log detection.**

## Performance

- **Duration:** 8 min
- **Started:** 2026-08-15T09:42:00Z
- **Completed:** 2026-08-15T09:50:00Z
- **Tasks:** 2
- **Files modified:** 4

## Accomplishments

- Replaced the removed legacy `BossYells` dictionary lookup with a Lua 5.1-compatible loop over the 15 evidence-backed definitions.
- Required both a current raid and equality between the active dataset key and the definition's canonical instance before recording a boss.
- Registered table-driven coverage for four non-English locales, exact English fallback, altered text, wrong or absent raid context, stale-key clearing, and unchanged combat-log delegation.

## Task Commits

Each task was committed atomically:

1. **Task 1: Specify exact mixed-language matching and canonical instance scope** - `d3660b3` (test)
2. **Task 2: Scope the existing yell fallback to exact text and active canonical raid** - `4e2b189` (fix)

## Files Created/Modified

- `Raid Management Addon/Init.lua` - Resolves exact definition text only after current-raid and canonical-instance gates.
- `tests/lua/harness/40_inspect_foundations.lua` - Covers all definitions and supported localized catalogs plus negative and delegation behavior.
- `tests/test_inspect_dataset_behavior.py` - Registers the focused Lua behavior case.
- `tests/test_localization_contract.py` - Enforces exact comparison, canonical scope, definition wiring, and unchanged combat-log delegation statically.

## Decisions Made

- Used `LootSourcesData.GetActiveInstanceKey()` as the authoritative transient scope already established by Phase 2; no display name, persisted field, or parallel resolver was added.
- Returned after the first matching definition so duplicate boss labels do not cause repeated recording while preserving exact definition order.

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

- No Lua executable is available on PATH. The 24 Lua-backed tests in the focused command remain environment-blocked; 32 static tests pass, including all new handler and evidence contracts. Both addon and harness Lua 5.1 syntax validators pass.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- Phase 2 implementation is complete and ready for verification.
- Exact localized server payloads and encounter recording still require the planned in-game localized-client smoke test in Phase 4.

## Self-Check: PASSED

- Both `02-05` task commits and this summary exist.
- Evidence, static handler contracts, Lua 5.1 addon/harness lint, `xpcall` scan, TOC validation, XML-handler scan, and `git diff --check` pass.

---
*Phase: 02-locale-independent-raid-recognition*
*Completed: 2026-08-15*
