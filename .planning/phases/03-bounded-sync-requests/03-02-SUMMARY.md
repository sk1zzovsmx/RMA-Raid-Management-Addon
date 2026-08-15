---
phase: 03-bounded-sync-requests
plan: 02
subsystem: loot-distribution-sync
tags: [wotlk-335a, lua-51, rate-limit, bounded-state, r5-wire]

requires:
  - phase: 03-bounded-sync-requests
    provides: reserve request admission and the shared debug-only rejection diagnostic from Plan 03-01
provides:
  - Per-canonical-sender distribution SNAP_REQ response admission
  - Inclusive five-second cooldowns with a 128-sender distribution-owner bound
  - Pre-PublishSnapshot rejection and cross-owner R5 compatibility coverage
affects: [phase-3-verification, phase-4-milestone-verification]

tech-stack:
  added: []
  patterns: [owner-local transient admission map, lazy exact-boundary pruning, pre-snapshot work gate]

key-files:
  created: []
  modified:
    - Raid Management Addon/Services/Loot/DistributionSession.lua
    - tests/lua/harness/10_loot_distribution.lua
    - tests/test_loot_distribution_hardening_behavior.py

key-decisions:
  - "Distribution response admission owns one sender-keyed transient map and never shares reserve or raid-history admission state."
  - "Raw sender membership is re-evaluated before lowercase short-name admission, while response targeting and version-5 envelopes remain unchanged."

patterns-established:
  - "Admit a validated and authorized SNAP_REQ immediately before PublishSnapshot so rejection performs no snapshot, serialization, chunk, or queue work."
  - "Fail closed at 128 active canonical senders without eviction; keep debug deduplication inside the admitted sender-kind state."

requirements-completed: [COMM-02, COMM-03, COMM-04]

duration: 11min
completed: 2026-08-15
---

# Phase 3 Plan 2: Bounded distribution snapshot requests Summary

**Distribution snapshot responses now admit one valid request per canonical sender every five seconds, with a 128-sender owner bound, zero rejected response work, and unchanged RMADist version-5 behavior.**

## Performance

- **Duration:** 11 min
- **Started:** 2026-08-15T11:57:31Z
- **Completed:** 2026-08-15T12:08:19Z
- **Tasks:** 2
- **Files modified:** 3

## Accomplishments

- Added a distribution-owned transient admission map capped at 128 active lowercase short-name senders, with inclusive five-second lazy expiry and no active-entry eviction.
- Rejected cooldown, invalid-identity, and capacity requests before `PublishSnapshot`, snapshot serialization, chunk construction, or direct/batch transport work.
- Preserved raw-sender membership checks, valid no-publish consumption, the `RMADist` prefix, protocol version 5, request IDs, response targets, `SNAP` and `SNAP_CHUNK` bodies, and `NORMAL` priority.
- Added focused behavior coverage for aliases, non-extending replays, exact expiry, malformed and unauthorized non-consumption, authorization leave/re-entry, debug deduplication, owner independence, and map capacity.

## Task Commits

Each task was committed atomically:

1. **Task 1: Specify the distribution snapshot admission boundary before runtime changes** - `11b130d` (test)
2. **Task 2: Admit distribution snapshot requests before PublishSnapshot** - `b8d6b8b` (fix)

## Files Created/Modified

- `Raid Management Addon/Services/Loot/DistributionSession.lua` - Owner-local admission constants, bounded transient state, lazy pruning, debug dedupe, and the pre-`PublishSnapshot` guard.
- `tests/lua/harness/10_loot_distribution.lua` - Response-work instrumentation and the complete inbound distribution admission behavior matrix.
- `tests/test_loot_distribution_hardening_behavior.py` - Focused Python registration for the new Lua behavior case.

## Decisions Made

- Reproduced the small bounded timestamp-map pattern inside the distribution owner instead of adding a shared limiter or referencing reserve/DBSync state.
- Used lowercase `Comms.NormalizeSender(rawSender)` only for admission identity; group membership continues to receive the original sender on every request.
- Kept capacity overflow silent because an unseen sender cannot receive a dedupe entry without breaking the hard state bound.

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

- The planned `lua`, `python`, and `py` command aliases were unavailable. The installed LuaJIT runtime at `C:\tools\LuaJIT\bin\luajit.exe` supplied Lua 5.1-compatible RED/GREEN execution, and the bundled Codex Python runtime executed the exact unittest registrations through a temporary external `lua.exe` hard-link alias. The RED case failed for the expected second `PublishSnapshot` entry; GREEN and all 114 owner tests passed.
- The generic GSD `state advance-plan` helper could not parse this repository's `Plan: 2 of 2` STATE format. The remaining prescribed progress, metric, decision, and session helpers succeeded; current-position fields were updated directly and Phase 3 was left awaiting its configured verifier. Its Windows commit wrapper also split the multiword metadata message, so the already staged metadata files were committed with direct Git.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- Both Phase 3 owner implementations and all COMM-01 through COMM-04 regression contracts are present and automated checks pass.
- Phase 3 remains in progress pending the configured verifier; multi-client and in-game compatibility checks remain scheduled for Phase 4.

## Self-Check: PASSED

- Both task commits and all three planned file changes exist.
- RED produced the expected missing-admission assertion against the unmodified distribution runtime; GREEN passes both focused owner cases and their Python registrations.
- The complete synchronization and loot-distribution owner suites pass 114 tests under LuaJIT.
- TOC validation, addon Lua 5.1 lint, variadic-`xpcall` scan, XML-handler search, no-new-timer search, and committed diff checks are clean.
- No prefix, wire version, payload, authorization, SavedVariable, timer, ticker, `OnUpdate`, shared admission module, reserve runtime, TOC, or vendored-library change was introduced.

---
*Phase: 03-bounded-sync-requests*
*Completed: 2026-08-15*
