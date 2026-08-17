# Architecture Research

**Domain:** Dependency reduction in a WotLK 3.3.5a / Lua 5.1 raid addon
**Researched:** 2026-08-17
**Confidence:** HIGH for current ownership and call paths; MEDIUM for talent-stack replacement until client behavior is observed

## Standard Architecture

### System Overview

```text
┌──────────────────────────────────────────────────────────────────────┐
│ Existing product consumers                                           │
│ Controllers / Widgets / Slash / Raid, Loot, Reserves, Sync services │
└───────────────────────────────┬──────────────────────────────────────┘
                                │ stable RMA APIs and events
┌───────────────────────────────┴──────────────────────────────────────┐
│ RMA-owned integration boundaries                                     │
│                                                                      │
│ addon.Comms.Payload       addon.DB.RaidEvents    Services.SpecInspect│
│ Serialize / Deserialize   raid UID / digest     snapshot/cache/event │
└──────────────┬─────────────────────┬───────────────────┬─────────────┘
               │                     │                   │
┌──────────────┴─────────────────────┴──────┐  ┌─────────┴─────────────┐
│ Candidate RMA-owned byte primitives      │  │ Existing inspect owner │
│ addon.WireCodec                           │  │ InspectCoordinator     │
│ addon-channel encode/decode + Adler32    │  │ queue/throttle/combat  │
└───────────────────────────────────────────┘  └─────────┬─────────────┘
                                                        │
                                              WoW 3.3.5 talent APIs
                                              and forwarded events
```

The safe shape is not a new dependency framework. It is two narrow decisions:

1. Replace only the three `LibDeflate` operations actually consumed by RMA with a small shared module, after side-by-side byte equivalence.
2. Replace the complete talent stack inside the existing `Services.SpecInspect` boundary, using `InspectCoordinator` and the client talent APIs directly. Keep every public SpecInspect method and `SpecInspectUpdated` payload stable.

`CallbackHandler-1.0` remains loaded and untouched. It is not part of either removal decision.

### Component Responsibilities

| Component | Responsibility | Required treatment |
|---|---|---|
| `Raid Management Addon.toc` | Authoritative dependency and runtime load order | Keep candidates loaded during proof; remove a candidate only after its gate passes |
| `addon.WireCodec` (candidate) | Byte-for-byte addon-channel encode/decode and unsigned Adler32 | New small module under `Modules/`; no serialization, compression, transport, or persistence policy |
| `addon.Comms.Payload` | `LibSerialize` envelope conversion and stable error categories | Modify only its codec binding; preserve protocol-5 shapes and bytes |
| `addon.DB.RaidEvents` | Canonical raid UID and state digest creation | Modify only its Adler32 binding; preserve exact formatted output |
| `Services.InspectCoordinator` | Single global inspect target, 1.75-second cadence, combat deferral, timeout, bounded queue | Reuse unchanged unless a demonstrated defect blocks direct talent inspection |
| `Services.SpecInspect` | Talent request policy, transient cache, dual-spec snapshot compatibility, role/icon projection, `SpecInspectUpdated` | Replace the vendored adapter internally; preserve its public methods and event contract |
| `Services.EquipInspect` | Equipment request lifecycle and persistence of compact inspect fields | Keep as consumer; verify simultaneous `INSPECT_TALENT_READY` handling remains owner-safe |
| `CallbackHandler-1.0` | Callback support for retained vendored libraries | Retain in TOC and do not edit |

## Current Call and Data Paths

### LibDeflate Path

```text
Feature protocol (version 5 envelope/table)
    ↓
addon.Comms.Payload.Serialize
    ↓ LibSerialize:Serialize
serialized binary string
    ↓ LibDeflate:EncodeForWoWAddonChannel
addon-message-safe bytes
    ↓ ChatThrottleLib / feature chunking
WoW addon channel

WoW addon channel
    ↓
addon.Comms.Payload.Deserialize
    ↓ LibDeflate:DecodeForWoWAddonChannel
serialized binary string
    ↓ LibSerialize:Deserialize
validated feature protocol consumer
```

`Payload.Serialize` does **not** call `CompressDeflate`; it only encodes the serialized bytes. The encoded output is consumed by version checks, raid sync, reserves sync, and loot distribution. This makes byte output—not merely round-trip equivalence—the wire contract.

The second path is independent of messaging:

```text
canonical raid UID seed ──────┐
                              ├─ LibDeflate:Adler32 ─ formatted 8-hex UID/digest
canonical encoded raid state ─┘
```

These values participate in stable raid identity, state comparison, replication, and persisted history. They must retain unsigned 32-bit results and the existing lowercase `%08x` formatting.

The vendored addon-channel codec is exactly `CreateCodec("\000", "\001", "")`: NUL and byte `0x01` are escaped, extended bytes remain unchanged, and decode rejects raw NUL. A replacement must also match malformed-input behavior, not just successful round trips.

### Atomic Talent Stack Path

```text
READY_CHECK / slash refresh / roster-driven demand / UI cache miss
    ↓
Services.SpecInspect
    ↓ InspectCoordinator:Request(category = "talents")
LibGroupTalents:RefreshTalentsByUnit
    ↓
LibTalentQuery queue / NotifyInspect / INSPECT_TALENT_READY
    ↓
LibGroupTalents cache and callbacks
    ↓
Services.SpecInspect rebuilds compatibility snapshot
    ↓ Bus: SpecInspectUpdated
RaidGrid / LootCounter / Master controller / RollRows

Equipment inspect owns global target
    ↓ same INSPECT_TALENT_READY
Services.EquipInspect reads Services.SpecInspect:GetUnitTalentSnapshot
    ↓
existing compact player.inspect fields in RMA_Raids
```

`Services.SpecInspect` consumes only these `LibGroupTalents` surfaces:

- `RefreshTalentsByUnit`
- `GetUnitTalentSpec` and `GetGUIDTalentSpec`
- `GetNumTalentGroups` and `GetActiveTalentGroup`
- `GetTalentTabInfo`
- `GetUnitRole`
- `LibGroupTalents_Update` and `LibGroupTalents_UpdateComplete`

The current monkey patch on `LibTalentQuery.CheckInspectQueue` exists solely to prevent the vendored queue from overwriting an equipment-owned inspect target. A direct implementation should delete that adapter and submit all talent requests through `InspectCoordinator`; it must not create a second queue or `OnUpdate` poller.

`LibBabble-TalentTree` is used by `LibTalentQuery` only to validate the first localized tree name. A direct result reader can obtain localized tree names and icons from `GetTalentTabInfo` after `INSPECT_TALENT_READY`, avoiding a replacement localization dataset.

The vendored group library also has an out-of-range peer communication path and proactive roster refresh behavior. These are architectural stop gates: they cannot silently disappear if characterization or client observation shows that RMA relies on them.

## Recommended Project Structure

```text
Raid Management Addon/
├── Libs/
│   ├── CallbackHandler-1.0/       # retained unchanged
│   ├── LibDeflate/                # removed only after codec parity gate
│   ├── LibTalentQuery-1.0/        # all three removed together only after talent gate
│   ├── LibGroupTalents-1.0/
│   └── LibBabble-TalentTree-3.0/
├── Modules/
│   ├── WireCodec.lua              # new only if LibDeflate replacement passes
│   └── Comms.lua                  # bind to WireCodec; retain Payload API/errors
├── Database/
│   └── DBRaidEvents.lua           # bind Adler32 to WireCodec
├── Services/
│   ├── InspectCoordinator.lua     # existing global ownership boundary
│   ├── SpecInspect.lua            # direct talent API integration, same public contract
│   └── EquipInspect.lua           # unchanged consumer unless evidence requires a tiny hook
├── Modules/Events.lua             # modify only if an additional forwarded WoW event is proven necessary
├── Init.lua                       # modify only for proven event forwarding
└── Raid Management Addon.toc      # load candidate module before consumers; conditional removals

tests/
├── lua/harness/
│   ├── codec parity vectors       # compare candidate against vendored LibDeflate before removal
│   └── 40_inspect_foundations.lua # replace library-shaped fixtures with stable SpecInspect behavior
└── Python contract launchers      # update only assertions tied to removed vendor names/load paths
```

### Structure Rationale

- **`Modules/WireCodec.lua`:** encoding and checksum are shared, stateless runtime primitives used by both `Modules/Comms.lua` and `Database/DBRaidEvents.lua`; neither owner should depend on the other.
- **`Services/SpecInspect.lua`:** it is already the sole proprietary adapter and public contract for the talent stack. A new talent framework or compatibility facade would preserve the dependency-shaped API unnecessarily.
- **No talent dataset:** localized talent names and icons should come from the inspected client's 3.3.5 APIs. Static copies would recreate `LibBabble` ownership and add locale drift.
- **No SavedVariables owner changes:** talent cache remains transient. `EquipInspect` continues to persist only its current compact fields through existing database owners.

## Architectural Patterns

### Pattern 1: Proof Before Cutover

**What:** Load the vendored implementation and candidate together in the test environment, compare outputs, then change production bindings and finally remove the vendor directory/TOC entry.

**When to use:** Both candidate decisions, because a keep decision is valid and removal is conditional.

**Trade-offs:** The proof stage temporarily carries both implementations in tests, but avoids permanent fallback code and permits exact differential evidence.

For the codec, the differential corpus must cover all 256 individual bytes, byte pairs involving `0x00`/`0x01`, extended bytes, empty and long strings, malformed encoded inputs, RFC-style Adler32 vectors, and captured protocol-5 payloads/digests. Do not ship a runtime switch or retain LibDeflate as a fallback after a successful cutover.

### Pattern 2: Stable Facade, Replaced Interior

**What:** Keep `Services.SpecInspect` methods and `SpecInspectUpdated` stable while replacing only their internal library adapter with direct client reads.

**When to use:** Talent-stack replacement.

**Trade-offs:** `SpecInspect.lua` owns more concrete WotLK behavior, but it already owns talent cache and projection policy. This is simpler than introducing an RMA clone of three generic libraries.

Required stable outputs include active and secondary spec name/icon, dominant tree, point totals, active/total group numbers, normalized role, GUID/class/timestamp, cache staleness behavior, refresh result categories, and update-event semantics.

### Pattern 3: One Global Inspect Owner

**What:** Every direct `NotifyInspect` call is started through `Services.InspectCoordinator`, correlated by owner plus GUID, and released only on matching terminal data or timeout.

**When to use:** Talent refresh and the existing equipment flow.

**Trade-offs:** Inspections are serialized and slower by design. This preserves correctness around the client-global inspect target and avoids the current LTQ monkey patch.

The forwarded `INSPECT_TALENT_READY` handler may be observed by both talent and equipment services, but only the category owner may finalize/release its request. Equipment-owned results may still be read silently by `GetUnitTalentSnapshot`, as they are today.

## Replacement Data Flows

### Candidate Codec Flow

```text
LibSerialize bytes
    ↓ addon.WireCodec.EncodeForAddonChannel
exact legacy wire bytes
    ↓ unchanged protocol-5 validation/chunking/transport

canonical state bytes
    ↓ addon.WireCodec.Adler32
exact existing UID/digest text
```

`WireCodec` must expose plain module functions rather than emulate `LibStub` or the entire `LibDeflate` object. Only the consumed contract should be owned.

### Candidate Talent Flow

```text
refresh demand
    ↓ resolve stable unit + GUID
InspectCoordinator:Request(owner, unit, guid, onStart, onFinish, "talents")
    ↓ onStart: NotifyInspect(unit) (or direct self-read)
wow.INSPECT_TALENT_READY(guid)
    ↓ verify coordinator owner and current UnitGUID
GetActiveTalentGroup / GetNumTalentGroups / GetTalentTabInfo / GetTalentInfo
    ↓ build same SpecInspect compatibility snapshot and role
cache by normalized name/GUID
    ↓ SpecInspectUpdated only on display change
InspectCoordinator:Release(owner, guid)
```

For remote dual specs, read all groups while the inspect result is current. For self, use the non-inspect form of the same 3.3.5 APIs. Role calculation must reproduce the current class/tree behavior, including the Death Knight and Feral Druid talent checks if role remains an observable field.

Roster updates may trigger bounded demand through the existing `wow.RAID_ROSTER_UPDATE` bus event. Add `PLAYER_TALENT_UPDATE` forwarding only if characterization proves lazy self-read plus current refresh triggers are insufficient. Do not restore the vendored frame's broad event set speculatively.

## Integration Points

### External Runtime APIs

| API | Integration pattern | Architectural note |
|---|---|---|
| `LibSerialize` | Retained in `Comms.Payload` | Serialized bytes must remain unchanged |
| WoW addon channel / `ChatThrottleLib` | Existing transport only | No prefix, envelope, chunk, or priority changes |
| `NotifyInspect`, `ClearInspectPlayer` | Only through `InspectCoordinator` lifecycle | Never issue a parallel talent inspect directly |
| `INSPECT_TALENT_READY` | Existing centralized event forwarding and Bus callback | Correlate by GUID/category before mutation or release |
| `GetTalentTabInfo`, `GetTalentInfo` | Read current self/inspect result | WotLK signatures and Lua 5.1 only |
| `GetActiveTalentGroup`, `GetNumTalentGroups` | Capture active and secondary groups | Preserve dual-spec snapshot fields |

### Internal Boundaries

| Boundary | Communication | Invariant |
|---|---|---|
| Feature protocols ↔ `Comms.Payload` | Direct module API | Version 5 and payload shapes unchanged |
| `Comms.Payload` / `DBRaidEvents` ↔ `WireCodec` | Direct stateless calls | Exact bytes and unsigned Adler32 |
| `SpecInspect` ↔ `InspectCoordinator` | Request/release API | One global inspect owner; existing bounds/timeouts |
| `SpecInspect` ↔ UI/services | Existing getters + `SpecInspectUpdated` | No consumers learn about the replacement |
| `EquipInspect` ↔ `SpecInspect` | `GetUnitTalentSnapshot` | Existing persisted compact fields unchanged |
| Runtime ↔ SavedVariables | Existing Database owners only | No new keys, schemas, or migration |

## New vs. Modified Files

| Decision | New | Modified | Removed only after PASS |
|---|---|---|---|
| LibDeflate replace | `Modules/WireCodec.lua`; focused differential tests | TOC, `Modules/Comms.lua`, `Database/DBRaidEvents.lua`, vendor-name contract fixtures/diagnostics only where now false | `Libs/LibDeflate/` |
| LibDeflate keep | Research/test evidence only | No runtime or TOC change | Nothing |
| Talent stack replace | Prefer no new runtime file; focused direct-API behavior tests | `Services/SpecInspect.lua`, TOC, existing talent fixtures; `Init.lua`/`Modules/Events.lua` only if a proven event is needed | All of `LibGroupTalents-1.0/`, `LibTalentQuery-1.0/`, `LibBabble-TalentTree-3.0/` together |
| Talent stack keep | Research/test evidence only | No runtime or TOC change | Nothing |

Do not rename `CallbackHandler`, remove it, or edit its vendored source in any branch of the decision.

## Phase and Build Order

1. **Lock contracts and characterize current behavior.** Record exact TOC order, current LibDeflate outputs, protocol-5 golden frames/digests, SpecInspect snapshots/events, direct API behavior, coordinator races, dual specs, roles, locales, roster refresh, and out-of-range peer behavior. Keep all vendors loaded.
2. **Prove the codec candidate in isolation.** Add the minimal module and differential tests while LibDeflate remains available as oracle. If every byte/malformed/checksum/golden-wire gate passes, bind RMA owners to it, run the full relevant suite, then remove `LibDeflate` and its TOC line. Otherwise delete/revert the candidate and record KEEP.
3. **Prove direct talent ownership behind `SpecInspect`.** Replace library fixtures with contract tests, route direct requests through `InspectCoordinator`, and verify equipment/talent ownership, cache/event outputs, active/secondary groups, roles, localization, roster behavior, and timeout/error categories. Keep the three vendors in place until automated and live evidence passes.
4. **Perform the atomic talent cutover.** Only after the talent gate passes, remove all three TOC entries and directories in one task. If any required behavior fails, restore/retain all three; no partial removal is allowed.
5. **Run final compatibility and package gates.** Full suite, TOC validator, Lua 5.1 lint, `xpcall` scan, XML-handler scan, vendored integrity/TOC checks, protocol-5 golden comparisons, SavedVariables reload smoke test, and multi-client talent observation. A final package must contain only the chosen dependency set.

The two replacement decisions are independent. A PASS/replace for one does not justify replacing the other.

## Architectural Stop Conditions

### Stop and KEEP LibDeflate if

- candidate encoding differs for any input byte sequence, including `0x00`, `0x01`, or `0x80`-`0xFF`;
- decode acceptance/rejection or returned bytes differ for malformed or valid input;
- any Adler32 number, `%08x` UID/digest, or captured protocol-5 message differs;
- repository search finds a real runtime need for compression or another LibDeflate API not covered by the narrow candidate;
- Lua 5.1 arithmetic cannot preserve the unsigned result on the target client;
- removal requires modifying vendored sources rather than changing RMA-owned bindings and TOC.

### Stop and KEEP the complete talent stack if

- active or secondary talent group, point totals, localized name, icon, dominant tree, or role cannot be reconstructed reliably from 3.3.5 APIs;
- matching `INSPECT_TALENT_READY` cannot safely coexist with `EquipInspect` under `InspectCoordinator`;
- direct replacement changes `SpecInspect` public methods, stable error categories, cache/update semantics, or persisted `player.inspect` fields;
- required roster, out-of-range, offline, respec, or cross-locale behavior demonstrably depends on the LGT peer protocol and cannot be retained without a new wire contract;
- replacement needs an `OnUpdate` polling queue, a second inspect owner, Ace2/Ace3, Retail APIs, Lua 5.2+, new SavedVariables, or edits under `Libs/`;
- any one of the three libraries would need to remain. The decision is all-three replace or all-three keep.

### Global stop conditions

- protocol version 5, prefix, envelope, chunk, payload, or checksum behavior changes;
- any of the six `RMA_*` SavedVariables changes schema or normal startup ownership;
- TOC validation, Lua 5.1 checks, full tests, or relevant client smoke tests fail after two evidence-based repair cycles;
- the final evidence describes a different runtime tree than the proposed removal commit.

## Scaling Considerations

This is an in-client addon, so user-count scaling is not the architectural driver. Bounds and client-global resources are.

| Pressure | Existing/candidate response |
|---|---|
| Larger raid roster | Reuse the 40-request `InspectCoordinator` queue and current cadence; do not add parallel inspection |
| Repeated UI reads | Keep the 30-minute transient SpecInspect cache and display-change event suppression |
| Large wire payloads | Preserve existing feature chunking and 243-byte validation; codec replacement must not change expansion |
| Long persisted history | Preserve canonical encoding plus Adler32 digest; no new persisted cache |

The first bottleneck is the client-global inspect target, already bounded by `InspectCoordinator`. The second is addon-channel message size/throttle, already owned by feature protocols and `ChatThrottleLib`. Neither warrants a new abstraction in v1.2.

## Anti-Patterns

### Reimplementing Full Vendor APIs

**What people do:** Create RMA clones registered in `LibStub` under the old library names.

**Why it is wrong:** It preserves generic compatibility surface that has no repository consumer and makes proof much larger.

**Do this instead:** Own only three byte primitives and the existing SpecInspect product contract.

### Round-Trip-Only Codec Testing

**What people do:** Accept a codec because its own encode/decode round trip succeeds.

**Why it is wrong:** Peers, persisted digests, and protocol fixtures require legacy byte output, not merely semantic recovery.

**Do this instead:** Differentially compare candidate output and malformed-input behavior against the vendored oracle plus captured protocol-5 vectors.

### Parallel Inspect Queues

**What people do:** Replace LTQ with a new frame and `OnUpdate` queue beside `InspectCoordinator`.

**Why it is wrong:** `NotifyInspect` uses client-global state and would recreate the equipment/talent race already guarded in `SpecInspect.lua`.

**Do this instead:** Use the existing coordinator as the only request scheduler and correlate completion by GUID/category.

### Partial Talent Removal

**What people do:** Remove only Babble or LTQ while retaining LGT through a shim.

**Why it is wrong:** It violates the milestone's atomic decision and leaves dependency-shaped compatibility code.

**Do this instead:** Remove all three only after end-to-end proof; otherwise keep all three unchanged.

### Runtime Fallbacks After Proof

**What people do:** Ship both implementations with feature detection or fallback.

**Why it is wrong:** It increases the owned surface and makes actual runtime behavior environment-dependent.

**Do this instead:** Use side-by-side comparison only during tests; ship exactly one proven path.

## Sources

Repository evidence (authoritative for current architecture):

- `AGENTS.md` — runtime, ownership, persistence, wire, vendored-source, and verification policy.
- `.planning/PROJECT.md` — v1.2 goal, atomic talent decision, version-5 and SavedVariables constraints.
- `Raid Management Addon/Raid Management Addon.toc` — authoritative dependency and runtime load order.
- `Raid Management Addon/Modules/Comms.lua:34-80` — actual LibDeflate codec consumption and stable Payload errors.
- `Raid Management Addon/Database/DBRaidEvents.lua:619-642` — Adler32 raid UID and digest consumers.
- `Raid Management Addon/Libs/LibDeflate/LibDeflate.lua:343-391,2918-3112` — vendored Adler32 and addon-channel codec behavior (read only).
- `Raid Management Addon/Services/SpecInspect.lua:1-595` — sole proprietary talent-stack adapter, cache, public API, callbacks, and coordinator integration.
- `Raid Management Addon/Services/InspectCoordinator.lua:1-188` — inspect serialization, bounds, throttle, combat behavior, timeout, and release contract.
- `Raid Management Addon/Services/EquipInspect.lua:328-364,914-960` — talent snapshot consumer and shared inspect-ready flow.
- `Raid Management Addon/Libs/LibTalentQuery-1.0/LibTalentQuery-1.0.lua:35-67,143-312,324-355` — vendored inspection queue, result validation, and Babble use (read only).
- `Raid Management Addon/Libs/LibGroupTalents-1.0/LibGroupTalents-1.0.lua:57-121,465-485,783-905,1151-1250,1555-1626` — vendored callbacks, talent projection, role logic, and consumed getters (read only).
- `tests/lua/harness/20_raid_database.lua:1623-1651` and `tests/lua/harness/50_reserves_messaging.lua:2590-2593` — current binary-channel and malformed-payload coverage.
- `tests/lua/harness/40_inspect_foundations.lua:240-367,600-778` — current coordinator/LGT correlation and actual vendored queue guard coverage.

No external source was needed to map the repository architecture. Client behavior that automation cannot establish remains an explicit live verification gate.

---
*Architecture research for: v1.2 Dependency Optimization*
*Researched: 2026-08-17*
