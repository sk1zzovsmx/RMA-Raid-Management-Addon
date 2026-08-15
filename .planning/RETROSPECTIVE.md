# Project Retrospective

_A living document updated after each milestone. Lessons feed forward into future planning._

## Milestone: v1.0 — Stabilization

**Shipped:** 2026-08-15
**Phases:** 4 | **Plans:** 12 | **Tasks:** 25

### What Was Built

- Non-destructive SavedVariables quarantine from bootstrap through history UI and raid-history synchronization.
- Canonical locale-independent raid admission with evidence-backed localized encounter fallback data.
- Bounded reserve and distribution response admission with unchanged RMA protocol version 5 contracts.
- A clean 507-test automated acceptance gate and an explicit observed/deferred live-risk record.

### What Worked

- Atomic plans kept persistence, recognition, localization, communication, and verification ownership separate.
- Focused RED/GREEN checks exposed stale assumptions before the single final full-suite run.
- Exact source provenance and digests prevented guessed localization data from entering runtime catalogs.
- The final evidence classification avoided presenting automation or a limited user observation as broader live proof.

### What Was Inefficient

- Early environments lacked a discoverable Lua runner even though LuaJIT later existed at a stable path.
- The retired-branding gate required several iterations before its evidence boundary was reduced to demonstrable current identity.
- Historical Phase 1 and Phase 2 verification metadata used approval wording that the final disposition had to supersede.

### Patterns Established

- Preserve unknown persisted data, classify it transiently, and fail closed at every consuming boundary.
- Keep canonical runtime identity separate from localized display and persisted presentation fields.
- Put bounded request admission inside each response owner immediately before expensive work.
- Label verification evidence as `AUTOMATED`, `OBSERVED`, or `DEFERRED`.

### Key Lessons

1. Discover the actual Lua-compatible runner before planning runtime gates.
2. Do not create negative branding assertions without an authoritative historical identifier set.
3. Treat exact locale bytes and wire formats as compatibility contracts, not text cleanup opportunities.
4. Record residual live risk explicitly when the corresponding scenario was not executed.

### Cost Observations

- Model mix: GSD phase research, planning, execution, checking, and milestone audit agents.
- Execution time: approximately 3.4 hours across 12 plans.
- Notable: Phase 4 consumed the most time because it reconciled environment discovery, stale fixtures, branding evidence limits, and live-evidence scope.

---

## Cross-Milestone Trends

### Process Evolution

| Milestone | Plans | Phases | Key Change |
| --------- | ----- | ------ | ---------- |
| v1.0 | 12 | 4 | Established evidence-bounded stabilization and verification |

### Cumulative Quality

| Milestone | Tests | Automated Result | Deferred Live Areas |
| --------- | ----- | ---------------- | ------------------- |
| v1.0 | 507 | 507/507 passed | 4 |

### Top Lessons (Verified Across Milestones)

1. Await another milestone before claiming cross-milestone validation of process lessons.
