---
phase: 06-logger-and-attendance-list-primitives
plan: 03
subsystem: ui
tags: [lua-5.1, wotlk-3.3.5a, attendance, list-layout, tdd]

# Dependency graph
requires:
  - phase: 06-logger-and-attendance-list-primitives
    provides: Seven focused shared list primitives and completed Logger migration
provides:
  - Attendance raid and player lists routed through shared geometry, binding, title, and label primitives
  - Controller-edge parity coverage for Attendance geometry, titles, empty states, loot-ban adjustment, Spec/Inspect rendering, and Force Inspect
affects: [07-ui-simplification-verification]

# Tech tracking
tech-stack:
  added: []
  patterns: [controller-owned presentation policy, shared list mechanics, Lua-backed TDD]

key-files:
  created: []
  modified:
    - Raid Management Addon/Controllers/Attendance.lua
    - tests/lua/harness/30_raid_runtime.lua
    - tests/test_runtime_foundations_behavior.py

key-decisions:
  - "Attendance continues to own every layout constant, descriptor, sorter, context and empty-state choice, loot-ban adjustment, Spec/Inspect path, and Force Inspect action while addon.UI.Lists performs only the extracted mechanics."
  - "Attendance passes fallback, gutter, insets, gaps, offsets, minimums, ratios, descriptors, and visibility choices explicitly; no shared default, wrapper, cache, listener, timer, or polling path was introduced."

patterns-established:
  - "Both list controllers now call the same seven focused primitives while retaining feature-specific policy at their controller edges."
  - "Controller-edge regressions compose real shared primitives with lightweight fixtures and assert feature-owned behavior through observable effects."

requirements-completed: [UI-03]

# Metrics
duration: 8min
completed: 2026-08-16
---

# Phase 6 Plan 3: Attendance Shared List Mechanics Summary

**Attendance raid and player lists now use the seven focused `addon.UI.Lists` operations with exact geometry, contextual-title, empty-state, loot-ban, Spec/Inspect, and Force Inspect parity.**

## Performance

- **Duration:** 8 min
- **Started:** 2026-08-16T16:47:09Z
- **Completed:** 2026-08-16T16:55:17Z
- **Tasks:** 2
- **Files modified:** 3

## Accomplishments

- Replaced Attendance's duplicated width fallback, budget, header, row, sort-binding, title, and label mechanics with the existing shared operations.
- Preserved Attendance-owned constants, duplicated raid/player descriptors, sorters, context and empty-state selection, loot-ban name inset, Spec/Inspect icons and tooltips, and Force Inspect wiring.
- Added a focused LuaJIT regression covering valid 640px geometry, the invalid-width 240 clamp, exact row/header parity, one-time sort binding, contextual titles, selected empty states, and feature-owned rendering.
- Closed the Phase 6 automated gate with clean WotLK validators and exactly 512/512 passing tests.

## TDD Evidence

- **RED:** The focused regression loaded the real shared operations and unchanged Attendance, completed all geometry, binding, title, empty-state, loot-ban, Spec/Inspect, tooltip, and Force Inspect assertions, then failed only at `UI.Lists.GetContentWidth` call count (`expected 14, got 0`).
- **GREEN:** The same focused regression passed after Attendance routed the existing call points through the seven operations and removed only duplicated mechanical helpers.
- **REFACTOR:** The GREEN change removed 161 duplicated lines while retaining the controller-owned presentation paths; no separate cleanup commit was needed.

## Task Commits

Each TDD stage was committed atomically:

1. **Task 1: RED - capture Attendance geometry and Spec/Inspect ownership** - `ee87855` (test)
2. **Task 2: Route Attendance mechanics through shared primitives and close final gates** - `794cfb7` (refactor)

## Files Created/Modified

- `Raid Management Addon/Controllers/Attendance.lua` - Routes Attendance mechanics through the focused shared operations while retaining feature presentation ownership.
- `tests/lua/harness/30_raid_runtime.lua` - Exercises Attendance geometry, sorting, titles, empty states, loot-ban adjustment, Spec/Inspect, and Force Inspect at the controller edge.
- `tests/test_runtime_foundations_behavior.py` - Registers the focused Lua case and asserts Attendance-specific ownership remains outside the shared module.

## Decisions Made

- Kept the existing localization, row drawing, and post-update recalculation points and supplied every numeric layout value explicitly from `AttendanceLayout`.
- Kept context and empty-state selection inside Attendance; `FormatCountTitle` receives the already selected context with no fallback, and `SetLabel` receives only the selected text.
- Kept Spec and Inspect sharing limited to their supplied column geometry; icon creation, textures, slot order, placement, state, tooltips, and interactions remain local.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Extended the pre-existing Attendance fixture with the required shared-operation surface**

- **Found during:** Task 2 final unittest discovery
- **Issue:** Two pre-existing Attendance identity/roster cases used an older lightweight `UI.Lists` fixture. After the controller correctly asserted the seven Plan 01 operations, those cases stopped at bootstrap before exercising their intended behavior.
- **Fix:** Added only the seven required fixture operations to the existing test double and incorporated the repair into the RED test commit; production behavior was unchanged.
- **Files modified:** `tests/lua/harness/30_raid_runtime.lua`
- **Verification:** The two failing cases plus the focused Attendance case passed 3/3, Lua 5.1 lint remained clean, and one replacement final discovery passed 512/512.
- **Committed in:** `ee87855`

**2. [Rule 3 - Blocking] Repaired GSD position and roadmap advancement manually**

- **Found during:** Plan metadata update
- **Issue:** `state advance-plan` could not parse the current position format, `state update-progress` rewrote aggregate totals as phase-local counts, `roadmap update-plan-progress` reported success without changing the current roadmap format, and the commit helper misparsed the spaced PowerShell message as pathspecs after staging the requested files.
- **Fix:** Retained the successful metric, decision, session, requirement, and staging updates; applied the equivalent current-position, aggregate progress, Phase 6 metric, plan checkbox, and roadmap completion changes directly; then committed the exact staged metadata files with Git.
- **Files modified:** `.planning/STATE.md`, `.planning/ROADMAP.md`
- **Verification:** STATE reports Phase 6 plan 3 of 3 and 100% aggregate plan progress; ROADMAP reports Phase 6 complete at 3/3; UI-03 is complete while QUAL-01 and QUAL-02 remain pending.
- **Committed in:** Plan metadata commit

---

**Total deviations:** 2 auto-fixed (2 blocking workflow/fixture issues).
**Impact on plan:** The fixture repair restored pre-existing coverage for the required shared contract, and the metadata repair applied the workflow's intended state. Runtime scope, architecture, and feature behavior were unchanged.

## Issues Encountered

- The first complete discovery reached all 512 tests and reported exactly two failures from the same outdated Attendance fixture surface. Following the plan's evidence-based repair rule, the nearest three focused cases were run first, affected static lint was repeated, and a single replacement final discovery passed.

## Verification

- Attendance RED: expected failure only on absent shared-operation calls after all feature assertions executed.
- Attendance GREEN: PASS using the external `lua.exe` and side-by-side `lua51.dll` shim.
- Phase 6 focused regressions: PASS, 3/3 together for shared primitives, Logger, and Attendance.
- TOC validator: PASS, 0 errors and 0 warnings.
- Lua 5.1 lint: PASS across 147 addon and harness files.
- Variadic `xpcall` scan: PASS across 137 addon Lua files.
- XML layout-only scan: PASS, no script handlers outside vendored libraries.
- Forbidden modern API scan: PASS, no matches outside vendored libraries.
- Ownership and scope scans: PASS; Spec/Inspect/Force Inspect remain Attendance-owned and no XML, Localization, Libs, TOC, persistence, wire, or unrelated feature file changed.
- Final unittest discovery: PASS, exactly 512 tests in 12.637s.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- Phase 6 is complete with UI-01, UI-02, and UI-03 protected by focused regressions.
- Phase 7 can perform milestone-level compatibility verification; QUAL-01 and QUAL-02 remain intentionally pending.

## Self-Check: PASSED

- Confirmed the summary and all three implementation/test files exist.
- Confirmed commits `ee87855` and `794cfb7` exist in Git history.

---
*Phase: 06-logger-and-attendance-list-primitives*
*Completed: 2026-08-16*
