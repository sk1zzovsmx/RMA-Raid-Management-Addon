# Loot Bans Optimization Audit Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Verify the complete Loot Bans slice and apply only measured, behavior-preserving reductions in runtime lookup cost and duplicated UI binding code.

**Architecture:** The audit first records a caller map and baseline. Two bounded candidates then require their own RED/GREEN evidence: submission-mode eligibility must defer the persistent ban lookup until structural gates pass, and Attendance must bind tooltip/click behavior through one local helper. A final report records executed deltas and rejects unsafe or low-ROI consolidation.

**Tech Stack:** World of Warcraft 3.3.5a build 12340, Interface `30300`, Lua 5.1.5, Python 3 `unittest`, PowerShell validation tools.

## Global Constraints

- Preserve all behavior listed in `docs/superpowers/specs/2026-07-12-loot-bans-optimization-audit-design.md`.
- Keep `Services/Raid/LootBans.lua` as the only runtime writer of persisted `lootBan` metadata.
- Preserve `RMA_Players`, the 240-ASCII note contract, fail-closed malformed records, and local-only state.
- Preserve visible pre-banned rolls, `BAN`/`BLK` mapping, reason precedence, duplicate limits, transaction atomicity, winners/ties, and every final award/trade guard.
- Preserve RaidGrid, popup, icons, tooltip, Attendance layout, row reuse, XML layout-only policy, and all user-facing behavior.
- Use only Lua 5.1 and WotLK 3.3.5a APIs; do not modify `Libs/`.
- Do not stage or commit the pre-existing `README.md` or `Raid Management Addon/README.md` changes.
- Apply no optimization without a failing call-count/duplication contract or a before/after measurement.
- Record rejected candidates; do not introduce compatibility aliases, pass-through wrappers, catch-all helpers, or speculative caching.

---

## File Map

| File | Responsibility |
|---|---|
| `docs/LOOT_BANS_OPTIMIZATION_AUDIT.md` | Tracked baseline, caller map, decisions, measurements, validation, and residual risks. |
| `Raid Management Addon/Services/Rolls/Responses.lua` | Defers the submission-only persistent ban lookup until structural gates pass. |
| `Raid Management Addon/Controllers/Attendance.lua` | Consolidates duplicate tooltip/click binding for name hotspot and status icon. |
| `tests/test_loot_bans_contract.py` | Adds behavioral lookup-count and shared-binding/reuse contracts. |

---

### Task 1: Baseline And Boundary Audit

**Files:**
- Create: `docs/LOOT_BANS_OPTIMIZATION_AUDIT.md`

**Interfaces:**
- Consumes: current repository, full test suite, validator outputs, `rg` caller maps, SLOC counts.
- Produces: an immutable `Before` baseline and explicit candidate decision table used by Tasks 2-4.

- [ ] **Step 1: Record repository state and baseline tests**

Run:

```powershell
git status --short --branch
git rev-parse --short HEAD
py -3 -m unittest tests.test_loot_bans_contract -v
py -3 -m unittest discover -s tests -p "test_*.py" -v
```

Record exact commit, dirty README state, focused/full test counts, and outcomes under `## Before Baseline`.

- [ ] **Step 2: Record SLOC and occurrence measurements**

Run:

```powershell
@(
  'Raid Management Addon/Services/Raid/LootBans.lua',
  'Raid Management Addon/Services/Rolls/Responses.lua',
  'Raid Management Addon/Services/Rolls/History.lua',
  'Raid Management Addon/Services/Rolls/Service.lua',
  'Raid Management Addon/Services/Master/AwardSequence.lua',
  'Raid Management Addon/Services/Master/TradeExecution.lua',
  'Raid Management Addon/Controllers/Master.lua',
  'Raid Management Addon/Controllers/Attendance.lua',
  'Raid Management Addon/Widgets/RaidGrid.lua',
  'tests/test_loot_bans_contract.py'
) | ForEach-Object { "$_`t$((Get-Content $_).Count)" }
rg -n "LootBans\.Get|LootBans\.IsActive|lootBans\.Get" "Raid Management Addon" -g "*.lua" -g "!Libs/**"
rg -n "lootBan\s*=|\[\s*['\"]lootBan['\"]\s*\]\s*=" "Raid Management Addon" -g "*.lua" -g "!Libs/**"
```

Copy exact counts and the sole-writer result into the audit.

- [ ] **Step 3: Write the caller map**

Document these exact flows with current filenames and function owners:

```text
Persistence: Master editor -> Raid.LootBans.Set/Remove -> RMA_Players -> LootBansChanged
Roll intake: SubmitIncomingRoll -> BuildCandidateEligibility -> History.AddRoll -> applyBlockedRollResponse
Roll display: SyncResponseEligibility -> Resolution.BuildRowInfoText -> RollRows.BuildModel
Loot award: AwardSequence final checks -> awardExecutor.Assign -> GiveMasterLoot
Inventory trade: TradeExecution final check -> effect/cursor -> InitiateTrade
UI refresh: LootBansChanged -> Master coalesced refresh / Attendance dirty / RaidGrid refresh
```

- [ ] **Step 4: Record candidate decisions**

Create this table with evidence-based decisions:

| Candidate | Decision | Required evidence |
|---|---|---|
| Submission lookup deferral | Apply | A structural denial currently performs one `LootBans.IsActive`; after patch it performs zero. |
| Attendance binding consolidation | Apply | Two duplicated binding blocks become one helper without changing scripts, click forwarding, or state. |
| Note validation micro-optimization | Reject | `string.len` is constant-time and note edits are not a hot path; no meaningful runtime benefit. |
| Award/trade guard consolidation | Reject | Separate physical effect boundaries and warning owners are intentional defense in depth. |
| Persistent lookup cache | Reject | Invalidation and external SavedVariables mutation risk exceed nine current read call sites. |
| Broad test-harness rewrite | Reject | High regression risk and no runtime product benefit. |

- [ ] **Step 5: Commit the baseline audit**

```powershell
git add -f -- docs/LOOT_BANS_OPTIMIZATION_AUDIT.md
git commit -m "docs(loot): Audit Loot Bans optimization baseline"
```

### Task 2: Defer Submission Ban Lookup Until Needed

**Files:**
- Modify: `Raid Management Addon/Services/Rolls/Responses.lua`
- Modify: `tests/test_loot_bans_contract.py`

**Interfaces:**
- Consumes: `opts.mode`, structural submission gates, `LootBans.IsActive(name)`.
- Produces: unchanged eligibility results with zero ban lookups for structurally denied submissions and one lookup for otherwise-valid submissions.

- [ ] **Step 1: Add a failing lookup-count test**

Extend the production roll harness with a counter in `LootBans.IsActive` and assert:

```lua
lootBanLookups = 0
state.canRoll = false
local ok, reason = Responses.SubmitIncomingRoll(ctx, "Alice", 87, "CHAT_MSG_SYSTEM")
assert(ok == false and reason == Responses.REASONS.SESSION_INACTIVE)
assert(lootBanLookups == 0)

state.canRoll = true
lootBanLookups = 0
local accepted, acceptedReason = Responses.SubmitIncomingRoll(ctx, "Alice", 87, "CHAT_MSG_SYSTEM")
assert(accepted == true and acceptedReason == nil)
assert(lootBanLookups == 1)
```

Repeat the zero-lookup assertion for NOT_IN_RAID and MANUAL_EXCLUSION. Preserve the existing non-submission test asserting `LOOT_BAN` precedence.

- [ ] **Step 2: Verify RED**

```powershell
py -3 -m unittest tests.test_loot_bans_contract.LootBansEnforcementContractTest -v
```

Expected: structural denial assertions observe one ban lookup.

- [ ] **Step 3: Compute ban state at the correct boundary**

Replace the unconditional early lookup with conditional evaluation:

```lua
if not deferLootBan and LootBans.IsActive(name) then
    return buildLootBanEligibility(opts, usedRolls, currentItemId, currentItemLink)
end
```

After session, roster, manual exclusion, reserve, and reroll gates, use:

```lua
if deferLootBan and LootBans.IsActive(name) then
    return buildLootBanEligibility(opts, usedRolls, currentItemId, currentItemLink)
end
```

Do not retain an `isLootBanned` local. Non-submission consumers still perform exactly one early lookup and retain `LOOT_BAN` precedence.

- [ ] **Step 4: Remove the unused blocked-writer parameter**

Change:

```lua
local function applyBlockedRollResponse(ctx, name, roll, source)
```

and update its only caller. The current `eligibility` parameter is unused and must not remain in the signature.

- [ ] **Step 5: Verify GREEN and commit**

```powershell
py -3 -m unittest tests.test_loot_bans_contract.LootBansEnforcementContractTest -v
py -3 -m unittest discover -s tests -p "test_*.py" -v
py -3 ".agents/skills/wow-addon-dev-wotlk-v335a/scripts/lint_lua51.py" "Raid Management Addon"
git diff --check
git add -- "Raid Management Addon/Services/Rolls/Responses.lua"
git add -f -- tests/test_loot_bans_contract.py
git commit -m "perf(loot): Defer denied-roll ban lookup"
```

### Task 3: Consolidate Attendance Tooltip Target Binding

**Files:**
- Modify: `Raid Management Addon/Controllers/Attendance.lua`
- Modify: `tests/test_loot_bans_contract.py`

**Interfaces:**
- Consumes: script-bearing hotspot/icon Buttons and current row click handler.
- Produces: `bindAttendanceLootBanTarget(target, row) -> boolean`, used by both cached UI targets.

- [ ] **Step 1: Add a failing shared-binding contract**

Add source and executable assertions:

```python
self.assertEqual(1, source.count("local function bindAttendanceLootBanTarget"))
self.assertIn("bindAttendanceLootBanTarget(hotspot, row)", source)
self.assertIn("bindAttendanceLootBanTarget(icon, row)", source)
self.assertEqual(1, source.count('SetScriptSafely(target, "OnEnter", showAttendanceLootBanTooltip)'))
self.assertEqual(1, source.count('SetScriptSafely(target, "OnLeave", HideTooltip)'))
```

Retain executable tests proving both targets forward the current row click, show the same note/title, and replace per-draw state.

- [ ] **Step 2: Verify RED**

```powershell
py -3 -m unittest tests.test_loot_bans_contract.LootBansAttendanceContractTest -v
```

Expected: shared helper assertions fail because bindings are duplicated.

- [ ] **Step 3: Implement one local binding helper**

Add beside `showAttendanceLootBanTooltip`:

```lua
local function bindAttendanceLootBanTarget(target, row)
    target._RMARow = row
    if target._RMALootBanTooltipBound then
        return true
    end
    local enterBound = SetScriptSafely(target, "OnEnter", showAttendanceLootBanTooltip)
    local leaveBound = SetScriptSafely(target, "OnLeave", HideTooltip)
    local clickBound = SetScriptSafely(target, "OnClick", function(self, button)
        local rowOnClick = self._RMARow and self._RMARow:GetScript("OnClick") or nil
        if rowOnClick then
            rowOnClick(self._RMARow, button)
        end
    end)
    target._RMALootBanTooltipBound = enterBound and leaveBound and clickBound
    return target._RMALootBanTooltipBound
end
```

In both `getAttendanceLootBanHotspot` and `getAttendanceLootBanIcon`, delete the duplicated binding blocks and call the helper on every draw so `_RMARow` is refreshed.

- [ ] **Step 4: Verify GREEN and commit**

```powershell
py -3 -m unittest tests.test_loot_bans_contract.LootBansAttendanceContractTest -v
py -3 -m unittest discover -s tests -p "test_*.py" -v
rg -n "<Scripts>|<On[A-Za-z]+>" "Raid Management Addon/UI" -g "*.xml"
py -3 ".agents/skills/wow-addon-dev-wotlk-v335a/scripts/lint_lua51.py" "Raid Management Addon"
git diff --check
git add -- "Raid Management Addon/Controllers/Attendance.lua"
git add -f -- tests/test_loot_bans_contract.py
git commit -m "refactor(attendance): Share Loot Ban target binding"
```

### Task 4: Final Measurements And Audit Closeout

**Files:**
- Modify: `docs/LOOT_BANS_OPTIMIZATION_AUDIT.md`

- [ ] **Step 1: Repeat baseline measurements**

Run the same SLOC, occurrence, writer, focused-test, and full-suite commands from Task 1. Add `## After Measurements` with exact before/after values and conservative executed deltas.

- [ ] **Step 2: Run complete validation**

```powershell
py -3 -m unittest discover -s tests -p "test_*.py" -v
if (Test-Path '.\tools\check-rma.ps1') { & .\tools\check-rma.ps1 } else { Write-Output 'UNAVAILABLE: tools/check-rma.ps1' }
stylua --check "Raid Management Addon"
luacheck "Raid Management Addon"
py -3 ".agents/skills/wow-addon-dev-wotlk-v335a/scripts/validate_toc.py" "Raid Management Addon/Raid Management Addon.toc"
py -3 ".agents/skills/wow-addon-dev-wotlk-v335a/scripts/lint_lua51.py" "Raid Management Addon"
py -3 ".agents/skills/wow-addon-dev-wotlk-v335a/scripts/scan_xpcall.py" "Raid Management Addon"
rg -n "<Scripts>|<On[A-Za-z]+>" "Raid Management Addon/UI" -g "*.xml"
rg -n "lootBan\s*=|\[\s*['\"]lootBan['\"]\s*\]\s*=" "Raid Management Addon" -g "*.lua" -g "!Libs/**"
git diff --check
git status --short --branch
```

Record pass/fail/unavailable status exactly. Whole-tree EOL drift and manual client smoke must remain explicit rather than reported as passed.

- [ ] **Step 3: Complete the decision and residual-risk sections**

Add:

```text
Applied: submission lookup deferral; Attendance target-binding consolidation.
Rejected: note micro-optimization; guard consolidation; persistent cache; broad test rewrite.
Manual smoke: not run unless directly observed in WotLK 3.3.5a.
Residual risk: popup/icon/tooltip layout and physical award/trade timing remain client-only acceptance.
```

- [ ] **Step 4: Commit the closeout report**

```powershell
git add -f -- docs/LOOT_BANS_OPTIMIZATION_AUDIT.md
git commit -m "docs(loot): Close Loot Bans optimization audit"
```
