# Loot Distribution Simplification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep the coherent `d4029e7` loot pipeline while adding only proven admission, ordering, and timer-safety fixes without retry or exhausted-state machinery.

**Architecture:** Preserve `AwardAttempt`, `AwardConfirmation`, `AwardSequence`, `TradeExecution`, `LootAttribution`, and `DistributionSession` as cohesive owners. Simplify the attempt snapshot, add side-effect-free admission guards, validate generated session ordering locally, and make critical timer failures terminate and clean up once.

**Tech Stack:** WoW 3.3.5a build 12340, Interface 30300, Lua 5.1.5, Python `unittest`, repository Lua runtime harness.

## Global Constraints

- Start from commit `d4029e7` on branch `codex/rework-simplification`.
- Preserve all `RMA_*` SavedVariables, addon-message prefixes, and wire formats.
- Use only Lua 5.1 syntax and WotLK 3.3.5a APIs.
- Do not add retry APIs, exhausted states, generation counters, capacity owners, terminal-only queues, or new modules.
- Admission checks run before countdown, UI, roll, or persistence mutation.
- A required timer-scheduling failure terminates the operation, releases ownership, and reports at most once.
- Do not modify `Raid Management Addon/Libs/*`.

## File Map

- `Raid Management Addon/Services/Master/AwardAttempt.lua`: explicit runtime attempt snapshot.
- `Raid Management Addon/Services/Loot/Inventory.lua`: canonical item matching and trade-count evidence.
- `Raid Management Addon/Services/Master/TradeExecution.lua`: one in-flight inventory trade guard.
- `Raid Management Addon/Controllers/Master.lua`: direct-assignment admission order.
- `Raid Management Addon/Services/Loot/DistributionSession.lua`: generated session parsing and stale replacement rejection.
- `Raid Management Addon/Services/Master/AwardSequence.lua`: multi-award timer scheduling failure cleanup.
- `Raid Management Addon/Services/Loot/LootAttribution.lua`: provisional grace timer scheduling fallback.
- `Raid Management Addon/Localization/localization.en.lua`: one existing-style timer failure message only if no suitable diagnostic already exists.
- `tests/lua/runtime_harness.lua`: production-path behavioral cases.
- `tests/test_loot_distribution_hardening_behavior.py`: Python test entrypoints.

---

### Task 1: Replace the Generic Award Snapshot Copy

**Files:**
- Modify: `Raid Management Addon/Services/Master/AwardAttempt.lua:13-63`
- Modify: `tests/lua/runtime_harness.lua:1682-1756`
- Modify: `tests/test_loot_distribution_hardening_behavior.py:17-19`

**Interfaces:**
- Consumes: `AwardAttempt.CreateExecuting(opts)` with scalar attempt fields, optional `source`, and optional flat `executorContext`.
- Produces: the unchanged AwardAttempt instance API; `source` and `executorContext` are isolated shallow snapshots.

- [ ] **Step 1: Add a failing snapshot-contract case**

Add this Lua case beside the existing AwardAttempt cases and register a Python wrapper named `test_award_attempt_snapshots_supported_fields_only`:

```lua
function cases.loot_award_attempt_snapshots_supported_fields_only(addon)
	local source = { kind = "loot", slot = 3 }
	local context = { bagId = 0, slotId = 4 }
	local attempt = addon.Services.Master.AwardAttempt.CreateExecuting({
		transactionId = "tx-simple-copy",
		winnerName = "Alpha",
		source = source,
		executorContext = context,
	})
	source.slot = 9
	context.slotId = 8
	assertEqual(3, attempt:GetState().source.slot, "source snapshot must be isolated")
	assertEqual(4, attempt:GetState().executorContext.slotId, "executor context must be isolated")
	local exposed = attempt:GetState()
	exposed.source.slot = 12
	assertEqual(3, attempt:GetState().source.slot, "returned state must not alias attempt state")
	print("PASS loot_award_attempt_snapshots_supported_fields_only")
end
```

Add the exact Python wrapper:

```python
def test_award_attempt_snapshots_supported_fields_only(self) -> None:
    self.assert_case("loot_award_attempt_snapshots_supported_fields_only")
```

- [ ] **Step 2: Run the new case and verify the existing implementation still passes behaviorally**

Run: `py -3 -m unittest tests.test_loot_distribution_hardening_behavior.LootDistributionHardeningTests.test_award_attempt_snapshots_supported_fields_only -v`

Expected: PASS. This is a characterization test; the simplification must preserve it.

- [ ] **Step 3: Replace the recursive copier with one explicit table snapshot helper**

Replace `copy(value, seen)` with explicit flat snapshots:

```lua
local function copyFlatTable(value)
	if type(value) ~= "table" then
		return value
	end
	local result = {}
	for key, child in pairs(value) do
		local childType = type(child)
		if childType ~= "function" and childType ~= "thread" and childType ~= "userdata" then
			result[key] = child
		end
	end
	return result
end

local function snapshotState(state)
	local result = copyFlatTable(state)
	result.source = copyFlatTable(state.source)
	result.executorContext = copyFlatTable(state.executorContext)
	result.checkpoints = copyFlatTable(state.checkpoints)
	return result
end
```

Use `copyFlatTable` for incoming `source`, `executorContext`, and transition context. Use `snapshotState(state)` for callbacks and `GetState()`. Do not add recursive or cycle-handling behavior.

- [ ] **Step 4: Run focused AwardAttempt tests**

Run: `py -3 -m unittest tests.test_loot_distribution_hardening_behavior.LootDistributionHardeningTests.test_award_attempt_checkpoints_are_retry_safe tests.test_loot_distribution_hardening_behavior.LootDistributionHardeningTests.test_award_attempt_snapshots_supported_fields_only -v`

Expected: 2 tests PASS.

- [ ] **Step 5: Commit the isolated simplification**

```powershell
git add -- "Raid Management Addon/Services/Master/AwardAttempt.lua" "tests/lua/runtime_harness.lua" "tests/test_loot_distribution_hardening_behavior.py"
git commit -m "refactor(loot): Simplify award attempt snapshots"
```

### Task 2: Add Only the Proven Admission Guards

**Files:**
- Modify: `Raid Management Addon/Services/Loot/Inventory.lua:104-122,220-290`
- Modify: `Raid Management Addon/Services/Master/TradeExecution.lua:625-633,860-930`
- Modify: `Raid Management Addon/Controllers/Master.lua:480-500,2689-2712`
- Modify: `tests/lua/runtime_harness.lua:9000-9700`
- Modify: `tests/test_loot_distribution_hardening_behavior.py`

**Interfaces:**
- Consumes: `Inventory.LootLinkMatchesTarget(slotLink, itemLink, wantedKey, wantedId)` and `Inventory.VerifyTradeEvidence(evidence, partnerName, requiredCount)`.
- Produces: `TradeExecution:TradeItem(...) -> nil, "trade_in_flight"` when occupied; direct assignment returns the unchanged `admitAwardEntry` reason before mutation.

- [ ] **Step 1: Add failing production-path cases**

Add three Lua cases and Python wrappers:

```lua
function cases.loot_inventory_canonical_match_and_required_count(addon)
	local bags = { [0] = { [1] = { link = "|Hitem:19019:0:0:0:0:0:0:1|h[A]|h", count = 2 } } }
	local inventory = installTradeEvidenceInventory(addon, bags)
	assertTrue(inventory.LootLinkMatchesTarget(
		"|Hitem:19019:0:0:0:0:0:0:1|h[A]|h",
		"|cffa335ee|Hitem:19019:0:0:0:0:0:0:1|h[B]|h|r",
		"item:19019:0:0:0:0:0:0:1",
		19019
	), "canonical item strings must match")
	local evidence = assert(inventory.CaptureTradeEvidence(bags[0][1].link, 0, 1))
	evidence.expectedPartner = "Winner"
	bags[0][1].count = 1
	local verified, reason = inventory.VerifyTradeEvidence(evidence, "Winner", 2)
	assertEqual(nil, verified, "one transferred copy must not satisfy a two-copy award")
	assertEqual("trade_transfer_unverified", reason, "partial transfer reason differs")
	bags[0][1] = nil
	local awarded
	verified, awarded = inventory.VerifyTradeEvidence(evidence, "Winner", 2)
	assertEqual(true, verified, "two transferred copies must satisfy the required count")
	assertEqual(2, awarded, "required-count evidence differs")
	print("PASS loot_inventory_canonical_match_and_required_count")
end

function cases.loot_trade_rejects_second_in_flight(addon)
	local fixture = installAwardTradeFixture(addon)
	assertTrue(fixture.controller:TradeItem(fixture.target, "Winner", 1, 99))
	local admitted, reason = fixture.controller:TradeItem(fixture.target, "Winner", 1, 98)
	assertEqual(nil, admitted, "second trade must be rejected")
	assertEqual("trade_in_flight", reason, "second trade reason differs")
	print("PASS loot_trade_rejects_second_in_flight")
end

function cases.loot_direct_assignment_admits_before_mutation(addon)
	local fixture = installLootHardeningMasterFixture(addon)
	local effect = { MarkUncertain = function() end, Fail = function() end }
	assertTrue(fixture.master._awardConfirmation:Queue({
		itemLink = "item:19019", itemIndex = 1, playerName = "Winner", effect = effect,
	}), "fixture must own one pending award")
	local assignmentsBefore = fixture.assignments
	local rollTypeBefore = fixture.lootState.currentRollType
	local timersBefore = fixture.timers
	local admitted, reason = fixture.master._Private.BtnHold(nil, "LeftButton")
	assertEqual(nil, admitted, "direct assignment must reject")
	assertEqual("award_in_flight", reason, "admission reason differs")
	assertEqual(assignmentsBefore, fixture.assignments, "rejected admission assigned loot")
	assertEqual(rollTypeBefore, fixture.lootState.currentRollType, "rejected admission changed roll type")
	assertEqual(timersBefore, fixture.timers, "rejected admission changed timer ownership")
	print("PASS loot_direct_assignment_admits_before_mutation")
end
```

Place the inventory and trade cases after `installTradeEvidenceInventory` and `installAwardTradeFixture`, so the existing local fixture functions are in lexical scope. Place the direct-assignment case with the existing `installLootHardeningMasterFixture` cases.

Add these exact Python wrappers:

```python
def test_inventory_canonical_match_and_required_count(self) -> None:
    self.assert_case("loot_inventory_canonical_match_and_required_count")

def test_trade_rejects_second_in_flight(self) -> None:
    self.assert_case("loot_trade_rejects_second_in_flight")

def test_direct_assignment_admits_before_mutation(self) -> None:
    self.assert_case("loot_direct_assignment_admits_before_mutation")
```

- [ ] **Step 2: Run the three cases and verify RED**

Run: `py -3 -m unittest tests.test_loot_distribution_hardening_behavior.LootDistributionHardeningTests.test_inventory_canonical_match_and_required_count tests.test_loot_distribution_hardening_behavior.LootDistributionHardeningTests.test_trade_rejects_second_in_flight tests.test_loot_distribution_hardening_behavior.LootDistributionHardeningTests.test_direct_assignment_admits_before_mutation -v`

Expected: FAIL because canonical comparison, the second-trade guard, and direct pre-admission are absent or incomplete.

- [ ] **Step 3: Implement canonical matching and required-count evidence**

In `Inventory.LootLinkMatchesTarget`, compare canonical item strings before falling back to item ID:

```lua
local targetKey = Item.GetItemStringFromLink(itemLink)
local slotKey = Item.GetItemStringFromLink(slotLink)
if targetKey and slotKey then
	return slotKey == targetKey
end
if wantedKey and slotKey and slotKey == wantedKey then
	return true
end
```

Record `sourceLocationKnown` in `CaptureTradeEvidence`. Extend `VerifyTradeEvidence` with `requiredCount`, compute source delta only for a known source location, compare the maximum source/total delta to `math.max(1, tonumber(requiredCount) or 1)`, and keep the existing `true, awardedCount` or `nil, "trade_transfer_unverified"` contract.

- [ ] **Step 4: Implement the two side-effect-free admission guards**

At the first line of `TradeExecution:TradeItem` add:

```lua
if pendingAcceptedTrade ~= nil then
	return nil, "trade_in_flight"
end
```

Do not add `RetryPendingResolution` or call recovery from `admitAwardEntry`.

At the first line of `assignToTarget` add:

```lua
local admitted, admissionReason = admitAwardEntry(false)
if not admitted then
	return nil, admissionReason
end
```

This block must remain before `stopCountdown()` and every `lootState` mutation.

- [ ] **Step 5: Run the full loot behavior module**

Run: `py -3 -m unittest tests.test_loot_distribution_hardening_behavior -v`

Expected: all loot-distribution tests PASS.

- [ ] **Step 6: Commit the guards**

```powershell
git add -- "Raid Management Addon/Services/Loot/Inventory.lua" "Raid Management Addon/Services/Master/TradeExecution.lua" "Raid Management Addon/Controllers/Master.lua" "tests/lua/runtime_harness.lua" "tests/test_loot_distribution_hardening_behavior.py"
git commit -m "fix(loot): Add bounded award admission guards"
```

### Task 3: Validate Generated Session Ordering Locally

**Files:**
- Modify: `Raid Management Addon/Services/Loot/DistributionSession.lua:156-165,375-386,623-675`
- Modify: `tests/lua/runtime_harness.lua:1436-1565`
- Modify: `tests/test_loot_distribution_hardening_behavior.py:68-78`

**Interfaces:**
- Consumes: generated session ID string `owner:ordinal:timestamp` and trusted sender.
- Produces: local `parseGeneratedSessionId(sessionId, authority) -> ordinal, timestamp | nil`; no exported API.

- [ ] **Step 1: Add malformed, cross-owner, and stale-order cases**

Add one runtime case that sends CLEAR/window messages through the existing DistributionSession fixture and asserts rejection of:

```lua
local rejected = {
	"Other:2:100",          -- authority mismatch
	"Authority:0:100",      -- ordinal below one
	"Authority:1:nan",      -- malformed timestamp
	"Authority:2:99",       -- older timestamp despite higher ordinal
	"Authority:9007199254740992:101", -- unsafe integer
}
```

Also assert that `Authority:2:101` replaces `Authority:1:100`, while the same timestamp is ordered by ordinal. Register it as `loot_distribution_generated_session_order_is_validated` in the Python wrapper.

```python
def test_distribution_generated_session_order_is_validated(self) -> None:
    self.assert_case("loot_distribution_generated_session_order_is_validated")
```

- [ ] **Step 2: Run the new case and verify RED**

Run: `py -3 -m unittest tests.test_loot_distribution_hardening_behavior.LootDistributionHardeningTests.test_distribution_generated_session_order_is_validated -v`

Expected: FAIL because the baseline parser accepts incomplete ordering rules.

- [ ] **Step 3: Implement the bounded local parser and comparison**

Add beside `isNewerSessionId`:

```lua
local MAX_SAFE_INTEGER = 9007199254740991

local function parseGeneratedSessionId(sessionId, authority)
	local owner, ordinalText, timeText = tostring(sessionId or ""):match("^([^:]+):(%d+):([%d%.]+)$")
	if not owner or owner == "" or owner ~= authority then
		return nil
	end
	local ordinal = tonumber(ordinalText)
	local timestamp = tonumber(timeText)
	if
		not ordinal
		or ordinal ~= ordinal
		or ordinal < 1
		or ordinal > MAX_SAFE_INTEGER
		or ordinal ~= math.floor(ordinal)
		or not timestamp
		or timestamp ~= timestamp
		or timestamp < 0
		or timestamp >= math.huge
	then
		return nil
	end
	return ordinal, timestamp
end

local function isNewerSessionId(candidate, current, authority)
	local candidateOrdinal, candidateTime = parseGeneratedSessionId(candidate, authority)
	local currentOrdinal, currentTime = parseGeneratedSessionId(current, authority)
	if not candidateOrdinal or not currentOrdinal then
		return false
	end
	return candidateTime > currentTime
		or (candidateTime == currentTime and candidateOrdinal > currentOrdinal)
end
```

Add a local `canReplaceOwnerSession(sender, sessionId)` that accepts the current session, accepts a different sender only through existing authority transition rules, and requires `isNewerSessionId` for replacement by the same owner. Call it before revision processing in `acceptIncomingMutation` and from the CLEAR stale check.

- [ ] **Step 4: Run distribution and wire-focused tests**

Run: `py -3 -m unittest tests.test_loot_distribution_hardening_behavior.LootDistributionHardeningTests.test_distribution_generated_session_order_is_validated tests.test_loot_distribution_hardening_behavior.LootDistributionHardeningTests.test_distribution_window_receiver_is_session_scoped tests.test_loot_distribution_hardening_behavior.LootDistributionHardeningTests.test_distribution_snapshot_cannot_resurrect_ended_session -v`

Expected: 3 tests PASS.

- [ ] **Step 5: Commit the ordering fix**

```powershell
git add -- "Raid Management Addon/Services/Loot/DistributionSession.lua" "tests/lua/runtime_harness.lua" "tests/test_loot_distribution_hardening_behavior.py"
git commit -m "fix(sync): Validate loot session ordering"
```

### Task 4: Make Critical Loot Timer Failures Terminal Once

**Files:**
- Modify: `Raid Management Addon/Services/Master/AwardSequence.lua:111-150,535-614`
- Modify: `Raid Management Addon/Services/Loot/LootAttribution.lua:484-550`
- Modify: `Raid Management Addon/Controllers/Master.lua:399-430`
- Modify: `Raid Management Addon/Localization/localization.en.lua`
- Modify: `tests/lua/runtime_harness.lua:1760-1860,9900-10400`
- Modify: `tests/test_loot_distribution_hardening_behavior.py`

**Interfaces:**
- Consumes: existing injected `scheduleTimer(callback, delay)` functions.
- Produces: `AwardSequence:Advance() -> nil, "timer_schedule_failed"` on delay failure; provisional attribution completes immediately when its grace timer cannot be armed; scheduler and finalization callback failures emit one warning through the owning controller.

- [ ] **Step 1: Add failing schedule-throw and false-handle cases**

For both injected scheduler behaviors—throwing an error and returning `nil`—assert:

```lua
assertEqual(nil, result, "schedule failure must reject the sequence")
assertEqual("timer_schedule_failed", reason, "schedule failure reason differs")
assertEqual(nil, fixture.lootState.multiAward, "failed sequence retained ownership")
assertEqual(1, fixture.warningCount, "schedule failure must warn once")
assertEqual(0, fixture.activeTimerCount(), "schedule failure left an active timer")
```

Add LootAttribution cases where the grace scheduler throws or returns `nil`, and where `onFinalize` throws. Assert the provisional finalizes exactly once from `LOOT_SLOT_CLEARED`, consumes the pending award, reports exactly one failure through `onFailure(reason)`, and remains reconcilable by a later authoritative loot event. Register Python wrappers for `loot_award_sequence_schedule_failure_is_terminal` and `loot_attribution_schedule_failure_finalizes_once`.

```python
def test_award_sequence_schedule_failure_is_terminal(self) -> None:
    self.assert_case("loot_award_sequence_schedule_failure_is_terminal")

def test_attribution_schedule_failure_finalizes_once(self) -> None:
    self.assert_case("loot_attribution_schedule_failure_finalizes_once")
```

- [ ] **Step 2: Run the new cases and verify RED**

Run: `py -3 -m unittest tests.test_loot_distribution_hardening_behavior.LootDistributionHardeningTests.test_award_sequence_schedule_failure_is_terminal tests.test_loot_distribution_hardening_behavior.LootDistributionHardeningTests.test_attribution_schedule_failure_finalizes_once -v`

Expected: FAIL because AwardSequence calls the scheduler directly and LootAttribution assumes a valid handle.

- [ ] **Step 3: Add one local AwardSequence cleanup path**

Add `stopAfterScheduleFailure(controller, ma, refreshNow)` in `AwardSequence.lua`. It must clear `scheduled`, `delayHandle`, `timeoutHandle`, `waitingForDecrement`, and `active`; set `cancelled` and `cancelReason = "timer_schedule_failed"`; release `lootState.multiAward`; reset item count; warn once; optionally refresh.

Wrap both `armProgressTimeout` and the delayed award scheduler with:

```lua
local scheduled, handle = pcall(controller.scheduleTimer, callback, delay)
if not scheduled or not handle then
	stopAfterScheduleFailure(controller, ma, refreshNow)
	return nil, "timer_schedule_failed"
end
ma.delayHandle = handle
```

Use the matching handle field for the progress timeout. Do not retry scheduling.

- [ ] **Step 4: Add a single immediate-finalization fallback in LootAttribution**

Extend the internal `ConfirmProvisional` call with a final `onFailure(reason)` callback supplied by `Controllers/Master.lua`. The controller maps both `"timer_schedule_failed"` and `"record_finalize_failed"` to one localized warning; it does not retry. Inside `ConfirmProvisional`, wrap it in a local `reportFailureOnce(reason)` closure so a scheduler failure followed by a finalization failure still emits only one warning.

Extract the existing grace callback body into a local `finalizeFromClearedSlot(provisional, pending, onFailure)` that marks the provisional finalized before invoking callbacks, sets `finalizedSource = "LOOT_SLOT_CLEARED"`, invokes `onFinalize` through `pcall`, consumes the pending reference exactly once, and calls `onFailure("record_finalize_failed")` once if the callback throws. Do not add retry counters, queues, generations, or recovery ownership.

Schedule it with:

```lua
local scheduled, handle = pcall(scheduleTimer, function()
	provisional.graceHandle = nil
	finalizeFromClearedSlot(provisional, pending, reportFailureOnce)
end, delay)
if scheduled and handle then
	provisional.graceHandle = handle
	return provisional
end
reportFailureOnce("timer_schedule_failed")
finalizeFromClearedSlot(provisional, pending, reportFailureOnce)
return provisional
```

Do not add retry, exhausted, generation, capacity, or manual-recovery state.

- [ ] **Step 5: Run the entire loot suite and static checks**

Run:

```powershell
py -3 -m unittest tests.test_loot_distribution_hardening_behavior tests.test_loot_bans_contract -v
py -3 ..\..\.agents\skills\wow-addon-dev-wotlk-v335a\scripts\lint_lua51.py "Raid Management Addon"
py -3 ..\..\.agents\skills\wow-addon-dev-wotlk-v335a\scripts\scan_xpcall.py "Raid Management Addon"
git diff --check
```

Expected: all tests PASS; validators report zero errors; `git diff --check` is silent.

- [ ] **Step 6: Commit timer safety**

```powershell
git add -- "Raid Management Addon/Services/Master/AwardSequence.lua" "Raid Management Addon/Services/Loot/LootAttribution.lua" "Raid Management Addon/Controllers/Master.lua" "Raid Management Addon/Localization/localization.en.lua" "tests/lua/runtime_harness.lua" "tests/test_loot_distribution_hardening_behavior.py"
git commit -m "fix(loot): Terminate failed award timers safely"
```

### Task 5: Prove the Reduced Loot State Surface

**Files:**
- Modify: `tests/test_loot_distribution_hardening_behavior.py`
- Verify: `Raid Management Addon/Controllers/Master.lua`
- Verify: `Raid Management Addon/Services/Master/AwardConfirmation.lua`
- Verify: `Raid Management Addon/Services/Master/TradeExecution.lua`
- Verify: `Raid Management Addon/Services/Loot/LootAttribution.lua`

**Interfaces:**
- Consumes: the completed Tasks 1-4.
- Produces: a contract test that rejects the post-`d4029e7` recovery state families.

- [ ] **Step 1: Add a focused negative source contract**

Add a Python test that reads only the four loot owner files and rejects these identifiers:

At the top of the Python module add:

```python
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
```

```python
forbidden = (
    "RetryPendingResolution",
    "RetryFinalization",
    "RetryTerminalPublication",
    "record_finalization_exhausted",
    "authoritative_reconciliation_exhausted",
    "publication_retrying",
    "publication_exhausted",
    "provisional_capacity_exhausted",
)
for path in owner_paths:
    source = path.read_text(encoding="utf-8")
    for identifier in forbidden:
        self.assertNotIn(identifier, source, f"{identifier} leaked into {path}")
```

Define `owner_paths` inside the test from the existing repository root constant:

```python
owner_paths = (
    ROOT / "Raid Management Addon" / "Controllers" / "Master.lua",
    ROOT / "Raid Management Addon" / "Services" / "Master" / "AwardConfirmation.lua",
    ROOT / "Raid Management Addon" / "Services" / "Master" / "TradeExecution.lua",
    ROOT / "Raid Management Addon" / "Services" / "Loot" / "LootAttribution.lua",
)
```

- [ ] **Step 2: Run the negative contract**

Run: `py -3 -m unittest tests.test_loot_distribution_hardening_behavior.LootDistributionHardeningTests.test_recovery_of_recovery_state_is_absent -v`

Expected: PASS on the simplified `d4029e7`-based branch.

- [ ] **Step 3: Run the full automated baseline**

Run: `py -3 -m unittest discover -s tests -v`

Expected: all tests PASS; count is at least the baseline 234 plus the new behavior cases.

- [ ] **Step 4: Commit the anti-regression contract**

```powershell
git add -- "tests/test_loot_distribution_hardening_behavior.py"
git commit -m "test(loot): Reject recovery state expansion"
```
