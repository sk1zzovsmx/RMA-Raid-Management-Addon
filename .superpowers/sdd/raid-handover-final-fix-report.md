# Raid Handover Final Fix Report

## Outcome

DONE. Duplicate distribution `ITEM_DONE` facts no longer stage duplicate player and boss prerequisites while the new raid leader is recovering authority. Promotion replays one complete award transaction and finishes synchronized.

## Root Cause

`DBSyncer` deduplicated only the staged `LOOT_ADDED` row by its distribution award `rollSessionId`. The real `Loot.Service:RecordDistributionAward` path calls `LogTradeOnlyLoot`, which can stage `PLAYER_UPDATED` and `BOSS_UPDATED` before `LOOT_ADDED`. A duplicate `ITEM_DONE` replay repeated those prerequisites before reaching the already-deduplicated loot row. Promotion then rejected the repeated entity event and suspended the syncer.

`Recording.Append` also accepted the store's `{ staged = true }`, `HANDOVER_STAGED` result pair as if the second return were canonical raid state. The prior defensive loop happened not to raise for the minimal token, but the non-canonical outcome was not explicit or preserved.

## TDD Evidence

The store-only handover regression was replaced with a real `Loot.Service` distribution callback path backed by the real raid store and syncer. The fixture creates a missing player and boss through semantic store commits, then calls the registered distribution callback for `item_done` and `item_done_replay`.

RED:

```text
duplicate ITEM_DONE repeated the staged player/boss/loot transaction:
expected 3, got 5
```

The five rows were the intended `PLAYER_UPDATED`, `BOSS_UPDATED`, and `LOOT_ADDED`, followed by duplicate player and boss prerequisites.

A second RED assertion required `Recording.Append` to return `HANDOVER_STAGED` as its explicit non-canonical outcome; the old implementation returned `nil`.

GREEN:

- The duplicate award is correlated by its existing distribution award ID (`rollSessionId`) while the matching handover is active.
- `RecordDistributionAward` acknowledges an award already included in handover replay before calling `LogTradeOnlyLoot` again.
- `Recording.Append` rejects non-table state, does not index the staging token, and preserves the staging/failure reason in its fourth return.

## Acceptance Criteria

| Criterion | Status | Evidence |
|---|---|---|
| Exercise duplicate `ITEM_DONE` through real Loot Service callback path | PASS | `raid_handover_duplicate_distribution_award_is_idempotent` loads real `Recording.lua` and `Service.lua` and invokes the registered distribution callback twice. |
| Require player and boss prerequisites | PASS | Regression stages semantic `PLAYER_UPDATED` and `BOSS_UPDATED` before real `LOOT_ADDED`. |
| Deduplicate the complete award transaction by roll session identity | PASS | Active handover exposes exact staged award membership; replay remains at three staged rows. |
| Promote exactly one player, boss, and loot row | PASS | Regression asserts one row in each canonical collection and sequence advancement of exactly three. |
| Promotion must not suspend | PASS | Regression asserts handover cleared and sync status `synchronized`, reason `UP_TO_DATE`. |
| Handle staging tokens as non-canonical | PASS | `loot_semantic_store_failure_is_atomic` asserts no mutation and explicit `HANDOVER_STAGED` outcome. |
| Preserve non-handover behavior | PASS | Focused suites (155 tests) and full suite (337 tests) pass. |
| No wire format, schema, SavedVariables, TOC, XML handler, or polling change | PASS | Diff is limited to internal sync query, Loot Service/Recording behavior, tests, and this report. |

## Behavior Delta

- Old behavior: duplicate distribution completion during handover could restage identical prerequisite entity events and make promotion fail atomically with a duplicate-event reason.
- New behavior: once a distribution award ID is already staged in the active matching handover, later completion replay acknowledges the same transaction without recreating prerequisites.
- Reason: `ITEM_DONE` is a retry-safe terminal fact; its complete canonical transaction must therefore be idempotent.
- Classification: old behavior was broken and could suspend raid-history replication during ordinary leader handover.
- Compatibility: no public, persisted, or wire contract changes. Normal authoritative commits outside handover retain the existing path.
- Migration: none.

## Validation

- Focused Loot/replication/recording suites: `155` tests passed.
- Full Python/Lua harness suite: `337` tests passed.
- TOC validator: `0` errors, `0` warnings in `1` file.
- Lua 5.1 validator: `133` files clean.
- Variadic `xpcall` scan: `133` files clean.
- Luacheck: `0` warnings, `0` errors in `120` files.
- Scoped StyLua check: changed production Lua files clean.
- XML handler scan: no `<Scripts>` or `<On...>` matches.
- `git diff --check`: clean.
- `tools/check-rma.ps1`: not run because the script is absent from both this worktree and the parent repository.

## Residual Risk

No automated WoW client is available, so the in-game leader-handover smoke test remains unexecuted. The real Lua service/store/syncer harness covers the failing transaction and promotion state, including the exact no-suspension outcome.
