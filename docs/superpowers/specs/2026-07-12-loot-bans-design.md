# Loot Bans Design

## Objective

Add a persistent Loot Ban workflow that keeps affected players visible while
preventing them from receiving loot through every RMA award path. Reuse the
existing RaidGrid picker and the existing `BLK` roll presentation instead of
introducing a parallel roster UI or response status.

The intended improvements are raid usability, runtime safety, and data
integrity: the Loot Master can record why a player is blocked, identify that
state in operational views, and rely on a final award guard that cannot be
bypassed through a different UI path.

## Persisted Model And Ownership

Loot Ban state belongs to a cohesive service owner named `LootBans`. The owner
normalizes realm and player names, reads and writes the persisted state,
answers status queries, and publishes an internal change notification. UI,
roll, and award owners consume this contract rather than accessing the saved
record directly.

The state is stored with the existing realm-scoped player metadata:

```lua
RMA_Players[realm][playerName].lootBan = {
    active = true,
    note = "Optional reason"
}
```

The note is optional. Whitespace-only input is normalized to no note, and text
is capped at 240 ASCII characters. Input beyond the limit is rejected with a
localized validation message rather than silently truncated. Removing a ban
deletes the `lootBan` field instead of retaining an inactive record.

This design adds no SavedVariable, non-RMA import, wire-format change, or addon
message synchronization. Loot Bans are local administrative state belonging to
the user operating RMA.

## Loot Bans Widget Flow

The Master Loot operational surface gains a `Loot Bans` action. It opens the
existing `Widgets.RaidGrid` in a new `lootBan` mode populated from the current
raid roster. RaidGrid remains generic: it renders caller-provided entries and
invokes a selection callback but owns no ban policy or persistence.

Roster presentation is:

- normal players use their class color;
- banned players use gray name text;
- normal players retain their inspected specialization icon;
- banned players replace the specialization icon with
  `Interface\Buttons\UI-GroupLoot-Pass-Up`;
- a banned player's tooltip shows `Loot Ban` and the note when one exists.

RaidGrid exposes this as a generic caller projection named
`entry.iconOverride`. When present, the override takes precedence over the
inspected specialization icon. RaidGrid does not inspect Loot Ban state or
special-case its `lootBan` mode; the Master controller supplies the override
only for active Loot Ban rows. Reused buttons must restore the ordinary spec
icon when the next entry has no override.

Selecting a player without a ban opens a popup with an optional note field and
`Apply Ban` and `Cancel` actions. Selecting a banned player opens the same
editor with the current note and `Update Ban`, `Remove Ban`, and `Cancel`
actions. Successful changes refresh the open RaidGrid and Attendance views
immediately.

The note is private local UI data. RMA does not announce it in raid chat or
whisper it to the affected player.

## Attendance Presentation

Attendance receives no new column. A currently banned player's name is gray,
and hovering the name shows a tooltip containing `Loot Ban` and the optional
note. Removing the ban restores the ordinary class-colored presentation.

An active ban also displays `Interface\Buttons\UI-GroupLoot-Pass-Up` inside
the existing Name cell, immediately to the left of the gray player name. This
is an additional status icon and does not replace Attendance specialization
icons. Lua creates and owns the icon and adjusts the name anchor only while the
ban is active; XML remains layout-only. Hovering either the status icon or the
name shows the same Loot Ban tooltip. Reused rows must hide the icon, restore
the ordinary name anchor, and replace tooltip state when rendering an unbanned
player.

Attendance displays current administrative state, including when viewing a
historical raid. It does not snapshot Loot Ban state into individual raid
records; therefore, applying or removing a ban changes the presentation of the
same player in historical Attendance views.

## Roll Eligibility

A banned player may still submit a roll. The response remains visible for
auditability but is classified through the existing `INELIGIBLE` response
status with a new specific reason code, `LOOT_BAN`. The roll value remains
visible in the Master roll list, while the Info column renders the localized
tag `BAN`. Other `INELIGIBLE` reasons continue to use the generic `BLK` tag.

Loot-banned responses do not participate in automatic winner selection,
cutoff ties, or multi-award winner construction. The reason remains distinct
from late rolls, manual per-session exclusions, passes, cancellations, and
other ineligibility causes.

## Award Enforcement

Winner filtering is not the security boundary. Immediately before an award or
inventory trade is executed, the centralized award validation path queries
`LootBans` again. This final guard covers:

- automatic roll winners;
- manual winner selection;
- RaidGrid manual awards;
- single-copy awards;
- multi-award sequences;
- inventory-item trades managed by the Master Loot workflow.

An active ban stops the operation before `GiveMasterLoot` or the managed trade
effect. The Loot Master receives a localized error naming the player and, when
present, the note. No automatic denial whisper is sent to the player.

## Behavior Delta

Old behavior: RMA could display `BLK` for an ineligible roll, but it had no
persistent player-level Loot Ban and no cross-path award prohibition.

New behavior: a realm-scoped persistent ban makes a player visibly ineligible
for rolls and blocks all managed award paths while retaining the player and
their response in the UI.

Reason: visibility without enforceable award protection is insufficient for
raid administration and can be bypassed through manual or alternate award
paths.

Compatibility impact: the public RMA identity, slash commands, existing
SavedVariables, addon-message formats, XML frame identities, and WotLK 3.3.5a
runtime contract remain unchanged. The only persisted addition is an optional
field within existing `RMA_Players` metadata. No migration is required because
an absent field means not banned.

## Failure Handling

- Empty or unresolved player names cannot be persisted.
- Missing realm or player metadata is created only through the existing
  canonical metadata access path.
- Invalid or stale `lootBan` values are treated as inactive and may be
  normalized by the owner when edited.
- An unavailable UI frame prevents the editor from opening but never bypasses
  final award validation.
- A ban added during an open roll is reflected when eligibility is refreshed
  and is always enforced by the final award guard.

## Verification

Behavior tests must cover:

- applying, editing, and removing a ban;
- note trimming, empty notes, and maximum length;
- realm and player separation;
- visible roll values whose `LOOT_BAN` reason renders `BAN` in the Info column,
  while unrelated ineligible reasons continue to render `BLK`;
- exclusion from automatic, tie, and multi-award winner resolution;
- final rejection of manual, single, multi-award, and inventory-trade paths;
- gray names and note tooltips in RaidGrid and Attendance;
- Loot Ban icon overrides in RaidGrid without changing normal spec icons;
- the additional Loot Ban icon in the Attendance Name cell without changing
  Attendance spec icons or adding a column;
- immediate refresh after changes;
- current-state behavior in historical Attendance views;
- unchanged wire formats and unaffected SavedVariables contracts.

Static verification must account for Python tests, `tools/check-rma.ps1`,
`stylua --check`, `luacheck`, TOC validation, Lua 5.1 validation, the Lua 5.1
`xpcall` scan, XML handler scans, branding scans, and `git diff --check`.

Manual in-game acceptance covers opening the widget, applying and editing a
note, tooltip behavior, gray-name presentation, `/reload` persistence, blocked
roll resolution, and blocked Master Loot and inventory-trade attempts. Static
completion is not evidence that this client smoke test was performed.
