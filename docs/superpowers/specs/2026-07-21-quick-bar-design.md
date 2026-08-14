# QuickBar Design

## Objective

Provide an optional compact on-screen QuickBar for common raid actions. The bar
is controlled from the minimap icon menu, can be dragged by an RMA icon handle,
and restores its position after `/reload`.

## Naming Contract

The feature name is `QuickBar` everywhere:

- Files: `Controllers/QuickBar.lua` and `UI/QuickBar.xml`.
- Controller: `addon.Controllers.QuickBar`.
- Frame: `RMAQuickBarFrame`.
- Popup keys: `RMA_QUICK_BAR_MASTER_LOOT` and `RMA_QUICK_BAR_GROUP_LOOT`.
- Option keys use the `quickBar` prefix.
- Localization keys use the `QuickBar` form.
- User-facing text consistently says `QuickBar`.

The feature is new and unreleased. Do not add aliases, migrations, fallback
lookups, deprecated names, or compatibility wrappers for its previous working
name. The retired-name search pattern must be constructed outside the
repository so the removed identifiers are not reintroduced in tracked docs.

## User Interface

The default horizontal layout is:

`[RMA icon handle] [ML] [GL] | [SR] | [HIS] | [RW]`

The vertical layout is:

```text
[RMA icon handle]
[ML]
[GL]
---
[SR]
---
[HIS]
---
[RW]
```

- The handle reuses the same RMA icon texture shown by the minimap button.
- The icon is the only drag handle. Dragging uses the left mouse button so
  action-button clicks cannot move the bar accidentally.
- The five text buttons use the addon's compact dark visual style.
- Tooltips expand the abbreviations: Master Loot, Group Loot, Loot History,
  SoftRes, and Raid Warning.
- ML has a static green border glow while Master Loot is active. GL has the
  same glow while Group Loot is active. Button text keeps its normal color and
  neither button glows for another loot method.
- The default position is centered near the bottom of the screen, above the
  default action bars.
- The bar is hidden by default for users who have not enabled it.

Static frame layout belongs in XML. Lua owns scripts, state, localization,
visibility, highlighting, and action dispatch.

The controller owns runtime reflow. It uses one frame and one set of controls,
reanchors them for the selected orientation, resizes the frame to its visible
contents, and clamps the resulting frame back onto the screen. The four action
groups are `ML/GL`, `SR`, `HIS`, and `RW`. Separators appear only between
non-empty visible groups, so hidden buttons cannot leave leading, trailing, or
adjacent separators. If every action button is disabled, the RMA icon handle
remains visible and draggable.

The ML and GL glow textures are static XML-owned visual elements. Lua only sets
their color and visibility; no animation or persistent `OnUpdate` is used.

## Minimap Menu

Add a checkable `Show QuickBar` entry to the minimap icon menu. Its checked
state reflects the saved option. Selecting it toggles the bar immediately and
persists visibility in `RMA_Options`.

The QuickBar entry is the final row in the menu, after `Clear Raid Icons`, so
the existing raid and loot actions remain grouped together above it. A disabled
separator precedes the QuickBar entry.

The minimap remains a core entry point. It must load and bind its tooltip and
left/right click scripts even if the optional QuickBar controller is unavailable.
The QuickBar menu row is enabled when its controller is available and safely
disabled otherwise.

## Slash Command

The existing `/rma` router exposes these commands:

- `/rma quickbar show` shows QuickBar and persists visibility.
- `/rma quickbar hide` hides QuickBar and persists visibility.

The slash entry point delegates both operations to
`addon.Controllers.QuickBar:SetShown`; it does not read or write the saved
option directly. `/rma help quickbar` lists the two supported subcommands.
Missing or unsupported QuickBar arguments show the same localized QuickBar
command help and do not change visibility. No toggle alias or additional
QuickBar slash alias is introduced.

## Interface Options

RMA registers a dedicated `QuickBar` child panel named
`RMAInterfaceOptionsQuickBarPanel` in Interface Options. The panel contains:

- One dropdown orientation selector with `Horizontal` and `Vertical` values.
- Five checkboxes controlling the ML, GL, SR, HIS, and RW buttons.

Horizontal is the default orientation and all five buttons are enabled by
default. Changes apply to the visible QuickBar immediately without `/reload`.
The Config controller reads and writes the settings through explicit QuickBar
controller methods for orientation and button visibility. The QuickBar
controller remains the only owner of its option keys and layout refresh; Config
does not reimplement persistence, layout, or visibility rules.

The Config XML remains layout-only. It declares the panel, localized labels,
orientation selector, and checkboxes; Lua owns option binding, refresh, and
event handlers.

## Action Behavior

### ML and GL

- ML opens an RMA confirmation popup before requesting Master Loot.
- GL opens an RMA confirmation popup before requesting Group Loot.
- Confirmation delegates the mutation to the Raid service.
- The Raid service verifies raid membership and raid-leader authority before
  calling the WotLK `SetLootMethod` API.
- Master Loot assigns the player as master looter.
- Invalid authority or raid state produces a localized warning and no change.
- If the selected method is already active, the button performs no change and
  does not open a popup.

### HIS, SR, and RW

- HIS calls the existing Loot History toggle.
- SR calls the existing SoftRes panel toggle.
- RW calls the existing Raid Warning panel toggle.

## Ownership and Persistence

The dedicated QuickBar controller owns the top-level frame, UI behavior,
confirmation routing, highlighting, and drag persistence. The minimap entry
point only exposes visibility and resolves the controller lazily. The Raid
service remains the sole owner of loot-method mutation.

The existing Minimap options namespace owns only these values:

- `quickBar`: boolean visibility, default `false`.
- `quickBarX`: horizontal center offset, default `0`.
- `quickBarY`: vertical center offset, default `-180`.
- `quickBarOrientation`: `"horizontal"` or `"vertical"`, default
  `"horizontal"`.
- `quickBarShowML`: ML visibility, default `true`.
- `quickBarShowGL`: GL visibility, default `true`.
- `quickBarShowSR`: SR visibility, default `true`.
- `quickBarShowHIS`: HIS visibility, default `true`.
- `quickBarShowRW`: RW visibility, default `true`.

The frame always anchors `CENTER` to `UIParent` `CENTER`; anchor names are
constants and are not persisted. Only the final clamped X/Y position is saved
on mouse release. Saved offsets are clamped again when restored, after an
orientation change, and after button visibility changes so resolution,
UI-scale, or frame-size changes cannot leave the bar inaccessible.

## Event Handling

The controller refreshes ML/GL highlighting when it binds and through the real
forwarded `PARTY_LOOT_METHOD_CHANGED` path. Bootstrap must seed the forwarded
event before dependent modules load. The feature uses no persistent `OnUpdate`;
native frame movement is limited to an active user drag.

## Localization

All new visible labels, Config text, orientation values, popup text, tooltips,
warnings, command help, and informational text belong to `addon.L`. Frame names
and popup keys use the RMA prefix. Runtime text remains ASCII.

## Compatibility and Safety

- Target Interface remains 30300 and runtime code remains Lua 5.1 compatible.
- No Retail or Classic-only API is introduced.
- XML remains layout-only with no `<Scripts>` or `<On...>` handlers.
- No SavedVariables key outside `RMA_Options` is added.
- Existing loot wire formats and addon-message behavior are unchanged.

## Verification

Automated and static checks cover:

- Complete absence of the previous working name in the final tree.
- Default-hidden and saved-visible behavior.
- Horizontal default and immediate horizontal/vertical reflow.
- All five buttons enabled by default and independently configurable.
- Separator compaction for every hidden-group boundary and handle-only mode.
- X/Y save, restore, and out-of-bounds clamping without persisted anchor names.
- Position reclamping after orientation and visible-button changes.
- Minimap tooltip and clicks with QuickBar both available and unavailable.
- QuickBar is the final minimap-menu row after `Clear Raid Icons`.
- `/rma quickbar show`, `/rma quickbar hide`, and `/rma help quickbar` routing.
- Missing or unsupported QuickBar slash arguments leave visibility unchanged.
- ML/GL confirmation, authority rejection, idempotency, and active glow.
- The real forwarded loot-method event bridge and static green glow transition.
- Normal ML/GL text color regardless of active loot method.
- HIS/SR/RW dispatch to their existing owners.
- Dedicated QuickBar Interface Options panel and option binding.
- TOC references, Lua 5.1 syntax, `xpcall` safety, XML handler policy, and
  `git diff --check`.

In-game smoke checks cover:

- Minimap tooltip and left/right clicks.
- Enabling and disabling QuickBar from the minimap menu.
- Showing and hiding QuickBar with the two `/rma quickbar` commands.
- Switching horizontal/vertical orientation from Interface Options.
- Enabling each button independently and verifying compact separators.
- Leaving only the draggable RMA handle when all buttons are disabled.
- Dragging by the icon and restoring position after `/reload`.
- ML and GL confirmation and method switching as raid leader.
- Static ML/GL glow refresh after an external loot-method change.
- Opening and closing Loot History, SoftRes, and Raid Warning.
