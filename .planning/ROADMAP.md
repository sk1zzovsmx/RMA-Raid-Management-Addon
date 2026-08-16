# Roadmap: Raid Management Addon

## Milestones

- ✅ **v1.0 Stabilization** - Phases 1-4 (shipped 2026-08-15)
- 🚧 **v1.1 UI Simplification** - Phases 5-7 (planned)

## Phases

**Phase Numbering:**
- Integer phases (5, 6, 7): Planned v1.1 milestone work
- Decimal phases (5.1, 5.2): Urgent insertions (marked with INSERTED)

Decimal phases appear between their surrounding integers in numeric order. Phase numbering continues from the shipped v1.0 milestone.

<details>
<summary>✅ v1.0 Stabilization (Phases 1-4) - SHIPPED 2026-08-15</summary>

- [x] **Phase 1: Persistence Safety** - Preserved incompatible raid archives and exposed quarantine without disabling unrelated features.
- [x] **Phase 2: Locale-Independent Raid Recognition** - Established canonical raid admission and supported-locale encounter fallback coverage.
- [x] **Phase 3: Bounded Sync Requests** - Bounded request-driven reserve and distribution responses without changing version-5 wire compatibility.
- [x] **Phase 4: Milestone Verification** - Completed the automated acceptance gate and recorded observed and deferred live evidence honestly.

The complete shipped roadmap remains archived at `.planning/milestones/v1.0-ROADMAP.md`.

</details>

### 🚧 v1.1 UI Simplification (Planned)

**Milestone Goal:** Remove demonstrated dead UI-facing paths and consolidate only the stable Logger/Attendance list-layout primitives without changing visible behavior or compatibility contracts.

- [x] **Phase 5: Runtime Surface Cleanup** - Removed three confirmed unconsumed exports or forwarders while preserving their runtime behavior.
- [ ] **Phase 6: Logger and Attendance List Primitives** - Share focused list-layout primitives while preserving each controller's presentation behavior.
- [ ] **Phase 7: UI Simplification Verification** - Prove the simplification preserves UI, localization, runtime, and WotLK 3.3.5a contracts.

## Phase Details

### Phase 5: Runtime Surface Cleanup
**Goal**: Screen notices, trade handling, and loot initialization retain their current behavior with the three unconsumed public or forwarding paths removed.
**Depends on**: Phase 4 (v1.0 shipped baseline)
**Requirements**: CLEAN-01, CLEAN-02, CLEAN-03
**Success Criteria** (what must be TRUE):
  1. Screen notices still appear through the internal event path after `ScreenNotice.Show` is no longer exported.
  2. Existing trade workflows behave identically after the unconsumed `Trade.EnsureState` export is removed.
  3. Loot startup produces the same normalized runtime state through a direct `ContextState.SyncRuntimeState` call, with no `Loot:SyncRuntimeState` forwarding method.
**Plans**: 1/1 complete

### Phase 6: Logger and Attendance List Primitives
**Goal**: Logger and Attendance use a small shared set of stable list-layout primitives while retaining controller-owned, feature-specific presentation.
**Depends on**: Phase 5
**Requirements**: UI-01, UI-02, UI-03
**Success Criteria** (what must be TRUE):
  1. Logger lists retain their calculated widths, sort behavior, clickable hit boxes, icon allowance, titles, and empty-state presentation.
  2. Attendance lists retain their calculated widths, sort behavior, inspect/spec columns, contextual titles, and empty-state presentation.
  3. Logger and Attendance obtain calculated widths, header and row layout, and sort binding from focused shared primitives without a generic framework, configuration DSL, or transfer of feature ownership.
**Plans**: TBD

### Phase 7: UI Simplification Verification
**Goal**: The completed simplification is demonstrably compatible with the addon's existing UI, runtime, localization, persistence, communication, and WotLK 3.3.5a contracts.
**Depends on**: Phase 6
**Requirements**: QUAL-01, QUAL-02
**Success Criteria** (what must be TRUE):
  1. The complete relevant automated suite and all applicable WotLK 3.3.5a static validators pass against the simplified implementation.
  2. XML remains layout-only, and the existing RMA version-5 wire protocols, six `RMA_*` SavedVariables, vendored libraries, and supported public entrypoints remain unchanged.
  3. Screen notices, trade, loot initialization, Logger, and Attendance retain their localized user-facing text and visible behavior after the cleanup.
**Plans**: TBD

## Progress

**Execution Order:**
Phases execute in numeric order: 5 → 6 → 7

| Phase | Milestone | Plans Complete | Status | Completed |
|-------|-----------|----------------|--------|-----------|
| 1. Persistence Safety | v1.0 | 3/3 | Complete | 2026-08-15 |
| 2. Locale-Independent Raid Recognition | v1.0 | 5/5 | Complete | 2026-08-15 |
| 3. Bounded Sync Requests | v1.0 | 2/2 | Complete | 2026-08-15 |
| 4. Milestone Verification | v1.0 | 2/2 | Complete | 2026-08-15 |
| 5. Runtime Surface Cleanup | v1.1 | 1/1 | Complete | 2026-08-16 |
| 6. Logger and Attendance List Primitives | v1.1 | 0/TBD | Not started | - |
| 7. UI Simplification Verification | v1.1 | 0/TBD | Not started | - |

---

_For current project status, see `.planning/PROJECT.md` and `.planning/STATE.md`._
