# Master Loot History Synchronization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make committed Master Loot records converge into every eligible client's Loot History within five seconds for correlated payloads up to 47 chunks, with larger valid late-join snapshots completing atomically inside the 30-second request timeout, including rank-zero master looters and without synchronizing live loot-window state.

**Architecture:** Keep `Services/Loot/Recording.lua` as the canonical history writer, use the existing post-commit `RaidLootUpdate` event as the invalidation boundary, and keep all wire/request/import behavior in `Database/DBSyncer.lua`. The master broadcasts a compact revision notice; peers validate the current master looter, coalesce notices, and whisper one existing snapshot/delta request. The current 120-second persistent pull remains the final fallback.

**Tech Stack:** WoW 3.3.5a, Interface `30300`, Lua 5.1, existing RMA Bus/Timer/Comms services, Python `unittest`, Lua behavior harness, `luacheck`, StyLua, and repository WotLK validators.

## Global Constraints

- Work only on `codex/rework-simplification`; do not integrate into `codex/loot-bans-optimization` before the two-client smoke passes.
- Preserve the `RMALogSync` prefix and protocol version `2`; add only the backward-compatible `RV` message kind.
- Do not change SavedVariables, snapshot/delta schemas, TOC entries, XML, or the live `RMADist` UI/state model.
- Do not write Loot History from a revision notice or `RMADist`; only existing atomic snapshot/delta import paths may mutate remote history.
- Use the actual current master looter as authority even when raid rank is zero. Do not weaken manual `REQ` authorization.
- Treat 47 chunks as the measurable five-second payload budget at 0.10 seconds per queued message plus 0.25 seconds of coalescing. The valid 256-chunk safety maximum is bounded by the 30-second request timeout, not the five-second target.
- Keep the implementation local to existing owners. No generic networking helper, token bucket, ACK protocol, polling loop, or new module.
- Each task starts with a failing focused test, implements the smallest passing change, runs focused validation, and creates one atomic commit.
- Run one final simplicity review. Any abstraction with one caller, duplicate recovery path, or state not required by the contract must be removed before smoke.

---

## Task 1: Emit a compact notice only after canonical history commit

**Files:**

- Modify: `Raid Management Addon/Services/Loot/Recording.lua:170-181`
- Modify: `Raid Management Addon/Services/Loot/Service.lua:884-935, 1196-1209`
- Modify: `Raid Management Addon/Database/DBSyncer.lua:1-120, 445-527, 1717-1745`
- Modify: `tests/test_raid_recording_integrity_behavior.py`
- Modify: `tests/lua/runtime_harness.lua:7168-7451, 7540-7578`
- Modify: `tests/test_sync_communications_behavior.py:36-70`

- [ ] **Step 1: Replace the obsolete trigger test with the post-commit contract**

  Extend `installRealDbSyncerFixture` with `RaidLootUpdate = "RAID_LOOT_UPDATE"`, remove `LootDistributionSessionChanged`, and add:

  ```lua
  function fixture:TriggerRaidLootUpdate(raidNum, row)
      local callback = assert(self.callbacks.RAID_LOOT_UPDATE, "raid loot callback must be bound")
      return callback("RAID_LOOT_UPDATE", raidNum, row)
  end
  ```

  Replace `sync_remote_item_done_accelerates_persistent_pull` with `sync_committed_history_revision_emits_notice_once`. The case must prove:

  ```lua
  function cases.sync_committed_history_revision_emits_notice_once(addon)
      local fixture, syncer = installRealDbSyncerFixture(addon)
      fixture.lootMethod = "master"
      fixture.localMasterLooter = true
      fixture.localRevision = 0

      assertEqual(0, #fixture.sent, "uncommitted history emitted a notice")
      fixture.localRevision = 7
      fixture:TriggerRaidLootUpdate(41, { lootNid = 12 })

      assertEqual(1, #fixture.sent, "committed history must emit one notice")
      assertEqual("RAID", fixture.sent[1].channel, "revision notice must use group transport")
      assertEqual(
          table.concat({ "RV", 2, 41, "Naxxramas", 25, 1, 7 }, "\t"),
          fixture.sent[1].message,
          "revision notice payload differs"
      )

      fixture:TriggerRaidLootUpdate(41, { lootNid = 12 })
      assertEqual(1, #fixture.sent, "equal revision must not emit twice")

      fixture.options.persistentSync = false
      fixture.localRevision = 8
      fixture:TriggerRaidLootUpdate(41, { lootNid = 13 })
      assertEqual(1, #fixture.sent, "disabled persistent sync emitted a notice")
      print("PASS sync_committed_history_revision_emits_notice_once")
  end
  ```

  Update the Python wrapper to run the new case and remove the obsolete remote-`ITEM_DONE` assertion.

  Add `loot_canonical_mutations_advance_revision_before_notification` under `test_raid_recording_integrity_behavior.py`. Its Lua case must execute the real recording/service paths for:

  - a newly appended direct Master Loot record;
  - the authoritative update that completes a provisional Hold award;
  - `MergeTradeOnlyFallback` for a later Hold/trade completion.

  For each path, capture the revision observed inside `RaidLootUpdate` and assert it is strictly greater than the previous revision. Make the recording builder reject one invalid append and assert both revision and event count remain unchanged; this is the explicit `failed commit emits no notice` boundary.

- [ ] **Step 2: Run the new test and confirm RED**

  Run:

  ```powershell
  py -3 -m unittest tests.test_sync_communications_behavior.SyncCommunicationsBehaviorTests.test_committed_history_revision_emits_notice_once -v
  ```

  Expected: FAIL because `DBSyncer` still binds `LootDistributionSessionChanged`, has no `RV` sender, and canonical row updates do not all advance the revision.

- [ ] **Step 3: Make every canonical row mutation advance revision before notification**

  Add one recording-owner method and use it from `Append`:

  ```lua
  function Recording.MarkUpdated(raid, row, reason)
      if type(raid) ~= "table" or type(row) ~= "table" then
          return 0
      end
      return Database.GetRaidStore():MarkLootSyncRevision(raid, row, reason or "loot_row")
  end
  ```

  Immediately after each successful in-place mutation in `UpgradeLoggedPassiveLootRoll`, `applyAuthoritativeProvisional`, and the `MergeTradeOnlyFallback` branch, call `Recording.MarkUpdated(raid, row, <specific reason>)` before `notifyRaidLootUpdate`. Use the reasons `passive_roll`, `authoritative_loot`, and `trade_reconcile`. Failed/no-op mutations must not advance revision or emit an event.

- [ ] **Step 4: Bind the existing post-commit event and send the notice**

  In `DBSyncer.lua`:

  ```lua
  local RaidLootUpdateEvent =
      assert(InternalEvents.RaidLootUpdate, "DBSyncer raid-loot update event is not initialized")

  local MSG_REVISION = "RV"
  module._lastAnnouncedRevisionByRaid = module._lastAnnouncedRevisionByRaid or {}
  ```

  Add the sender after `isPersistentSyncEnabled`; it uses the existing `Services.Raid` owner directly and does not depend on a later local declaration:

  ```lua
  local function announceCommittedRevision(raidNum)
      local raidService = Services.Raid
      if not isPersistentSyncEnabled()
          or not addon.IsInGroup()
          or raidService:GetLootMethodName() ~= "master"
          or raidService:IsMasterLooter() ~= true
      then
          return false
      end
      local raid, currentRaidId = SnapshotImport.GetCurrentRaidRecord()
      if not raid or tonumber(raidNum) ~= tonumber(currentRaidId) then
          return false
      end
      local revision = Database.GetRaidStore():GetRaidSyncRevision(raid)
      local raidNid = tonumber(raid.raidNid) or 0
      local lastRevision = tonumber(module._lastAnnouncedRevisionByRaid[raidNid]) or 0
      if raidNid <= 0 or revision <= lastRevision then
          return false
      end
      local signature = SnapshotImport.BuildSignatureFromRaid(raid)
      local payload = packFields(
          FIELD_SEP,
          MSG_REVISION,
          PROTOCOL_VERSION,
          raidNid,
          SnapshotPayload.EncodeText(signature.zone),
          tonumber(signature.size) or 0,
          tonumber(signature.diff) or 0,
          revision
      )
      local queued = Comms.Sync(COMM_PREFIX, payload)
      if queued then
          module._lastAnnouncedRevisionByRaid[raidNid] = revision
      end
      return queued == true
  end
  ```

  Bind it in `bindPersistentSyncCallbacks`:

  ```lua
  RegisterCallback(RaidLootUpdateEvent, function(_, raidNum)
      announceCommittedRevision(raidNum)
  end)
  ```

  Remove `COMPLETED_LOOT_SYNC_DELAY_SECONDS`, `_persistentSyncAccelerated`, and the `LootDistributionSessionChanged` callback. Keep the existing 120-second scheduler unchanged.

- [ ] **Step 5: Run focused GREEN checks**

  ```powershell
  py -3 -m unittest tests.test_raid_recording_integrity_behavior -v
  py -3 -m unittest tests.test_sync_communications_behavior -v
  luacheck "Raid Management Addon/Services/Loot/Recording.lua" "Raid Management Addon/Services/Loot/Service.lua" "Raid Management Addon/Database/DBSyncer.lua"
  git diff --check
  ```

  Expected: all PASS; no notice is emitted until the existing `RaidLootUpdate` boundary fires after `Recording.Append` and revision advancement.

- [ ] **Step 6: Commit Task 1**

  ```powershell
  git add -- "Raid Management Addon/Services/Loot/Recording.lua" "Raid Management Addon/Services/Loot/Service.lua" "Raid Management Addon/Database/DBSyncer.lua" "tests/lua/runtime_harness.lua" "tests/test_raid_recording_integrity_behavior.py" "tests/test_sync_communications_behavior.py"
  git commit -m "fix(sync): announce committed loot history revisions"
  ```

---

## Task 2: Validate revision notices and pull directly from the master looter

**Files:**

- Modify: `Raid Management Addon/Database/DBSyncer.lua:360-527, 721-927, 1607-1660, 1747-1810`
- Modify: `Raid Management Addon/Localization/DiagnoseLog.en.lua:255-266`
- Modify: `tests/lua/runtime_harness.lua:7168-7451, 7746-7794`
- Modify: `tests/test_sync_communications_behavior.py:36-80, 232-246`

- [ ] **Step 1: Add failing authority, coalescing, and lineage tests**

  Add `sync_revision_notice_targets_master_and_coalesces` to prove that two `RV` notices from the current rank-zero master allocate one 0.25-second timer and then one `WHISPER` `RQ` targeted to that master. The last advertised revision must win.

  Add `sync_revision_notice_rejects_stale_mismatch_and_non_master` to prove:

  - a sender that is not `Services.Raid:IsLootAuthority` schedules nothing;
  - the rejected sender produces `Diag.W.LogSyncRevisionUnauthorized` once;
  - a zone/size/difficulty mismatch schedules nothing;
  - a notice at or below the recorded source revision schedules nothing;
  - no notice mutates `fixture.localRevision` or imports a snapshot directly.

  Strengthen `sync_master_looter_is_authoritative_without_rank` by changing the fixture capability stub to derive leadership from the local roster rank instead of always returning `true`. The existing rank-zero local master request must still produce a response after implementation.

- [ ] **Step 2: Run focused tests and confirm RED**

  ```powershell
  py -3 -m unittest tests.test_sync_communications_behavior.SyncCommunicationsBehaviorTests.test_revision_notice_targets_master_and_coalesces tests.test_sync_communications_behavior.SyncCommunicationsBehaviorTests.test_revision_notice_rejects_stale_mismatch_and_non_master tests.test_sync_communications_behavior.SyncCommunicationsBehaviorTests.test_sync_master_looter_is_authoritative_without_rank -v
  ```

  Expected: FAIL because `RV` is ignored and rank-zero broadcast responses are still blocked by `canAnswerRequests`.

- [ ] **Step 3: Separate automatic loot authority from manual request authority**

  Define these helpers before `trackPendingRequest`, so notice handling and the later timeout callback both capture valid Lua locals:

  ```lua
  local function isCurrentMasterLooterSender(rawSender)
      local raid = Services.Raid
      return raid:GetLootMethodName() == "master" and raid:IsLootAuthority(rawSender) == true
  end

  local function isLocalMasterLooter()
      local raid = Services.Raid
      return raid:GetLootMethodName() == "master" and raid:IsMasterLooter() == true
  end
  ```

  Replace the authorization portion at the start of `handleIncomingRequest` with the following code, then leave its existing `allowIncomingRequest`, raid resolution, rate limiting, delta, and snapshot statements byte-for-byte in their current order:

  ```lua
  local function canAnswerAutomaticSync(rawSender)
      return addon.IsInGroup()
          and isCurrentGroupMember(rawSender)
          and isLocalMasterLooter()
  end

  if mode == MODE_SYNC then
      if not canAnswerAutomaticSync(rawSender) then
          return
      end
  elseif not canAnswerRequests(rawSender, channel) then
      return
  end
  ```

  This must apply to both `RAID` and `WHISPER` automatic sync requests. Do not change `MODE_REQ` or `MODE_PUSH` gates.

- [ ] **Step 4: Make automatic pulls target-aware without exporting a new API**

  Forward-declare the private request function before `handleRevisionNotice`:

  ```lua
  local requestLoggerSync
  ```

  Change its later definition and signature to:

  ```lua
  requestLoggerSync = function(syncer, quiet, target, requestedSourceRaidNid, retryCount)
  ```

  Store these fields in the existing pending request:

  ```lua
  target = target,
  sourceRaidNid = requestedSourceRaidNid or lineageSourceRaidNid,
  retryCount = tonumber(retryCount) or 0,
  ```

  Rename the current local `sourceRaidNid` inside `requestLoggerSync` to `lineageSourceRaidNid`, including its assignment from `_syncLineage`. This avoids shadowing the explicit advertised source ID.

  Queue the request with:

  ```lua
  local queued, reason = sendRequest(
      MODE_SYNC,
      requestId,
      tonumber(currentRaid.raidNid) or 0,
      signature,
      target
  )
  ```

  Keep `RequestLoggerSync()` and the 120-second fallback calling the function without a target so their current behavior remains intact.

- [ ] **Step 5: Parse, validate, and coalesce `RV` before generic request parsing**

  Add:

  ```lua
  local NOTICE_PULL_DELAY_SECONDS = 0.25
  module._noticePullHandle = module._noticePullHandle or nil
  module._pendingNotice = module._pendingNotice or nil
  ```

  Implement `handleRevisionNotice(sender, sourceRaidNid, signature, revision)` with these exact gates:

  ```lua
  if not isPersistentSyncEnabled() then return false end
  if not isCurrentMasterLooterSender(sender) then
      addon:warn(Diag.W.LogSyncRevisionUnauthorized:format(tostring(sender)))
      return false
  end
  local raid = select(1, SnapshotImport.GetCurrentRaidRecord())
  if not raid or not SnapshotImport.RaidMatchesSignature(raid, signature) then return false end

  local lineage = module._syncLineage[tonumber(raid.raidNid)]
  if type(lineage) == "table"
      and identitiesMatchRosterMember(lineage.authorityName, sender)
      and tonumber(lineage.sourceRaidNid) == tonumber(sourceRaidNid)
      and tonumber(lineage.sourceRevision) >= tonumber(revision)
  then
      return false
  end
  ```

  Add the diagnostic template:

  ```lua
  Diag.W.LogSyncRevisionUnauthorized = "[Sync] Ignored history revision from non-master sender=%s"
  ```

  Keep `isAuthorizedSyncResponder` for the existing non-Master-Loot synchronization paths; do not reuse it for `RV`.

  Store only `{ sender, sourceRaidNid, signature, revision }`. If the same validated authority/lineage notice arrives before the timer fires, replace the stored revision only when it is higher and reuse the timer. When the timer fires, clear both notice fields before calling:

  ```lua
  requestLoggerSync(module, true, notice.sender, notice.sourceRaidNid, 0)
  ```

  In `OnAddonMessage`, recognize `RV` immediately after splitting fields and before treating field 3 as a request ID:

  ```lua
  if kind == MSG_REVISION and version == PROTOCOL_VERSION and n >= 7 then
      local sourceRaidNid = parseNumber(fields[3], 0)
      local zone = SnapshotPayload.DecodeText(fields[4])
      local signature = {
          zone = zone,
          size = parseNumber(fields[5], 0),
          diff = parseNumber(fields[6], 0),
      }
      local revision = parseNumber(fields[7], 0)
      if sourceRaidNid > 0 and zone and signature.size > 0 and signature.diff > 0 and revision > 0 then
          handleRevisionNotice(sender, sourceRaidNid, signature, revision)
      end
      return
  end
  ```

- [ ] **Step 6: Run focused GREEN checks**

  ```powershell
  py -3 -m unittest tests.test_sync_communications_behavior -v
  luacheck "Raid Management Addon/Database/DBSyncer.lua"
  git diff --check
  ```

  Expected: all PASS; only the current master can send or answer automatic sync, and duplicate notices cause one targeted request.

- [ ] **Step 7: Commit Task 2**

  ```powershell
  git add -- "Raid Management Addon/Database/DBSyncer.lua" "Raid Management Addon/Localization/DiagnoseLog.en.lua" "tests/lua/runtime_harness.lua" "tests/test_sync_communications_behavior.py"
  git commit -m "fix(sync): pull history from current master looter"
  ```

---

## Task 3: Recover late joins and retry one timed-out targeted pull

**Files:**

- Modify: `Raid Management Addon/Services/Raid/Capabilities.lua:15-95`
- Modify: `Raid Management Addon/Modules/Events.lua:10-40`
- Modify: `Raid Management Addon/Init.lua:594-623, 857-860`
- Modify: `Raid Management Addon/Database/DBSyncer.lua:21-49, 468-490, 1607-1745`
- Modify: `tests/lua/runtime_harness.lua:7168-7451, 8226-8245, 8754-8774`
- Modify: `tests/test_sync_communications_behavior.py:120-145, 202-215`

- [ ] **Step 1: Add failing late-join and bounded-retry tests**

  Add `sync_late_join_targets_current_master_after_roster_identity`:

  - fixture A and B have the same zone/size/difficulty but deliberately different local login timestamps;
  - `RaidRosterDelta` resolves `Master-Test Realm` as the current master;
  - repeated roster/create/options callbacks share one scheduled authority pull;
  - a forwarded `ZONE_CHANGED_NEW_AREA` context event uses the same coalescing path;
  - later roster churn with the same raid/master/signature context schedules no new pull;
  - firing it sends one whisper request to the master;
  - the existing authoritative snapshot import remains the only history mutation.

  Add `sync_targeted_timeout_retries_once`:

  - start one targeted automatic sync;
  - fire its 30-second timeout;
  - assert exactly one new request with `retryCount == 1`;
  - fire the second timeout;
  - assert no third request and no active retry timer.

  Replace the fixture's constant request ID stub with a monotonic test allocator so the retry exercises real request correlation:

  ```lua
  fixture.nextRequestId = 0
  addon.Comms.NextRequestId = function()
      fixture.nextRequestId = fixture.nextRequestId + 1
      return "generated-" .. tostring(fixture.nextRequestId)
  end
  ```

  Update older fixture assertions that hard-code `generated` to read the request ID from the queued `RQ` message or use `generated-1`. Do not change production request-ID behavior.

  Keep the existing manual request timeout test unchanged to prove manual requests are not retried.

- [ ] **Step 2: Run the new cases and confirm RED**

  ```powershell
  py -3 -m unittest tests.test_sync_communications_behavior.SyncCommunicationsBehaviorTests.test_late_join_targets_current_master_after_roster_identity tests.test_sync_communications_behavior.SyncCommunicationsBehaviorTests.test_targeted_timeout_retries_once -v
  ```

  Expected: FAIL because no roster callback or targeted retry exists.

- [ ] **Step 3: Let the existing raid capability owner resolve the current master**

  In `Services/Raid/Capabilities.lua`, bind `UnitName` beside `UnitIsUnit` and add:

  ```lua
  function module:GetMasterLooterName()
      local method, partyMaster, raidMaster = GetLootMethod()
      if method ~= "master" then return nil end
      local unit
      if raidMaster ~= nil then
          unit = raidMaster == 0 and "player" or "raid" .. tostring(raidMaster)
      elseif partyMaster ~= nil then
          unit = partyMaster == 0 and "player" or "party" .. tostring(partyMaster)
      end
      local name = unit and UnitName(unit)
      return name and name ~= "" and name or nil
  end
  ```

  `DBSyncer` must call `Services.Raid:GetMasterLooterName()` and must not duplicate `GetLootMethod`/unit-index policy.

  Register and forward the existing WoW zone boundary:

  ```lua
  Events.Wow.ZoneChangedNewArea = Events.Wow.ZoneChangedNewArea or "wow.ZONE_CHANGED_NEW_AREA"
  ```

  At the end of `addon:ZONE_CHANGED_NEW_AREA()`, after `handleRaidInstanceInfoChanged()`, call `Bus.TriggerEvent(WowEvents.ZoneChangedNewArea)`. Bind `RaidRosterDelta`, `RaidCreate`, and `Wow.ZoneChangedNewArea` in `DBSyncer`.

- [ ] **Step 4: Coalesce late-join pulls through the same notice scheduler**

  Add `module._lastRecoveryContext = module._lastRecoveryContext or nil` and a private `scheduleAuthorityPull()` that:

  - exits when persistent sync is disabled, no current raid exists, or the local client is master;
  - resolves the current master with `Services.Raid:GetMasterLooterName()`;
  - constructs `contextKey` from local `raid.raidNid`, normalized master name, zone, size, and difficulty;
  - returns without scheduling when `contextKey == module._lastRecoveryContext`;
  - stores `contextKey` only after the targeted request is successfully queued; clear it when persistent sync is disabled or current raid/master identity becomes unusable;
  - stores a notice-shaped pending pull with no advertised source raid ID;
  - reuses `_noticePullHandle` instead of creating a second scheduler;
  - requests a full snapshot when no matching runtime lineage exists.

  Bind it from:

  ```lua
  RegisterCallback(OptionsLoadedEvent, function()
      module:RefreshPersistentSync(5)
      scheduleAuthorityPull()
  end)
  RegisterCallback(RaidCreateEvent, scheduleAuthorityPull)
  RegisterCallback(RaidRosterDeltaEvent, scheduleAuthorityPull)
  RegisterCallback(ZoneChangedNewAreaEvent, scheduleAuthorityPull)
  ```

  The existing 120-second fallback remains scheduled separately. Do not add `OnUpdate` or another recurring timer.

- [ ] **Step 5: Retry only targeted automatic requests and only once**

  Move the existing `local requestLoggerSync` declaration above `trackPendingRequest` so both timeout handling and notice handling share it. Do not introduce a second declaration. In the pending timeout callback:

  ```lua
  local retry = pendingState.mode == MODE_SYNC
      and pendingState.target
      and (tonumber(pendingState.retryCount) or 0) < 1
  local target = pendingState.target
  local sourceRaidNid = pendingState.sourceRaidNid
  local retryCount = (tonumber(pendingState.retryCount) or 0) + 1
  terminalizeRequest(requestId, "timeout")
  if retry and isCurrentMasterLooterSender(target) then
      requestLoggerSync(syncer, true, target, sourceRaidNid, retryCount)
  end
  ```

  Manual `REQ`, broadcast fallback `SYNC`, invalid authority, changed raid signature, and the second timeout must terminate without retry.

- [ ] **Step 6: Run focused GREEN checks**

  ```powershell
  py -3 -m unittest tests.test_sync_communications_behavior -v
  luacheck "Raid Management Addon/Database/DBSyncer.lua"
  git diff --check
  ```

  Expected: all PASS; late join uses one targeted pull and timeout recovery is bounded to one retry.

- [ ] **Step 7: Commit Task 3**

  ```powershell
  git add -- "Raid Management Addon/Services/Raid/Capabilities.lua" "Raid Management Addon/Modules/Events.lua" "Raid Management Addon/Init.lua" "Raid Management Addon/Database/DBSyncer.lua" "tests/lua/runtime_harness.lua" "tests/test_sync_communications_behavior.py"
  git commit -m "fix(sync): recover late-joining loot history peers"
  ```

---

## Task 4: Simplify transport pacing and remove failed-trigger plumbing

**Files:**

- Modify: `Raid Management Addon/Modules/Comms.lua:40-47, 232-280`
- Modify: `Raid Management Addon/Services/Loot/DistributionSession.lua:191-193, 260-329`
- Modify: `tests/lua/runtime_harness.lua:1359-1374, 7430-7449, 8449-8478`
- Modify: `tests/test_sync_communications_behavior.py:55-95`

- [ ] **Step 1: Add failing constant-pacing and cleanup assertions**

  Extend the real Comms queue case to enqueue three messages, fire successive queue timers, and assert exactly one send per timer. Assert the delay is `0.10` seconds each time.

  Add `sync_representative_payloads_meet_latency_budget`. Build, serialize, chunk, and drain through the real queue:

  - a one-row delta representing a newly committed award;
  - a 20-row full snapshot representing a late join during a normal raid.

  Measure simulated time as the 0.25-second notice/recovery coalescing delay plus every scheduled queue delay through the final chunk. Both representative payloads must be at most 47 chunks and finish below five seconds. Also drain 256 maximum-sized queued messages with no unrelated backlog and assert completion below the existing 30-second request timeout.

  Remove `test_distribution_event_reports_current_mutation_sender` and its Lua case. Update the distribution fixture event capture to accept only `(reason, row, sessionId)`. Add a source assertion that `DBSyncer.lua` contains neither `COMPLETED_LOOT_SYNC_DELAY_SECONDS` nor `LootDistributionSessionChangedEvent`.

- [ ] **Step 2: Run focused tests and confirm RED**

  ```powershell
  py -3 -m unittest tests.test_sync_communications_behavior.SyncCommunicationsBehaviorTests.test_real_comms_queue_uses_constant_single_message_pacing tests.test_sync_communications_behavior.SyncCommunicationsBehaviorTests.test_representative_payloads_meet_latency_budget tests.test_sync_communications_behavior.SyncCommunicationsBehaviorTests.test_failed_item_done_trigger_is_removed -v
  ```

  Expected: FAIL because the queue still emits bursts of four and the mutation-provenance argument still exists.

- [ ] **Step 3: Use conservative constant queue pacing**

  In `Modules/Comms.lua`, change only:

  ```lua
  local COMMS_ADDON_QUEUE_BURST = 1
  local COMMS_ADDON_QUEUE_DELAY_SECONDS = 0.10
  ```

  Keep queue capacity, atomic batch preflight, backpressure, and all public Comms APIs unchanged. This is a fixed transport policy, not adaptive throttling.

- [ ] **Step 4: Remove mutation provenance that no longer has a consumer**

  In `DistributionSession.lua`:

  ```lua
  local function triggerChanged(reason, row)
      TriggerEvent(DistributionChangedEvent, reason, row, state.sessionId)
  end
  ```

  Keep `row.sender` because it is part of live distribution state, but stop passing `mutationSender` through `applyItemData` and `triggerChanged`. Do not change any `RMADist` message field.

- [ ] **Step 5: Run focused GREEN checks**

  ```powershell
  py -3 -m unittest tests.test_sync_communications_behavior -v
  luacheck "Raid Management Addon/Modules/Comms.lua" "Raid Management Addon/Services/Loot/DistributionSession.lua" "Raid Management Addon/Database/DBSyncer.lua"
  git diff --check
  ```

  Expected: all PASS; snapshot/delta batches retain atomic enqueue but leave the queue one message at a time.

  If either representative real payload exceeds 47 chunks/five seconds, or the 256-message safety maximum exceeds 30 seconds without unrelated backlog, stop this task and revise the pacing/latency contract with measured chunk counts before committing. Do not hide the mismatch by testing fabricated short strings.

- [ ] **Step 6: Commit Task 4**

  ```powershell
  git add -- "Raid Management Addon/Modules/Comms.lua" "Raid Management Addon/Services/Loot/DistributionSession.lua" "tests/lua/runtime_harness.lua" "tests/test_sync_communications_behavior.py"
  git commit -m "refactor(sync): simplify addon message pacing"
  ```

---

## Task 5: Prove convergence, run one simplicity review, and prepare smoke

**Files:**

- Modify: `docs/SYNC_COMMUNICATIONS_HARDENING_REPORT.md`
- Review only: all files changed in Tasks 1-4

- [ ] **Step 1: Add the correlated wire/import round-trip case**

  Extend the real DBSyncer fixture's `ReplaceRaidFromAuthority` stub to retain `fixture.importedSnapshot = deepCopy(snapshot)`. Add the following Python wrapper:

  ```python
  def test_notice_snapshot_round_trip_preserves_history_fields(self) -> None:
      result = run_lua_case("sync_notice_snapshot_round_trip_preserves_history_fields")
      self.assertIn("PASS sync_notice_snapshot_round_trip_preserves_history_fields", result.stdout)
  ```

  Add `sync_notice_snapshot_round_trip_preserves_history_fields` to the Lua harness. This test covers only the correlated `RV` -> targeted `RQ` -> `SN` -> import boundary; Task 1's real recording tests cover direct award, provisional Hold completion, and later Hold/trade mutation. Use canonical player references:

  ```lua
  local expectedLoot = {
      { lootNid = 1, itemId = 19019, itemLink = "item:19019", looterNid = 1, rollType = 1, rollValue = 98, bossNid = 1, source = "CHAT_MSG_LOOT" },
      { lootNid = 2, itemId = 17182, itemLink = "item:17182", looterNid = 2, rollType = 2, rollValue = 87, bossNid = 1, source = "CHAT_MSG_LOOT" },
      { lootNid = 3, itemId = 18832, itemLink = "item:18832", looterNid = 3, rollType = 3, rollValue = 76, bossNid = 1, source = "TRADE_ONLY" },
  }
  ```

  The case body must perform this exact lifecycle:

  ```lua
  function cases.sync_notice_snapshot_round_trip_preserves_history_fields(addon)
      local fixture, syncer = installRealDbSyncerFixture(addon)
      fixture.lootMethod = "master"
      fixture.lootAuthority = "Master-Test Realm"
      fixture.roster = {
          { name = "Master-Test Realm", rank = 0 },
          { name = "Peer-Test Realm", rank = 0 },
      }
      fixture.snapshot = {
          header = {
              protocolVersion = 2,
              raidNid = 88,
              revision = 3,
              zone = "Naxxramas",
              size = 25,
              difficulty = 1,
          },
          players = {
              { playerNid = 1, name = "DirectWinner" },
              { playerNid = 2, name = "HoldWinner" },
              { playerNid = 3, name = "TradeWinner" },
          },
          attendance = {},
          bosses = { { bossNid = 1, name = "Patchwerk" } },
          loot = deepCopy(expectedLoot),
      }

      syncer:OnAddonMessage(
          "RMALogSync",
          table.concat({ "RV", 2, 88, "Naxxramas", 25, 1, 3 }, "\t"),
          "RAID",
          "Master-Test Realm"
      )
      local noticeTimer = assert(syncer._noticePullHandle, "revision notice did not schedule a pull")
      assertTrue(fixture:FireTimer(noticeTimer), "revision pull timer did not fire")
      local request = fixture.sent[#fixture.sent]
      assertEqual("WHISPER", request.channel, "history request must be targeted")
      assertEqual("Master-Test Realm", request.target, "history request targeted the wrong authority")
      local requestId = string.match(request.message, "^[^\t]+\t[^\t]+\t([^\t]+)")
      syncer:OnAddonMessage(
          "RMALogSync",
          table.concat({ "SN", 2, requestId, "SYNC", 88, 1, 1, "snapshot" }, "\t"),
          "WHISPER",
          "Master-Test Realm"
      )

      local imported = assert(fixture.importedSnapshot, "authoritative snapshot was not imported")
      assertEqual(3, #imported.loot, "imported workflow row count differs")
      for i = 1, #expectedLoot do
          local expected = expectedLoot[i]
          local actual = imported.loot[i]
          assertEqual(expected.itemLink, actual.itemLink, "imported item differs")
          assertEqual(expected.looterNid, actual.looterNid, "imported winner reference differs")
          assertEqual(expected.rollType, actual.rollType, "imported roll type differs")
          assertEqual(expected.rollValue, actual.rollValue, "imported roll value differs")
      end
      assertEqual(1, fixture.imports, "history must import once")

      syncer:OnAddonMessage(
          "RMALogSync",
          table.concat({ "RV", 2, 88, "Naxxramas", 25, 1, 3 }, "\t"),
          "RAID",
          "Master-Test Realm"
      )
      assertEqual(nil, syncer._noticePullHandle, "equal revision scheduled a duplicate pull")
      assertEqual(1, fixture.imports, "equal revision duplicated history")
      print("PASS sync_notice_snapshot_round_trip_preserves_history_fields")
  end
  ```

  Keep the existing real import cases `sync_late_join_bootstrap_replaces_unrelated_local_history`, `sync_authoritative_delta_maps_source_to_local_raid`, and `sync_history_import_is_atomic_across_build_and_commit_failures` in the focused run. Together with the new wire lifecycle they prove:

  - a committed revision notice causes the peer to whisper its validated master;
  - the imported row preserves `itemLink`, winner, `rollType`, `rollValue`, and raid association;
  - applying the same notice/response again does not duplicate the row;
  - a non-master response cannot import;
  - late-join bootstrap succeeds despite different local login timestamps in its dedicated real-import case.

- [ ] **Step 2: Run the correlated round-trip case and full suite**

  ```powershell
  py -3 -m unittest tests.test_sync_communications_behavior.SyncCommunicationsBehaviorTests.test_notice_snapshot_round_trip_preserves_history_fields -v
  py -3 -m unittest discover -s tests -p "test_*.py" -v
  ```

  Expected: focused case PASS and full suite PASS with no test-count regression except intentional replacement/removal of obsolete trigger tests.

- [ ] **Step 3: Run repository validators**

  ```powershell
  py -3 "..\..\.agents\skills\wow-addon-dev-wotlk-v335a\scripts\validate_toc.py" "Raid Management Addon/Raid Management Addon.toc"
  py -3 "..\..\.agents\skills\wow-addon-dev-wotlk-v335a\scripts\lint_lua51.py" "Raid Management Addon"
  py -3 "..\..\.agents\skills\wow-addon-dev-wotlk-v335a\scripts\scan_xpcall.py" "Raid Management Addon"
  rg -n "<Scripts>|<On[A-Za-z]+>" "Raid Management Addon/UI" -g "*.xml"
  luacheck "Raid Management Addon" --exclude-files "Raid Management Addon/Libs/**"
  stylua --check "Raid Management Addon/Database/DBSyncer.lua" "Raid Management Addon/Modules/Comms.lua" "Raid Management Addon/Services/Loot/DistributionSession.lua"
  git diff --check
  git status --short --branch
  ```

  Expected: TOC/Lua 5.1/xpcall/luacheck/diff checks PASS; XML search returns no matches. Record any pre-existing focused StyLua EOL/formatting baseline honestly and do not bulk-format unrelated files. `tools/check-rma.ps1` is absent and must be reported as unavailable, not passed.

- [ ] **Step 4: Run exactly one simplicity review**

  Review the complete Task 1-4 diff against the approved design and remove anything that violates these checks:

  - no new module, SavedVariables field, schema, TOC entry, or XML change;
  - one history writer and one importer path only;
  - one coalescing timer shared by notice and late-join pulls;
  - one bounded targeted retry, no generic retry framework;
  - no remaining `ITEM_DONE` persistence trigger or mutation-provenance argument;
  - no public API added solely for tests;
  - no duplicate authority resolver or signature matcher;
  - no speculative compatibility wrapper, ACK, token bucket, or live-history UI.

  After any simplification, rerun the focused sync file, full suite, `luacheck` on touched Lua files, and `git diff --check`.

- [ ] **Step 5: Update the hardening report only with verified behavior**

  Document:

  - old boundary: remote `ITEM_DONE` plus fixed two-second pull;
  - new boundary: committed history revision plus advisory `RV` notice;
  - rank-zero master-looter authorization;
  - targeted late-join recovery and single retry;
  - fixed one-message queue pacing;
  - no SavedVariables or snapshot/delta schema change;
  - automated validation results and remaining in-game smoke requirement.

- [ ] **Step 6: Commit automated completion**

  ```powershell
  git add -- "tests/lua/runtime_harness.lua" "tests/test_sync_communications_behavior.py" "docs/SYNC_COMMUNICATIONS_HARDENING_REPORT.md"
  git commit -m "test(sync): verify Master Loot history convergence"
  ```

- [ ] **Step 7: Run the final two-client in-game smoke before integration**

  On client A (actual master looter, no leader/assistant rank required) and client B:

  1. Enable persistent sync on both clients and verify no Lua errors on login.
  2. Direct-award one item; verify B's Loot History shows the same item, winner, roll type, roll value, and raid within five seconds; capture diagnostics if the correlated payload unexpectedly exceeds 47 chunks.
  3. Hold one item, complete its addon-driven trade later, and verify the same fields converge once without duplicates.
  4. Complete a manual trade flow and verify unrelated history is unchanged.
  5. Join B after A has already recorded loot; verify B converges after roster/current-raid identity becomes usable despite different login times. Expect five seconds up to 47 chunks and otherwise require atomic completion before the 30-second request timeout.
  6. Repeat one notice-producing action and verify B does not gain a duplicate row.
  7. Disable persistent sync on B and verify no automatic pull occurs.
  8. `/reload` both clients and verify `RMA_*` data remains intact.

  Expected: all eight checks PASS. If any fail, keep integration suspended, preserve diagnostics, and return to the smallest failing automated boundary.

- [ ] **Step 8: Integrate only after smoke approval**

  Do not cherry-pick or merge into `codex/loot-bans-optimization` in this task. After the user reports a passing smoke, verify both worktrees are clean, show the exact commits to integrate, and request/execute the already-approved local integration as a separate final action.
