# Sync And Communications Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make raid-history synchronization fail closed, bounded, revision-monotone, and atomic without changing existing RMA prefixes or wire payload versions.

**Architecture:** `Modules/Comms.lua` remains the transport queue owner; `DBSyncer.lua` coordinates authorization, requests, chunks, and terminal results; payload modules parse and validate detached data; `DBSyncImport.lua` builds a candidate and commits through `DBRaidStore` only after complete validation. No inbound packet mutates canonical history before trust, limits, schema, context, and revision checks pass.

**Tech Stack:** WotLK 3.3.5a, Interface `30300`, Lua 5.1, Python `unittest`, Lua behavior harness, `luacheck`, local WotLK validators.

## Global Constraints

- Preserve `RMALogSync`, all other RMA prefixes, and existing v1/v2 payload fields.
- Do not increment SavedVariables schema or import non-RMA globals.
- Authorization fails closed; roster uncertainty defers or rejects and never accepts payload mutation.
- Incoming chunk/payload/state allocations are bounded before allocation.
- Stale/equal/out-of-order revisions never overwrite newer canonical data.
- Import is detached and atomic; failure preserves raid data, revision, indexes, and UI state.
- Use stable realm-qualified identity internally where available; display normalization must not weaken authorization.
- Lua 5.1/WotLK only; no Retail APIs, variadic `xpcall`, unbounded timers, or unbounded queues.
- Preserve existing README edits; runtime smoke remains explicitly deferred until the entire refactoring program ends.

---

### Task 1: Add Sync Behavior Fixtures

**Files:**
- Modify: `tests/lua/runtime_harness.lua`
- Create: `tests/test_sync_communications_behavior.py`

- [ ] Add RED unknown-case smoke for sync fixture.
- [ ] Add isolated roster roles, realm-qualified senders, fake comms, bounded clock/timers, raid revisions, request/chunk builders, and deep mutation assertions.
- [ ] Run focused/full suites and commit `test(sync): Add communications behavior harness`.

### Task 2: Fail Closed On Sync Authorization

**Files:**
- Modify: `Raid Management Addon/Database/DBSyncer.lua`
- Modify: `Raid Management Addon/Services/Raid/Capabilities.lua` only if a reusable stable identity query is required.
- Modify: sync behavior tests.

- [ ] Add RED cases: unknown sender during grace rejected; officer accepted; ordinary member rejected; roster-late sender accepted only after positive lookup.
- [ ] Remove the two-second accept-anyone fallback; defer/reject without allocating import state.
- [ ] Require whisper requesters to be current group members before returning stored history.
- [ ] Preserve authorized leader/assistant flows and commit `fix(sync): Enforce responder authorization`.

### Task 3: Require Consent For PUSH Imports

**Files:**
- Modify: `Raid Management Addon/Database/DBSyncer.lua`
- Modify: `Raid Management Addon/Database/DBOptions.lua` only if existing Logger target options need typed access.
- Modify: `Raid Management Addon/Controllers/Config.lua` only for existing option semantics/help.
- Modify: sync tests and `docs/FEATURE_API_MAP.md`.

- [ ] Add RED outsider/member/officer/configured-target PUSH cases; rejected PUSH must not insert a raid.
- [ ] Define trust: PUSH requires current group membership plus positive authority and either a pending correlated request or configured push source; no implicit acceptance.
- [ ] Make `syncRequirePlayer`/`syncPushPlayer` effective or remove misleading configuration in the same batch.
- [ ] Document trust model and commit `fix(sync): Require consent for history push`.

### Task 4: Bound Transport, Assembly, And Payloads

**Files:**
- Modify: `Raid Management Addon/Modules/Comms.lua`
- Modify: `Raid Management Addon/Database/DBSyncer.lua`
- Modify: `Raid Management Addon/Database/DBSyncPayload.lua`
- Modify: sync tests.

- [ ] Define ASCII constants for max chunks, encoded bytes, incoming states globally/per sender, rows, and field lengths based on existing message constraints.
- [ ] Add RED boundary and over-limit tests before state allocation, including request-ID floods and malformed changing part counts.
- [ ] Replace unbounded/O(n) queue shifting with bounded head-index queue and explicit backpressure result.
- [ ] Keep FIFO and current wire chunks; clear malformed/expired states deterministically.
- [ ] Commit `fix(comms): Bound sync transport resources`.

### Task 5: Validate Protocol And Revision Monotonicity

**Files:**
- Modify: `Raid Management Addon/Database/DBSyncPayload.lua`
- Modify: `Raid Management Addon/Database/DBSyncImport.lua`
- Modify: `Raid Management Addon/Database/DBSyncer.lua`
- Modify: sync tests.

- [ ] Add malformed protocol/schema/range/duplicate/reference/header-envelope mismatch cases.
- [ ] Add stale/equal/gapped/out-of-order snapshot/delta cases and per-loot revision bounds.
- [ ] Implement pure `ValidateSnapshot`/`ValidateDelta` stable reason codes before mutation.
- [ ] Require snapshot revision newer than local; delta `sinceRevision` compatible with local and every row revision monotone within envelope.
- [ ] Commit `fix(sync): Reject invalid and stale history payloads`.

### Task 6: Make Snapshot And Delta Import Atomic

**Files:**
- Modify: `Raid Management Addon/Database/DBSyncImport.lua`
- Modify: `Raid Management Addon/Database/DBRaidStore.lua`
- Modify: `Raid Management Addon/Database/DBSyncer.lua`
- Modify: sync tests.

- [ ] Add injected failure after each former incremental mutation; canonical raid/revision/indexes must remain deeply equal.
- [ ] Build detached candidate, validate current schema/references/revisions, then commit once through a store-owned command with rollback on postcondition failure.
- [ ] Publish UI/data event only after commit; rejected/failed imports publish none.
- [ ] Preserve current merge semantics for accepted snapshots unless a separately approved product decision changes it.
- [ ] Commit `fix(sync): Commit history imports atomically`.

### Task 7: Harden Request Correlation And Terminal Lifecycle

**Files:**
- Modify: `Raid Management Addon/Modules/Comms.lua`
- Modify: `Raid Management Addon/Database/DBSyncer.lua`
- Modify: sync tests.

- [ ] Add tests for unsolicited response, reused request ID, wrong sender/raid, timeout then late packet, duplicate terminal callback, and sender-state cleanup.
- [ ] Bind request IDs to sender, raid, mode, creation time, and terminal state; reject cross-context reuse.
- [ ] Ensure timeout/cancel/complete callbacks deliver once and release all bounded state.
- [ ] Preserve wire-compatible request IDs; strengthen local correlation without adding fields to existing payloads.
- [ ] Commit `fix(sync): Correlate request lifecycle safely`.

### Task 8: Produce Sync Coherence Report

**Files:**
- Create: `docs/SYNC_COMMUNICATIONS_HARDENING_REPORT.md`
- Modify: `docs/FEATURE_API_MAP.md`, `docs/ARCHITECTURE.md`, `docs/VALIDATION.md` only for actual final contracts.

- [ ] Run full tests, TOC, Lua 5.1, xpcall, XML scan, whole-addon luacheck, focused StyLua, and diff-check.
- [ ] Verify prefixes/wire fields/schema/TOC/XML/SavedVariables unchanged and all runtime files TOC-referenced.
- [ ] Record authorization, limits, revision, atomicity, lifecycle deltas and residual risks.
- [ ] Record `runtime smoke: deferred by user until the full refactoring program is complete`.
- [ ] Commit `docs(sync): Record communications hardening verification`.
