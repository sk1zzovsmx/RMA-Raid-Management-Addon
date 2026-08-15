---
phase: 02-locale-independent-raid-recognition
plan: 03
subsystem: localization-evidence
tags: [wotlk-335a, localization, broadcast-text, utf-8, provenance]

requires:
  - phase: 02-locale-independent-raid-recognition
    provides: fixed 15-entry yell fallback key list and canonical instance scopes
provides:
  - 60/60 exact non-English monster-yell evidence matrix
  - pinned numeric-key provenance with UTF-8 length and SHA-256 per payload
  - reproducible fail-closed acceptance command for downstream locale binding
affects: [02-04, 02-05, phase-4-localized-smoke-test]

tech-stack:
  added: []
  patterns: [numeric BroadcastTextId provenance, exact UTF-8 payload hashing, fail-closed locale evidence gate]

key-files:
  created:
    - .planning/phases/02-locale-independent-raid-recognition/02-YELL-EVIDENCE.md
  modified: []

key-decisions:
  - "CMaNGOS BroadcastTextId rows are the primary exact payload evidence; AzerothCore direct rows are cross-checked wherever present."
  - "A direct-row disagreement is accepted only when AzerothCore broadcast_text_locale at the pinned SHA matches the primary bytes for the same numeric ID."
  - "Plan 02-04 may bind only the 60 accepted byte-exact strings; guessed or normalized text remains forbidden."

patterns-established:
  - "Locale evidence rows carry source SHA/path, numeric key, payload field, VerifiedBuild, UTF-8 length, digest, and exact text."
  - "Invisible punctuation differences such as NBSP are correctness-relevant and are resolved by digest, not visual similarity."

requirements-completed: [LOCL-01]

duration: 17min
completed: 2026-08-15
---

# Phase 2 Plan 3: Monster-yell locale evidence Summary

**Pinned CMaNGOS and AzerothCore data now proves 60 exact non-English yell payloads with a reproducible zero-missing, zero-conflict acceptance gate.**

## Performance

- **Duration:** 17 min
- **Started:** 2026-08-15T09:05:00Z
- **Completed:** 2026-08-15T09:22:10Z
- **Tasks:** 2
- **Files modified:** 1

## Accomplishments

- Extracted all 15 BroadcastTextIds for `ruRU`, `zhCN`, `esES`, and `frFR` from a pinned CMaNGOS WotLK database revision.
- Recorded the exact UTF-8 text, byte length, SHA-256, numeric creature/text provenance, payload field, build marker, and cross-source status for all 60 rows.
- Compared 18 encounter/locale candidates from AzerothCore direct creature-text data: 15 matched directly and three were resolved by exact same-ID AzerothCore broadcast rows.
- Added and executed a standalone acceptance command reporting `accepted=60 unique=60 missing=0 conflicts=0 invalid=0`.
- Documented the existing Algalon English period-versus-hyphen discrepancy without altering runtime text.

## Task Commits

Each task was committed atomically:

1. **Task 1: Extract all keyed locale rows from pinned client-derived sources** - `593cda7` (docs)
2. **Task 2: Enforce the hard 60/60 acceptance gate** - `1cc12bc` (test)

## Files Created/Modified

- `.planning/phases/02-locale-independent-raid-recognition/02-YELL-EVIDENCE.md` - Auditable exact-text matrix, discrepancy resolutions, pinned source metadata, and executable acceptance check.

## Decisions Made

- Used the non-empty gender-specific BroadcastText payload exactly as stored; no case, punctuation, whitespace, or typography normalization was applied.
- Treated absent AzerothCore direct rows as permissible primary-only evidence because the plan requires that cross-check only where a direct row exists.
- Resolved Thorim `zhCN`, Algalon `frFR`, and Valithria `frFR` only after the same BroadcastTextId in AzerothCore `broadcast_text_locale.sql` matched the CMaNGOS bytes and digest.

## Deviations from Plan

None - the third pinned AzerothCore broadcast table was acquired through the plan's explicit conflict-resolution path, and no runtime or localization scope was added.

## Issues Encountered

- Three AzerothCore direct creature-text rows disagreed with the primary source. The two French differences were ordinary spaces versus non-breaking spaces; the Thorim Chinese row contained another sentence. All were resolved by an exact same-ID match in the pinned AzerothCore client-derived broadcast table.
- The temporary source files were tens of megabytes and contained large multi-row SQL statements; extraction used targeted numeric-key regexes rather than loading source material into the repository.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- Plan 02-04 has a complete byte-exact source matrix and may bind only these accepted strings to locale catalogs.
- Phase 4 still needs the planned in-game localized-client smoke check because static evidence cannot observe a specific private server's emitted event payload.

## Self-Check: PASSED

- Evidence artifact exists and contains 60 accepted rows.
- Commits `593cda7` and `1cc12bc` exist in Git history.
- No addon runtime, locale catalog, TOC, SavedVariables, or wire-format file was changed by this plan.

---
*Phase: 02-locale-independent-raid-recognition*
*Completed: 2026-08-15*
