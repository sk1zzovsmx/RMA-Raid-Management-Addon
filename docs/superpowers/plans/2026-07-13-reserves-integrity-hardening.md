# Reserves Integrity Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Reserves mutations, synchronization, imports, and bulk edits fail closed and atomic before addressing lower-risk supporting features.

**Architecture:** `Services/Reserves.lua` remains the canonical mutation owner; `Services/Reserves/Sync.lua` owns the wire lifecycle; `Import.lua` owns bounded parsing; `Widgets/ReservesUI.lua` only submits commands and renders results. Remote sync data stays detached until verified, and no failed/no-op action may promote it into `RMA_Reserves`.

**Tech Stack:** WoW 3.3.5a, Interface 30300, Lua 5.1, Python unittest plus the repository Lua runtime harness.

## Global Constraints

- Preserve `RMA_Reserves`, existing addon-message fields/prefixes, `/rma`, XML frame identities, and Lua 5.1 compatibility.
- Do not modify `Libs/*`, add Ace dependencies, or add Retail APIs.
- XML remains layout-only; user-facing errors use `addon.L`.
- Runtime smoke is deferred by the user until the full refactoring program is complete.

---

### Task 1: Promote Synced Data Only After A Successful Mutation

**Files:**
- Modify: `Raid Management Addon/Services/Reserves.lua`
- Modify: `tests/lua/runtime_harness.lua`
- Create: `tests/test_reserves_integrity_behavior.py`

**Interfaces:**
- Consumes: current `SetQuantity`, `SetPlus`, `Remove`, `Save`, and synced-cache selection.
- Produces: the same public return signatures, with clone-on-success persistence semantics.

- [ ] Add production-loaded tests that seed detached synced data, call invalid-player, missing-item, and no-change mutations, then save/reload and assert `RMA_Reserves` and cache ownership are unchanged.
- [ ] Run the focused test and observe failure caused by `ensureMutableLocalReserves()` promotion.
- [ ] Resolve and validate the target against the active view first; create a detached mutable clone only after the command is known to change canonical data.
- [ ] Commit the clone and clear synced-cache state in one non-failing publish step; keep failed/no-op return reasons stable.
- [ ] Run focused/full tests and commit `fix(reserves): Promote sync cache only on mutation`.

### Task 2: Make Sync Checksums Deterministic And Verified

**Files:**
- Modify: `Raid Management Addon/Services/Reserves.lua`
- Modify: `Raid Management Addon/Services/Reserves/Sync.lua`
- Modify: `tests/lua/runtime_harness.lua`
- Modify: `tests/test_reserves_integrity_behavior.py`

**Interfaces:**
- Produces: `Reserves.BuildCanonicalChecksum(data)` shared by outbound META and inbound verification.

- [ ] Add tests showing equivalent insertion orders produce the same checksum and corrupted/truncated/empty/count-mismatched payloads never reach `SetSyncedData`.
- [ ] Run tests RED against unordered `pairs()` and META-only checksum comparison.
- [ ] Canonicalize player keys and reserve rows before hashing; validate decoded schema and announced counts, recompute checksum, and compare before cache publication.
- [ ] Deterministically clear rejected/expired transfer state and preserve the last valid local/synced view.
- [ ] Run focused/full tests and commit `fix(reserves): Verify canonical sync payloads`.

### Task 3: Snapshot And Cancel Asynchronous Imports Safely

**Files:**
- Modify: `Raid Management Addon/Services/Reserves.lua`
- Modify: `tests/lua/runtime_harness.lua`
- Modify: `tests/test_reserves_integrity_behavior.py`

**Interfaces:**
- Produces: one terminal callback result per apply request: `completed`, `failed`, or `cancelled`.

- [ ] Test caller mutation between chunks, replacement by a second request, explicit cancel, callback reentrancy, and reload-shaped canonical equality.
- [ ] Run RED and capture direct iteration/replacement behavior.
- [ ] Deep-snapshot parsed source data at request start; use a generation/token guard for scheduled chunks; terminalize the replaced request as cancelled exactly once.
- [ ] Build a detached candidate and publish only after the final row validates; failure/cancel leaves `RMA_Reserves` unchanged.
- [ ] Run focused/full tests and commit `fix(reserves): Snapshot asynchronous imports`.

### Task 4: Bound Import Parsers Before Allocation

**Files:**
- Modify: `Raid Management Addon/Services/Reserves/Import.lua`
- Modify: `tests/lua/runtime_harness.lua`
- Modify: `tests/test_reserves_integrity_behavior.py`

**Interfaces:**
- Produces: stable reasons for encoded bytes, decoded bytes, rows, players, reserves-per-player, and field-length limits.

- [ ] Derive explicit ASCII constants from current UI/chat constraints and add exact-boundary/over-limit tests for CSV, Base64, JSON, and compressed input.
- [ ] Reject oversized encoded input before decode/decompress and oversized decoded/schema collections before aggregate allocation.
- [ ] Validate dense sequences, exact field types, positive item identifiers, bounded quantities, ASCII-safe names/aliases, and duplicate policy.
- [ ] Run focused/full tests and commit `fix(reserves): Bound imported reserve data`.

### Task 5: Commit Bulk Edits Atomically With Feedback

**Files:**
- Modify: `Raid Management Addon/Services/Reserves.lua`
- Modify: `Raid Management Addon/Widgets/ReservesUI.lua`
- Modify: `Raid Management Addon/Localization/localization.en.lua`
- Modify: `tests/lua/runtime_harness.lua`
- Modify: `tests/test_reserves_integrity_behavior.py`

**Interfaces:**
- Produces: `Reserves.ApplyBatch(commands)` returning `true, summary` or `nil, reason, rowIndex`.

- [ ] Test mixed valid/invalid/no-change rows, one save/event on success, zero mutation/event on failure, and edit-mode retention with localized row feedback.
- [ ] Validate all commands against a detached candidate, then publish/save/notify once; never call row mutations incrementally from the widget.
- [ ] Update UI baseline and exit edit mode only on successful batch completion.
- [ ] Run focused/full tests and commit `fix(reserves): Apply bulk edits atomically`.

### Task 6: Bound Whisper Admission And Produce A Coherence Report

**Files:**
- Modify: `Raid Management Addon/Services/Reserves/Chat.lua`
- Modify: `Raid Management Addon/Localization/localization.en.lua`
- Modify: `tests/lua/runtime_harness.lua`
- Modify: `tests/test_reserves_integrity_behavior.py`
- Create: `docs/RESERVES_INTEGRITY_REPORT.md`
- Modify: `docs/FEATURE_API_MAP.md`, `docs/ARCHITECTURE.md`, `docs/VALIDATION.md` only for final contracts.

**Interfaces:**
- Preserves the current opt-in signup policy; adds bounded per-sender admission and storage limits without silently redefining pre-raid signup as raid-only.

- [ ] Test out-of-group opt-in behavior explicitly, per-sender bursts, total/participant caps, invalid names/items, response queue bounds, and reload persistence.
- [ ] Add a bounded TTL rate policy before mutation/reply and reject capacity overflow with localized feedback; do not infer a raid-membership requirement unless the existing product contract proves it.
- [ ] Run full unittest, TOC, Lua 5.1, xpcall, XML handler, luacheck, and `git diff --check` gates.
- [ ] Record behavior deltas, SavedVariables/wire compatibility, TOC/runtime file coherence, unavailable tools, and `runtime smoke: deferred by user until the full refactoring program is complete`.
- [ ] Commit `docs(reserves): Record integrity hardening contract`.
