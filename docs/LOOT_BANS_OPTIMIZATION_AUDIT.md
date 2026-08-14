# Loot Bans Optimization Audit

This document records the immutable before-state and ownership boundaries for the behavior-preserving Loot Bans optimization. It does not authorize changes outside the two accepted candidates below.

## Before Baseline

- Baseline commit: `293c719`
- Branch: `codex/loot-bans-optimization-work`
- Worktree state: clean; `git status --short --branch` reported only the branch header. No dirty README files were present in this isolated worktree.
- Focused contract suite: `py -3 -m unittest tests.test_loot_bans_contract -v` passed 40 of 40 tests in 0.453 seconds.
- Full suite: `py -3 -m unittest discover -s tests -p "test_*.py" -v` passed 52 of 52 tests in 0.458 seconds.

## Before Measurements

Physical line counts from PowerShell `Get-Content` are:

| File | Lines |
|---|---:|
| `Raid Management Addon/Services/Raid/LootBans.lua` | 93 |
| `Raid Management Addon/Services/Rolls/Responses.lua` | 1003 |
| `Raid Management Addon/Services/Rolls/History.lua` | 199 |
| `Raid Management Addon/Services/Rolls/Service.lua` | 730 |
| `Raid Management Addon/Services/Master/AwardSequence.lua` | 496 |
| `Raid Management Addon/Services/Master/TradeExecution.lua` | 759 |
| `Raid Management Addon/Controllers/Master.lua` | 3639 |
| `Raid Management Addon/Controllers/Attendance.lua` | 1238 |
| `Raid Management Addon/Widgets/RaidGrid.lua` | 482 |
| `tests/test_loot_bans_contract.py` | 1224 |

The requested read-occurrence search returned nine lines: three `LootBans.Get` UI consumers (`Master.lua:624`, `Master.lua:655`, and `Attendance.lua:1059`), one `LootBans.IsActive` roll consumer (`Responses.lua:592`), two injected-owner reads (`AwardSequence.lua:174` and `TradeExecution.lua:217`), and the `Get` definition, `IsActive` definition, and `IsActive`-to-`Get` delegation in `LootBans.lua:46`, `:65`, and `:66`. Thus the measured footprint is nine read-related occurrences, comprising six external consumer call sites plus the owner definitions/delegation.

The requested writer search returned only `Raid Management Addon/Services/Raid/LootBans.lua`: `Set` assigns the canonical `{ active = true, note = cleanNote }` record at line 78, `Remove` checks the field at line 85, and `Remove` clears it at line 88. The sole runtime writer is therefore `Raid.LootBans`; the line-85 match is a guard, not a write.

## Caller And Ownership Map

- Persistence: the Loot Ban editor in `Controllers/Master.lua` calls `Raid.LootBans.Set` or `Raid.LootBans.Remove`; `Services/Raid/LootBans.lua` alone writes `RMA_Players[*].lootBan` and emits `LootBansChanged` through the event bus.
- Roll intake: `Services/Rolls/Service.lua` forwards to `Responses.SubmitIncomingRoll`; `Services/Rolls/Responses.lua` owns `SubmitIncomingRoll`, calls `Responses.BuildCandidateEligibility`, commits through `History.AddRoll` in `Services/Rolls/History.lua`, and applies a blocked projection through local `applyBlockedRollResponse`.
- Roll display: `Responses.SyncResponseEligibility` refreshes eligibility; `Services/Rolls/Display.lua` projects `Resolution.BuildRowInfoText`; the Master roll-selection controller then delegates row construction to `Services/Master/RollRows.lua` `RollRows.BuildModel`.
- Loot award: `Services/Master/AwardSequence.lua` owns the final Loot Ban checks immediately before setting the effect and calling `awardExecutor:Assign`; `Controllers/Master.lua` owns the executor boundary and ultimately calls the WotLK `GiveMasterLoot` API.
- Inventory trade: `Services/Master/TradeExecution.lua` owns the final Loot Ban check before creating/advancing the award effect, manipulating the item cursor, and calling the WotLK `InitiateTrade` API.
- UI refresh: `LootBansChanged` causes `Controllers/Master.lua` to request its coalesced model refresh and refresh a visible Loot Ban `Widgets.RaidGrid`; `Controllers/Attendance.lua` marks its attendance lists dirty. The RaidGrid is a projection/rendering owner and does not read persistence or own Loot Ban policy.

## Candidate Decisions

| Candidate | Decision | Required evidence |
|---|---|---|
| Submission lookup deferral | Apply | A structural denial currently performs one `LootBans.IsActive`; after patch it performs zero. |
| Attendance binding consolidation | Apply | Two duplicated binding blocks become one helper without changing scripts, click forwarding, or state. |
| Note validation micro-optimization | Reject | `string.len` is constant-time and note edits are not a hot path; no meaningful runtime benefit. |
| Award/trade guard consolidation | Reject | Separate physical effect boundaries and warning owners are intentional defense in depth. |
| Persistent lookup cache | Reject | Invalidation and external SavedVariables mutation risk exceed nine read-related occurrences (six external consumer call sites). |
| Broad test-harness rewrite | Reject | High regression risk and no runtime product benefit. |

The accepted work is a maintainability and targeted performance improvement only. The rejected candidates preserve the existing persistence owner, final-effect defenses, SavedVariables mutation tolerance, and behavior-focused test boundary.

## After Measurements

Measurements were repeated at commit `bea59fb` with the same commands used for the before baseline.

| File | Before | After | Delta |
|---|---:|---:|---:|
| `Raid Management Addon/Services/Raid/LootBans.lua` | 93 | 93 | 0 |
| `Raid Management Addon/Services/Rolls/Responses.lua` | 1003 | 1001 | -2 |
| `Raid Management Addon/Services/Rolls/History.lua` | 199 | 199 | 0 |
| `Raid Management Addon/Services/Rolls/Service.lua` | 730 | 730 | 0 |
| `Raid Management Addon/Services/Master/AwardSequence.lua` | 496 | 496 | 0 |
| `Raid Management Addon/Services/Master/TradeExecution.lua` | 759 | 759 | 0 |
| `Raid Management Addon/Controllers/Master.lua` | 3639 | 3639 | 0 |
| `Raid Management Addon/Controllers/Attendance.lua` | 1238 | 1233 | -5 |
| `Raid Management Addon/Widgets/RaidGrid.lua` | 482 | 482 | 0 |
| `tests/test_loot_bans_contract.py` | 1224 | 1311 | +87 |

The read-occurrence search now returns ten lines rather than nine. The increase is intentional: the submission path in `Responses.lua` has separate early and deferred textual `LootBans.IsActive` call sites. It is not an execution increase. Instrumented tests prove that session-inactive, not-in-raid, manually excluded, unreserved reserved-roll, and reroll-filtered submissions each execute zero lookups instead of one; an otherwise-valid banned submission still executes exactly one. Non-submission precedence remains unchanged.

The writer search still returns the same three lines in `Services/Raid/LootBans.lua`: two assignments and the `Remove` guard. `Raid.LootBans` remains the sole runtime writer.

The focused Loot Bans contract suite increased from 40 to 42 tests and passed 42 of 42 in 0.474 seconds. The full suite increased from 52 to 54 tests and passed 54 of 54 in 0.487 seconds. Attendance physical lines decreased by five; its non-blank runtime SLOC decreased by six, from 1123 to 1117. The duplicated target-specific binding bodies were replaced by one shared helper called for both targets on every draw.

## Final Validation

| Check | Result |
|---|---|
| Full Python suite | PASS: 54 of 54 tests |
| `tools/check-rma.ps1` | UNAVAILABLE: file is not present |
| Whole-tree `stylua --check` | FAIL: 131 files report formatting differences dominated by repository-wide EOL drift; no bulk rewrite was performed |
| Whole-tree `luacheck` | PASS: 0 warnings and 0 errors in 119 files |
| TOC validator | PASS: 0 errors and 0 warnings in 1 file |
| Lua 5.1 validator | PASS: 132 files clean |
| Lua 5.1 variadic `xpcall` scan | PASS: 132 files clean |
| XML script-handler scan | PASS: no matches (an `rg` exit code of 1 means no match) |
| Loot Ban writer scan | PASS: unchanged three matches in the sole owner |
| `git diff --check` | PASS |
| Worktree status before report edit | Clean on `codex/loot-bans-optimization-work` |

The skill validator scripts are not versioned inside this isolated worktree, so the documented relative commands were unavailable there. The same validators were run successfully from the project-local skill path in the parent workspace against this worktree's addon files. Whole-tree StyLua remains explicitly failed; the touched Attendance file passed its focused StyLua check in Task 3. No manual WotLK 3.3.5a client smoke was run.

## Final Decisions And Residual Risk

- Applied: submission lookup deferral; Attendance target-binding consolidation.
- Rejected: note micro-optimization; guard consolidation; persistent cache; broad test rewrite.
- Manual smoke: not run because it was not directly observed in a WotLK 3.3.5a client.
- Residual risk: popup, icon, and tooltip layout plus physical award/trade timing remain client-only acceptance points.

No SavedVariables schema, wire format, TOC load order, XML layout, localization, or vendored dependency changed. The audit therefore closes with demonstrated lookup reduction and reduced Attendance duplication, while retaining the existing persistence owner and final-effect defenses.
