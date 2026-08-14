# Recovery-First Raid Leader Handover Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace unsafe canonical-event staging during Raid Leader handover with recovery-first promotion, bounded domain-owned facts, and one local authority-transition warning for the old and new Raid Leaders.

**Architecture:** `DBRaidStore` rejects canonical writes while `DBSyncer` is recovering and promotes only the recovered record. `DBSyncer` publishes one internal recovery-finished notification; the Raid service explicitly orders roster refresh, boss replay, Loot service replay, and the optional automatic conclusion retry. Boss and Group Loot queues contain stable pre-NID facts only; Master Loot awards reuse the existing retry.

**Tech Stack:** WoW WotLK 3.3.5a build 12340, Interface 30300, Lua 5.1.5, RMA event bus, Python `unittest`, Lua runtime harness.

## Global Constraints

- Work only in `C:\Users\ferra\Downloads\RMA-Raid Management Addon\.worktrees\single-raid-history-sharing` on `codex/single-raid-history-sharing`.
- Preserve the unrelated `.superpowers/sdd/task-4-report.md` modification; never stage or edit it.
- Do not integrate into `codex/loot-bans-optimization` until the two-client in-game smoke is positive.
- Keep `RMA_*` SavedVariables and the version-3 addon-message wire format unchanged.
- Keep active-raid authority on the Raid Leader in both Master Loot and Group Loot; the Master Looter retains loot-operation permissions only.
- Historical raids remain offer-and-consent only, including imports with `revision = 0`.
- Use Lua 5.1 syntax and WotLK 3.3.5a APIs only; no Ace, Retail APIs, polling `OnUpdate`, or vendored-library edits.
- Runtime code, comments, localized English strings, and diagnostics remain ASCII.
- Do not introduce a generic database queue, NID rebaser, merge engine, new SavedVariables schema, or new wire message.
- Run each task test red before production edits, green after the minimal implementation, then commit only that task's files.

---

## File Map

- Modify `Raid Management Addon/Database/DBRaidStore.lua`: return authority rejection reasons, remove canonical staging, and promote recovered state without replay input.
- Modify `Raid Management Addon/Database/DBSyncer.lua`: own recovery lifecycle, transition warnings, promotion, ready/failure notification, and the read-only recovery query.
- Modify `Raid Management Addon/Modules/Events.lua`: register `RaidAuthorityRecoveryFinished`.
- Modify `Raid Management Addon/Localization/localization.en.lua`: add the two local authority-transition warning templates.
- Modify `Raid Management Addon/Services/Raid/State.lua`: own bounded boss facts, ordered recovery replay, and one automatic conclusion retry.
- Modify `Raid Management Addon/Services/Loot/Service.lua`: gate Group Loot before runtime consumption, own bounded pre-NID receipts, replay them, and reuse the ML award retry.
- Modify `tests/lua/runtime_harness.lua`: add/replace lifecycle, collision, replay, deduplication, failure, and warning behavior cases.
- Modify `tests/test_raid_replication_behavior.py`: expose every new Lua regression through the Python suite and retire staged-replay expectations.
- Modify `docs/smoke-tests/raid-history-sharing.md` only if that tracked smoke gate exists: add authority handover/WARN observations without marking the smoke passed.

---

### Task 1: Make Store Promotion Recovery-Only

**Files:**
- Modify: `Raid Management Addon/Database/DBRaidStore.lua:81-100, 701-715, 897-1015`
- Modify: `tests/lua/runtime_harness.lua:13070-13120, 13429-13470`
- Modify: `tests/test_raid_replication_behavior.py`

**Interfaces:**
- Consumes: `authorityGuard(operation) -> allowed:boolean, reason:string|nil`.
- Produces: `RaidStore:PromoteAuthority(raidUid:string, recoveredSequence:number) -> promotedRecord:table|nil, reason:string|nil`.
- Produces: `CommitAuthoritativeEvent` and `ConcludeActiveRaid` return `nil, "AUTHORITY_RECOVERING"` while handover closes writes.
- Removes: `RaidStore:SetAuthoritativeEventStager` and the third `staged` argument to `PromoteAuthority`.

- [ ] **Step 1: Write the failing store tests**

Replace the staged-promotion case with a recovery-only case and add reason propagation:

```lua
function cases.raid_handover_store_promotion_is_recovery_only(addon)
    local store = installRaidArchiveFixture(addon)
    local recovering = false
    assert(store:SetAuthorityGuard(function(operation)
        if operation == "promote" then return true end
        if recovering then return false, "AUTHORITY_RECOVERING" end
        return true
    end))
    local _, _, raidUid = assert(store:CreateActiveRaid({
        authorityKey = "Leader-Realm", serverTime = 1721120000,
        zone = "Naxxramas", size = 25, difficulty = 1,
        players = {}, bossKills = {}, attendance = {}, loot = {},
    }))
    local before = deepCopy(assert(store:GetRecord(raidUid)))
    recovering = true
    local rejected, reason = store:CommitAuthoritativeEvent(raidUid, "PLAYER_UPDATED", {
        player = { playerNid = 2, name = "Marco", join = 1721120001, countMS = 0 },
    })
    assertEqual(nil, rejected, "recovering store accepted a canonical mutation")
    assertEqual("AUTHORITY_RECOVERING", reason, "recovering rejection reason differs")
    assertTrue(deepEqual(before, store:GetRecord(raidUid)), "rejected mutation changed state")

    local promoted = assert(store:PromoteAuthority(raidUid, before.sequence))
    assertEqual(before.authorityEpoch + 1, promoted.authorityEpoch, "epoch did not advance")
    assertEqual(before.sequence, promoted.sequence, "promotion replayed an event")
    assertEqual(before.sequence, promoted.checkpointSequence, "checkpoint differs")
    assertEqual(0, #promoted.events, "promotion retained a staged ledger")
    print("PASS raid_handover_store_promotion_is_recovery_only")
end
```

Add the Python wrapper:

```python
def test_authority_promotion_uses_only_recovered_state(self) -> None:
    self.assert_case("raid_handover_store_promotion_is_recovery_only")
```

Delete Python registrations for `raid_handover_staged_replay` and `raid_handover_atomic_replay_failure`; those tests protect the unsafe behavior being removed.

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```powershell
py -3 -m unittest tests.test_raid_replication_behavior.RaidReplicationBehaviorTests.test_authority_promotion_uses_only_recovered_state -v
```

Expected: FAIL because the guard reason becomes `NOT_RAID_LEADER` and `PromoteAuthority` still expects/replays `staged` rows.

- [ ] **Step 3: Implement the minimal recovery-only store contract**

Change the authority helper to preserve an explicit rejection reason:

```lua
local function requireLocalAuthority(operation)
    if type(authorityGuard) ~= "function" then
        return nil, "AUTHORITY_GUARD_UNAVAILABLE"
    end
    local ok, allowed, reason = pcall(authorityGuard, operation)
    if not ok then
        return nil, "NOT_RAID_LEADER"
    end
    if allowed ~= true then
        return nil, reason or "NOT_RAID_LEADER"
    end
    return true
end
```

Remove `authoritativeEventStager`, `SetAuthoritativeEventStager`, and the staging branch from `CommitAuthoritativeEvent`. Simplify promotion to validate the recovered record, increment `authorityEpoch`, set `checkpointSequence = recoveredSequence`, clear `events`, recompute/retain the unchanged state digest, validate atomically, store the candidate, and return the promoted record:

```lua
function module:PromoteAuthority(raidUid, recoveredSequence)
    local authorized, authorityReason = requireLocalAuthority("promote")
    if not authorized then return nil, authorityReason end
    local current = self:GetRecord(raidUid)
    if not current or current.sequence ~= recoveredSequence then
        return nil, "RECOVERED_SEQUENCE_MISMATCH"
    end
    local candidate = deepCopy(current)
    candidate.authorityEpoch = candidate.authorityEpoch + 1
    candidate.checkpointSequence = recoveredSequence
    candidate.events = {}
    local valid, reason = getValidator():ValidateRecord(candidate)
    if not valid then return nil, reason end
    self:EnsureArchive().raids[raidUid] = candidate
    return candidate
end
```

- [ ] **Step 4: Run focused and store regression tests**

Run:

```powershell
py -3 -m unittest tests.test_raid_replication_behavior.RaidReplicationBehaviorTests.test_authority_promotion_uses_only_recovered_state tests.test_raid_replication_behavior.RaidReplicationBehaviorTests.test_store_commit_and_replica_apply_are_atomic -v
```

Expected: both PASS.

- [ ] **Step 5: Commit Task 1**

```powershell
git add -- "Raid Management Addon/Database/DBRaidStore.lua" "tests/lua/runtime_harness.lua" "tests/test_raid_replication_behavior.py"
git diff --cached --check
git commit -m "fix(sync): promote only recovered raid state"
```

---

### Task 2: Publish Recovery Lifecycle And Local Authority WARN

**Files:**
- Modify: `Raid Management Addon/Modules/Events.lua`
- Modify: `Raid Management Addon/Localization/localization.en.lua`
- Modify: `Raid Management Addon/Database/DBSyncer.lua:58-105, 573-703, 1281-1440`
- Modify: `tests/lua/runtime_harness.lua`
- Modify: `tests/test_raid_replication_behavior.py`

**Interfaces:**
- Consumes: Task 1 `RaidStore:PromoteAuthority(raidUid, recoveredSequence)`.
- Produces: `Events.Internal.RaidAuthorityRecoveryFinished`.
- Produces event: `RaidAuthorityRecoveryFinished(raidUid:string, succeeded:boolean, reason:string)` exactly once per completed/suspended handover.
- Produces: `DB.Syncer:IsAuthorityRecovering(raidUid:string|nil) -> boolean`.
- Produces localization: `L.WarnRaidDatabaseAuthorityReleased` and `L.WarnRaidDatabaseAuthorityReceived`.

- [ ] **Step 1: Write failing lifecycle and warning tests**

Add one harness case that models old leader, new leader, and ordinary member, captures `addon:warn`, and fires repeated roster/head activity:

```lua
function cases.raid_handover_recovery_lifecycle_and_warnings()
    local network = newLiveReplicationNetwork()
    local oldLeader = installLiveReplicationClient(network, "Leader", makeLiveRecord(3))
    local newLeader = installLiveReplicationClient(network, "Member", makeLiveRecord(2))
    local ordinary = installLiveReplicationClient(network, "Other", makeLiveRecord(2))
    oldLeader.warnings, newLeader.warnings, ordinary.warnings = {}, {}, {}
    network.raidLeader = "Member"
    fireLiveReplicationCallback(oldLeader, "RaidRosterDelta")
    fireLiveReplicationCallback(newLeader, "RaidRosterDelta")
    fireLiveReplicationCallback(ordinary, "RaidRosterDelta")
    fireLiveReplicationCallback(oldLeader, "RaidRosterDelta")
    fireLiveReplicationCallback(newLeader, "RaidRosterDelta")
    assertEqual(1, #oldLeader.warnings, "old leader warning count differs")
    assertEqual(1, #newLeader.warnings, "new leader warning count differs")
    assertEqual(0, #ordinary.warnings, "ordinary member received authority warning")
    assertTrue(newLeader.syncer:IsAuthorityRecovering("raid-live"), "handover is not read-only")
    assertTrue(newLeader:FireHandoverTimer(), "handover timer was not fired")
    assertEqual(false, newLeader.syncer:IsAuthorityRecovering("raid-live"), "recovery remained closed")
    assertEqual(1, #newLeader.recoveryFinished, "recovery event count differs")
    assertEqual(true, newLeader.recoveryFinished[1].succeeded, "recovery did not publish success")
    print("PASS raid_handover_recovery_lifecycle_and_warnings")
end
```

Extend the live client fixture only with local warning capture and recovery-event capture; do not simulate a raid-chat send. Add:

```python
def test_handover_publishes_lifecycle_and_warns_only_old_and_new_leaders(self) -> None:
    self.assert_case("raid_handover_recovery_lifecycle_and_warnings")
```

- [ ] **Step 2: Run the focused test and verify RED**

Run the new Python method. Expected: FAIL because the event, read-only query, warning strings, and deduplication do not exist.

- [ ] **Step 3: Implement lifecycle, promotion, and WARN**

Register the internal event:

```lua
Internal.RaidAuthorityRecoveryFinished = "RaidAuthorityRecoveryFinished"
```

Add localized ASCII templates:

```lua
L.WarnRaidDatabaseAuthorityReleased = "Raid database authority passed to %s. This client now holds a read-only replica."
L.WarnRaidDatabaseAuthorityReceived = "Raid database authority received from %s. Recovery is in progress; raid history writes are temporarily paused."
```

In `DBSyncer`, bind `TriggerEvent`, resolve the new internal event, and replace staged handover state with a transition key and recovery-only promotion. The authority guard must be:

```lua
if operation == "promote" then
    return module._handover ~= nil
end
if module._handover ~= nil then
    return false, "AUTHORITY_RECOVERING"
end
return isRaidLeader and identifiedLeader ~= nil and identifiedLeader == localPlayer
```

Add:

```lua
function module:IsAuthorityRecovering(raidUid)
    local handover = self._handover
    return handover ~= nil and (raidUid == nil or handover.raidUid == raidUid)
end
```

Warn only when the normalized pair changes:

```lua
local key = tostring(previousAuthority or "?") .. ">" .. tostring(currentAuthority or "?")
if module._lastWarnedAuthorityPair ~= key then
    if previousAuthority == localPlayer and currentAuthority then
        addon:warn(L.WarnRaidDatabaseAuthorityReleased:format(currentAuthority))
    elseif currentAuthority == localPlayer and previousAuthority then
        addon:warn(L.WarnRaidDatabaseAuthorityReceived:format(previousAuthority))
    end
    module._lastWarnedAuthorityPair = key
end
```

On promotion, call `PromoteAuthority` without staged events, set synchronized status, clear `_handover`, emit success, then advertise the new head. On suspension/cancellation emit failure before clearing handover. Remove `planStagedPlayer`, `IsDistributionAwardStaged`, the store stager registration, staged-award maps, and handover replay broadcasting branches.

- [ ] **Step 4: Run lifecycle and existing sync tests**

Run:

```powershell
py -3 -m unittest tests.test_raid_replication_behavior.RaidReplicationBehaviorTests.test_handover_publishes_lifecycle_and_warns_only_old_and_new_leaders tests.test_raid_replication_behavior.RaidReplicationBehaviorTests.test_master_looter_handover_prefers_previous_authority_and_rejects_old_writes tests.test_raid_replication_behavior.RaidReplicationBehaviorTests.test_repeated_master_looter_changes_cancel_stale_work -v
```

Expected: PASS. Rename outdated Python method descriptions from “Master Looter handover” to “Raid Leader handover” without changing case semantics.

- [ ] **Step 5: Commit Task 2**

```powershell
git add -- "Raid Management Addon/Modules/Events.lua" "Raid Management Addon/Localization/localization.en.lua" "Raid Management Addon/Database/DBSyncer.lua" "tests/lua/runtime_harness.lua" "tests/test_raid_replication_behavior.py"
git diff --cached --check
git commit -m "fix(sync): recover before raid authority promotion"
```

---

### Task 3: Replay Raid Facts Against Recovered State

**Files:**
- Modify: `Raid Management Addon/Services/Raid/State.lua:58-120, 1484-1509, 1638-1656, 1727-1840`
- Modify: `tests/lua/runtime_harness.lua`
- Modify: `tests/test_raid_replication_behavior.py`

**Interfaces:**
- Consumes: `RaidAuthorityRecoveryFinished(raidUid, succeeded, reason)` and `Syncer:IsAuthorityRecovering(raidUid)`.
- Produces: `Services.Raid:_ReplayAuthorityRecovery(raidUid, succeeded, reason)` as an internal testable coordinator.
- Produces: `Services.Loot:ReplayAuthorityRecoveryFacts(raidUid) -> boolean` from Task 4; call it only when present.
- Owns: at most 64 boss facts `{raidUid, bossName, manDiff, sourceNpcId, observedAt, key}` and one automatic conclusion `{raidUid, endTime}`.

- [ ] **Step 1: Write failing collision, order, and failure tests**

Add a faithful-store case whose stale local state has `nextPlayerNid = 2`, whose recovered snapshot already contains `Luca` at NID 2, and which observes `Marco` plus a boss during recovery. Assert no canonical sequence changes before recovery; after `_ReplayAuthorityRecovery`, assert Luca remains NID 2, Marco receives another NID, the boss attendance references the final NIDs, and one roster refresh precedes boss replay.

```lua
assertEqual(2, recovered.state.players[1].playerNid, "recovered Luca NID differs")
assertEqual("Luca", recovered.state.players[1].name, "recovered player was overwritten")
assertTrue(member.raid:GetPlayerID("Marco") > 2, "pending player reused recovered NID")
assertEqual("roster", replayOrder[1], "roster did not replay first")
assertEqual("boss", replayOrder[2], "boss did not replay second")
```

Add a failure branch that queues a boss, emits `RaidAuthorityRecoveryFinished(raidUid, false, "DIGEST_CONFLICT")`, and asserts the fact is cleared and never mutates sequence. Add Python wrappers:

```python
def test_recovery_replays_roster_and_boss_without_nid_aliasing(self) -> None:
    self.assert_case("raid_handover_replays_raid_facts_after_snapshot")

def test_recovery_failure_discards_pending_raid_facts(self) -> None:
    self.assert_case("raid_handover_discards_raid_facts_on_failure")
```

- [ ] **Step 2: Run both tests and verify RED**

Expected: FAIL because `AddBoss` still materializes/stages `bossNid`, no bounded fact owner exists, and no recovery coordinator runs.

- [ ] **Step 3: Implement the minimal Raid fact owner**

At the entry to `AddBoss`, resolve the active `raidUid` and, when the syncer reports recovery, store only stable inputs before allocating player/boss NIDs:

```lua
local fact = {
    raidUid = raidUid,
    bossName = bossName,
    manDiff = manDiff,
    sourceNpcId = tonumber(sourceNpcId),
    observedAt = tonumber(observedAt) or Time.GetCurrentTime(),
}
fact.key = table.concat({ fact.raidUid, tostring(fact.sourceNpcId or fact.bossName), tostring(fact.manDiff or 0) }, "|")
```

Use a local array plus key map, cap it at 64, and let the existing 30-second boss dedupe window decide expiry/replay duplicates. Do not persist the queue or add options.

Register the recovery-finished callback. On failure, authority loss, or mismatched `raidUid`, clear boss/conclusion facts. On success:

```lua
module:RefreshAndPublish()
replayPendingBossFacts(raidUid)
local loot = Services.Loot
if loot and type(loot.ReplayAuthorityRecoveryFacts) == "function" then
    loot:ReplayAuthorityRecoveryFacts(raidUid)
end
retryAutomaticConclusion(raidUid)
```

Replay `AddBoss` with the original `observedAt` so existing deduplication sees the real event time. Remove all `HANDOVER_STAGED` handling and planned-player return paths. `End()` returns `AUTHORITY_RECOVERING` without clearing runtime state; only the automatic session caller stores one conclusion retry.

- [ ] **Step 4: Run Raid recovery and ordinary recording tests**

Run the two new methods plus `test_local_mutations_commit_semantic_events_in_order`, `test_group_loot_uses_raid_leader_as_authority`, and `test_conclusion_compacts_the_active_event_ledger_atomically`. Expected: PASS.

- [ ] **Step 5: Commit Task 3**

```powershell
git add -- "Raid Management Addon/Services/Raid/State.lua" "tests/lua/runtime_harness.lua" "tests/test_raid_replication_behavior.py"
git diff --cached --check
git commit -m "fix(raid): replay facts after authority recovery"
```

---

### Task 4: Replay Group Loot And Reuse Master Loot Retry

**Files:**
- Modify: `Raid Management Addon/Services/Loot/Service.lua:95-130, 978-1155, 1276-1467`
- Modify: `tests/lua/runtime_harness.lua`
- Modify: `tests/test_raid_replication_behavior.py`

**Interfaces:**
- Consumes: `Syncer:IsAuthorityRecovering(raidUid)` and Task 3 ordered coordinator.
- Produces: `Services.Loot:ReplayAuthorityRecoveryFacts(raidUid) -> boolean`.
- Owns: at most 64 Group Loot facts for 60 seconds, containing no `playerNid`, `bossNid`, or `lootNid`.
- Reuses: existing ML retry keyed by `sessionId .. "|" .. transactionId`, two attempts one second apart.

- [ ] **Step 1: Write failing Group Loot and ML retry tests**

Add a case where recovery snapshot contains `Luca=NID2` and an existing loot row, then deliver a Group Loot winner message for `Marco` during recovery. Assert before promotion that sequence, counters, workflow duplicate markers, and loot count are unchanged. After replay, assert Luca is intact, Marco resolves to a fresh NID, loot and counter commit once, and a receipt already present in the snapshot is not duplicated.

Add a second case where `RecordDistributionAward` runs during recovery and verify the existing retry map contains one stable award, the database does not change before promotion, and replay records exactly one atomic loot+counter event afterward.

```python
def test_group_loot_waits_for_recovery_before_consuming_runtime_state(self) -> None:
    self.assert_case("raid_handover_replays_group_loot_after_snapshot")

def test_master_loot_award_reuses_bounded_retry_during_recovery(self) -> None:
    self.assert_case("raid_handover_master_loot_uses_existing_retry")
```

- [ ] **Step 2: Run both tests and verify RED**

Expected: Group Loot consumes workflow/counter state before the rejected commit, and ML returns non-retryable `distribution_record_failed`.

- [ ] **Step 3: Implement the minimal Loot fact owner**

At the start of `AddLoot`, before `Workflow.RecordReceipt`, counter application, passive duplicate memory, or context consumption, resolve the active `raidUid`. If recovering, copy only:

```lua
local function copyRecoveryValue(value)
    if type(value) ~= "table" then return value end
    local copy = {}
    for key, item in pairs(value) do
        copy[copyRecoveryValue(key)] = copyRecoveryValue(item)
    end
    return copy
end
```

```lua
{
    raidUid = raidUid,
    msg = msg,
    rollType = rollType,
    rollValue = rollValue,
    parsedGroupLoot = copyRecoveryValue(parsedGroupLoot),
    observedAt = Time.GetCurrentTime(),
    expiresAt = GetTime() + GROUP_LOOT_PENDING_AWARD_TTL_SECONDS,
}
```

Derive a stable key from `raidUid`, parsed session/roll identifiers when present, normalized looter, and item link; fall back to the exact loot message plus observation bucket only when the parsed result has no stable identifiers. Cap the array and key map at 64. No SavedVariables or option is added.

Implement `ReplayAuthorityRecoveryFacts(raidUid)` to discard expired/mismatched facts, check the recovered canonical loot for the same stable session/item/looter identity, and call the ordinary `AddLoot` path only for missing receipts. Remove each fact only after successful consumption or proven canonical duplication.

Before `RecordDistributionAward` tries `LogTradeOnlyLoot`, return `distribution_authority_not_ready, true` when `IsAuthorityRecovering(currentRaidUid)` is true. Delete `isDistributionAwardStaged`; `queueDistributionAwardRetry` remains the single ML queue.

- [ ] **Step 4: Run Loot recovery, split-authority, and atomicity tests**

Run the two new methods plus:

```powershell
py -3 -m unittest tests.test_raid_replication_behavior.RaidReplicationBehaviorTests.test_split_raid_leader_master_looter_records_and_replicates_trade_award_once tests.test_raid_replication_behavior.RaidReplicationBehaviorTests.test_distribution_award_commits_loot_and_counter_atomically -v
```

Expected: all PASS with no duplicate loot or counter.

- [ ] **Step 5: Commit Task 4**

```powershell
git add -- "Raid Management Addon/Services/Loot/Service.lua" "tests/lua/runtime_harness.lua" "tests/test_raid_replication_behavior.py"
git diff --cached --check
git commit -m "fix(loot): replay receipts after raid recovery"
```

---

### Task 5: Integrated Gates, Simplicity Review, And Smoke Contract

**Files:**
- Modify only if present: `docs/smoke-tests/raid-history-sharing.md`
- Review: all files changed by Tasks 1-4

**Interfaces:**
- Consumes: all preceding behavior.
- Produces: no new runtime interface.

- [ ] **Step 1: Run the complete automated suite**

```powershell
py -3 -m unittest discover -s tests -p "test_*.py"
```

Expected: all tests PASS; report the exact count rather than preserving the previous 337 count as an assumption.

- [ ] **Step 2: Run WotLK and repository validators**

```powershell
py -3 .agents/skills/wow-addon-dev-wotlk-v335a/scripts/validate_toc.py "Raid Management Addon/Raid Management Addon.toc"
py -3 .agents/skills/wow-addon-dev-wotlk-v335a/scripts/lint_lua51.py "Raid Management Addon"
py -3 .agents/skills/wow-addon-dev-wotlk-v335a/scripts/scan_xpcall.py "Raid Management Addon"
rg -n "<Scripts>|<On[A-Za-z]+>" "Raid Management Addon/UI" -g "*.xml"
git diff --check
```

Expected: validators PASS; XML search has no script handlers; diff check is clean. If `tools/check-rma.ps1`, `stylua`, or `luacheck` exists, run it and record the exact result; do not claim unavailable gates passed.

- [ ] **Step 3: Run a read-only anti-over-engineering review**

Resolve scope as the Task 1 base commit through `HEAD`. Reject the result if it contains a generic event queue, NID rebase/merge abstraction, duplicated ML retry, new persistence/wire fields, polling, single-use pass-through module, or warning broadcast. Expected verdict: `PASS` or only actionable low-risk items fixed before continuing.

- [ ] **Step 4: Update the smoke checklist without claiming success**

If `docs/smoke-tests/raid-history-sharing.md` exists, add unchecked observations:

```markdown
- [ ] Change Raid Leader from A to B: only A and B see one local database-authority WARN.
- [ ] During B recovery, trigger Group Loot and a boss/award; after synchronization, Loot History contains one correctly attributed row and no recovered player is overwritten.
- [ ] A offers a historical raid, B accepts it, and B sees it in Loot History.
```

Keep the integration gate explicitly blocked until the user reports a positive in-game smoke.

- [ ] **Step 5: Commit only a changed smoke document**

```powershell
git add -- "docs/smoke-tests/raid-history-sharing.md"
git diff --cached --check
git commit -m "test(sync): refresh recovery-first smoke gate"
```

Skip this commit when no tracked smoke document changed.

- [ ] **Step 6: Hand off the in-game smoke**

Report exact automated counts, validators, commits, and residual attendance limitation. Do not merge, rebase, cherry-pick, or modify `codex/loot-bans-optimization`. The work remains incomplete for integration until the user confirms the two-client smoke is positive.
