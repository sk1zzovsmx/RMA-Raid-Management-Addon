---
phase: 02-locale-independent-raid-recognition
plan: 04
subsystem: localization
tags: [wotlk-335a, localization, monster-yell, utf-8, sha-256]

requires:
  - phase: 02-locale-independent-raid-recognition
    provides: 60-row accepted monster-yell evidence matrix and canonical instance scopes
provides:
  - 60 evidence-bound non-English monster-yell scalar values
  - 15 English-owned fallback definitions with stable keys and canonical raid scope
  - static byte-length, digest, parity, and scope contracts
affects: [02-05, phase-4-localized-smoke-test]

tech-stack:
  added: []
  patterns: [English-owned fallback definitions, scalar locale overrides, exact UTF-8 digest enforcement]

key-files:
  created: []
  modified:
    - Raid Management Addon/Localization/localization.en.lua
    - Raid Management Addon/Localization/localization.ru.lua
    - Raid Management Addon/Localization/localization.zhCN.lua
    - Raid Management Addon/Localization/localization.es.lua
    - Raid Management Addon/Localization/localization.fr.lua
    - tests/test_localization_contract.py

key-decisions:
  - "Each fallback keeps its original English payload separately from the current-locale scalar and carries one canonical instance key."
  - "Only the 60 accepted evidence bytes are present in non-English catalogs; locale files remain scalar-only."

patterns-established:
  - "BossYellDefinitions owns fallback metadata in English while locale catalogs override only stable BossYell* scalars."
  - "Static tests recompute UTF-8 byte length and SHA-256 from decoded runtime strings before accepting catalog changes."

requirements-completed: [LOCL-01, LOCL-02]

duration: 7min
completed: 2026-08-15
---

# Phase 2 Plan 4: Evidence-bound localized yell catalogs Summary

**Fifteen scoped English fallback definitions and 60 exact non-English scalars now preserve the accepted source bytes under digest-enforced localization contracts.**

## Performance

- **Duration:** 7 min
- **Started:** 2026-08-15T09:35:00Z
- **Completed:** 2026-08-15T09:41:51Z
- **Tasks:** 2
- **Files modified:** 6

## Accomplishments

- Revalidated the prerequisite matrix at `accepted=60 unique=60 missing=0 conflicts=0 invalid=0` before editing any runtime locale catalog.
- Replaced the legacy English lookup table with exactly 15 English-owned definitions containing stable scalar keys, original English text, boss labels, and canonical raid scopes.
- Added exact `ruRU`, `zhCN`, `esES`, and `frFR` scalars whose UTF-8 lengths and SHA-256 digests match all 60 accepted evidence rows.
- Added fail-closed static contracts for evidence completeness, definition parity, catalog byte drift, scalar ownership, and forbidden display-name admission tables.

## Task Commits

Each task was committed atomically:

1. **Task 1: Add failing evidence-bound catalog and definition contracts** - `a65fde9` (test)
2. **Task 2: Add exact locale scalars and existing-fallback metadata** - `8222b99` (feat)

## Files Created/Modified

- `Raid Management Addon/Localization/localization.en.lua` - Original English scalars and the 15 canonical-scope fallback definitions.
- `Raid Management Addon/Localization/localization.ru.lua` - Fifteen exact `ruRU` evidence scalars.
- `Raid Management Addon/Localization/localization.zhCN.lua` - Fifteen exact `zhCN` evidence scalars.
- `Raid Management Addon/Localization/localization.es.lua` - Fifteen exact `esES` evidence scalars.
- `Raid Management Addon/Localization/localization.fr.lua` - Fifteen exact `frFR` evidence scalars, including source-significant non-breaking spaces.
- `tests/test_localization_contract.py` - Matrix parsing, digest verification, definition parity, and scalar-only ownership contracts.

## Decisions Made

- Retained the addon's existing English Algalon punctuation exactly; the evidence matrix is authoritative only for the four non-English catalogs in this plan.
- Stored `englishText` as the English scalar value captured when the English catalog loads, so later locale overrides remain independently available through `L[localeKey]`.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Command-token test misclassified exact yell text**
- **Found during:** Task 2 (full localization contract verification)
- **Issue:** The generic command-token test interpreted the letters `NE` inside English `RENEWED` as the Need command and incorrectly required those bytes in translated Valithria text.
- **Fix:** Excluded evidence-bound `BossYell*` scalars from command-token translation checks; their exact bytes are governed by the stricter matrix digest contract.
- **Files modified:** `tests/test_localization_contract.py`
- **Verification:** All 29 non-Lua localization tests pass, including the exact catalog digest cases.
- **Committed in:** `8222b99`

---

**Total deviations:** 1 auto-fixed bug.
**Impact on plan:** The correction removes a false-positive test without weakening yell validation or changing runtime scope.

## Issues Encountered

- The full localization module has one environment-only failure because no `lua` executable is available on PATH. The remaining 29 tests pass; Lua 5.1 static lint reports all 137 addon Lua files clean.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- Plan 02-05 can consume `L.BossYellDefinitions`, compare exact English/current-locale values, and enforce canonical instance scope.
- A localized WotLK client smoke test remains required in Phase 4 because static source evidence cannot prove the payload emitted by a particular private server.

## Self-Check: PASSED

- All five locale catalogs and both task commits exist.
- Evidence gate, 29 non-Lua localization tests, TOC validation, Lua 5.1 lint, `xpcall` scan, and `git diff --check` pass.
- No new encounter, `RaidZones` admission data, wire-format change, dependency, or vendored-library modification was introduced.

---
*Phase: 02-locale-independent-raid-recognition*
*Completed: 2026-08-15*
