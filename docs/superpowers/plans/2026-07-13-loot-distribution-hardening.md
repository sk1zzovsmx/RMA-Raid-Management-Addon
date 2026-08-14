# Loot Distribution Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make roll resolution, master-loot awards, RMADist windows, inventory trades, and multi-award recovery fail closed and report only confirmed outcomes.

**Architecture:** Strengthen the existing cohesive owners rather than adding a global transaction layer. `Services.Rolls` freezes winner input, `AwardAttempt` and `AwardConfirmation` own checkpointed award transitions, `LootAttribution` owns transaction cleanup, `DistributionSession` owns atomic wire acceptance, and `TradeExecution`/`Trade` require inventory evidence before publication.

**Tech Stack:** WoW 3.3.5a, Interface 30300, Lua 5.1, Python `unittest`, the production Lua runtime harness, and project-local WotLK validators.

## Global Constraints

- Preserve `RMA_Raids`, `RMA_Players`, `RMA_Reserves`, `RMA_Warnings`, `RMA_Spammer`, and `RMA_Options`; add no SavedVariable schema or recovery journal.
- Preserve `/rma`, XML frame identities, addon prefix `RMADist`, protocol version 2, and WotLK 3.3.5a chat/loot/trade APIs.
- RMADist may add only the compatible optional `expectedRows` field to `WINDOW_BEGIN`; do not remove legacy `ITEM` messages.
- Keep XML layout-only, runtime Lua 5.1/ASCII, and `Libs/**` untouched.
- Success chat, whisper, counters, logger commits, and RMADist completion must follow physical confirmation/evidence, never an attempted effect.
- Treat an irreversible effect without enough evidence as bounded `uncertain`, not confirmed success or known failure.
- Use existing owners; add no generic transaction, retry, cache, performance, or helper module.
- Runtime smoke remains deferred until the full refactoring program is complete.

---

### Task 1: Freeze Roll Intake And Reject Reentrant Awards

**Files:**
- Modify: `Raid Management Addon/Services/Rolls/Service.lua`
- Modify: `Raid Management Addon/Services/Rolls/Sessions.lua`
- Modify: `Raid Management Addon/Controllers/Master.lua`
- Modify: `Raid Management Addon/Services/Master/AwardConfirmation.lua`
- Modify: `tests/lua/runtime_harness.lua`
- Create: `tests/test_loot_distribution_hardening_behavior.py`

**Interfaces:**
- Produces: `Services.Rolls:FreezeRollIntake(reason) -> model | nil, reason`.
- Produces: `AwardConfirmation:HasInFlight() -> boolean` and duplicate-safe queue admission used by all award entrypoints.
- Consumes: existing countdown, response, roll-session, display-model, and Master award handlers.

- [ ] **Step 1: Add Python behavior entrypoints**

Create the test file with real harness cases:

```python
from pathlib import Path
import unittest

from tests.lua_test_runner import run_lua_case


class LootDistributionHardeningTests(unittest.TestCase):
    def assert_case(self, name: str) -> None:
        result = run_lua_case(name)
        self.assertIn(f"PASS {name}", result.stdout)

    def test_award_freezes_roll_intake(self) -> None:
        self.assert_case("loot_award_freezes_roll_intake")

    def test_duplicate_award_is_rejected_in_flight(self) -> None:
        self.assert_case("loot_duplicate_award_is_rejected_in_flight")
```

- [ ] **Step 2: Add failing production-harness scenarios**

In `runtime_harness.lua`, load the real Rolls and award owners. Assert that an
award after an expired non-blocking countdown freezes `record`, `canRoll`, the
session window, and the resolved winner; a later system roll and stale countdown
callback change nothing. Assert that button/manual-grid reentry while a
confirmation is pending produces one queue entry and one executor call.

```lua
local frozen, reason = Rolls:FreezeRollIntake("award")
assertTrue(frozen ~= nil, reason or "freeze failed")
assertEqual(false, rollState.record, "award freeze must stop recording")
assertEqual(false, rollState.canRoll, "award freeze must close intake")
submitLateRoll("LatePlayer", 100)
assertEqual(expectedWinner, Rolls:GetResolvedWinner().name, "late roll changed frozen winner")

local first = requestAward()
local second, duplicateReason = requestAward()
assertEqual(true, first, "first award must enter")
assertEqual(nil, second, "second award must fail closed")
assertEqual("award_in_flight", duplicateReason, "stable duplicate reason")
assertEqual(1, effectCalls, "duplicate award reached effect")
```

- [ ] **Step 3: Run RED**

Run:

```powershell
py -3 -m unittest tests.test_loot_distribution_hardening_behavior -v
```

Expected: both tests fail because `FreezeRollIntake` and the shared in-flight
guard do not exist.

- [ ] **Step 4: Implement the atomic freeze and guard**

Inside the Rolls service, reuse the existing local owners and return the final
model:

```lua
function module:FreezeRollIntake(reason)
    local session = getRollSession()
    if not session or session.active ~= true then
        return nil, "no_active_roll_session"
    end
    finishRollIntake()
    Countdown.Stop(state)
    closeRollSession()
    local model = Display.BuildModel(getDisplayContext())
    return model, reason or "frozen"
end
```

Call it once at the start of the actual award branch, after tie-reroll detection
but before winner extraction. Add one controller helper that checks
`module._awardConfirmation:HasInFlight()` and the existing multi-award state;
reuse it for button, manual grid, single, and multi entry paths.

- [ ] **Step 5: Run GREEN and regressions**

Run the two tests above, `tests.test_loot_bans_contract`, and the full suite.

- [ ] **Step 6: Commit**

```powershell
git add -- "Raid Management Addon/Services/Rolls/Service.lua" "Raid Management Addon/Services/Rolls/Sessions.lua" "Raid Management Addon/Controllers/Master.lua" "Raid Management Addon/Services/Master/AwardConfirmation.lua" "tests/lua/runtime_harness.lua"
git add -f -- tests/test_loot_distribution_hardening_behavior.py
git commit -m "fix(loot): Freeze rolls before award execution"
```

---

### Task 2: Make Award Attempts Checkpointed And Retry-Safe

**Files:**
- Modify: `Raid Management Addon/Services/Master/AwardAttempt.lua`
- Modify: `Raid Management Addon/Services/Master/AwardConfirmation.lua`
- Modify: `Raid Management Addon/Controllers/Master.lua`
- Modify: `Raid Management Addon/Localization/localization.en.lua`
- Modify: `tests/lua/runtime_harness.lua`
- Modify: `tests/test_loot_distribution_hardening_behavior.py`

**Interfaces:**
- Produces: `AwardAttempt:RunCheckpoint(name, callback, ...) -> true | nil, reason`.
- Produces: retryable `Confirm`, `MarkUncertain`, and terminal `Fail` transitions with copied state from `GetState`.
- Produces: confirmation entries retained until all confirmation work succeeds.
- Consumes: Task 1 in-flight ownership.

- [ ] **Step 1: Add failing transition and confirmation cases**

Add cases for callback throw, callback rejection after one checkpoint, reentrant
confirm, duplicate slot clear, timeout, and retry. The core assertion is:

```lua
local attempt = AwardAttempt.CreateExecuting(opts)
assertEqual(true, attempt:RunCheckpoint("publish", publishOnce))
assertEqual(nil, attempt:Confirm(), "first confirm must become uncertain")
assertEqual("uncertain", attempt:GetState().state)
assertEqual(true, attempt:Confirm(), "retry must complete")
assertEqual(1, publishCalls, "successful checkpoint repeated")
assertEqual("confirmed", attempt:GetState().state)
```

For `AwardConfirmation`, assert a rejected effect remains findable/in-flight,
requests one refresh/warning, and a later confirm retries it without scheduling a
second timeout.

- [ ] **Step 2: Run RED**

Run only the new attempt/confirmation cases. Expected failures: no checkpoint or
uncertain API, and current confirmation removes the entry before effect success.

- [ ] **Step 3: Implement the state machine**

Keep state and checkpoints inside `AwardAttempt`:

```lua
local checkpoints = {}
local transitioning = false

function instance:RunCheckpoint(name, callback, ...)
    if checkpoints[name] == true then return true end
    local ok, result, reason = pcall(callback, ...)
    if not ok or result ~= true then
        return nil, ok and (reason or "checkpoint_rejected") or tostring(result)
    end
    checkpoints[name] = true
    return true
end
```

`Confirm` accepts `executing` or `uncertain`, uses `confirming` plus the
reentrancy flag, runs its callback, commits `confirmed` only after success, and
otherwise commits `uncertain` with the stable reason. `Fail` contains its
callback and commits once. `GetState` returns checkpoint names, never callback
functions.

Change `AwardConfirmation:Confirm` to keep the entry until provisional and
effect confirmation both return true. Timeout changes the attempt to uncertain,
warns once, and retains bounded reconciliation ownership rather than publishing
cancellation immediately.

- [ ] **Step 4: Make terminal controller effects named checkpoints**

Use `attempt:RunCheckpoint` for provisional attribution, RMADist state, player
counter, sequence progress, notification, and refresh. Each callback returns
`true` or `nil, reason`; no bare side-effect chain may partially succeed without
recording its checkpoint.

- [ ] **Step 5: Run GREEN/full suite and commit**

```powershell
git add -- "Raid Management Addon/Services/Master/AwardAttempt.lua" "Raid Management Addon/Services/Master/AwardConfirmation.lua" "Raid Management Addon/Controllers/Master.lua" "Raid Management Addon/Localization/localization.en.lua" "tests/lua/runtime_harness.lua" "tests/test_loot_distribution_hardening_behavior.py"
git commit -m "fix(loot): Retain uncertain award confirmations"
```

---

### Task 3: Harden The Master-Loot Effect Boundary And Attribution

**Files:**
- Modify: `Raid Management Addon/Services/Loot/Inventory.lua`
- Modify: `Raid Management Addon/Services/Loot/LootAttribution.lua`
- Modify: `Raid Management Addon/Services/Loot/Service.lua`
- Modify: `Raid Management Addon/Services/Master/AwardConfirmation.lua`
- Modify: `Raid Management Addon/Controllers/Master.lua`
- Modify: `Raid Management Addon/Localization/localization.en.lua`
- Modify: `tests/lua/runtime_harness.lua`
- Modify: `tests/test_loot_distribution_hardening_behavior.py`

**Interfaces:**
- Produces: `Inventory.ValidateLootSlot(slot, itemLink) -> true | nil, reason`.
- Produces: `LootAttribution.Cancel(transactionId) -> boolean` exposed through `Services.Loot:CancelPendingAward(transactionId)`.
- Produces: atomic `AwardConfirmation:Queue(opts) -> pending | nil, reason`.
- Consumes: Task 2 checkpointed confirmation.

- [ ] **Step 1: Add failing effect-boundary matrix**

Cover strict canonical mismatch, same-ID/different-item-string rejection,
candidate/permission changes, timer nil/throw, `GiveMasterLoot` throw, UI error,
timeout with item still present, timeout with item absent, and success timing.

```lua
local ok, reason = assignItem(targetLink, winner, rollType, rollValue)
assertEqual(nil, ok)
assertEqual("loot_slot_changed", reason)
assertEqual(0, giveMasterLootCalls)
assertEqual(0, successMessages)
assertEqual(0, pendingAttributionCount())
```

For success, assert no `ROLL_END`, `ITEM_DONE`, raid announcement, or whisper
before slot confirmation; after confirmation each occurs exactly once.

- [ ] **Step 2: Run RED**

Expected: current code uses item-ID fallback despite canonical mismatch, queue
cannot fail atomically, API errors escape, attribution remains, and success is
premature.

- [ ] **Step 3: Implement strict item and transaction cleanup APIs**

```lua
function Inventory.ValidateLootSlot(slot, itemLink)
    local current = GetLootSlotLink(tonumber(slot) or 0)
    if not current then return nil, "loot_slot_missing" end
    local wantedKey = Item.GetItemStringFromLink(itemLink)
    local currentKey = Item.GetItemStringFromLink(current)
    if wantedKey and currentKey then
        return wantedKey == currentKey and true or nil,
            wantedKey == currentKey and nil or "loot_slot_changed"
    end
    return Item.GetItemIdFromLink(current) == Item.GetItemIdFromLink(itemLink)
        and true or nil, "loot_slot_changed"
end
```

Implement `LootAttribution.Cancel` by scanning pending lists, removing only rows
whose normalized `transactionId` matches, deleting empty lists, and returning
whether anything changed. Do not purge unrelated same-item awards.

- [ ] **Step 4: Reorder `assignItem` around the effect**

Final order: freeze/in-flight guard from Task 1; validate permission/winner;
resolve candidate; final strict slot validation; create attribution; queue
confirmation; protected `GiveMasterLoot`; on throw cancel confirmation and exact
attribution; return real reason. Store output/whisper on the attempt and send
them only from the confirmed notification checkpoint.

Queue scheduling must use `pcall`; a nil/throw scheduler leaves no confirmation
or attribution. Timeout resolution checks the strict slot: still present means
known failure/cancel attribution; absent means retry confirmation; unavailable
loot window remains uncertain without success.

- [ ] **Step 5: Run GREEN, loot-ban regressions, full suite, and commit**

```powershell
git add -- "Raid Management Addon/Services/Loot/Inventory.lua" "Raid Management Addon/Services/Loot/LootAttribution.lua" "Raid Management Addon/Services/Loot/Service.lua" "Raid Management Addon/Services/Master/AwardConfirmation.lua" "Raid Management Addon/Controllers/Master.lua" "Raid Management Addon/Localization/localization.en.lua" "tests/lua/runtime_harness.lua" "tests/test_loot_distribution_hardening_behavior.py"
git commit -m "fix(loot): Confirm awards before publishing success"
```

---

### Task 4: Make RMADist Windows Atomic And Session-Scoped

**Files:**
- Modify: `Raid Management Addon/Services/Loot/DistributionSession.lua`
- Modify: `Raid Management Addon/Services/Loot/Service.lua`
- Modify: `tests/lua/runtime_harness.lua`
- Modify: `tests/test_loot_distribution_hardening_behavior.py`

**Interfaces:**
- Produces: `DistributionSession.BeginWindow(expectedRows) -> revision | nil, reason`.
- Produces: `PublishWindowItems(items, revision) -> true | nil, reason` and no `WINDOW_END` after partial enqueue.
- Produces: one inbound reducer that accepts sender/session/revision/state before mutation.

- [ ] **Step 1: Add failing transport/receiver cases**

Add tests for row-N enqueue failure, missing/duplicate/oversized rows, zero rows,
stale/equal/gapped revisions, delayed atomic messages, ended-session tombstones,
snapshot resurrection, authority change, ownership survival across display clear,
and retryable `SESSION_END` send failure.

```lua
local revision = DistributionSession.BeginWindow(3)
local ok, reason = DistributionSession.PublishWindowItems(items, revision)
assertEqual(nil, ok)
assertEqual("window_item_send_failed", reason)
assertEqual(0, countSentKind("WINDOW_END"), "partial window committed")
deliverStagedPartialWindow()
assertDeepEqual(previousDisplay, DistributionSession.GetDisplayModel())
```

- [ ] **Step 2: Run RED**

Expected: current sender reports any-row success, sends END, receiver lacks
expected count, stale atomic messages mutate state, and snapshot can resurrect.

- [ ] **Step 3: Implement additive expected-row publication**

Keep `PROTOCOL_VERSION = 2`. Encode expected rows as the next `WINDOW_BEGIN`
field. Old receivers ignore it. New receivers store `expectedRows` only when it
is an integer from 0 through `MAX_WINDOW_ROWS`.

The sender calculates rows first, sends BEGIN, requires every item enqueue, and
sends END only after complete success. `Loot:FetchLoot` propagates the first
failure instead of ignoring it.

- [ ] **Step 4: Route inbound changes through one acceptance decision**

Add a local reducer returning `true` or `nil, reason` for trusted authority,
current/allowed session, valid monotonic revision, non-tombstoned stream, and
message state. `WINDOW_END` commits the detached staged candidate only when
`#order == expectedRows` if expected count exists. Snapshot application builds a
detached candidate and checks tombstone/revision before replacing active roots.

Do not delete session ownership tokens in display `Clear`. Set
`sessionEndRequested` only after a successful end send so failure is retryable.

- [ ] **Step 5: Run GREEN, sync regressions, full suite, and commit**

```powershell
git add -- "Raid Management Addon/Services/Loot/DistributionSession.lua" "Raid Management Addon/Services/Loot/Service.lua" "tests/lua/runtime_harness.lua" "tests/test_loot_distribution_hardening_behavior.py"
git commit -m "fix(sync): Commit complete loot windows only"
```

---

### Task 5: Require Inventory Evidence For Award Trades

**Files:**
- Modify: `Raid Management Addon/Services/Loot/Inventory.lua`
- Modify: `Raid Management Addon/Services/Master/TradeExecution.lua`
- Modify: `Raid Management Addon/Services/Master/Trade.lua`
- Modify: `Raid Management Addon/Controllers/Master.lua`
- Modify: `Raid Management Addon/Localization/localization.en.lua`
- Modify: `tests/lua/runtime_harness.lua`
- Modify: `tests/test_loot_distribution_hardening_behavior.py`

**Interfaces:**
- Produces: `Inventory.CaptureTradeEvidence(itemLink, bagId, slotId) -> evidence | nil, reason`.
- Produces: `Inventory.VerifyTradeEvidence(evidence) -> true, awardedCount | nil, reason`.
- Produces: TradeExecution runtime states `requested`, `shown`, `accepted`, `verifying`, `confirmed`, `failed`, `uncertain`.
- Consumes: checkpointed AwardAttempt and RMADist terminal publication.

- [ ] **Step 1: Add failing WotLK event-order matrix**

Cover pending creation before `InitiateTrade`, expected `TRADE_SHOW`, cancel
before/after show, one/both accepted, accepted then canceled close without item
delta, successful source-slot decrease, successful total-count decrease, wrong
partner, item replaced, logger rejection/retry, and manual Hold trade evidence.

```lua
assertEqual(true, trade:TradeItem(itemLink, winner, rollType, rollValue))
fire("TRADE_SHOW")
assertEqual("shown", trade:GetPendingState().state)
fire("TRADE_ACCEPT_UPDATE", 1, 1)
fire("TRADE_CLOSED")
runDeferredSettle()
assertEqual(0, loggerCalls, "close without inventory delta logged success")
assertEqual("uncertain", trade:GetPendingState().state)
```

- [ ] **Step 2: Run RED**

Expected: `TRADE_SHOW` fails pending state, accepted+closed confirms without
evidence, awarded count defaults to one, and manual trade logs without proof.

- [ ] **Step 3: Implement evidence capture/query**

Capture canonical key, expected partner, source slot link/count, and total owned
count before cursor pickup. Verification requires matching partner and a
positive decrease in the matching source stack or total owned count. Return
`nil, "trade_transfer_unverified"` otherwise; remove the unconditional one-item
fallback for tracked trades.

- [ ] **Step 4: Implement explicit trade transitions**

Create pending state before `InitiateTrade`. `TRADE_SHOW` advances an expected
request. Both accepted flags advance intent only. Deferred close moves through
`verifying`; only positive evidence calls the checkpointed logger/count/RMADist
confirmation. Known cancel fails; ambiguous close is uncertain and emits one
localized message. Keep session ownership until a confirmed/failed terminal
state; logger checkpoint failure remains retryable without duplicate commits.

Apply `CaptureTradeEvidence`/`VerifyTradeEvidence` to manual Hold trades while
keeping their existing reason selection in `Services.Master.Trade`.

- [ ] **Step 5: Run GREEN, raid-recording regressions, full suite, and commit**

```powershell
git add -- "Raid Management Addon/Services/Loot/Inventory.lua" "Raid Management Addon/Services/Master/TradeExecution.lua" "Raid Management Addon/Services/Master/Trade.lua" "Raid Management Addon/Controllers/Master.lua" "Raid Management Addon/Localization/localization.en.lua" "tests/lua/runtime_harness.lua" "tests/test_loot_distribution_hardening_behavior.py"
git commit -m "fix(trade): Verify item transfer before award commit"
```

---

### Task 6: Add Multi-Award Cancellation And Complete Performance Spans

**Files:**
- Modify: `Raid Management Addon/Services/Master/AwardSequence.lua`
- Modify: `Raid Management Addon/Services/Master/ButtonState.lua`
- Modify: `Raid Management Addon/Controllers/Master.lua`
- Modify: `Raid Management Addon/Localization/localization.en.lua`
- Modify: `tests/lua/runtime_harness.lua`
- Modify: `tests/test_loot_distribution_hardening_behavior.py`

**Interfaces:**
- Produces: `AwardSequence:CancelRemaining(reason) -> true | false, reason`.
- Produces: button model fields `clearText`, `clearTooltip`, and `canClear` reflecting active multi-award cancellation.
- Consumes: Task 1 in-flight guard and Task 2 terminal ownership.

- [ ] **Step 1: Add failing cancellation/performance cases**

Assert cancellation during delay/timeout cancels both handles, preserves
confirmed count, does not start the next winner, does not claim cancellation of
the current irreversible attempt, refreshes once, and permits a later fresh
sequence. Assert Clear text/tooltip becomes localized Cancel Remaining Awards.

Instrument `_PerfStart`/`_PerfFinish` and assert every `LOOT_SLOT_CLEARED` exit
closes `Total`, including the auto-managed continuation return. Count bounded
loot scans, candidate scans, RMADist sends, and refresh requests for 20 slots;
record evidence but do not add a cache unless repetition is proven.

- [ ] **Step 2: Run RED**

Expected: no public cancellation action, Clear is disabled/clears rolls, and the
early return skips `_PerfFinish("LOOT_SLOT_CLEARED", "Total")`.

- [ ] **Step 3: Implement cancellation and truthful button state**

`CancelRemaining` marks the sequence canceled, cancels delay/progress handles,
prevents further continuation, preserves confirmed progress, and leaves the
current confirmation owner untouched. `Private.BtnClear` delegates to it only
for active multi-award; otherwise it retains the existing clear-roll behavior.
No XML changes are required.

- [ ] **Step 4: Fix performance control flow**

Store the continuation result, finish all perf spans, then return:

```lua
local continued = awardController:ContinueOnLootSlotCleared(clearedSlot)
addon._PerfFinish("LOOT_SLOT_CLEARED", "ContinueAward")
addon._PerfFinish("LOOT_SLOT_CLEARED", "Total")
return continued
```

If the bounded fixture proves duplicate refresh requests, coalesce them through
the controller's existing refresh coordinator. Do not add a new cache/module.

- [ ] **Step 5: Run GREEN/full suite and commit**

```powershell
git add -- "Raid Management Addon/Services/Master/AwardSequence.lua" "Raid Management Addon/Services/Master/ButtonState.lua" "Raid Management Addon/Controllers/Master.lua" "Raid Management Addon/Localization/localization.en.lua" "tests/lua/runtime_harness.lua" "tests/test_loot_distribution_hardening_behavior.py"
git commit -m "fix(loot): Allow canceling remaining awards"
```

---

### Task 7: Synchronize Contracts, Evidence, And Final Coherence

**Files:**
- Create: `docs/LOOT_DISTRIBUTION_HARDENING_REPORT.md`
- Modify: `docs/ARCHITECTURE.md`
- Modify: `docs/FEATURE_API_MAP.md`
- Modify: `docs/VALIDATION.md`
- Modify: `docs/RAID_RECORDING_INTEGRITY_REPORT.md`
- Modify: `tests/test_runtime_bootstrap_contract.py` only to replace touched implementation-spelling checks with behavior/load-order contracts.

**Interfaces:**
- Consumes: final APIs and evidence from Tasks 1-6.
- Produces: the authoritative behavior delta, compatibility statement, validation evidence, and residual live-client risks.

- [ ] **Step 1: Audit final code against the design**

Check every design acceptance matrix, all callers of new/changed APIs, current
TOC entries, untracked/deleted runtime files, RMADist protocol constants, six
SavedVariables, localization use, XML handler scan, and no `Libs` changes.

- [ ] **Step 2: Replace only touched brittle source contracts**

Keep TOC/load-order and external XML identity assertions. Replace the fallback
award-attempt regex with a Lua behavior case proving every award entry creates a
transaction and rejects duplicate effect entry. Do not rewrite unrelated icon
or layout contracts in this batch.

- [ ] **Step 3: Write the hardening report**

Document:

- old/new behavior and why each old behavior was unsafe;
- roll freeze and winner immutability;
- award states/checkpoints/uncertainty and attribution cancellation;
- exact confirmation/reconciliation time bounds actually implemented;
- RMADist optional v2 field and mixed-version compatibility;
- trade evidence and manual-trade semantics;
- multi-award cancel UX;
- measured scan/send/refresh counts and any optimization applied;
- SavedVariables, TOC, registry, XML, localization, and wire coherence;
- every command/result and missing `tools/check-rma.ps1` if still absent;
- exact line: `runtime smoke: deferred by user until the full refactoring program is complete`.

Update `RAID_RECORDING_INTEGRITY_REPORT.md` so loot/roll/award/trade safety is no
longer listed as wholly deferred; retain the precise live-client/reload residual
risk.

- [ ] **Step 4: Run all fresh gates**

```powershell
py -3 -m unittest discover -s tests -q
py -3 "C:\Users\ferra\Downloads\RMA-Raid Management Addon\.agents\skills\wow-addon-dev-wotlk-v335a\scripts\validate_toc.py" "Raid Management Addon/Raid Management Addon.toc"
py -3 "C:\Users\ferra\Downloads\RMA-Raid Management Addon\.agents\skills\wow-addon-dev-wotlk-v335a\scripts\lint_lua51.py" "Raid Management Addon"
py -3 "C:\Users\ferra\Downloads\RMA-Raid Management Addon\.agents\skills\wow-addon-dev-wotlk-v335a\scripts\scan_xpcall.py" "Raid Management Addon"
rg -n "<Scripts>|<On[A-Za-z]+>" "Raid Management Addon/UI" -g "*.xml"
$files = rg --files "Raid Management Addon" -g "*.lua" -g "!Libs/**"; luacheck $files
git diff --check 04163f5..HEAD
git status --short --branch
```

XML `rg` exit 1 with no matches is success. Run `tools/check-rma.ps1` only if it
exists. Record StyLua honestly on touched files without applying repository-wide
line-ending churn.

- [ ] **Step 5: Commit**

```powershell
git add -- docs/ARCHITECTURE.md docs/FEATURE_API_MAP.md docs/VALIDATION.md docs/RAID_RECORDING_INTEGRITY_REPORT.md tests/test_runtime_bootstrap_contract.py
git add -f -- docs/LOOT_DISTRIBUTION_HARDENING_REPORT.md
git commit -m "docs(loot): Record distribution hardening"
```

After the task review is clean, request a whole-branch architecture/code review
for `04163f5..HEAD`, fix every Critical/Important/Minor finding, rerun all gates,
and only then fast-forward locally into `codex/loot-bans-optimization`. Preserve
the user's dirty README and raid-report edits in the main checkout. Remove the
temporary worktree/branch only after merged-result verification.
