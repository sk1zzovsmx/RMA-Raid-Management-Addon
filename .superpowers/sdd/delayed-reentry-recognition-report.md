# Delayed Re-entry Recognition Report

## Scope

Task: republish the existing `RaidInstanceRecognized` flow when delayed login
instance data becomes valid, before `CheckInitialRaidState()` evaluates the
session write barrier.

Changed task files only:

- `Raid Management Addon/Init.lua`
- `tests/lua/runtime_harness.lua`
- `tests/test_raid_replication_behavior.py`
- this report

No changes were made to `Session.lua`, timer/retry policy, SavedVariables,
addon-message wire format, or public interfaces.

## RED Evidence

Command:

```powershell
python -m unittest tests.test_raid_replication_behavior.RaidReplicationBehaviorTests.test_reentry_starts_when_instance_context_settles_after_login -v
```

Output before the runtime change:

```text
FAIL: test_reentry_starts_when_instance_context_settles_after_login
AssertionError: ... runtime_harness.lua:13: settled delayed instance context did not start re-entry recovery
Ran 1 test in 0.053s
FAILED (failures=1)
```

This proved that the delayed `CheckInitialRaidState` path did not republish
`RaidInstanceRecognized`, leaving `DB.Syncer._reentry` nil.

## GREEN Evidence

Runtime change in the existing delayed `PLAYER_ENTERING_WORLD` callback:

```lua
handleRaidInstanceInfoChanged()
module:CheckInitialRaidState()
```

The test fixture now controls production `GetInstanceInfo` through
`productionInstanceReady`; both existing fixture stubs use the same resolver.
The regression restores the leader production `UnitName` fixture after creating
`ReplicaB`, matching the neighboring production re-entry case. Without that
setup, the shared harness global points at `ReplicaB` and the leader cannot
recognize the responder; this is fixture isolation only, not runtime behavior.

Focused command:

```powershell
python -m unittest tests.test_raid_replication_behavior.RaidReplicationBehaviorTests.test_reentry_starts_when_instance_context_settles_after_login -v
```

Output:

```text
test_reentry_starts_when_instance_context_settles_after_login ... ok
Ran 1 test in 0.049s
OK
```

Nearby replication/authority suite:

```powershell
python -m unittest tests.test_raid_replication_behavior -v
```

Output: `Ran 96 tests in 3.919s` / `OK`.

The new case verifies unavailable login context does not start recovery or
select a current raid; after the existing delayed callback sees a settled raid
context, recovery starts before the guarded session check, no competing
`RAID_CREATED` event is emitted, and exactly one re-entry popup is shown.

## Final Verification

```powershell
python -m unittest discover -s tests -p "test_*.py"
py -3 "C:\Users\ferra\Downloads\RMA-Raid Management Addon\.agents\skills\wow-addon-dev-wotlk-v335a\scripts\validate_toc.py" "Raid Management Addon\Raid Management Addon.toc"
py -3 "C:\Users\ferra\Downloads\RMA-Raid Management Addon\.agents\skills\wow-addon-dev-wotlk-v335a\scripts\lint_lua51.py" "Raid Management Addon"
py -3 "C:\Users\ferra\Downloads\RMA-Raid Management Addon\.agents\skills\wow-addon-dev-wotlk-v335a\scripts\scan_xpcall.py" "Raid Management Addon"
rg -n "<Scripts>|<On[A-Za-z]+>" "Raid Management Addon\UI" -g "*.xml"
luacheck "Raid Management Addon" --exclude-files "Raid Management Addon/Libs/**"
git diff --check
```

Results:

- Python suite: `Ran 391 tests in 12.238s` / `OK`.
- TOC: `OK: 0 error(s), 0 warning(s) in 1 file(s)`.
- Lua 5.1: `OK: 134 file(s) clean`.
- Variadic `xpcall`: `OK: 134 file(s) clean of variadic xpcall`.
- XML handler scan: no matches (the `rg` exit code was 1, the expected negative result).
- `luacheck`: no errors; one existing warning in untouched
  `Raid Management Addon/Database/DBSyncer.lua:935:96-99` (`W542 empty if branch`).
- `git diff --check`: passed; only Git's existing LF-to-CRLF checkout notices appeared.

## Self-review

- The refresh calls the existing local helper and occurs immediately before the
  existing guarded session check, so no timer, retry, API, schema, or wire
  contract changed.
- The regression executes the complete production-shaped entry path with an
  active persisted raid and nil current raid; it catches the original deadlock
  and guards against a competing raid creation or duplicate popup.
- The mutable instance fixture has no effect unless a test explicitly sets
  `productionInstanceReady = false`.
- `Session.lua`, task-4 evidence, and `.planning/` were not changed.

## Remaining Manual Smoke Risk

An in-game WotLK 3.3.5a reload smoke remains required: enter with delayed
instance data and an active persisted raid, then confirm Yes resumes the same
UID and No concludes it before creating exactly one new UID. No deploy was
performed by this task.
