# Raid Reentry Check Fix

**Date:** 2026-07-26

## Problem

After a client restart, `Database.GetCurrentRaid()` is nil because the current
selection is runtime-only. The persistent raid archive can still contain an
active record through `activeRaidUid`.

`Raid:Check()` previously interpreted the nil runtime selection as absence of a
raid, attempted `Raid:Create()`, and ignored its result. The store correctly
rejected that duplicate creation with `ACTIVE_RAID_EXISTS`, leaving the runtime
without a selected raid.

## Behavior

`Raid:Check()` distinguishes the two persistent states:

- If the raid store contains an active record, it does not create another raid
  and returns `false, "RAID_REENTRY_REQUIRED"`. The existing `DBSyncer` and
  Logger Resume/Replace popup continue to own recovery and user choice.
- If the raid store has no active record, it calls `Raid:Create()` once and
  returns that method's result unchanged.

Existing authority-recovery and current-session change behavior remains
unchanged.

## Ownership And Compatibility

- `Services/Raid/Session.lua` owns the create-or-defer decision.
- `Database/DBSyncer.lua` owns reentry synchronization.
- `Services/Raid/State.lua` owns Resume/Replace application.
- `Controllers/Logger.lua` owns the popup.
- `Database/DBRaidStore.lua` remains the canonical active-raid store.

The fix adds no module, persistence field, migration, wire-format change,
localization string, UI frame, or public API.

## Verification

Behavior tests cover:

1. Persistent active raid: defer without calling `Raid:Create()`.
2. No persistent active raid: call `Raid:Create()` exactly once and preserve its
   return values.
3. Rejected creation: preserve the original failure reason.
4. Existing reentry, replication, and loot-distribution behavior.

An in-game smoke test should verify that `/reload` presents Resume/Replace for
an active archived raid and still creates automatically when no active record
exists.
