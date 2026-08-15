---
phase: 01-persistence-safety
plan: 03
subsystem: ui-sync
tags: [savedvariables, quarantine, logger, raid-sync, lua-5.1, wotlk]

requires:
  - phase: 01-persistence-safety-02
    provides: Bootstrap-derived quarantine state and localized recovery/status strings
provides:
  - Explicit read-only quarantine presentation in Loot History
  - Pre-transport quarantine admission for all raid-history synchronization paths
  - Regression contracts preserving version-5 wire behavior and unrelated handler availability
affects: [phase-2-raid-recognition, logger-history-ui, raid-history-sync, milestone-verification]

tech-stack:
  added: []
  patterns: [database-owned quarantine query, controller read-only projection, pre-transport sync admission]

key-files:
  created: []
  modified:
    - Raid Management Addon/Controllers/Logger.lua
    - Raid Management Addon/Database/DBSyncer.lua
    - tests/lua/harness/70_raid_sync.lua
    - tests/test_raid_replication_behavior.py
    - tests/test_sync_communications_behavior.py

key-decisions:
  - "Loot History stays open and renders the existing localized quarantine label while all history actions and selections are disabled."
  - "DBSyncer checks the SavedVariables owner before decoding, serialization, session allocation, recovery, import, or archive mutation."
  - "The quarantine guard is scoped to RMARaidSync; Reserves and Distribution owners and wire contracts remain unchanged."

patterns-established:
  - "Consumer quarantine checks read only Database.SavedVariables.GetRaidArchiveError and never inspect RMA_Raids directly."
  - "Synchronization suspension returns the localized catalog string through the existing status/reason API."

requirements-completed: [PERS-02, PERS-03]

duration: 12min
completed: 2026-08-15
---

# Phase 1 Plan 3: Read-Only History and Sync Suspension Summary

**Visible read-only raid-history quarantine with RMARaidSync rejected before protocol, queue, recovery, import, or store work**

## Performance

- **Duration:** 12 min
- **Started:** 2026-08-15T01:50:00Z
- **Completed:** 2026-08-15T02:01:30Z
- **Tasks:** 2
- **Files modified:** 5

## Accomplishments

- Made quarantined raid history visibly unavailable instead of indistinguishable from a legitimate empty archive.
- Cleared history selections and disabled set-current, share, export, delete, add, edit, and maintenance controls without closing the window.
- Added one database-owned sync admission boundary and applied it before inbound decode, outbound encode, transfer allocation, recovery, historical consent, authority handover, and store mutation paths.
- Preserved `RMARaidSync`, protocol version 5, envelope/payload structure, authorization rules, and the separate Reserves/Distribution handlers.

## Task Commits

Each task was committed atomically:

1. **Task 1: Present quarantined history as explicitly read-only** - `fb55d4e` (fix)
2. **Task 2: Suspend only raid-history synchronization during quarantine** - `a331e24` (fix)

Verification repairs:

- `03381f8` - use the localized quarantine status without an English runtime fallback.
- `a87cb8b` - reset selections through the existing `Selection.EnsureState` public API.

## Files Created/Modified

- `Raid Management Addon/Controllers/Logger.lua` - Projects quarantine into the existing history panels and disables history actions.
- `Raid Management Addon/Database/DBSyncer.lua` - Rejects quarantined raid sync before transport, recovery, or persistence work.
- `tests/lua/harness/70_raid_sync.lua` - Covers read-only UI and fail-closed sync behavior.
- `tests/test_raid_replication_behavior.py` - Registers UI behavior and static ownership contracts.
- `tests/test_sync_communications_behavior.py` - Registers sync suspension and wire-preservation contracts.

## Decisions Made

- Reused the two existing panel empty-state labels; no screen, popup, repair UI, or persistence flag was added.
- Returned `L.RaidSyncStatusQuarantined` as the existing sync status reason so the failure is localized without changing the protocol.
- Kept quarantine admission inside `DBSyncer`; generic Comms, Reserves, and Distribution were not changed.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Removed a runtime English fallback rejected by localization policy**
- **Found during:** Final localization verification
- **Issue:** The initial sync guard used an English diagnostic fallback outside the locale catalog.
- **Fix:** Made `L.RaidSyncStatusQuarantined` the sole user-visible suspension reason.
- **Files modified:** `Raid Management Addon/Database/DBSyncer.lua`
- **Verification:** Focused localization fallback and quarantine-message contracts pass.
- **Committed in:** `03381f8`

**2. [Rule 1 - Bug] Replaced an absent selection API with the established reset contract**
- **Found during:** Final controller API inspection
- **Issue:** The first UI implementation called `UI.Selection.Clear`, which the public selection owner does not expose.
- **Fix:** Reused `UI.Selection.EnsureState`, the existing deterministic context reset operation.
- **Files modified:** `Raid Management Addon/Controllers/Logger.lua`, `tests/lua/harness/70_raid_sync.lua`
- **Verification:** Lua 5.1 lint and focused Logger ownership contract pass; source inspection confirms the public method exists.
- **Committed in:** `a87cb8b`

---

**Total deviations:** 2 auto-fixed bugs. **Impact on plan:** Both repairs were required for runtime correctness and localization compliance; no scope or protocol expansion.

## Issues Encountered

- No Lua 5.1-compatible executable is available on `PATH`. The complete unittest discovery ran 492 tests: 101 passed, 390 Lua-backed cases stopped at the explicit `lua command is not available on PATH` gate, and 1 was skipped. The two new Lua cases therefore require Lua 5.1 or in-game execution.

## User Setup Required

None - no external service configuration required.

## Verification

- Focused static quarantine ownership, wire boundary, and localization contracts: 4 passed.
- TOC validator: 0 errors, 0 warnings.
- Lua 5.1 validator: 146 addon and harness files clean.
- Variadic `xpcall` scanner: 137 addon files clean.
- XML handler scan: no layout script handlers.
- Final wire diff scan: no prefix, protocol-version, envelope, or payload-shape changes.
- `git diff --check`: clean.
- Lua-backed behavior execution: blocked only by the documented missing runner.

## Next Phase Readiness

- Phase 1 persistence consumers now fail closed from bootstrap through UI and raid-history synchronization.
- Phase 2 can proceed with canonical raid recognition without carrying unresolved persistence implementation work.
- Runtime login/reload, multi-client, combat, and taint behavior remains scheduled for the milestone in-game verification phase.

## Self-Check: PASSED

- All five required source/test files exist.
- Both task commits and both verification-repair commits are present in Git history.
- Static WotLK, localization, TOC, XML, wire, and Lua 5.1 checks pass.

---
*Phase: 01-persistence-safety*
*Completed: 2026-08-15*
