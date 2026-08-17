# Feature Research

**Domain:** Brownfield dependency optimization for a WotLK 3.3.5a raid-management addon
**Milestone:** v1.2 Dependency Optimization
**Researched:** 2026-08-17
**Confidence:** HIGH for repository-visible contracts; MEDIUM for behavior that still requires a live multi-client 3.3.5a observation

## Research Boundary

This milestone is not a product-feature expansion. Its user-visible success condition is that RMA continues to behave exactly as it does today while carrying less vendored dependency code where, and only where, compatibility is demonstrated.

Two independent decisions are in scope:

1. Keep or replace `LibDeflate` for the exact subset RMA consumes.
2. Keep or replace `LibGroupTalents-1.0`, `LibTalentQuery-1.0`, and `LibBabble-TalentTree-3.0` as one atomic stack.

`CallbackHandler-1.0` explicitly remains unchanged. A valid milestone outcome may replace neither candidate when the proof gates do not close.

## Feature Landscape

### Table Stakes (Must Remain Observable)

| Behavior | Why Required | Complexity | Repository Contract |
|---|---|---:|---|
| RMA v5 peers exchange identical addon-message payload bytes | Encoding is part of every current RMA addon-message protocol, not an internal implementation detail | HIGH | `Modules/Comms.lua` serializes with `LibSerialize`, then calls `EncodeForWoWAddonChannel`; inbound data follows the exact inverse path. Protocol version remains `5`. |
| All binary Lua strings encode and round-trip through the addon-channel codec | Serialized payloads may contain any byte; WoW addon messages cannot carry NUL unchanged | MEDIUM | The current codec maps `00 -> 01 02` and `01 -> 01 03`, leaves `0x02`-`0xff` unchanged, emits no NUL, and returns `nil` when raw NUL is present during decode. |
| Malformed input retains the current fail-closed behavior and stable RMA error taxonomy | A replacement must not turn damaged traffic into accepted payloads or leak library errors into feature code | MEDIUM | `Payload.Serialize` returns `SERIALIZE_FAILED` or `CHANNEL_ENCODE_FAILED`; `Payload.Deserialize` returns `MALFORMED_PAYLOAD`, `CHANNEL_DECODE_FAILED`, or `DESERIALIZE_FAILED`, with library calls protected by `pcall`. |
| Adler32 results remain identical unsigned 32-bit values for every byte string | Checksums participate in stable raid identity and canonical state digests | HIGH | `DBRaidEvents.CreateRaidUid` formats Adler32 as eight lowercase hex digits; `DigestState` formats `<8-hex>:<canonical-byte-count>`. Any checksum drift changes IDs, conflict detection, and sync decisions. |
| Existing raid UIDs and state digests remain reproducible | Persisted and exchanged histories must retain identity across old and new RMA clients | HIGH | Adler32 input construction and canonical encoding are existing compatibility contracts; the six `RMA_*` SavedVariables and their schemas must not change. |
| Specialization refresh remains asynchronous and user-invocable | Raid leaders already use `/rma specinspect`, `/rma specinspect force`, and `/rma inspectspec` | HIGH | `SpecInspect.RefreshPlayer`, raid sweep, ready-check refresh, cached results, and the documented queued/skipped/unavailable/delayed outcomes are current behavior. |
| Talent and equipment inspection remain globally serialized | The WotLK client has one global inspect target; competing `NotifyInspect` flows can corrupt results | HIGH | `InspectCoordinator` owns target, queue, combat deferral, timeout, throttle, and cleanup. The current `LibTalentQuery.CheckInspectQueue` guard prevents talent work while equipment owns inspection. |
| Talent completion is correlated to the requested GUID | An unrelated inspect completion must not release another request or publish the wrong player's spec | HIGH | `pendingTalentByGuid`, `LibGroupTalents_Update`, and `LibGroupTalents_UpdateComplete` release only the matching coordinator owner; focused tests exercise unrelated and matching GUIDs. |
| Current and secondary talent groups remain available | Attendance persists and displays primary and secondary specialization data | HIGH | Required snapshot fields include `activeGroup`, `numGroups`, per-group points/name/icon/main tree, plus `secondarySpecName`, `secondaryIcon`, `secondaryGroup`, and `secondaryMainTalentTree`. |
| Specialization names, icons, and roles remain correct on supported locales | RaidGrid, Loot Counter, and Attendance consume icons/names; Attendance sorts and shows tooltips; roles are normalized for runtime consumers | HIGH | RMA consumes `GetUnitTalentSpec`, `GetTalentTabInfo`, `GetUnitRole`, `GetActiveTalentGroup`, and `GetNumTalentGroups`. `LibBabble-TalentTree` currently localizes LibTalentQuery's first-tree validation outside enUS/enGB. |
| Cached spec display remains stable and event-driven | Missing or delayed inspection must not erase usable display data or add polling | MEDIUM | `SpecInspect` caches by normalized player name/GUID for 1800 seconds and emits `SpecInspectUpdated` only when display fields change; RaidGrid and Loot Counter redraw from that event. |
| Ready equipment snapshots retain spec fields without altering persistence semantics | Successful equipment inspection currently captures gear plus available talent data | HIGH | `EquipInspect` copies primary/secondary spec fields into the canonical ready snapshot. Failed/pending attempts remain runtime-only, and changed ready snapshots advance revision under existing rules. |
| Runtime remains WotLK 3.3.5a / Interface 30300 / Lua 5.1 safe | The addon must load on the target client | HIGH | No Retail/Classic-only API, Lua 5.2+ syntax, Ace2, or Ace3 may be introduced. Combat and protected inspect restrictions remain binding. |

### Optimization Value (Why Replace At All)

| Capability | Value Proposition | Complexity | Notes |
|---|---|---:|---|
| Minimal owned addon-channel codec plus Adler32 implementation | Removes the unused compression/decompression, zlib, dictionary, chat/print codec, and test surfaces from the shipped `LibDeflate` file | MEDIUM | Justified only if exhaustive/golden parity is easier to verify than retaining the library. RMA does not call Deflate/Zlib compression APIs. |
| RMA-owned talent acquisition matched to `SpecInspect` and `InspectCoordinator` | Can remove a broad legacy talent/glyph/comm library stack and the method-patching guard while clarifying inspect ownership | HIGH | Replacement needs only demonstrated RMA behaviors, not the entire public API of the three libraries, but it must preserve every behavior RMA actually observes. |
| Evidence-backed keep decision | Avoids risky churn when a smaller implementation cannot reproduce wire or live inspect behavior | LOW | Keeping a dependency is a successful decision when a gate fails; no forced removal target exists. |
| TOC and package cleanup after proven replacement | Ensures removed libraries are truly absent from load order and release contents | LOW | Apply only after the relevant proof suite passes. Never edit the vendored source in place. |

### Anti-Features (Explicitly Avoid)

| Anti-Feature | Surface Appeal | Why Problematic | Required Alternative |
|---|---|---|---|
| Replace `LibDeflate` with Base64, JSON, compression, or a new wire format | A familiar or smaller codec may look cleaner | Changes RMA payload bytes, size, interoperability, and possibly protocol semantics | Preserve exact `LibSerialize` bytes and exact addon-channel encoding under protocol v5. |
| Add compression because `LibDeflate` supports it | Could reduce some message sizes | RMA currently does not compress wire payloads; compressed SoftRes import is intentionally unsupported due to lack of bounded-output inflate | Keep compression out of v1.2. |
| Accept decode round-trip parity without byte-output parity | Round trips can pass even when peers see different wire bytes | Existing v5 clients and golden payloads require deterministic byte compatibility | Compare encoded bytes directly for exhaustive and real payload vectors, then cross-decode old/new outputs. |
| Reimplement the full public API of either library family | Appears safer than identifying actual consumers | Recreates large unused surfaces, increases defect risk, and violates KISS/YAGNI | Implement only the repository-proven codec/checksum or talent contracts. |
| Remove only one or two talent libraries | May produce an incremental line-count win | The user requires one atomic decision; hidden load/runtime coupling spans LGT -> LTQ -> LibBabble validation | Remove all three together or keep all three. |
| Remove or replace `CallbackHandler-1.0` | It is adjacent to the talent stack | Explicitly excluded; it may serve other current/future vendored consumers and is not part of the approved decision | Leave its source and TOC entry unchanged. |
| Let talent code call `NotifyInspect` outside `InspectCoordinator` | Simplifies a local implementation | Reintroduces races with equipment inspection and violates the single global-target contract | Route talent requests through the existing coordinator and retain category ownership. |
| Add another `OnUpdate` poller or parallel inspect scheduler | Resembles the legacy libraries' internal model | Duplicates timing/ownership and risks stale or mismatched inspect results | Use coordinator callbacks/timers and existing WoW events. |
| Preserve legacy glyph, talent-by-name, storage-string, or cross-addon talent APIs without a consumer | Could offer hypothetical compatibility | No proprietary RMA consumer was found; speculative compatibility would defeat dependency reduction | Omit unless a concrete current consumer or acceptance test proves need. |
| Change SavedVariables to store talent caches or replacement state | Makes refreshes appear faster | Expands schema, duplicates derived runtime data, and changes sync/persistence contracts | Retain the existing runtime cache and canonical last-successful equipment/spec snapshot only. |
| Edit files under `Libs/` to slim them in place | Produces a smaller diff than replacement | Vendored sources are explicitly outside project ownership | Add RMA-owned replacement code, then remove obsolete vendored directories only after acceptance. |
| Claim automated WoW behavior as live PASS | Unit tests can emulate events and API calls | They cannot establish client inspect restrictions, localized multi-client behavior, combat, or taint | Record those checks as OBSERVED only when executed in a 3.3.5a client; otherwise keep them DEFERRED and unpassed. |

## Required Behavioral Contracts

### LibDeflate Candidate: Exact Consumed Surface

RMA consumes exactly three operations:

| Operation | Required Contract |
|---|---|
| `EncodeForWoWAddonChannel(string)` | Accept a Lua string, return the exact current encoded bytes, emit no NUL, escape `0x00` and `0x01` exactly as the current codec does, and preserve bytes `0x02` through `0xff`. Non-string misuse must be contained by RMA's existing `pcall` boundary. |
| `DecodeForWoWAddonChannel(string)` | Return exactly the current decoded bytes for valid/current inputs and match current handling of raw NUL, recognized escape pairs, orphan escape bytes, unknown escape suffixes, empty strings, and arbitrary high bytes. RMA rejects empty decoded results at the payload boundary. |
| `Adler32(string)` | Return the same unsigned 32-bit Adler-32 value as the vendored library for empty strings, ASCII, NUL/high-byte input, long strings across modulo boundaries, canonical states, and UID seeds. |

No proprietary runtime call to `CompressDeflate`, `DecompressDeflate`, Zlib, dictionaries, custom codecs, chat codecs, or print codecs was found. These APIs are not replacement requirements.

### Atomic Talent Stack Candidate: Exact Consumed Surface

The replacement does not need to preserve the three libraries' global APIs. It must preserve the behavior RMA receives through `Services/SpecInspect.lua`:

| Required Capability | Existing Integration Evidence |
|---|---|
| Resolve roster unit and stable GUID before a request | `RefreshPlayer` uses Raid unit resolution and `UnitGUID`; missing names, units, GUIDs, and library support return stable failure states. |
| Request or force talent refresh for a unit | Current path calls `RefreshTalentsByUnit` through `InspectCoordinator` under the `talents` category. Duplicate pending requests for the same GUID coalesce as `queued`. |
| Read each available talent group | Current path uses `GetNumTalentGroups`, `GetActiveTalentGroup`, and `GetUnitTalentSpec(unit, group)`. |
| Derive dominant tree without inventing certainty | Three point totals determine `mainTalentTree`; ties retain the returned name but leave the dominant tree index `nil`. |
| Resolve localized tree name and icon | Current path matches `GetTalentTabInfo` name to the specialization name, first by dominant tab then by all three tabs. Missing icon makes the display snapshot incomplete rather than fabricated. |
| Normalize role | Current `tank`/`healer` map to `TANK`/`HEALER`; `melee`/`caster` map to `DAMAGER`; unknown roles remain `nil`. |
| Publish correlated completion | Matching `Update` data rebuilds the player snapshot and releases the matching GUID owner. Batch completion releases only GUIDs with readable talent data, then refreshes current roster snapshots. |
| Preserve refresh triggers and cache semantics | Ready check, manual/forced raid sweep, stale cache, GUID change, and equipment inspect all continue to use the same service contract and `SpecInspectUpdated` event. |
| Defer safely under client constraints | Combat, inspect throttling, queue bounds, timeout, `ClearInspectPlayer`, and equipment/talent exclusion remain owned by `InspectCoordinator`. |
| Support target locales without false validation failure | The current stack localizes its class first-tree validation through `LibBabble-TalentTree` outside enUS/enGB. A replacement may eliminate that validation, but must not reject correct localized talent results or regress supported RMA locales. |

Legacy LGT peer-to-peer talent/glyph communication is an implementation behavior of the vendored library, but no proprietary RMA code calls its glyph, storage, talent-by-name, or comm APIs. Removal does not require protocol compatibility with the `LibGroupTalents-1.0` addon-message prefix unless a focused live/repository test demonstrates that RMA's documented specialization refresh depends on out-of-range peer exchange. Until that is disproved, out-of-range/multi-client refresh remains a MEDIUM-confidence live-risk gate, not an assumed removable feature.

## Feature Dependencies

```text
[RMA protocol v5 payload compatibility]
    |-- requires --> [LibSerialize output unchanged]
    |-- requires --> [byte-identical addon-channel encode/decode]
    `-- requires --> [existing RMA prefix, envelope, chunk, and transport behavior]

[stable raid UID and state digest]
    |-- requires --> [canonical input bytes unchanged]
    `-- requires --> [unsigned Adler32 parity]

[primary/secondary spec display and persistence]
    |-- requires --> [group count + active group]
    |-- requires --> [three tree point totals + localized names/icons]
    |-- requires --> [GUID-correlated asynchronous completion]
    `-- requires --> [SpecInspect cache/event contract]

[safe talent refresh]
    `-- requires --> [InspectCoordinator exclusive global inspect ownership]
                          `-- conflicts --> [independent LTQ-style OnUpdate/NotifyInspect scheduler]

[remove talent stack]
    `-- requires --> [replace all required behavior of LGT + LTQ + LibBabble]

[CallbackHandler-1.0]
    `-- unchanged and outside --> [atomic talent stack removal decision]
```

### Dependency Notes

- **Wire codec parity requires unchanged serialization:** encoding tests must start from both raw byte vectors and real `LibSerialize` outputs; changing serialization would invalidate codec conclusions.
- **Adler32 parity protects both persistence identity and synchronization:** it is not merely a utility checksum because its formatted output is embedded in raid UIDs and state digests.
- **Talent stack removal requires coordinator integration first:** the replacement must never create a second owner of `NotifyInspect` timing or target cleanup.
- **Dual spec depends on complete per-group reads:** primary-only parity is insufficient because the canonical ready inspect snapshot persists secondary spec fields when available.
- **Localization is behavioral, not cosmetic:** tree-name/icon matching and LTQ validation can fail when localized names differ, so supported non-English clients need explicit coverage.
- **The two candidate decisions are independent:** codec failure does not block talent-stack replacement, and talent-stack failure does not block codec replacement.

## Keep-or-Replace Acceptance Gates

### Gate A: LibDeflate

Replace and remove `LibDeflate` only when all of the following pass against the unmodified vendored implementation:

- Exhaustive single-byte and structured multi-byte golden vectors cover all `0x00`-`0xff` values, repeated NUL/escape bytes, every adjacent pair around `0x00`/`0x01`, empty input, long binary input, and deterministic repeated calls.
- Encoding output is byte-for-byte identical, not merely round-trip equivalent.
- Old encoder -> new decoder and new encoder -> old decoder both reproduce original bytes.
- Decoder behavior matches for valid data and malformed cases, including raw NUL, recognized escapes, orphan escape bytes, unknown suffixes, and high bytes.
- Adler32 matches for standard vectors, all byte values, empty input, long/modulo-boundary inputs, actual canonical raid states, and actual raid UID seeds; formatted UID/digest strings remain identical.
- Existing v5 protocol, sync, version-check, reserve/distribution messaging, chunk sizing, and error-path tests pass without changing payload shapes or version.
- Lua 5.1 syntax/runtime and WotLK static gates pass.
- Only after proof: update code ownership/docs/tests, remove the `LibDeflate` TOC entry and vendored directory, and confirm no runtime/package reference remains.

**Keep decision:** Any byte mismatch, malformed-input drift, checksum mismatch, protocol regression, or inability to prove representative v5 interoperability keeps `LibDeflate` unchanged. Do not wrap both implementations or add a fallback compatibility layer.

### Gate B: Atomic Talent Stack

Replace and remove all three talent libraries only when all of the following pass:

- Focused tests reproduce the existing `SpecInspect` public states, snapshot fields, dominant-tree tie behavior, role normalization, cache/stale/GUID rules, ready-check and manual/force triggers, and display-event deduplication.
- Primary and secondary specs, icons, group numbers, and main-tree indexes flow unchanged into equipment snapshots, Attendance, RaidGrid, and Loot Counter.
- Requests are admitted only through `InspectCoordinator`; equipment ownership blocks talent inspection, matching GUID completion releases it, unrelated completion does not, duplicate requests coalesce, and timer/queue/timeout/combat failures remain bounded and stable.
- Missing/unavailable talent data remains non-fatal: last usable display/canonical ready snapshot is preserved and no partial/corrupt persisted row is created.
- Supported locale fixtures prove correct tree names/icons without depending on English-only comparisons. At minimum cover the five RMA catalogs where client locale data is available; do not fabricate translations.
- Existing Lua behavior tests and WotLK static validators pass with `CallbackHandler-1.0` untouched.
- Live 3.3.5a observation covers at least player plus another raid member, dual spec when available, equipment/talent contention, a forced refresh, a ready-check refresh, and a supported non-English client. Multi-client/out-of-range behavior is OBSERVED or explicitly DEFERRED and unpassed; it must not be silently classified as parity.
- Only after proof: remove all three TOC entries and all three vendored directories in one accepted change, then confirm no source, test, XML, documentation, or release-package reference requires them.

**Keep decision:** Keep all three libraries if any required RMA behavior cannot be reproduced safely, if inspect ownership becomes ambiguous, if supported localization regresses, or if the remaining out-of-range/multi-client uncertainty is judged incompatible with the milestone's preservation requirement. No partial removal is allowed.

## Milestone Definition

### Required for v1.2 Completion

- [ ] Produce a reproducible keep-or-replace evidence record for `LibDeflate`.
- [ ] If Gate A passes, implement the minimal RMA-owned codec/checksum subset and remove `LibDeflate`; otherwise keep it without runtime churn.
- [ ] Produce one reproducible keep-or-replace evidence record for the atomic talent stack.
- [ ] If Gate B passes, implement the minimal RMA-owned talent path and remove all three libraries together; otherwise keep all three without partial refactoring.
- [ ] Preserve protocol v5, payload shapes, six canonical SavedVariables, Interface 30300, Lua 5.1, vendored-source integrity, and existing architectural ownership throughout.
- [ ] Separate AUTOMATED, OBSERVED, and DEFERRED evidence; a deferred live check is never PASS.

### Explicitly Out of Scope

- Protocol version changes, new envelopes, new prefixes, payload reshaping, new serialization, or new compression.
- SavedVariables schema changes, new SavedVariables, migration/import from non-RMA keys, or persisted talent caches.
- General communication, synchronization, UI, attendance, equipment, or architecture redesign.
- New raid-management features, new slash commands, new options, or user-facing configuration for dependency selection.
- Full API compatibility for unused LibDeflate, LGT, LTQ, or LibBabble capabilities.
- Glyph tracking, talent-by-name queries, storage strings, talent sharing as a new RMA protocol, or support for consumers outside this repository.
- Ace2/Ace3 introduction, Retail/Classic APIs, Lua 5.2+ constructs, or a second inspect scheduler.
- Editing vendored library source. Libraries are either kept byte-for-byte or removed after a proven replacement.
- Removing or replacing `CallbackHandler-1.0`.

## Prioritization Matrix

| Deliverable | User/Runtime Value | Implementation Cost | Priority |
|---|---:|---:|---:|
| Golden codec/checksum parity suite and decision | HIGH | MEDIUM | P1 |
| Talent behavioral contract suite and atomic decision | HIGH | HIGH | P1 |
| Protocol v5, persistence, Lua 5.1, and TOC regression gates | HIGH | MEDIUM | P1 |
| Minimal LibDeflate replacement after Gate A | MEDIUM | MEDIUM | P1 only if proven |
| Minimal talent replacement after Gate B | MEDIUM | HIGH | P1 only if proven |
| Live localized/multi-client talent observation | HIGH | HIGH | P1 gate or explicit DEFERRED risk disposition |
| Unused legacy-library API compatibility | LOW | HIGH | Excluded |

## Sources

Repository evidence is primary:

- `.planning/PROJECT.md` — v1.2 goal, active requirements, constraints, and atomic talent-stack decision.
- `Raid Management Addon/Raid Management Addon.toc` — authoritative dependency load order and unchanged `CallbackHandler-1.0` entry.
- `Raid Management Addon/Modules/Comms.lua` — exact payload serialization/encoding/decoding boundary and protocol version 5.
- `Raid Management Addon/Database/DBRaidEvents.lua` — Adler32 use in stable raid UIDs and canonical state digests.
- `Raid Management Addon/Services/SpecInspect.lua` — exact talent APIs consumed, cache, snapshot, callback, and coordinator contracts.
- `Raid Management Addon/Services/InspectCoordinator.lua` and `Services/EquipInspect.lua` — exclusive inspect ownership and persisted ready spec fields.
- `Raid Management Addon/Services/Attendance/View.lua`, `Controllers/Attendance.lua`, `Widgets/RaidGrid.lua`, and `Widgets/LootCounter.lua` — user-visible consumers of specialization names and icons.
- `Raid Management Addon/README.md`, `docs/ARCHITECTURE.md`, and `docs/SAVED_VARIABLES.md` — documented inspection, wire, and persistence behavior.
- `tests/lua/harness/20_raid_database.lua`, `40_inspect_foundations.lua`, and `70_raid_sync.lua`; `tests/test_runtime_bootstrap_contract.py` — current automated evidence and identifiable coverage gaps.
- Unmodified vendored sources under `Raid Management Addon/Libs/LibDeflate`, `LibGroupTalents-1.0`, `LibTalentQuery-1.0`, and `LibBabble-TalentTree-3.0` — reference behavior and dependency coupling only; no edits performed.

No web source was needed for this feature-contract dimension because the repository and vendored reference implementations define the compatibility target more precisely than external documentation.

---
*Feature research for: v1.2 Dependency Optimization*
*Researched: 2026-08-17*
