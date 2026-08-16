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

## Milestone: v1.1 — UI Simplification

**Shipped:** 2026-08-16
**Phases:** 3 | **Plans:** 7 | **Tasks:** 15

### What Was Built

- Removed three repository-proven unconsumed exports or forwarders without compatibility aliases.
- Added seven focused shared list primitives and migrated Logger and Attendance while preserving controller ownership.
- Added controller-edge regressions for numeric layout, Source behavior, Spec/Inspect, contextual presentation, and Force Inspect.
- Reproduced and repaired the WotLK Screen Notice FontString failure, then closed the repaired tree at 512/512 tests.
- Published a versioned acceptance report separating automated, observed, and deferred evidence.

### What Worked

- TDD made each deletion and controller migration fail for the intended missing behavior before production edits.
- Fixed-scope and protected-surface checks kept XML, localization, persistence, wire version 5, entrypoints, and vendored libraries unchanged.
- Feature policy stayed in Logger and Attendance because every shared primitive required explicit caller-owned geometry and presentation choices.
- The live Screen Notice failure was isolated to one focused repair and one focused retest without rerunning unrelated client scenarios.

### What Was Inefficient

- GSD metadata helpers repeatedly misread cumulative totals or the current roadmap format, requiring manual diff repair.
- The first full Phase 6 discovery exposed two stale Attendance fixtures after the controller contract became explicit.
- Plan 07-01's full gate became historical when the later live test found the Screen Notice font defect, requiring one replacement final gate.
- The unavailable Trade uncertainty/retry scenario prevented complete live coverage.

### Patterns Established

- Delete dead surfaces without deprecation aliases when repository evidence proves no consumer.
- Extract mechanics only after two concrete consumers demonstrate a stable contract; keep feature policy at controller edges.
- A later runtime repair supersedes earlier full-suite evidence for final acceptance.
- Preserve `AUTOMATED`, `OBSERVED`, and `DEFERRED` provenance through summaries, verification, audit, and milestone closure.

### Key Lessons

1. Client-created FontStrings need a behavior-level fixture that rejects `SetText` until a valid font is assigned.
2. Run focused controller fixtures before full discovery whenever a shared contract becomes an asserted bootstrap dependency.
3. Inspect every GSD metadata diff before committing; helper success output is not proof that aggregate state remained correct.
4. Keep library replacement in a separate milestone because codec and inspection stacks require compatibility evidence beyond UI simplification.

### Cost Observations

- Model mix: quality-profile GSD discussion, planning, execution, verification, integration audit, and milestone workflows.
- Execution time: approximately 1.7 hours across 7 plans, including the blocking live Screen Notice retest.
- Notable: Phase 7 dominated the milestone because real-client evidence found a defect that automation initially missed.

---

## Cross-Milestone Trends

### Process Evolution

| Milestone | Plans | Phases | Key Change |
| --------- | ----- | ------ | ---------- |
| v1.0 | 12 | 4 | Established evidence-bounded stabilization and verification |
| v1.1 | 7 | 3 | Added focused UI sharing and superseded-gate discipline after live repair |

### Cumulative Quality

| Milestone | Tests | Automated Result | Deferred Live Areas |
| --------- | ----- | ---------------- | ------------------- |
| v1.0 | 507 | 507/507 passed | 4 |
| v1.1 | 512 | 512/512 passed | 5, including inherited risks |

### Top Lessons (Verified Across Milestones)

1. Focused RED/GREEN checks followed by one final repaired-tree gate remain effective across milestones.
2. Evidence must remain classified as automated, observed, or deferred through every planning and archival layer.
3. Compatibility-sensitive data and behavior should stay with existing owners unless concrete evidence justifies a new abstraction.
