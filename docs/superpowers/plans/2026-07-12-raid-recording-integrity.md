# Raid Recording Integrity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make raid roster, attendance, logger cleanup, session creation, and inspect persistence preserve stable raid history and synchronization semantics under retries, deletion, cancellation, and transient failures.

**Architecture:** Mutation owners publish one completed-state event and advance `syncRevision` exactly once per real canonical change. Stable `raidNid` identifies delayed work and UI notifications; array indexes remain short-lived lookup details. Logger cleanup uses store-owned mutation commands, and inspect persistence separates last-known-good data from transient attempt state.

**Tech Stack:** WoW 3.3.5a, Interface `30300`, Lua 5.1, Python `unittest`, Lua behavior harness, `luacheck`, StyLua, and local WotLK validators.

## Global Constraints

- Preserve addon identity, `/rma`, Interface `30300`, and the six `RMA_*` SavedVariables.
- Do not increment the raid schema version or change addon-message wire formats in this batch.
- Use stable `raidNid` and player NIDs across delayed or persisted workflows.
- Mutations advance sync revision once per completed transaction and never on no-op or rejected work.
- Events describe completed state changes and carry stable domain identity.
- Preserve Lua 5.1 and WotLK 3.3.5a compatibility; no Retail APIs or variadic `xpcall`.
- Do not modify `Libs/`, XML scripts, or the existing uncommitted README changes.
- Add behavior tests before production changes and record every behavior delta.

---

### Task 1: Extend The Lua Harness For Raid Recording

**Files:**
- Modify: `tests/lua/runtime_harness.lua`
- Create: `tests/test_raid_recording_integrity_behavior.py`

**Interfaces:**
- Consumes: existing `run_lua_case` and isolated addon loading.
- Produces: reusable fixtures for two raids with non-index `raidNid`, store revision tracking, event capture, controllable timers, roster APIs, and inspect callbacks.

- [ ] Add an initially failing `raid_recording_fixture_smoke` Python case.
- [ ] Run it and record the expected unknown-case failure.
- [ ] Add fixture builders without test-only production APIs; include deep-copy/equality and stable event/revision assertions.
- [ ] Run focused and full suites; expect the prior 83 tests plus the new smoke case to pass.
- [ ] Commit as `test(raid): Add recording integrity harness`.

---

### Task 2: Publish Every Roster Mutation Exactly Once

**Files:**
- Modify: `Raid Management Addon/Services/Raid/Roster.lua`
- Modify: `Raid Management Addon/Init.lua`
- Modify: `Raid Management Addon/Controllers/Attendance.lua`
- Modify: `Raid Management Addon/Services/Logger/Actions.lua`
- Modify: `tests/lua/runtime_harness.lua`
- Modify: `tests/test_raid_recording_integrity_behavior.py`

**Interfaces:**
- Produces: `Roster:RefreshAndPublish()` returns the delta and publishes one `RaidRosterDelta` after mutation; callers no longer publish independently.

- [ ] Add failing cases for dispatcher refresh, scheduled retry, Attendance manual refresh, and Logger-triggered refresh; each mutation must publish one delta.
- [ ] Prove the baseline misses non-dispatch publications and would double-publish if ownership were merely added.
- [ ] Move publication into one roster-owned entry point and update every caller.
- [ ] Verify no-op refresh publishes no delta and timer cancellation/debounce behavior is preserved.
- [ ] Run focused/full tests and Lua validators.
- [ ] Commit as `fix(raid): Publish roster mutations consistently`.

---

### Task 3: Make Attendance Idempotent, Revisioned, And Stable-ID Based

**Files:**
- Modify: `Raid Management Addon/Services/Raid/Attendance.lua`
- Modify: `Raid Management Addon/Controllers/Attendance.lua`
- Modify: `tests/lua/runtime_harness.lua`
- Modify: `tests/test_raid_recording_integrity_behavior.py`
- Modify: `docs/FEATURE_BOUNDARIES.md`

**Interfaces:**
- Produces: attendance events carry `raidNid`; real mutations touch raid sync revision once; `openSegment` distinguishes reuse from mutation.

- [ ] Add failing seed/delta/close cases where raid index is `2` and `raidNid` is `42`.
- [ ] Assert duplicate seed/join and rank-only updates return false, emit nothing, and preserve revision.
- [ ] Assert subgroup/online transitions close/open exactly once, emit one event with `raidNid`, and advance one revision.
- [ ] Update the controller to resolve stable event identity at the UI edge.
- [ ] Document the event identity and revision contract; run validation.
- [ ] Commit as `fix(attendance): Record only real presence changes`.

---

### Task 4: Separate Attendance Removal From Player Purge

**Files:**
- Modify: `Raid Management Addon/Services/Attendance/Actions.lua`
- Modify: `Raid Management Addon/Controllers/Attendance.lua`
- Modify: `Raid Management Addon/Localization/localization.en.lua`
- Modify: `tests/lua/runtime_harness.lua`
- Modify: `tests/test_raid_recording_integrity_behavior.py`

**Interfaces:**
- Produces: `DeleteRaidAttendance(raidNid, playerNids)` removes only attendance evidence selected by the user; destructive `PurgeRaidPlayers` remains a separately named, explicitly confirmed command if retained.

- [ ] Add a failing UI/domain case proving current Delete removes player identity, boss membership, loot, and leaves orphan inspect data.
- [ ] Define non-destructive deletion to preserve players, boss attendance, loot, and inspect snapshots while updating the selected attendance projection and revision once.
- [ ] If a full purge remains user-reachable, require an explicit confirmation text naming the cascade and atomically remove player/boss/loot/attendance/inspect plus pending inspect work.
- [ ] Add localized success/failure feedback and one completed event.
- [ ] Run focused/full/static validation.
- [ ] Commit as `fix(attendance): Preserve raid history on removal`.

---

### Task 5: Make Raid Session Creation Failure-Atomic

**Files:**
- Modify: `Raid Management Addon/Services/Raid/State.lua`
- Modify: `tests/lua/runtime_harness.lua`
- Modify: `tests/test_raid_recording_integrity_behavior.py`

**Interfaces:**
- Consumes: `RaidStore:CreateRaidRecord` and `InsertRaid`.
- Produces: a new raid is prepared and admitted before the current session is ended; failure preserves current raid, end time, attendance, and runtime state.

- [ ] Add failing injected `CreateRaidRecord` and `InsertRaid` cases.
- [ ] Assert old raid remains current and open, no event/revision changes, and no partial raid is persisted.
- [ ] Stage/validate the candidate, then perform the smallest commit sequence with rollback if insertion or switch fails.
- [ ] Add successful replacement coverage preserving current external behavior and event order.
- [ ] Run validators and commit as `fix(raid): Make session replacement atomic`.

---

### Task 6: Move Logger Cleanup Behind Store-Owned Transactions

**Files:**
- Modify: `Raid Management Addon/Database/DBRaidStore.lua`
- Modify: `Raid Management Addon/Services/Logger/Actions.lua`
- Modify: `Raid Management Addon/Controllers/Logger.lua`
- Modify: `tests/lua/runtime_harness.lua`
- Modify: `tests/test_raid_recording_integrity_behavior.py`

**Interfaces:**
- Produces: store commands for batch raid/loot deletion by stable NID; cleanup result includes `changed`, `complete`, counts, affected raid NIDs, and cancellation state.

- [ ] Add failing synchronous cleanup tests proving deleted loot does not advance revision/full-sync requirements.
- [ ] Add failing async cancellation after one chunk; partial persisted work must be finalized and publish one `LoggerDataChanged` with `complete=false`, or staged work must roll back fully.
- [ ] Replace raw `GetRawRaids`/`tremove` mutation with store-owned commands that maintain current selection and indexes by `raidNid`.
- [ ] Ensure surviving raids advance revision once per cleanup transaction and deletions require full sync where the delta protocol cannot represent them.
- [ ] Add bulk raid deletion event coverage and one controller refresh path.
- [ ] Run focused/full/static validation and commit as `fix(logger): Make history cleanup coherent`.

---

### Task 7: Make Logger Rebuild And RecordLoot Atomic

**Files:**
- Modify: `Raid Management Addon/Services/Logger/Actions.lua`
- Modify: `Raid Management Addon/Database/DBRaidStore.lua`
- Modify: `tests/lua/runtime_harness.lua`
- Modify: `tests/test_raid_recording_integrity_behavior.py`

**Interfaces:**
- Produces: atomic store mutation for static-source boss creation plus loot patch; `RecordLoot` stages and verifies before canonical commit.

- [ ] Add failing source-rebuild cases: boss creation and loot reassignment must cause full-sync revision; unresolved/no-change must not.
- [ ] Add injected RecordLoot verification failure and assert loot row plus raid revision remain deeply unchanged.
- [ ] Stage changes, validate references/NIDs, commit once, rebuild indexes, then publish.
- [ ] Preserve stable NIDs and existing local UI result shapes.
- [ ] Run validation and commit as `fix(logger): Commit history mutations atomically`.

---

### Task 8: Bind Equip Inspect Work To Stable Raid Identity

**Files:**
- Modify: `Raid Management Addon/Services/EquipInspect.lua`
- Modify: `Raid Management Addon/Services/Attendance/View.lua`
- Modify: `Raid Management Addon/Controllers/Attendance.lua`
- Modify: `tests/lua/runtime_harness.lua`
- Modify: `tests/test_raid_recording_integrity_behavior.py`

**Interfaces:**
- Produces: queues, timers, status, and callbacks keyed by `raidNid`; every delayed effect re-resolves the raid and cancels if identity is gone.

- [ ] Add failing reorder/delete case: queue for raid B, delete raid A, fire ready and timeout; only B may change.
- [ ] Convert runtime keys and callback payloads to `raidNid`, with explicit orphan cancellation.
- [ ] Make `ForcePlayer` propagate queued/pending/missing results and have the controller show localized feedback.
- [ ] Verify timers remain throttled, bounded, and combat-safe.
- [ ] Run validation and commit as `fix(inspect): Track work by stable raid identity`.

---

### Task 9: Preserve Last-Known-Good Inspect Data

**Files:**
- Modify: `Raid Management Addon/Services/EquipInspect.lua`
- Modify: `Raid Management Addon/Database/DBRaidMigrations.lua` only if persisted timestamp cleanup is required without a schema bump.
- Modify: `tests/lua/runtime_harness.lua`
- Modify: `tests/test_raid_recording_integrity_behavior.py`
- Modify: `docs/SAVED_VARIABLES.md`

**Interfaces:**
- Produces: ready snapshots remain canonical; transient timeout/skipped/failed attempt status is runtime-only or stored separately without replacing gear/spec data; persisted timestamps use epoch time if retained.

- [ ] Add failing ready-then-timeout/out-of-range cases proving valid gear is currently overwritten.
- [ ] Preserve ready data while exposing the latest attempt failure to UI.
- [ ] Replace persisted `GetTime()` uptime with the existing epoch time owner, or remove those fields from persistence and document the decision.
- [ ] Add reload-shaped timestamp/snapshot tests and no-op revision assertions.
- [ ] Run validation and commit as `fix(inspect): Preserve last known good snapshots`.

---

### Task 10: Produce The Raid Recording Coherence Report

**Files:**
- Create: `docs/RAID_RECORDING_INTEGRITY_REPORT.md`
- Modify: `docs/ARCHITECTURE.md`, `docs/FEATURE_API_MAP.md`, or `docs/VALIDATION.md` only where the final implementation changes their contracts.

- [ ] Run the full Python suite, TOC validator, Lua 5.1 validator, `xpcall` scan, XML-handler scan, whole-addon `luacheck`, focused StyLua checks, and `git diff --check`.
- [ ] Confirm no SavedVariables/schema/wire/TOC/XML identity changes and every runtime file remains TOC-referenced.
- [ ] Record behavior deltas, sync revision semantics, event identities, atomicity guarantees, commands/results, and residual risks.
- [ ] Include `runtime smoke: not run; manual acceptance pending` unless a real WotLK client smoke was performed.
- [ ] Commit as `docs(raid): Record recording integrity verification`.

## Deferred To Later Risk-Ordered Batches

- Sync transport authorization, PUSH consent, chunk/payload limits, revision monotonicity, and atomic remote import.
- Loot/roll/award/trade effect safety beyond logger recording.
- SpecInspect unresolved-GUID callbacks and non-integrity UI redesign.
