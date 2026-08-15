# Roadmap: Raid Management Addon Stabilization

## Overview

This milestone first makes persisted raid history fail closed without data loss, then removes locale-dependent raid admission and restores localized encounter fallback coverage. It next bounds request-driven synchronization work without changing the version-5 wire contract, and concludes with repository validation plus the in-game checks that static tooling cannot prove.

## Phases

**Phase Numbering:**
- Integer phases (1, 2, 3): Planned milestone work
- Decimal phases (2.1, 2.2): Urgent insertions (marked with INSERTED)

Decimal phases appear between their surrounding integers in numeric order.

- [x] **Phase 1: Persistence Safety** - Preserve incompatible raid archives and expose quarantine without disabling unrelated features.
- [x] **Phase 2: Locale-Independent Raid Recognition** - Use one canonical admission path and retain encounter fallback coverage on supported locales.
- [x] **Phase 3: Bounded Sync Requests** - Rate-limit request-driven reserve and distribution responses without changing wire compatibility.
- [ ] **Phase 4: Milestone Verification** - Complete runtime hygiene, automated validation, and documented in-game acceptance checks.

## Phase Details

### Phase 1: Persistence Safety
**Goal**: Raid history remains recoverable when persisted data is malformed or from an unsupported future format, while unaffected addon features continue to initialize.
**Depends on**: Nothing (first phase)
**Requirements**: PERS-01, PERS-02, PERS-03
**Success Criteria** (what must be TRUE):
  1. Loading an unknown or future `RMA_Raids` archive leaves its in-memory value unchanged rather than replacing it with an empty archive.
  2. When raid-history validation fails, the user receives a localized quarantine diagnostic and raid-history mutations fail closed while unrelated RMA features remain usable.
  3. Valid, malformed format-1, non-table, and future-format archives have automated load-and-save-preparation regression coverage.
**Plans**: 3 plans

Plans:
- [x] 01-01-PLAN.md - Preserve every existing unsupported raid archive and establish stable quarantine classification.
- [x] 01-02-PLAN.md - Complete degraded bootstrap, localized diagnostics, and automatic recovery behavior.
- [x] 01-03-PLAN.md - Make history read-only and suspend only raid-history synchronization while quarantined.

### Phase 2: Locale-Independent Raid Recognition
**Goal**: Supported raids and fallback encounters are recognized independently of English display strings on every currently supported client locale.
**Depends on**: Phase 1
**Requirements**: RAID-01, RAID-02, RAID-03, LOCL-01, LOCL-02
**Success Criteria** (what must be TRUE):
  1. Raid session and roster admission use the canonical instance resolver as their sole operational gate.
  2. Vanilla, Burning Crusade, and Wrath raids can start and update sessions regardless of the localized instance name returned by the client.
  3. Encounters that require the monster-yell fallback remain recordable on every supported locale.
  4. Automated checks cover Vanilla map IDs, at least one non-English instance name, and complete locale fallback data without allowing display strings to become admission gates.
**Plans**: 5 plans

Plans:
- [x] 02-01-PLAN.md - Make canonical resolver output the sole Session and Roster admission identity.
- [x] 02-02-PLAN.md - Add bounded retry recovery and one localized unknown-instance warning.
- [x] 02-03-PLAN.md - Acquire and validate the mandatory 60/60 yell evidence matrix.
- [x] 02-04-PLAN.md - Bind exact evidence-backed strings to locale catalogs and fallback metadata.
- [x] 02-05-PLAN.md - Enforce exact mixed-language yell matching in the expected canonical raid.

### Phase 3: Bounded Sync Requests
**Goal**: Group members can request reserve and distribution state normally without allowing repeated requests to create unbounded response work.
**Depends on**: Phase 2
**Requirements**: COMM-01, COMM-02, COMM-03, COMM-04
**Success Criteria** (what must be TRUE):
  1. The first authorized reserve or distribution snapshot request from a sender receives the same compatible response as before.
  2. Repeated `META_REQ`, `DATA_REQ`, and `SNAP_REQ` messages from one sender are rejected at the defined boundary before response serialization or queue allocation, then become eligible after expiry.
  3. Sender normalization prevents equivalent sender identities from bypassing the per-sender limit.
  4. Existing RMA prefixes, protocol-version-5 envelopes, payload shapes, and authorization behavior remain unchanged and are covered by regression tests.
**Plans**: 2 plans

Plans:
- [x] 03-01-PLAN.md - Bound reserve META_REQ and DATA_REQ response work per canonical sender and request kind.
- [x] 03-02-PLAN.md - Bound distribution SNAP_REQ response work and close cross-owner R5 compatibility coverage.

### Phase 4: Milestone Verification
**Goal**: The corrective milestone is demonstrably compatible with WotLK 3.3.5a and safe across reload, localization, multi-client synchronization, combat, and taint-sensitive workflows.
**Depends on**: Phase 3
**Requirements**: QUAL-01, QUAL-02, QUAL-03
**Success Criteria** (what must be TRUE):
  1. Proprietary runtime Lua is ASCII-only outside intentional non-English localization data.
  2. All required WotLK, Lua 5.1, TOC, XML, branding, `xpcall`, and available automated test checks pass after the corrections.
  3. A repeatable in-game checklist records successful login, `/rma`, window creation, valid and quarantined reload behavior, localized raid recognition, and loot/reserve workflows.
  4. Multi-client synchronization, combat-lockdown behavior, and taint logging complete without new Lua errors, protected-action failures, or protocol incompatibility.
**Plans**: TBD

## Progress

**Execution Order:**
Phases execute in numeric order: 1 → 2 → 3 → 4

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 1. Persistence Safety | 3/3 | Complete | 2026-08-15 |
| 2. Locale-Independent Raid Recognition | 5/5 | Complete | 2026-08-15 |
| 3. Bounded Sync Requests | 2/2 | Complete | 2026-08-15 |
| 4. Milestone Verification | 0/TBD | Not started | - |
