# Live Loot Synchronization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver normal loot to every aligned RMA replica through one compact broadcast, then recover missed positions monotonically without request churn, live/history rate starvation, or dependence on a later loot event.

**Architecture:** Protocol v4 adds a positional `LIVE_LOOT` codec that reconstructs the existing canonical event exactly and falls back to a consolidated head when it cannot. `DBSyncer` broadcasts the compact event immediately, advertises one trailing active head after 0.25 seconds, and retains the newest compatible recovery target while useful work finishes. `DBSyncSession` keeps independent bounded live and history rate classes and reports the exact retry delay to the orchestrator.

**Tech Stack:** WoW 3.3.5a build 12340, Interface 30300, Lua 5.1.5, addon messages, JSON positional encoding, Python `unittest`, Lua runtime harness, PowerShell validators, StyLua, Luacheck.

## Global Constraints

- Accept only wire marker `R4`; reject `R3` without negotiation, dual broadcast, or a legacy decoder.
- Keep valid `RMA_Raids`, `RMA_Players`, `RMA_Reserves`, `RMA_Warnings`, `RMA_Spammer`, and `RMA_Options` data unchanged.
- Keep the canonical raid archive, event vocabulary, reducers, digest algorithm, stable entity IDs, and SavedVariables schema unchanged.
- Every encoded addon message must be at most 243 bytes; transfer chunks remain at most 220 bytes.
- `LIVE_LOOT` uses dense positional JSON with explicit JSON null values, no named body fields, no Base64 expansion, and no Deflate compression.
- Normal aligned replicas receive one group `LIVE_LOOT`; range and snapshot recovery remain correlated whispers.
- Active commits advertise only the newest trailing `HEAD` 0.25 seconds after the latest commit; `RAID_CONCLUDED` keeps its immediate final head.
- Keep one useful ordinary replica recovery in flight and retain only the newest compatible follow-up position.
- Live and history classes each allow four outgoing operations per target and six incoming requests per sender in a thirty-second window.
- A rate-limited admission returns the exact delay until the oldest relevant timestamp expires; backpressure retries once after 0.25 seconds.
- `TIMER_UNAVAILABLE`, invalid authority, invalid metadata, malformed canonical data, and digest conflicts remain terminal fail-closed outcomes.
- Preserve stricter handover, reentry, raid conclusion, and consent-gated historical transfer semantics.
- Keep the global communications FIFO at one message every 0.10 seconds and capacity 256; do not globally accelerate it.
- Do not add a runtime module, TOC entry, generic retry framework, user option, Ace dependency, Retail API, Lua 5.2+ construct, or change under `Raid Management Addon/Libs/`.

---

### Task 1: Protocol V4 Compact Live-Loot Codec

**Files:**
- Modify: `tests/lua/runtime_harness.lua:4604-4945`
- Modify: `tests/test_raid_replication_behavior.py:191-196`
- Modify: `Raid Management Addon/Database/DBSyncProtocol.lua:1-430`

**Interfaces:**
- Consumes: `RaidEvents.BuildEventUid(raidUid, epoch, sequence)`, `RaidEvents.ValidateEvent(event)`, `Item.GetItemIdFromLink(itemLink)`, `Item.GetItemStringFromLink(itemLink)`, `Json.NULL`.
- Produces: `Protocol.VERSION == 4`; `Protocol.Encode("LIVE_LOOT", "-", "-", { event = canonicalEvent }) -> wire | nil, reason`; `Protocol.Decode(wire) -> envelope` whose `body.event` is the exact reconstructed canonical event.
- Preserves: `Protocol.Encode`, `Decode`, `EncodeBody`, and `DecodeBody` for all existing message kinds; their only common wire change is `R3` to `R4`.

- [ ] **Step 1: Write the failing version-4 and compact-codec tests**

Update `installRaidReplicationProtocolFixture` with the same deterministic item
parsers used by production. Do not load all of `Modules/Item.lua` into this
focused fixture because its unrelated WoW API dependencies would turn a codec
test into an incomplete runtime mock:

```lua
addon.Item = addon.Item or {}
addon.Item.GetItemIdFromLink = function(itemLink)
	return type(itemLink) == "string" and tonumber(string.match(itemLink, "item:(%d+)")) or nil
end
addon.Item.GetItemStringFromLink = function(itemLink)
	return type(itemLink) == "string" and string.match(itemLink, "|H(item:[%-%d:]+)|h") or nil
end
```

Update `raid_replication_protocol_round_trip` to expect version 4, add `LIVE_LOOT` to `protocolBodies()`, and assert `R3` rejection:

```lua
assertEqual(4, protocol.VERSION, "protocol version differs")
assertEqual(nil, protocol.Decode(string.gsub(wire, "^R4", "R3")), "R3 wire was accepted")
```

Add `cases.raid_replication_protocol_compact_live_loot` using a realistic epic hyperlink and canonical event:

```lua
local event = {
	raidUid = "r:1721120000:1:12345678",
	authorityEpoch = 1,
	sequence = 42,
	eventUid = assert(events.BuildEventUid("r:1721120000:1:12345678", 1, 42)),
	eventType = "LOOT_ADDED",
	payload = {
		loot = {
			lootNid = 31,
			itemId = 47242,
			itemName = "Pride of the Eredar",
			itemString = "item:47242:0:0:0:0:0:0:0",
			itemLink = "|cffa335ee|Hitem:47242:0:0:0:0:0:0:0|h[Pride of the Eredar]|h|r",
			itemRarity = 4,
			itemTexture = "Interface\\Icons\\INV_Jewelry_Ring_66",
			itemCount = 1,
			looterNid = 7,
			rollType = 1,
			rollValue = 94,
			rollSessionId = "RS:42",
			bossNid = 4,
			time = 1721120200,
			source = "DISTRIBUTION_AWARD",
		},
	},
	resultDigest = "12345678:2048",
}
local verbose, verboseReason = protocol.Encode("EVENT", "-", "-", { event = event })
assertEqual(nil, verbose, "representative verbose loot unexpectedly fit")
assertEqual("MESSAGE_TOO_LARGE", verboseReason)
local wire, reason = protocol.Encode("LIVE_LOOT", "-", "-", { event = event })
assertTrue(wire ~= nil, "compact live loot did not encode: " .. tostring(reason))
assertTrue(#wire <= 243, "compact live loot exceeded 243 bytes")
local decoded = assert(protocol.Decode(wire))
assertEqual("LIVE_LOOT", decoded.kind)
assertTrue(deepEqual(event, decoded.body.event), "compact live loot did not reconstruct exactly")
```

Extend `raid_replication_protocol_rejects_invalid` with dense-array arity, null-slot, malformed hyperlink, mismatched derived item fields, unexpected loot keys, malformed nested source tuples, and an encoded result over 243 bytes. Each must return `INVALID_MESSAGE_BODY`, `NON_RECONSTRUCTIBLE_LIVE_LOOT`, or `MESSAGE_TOO_LARGE` without throwing.

Add the Python wrapper:

```python
def test_version_4_compact_live_loot_is_exact_and_wire_bounded(self) -> None:
    self.assert_case("raid_replication_protocol_compact_live_loot")
```

Rename the two existing Python version-3 method names to version 4 without changing their Lua case names.

- [ ] **Step 2: Run the focused tests and verify RED**

Run:

```powershell
py -3 -m unittest tests.test_raid_replication_behavior.RaidReplicationBehaviorTests.test_version_4_protocol_round_trips_every_closed_message_kind tests.test_raid_replication_behavior.RaidReplicationBehaviorTests.test_version_4_protocol_rejects_invalid_envelopes_and_bodies tests.test_raid_replication_behavior.RaidReplicationBehaviorTests.test_version_4_compact_live_loot_is_exact_and_wire_bounded
```

Expected: FAIL because the protocol still emits `R3`, has no `LIVE_LOOT` schema, and verbose `EVENT` is the only live codec.

- [ ] **Step 3: Add the closed compact schema and deterministic projections**

In `DBSyncProtocol.lua`, add the item dependency and explicit schema:

```lua
local Item = assert(addon.Item, "Item dependency is not initialized")

MESSAGE_SCHEMAS.LIVE_LOOT = { event = true }

local LOOT_FIELDS = {
	lootNid = true, itemId = true, itemName = true, itemString = true,
	itemLink = true, itemRarity = true, itemTexture = true, itemCount = true,
	looterNid = true, rollType = true, rollValue = true, rollSessionId = true,
	bossNid = true, time = true, source = true, lootSource = true,
}

local ITEM_RARITY_BY_COLOR = {
	ff9d9d9d = 0, ffffffff = 1, ff1eff00 = 2, ff0070dd = 3,
	ffa335ee = 4, ffff8000 = 5, ffe6cc80 = 6,
}
```

Represent the body as exactly sixteen slots:

```lua
local function compactLiveLoot(event)
	local loot = event.payload.loot
	return {
		event.raidUid, event.authorityEpoch, event.sequence, event.resultDigest,
		loot.lootNid, loot.itemLink, loot.itemCount, loot.looterNid,
		loot.rollType, loot.rollValue, loot.rollSessionId or Json.NULL,
		loot.bossNid, loot.time, loot.source or Json.NULL,
		loot.itemTexture or Json.NULL, encodeLootSource(loot.lootSource) or Json.NULL,
	}
end
```

`encodeLootSource` and `decodeLootSource` must use this exact positional shape:

```text
[kind,bossNid,sourceNpcId,sourceName,sourceKey,openedAt,snapshotId,candidates]
candidate = [name,kind,sourceKey,npcId]
```

Reject unknown source/candidate keys. Use `Json.NULL` for every nil slot. Bound candidates before allocation using the current canonical event/entity limits; do not add a new persistence validator rule.

Reconstruct `itemId`, `itemString`, hyperlink display name, hyperlink color rarity, `eventUid`, and constant `LOOT_ADDED`. Reject the compact path unless a private deep exact comparison proves that the reconstructed event has the same keys and values as the input canonical event.

- [ ] **Step 4: Route version-4 encoding and decoding through the compact body**

Use one marker constant and special-case only `LIVE_LOOT`:

```lua
local WIRE_MARKER = "R4"
Protocol.VERSION = 4

local function encodeBodyForKind(kind, body)
	if kind == "LIVE_LOOT" then
		local compact, reason = encodeLiveLootBody(body.event)
		if not compact then return nil, reason end
		return encodeJson(compact)
	end
	return Protocol.EncodeBody(body)
end

local function decodeBodyForKind(kind, text)
	if kind == "LIVE_LOOT" then
		return decodeLiveLootBody(text)
	end
	return Protocol.DecodeBody(text)
end
```

Add `LIVE_LOOT` to the fire-and-forget envelope kinds. `Protocol.Encode` must use `WIRE_MARKER`, run the existing 243-byte final gate, and `Protocol.Decode` must require exactly `R4`. The decoded compact body must still pass `RaidEvents.ValidateEvent` through `validateBody`.

- [ ] **Step 5: Run focused and neighboring protocol tests and verify GREEN**

Run:

```powershell
py -3 -m unittest tests.test_raid_replication_behavior.RaidReplicationBehaviorTests.test_version_4_protocol_round_trips_every_closed_message_kind tests.test_raid_replication_behavior.RaidReplicationBehaviorTests.test_version_4_protocol_rejects_invalid_envelopes_and_bodies tests.test_raid_replication_behavior.RaidReplicationBehaviorTests.test_version_4_compact_live_loot_is_exact_and_wire_bounded tests.test_raid_replication_behavior.RaidReplicationBehaviorTests.test_transfer_sessions_assemble_ranges_and_reject_conflicting_duplicates
```

Expected: PASS.

- [ ] **Step 6: Commit**

```powershell
git add -- "Raid Management Addon/Database/DBSyncProtocol.lua" "tests/lua/runtime_harness.lua" "tests/test_raid_replication_behavior.py"
git commit -m "feat(sync): add compact version 4 live loot codec"
```

---

### Task 2: Independent Live And History Rate Classes

**Files:**
- Modify: `tests/lua/runtime_harness.lua:18480-19105,24391-24990`
- Modify: `tests/test_sync_communications_behavior.py:96-115`
- Modify: `Raid Management Addon/Database/DBSyncSession.lua:25-390`
- Modify: `Raid Management Addon/Database/DBSyncer.lua:573-580,638-646,1388-1475,1715-1725`

**Interfaces:**
- Produces: `Session.RATE_CLASS_LIVE == "live"`, `Session.RATE_CLASS_HISTORY == "history"`.
- Changes: `AllowIncomingRequest(sender, rateClass) -> allowed, reason, retryDelay`; `BeginRequest(..., callback, rateClass) -> requestId | nil, reason, retryDelay`; `QueueTransfer(..., body, rateClass) -> queued, reason, retryDelay`.
- Preserves: four outgoing operations and six incoming requests per peer per thirty seconds within each class; one correlated timeout resend that consumes no new operation slot.

- [ ] **Step 1: Write failing rate-isolation and exact-delay tests**

Update `beginRangeRequest` and all direct session calls to pass `fixture.session.RATE_CLASS_LIVE`. Extend `raid_transfer_session_rate_limits`:

```lua
for i = 1, 4 do
	assert(beginRangeRequest(fixture, function() end, "Peer"))
end
local id, reason, retryDelay = fixture.session:BeginRequest(
	"RANGE_REQ", "Peer", rangeMetadata(), "RANGE_DATA", rangeMetadata(),
	function() end, fixture.session.RATE_CLASS_LIVE
)
assertEqual(nil, id)
assertEqual("RATE_LIMIT", reason)
assertEqual(30, retryDelay)

for i = 1, 4 do
	assert(fixture.session:QueueTransfer(
		"SNAP_DATA", "history-" .. i, "Peer",
		{ raidUid = "r1", authorityEpoch = 1, sequence = 1 },
		{ snapshot = "x" }, fixture.session.RATE_CLASS_HISTORY
	))
end
```

Assert the fifth history operation fails independently, live remains capped,
the seventh incoming request fails independently per class, and advancing to
exactly `now + 30` admits the next operation. Add a history-offer integration
assertion that accepted historical `SNAP_REQ` and `SNAP_DATA` use `history`,
while active range/snapshot calls use `live`.

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```powershell
py -3 -m unittest tests.test_sync_communications_behavior.SyncCommunicationsBehaviorTests.test_transfer_session_rate_limits_have_exact_boundaries
```

Expected: FAIL because the session has one shared map, accepts no class argument, and returns no retry delay.

- [ ] **Step 3: Partition bounded rate state and return exact delay**

In `DBSyncSession.lua`:

```lua
Session.RATE_CLASS_LIVE = "live"
Session.RATE_CLASS_HISTORY = "history"

local RATE_CLASSES = { live = true, history = true }
Session._incomingRates = { live = {}, history = {} }
Session._outgoingRates = { live = {}, history = {} }
```

Keep reload/test fixture safety with a small normalizer that returns an existing
`{ live, history }` shape or replaces the obsolete runtime-only flat map. Do not
migrate or persist rate timestamps.

When a peer is at its limit, return the exact remaining delay:

```lua
local retryDelay = timestamps[1] + RATE_WINDOW_SECONDS - now
if retryDelay < 0 then retryDelay = 0 end
return false, "RATE_LIMIT", retryDelay
```

Validate the rate class and request contract before consuming a timestamp.
`RATE_CAPACITY` returns the earliest expiry in that class. Queue or timer failure
does not allocate pending request state; keep its existing reason.

- [ ] **Step 4: Wire every sync call to the correct class**

Use `Session.RATE_CLASS_LIVE` for:

- active `RANGE_REQ` and `RANGE_DATA`;
- active replica, handover, and reentry `SNAP_REQ` and `SNAP_DATA`.

Use `Session.RATE_CLASS_HISTORY` for:

- consented completed-raid `SNAP_REQ` and `SNAP_DATA`.

Pass the class to both `AllowIncomingRequest` and `QueueTransfer` on the response
side. Do not infer historical consent inside `DBSyncSession`; `DBSyncer` already
owns that policy.

- [ ] **Step 5: Run focused session and historical-transfer tests**

Run:

```powershell
py -3 -m unittest tests.test_sync_communications_behavior.SyncCommunicationsBehaviorTests.test_transfer_session_rate_limits_have_exact_boundaries tests.test_sync_communications_behavior.SyncCommunicationsBehaviorTests.test_transfer_session_retries_once_then_fails_once tests.test_raid_recording_integrity_behavior
```

Expected: PASS with no Deflate calls and no cross-class starvation.

- [ ] **Step 6: Commit**

```powershell
git add -- "Raid Management Addon/Database/DBSyncSession.lua" "Raid Management Addon/Database/DBSyncer.lua" "tests/lua/runtime_harness.lua" "tests/test_sync_communications_behavior.py"
git commit -m "fix(sync): isolate live recovery rate budget"
```

---

### Task 3: Immediate Live Broadcast And Consolidated Active Head

**Files:**
- Modify: `tests/lua/runtime_harness.lua:19096-20170,20649-20670`
- Modify: `tests/test_sync_communications_behavior.py:15-28`
- Modify: `Raid Management Addon/Database/DBSyncer.lua:30-100,267-345,1286-1365,1553-1580,1800-1920`

**Interfaces:**
- Consumes: version-4 `Protocol.Encode("LIVE_LOOT", ...)` and existing `Comms.SendAddonBatch`.
- Produces: one immediate group `LIVE_LOOT` for reconstructible loot; one replaceable active-head timer at exactly 0.25 seconds; ordinary `LIVE_LOOT` input reuses canonical event application.
- Preserves: immediate final `RAID_CONCLUDED` head, explicit `AdvertiseHead`, authority discovery, reentry, handover, and logger invalidation.

- [ ] **Step 1: Write failing multi-replica and lost-final-message tests**

Add a fixture helper that fires a timer by exact delay without disturbing
handover/reentry timers:

```lua
function client:FireTimerByDelay(expectedDelay)
	for index, timer in pairs(self.timers or {}) do
		if timer and timer.delay == expectedDelay and not timer.cancelled then
			self.timers[index] = nil
			timer.callback()
			return true
		end
	end
	return false
end
```

Add `raid_live_loot_broadcast_advances_multiple_replicas`: install Leader,
MemberB, and MemberC with the real protocol and aligned real stores; commit four
real `LOOT_ADDED` events; assert each member reaches the leader's sequence,
digest, and loot count without `RANGE_REQ` or `SNAP_REQ`; assert four immediate
`LIVE_LOOT` broadcasts and, after firing the timer, exactly one `HEAD` carrying
the fourth position.

Add `raid_live_loot_lost_final_recovers_from_trailing_head`: temporarily remove
MemberB from `network.clients`, commit the final reconstructible loot, restore
MemberB, fire the leader's 0.25-second timer, and assert only MemberB sends one
`RANGE_REQ`, receives `RANGE_DATA`, and converges without another loot event.
MemberC must remain request-free.

Update the existing oversized generic-event fallback test so it asserts no
immediate head, fires the 0.25-second timer, then verifies one head-driven range
and convergence.

Add Python wrappers for the two new cases.

- [ ] **Step 2: Run the focused tests and verify RED**

Run:

```powershell
py -3 -m unittest tests.test_sync_communications_behavior.SyncCommunicationsBehaviorTests.test_compact_live_loot_broadcast_advances_every_aligned_replica tests.test_sync_communications_behavior.SyncCommunicationsBehaviorTests.test_lost_final_live_loot_recovers_from_consolidated_head tests.test_sync_communications_behavior.SyncCommunicationsBehaviorTests.test_oversized_real_protocol_event_falls_back_to_head_and_converges
```

Expected: FAIL because loot still falls back immediately to `HEAD`, no trailing
head is scheduled, and `LIVE_LOOT` is not routed by `DBSyncer`.

- [ ] **Step 3: Add one replaceable active-head scheduler**

In `DBSyncer.lua`:

```lua
local LIVE_HEAD_DELAY_SECONDS = 0.25
module._pendingHeadAdvertisement = nil

local function cancelPendingHead()
	local pending = module._pendingHeadAdvertisement
	if pending and pending.timer then module:CancelTimer(pending.timer) end
	module._pendingHeadAdvertisement = nil
end
```

`scheduleConsolidatedHead(record, raidUid)` must copy the current head, cancel
and replace the previous timer, and use an identity check in its callback. Before
sending, revalidate that the local client is still the normalized raid leader,
the raid remains active, and UID/epoch/sequence still match the pending head. If
scheduling returns nil or throws, clear pending state and send the newest head
immediately.

- [ ] **Step 4: Broadcast compact loot and route it through the existing reducer**

In `broadcastCommittedEvent`:

```lua
if event.eventType == "LOOT_ADDED" then
	local wire, reason = Protocol.Encode("LIVE_LOOT", "-", "-", { event = event })
	if wire then
		Comms.SendAddonBatch(COMM_PREFIX, { wire })
	elseif reason ~= "NON_RECONSTRUCTIBLE_LIVE_LOOT" and reason ~= "MESSAGE_TOO_LARGE" then
		setStatus(STATUS_FAILED, reason or "LIVE_LOOT_ENCODE_FAILED")
	end
else
	sendGroup("EVENT", { event = event })
end
```

For every commit whose record remains active, schedule the consolidated head
regardless of compact-send success. For `RAID_CONCLUDED`, cancel the pending
active head and keep the existing immediate final-head publication.

Add `LIVE_LOOT = handleEvent` to the handler table, fire-and-forget target rules,
and authority-gated kinds in `OnAddonMessage`. Because Protocol.Decode already
returns the full canonical event, do not create a second reducer or mutation
path.

- [ ] **Step 5: Run focused and authority-boundary tests**

Run:

```powershell
py -3 -m unittest tests.test_sync_communications_behavior.SyncCommunicationsBehaviorTests.test_compact_live_loot_broadcast_advances_every_aligned_replica tests.test_sync_communications_behavior.SyncCommunicationsBehaviorTests.test_lost_final_live_loot_recovers_from_consolidated_head tests.test_sync_communications_behavior.SyncCommunicationsBehaviorTests.test_oversized_real_protocol_event_falls_back_to_head_and_converges tests.test_sync_communications_behavior.SyncCommunicationsBehaviorTests.test_untrusted_sender_and_old_epoch_fail_closed tests.test_raid_replication_behavior.RaidReplicationBehaviorTests.test_conclusion_compacts_the_active_event_ledger_atomically
```

Expected: PASS. Normal compact delivery allocates no request session; missed or
oversized delivery converges after one trailing head.

- [ ] **Step 6: Commit**

```powershell
git add -- "Raid Management Addon/Database/DBSyncer.lua" "tests/lua/runtime_harness.lua" "tests/test_sync_communications_behavior.py"
git commit -m "feat(sync): broadcast compact live loot updates"
```

---

### Task 4: Monotonic Catch-Up And Bounded Admission Retry

**Files:**
- Modify: `tests/lua/runtime_harness.lua:19630-19795,20706-20820,21980-22071`
- Modify: `tests/test_sync_communications_behavior.py:28-75`
- Modify: `Raid Management Addon/Database/DBSyncer.lua:83-100,423-705,1100-1135,1225-1305`

**Interfaces:**
- Consumes: `BeginRequest` third failure value `retryDelay`, live rate class, existing `compareHead`, `requestRange`, `requestSnapshot`, and `finishRecovery`.
- Produces: one in-flight ordinary replica recovery with one newest compatible `followUp`; one `_admissionRetry` target/timer; at most one automatic retry for a retained target.
- Preserves: digest-conflict suspension, direct-event satisfaction, authority-change cancellation, range-to-snapshot fallback, handover/reentry failure closure, and one correlated timeout resend.

- [ ] **Step 1: Write failing monotonic range and admission-retry tests**

Add `raid_live_sync_range_coalesces_newer_head_burst`: hold the first range
response, deliver compatible active heads through a sequence greater than four,
and assert one initial `RANGE_REQ`, zero cancelled requests, and only the newest
follow-up retained. Release the first response; assert exactly one catch-up
range and final sequence/digest convergence.

Rewrite `raid_live_sync_real_session_monotonic_supersession` to express the new
contract: a newer final head does not cancel the active range; after the range
finishes, the retained complete head opens one final snapshot and converges.

Add `raid_live_sync_retries_latest_rate_limited_head`: preconsume four live
operations, deliver a valid head, assert no request and one retry timer with the
exact returned delay; deliver newer same-stream heads, assert the same timer and
newest target; advance the fixture clock to the boundary, fire the timer, and
assert one request for the newest sequence. Inject a second admission failure in
a separate assertion and verify it becomes `failed` without scheduling a third
attempt.

Keep the existing direct-event cancellation and pending digest-conflict cases as
neighbor regressions.

- [ ] **Step 2: Run focused tests and verify RED**

Run:

```powershell
py -3 -m unittest tests.test_sync_communications_behavior.SyncCommunicationsBehaviorTests.test_range_recovery_coalesces_newer_head_burst tests.test_sync_communications_behavior.SyncCommunicationsBehaviorTests.test_real_session_newer_conclusion_supersedes_pending_range tests.test_sync_communications_behavior.SyncCommunicationsBehaviorTests.test_rate_limited_live_recovery_retries_latest_head_once
```

Expected: FAIL because a newer range is cancelled/replaced, final heads replace
the pending request immediately, and admission failure discards the remote head.

- [ ] **Step 3: Generalize compatible ordinary-replica coalescing**

Replace `coalesceReplicaSnapshot` with a compatibility test that accepts pending
ordinary `RANGE_REQ` or `SNAP_REQ` plus a newer ordinary range/snapshot target
from the same sender, raid UID, and authority epoch. Handover and reentry remain
excluded.

```lua
local function coalesceReplicaRecovery(pending, recovery)
	if pending.handover or pending.reentry or recovery.handover or recovery.reentry then return false end
	if pending.sender ~= recovery.sender
		or pending.raidUid ~= recovery.raidUid
		or pending.authorityEpoch ~= recovery.authorityEpoch then return false end
	local latest = pending.followUp or pending
	if recovery.sequence > latest.sequence then pending.followUp = recovery end
	return true
end
```

The existing same-position/different-digest guard must continue checking both
the active recovery and `followUp` before coalescing.

- [ ] **Step 4: Continue once from the newest retained position**

In both range and snapshot success callbacks, capture `recovery.followUp` before
`finishRecovery`. After atomic installation, compare the new local head against
the retained target. If it is still newer, call the existing `compareHead`
exactly once so checkpoint/status policy selects range or snapshot correctly.

On range failure, snapshot fallback must target `recovery.followUp or remoteHead`.
When a direct event satisfies only the original recovery but not its follow-up,
finish the original work and continue toward the follow-up instead of clearing
all progress. When it reaches the follow-up sequence/digest, clear both.

- [ ] **Step 5: Retain and retry one failed live admission**

Add one runtime state:

```lua
module._admissionRetry = nil
```

Implement `clearAdmissionRetry(reason)` and
`scheduleAdmissionRetry(sender, remoteHead, reason, retryDelay)`. The state is
bounded to `{ sender, head, timer, retryUsed }`. A newer compatible head replaces
only `.head`; it never creates a second timer. Use returned rate delay for
`RATE_LIMIT`/`RATE_CAPACITY` and 0.25 seconds for `backpressure` or
`scheduler_unavailable`.

The timer clears its handle, marks `retryUsed = true`, and re-enters
`compareHead(sender, latestHead, true)`. A second admission failure clears the
state and sets the existing failed status. `TIMER_UNAVAILABLE` remains terminal.

Clear or cancel retained retry state when:

- authority changes;
- synchronization suspends on digest conflict;
- the local head already matches the target;
- a direct event reaches the target;
- a live request starts successfully.

Do not use this retry state for handover, reentry, or historical sharing.

- [ ] **Step 6: Run focused recovery tests and verify GREEN**

Run:

```powershell
py -3 -m unittest tests.test_sync_communications_behavior.SyncCommunicationsBehaviorTests.test_range_recovery_coalesces_newer_head_burst tests.test_sync_communications_behavior.SyncCommunicationsBehaviorTests.test_real_session_newer_conclusion_supersedes_pending_range tests.test_sync_communications_behavior.SyncCommunicationsBehaviorTests.test_rate_limited_live_recovery_retries_latest_head_once tests.test_sync_communications_behavior.SyncCommunicationsBehaviorTests.test_real_session_direct_event_cancels_obsolete_recovery tests.test_sync_communications_behavior.SyncCommunicationsBehaviorTests.test_real_store_pending_head_digest_conflict_cancels_recovery tests.test_sync_communications_behavior.SyncCommunicationsBehaviorTests.test_real_store_pending_event_digest_conflict_cancels_before_apply
```

Expected: PASS with one useful request plus one catch-up, no stale callback
status change, and no unbounded retry timer.

- [ ] **Step 7: Run the complete relevant suite**

Run:

```powershell
py -3 -m unittest tests.test_sync_communications_behavior tests.test_raid_replication_behavior tests.test_raid_recording_integrity_behavior
```

Expected: PASS.

- [ ] **Step 8: Commit**

```powershell
git add -- "Raid Management Addon/Database/DBSyncer.lua" "tests/lua/runtime_harness.lua" "tests/test_sync_communications_behavior.py"
git commit -m "fix(sync): make live recovery monotonic"
```

---

## Final Verification And Review Gate

After all four task reviews are clean, run from the worktree root:

```powershell
py -3 -m unittest discover -s tests -p 'test_*.py'
py -3 .agents/skills/wow-addon-dev-wotlk-v335a/scripts/validate_toc.py "Raid Management Addon/Raid Management Addon.toc"
py -3 .agents/skills/wow-addon-dev-wotlk-v335a/scripts/lint_lua51.py "Raid Management Addon"
py -3 .agents/skills/wow-addon-dev-wotlk-v335a/scripts/scan_xpcall.py "Raid Management Addon"
rg -n "<Scripts>|<On[A-Za-z]+>" "Raid Management Addon/UI" -g "*.xml"
luacheck "Raid Management Addon/Database/DBSyncProtocol.lua" "Raid Management Addon/Database/DBSyncSession.lua" "Raid Management Addon/Database/DBSyncer.lua"
stylua --check "Raid Management Addon/Database/DBSyncProtocol.lua" "Raid Management Addon/Database/DBSyncSession.lua" "Raid Management Addon/Database/DBSyncer.lua" "tests/lua/runtime_harness.lua"
git diff --check 868902da352bdff86be1204dcd1f33d1e2162f1b..HEAD
git status --short --branch
```

Generate one whole-branch review package from base `868902d` through `HEAD` and
dispatch a final reviewer. Critical and Important findings must be fixed and
re-reviewed. Record Minor findings in the SDD progress ledger for the final
review to triage.

Before calling the branch ready, report:

- changed TOC-referenced runtime files;
- untracked runtime files;
- deleted runtime references;
- registry and load-order risk;
- every validation command and result;
- the fact that two-client WotLK smoke remains required.

The in-game smoke must follow the approved design: four rapid awards, a final
award with no later trigger, one intentionally missed live message, a late third
client, `/reload`, and simultaneous historical sharing without live starvation.
