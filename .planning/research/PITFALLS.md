# Pitfalls Research

**Domain:** Dependency reduction in a Lua 5.1 World of Warcraft 3.3.5a raid addon
**Researched:** 2026-08-17
**Confidence:** HIGH for repository contracts; MEDIUM for behavior that still requires a real 3.3.5a client

## Critical Pitfalls

### Pitfall 1: Replacing the wire codec with a merely reversible codec

**What goes wrong:**
Two RMA clients can each round-trip their own payloads but cannot exchange payloads byte-for-byte with current protocol-version-5 peers. Extended bytes, NUL handling, malformed inputs, or expansion length differ even though simple ASCII fixtures pass.

**Why it happens:**
`Modules/Comms.lua` uses `LibDeflate:EncodeForWoWAddonChannel` and `DecodeForWoWAddonChannel` directly around `LibSerialize`; RMA does not compress that path. A replacement can therefore look much smaller than LibDeflate while still silently changing the wire alphabet or failure behavior. Upstream explicitly says addon-channel data must be encoded so NUL is absent, but reversibility alone does not define RMA's existing byte contract.

**How to avoid:**
Capture golden vectors from the vendored LibDeflate 1.0.2 implementation for empty, ASCII, every byte 0-255, embedded NUL, extended bytes, long payloads, and malformed encodings. Require exact encoded bytes, exact decoded bytes, exact nil/error behavior through RMA's `pcall` boundary, and version-5 cross-implementation exchange before replacing it.

**Warning signs:**
Tests assert only `decode(encode(x)) == x`; the new encoder uses Base64; encoded lengths change; or a protocol test passes without comparing old and new bytes.

**Phase to address:**
LibDeflate decision phase, before any TOC or vendored-directory removal.

---

### Pitfall 2: Reimplementing unused DEFLATE functionality

**What goes wrong:**
The milestone replaces one mature dependency with a large, harder-to-audit local compression library, increasing owned code and runtime risk without serving a current RMA call path.

**Why it happens:**
The library name suggests compression is required. Repository-owned runtime calls only addon-channel encode/decode and Adler32. `Services/Reserves/Import.lua` intentionally rejects compressed imports because there is no bounded-output inflate contract.

**How to avoid:**
Define the replacement surface from proprietary call sites, not the upstream library API. Do not add raw DEFLATE, zlib, dictionaries, chat/print codecs, or compressed SoftRes import unless a separate approved requirement proves they are needed.

**Warning signs:**
New code contains Huffman tables, inflate loops, compression levels, or a decompression size limit added solely to justify the replacement.

**Phase to address:**
LibDeflate contract and implementation decision.

---

### Pitfall 3: Computing a different Adler32 representation

**What goes wrong:**
Raid UIDs and canonical state digests change, causing peers to disagree about identity or state while all higher-level data appears identical.

**Why it happens:**
`Database/DBRaidEvents.lua` formats the numeric result as eight lowercase hexadecimal digits. Lua 5.1 uses doubles, WoW exposes `bit.*` with signed 32-bit behavior, and seemingly equivalent checksum implementations can differ on unsigned normalization or long-input reduction.

**How to avoid:**
Use the vendored implementation as the oracle. Test RFC-style vectors plus RMA UID seeds, canonical raid states, boundary lengths, binary inputs, and long inputs. Compare both numeric results and the exact `%08x` strings consumed by RMA.

**Warning signs:**
Only `"Wikipedia"` is tested; negative `bit.*` values reach `string.format`; or tests compare decimal strings but not persisted/wire-facing digest text.

**Phase to address:**
LibDeflate decision phase.

---

### Pitfall 4: Creating a second owner of the client-global inspect target

**What goes wrong:**
Talent refreshes and equipment inspection issue overlapping `NotifyInspect` calls, consume each other's `INSPECT_TALENT_READY`, starve queued work, or clear the wrong owner.

**Why it happens:**
The vendored `LibTalentQuery` owns an internal queue and frame-driven dispatcher, while RMA already centralizes client-global inspect ownership in `Services/InspectCoordinator.lua`. `Services/SpecInspect.lua` currently guards `LibTalentQuery.CheckInspectQueue` whenever equipment owns the coordinator; that guard is a demonstrated compatibility requirement, not incidental glue.

**How to avoid:**
Make `InspectCoordinator` the only authority allowed to schedule `NotifyInspect`. A replacement talent service must request and release coordinator ownership by GUID, respect throttle/timeout/queue-full states, ignore stale callbacks, and coexist with equipment inspection under focused behavior tests.

**Warning signs:**
The replacement owns its own `OnUpdate` queue; calls `NotifyInspect` directly outside the coordinator callback; or removes the existing vendored integration test without an equivalent coordinator-level test.

**Phase to address:**
Talent-stack replacement phase before removing any of the three libraries.

---

### Pitfall 5: Preserving only the displayed primary spec

**What goes wrong:**
The attendance UI initially looks correct, but secondary spec, active group, role, icon, forced refresh, stale-cache recovery, or batch completion regresses.

**Why it happens:**
`Services/SpecInspect.lua` consumes a wider contract than a single spec string: talent-group count, active group, three tab point totals, tab names and icons, role, GUID lookup, targeted refresh, per-unit update callbacks, and update-complete callbacks. It derives compatibility snapshots and emits `SpecInspectUpdated` only when display data changes.

**How to avoid:**
Inventory every consumed library method and callback. Test primary and secondary groups, tied point totals, role normalization, icon lookup, cache staleness, roster removal, ready-check refresh, forced refresh, queue failure, and completion/release behavior before allowing the atomic stack decision to be REPLACE.

**Warning signs:**
Acceptance is based on one priest fixture; the new API returns only `specName`; or callbacks are replaced by unconditional frame polling.

**Phase to address:**
Talent behavior contract and replacement phases.

---

### Pitfall 6: Losing locale-safe talent names and icon matching

**What goes wrong:**
Non-English clients produce missing icons, mismatched spec names, or incomplete snapshots even though enUS tests pass.

**Why it happens:**
`LibTalentQuery` optionally loads `LibBabble-TalentTree` outside enUS, and `SpecInspect` currently matches the returned spec name against talent-tab names to select the icon. Removing the three-library stack eliminates both the localization data and the adapter behavior at once.

**How to avoid:**
Prefer live client `GetTalentTabInfo` names/icons indexed by the inspected group and dominant tab, keeping canonical control flow numeric and display text client-derived. Add localized fixtures containing non-ASCII names and require an actual non-enUS client observation before claiming full locale parity.

**Warning signs:**
English talent-tree literals appear in proprietary runtime code; icon selection compares against an English catalog; or localized coverage is relabeled PASS from mocked data alone.

**Phase to address:**
Talent-stack replacement and final compatibility verification.

---

### Pitfall 7: Treating the atomic stack as three independent cleanups

**What goes wrong:**
The TOC loads a hybrid of old and new talent ownership, hidden LibStub registrations survive, or load order changes make startup dependent on another addon supplying a removed library.

**Why it happens:**
`LibGroupTalents` directly depends on `LibTalentQuery`; `LibTalentQuery` optionally consumes `LibBabble-TalentTree`; all are explicitly ordered in the TOC. The approved product decision is all-three KEEP or all-three REPLACE. `CallbackHandler` remains and must not be swept into the removal.

**How to avoid:**
Make one decision gate cover all three directories, their TOC entries, XML manifests, LibStub lookups, tests, diagnostics, and documentation. Run a clean-load test where no other addon supplies any of the removed libraries. Independently prove every remaining `CallbackHandler` consumer before retaining its TOC entry.

**Warning signs:**
One library directory disappears in an earlier commit; optional LibStub lookups mask missing startup ownership; or tests preinstall fake libraries globally.

**Phase to address:**
Atomic talent-stack decision and TOC cleanup.

---

### Pitfall 8: Deleting the oracle before compatibility is locked

**What goes wrong:**
Golden-vector tests become circular because the new implementation generates its own expected values, and discrepancies can no longer be diagnosed against the exact shipped dependency.

**Why it happens:**
Dependency removal is visually satisfying and can be performed before the compatibility suite is complete. The project policy also prohibits editing vendored sources, so the vendored implementation must remain an untouched oracle during evaluation.

**How to avoid:**
First freeze black-box golden vectors and differential tests against the untouched libraries. Only after replacement tests pass should proprietary call sites and TOC entries change; remove vendored directories last. Keep the committed vectors after removal.

**Warning signs:**
The first implementation commit deletes `Libs/`; expected values are computed at test runtime by the replacement; or no baseline commit/hash is recorded.

**Phase to address:**
Both dependency decision phases; removal is the final task of an approved replacement.

## Technical Debt Patterns

| Shortcut | Immediate Benefit | Long-term Cost | When Acceptable |
|----------|-------------------|----------------|-----------------|
| Compatibility wrapper exposing the full LibDeflate API | Fewer call-site edits | Preserves an unused third-party-shaped surface and invites unsupported compression use | Never; expose only current RMA-owned operations |
| New generic callback framework for the talent replacement | Familiar library-like API | Duplicates `addon.Bus`/`InspectCoordinator` ownership and expands scope | Never for this milestone |
| English spec-name lookup table | Easy deterministic fixture | Locale regressions and duplicated client data | Tests only, never runtime |
| Polling every raid member continuously | Simple refresh logic | Inspect contention, throttling, and unnecessary frame work | Never; preserve event/ready-check/explicit refresh triggers |
| Keeping removed library directories “just in case” | Easy rollback | No dependency-footprint reduction and ambiguous ownership | Only on a temporary implementation branch, not the accepted result |

## Integration Gotchas

| Integration | Common Mistake | Correct Approach |
|-------------|----------------|------------------|
| `LibSerialize` to addon channel | Replace LibDeflate with printable/Base64 encoding | Reproduce the exact existing addon-channel codec bytes and failure behavior |
| Raid UID/state digest | Validate only checksum mathematics | Validate exact RMA seeds, canonical state encoding, lowercase hex, and length suffix |
| Equipment and talent inspection | Let each service throttle itself | Route both through the one `InspectCoordinator` ownership queue |
| Talent callbacks to `SpecInspect` | Fire update when any partial tab arrives | Rebuild a complete snapshot and preserve update/update-complete release semantics |
| TOC cleanup | Rely on another addon's global LibStub registration | Prove clean standalone load with only RMA's packaged contents |

## Performance Traps

| Trap | Symptoms | Prevention | When It Breaks |
|------|----------|------------|----------------|
| Byte-by-byte codec builds one-character strings repeatedly | High allocation/GC during large sync chunks | Use bounded table buffers and `table.concat`; benchmark against current maximum payloads | Large snapshots or repeated reserve/raid sync bursts |
| Adler32 reduces modulo only at the end | Precision drift or slow arithmetic | Use bounded periodic reduction compatible with Lua 5.1 doubles | Long canonical raid-state strings |
| Full talent scans on every frame/update | Inspect queue never drains; UI data churn | Event-driven invalidation plus ready-check/explicit refresh and stale-cache policy | Full raids, especially alongside equipment inspection |
| Rebuilding and emitting unchanged talent snapshots | Excess Attendance redraws | Preserve `snapshotDisplayEqual`-style change detection | Repeated update-complete batches |

## Correctness and Trust-Boundary Mistakes

| Mistake | Risk | Prevention |
|---------|------|------------|
| Decoder accepts bytes the old codec rejects | Malformed peer input reaches `LibSerialize` under a changed protocol contract | Differential malformed-input corpus and fail-closed assertions |
| Stale `INSPECT_TALENT_READY` is attributed to current owner | Wrong player's spec/equipment is cached | GUID/owner matching through `InspectCoordinator`; ignore late callbacks |
| Optional global library lookup hides packaging error | Feature silently depends on another installed addon | Clean standalone load and explicit missing-owner behavior |

## UX Pitfalls

| Pitfall | User Impact | Better Approach |
|---------|-------------|-----------------|
| Replacement changes spec labels/icons by locale | Attendance rows become blank or misleading | Use inspected client tab metadata and verify localized clients honestly |
| Refresh failure clears last good data | Previously useful spec disappears during transient inspect contention | Preserve the last complete snapshot and surface stable runtime state |
| Dependency retention is reported as failure | Encourages unsafe code removal | Treat evidence-backed KEEP as a successful milestone decision |

## "Looks Done But Isn't" Checklist

- [ ] **Codec:** Golden vectors include all byte values, malformed input, exact output length, and cross-version-5 peer exchange.
- [ ] **Adler32:** Exact numeric and formatted digest parity covers real RMA UID/state fixtures and long inputs.
- [ ] **Talent data:** Primary/secondary group, role, icon, stale cache, ready check, force refresh, and batch completion are covered.
- [ ] **Inspect ownership:** Talent and equipment requests serialize through `InspectCoordinator`, including timeouts and stale callbacks.
- [ ] **Localization:** Non-English automated fixtures exist and real-client coverage is labeled OBSERVED or DEFERRED, never inferred PASS.
- [ ] **Packaging:** All three talent libraries are removed together or all retained; `CallbackHandler` remains; clean standalone TOC load passes.
- [ ] **Vendored integrity:** No source under `Libs/` was edited; any approved directories were removed only after oracle tests were committed.

## Recovery Strategies

| Pitfall | Recovery Cost | Recovery Steps |
|---------|---------------|----------------|
| Codec parity fails before removal | LOW | Select KEEP, retain LibDeflate and TOC entry, preserve the failing vectors as decision evidence |
| Codec mismatch ships | HIGH | Restore LibDeflate-owned codec immediately; keep protocol version 5; test old/new peer convergence before another attempt |
| Talent parity fails before removal | LOW | Select atomic KEEP for all three libraries and retain the coordinator guard |
| Inspect collision appears in client | HIGH | Restore the prior three-library stack and guard, then reproduce ownership order with a coordinator behavior test |
| Locale parity is unverified | LOW | Mark live localization DEFERRED and unpassed; do not claim the replacement fully accepted |

## Pitfall-to-Phase Mapping

| Pitfall | Prevention Phase | Verification |
|---------|------------------|--------------|
| Wire codec drift | LibDeflate decision | Differential golden vectors and real version-5 cross-peer smoke test |
| Unused compression reimplementation | LibDeflate decision | Proprietary-call inventory contains no unsupported new API |
| Adler32 representation drift | LibDeflate decision | Exact checksum and RMA digest corpus |
| Duplicate inspect ownership | Talent-stack replacement | Equipment/talent interleaving and stale-callback behavior tests |
| Incomplete talent snapshot | Talent-stack replacement | Full SpecInspect contract matrix |
| Locale mismatch | Talent-stack replacement plus final gate | Non-English fixtures and explicitly classified live evidence |
| Partial stack/TOC cleanup | Atomic removal task | Retired-identifier scan and clean standalone TOC load |
| Lost compatibility oracle | First task of each decision phase | Baseline vectors committed before implementation/removal |

## Sources

### Primary repository evidence

- `Raid Management Addon/Modules/Comms.lua` — exact LibSerialize/addon-channel codec boundary and stable failure categories.
- `Raid Management Addon/Database/DBRaidEvents.lua` — Adler32 use in raid UID and canonical state digest formats.
- `Raid Management Addon/Services/SpecInspect.lua` — consumed talent API, cache semantics, callbacks, and InspectCoordinator guard.
- `Raid Management Addon/Services/InspectCoordinator.lua` — client-global inspect ownership contract.
- `Raid Management Addon/Services/Reserves/Import.lua` — compressed import is deliberately unsupported without bounded inflate.
- `Tests/lua/harness/20_raid_database.lua`, `40_inspect_foundations.lua`, and `70_raid_sync.lua` — current wire, vendored talent integration, and inspect-coordination evidence.
- Untouched vendored `LibDeflate` 1.0.2, `LibTalentQuery` revision 84, and `LibGroupTalents` revision 65 sources — black-box compatibility oracles.

### Upstream primary sources

- https://github.com/SafeteeWoW/LibDeflate — official implementation, Lua 5.1 support, addon-channel encoding purpose, DEFLATE/zlib scope, and test corpus.
- https://github.com/rossnichols/LibSerialize/blob/main/LibSerialize.lua — upstream guidance distinguishing serialization, optional compression, and mandatory addon-channel-safe encoding.

---
*Pitfalls research for: RMA v1.2 Dependency Optimization*
*Researched: 2026-08-17*
