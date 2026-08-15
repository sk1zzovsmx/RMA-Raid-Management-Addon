---
phase: 02-locale-independent-raid-recognition
plan: 02
subsystem: raid-runtime
tags: [wotlk-335a, lua-51, raid-session, bounded-retry, localization]

requires:
  - phase: 02-locale-independent-raid-recognition
    provides: canonical transient raid identity and Init-owned dataset activation from Plan 02-01
provides:
  - Existing bounded raid retries re-enter the canonical Init resolver and transactional dataset activation
  - Unknown raid transitions clear stale context and emit one localized warning per entry identity
  - Received instance name, map ID, and difficulty remain debug-only diagnostics
affects: [02-04, 02-05, raid-session, localization]

tech-stack:
  added: []
  patterns:
    - Init passes a narrow refresh callback into the existing Raid timer cadence
    - Entry events may warn once while delayed retries always execute in no-warning mode

key-files:
  created: []
  modified:
    - Raid Management Addon/Init.lua
    - Raid Management Addon/Services/Raid/Session.lua
    - Raid Management Addon/Localization/DiagnoseLog.en.lua
    - Raid Management Addon/Localization/localization.en.lua
    - Raid Management Addon/Localization/localization.ru.lua
    - Raid Management Addon/Localization/localization.zhCN.lua
    - Raid Management Addon/Localization/localization.es.lua
    - Raid Management Addon/Localization/localization.fr.lua
    - tests/lua/harness/30_raid_runtime.lua
    - tests/test_runtime_foundations_behavior.py
    - tests/test_localization_contract.py

key-decisions:
  - "Unknown-instance warning dedupe is transient Init state keyed by received map ID and display name; recognized and non-raid transitions reset it."
  - "Only entry and zone-change paths may emit the player warning; retry callbacks re-enter coordination in explicit no-warning and no-reschedule mode."

patterns-established:
  - "Bounded recovery: Session owns timer cadence while Init owns every fresh instance read, resolver call, and dataset activation."
  - "Diagnostic separation: the scalar addon.L warning has no placeholders; received technical values use addon.Diagnose only."

requirements-completed: [RAID-02, RAID-03, LOCL-02]

duration: 10min
completed: 2026-08-15
---

# Phase 2 Plan 2: Bounded Unknown-Raid Recovery Summary

**The existing 0.3–3.5 second raid retry cadence now re-enters canonical instance coordination, recovers delayed map IDs, and keeps unsupported-entry warnings localized and deduplicated.**

## Performance

- **Duration:** 10 min
- **Started:** 2026-08-15T09:23:00Z
- **Completed:** 2026-08-15T09:33:12Z
- **Tasks:** 2
- **Files modified:** 11

## Accomplishments

- Routed each existing delayed Session callback through Init-owned `GetInstanceInfo`, canonical resolution, and transactional dataset activation without recursive scheduling or `OnUpdate`.
- Cleared stale recognized context on unsupported transitions, deduplicated overlapping entry events, and reset warning eligibility after recognized or non-raid transitions.
- Added one concise, placeholder-free warning to all five supported catalogs while keeping received name, map ID, and difficulty in a debug diagnostic.

## Task Commits

Each task was committed atomically:

1. **Task 1: Re-enter canonical coordination from bounded retries and dedupe unknown warnings** - `fa0df7a` (fix)
2. **Task 2: Localize the concise unknown-instance warning on every supported locale** - `00656b5` (feat)

## Files Created/Modified

- `Raid Management Addon/Init.lua` - Owns retry coordination, stale-state clearing, warning dedupe, and diagnostic separation.
- `Raid Management Addon/Services/Raid/Session.lua` - Invokes the supplied Init refresh operation from the existing bounded timers.
- `Raid Management Addon/Localization/DiagnoseLog.en.lua` - Defines the debug-only unknown-instance detail template.
- `Raid Management Addon/Localization/localization.*.lua` - Provides the scalar unsupported-instance warning in every supported locale.
- `tests/lua/harness/30_raid_runtime.lua` - Covers recognized-to-unknown clearing, overlapping events, leave/re-entry, no warning spam, and delayed map-ID recovery.
- `tests/test_runtime_foundations_behavior.py` - Registers the Lua case and static coordinator/no-`OnUpdate` contract.
- `tests/test_localization_contract.py` - Enforces warning parity and rejects technical placeholders.

## Decisions Made

- Kept retry scheduling in the Raid service and passed only a per-batch callback, preserving module ownership without adding a new scheduler.
- Used received map ID plus display name as the dedupe identity because these are the exact facts available before canonical recognition.

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

- The environment has no Lua or LuaJIT executable, so the new Lua behavior case remains runner-blocked. Six focused static contracts pass; addon and harness Lua 5.1 lint, the `xpcall` scan, TOC validation, XML handler scan, and `git diff --check` are clean.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- Exact localized yell metadata can now rely on a stable canonical active-instance context.
- The registered retry behavior still requires the milestone's WotLK 3.3.5a in-game smoke test.

## Self-Check: PASSED

- Summary exists and both `02-02` task commits are present.
- Focused static contracts and all available WotLK validators pass; Lua runtime execution is explicitly recorded as environment-blocked.

---
*Phase: 02-locale-independent-raid-recognition*
*Completed: 2026-08-15*
