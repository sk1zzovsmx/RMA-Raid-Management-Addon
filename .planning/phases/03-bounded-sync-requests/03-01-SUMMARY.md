---
phase: 03-bounded-sync-requests
plan: 01
subsystem: reserve-sync
tags: [wotlk-335a, lua-51, rate-limit, bounded-state, r5-wire]

requires:
  - phase: 02-locale-independent-raid-recognition
    provides: stable raid runtime and completed localization corrections
provides:
  - Per-canonical-sender and per-request-kind reserve response admission
  - Inclusive five-second cooldowns with a 128-sender service-wide bound
  - Pre-construction rejection and debug-only deduplication without R5 wire changes
affects: [03-02, phase-4-multi-client-sync-verification]

tech-stack:
  added: []
  patterns: [owner-local transient admission map, lazy exact-boundary pruning, pre-response work gate]

key-files:
  created: []
  modified:
    - Raid Management Addon/Services/Reserves/Sync.lua
    - Raid Management Addon/Localization/DiagnoseLog.en.lua
    - tests/lua/harness/50_reserves_messaging.lua
    - tests/test_sync_communications_behavior.py

key-decisions:
  - "Reserve response admission uses one sender-keyed owner-local map with independent META_REQ and DATA_REQ state under each canonical sender."
  - "The 128-sender hard bound fails closed without eviction; debug deduplication lives only inside an already admitted kind state."

patterns-established:
  - "Validate and authorize from the raw sender before admission, then gate immediately before response construction."
  - "Lowercase Comms.NormalizeSender output only for admission identity while preserving existing response targets and R5 envelopes."

requirements-completed: [COMM-01, COMM-03, COMM-04]

duration: 12min
completed: 2026-08-15
---

# Phase 3 Plan 1: Bounded reserve response requests Summary

**Reserve metadata and data responses now admit one valid request per canonical sender and kind every five seconds, with zero rejected-response work and unchanged version-5 behavior.**

## Performance

- **Duration:** 12 min
- **Started:** 2026-08-15T11:39:23Z
- **Completed:** 2026-08-15T11:51:11Z
- **Tasks:** 2
- **Files modified:** 4

## Accomplishments

- Added one transient reserve-owned map capped at 128 active canonical senders, with independent `META_REQ` and `DATA_REQ` timestamps and inclusive lazy expiry.
- Rejected aliases, active cooldowns, and capacity overflow before payload projection, response serialization, chunk construction, or direct/batch queue work.
- Preserved raw-sender authorization checks, normal metadata-then-data flow, the `RMAResSync` prefix, version 5 envelopes, request IDs, targets, bodies, and queue priorities.
- Added focused behavior coverage for malformed and unauthorized non-consumption, no-data consumption, debug deduplication, non-extending replays, exact expiry, and no-eviction capacity behavior.

## Task Commits

Each task was committed atomically:

1. **Task 1: Specify the reserve request admission boundary before runtime changes** - `aeedc4b` (test)
2. **Task 2: Admit reserve requests in the owner before response construction** - `cb734bc` (fix)

## Files Created/Modified

- `Raid Management Addon/Services/Reserves/Sync.lua` - Owner-local admission constants, bounded transient state, lazy pruning, debug dedupe, and pre-response guards.
- `Raid Management Addon/Localization/DiagnoseLog.en.lua` - Shared ASCII debug template for request-rate rejection.
- `tests/lua/harness/50_reserves_messaging.lua` - Real-owner fixture counters and the full inbound reserve admission behavior matrix.
- `tests/test_sync_communications_behavior.py` - Focused Python registration for the new Lua behavior case.

## Decisions Made

- Kept the two reserve request-kind budgets nested under one normalized sender entry so the normal `META_REQ` then `DATA_REQ` exchange remains immediate without doubling service capacity.
- Used lowercase `Comms.NormalizeSender(rawSource)` only as the transient admission key; membership continues to receive the original sender and response targeting continues to use the existing normalized display value.
- Kept capacity rejection silent because an unseen overflow sender cannot receive a debug-dedupe entry without violating the hard memory bound.

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

- The configured `lua` command and repository virtualenv were unavailable, but an existing LuaJIT runtime compatible with Lua 5.1 was found at `C:\tools\LuaJIT\bin\luajit.exe`. The committed RED snapshot then failed on the expected alias-replay payload-work assertion, and the GREEN worktree passed the same case. A temporary PATH alias also let the exact Python method and all 56 synchronization communication tests run successfully.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- Plan 03-02 can reproduce the same small owner-local algorithm for distribution `SNAP_REQ` while reusing `LogSyncRequestRateLimited`.
- Reserve behavior is covered by the focused case and the complete 56-test synchronization module; multi-client in-game verification remains scheduled for Phase 4.

## Self-Check: PASSED

- Both task commits and all four planned file changes exist.
- RED failed against the unmodified runtime for missing admission; GREEN, the four adjacent reserve cases, and all 56 synchronization communication tests pass under LuaJIT.
- TOC validation, addon and harness Lua 5.1 lint, variadic-`xpcall` scan, XML-handler search, no-new-timer search, and `git diff --check` are clean.
- No prefix, wire version, payload, authorization, SavedVariable, timer, ticker, `OnUpdate`, shared admission module, TOC, or vendored-library change was introduced.

---
*Phase: 03-bounded-sync-requests*
*Completed: 2026-08-15*
