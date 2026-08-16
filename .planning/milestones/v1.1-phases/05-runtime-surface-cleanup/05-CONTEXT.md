# Phase 5: Runtime Surface Cleanup - Context

**Gathered:** 2026-08-16
**Status:** Ready for planning

<domain>
## Phase Boundary

Remove only the three repository-confirmed unconsumed public or forwarding paths: `ScreenNotice.Show`, `Trade.EnsureState`, and `Loot:SyncRuntimeState`. Screen notices, trade behavior, and loot runtime-state normalization must remain unchanged. New APIs, compatibility shims, UI changes, and dependency work are outside this phase.

</domain>

<decisions>
## Implementation Decisions

### Screen notice invocation
- Remove the direct `ScreenNotice.Show` export completely; do not retain a deprecated alias or compatibility shim.
- Keep the internal `ScreenNotice` event as the sole supported production invocation path.
- Preserve the existing `showNotice` callback behavior, duration handling, frame updates, and fade behavior.

### Trade state ownership
- Remove `Trade.EnsureState` completely; do not expose a replacement state accessor.
- Keep mutable Trade state private to `Services/Master/Trade.lua` and continue using the local `ensureState` helper from owning operations.
- Preserve all existing Trade public behavior and return contracts.

### Loot runtime initialization
- Replace the guarded call through `Loot:SyncRuntimeState` with a direct same-file call to `ContextState.SyncRuntimeState`.
- Remove the `Loot:SyncRuntimeState` forwarding method completely; do not add an alias.
- Preserve the normalized loot context, synchronized legacy fields, and bootstrap ordering exactly.

### Compatibility policy
- Compatibility is defined by supported in-repository entrypoints and observed runtime behavior, not by unused speculative external callers.
- No XML, localization, SavedVariables, wire protocol, vendored library, or visible UI changes belong in this phase.
- Dependency optimization remains deferred to v1.2; shared Logger/Attendance primitives remain Phase 6 work.

### Codex's Discretion
- Exact focused-test organization and assertion placement.
- Whether existing tests are extended or a narrowly scoped regression test is added, provided current contracts are protected without speculative coverage.
- Mechanical ordering of the three independent removals within the phase plan.

</decisions>

<specifics>
## Specific Ideas

- Prefer deletion and direct ownership over deprecation layers because repository evidence shows no consumers.
- Treat this as behavior-preserving surface reduction, not a public API migration.

</specifics>

<code_context>
## Existing Code Insights

### Reusable Assets
- `Modules/UI/ScreenNotice.lua`: local `showNotice` already owns all behavior and is registered directly with `Internal.ScreenNotice`.
- `Services/Master/Trade.lua`: local `ensureState` is already used by owning Trade operations; the public forwarder adds no behavior.
- `Services/Loot/State.lua`: `ContextState.SyncRuntimeState` and its sole forwarding caller are defined in the same file.
- Existing Lua harness and Python contract suites provide the baseline for behavior-preserving regression checks.

### Established Patterns
- RMA uses event-driven redraw and notification paths; direct UI invocation is unnecessary when an internal event owner exists.
- Mutable service state stays behind its owning service operations rather than being exposed through unused accessors.
- Small same-file delegation layers are removed when they do not protect a real ownership or compatibility boundary.

### Integration Points
- `Internal.ScreenNotice` publication and `RegisterCallback(ScreenNoticeEvent, showNotice)` must remain connected.
- Trade consumers continue through the remaining `Trade.*` public methods; no caller migration is required.
- `Database.EnsureLootRuntimeState` must invoke `ContextState.SyncRuntimeState` directly during bootstrap.

</code_context>

<deferred>
## Deferred Ideas

- Logger and Attendance shared list-layout primitives — Phase 6.
- `LibDeflate` replacement and talent-library stack evaluation — future v1.2 Dependency Optimization milestone.

</deferred>

---

*Phase: 05-runtime-surface-cleanup*
*Context gathered: 2026-08-16*
