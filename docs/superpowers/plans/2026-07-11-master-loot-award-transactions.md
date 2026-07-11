# Master Loot Award Transactions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make loot-window and inventory Master Loot awards commit exactly once only after delivery evidence, with explicit failure, resilient logging, accurate distributed state, and one final transaction owner.

**Architecture:** Correct each existing executor incrementally before extracting shared policy. Trade and loot-window code continue to perform WoW API interactions, while terminal effects migrate behind an idempotent runtime transaction contract. Existing wire messages remain compatible; new cancellation and batch messages are additive.

**Tech Stack:** Lua 5.1, WoW WotLK 3.3.5a Interface 30300, Python `unittest` contract/behavior harnesses, StyLua, Luacheck.

## Global Constraints

- Target WoW WotLK 3.3.5a, Interface 30300, and Lua 5.1.
- Preserve existing `RMA_*` SavedVariables and existing addon-message payload layouts.
- Keep inbound legacy `ROLL_TICK` and `AWARDED` handlers.
- Keep `ROLL_END` meaning `winner_selected`; only `ITEM_DONE` means confirmed delivery.
- Add `ITEM_CANCELLED` as an additive message that old clients may ignore.
- Never persist incomplete award transactions across reloads.
- Never correlate identical awards by item ID alone.
- Keep XML layout-only and preserve current public frame identities.
- Every task follows RED-GREEN-REFACTOR and ends with a focused commit.

---

### Task 1: Stage Addon-Driven Trade Confirmation

**Files:**
- Modify: `Raid Management Addon/Services/Master/TradeExecution.lua`
- Modify: `Raid Management Addon/Controllers/Master.lua`
- Test: `tests/test_master_multi_award_behavior.py`
- Test: `tests/test_init_core_micro_cleanup_contract.py`

**Interfaces:**
- Consumes: `TRADE_ACCEPT_UPDATE`, `TRADE_CLOSED`, existing trade failure callbacks and timer scheduling.
- Produces: pending trade confirmation state with `accepted`, `failed`, and `settled` fields; `SettleAcceptedTrade()` and `FailAcceptedTrade(reason)` controller methods.

- [ ] **Step 1: Write failing tests for deferred confirmation**

Add behavior/contract tests proving both accepted flags only stage confirmation:

```python
def test_addon_trade_acceptance_waits_for_close_before_terminal_effects(self):
    source = read(TRADE_EXECUTION)
    accepted = function_body(source, "controller:HandleAcceptedAwardTrade")
    self.assertIn("pendingTradeConfirmation", accepted)
    self.assertNotIn("PublishItemDone", accepted)
    self.assertNotIn("requestLoggerLootLog", accepted)
    self.assertIn("function controller:SettleAcceptedTrade", source)
    self.assertIn("function controller:FailAcceptedTrade", source)
```

Add assertions that `Master:TRADE_CLOSED()` invokes settlement and that failure handlers invoke failure before cleanup.

- [ ] **Step 2: Run focused tests and verify RED**

Run:

```powershell
python -m unittest tests.test_master_multi_award_behavior tests.test_init_core_micro_cleanup_contract
```

Expected: FAIL because pending confirmation and settlement methods do not exist and terminal effects still occur in `HandleAcceptedAwardTrade`.

- [ ] **Step 3: Implement staged acceptance and settlement**

In `TradeExecution.CreateController`, keep pending state private to the controller:

```lua
controller.pendingTradeConfirmation = nil

function controller:HandleAcceptedAwardTrade(playerAccepted, targetAccepted)
    local tradeWinner = self.lootState.tradeWinner
    if not (self.lootState.trader and tradeWinner and self.lootState.trader ~= tradeWinner) then
        return false
    end
    if playerAccepted ~= 1 or targetAccepted ~= 1 then
        return false
    end
    self.pendingTradeConfirmation = {
        winnerName = tradeWinner,
        itemLink = self.lootState.tradeItemLink or self.loot.GetItemLink(),
        rollType = self.lootState.currentRollType,
        accepted = true,
        failed = false,
        settled = false,
    }
    return true
end
```

Move existing context creation, logger write, `PublishItemDone`, and inventory progress into `SettleAcceptedTrade()`. Guard it with `settled` and `failed`. `FailAcceptedTrade(reason)` marks failure, clears the pending record, and leaves no logger/counter/wire-success side effects. Wire `TRADE_CLOSED` to settle after existing close-delay behavior; wire known trade errors/cancellation to fail first.

- [ ] **Step 4: Run focused tests and verify GREEN**

Run the command from Step 2. Expected: PASS.

- [ ] **Step 5: Refactor and commit**

Remove duplicated terminal code left in the acceptance handler, run StyLua on touched Lua files, rerun focused tests, and commit:

```powershell
git add "Raid Management Addon/Services/Master/TradeExecution.lua" "Raid Management Addon/Controllers/Master.lua" tests/test_master_multi_award_behavior.py tests/test_init_core_micro_cleanup_contract.py
git commit -m "fix(master): Confirm trades after settlement"
```

---

### Task 2: Add Uniform Award Confirmation And Failure Effects

**Files:**
- Modify: `Raid Management Addon/Services/Loot/DistributionSession.lua`
- Modify: `Raid Management Addon/Services/Master/Award.lua`
- Modify: `Raid Management Addon/Services/Master/TradeExecution.lua`
- Modify: `Raid Management Addon/Controllers/Master.lua`
- Test: `tests/test_master_multi_award_behavior.py`
- Test: `tests/test_loot_runtime_state_ownership.py`

**Interfaces:**
- Consumes: staged trade settlement from Task 1, pending loot counter confirmation, `ROLL_END` winner selection.
- Produces: `PublishItemCancelled(item, winner, reason)` and shared terminal callbacks `confirmAward(effect)` / `failAward(effect, reason)` injected into both executors.

- [ ] **Step 1: Write failing terminal-effect tests**

Add tests proving:

```python
def test_item_done_is_only_published_from_confirmation_paths(self):
    award = read(MASTER_AWARD)
    trade = read(TRADE_EXECUTION)
    self.assertNotIn("PublishItemDone", function_body(trade, "controller:HandleAcceptedAwardTrade"))
    self.assertIn("confirmAward", award)
    self.assertIn("confirmAward", trade)
    self.assertIn("failAward", award)
    self.assertIn("failAward", trade)

def test_distribution_exposes_additive_item_cancelled(self):
    source = read(DISTRIBUTION_SESSION)
    self.assertIn("function DistributionSession.PublishItemCancelled", source)
    self.assertIn('MSG_ITEM_CANCELLED = "ITEM_CANCELLED"', source)
```

- [ ] **Step 2: Run focused tests and verify RED**

Run:

```powershell
python -m unittest tests.test_master_multi_award_behavior tests.test_loot_runtime_state_ownership
```

Expected: FAIL on missing cancellation publisher and shared terminal callbacks.

- [ ] **Step 3: Implement additive cancellation and terminal callbacks**

Add `ITEM_CANCELLED` encoding/decoding without changing existing message fields. Its row transition returns an item from `winner` to `active` and records a runtime failure reason. Inject callbacks shaped as:

```lua
confirmAward = function(effect)
    if effect.confirmed or effect.failed then return false end
    effect.confirmed = true
    LootDistribution.PublishItemDone(effect.itemLink, effect.winnerName)
    return true
end

failAward = function(effect, reason)
    if effect.confirmed or effect.failed then return false end
    effect.failed = true
    LootDistribution.PublishItemCancelled(effect.itemLink, effect.winnerName, reason)
    return true
end
```

Move counter advancement and multi-winner continuation behind `confirmAward`. Route candidate failure, pending-counter failure, trade failure, and timeouts through `failAward`. Do not move `ROLL_END`; it remains winner selection.

- [ ] **Step 4: Run focused tests and verify GREEN**

Run the command from Step 2. Expected: PASS.

- [ ] **Step 5: Refactor and commit**

Format, rerun focused tests, and commit:

```powershell
git add "Raid Management Addon/Services/Loot/DistributionSession.lua" "Raid Management Addon/Services/Master/Award.lua" "Raid Management Addon/Services/Master/TradeExecution.lua" "Raid Management Addon/Controllers/Master.lua" tests/test_master_multi_award_behavior.py tests/test_loot_runtime_state_ownership.py
git commit -m "feat(master): Unify award terminal effects"
```

---

### Task 3: Reconcile Provisional Loot-Window Records

**Files:**
- Modify: `Raid Management Addon/Services/Loot/PendingAwards.lua`
- Modify: `Raid Management Addon/Services/Loot/Service.lua`
- Modify: `Raid Management Addon/Controllers/Master.lua`
- Test: `tests/test_loot_runtime_state_ownership.py`
- Test: `tests/test_master_multi_award_behavior.py`

**Interfaces:**
- Consumes: confirmed slot evidence, pending award identity, `CHAT_MSG_LOOT` parsing.
- Produces: `CreateProvisionalAward`, `ReconcileProvisionalAward`, and `FinalizeProvisionalAward` runtime operations keyed by transaction/session/item/winner.

- [ ] **Step 1: Write failing reconciliation tests**

Add harness tests for three cases:

```python
def test_slot_clear_then_chat_produces_one_record(self):
    result = run_provisional_harness("slot_then_chat")
    self.assertEqual(result["loot_count"], 1)
    self.assertEqual(result["finalized_count"], 1)

def test_missing_chat_finalizes_one_provisional_record(self):
    result = run_provisional_harness("slot_then_timeout")
    self.assertEqual(result["loot_count"], 1)
    self.assertEqual(result["source"], "MASTER_LOOT_PROVISIONAL")

def test_identical_items_for_two_winners_remain_distinct(self):
    result = run_provisional_harness("identical_two_winners")
    self.assertEqual(result["loot_count"], 2)
    self.assertEqual(result["winners"], ["Alpha", "Bravo"])
```

The first asserts one record after provisional creation plus chat reconciliation. The second advances the bounded grace callback and asserts one record. The third uses the same item ID/link with different winner and transaction/session identities and asserts two records.

- [ ] **Step 2: Run focused tests and verify RED**

Run:

```powershell
python -m unittest tests.test_loot_runtime_state_ownership tests.test_master_multi_award_behavior
```

Expected: FAIL because slot clearing does not create provisional logging evidence.

- [ ] **Step 3: Implement provisional lifecycle**

Store provisional entries only in runtime state:

```lua
{
    transactionId = transactionId,
    rollSessionId = rollSessionId,
    itemKey = itemKey,
    itemLink = itemLink,
    winnerName = winnerName,
    clearedSlot = clearedSlot,
    finalized = false,
}
```

Create the provisional record when pending counter confirmation observes `LOOT_SLOT_CLEARED`. Reconcile chat using transaction ID when available, then roll session ID plus item key/link and normalized winner. Never accept item ID alone. Schedule one bounded grace finalizer through the existing Timer owner; finalization appends at most once and late chat merges into the existing record.

- [ ] **Step 4: Run focused tests and verify GREEN**

Run the command from Step 2. Expected: PASS.

- [ ] **Step 5: Refactor and commit**

Format, rerun focused tests, and commit:

```powershell
git add "Raid Management Addon/Services/Loot/PendingAwards.lua" "Raid Management Addon/Services/Loot/Service.lua" "Raid Management Addon/Controllers/Master.lua" tests/test_loot_runtime_state_ownership.py tests/test_master_multi_award_behavior.py
git commit -m "fix(loot): Reconcile provisional master awards"
```

---

### Task 4: Publish Countdown Duration

**Files:**
- Modify: `Raid Management Addon/Controllers/Master.lua`
- Modify: `Raid Management Addon/Services/Loot/DistributionSession.lua`
- Test: `tests/test_master_multi_award_behavior.py`

**Interfaces:**
- Consumes: existing explicit countdown start and `PublishRollStart(item, type, duration)`.
- Produces: a second idempotent `ROLL_START` update carrying the chosen duration; no outbound tick.

- [ ] **Step 1: Write failing countdown publication test**

```python
def test_starting_countdown_publishes_duration_without_roll_ticks(self):
    source = read(MASTER)
    countdown = function_body(source, "startCountdown")
    self.assertRegex(countdown, r"PublishRollStart\([^\n]+duration")
    self.assertNotIn("PublishRollTick", source)
```

- [ ] **Step 2: Run focused test and verify RED**

Run:

```powershell
python -m unittest tests.test_master_multi_award_behavior
```

Expected: FAIL because countdown start does not publish duration.

- [ ] **Step 3: Publish duration at countdown start**

After countdown validation and immediately before starting the local countdown, call:

```lua
LootDistribution.PublishRollStart(Loot.GetItemLink(), lootState.currentRollType, duration)
```

Ensure receiver updates duration without clearing winner/identity fields unrelated to a rolling restart.

- [ ] **Step 4: Run focused test and verify GREEN**

Run the command from Step 2. Expected: PASS.

- [ ] **Step 5: Refactor and commit**

Format, rerun the focused test, and commit:

```powershell
git add "Raid Management Addon/Controllers/Master.lua" "Raid Management Addon/Services/Loot/DistributionSession.lua" tests/test_master_multi_award_behavior.py
git commit -m "fix(master): Publish roll countdown duration"
```

---

### Task 5: Make Remote Loot Sessions Atomic

**Files:**
- Modify: `Raid Management Addon/Services/Loot/DistributionSession.lua`
- Modify: `Raid Management Addon/Services/Loot/Service.lua`
- Modify: `Raid Management Addon/Controllers/Master.lua`
- Test: `tests/test_loot_runtime_state_ownership.py`

**Interfaces:**
- Consumes: current `CLEAR`, `ITEM`, and snapshot row application.
- Produces: additive `WINDOW_BEGIN`, `WINDOW_END`, and `SESSION_END` messages with monotonically increasing runtime revision.

- [ ] **Step 1: Write failing atomic-window tests**

```python
def test_window_items_are_hidden_until_matching_window_end(self):
    result = run_distribution_harness("matching_window_end")
    self.assertEqual(result["visible_before_end"], 0)
    self.assertEqual(result["visible_after_end"], 2)

def test_stale_revision_cannot_replace_newer_window(self):
    result = run_distribution_harness("stale_revision")
    self.assertEqual(result["revision"], 2)
    self.assertEqual(result["item_key"], "new-item")

def test_loot_close_publishes_session_end_without_pending_inventory_trade(self):
    result = run_distribution_harness("session_end_ownership")
    self.assertTrue(result["closed_without_trade"])
    self.assertFalse(result["closed_with_pending_trade"])
```

Tests must assert that item messages between begin/end update a staging table, mismatched/stale end messages do not commit it, and cleanup does not end a session owned by a pending inventory transaction.

- [ ] **Step 2: Run focused tests and verify RED**

Run:

```powershell
python -m unittest tests.test_loot_runtime_state_ownership
```

Expected: FAIL on missing batch messages and revision staging.

- [ ] **Step 3: Implement additive batch lifecycle**

Add a runtime revision counter. Publisher sequence:

```lua
DistributionSession.BeginWindow(revision)
DistributionSession.PublishWindowItems(items, revision)
DistributionSession.EndWindow(revision)
```

Receivers stage rows by revision and atomically swap them into visible session state on matching `WINDOW_END`. Add `PublishSessionEnd` during delayed loot cleanup when no inventory transaction owns the session. Preserve v1 item handling for peers that do not send batch messages.

- [ ] **Step 4: Run focused tests and verify GREEN**

Run the command from Step 2. Expected: PASS.

- [ ] **Step 5: Refactor and commit**

Format, rerun focused tests, and commit:

```powershell
git add "Raid Management Addon/Services/Loot/DistributionSession.lua" "Raid Management Addon/Services/Loot/Service.lua" "Raid Management Addon/Controllers/Master.lua" tests/test_loot_runtime_state_ownership.py
git commit -m "feat(loot): Publish atomic remote sessions"
```

---

### Task 6: Extract The Award Transaction Owner

**Files:**
- Create: `Raid Management Addon/Services/Master/AwardTransaction.lua`
- Modify: `Raid Management Addon/Raid Management Addon.toc`
- Modify: `Raid Management Addon/Services/Master/Award.lua`
- Modify: `Raid Management Addon/Services/Master/TradeExecution.lua`
- Modify: `Raid Management Addon/Controllers/Master.lua`
- Test: `tests/test_master_multi_award_behavior.py`
- Test: `tests/test_master_service_namespace_ownership.py`
- Test: `tests/test_vertical_slice_architecture.py`

**Interfaces:**
- Consumes: proven terminal callbacks, provisional logging hooks, distribution publisher, counter/progress hooks.
- Produces: `Master.AwardTransaction.Create(opts)` returning an owner with `Select`, `StartRoll`, `SelectWinner`, `BeginExecution`, `Confirm`, `Fail`, `GetState`, and `IsTerminal`.

- [ ] **Step 1: Write failing owner contract and transition tests**

```python
def test_award_transaction_is_a_concrete_master_owner(self):
    source = read(AWARD_TRANSACTION)
    self.assertIn("Master.AwardTransaction = Master.AwardTransaction or {}", source)
    for method in ("Select", "StartRoll", "SelectWinner", "BeginExecution", "Confirm", "Fail", "GetState", "IsTerminal"):
        self.assertIn("function controller:" + method, source)

def test_executors_delegate_terminal_policy_to_transaction_owner(self):
    for path in (MASTER_AWARD, TRADE_EXECUTION):
        source = read(path)
        self.assertIn("awardTransaction", source)
        self.assertNotIn("PublishItemDone", source)
        self.assertNotIn("PublishItemCancelled", source)
```

Add Lua behavior harness cases for valid progression, invalid transition rejection, idempotent confirm/fail, and exactly-once terminal callbacks.

- [ ] **Step 2: Run focused tests and verify RED**

Run:

```powershell
python -m unittest tests.test_master_multi_award_behavior tests.test_master_service_namespace_ownership tests.test_vertical_slice_architecture
```

Expected: FAIL because the owner file and API do not exist and executors still own terminal policy.

- [ ] **Step 3: Implement the owner and migrate executors**

Implement the transition table:

```lua
local transitions = {
    selected = { rolling = true, winner_selected = true, failed = true },
    rolling = { winner_selected = true, failed = true },
    winner_selected = { executing = true, failed = true },
    executing = { confirmed = true, failed = true },
    confirmed = {},
    failed = {},
}
```

`Confirm` and `Fail` perform terminal effects once through injected hooks. Add the file to the TOC immediately before Award and TradeExecution. Replace executor-owned terminal callbacks with transaction calls. Keep controller/UI state projection separate from domain transition state.

- [ ] **Step 4: Run focused tests and verify GREEN**

Run the command from Step 2. Expected: PASS.

- [ ] **Step 5: Run full validation**

Run:

```powershell
python -m unittest discover -s tests -p "test_*.py"
stylua --check "Raid Management Addon"
luacheck "Raid Management Addon" --exclude-files "Raid Management Addon/Libs/**"
py -3 .agents/skills/wow-addon-dev-wotlk-v335a/scripts/validate_toc.py "Raid Management Addon/Raid Management Addon.toc"
py -3 .agents/skills/wow-addon-dev-wotlk-v335a/scripts/lint_lua51.py "Raid Management Addon"
py -3 .agents/skills/wow-addon-dev-wotlk-v335a/scripts/scan_xpcall.py "Raid Management Addon"
git diff --check
```

Expected: all commands exit 0; Luacheck reports zero warnings/errors; no XML runtime handlers are introduced.

- [ ] **Step 6: Commit**

```powershell
git add "Raid Management Addon/Services/Master/AwardTransaction.lua" "Raid Management Addon/Raid Management Addon.toc" "Raid Management Addon/Services/Master/Award.lua" "Raid Management Addon/Services/Master/TradeExecution.lua" "Raid Management Addon/Controllers/Master.lua" tests/test_master_multi_award_behavior.py tests/test_master_service_namespace_ownership.py tests/test_vertical_slice_architecture.py
git commit -m "refactor(master): Centralize award transactions"
```

---

### Task 7: Whole-Branch Review And Coherence Report

**Files:**
- Modify: `docs/GREENFIELD_COMMIT_COHERENCE.md`
- Test: `tests/test_tooling_docs_consistency.py`

**Interfaces:**
- Consumes: all six reviewed task commits.
- Produces: final validation evidence, behavior delta, TOC/registry risk statement, and residual in-game smoke risks.

- [ ] **Step 1: Update coherence assertions first**

Change the documentation-consistency test to require the new test count reported by a fresh full-suite run and require the phrases `award transaction`, `ITEM_CANCELLED`, `provisional loot`, and `in-game trade smoke`.

- [ ] **Step 2: Run the documentation test and verify RED**

```powershell
python -m unittest tests.test_tooling_docs_consistency
```

Expected: FAIL until the coherence report is updated.

- [ ] **Step 3: Update the coherence report**

Record old/new behavior, compatibility impact, SavedVariables impact, additive wire messages, changed TOC entry, exact validation commands/results, untracked/deleted runtime checks, and the remaining need for real-client trade/loot ordering smoke tests.

- [ ] **Step 4: Run documentation and full validation GREEN**

Run the Task 6 full validation commands plus:

```powershell
rg -n "<Scripts>|<On[A-Za-z]+>" "Raid Management Addon/UI" -g "*.xml"
git diff --cached --check
```

Expected: all automated gates pass and XML search returns no runtime script handlers.

- [ ] **Step 5: Commit documentation**

```powershell
git add docs/GREENFIELD_COMMIT_COHERENCE.md tests/test_tooling_docs_consistency.py
git commit -m "docs(master): Record award transaction coherence"
```

- [ ] **Step 6: Run final whole-branch review**

Generate a review package from the commit before Task 1 through `HEAD`, dispatch the final code reviewer, fix every Critical/Important finding in one correction wave, rerun covering tests, and repeat review until approved.
