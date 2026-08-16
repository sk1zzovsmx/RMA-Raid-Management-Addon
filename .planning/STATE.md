---
gsd_state_version: 1.0
milestone: v1.1
milestone_name: UI Simplification
status: planning
stopped_at: Phase 7 context gathered
last_updated: "2026-08-16T17:39:22.869Z"
last_activity: 2026-08-16 - Phase 7 context gathered
progress:
  total_phases: 3
  completed_phases: 2
  total_plans: 16
  completed_plans: 16
  percent: 100
---

# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-08-16)

**Core value:** Raid-critical data and workflows must remain correct, recoverable, and compatible on WotLK 3.3.5a clients.
**Current focus:** Plan Phase 7 UI Simplification Verification

## Current Position

Phase: 7 of 7 (UI Simplification Verification)
Plan: Not started
Status: Ready to plan
Last activity: 2026-08-16 - Phase 7 context gathered

Progress: [██████████] 100%

## Performance Metrics

**Velocity:**
- Total plans completed: 16
- Average duration: 15 min
- Total execution time: 4.0 hours

**By Phase:**

| Phase | Plans | Total | Avg/Plan |
|-------|-------|-------|----------|
| Phase 01 | 3 | 30 min | 10 min |
| Phase 02 | 5 | 62 min | 12 min |
| Phase 03 | 2 | 23 min | 12 min |
| Phase 04 | 2 | 90 min | 45 min |
| Phase 05 | 1 | 12 min | 12 min |
| Phase 06 | 3 | 27 min | 9 min |

**Recent Trend:**
- Last 5 plans: 6 min, 12 min, 7 min, 12 min, 8 min
- Trend: Phase 6 complete; focused list ownership and compatibility gates are green

*Updated after each plan completion*
| Phase 01 P03 | 12min | 2 tasks | 5 files |
| Phase 02 P01 | 20min | 2 tasks | 7 files |
| Phase 02 P03 | 17min | 2 tasks | 1 files |
| Phase 02 P02 | 10min | 2 tasks | 11 files |
| Phase 02 P04 | 7min | 2 tasks | 6 files |
| Phase 02 P05 | 8min | 2 tasks | 4 files |
| Phase 03 P01 | 12min | 2 tasks | 4 files |
| Phase 03 P02 | 11min | 2 tasks | 3 files |
| Phase 04 P01 | 84min | 3 tasks | 6 files |
| Phase 04 P02 | 6min | 2 tasks | 1 files |
| Phase 05 P01 | 12min | 3 tasks | 8 files |
| Phase 06 P01 | 7 min | 2 tasks | 3 files |
| Phase 06 P02 | 12 min | 2 tasks | 3 files |
| Phase 06 P03 | 8 min | 2 tasks | 3 files |

## Accumulated Context

### Decisions

Decisions are logged in PROJECT.md Key Decisions table.
Recent decisions affecting current work:

- [Milestone]: Correct only demonstrated stabilization defects; no general refactors or new features.
- [Milestone v1.1]: Sequence bounded dead-path cleanup before Logger/Attendance primitive consolidation, then run one compatibility verification phase.
- [Milestone v1.1]: Keep shared UI scope limited to demonstrated calculated-width, header, row, title, and sort-binding primitives; do not introduce a framework or DSL.
- [Phase 1]: Preserve unsupported `RMA_Raids` values and fail closed through explicit quarantine.
- [Phase 2]: Canonical map-ID resolution is the only raid-admission source of truth.
- [Phase 3]: Add application-level request limits without changing version-5 wire formats.
- [Phase 4]: QUAL-03 closes through an accepted AUTOMATED/OBSERVED/DEFERRED disposition; deferred live risks are not treated as passed.
- [Phase 04]: Branding acceptance asserts authoritative current RMA identity only; unavailable pre-normalization identifiers are not invented or claimed as scanned.
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
- [Phase 02]: English yell fallback definitions retain original text separately from current-locale scalars and carry one canonical raid scope. — Exact English acceptance and localized acceptance must coexist without display-name admission or persisted schema changes.
- [Phase 02]: Non-English yell catalogs bind only the 60 accepted evidence bytes and remain scalar-only. — Exact matching makes punctuation, whitespace, and Unicode byte drift correctness-relevant.
- [Phase 02]: Monster-yell fallback requires exact English or current-locale text in the active canonical raid. — Exact matching prevents ambiguous cross-instance boss records without changing combat-log detection or compatibility contracts.
- [Phase 03]: Reserve response admission uses one sender-keyed owner-local map with independent META_REQ and DATA_REQ state under each canonical sender. — The normal metadata-then-data flow stays immediate while the reserve service retains one literal 128-sender bound.
- [Phase 03]: Capacity rejection fails closed without eviction and debug deduplication stays inside admitted kind state. — Active protection cannot be displaced by sender churn and no overflow or diagnostic table can exceed the service bound.
- [Phase 03]: Distribution response admission owns one sender-keyed transient map and never shares reserve or raid-history admission state. — Owner independence keeps each literal 128-sender bound isolated and avoids a shared communication abstraction.
- [Phase 03]: Raw sender membership is re-evaluated before lowercase short-name admission. — Authorization behavior remains unchanged while case and realm aliases share one transient cooldown.
- [Phase 05]: Internal ScreenNotice events are the sole notice invocation path; no compatibility export was retained. — The removed direct export had no repository consumer and the internal event already owns behavior.
- [Phase 05]: Trade mutable state remains accessible only through Trade-owned operations and the private ensureState helper. — Observable Trade contracts do not require exposing mutable runtime state.
- [Phase 05]: Database.EnsureLootRuntimeState calls ContextState.SyncRuntimeState directly at the established bootstrap point. — The same-file state owner preserves normalization without an unconsumed service forwarder.
- [Phase 06]: Every list geometry value and binding flag remains caller-supplied; addon.UI.Lists adds no visual defaults or orchestration layer. — The phase shares only proven mechanics while controllers retain presentation policy.
- [Phase 06]: CalculateColumnWidths retains its pairs-derived variable-key ordering and remainder distribution. — Numeric parity is compatibility-sensitive and sorting would change current Logger and Attendance results.
- [Phase 06]: Logger retains all feature presentation policy while addon.UI.Lists performs only extracted mechanics. — This preserves Source behavior, geometry, localization, sorting, and existing refresh ownership.
- [Phase 06]: The Logger controller regression composes real shared primitives with the lightweight controller fixture. — Plan 01 already protects the width algorithm; plan 02 verifies controller integration without duplicating it.
- [Phase 06]: Attendance retains all feature presentation policy while addon.UI.Lists performs only extracted mechanics. — This preserves descriptors, sorting, context and empty-state selection, loot-ban adjustment, Spec/Inspect rendering, and Force Inspect ownership.
- [Phase 06]: Attendance supplies every geometry and presentation choice explicitly to the shared operations. — No hidden defaults, wrapper layer, cache, listener, timer, or polling path is justified.

### Pending Todos

None yet.

### Blockers/Concerns

- No v1.1 roadmap or phase-planning blocker is known.
- No v1.0 milestone completion blocker remains under the approved QUAL-03 contract.
- Accepted residual risks remain for unexecuted SavedVariables quarantine/recovery, localized/multi-client sync, combat protected-action behavior, and taint checks.

## Session Continuity

Last session: 2026-08-16T17:39:22.867Z
Stopped at: Phase 7 context gathered
Resume file: .planning/phases/07-ui-simplification-verification/07-CONTEXT.md
