# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-08-15)

**Core value:** Raid-critical data and workflows must remain correct, recoverable, and compatible on WotLK 3.3.5a clients.
**Current focus:** Phase 1 - Persistence Safety

## Current Position

Phase: 1 of 4 (Persistence Safety)
Plan: 0 of TBD in current phase
Status: Ready to plan
Last activity: 2026-08-15 - Roadmap created with complete v1 requirement coverage

Progress: [----------] 0%

## Performance Metrics

**Velocity:**
- Total plans completed: 0
- Average duration: -
- Total execution time: 0.0 hours

**By Phase:**

| Phase | Plans | Total | Avg/Plan |
|-------|-------|-------|----------|
| - | - | - | - |

**Recent Trend:**
- Last 5 plans: -
- Trend: -

*Updated after each plan completion*

## Accumulated Context

### Decisions

Decisions are logged in PROJECT.md Key Decisions table.
Recent decisions affecting current work:

- [Milestone]: Correct only demonstrated stabilization defects; no general refactors or new features.
- [Phase 1]: Preserve unsupported `RMA_Raids` values and fail closed through explicit quarantine.
- [Phase 2]: Canonical map-ID resolution is the only raid-admission source of truth.
- [Phase 3]: Add application-level request limits without changing version-5 wire formats.
- [Phase 4]: Manual in-game smoke tests are part of milestone acceptance.

### Pending Todos

None yet.

### Blockers/Concerns

- Lua-backed automated tests cannot run in the current Codex environment until a Lua 5.1-compatible executable is available; keep this environment limitation distinct from product failures.
- Combat lockdown, taint, localized-client behavior, SavedVariables reload, and multi-client synchronization require in-game verification.

## Session Continuity

Last session: 2026-08-15 01:19
Stopped at: Roadmap initialized; Phase 1 is ready for detailed planning.
Resume file: None
