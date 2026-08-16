---
phase: 06-logger-and-attendance-list-primitives
plan: 01
subsystem: ui
tags: [lua-5.1, wotlk-3.3.5a, list-layout, tdd]

# Dependency graph
requires: []
provides:
  - Seven explicit geometry, binding, title, and label primitives under addon.UI.Lists
  - Lua-backed parity coverage for Logger and Attendance list mechanics
affects: [06-02-controller-migration, 06-03-phase-verification]

# Tech tracking
tech-stack:
  added: []
  patterns: [controller-supplied geometry, focused shared UI primitives, Lua-backed TDD]

key-files:
  created: []
  modified:
    - Raid Management Addon/Modules/UI/ListController.lua
    - tests/lua/harness/40_inspect_foundations.lua
    - tests/test_runtime_foundations_behavior.py

key-decisions:
  - "Every layout value and binding flag remains caller-supplied; addon.UI.Lists introduces no visual defaults or orchestration layer."
  - "The regression fixes literal floor allocations and verifies remainder pixels against the unmodified LuaJIT pairs order observed for each fixture table."

patterns-established:
  - "Shared list primitives apply only explicit controller-owned descriptors and geometry."
  - "Pairs-derived remainder parity is asserted without sorting or replacing the existing allocation order."

requirements-completed: [UI-01]

# Metrics
duration: 7min
completed: 2026-08-16
---

# Phase 6 Plan 1: Shared List Primitive Contract Summary

**Seven focused `addon.UI.Lists` primitives preserve Logger and Attendance geometry, sort binding, titles, and optional-label behavior under Lua 5.1.**

## Performance

- **Duration:** 7 min
- **Started:** 2026-08-16T16:23:07Z
- **Completed:** 2026-08-16T16:29:42Z
- **Tasks:** 2
- **Files modified:** 3

## Accomplishments

- Added exact content-width and column-budget operations with explicit fallback, gutter, lead, gap, and returned-width inputs.
- Added header, row, one-time sort binding, count-title, and optional-label operations without controller policy or hidden visual defaults.
- Locked the existing `CalculateColumnWidths` minimum, fixed-key, floor, proportional, and pairs-derived remainder behavior in a focused LuaJIT regression.

## TDD Evidence

- **RED:** The focused Python method reached LuaJIT, completed all pre-existing width-allocation assertions, and failed at `tests/lua/runtime_harness.lua` with `attempt to call field 'GetContentWidth' (a nil value)` before any production edit.
- **GREEN:** The same focused method passed after adding only the seven planned public operations.
- **REFACTOR:** No separate refactor was needed; the minimal green implementation already matched the focused owner and API boundary.

## Task Commits

Each TDD stage was committed atomically:

1. **Task 1: RED - lock the explicit shared list contract** - `344e6f3` (test)
2. **Task 2: GREEN - add focused primitives under addon.UI.Lists** - `489d2d3` (feat)

## Files Created/Modified

- `Raid Management Addon/Modules/UI/ListController.lua` - Adds exactly the seven shared list primitives under the existing owner.
- `tests/lua/harness/40_inspect_foundations.lua` - Exercises numeric parity, explicit layout geometry, binding, titles, and optional-label visibility.
- `tests/test_runtime_foundations_behavior.py` - Registers the focused Lua-backed regression.

## Decisions Made

- Kept all fallback widths, gutters, offsets, gaps, descriptor tables, strings, and visibility choices explicit at call sites.
- Preserved `CalculateColumnWidths` unchanged and tested its current `pairs` ordering rather than sorting or normalizing variable keys.
- Used the existing `Frames.SetScriptSafely` and `Primitives.SetShown` owners directly; no wrapper, cache, listener, timer, or polling path was added.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Stabilized the LuaJIT remainder characterization**

- **Found during:** Task 1 (RED fixture calibration)
- **Issue:** A single hard-coded final remainder map perturbed with LuaJIT table allocation as the concatenated harness source changed, causing the pre-API baseline to fail before the intended RED.
- **Fix:** Hard-coded the representative minimum-plus-floor maps, independently enumerated the fixture table's current `pairs` order, and asserted that only the exact first remainder keys receive the final pixels. This preserves the specified algorithm and fails if production sorts, skips, or redistributes keys.
- **Files modified:** `tests/lua/harness/40_inspect_foundations.lua`
- **Verification:** The corrected RED passed every allocation assertion and failed only on missing `Lists.GetContentWidth`; GREEN passed unchanged.
- **Committed in:** `344e6f3`

**2. [Rule 3 - Blocking] Repaired GSD state and roadmap advancement manually**

- **Found during:** Plan metadata update
- **Issue:** `state advance-plan` could not parse the pre-plan `Plan: —` position, and `roadmap update-plan-progress` reported success without changing the repository's current roadmap format.
- **Fix:** Retained the successful metric, decision, session, and requirement updates, then applied the equivalent current-position, progress, phase metric, plan checkbox, and roadmap progress changes directly.
- **Files modified:** `.planning/STATE.md`, `.planning/ROADMAP.md`
- **Verification:** STATE reports Phase 6 plan 1 of 3 and 88% aggregate plan progress; ROADMAP reports 1/3 and checks 06-01; UI-01 is complete in REQUIREMENTS.
- **Committed in:** Plan metadata commit

---

**Total deviations:** 2 auto-fixed (1 bug, 1 blocking workflow issue).
**Impact on plan:** The test fix retained exact current-runtime pairs-order coverage, and the metadata repair applied the workflow's intended state. Production scope and API remained unchanged.

## Issues Encountered

- The system `node` and `py` launchers were not on PATH. The standard GSD scripts used the bundled Node runtime, and validation used the bundled Python runtime already prescribed by the test command.

## Verification

- Focused unittest: PASS on external `lua.exe`/`lua51.dll` shim.
- Focused export scan: exactly 7 planned `Lists` functions.
- New forbidden machinery scan: no added `OnUpdate`, timer, resize, cache, or metatable path.
- Lua 5.1 lint: PASS.
- Variadic `xpcall` scan: PASS.
- `git diff --check 344e6f3^..489d2d3`: PASS.
- Full unittest discovery intentionally not run, as required by the plan.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- The deterministic shared primitive contract is ready for Logger and Attendance controller migration in plan 06-02.
- No blocker is known.

## Self-Check: PASSED

- Confirmed the summary and all three modified implementation/test files exist.
- Confirmed commits `344e6f3` and `489d2d3` exist in Git history.

---
*Phase: 06-logger-and-attendance-list-primitives*
*Completed: 2026-08-16*
