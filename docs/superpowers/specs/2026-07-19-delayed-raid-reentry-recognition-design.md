# Delayed Raid Re-entry Recognition Design

## Problem

On WotLK 3.3.5a, `GetInstanceInfo()` may not expose the raid context during
the first `PLAYER_ENTERING_WORLD` callback. RMA currently emits
`RaidInstanceRecognized` only from that immediate path and related WoW zone
events. The later `CheckInitialRaidState()` call can see the raid, but it calls
`Raid:Check()` directly.

When an active persisted raid exists, `Raid:Check()` correctly stops at the
recovery-before-write barrier. Because the delayed path never notifies the
sync owner, recovery does not start, no re-entry popup appears, and no current
raid can be selected or created.

Runtime evidence confirms the blocked state: the client is in a raid, is the
Raid Leader with roster rank 2, has one persisted `active` record, and has no
current raid selected.

## Chosen Design

Keep instance recognition and event publication owned by `Init.lua`.
`PLAYER_ENTERING_WORLD` will retain the existing immediate recognition attempt
and the existing single three-second initial check. When that delayed callback
runs, it will refresh the instance datasets through the same
`handleRaidInstanceInfoChanged()` path before running
`CheckInitialRaidState()`.

If the instance is then recognized, the existing helper publishes
`RaidInstanceRecognized`; `DBSyncer` starts recovery and the ordinary session
check remains blocked until the user resolves the re-entry decision. If the
instance is still unavailable or unmapped, no event is published and existing
behavior is preserved.

This design deliberately does not make `Session.lua` publish sync events. It
also does not add a timer, retry loop, fallback raid creation, wire-format
change, or SavedVariables migration.

## Alternatives Rejected

1. Remove or weaken `AUTHORITY_RECOVERING` in `Session:Check()`. This would
   restore raid creation but violate recovery-before-write and could create a
   competing raid UID.
2. Publish `RaidInstanceRecognized` from `Session.lua`. This would mix session
   state checks with bootstrap/event ownership and duplicate the recognition
   policy already present in `Init.lua`.
3. Add another polling scheduler. The existing delayed login callback is enough
   to reproduce and solve the observed failure; another retry mechanism is not
   justified.

## Data Flow

1. `PLAYER_ENTERING_WORLD` performs the current immediate recognition attempt.
2. The existing three-second timer fires.
3. The timer calls `handleRaidInstanceInfoChanged()`.
4. A valid raid context publishes `RaidInstanceRecognized`.
5. `DBSyncer` starts re-entry recovery for the persisted active raid.
6. `CheckInitialRaidState()` runs but cannot write while recovery is active.
7. Recovery selects the best valid snapshot and requests the existing Yes/No
   decision.

## Error Handling

- An unavailable, non-raid, or unmapped instance remains a no-op.
- Recovery conflict and digest behavior remain unchanged and fail closed.
- Duplicate recognized events remain safe through the existing `_reentry` and
  `_discovery` guards.
- The current raid is never created while an active persisted raid is waiting
  for recovery.

## Verification

Add an end-to-end harness regression in which:

- `PLAYER_ENTERING_WORLD` initially returns a non-raid/unavailable context;
- the client is already the resolved Raid Leader;
- a valid active raid is persisted and no current raid is selected;
- the context becomes Naxxramas 25-player difficulty 2 before the existing
  delayed callback fires;
- firing that callback starts re-entry and eventually shows exactly one popup;
- no competing `RAID_CREATED` event is emitted before the decision.

Then run the focused re-entry tests, replication/communications tests, the full
Python suite, WotLK TOC and Lua 5.1 validators, the `xpcall` scan, XML handler
scan, `luacheck`, and `git diff --check`. Final acceptance remains the in-game
reload smoke for both Yes and No decisions.

## Scope And Compatibility

- Runtime target remains WotLK 3.3.5a, Interface 30300, Lua 5.1.
- No public API, addon-message protocol, SavedVariables schema, or UI layout
  changes.
- Intended improvement: runtime safety and data integrity during Raid Leader
  reload inside an active raid instance.
