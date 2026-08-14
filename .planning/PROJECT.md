# Raid Management Addon Stabilization

## What This Is

Raid Management Addon (RMA) is an existing World of Warcraft raid-management addon for the WotLK 3.3.5a client. It supports raid history, loot distribution, reserves, attendance, warnings, recruitment messaging, and synchronization between group members.

This milestone stabilizes the existing addon by correcting the concrete persistence, raid-recognition, localization, and communication risks found during the repository-wide review. It does not redesign the addon or expand its product scope.

## Core Value

Raid-critical data and workflows must remain correct, recoverable, and compatible on WotLK 3.3.5a clients.

## Requirements

### Validated

- ✓ The addon loads through an Interface 30300 TOC and exposes `/rma` — existing.
- ✓ Raid, loot, reserves, attendance, warnings, spammer, logger, and configuration workflows exist — existing.
- ✓ Persistence is owned through the six public `RMA_*` SavedVariables — existing.
- ✓ Raid, reserve, distribution, and version communication use explicit RMA-prefixed version-5 wire protocols — existing.
- ✓ Runtime code targets Lua 5.1 and avoids Retail-only APIs — existing static validation.
- ✓ XML is layout-only and runtime UI behavior is owned by Lua — existing static validation.

### Active

- [ ] Preserve incompatible or future `RMA_Raids` archives instead of replacing them before validation.
- [ ] Expose an explicit degraded/quarantine state when raid persistence cannot be normalized during `ADDON_LOADED`.
- [ ] Use the canonical locale-independent instance resolver for raid admission and session creation.
- [ ] Cover Vanilla and localized-client raid recognition with focused regression tests.
- [ ] Bound incoming reserve and loot-distribution snapshot requests with per-sender rate limits.
- [ ] Preserve boss-kill fallback behavior on supported non-English clients.
- [ ] Remove the remaining non-ASCII runtime comment.
- [ ] Verify the milestone with automated checks plus documented in-game multi-client, reload, combat-lockdown, and taint smoke tests.

### Out of Scope

- General architecture or UI redesign — the review did not demonstrate a need for it.
- Reclassification of QuickBar, Debug registry, or DBSyncer ownership — informative structural observations only, with no current runtime defect.
- Migration from non-RMA SavedVariables or retired addon identities — explicitly forbidden without a separate import-tool request.
- Wire-format changes or protocol-version bumps — existing version-5 payloads remain the compatibility contract.
- New raid-management features — this milestone is corrective only.
- Editing vendored libraries under `Libs/` — upstream code is outside project ownership.

## Context

- A repository-wide read-only review mapped the TOC, bootstrap, module ownership, persistence, UI, and communication flows.
- The review found two critical defects: destructive handling of incompatible raid archives and duplicate locale-dependent raid-admission gates.
- It also found warning-level gaps in quarantine visibility, boss-yell localization, and request admission limits.
- Static validation currently reports a clean TOC, 137 Lua 5.1-compatible files, no variadic `xpcall` traps, and no XML script handlers.
- The Python test suite discovers 484 tests. In the current Codex environment, Lua-backed cases cannot run because a `lua` executable is unavailable; this environment limitation must remain distinct from product failures.
- The project is brownfield even though the generic GSD detector does not recognize its addon-only repository shape as an application package.

## Constraints

- **Client compatibility**: Target WotLK 3.3.5a, Interface 30300.
- **Language**: Runtime Lua 5.1 only; no Lua 5.2+ syntax or APIs.
- **Persistence**: Only the six existing `RMA_*` SavedVariables may be read or written during normal startup.
- **Data safety**: Unknown, corrupt, or future-format persisted data must fail closed without mutation.
- **Wire compatibility**: Keep the current RMA prefixes, payload shapes, and protocol version unless a separately approved breaking change is required.
- **Architecture**: Preserve Database, Services, Controllers, Widgets, EntryPoints, and layout-only XML ownership boundaries.
- **Scope**: Apply the smallest demonstrated correction; do not introduce speculative compatibility layers or general refactors.
- **Verification**: Automated validation is necessary but not sufficient for combat lockdown, taint, SavedVariables reload, localization, or multi-client behavior.

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| Treat this as a stabilization milestone, not a redesign | The review identified bounded correctness risks and no broad overengineering problem | — Pending |
| Preserve incompatible `RMA_Raids` data and enter quarantine | Future or malformed persisted data must not be silently replaced | — Pending |
| Make the canonical map-ID resolver the only raid-admission source of truth | Localized display strings must not control runtime recognition | — Pending |
| Add application-level request admission limits without changing wire payloads | Protect runtime resources while preserving peer compatibility | — Pending |
| Include manual in-game smoke tests as final acceptance criteria | Combat, taint, localization, reload, and multi-client behavior cannot be proven statically | — Pending |

---

_Last updated: 2026-08-15 after initialization from the repository-wide review_
