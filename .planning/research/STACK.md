# Stack Research

**Domain:** WotLK 3.3.5a addon dependency reduction with wire- and persistence-sensitive behavior
**Researched:** 2026-08-17
**Confidence:** HIGH for the codec/checksum target; MEDIUM for the talent-stack target pending live-client proof

## Recommended Stack

### Core Technologies

| Technology | Version | Purpose | Why Recommended |
|------------|---------|---------|-----------------|
| WoW client runtime | WotLK 3.3.5a, build 12340, Interface 30300 | Authoritative addon runtime and inspect/talent API | This is RMA's binding runtime contract; replacements must use APIs available here rather than Retail/Classic compatibility layers. |
| Lua | 5.1.5-compatible source | Internal codec, checksum, talent snapshot logic | RMA already owns small focused modules in Lua. The required LibDeflate surface can be expressed with byte operations and modulo arithmetic, and the talent surface can be driven by the existing event bus and inspect coordinator without a new framework. |
| RMA protocol | Version 5 | Existing addon-channel payload contract | `Modules/Comms.lua` serializes with `LibSerialize` and applies only LibDeflate's addon-channel byte codec; it does **not** call DEFLATE compression. Preserving those exact encoded bytes preserves the current payload shape and peers. |
| RMA inspect coordination | Current `Services/InspectCoordinator.lua` contract | Serialize all RMA ownership of the client-global inspect target | A direct talent implementation should request category `"talents"`, call `NotifyInspect` only from the granted `onStart`, correlate `INSPECT_TALENT_READY` by GUID, and release through the coordinator. This removes the current monkey-patch of LibTalentQuery's polling queue rather than recreating it. |

### Supporting Libraries

| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| LibSerialize | vendored revision not asserted by this research | Stable table serialization/deserialization used by RMA payloads | Retain unchanged. It is still the serialization owner even if LibDeflate is removed. |
| ChatThrottleLib | vendored repository copy | Throttled addon/chat transport | Retain unchanged. Dependency optimization must not alter transport scheduling or destinations. |
| CallbackHandler-1.0 | LibStub minor 5; `$Id ... 895 2009-12-06 ...$` | Legacy callback dispatcher | Retain unchanged and keep its current TOC entry, per explicit milestone constraint, even if removal of the talent stack leaves no repository consumer. Do not fold this retained dependency into the talent decision. |
| LibStub | vendored repository copy | Registration for retained legacy libraries | Retain while other vendored libraries still use it. Internal RMA replacements should publish on `addon.*`, not register new pseudo-libraries. |

### Proposed Internal Replacements

| Internal owner | Replaces | Required surface | Recommendation |
|----------------|----------|------------------|----------------|
| A small shared byte utility under `Modules/` (for example `addon.Bytes`) | The RMA-used subset of LibDeflate 1.0.2-release | addon-channel encode, addon-channel decode, Adler32 | **Preferred after golden-vector proof.** Implement only these three operations. For the current codec, byte `0` maps to `1,2`, byte `1` maps to `1,3`, all other bytes pass through; decoding rejects any raw NUL exactly as the vendored codec does. Adler32 follows RFC 1950. Do not copy or retain the general codec factory or DEFLATE engine. |
| `Services/SpecInspect.lua` itself | LibGroupTalents-1.0 + LibTalentQuery-1.0 + LibBabble-TalentTree-3.0 as one atomic unit | queued refresh, ready-event correlation, active/secondary group snapshots, localized tree name/icon, point totals, role if still consumed, stale cache and `SpecInspectUpdated` | **Preferred design, but replacement remains conditional.** Read talent tabs directly after the coordinator-owned inspect completes. Preserve the existing `addon.Services.SpecInspect` public contract; do not emulate the three LibStub APIs. Remove all three vendored libraries and their TOC lines only after automated and live-client gates establish equivalent required behavior. |

### Development Tools

| Tool | Purpose | Notes |
|------|---------|-------|
| Existing Python/Lua behavior suite | Golden vectors and service regressions | Add codec vectors for empty/ASCII/NUL/escape/all-256-byte/repeated/random binary inputs, malformed decode inputs, RFC Adler32 vectors, and captured protocol-v5 payloads. |
| WotLK static validators in `.agents/skills/wow-addon-dev-wotlk-v335a/scripts/` | TOC, Lua 5.1, and `xpcall` compatibility | Run `validate_toc.py`, `lint_lua51.py`, and `scan_xpcall.py` after runtime/TOC changes. |
| WotLK 3.3.5a client | Inspect lifecycle and multi-client proof | Automation cannot prove inspect timing, range/visibility behavior, localized tree names, dual-spec data, combat interaction, or peer interoperability. |
| SHA-256 integrity check | Prove vendored sources were not edited during evaluation | Baseline hashes are recorded under Evidence below. A successful replacement deletes complete candidate directories only after proof; it never patches their contents. |

## Installation

No external package installation is recommended.

If and only if the codec/checksum gate passes:

```text
1. Add the internal byte utility to Layer 4 before Modules\Comms.lua.
2. Route Modules\Comms.lua and Database\DBRaidEvents.lua to that addon-owned API.
3. Remove Libs\LibDeflate\LibDeflate.lua from the TOC and then remove its directory.
```

If and only if the atomic talent gate passes:

```text
1. Make Services\SpecInspect.lua consume the existing event bus, InspectCoordinator,
   and WotLK talent APIs directly.
2. Remove the three TOC entries for LibBabble-TalentTree-3.0,
   LibTalentQuery-1.0, and LibGroupTalents-1.0 together.
3. Remove all three directories together; retain CallbackHandler-1.0 unchanged.
```

## Alternatives Considered

| Recommended | Alternative | When to Use Alternative |
|-------------|-------------|-------------------------|
| Replace only LibDeflate's three consumed operations with a small addon-owned module | Retain LibDeflate 1.0.2-release | Retain if any established payload/golden vector differs, malformed-decode behavior differs, Adler32 differs, or another proprietary runtime call to its compression/general-codec API is discovered. Retention is a valid milestone result. |
| Direct talent reads inside `Services/SpecInspect.lua` | Retain the complete talent stack | Retain all three if live-client tests cannot prove active and secondary talent groups, localized names/icons, refresh completion, inspect-target serialization, and accepted range/availability behavior. Retention is a valid atomic result. |
| Preserve `addon.Services.SpecInspect` as the only application-facing interface | Build a compatibility shim exposing `LibGroupTalents-1.0`/`LibTalentQuery-1.0` names | Use a shim only if an actual in-repository consumer outside `SpecInspect` is found. Current evidence shows none, so a shim would preserve unused third-party surface and defeat the ownership simplification. |
| Use client-returned localized talent tab names/icons | Copy LibBabble data into RMA | Never for the current requirement. Direct API values avoid a second locale catalog; copied tables add maintenance and are unnecessary if inspect correlation is correct. |

## What NOT to Use

| Avoid | Why | Use Instead |
|-------|-----|-------------|
| A newer LibDeflate drop-in as the default answer | It keeps the 120,221-byte/3,536-line general compression implementation and does not reduce owned dependency surface. Version changes also do not by themselves prove byte-identical output. | A minimal internal encode/decode/Adler32 module, conditional on exhaustive and golden-vector parity. |
| Native zlib, a DLL, `io`, or `os` | Not portable addon runtime facilities; they violate the Lua/WoW execution model and release policy. | Pure Lua 5.1 byte logic. |
| Any DEFLATE compressor or decompressor in the replacement | No proprietary RMA runtime path calls `CompressDeflate` or `DecompressDeflate`; adding one is YAGNI and expands the attack/resource surface. | Keep serialized-but-uncompressed protocol-v5 payload behavior exactly as it is. |
| Ace2/Ace3, a timer framework, or another inspect library | Explicitly forbidden or unjustified; RMA already has an event bus, timer mixin, and global inspect coordinator. | Existing `addon.Bus`, `addon.Timer`, and `Services.InspectCoordinator`. |
| Retail/Classic APIs such as `C_AddOns`, `C_Timer`, or specialization APIs | They are absent from the 3.3.5a target. | WotLK globals already demonstrated by the vendored code: `NotifyInspect`, `INSPECT_TALENT_READY`, `GetNumTalentGroups`, `GetActiveTalentGroup`, `GetTalentTabInfo`, and (only if needed for role parity) `GetTalentInfo`. |
| Reimplementing LibGroupTalents' glyph, storage-string, role-change, roster, or `LGT` peer protocol wholesale | RMA does not call those library APIs directly. Recreating a 1,727-line general library is not dependency optimization and could create a second wire-compatibility obligation. | Implement only behavior required by the existing `SpecInspect` contract. Treat any required out-of-range peer-fed talent behavior as an explicit keep/remove gate, not an assumed feature to recreate. |
| Removing CallbackHandler-1.0 as collateral cleanup | The user explicitly excluded it from the atomic talent-stack decision. | Leave its source and TOC entry unchanged. |

## Stack Patterns by Variant

**If codec vectors are byte-identical:**

- Use the internal three-operation byte utility.
- Remove LibDeflate from the TOC and repository.
- Keep `LibSerialize` payload bytes and protocol version 5 unchanged.
- Update bootstrap tests that currently assert the `LibStub("LibDeflate")` implementation detail to assert the byte contract instead.

**If any codec vector differs:**

- Keep LibDeflate 1.0.2-release unchanged.
- Record the smallest counterexample and do not introduce a dual-codec fallback.
- Do not bump protocol version 5 in this milestone.

**If direct talent inspection passes automated and live gates:**

- Remove LibGroupTalents, LibTalentQuery, and LibBabble-TalentTree together.
- Let `SpecInspect` own direct snapshot construction and listen to the already-forwarded `wow.INSPECT_TALENT_READY` event.
- Correlate readiness with both coordinator ownership and GUID before reading tabs or releasing the target.
- Preserve stale-cache behavior (`1800` seconds), active/secondary group fields, localized spec names/icons, point totals/main tree, failure reasons, and `SpecInspectUpdated` emission.

**If direct talent inspection cannot prove required parity:**

- Keep all three talent libraries and their TOC ordering unchanged.
- Keep the existing LibTalentQuery guard that blocks its polling queue while equipment owns the inspect target.
- Document whether the blocker is dual-spec data, locale behavior, range/visibility, role classification, completion correlation, or the talent stack's peer-fed out-of-range behavior.

## Version Compatibility

| Package / component | Compatible With | Notes |
|---------------------|-----------------|-------|
| Internal byte utility (proposed) | LibDeflate 1.0.2-release consumed subset | Must match `EncodeForWoWAddonChannel`, `DecodeForWoWAddonChannel`, and `Adler32` exactly, including invalid input behavior used by RMA. Compression APIs are deliberately not part of the internal contract. |
| Internal byte utility (proposed) | RMA protocol v5 + current LibSerialize bytes | `Payload.Serialize` and `Payload.Deserialize` must remain mutually compatible with current and replacement builds; database UID/digest checksums must remain identical. |
| Direct `SpecInspect` implementation (proposed) | WotLK 3.3.5a / Lua 5.1 | Must use only legacy global APIs and event forwarding already present in `Init.lua`/`Modules/Events.lua`. No specialization ID API is available or needed. |
| Direct `SpecInspect` implementation (proposed) | `Services/InspectCoordinator.lua` | Must not independently poll or notify outside coordinator ownership. The coordinator already supplies an 8-second deadline, 1.75-second minimum start interval, combat pause, and 40-request bound. |
| LibGroupTalents-1.0 revision 65 | LibTalentQuery-1.0 revision 84 (LibStub minor 90084), CallbackHandler-1.0 minor 5 | Current ordered stack. It also contains broader roster, glyph, role, storage, and peer communication behavior not directly consumed by proprietary RMA code. |
| LibTalentQuery-1.0 revision 84 | LibBabble-TalentTree-3.0 revision 26 (LibStub minor 90026) on non-English clients | Babble is used only to localize a validation table for the first talent-tree name; a direct correlated read should use the client-returned localized tree metadata instead. |
| CallbackHandler-1.0 minor 5 | Current TOC / LibStub | Explicitly retained unchanged regardless of the atomic talent decision. |

## Compatibility Matrix and Proof Gates

| Contract | Current evidence | Replacement gate | Confidence |
|----------|------------------|------------------|------------|
| Addon-channel encoding | `Modules/Comms.lua:64` calls LibDeflate encoding on raw LibSerialize output; current codec is generated with reserved NUL and escape byte 1. | Exhaustive single-byte and all-256-byte vectors, embedded NUL/byte-1 sequences, captured v5 payloads, and randomized binary strings produce byte-identical output. | HIGH |
| Addon-channel decoding | `Modules/Comms.lua:75` decodes before LibSerialize; malformed input is converted to `CHANNEL_DECODE_FAILED`. | Current and replacement return identical bytes or failure for golden valid/malformed vectors, including raw NUL, trailing escape byte, and unknown escape suffix. | HIGH |
| Adler32 | `Database/DBRaidEvents.lua:628,641` uses it for raid UID checksum and canonical state digest. | RFC 1950 vectors plus existing UID/digest fixtures and long/binary strings match exact unsigned values and formatted hex. | HIGH |
| DEFLATE compression | No proprietary runtime call found; `Services/Reserves/Import.lua:34` explicitly leaves compressed import unsupported. | Re-run repository-wide call search immediately before removal. No replacement compressor is required unless new evidence appears. | HIGH |
| Inspect target ownership | `SpecInspect` currently asks `InspectCoordinator` to run LGT refresh and monkey-patches LTQ's `CheckInspectQueue`; tests cover equipment/talent serialization. | Direct implementation calls `NotifyInspect` only in coordinator `onStart`, ignores mismatched GUID events, and releases only its matching owner. | HIGH automated; MEDIUM live |
| Active and secondary talent groups | `SpecInspect` requests LGT group count/active group and stores both groups. | Real 3.3.5a client observation with single-spec and dual-spec characters; names, icons, active group, secondary group, tree index and point totals match baseline. | MEDIUM |
| Localized tree names/icons | LGT derives class tab metadata from client APIs; LTQ uses Babble only for a locale-sensitive validation guard. | Observe at least one supported non-English client. Ensure no English-only comparison controls acceptance. | MEDIUM |
| Role field | LGT infers healer/tank/damage, including talent-specific DK/Druid cases; RMA copies `spec.role` into `specRole`, but no repository consumer of `specRole` was found. | Either prove the field is not a supported consumer contract and remove it deliberately, or implement/test equivalent classification. Do not silently change its values. | MEDIUM |
| Out-of-range/peer-fed talents | LGT can request talent data from compatible peers when direct inspection is unavailable; proprietary RMA has no direct API call to that transport. | Product decision or live baseline must establish whether this incidental behavior is required. If required, retain the atomic stack; do not casually clone the `LGT` protocol. | LOW until decided |
| SavedVariables | `SpecInspect` cache is runtime-only; EquipInspect persists compact spec fields through existing database owners. | No new SavedVariable, schema, or migration; reload smoke confirms the same six `RMA_*` globals and compact stored fields. | HIGH |

## Evidence

### Repository paths

- `Raid Management Addon/Raid Management Addon.toc` — authoritative current load order: CallbackHandler, LibDeflate, Babble, TalentQuery, then GroupTalents.
- `Raid Management Addon/Modules/Comms.lua:31-78` — only addon payload codec calls: LibSerialize plus LibDeflate channel encode/decode, with no compression.
- `Raid Management Addon/Database/DBRaidEvents.lua:620-642` — only proprietary Adler32 calls, used by stable identity/digest formatting.
- `Raid Management Addon/Services/Reserves/Import.lua:34` — compressed external input is intentionally unsupported.
- `Raid Management Addon/Services/SpecInspect.lua:36-594` — complete proprietary talent-library integration and existing public application contract.
- `Raid Management Addon/Services/InspectCoordinator.lua` — current global inspect owner, timeout, throttle, combat pause, GUID correlation surface, and queue bound.
- `Raid Management Addon/Services/EquipInspect.lua:951-956` — existing RMA subscription to forwarded `INSPECT_TALENT_READY` with GUID.
- `tests/lua/harness/40_inspect_foundations.lua:250-366,680-778` — current coordinator/LGT behavior and vendored-queue guard tests.
- `tests/test_runtime_bootstrap_contract.py:218-230` — current test asserts LibDeflate as an implementation detail and should become a byte-contract assertion if replacement succeeds.

### Vendored metadata and integrity baseline

| Candidate | Proven metadata | Size | SHA-256 |
|-----------|-----------------|------|---------|
| LibDeflate | 1.0.2-release, LibStub minor 3, zlib license | 120,221 bytes / 3,536 lines | `912799ba0f5970f9ad9204c06b8cc18588d9a1fabda8f79f0fa07ba5101cf0c9` |
| LibTalentQuery-1.0 | revision 84, LibStub minor 90084, LGPL v2.1 | 11,459 bytes / 358 lines | `a0ff05488527e115195bc01ab5de37f326ef534eb1e093c0ed738773aafdd7ad` |
| LibGroupTalents-1.0 | revision 65, LibStub minor 65 | 49,266 bytes / 1,727 lines | `424ae80bf14f5dfca2f8ea84c3c0d79aca84508b4b7236248f9007b4a0b94ad4` |
| LibBabble-TalentTree-3.0 | revision 26, LibStub minor 90026, MIT | 7,732 bytes / 295 lines | `dc65c70de549f3220543f5e48d4bedf8e20a21477abfe7212df91b8785f3d253` |
| Bundled LibBabble-3.0 core | minor 2, public domain | 8,233 bytes / 292 lines | `93a91850c50c22713f613d227982cf613a3222b924dc7606a9f84b767291c8cb` |
| CallbackHandler-1.0 (retained) | minor 5, source ID revision 895 | 9,201 bytes / 240 lines | `f48a3c7182d3fadc32709d986f857185689efd2fffd521ceb43107e2445ba3fc` |

### Primary specifications

- [RFC 1950, ZLIB Compressed Data Format Specification](https://www.rfc-editor.org/info/rfc1950/) — authoritative Adler32 definition; the proposed checksum must match it and the vendored implementation.
- [Lua 5.1 Reference Manual](https://www.lua.org/manual/5.1/manual.html) — authoritative language and standard-library contract for byte/string implementation choices.

## Research Conclusion

The stack should not gain any external dependency. LibDeflate is a strong removal candidate because RMA consumes only a tiny deterministic subset: addon-channel byte escaping and Adler32. A minimal addon-owned Lua 5.1 module can plausibly replace it with high confidence once strict golden vectors pass.

The talent stack is also technically reducible to direct WotLK APIs because RMA already owns the application cache, refresh policy, event bus, and global inspect coordinator. However, removal is a lower-confidence decision until live 3.3.5a evidence closes dual-spec, locale, role, and range/peer-fed behavior. The correct milestone outcome is atomic: remove all three after those gates, or retain all three unchanged. CallbackHandler remains unchanged in either case.

---
*Stack research for: RMA v1.2 Dependency Optimization*
*Researched: 2026-08-17*
