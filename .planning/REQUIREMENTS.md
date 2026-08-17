# Requirements: Raid Management Addon v1.2 Dependency Optimization

**Defined:** 2026-08-17
**Core Value:** Raid-critical data and workflows must remain correct, recoverable, and compatible on WotLK 3.3.5a clients.

## v1.2 Requirements

### Evidence

- [ ] **EVID-01**: RMA preserves hashes, consumed contracts, and golden vectors from the untouched candidate libraries before any replacement or removal.
- [ ] **EVID-02**: RMA classifies every acceptance result as `AUTOMATED`, `OBSERVED`, or `DEFERRED`, and never treats a deferred check as passed.
- [ ] **EVID-03**: RMA records independent KEEP/REPLACE decisions for LibDeflate and the atomic talent stack, and accepts an evidence-backed KEEP as a successful milestone outcome.

### Codec and Checksum

- [ ] **CODEC-01**: A candidate addon-channel encoder produces exactly the same bytes as the untouched LibDeflate implementation for binary inputs, real RMA payloads, and defined boundary cases.
- [ ] **CODEC-02**: A candidate addon-channel decoder reproduces the untouched LibDeflate implementation's exact results and failure behavior for valid and malformed inputs.
- [ ] **CODEC-03**: A candidate Adler32 implementation preserves exact numeric checksums, formatted raid UIDs, and canonical state digests across golden and real RMA inputs.
- [ ] **CODEC-04**: RMA preserves protocol version 5 serialization, payload shapes, chunk behavior, and stable error categories without adding compression.
- [ ] **CODEC-05**: RMA adopts the minimal codec/checksum replacement and removes LibDeflate plus its TOC entry only if every required gate passes; otherwise it retains LibDeflate without a permanent fallback or dual implementation.

### Talent Inspection

- [ ] **TAL-01**: Users retain manual, forced, and ready-check specialization refresh with the existing SpecInspect states, cache lifetime, stale-data behavior, and update-event semantics.
- [ ] **TAL-02**: Users retain primary and secondary specialization data including active group, point totals, dominant tree, localized name, icon, and normalized role.
- [ ] **TAL-03**: Talent inspection uses InspectCoordinator as the sole owner of NotifyInspect and preserves GUID correlation, throttling, timeout, combat deferral, bounded queue behavior, and equipment-inspection exclusion.
- [ ] **TAL-04**: Attendance, RaidGrid, Loot Counter, and Equipment Inspect retain their current specialization behavior without changing persistence semantics.
- [ ] **TAL-05**: RMA observes supported localization, remote dual-spec, and peer/out-of-range behavior on a real WotLK 3.3.5a client when those behaviors are required for replacement; unproved required behavior prevents removal.
- [ ] **TAL-06**: RMA removes LibGroupTalents, LibTalentQuery, and LibBabble-TalentTree together only after all replacement gates pass; otherwise it retains all three without partial removal.
- [ ] **TAL-07**: CallbackHandler-1.0 remains unchanged in source and TOC regardless of the talent-stack decision.

### Final Compatibility

- [ ] **COMP-01**: RMA remains compatible with WotLK 3.3.5a, Interface 30300, and Lua 5.1 after the selected dependency decisions.
- [ ] **COMP-02**: RMA preserves protocol version 5, addon-message prefixes, payloads, and the six canonical `RMA_*` SavedVariables without schema changes.
- [ ] **COMP-03**: RMA never modifies vendored library source and removes an approved candidate directory only after its compatibility evidence passes.
- [ ] **COMP-04**: The final gate validates the actual selected runtime tree, standalone TOC/package contents, automated suite, and applicable client observations without promoting deferred risk to PASS.

## Future Requirements

None identified. New dependency candidates or capability changes require a separately approved milestone or roadmap revision.

## Out of Scope

| Feature | Reason |
|---------|--------|
| Compression, decompression, zlib, dictionaries, or compressed SoftRes import | No proprietary RMA runtime consumer requires these LibDeflate capabilities; bounded inflate is a separate product and safety decision. |
| New wire format, protocol version, prefix, payload shape, serialization, or talent-sharing protocol | v1.2 optimizes dependencies without changing compatibility contracts. |
| Full compatibility facades for unused vendor APIs | Recreating unconsumed APIs would defeat dependency reduction and violate KISS/YAGNI. |
| Partial removal of the three talent libraries | The user approved one atomic KEEP/REPLACE decision. |
| Removal or replacement of CallbackHandler-1.0 | Explicitly excluded from the talent-stack decision. |
| Persisted talent cache, SavedVariables changes, or non-RMA migration | Talent display remains derived/runtime data and persistence contracts are frozen. |
| General UI, communication, synchronization, inspection, or architecture redesign | No demonstrated requirement; only minimal integration changes needed by a proven replacement are allowed. |
| Editing retained vendored sources | Vendored libraries remain untouched compatibility oracles and upstream-owned code. |

## Traceability

Populated during roadmap creation. Every v1.2 requirement must map to exactly one phase.

| Requirement | Phase | Status |
|-------------|-------|--------|
| EVID-01 | — | Pending |
| EVID-02 | — | Pending |
| EVID-03 | — | Pending |
| CODEC-01 | — | Pending |
| CODEC-02 | — | Pending |
| CODEC-03 | — | Pending |
| CODEC-04 | — | Pending |
| CODEC-05 | — | Pending |
| TAL-01 | — | Pending |
| TAL-02 | — | Pending |
| TAL-03 | — | Pending |
| TAL-04 | — | Pending |
| TAL-05 | — | Pending |
| TAL-06 | — | Pending |
| TAL-07 | — | Pending |
| COMP-01 | — | Pending |
| COMP-02 | — | Pending |
| COMP-03 | — | Pending |
| COMP-04 | — | Pending |

**Coverage:**
- v1.2 requirements: 19 total
- Mapped to phases: 0
- Unmapped: 19

---
*Requirements defined: 2026-08-17*
*Last updated: 2026-08-17 after initial v1.2 definition*
