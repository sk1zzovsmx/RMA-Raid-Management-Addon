# RMA Feature Boundaries

## Shared Kernel

Owns bootstrap, TOC/load-order diagnostics, SavedVariables access, database stores,
timers, communication, common item/string/time helpers, and reusable UI primitives.
It must not own product workflow decisions.

### Commands

Commands request a mutation and return success or failure. Commands and queries use
direct owner calls.

### Queries

Queries return data without requesting UI behavior or publishing a command event.
Commands and queries use direct owner calls.

### Notifications

Notifications report a completed state change and do not return a result to the
publisher. Notifications use addon.Bus after the state change succeeds.
A service may notify that UI attention is needed, but the event name must describe
the completed condition rather than encode an imperative controller command.
`GroupLootRestoreNeeded` is the reference pattern.

### UI Requests

UI requests do not return a value.
Commands and queries do not pass through addon.Bus.
addon.Bus may carry UI requests only as imperative one-way notifications.

## Configuration

Owns the top-level configuration frame, option composition, presets, and shortcuts
to feature-owned actions. It does not own Warnings, Spammer, Logger, or Raid data.
`Controllers/Config.lua` is the top-level configuration owner.

## Raid

Owns group capabilities, roster state, raid sessions, attendance capture, loot
method automation, raid projections, and raid-specific diagnostic data. Synthetic
roster, roll, and RaidGrid debug support is owned by `Services/Raid/Debug.lua`.

## Master Loot

Owns the composition of loot, rolls, award, trade, item-selection, and child-widget
workflows. `Controllers/Master.lua` remains its UI and WoW-event composition root.
Cross-owner calls bind directly to `Services.Loot.DistributionSession`,
`Services.Loot.Inventory`, and `Services.Loot.AwardPlanner`; the remaining
underscore-prefixed Loot helpers stay private to `Services/Loot/*`.

## Logger And Attendance

Logger owns raid-history mutations and loot-history presentation. Attendance owns
attendance presentation and export. Shared raid projections remain owned by Raid.

## Reserves

Owns reserve import, aliases, display models, sync, whisper behavior, and reserve UI.

## Warnings

Owns warning persistence, preview models, announcement requests, and its top-level UI.

## Spammer

Owns recruitment draft data, preview generation, send-cycle control, and its top-level UI.
