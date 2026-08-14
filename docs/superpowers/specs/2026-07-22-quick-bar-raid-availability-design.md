# QuickBar Raid Availability Design

## Objective

Make the QuickBar ML and GL actions available only while the player belongs to
a raid party. A normal party is not a raid party for this behavior.

## Behavior

- While solo or in a normal party, ML and GL remain visible but are disabled.
- Disabled ML and GL buttons are grey through the native WotLK button state,
  cannot open confirmation popups, and show no active loot-method glow.
- Inside a raid party, ML and GL are enabled and keep their existing
  confirmation, loot-method, and glow behavior.
- HIS, SR, RW, dragging, orientation, visibility settings, and position
  persistence are unchanged.
- Raid-leader authorization remains owned by the Raid service and is not
  duplicated in the widget.

## Ownership And Events

`addon.Widgets.QuickBar` reads raid membership through
`Raid:IsPlayerInRaid()`. It refreshes ML/GL availability when the widget binds
and whenever either `Events.Wow.RaidRosterUpdate` or
`Events.Internal.RaidRosterDelta` is published. `Init.lua` forwards the real
`RAID_ROSTER_UPDATE` event after every roster refresh attempt, including a
no-op refresh with no current RMA raid. The event-driven design remains
polling-free.

## Verification

The runtime test covers these transitions:

1. Solo or normal party: ML/GL disabled, no glow, and no popup from a click.
2. Join a raid party and invoke `addon:RAID_ROSTER_UPDATE(true)` with a no-op
   roster refresh: ML/GL enabled through the forwarded event.
3. Leave the raid party and invoke `addon:RAID_ROSTER_UPDATE(true)`: ML/GL
   disabled again and both glows hidden.

Static contracts continue to require `Widgets.QuickBar` ownership and WotLK
3.3.5a-compatible APIs.
