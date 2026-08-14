# Local Award Ownership and Snapshot Coalescing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Record each local Leader/Master Looter award once and let an ordinary replica finish one active-raid snapshot before catching up to newer events without reaching `RATE_LIMIT`.

**Architecture:** Add one local-owner gate inside the existing `RecordDistributionAward` owner; remote Master Looter facts retain the current persistence path. For ordinary replica snapshots only, retain the newest compatible follow-up position instead of cancelling the in-flight request, then use the existing range recovery and snapshot fallback after installation.

**Tech Stack:** WoW 3.3.5a, Interface `30300`, Lua 5.1, Python `unittest`, the existing Lua runtime harness, `luacheck`, StyLua, and the project WotLK validators.

## Global Constraints

- Work only in the isolated `codex/single-raid-history-sharing` worktree.
- Runtime code must remain Lua 5.1-compatible and use only WotLK 3.3.5a APIs.
- Keep raid schema `6`, sync protocol `3`, wire payloads, and `RMA_*` SavedVariables unchanged.
- Do not raise or disable communication rate limits.
- Do not add time-window/content-based loot deduplication or a new transaction identifier.
- Preserve split authority: a Raid Leader must still persist an award sent by a different Master Looter.
- Do not change Raid Leader reentry, authority handover, history offers, or their fail-closed barriers.
- The HOLD `record_finalize_failed` warning is outside this plan.
- Preserve unrelated changes in `.superpowers/sdd/task-4-report.md` and `.planning/`.
- Do not integrate into `codex/loot-bans-optimization` until the two-client in-game smoke is positive.

---

## File Structure

- Modify `Raid Management Addon/Services/Loot/Service.lua`: consume a valid distribution fact without a second write when its sender is the local Raid Leader.
- Modify `Raid Management Addon/Database/DBSyncer.lua`: coalesce newer compatible positions onto one ordinary replica snapshot and perform one range catch-up after installation.
- Modify `tests/lua/runtime_harness.lua`: extend production-chain loot coverage and add a held-snapshot event-burst regression.
- Reuse the already registered split-authority regression for local-owner assertions, avoiding a second copy of its production fixture.
- Modify `tests/test_sync_communications_behavior.py`: register the held-snapshot convergence regression.
- Create no runtime module, persisted field, protocol message, or configuration option.

### Task 1: Give the Local Attribution Flow Sole Write Ownership

**Files:**
- Modify: `Raid Management Addon/Services/Loot/Service.lua:1600-1672`
- Test: `tests/lua/runtime_harness.lua:16871-17188`

**Interfaces:**
- Consumes: `module:RecordDistributionAward(row, sessionId, expectedRaidUid)`, `Database.GetPlayerName()`, `Raid:IsRaidLeader()`, and normalized `facts.sender`.
- Produces: the existing `(recorded, reason, retryable, facts)` return contract; a valid locally owned fact returns `true, nil, false, facts` without calling `LogTradeOnlyLoot`.
- Preserves: remote Master Looter facts continue through `LogTradeOnlyLoot(..., "DISTRIBUTION_AWARD", ..., facts.awardId)`.

- [ ] **Step 1: Extend the production-chain case with local orderings**

Inside `raid_live_sync_split_loot_authority_records_trade_award_once`, widen the
fixture authority predicate so the real Loot Service can validate both the
remote Master Looter and the local Leader:

```lua
	leaderRaid.IsLootAuthority = function(_, sender)
		local normalized = type(sender) == "string" and (string.match(sender, "^([^%-]+)") or sender) or nil
		return normalized == "Master" or normalized == "Leader"
	end
```

Append these assertions immediately before the case's existing `PASS` print,
after resetting `leader.acceptDistributionAwards = true`:

```lua
	local loot = leaderAddon.Services.Loot
	local beforeLocalAwards = #leader.store.record.state.loot
	local localRow = {
		sender = "Leader",
		itemLink = "item:19200",
		winnerName = "Winner",
		rollType = 4,
		rollValue = 94,
		count = 1,
		reason = "master_loot:AT:local:1",
	}
	local firstNid = loot:LogTradeOnlyLoot(
		localRow.itemLink, localRow.winnerName, localRow.rollType, localRow.rollValue, localRow.count,
		"CHAT_MSG_LOOT", nil, nil, "RS:local:1"
	)
	assertTrue(tonumber(firstNid) > 0, "local attribution did not create its canonical row")
	assertTrue(loot:RecordDistributionAward(localRow, "Leader:session:1"),
		"local distribution fact was not consumed")
	assertEqual(beforeLocalAwards + 1, #leader.store.record.state.loot,
		"slot/chat-first local distribution created a second row")

	localRow.itemLink = "item:19201"
	localRow.reason = "master_loot:AT:local:2"
	assertTrue(loot:RecordDistributionAward(localRow, "Leader:session:2"),
		"distribution-first local fact was not consumed")
	assertEqual(beforeLocalAwards + 1, #leader.store.record.state.loot,
		"distribution-first local fact wrote before local attribution")
	local secondNid = loot:LogTradeOnlyLoot(
		localRow.itemLink, localRow.winnerName, localRow.rollType, 55, localRow.count,
		"CHAT_MSG_LOOT", nil, nil, "RS:local:2"
	)
	assertTrue(tonumber(secondNid) > 0, "distribution-first local attribution did not write")
	assertEqual(beforeLocalAwards + 2, #leader.store.record.state.loot,
		"two distinct local awards did not produce exactly two rows")
```

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```powershell
python -m unittest tests.test_raid_replication_behavior.RaidReplicationBehaviorTests.test_split_raid_leader_master_looter_records_and_replicates_trade_award_once -v
```

Expected: FAIL because the valid local `DISTRIBUTION_AWARD` calls
`LogTradeOnlyLoot` with `session|AT:*` and creates an extra canonical row.

- [ ] **Step 3: Add the minimal local-owner gate**

In `RecordDistributionAward`, retain all existing fact, recovery, capability,
and loot-authority validation. Immediately after the existing
`CanCommitRaidHistory`/`IsLootAuthority` check and before `LogTradeOnlyLoot`, add:

```lua
		local localPlayerName = Database.GetPlayerName and NormalizeName(Database.GetPlayerName(), true) or nil
		local distributionSender = NormalizeName(facts.sender, true)
		if
			raidService.IsRaidLeader
			and raidService:IsRaidLeader() == true
			and localPlayerName
			and distributionSender == localPlayerName
		then
			return true, nil, false, facts
		end
```

Do not change `LogTradeOnlyLoot`, `Recording.FindTradeOnlyFallback`, the
distribution payload, or retry limits.

- [ ] **Step 4: Run focused ownership tests and verify GREEN**

Run:

```powershell
python -m unittest tests.test_raid_replication_behavior.RaidReplicationBehaviorTests.test_split_raid_leader_master_looter_records_and_replicates_trade_award_once -v
python -m unittest tests.test_loot_distribution_hardening_behavior -v
```

Expected: both focused ownership cases and the Loot Distribution Hardening
module pass. The local case contains one row per award; the remote Master Looter
case still commits and replicates `DISTRIBUTION_AWARD` once.

- [ ] **Step 5: Review and commit Task 1**

Run `git diff --check`, confirm that Task 1 changes only the Loot Service and
Lua runtime harness, then commit:

```powershell
git add -- "Raid Management Addon/Services/Loot/Service.lua" `
  "tests/lua/runtime_harness.lua"
git commit -m "fix(sync-04): keep local award ownership singular"
```

Expected: one atomic runtime/test commit; no protocol, schema, store, or rate
limit changes.

### Task 2: Coalesce Newer Events Behind an In-Flight Replica Snapshot

**Files:**
- Modify: `Raid Management Addon/Database/DBSyncer.lua:423-513,581-641`
- Test: `tests/lua/runtime_harness.lua:13634-14220,14959-15012`
- Test: `tests/test_sync_communications_behavior.py:25-31`

**Interfaces:**
- Consumes: the existing recovery table, `Session:BeginRequest`, `requestRange`, `finishRecovery`, and snapshot validation/install paths.
- Produces: `recovery.followUp`, a runtime-only newest compatible recovery position retained while an ordinary `SNAP_REQ` is active.
- Preserves: handover and reentry recoveries, digest-conflict suspension, range validation, full-snapshot fallback, session limits, protocol, and persisted state.

- [ ] **Step 1: Add the failing held-snapshot burst case**

Add this case immediately after the local `countKind` helper that follows
`raid_live_sync_snapshot_bootstrap` in `tests/lua/runtime_harness.lua`:

```lua
function cases.raid_live_sync_snapshot_coalesces_newer_event_burst()
	local network = newLiveReplicationNetwork()
	network.holdTransfers = true
	local leader = installLiveReplicationClient(network, "Leader", makeLiveRecord(2))
	local member = installLiveReplicationClient(network, "Member", nil)

	assertTrue(leader.syncer:AdvertiseHead(), "leader did not advertise bootstrap HEAD")
	local heldSnapshot = assert(network.heldTransfers[1], "initial snapshot response was not held")
	assertEqual(1, countKind(member.requests, "SNAP_REQ"), "bootstrap did not start one snapshot")

	for sequence = 3, 8 do
		assertTrue(leader.store:Commit(makeLiveEvent(sequence)),
			"leader could not commit burst event " .. tostring(sequence))
	end
	assertEqual(1, countKind(member.requests, "SNAP_REQ"),
		"newer events replaced the in-flight snapshot")

	network.holdTransfers = false
	assertTrue(network:deliver(
		heldSnapshot.sender, heldSnapshot.prefix, heldSnapshot.wire, "WHISPER", heldSnapshot.target
	), "held snapshot was not accepted")
	assertEqual(1, countKind(member.requests, "RANGE_REQ"),
		"snapshot completion did not request one catch-up range")
	assertEqual(leader.store.record.sequence, member.store.record.sequence,
		"member sequence did not converge after the burst")
	assertEqual(leader.store.record.digest, member.store.record.digest,
		"member digest did not converge after the burst")
	local status, reason = member.syncer:GetStatus()
	assertEqual("synchronized", status, "member did not finish synchronized")
	assertEqual("UP_TO_DATE", reason, "member retained a recovery failure")
	print("PASS raid_live_sync_snapshot_coalesces_newer_event_burst")
end
```

The existing live network deliberately holds `SNAP_DATA` while six authoritative
events arrive, reproducing more operations than the real session's limit of
four per target. It then releases only the original response.

- [ ] **Step 2: Register the focused Python regression**

Add this method beside `test_late_join_bootstraps_by_snapshot` in
`tests/test_sync_communications_behavior.py`:

```python
def test_snapshot_bootstrap_coalesces_newer_event_burst(self) -> None:
    self.assert_case("raid_live_sync_snapshot_coalesces_newer_event_burst")
```

- [ ] **Step 3: Run the focused test and verify RED**

Run:

```powershell
python -m unittest tests.test_sync_communications_behavior.SyncCommunicationsBehaviorTests.test_snapshot_bootstrap_coalesces_newer_event_burst -v
```

Expected: FAIL because every newer event cancels the held snapshot and starts a
new `SNAP_REQ`, so the request-count assertion exceeds one and the originally
held response no longer owns a live request.

- [ ] **Step 4: Coalesce only compatible ordinary replica snapshots**

Add this helper immediately before `admitRecovery` in `DBSyncer.lua`:

```lua
local function coalesceReplicaSnapshot(pending, recovery)
	if
		pending.kind ~= "SNAP_REQ"
		or recovery.kind ~= "SNAP_REQ"
		or pending.handover
		or pending.reentry
		or recovery.handover
		or recovery.reentry
		or pending.sender ~= recovery.sender
		or pending.raidUid ~= recovery.raidUid
		or pending.authorityEpoch ~= recovery.authorityEpoch
	then
		return false
	end
	local latest = pending.followUp or pending
	if recovery.sequence > latest.sequence then
		pending.followUp = recovery
	end
	return true
end
```

Insert this check inside `admitRecovery`, immediately before its existing
newer-sequence supersession branch:

```lua
		if coalesceReplicaSnapshot(pending, recovery) then
			return true, "RECOVERY_PENDING"
		end
```

Leave the existing monotonic supersession branch in place for non-coalesced
range, handover, reentry, different-identity, and other recovery cases.

- [ ] **Step 5: Preserve digest-conflict suspension for the retained position**

Update `rejectInflightDigestConflict` so it checks both the in-flight position
and its retained follow-up:

```lua
local function samePositionWithDifferentDigest(expected, actual)
	return expected
		and expected.sequence == actual.sequence
		and expected.digest ~= actual.digest
end

local function rejectInflightDigestConflict(sender, remotePosition)
	local recovery = module._recovery
	if
		recovery
		and recovery.sender == sender
		and recovery.raidUid == remotePosition.raidUid
		and recovery.authorityEpoch == remotePosition.authorityEpoch
		and (
			samePositionWithDifferentDigest(recovery, remotePosition)
			or samePositionWithDifferentDigest(recovery.followUp, remotePosition)
		)
	then
		releaseRecovery(recovery, "DIGEST_CONFLICT", true)
		setStatus(STATUS_SUSPENDED, "DIGEST_CONFLICT")
		return true
	end
	return false
end
```

Do not weaken existing UID, epoch, sender, sequence, or digest checks.

- [ ] **Step 6: Catch up once after installing the requested snapshot**

In the successful `requestSnapshot` callback, capture the follow-up before
finishing the current recovery, then request its missing range only after the
snapshot is valid and installed:

```lua
			local followUp = recovery.followUp
			local finished = finishRecovery(recovery, replaced ~= nil, replaceReason)
			if
				replaced ~= nil
				and followUp
				and followUp.sequence > snapshot.sequence
			then
				return requestRange(
					followUp.sender,
					snapshot.sequence + 1,
					followUp.sequence,
					followUp
				)
			end
			return finished
```

The existing `requestRange` callback remains responsible for validated atomic
application and its existing snapshot fallback when the ledger range is
unavailable. Do not buffer event payloads or add timers.

- [ ] **Step 7: Run focused sync tests and verify GREEN**

Run:

```powershell
python -m unittest \
  tests.test_sync_communications_behavior.SyncCommunicationsBehaviorTests.test_snapshot_bootstrap_coalesces_newer_event_burst \
  tests.test_sync_communications_behavior.SyncCommunicationsBehaviorTests.test_late_join_bootstraps_by_snapshot \
  tests.test_sync_communications_behavior.SyncCommunicationsBehaviorTests.test_real_session_newer_conclusion_supersedes_pending_range \
  tests.test_sync_communications_behavior.SyncCommunicationsBehaviorTests.test_real_store_pending_head_digest_conflict_cancels_recovery \
  tests.test_raid_replication_behavior.RaidReplicationBehaviorTests.test_authority_change_cancels_a_returning_leaders_pending_snapshot -v
```

Expected: all five pass. Ordinary bootstrap coalesces; range supersession,
reentry cancellation, and digest-conflict suspension retain their previous
contracts.

- [ ] **Step 8: Run the complete verification once**

Run:

```powershell
python -m unittest tests.test_loot_distribution_hardening_behavior -v
python -m unittest tests.test_raid_replication_behavior -v
python -m unittest tests.test_sync_communications_behavior -v
python -m unittest discover -s tests -p "test_*.py" -v
py -3 "C:\Users\ferra\Downloads\RMA-Raid Management Addon\.agents\skills\wow-addon-dev-wotlk-v335a\scripts\validate_toc.py" "Raid Management Addon\Raid Management Addon.toc"
py -3 "C:\Users\ferra\Downloads\RMA-Raid Management Addon\.agents\skills\wow-addon-dev-wotlk-v335a\scripts\lint_lua51.py" "Raid Management Addon"
py -3 "C:\Users\ferra\Downloads\RMA-Raid Management Addon\.agents\skills\wow-addon-dev-wotlk-v335a\scripts\scan_xpcall.py" "Raid Management Addon"
rg -n "<Scripts>|<On[A-Za-z]+>" "Raid Management Addon\UI" -g "*.xml"
luacheck "Raid Management Addon" --exclude-files "Raid Management Addon/Libs/**"
stylua --check -- "Raid Management Addon/Services/Loot/Service.lua" "Raid Management Addon/Database/DBSyncer.lua" "tests/lua/runtime_harness.lua"
git diff --check
```

Expected: the full Python suite and Lua 5.1, TOC, `xpcall`, luacheck, and diff
checks pass. The XML search returns no matches (exit `1`, which is success for
this policy). Report existing focused StyLua/EOL or unrelated luacheck baselines
honestly; do not bulk-format unrelated code.

- [ ] **Step 9: Review scope and commit Task 2**

Confirm that the complete runtime diff is limited to `Service.lua` and
`DBSyncer.lua`, with the Lua harness and sync Python registration, and that protocol, schema,
SavedVariables, rate-limit constants, history offers, reentry, and handover are
unchanged. Then commit Task 2:

```powershell
git add -- "Raid Management Addon/Database/DBSyncer.lua" `
  "tests/lua/runtime_harness.lua" `
  "tests/test_sync_communications_behavior.py"
git commit -m "fix(sync-04): coalesce active replica snapshot catch-up"
```

Expected: one atomic runtime/test commit.

---

## Post-Implementation Smoke Gate

After independent task review and final code-quality review:

1. Re-run the extended ownership regression and the new snapshot regression from fresh command output.
2. Deploy the verified addon from this isolated worktree to both game clients and verify source/destination hashes.
3. Do not edit SavedVariables while either WoW process is running.
4. B joins before A; A becomes Raid Leader and creates the authoritative raid.
5. A is also Master Looter and awards at least three items while B bootstraps.
6. Each award appears once in A's Loot History; B receives the raid and converges without `RATE_LIMIT`.
7. Repeat one award with a different Master Looter and verify the Raid Leader and B each receive one row.

Do not integrate into `codex/loot-bans-optimization` until the user reports this smoke as positive.
