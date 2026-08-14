# Raid Data Replication Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the beta raid database synchronization with authoritative, event-driven replication for the active raid and consent-gated immutable snapshot sharing for completed raids.

**Architecture:** `RMA_Raids` becomes a versioned archive keyed by stable `raidUid`; each record owns canonical raid state plus persisted epoch, sequence, digest, checkpoint, and a bounded active event range. The Master Looter commits semantic events and replicas recover by range or validated snapshot, while completed history moves only through targeted offer and acceptance.

**Tech Stack:** WoW 3.3.5a build 12340, Interface 30300, Lua 5.1.5, Blizzard addon-message API, bundled LibDeflate, existing RMA `Comms`/`Timer`/`Bus`, Python 3 `unittest`, Lua runtime harness.

## Global Constraints

- Work only in `.worktrees/single-raid-history-sharing` on `codex/single-raid-history-sharing`.
- Do not integrate into `codex/loot-bans-optimization` until the two-client in-game smoke is positive.
- Keep addon name `Raid Management Addon`, runtime short name `RMA`, `/rma`, `RMA_*` SavedVariables, and RMA addon-message prefixes.
- Runtime must remain compatible with WotLK 3.3.5a, build 12340, Interface `30300`, and Lua 5.1.5.
- Do not add Ace2, Ace3, Retail APIs, Classic APIs, Lua 5.2 syntax, XML script handlers, or edits under `Libs/`.
- The wire protocol is version `3`; every other protocol version is rejected before body decoding and cannot mutate the new store.
- Unsupported beta `RMA_Raids` data is reset to an empty format-version-1 archive without migration or backup.
- The canonical active ledger is persisted, bounded to 512 events after its checkpoint, and removed when the raid concludes.
- Current-raid replication is automatic from the Master Looter; completed raids require a targeted offer and explicit recipient acceptance.
- Same UID and digest is idempotent; same UID with a different digest is a conflict and is never merged or overwritten automatically.
- Each targeted request retries at most once. Do not add per-event or per-chunk acknowledgements.
- Normal UI exposes essential state only; request IDs, chunks, digests, retries, and rates remain debug diagnostics.
- No compatibility facade, alternate synchronization strategy, generic patch event, global ledger, CRDT, or peer database convergence layer may remain in the finished change.
- Use `apply_patch` for edits, TDD for every runtime behavior, focused tests before full tests, and an atomic commit after every task.

## Locked File Ownership

- Create `Raid Management Addon/Database/DBRaidEvents.lua`: canonical encoding, UID/event identity, event schemas, reducers, and state digest.
- Rewrite `Raid Management Addon/Database/DBRaidStore.lua`: archive access, ordered history projection, atomic authoritative and replica commits, checkpoint, snapshot, import, and compaction.
- Keep `Raid Management Addon/Database/DBRaidQueries.lua`: read-only projections over canonical `record.state`.
- Rewrite `Raid Management Addon/Database/DBRaidValidator.lua`: complete archive, record, state, snapshot, and bound validation.
- Create `Raid Management Addon/Database/DBSyncProtocol.lua`: version-3 envelope and message-body codec only.
- Create `Raid Management Addon/Database/DBSyncSession.lua`: request correlation, channel-safe encoding, chunks, capacity, expiry, throttling, and one retry.
- Rewrite `Raid Management Addon/Database/DBSyncer.lua`: Master Looter authority, live replication, recovery, handover, history offers, and user-visible outcomes.
- Delete `Raid Management Addon/Database/DBRaidMigrations.lua`, `DBSyncMetrics.lua`, `DBSyncPayload.lua`, and `DBSyncImport.lua` after all callers move to the new owners.
- Modify `Raid Management Addon/Database/SavedVariables.lua` and `DB.lua` only for archive bootstrap and owner lookup.
- Modify mutation owners under `Services/Raid`, `Services/Loot`, `Services/Logger`, `Services/Attendance`, and `Services/EquipInspect.lua` only where canonical raid state changes.
- Modify `Modules/Events.lua`, `Modules/Comms.lua`, localization, `Controllers/Logger.lua`, `Controllers/Config.lua`, `EntryPoints/SlashEvents.lua`, `UI/LootHistory.xml`, and `UI/Config.xml` only for the new sync contract and essential feedback.
- Modify `Raid Management Addon.toc` once the new module load order is ready.
- Add behavior cases to `tests/lua/runtime_harness.lua` and expose them through `tests/test_raid_replication_behavior.py`; update existing sync/config/sharing contracts instead of keeping tests for removed beta behavior.

---

### Task 1: Deterministic Raid Events And Digest

**Files:**
- Create: `Raid Management Addon/Database/DBRaidEvents.lua`
- Modify: `Raid Management Addon/Raid Management Addon.toc`
- Modify: `tests/lua/runtime_harness.lua`
- Create: `tests/test_raid_replication_behavior.py`

**Interfaces:**
- Consumes: `addon.Time.GetCurrentTime`, `LibStub("LibDeflate")`, canonical raid tables.
- Produces: `addon.DB.RaidEvents.CreateRaidUid(creatorKey, serverTime, counter, sessionNonce)`, `BuildEventUid(raidUid, epoch, sequence)`, `DigestState(state)`, `ValidateEvent(event)`, and `Apply(state, event)`.
- Returns: value on success; `nil, "UPPER_SNAKE_REASON"` on recoverable validation failure.

- [ ] **Step 1: Add failing Python behavior entrypoints**

Create `tests/test_raid_replication_behavior.py` with:

```python
from __future__ import annotations

import unittest

from tests.lua_test_runner import run_lua_case


class RaidReplicationBehaviorTests(unittest.TestCase):
    def assert_case(self, case_name: str) -> None:
        result = run_lua_case(case_name)
        self.assertIn(f"PASS {case_name}", result.stdout)

    def test_event_identity_is_deterministic_and_bounded(self) -> None:
        self.assert_case("raid_replication_event_identity")

    def test_digest_is_order_independent_for_maps(self) -> None:
        self.assert_case("raid_replication_digest")

    def test_reducers_are_idempotent_and_fail_closed(self) -> None:
        self.assert_case("raid_replication_reducers")


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Add the three failing Lua cases**

Append cases that load `DBRaidEvents.lua` and make these exact assertions:

```lua
function cases.raid_replication_event_identity(addon)
	installRaidReplicationEventFixture(addon)
	local events = addon.DB.RaidEvents
	local uid = assert(events.CreateRaidUid("Leader-Realm", 1721120000, 7, "abcd1234"))
	assertTrue(#uid <= 40, "raid UID exceeds wire bound")
	assertEqual(uid, events.CreateRaidUid("Leader-Realm", 1721120000, 7, "abcd1234"))
	assertEqual(uid .. ":2:18", events.BuildEventUid(uid, 2, 18))
	print("PASS raid_replication_event_identity")
end

function cases.raid_replication_digest(addon)
	installRaidReplicationEventFixture(addon)
	local events = addon.DB.RaidEvents
	local left = { zone = "ICC", players = { ["p2"] = { name = "B" }, ["p1"] = { name = "A" } } }
	local right = { players = { ["p1"] = { name = "A" }, ["p2"] = { name = "B" } }, zone = "ICC" }
	local leftDigest = assert(events.DigestState(left))
	assertEqual(leftDigest, events.DigestState(right))
	assertTrue(string.match(leftDigest, "^[0-9a-f][0-9a-f]+:%d+$") ~= nil)
	print("PASS raid_replication_digest")
end

function cases.raid_replication_reducers(addon)
	installRaidReplicationEventFixture(addon)
	local events = addon.DB.RaidEvents
	local state = { loot = {}, players = {}, bossKills = {}, attendance = {}, nextLootNid = 1 }
	local event = {
		raidUid = "r1", authorityEpoch = 1, sequence = 1, eventUid = "r1:1:1",
		eventType = "LOOT_ADDED", payload = { loot = { lootNid = 1, itemLink = "item:19019" } },
	}
	local nextState = assert(events.Apply(state, event))
	assertEqual("item:19019", nextState.loot[1].itemLink)
	assertEqual(nil, events.Apply(nextState, event))
	assertEqual(0, #state.loot, "reducer mutated its input")
	print("PASS raid_replication_reducers")
end
```

Add `installRaidReplicationEventFixture` beside the other fixture installers. It must provide deterministic `LibDeflate:Adler32`, load `DBRaidEvents.lua`, and must not load the store or syncer.

Use this fixture implementation:

```lua
local function installRaidReplicationEventFixture(addon)
	local function adler32(text)
		local a, b = 1, 0
		for i = 1, #text do
			a = (a + string.byte(text, i)) % 65521
			b = (b + a) % 65521
		end
		return b * 65536 + a
	end
	_G.LibStub = function(name)
		assertEqual("LibDeflate", name)
		return { Adler32 = function(_, text) return adler32(text) end }
	end
	addon.DB = addon.DB or {}
	loadAddonFile(addon, "Raid Management Addon/Database/DBRaidEvents.lua")
end
```

- [ ] **Step 3: Run the focused test and confirm RED**

Run:

```powershell
py -3 -m unittest tests.test_raid_replication_behavior -v
```

Expected: all three cases fail because `DBRaidEvents.lua` or its public methods do not exist.

- [ ] **Step 4: Implement the event owner**

Implement one table-driven schema registry and one reducer dispatch. The public surface must be exactly:

```lua
local addon = select(2, ...)
local DB = addon.DB
local LibDeflate = assert(LibStub("LibDeflate"), "LibDeflate is not initialized")

DB.RaidEvents = DB.RaidEvents or {}
local Events = DB.RaidEvents

local EVENT_TYPES = {
	RAID_CREATED = true,
	RAID_METADATA_UPDATED = true,
	PLAYER_UPDATED = true,
	PLAYER_DEPARTED = true,
	BOSS_UPDATED = true,
	ATTENDANCE_UPDATED = true,
	LOOT_ADDED = true,
	LOOT_UPDATED = true,
	LOOT_DELETED = true,
	RAID_CONCLUDED = true,
}

function Events.CreateRaidUid(creatorKey, serverTime, counter, sessionNonce)
	local identity = normalizeIdentity(creatorKey)
	local timestamp = exactInteger(serverTime, 1, 9999999999)
	local ordinal = exactInteger(counter, 1, 999999)
	local nonce = normalizeToken(sessionNonce, 12)
	if not identity or not timestamp or not ordinal or not nonce then
		return nil, "INVALID_RAID_UID_INPUT"
	end
	local seed = identity .. ":" .. timestamp .. ":" .. ordinal .. ":" .. nonce
	local checksum = string.format("%08x", LibDeflate:Adler32(seed))
	return "r:" .. timestamp .. ":" .. ordinal .. ":" .. checksum
end

function Events.BuildEventUid(raidUid, epoch, sequence)
	return tostring(raidUid) .. ":" .. tostring(epoch) .. ":" .. tostring(sequence)
end

function Events.DigestState(state)
	local encoded, reason = canonicalEncode(state)
	if not encoded then return nil, reason end
	return string.format("%08x:%d", LibDeflate:Adler32(encoded), #encoded)
end

function Events.ValidateEvent(event)
	return validateEventAgainstSchemas(event, EVENT_TYPES)
end

function Events.Apply(state, event)
	local valid, reason = Events.ValidateEvent(event)
	if not valid then return nil, reason end
	return applyEventToCopiedState(state, event)
end
```

Canonical encoding must type-tag nil/boolean/number/string/table, length-prefix strings, reject NaN/infinity/functions/userdata/threads/cycles, sort map keys by encoded scalar key, and preserve dense-array order. Reducers must copy before mutation, require stable numeric entity NIDs, reject duplicates for `*_ADDED`, and reject all mutation after `RAID_CONCLUDED`. `PLAYER_UPDATED`, `BOSS_UPDATED`, and `ATTENDANCE_UPDATED` are explicit stable-NID upserts used for both creation and later updates; `LOOT_UPDATED` and delete events require an existing entity.

Define these private functions in the same file; no other module may call them:

```text
exactInteger(value, minimum, maximum) -> integer | nil
normalizeIdentity(value) -> lowercase bounded ASCII string | nil
normalizeToken(value, maximumBytes) -> bounded ASCII string | nil
canonicalEncode(value) -> encoded string | nil, reason
validateEventAgainstSchemas(event, schemas) -> true | nil, reason
applyEventToCopiedState(state, event) -> copied state | nil, reason
```

- [ ] **Step 5: Add the TOC entry and verify GREEN**

Load `Database\DBRaidEvents.lua` immediately before `Database\DBRaidStore.lua`, then run:

```powershell
py -3 -m unittest tests.test_raid_replication_behavior -v
```

Expected: three tests pass.

- [ ] **Step 6: Commit the event core**

```powershell
git add -f -- "Raid Management Addon/Database/DBRaidEvents.lua" "Raid Management Addon/Raid Management Addon.toc" tests/lua/runtime_harness.lua tests/test_raid_replication_behavior.py
git diff --cached --check
git commit -m "feat(database): Add deterministic raid event core"
```

---

### Task 2: Versioned Archive And Atomic Store

**Files:**
- Modify: `Raid Management Addon/Database/SavedVariables.lua`
- Modify: `Raid Management Addon/Database/DB.lua`
- Rewrite: `Raid Management Addon/Database/DBRaidStore.lua`
- Rewrite: `Raid Management Addon/Database/DBRaidValidator.lua`
- Modify: `Raid Management Addon/Database/DBRaidQueries.lua`
- Modify: `tests/lua/runtime_harness.lua`
- Modify: `tests/test_raid_replication_behavior.py`
- Modify: `tests/test_runtime_bootstrap_contract.py`

**Interfaces:**
- Consumes: `DB.RaidEvents`, `SavedVariables.GetRaids`, existing raid state fields.
- Produces: `EnsureArchive`, `GetRecord`, `GetActiveRecord`, `GetStateByIndex`, `GetIndexByUid`, `CreateActiveRaid`, `CommitAuthoritativeEvent`, `ApplyReplicaEvent`, `GetEventRange`, `BuildSnapshot`, `ReplaceActiveFromSnapshot`, `ImportHistoricalSnapshot`, and `ConcludeActiveRaid`.
- Compatibility during Tasks 2-3: `Database.EnsureRaidByIndex` returns `record.state`; numeric history selection remains an ordered projection over `archive.order`.

- [ ] **Step 1: Add failing archive/store cases**

Extend the Python class with:

```python
    def test_beta_store_resets_and_reload_preserves_sync_position(self) -> None:
        self.assert_case("raid_replication_archive_reload")

    def test_store_commit_and_replica_apply_are_atomic(self) -> None:
        self.assert_case("raid_replication_atomic_store")

    def test_checkpoint_bounds_range_and_snapshot_fallback(self) -> None:
        self.assert_case("raid_replication_checkpoint")
```

The Lua cases must assert this canonical shape:

```lua
RMA_Raids = {
	formatVersion = 1,
	activeRaidUid = "r:1721120000:1:89abcdef",
	order = { "r:1721120000:1:89abcdef" },
	raids = {
		["r:1721120000:1:89abcdef"] = {
			status = "active", authorityEpoch = 1, sequence = 1,
			digest = "89abcdef:2048", checkpointSequence = 0,
			state = { zone = "ICC", players = {}, bossKills = {}, attendance = {}, loot = {} },
			events = {
				{
					raidUid = "r:1721120000:1:89abcdef", authorityEpoch = 1,
					sequence = 1, eventUid = "r:1721120000:1:89abcdef:1:1",
					eventType = "RAID_CREATED",
					payload = {
						state = { zone = "ICC", players = {}, bossKills = {}, attendance = {}, loot = {} },
					},
					resultDigest = "89abcdef:2048",
				},
			},
		},
	},
}
```

Also inject a failing reducer and digest mismatch and assert that the original record is deeply unchanged.

- [ ] **Step 2: Run the new cases and confirm RED**

```powershell
py -3 -m unittest tests.test_raid_replication_behavior.RaidReplicationBehaviorTests.test_beta_store_resets_and_reload_preserves_sync_position tests.test_raid_replication_behavior.RaidReplicationBehaviorTests.test_store_commit_and_replica_apply_are_atomic tests.test_raid_replication_behavior.RaidReplicationBehaviorTests.test_checkpoint_bounds_range_and_snapshot_fallback -v
```

Expected: three failures because the archive APIs do not exist.

- [ ] **Step 3: Replace beta bootstrap with strict archive bootstrap**

Implement this behavior in `SavedVariables.lua` and call it from `NormalizeAfterLoad`:

```lua
local RAID_ARCHIVE_FORMAT_VERSION = 1

local function newRaidArchive()
	return { formatVersion = RAID_ARCHIVE_FORMAT_VERSION, activeRaidUid = nil, order = {}, raids = {} }
end

local function ensureRaidArchive()
	local current = _G.RMA_Raids
	if type(current) ~= "table"
		or current.formatVersion ~= RAID_ARCHIVE_FORMAT_VERSION
		or type(current.order) ~= "table"
		or type(current.raids) ~= "table"
	then
		current = newRaidArchive()
		_G.RMA_Raids = current
	end
	return current
end

function SavedVariables.GetRaids()
	return ensureRaidArchive()
end
```

Do not read an array-shaped beta store after deciding it is unsupported.

- [ ] **Step 4: Implement atomic store contracts**

Use copy-validate-replace for every write. The authoritative commit path must follow this exact order:

```lua
function Store:CommitAuthoritativeEvent(raidUid, eventType, payload)
	local current = self:GetRecord(raidUid)
	if not current or current.status ~= "active" then return nil, "RAID_NOT_ACTIVE" end
	local event = {
		raidUid = raidUid,
		authorityEpoch = current.authorityEpoch,
		sequence = current.sequence + 1,
		eventUid = RaidEvents.BuildEventUid(raidUid, current.authorityEpoch, current.sequence + 1),
		eventType = eventType,
		payload = deepCopy(payload),
	}
	local candidateState, reason = RaidEvents.Apply(current.state, event)
	if not candidateState then return nil, reason end
	event.resultDigest = assert(RaidEvents.DigestState(candidateState))
	local candidate = deepCopy(current)
	candidate.state = candidateState
	candidate.sequence = event.sequence
	candidate.digest = event.resultDigest
	candidate.events[#candidate.events + 1] = deepCopy(event)
	checkpointIfRequired(candidate, 512)
	local valid, validationReason = Validator:ValidateRecord(candidate)
	if not valid then return nil, validationReason end
	archive.raids[raidUid] = candidate
	TriggerEvent(RaidReplicationCommittedEvent, deepCopy(event))
	return deepCopy(event), candidate.state
end
```

`ApplyReplicaEvent` must additionally require exact next sequence, matching UID/epoch, and matching calculated `resultDigest`. `ReplaceActiveFromSnapshot` and `ImportHistoricalSnapshot` must validate a detached candidate before one table assignment. `GetEventRange` returns only a contiguous range newer than `checkpointSequence`; otherwise return `nil, "SNAPSHOT_REQUIRED"`.

Define `deepCopy(value, seen)` and `checkpointIfRequired(record, limit)` as
private `DBRaidStore.lua` functions. Resolve `Validator` once from
`Database.GetRaidValidator()`, resolve `archive` inside each public write through
`EnsureArchive()`, and bind `RaidReplicationCommittedEvent` from
`Events.Internal` before calling the existing `Bus.TriggerEvent`.

`CreateActiveRaid` obtains a session nonce once, increments a module-local
counter, and regenerates while the candidate UID already exists locally. It
creates sequence 1 through `RAID_CREATED`, so state, digest, and the first event
are committed together.

- [ ] **Step 5: Preserve ordered feature reads without a persisted adapter**

Make `archive.order` the sole UI ordering source. `EnsureRaidByIndex(index)` resolves `order[index]` and returns `record.state, index, record`; `EnsureRaidByNid` resolves the stable `raidNid` stored inside state through a runtime-only index. Do not persist flattened copies, metatables, or aliases.

- [ ] **Step 6: Run archive tests and the existing recording suite**

```powershell
py -3 -m unittest tests.test_raid_replication_behavior tests.test_raid_recording_integrity_behavior tests.test_runtime_bootstrap_contract -v
```

Expected: all selected tests pass; unsupported beta fixtures now expect a clean archive.

- [ ] **Step 7: Commit the archive store**

```powershell
git add -f -- "Raid Management Addon/Database/SavedVariables.lua" "Raid Management Addon/Database/DB.lua" "Raid Management Addon/Database/DBRaidStore.lua" "Raid Management Addon/Database/DBRaidValidator.lua" "Raid Management Addon/Database/DBRaidQueries.lua" tests/lua/runtime_harness.lua tests/test_raid_replication_behavior.py tests/test_runtime_bootstrap_contract.py
git diff --cached --check
git commit -m "feat(database): Store raids in an atomic versioned archive"
```

---

### Task 3: Route Canonical Local Mutations Through Semantic Events

**Files:**
- Modify: `Raid Management Addon/Services/Raid/State.lua`
- Modify: `Raid Management Addon/Services/Raid/Roster.lua`
- Modify: `Raid Management Addon/Services/Raid/Attendance.lua`
- Modify: `Raid Management Addon/Services/Loot/Recording.lua`
- Modify: `Raid Management Addon/Services/Logger/Actions.lua`
- Modify: `Raid Management Addon/Services/Attendance/Actions.lua`
- Modify: `Raid Management Addon/Services/EquipInspect.lua`
- Modify: `Raid Management Addon/Database/DBRaidStore.lua`
- Modify: `tests/lua/runtime_harness.lua`
- Modify: `tests/test_raid_replication_behavior.py`
- Modify: `tests/test_raid_recording_integrity_behavior.py`

**Interfaces:**
- Consumes: `CreateActiveRaid`, `CommitAuthoritativeEvent`, `ConcludeActiveRaid`.
- Produces: every syncable active-raid mutation as one of the ten event types; no direct state mutation followed by a revision touch.
- Upsert contract: `PLAYER_UPDATED`, `BOSS_UPDATED`, and `ATTENDANCE_UPDATED` create a missing stable NID or replace its existing entity; `LOOT_UPDATED` and delete events reject missing entities.

- [ ] **Step 1: Add failing mutation coverage**

Add Python methods for `raid_replication_local_mutations` and `raid_replication_conclusion`. The fixture must record committed event types and assert this sequence:

```lua
local expected = {
	"RAID_CREATED", "PLAYER_UPDATED", "ATTENDANCE_UPDATED", "BOSS_UPDATED",
	"LOOT_ADDED", "LOOT_UPDATED", "LOOT_DELETED", "RAID_CONCLUDED",
}
assertDeepEqual(expected, committedTypes)
assertEqual("complete", store:GetRecord(raidUid).status)
assertEqual(0, #store:GetRecord(raidUid).events)
```

Assert a failed validation emits no bus event and does not change sequence or digest.

- [ ] **Step 2: Run focused mutation tests and confirm RED**

```powershell
py -3 -m unittest tests.test_raid_replication_behavior tests.test_raid_recording_integrity_behavior -v
```

Expected: new semantic-event cases fail while existing recording integrity cases remain diagnostic evidence.

- [ ] **Step 3: Convert raid lifecycle and roster ownership**

Build the complete initial state in local memory, then create it through:

```lua
local state, raidIndex, raidUid = raidStore:CreateActiveRaid({
	authorityKey = Database.GetPlayerName(),
	serverTime = currentTime,
	realm = realm,
	zone = zoneName,
	size = raidSize,
	difficulty = instanceDiff,
	players = pendingPlayers,
})
```

Replace roster writes with full stable-entity payloads:

```lua
raidStore:CommitAuthoritativeEvent(raidUid, "PLAYER_UPDATED", { player = playerRecord })
raidStore:CommitAuthoritativeEvent(raidUid, "PLAYER_DEPARTED", {
	playerNid = playerNid,
	leave = leaveTimestamp,
})
```

`Raid:End()` must commit `RAID_CONCLUDED`; its reducer closes open player and attendance intervals, sets `endTime`, marks status complete, and compacts events in the same store transaction.

- [ ] **Step 4: Convert attendance, boss, loot, logger, and inspect mutations**

Use these payload contracts:

```lua
{ attendance = completeAttendanceEntry }
{ boss = completeBossRecord }
{ loot = completeLootRecord }
{ lootNid = stableLootNid }
{ player = completePlayerRecord }
```

The build helpers may prepare candidate entities, but only reducers write canonical raid state. `Recording.Append` allocates `lootNid` from the current state, builds the row, and commits `LOOT_ADDED`; Logger edits commit `LOOT_UPDATED`; bulk deletion commits one `LOOT_DELETED` per stable NID in deterministic ascending order.

- [ ] **Step 5: Retire revision-era mutation APIs without breaking the loaded beta syncer**

Remove revision fields from state/runtime and remove every revision-era call from canonical local mutation owners. Until Task 6 replaces the unconditionally loaded beta `DBSyncer`, retain only the smallest package-private compatibility methods proven by `rg` to be reachable from `DBSyncer.lua`, `DBSyncPayload.lua`, or `DBSyncImport.lua`. Read-only methods project canonical record sequence/event state; every legacy mutation/import method fails closed without changing the archive. Add a loaded-runtime test proving routine sync callbacks do not throw and a legacy inbound transfer cannot mutate canonical state. Add no new caller. Task 6 must delete this bridge when it rewrites the syncer. Replace tests that asserted revision touches with assertions on sequence, digest, emitted event order, and legacy fail-closed behavior.

- [ ] **Step 6: Run mutation and full baseline tests**

```powershell
py -3 -m unittest tests.test_raid_replication_behavior tests.test_raid_recording_integrity_behavior -v
py -3 -m unittest discover -s tests -p "test_*.py" -q
```

Expected: focused suite passes and full suite passes with an updated test count greater than 317.

- [ ] **Step 7: Commit semantic local writes**

```powershell
git add -f -- "Raid Management Addon/Services/Raid/State.lua" "Raid Management Addon/Services/Raid/Roster.lua" "Raid Management Addon/Services/Raid/Attendance.lua" "Raid Management Addon/Services/Loot/Recording.lua" "Raid Management Addon/Services/Logger/Actions.lua" "Raid Management Addon/Services/Attendance/Actions.lua" "Raid Management Addon/Services/EquipInspect.lua" "Raid Management Addon/Database/DBRaidStore.lua" tests/lua/runtime_harness.lua tests/test_raid_replication_behavior.py tests/test_raid_recording_integrity_behavior.py
git diff --cached --check
git commit -m "refactor(database): Commit raid changes as semantic events"
```

---

### Task 4: Version-3 Wire Codec

**Files:**
- Create: `Raid Management Addon/Database/DBSyncProtocol.lua`
- Modify: `Raid Management Addon/Raid Management Addon.toc`
- Modify: `tests/lua/runtime_harness.lua`
- Modify: `tests/test_raid_replication_behavior.py`

**Interfaces:**
- Consumes: `addon.Comms.Payload`, `addon.Json`, LibDeflate only through the session owner.
- Produces: `Protocol.VERSION`, `Encode(kind, requestId, target, body)`, `Decode(message)`, `EncodeBody(body)`, and `DecodeBody(text)`.
- Message kinds: `HEAD`, `EVENT`, `RANGE_REQ`, `RANGE_DATA`, `SNAP_REQ`, `SNAP_DATA`, `OFFER`, `RESULT`.

**Closed schema:**

- Envelope `requestId` and `target` are `"-"` for broadcast `HEAD`/`EVENT`; every other kind requires visible ASCII without tabs, 1-64 bytes. The real sender still comes only from the WoW event.
- `raidUid`: visible ASCII without tabs, 1-40 bytes.
- `authorityEpoch`: integer 1-999999. `sequence` and `checkpointSequence`: integer 0-999999999 with checkpoint not greater than sequence.
- `digest`: exactly eight lowercase hexadecimal digits, colon, and canonical byte count 1-999999999.
- `HEAD`: exactly `raidUid`, `authorityEpoch`, `sequence`, `checkpointSequence`, `digest`, `status`; status is `active` or `complete`.
- `EVENT`: exactly `event`; validate its complete nested table through `DB.RaidEvents.ValidateEvent` and require `resultDigest`.
- `RANGE_REQ`: exactly `raidUid`, `authorityEpoch`, `fromSequence`, `toSequence`; both positive, ordered, and at most 512 events inclusive.
- `RANGE_DATA`: exactly `raidUid`, `authorityEpoch`, `fromSequence`, `toSequence`, `partIndex`, `partCount`, `chunk`; range rules match `RANGE_REQ`, parts are integers 1-256 with index not greater than count, and chunk is visible ASCII without tabs, 1-220 bytes.
- `SNAP_REQ`: exactly `raidUid`.
- `SNAP_DATA`: exactly `raidUid`, `authorityEpoch`, `sequence`, `partIndex`, `partCount`, `chunk`; sequence is positive, part and chunk bounds match `RANGE_DATA`.
- `OFFER`: exactly `raidUid`, `authorityEpoch`, `sequence`, `digest`, `zone`, `startTime`, `size`, `difficulty`, `lootCount`; authority epoch is 1-999999, zone is 1-128 bytes with UTF-8/high bytes allowed and C0 controls, DEL, and WoW `|` markup rejected, startTime is an integer 1-9999999999, size is 1-40, difficulty is 1-4, and lootCount is 0-10000.
- `RESULT`: exactly `outcome` plus optional `reason`; outcome is `IMPORTED`, `ALREADY_PRESENT`, `CONFLICT`, `DECLINED`, or `FAILED`, and reason when present is visible ASCII without tabs up to 96 bytes.
- Every body rejects unknown keys. `Encode` also rejects any valid body whose final envelope exceeds 255 bytes; Task 5 dynamically chooses a safe chunk length no greater than 220 after protocol preflight.

- [ ] **Step 1: Add failing protocol tests**

Add cases `raid_replication_protocol_round_trip` and `raid_replication_protocol_rejects_invalid`. Cover all eight kinds, exact version `3`, 255-byte envelope bound, unknown kind, version 2, extra fields, invalid numeric bounds, non-ASCII UID, and malformed encoded body.

- [ ] **Step 2: Confirm RED**

```powershell
py -3 -m unittest tests.test_raid_replication_behavior -v
```

Expected: the two protocol cases fail because `DBSyncProtocol.lua` is absent.

- [ ] **Step 3: Implement the codec with a closed schema**

Use a fixed tab-separated envelope:

```text
R3<TAB>KIND<TAB>requestId<TAB>target<TAB>encodedBody
```

Implement the exported entrypoints as:

```lua
Protocol.VERSION = 3

function Protocol.Encode(kind, requestId, target, body)
	if not MESSAGE_SCHEMAS[kind] then return nil, "UNKNOWN_MESSAGE_KIND" end
	local valid, reason = validateBody(kind, body)
	if not valid then return nil, reason end
	local encodedBody = assert(Protocol.EncodeBody(body))
	local message = Payload.PackFields("\t", "R3", kind, requestId or "-", target or "-", encodedBody)
	if #message > 255 then return nil, "MESSAGE_TOO_LARGE" end
	return message
end

function Protocol.Decode(message)
	local fields, count = Payload.SplitFields(message, "\t")
	if count ~= 5 or fields[1] ~= "R3" then return nil, "UNSUPPORTED_PROTOCOL" end
	local kind = fields[2]
	if not MESSAGE_SCHEMAS[kind] then return nil, "UNKNOWN_MESSAGE_KIND" end
	local body, reason = Protocol.DecodeBody(fields[5])
	if not body then return nil, reason end
	local valid, validationReason = validateBody(kind, body)
	if not valid then return nil, validationReason end
	return { kind = kind, requestId = fields[3], target = fields[4], body = body }
end
```

Schemas must enumerate allowed keys and bounds. Do not accept unknown keys or dispatch arbitrary method names.

- [ ] **Step 4: Verify GREEN and wire size**

```powershell
py -3 -m unittest tests.test_raid_replication_behavior -v
```

Expected: protocol cases pass, including representative 255-byte boundary assertions.

- [ ] **Step 5: Commit the protocol**

```powershell
git add -f -- "Raid Management Addon/Database/DBSyncProtocol.lua" "Raid Management Addon/Raid Management Addon.toc" tests/lua/runtime_harness.lua tests/test_raid_replication_behavior.py
git diff --cached --check
git commit -m "feat(sync): Add closed version-3 raid protocol"
```

---

### Task 5: Bounded Transfer Sessions, Range Recovery, And One Retry

**Files:**
- Create: `Raid Management Addon/Database/DBSyncSession.lua`
- Modify: `Raid Management Addon/Raid Management Addon.toc`
- Modify: `Raid Management Addon/Modules/Comms.lua`
- Modify: `tests/lua/runtime_harness.lua`
- Modify: `tests/test_raid_replication_behavior.py`
- Modify: `tests/test_sync_communications_behavior.py`

**Interfaces:**
- Consumes: `DB.SyncProtocol`, `Comms.QueueAddonMessage`, `Comms.QueueAddonMessages`, `Timer`, and LibDeflate addon-channel encode/decode only.
- Produces: `BeginRequest`, `AllowIncomingRequest`, `QueueTransfer`, `ReceiveChunk`, `CompleteRequest`, `CancelRequest`, `Expire`, and `SendResult`.
- `BeginRequest(requestKind, target, requestBody, expectedResponseKind, expectedMetadata, callback)` generates the bounded session-scoped request ID, protocol-encodes the final request, queues it, and stores that immutable encoded message, original callback, and expected response contract for one retry. It returns the request ID on success. `ReceiveChunk(sender, envelope)` cannot accept or replace a callback.
- Bounds: 220-byte chunk payload, 256 chunks, 56,320 encoded bytes, 65,536 decoded bytes, 64 global assemblies, 8 per sender, 30-second request TTL, 45-second assembly TTL, one retry.
- Rates: at most 6 newly accepted inbound requests per normalized sender in 30 seconds through `AllowIncomingRequest`, and at most 4 outbound requests or transfer batches per normalized target in 30 seconds. Reject over-limit work before serialization, channel encoding, store reads, or queue allocation.
- Transfer bodies use only `EncodeForWoWAddonChannel` and `DecodeForWoWAddonChannel`; never call Deflate compression or decompression. Check encoded totals before channel decoding and decoded totals before `Protocol.DecodeBody`.
- Correlation: `SNAP_REQ` accepts only `SNAP_DATA`; `RANGE_REQ` accepts only `RANGE_DATA`. The expected metadata table is copied at request creation and compares raid UID plus epoch and sequence/range fields appropriate to the response. Every chunk in one assembly must have identical immutable metadata.

- [ ] **Step 1: Add failing bounded-session cases**

Add cases for contiguous range assembly, out-of-order chunks, duplicate chunk no-op, conflicting duplicate rejection, pre-allocation limit rejection, timeout retry exactly once, second timeout terminal failure, and atomic batch enqueue. Expose them through Python methods with one case per behavior group.

- [ ] **Step 2: Confirm RED**

```powershell
py -3 -m unittest tests.test_raid_replication_behavior tests.test_sync_communications_behavior -v
```

Expected: new session cases fail; existing Comms queue safety cases pass.

- [ ] **Step 3: Implement a single session state machine**

Use only these states:

```lua
local REQUEST_PENDING = "pending"
local REQUEST_ASSEMBLING = "assembling"
local REQUEST_COMPLETE = "complete"
local REQUEST_FAILED = "failed"
```

`QueueTransfer` serializes and addon-channel-encodes before calculating chunk count, preflights every final wire message through `Protocol.Encode`, then queues the complete batch or nothing. It applies the outgoing-target rate limit before serialization. `ReceiveChunk` checks sender, request ID, expected response kind, expected immutable metadata, target, part count, part index, encoded byte total, and capacity before creating an assembly table. Completion concatenates chunks in numeric order, channel-decodes under the hard input/output bounds, and validates the structured body before invoking the original request callback.

Timeout handling must be exactly:

```lua
if request.retryCount == 0 then
	request.retryCount = 1
	request.deadline = now + REQUEST_TTL_SECONDS
	return resendRequest(request)
end
request.state = REQUEST_FAILED
return completeRequest(request, false, "TIMEOUT")
```

Define `resendRequest(request)` as the private function that requeues the
original encoded request to its original target. Define
`completeRequest(request, succeeded, reason)` as the single private terminal
path that cancels its timer, removes it from pending state, and invokes its
registered callback once.

- [ ] **Step 4: Keep Comms transport generic and bounded**

Retain the existing constant-paced queue and atomic batch preflight. Remove sync-specific request ID generation from `Comms` after `DBSyncSession` owns it; keep text encoding, sender normalization, prefix registration, and addon-message queueing.

- [ ] **Step 5: Verify focused suites**

```powershell
py -3 -m unittest tests.test_raid_replication_behavior tests.test_sync_communications_behavior -v
```

Expected: all selected tests pass, including one retry and no partial enqueue.

- [ ] **Step 6: Commit session transport**

```powershell
git add -f -- "Raid Management Addon/Database/DBSyncSession.lua" "Raid Management Addon/Raid Management Addon.toc" "Raid Management Addon/Modules/Comms.lua" tests/lua/runtime_harness.lua tests/test_raid_replication_behavior.py tests/test_sync_communications_behavior.py
git diff --cached --check
git commit -m "feat(sync): Add bounded raid transfer sessions"
```

---

### Task 6: Automatic Live Replication And Recovery

**Files:**
- Rewrite: `Raid Management Addon/Database/DBSyncer.lua`
- Modify: `Raid Management Addon/Modules/Events.lua`
- Modify: `Raid Management Addon/Database/DBRaidStore.lua`
- Modify: `Raid Management Addon/Localization/localization.en.lua`
- Modify: `Raid Management Addon/Localization/DiagnoseLog.en.lua`
- Modify: `tests/lua/runtime_harness.lua`
- Modify: `tests/test_raid_replication_behavior.py`
- Rewrite: `tests/test_sync_communications_behavior.py`

**Interfaces:**
- Consumes: store commit bus event, protocol, session, `Raid:GetMasterLooterName`, `Raid:IsMasterLooter`, real addon-message sender.
- Produces: `OnAddonMessage`, `AdvertiseHead`, `RequestMissingRange`, `RequestSnapshot`, `GetStatus`, and automatic event broadcast.

- [ ] **Step 1: Add failing two-client simulations**

Add independent in-memory client fixtures A and B with separate archives and one captured transport. Cover:

```text
A commits EVENT 1 -> B applies EVENT 1
B misses EVENT 2 -> receives EVENT 3 -> RANGE_REQ 2..3 -> converges
B has no raid -> HEAD -> SNAP_REQ -> converges
B reloads from persisted archive -> matching HEAD -> sends no request
wrong sender -> no mutation
old epoch -> no mutation
same position and different digest -> suspended
```

- [ ] **Step 2: Confirm RED**

```powershell
py -3 -m unittest tests.test_raid_replication_behavior tests.test_sync_communications_behavior -v
```

Expected: new live replication cases fail against the beta syncer.

- [ ] **Step 3: Replace beta orchestration with one dispatch table**

Register only `RMARaidSync` and dispatch decoded version-3 messages through:

```lua
local HANDLERS = {
	HEAD = handleHead,
	EVENT = handleEvent,
	RANGE_REQ = handleRangeRequest,
	RANGE_DATA = handleRangeData,
	SNAP_REQ = handleSnapshotRequest,
	SNAP_DATA = handleSnapshotData,
	OFFER = handleOffer,
	RESULT = handleResult,
}
```

`OnAddonMessage` must normalize the event sender, reject self, decode before allocation, confirm current group membership, and pass the real sender separately from payload data. Live `EVENT` accepts only `Raid:GetMasterLooterName()`.

- [ ] **Step 4: Implement event-driven recovery**

On authoritative commit, broadcast one `EVENT`. Advertise `HEAD` on addon load, raid creation, roster change, and zone change. Replica comparison must be:

```lua
if samePositionAndDigest(localHead, remoteHead) then return true end
if sameRaidAndEpoch(localHead, remoteHead) and canRequestRange(localHead, remoteHead) then
	return requestRange(remoteSender, localHead.sequence + 1, remoteHead.sequence)
end
return requestSnapshot(remoteSender, remoteHead.raidUid)
```

Define `samePositionAndDigest`, `sameRaidAndEpoch`, and `canRequestRange` as
private pure comparisons in `DBSyncer.lua`; define `requestRange` and
`requestSnapshot` as the only targeted recovery senders and route both through
`DBSyncSession.BeginRequest`.

There is no persistent timer, periodic full sync, per-event ACK, or per-chunk ACK.

- [ ] **Step 5: Expose essential status and optional diagnostics**

`GetStatus()` returns only `synchronized`, `recovering`, `handover`, `transferring_history`, `suspended`, or `failed` plus a localized reason key. Detailed request/epoch/sequence/digest/chunk/retry data is emitted only when `Options.IsDebugEnabled()` is true.

Delete the temporary revision/import compatibility bridge retained by Task 3 as soon as the version-3 syncer no longer loads or calls the beta payload/import owners.

- [ ] **Step 6: Verify live replication**

```powershell
py -3 -m unittest tests.test_raid_replication_behavior tests.test_sync_communications_behavior -v
```

Expected: all live, reload, late-join, invalid-sender, and conflict simulations pass.

- [ ] **Step 7: Commit live replication**

```powershell
git add -f -- "Raid Management Addon/Database/DBSyncer.lua" "Raid Management Addon/Modules/Events.lua" "Raid Management Addon/Database/DBRaidStore.lua" "Raid Management Addon/Localization/localization.en.lua" "Raid Management Addon/Localization/DiagnoseLog.en.lua" tests/lua/runtime_harness.lua tests/test_raid_replication_behavior.py tests/test_sync_communications_behavior.py
git diff --cached --check
git commit -m "feat(sync): Replicate active raids from Master Looter"
```

---

### Task 7: Master Looter Handover

**Files:**
- Modify: `Raid Management Addon/Database/DBSyncer.lua`
- Modify: `Raid Management Addon/Database/DBRaidStore.lua`
- Modify: `tests/lua/runtime_harness.lua`
- Modify: `tests/test_raid_replication_behavior.py`

**Interfaces:**
- Consumes: peer `HEAD`, range/snapshot recovery, `Raid:GetMasterLooterName`.
- Produces: bounded runtime staging during handover, `Store:PromoteAuthority(raidUid, recoveredSequence)`, epoch increment after recovery, and conflict suspension.

- [ ] **Step 1: Add failing handover cases**

Cover previous authority available, previous authority unavailable with highest valid peer, no peer with valid local state, staged local loot replay, old authority rejection immediately after game role change, and equal UID/epoch/sequence with divergent digest suspension.

- [ ] **Step 2: Confirm RED**

```powershell
py -3 -m unittest tests.test_raid_replication_behavior -v
```

Expected: handover cases fail because the new authority publishes before selecting a base.

- [ ] **Step 3: Implement the bounded handover state**

Use one runtime record:

```lua
module._handover = {
	raidUid = raidUid,
	previousAuthority = previousAuthority,
	newAuthority = newAuthority,
	startedAt = GetTime(),
	heads = {},
	staged = {},
	maxStaged = 64,
}
```

Reject the prior sender as soon as `GetMasterLooterName()` changes. Prefer its valid head only as recovery data; otherwise choose highest sequence. A tie with different digests suspends. After recovery, atomically increment `authorityEpoch`, reset the active event range checkpoint to the recovered sequence, replay staged semantic payloads in order, then advertise the new head. Physical loot processing remains independent from session recovery.

- [ ] **Step 4: Verify handover and regression tests**

```powershell
py -3 -m unittest tests.test_raid_replication_behavior tests.test_loot_distribution_hardening_behavior -v
```

Expected: handover and loot distribution suites pass.

- [ ] **Step 5: Commit handover**

```powershell
git add -f -- "Raid Management Addon/Database/DBSyncer.lua" "Raid Management Addon/Database/DBRaidStore.lua" tests/lua/runtime_harness.lua tests/test_raid_replication_behavior.py
git diff --cached --check
git commit -m "feat(sync): Recover safely across Master Looter handover"
```

---

### Task 8: Consent-Gated Historical Snapshot Sharing

**Files:**
- Modify: `Raid Management Addon/Database/DBSyncer.lua`
- Modify: `Raid Management Addon/Database/DBRaidStore.lua`
- Modify: `Raid Management Addon/Controllers/Logger.lua`
- Modify: `Raid Management Addon/EntryPoints/SlashEvents.lua`
- Modify: `Raid Management Addon/UI/LootHistory.xml`
- Modify: `Raid Management Addon/Localization/localization.en.lua`
- Modify: `Raid Management Addon/Localization/DiagnoseLog.en.lua`
- Modify: `tests/lua/runtime_harness.lua`
- Modify: `tests/test_raid_replication_behavior.py`
- Rewrite: `tests/test_single_raid_sharing_contract.py`

**Interfaces:**
- Consumes: immutable completed snapshot, targeted session transfer, group membership.
- Produces: `OfferHistoricalRaid(raidUid, target)`, `AcceptHistoricalOffer(sender, offerId)`, `DeclineHistoricalOffer(sender, offerId)`.

- [ ] **Step 1: Add failing history cases**

Cover offer summary only before consent, decline no-op, acceptance import visible through `DBRaidQueries`, source UID/digest deduplication, divergent digest preservation, local variant-key reload, partial transfer no mutation, 30-second retry within a 65-second accepted lifetime, sender leaving the group, closed `RESULT` state/outcome correlation, safe display text, and visible terminal feedback on both peers.

- [ ] **Step 2: Confirm RED**

```powershell
py -3 -m unittest tests.test_raid_replication_behavior tests.test_single_raid_sharing_contract -v
```

Expected: history cases fail until old request/push behavior is replaced.

- [ ] **Step 3: Implement the exact consent flow**

`OFFER` contains only offer ID, target, raid UID, authority epoch, sequence, digest, zone, start time, size, difficulty, and loot count. The epoch is required for exact `SNAP_DATA` correlation. Acceptance validates the stored offer against sender and expiry, then sends targeted `SNAP_REQ`. The receiver imports only after complete snapshot validation:

```lua
local outcome, reason, importedIndex = raidStore:ImportHistoricalSnapshot(snapshot)
session:SendResult(sender, requestId, outcome, reason)
if outcome == "IMPORTED" or outcome == "CONFLICT" then
	TriggerEvent(LoggerSelectRaidEvent, importedIndex)
end
```

Import outcomes are `IMPORTED`, `ALREADY_PRESENT`, or `CONFLICT`. `CONFLICT`
means the divergent completed snapshot was preserved under a deterministic
local archive key annotated with `sourceRaidUid` and `conflictOfRaidUid`; its
source UID remains the wire identity and it is excluded from the derived
runtime raidNid index. Both provenance fields are stripped from wire snapshots,
remote provenance is discarded before validation, and the locally reconstructed
final record is revalidated immediately before assignment. Reimporting the same variant is idempotent. The existing
format-v1 archive and order persist both rows across reload without adding a
SavedVariable. Offers and transfer sessions remain runtime-only. The receiver's
incoming consent offer expires after 30 seconds, while the sender retains only
its outgoing correlation for 65 seconds so a Session retry at 30 seconds plus
jitter can still be served. Expiration uses `expiresAt <= now`, so receiver
acceptance at exactly 30 seconds is rejected. Accepted sender/receiver state lasts 65 seconds.
`RESULT` accepts `DECLINED` only for an offered offer ID and all other outcomes
only for the exact accepted request ID.

- [ ] **Step 4: Update Logger UI and slash contract**

Keep static XML layout and Lua-owned actions. The Share dialog selects one completed raid and one current group recipient. Remove manual `require`, `push`, and `sync` commands; retain `/rma logger share` as the UI entrypoint. Automatic current-raid recovery is shown as status, not as a Recover button.

- [ ] **Step 5: Verify the requested A-to-B history path**

The harness must instantiate two isolated peers with the real Store, Protocol,
Session, and Syncer and execute A offer -> B accept -> A handles SNAP_REQ -> A
queues the real chunk transfer -> B assembles/imports/sends RESULT -> A handles
RESULT. Drop the first SNAP_REQ, retry at 30 seconds, and deliver before 60;
assert the row appears through the real query projection. Do not construct
SNAP_DATA directly in this end-to-end test.

```powershell
py -3 -m unittest tests.test_raid_replication_behavior tests.test_single_raid_sharing_contract -v
```

Expected: all sharing and Loot History visibility cases pass.

- [ ] **Step 6: Commit historical sharing**

```powershell
git add -f -- "Raid Management Addon/Database/DBSyncer.lua" "Raid Management Addon/Database/DBRaidStore.lua" "Raid Management Addon/Controllers/Logger.lua" "Raid Management Addon/EntryPoints/SlashEvents.lua" "Raid Management Addon/UI/LootHistory.xml" "Raid Management Addon/Localization/localization.en.lua" "Raid Management Addon/Localization/DiagnoseLog.en.lua" tests/lua/runtime_harness.lua tests/test_raid_replication_behavior.py tests/test_single_raid_sharing_contract.py
git diff --cached --check
git commit -m "feat(sync): Share completed raids with recipient consent"
```

---

### Task 9: Remove Beta Synchronization And Configuration Surface

**Files:**
- Delete: `Raid Management Addon/Database/DBRaidMigrations.lua`
- Delete: `Raid Management Addon/Database/DBSyncMetrics.lua`
- Delete: `Raid Management Addon/Database/DBSyncPayload.lua`
- Delete: `Raid Management Addon/Database/DBSyncImport.lua`
- Modify: `Raid Management Addon/Raid Management Addon.toc`
- Modify: `Raid Management Addon/Database/DB.lua`
- Modify: `Raid Management Addon/Database/DBSyncer.lua`
- Modify: `Raid Management Addon/Controllers/Config.lua`
- Modify: `Raid Management Addon/UI/Config.xml`
- Modify: `Raid Management Addon/Localization/localization.en.lua`
- Modify: `Raid Management Addon/Localization/DiagnoseLog.en.lua`
- Modify: `tests/test_config_xml_contract.py`
- Modify: `tests/test_runtime_bootstrap_contract.py`
- Modify: `tests/test_sync_communications_behavior.py`
- Modify: `tests/test_single_raid_sharing_contract.py`

**Interfaces:**
- Consumes: completed version-3 implementation.
- Produces: one synchronization architecture and one option surface: automatic current raid, consent history, debug diagnostics.

- [ ] **Step 1: Add negative architecture assertions**

Assert that the TOC and runtime contain no beta owners or symbols:

```python
for retired in (
    "DBRaidMigrations.lua",
    "DBSyncMetrics.lua",
    "DBSyncPayload.lua",
    "DBSyncImport.lua",
    "MODE_PUSH",
    "MODE_REQ",
    "MODE_SYNC",
    "persistentSync",
    "RequestLoggerReq",
    "BroadcastLoggerPush",
    "RequestLoggerSync",
):
    self.assertNotIn(retired, combined_runtime_source)
```

- [ ] **Step 2: Run architecture tests and confirm RED**

```powershell
py -3 -m unittest tests.test_config_xml_contract tests.test_runtime_bootstrap_contract tests.test_sync_communications_behavior tests.test_single_raid_sharing_contract -v
```

Expected: negative assertions fail while beta files and controls remain.

- [ ] **Step 3: Delete retired owners and references**

Remove the four files, their TOC entries, module bindings, option defaults, controls, diagnostics, slash actions, and tests that assert beta behavior. Do not replace metrics with another metrics module; debug traces in `DBSyncer` and `DBSyncSession` are sufficient.

- [ ] **Step 4: Validate TOC, Lua 5.1, XML, and retired symbols**

```powershell
py -3 "..\..\.agents\skills\wow-addon-dev-wotlk-v335a\scripts\validate_toc.py" "Raid Management Addon/Raid Management Addon.toc"
py -3 "..\..\.agents\skills\wow-addon-dev-wotlk-v335a\scripts\lint_lua51.py" "Raid Management Addon"
py -3 "..\..\.agents\skills\wow-addon-dev-wotlk-v335a\scripts\scan_xpcall.py" "Raid Management Addon"
rg -n "<Scripts>|<On[A-Za-z]+>" "Raid Management Addon/UI" -g "*.xml"
rg -n "DBRaidMigrations|DBSyncMetrics|DBSyncPayload|DBSyncImport|MODE_PUSH|MODE_REQ|MODE_SYNC|persistentSync|RequestLoggerReq|BroadcastLoggerPush|RequestLoggerSync" "Raid Management Addon" tests -g "*.lua" -g "*.xml" -g "*.toc" -g "*.py"
```

Expected: validators exit 0; XML and retired-symbol searches return no matches.

- [ ] **Step 5: Run the full suite**

```powershell
py -3 -m unittest discover -s tests -p "test_*.py" -q
```

Expected: all tests pass with a count greater than 317.

- [ ] **Step 6: Commit beta removal**

```powershell
git add -A -- "Raid Management Addon" tests
git diff --cached --check
git commit -m "refactor(sync): Remove beta database synchronization"
```

---

### Task 10: Final Verification And Two-Client Smoke Gate

**Files:**
- Verify: `docs/superpowers/specs/2026-07-16-raid-data-replication-design.md`
- Create: `docs/superpowers/smoke/2026-07-16-raid-data-replication.md`

**Interfaces:**
- Consumes: completed implementation and two WotLK 3.3.5a clients A and B.
- Produces: reproducible validation evidence and an explicit positive or blocked integration gate.

- [ ] **Step 1: Run repository validation from a clean worktree**

```powershell
py -3 -m unittest discover -s tests -p "test_*.py" -q
if (Get-Command stylua -ErrorAction SilentlyContinue) { stylua --check "Raid Management Addon" }
if (Get-Command luacheck -ErrorAction SilentlyContinue) { luacheck "Raid Management Addon" }
py -3 "..\..\.agents\skills\wow-addon-dev-wotlk-v335a\scripts\validate_toc.py" "Raid Management Addon/Raid Management Addon.toc"
py -3 "..\..\.agents\skills\wow-addon-dev-wotlk-v335a\scripts\lint_lua51.py" "Raid Management Addon"
py -3 "..\..\.agents\skills\wow-addon-dev-wotlk-v335a\scripts\scan_xpcall.py" "Raid Management Addon"
git diff --check
git status --short --branch
```

Expected: every available command exits 0; record unavailable executables honestly instead of claiming they ran.

- [ ] **Step 2: Perform the live current-raid smoke**

Record exact client/version, character names, timestamp, and result for:

```text
A becomes Master Looter and creates a raid.
A records a boss and loot; B receives both without opening RMA windows.
B reloads; matching data remains and only a missing range is requested when one event is deliberately withheld.
A third late-join state or a reset B bootstraps by snapshot.
Master Looter changes A -> B; B recovers, increments epoch, and records new loot.
A converges to B; old A-authority messages are rejected.
Raid ends; both clients retain the completed snapshot and no active event ledger.
```

- [ ] **Step 3: Perform the required historical sharing smoke**

Record pass/fail for:

```text
Current Raid may leave B with the live completed copy. Therefore, while B is
offline or reset, A creates and completes a second raid. Record that raid's
source `raidUid` and explicitly verify it is absent from B before the offer.
A opens Loot History, selects that second completed raid, and offers it to B.
B declines; B's database remains unchanged.
A offers again; B accepts.
B receives a terminal success and the raid appears once in Loot History.
A offers the identical second raid again; B reports `ALREADY_PRESENT` and creates no duplicate.
Interrupt one transfer; B's SavedVariables remain unchanged.
Reload both clients; completed raids persist and offers/transfers do not.
```

- [ ] **Step 4: Write the smoke artifact**

Create `docs/superpowers/smoke/2026-07-16-raid-data-replication.md` with sections `Environment`, `Automated Validation`, `Current Raid`, `Handover`, `Historical Offer`, `Reload`, `Failures`, and `Integration Gate`. Set `Integration Gate: POSITIVE` only if every required live step passed; otherwise set `Integration Gate: BLOCKED` and include the exact failing step and Lua error or observed state.

- [ ] **Step 5: Review final architecture for unnecessary complexity**

Invoke `detect-over-engineering` on the branch diff. Required outcome before integration: no Warning or Critical finding; remove single-use wrappers, unused configuration, duplicate import paths, and speculative strategies while retaining bounds, validation, retry, and diagnostics.

- [ ] **Step 6: Commit verification evidence**

```powershell
git add -f -- docs/superpowers/smoke/2026-07-16-raid-data-replication.md docs/superpowers/specs/2026-07-16-raid-data-replication-design.md
git diff --cached --check
git commit -m "test(sync): Record raid replication smoke results"
```

- [ ] **Step 7: Enforce the integration gate**

If the artifact says `BLOCKED`, stop on `codex/single-raid-history-sharing` and do not merge, cherry-pick, rebase, or copy changes into `codex/loot-bans-optimization`. If it says `POSITIVE`, present the verified branch and commit list to the user before any integration action.
