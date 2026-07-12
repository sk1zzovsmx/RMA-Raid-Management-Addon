# Visible Banned Roll Intake Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Record and display the first roll from a player who was already Loot Banned before submission, while keeping the response permanently ineligible and preserving duplicate limits.

**Architecture:** `Responses.SubmitIncomingRoll` recognizes `LOOT_BAN` as a recordable-but-ineligible submission. A dedicated helper writes the canonical roll fields directly as `INELIGIBLE / LOOT_BAN`, updates the normal roll tracker once, and never exposes a temporary eligible response.

**Tech Stack:** WotLK 3.3.5a, Lua 5.1.5, Python 3 `unittest`, existing Lua behavioral harness.

## Global Constraints

- Change only roll-response intake and focused tests unless a localized message is strictly required.
- The first valid open-session Loot Ban roll returns success, stores its numeric value, remains visible, and has Info `BAN`.
- The response is never `ROLL`, selectable, tied, or a winner at any observable point.
- Do not send a denial whisper for the recorded Loot Ban roll.
- Increment the canonical roll tracker exactly once.
- A second roll from the same banned player is rejected as `ROLL_LIMIT`, recorded only as an out-of-flow duplicate, and cannot replace `bestRoll`.
- Preserve all behavior for non-Loot-Ban ineligibility, late rolls, reserves, tie rerolls, passes, cancellations, and ordinary accepted rolls.
- Lua 5.1/WotLK 3.3.5a only; no XML, SavedVariables, wire, README, or `Libs/` changes.

---

### Task 1: Recordable Loot Ban Submission

**Files:**
- Modify: `Raid Management Addon/Services/Rolls/Responses.lua`
- Modify: `tests/test_loot_bans_contract.py`

**Interfaces:**
- Consumes: `Responses.REASONS.LOOT_BAN`, `ctx.addRoll`, current response tracker and session state.
- Produces: first submission `true, nil` plus response `{bestRoll, lastRoll, status=INELIGIBLE, reason=LOOT_BAN, isEligible=false}`; duplicate `false, ROLL_LIMIT`.

- [ ] **Step 1: Add a failing real submission test**

Extend the roll Lua harness to call the production `Responses.SubmitIncomingRoll` with `banned = true` before any roll. Assert after the first submission:

```lua
local ok, reason = Responses.SubmitIncomingRoll(ctx, "Alice", 87, "CHAT_MSG_SYSTEM")
assert(ok == true and reason == nil)
local response = state.responsesByPlayer.Alice
assert(response.bestRoll == 87 and response.lastRoll == 87)
assert(response.status == Responses.STATUS.INELIGIBLE)
assert(response.reason == Responses.REASONS.LOOT_BAN)
assert(response.isEligible == false)
assert(tracker.Alice == 1)
assert(#whispers == 0)
assert(#observedStatuses == 1 and observedStatuses[1] == Responses.STATUS.INELIGIBLE)
```

Build resolution and RollRows display from that response and assert it remains visible with `roll=87`, `infoText="BAN"`, `canClick=false`, and no winner/tie membership.

- [ ] **Step 2: Add duplicate expectations and verify RED**

Call submission again with `99`:

```lua
local duplicateOk, duplicateReason = Responses.SubmitIncomingRoll(ctx, "Alice", 99, "CHAT_MSG_SYSTEM")
assert(duplicateOk == false and duplicateReason == Responses.REASONS.ROLL_LIMIT)
assert(response.bestRoll == 87 and tracker.Alice == 1)
```

Run:

```powershell
py -3 -m unittest tests.test_loot_bans_contract.LootBansEnforcementContractTest -v
```

Expected: first submission currently returns `false, LOOT_BAN` and stores no `bestRoll`.

- [ ] **Step 3: Add an atomic blocked-roll writer**

Beside `applyAcceptedRollResponse`, add a focused helper that writes the same canonical roll metadata but never uses status `ROLL` or `isEligible=true`:

```lua
local function applyBlockedRollResponse(ctx, name, roll, eligibility, source)
    local _, state = assertContext(ctx)
    local response = getOrCreateResponse(state, name)
    response.bestRoll = tonumber(roll)
    response.lastRoll = tonumber(roll)
    response.status = RESPONSE_STATUS.INELIGIBLE
    response.explicitStatus = nil
    response.bucket = "INELIGIBLE"
    response.reason = reasonCodes.LOOT_BAN
    response.allowedRolls = 1
    response.usedRolls = 1
    response.source = source or "system_roll"
    response.updatedAt = GetTime()
    response.isEligible = false
    response.isOutOfTime = false
    return response
end
```

Keep the assignment atomic inside the helper; do not call `applyAcceptedRollResponse` and then reclassify.

- [ ] **Step 4: Route Loot Ban before the generic denial branch**

In `SubmitIncomingRoll`, after building eligibility and before `if not eligibility.ok`, handle `eligibility.reason == reasonCodes.LOOT_BAN`:

```lua
if eligibility.reason == reasonCodes.LOOT_BAN then
    if (tonumber(eligibility.usedRolls) or 0) >= 1 then
        recordOutOfFlowAttempt(state, player, reasonCodes.ROLL_LIMIT, roll, source)
        return false, reasonCodes.ROLL_LIMIT
    end
    if ctx.addRoll then
        ctx.addRoll(player, roll, context.itemId)
    end
    applyBlockedRollResponse(ctx, player, roll, eligibility, source)
    return true, nil
end
```

The implementation must derive tracker state after `ctx.addRoll` using the existing contract and must not emit a denial whisper. If `ctx.addRoll` does not update `eligibility.usedRolls`, the helper still writes `usedRolls=1` while the canonical tracker is verified by the test.

- [ ] **Step 5: Verify GREEN and all regressions**

```powershell
py -3 -m unittest tests.test_loot_bans_contract.LootBansEnforcementContractTest -v
py -3 -m unittest discover -s tests -p "test_*.py" -v
py -3 "C:\Users\ferra\Downloads\RMA-Raid Management Addon\.agents\skills\wow-addon-dev-wotlk-v335a\scripts\lint_lua51.py" "Raid Management Addon"
py -3 "C:\Users\ferra\Downloads\RMA-Raid Management Addon\.agents\skills\wow-addon-dev-wotlk-v335a\scripts\scan_xpcall.py" "Raid Management Addon"
git diff --check
```

Expected: all tests pass; validators exit 0.

- [ ] **Step 6: Commit**

```powershell
git add -- "Raid Management Addon/Services/Rolls/Responses.lua"
git add -f -- tests/test_loot_bans_contract.py
git commit -m "fix(loot): Keep banned player rolls visible"
```

### Task 2: Review And Manual Acceptance Status

- [ ] **Step 1: Review for transient eligibility and regression risk**

Confirm no branch calls `applyAcceptedRollResponse` for a Loot Ban, the response is written once as ineligible, duplicate attempts cannot replace the roll, and other denial reasons still use the existing generic branch.

- [ ] **Step 2: Record client smoke honestly**

After `/reload`, verify a pre-banned player rolling appears with their number and `BAN`, cannot win or be selected, sends no denial whisper, and a repeated roll does not replace the first. Do not claim this was observed unless run in the WotLK client.
