# Requirements: Raid Management Addon v1.1 UI Simplification

**Defined:** 2026-08-16
**Core Value:** Raid-critical data and workflows must remain correct, recoverable, and compatible on WotLK 3.3.5a clients.

## v1.1 Requirements

### Runtime Cleanup

- [x] **CLEAN-01**: Screen notices continue to work through the internal event path after the unconsumed `ScreenNotice.Show` export is removed.
- [x] **CLEAN-02**: Trade behavior remains unchanged after the unconsumed `Trade.EnsureState` export is removed.
- [x] **CLEAN-03**: Loot runtime initialization produces the same normalized state by calling `ContextState.SyncRuntimeState` directly without the `Loot:SyncRuntimeState` forwarder.

### Shared UI Primitives

- [ ] **UI-01**: Logger and Attendance use focused shared primitives for calculated widths, headers, rows, and sort binding without introducing a generic framework or configuration DSL.
- [ ] **UI-02**: Logger lists preserve their current calculated widths, sorting, hit boxes, icon allowance, titles, and empty states after consolidation.
- [ ] **UI-03**: Attendance lists preserve their current calculated widths, sorting, inspect/spec columns, contextual titles, and empty states after consolidation.

### Compatibility

- [ ] **QUAL-01**: The complete relevant automated suite and WotLK 3.3.5a static validators pass after the simplification.
- [ ] **QUAL-02**: The milestone leaves XML, RMA version-5 wire protocols, SavedVariables, vendored libraries, supported public entrypoints, localization, and visible behavior unchanged.

## Future Requirements

Deferred to the separately scoped v1.2 Dependency Optimization milestone.

### Dependency Optimization

- **DEPS-01**: RMA replaces `LibDeflate` only if addon-channel codec output, decoding behavior, and Adler32 checksums remain byte-for-byte compatible with established golden vectors.
- **DEPS-02**: RMA evaluates `LibGroupTalents`, `LibTalentQuery`, `LibBabble-TalentTree`, and `CallbackHandler` as one dependency stack against the existing `InspectCoordinator` before deciding whether replacement is justified.
- **DEPS-03**: RMA retains `LibStub`, `LibSerialize`, `ChatThrottleLib`, `LibDeformat`, and `LibBossIDs` unless new repository evidence demonstrates a safer and simpler replacement.

## Out of Scope

| Feature | Reason |
|---------|--------|
| General UI redesign | The milestone consolidates implementation primitives without changing presentation or workflows. |
| Generic UI framework or declarative layout DSL | Two concrete consumers do not justify a new framework or speculative extension points. |
| Vendored library changes | Dependency optimization is deferred to v1.2 and vendored source remains upstream-owned. |
| Wire-format or protocol-version changes | RMA version-5 communication compatibility remains binding. |
| SavedVariables schema changes | UI simplification has no persistence requirement. |
| New raid-management features | The milestone is a bounded internal simplification only. |

## Traceability

Each v1.1 requirement maps to exactly one roadmap phase.

| Requirement | Phase | Status |
|-------------|-------|--------|
| CLEAN-01 | Phase 5 | Complete |
| CLEAN-02 | Phase 5 | Complete |
| CLEAN-03 | Phase 5 | Complete |
| UI-01 | Phase 6 | Pending |
| UI-02 | Phase 6 | Pending |
| UI-03 | Phase 6 | Pending |
| QUAL-01 | Phase 7 | Pending |
| QUAL-02 | Phase 7 | Pending |

**Coverage:**
- v1.1 requirements: 8 total
- Mapped to phases: 8
- Unmapped: 0

---
*Requirements defined: 2026-08-16*
*Last updated: 2026-08-16 after completing Phase 5 runtime surface cleanup*
