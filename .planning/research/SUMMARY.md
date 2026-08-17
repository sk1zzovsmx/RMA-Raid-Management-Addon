# Project Research Summary

**Project:** Raid Management Addon — v1.2 Dependency Optimization
**Domain:** Brownfield dependency reduction for a WotLK 3.3.5a / Lua 5.1 raid addon
**Researched:** 2026-08-17
**Confidence:** HIGH for repository-visible codec, checksum, ownership, and packaging contracts; MEDIUM for talent replacement pending real-client evidence

## Executive Summary

RMA v1.2 should reduce shipped dependency code only where compatibility is proven against the current untouched vendors. The research recommends no new external dependency, no new framework, no wire-format change, and no SavedVariables change. It identifies two independent KEEP/REPLACE decisions: `LibDeflate`, and the atomic talent unit formed by `LibGroupTalents-1.0`, `LibTalentQuery-1.0`, and `LibBabble-TalentTree-3.0`. Either decision may validly end in KEEP without blocking the other. `CallbackHandler-1.0` remains loaded and unchanged regardless of the talent result.

`LibDeflate` is the stronger replacement candidate because proprietary RMA code consumes exactly three operations: addon-channel encode, addon-channel decode, and Adler32. It does not consume DEFLATE/zlib compression. A small RMA-owned Lua 5.1 byte module is appropriate only after differential golden vectors prove byte-for-byte output, malformed-input behavior, checksum values, formatted raid UIDs/digests, and protocol-v5 interoperability against the existing implementation.

The talent stack can plausibly be replaced inside the existing `Services/SpecInspect.lua` facade using WotLK talent APIs and `Services/InspectCoordinator.lua` as the sole global inspect owner. However, automated tests cannot prove client timing, dual-spec visibility, localized names/icons, equipment contention, or peer-fed/out-of-range behavior. The three libraries must therefore remain intact until both automated contract evidence and the required real-client observations pass. Deferred evidence is explicitly unpassed and cannot authorize removal.

## Key Findings

Detailed findings: [STACK.md](./STACK.md), [FEATURES.md](./FEATURES.md), [ARCHITECTURE.md](./ARCHITECTURE.md), and [PITFALLS.md](./PITFALLS.md).

### Recommended Stack

Keep the WotLK 3.3.5a build 12340 / Interface 30300 runtime, Lua 5.1, RMA protocol version 5, `LibSerialize`, `ChatThrottleLib`, `LibStub`, the existing event bus/timer facilities, and `InspectCoordinator`. Add no external package. Replacement code, if accepted, should be a narrow addon-owned implementation rather than another generic library or a LibStub compatibility facade.

**Core technologies:**

- WotLK 3.3.5a and Lua 5.1 — binding runtime and language contract; no Retail/Classic APIs, Ace2/Ace3, DLL, `io`, or `os`.
- RMA protocol version 5 plus unchanged `LibSerialize` output — authoritative payload contract; encoding changes are not permitted.
- `Services/InspectCoordinator.lua` — sole scheduler and owner of `NotifyInspect`, target cleanup, throttling, combat deferral, timeout, and queue bounds.
- `CallbackHandler-1.0` — retained in its current TOC position and source form; explicitly outside the atomic talent removal decision.

**Exact minimal `LibDeflate` surface consumed by RMA:**

1. `EncodeForWoWAddonChannel(string)`: byte `0x00` becomes `0x01 0x02`, byte `0x01` becomes `0x01 0x03`, and bytes `0x02` through `0xff` pass through unchanged.
2. `DecodeForWoWAddonChannel(string)`: reverses those escape pairs and matches the vendor for raw NUL, orphan escape, unknown escape suffix, empty input, and high-byte behavior; RMA's existing `pcall` boundary and stable error taxonomy remain intact.
3. `Adler32(string)`: returns the identical unsigned 32-bit value for every byte string, including long inputs across modulo boundaries, and preserves exact lowercase `%08x` raid UID and `<8-hex>:<length>` digest output.

No proprietary runtime call to compression, decompression, dictionaries, custom codecs, chat/print codecs, or zlib was found. Reimplementing any of them would add unsupported scope.

### Required Outcomes

This milestone has no new user-facing feature. Its table stakes are unchanged behavior with evidence-backed dependency decisions:

- Protocol-v5 peers exchange identical serialized and addon-channel-encoded bytes, with the same malformed-input failures.
- Existing raid UIDs, canonical state digests, payload shapes, prefixes, chunk behavior, and the six canonical `RMA_*` SavedVariables remain unchanged.
- `SpecInspect` preserves manual/forced/ready-check refresh, cached and stale states, GUID-correlated completion, active and secondary groups, names, icons, point totals, dominant tree, role contract, and event deduplication.
- Talent and equipment inspection remain serialized through one coordinator; no new `OnUpdate` poller or second inspect queue is introduced.
- The talent decision is atomic: remove `LibGroupTalents-1.0`, `LibTalentQuery-1.0`, and `LibBabble-TalentTree-3.0` together, or retain all three together.
- Vendored sources are used read-only as compatibility oracles. Approved replacement deletes complete candidate directories only after proof; it never edits them.

**Explicitly excluded:** compression support, new talent wire protocols, full vendor API clones, persistent talent caches, partial talent-library removal, `CallbackHandler-1.0` cleanup, protocol bump, SavedVariables migration, and general UI/architecture redesign.

### Architecture Approach

Use proof-before-cutover and stable RMA facades. During evaluation, keep the untouched vendor and the candidate side by side in tests. If the codec gate passes, a small shared module such as `Modules/WireCodec.lua` owns only the three byte operations; `Modules/Comms.lua` and `Database/DBRaidEvents.lua` retain their current policy and output contracts. If the talent gate passes, replace only the interior of `Services/SpecInspect.lua`; do not emulate the three LibStub APIs. All direct inspection starts through `InspectCoordinator`, and completion is correlated by coordinator category/owner plus GUID before cache mutation or release.

**Major components:**

1. `Raid Management Addon/Modules/Comms.lua` — unchanged serialization envelope and stable payload error categories; only its codec binding may change.
2. `Raid Management Addon/Database/DBRaidEvents.lua` — unchanged canonical UID/digest construction; only its checksum binding may change.
3. Candidate `Raid Management Addon/Modules/WireCodec.lua` — stateless addon-channel encode/decode and Adler32 only, created only for a proven replacement.
4. `Raid Management Addon/Services/SpecInspect.lua` — stable public talent facade, cache, projection, and `SpecInspectUpdated` contract.
5. `Raid Management Addon/Services/InspectCoordinator.lua` — unchanged single owner of client-global inspect scheduling and cleanup unless a demonstrated blocker requires a focused correction.
6. `Raid Management Addon/Raid Management Addon.toc` — authoritative load order; candidate entries remain until their corresponding decision gate passes.

### Independent Decision Gates

| Decision | REPLACE only when | KEEP when |
|---|---|---|
| `LibDeflate` | Exact encoding bytes, cross-decode, malformed decode, Adler32 values, formatted UID/digest fixtures, captured v5 payloads, Lua 5.1 checks, and relevant full-suite/package checks all pass | Any mismatch occurs, another consumed vendor API is discovered, or representative v5 interoperability cannot be proven |
| Atomic talent stack | The complete `SpecInspect` contract, coordinator ownership, consumer/persistence flow, locale fixtures, and required live 3.3.5a observations all pass; then all three vendors are removed together | Any required dual-spec, role, locale, contention, roster, out-of-range, or peer-fed behavior cannot be proven; no partial cutover is permitted |

A KEEP result is successful decision evidence, not a milestone failure. No permanent dual implementation, compatibility shim, or fallback is recommended after either decision.

### Evidence Classification

| Classification | What qualifies | How it affects a gate |
|---|---|---|
| **AUTOMATED** | Differential oracle vectors, behavior tests, protocol fixtures, UID/digest corpus, TOC/Lua 5.1/`xpcall`/XML/identity scans, clean-load and package checks | Can close deterministic code and packaging contracts |
| **OBSERVED** | Executed behavior on a real 3.3.5a client, with the build/configuration and result recorded: cross-peer v5 exchange; player and raid-member inspection; dual spec where available; forced and ready-check refresh; equipment contention; supported non-English locale; reload persistence smoke | Required wherever the client runtime, localization, inspect timing, or multi-client behavior is the only authority |
| **DEFERRED** | A live check that was not executed or could not be established | Remains explicitly unpassed. It may document residual risk for a KEEP result, but it cannot authorize a removal whose acceptance gate requires that observation |

Automated mocks must never be relabeled as live PASS. Any verification after a later runtime repair supersedes earlier complete-gate evidence so the final report describes the actual proposed tree.

### Critical Pitfalls

1. **Accepting reversible instead of byte-identical encoding** — compare exact old/new bytes and malformed behavior, not only `decode(encode(x))`.
2. **Reimplementing unused DEFLATE functionality** — constrain the candidate to the three repository-proven operations.
3. **Changing Adler32 representation** — compare numeric values and exact formatted RMA UIDs/digests on binary, long, and real canonical inputs.
4. **Creating a second inspect owner** — issue `NotifyInspect` only from coordinator-owned work and release only the matching owner/GUID.
5. **Preserving only the visible primary spec** — characterize dual spec, role, icon, cache, event, ready-check, force-refresh, timeout, and consumer persistence behavior.
6. **Losing locale or peer-fed behavior** — use client-returned localized metadata and require honest real-client evidence; retain the full stack if required out-of-range behavior depends on LGT communication.
7. **Partial cleanup or premature oracle deletion** — commit characterization evidence first; remove all three talent libraries atomically and retain `CallbackHandler-1.0`.

## Implications for Roadmap

The prior milestone ended at Phase 7. Recommended v1.2 ordering starts at Phase 8 and keeps the two replacement decisions independently reversible.

### Phase 8: Dependency Contracts and Baselines

**Rationale:** Both candidates need committed compatibility oracles before implementation or deletion. Shared baseline work must precede either decision.

**Delivers:** Exact current call inventory; vendor hashes; protocol-v5 and UID/digest vectors; malformed codec corpus; full `SpecInspect` snapshot/event/error matrix; coordinator contention characterization; explicit live-test matrix; proof that `CallbackHandler-1.0` remains untouched.

**Avoids:** Circular tests, premature vendor deletion, hidden APIs, and evidence claims that conflate AUTOMATED, OBSERVED, and DEFERRED.

### Phase 9: LibDeflate KEEP/REPLACE Decision

**Rationale:** The consumed surface is deterministic, narrow, and high-confidence, making it the lower-risk replacement decision. It does not depend on the talent result.

**Delivers:** A minimal candidate byte module tested side by side with untouched LibDeflate; exhaustive and real-payload parity; exact checksum/digest parity; then either a clean REPLACE cutover and library removal, or a documented KEEP with the smallest counterexample.

**Uses:** Lua 5.1 strings/arithmetic, unchanged `LibSerialize`, RFC 1950 Adler32, existing RMA protocol tests, and WotLK validators. No compression implementation and no new dependency.

### Phase 10: Atomic Talent Stack KEEP/REPLACE Decision

**Rationale:** Talent replacement has broader asynchronous and client-only behavior. It should begin only after Phase 8 has frozen the facade and observation requirements, but remains independent of Phase 9's outcome.

**Delivers:** Direct talent acquisition behind the stable `SpecInspect` facade, coordinator-only inspection, dual-spec/name/icon/points/tree/role/cache/event parity, consumer and persistence verification, and required real-client observations. On PASS, remove all three talent libraries and TOC entries together; otherwise restore/retain all three with a documented KEEP. `CallbackHandler-1.0` remains unchanged in both branches.

**Avoids:** Parallel inspect queues, partial stack cleanup, English-only control flow, speculative vendor API clones, and silently dropped LGT peer/out-of-range behavior.

### Phase 11: Final Compatibility and Package Gate

**Rationale:** The final evidence must validate the actual selected combination: KEEP/KEEP, REPLACE/KEEP, KEEP/REPLACE, or REPLACE/REPLACE.

**Delivers:** Full relevant suite, static WotLK gates, protocol-v5 golden verification, SavedVariables/reload smoke, clean standalone TOC/package load, retired-reference scans, vendor integrity proof for retained libraries, and a decision record separating AUTOMATED, OBSERVED, and DEFERRED results.

**Avoids:** Shipping evidence from an earlier tree, accidental dependence on another addon's globals, incomplete package cleanup, and overstated live compatibility.

### Phase Ordering Rationale

- Phase 8 protects both decisions by preserving the current libraries as black-box oracles and freezing the compatibility contracts first.
- Phase 9 comes before the talent work because codec/checksum parity is deterministic and can deliver an independent, lower-risk reduction quickly.
- Phase 10 remains a separate phase because its acceptance depends on asynchronous client-global state and observed 3.3.5a behavior.
- Phase 11 validates the selected combination without coupling the KEEP/REPLACE outcomes or assuming that one success justifies the other.

### Research Flags

Phases needing focused research or characterization during planning:

- **Phase 8:** Capture real protocol-v5 payloads and establish whether `specRole` and LGT peer-fed/out-of-range refresh are supported product contracts.
- **Phase 10:** Confirm exact WotLK 3.3.5a talent API signatures/data lifetime for self and remote dual specs; plan access to a supported non-English client and multi-client/out-of-range scenarios.

Phases with standard patterns:

- **Phase 9:** Differential byte/checksum testing and staged replacement are well-defined from current source plus RFC 1950.
- **Phase 11:** Repository validators, full-suite execution, TOC/package inspection, and evidence classification follow established RMA milestone practice.

## Confidence Assessment

| Area | Confidence | Notes |
|---|---|---|
| Stack | HIGH for codec; MEDIUM for talent | No new dependency is needed. The codec surface is exact; live talent behavior remains unresolved. |
| Required behavior | HIGH for repository-visible contracts | Current consumers, fields, events, errors, persistence, and TOC coupling are mapped. |
| Architecture | HIGH for ownership; MEDIUM for direct talent details | `SpecInspect` and `InspectCoordinator` are clear boundaries; real-client data lifetime and peer behavior require observation. |
| Pitfalls | HIGH | Wire drift, checksum drift, inspect contention, localization, atomic cleanup, and oracle preservation have direct repository evidence. |

**Overall confidence:** MEDIUM-HIGH. The roadmap and codec decision are high-confidence; the final talent decision intentionally remains conditional.

### Gaps to Address

- **Malformed decoder edge semantics:** Freeze exact vendor outcomes for raw NUL, trailing escape, unknown suffix, empty string, and arbitrary high bytes before candidate implementation.
- **Representative v5 interoperability:** Capture real payload vectors and observe current/candidate peer exchange before authorizing LibDeflate deletion.
- **Role contract:** `SpecInspect` emits `specRole`, but research found no clear repository consumer. Preserve existing values unless Phase 8 proves removal is safe and explicitly approves it.
- **Out-of-range and peer-fed talent behavior:** Determine whether documented/user-observable refresh relies on the LGT addon-message path. If it does, KEEP the complete talent stack rather than cloning a new wire protocol.
- **Remote dual-spec API behavior:** Confirm group count, active group, tab points/names/icons, and result lifetime on a real 3.3.5a client.
- **Localization:** Execute at least one supported non-English client observation; automated localized fixtures alone are not OBSERVED parity.
- **Client-only safety:** Equipment/talent contention, forced and ready-check refresh, combat behavior, timeout/late callback handling, clean standalone load, and reload persistence need recorded observations where automation cannot prove them.

## Sources

### Primary Repository Evidence

- `AGENTS.md` and `.planning/PROJECT.md` — binding runtime, scope, persistence, wire, vendored-source, and milestone constraints.
- `Raid Management Addon/Raid Management Addon.toc` — authoritative dependency ordering and packaging surface.
- `Raid Management Addon/Modules/Comms.lua` — exact `LibSerialize` and addon-channel codec boundary plus stable error taxonomy.
- `Raid Management Addon/Database/DBRaidEvents.lua` — Adler32 use in stable raid UIDs and canonical state digests.
- `Raid Management Addon/Services/SpecInspect.lua` — sole proprietary talent-stack adapter, public contract, cache, and events.
- `Raid Management Addon/Services/InspectCoordinator.lua` and `Raid Management Addon/Services/EquipInspect.lua` — global inspect ownership and persisted talent-field consumption.
- `Raid Management Addon/Services/Reserves/Import.lua` — explicit evidence that compressed input is not a supported runtime path.
- `tests/lua/harness/20_raid_database.lua`, `tests/lua/harness/40_inspect_foundations.lua`, `tests/lua/harness/50_reserves_messaging.lua`, and `tests/lua/harness/70_raid_sync.lua` — current behavior and integration evidence.
- Untouched vendored `LibDeflate`, `LibGroupTalents-1.0`, `LibTalentQuery-1.0`, and `LibBabble-TalentTree-3.0` sources — black-box compatibility oracles; `CallbackHandler-1.0` is the retained integrity baseline.

### Primary Upstream Sources

- [LibDeflate upstream](https://github.com/SafeteeWoW/LibDeflate) — official implementation scope, addon-channel codec purpose, Lua compatibility, and tests.
- [RFC 1950](https://www.rfc-editor.org/info/rfc1950/) — authoritative Adler32 definition.
- [Lua 5.1 Reference Manual](https://www.lua.org/manual/5.1/manual.html) — authoritative runtime language and standard-library behavior.
- [LibSerialize upstream source](https://github.com/rossnichols/LibSerialize/blob/main/LibSerialize.lua) — separation of serialization, optional compression, and addon-channel-safe encoding.

---
*Research completed: 2026-08-17*
*Ready for roadmap: yes — begin with Phase 8*
