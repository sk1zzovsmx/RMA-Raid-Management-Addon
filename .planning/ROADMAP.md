# Roadmap: Raid Management Addon

## Milestones

- [v1.0 Stabilization](milestones/v1.0-ROADMAP.md) — Phases 1-4, shipped 2026-08-15.
- [v1.1 UI Simplification](milestones/v1.1-ROADMAP.md) — Phases 5-7, shipped 2026-08-16.
- **v1.2 Dependency Optimization** — Phases 8-12, planned.

## Overview

v1.2 reduces shipped dependency code only after compatibility is proven against the untouched vendors. It first locks the evidence and decision rules, then evaluates LibDeflate independently, proves the direct talent path while the complete vendor stack remains available, performs an all-three-or-none talent cutover, and finally validates the exact selected runtime tree and package. An evidence-backed KEEP is a successful result for either candidate and does not block the other decision.

## Phases

- [ ] **Phase 8: Contract and Evidence Baseline** — Freeze the current dependency contracts, golden evidence, and independent decision rules before any cutover.
- [ ] **Phase 9: Codec Compatibility Decision** — Prove and select exactly one LibDeflate KEEP or REPLACE outcome without changing protocol behavior.
- [ ] **Phase 10: Talent Compatibility Proof** — Prove the direct SpecInspect path, including required client behavior, while all three talent libraries remain intact.
- [ ] **Phase 11: Atomic Talent Stack Decision** — Apply one all-three KEEP or REPLACE result while leaving CallbackHandler unchanged.
- [ ] **Phase 12: Selected-Tree Compatibility Gate** — Validate the actual chosen runtime tree, TOC, package, persistence, and evidence disposition.

## Phase Details

### Phase 8: Contract and Evidence Baseline

**Goal**: Establish reproducible evidence and decision boundaries before candidate code can authorize dependency removal.
**Depends on**: Phase 7
**Requirements**: EVID-01, EVID-02, EVID-03
**Success Criteria** (what must be TRUE):
  1. A reproducible baseline records hashes, TOC placement, consumed contracts, and golden vectors from each untouched candidate library.
  2. Every acceptance gate is labeled `AUTOMATED`, `OBSERVED`, or `DEFERRED`, and reports never count `DEFERRED` as passed.
  3. LibDeflate and the atomic talent stack have separate KEEP/REPLACE decision records, and either can close as KEEP without blocking the other or failing the milestone.
**Plans**: TBD

### Phase 9: Codec Compatibility Decision

**Goal**: Reach and implement an evidence-backed LibDeflate KEEP or REPLACE decision using exact differential compatibility.
**Depends on**: Phase 8
**Requirements**: CODEC-01, CODEC-02, CODEC-03, CODEC-04, CODEC-05
**Success Criteria** (what must be TRUE):
  1. Candidate addon-channel encoding is byte-identical to untouched LibDeflate for binary boundaries, real RMA payloads, and golden vectors.
  2. Candidate decoding matches valid results and malformed-input failure behavior, while Adler32 preserves every numeric checksum, raid UID, and canonical digest under test.
  3. Protocol version 5 serialization, payload shapes, chunk behavior, error categories, and the absence of compression remain unchanged.
  4. The shipped codec path is singular: a fully passing candidate replaces LibDeflate and its TOC entry, or LibDeflate remains with no permanent candidate fallback or dual implementation.
**Plans**: TBD

### Phase 10: Talent Compatibility Proof

**Goal**: Demonstrate that direct WotLK talent inspection behind SpecInspect can preserve all required behavior before any talent library is removed.
**Depends on**: Phase 8
**Requirements**: TAL-01, TAL-02, TAL-03, TAL-04, TAL-05
**Success Criteria** (what must be TRUE):
  1. Manual, forced, and ready-check refresh preserve SpecInspect states, cache lifetime, stale-data behavior, and update-event semantics.
  2. Self and remote snapshots preserve active group, primary and secondary point totals, dominant tree, localized name, icon, and normalized role.
  3. InspectCoordinator remains the sole NotifyInspect owner and preserves GUID correlation, throttling, timeout, combat deferral, bounded queues, and exclusion between talent and equipment requests.
  4. Attendance, RaidGrid, Loot Counter, and Equipment Inspect retain their current specialization behavior without persistence changes.
  5. Required localization, remote dual-spec, and peer/out-of-range behavior is observed on a real WotLK 3.3.5a client; any required unproved behavior blocks replacement rather than becoming PASS.
**Plans**: TBD

### Phase 11: Atomic Talent Stack Decision

**Goal**: Select and apply one proof-backed outcome for the complete talent stack without altering CallbackHandler.
**Depends on**: Phase 10
**Requirements**: TAL-06, TAL-07
**Success Criteria** (what must be TRUE):
  1. If every talent gate passes, LibGroupTalents, LibTalentQuery, and LibBabble-TalentTree are removed together with their TOC entries only after the passing evidence is recorded.
  2. If any required talent gate does not pass, all three libraries and their TOC entries remain; no partial removal, production fallback, or hybrid stack is shipped.
  3. CallbackHandler-1.0 remains byte-unchanged and in its existing TOC position for either talent outcome.
**Plans**: TBD

### Phase 12: Selected-Tree Compatibility Gate

**Goal**: Close v1.2 against the exact runtime tree and dependency decisions that will ship.
**Depends on**: Phases 9 and 11
**Requirements**: COMP-01, COMP-02, COMP-03, COMP-04
**Success Criteria** (what must be TRUE):
  1. The selected addon tree passes the applicable Interface 30300, Lua 5.1, TOC, XML, unsupported-API, and complete automated behavior gates for WotLK 3.3.5a.
  2. Protocol version 5, addon-message prefixes, payloads, and all six canonical `RMA_*` SavedVariables remain unchanged, including reload behavior where observable.
  3. Vendored-source integrity is demonstrated, and the standalone TOC and package contain exactly the dependency set selected by the two independent decisions.
  4. Final evidence is anchored to the actual selected runtime tree, distinguishes `AUTOMATED`, `OBSERVED`, and `DEFERRED`, and never promotes deferred client risk to PASS.
**Plans**: TBD

## Progress

**Execution Order:** Phase 8 → Phase 9 and Phase 10 → Phase 11 → Phase 12. Phases 9 and 10 may be planned independently after Phase 8; Phase 12 requires both decisions.

| Phase | Milestone | Plans Complete | Status | Completed |
|-------|-----------|----------------|--------|-----------|
| 8. Contract and Evidence Baseline | v1.2 | 0/TBD | Not started | - |
| 9. Codec Compatibility Decision | v1.2 | 0/TBD | Not started | - |
| 10. Talent Compatibility Proof | v1.2 | 0/TBD | Not started | - |
| 11. Atomic Talent Stack Decision | v1.2 | 0/TBD | Not started | - |
| 12. Selected-Tree Compatibility Gate | v1.2 | 0/TBD | Not started | - |

---

_For current project status, see `.planning/PROJECT.md` and `.planning/STATE.md`._
