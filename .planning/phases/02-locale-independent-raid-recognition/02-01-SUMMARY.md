---
phase: 02-locale-independent-raid-recognition
plan: 01
subsystem: raid-runtime
tags: [wotlk-335a, lua-51, raid-session, canonical-identity, localization]

requires:
  - phase: 01-persistence-safety
    provides: fail-closed raid archive bootstrap and recovery state
provides:
  - Canonical instance resolver output as the sole Session and Roster admission identity
  - Transient Raid-owned instance context with localized display name and canonical key
  - Fail-closed roster mutation when recognized instance context is absent
affects: [02-02, 02-05, raid-sync, raid-roster]

tech-stack:
  added: []
  patterns:
    - Init commits recognized context only after both instance datasets activate
    - Session binds current raid records to transient canonical keys without rewriting persisted zones

key-files:
  created: []
  modified:
    - Raid Management Addon/Init.lua
    - Raid Management Addon/Services/Raid/Session.lua
    - Raid Management Addon/Services/Raid/Roster.lua
    - tests/lua/harness/30_raid_runtime.lua
    - tests/lua/harness/40_inspect_foundations.lua
    - tests/test_runtime_foundations_behavior.py
    - tests/test_inspect_dataset_behavior.py

key-decisions:
  - "Canonical instance identity remains transient and Raid-owned; persisted zone names and wire payloads remain unchanged."
  - "The first recognized context after reload binds the current raid record without using or rewriting its localized zone name."

patterns-established:
  - "Recognition ownership: only Init calls ResolveInstanceKey; Session and Roster consume the committed Raid context."
  - "Roster admission: an in-raid refresh returns before canonical mutation when recognized context is absent."

requirements-completed: [RAID-01, RAID-02, RAID-03, LOCL-02]

duration: 20min
completed: 2026-08-15
---

# Phase 2 Plan 1: Canonical Raid Admission Summary

**Dataset-backed map-ID recognition now drives Session and Roster through one transient canonical context while localized raid names remain presentation and persisted history data.**

## Performance

- **Duration:** 20 min
- **Started:** 2026-08-15T08:59:00Z
- **Completed:** 2026-08-15T09:19:00Z
- **Tasks:** 2
- **Files modified:** 7

## Accomplishments

- Added regression coverage for Vanilla map 409, TBC map 532, Wrath map 631, map-ID/name conflicts, canonical fallback, and unknown fail-closed behavior.
- Removed independent `RaidZones`, `GetInstanceInfo`, and resolver admission from Session and Roster.
- Preserved localized stored zone names while using a transient canonical key for same-instance comparisons and stale-context rejection.

## Task Commits

Each task was committed atomically:

1. **Task 1: Specify canonical admission and localized display behavior** - `6f0b11f` (test)
2. **Task 2: Carry one transient recognized context into Session and Roster** - `8521cae` (fix)

## Files Created/Modified

- `Raid Management Addon/Init.lua` - Commits or clears Raid context alongside canonical dataset activation.
- `Raid Management Addon/Services/Raid/Session.lua` - Owns transient context, reload binding, and canonical same-instance checks.
- `Raid Management Addon/Services/Raid/Roster.lua` - Consumes shared context and rejects stale admission before mutation.
- `tests/lua/harness/30_raid_runtime.lua` - Covers localized display preservation, reload binding, canonical replacement, and stale roster rejection.
- `tests/lua/harness/40_inspect_foundations.lua` - Covers cross-expansion resolver behavior and map-ID priority.
- `tests/test_runtime_foundations_behavior.py` - Registers focused runtime and static ownership contracts.
- `tests/test_inspect_dataset_behavior.py` - Registers resolver behavior and static priority contract.

## Decisions Made

- Kept canonical identity in Session-local runtime state because it is operational context, not persistence or wire data.
- Kept the current raid's initial post-reload canonical binding independent of its saved localized zone, preventing historical rewrites.

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

- The environment has no `lua` executable, so 62 Lua-backed cases in the focused wrappers remain environment-blocked. Three static contracts pass; addon and harness Lua 5.1 syntax checks pass. This is the pre-existing runner limitation recorded in project state, not a product failure.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- Canonical context is available for the bounded unknown-instance retry and warning behavior in Plan 02-02.
- Exact in-game behavior still requires the milestone's localized-client smoke test.

## Self-Check: PASSED

- Summary exists and both `02-01` task commits are present.
- Static ownership tests, Lua 5.1 addon/harness lint, `xpcall` scan, TOC validation, and `git diff --check` pass.

---
*Phase: 02-locale-independent-raid-recognition*
*Completed: 2026-08-15*
