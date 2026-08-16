---
phase: 05-runtime-surface-cleanup
plan: 01
subsystem: runtime-surface
tags: [wotlk-335a, lua-51, screen-notice, trade, loot-state]

requires:
  - phase: 04-milestone-verification
    provides: Verified v1.0 runtime compatibility baseline
provides:
  - Internal-event-only screen notice invocation
  - Trade-owned private mutable state initialization
  - Direct loot-context normalization during runtime bootstrap
affects: [06-logger-attendance-list-primitives, 07-ui-simplification-verification]

tech-stack:
  added: []
  patterns: [event-owned UI invocation, private service state, direct same-file state ownership]

key-files:
  created:
    - .planning/phases/05-runtime-surface-cleanup/05-01-SUMMARY.md
  modified:
    - Raid Management Addon/Modules/UI/ScreenNotice.lua
    - Raid Management Addon/Services/Master/Trade.lua
    - Raid Management Addon/Services/Loot/State.lua
    - tests/lua/harness/20_raid_database.lua
    - tests/lua/harness/30_raid_runtime.lua
    - tests/lua/harness/60_loot_ui.lua
    - tests/test_runtime_bootstrap_contract.py
    - tests/test_runtime_foundations_behavior.py

key-decisions:
  - "Internal ScreenNotice events are the sole notice invocation path; no compatibility export was retained."
  - "Trade mutable state remains accessible only through Trade-owned operations and the private ensureState helper."
  - "Database.EnsureLootRuntimeState calls ContextState.SyncRuntimeState directly at the established bootstrap point."

patterns-established:
  - "Runtime surface cleanup removes unconsumed forwarding APIs without replacement aliases."
  - "Behavior regressions assert observable operations and owner-level state rather than removed accessors."

requirements-completed: [CLEAN-01, CLEAN-02, CLEAN-03]

duration: 12min
completed: 2026-08-16
---

# Phase 5 Plan 1: Runtime Surface Cleanup Summary

**Screen notices, manual Trade handling, and loot bootstrap retain their behavior through their actual owners with three unconsumed exports or forwarders removed.**

## Performance

- **Duration:** 12 min
- **Started:** 2026-08-16T14:15:00Z
- **Completed:** 2026-08-16T14:27:00Z
- **Tasks:** 3
- **Files modified:** 8

## Accomplishments

- Kept screen notice rendering, sizing, title colorization, detail hiding, alpha/show behavior, and fade timing on `Internal.ScreenNotice` while removing `ScreenNotice.Show`.
- Preserved failed-verification and successful-retry Trade behavior through public operations while removing `Trade.EnsureState`.
- Preserved loot context identity, legacy projections, session/snapshot normalization, and loot defaults through a direct `ContextState.SyncRuntimeState` bootstrap call.

## RED/GREEN Evidence

### Task 1: Internal screen notice invocation

- **RED:** The focused Python registration reached LuaJIT and failed because `addon.UI.ScreenNotice.Show` was still a function: `expected nil, got function`.
- **GREEN:** `RuntimeFoundationsBehaviorTest.test_screen_notice_uses_internal_event_without_direct_export` ran 1 test and passed. The removed-symbol search returned no matches and the event registration remained at `ScreenNotice.lua:115`.

### Task 2: Private Trade state initialization

- **RED:** The focused Python registration reached LuaJIT and failed because `Trade.EnsureState` was still a function: `expected nil, got function`.
- **GREEN:** `LootDistributionHardeningTests.test_manual_hold_trade_requires_inventory_evidence` ran 1 test and passed. The regression proves warnings/logger/counter/pending-close transitions without consuming internal state; the removed-symbol search returned no matches and all private `ensureState` call sites remained.

### Task 3: Direct loot runtime-state normalization

- **RED:** The focused Python registration reached LuaJIT and failed because `addon.Services.Loot.SyncRuntimeState` was still a function: `expected nil, got function`.
- **GREEN:** `RuntimeBootstrapContractTest.test_loot_runtime_state_syncs_directly_without_service_forwarder` ran 1 test and passed. The regression proves root, raid-state, loot-context, and item-info identity; numeric/default normalization; active and legacy projections; session/snapshot maps; and owner availability.

## Task Commits

Each task was committed atomically:

1. **Task 1: Keep screen notices on the internal event path only** - `d335ef7` (`refactor`)
2. **Task 2: Keep mutable Trade state behind owning operations** - `1620f44` (`refactor`)
3. **Task 3: Normalize loot runtime state through the same-file owner directly** - `c593854` (`refactor`)

## Files Created/Modified

- `Raid Management Addon/Modules/UI/ScreenNotice.lua` - Removed the direct `Show` export while retaining event callback registration.
- `Raid Management Addon/Services/Master/Trade.lua` - Removed the public mutable-state accessor while retaining the local owner helper.
- `Raid Management Addon/Services/Loot/State.lua` - Replaced the service forwarder with the direct state-owner call and removed the forwarder.
- `tests/lua/harness/30_raid_runtime.lua` - Added the focused screen notice event regression.
- `tests/lua/harness/60_loot_ui.lua` - Reworked manual Trade evidence around public operations and observable transitions.
- `tests/lua/harness/20_raid_database.lua` - Added the focused loot runtime-state normalization regression.
- `tests/test_runtime_foundations_behavior.py` - Registered the screen notice Lua case.
- `tests/test_runtime_bootstrap_contract.py` - Registered the loot runtime-state Lua case.

## Verification

- Focused screen notice regression: 1/1 passed.
- Focused manual Trade regression: 1/1 passed.
- Focused loot runtime-state regression: 1/1 passed.
- Complete unit-test discovery: **509/509 passed** in 14.456 seconds.
- TOC validator: 0 errors, 0 warnings.
- Lua 5.1 lint: 137 files clean.
- Variadic `xpcall` scan: 137 files clean.
- XML script-handler scan: no matches.
- Removed runtime-symbol scan: no matches.
- Ownership linkage searches: screen notice registration, private Trade helper/callers, and direct ContextState bootstrap call all present.
- `git diff --check`: clean.
- Commit-range scope inspection: only the eight approved runtime/test files changed; no XML, localization, `Libs/`, TOC, SavedVariables, communication, Logger, or Attendance files changed.

## Decisions Made

- Followed the phase decisions exactly: delete rather than deprecate, keep state behind the owning operations, and call the same-file loot state owner directly.
- No replacement API or compatibility shim was introduced.

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

- The `py`, `python`, and `node` aliases were unavailable in this process, and the repository virtualenv points to a removed interpreter. The exact unittest modules and validators were executed with the installed Python 3.13 executable. Lua-backed cases used the established external `%TEMP%` hard-link alias to `C:\tools\LuaJIT\bin\luajit.exe`; no repository tooling or runtime file was changed.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

Phase 5 runtime surface cleanup is complete and bounded. Phase 6 can consolidate only the approved Logger/Attendance list primitives against the clean 509-test baseline.

## Self-Check: PASSED

- Summary and all eight claimed changed files exist.
- Task commits `d335ef7`, `1620f44`, and `c593854` exist in Git history.
- All fresh verification evidence above was collected after the final runtime changes.

---
*Phase: 05-runtime-surface-cleanup*
*Completed: 2026-08-16*
