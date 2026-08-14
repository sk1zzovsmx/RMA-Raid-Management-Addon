# Quick Access Bar Design

## Objective

Add an optional, compact on-screen Quick Access bar for common raid actions. The
bar is controlled from the minimap icon menu, can be dragged by an RMA icon
handle, and restores its position after `/reload`.

## User Interface

The bar is a single horizontal row:

`[RMA icon handle] [ML] [GL] [HIS] [SR] [RW]`

- The handle reuses the same RMA icon texture shown by the minimap button.
- The RMA icon is the only drag handle. Dragging uses the left mouse button so
  clicks on action buttons cannot move the bar accidentally.
- The five text buttons are compact and use the addon's existing dark visual
  style.
- Tooltips expand the abbreviations: Master Loot, Group Loot, Loot History,
  SoftRes, and Raid Warning.
- ML is highlighted while Master Loot is active. GL is highlighted while Group
  Loot is active. Neither is highlighted for another loot method.
- The default position is centered near the bottom of the screen, above the
  default action bars. The saved position overrides the default.
- The bar is hidden by default for users who have not enabled it.

Static frame layout belongs in XML. Lua owns scripts, state, localization,
visibility, highlighting, and action dispatch.

## Minimap Menu

Add a checkable `Show Quick Access bar` entry to the minimap icon menu. Its
checked state reflects the current saved option. Selecting it toggles the bar
immediately and persists the new visibility in `RMA_Options`.

The entry remains available regardless of raid membership so the user can
configure the interface at any time.

## Action Behavior

### ML and GL

- ML opens an RMA confirmation popup before requesting Master Loot.
- GL opens an RMA confirmation popup before requesting Group Loot.
- Confirmation delegates the actual change to the Raid service.
- The Raid service verifies that the player is in a raid and is the raid leader
  before calling the WotLK `SetLootMethod` API.
- Master Loot assigns the player as master looter.
- If authority or raid state is invalid, no change occurs and RMA reports a
  localized warning.
- If the selected loot method is already active, no confirmation is needed; the
  button performs no change.

### HIS, SR, and RW

- HIS calls the existing Loot History toggle.
- SR calls the existing SoftRes panel toggle.
- RW calls the existing Raid Warning panel toggle.

These actions preserve each target controller's current show/hide behavior.

## Ownership and Data Flow

A dedicated Quick Access controller owns the top-level bar and its UI behavior.
It depends on the existing Raid service, Logger controller, Warnings controller,
and Reserves widget. The minimap entry point only toggles the controller and
does not duplicate its behavior.

The existing Minimap options namespace owns these additional canonical values:

- `quickAccessBar`: boolean visibility, default `false`.
- `quickAccessPoint`: anchor point string.
- `quickAccessRelativePoint`: relative anchor point string.
- `quickAccessX`: horizontal offset number.
- `quickAccessY`: vertical offset number.

Only the final drag position is persisted on mouse release. Coordinates are
clamped to the visible screen before saving and when restored, preventing the
bar from becoming inaccessible after resolution or UI-scale changes.

## Event Handling

The controller refreshes the ML/GL highlight when it binds and on
`PARTY_LOOT_METHOD_CHANGED`. It does not use `OnUpdate`. Drag scripts are active
only during a user drag and are removed on mouse release.

## Localization

All new visible labels, popup text, tooltips, warnings, and informational text
are added to `addon.L`. Frame names and popup keys use the RMA prefix. Runtime
text remains ASCII.

## Compatibility and Safety

- Target Interface remains 30300 and runtime code remains Lua 5.1 compatible.
- No Retail or Classic-only API is introduced.
- XML remains layout-only with no `<Scripts>` or `<On...>` handlers.
- No SavedVariables key outside `RMA_Options` is added.
- Existing loot wire formats and addon-message behavior are unchanged.

## Verification

Automated and static checks cover:

- Default-hidden and saved visibility behavior.
- Position save/restore and screen clamping.
- ML/GL confirmation dispatch, authority rejection, and active highlight state.
- HIS/SR/RW dispatch to their existing owners.
- TOC references, Lua 5.1 syntax, `xpcall` safety, XML handler policy, stale
  branding scan, and `git diff --check`.

In-game smoke checks cover:

- Enabling and disabling the bar from the minimap menu.
- Dragging by the icon and restoring the same position after `/reload`.
- ML and GL confirmation and method switching as raid leader.
- Correct active-method highlight after an external loot-method change.
- Opening and closing Loot History, SoftRes, and Raid Warning.
