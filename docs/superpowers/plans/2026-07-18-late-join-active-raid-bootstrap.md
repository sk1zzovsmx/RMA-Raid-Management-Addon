# Late-Join Active Raid Bootstrap Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a non-leader who enters or reloads inside an already-running raid request and persist the Raid Leader's active raid replica without creating a competing raid.

**Architecture:** Add one closed, empty `HEAD_REQ` message to protocol v3 and send it by whisper to the identified Raid Leader from a new internal `RaidInstanceRecognized` event. `DBSyncer` owns a bounded immediate-plus-one-retry discovery state; the Raid Leader answers with the existing group `HEAD`, after which the unchanged `HEAD -> SNAP_REQ -> SNAP_DATA` path installs the active replica. Entry order changes timing only: authority always follows the current Raid Leader, while completed history remains offer-and-consent.

**Tech Stack:** World of Warcraft WotLK 3.3.5a API, Lua 5.1, RMA event bus and timer mixin, Python `unittest`, in-process two-peer Lua runtime harness.

## Global Constraints

- Target WotLK 3.3.5a with `## Interface: 30300` and Lua 5.1 syntax only.
- Keep the Raid Leader as the sole active-raid authority for both Master Loot and Group Loot.
- A non-leader may persist only the Raid Leader's authenticated read-only active replica; it must never create a competing raid.
- Completed historical raids remain offer-and-consent only; `HEAD_REQ` must not auto-import completed history.
- Keep protocol version 3 and make `HEAD_REQ` additive; accept existing legacy messages and send the modern closed format.
- Use one immediate request and at most one retry after exactly three seconds; coalesce duplicate recognition events.
- Add no polling, unbounded `OnUpdate`, SavedVariables schema change, migration, new dependency, or vendored-library edit.
- Preserve the existing recovery-first handover and the same stable raid identity across leadership changes.
- Do not integrate this branch into `codex/loot-bans-optimization` until the two-client live smoke is positive.

---

### Task 1: Close the `HEAD_REQ` Wire Contract

**Files:**
- Modify: `Raid Management Addon/Database/DBSyncProtocol.lua:37-78,165-218,232-252`
- Test: `tests/lua/runtime_harness.lua:3431-3645`

**Interfaces:**
- Consumes: `Protocol.Encode(kind, requestId, target, body)` and `Protocol.Decode(message)`.
- Produces: `HEAD_REQ` with body `{}`, `requestId = "-"`, and `target = "-"`; it is fire-and-forget at the envelope layer and is delivered by whisper at the transport layer.

- [ ] **Step 1: Write failing protocol round-trip and rejection coverage**

Insert `HEAD_REQ = {},` as the first entry returned by `protocolBodies()`, then classify it with the other fire-and-forget kinds:

```lua
HEAD_REQ = {},

local kinds = { "HEAD_REQ", "HEAD", "EVENT", "RANGE_REQ", "RANGE_DATA", "SNAP_REQ", "SNAP_DATA", "OFFER", "RESULT" }
for i = 1, #kinds do
	local kind = kinds[i]
	local fireAndForget = kind == "HEAD_REQ" or kind == "HEAD" or kind == "EVENT"
	local requestId, target
	if not fireAndForget then
		requestId = "request-" .. i
		target = "Recipient"
	end
	local message = assert(protocol.Encode(kind, requestId, target, bodies[kind]))
	local decoded = assert(protocol.Decode(message))
	assertEqual(kind, decoded.kind, kind .. " decoded kind differs")
	assertEqual(requestId or "-", decoded.requestId, kind .. " decoded request ID differs")
	assertEqual(target or "-", decoded.target, kind .. " decoded target differs")
	assertTrue(deepEqual(bodies[kind], decoded.body), kind .. " decoded body differs")
end
```

Add these invalid cases before the existing rejection loop:

```lua
reject("HEAD_REQ nonempty body", "HEAD_REQ", nil, nil, { raidUid = "r1" })
reject("HEAD_REQ targeted addressing", "HEAD_REQ", "request", "Leader", {})
```

- [ ] **Step 2: Run the focused tests and verify RED**

Run:

```powershell
python -m unittest tests.test_raid_replication_behavior.RaidReplicationBehaviorTests.test_version_3_protocol_round_trips_every_closed_message_kind tests.test_raid_replication_behavior.RaidReplicationBehaviorTests.test_version_3_protocol_rejects_invalid_envelopes_and_bodies -v
```

Expected: FAIL because `HEAD_REQ` is not present in `MESSAGE_SCHEMAS` and cannot be encoded.

- [ ] **Step 3: Implement the minimal closed protocol kind**

Insert the exact schema and validator entries without changing the protocol version:

```lua
HEAD_REQ = {},

HEAD_REQ = function()
	return true
end,

local function validateEnvelope(kind, requestId, target)
	if kind == "HEAD_REQ" or kind == "HEAD" or kind == "EVENT" then
		if requestId ~= "-" or target ~= "-" then
			return nil, "INVALID_ENVELOPE_TARGET"
		end
		return true
	end
	if requestId == "-" or target == "-" or not visibleAscii(requestId, 1, 64) or not visibleAscii(target, 1, 64) then
		return nil, "INVALID_ENVELOPE_TARGET"
	end
	return true
end
```

The existing exact-key body validation makes `{ raidUid = "r1" }` fail against the empty schema; do not introduce a special parser or session type.

- [ ] **Step 4: Run the focused tests and verify GREEN**

Run the Step 2 command again.

Expected: both tests PASS and protocol version remains `3`.

- [ ] **Step 5: Commit the wire contract**

```powershell
git add -- 'Raid Management Addon/Database/DBSyncProtocol.lua' 'tests/lua/runtime_harness.lua'
git commit -m "feat(sync-02): add head discovery request"
```

---

### Task 2: Discover an Existing Active Raid from the Late Participant

**Files:**
- Modify: `Raid Management Addon/Init.lua:66-90,772-825`
- Modify: `Raid Management Addon/Database/DBSyncer.lua:30-85,298-303,734-780,1054-1091,1265-1312,1367-1372`
- Test: `tests/lua/runtime_harness.lua:13350-13820,14214-14225`
- Test: `tests/test_raid_replication_behavior.py:55-70`

**Interfaces:**
- Consumes: Task 1's `HEAD_REQ` envelope; `Raid:GetRaidLeaderName()`, `Raid:IsRaidLeader()`, `Raid:IsGroupMember(name)`, `RaidStore:GetActiveRecord()`, `addon.Timer:After(delay, callback)`, and existing `module:AdvertiseHead()`.
- Produces: internal event `Events.Internal.RaidInstanceRecognized`; local helpers `cancelDiscovery()`, `sendHeadRequest(authority)`, `requestActiveRaidIfNeeded()`; one `HEAD_REQ` whisper followed by the existing authenticated snapshot bootstrap.

- [ ] **Step 1: Write the late-join test in real temporal order**

Add `RaidInstanceRecognized = "RaidInstanceRecognized"` to the fixture's `addon.Events.Internal` table. Its callbacks and sent message kinds are already exposed as `client.callbacks` and `client.requests`. Then add a case where A already has state before B exists:

```lua
function cases.raid_live_sync_late_join_discovers_existing_active_raid()
	local network = newLiveReplicationNetwork()
	local leader = installLiveReplicationClient(network, "Leader", makeLiveRecord(2))
	local member = installLiveReplicationClient(network, "Member", nil)

	local recognized = assert(member.callbacks.RaidInstanceRecognized, "recognized-instance callback missing")
	recognized[1](nil, "Naxxramas", "naxxramas")

	assertEqual("HEAD_REQ", member.requests[1], "late member did not request the active HEAD")
	assertEqual("HEAD", leader.requests[1], "leader did not advertise its active HEAD")
	assertEqual("SNAP_REQ", member.requests[2], "late member did not request the snapshot")
	assertEqual("SNAP_DATA", leader.requests[2], "leader did not transfer the snapshot")
	assertEqual(leader.store.record.raidUid, member.store.record.raidUid, "replica UID differs")
	assertEqual(leader.store.record.sequence, member.store.record.sequence, "replica sequence differs")
	assertEqual(leader.store.record.digest, member.store.record.digest, "replica digest differs")
	assertEqual(nil, member.store.committed[1], "non-leader committed an authoritative event")

	print("PASS raid_live_sync_late_join_discovers_existing_active_raid")
end
```

Expose it through Python:

```python
def test_late_nonleader_discovers_the_leaders_existing_active_raid(self) -> None:
    self.assert_case("raid_live_sync_late_join_discovers_existing_active_raid")
```

- [ ] **Step 2: Run the new test and verify RED**

Run:

```powershell
python -m unittest tests.test_raid_replication_behavior.RaidReplicationBehaviorTests.test_late_nonleader_discovers_the_leaders_existing_active_raid -v
```

Expected: FAIL because `RaidInstanceRecognized` is not registered and B cannot originate `HEAD_REQ`.

- [ ] **Step 3: Publish recognized instances from `Init.lua`**

Seed and capture the internal event next to the existing bootstrap events:

```lua
Internal.RaidInstanceRecognized = Internal.RaidInstanceRecognized or "RaidInstanceRecognized"
```

After `scheduleRaidInstanceChecksIfRecognized` has confirmed a non-empty recognized `instanceKey`, publish exactly once per confirmed call before scheduling the existing raid checks:

```lua
Bus.TriggerEvent(InternalEvents.RaidInstanceRecognized, instanceName, instanceKey)
```

Keep WoW instance API calls in `Init.lua`; do not move recognition into the database layer.

- [ ] **Step 4: Add bounded discovery state and direct transport in `DBSyncer.lua`**

Bind the new event and add one constant:

```lua
local RaidInstanceRecognizedEvent = assert(InternalEvents.RaidInstanceRecognized, "Raid instance event is not initialized")
local DISCOVERY_RETRY_SECONDS = 3
```

Add a fire-and-forget whisper helper beside `sendGroup`:

```lua
local function sendDirectFireAndForget(kind, target, body)
	local message, reason = Protocol.Encode(kind, "-", "-", body)
	if not message then
		return false, reason
	end
	return Comms.QueueAddonMessage(COMM_PREFIX, message, "WHISPER", target)
end
```

Use the existing timer mixin and the pending table's identity as the stale-callback token:

```lua
local function cancelDiscovery()
	local pending = module._discovery
	if pending and pending.timer then
		module:CancelTimer(pending.timer)
	end
	module._discovery = nil
end

local function sendHeadRequest(authority)
	return sendDirectFireAndForget("HEAD_REQ", authority, {})
end

local function requestActiveRaidIfNeeded()
	refreshAuthority()
	if RaidStore:GetActiveRecord() or Raid:IsRaidLeader() then
		cancelDiscovery()
		return
	end
	local authority = normalizeName(Raid:GetRaidLeaderName())
	if not authority or authority == localPlayer or not Raid:IsGroupMember(authority) then
		return
	end
	if module._discovery and module._discovery.authority == authority then
		return
	end
	cancelDiscovery()
	local pending = { authority = authority }
	module._discovery = pending
	sendHeadRequest(authority)
	if module._discovery ~= pending then
		return
	end
	pending.timer = module:ScheduleTimer(function()
		if module._discovery ~= pending then
			return
		end
		module._discovery = nil
		if not RaidStore:GetActiveRecord() and not Raid:IsRaidLeader()
			and normalizeName(Raid:GetRaidLeaderName()) == authority and Raid:IsGroupMember(authority)
		then
			sendHeadRequest(authority)
		end
	end, DISCOVERY_RETRY_SECONDS)
end
```

Register it once:

```lua
RegisterCallback(RaidInstanceRecognizedEvent, requestActiveRaidIfNeeded)
```

- [ ] **Step 5: Accept `HEAD_REQ` only at the current authority and cancel on authenticated HEAD**

Add a handler before `HANDLERS`:

```lua
local function handleHeadRequest(sender)
	local leader = normalizeName(Raid:GetRaidLeaderName())
	if not Raid:IsRaidLeader() or leader ~= localPlayer or not Raid:IsGroupMember(sender) then
		return false
	end
	return module:AdvertiseHead()
end
```

Add `HEAD_REQ = handleHeadRequest` to `HANDLERS`. In `OnAddonMessage`, exempt it from the payload target check while preserving the group-member check already performed before dispatch:

```lua
if kind ~= "HEAD_REQ" and kind ~= "HEAD" and kind ~= "EVENT" then
	if normalizeName(envelope.target) ~= localPlayer then
		return false
	end
end
```

At the start of `handleHead`, after the existing Raid Leader sender authentication has succeeded, cancel pending discovery only for an active HEAD:

```lua
if envelope.body.status == "active" then
	cancelDiscovery()
end
```

Do not route `HEAD_REQ` through `DBSyncSession`; it has no correlated response body.

- [ ] **Step 6: Prove coalescing and the one-retry bound**

In the same Lua case, add a second sub-scenario with an identified addon-less leader. Fire the recognition callback twice, assert one immediate `HEAD_REQ`, execute the stored three-second callback, assert exactly one second `HEAD_REQ`, execute the stale callback again, and assert the count stays two:

```lua
local isolatedNetwork = newLiveReplicationNetwork()
isolatedNetwork.raidLeader = "AbsentLeader"
local isolated = installLiveReplicationClient(isolatedNetwork, "Member", nil)
local isolatedRecognized = assert(isolated.callbacks.RaidInstanceRecognized)
isolatedRecognized[1](nil, "Naxxramas", "naxxramas")
isolatedRecognized[1](nil, "Naxxramas", "naxxramas")
assertEqual(1, countKind(isolated.requests, "HEAD_REQ"), "duplicate signals did not coalesce")
local retry = assert(isolated.timers[#isolated.timers], "discovery retry missing")
retry()
assertEqual(2, countKind(isolated.requests, "HEAD_REQ"), "bounded retry count differs")
retry()
assertEqual(2, countKind(isolated.requests, "HEAD_REQ"), "stale retry sent again")
assertEqual(nil, isolated.store.record, "non-leader created without an addon-enabled authority")
```

Implement `countKind` as a local harness helper that linearly counts exact string matches; do not add runtime instrumentation.

```lua
local function countKind(kinds, expected)
	local count = 0
	for i = 1, #kinds do
		if kinds[i] == expected then
			count = count + 1
		end
	end
	return count
end
```

- [ ] **Step 7: Run focused and replication suites**

Run:

```powershell
python -m unittest tests.test_raid_replication_behavior.RaidReplicationBehaviorTests.test_late_nonleader_discovers_the_leaders_existing_active_raid -v
python -m unittest tests.test_raid_replication_behavior -v
```

Expected: the new temporal regression PASSes; all raid replication behavior tests PASS.

- [ ] **Step 8: Commit the active bootstrap**

```powershell
git add -- 'Raid Management Addon/Init.lua' 'Raid Management Addon/Database/DBSyncer.lua' 'tests/lua/runtime_harness.lua' 'tests/test_raid_replication_behavior.py'
git commit -m "fix(sync-02): bootstrap late raid participants"
```

---

### Task 3: Lock Entry-Order Authority and Refresh the Live Gate

**Files:**
- Modify: `tests/lua/runtime_harness.lua:13984-14050,14214-14225,15174-15244`
- Modify: `tests/test_raid_replication_behavior.py:55-85,140-160`
- Modify: `docs/superpowers/smoke/2026-07-16-raid-data-replication.md`

**Interfaces:**
- Consumes: Task 2's `RaidInstanceRecognized` callback, bounded `HEAD_REQ`, existing `RaidCreate` callback, and existing recovery-first handover.
- Produces: automated proof for all three entry-order cases and an honest live-smoke gate that remains blocked until tested in WotLK.

- [ ] **Step 1: Add B-first and handover identity regressions**

Add a B-first case where A is already identified as leader but has no active record. B requests and remains empty; A then receives an active record and fires only its existing `RaidCreate` callback; B must import that record:

```lua
function cases.raid_live_sync_member_enters_before_designated_leader()
	local network = newLiveReplicationNetwork()
	local leader = installLiveReplicationClient(network, "Leader", nil)
	local member = installLiveReplicationClient(network, "Member", nil)
	local recognized = assert(member.callbacks.RaidInstanceRecognized)
	recognized[1](nil, "Naxxramas", "naxxramas")
	assertEqual(nil, member.store.record, "member created before the designated leader")

	leader.store.record = makeLiveRecord(2)
	local created = assert(leader.callbacks.RaidCreate)
	created[1](nil, "raid-live")
	assertEqual("raid-live", member.store.record.raidUid, "member did not import after leader entry")
	assertEqual(nil, member.store.committed[1], "member became authority from entry order")
	print("PASS raid_live_sync_member_enters_before_designated_leader")
end
```

Extend `raid_handover_repeated_authority_change` with identity assertions around its existing Member-to-Leader authority transition:

```lua
local originalUid = member.store.record.raidUid
local originalCount = member.store.record and 1 or 0
assertEqual(originalUid, leader.store.record.raidUid, "handover changed the stable raid UID")
assertEqual(originalUid, member.store.record.raidUid, "old leader retained a different raid UID")
assertEqual(originalCount, member.store.record and 1 or 0, "handover created a duplicate raid")
```

Expose the new case through Python; the existing handover case already maps to `test_repeated_raid_leader_changes_cancel_stale_work`:

```python
def test_member_entry_before_the_designated_leader_waits_for_authority(self) -> None:
    self.assert_case("raid_live_sync_member_enters_before_designated_leader")
```

- [ ] **Step 2: Run ordering tests and verify GREEN**

Run:

```powershell
python -m unittest tests.test_raid_replication_behavior.RaidReplicationBehaviorTests.test_member_entry_before_the_designated_leader_waits_for_authority tests.test_raid_replication_behavior.RaidReplicationBehaviorTests.test_repeated_raid_leader_changes_cancel_stale_work -v
```

Expected: both tests PASS; B remains empty until the Raid Leader has an active raid, and handover preserves one UID.

- [ ] **Step 3: Run the full automated validation gate**

Run:

```powershell
python -m unittest discover -s tests -v
git diff --check
py -3 'C:/Users/ferra/Downloads/RMA-Raid Management Addon/.agents/skills/wow-addon-dev-wotlk-v335a/scripts/validate_toc.py' 'Raid Management Addon/Raid Management Addon.toc'
py -3 'C:/Users/ferra/Downloads/RMA-Raid Management Addon/.agents/skills/wow-addon-dev-wotlk-v335a/scripts/lint_lua51.py' 'Raid Management Addon'
py -3 'C:/Users/ferra/Downloads/RMA-Raid Management Addon/.agents/skills/wow-addon-dev-wotlk-v335a/scripts/scan_xpcall.py' 'Raid Management Addon'
rg -n "<Scripts>|<On[A-Za-z]+>" 'Raid Management Addon/UI' -g '*.xml'
rg -n "C_Timer|C_AddOns|Settings\.|MenuUtil|SetAtlas|SetColorTexture|table\.pack|table\.unpack|goto|_ENV|//" 'Raid Management Addon' -g '*.lua'
git status --short --branch
```

Expected: the full test suite PASSes; `git diff --check` is clean; TOC, Lua 5.1, and `xpcall` validators PASS; searches introduce no new forbidden WotLK API or XML handler. `tools/check-rma.ps1` is absent in this worktree, so do not claim that validator ran.

- [ ] **Step 4: Update the smoke document without claiming live success**

Record:

```markdown
## Late-Join Active Bootstrap Gate

- Automated: PASS — A active first, B recognition only, `HEAD_REQ -> HEAD -> SNAP_REQ -> SNAP_DATA`.
- Entry order: PASS — B before designated A waits; B-as-leader handover keeps one stable UID; leader without RMA is not substituted.
- Live WotLK two-client smoke: NOT RUN.
- Integration into `codex/loot-bans-optimization`: BLOCKED until the live smoke is positive.
```

Keep the existing historical smoke sequence A offers -> B accepts -> raid visible in Loot History. Add the exact automated test total from Step 3 and the two runtime commit hashes from Tasks 1 and 2.

- [ ] **Step 5: Commit the ordering gate and smoke metadata**

```powershell
git add -- 'tests/lua/runtime_harness.lua' 'tests/test_raid_replication_behavior.py' 'docs/superpowers/smoke/2026-07-16-raid-data-replication.md'
git commit -m "test(sync-02): cover entry-order authority"
```

- [ ] **Step 6: Produce the final branch handoff**

Run:

```powershell
git log -3 --oneline
git status --short --branch
```

Expected: the three task commits are present; only the pre-existing user modification `.superpowers/sdd/task-4-report.md` and the untracked `.planning/` debug artifact remain outside the task commits. Report the automated result and explicitly request the live A/B smoke; do not merge or integrate the branch.
