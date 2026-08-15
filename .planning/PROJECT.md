# Raid Management Addon Stabilization

## What This Is

Raid Management Addon (RMA) is an existing World of Warcraft raid-management addon for the WotLK 3.3.5a client. It supports raid history, loot distribution, reserves, attendance, warnings, recruitment messaging, and synchronization between group members.

This milestone stabilizes the existing addon by correcting the concrete persistence, raid-recognition, localization, and communication risks found during the repository-wide review. It does not redesign the addon or expand its product scope. Final live verification uses the user-approved pragmatic disposition scope: automated results, the exact live observation provided, and explicitly accepted residual risks are recorded separately without treating unexecuted checks as passes.

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
- [ ] Close milestone verification with 507/507 automated acceptance and a privacy-safe disposition record that separates the exact live observation from deferred live risks.

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
- Phase 4 automated acceptance reports 507/507 tests through LuaJIT plus clean TOC, Lua 5.1, variadic-`xpcall`, XML, API, timer, ASCII, current-identity, and diff gates.
- Live evidence is limited to the user's exact observation that no Lua errors occurred. SavedVariables quarantine/recovery, localized/multi-client sync, combat protected-action behavior, and taint remain unexecuted accepted residual risks.
- The project is brownfield even though the generic GSD detector does not recognize its addon-only repository shape as an application package.

## Constraints

- **Client compatibility**: Target WotLK 3.3.5a, Interface 30300.
- **Language**: Runtime Lua 5.1 only; no Lua 5.2+ syntax or APIs.
- **Persistence**: Only the six existing `RMA_*` SavedVariables may be read or written during normal startup.
- **Data safety**: Unknown, corrupt, or future-format persisted data must fail closed without mutation.
- **Wire compatibility**: Keep the current RMA prefixes, payload shapes, and protocol version unless a separately approved breaking change is required.
- **Architecture**: Preserve Database, Services, Controllers, Widgets, EntryPoints, and layout-only XML ownership boundaries.
- **Scope**: Apply the smallest demonstrated correction; do not introduce speculative compatibility layers or general refactors.
- **Verification**: Automated validation does not prove combat, taint, SavedVariables disk behavior, localization, or multi-client integration. Unexecuted live coverage must be labeled deferred residual risk, never PASS.

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| Treat this as a stabilization milestone, not a redesign | The review identified bounded correctness risks and no broad overengineering problem | — Pending |
| Preserve incompatible `RMA_Raids` data and enter quarantine | Future or malformed persisted data must not be silently replaced | — Pending |
| Make the canonical map-ID resolver the only raid-admission source of truth | Localized display strings must not control runtime recognition | — Pending |
| Add application-level request admission limits without changing wire payloads | Protect runtime resources while preserving peer compatibility | — Pending |
| Close Phase 4 with an accepted-risk verification disposition rather than mandatory completion of every live smoke step | The user explicitly selected pragmatic scope reduction option 2; honest separation of automated, observed, and deferred evidence is preferable to fabricated PASS results | QUAL-03 is redefined as the disposition-record requirement; deferred live checks remain residual risk |

---

_Last updated: 2026-08-15 after the user-approved Phase 4 verification scope reduction_
