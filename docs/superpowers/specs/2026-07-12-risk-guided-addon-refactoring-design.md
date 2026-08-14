# Risk-Guided Addon Refactoring Design

## Objective

Review and progressively refactor the entire Raid Management Addon from its
current state. The work may include bug fixes and focused UX improvements when
the review provides concrete evidence for them.

Priorities, in order, are:

1. Runtime reliability and data integrity.
2. Architectural maintainability.
3. Performance.
4. Raid workflow UX.

This is not `GREENFIELD_REWRITE`. Existing external contracts remain stable
unless a behavior is demonstrated to be broken, unsafe, confusing, or obsolete
and the change is recorded as an explicit behavior delta.

## Baseline And Scope

The current branch and working tree are the baseline. Existing uncommitted
README changes must be preserved and must not be folded into unrelated commits.
The initial automated baseline is 56 passing Python tests.

The review covers all first-party runtime Lua, XML layout, TOC load order,
tests, and maintained project documentation. Vendored libraries under `Libs/`
remain out of scope. WotLK 3.3.5a, Interface `30300`, and Lua 5.1 compatibility
are binding constraints.

## Delivery Strategy

Work proceeds through small, risk-ordered vertical slices. A slice follows a
runtime or product flow from its WoW event or `/rma` entry point through domain
services and persistence to its UI projection and tests. The repository must
remain coherent and verifiable at the end of every slice.

The planned order is:

1. Runtime and data foundations: bootstrap, SavedVariables, options, schemas,
   RMA migrations, raid storage, and persisted invariants.
2. Raid recording: raid state, sessions, roster, attendance, logger, and record
   reconciliation.
3. Loot distribution: loot state, rolls, winner selection, awards, trades, and
   final defenses before WoW effects.
4. Communications: prefixes, authorization, chunking, rate limiting,
   versioning, and payload import.
5. Supporting features: reserves, warnings, spammer, inspection, and datasets.
6. UI composition: oversized controllers, widgets, event-driven refresh,
   frame ownership, and interaction consistency.

Each slice follows this sequence:

1. Map ownership, callers, data flow, effects, and current tests.
2. Establish or strengthen behavior-focused tests for important invariants.
3. Fix demonstrated reliability or data-integrity defects.
4. Consolidate ownership, duplicated logic, and accidental internal APIs.
5. Apply measured performance improvements.
6. Apply narrowly scoped UX improvements that support the same workflow.
7. Reconcile documentation, TOC entries, tests, and validation evidence.

## Architecture And Ownership

The existing product-oriented layers remain the starting architecture:

- `Init.lua` owns bootstrap and top-level event wiring.
- `Database/*` owns persistence contracts and SavedVariables access.
- `Modules/*` owns shared runtime infrastructure and static data.
- `Services/*` owns domain and runtime logic.
- `Controllers/*` owns top-level feature composition and frames.
- `Widgets/*` owns feature UI components without persistence ownership.
- `EntryPoints/*` owns slash-command and minimap entry points.
- `UI/*` owns static XML layout only.

Refactoring is cohesion-first. Files are not split or merged based on size
alone. A boundary is retained or introduced only when it owns a durable
concept, policy, data shape, integration boundary, UI composition role, or
testable algorithm. Pass-through wrappers and generic catch-all helpers are
candidates for removal when callers can bind safely to the concrete owner.

Services must not call controllers or depend on frame-specific behavior.
Controllers and widgets must not mutate persistence directly. Commands and
queries use direct owner calls; the event bus reports completed state changes
or one-way UI requests.

## Data Integrity Contracts

- SavedVariables contain canonical restore-critical data only. Runtime caches,
  indexes, and projections are derived after loading.
- Each persisted structure has one clear mutation owner.
- Inputs are validated before canonical state changes.
- Multi-record changes are atomic from the perspective of runtime callers.
- Cross-session references use stable identifiers rather than volatile array
  positions.
- Bootstrap, RMA schema migrations, and any explicitly requested non-RMA import
  remain separate workflows.
- No non-RMA SavedVariable is read, migrated, or written during startup.

Loot and trade flows separate planning, final validation, and the WoW effect.
Permissions, target eligibility, loot bans, item availability, and relevant
session state are rechecked immediately before the effect. Logger
reconciliation between Master Loot, trades, Group Loot, and synchronization is
deterministic and avoids duplicate canonical records.

Incoming synchronization data remains untrusted until sender authorization,
protocol version, schema, raid context, and size limits have all been validated.
Wire-format changes require explicit versioning and compatibility analysis.

## Error Handling

Recoverable failures return `nil, "reason"` or `false` with a stable reason that
can be localized at the appropriate UI boundary. Effect-producing operations
use the order: validate fully, mutate canonical state, then publish the
completed-state notification.

Unexpected errors are contained only at appropriate runtime integration
boundaries. Error handling must not hide invalid state, convert partial failure
into apparent success, or use the unsupported extra-argument form of `xpcall`
in Lua 5.1.

## Behavior Deltas

Every intentional behavior change records:

- previous behavior;
- new behavior;
- reason for the change;
- classification of the previous behavior as broken, unsafe, confusing, or
  obsolete;
- compatibility and migration impact;
- automated tests and manual smoke checks that demonstrate the new contract.

The stable external surface includes addon identity, `/rma` and documented
aliases, `RMA_*` SavedVariables, RMA addon-message prefixes, TOC metadata, and
referenced FrameXML identities. Internal `addon.*` exports are not preserved
solely because they currently exist.

## Performance Policy

Optimization requires an identifiable cost such as repeated scans, redundant
model construction, excessive allocations in loot or sync paths, repeated
event work, or duplicated UI refresh. Changes should include a structural or
measured before-and-after comparison when practical.

Persistent or complex caching is avoided when invalidation risk exceeds the
observed benefit, especially for mutable SavedVariables and raid state. Runtime
work remains event-driven, bounded, throttled where required, and safe during
combat.

## UX Policy

UX changes support raid operation rather than visual redesign. Priorities are:

- clear feedback for failed or blocked actions;
- controls whose enabled state reflects permissions and current workflow state;
- stable list rows and predictable action columns;
- event-driven refresh rather than continuous polling;
- consistent interaction patterns across related raid workflows;
- compliance with combat lockdown and WotLK 3.3.5a API constraints.

## Testing And Validation

Each slice receives tests focused on behavior, external contracts, invariants,
and rejected unsafe states. Tests must not freeze temporary file boundaries,
private helper names, or accidental module exports.

The required verification set is proportional to the slice and includes:

- focused tests added or changed by the slice;
- the complete Python test suite;
- TOC reference and Interface validation;
- Lua 5.1 syntax validation;
- Lua 5.1 `xpcall` scanning;
- XML script-handler scanning;
- `luacheck` for touched files and, when practical, the whole addon;
- focused `stylua --check` without unrelated repository-wide EOL rewrites;
- `git diff --check`;
- explicit reporting of remaining client-only risks.

Static checks cannot prove protected actions, combat behavior, UI layout,
SavedVariables reload behavior, chat behavior, or synchronization timing in a
real 3.3.5a client. When such testing is unavailable, the result is reported as
`runtime smoke: not run; manual acceptance pending`.

## Batch Completion

A batch is complete only when implementation, behavior deltas, architectural
ownership, documentation, TOC load order, tests, and validation evidence agree.
Any residual risk is recorded explicitly. No speculative features, transitional
wrappers, hidden deferred work, or unrelated redesign are included.
