# Requirements: Raid Management Addon Stabilization

**Defined:** 2026-08-15
**Core Value:** Raid-critical data and workflows must remain correct, recoverable, and compatible on WotLK 3.3.5a clients.

## v1 Requirements

Requirements for the stabilization milestone. Each requirement maps to exactly one roadmap phase.

### Persistence Safety

- [ ] **PERS-01**: An existing `RMA_Raids` value with an unknown or future archive format remains byte-for-byte equivalent in memory after addon initialization and is not replaced by an empty archive.
- [ ] **PERS-02**: When raid persistence validation fails during `ADDON_LOADED`, RMA enters an explicit degraded/quarantine state, reports a localized diagnostic, and rejects raid-history mutation without preventing unrelated features from initializing.
- [ ] **PERS-03**: Automated regression cases cover valid, malformed format-1, non-table, and future-format `RMA_Raids` inputs through load and save preparation.

### Raid Recognition

- [ ] **RAID-01**: RMA uses the canonical locale-independent instance resolver as the only operational admission gate for raid session and roster checks.
- [ ] **RAID-02**: Supported Vanilla, Burning Crusade, and Wrath raid instances can start or update raid sessions independently of the client's localized instance name.
- [ ] **RAID-03**: Automated regression cases cover map-ID recognition for Vanilla raids and at least one non-English localized instance name.

### Communication Safety

- [ ] **COMM-01**: Reserve `META_REQ` and `DATA_REQ` messages are admitted through a bounded per-sender rate limit before response serialization or queue allocation.
- [ ] **COMM-02**: Loot-distribution `SNAP_REQ` messages are admitted through a bounded per-sender rate limit before snapshot serialization or queue allocation.
- [ ] **COMM-03**: Rate limiting preserves all existing RMA prefixes, protocol version 5 envelopes, payload shapes, authorization checks, and normal first-request behavior.
- [ ] **COMM-04**: Automated regression cases prove exact rate-limit boundaries, expiry, sender normalization, and absence of response work for rejected requests.

### Localization

- [ ] **LOCL-01**: Boss encounters that depend on the monster-yell fallback remain recordable on each currently supported client locale, using localized exact text only where no locale-independent signal is available.
- [ ] **LOCL-02**: Localization regression checks enforce complete fallback coverage without turning display-string tables into runtime raid-admission gates.

### Verification and Hygiene

- [ ] **QUAL-01**: Proprietary runtime Lua contains no non-ASCII characters outside localization data explicitly intended for non-English clients.
- [ ] **QUAL-02**: The TOC validator, Lua 5.1 validator, variadic-`xpcall` scanner, XML handler scan, branding scan, and complete available automated test suite pass after the corrections.
- [ ] **QUAL-03**: A documented in-game smoke test verifies clean login, `/rma`, window creation, valid and quarantined SavedVariables reload, localized raid recognition, loot/reserve workflows, multi-client sync, combat lockdown, and taint behavior.

## v2 Requirements

No deferred product features are part of this corrective milestone.

## Out of Scope

| Feature | Reason |
|---------|--------|
| General UI or architecture redesign | No demonstrated defect requires it. |
| QuickBar, Debug registry, or DBSyncer reclassification | Structural observations are informative but not current runtime failures. |
| Import or migration from non-RMA SavedVariables | Requires a separate explicit import-tool request. |
| Wire-format or protocol-version changes | Existing version-5 compatibility must be preserved. |
| New raid-management features | The milestone is limited to demonstrated review findings. |
| Vendored library edits | `Libs/` remains upstream-owned. |

## Traceability

Roadmap phase mappings will be populated during roadmap creation.

| Requirement | Phase | Status |
|-------------|-------|--------|
| PERS-01 | TBD | Pending |
| PERS-02 | TBD | Pending |
| PERS-03 | TBD | Pending |
| RAID-01 | TBD | Pending |
| RAID-02 | TBD | Pending |
| RAID-03 | TBD | Pending |
| COMM-01 | TBD | Pending |
| COMM-02 | TBD | Pending |
| COMM-03 | TBD | Pending |
| COMM-04 | TBD | Pending |
| LOCL-01 | TBD | Pending |
| LOCL-02 | TBD | Pending |
| QUAL-01 | TBD | Pending |
| QUAL-02 | TBD | Pending |
| QUAL-03 | TBD | Pending |

**Coverage:**
- v1 requirements: 15 total
- Mapped to phases: 0
- Unmapped: 15

---

_Requirements defined: 2026-08-15_
_Last updated: 2026-08-15 after initial definition_
