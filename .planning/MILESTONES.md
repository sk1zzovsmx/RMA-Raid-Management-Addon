# Project Milestones: Raid Management Addon

## v1.1 UI Simplification (Shipped: 2026-08-16)

**Delivered:** Bounded runtime-surface cleanup and focused Logger/Attendance list primitives with preserved WotLK 3.3.5a compatibility and explicit accepted-risk verification.

**Phases completed:** 5-7 (3 phases, 7 plans, 15 tasks)

**Key accomplishments:**

- Removed `ScreenNotice.Show`, `Trade.EnsureState`, and the loot-state forwarding method without adding compatibility aliases or changing supported entrypoints.
- Added seven focused `addon.UI.Lists` primitives and routed Logger and Attendance through them while retaining feature-owned presentation, Spec/Inspect, Source, and Force Inspect behavior.
- Reproduced and fixed the WotLK Screen Notice `Font not set` failure with a behavior-level RED test and a focused live retest.
- Preserved XML, localization, the six SavedVariables, RMA protocol version 5, vendored libraries, TOC ownership, and public entrypoints across an exact six-file runtime diff.
- Closed the repaired tree at 512/512 tests with honest `AUTOMATED`, `OBSERVED`, and `DEFERRED` evidence boundaries.

**Stats:**

- 37 files changed across implementation, tests, and planning; exactly 6 addon runtime files changed
- 85,803 lines of proprietary runtime Lua at completion
- 4,392 insertions and 439 deletions across the milestone Git range
- 3 phases, 7 plans, 15 tasks, 33 pre-archive commits
- Completed on 2026-08-16

**Git range:** `d335ef7` -> `7200e07`

**Accepted residual risk:** Trade live completion plus genuine uncertainty/retry remains deferred and unpassed. SavedVariables quarantine/recovery, localized multi-client synchronization, combat lockdown, and taint remain inherited live-only risks. Two unused local `GetContentWidth` aliases remain bounded cleanup debt.

**What's next:** Define v1.2 Dependency Optimization with byte-compatible LibDeflate evaluation and one evidence-based talent-library stack decision.

---

## v1.0 Stabilization (Shipped: 2026-08-15)

**Delivered:** Non-destructive raid-history persistence, locale-independent raid recognition, bounded synchronization requests, and a complete automated WotLK 3.3.5a acceptance gate.

**Phases completed:** 1-4 (12 plans, 25 tasks)

**Key accomplishments:**

- Preserved unsupported or malformed `RMA_Raids` archives and exposed a localized, fail-closed quarantine state without disabling unrelated features.
- Replaced locale-dependent raid admission with one canonical instance context and added evidence-backed exact encounter-yell coverage for all five supported catalogs.
- Bounded reserve and distribution response work per canonical sender while preserving RMA prefixes, protocol version 5, payloads, and authorization behavior.
- Passed the complete 507-test LuaJIT suite plus TOC, Lua 5.1, `xpcall`, XML, API, ASCII, identity, and diff gates.
- Recorded the sole live observation exactly as `no Lua errors occurred` and kept four unexecuted live areas explicitly deferred and unpassed.

**Stats:**

- 65 files changed across the milestone Git range
- 77,202 lines of proprietary runtime Lua at completion
- 4 phases, 12 plans, 25 tasks
- Completed on 2026-08-15

**Git range:** `3f78735` -> `5d092b6`

**Accepted residual risk:** Real-client SavedVariables quarantine/recovery, localized multi-client synchronization, combat protected-action behavior, and taint verification were not executed. Historical pre-normalization branding cannot be proven from the available Git ancestry.

**What's next:** No next milestone scope is defined. Start with `$gsd-new-milestone` when new concrete work is selected.

---
