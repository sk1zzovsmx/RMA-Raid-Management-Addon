# Phase 3: Bounded Sync Requests - Research

**Researched:** 2026-08-15
**Domain:** Application-level admission of request-driven addon-message response work
**Confidence:** HIGH

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

### Request budgets
- Rate-limit each normalized sender and request kind independently. `META_REQ`, `DATA_REQ`, and distribution `SNAP_REQ` do not share a counter.
- Reserve and loot-distribution admission state remain independent. Activity in one service must not reduce the budget of the other.
- This separation is required so the normal reserve flow can send `META_REQ` and then `DATA_REQ` immediately without self-throttling.
- Only structurally valid and currently authorized requests consume a budget entry. Malformed, mistargeted, invalid-version, non-member, or otherwise unauthorized messages are rejected before rate admission.
- A valid authorized request consumes its budget even if the responder has no usable data and follows the existing no-data/failure behavior. Response work, including an existing error response, must still be bounded.

### Exact limit and expiry
- Admit one request per normalized sender and request kind every 5 seconds.
- Rejected attempts do not extend or restart the cooldown. Expiry is measured from the last admitted request.
- The exact boundary is inclusive: a request is eligible when elapsed time is greater than or equal to 5 seconds.
- Prune expired admission state lazily when relevant messages arrive. Do not add a timer, ticker, or `OnUpdate` solely for cleanup.
- Keep the number of tracked sender entries globally bounded within each owning service. After pruning expired entries, reject a previously unseen sender if capacity is still full; do not evict an active entry to admit it.

### Sender identity
- Use a case-insensitive canonical short-name identity for the budget. `Massimo`, `massimo`, and equivalent `Name-Realm` forms share the same entry.
- Reuse the established sender normalization semantics rather than creating an alternate identity rule for rate limiting.
- If sender normalization does not produce a valid non-empty identity, reject the request fail-closed and do not place it into a shared anonymous bucket.
- Re-evaluate group membership and feature authorization from the original sender on every request.
- A role change or group leave/re-entry does not clear a still-active cooldown. Once the sender becomes authorized again, the existing entry expires normally.

### Rejection and visibility
- A rate-limited request produces no addon response: no ACK, error envelope, snapshot, chunk, or queued message.
- Do not show ordinary chat output, warnings, popups, or UI state for rate-limit rejection.
- When debug logging is enabled, record only the first rejection for that sender/request-kind cooldown. Further rejected attempts during the same cooldown remain silent.
- Debug detail may identify the owning service, request kind, and normalized sender; it must not include request bodies, reserve data, snapshot contents, or other transferred state.
- Admission state and debug-deduplication state are transient session memory only. Login or `/reload` resets them; no SavedVariable or persisted schema is added.

### Codex's Discretion
- The exact bounded capacity for tracked sender entries, provided tests prove the bound, lazy expiry, and fail-closed behavior at capacity.
- Internal helper names and whether each owner uses one table keyed by request kind or separate tables, provided ownership and the independent budgets above remain clear.
- The smallest repository-consistent debug diagnostic keys and wording.
- Handler return values for silently consumed rejections, provided the message remains handled and cannot fall through to another protocol owner.
- Test fixture organization and whether the existing bounded-rate algorithm is reused directly or reproduced locally with less coupling.

### Deferred Ideas (OUT OF SCOPE)

None - discussion stayed within the phase boundary. Broader traffic shaping, outbound retry policy, protocol negotiation, new wire errors, configurable rate limits, UI controls, and persistent abuse tracking remain outside this phase.
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| COMM-01 | Reserve `META_REQ` and `DATA_REQ` messages are admitted through a bounded per-sender rate limit before response serialization or queue allocation. | Put one reserve-owned admission gate after each request body's existing validation and before `sendMetadata()` or `sendData()`; spy on payload construction, serialization, and transport in the Lua fixture. |
| COMM-02 | Loot-distribution `SNAP_REQ` messages are admitted through a bounded per-sender rate limit before snapshot serialization or queue allocation. | Admit after the existing closed R5 decode and membership check, before `DistributionSession.PublishSnapshot()`; rejected requests must never enter that method. |
| COMM-03 | Rate limiting preserves all existing RMA prefixes, protocol version 5 envelopes, payload shapes, authorization checks, and normal first-request behavior. | Keep admission as an internal pre-dispatch guard only; do not touch either codec, message constants, response builders, requester behavior, or transport options. |
| COMM-04 | Automated regression cases prove exact rate-limit boundaries, expiry, sender normalization, and absence of response work for rejected requests. | Extend the two existing owner-specific Lua fixtures with controllable time, authorization, debug capture, construction/serialization spies, capacity floods, alias requests, and first-response wire assertions. |
</phase_requirements>

## Summary

Both vulnerable paths are already centralized and have the clock and sender-normalization facilities needed for a bounded correction. In `Services/Reserves/Sync.lua`, closed protocol-version-5 decoding, target validation, sender normalization, and authorization occur in `Sync:HandleMessage`; `META_REQ` and `DATA_REQ` then validate their request bodies immediately before `sendMetadata()` and `sendData()`. Those send functions perform the expensive or allocative work: reserve payload projection, transfer construction, payload serialization, chunk-table construction, and transport enqueue. The admission call therefore belongs inside each request branch after its body check and immediately before the corresponding send function.

`Services/Loot/DistributionSession.lua` has an even narrower seam. `decodeMessage()` already rejects oversized, sparse, wrong-version, mistargeted, missing-request-ID, and non-empty `SNAP_REQ` bodies. `HandleMessage()` then checks current group membership from the original sender before eventually calling `DistributionSession.PublishSnapshot()`, which builds and serializes the snapshot and may allocate a chunk batch. Admission belongs after that membership check and before `PublishSnapshot()`. A silent rejection should return `true` so the already-recognized protocol message remains consumed.

Use one transient map per owning service, keyed by lowercase `Comms.NormalizeSender(sender)`. Each entry holds only the active request-kind timestamp and its debug-rejection flag. Cap each service at 128 distinct active senders, matching the established `Database/DBSyncSession.lua` peer bound. Lazy pruning removes request-kind state when `now - admittedAt >= 5`, removes a sender only when none of that owner's kinds remain active, and happens only when a relevant valid authorized request reaches admission. This gives reserves two independent timestamps under one bounded sender entry and distribution one, without a new module, timer, SavedVariable, wire field, or raid-history dependency.

**Primary recommendation:** implement two owner-scoped plans, reserves first and distribution second, each with focused failing behavior coverage before the local Lua change; share only one generic debug diagnostic template, not admission state or a new infrastructure module.

## Standard Stack

### Core

| Component | Version / owner | Purpose | Why standard here |
|-----------|-----------------|---------|-------------------|
| WoW client runtime | WotLK 3.3.5a, build 12340 | `GetTime()` and addon-message delivery | Repository target; both owners already bind `GetTime` at load. |
| Lua | 5.1.5 | Timestamp map and owner-local admission helpers | Mandatory runtime; a table and `pairs()` are sufficient. |
| `Comms.NormalizeSender` | Repository module | Existing short-name normalization | It is already the communication identity rule and removes the realm suffix. |
| Reserve sync owner | `Services/Reserves/Sync.lua`, R5 | `META_REQ` / `DATA_REQ` handling | Owns reserve runtime state and every response-construction path. |
| Distribution owner | `Services/Loot/DistributionSession.lua`, R5 | `SNAP_REQ` handling | Owns distribution runtime state and snapshot construction. |
| Existing behavior harness | Python `unittest` + Lua runtime harness | Exact behavioral regression cases | Fixtures already expose controllable `GetTime`, real codecs, transport capture, and the production owners. |

### Supporting

| Component | Purpose | When to use |
|-----------|---------|-------------|
| `Database/DBSyncSession.lua` rate-map code | Repository precedent for lowercase normalized peers, lazy expiry, capacity 128, and exact-boundary tests | Copy the small algorithmic ideas only; do not make reserve/distribution depend on raid-history synchronization. |
| `addon.hasDebug` / `addon:debug` | Runtime-enabled debug visibility | Emit the first active-cooldown rejection only. |
| `addon.Diagnose` (`Diag.D`) | Diagnostic template ownership | Add one generic request-admission rejection template with service, kind, and normalized sender placeholders. |
| ChatThrottleLib through `addon.Comms` | Existing outbound bandwidth scheduling | Leave unchanged; it is downstream of the new admission boundary. |

### No new dependencies

Do not add Ace libraries, a rate-limit package, a timer abstraction, a shared request-admission module, TOC entries, or configuration. This is two small service-owned guards around fixed existing dispatch points.

## Current Architecture and Exact Integration Boundaries

### Reserve request path

Current order in `Sync:HandleMessage()`:

1. Verify prefix and run existing incoming-transfer cleanup.
2. Decode a dense five-field R5 envelope and validate request ID, target representation, and body table.
3. Validate that the target is broadcast for `META_REQ` or the local player for `DATA_REQ`.
4. Normalize sender for existing correlation/response use; preserve `rawSource` for authorization.
5. Call `IsGroupMember(Raid, rawSource)` for both request kinds.
6. Validate the exact body shape inside the selected request branch.
7. Call `sendMetadata(source, requestId)` or `sendData(source, requestId)`.

Insert admission between steps 6 and 7, passing the original sender for canonical rate-key derivation. Do not move the membership check or reuse the rate key for authorization. The existing response target (`source`) and request ID remain untouched.

The protected work begins at:

- `sendMetadata`: checks availability, calls `Sync:GetPayload()`, serializes a `META_ACK`, and queues it; no-data sends the existing `DATA_ERR`.
- `sendData`: checks availability, calls `Sync:GetPayload()`, builds the canonical projection and transfer, serializes it, builds all chunk envelopes, allocates a messages table, queues the batch, and queues `DATA_DONE`; failure uses the existing error response.

Consequently, admission inside `sendMetadata` or `sendData` would be too broad an API change and would obscure which request kind owns the budget. Admission after `Sync:GetPayload`, `Payload.Serialize`, or `buildChunkMessages` is too late for COMM-01.

### Distribution snapshot path

`decodeMessage()` already performs all structural validation before returning `SNAP_REQ`: message length, deserialization, dense five-slot envelope, exact protocol version 5, known kind, request-ID/target types, local-target rules, required request ID, broadcast-only request target, and an empty body. `HandleMessage()` then calls `IsGroupMember(Raid, sender)` using the original sender.

Admit immediately after that successful membership check. On rejection, return `true`. On admission, continue to the existing dispatcher and preserve its current `return DistributionSession.PublishSnapshot(sender, requestId)` behavior. `PublishSnapshot()` performs `canPublish`, session-ID creation, `encodeSnapshot()`, single-message serialization or chunk-message construction, and direct/batch enqueue. Never call it for a rejected request.

### Ownership and state shape

Use a single sender map in each existing owner, for example conceptually:

```lua
-- Shape recommendation; exact internal names remain planner discretion.
owner._requestAdmissions[normalizedSender] = {
	[MESSAGE_KIND] = {
		admittedAt = now,
		rejectionLogged = false,
	},
}
```

For reserves, one sender entry can hold independent `META_REQ` and `DATA_REQ` states. For distribution, it holds only `SNAP_REQ`. A single sender map makes the 128-entry service-wide bound literal: reserves can never grow to 256 entries merely because it has two request kinds. It also keeps debug deduplication inside the same bounded state instead of introducing an attacker-growable second map.

The maps belong on `Sync` and `DistributionSession`, following their existing `_incoming`, `_pendingRequests`, and `_incomingSnapshots` transient state patterns. They are not placed in `RMA_*`, addon options, wire bodies, or the database layer. A normal login or `/reload` creates a fresh addon namespace and therefore fresh maps.

## Recommended Admission Algorithm

### Constants

- `REQUEST_COOLDOWN_SECONDS = 5`
- `MAX_REQUEST_SENDERS = 128`

Capacity 128 is recommended because it is already the established `MAX_RATE_PEERS` bound in `Database/DBSyncSession.lua`, comfortably exceeds a WotLK raid roster, and avoids inventing another repository-specific scale. The capacity is per service, not shared between reserve and distribution.

### Normalize

1. Call the already-bound `Comms.NormalizeSender(sender)`.
2. Require a non-empty string result.
3. Apply `string.lower` to that result for the rate key.
4. On failure, reject silently without creating an anonymous or fallback entry.

Do not change `Comms.NormalizeSender` itself. Its current behavior extracts text before the first hyphen and delegates to `Strings.NormalizeName`; changing it would affect every communication owner.

### Lazy prune and count

For every existing sender entry, remove a request-kind state when `now - admittedAt >= REQUEST_COOLDOWN_SECONDS`. After kind pruning, remove the sender entry when no active kinds remain. Count only remaining sender entries. This exact `>=` comparison admits at `t + 5.000`; using `>` would be an off-by-one error. The existing DBSync rate map expresses the same boundary by retaining only timestamps strictly newer than its cutoff.

Prune only after the request has passed decoding, target/body validation, and current authorization. Invalid or unauthorized floods should not consume or mutate admission state, including cleanup state.

### Admit or reject

1. If the normalized sender already has active state for this request kind, reject without updating `admittedAt`.
2. If debug is enabled and that active kind has not logged a rejection, emit one diagnostic and set only `rejectionLogged = true`.
3. If the sender is new and the post-prune count is 128, reject without evicting any active sender and without creating a new state entry.
4. Otherwise create/reuse the sender entry and set this kind to `{ admittedAt = now, rejectionLogged = false }`.
5. Treat this admission as consumed even when the following existing provider/publisher path returns no data or another failure.

A capacity-rejected unseen sender has no admitted cooldown to deduplicate and cannot be added without violating the bound. Keep that path silent. The required one-debug-line behavior applies to rejection during an existing admitted sender/kind cooldown, whose dedupe flag is already bounded.

### Debug diagnostic

One repository-owned template is sufficient, for example:

```lua
Diag.D.LogSyncRequestRateLimited = "[Sync] Request rate limited service=%s kind=%s sender=%s"
```

Guard with the established runtime debug signal (`addon.hasDebug`) and `addon.debug`. Format only an ASCII service label, request-kind constant, and lowercase normalized short name. Do not format `msg`, `body`, request payload data, snapshot rows, checksums, or transfer content.

## Recommended Plan Decomposition

### Plan 03-01: Bound reserve metadata and data responses

1. Extend the reserve fixture and add a failing owner-level case covering first `META_REQ` and `DATA_REQ` admission, cross-kind independence, same-kind alias rejection, `t + 4.999` rejection, exact `t + 5.000` admission, rejected-attempt non-extension, invalid/unauthorized non-consumption, role re-evaluation without cooldown clearing, no-data consumption, capacity 128 with lazy pruning/no eviction, one debug line per cooldown, and zero payload-construction/serialization/queue calls for rejection.
2. Add the reserve-local admission map/helper, integrate it after each body validator and before the existing send function, and add the shared diagnostic key.

Likely files:

- `Raid Management Addon/Services/Reserves/Sync.lua`
- `Raid Management Addon/Localization/DiagnoseLog.en.lua`
- `tests/lua/harness/50_reserves_messaging.lua`
- `tests/test_sync_communications_behavior.py`

### Plan 03-02: Bound distribution snapshot responses and close compatibility coverage

1. Extend the distribution fixture and add a failing owner-level case covering the same one-per-five-second semantics, short-name/case aliases, malformed and non-member non-consumption, authorization re-evaluation, no-publish consumption, capacity 128 with lazy pruning/no eviction, debug deduplication, handled rejection, and proof that rejection never enters `PublishSnapshot`, snapshot serialization, chunk construction, or transport.
2. Add the distribution-local admission map/helper after `SNAP_REQ` membership authorization and before the dispatcher. Assert that the normal first response still uses `RMADist`, R5, the original request ID and target semantics, then run the focused owner checks and repository validators available in the environment.

Likely files:

- `Raid Management Addon/Services/Loot/DistributionSession.lua`
- `tests/lua/harness/10_loot_distribution.lua`
- `tests/test_loot_distribution_hardening_behavior.py`

The second plan should reuse the diagnostic template added by Plan 03-01. It should reproduce the tiny owner-local algorithm rather than extracting a module: the services cannot share state, have different message validation/dispatch shapes, and need only one helper apiece.

## Don't Hand-Roll

| Problem | Do not build | Use instead | Why |
|---------|--------------|-------------|-----|
| Sender identity | Realm parsing, case rules, GUID lookup, or a new canonical-name service | `Comms.NormalizeSender` plus `string.lower` | Preserves the established communication identity contract and alias behavior. |
| Rate algorithm | Token bucket, sliding window, retry queue, exponential backoff, or configurable limiter | One admitted timestamp per sender/kind | The locked contract is exactly one request every five seconds; extra machinery adds states the phase does not need. |
| Cleanup | Timer, ticker, `OnUpdate`, logout hook, or group-roster cleanup | Lazy pruning on admitted request paths | Expired entries are harmless until another relevant request and must not add permanent work. |
| Global protection | Eviction/LRU or an unbounded overflow/dedupe table | Fixed 128 active senders per service and fail-closed new-sender rejection | Eviction lets attacker churn displace active protection; overflow state defeats the memory bound. |
| Cross-owner reuse | Dependency from reserve/distribution to `DB.SyncSession` | Reproduce the small timestamp-map pattern locally | DBSync has different 6/30-second sliding semantics, live/history classes, retry-delay returns, and database ownership. |
| Transport shaping | Replacement for ChatThrottleLib or new queue rules | Existing `addon.Comms` transport after admission | Outbound bandwidth throttling does not prevent pre-queue construction work and should remain unchanged. |
| Abuse reporting | Wire ACK/error, UI warning, popup, persisted ban, or chat message | One debug-only local diagnostic per active cooldown | All user-facing/wire/persistent responses are explicitly out of scope. |

## Common Pitfalls

### 1. Admitting before full request validation and authorization

**Failure:** malformed, wrong-version, mistargeted, non-member, or malformed-body requests consume a real member's cooldown.

**Prevention:** distribution may admit after its decoder and membership check because the decoder validates the empty body. Reserves must admit separately inside each request branch after its branch-specific body validator; the shared authorization block alone is not late enough.

### 2. Admitting inside or after response construction

**Failure:** the addon still builds reserve projections/snapshots, serializes bodies, allocates chunk tables, or reaches ChatThrottleLib before rejecting.

**Prevention:** gate before `sendMetadata`, `sendData`, and `PublishSnapshot`. Tests must spy on those construction surfaces, not merely assert that no final packet was observed.

### 3. Sharing reserve request-kind state

**Failure:** the normal `META_REQ` -> `META_ACK` -> `DATA_REQ` exchange self-throttles.

**Prevention:** store independent timestamps under the same normalized sender entry and explicitly send both kinds at the same test time.

### 4. Case or realm aliases bypassing the budget

**Failure:** `Player`, `player`, `Player-Realm`, and `player-OtherRealm` allocate distinct quotas.

**Prevention:** derive only the admission key from lowercase `Comms.NormalizeSender(originalSender)`. Keep the original sender for every membership/authority check and preserve existing response targeting.

### 5. Rejection extending the cooldown

**Failure:** a request flood keeps moving the eligibility time forward forever.

**Prevention:** never overwrite `admittedAt` on rejection; only set the bounded debug-dedupe flag. Test admit at `t`, reject at `t + 4.999`, and admit at exactly `t + 5.000`.

### 6. Clearing cooldown on authorization changes

**Failure:** leaving and rejoining the group or changing roles grants an immediate new request.

**Prevention:** admission state is not roster state. Re-check authorization from the original sender on every message, but prune cooldown only by elapsed time.

### 7. Per-kind capacity instead of service-wide sender capacity

**Failure:** the reserve owner tracks 256 senders because each of two request-kind maps independently allows 128.

**Prevention:** use one sender-keyed map per service with nested kind state. Count sender keys after pruning.

### 8. Evicting an active sender to admit a new one

**Failure:** a churn attack repeatedly replaces protected entries and regains response work.

**Prevention:** at capacity, existing senders retain their state and unseen senders fail closed. Admit a new sender only after lazy pruning actually frees a key.

### 9. Unbounded debug deduplication

**Failure:** the response map is bounded but a second logging map grows with every spoofed sender.

**Prevention:** keep `rejectionLogged` inside active admitted kind state. Do not allocate debug state for invalid identities or capacity-rejected unseen senders.

### 10. Returning a fall-through value on rejection

**Failure:** another protocol owner can see or reinterpret an already-recognized message.

**Prevention:** return `true` for every silent rate/capacity/identity rejection after the prefix has matched. Preserve existing first-request return behavior.

### 11. Accidentally changing compatibility surfaces

**Failure:** a protocol bump, new error envelope, modified request body, changed target, or new queue priority breaks mixed RMA clients.

**Prevention:** change only internal admission state and dispatch guards. Assert the first admitted response's prefix, envelope version, kind, request ID, body shape, target, and existing priority in the owner tests.

## Test Strategy

### Reserve fixture additions

The existing `installRealReservesSyncFixture` already supplies a real payload codec, controllable `GetTime`, captured direct/batch sends, sender normalization, and authorization stubs. Extend it minimally with:

- mutable group-membership/authorization behavior using the original sender;
- captured debug messages and an `addon.hasDebug` toggle;
- a counter wrapper around `Sync.GetPayload` to prove rejected requests do not construct reserve payloads;
- a counter wrapper around `Payload.Serialize`, with all inbound request envelopes prebuilt before the counter is reset, to prove no response serialization;
- existing `sent` length/kind counts to prove no queue allocation;
- a way to set local-data availability for the first valid no-data/failure case.

Keep the existing outgoing request-correlation/capacity case. Add a separate clearly named inbound response-admission case rather than overloading its unrelated pending-request assertions.

### Distribution fixture additions

`createDistributionSessionFixture` already supplies controllable time, real payload encoding, captured sends, mutable authority, and group stubs. Extend it with:

- mutable membership and `CanUseCapability` results;
- debug capture and enable toggle;
- a wrapper around `DistributionSession.PublishSnapshot` to count entries into snapshot construction;
- a `Payload.Serialize` response counter after all inbound messages are prebuilt;
- existing `kindAttempts` / `sent` counters for transport proof.

Keep the existing correlated incoming-snapshot assembly cap case. Add a separate inbound `SNAP_REQ` admission case because assembly limits and responder request limits protect different resources.

### Required behavior matrix

For each applicable request kind, prove:

1. first valid authorized request is admitted and produces the unchanged compatible behavior;
2. same normalized sender/kind before five seconds is handled silently;
3. reserve request kinds remain independent, and each service retains its own separately bounded map;
4. a rejected replay does not move the original expiry;
5. exact `t + 5.000` is admitted;
6. case and `Name-Realm` aliases share state;
7. malformed, wrong-target/version, invalid-normalization, and unauthorized input do not consume state;
8. authorization is evaluated from the original sender each time and leave/re-entry does not clear active state;
9. a valid no-data/publish-failure request consumes its admission;
10. only the first active-cooldown rejection logs in debug mode;
11. 128 active senders is the hard service bound; sender 129 is rejected without eviction or response work;
12. lazy expiry frees capacity and admits at the exact boundary;
13. rejected requests perform zero payload/snapshot construction, response serialization, chunk building, and queue work.

### Suggested focused commands

When a Lua 5.1-compatible executable is available:

```powershell
lua tests/lua/runtime_harness.lua reserves_sync_incoming_requests_are_rate_limited_before_response_work
lua tests/lua/runtime_harness.lua loot_distribution_snapshot_requests_are_rate_limited_before_response_work
python -m unittest tests.test_sync_communications_behavior tests.test_loot_distribution_hardening_behavior
```

Repository/runtime checks after both owners are complete:

```powershell
py -3 .agents/skills/wow-addon-dev-wotlk-v335a/scripts/lint_lua51.py "Raid Management Addon"
py -3 .agents/skills/wow-addon-dev-wotlk-v335a/scripts/scan_xpcall.py "Raid Management Addon"
rg -n "C_Timer|OnUpdate|ScheduleTimer" "Raid Management Addon/Services/Reserves/Sync.lua" "Raid Management Addon/Services/Loot/DistributionSession.lua"
git diff --check
```

The current environment still has no `lua` command, matching `.planning/STATE.md`. Python methods that invoke `run_lua_case` will therefore report an environment limitation here. The executor should still add the Lua behavior cases, run the Lua 5.1 static validator, and run the cases in a Lua-capable or in-game environment before claiming COMM-04 fully verified.

## Open Questions

No design question remains open for planning. The discretionary choices are resolved as follows:

- capacity: 128 active normalized senders per owning service;
- state: one sender-keyed owner-local map with nested request-kind state;
- reuse: reproduce the small DBSync timestamp-map pattern locally, without a database dependency;
- debug: one shared diagnostic template, with dedupe inside bounded admitted-kind state;
- rejection return: `true`, so the message remains handled;
- tests: new inbound-admission behavior cases beside, not inside, the existing outgoing correlation/assembly-limit cases.

The only verification constraint is environmental: the current shell lacks a Lua executable. This does not block planning or implementation, but runtime behavior evidence must be obtained before phase acceptance.

## Sources

### Primary (HIGH confidence)

- `.planning/phases/03-bounded-sync-requests/03-CONTEXT.md` - locked admission, identity, capacity, visibility, and compatibility decisions.
- `.planning/REQUIREMENTS.md` and `.planning/ROADMAP.md` - COMM-01 through COMM-04 and phase success criteria.
- `Raid Management Addon/Services/Reserves/Sync.lua:36-70,400-471,541-624` - R5 constants, transient owner state, response construction, closed decode, authorization, body validation, and exact request dispatch seams.
- `Raid Management Addon/Services/Loot/DistributionSession.lua:40-113,966-1088,1143-1145,2004-2071,2091-2167` - R5 constants, normalization, closed request validation, snapshot serialization, pending request behavior, membership authorization, and exact publish seam.
- `Raid Management Addon/Modules/Comms.lua:405-411` - established short-name sender normalization.
- `Raid Management Addon/Database/DBSyncSession.lua:34-38,77-160` - established 128-peer bound, lowercase normalization, lazy timestamp pruning, capacity rejection, and non-extending admission pattern.
- `tests/lua/harness/70_raid_sync.lua:578-759` - existing exact-boundary, no-serialization/no-queue, independent-class, map-bound, lazy-expiry, and capacity retry tests.
- `tests/lua/harness/50_reserves_messaging.lua:1395-1520,1834-1870,2109-2173` - reserve fixture capabilities, real response path, and existing outgoing correlation/capacity coverage.
- `tests/lua/harness/10_loot_distribution.lua:3-134,484-547` - distribution fixture capabilities and existing pending snapshot/assembly bounds.
- `Raid Management Addon/Init.lua:429-475` and `Raid Management Addon/Database/DBOptions.lua:366-380` - established runtime debug enablement and non-persisted debug state.
- `Raid Management Addon/Localization/DiagnoseLog.en.lua` - repository diagnostic-template owner.
- `AGENTS.md` and `.agents/skills/wow-addon-dev-wotlk-v335a/SKILL.md` - binding WotLK 3.3.5a, Lua 5.1, owner-boundary, no-SavedVariables, no-wire-change, and no-polling constraints.

### Missing requested context files

The supplied file list named `.planning/codebase/ARCHITECTURE.md`, `CONVENTIONS.md`, `STACK.md`, and `TESTING.md`, but `.planning/codebase/` does not exist in this checkout. The live source, tests, root `AGENTS.md`, project skill, and planning artifacts above provide direct higher-fidelity evidence, so their absence does not block this research.

## Metadata

**Confidence breakdown:**

- Standard stack: HIGH - fixed by repository runtime policy and current owner dependencies.
- Integration boundaries: HIGH - both handlers, validators, response constructors, and transport calls were inspected directly.
- Admission algorithm: HIGH - exact locked semantics plus an existing repository implementation/test precedent.
- Capacity recommendation: HIGH - 128 is already the repository's bounded peer-map constant and tests establish its behavior.
- Test strategy: HIGH - both live fixtures and the existing DBSync rate-limit regression were inspected directly.
- Runtime execution availability: HIGH - `lua` is absent from PATH and the limitation is already recorded in project state.

**Research date:** 2026-08-15
**Valid until:** stable for this repository revision; re-check if either owner handler, R5 codec, sender normalization, or test fixture changes before execution.
