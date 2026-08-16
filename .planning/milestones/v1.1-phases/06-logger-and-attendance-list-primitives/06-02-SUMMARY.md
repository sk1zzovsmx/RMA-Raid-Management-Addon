---
phase: 06-logger-and-attendance-list-primitives
plan: 02
subsystem: ui
tags: [lua-5.1, wotlk-3.3.5a, logger, list-layout, tdd]

# Dependency graph
requires:
  - phase: 06-logger-and-attendance-list-primitives
    provides: Seven explicit shared list primitives under addon.UI.Lists
provides:
  - Logger raid and loot lists routed through the shared geometry, binding, title, and label primitives
  - Controller-edge parity coverage for Logger geometry, Source behavior, titles, hints, and sort binding
affects: [06-03-attendance-migration, 07-ui-simplification-verification]

# Tech tracking
tech-stack:
  added: []
  patterns: [controller-owned presentation policy, shared list mechanics, Lua-backed TDD]

key-files:
  created: []
  modified:
    - Raid Management Addon/Controllers/Logger.lua
    - tests/lua/harness/70_raid_sync.lua
    - tests/test_sync_communications_behavior.py

key-decisions:
  - "Logger continues to own every layout constant, descriptor, sorter, localized selection, Source interaction, and refresh call point while addon.UI.Lists performs only the extracted mechanics."
  - "The Logger regression composes the real Phase 6 shared operations with the existing lightweight controller fixture, so the controller edge is observed without replacing the production width algorithm."

patterns-established:
  - "Controllers pass all geometry and presentation choices explicitly into focused addon.UI.Lists operations."
  - "Feature-specific interaction state remains outside stable initial shared sort binding."

requirements-completed: [UI-02]

# Metrics
duration: 12min
completed: 2026-08-16
---

# Phase 6 Plan 2: Logger Shared List Mechanics Summary

**Logger raid and loot lists now use the seven focused `addon.UI.Lists` operations with exact controller-edge geometry, Source interaction, title, hint, and binding parity.**

## Performance

- **Duration:** 12 min
- **Started:** 2026-08-16T16:31:00Z
- **Completed:** 2026-08-16T16:43:15Z
- **Tasks:** 2
- **Files modified:** 3

## Accomplishments

- Replaced Logger's duplicated width fallback, budget, header, row, sort-binding, title, and label mechanics with the existing shared operations.
- Preserved Logger-owned constants, raid/loot descriptors, item icon allowance, Source hit box and tooltip ownership, Source availability state, sorters, localized selection, and refresh points.
- Added a focused LuaJIT regression covering valid 640px geometry, invalid-width 240 fallback/clamp behavior, row/header parity, one-time sort binding, contextual titles, and exact empty-state selection.

## TDD Evidence

- **RED:** The focused regression loaded the real shared primitives and unchanged Logger, passed all controller-edge behavior checks, then failed only at `UI.Lists.GetContentWidth` call count (`expected 18, got 0`).
- **GREEN:** The same focused regression passed after Logger routed its existing call points through the seven shared operations.
- **REFACTOR:** The GREEN implementation removed 195 duplicated lines while retaining the feature-owned presentation policy and introduced no additional abstraction layer.

## Task Commits

Each TDD stage was committed atomically:

1. **Task 1: RED - lock Logger list presentation parity** - `7135025` (test)
2. **Task 2: GREEN - share Logger list mechanics** - `65f9d78` (refactor)

## Files Created/Modified

- `Raid Management Addon/Controllers/Logger.lua` - Routes Logger mechanics through the focused shared list operations while retaining presentation ownership.
- `tests/lua/harness/70_raid_sync.lua` - Exercises Logger geometry, Source state and hit box, binding, titles, and hints at the controller edge.
- `tests/test_sync_communications_behavior.py` - Registers the focused Lua case and asserts Logger-specific source ownership.

## Decisions Made

- Kept the existing Logger-specific width calculation and application call points, but made each use the shared primitive with every fallback, gutter, lead, gap, offset, and returned icon width supplied explicitly.
- Kept `updateSourceHeaderState` independent of shared binding so boss selection alone continues to control Source mouse availability and alpha.
- Used the real shared operations inside the fixture while retaining only the existing lightweight controller double needed to invoke Logger configuration callbacks directly.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Repaired GSD position and roadmap advancement manually**

- **Found during:** Plan metadata update
- **Issue:** `state advance-plan` could not parse the current position format, `state update-progress` rewrote aggregate totals as phase-local counts, and `roadmap update-plan-progress` reported success without updating the current roadmap format.
- **Fix:** Retained the successful metric, decision, session, and requirement updates, then applied the equivalent current-position, aggregate progress, Phase 6 metric, plan checkbox, and roadmap count changes directly.
- **Files modified:** `.planning/STATE.md`, `.planning/ROADMAP.md`
- **Verification:** STATE reports Phase 6 plan 2 of 3 and 94% aggregate plan progress; ROADMAP reports 2/3 and checks 06-02; UI-02 is complete in REQUIREMENTS.
- **Committed in:** Plan metadata commit

---

**Total deviations:** 1 auto-fixed (1 blocking workflow issue).
**Impact on plan:** Runtime and test scope were unchanged; the metadata repair applied the workflow's intended state.

## Issues Encountered

- During GREEN calibration, the regression initially expected eight `SetLabel` calls but observed sixteen because both titles and empty-state labels correctly use the shared label primitive. The expectation was corrected in the RED commit before the final GREEN verification; no production behavior or scope changed.

## Verification

- Focused Logger unittest: PASS using external `lua.exe` and side-by-side `lua51.dll` shim.
- Lua 5.1 lint: PASS across 137 addon Lua files.
- Variadic `xpcall` scan: PASS across 137 addon Lua files.
- Logger ownership scan: PASS for layout tables/constants, Source state, empty-state selector, and tooltip model.
- Shared-owner constant scan: PASS; no Logger visual constants moved into `ListController.lua`.
- New machinery scan: PASS; no listener, timer, polling, resize, metatable, or cache path added.
- `git diff --check 7135025^..65f9d78`: PASS.
- Full unittest discovery intentionally not run, as required by the plan.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- Logger migration is complete and UI-02 is protected by focused controller-edge regression.
- Phase 6 plan 03 can migrate Attendance and run the final phase-wide gates.

## Self-Check: PASSED

- Confirmed the summary and all three modified implementation/test files exist.
- Confirmed commits `7135025` and `65f9d78` exist in Git history.

---
*Phase: 06-logger-and-attendance-list-primitives*
*Completed: 2026-08-16*
