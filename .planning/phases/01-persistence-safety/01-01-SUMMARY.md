---
phase: 01-persistence-safety
plan: 01
subsystem: database
tags: [savedvariables, quarantine, lua-5.1, wotlk]

requires: []
provides:
  - Nil-only creation of the canonical format-1 raid archive
  - Stable quarantine categories for invalid type, unsupported format, and corrupt format-1 archives
  - Preservation regressions covering load, access, normalization, and save preparation
affects: [01-02-degraded-bootstrap, 01-03-history-quarantine]

tech-stack:
  added: []
  patterns: [nil-only SavedVariables initialization, transient quarantine classification, fail-closed save preparation]

key-files:
  created: []
  modified:
    - Raid Management Addon/Database/SavedVariables.lua
    - tests/lua/harness/30_raid_runtime.lua
    - tests/test_raid_replication_behavior.py

key-decisions:
  - "GetRaidArchiveError remains the store-facing stable quarantine category while validator detail is exposed separately for diagnostics."
  - "Only a nil RMA_Raids value is treated as a fresh install; every non-nil value is preserved exactly until validation."

patterns-established:
  - "Archive classification: check type, then format version, then the format-1 structural validator."
  - "Quarantine metadata is session-local and never persisted alongside the archive."

requirements-completed: [PERS-01, PERS-03]

duration: 10min
completed: 2026-08-15
---

# Phase 1 Plan 1: Archive Preservation Summary

**Nil-only raid archive creation with non-destructive quarantine classification for every existing unsupported SavedVariable value**

## Performance

- **Duration:** 10 min
- **Started:** 2026-08-15T01:30:00Z
- **Completed:** 2026-08-15T01:40:16Z
- **Tasks:** 2
- **Files modified:** 3

## Accomplishments

- Replaced destructive type/version normalization with canonical archive creation only when `RMA_Raids` is nil.
- Added stable invalid-type, unsupported-format, and corrupt-format-1 quarantine categories while retaining validator detail for diagnostics.
- Added focused regressions for fresh, valid, scalar, older-format, future-format, and malformed format-1 archives across initialization and save preparation.

## Task Commits

Each task was committed atomically:

1. **Task 1: Add failing preservation regressions** - `3f78735` (test)
2. **Task 2: Implement nil-only creation and stable quarantine classification** - `73d0fda` (fix)

## Files Created/Modified

- `Raid Management Addon/Database/SavedVariables.lua` - Preserves every non-nil raid archive and owns transient classification metadata.
- `tests/lua/harness/30_raid_runtime.lua` - Exercises supported initialization and quarantined preservation paths.
- `tests/test_raid_replication_behavior.py` - Registers the focused Lua behavior cases.

## Decisions Made

- Kept `GetRaidArchiveError()` compatible with `DBRaidStore` by returning a stable truthy category code; detailed validator reasons are available through `GetRaidArchiveErrorDetail()`.
- Exposed the rejected format version only as transient metadata for the next bootstrap/diagnostic plan.
- Did not add migration, repair, shadow archive, persistence flag, or direct SavedVariables access outside the database owner.

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

- The environment has no Lua 5.1 executable on `PATH`. Focused and complete Python discovery reached only the documented `lua command is not available on PATH` runner gate. Addon and harness sources passed the repository Lua 5.1 static validator; this environment limitation is not classified as a product failure.

## User Setup Required

None - no external service configuration required.

## Verification

- TOC validator: 0 errors, 0 warnings.
- Lua 5.1 validator: 137 addon files and 10 harness files clean.
- Variadic `xpcall` scanner: 137 addon files clean.
- XML handler scan: no layout script handlers.
- `git diff --check`: clean.
- Lua-backed behavior execution: blocked only by the documented missing runner.

## Next Phase Readiness

- Stable archive categories and diagnostic detail are ready for Plan 01-02 bootstrap consumption and localized warnings.
- No implementation blocker remains; runtime behavior still needs execution under Lua 5.1 or the WotLK client.

## Self-Check: PASSED

- Required source and test files exist.
- Both task commits are present in Git history.

---
*Phase: 01-persistence-safety*
*Completed: 2026-08-15*
