# Loot Ban Roll Tag Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep banned player rolls visible while rendering `BAN` in the Master roll-list Info column and preserving `BLK` for other ineligible responses.

**Architecture:** The existing response remains `INELIGIBLE` with reason `LOOT_BAN`; only the pure row-info projection changes. `Resolution.BuildRowInfoText` maps that specific reason to localized `BAN`, while display visibility continues to depend on the recorded roll value.

**Tech Stack:** WotLK 3.3.5a, Interface `30300`, Lua 5.1.5, Python 3 `unittest` with the existing Lua runtime harness.

## Global Constraints

- Add no response status, SavedVariable, wire field, or controller special case.
- Keep `LOOT_BAN` responses `INELIGIBLE` and non-selectable.
- Preserve the submitted roll value and visible row.
- Render localized `BAN` only for reason `LOOT_BAN`; preserve `BLK` for other ineligible reasons.
- Preserve all existing PASS, CANCELLED, OOT, OUT, reroll, duplicate, and tie precedence.
- Lua 5.1/WotLK 3.3.5a only; no XML, README, or `Libs/` changes.

---

### Task 1: Specific Loot Ban Info Tag

**Files:**
- Modify: `Raid Management Addon/Localization/localization.en.lua`
- Modify: `Raid Management Addon/Services/Rolls/Resolution.lua`
- Modify: `tests/test_loot_bans_contract.py`

**Interfaces:**
- Consumes: `response.status`, `response.reason`, `response.bestRoll`, `Responses.REASONS.LOOT_BAN`.
- Produces: `L.StrRollLootBanTag = "BAN"`; `Resolution.BuildRowInfoText(...) -> "BAN"` for Loot Ban only.

- [ ] **Step 1: Add a failing executable projection test**

Extend the existing Lua roll/display harness in `LootBansEnforcementContractTest` to build an already-recorded banned response and assert:

```lua
assert(response.bestRoll == 87)
assert(response.status == Responses.STATUS.INELIGIBLE)
assert(response.reason == Responses.REASONS.LOOT_BAN)
assert(Resolution.BuildRowInfoText(ctx, response, false) == "BAN")
```

Add a second ineligible response whose reason is `INELIGIBLE` and assert:

```lua
assert(Resolution.BuildRowInfoText(ctx, otherBlocked, false) == "BLK")
```

Also assert that the display row for the banned response remains present with `roll == 87` and `infoText == "BAN"`.

- [ ] **Step 2: Verify RED**

```powershell
py -3 -m unittest tests.test_loot_bans_contract.LootBansEnforcementContractTest -v
```

Expected: the new assertion receives `BLK` because no specific Loot Ban mapping exists.

- [ ] **Step 3: Add localized tag**

In `Localization/localization.en.lua` beside `L.StrRollBlockedTag` add:

```lua
L.StrRollLootBanTag = "BAN"
```

- [ ] **Step 4: Add the specific reason mapping without changing precedence**

Inside the existing `response.status == responseStatus.INELIGIBLE` branch of `Resolution.BuildRowInfoText`, after the `NOT_IN_RAID` and `REROLL_FILTERED` special cases and before the generic return, add:

```lua
if response.reason == reasonCodes.LOOT_BAN then
    return L.StrRollLootBanTag
end
return L.StrRollBlockedTag
```

- [ ] **Step 5: Verify GREEN and regression suite**

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
git add -- "Raid Management Addon/Localization/localization.en.lua" "Raid Management Addon/Services/Rolls/Resolution.lua"
git add -f -- tests/test_loot_bans_contract.py
git commit -m "feat(loot): Mark banned rolls in Info column"
```

### Task 2: Final Review And Manual Acceptance Status

- [ ] **Step 1: Review the complete delta**

Confirm the diff changes only localization, pure row-info projection, and focused tests. Verify no visibility filter, response transition, winner resolution, or controller code changed.

- [ ] **Step 2: Record manual smoke honestly**

After `/reload`, the client acceptance is:

1. A banned player rolls and remains listed with the submitted number.
2. Info shows `BAN`.
3. The row cannot be selected or marked winner.
4. Another non-Loot-Ban blocked response still shows `BLK`.

Do not claim this smoke was observed unless run in the WotLK client.
