# Raid Management Addon

## What This Is

Raid Management Addon (RMA) is a World of Warcraft raid-management addon for the WotLK 3.3.5a client. It supports raid history, loot distribution, reserves, attendance, warnings, recruitment messaging, and synchronization between group members.

Versions v1.0 and v1.1 established a safer runtime baseline and simplified demonstrated UI internals without changing product scope or compatibility contracts.

## Core Value

Raid-critical data and workflows must remain correct, recoverable, and compatible on WotLK 3.3.5a clients.

## Current State

**Latest shipped milestone:** v1.1 UI Simplification — 2026-08-16

- The addon targets Interface 30300 and Lua 5.1.
- Normal persistence remains limited to the six canonical `RMA_*` SavedVariables.
- Communication retains the established RMA prefixes, payloads, and protocol version 5.
- Three unconsumed exports/forwarders were removed without replacement aliases.
- Logger and Attendance use seven focused shared list primitives while retaining controller-owned behavior and presentation.
- The repaired v1.1 tree passed 512/512 tests and the applicable WotLK static gates.
- Screen Notice, Loot initialization, Logger, and Attendance have approved client observations; Trade completion plus genuine uncertainty/retry remains deferred and unpassed.

Planning history is archived under `.planning/milestones/`. No milestone requirements are active.

## Requirements

### Validated

- ✓ Interface 30300 load order, `/rma`, Lua 5.1 compatibility, and layout-only XML — existing and revalidated through v1.1.
- ✓ Raid, loot, reserves, attendance, warnings, spammer, logger, configuration, and synchronization workflows — existing.
- ✓ Six canonical `RMA_*` SavedVariables with fail-closed quarantine for unsupported or malformed raid archives — v1.0.
- ✓ Canonical locale-independent raid admission with evidence-backed exact encounter-yell fallback data — v1.0.
- ✓ Bounded reserve and distribution response work without changing protocol version 5 — v1.0.
- ✓ Unconsumed Screen Notice, Trade-state, and Loot-state forwarding surfaces removed without changing supported entrypoints — v1.1.
- ✓ Seven focused Logger/Attendance list primitives with feature policy retained by each controller — v1.1.
- ✓ UI, runtime, localization, persistence, communication, vendored-library, and WotLK compatibility gates closed under an explicit accepted-risk disposition — v1.1.

### Active

None. The next milestone must create fresh requirements.

### Out of Scope Until Explicitly Approved

- General architecture or UI redesign — no demonstrated requirement.
- Migration from non-RMA SavedVariables or retired addon identities — requires a separate explicit import-tool request.
- Wire-format changes or protocol-version bumps — version 5 remains the compatibility contract.
- New raid-management features — require a separately scoped milestone.
- Editing vendored libraries under `Libs/` — upstream source remains outside project ownership unless a replacement milestone explicitly removes a dependency.

## Next Milestone Goals

Candidate v1.2 scope: **Dependency Optimization**. These are planning inputs, not active requirements until `$gsd-new-milestone` confirms them.

- Evaluate replacing `LibDeflate` only with byte-for-byte compatible addon-channel encoding, decoding, and Adler32 golden vectors.
- Evaluate `LibGroupTalents`, `LibTalentQuery`, `LibBabble-TalentTree`, and `CallbackHandler` as one dependency stack against the existing `InspectCoordinator`.
- Retain `LibStub`, `LibSerialize`, `ChatThrottleLib`, `LibDeformat`, and `LibBossIDs` unless repository evidence proves a safer and simpler replacement.
- Keep dependency work separate from UI cleanup and do not edit vendored sources in place.

## Context

- v1.0 Stabilization shipped 4 phases, 12 plans, and 25 tasks on 2026-08-15.
- v1.1 UI Simplification shipped 3 phases, 7 plans, and 15 tasks on 2026-08-16.
- Proprietary runtime currently contains 137 Lua files and approximately 85,803 lines.
- The local behavior suite uses an external LuaJIT shim because `lua` is not normally available on PATH.
- Accepted residual live risks remain for Trade uncertainty/retry, SavedVariables quarantine/recovery, localized multi-client synchronization, combat lockdown, and taint.
- Two unused local `GetContentWidth` aliases remain bounded non-runtime cleanup debt in Logger and Attendance.

## Constraints

- **Client compatibility:** WotLK 3.3.5a, Interface 30300.
- **Language:** Runtime Lua 5.1 only; no Retail/Classic-only APIs or Lua 5.2+ syntax.
- **Persistence:** Only the six existing `RMA_*` SavedVariables may be read or written during normal startup.
- **Data safety:** Unknown, corrupt, or future-format persisted data must fail closed without mutation.
- **Wire compatibility:** Preserve RMA prefixes, payload shapes, and protocol version unless a separately approved breaking change is required.
- **Architecture:** Preserve Database, Services, Controllers, Widgets, EntryPoints, and layout-only XML ownership boundaries.
- **Scope:** Apply the smallest demonstrated correction; avoid speculative compatibility layers and general refactors.
- **Verification:** Automation does not prove client rendering, combat, taint, SavedVariables disk behavior, localization, or multi-client integration. Unexecuted live coverage remains deferred, never PASS.

## Key Decisions

| Decision | Rationale | Outcome |
|---|---|---|
| Preserve incompatible `RMA_Raids` data and enter quarantine | Unknown persisted data must remain recoverable | ✓ Good — shipped v1.0 |
| Use canonical map-ID resolution as the only raid-admission source | Localized display strings must not control admission | ✓ Good — shipped v1.0 |
| Bound request work without changing wire payloads | Protect resources while retaining peer compatibility | ✓ Good — shipped v1.0 |
| Separate automated, observed, and deferred verification evidence | Unavailable live checks must not become fabricated PASS results | ✓ Good — retained through v1.1 |
| Remove only repository-proven dead exports/forwarders | Historical compatibility alone does not justify unused public surface | ✓ Good — shipped v1.1 |
| Share only stable Logger/Attendance mechanics | Two consumers justify focused primitives, not a framework or DSL | ✓ Good — shipped v1.1 |
| Keep feature geometry and behavior controller-owned | Shared UI code must not absorb Source, Spec/Inspect, or contextual policy | ✓ Good — shipped v1.1 |
| Supersede a complete gate after any later runtime repair | Final evidence must describe the actual shipped runtime tree | ✓ Good — repaired tree passed 512/512 |
| Split UI simplification from dependency optimization | Codec and talent-stack replacement require separate compatibility proof | ✓ Good — v1.2 candidate scope retained |

<details>
<summary>Archived v1.1 planning scope</summary>

The v1.1 milestone removed three unconsumed runtime paths, introduced seven focused list primitives, migrated Logger and Attendance, and closed compatibility under the approved accepted-risk policy. Full phase history, requirements, audit, plans, summaries, and verification reports are stored under `.planning/milestones/v1.1-*`.

</details>

---

_Last updated: 2026-08-16 after v1.1 UI Simplification milestone_
