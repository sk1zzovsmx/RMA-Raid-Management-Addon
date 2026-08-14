# Inspect And Dataset Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prevent incomplete inspect snapshots and conflicting inspect ownership, then make instance datasets locale-safe and atomically activated.

**Architecture:** `EquipInspect` remains the equipment snapshot owner, while a single RMA inspect coordinator serializes client-global inspect effects used by equipment and talents. Dataset modules resolve a canonical instance identity before building detached indexes and publishing one generation atomically.

**Tech Stack:** WoW 3.3.5a, Interface 30300, Lua 5.1, LibGroupTalents integration, Python unittest and the Lua runtime harness.

## Global Constraints

- Preserve existing `RMA_*` SavedVariables, inspect UI contracts, TOC identities, and WotLK APIs.
- Do not modify vendored `Libs/*`; adapt through first-party integration boundaries.
- No unbounded `OnUpdate`; inspect and item-info retries must be bounded and combat-safe.
- Runtime smoke remains deferred until the full refactoring program is complete.

---

### Task 1: Persist Equipment Only When Item Information Is Complete

**Files:**
- Modify: `Raid Management Addon/Services/EquipInspect.lua`
- Modify: `tests/lua/runtime_harness.lua`
- Create: `tests/test_inspect_dataset_behavior.py`

- [ ] Add cold-cache tests where `GetItemInfo` initially returns nil, later resolves, and never resolves before timeout; assert no partial `ready` snapshot replaces the last known good data.
- [ ] Track unresolved equipped item IDs/slots separately from empty slots and schedule bounded retries through the existing timer owner or `GET_ITEM_INFO_RECEIVED` integration.
- [ ] Persist `ready` and average item level only when every relevant equipped item is resolved; timeout remains runtime-only failure and retains canonical snapshot.
- [ ] Run focused/full gates and commit `fix(inspect): Wait for complete item information`.

### Task 2: Establish One Client-Global Inspect Coordinator

**Files:**
- Create only if cohesion requires: `Raid Management Addon/Services/InspectCoordinator.lua`
- Modify: `Raid Management Addon/Services/EquipInspect.lua`
- Modify: `Raid Management Addon/Services/SpecInspect.lua`
- Modify: `Raid Management Addon/Raid Management Addon.toc`
- Modify: `tests/lua/runtime_harness.lua`
- Modify: `tests/test_inspect_dataset_behavior.py`

- [ ] Add production-real interleaving tests for equipment inspect and LibGroupTalents refresh, GUID-mismatched `INSPECT_READY`, combat deferral, timeout, cancellation, and `ClearInspectPlayer` ownership.
- [ ] Introduce one cohesive coordinator only if it owns the global target, queue, timeout, and clear lifecycle; otherwise implement an equivalent explicit handshake in an existing owner.
- [ ] Route first-party `NotifyInspect`/clear operations through that owner without modifying LibGroupTalents; serialize or suspend talent refresh so one flow cannot clear another flow's target.
- [ ] Run focused/full gates and commit `fix(inspect): Serialize global inspect ownership`.

### Task 3: Resolve Instance Dataset Identity Independently Of Client Locale

**Files:**
- Modify: `Raid Management Addon/Init.lua`
- Modify: `Raid Management Addon/Modules/Dataset/LootSourcesData.lua`
- Modify: `Raid Management Addon/Modules/Dataset/IgnoredMobs.lua`
- Modify: `Raid Management Addon/Localization/localization.en.lua` only if maintained locale aliases belong there.
- Modify: `tests/lua/runtime_harness.lua`
- Modify: `tests/test_inspect_dataset_behavior.py`

- [ ] Test non-enUS instance names and canonical identity resolution without relying only on English `GetInstanceInfo()` text.
- [ ] Prefer stable map/instance identifiers available in 3.3.5a; where unavailable, keep a bounded locale-alias map with explicit unknown behavior.
- [ ] Feed one canonical instance key to loot-source and ignored-mob datasets; unknown identity must fail visibly/conservatively without attributing the wrong raid.
- [ ] Run focused/full gates and commit `fix(dataset): Resolve localized raid identities`.

### Task 4: Publish Dataset Indexes Atomically And Report Coherence

**Files:**
- Modify: `Raid Management Addon/Modules/Dataset/LootSourcesData.lua`
- Modify: `tests/lua/runtime_harness.lua`
- Modify: `tests/test_inspect_dataset_behavior.py`
- Create: `docs/INSPECT_DATASET_HARDENING_REPORT.md`
- Modify: `docs/FEATURE_API_MAP.md`, `docs/ARCHITECTURE.md`, `docs/VALIDATION.md` only for final contracts.

- [ ] Fault-inject dataset build failures and assert active roots, generation, attribution, and ignored-mob behavior preserve the last known good index.
- [ ] Build candidate indexes off-side and swap all active roots/generation in one non-failing publish; define unsupported-instance deactivation separately from build failure.
- [ ] Run full unittest, TOC, Lua 5.1, xpcall, XML, whole-addon luacheck, and `git diff --check` gates.
- [ ] Record behavior deltas, TOC/registry/SavedVariables coherence, test evidence, client-only risks, and `runtime smoke: deferred by user until the full refactoring program is complete`.
- [ ] Commit `docs(inspect): Record inspect and dataset hardening`.
