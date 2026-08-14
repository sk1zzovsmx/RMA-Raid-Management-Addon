# Popup Roster Retry Report

## Scope

- Fixed the missing raid re-entry decision after login when
  `RaidInstanceRecognized` arrives before the WotLK raid roster exposes the
  local player as Raid Leader.
- Reused the existing single 3-second discovery timer and its recognized
  instance context.
- Did not change SavedVariables, sync messages, member late-join discovery,
  fresh raid bootstrap, handover, digest conflict, or no-copy policies.

## TDD Evidence

### RED

Added
`raid_reentry_retries_once_after_leader_roster_settlement`, using the real
`Init.lua`, `Session.lua`, `State.lua`, and `Capabilities.lua` owners with:

- a persisted active archive record;
- `Database.GetCurrentRaid() == nil`;
- an initially unsettled production roster rank;
- the roster becoming settled before the bounded retry fires.

Before editing runtime code, the focused test failed with:

```text
unsettled leader discovery did not retain the recognized context
```

This proved the reported race: the active record path cancelled discovery and
never reached `startReentry` after leadership settled.

The review then exposed a second, narrower settlement state. A new regression,
`raid_reentry_waits_for_leader_identity_after_role_settlement`, separated the
local leader role from the roster leader identity. Before the second runtime
edit it failed with:

```text
leader role without matching identity started re-entry recovery
```

That RED proved that checking only `Raid:IsRaidLeader()` could start recovery
while `Raid:GetRaidLeaderName()` was still unresolved.

A final discriminating step exercised the immediate event path rather than the
timer callback: after `PLAYER_ENTERING_WORLD`, only the local role settled and
`ZONE_CHANGED_NEW_AREA` fired before the discovery timer. Before the uniform
guard was added, it failed with:

```text
leader role without matching identity started immediate re-entry recovery
```

The immediate path now applies the same role-and-identity requirement and
leaves the original bounded discovery handle active while identity is
unresolved.

### GREEN

`DBSyncer.lua` now retains the recognized instance name and difficulty only
for the existing bounded discovery attempt. Its callback refreshes authority
once and starts re-entry only when all four facts are true:

- an active archive record still exists;
- no current raid is selected;
- the production raid capability now reports the local Raid Leader role;
- the normalized roster leader identity matches the local player.

If an active record remains but the client is not Raid Leader, the callback
terminates without another retry.

The immediate recognized-instance path enforces the same four facts. A partial
role-only settlement falls through to the already scheduled discovery attempt;
it does not create another scheduler or retry.

The positive regression now enters through `PLAYER_ENTERING_WORLD`, identifies
the discovery timer through `syncer._discovery.timer`, and keeps the concurrent
3-second `CheckInitialRaidState` timer active. After both role and identity
settle, it observes exactly one re-entry decision and one popup. The partial
settlement regression proves that role alone terminates the bounded attempt
without recovery or another timer.

The production-capability fixture leaves `UnitIsGroupLeader` unavailable and
uses the WotLK `_G.IsRaidLeader` fallback owned by `Init.lua`; no Retail API was
introduced.

## Files

- `Raid Management Addon/Database/DBSyncer.lua`
- `tests/lua/runtime_harness.lua`
- `tests/test_raid_replication_behavior.py`

## Verification

- Focused re-entry and unresolved-authority checks: 9 passed.
- Replica and sync communications checks: 35 passed.
- Full repository suite: 390 passed.
- TOC validation: passed.
- Lua 5.1 validation: 134 files clean.
- Lua 5.1 `xpcall` scan: 134 files clean.
- XML script-handler scan: no matches.
- `git diff --check`: passed.

## Residual Concern

Automated coverage reproduces the WotLK roster-settlement ordering, but the
actual login/reload popup must still be smoke-tested in game. No deployment or
integration was performed.
