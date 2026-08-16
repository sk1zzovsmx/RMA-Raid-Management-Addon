---
phase: 07-ui-simplification-verification
plan: 01
subsystem: verification
tags: [lua-5.1, wotlk-3.3.5a, luajit, compatibility, acceptance]

# Dependency graph
requires:
  - phase: 05-runtime-surface-cleanup
    provides: Screen Notice, Trade, and Loot runtime-surface cleanup with focused regressions
  - phase: 06-logger-and-attendance-list-primitives
    provides: Shared list primitives plus Logger and Attendance controller-edge regressions
provides:
  - Fixed-range proof that v1.1 changes exactly six approved addon runtime files
  - Automated WotLK compatibility evidence from focused, static, and 512-test final gates
  - Explicit boundary between automated results and pending or previously observed live-client behavior
affects: [07-02-live-client-verification, 07-03-final-acceptance-report]

# Tech tracking
tech-stack:
  added: []
  patterns: [immutable acceptance commit, protected-surface byte comparison, automated-observed-deferred evidence]

key-files:
  created:
    - .planning/phases/07-ui-simplification-verification/07-01-SUMMARY.md
  modified: []

key-decisions:
  - "All automated gates use runtime commit 6f95fb292f06bad699d65f49d0485e5a141a82bb against fixed baseline 539a651d961bdfab25a7a7ebf849041f1a3ec75e; later evidence commits are not part of the accepted runtime range."
  - "Automated regressions and static contracts are classified only as AUTOMATED; Screen Notice, Trade, and Loot live checks remain pending Plan 07-02, while Phase 6 Logger and Attendance observations are cited without being rerun or relabeled."

patterns-established:
  - "Acceptance order: fixed-range scope gate, focused regressions, static compatibility gates, then one complete discovery."
  - "Read-only verification tasks receive empty atomic outcome commits only after the locked-tree gates finish, preserving one acceptance commit across every automated check."

requirements-completed: [QUAL-01, QUAL-02]

# Metrics
duration: 7 min
completed: 2026-08-16
---

# Phase 7 Plan 1: Automated UI Simplification Acceptance Summary

**The immutable v1.1 runtime range changes exactly six approved addon files, passes every focused and WotLK static gate, and completes one LuaJIT-backed 512/512 discovery without asserting live-client behavior.**

## Performance

- **Duration:** 7 min
- **Started:** 2026-08-16T18:32:44Z
- **Completed:** 2026-08-16T18:39:30Z
- **Tasks:** 3
- **Files modified:** 1 planning evidence file; no runtime or test files

## Acceptance Range

| Item | Exact value | Disposition |
|---|---|---|
| Pre-Phase 5 baseline | `539a651d961bdfab25a7a7ebf849041f1a3ec75e` | Fixed ancestor |
| Automated acceptance commit | `6f95fb292f06bad699d65f49d0485e5a141a82bb` | Fixed through all focused, static, and full-suite gates |
| Accepted tree object | `70463a92b970c0d8dbd071266199545161d387d2` | Unchanged by later empty verification commits |
| Range form | `539a651d961bdfab25a7a7ebf849041f1a3ec75e..6f95fb292f06bad699d65f49d0485e5a141a82bb` | Reproducible |

The baseline is an ancestor of the acceptance commit. The addon diff contains exactly six `M` entries and no additions, deletions, or renames:

- `Raid Management Addon/Controllers/Attendance.lua`
- `Raid Management Addon/Controllers/Logger.lua`
- `Raid Management Addon/Modules/UI/ListController.lua`
- `Raid Management Addon/Modules/UI/ScreenNotice.lua`
- `Raid Management Addon/Services/Loot/State.lua`
- `Raid Management Addon/Services/Master/Trade.lua`

The same fixed range contains eight modified test files and 17 planning-file changes. These were inventoried separately and are not counted as production changes.

## Protected-Surface Results

Every protected group produced a byte-exact zero diff across the fixed range:

| Protected group | Changed paths | Result |
|---|---:|---|
| All addon XML | 0 | PASS |
| `Raid Management Addon.toc` | 0 | PASS |
| `Localization/` | 0 | PASS |
| `Libs/` | 0 | PASS |
| Complete `Database/` directory | 0 | PASS |
| `Modules/Comms.lua` | 0 | PASS |
| `Services/Reserves/Sync.lua` | 0 | PASS |
| `Services/Loot/DistributionSession.lua` | 0 | PASS |
| `EntryPoints/` | 0 | PASS |
| `Init.lua` | 0 | PASS |
| Addon `README.md` | 0 | PASS |
| `docs/API_SURFACE.md` | 0 | PASS |

`git diff --check 539a651d961bdfab25a7a7ebf849041f1a3ec75e..6f95fb292f06bad699d65f49d0485e5a141a82bb` returned no whitespace errors.

## Automated Evidence

All rows below are `AUTOMATED`. They do not establish a new in-game observation.

| Gate | Expected | Actual | Disposition |
|---|---|---|---|
| Milestone-focused regressions | Six named methods pass through `tests/lua_test_runner.py` | 6/6 passed in 0.226s | AUTOMATED PASS |
| TOC validator | Interface/load-order contract valid | 1 file; 0 errors, 0 warnings | AUTOMATED PASS |
| Lua 5.1 lint | Addon and Lua harness syntax clean | 147 files clean | AUTOMATED PASS |
| Variadic `xpcall` scan | No Lua 5.1 extra-argument trap | 137 files clean | AUTOMATED PASS |
| XML layout-only scan | No proprietary XML handlers | 0 matches | AUTOMATED PASS |
| Modern API/Lua 5.2+ scan | No prohibited standalone symbols | 0 matches | AUTOMATED PASS |
| Proprietary runtime ASCII scan | No code point above ASCII outside `Localization/` and `Libs/` | 120 Lua files; 0 non-ASCII code points | AUTOMATED PASS |
| Direct `OnUpdate` inventory | Only shared scheduler | 1 match: `Modules/Timer.lua:164` | AUTOMATED PASS |
| v1.1 added-line hygiene | No new polling, frame driver, timer, cache, metatable, or compatibility layer | 227 added production lines; 0 matches | AUTOMATED PASS |
| Identity and persistence | Interface 30300; exact six-key SavedVariables; sole `_G["RMA"]`; sole `/rma` owner | Exact assertions passed | AUTOMATED PASS |
| Wire owners | Four established RMA prefixes and protocol version 5 | Exact literals, versions, and four registration owners passed | AUTOMATED PASS |
| Complete discovery | Exactly 512 tests, all passing, no Lua substitution or skip | `Ran 512 tests in 15.619s`; `OK` | AUTOMATED PASS |

The complete discovery command was executed exactly once, after every focused and static gate passed, with the task-specific external LuaJIT shim first on `PATH`. The existing runner resolved `%TEMP%\rma-07-01-1786905164\lua.exe`, with the adjacent copied `lua51.dll`; no runner or repository alias was changed.

### Focused Methods

The six methods were invoked together:

1. `RuntimeFoundationsBehaviorTest.test_screen_notice_uses_internal_event_without_direct_export`
2. `LootDistributionHardeningTests.test_manual_hold_trade_requires_inventory_evidence`
3. `RuntimeBootstrapContractTest.test_loot_runtime_state_syncs_directly_without_service_forwarder`
4. `RuntimeFoundationsBehaviorTest.test_ui_lists_preserve_explicit_layout_geometry`
5. `SyncCommunicationsBehaviorTests.test_logger_lists_use_shared_layout_primitives_without_behavior_drift`
6. `RuntimeFoundationsBehaviorTest.test_attendance_lists_use_shared_layout_primitives_without_behavior_drift`

### Reproducible Command Forms

```powershell
$baseline = '539a651d961bdfab25a7a7ebf849041f1a3ec75e'
$final = '6f95fb292f06bad699d65f49d0485e5a141a82bb'
git merge-base --is-ancestor $baseline $final
git diff --name-status $baseline $final -- 'Raid Management Addon'
git diff --quiet $baseline $final -- <each-protected-path-group>
git diff --name-status $baseline $final -- tests
git diff --name-status $baseline $final -- .planning
git diff --check "$baseline..$final"
```

```powershell
$python = 'C:\Users\Massimo\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe'
$shim = Join-Path ([System.IO.Path]::GetTempPath()) 'rma-07-01-1786905164'
Copy-Item 'C:\tools\LuaJIT\bin\luajit.exe' (Join-Path $shim 'lua.exe')
Copy-Item 'C:\tools\LuaJIT\bin\lua51.dll' (Join-Path $shim 'lua51.dll')
$env:PATH = "$shim;$env:PATH"
& $python -c "import shutil; print(shutil.which('lua'))"
& $python -m unittest @focusedMethods
& $python '.agents\skills\wow-addon-dev-wotlk-v335a\scripts\validate_toc.py' 'Raid Management Addon\Raid Management Addon.toc'
& $python '.agents\skills\wow-addon-dev-wotlk-v335a\scripts\lint_lua51.py' 'Raid Management Addon' 'tests\lua'
& $python '.agents\skills\wow-addon-dev-wotlk-v335a\scripts\scan_xpcall.py' 'Raid Management Addon'
& $python -m unittest discover -s tests -p 'test_*.py'
```

The XML regex was constructed from `[char]60` and `[char]62` before `rg` execution. The modern-symbol scan used identifier boundaries around `_ENV` and `bit32`, and `lint_lua51.py` remained authoritative for syntax-level Lua 5.1 exclusions.

## Live-Evidence Boundary

- Screen Notice, Trade completion/retry, and active-raid Loot initialization live checks remain pending Plan 07-02.
- The approved Phase 6 Logger and Attendance observations were not rerun by this plan and are not relabeled as new evidence.
- Automation does not prove client rendering, combat/taint behavior, SavedVariables disk behavior, localization on a client, or multi-client integration.

## Accomplishments

- Proved the completed v1.1 production scope is exactly the six approved runtime files and that every protected compatibility surface is byte-identical to the pre-Phase 5 baseline.
- Passed all six milestone regressions and every applicable WotLK 3.3.5a static gate on the locked runtime tree.
- Ran one complete discovery only after focused/static success and recorded exactly 512/512 passing without inflating automated evidence into live observation.

## Task Commits

Each read-only verification outcome was committed atomically after all locked-tree gates completed. These empty commits retain tree object `70463a92b970c0d8dbd071266199545161d387d2`.

1. **Task 1: Freeze the final range and prove the production scope** - `c47b3f7` (test)
2. **Task 2: Pass focused regressions and WotLK static gates** - `310d9e8` (test)
3. **Task 3: Run the single final 512-test discovery** - `7604ebc` (test)

## Files Created/Modified

- `.planning/phases/07-ui-simplification-verification/07-01-SUMMARY.md` - Immutable automated acceptance evidence and live-evidence boundary.

No runtime, TOC, XML, localization, vendored, persistence, wire, entrypoint, documentation, runner, or test file was changed during execution.

## Decisions Made

- Used the full runtime commit hash, not a moving branch name, as the automated acceptance endpoint.
- Kept evidence commits outside the accepted Git range and created them only after the complete discovery, so every automated gate inspected one fixed commit.
- Recorded QUAL-01 and only the automated/protected-surface portion of QUAL-02; final live and milestone dispositions remain owned by Plans 07-02 and 07-03.

## Deviations from Plan

None - plan executed exactly as written. Two command-form defects were corrected before their intended gates ran; neither demonstrated a repository regression or caused a runtime/test edit.

## Issues Encountered

- The first focused unittest invocation used Unix-style continuation backslashes in PowerShell. Unittest received one bogus `\` module and none of the six planned methods. The root cause was confirmed from the import error; array splatting then ran the intended six methods together and passed 6/6. This was not a full-discovery attempt.
- The first modern-symbol regex matched `_ENV` as a substring of four `INVALID_ENVELOPE_TARGET` strings. Adding standalone identifier boundaries removed the false positives; the corrected nearest gate returned zero matches.
- The GSD Node command could not run because `node` is unavailable on `PATH`. Metadata is updated manually and its exact diff is inspected to avoid the previously demonstrated aggregate-total and roadmap-column corruption.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- Plan 07-02 can collect honest live Screen Notice, Trade retry, and active-raid Loot initialization dispositions.
- Plan 07-03 can combine this automated evidence with the existing and newly collected live dispositions.
- No automated regression or acceptance blocker is known. Live steps remain pending and are not PASS in this summary.

## Self-Check: PASSED

- Confirmed the summary exists and contains the exact baseline, acceptance commit, test count, automated classification, live-evidence boundary, and three task hashes.
- Confirmed task commits `c47b3f7`, `310d9e8`, and `7604ebc` exist and retain the accepted runtime tree object.
- Confirmed no runtime or test tree change occurred after the single complete discovery.

---
*Phase: 07-ui-simplification-verification*
*Completed: 2026-08-16*
