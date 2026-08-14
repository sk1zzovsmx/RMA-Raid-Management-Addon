# Planned NID Handover Fix Report

## Scope

- Branch: `codex/single-raid-history-sharing`
- Base HEAD: `6cc548e` (`fix(sync): dedupe staged handover awards`)
- Runtime owner: `Raid Management Addon/Services/Raid/State.lua`
- Regression owner: `tests/lua/runtime_harness.lua`
- No SavedVariables, schema, TOC, addon-message prefix, or wire-format changes.
- The unrelated dirty `.superpowers/sdd/task-4-report.md` was preserved and excluded from this change.

## Behavior Delta

Before the fix, `EnsureRaidPlayerNid` accepted a staged `PLAYER_UPDATED` event,
reread unchanged canonical state, and returned player NID `0`. The following
staged `LOOT_ADDED` event therefore referenced no player and could not be
promoted atomically. Staged boss creation also set the runtime `lastBoss` value
and emitted canonical-success side effects even though canonical raid state had
not changed.

After the fix, player and boss prerequisite paths return their deterministic
planned NIDs only when the semantic store reports `HANDOVER_STAGED`. Ordinary
successful commits still read and return canonical state as before, ordinary
failures remain failures, and staged boss creation returns before canonical
last-boss/context/log success effects. Handover promotion replays exactly one
linked player, boss, and loot transaction for duplicate terminal `ITEM_DONE`
facts.

## TDD Evidence

Focused command:

```powershell
py -3 -m unittest tests.test_raid_replication_behavior.RaidReplicationBehaviorTests.test_duplicate_distribution_award_is_idempotent_during_handover -v
```

RED with real `Raid/State.lua`, real `Raid/Roster.lua`, and the real boss
prerequisite path:

- Exactly three prerequisites were staged, but promotion did not complete
  because the staged loot carried `looterNid = 0`.
- With only the boss staging guard removed, the same case failed explicitly:
  `staged boss prerequisite claimed a canonical last boss: expected 0, got 1`.

GREEN after the minimal production fix:

- Exit 0.
- `Ran 1 test in 0.046s`.
- `OK`.

The regression asserts that canonical player, boss, and loot collections remain
unchanged before promotion; `lastBoss` remains unset; promotion appends exactly
one player, boss, and loot row; loot NIDs link to the promoted player and boss;
the countable award increments `countMS` once; and sync ends at
`synchronized / UP_TO_DATE` without suspension.

## Test Evidence

Replication suite:

```powershell
py -3 -m unittest tests.test_raid_replication_behavior -v
```

- Exit 0.
- `Ran 47 tests in 2.024s`.
- `OK`.

Full suite:

```powershell
py -3 -m unittest discover -s tests -p "test_*.py" -q
```

- Exit 0.
- `Ran 337 tests in 10.668s`.
- `OK`.

## Validator Evidence

- TOC validator: exit 0, `OK: 0 error(s), 0 warning(s) in 1 file(s)`.
- Lua 5.1 validator: exit 0, `OK: 133 file(s) clean`.
- Lua 5.1 variadic `xpcall` scan: exit 0,
  `OK: 133 file(s) clean of variadic xpcall`.
- `stylua --check Raid Management Addon/Services/Raid/State.lua`: exit 0.
- `luacheck Raid Management Addon/Services/Raid/State.lua`: exit 0,
  `0 warnings / 0 errors`.
- XML script-handler scan: no matches (expected `rg` exit 1).
- `git diff --check`: exit 0; only Git line-ending notices were emitted.
- `tools/check-rma.ps1` was not run because this worktree and repository root do
  not contain that script.

The full `tests/lua/runtime_harness.lua` is not StyLua-clean at baseline. A
check of the committed HEAD version also exits 1. Luacheck reports the same six
pre-existing harness warnings on both HEAD and the changed file, with zero
errors and no new warnings.

## Residual Risk

- No live two-client WotLK 3.3.5a handover smoke test was available. The
  automated faithful live-replica fixture covers staging, duplicate terminal
  facts, atomic promotion, linked identifiers, counter replay, and final sync
  status, but in-game validation remains required before release confidence.

## Follow-Up: Multi-Player Planned NID Allocation

Re-review found that boss roster capture calls the real player prerequisite for
the already staged winner and for other missing connected members. Because the
canonical `nextPlayerNid` remains unchanged during handover, the prior fix could
stage the winner twice and assign the same planned NID to different names.

The real-helper regression now supplies two connected roster units: `Winner`
and `Helper`. Before production changes, the focused case failed with:

```text
duplicate ITEM_DONE or repeated roster name changed the planned transaction: expected 4, got 5
```

The sync stager now derives a bounded player projection from the canonical raid
plus the active handover's maximum 64 staged events. A repeated normalized name
reuses and replaces its staged update; a distinct name whose requested NID is
already used receives the next free sequential NID. The staged response carries
the adjusted payload so Raid State returns the planned NID to boss attendance
and loot callers. No independent projection table exists, so authority/raid
transition replaces its source handover, and rejected/full stage attempts
cannot reserve or leak allocator state.

The expanded regression proves before promotion that canonical players,
bosses, loot, and `lastBoss` remain unchanged. After promotion it proves:

- exactly two players, one boss, and one loot row;
- unique player NIDs for `Winner` and `Helper`;
- boss attendance linked to both planned player NIDs;
- loot linked to the winner and boss NIDs;
- one winner counter increment and no helper increment;
- duplicate terminal `ITEM_DONE` facts add no duplicate transaction; and
- final sync state is `synchronized / UP_TO_DATE` without suspension.

Fresh follow-up verification:

- Focused regression: exit 0, `Ran 1 test in 0.054s`, `OK`.
- Replication suite: exit 0, `Ran 47 tests in 2.043s`, `OK`.
- Full suite: exit 0, `Ran 337 tests in 10.681s`, `OK`.
- TOC: `OK: 0 error(s), 0 warning(s) in 1 file(s)`.
- Lua 5.1: `OK: 133 file(s) clean`.
- Variadic `xpcall`: `OK: 133 file(s) clean of variadic xpcall`.
- StyLua on both changed production files: exit 0.
- Luacheck on both changed production files: `0 warnings / 0 errors`.
- `git diff --check`: exit 0 with line-ending notices only.
