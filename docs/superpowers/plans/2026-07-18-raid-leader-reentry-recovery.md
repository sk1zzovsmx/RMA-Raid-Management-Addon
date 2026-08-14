# Raid Leader Re-entry Recovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a returning Raid Leader recover the newest valid active-raid replica before writing, then explicitly resume the same raid or conclude it and create one replacement.

**Architecture:** Extend protocol-v3 HEADs with optional modern instance context, add monotonic snapshot repair to the canonical store, and reuse `HEAD_REQ -> HEAD -> SNAP_REQ -> SNAP_DATA` for a bounded same-authority recovery. `DBSyncer` owns the write barrier and peer selection, `Services/Raid/State.lua` owns the resume/replace mutation, and a focused controller owns the confirmation popup through internal bus events.

**Tech Stack:** World of Warcraft WotLK 3.3.5a build 12340, Interface 30300, Lua 5.1, RMA event bus/timer/popup infrastructure, Python `unittest`, and the in-process multi-client Lua runtime harness.

## Global Constraints

- Target WotLK 3.3.5a with `## Interface: 30300` and Lua 5.1 syntax only.
- The current Raid Leader remains the sole active-raid writer in both Master Loot and Group Loot.
- Block raid creation and authoritative loot, roster, boss, and attendance writes until re-entry recovery and the resume decision finish.
- Admit only the same `raidUid + authorityEpoch` when the Leader knows its UID; without a local UID require all modern valid replies to agree on UID, epoch, zone, size, and difficulty.
- Select the highest sequence; equal sequence with different digest suspends recovery and never overwrites either copy.
- Reuse protocol version 3 and `HEAD_REQ`; receive legacy context-free HEADs for known-UID synchronization and send modern HEADs with bounded context.
- Use one immediate group request, one retry after exactly three seconds only when no valid replica replied, and close collection three seconds after the final request.
- Add no polling, unbounded `OnUpdate`, new SavedVariables schema, migration, new raid status, new dependency, or vendored-library edit.
- Completed history remains offer-and-consent only.
- Do not integrate, cherry-pick, rebase, or copy this branch into `codex/loot-bans-optimization` until the complete two-client live smoke is positive.
- Preserve the pre-existing user modification `.superpowers/sdd/task-4-report.md` and untracked `.planning/` files.

---

### Task 1: Modern HEAD Context and Monotonic Snapshot Repair

**Files:**
- Modify: `Raid Management Addon/Database/DBSyncProtocol.lua:35-75,165-190`
- Modify: `Raid Management Addon/Database/DBRaidStore.lua:1096-1148`
- Test: `tests/lua/runtime_harness.lua:3323-3355,3431-3648`
- Test: `tests/test_raid_replication_behavior.py:55-60,120-125`

**Interfaces:**
- Consumes: `Protocol.Encode/Decode`, the existing closed HEAD schema, `RaidStore:RepairActiveFromSnapshot(snapshot)`, and fully validated snapshot records.
- Produces: optional all-or-none HEAD fields `zone: string`, `size: 10|25`, and `difficulty: 1|2|3|4`; monotonic repair results `STALE_SNAPSHOT`, `AUTHORITY_EPOCH_MISMATCH`, and `DIGEST_CONFLICT`.

- [ ] **Step 1: Write failing protocol compatibility tests**

Extend `protocolBodies().HEAD` with the modern context and add a legacy copy that omits all three fields:

```lua
HEAD = {
	raidUid = "r:1721120000:1:12345678",
	authorityEpoch = 2,
	sequence = 7,
	checkpointSequence = 3,
	digest = "12345678:42",
	status = "active",
	zone = "Icecrown Citadel",
	size = 25,
	difficulty = 4,
},

local legacyHead = deepCopy(bodies.HEAD)
legacyHead.zone = nil
legacyHead.size = nil
legacyHead.difficulty = nil
local legacyWire = assert(protocol.Encode("HEAD", nil, nil, legacyHead))
assertTrue(deepEqual(legacyHead, assert(protocol.Decode(legacyWire)).body), "legacy HEAD did not round-trip")
```

Add closed-schema rejection cases:

```lua
candidate = deepCopy(bodies.HEAD)
candidate.size = nil
reject("partial HEAD context", "HEAD", nil, nil, candidate)

candidate = deepCopy(bodies.HEAD)
candidate.size = 40
reject("HEAD raid size", "HEAD", nil, nil, candidate)

candidate = deepCopy(bodies.HEAD)
candidate.difficulty = 5
reject("HEAD difficulty", "HEAD", nil, nil, candidate)

candidate = deepCopy(bodies.HEAD)
candidate.zone = string.rep("x", 81)
reject("HEAD zone bound", "HEAD", nil, nil, candidate)
```

- [ ] **Step 2: Write failing monotonic-repair tests**

Extend `raid_replication_live_snapshot_repair` by building two valid sequence-2 branches from the same captured sequence-1 archive:

```lua
local sequenceOne = store:CaptureRaidHistoryState()
local function snapshotFromArchive(captured, uid)
	local record = assert(captured.raids[uid], "captured record missing")
	local snapshot = deepCopy(record)
	snapshot.raidUid = uid
	snapshot.checkpointSequence = snapshot.sequence
	snapshot.events = {}
	return snapshot
end
assert(store:CommitAuthoritativeEvent(raidUid, "RAID_METADATA_UPDATED", {
	metadata = { zone = "Ulduar" },
}))
local branchA = assert(store:BuildSnapshot(raidUid))

assert(store:RestoreRaidHistoryState(sequenceOne))
assert(store:CommitAuthoritativeEvent(raidUid, "RAID_METADATA_UPDATED", {
	metadata = { zone = "Naxxramas" },
}))
local branchB = assert(store:BuildSnapshot(raidUid))
assertEqual(branchA.sequence, branchB.sequence)
assertTrue(branchA.digest ~= branchB.digest, "fixture branches did not diverge")

assert(store:RestoreRaidHistoryState(sequenceOne))
assert(store:RepairActiveFromSnapshot(branchA))
local beforeRejectedRepair = store:CaptureRaidHistoryState()
local staleSnapshot = snapshotFromArchive(sequenceOne, raidUid)
local repaired, repairReason = store:RepairActiveFromSnapshot(staleSnapshot)
assertEqual(nil, repaired)
assertEqual("STALE_SNAPSHOT", repairReason)
assertEqual("DIGEST_CONFLICT", select(2, store:RepairActiveFromSnapshot(branchB)))
assertTrue(deepEqual(beforeRejectedRepair, store:CaptureRaidHistoryState()), "rejected repair mutated archive")

local wrongEpoch = deepCopy(branchA)
wrongEpoch.authorityEpoch = wrongEpoch.authorityEpoch + 1
assertEqual("AUTHORITY_EPOCH_MISMATCH", select(2, store:RepairActiveFromSnapshot(wrongEpoch)))
```

- [ ] **Step 3: Run focused tests and verify RED**

Run:

```powershell
py -3 -m unittest tests.test_raid_replication_behavior.RaidReplicationBehaviorTests.test_authenticated_live_snapshot_repairs_only_current_active_record tests.test_raid_replication_behavior.RaidReplicationBehaviorTests.test_version_3_protocol_round_trips_every_closed_message_kind tests.test_raid_replication_behavior.RaidReplicationBehaviorTests.test_version_3_protocol_rejects_invalid_envelopes_and_bodies -v
```

Expected: FAIL because HEAD context keys are rejected and `RepairActiveFromSnapshot` currently replaces lower or tied-divergent positions.

- [ ] **Step 4: Implement the optional modern HEAD context**

Change the HEAD schema and validator without changing `Protocol.VERSION`:

```lua
HEAD = {
	raidUid = true,
	authorityEpoch = true,
	sequence = true,
	checkpointSequence = true,
	digest = true,
	status = true,
	zone = false,
	size = false,
	difficulty = false,
},
```

At the start of the HEAD validator, validate context as all-or-none:

```lua
local hasZone = body.zone ~= nil
local hasSize = body.size ~= nil
local hasDifficulty = body.difficulty ~= nil
local hasContext = hasZone or hasSize or hasDifficulty
if hasContext then
	if not (hasZone and hasSize and hasDifficulty) then
		return nil
	end
	local size = exactInteger(body.size, 10, 25)
	if not displayAscii(body.zone, 1, 80)
		or (size ~= 10 and size ~= 25)
		or not exactInteger(body.difficulty, 1, 4)
	then
		return nil
	end
end
```

Keep context-free version-3 HEADs valid. Do not add a new message kind or bump the protocol version.

- [ ] **Step 5: Add the monotonic repair gate before archive replacement**

In `RepairActiveFromSnapshot`, after loading `current` and before assigning `archive.raids[raidUid]`, add:

```lua
if candidate.authorityEpoch ~= current.authorityEpoch then
	return nil, "AUTHORITY_EPOCH_MISMATCH"
end
if candidate.sequence < current.sequence then
	return nil, "STALE_SNAPSHOT"
end
if candidate.sequence == current.sequence then
	if candidate.digest ~= current.digest or candidate.status ~= current.status then
		return nil, "DIGEST_CONFLICT"
	end
	return current.state
end
```

Leave greater-sequence active or completed repair unchanged after complete record validation. Do not compare timestamps, roster counts, or array indexes.

- [ ] **Step 6: Run focused tests and verify GREEN**

Run the Step 3 command again.

Expected: all three tests PASS; modern and legacy HEADs decode, and rejected repairs leave the archive byte-for-byte unchanged.

- [ ] **Step 7: Commit the protocol and store safety boundary**

```powershell
git add -- 'Raid Management Addon/Database/DBSyncProtocol.lua' 'Raid Management Addon/Database/DBRaidStore.lua' 'tests/lua/runtime_harness.lua'
git commit -m "fix(sync-03): prevent active snapshot downgrade"
```

---

### Task 2: Bounded Same-authority Recovery Before Any Write

**Files:**
- Modify: `Raid Management Addon/Init.lua:70-80,775-795`
- Modify: `Raid Management Addon/Modules/Events.lua:20-55`
- Modify: `Raid Management Addon/Services/Raid/Session.lua:20-125`
- Modify: `Raid Management Addon/Database/DBSyncer.lua:10-90,250-370,390-610,713-868,1050-1085,1330-1448`
- Modify: `Raid Management Addon/Localization/localization.en.lua:41-50`
- Modify: `Raid Management Addon/Localization/DiagnoseLog.en.lua:33-50`
- Test: `tests/lua/runtime_harness.lua:13351-13823,14280-14698`
- Test: `tests/test_raid_replication_behavior.py:60-90`
- Test: `tests/test_sync_communications_behavior.py:60-82`

**Interfaces:**
- Consumes: Task 1 modern HEAD context and monotonic repair, `RaidInstanceRecognized(instanceName, instanceKey, instanceDiff)`, and the existing snapshot session.
- Produces: `Raid:ResolveRaidInstanceContext(instanceName, instanceDiff)`; `Events.Internal.RaidReentryRecoveryReady`; runtime `_reentry` phases `collecting`, `snapshot`, `decision`, `transition`; `DBSyncer:IsAuthorityRecovering(raidUid?)`; authenticated replica HEAD whispers; one WARN on terminal suspension.

- [ ] **Step 1: Extend the multi-client fixture without changing production behavior**

Add `zone`, `size`, and `difficulty` to `makeLiveRecord`:

```lua
state = {
	value = sequence,
	zone = "Naxxramas",
	size = 10,
	difficulty = 1,
},
```

Make the fixture bus dispatch registered callbacks synchronously after recording lifecycle evidence:

```lua
function addon.Bus.TriggerEvent(eventName, ...)
	local args = { ... }
	if eventName == addon.Events.Internal.RaidAuthorityRecoveryFinished then
		client.recoveryFinished[#client.recoveryFinished + 1] = {
			raidUid = args[1],
			succeeded = args[2],
			reason = args[3],
			recovering = client.syncer and client.syncer:IsAuthorityRecovering(args[1]) or false,
		}
	end
	local listeners = client.callbacks[eventName] or {}
	for i = 1, #listeners do
		listeners[i](eventName, unpack(args))
	end
end
```

Add `RaidReentryRecoveryReady` to the fixture event table and capture its summary in `client.reentryReady`.

Add this method to the fixture's `addon.Services.Raid` table:

```lua
ResolveRaidInstanceContext = function(_, instanceName, instanceDiff)
	local difficulty = tonumber(instanceDiff)
	if difficulty ~= 1 and difficulty ~= 2 and difficulty ~= 3 and difficulty ~= 4 then
		return nil, "INVALID_RAID_CONTEXT"
	end
	local size = (difficulty == 1 or difficulty == 3) and 10 or 25
	return { zone = instanceName, size = size, difficulty = difficulty }
end,
```

- [ ] **Step 2: Write failing recovery selection and conflict tests**

Add these cases and Python mappings:

```lua
function cases.raid_leader_reentry_recovers_highest_replica_before_write()
	local network = newLiveReplicationNetwork()
	local leader = installLiveReplicationClient(network, "Leader", makeLiveRecord(2))
	local replicaB = installLiveReplicationClient(network, "ReplicaB", makeLiveRecord(5))
	local replicaC = installLiveReplicationClient(network, "ReplicaC", makeLiveRecord(4))
	local recognized = assert(leader.callbacks.RaidInstanceRecognized)
	recognized[1](nil, "Naxxramas", "naxxramas", 1)
	assertEqual(nil, leader.store:Commit(makeLiveEvent(3)), "Leader wrote during recovery")
	assertEqual("AUTHORITY_RECOVERING", select(2, leader.store:CommitAuthoritativeEvent("raid-live", "TEST", {})))
	assert(leader:FireHandoverTimer())
	assertEqual(5, leader.store.record.sequence, "Leader did not recover the highest sequence")
	assertEqual(replicaB.store.record.digest, leader.store.record.digest, "Leader recovered the wrong digest")
	assertEqual(1, #leader.reentryReady, "recovery did not publish one ready decision")
	assertTrue(leader.syncer:IsAuthorityRecovering("raid-live"), "write barrier opened before decision")
	print("PASS raid_leader_reentry_recovers_highest_replica_before_write")
end

function cases.raid_leader_reentry_suspends_on_tied_digest_conflict()
	local network = newLiveReplicationNetwork()
	local leader = installLiveReplicationClient(network, "Leader", makeLiveRecord(2))
	installLiveReplicationClient(network, "ReplicaB", makeLiveRecord(5, "aaaaaaaa:1"))
	installLiveReplicationClient(network, "ReplicaC", makeLiveRecord(5, "bbbbbbbb:1"))
	assert(leader.callbacks.RaidInstanceRecognized[1](nil, "Naxxramas", "naxxramas", 1) == nil)
	assert(leader:FireHandoverTimer())
	local status, reason = leader.syncer:GetStatus()
	assertEqual("suspended", status)
	assertEqual("DIGEST_CONFLICT", reason)
	assertEqual(2, leader.store.record.sequence, "conflict overwrote local state")
	assertEqual(1, #leader.warnings, "conflict WARN count differs")
	assertEqual(0, #leader.reentryReady, "conflict opened the decision flow")
	print("PASS raid_leader_reentry_suspends_on_tied_digest_conflict")
end
```

The fixture's store authority guard must return the real reason from the guard instead of collapsing every rejection to `NOT_RAID_LEADER`.

- [ ] **Step 3: Write failing unknown-UID consensus and retry-bound tests**

Add two sub-scenarios:

```lua
function cases.raid_leader_reentry_unknown_uid_requires_consensus()
	local unanimousNetwork = newLiveReplicationNetwork()
	local leader = installLiveReplicationClient(unanimousNetwork, "Leader", nil)
	installLiveReplicationClient(unanimousNetwork, "ReplicaB", makeLiveRecord(3))
	installLiveReplicationClient(unanimousNetwork, "ReplicaC", makeLiveRecord(5))
	leader.callbacks.RaidInstanceRecognized[1](nil, "Naxxramas", "naxxramas", 1)
	assert(leader:FireHandoverTimer())
	assertEqual("raid-live", leader.store.record.raidUid, "unanimous UID was not recovered")
	assertEqual(5, leader.store.record.sequence, "unanimous recovery did not select the highest sequence")

	local splitNetwork = newLiveReplicationNetwork()
	local splitLeader = installLiveReplicationClient(splitNetwork, "Leader", nil)
	local left = makeLiveRecord(3)
	local right = makeLiveRecord(4)
	right.raidUid = "raid-other"
	installLiveReplicationClient(splitNetwork, "ReplicaB", left)
	installLiveReplicationClient(splitNetwork, "ReplicaC", right)
	splitLeader.callbacks.RaidInstanceRecognized[1](nil, "Naxxramas", "naxxramas", 1)
	assert(splitLeader:FireHandoverTimer())
	assertEqual("suspended", splitLeader.syncer:GetStatus())
	assertEqual(nil, splitLeader.store.record, "discordant replicas selected an arbitrary UID")
	print("PASS raid_leader_reentry_unknown_uid_requires_consensus")
end

function cases.raid_leader_reentry_retry_is_bounded()
	local network = newLiveReplicationNetwork()
	local leader = installLiveReplicationClient(network, "Leader", nil)
	local recognized = assert(leader.callbacks.RaidInstanceRecognized)
	recognized[1](nil, "Naxxramas", "naxxramas", 1)
	recognized[1](nil, "Naxxramas", "naxxramas", 1)
	assertEqual(1, countKind(leader.requests, "HEAD_REQ"), "duplicate recognition sent twice")
	assert(leader:FireHandoverTimer())
	assertEqual(2, countKind(leader.requests, "HEAD_REQ"), "missing reply did not use exactly one retry")
	assert(leader:FireHandoverTimer())
	assertEqual(2, countKind(leader.requests, "HEAD_REQ"), "recovery exceeded its request bound")
	assertEqual(1, #leader.reentryReady, "empty recovery did not reach one terminal decision")
	assertEqual(nil, leader.store.record, "syncer created a raid instead of delegating the decision")
	print("PASS raid_leader_reentry_retry_is_bounded")
end
```

- [ ] **Step 4: Run the new cases and verify RED**

Run:

```powershell
lua tests/lua/runtime_harness.lua raid_leader_reentry_recovers_highest_replica_before_write
lua tests/lua/runtime_harness.lua raid_leader_reentry_suspends_on_tied_digest_conflict
lua tests/lua/runtime_harness.lua raid_leader_reentry_unknown_uid_requires_consensus
lua tests/lua/runtime_harness.lua raid_leader_reentry_retry_is_bounded
```

Expected: each case FAILs because a local Raid Leader currently skips discovery and accepts writes immediately.

- [ ] **Step 5: Publish and resolve one canonical recognized-instance context**

In `Init.lua`, preserve the current event arguments and append `instanceDiff`:

```lua
Bus.TriggerEvent(InternalEvents.RaidInstanceRecognized, instanceName, instanceKey, instanceDiff)
```

In `Modules/Events.lua` add:

```lua
Internal.RaidReentryRecoveryReady = "RaidReentryRecoveryReady"
```

In `Services/Raid/Session.lua`, add the shared resolver used by `DBSyncer` and,
in Task 3, by `Raid:Check`:

```lua
function module:ResolveRaidInstanceContext(instanceName, instanceDiff)
	local difficulty = module._ResolveRaidDifficultyInternal(instanceDiff)
	local size = module._GetRaidSizeFromDifficultyInternal(difficulty)
	if type(instanceName) ~= "string" or instanceName == "" or not size then
		return nil, "INVALID_RAID_CONTEXT"
	end
	return { zone = instanceName, size = size, difficulty = difficulty }
end
```

No SavedVariables field is added.

- [ ] **Step 6: Add context to sent HEADs and role-aware HEAD_REQ responses**

Extend `headFromRecord`:

```lua
local state = record.state
local head = {
	raidUid = raidUid,
	authorityEpoch = record.authorityEpoch,
	sequence = record.sequence,
	checkpointSequence = record.checkpointSequence,
	digest = record.digest,
	status = record.status,
}
if type(state) == "table" and type(state.zone) == "string"
	and (tonumber(state.size) == 10 or tonumber(state.size) == 25)
	and tonumber(state.difficulty)
then
	head.zone = state.zone
	head.size = tonumber(state.size)
	head.difficulty = tonumber(state.difficulty)
end
return head
```

Change `handleHeadRequest` so a non-Leader replica answers a request from the authenticated current Raid Leader with one direct HEAD whisper; retain the existing Leader response for participant bootstrap:

```lua
if sender == leader and leader ~= localPlayer and Raid:IsGroupMember(sender) then
	local record, raidUid = currentRecordAndUid()
	local head = headFromRecord(record, raidUid)
	return head and sendDirectFireAndForget("HEAD", sender, head) or false
end
if Raid:IsRaidLeader() and leader == localPlayer and Raid:IsGroupMember(sender) then
	return module:AdvertiseHead()
end
return false
```

- [ ] **Step 7: Implement the bounded `_reentry` state and candidate selection**

Add `Database = addon.Database`, `_reentry = nil`, and helpers with these exact contracts:

```lua
local function suspendReentry(reentry, reason)
	-- Cancel both timers and any correlated snapshot request, retain the write
	-- barrier as phase="suspended", set STATUS_SUSPENDED, warn once, and return false, reason.
end

local function recordReentryHead(sender, head)
	-- Admit active current-group HEADs only. Known local UID requires exact UID
	-- and epoch. Unknown UID requires complete modern context matching the
	-- recognized instance. Store one copied HEAD per normalized sender.
end

local function selectReentryBase(reentry)
	-- Validate every admitted position, reject UID/epoch disagreement when the
	-- local UID is unknown, reject tied digest divergence, and return
	-- selectedSender, selectedHead for the greatest sequence. Include the local
	-- HEAD as a candidate when present.
end

local function publishReentryReady(reentry, raidUid)
	reentry.phase = "decision"
	local record = RaidStore:GetActiveRecord()
	TriggerEvent(RaidReentryRecoveryReadyEvent, {
		raidUid = raidUid,
		context = copyScalarTable(reentry.context),
		raid = record and record.state or nil,
	})
end
```

Use one timer at three seconds. If no remote HEAD was admitted, send exactly one retry and replace it with one final three-second timer. Otherwise close on the first timer. At close, use the local copy when it is already the selected position, request one snapshot from the selected replica when missing or behind, or publish `{ raidUid = nil, raid = nil }` when no copy exists.

Pass the owning attempt into snapshot recovery so normal replica and handover
completion remain unchanged:

```lua
local recovery = {
	sender = remoteSender,
	kind = "SNAP_REQ",
	raidUid = remoteHead.raidUid,
	authorityEpoch = remoteHead.authorityEpoch,
	sequence = remoteHead.sequence,
	digest = remoteHead.digest,
	handover = handover,
	reentry = reentry,
}

-- In finishRecovery, immediately after releaseRecovery:
if recovery.reentry then
	if not succeeded then
		return suspendReentry(recovery.reentry, reason or "SNAPSHOT_FAILED")
	end
	return publishReentryReady(recovery.reentry, recovery.raidUid)
end
```

Route HEADs from non-Leader senders to `recordReentryHead` only while the local player is the current Raid Leader and `_reentry.phase == "collecting"`; keep the existing sender authentication for every normal HEAD.

- [ ] **Step 8: Close the write and publication barriers**

Update the authority guard and publication gates:

```lua
if module._reentry and module._reentry.phase ~= "transition" then
	return false, "AUTHORITY_RECOVERING"
end
if Raid:IsRaidLeader() and RaidStore:GetActiveRecord()
	and Database.GetCurrentRaid() == nil and module._reentry == nil
then
	return false, "AUTHORITY_RECOVERY_REQUIRED"
end
```

Make `IsAuthorityRecovering` return true for `_handover`, every `_reentry` phase, and the pre-recognition `active record + nil currentRaid` condition. Block `AdvertiseHead`, `broadcastCommittedEvent`, and `advertiseIfAuthoritative` while `_reentry` exists or the pre-recognition condition holds.

When `RaidInstanceRecognized` fires for a local Raid Leader with no runtime current raid, start/coalesce re-entry instead of returning. Preserve the existing non-Leader discovery path exactly.

- [ ] **Step 9: Add one essential WARN and debug-only trace reasons**

Add:

```lua
L.WarnRaidReentryRecoverySuspended =
	"Raid database recovery was suspended (%s). Recording remains paused and no raid copy was overwritten."
```

Use `addon:warn` once per re-entry attempt on digest conflict, UID/epoch disagreement, unexpected epoch, or snapshot failure. Add debug trace templates to `DiagnoseLog.en.lua`; do not emit peer digests during normal logging.

- [ ] **Step 10: Run focused suites and verify GREEN**

Run:

```powershell
py -3 -m unittest tests.test_raid_replication_behavior tests.test_sync_communications_behavior -v
```

Expected: all replication and communication tests PASS, including the four new cases and the existing late-join, reload-noop, handover, and history-consent regressions.

- [ ] **Step 11: Commit same-authority recovery**

```powershell
git add -- 'Raid Management Addon/Init.lua' 'Raid Management Addon/Modules/Events.lua' 'Raid Management Addon/Services/Raid/Session.lua' 'Raid Management Addon/Database/DBSyncer.lua' 'Raid Management Addon/Localization/localization.en.lua' 'Raid Management Addon/Localization/DiagnoseLog.en.lua' 'tests/lua/runtime_harness.lua' 'tests/test_raid_replication_behavior.py' 'tests/test_sync_communications_behavior.py'
git commit -m "fix(sync-03): recover leader state before writes"
```

---

### Task 3: Resume Popup, Controlled Transition, and Final Runtime Gate

**Files:**
- Create: `Raid Management Addon/Controllers/RaidRecovery.lua`
- Modify: `Raid Management Addon/Raid Management Addon.toc:55-105`
- Modify: `Raid Management Addon/Modules/Events.lua:30-60`
- Modify: `Raid Management Addon/Database/DBSyncer.lua:55-90,1360-1455`
- Modify: `Raid Management Addon/Services/Raid/State.lua:20-35,114-135,1555-1760,2100-2120`
- Modify: `Raid Management Addon/Services/Raid/Session.lua:20-125`
- Modify: `Raid Management Addon/Services/Raid/Capabilities.lua:100-120,230-245`
- Modify: `Raid Management Addon/Localization/localization.en.lua:41-55`
- Modify: `tests/lua/runtime_harness.lua:3655-3805,13351-14698`
- Modify: `tests/test_raid_replication_behavior.py:55-100,105-130`
- Modify: `docs/superpowers/smoke/2026-07-16-raid-data-replication.md`

**Interfaces:**
- Consumes: Task 2 `RaidReentryRecoveryReady`, `_reentry.phase == "decision"`, and the existing `UI.Popups` API.
- Produces: `RaidReentryDecisionRequired(summary)`, `RaidReentryDecisionResolved(raidUid, decision, context)`, `Raid:ResolveRaidInstanceContext(instanceName, instanceDiff)`, and `Raid:ApplyReentryDecision(raidUid, decision, context)`.

- [ ] **Step 1: Write failing resume/replace service tests**

Using `installRaidCreationFixture`, add a case that gives its store `GetRecord`, `GetIndexByUid`, and the active UID. Assert both branches:

```lua
function cases.raid_reentry_state_applies_resume_and_replace(addon)
	local fixture, raid = installRaidCreationFixture(addon, nil)
	fixture.store.GetRecord = function(_, raidUid)
		return raidUid == "active-fixture" and { status = "active", state = fixture.raids[1] } or nil
	end
	fixture.store.GetIndexByUid = function(_, raidUid)
		return raidUid == "active-fixture" and 1 or nil
	end
	fixture.store.GetRaidUid = function(_, state)
		return state == fixture.raids[1] and "active-fixture" or nil
	end

	addon.Database.SetCurrentRaid(nil)
	local before = deepCopy(fixture.raids[1])
	local resumed, resumedUid = raid:ApplyReentryDecision("active-fixture", "resume", {
		zone = fixture.raids[1].zone,
		size = fixture.raids[1].size,
		difficulty = fixture.raids[1].difficulty,
	})
	assertEqual(true, resumed)
	assertEqual("active-fixture", resumedUid)
	assertEqual(1, addon.Database.GetCurrentRaid())
	assertTrue(deepEqual(before, fixture.raids[1]), "resume mutated the persisted raid")

	addon.Database.SetCurrentRaid(nil)
	assertEqual(true, select(1, raid:ApplyReentryDecision("active-fixture", "replace", {
		zone = "Ulduar", size = 25, difficulty = 2,
	})))
	assertEqual(3, addon.Database.GetCurrentRaid(), "replacement did not become current")
	assertEqual(1, fixture.historyCaptures, "replacement was not one atomic Create transaction")
	print("PASS raid_reentry_state_applies_resume_and_replace")
end
```

Add a mismatch assertion proving that `resume` returns `false, "RAID_CONTEXT_MISMATCH"` without setting `currentRaid`.

- [ ] **Step 2: Write failing popup routing and dismissal tests**

Add `RaidReentryDecisionRequired` and `RaidReentryDecisionResolved` to the
multi-client fixture's `addon.Events.Internal` table so the same names are used
by the isolated controller fixture and the end-to-end cases.

Create a focused controller fixture with stubbed `UI.Popups.Define`, `IsDefined`, and `Show`. Dispatch `RaidReentryDecisionRequired` and assert:

```lua
assertEqual("RMA_RAID_REENTRY_CONFIRM", shown.key)
assertTrue(string.find(shown.text, "Naxxramas", 1, true) ~= nil)
assertTrue(string.find(shown.text, "10", 1, true) ~= nil)
assertTrue(string.find(shown.text, "10N", 1, true) ~= nil)

dialog.OnAccept(nil, shown.data)
assertEqual("resume", resolved[1].decision)
dialog.OnCancel(nil, shown.data, "clicked")
assertEqual("replace", resolved[2].decision)
assertEqual(0, dialog.hideOnEscape, "Escape could silently choose No")
assertEqual(nil, dialog.OnHide, "popup hide mutated recovery")
```

Expose `raid_reentry_state_applies_resume_and_replace` and `raid_reentry_popup_routes_explicit_decisions` through `tests/test_raid_replication_behavior.py`.

- [ ] **Step 3: Run the focused cases and verify RED**

Run:

```powershell
lua tests/lua/runtime_harness.lua raid_reentry_state_applies_resume_and_replace
lua tests/lua/runtime_harness.lua raid_reentry_popup_routes_explicit_decisions
```

Expected: FAIL because the Raid service methods, events, and controller do not exist.

- [ ] **Step 4: Add the controlled transition method to Raid**

At the start of `module:Check`, return `false, "AUTHORITY_RECOVERING"` when `Database.GetSyncer():IsAuthorityRecovering()` is true. Then resolve context through Task 2's `ResolveRaidInstanceContext` method so `Check` and re-entry use one size/difficulty policy.

In `State.lua`, implement:

```lua
function module:ApplyReentryDecision(raidUid, decision, context)
	if type(context) ~= "table" then
		return false, "INVALID_RAID_CONTEXT"
	end
	local raidStore = Database.GetRaidStore()
	if decision == "new" and raidUid == nil then
		Database.SetCurrentRaid(nil)
		local created, reason = module:Create(context.zone, context.size, context.difficulty)
		local active = raidStore:GetActiveRecord()
		return created == true, created and active and raidStore:GetRaidUid(active.state) or reason
	end
	local record = raidStore:GetRecord(raidUid)
	local index = raidStore:GetIndexByUid(raidUid)
	if not record or record.status ~= "active" or not index then
		return false, "RAID_NOT_ACTIVE"
	end
	if decision == "resume" then
		if record.state.zone ~= context.zone
			or tonumber(record.state.size) ~= tonumber(context.size)
			or tonumber(record.state.difficulty) ~= tonumber(context.difficulty)
		then
			return false, "RAID_CONTEXT_MISMATCH"
		end
		Database.SetCurrentRaid(index)
		scheduleRosterRefresh()
		return true, raidUid
	end
	if decision == "replace" then
		Database.SetCurrentRaid(index)
		local created, reason = module:Create(context.zone, context.size, context.difficulty)
		local active = raidStore:GetActiveRecord()
		return created == true, created and active and raidStore:GetRaidUid(active.state) or reason
	end
	return false, "INVALID_REENTRY_DECISION"
end
```

The existing transactional `Create` remains the only conclusion-plus-create implementation; do not duplicate its rollback logic.

- [ ] **Step 5: Add decision events and the focused popup controller**

Seed:

```lua
Internal.RaidReentryDecisionRequired = "RaidReentryDecisionRequired"
Internal.RaidReentryDecisionResolved = "RaidReentryDecisionResolved"
```

Create `Controllers/RaidRecovery.lua` with no frame or XML:

```lua
local addon = select(2, ...)
local Events = addon.Events
local Bus = addon.Bus
local L = addon.L
local Popups = assert(addon.UI.Popups, "Raid recovery popup namespace is not initialized")
local Projections = assert(addon.Services.Raid.Projections, "Raid projections are not initialized")
local Required = assert(Events.Internal.RaidReentryDecisionRequired)
local Resolved = assert(Events.Internal.RaidReentryDecisionResolved)
local KEY = "RMA_RAID_REENTRY_CONFIRM"

if not Popups.IsDefined(KEY) then
	Popups.Define(KEY, {
		text = "%s",
		button1 = _G.YES or _G.OKAY,
		button2 = _G.NO or _G.CANCEL,
		timeout = 0,
		whileDead = 1,
		hideOnEscape = 0,
		OnAccept = function(_, data)
			Bus.TriggerEvent(Resolved, data.raidUid, "resume", data.context)
		end,
		OnCancel = function(_, data)
			Bus.TriggerEvent(Resolved, data.raidUid, "replace", data.context)
		end,
	})
end

Bus.RegisterCallback(Required, function(_, summary)
	if type(summary) ~= "table" or type(summary.raid) ~= "table" then return end
	local text = L.PopupRaidReentryConfirm:format(
		tostring(summary.raid.zone),
		tonumber(summary.raid.size) or 0,
		Projections.GetDifficultyLabel(summary.raid)
	)
	Popups.Show(KEY, text, nil, summary)
end)
```

Add to localization:

```lua
L.PopupRaidReentryConfirm =
	"Resume the previous raid?\nZone: %s\nSize: %d\nDifficulty: %s"
```

Load the controller in the TOC after `Services/Raid/Projections.lua`. Do not add XML or a ModuleRegistry wrapper.

- [ ] **Step 6: Route recovery-ready summaries and execute one synchronous decision**

Register a Raid-side callback for `RaidReentryRecoveryReady`:

```lua
RegisterCallback(RaidReentryRecoveryReadyEvent, function(_, summary)
	local raid = type(summary) == "table" and summary.raid or nil
	local context = type(summary) == "table" and summary.context or nil
	if raid and raid.zone == context.zone
		and tonumber(raid.size) == tonumber(context.size)
		and tonumber(raid.difficulty) == tonumber(context.difficulty)
	then
		TriggerEvent(RaidReentryDecisionRequiredEvent, summary)
	else
		TriggerEvent(RaidReentryDecisionResolvedEvent, summary and summary.raidUid or nil,
			raid and "replace" or "new", context)
	end
end)
```

In `DBSyncer`, register `RaidReentryDecisionResolved`. Accept it only when `_reentry.phase == "decision"`, the UID matches the selected candidate, and the decision is `resume`, `replace`, or `new` as appropriate. Set `phase = "transition"`, synchronously call `Raid:ApplyReentryDecision`, and then:

```lua
if not succeeded then
	return suspendReentry(reentry, resultOrReason or "REENTRY_TRANSITION_FAILED")
end
module._reentry = nil
setStatus(STATUS_SYNCHRONIZED, "UP_TO_DATE")
return module:AdvertiseHead()
```

Because WoW Lua dispatch is single-threaded, the store authority guard permits writes only while this exact `_reentry` object is in `transition`; `broadcastCommittedEvent` remains blocked until the transition returns. This allows the existing atomic `Create` to conclude and replace without opening an interleaving window.

- [ ] **Step 7: Gate capability checks and prove normal writers remain closed**

At the start of `CanCommitRaidHistory`:

```lua
local syncer = addon.DB and addon.DB.Syncer
if syncer and type(syncer.IsAuthorityRecovering) == "function" and syncer:IsAuthorityRecovering() then
	return false
end
```

Extend the Task 2 highest-replica case so `CanCommitRaidHistory`, `Raid:Check`, loot, roster, boss, and attendance fixture writers produce no canonical event before the decision. Reuse existing handover recovery-gate fixtures; do not create a second mock family.

- [ ] **Step 8: Add end-to-end decision regressions**

Add a decision bridge to the multi-client fixture. It models only the synchronous
event wiring; the real mutation semantics remain covered by
`raid_reentry_state_applies_resume_and_replace`:

```lua
local function installReentryDecisionBridge(client)
	client.currentRaidUid = nil
	client.createdRaids = 0
	client.concludedRaids = 0
	client.decisionRequests = {}
	client.addon.Services.Raid.ApplyReentryDecision = function(_, raidUid, decision, context)
		if decision == "resume" then
			client.currentRaidUid = raidUid
			return true, raidUid
		end
		if decision == "replace" then
			client.concludedRaids = client.concludedRaids + 1
			client.createdRaids = client.createdRaids + 1
			client.store.record = makeLiveRecord(1)
			client.store.record.raidUid = "raid-replacement-" .. tostring(client.createdRaids)
			client.currentRaidUid = client.store.record.raidUid
			return true, client.currentRaidUid
		end
		if decision == "new" and raidUid == nil then
			client.createdRaids = client.createdRaids + 1
			client.store.record = makeLiveRecord(1)
			client.store.record.raidUid = "raid-new-" .. tostring(client.createdRaids)
			client.currentRaidUid = client.store.record.raidUid
			return true, client.currentRaidUid
		end
		return false, "INVALID_REENTRY_DECISION"
	end
	client.addon.Bus.RegisterCallback(client.addon.Events.Internal.RaidReentryRecoveryReady, function(_, summary)
		local raid, context = summary.raid, summary.context
		if raid and raid.zone == context.zone and tonumber(raid.size) == tonumber(context.size)
			and tonumber(raid.difficulty) == tonumber(context.difficulty)
		then
			client.decisionRequests[#client.decisionRequests + 1] = deepCopy(summary)
			client.addon.Bus.TriggerEvent(client.addon.Events.Internal.RaidReentryDecisionRequired, summary)
		else
			client.addon.Bus.TriggerEvent(client.addon.Events.Internal.RaidReentryDecisionResolved,
				summary.raidUid, raid and "replace" or "new", context)
		end
	end)
end

local function resolveReentry(client, decision)
	local summary = assert(client.decisionRequests[#client.decisionRequests], "re-entry decision missing")
	client.addon.Bus.TriggerEvent(client.addon.Events.Internal.RaidReentryDecisionResolved,
		summary.raidUid, decision, summary.context)
end
```

Then add the exact cases:

```lua
function cases.raid_leader_reentry_resume_keeps_identity()
	local network = newLiveReplicationNetwork()
	local leader = installLiveReplicationClient(network, "Leader", makeLiveRecord(2))
	installReentryDecisionBridge(leader)
	installLiveReplicationClient(network, "ReplicaB", makeLiveRecord(5))
	leader.callbacks.RaidInstanceRecognized[1](nil, "Naxxramas", "naxxramas", 1)
	assert(leader:FireHandoverTimer())
	local sequence, digest = leader.store.record.sequence, leader.store.record.digest
	resolveReentry(leader, "resume")
	assertEqual("raid-live", leader.currentRaidUid)
	assertEqual(sequence, leader.store.record.sequence, "resume created a revision")
	assertEqual(digest, leader.store.record.digest, "resume changed the digest")
	assertEqual(0, leader.createdRaids)
	print("PASS raid_leader_reentry_resume_keeps_identity")
end

function cases.raid_leader_reentry_replace_uses_recovered_base()
	local network = newLiveReplicationNetwork()
	local leader = installLiveReplicationClient(network, "Leader", makeLiveRecord(2))
	installReentryDecisionBridge(leader)
	installLiveReplicationClient(network, "ReplicaB", makeLiveRecord(5))
	leader.callbacks.RaidInstanceRecognized[1](nil, "Naxxramas", "naxxramas", 1)
	assert(leader:FireHandoverTimer())
	assertEqual(5, leader.store.record.sequence, "replacement did not first recover the best base")
	resolveReentry(leader, "replace")
	assertEqual(1, leader.concludedRaids)
	assertEqual(1, leader.createdRaids)
	assertEqual("raid-replacement-1", leader.currentRaidUid)
	print("PASS raid_leader_reentry_replace_uses_recovered_base")
end

function cases.raid_leader_reentry_context_mismatch_skips_popup()
	local network = newLiveReplicationNetwork()
	local previous = makeLiveRecord(2)
	previous.state.zone = "Ulduar"
	local leader = installLiveReplicationClient(network, "Leader", previous)
	installReentryDecisionBridge(leader)
	leader.callbacks.RaidInstanceRecognized[1](nil, "Naxxramas", "naxxramas", 1)
	assert(leader:FireHandoverTimer())
	assertEqual(0, #leader.decisionRequests, "mismatched context opened the popup")
	assertEqual(1, leader.concludedRaids)
	assertEqual(1, leader.createdRaids)
	print("PASS raid_leader_reentry_context_mismatch_skips_popup")
end

function cases.raid_leader_reentry_dismissal_stays_suspended()
	local network = newLiveReplicationNetwork()
	local leader = installLiveReplicationClient(network, "Leader", makeLiveRecord(2))
	installReentryDecisionBridge(leader)
	leader.callbacks.RaidInstanceRecognized[1](nil, "Naxxramas", "naxxramas", 1)
	assert(leader:FireHandoverTimer())
	assertEqual(1, #leader.decisionRequests)
	assertTrue(leader.syncer:IsAuthorityRecovering("raid-live"), "dismissal opened writes")
	assertEqual(nil, leader.store:Commit(makeLiveEvent(3)), "dismissal allowed a commit")
	assertEqual(0, leader.createdRaids)
	print("PASS raid_leader_reentry_dismissal_stays_suspended")
end

function cases.raid_leader_reentry_empty_recovery_creates_once()
	local network = newLiveReplicationNetwork()
	local leader = installLiveReplicationClient(network, "Leader", nil)
	installReentryDecisionBridge(leader)
	leader.callbacks.RaidInstanceRecognized[1](nil, "Naxxramas", "naxxramas", 1)
	assert(leader:FireHandoverTimer())
	assertEqual(0, leader.createdRaids, "new raid was created before the retry window")
	assert(leader:FireHandoverTimer())
	assertEqual(1, leader.createdRaids)
	assertEqual("raid-new-1", leader.currentRaidUid)
	print("PASS raid_leader_reentry_empty_recovery_creates_once")
end

function cases.raid_leader_reentry_rejects_invalid_candidates()
	local network = newLiveReplicationNetwork()
	local leader = installLiveReplicationClient(network, "Leader", makeLiveRecord(3))
	installReentryDecisionBridge(leader)
	installLiveReplicationClient(network, "ReplicaB", makeLiveRecord(1))
	leader.callbacks.RaidInstanceRecognized[1](nil, "Naxxramas", "naxxramas", 1)
	local before = deepCopy(leader.store.record)
	local wrongUid = makeLiveRecord(9)
	wrongUid.raidUid = "raid-other"
	local wrongEpoch = makeLiveRecord(9)
	wrongEpoch.authorityEpoch = 2
	local stale = makeLiveRecord(1)
	for _, row in ipairs({
		{ sender = "Outsider", head = makeLiveRecord(9) },
		{ sender = "ReplicaB", head = wrongUid },
		{ sender = "ReplicaB", head = wrongEpoch },
		{ sender = "ReplicaB", head = stale },
	}) do
		local head = deepCopy(row.head)
		head.state = nil
		head.events = nil
		local wire = network:encode("HEAD", "-", "-", head)
		leader.syncer:OnAddonMessage("RMARaidSync", wire, "WHISPER", row.sender .. "-Test Realm")
	end
	assertTrue(deepEqual(before, leader.store.record), "invalid candidate mutated the Leader")
	assertEqual(0, #leader.decisionRequests, "invalid candidate opened a decision early")
	print("PASS raid_leader_reentry_rejects_invalid_candidates")
end
```

Expose each through `tests/test_raid_replication_behavior.py`. Keep the existing `raid_live_sync_late_join_discovers_existing_active_raid`, `raid_live_sync_reload_noop`, split ML/RL, historical consent, and revision-zero import tests in the focused regression command.

- [ ] **Step 9: Run focused and full automated verification**

Run:

```powershell
py -3 -m unittest tests.test_raid_replication_behavior tests.test_sync_communications_behavior tests.test_single_raid_sharing_contract -v
py -3 -m unittest discover -s tests -v
git diff --check
py -3 'C:/Users/ferra/Downloads/RMA-Raid Management Addon/.agents/skills/wow-addon-dev-wotlk-v335a/scripts/validate_toc.py' 'Raid Management Addon/Raid Management Addon.toc'
py -3 'C:/Users/ferra/Downloads/RMA-Raid Management Addon/.agents/skills/wow-addon-dev-wotlk-v335a/scripts/lint_lua51.py' 'Raid Management Addon'
py -3 'C:/Users/ferra/Downloads/RMA-Raid Management Addon/.agents/skills/wow-addon-dev-wotlk-v335a/scripts/scan_xpcall.py' 'Raid Management Addon'
rg -n '<Scripts>|<On[A-Za-z]+>' 'Raid Management Addon/UI' -g '*.xml'
rg -n 'C_Timer|C_AddOns|Settings\.|MenuUtil|SetAtlas|SetColorTexture|table\.pack|table\.unpack|goto|_ENV|//' 'Raid Management Addon' -g '*.lua'
git status --short --branch
```

Expected: all tests PASS; TOC has zero errors/warnings; every addon Lua file passes the Lua 5.1 and `xpcall` validators; no XML handler is added; unsupported-API matches are either absent from changed files or documented as pre-existing; `git diff --check` is clean.

- [ ] **Step 10: Update the smoke artifact honestly**

Add:

```markdown
## Raid Leader Re-entry Recovery Gate

- Automated: PASS -- write barrier, bounded replica HEAD collection, greatest-sequence snapshot recovery, digest-conflict suspension, popup Yes/No, context mismatch, and no-copy creation.
- Live WotLK two-client smoke: NOT RUN.
- Required live path: A creates -> B replicates -> A reloads stale -> A recovers B -> popup Yes -> same UID -> new loot converges.
- Replacement path: popup No -> recovered previous raid concludes -> exactly one new raid is created.
- Historical path: A offers -> B accepts -> completed raid visible in B Loot History.
- Integration into `codex/loot-bans-optimization`: BLOCKED until every live path is positive.
```

Record the exact test count, validator file count, and Task 1/Task 2/Task 3 runtime commit hashes. Do not mark any live checkbox complete without observed in-game evidence.

- [ ] **Step 11: Commit the popup, transition, tests, and smoke gate**

```powershell
git add -- 'Raid Management Addon/Raid Management Addon.toc' 'Raid Management Addon/Controllers/RaidRecovery.lua' 'Raid Management Addon/Modules/Events.lua' 'Raid Management Addon/Database/DBSyncer.lua' 'Raid Management Addon/Services/Raid/State.lua' 'Raid Management Addon/Services/Raid/Session.lua' 'Raid Management Addon/Services/Raid/Capabilities.lua' 'Raid Management Addon/Localization/localization.en.lua' 'tests/lua/runtime_harness.lua' 'tests/test_raid_replication_behavior.py' 'docs/superpowers/smoke/2026-07-16-raid-data-replication.md'
git commit -m "feat(sync-03): confirm recovered raid continuation"
```

- [ ] **Step 12: Produce the branch handoff without integration**

Run:

```powershell
git log -4 --oneline
git status --short --branch
```

Expected: the design commit plus three task commits are present. Only the pre-existing `.superpowers/sdd/task-4-report.md` modification and `.planning/` files remain outside this work. Report code readiness separately from the still-blocked live integration gate.
