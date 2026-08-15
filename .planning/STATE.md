---
gsd_state_version: 1.0
milestone: v1.0
milestone_name: milestone
status: executing
stopped_at: Completed 02-02-PLAN.md
last_updated: "2026-08-15T09:34:05.271Z"
last_activity: 2026-08-15 - Completed Phase 2 Plan 02 bounded unknown-raid recovery
progress:
  total_phases: 4
  completed_phases: 1
  total_plans: 8
  completed_plans: 6
  percent: 75
---

# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-08-15)

**Core value:** Raid-critical data and workflows must remain correct, recoverable, and compatible on WotLK 3.3.5a clients.
**Current focus:** Phase 2 - Locale-Independent Raid Recognition

## Current Position

Phase: 2 of 4 (Locale-Independent Raid Recognition)
Plan: 4 of 5
Status: Phase 2 in progress
Last activity: 2026-08-15 - Completed Phase 2 Plan 02 bounded unknown-raid recovery

Progress: [████████░░] 75%

## Performance Metrics

**Velocity:**
- Total plans completed: 6
- Average duration: 13 min
- Total execution time: 1.3 hours

**By Phase:**

| Phase | Plans | Total | Avg/Plan |
|-------|-------|-------|----------|
| Phase 01 | 3 | 30 min | 10 min |
| Phase 02 | 3 | 47 min | 16 min |

**Recent Trend:**
- Last 5 plans: 8 min, 12 min, 20 min, 17 min, 10 min
- Trend: Phase 2 admission, bounded recovery, and evidence foundations completed

*Updated after each plan completion*
| Phase 01 P03 | 12min | 2 tasks | 5 files |
| Phase 02 P01 | 20min | 2 tasks | 7 files |
| Phase 02 P03 | 17min | 2 tasks | 1 files |
| Phase 02 P02 | 10min | 2 tasks | 11 files |

## Accumulated Context

### Decisions

Decisions are logged in PROJECT.md Key Decisions table.
Recent decisions affecting current work:

- [Milestone]: Correct only demonstrated stabilization defects; no general refactors or new features.
- [Phase 1]: Preserve unsupported `RMA_Raids` values and fail closed through explicit quarantine.
- [Phase 2]: Canonical map-ID resolution is the only raid-admission source of truth.
- [Phase 3]: Add application-level request limits without changing version-5 wire formats.
- [Phase 4]: Manual in-game smoke tests are part of milestone acceptance.
- [Phase 01]: Only nil RMA_Raids initializes a canonical archive; every non-nil value is preserved for validation. — Unknown, future, malformed, and incorrectly typed SavedVariables must remain recoverable.
- [Phase 01]: The store-facing archive error is a stable quarantine category; validator detail remains separate and transient. — DBRaidStore needs a stable fail-closed reason while bootstrap diagnostics need non-user-facing detail.
- [Phase 01]: Bootstrap stores only stable archive category and optional format version in transient addon.State. — Validator detail remains debug-only and no quarantine flag is persisted.
- [Phase 01]: Emit the localized quarantine warning only after degraded bootstrap commits successfully. — Unrelated features initialize normally and blocked history operations do not repeat the global warning.
- [Phase 01]: Loot History stays open with a localized quarantine label while every history action and selection is disabled. — Quarantine must be visibly different from empty history without adding repair or destructive UI.
- [Phase 01]: DBSyncer rejects quarantine before protocol, session, recovery, import, or store work. — A peer must never replace an incompatible archive and unrelated sync owners must remain independent.
- [Phase 02]: Canonical identity remains transient and Raid-owned while persisted zone names and wire payloads remain unchanged. — Locale-independent admission must not migrate history or change compatibility contracts.
- [Phase 02]: The first recognized context after reload binds the current raid without rewriting its saved zone. — Historical localized names remain stable while subsequent same-instance checks use canonical identity.
- [Phase 02]: Only the 60 byte-exact accepted BroadcastText payloads may feed runtime locale catalogs. — Functional exact matching cannot tolerate guessed translations or punctuation normalization.
- [Phase 02]: Direct locale discrepancies require an exact same-ID client-derived source before acceptance. — Numeric provenance and digest agreement resolve invisible punctuation or stale direct-row conflicts without judgment.
- [Phase 02]: Unknown raid warning dedupe is transient Init state keyed by received map ID and display name. — This prevents overlapping entry events and bounded retries from spamming while allowing a fresh warning after recognized or non-raid transitions.
- [Phase 02]: Session owns the bounded timer cadence while Init owns every retry refresh and dataset activation. — This preserves module ownership and avoids recursive scheduling or a new polling mechanism.

### Pending Todos

None yet.

### Blockers/Concerns

- Lua-backed automated tests cannot run in the current Codex environment until a Lua 5.1-compatible executable is available; keep this environment limitation distinct from product failures.
- Combat lockdown, taint, localized-client behavior, SavedVariables reload, and multi-client synchronization require in-game verification.

## Session Continuity

Last session: 2026-08-15T09:34:05.269Z
Stopped at: Completed 02-02-PLAN.md
Resume file: None
