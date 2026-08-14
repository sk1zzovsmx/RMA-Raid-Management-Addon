# Interface Options Layout And Category Design

Date: 2026-08-02

## Status

Approved design for reorganizing `Interface > AddOns > RMA` and unifying the
visual layout of its configuration panels. This design is intentionally scoped
to the existing configuration surface. It does not replace the configuration
framework or change option persistence and behavior.

## Context

The current Interface Options implementation registers one RMA root panel and
six child panels through the WotLK 3.3.5a `InterfaceOptions_AddCategory` API.
Static frame structure lives in `UI/Config.xml`; `Controllers/Config.lua`
describes rows; `Modules/UI/OptionsLayout.lua` places and sizes their controls.

In-game screenshots at the current UI scale demonstrate three related defects:

- the configured scroll-child width can exceed the visible panel width;
- fixed text heights clip or truncate descriptions;
- panels do not consistently use the same title, margins, columns, spacing, or
  scrolling behavior.

The existing Master Loot page also contains settings owned by general UI,
Minimap, Rolls, and Loot Counter behavior. The page is therefore both visually
overloaded and semantically inaccurate.

## Goals

- Give every RMA Interface Options page one shared visual contract.
- Keep every scroll frame and scroll child inside the visible Blizzard panel.
- Prevent supported English labels and descriptions from being clipped.
- Place settings under the product area that owns their behavior.
- Preserve every option key, default, setter, event, dependency, and persisted
  value.
- Preserve WotLK 3.3.5a, Interface `30300`, and Lua 5.1 compatibility.
- Keep XML layout-only and Lua responsible for dynamic layout and behavior.

## Non-Goals

- Replacing the configuration framework or persistence owner.
- Redesigning operational windows outside Interface Options.
- Changing option semantics, defaults, SavedVariables, or slash commands.
- Adding new configuration options.
- Making the layout responsive to arbitrary runtime resizing; the Blizzard
  Interface Options host has a stable WotLK layout.
- Introducing another layout module or a generic UI framework.

## Selected Approach

Strengthen the existing `addon.UI.Layout` owner and use it consistently across
all RMA Interface Options pages. Panel shells and named controls remain declared
in XML. Lua defines row composition, calculates geometry, binds behavior, and
refreshes visible state.

This approach fixes the shared cause instead of adding per-panel offsets or
pulling unrelated framework changes into a bounded UI correction.

## Category Structure

The RMA tree under `Interface > AddOns` becomes:

1. **RMA** - overview and navigation guidance.
2. **General** - item tooltips and the minimap launcher.
3. **Master Loot** - loot-method automation, loot announcements, assignment and
   trade behavior, opened-loot announcements, presets, and announcement preview.
4. **Rolls** - roll ordering, countdown behavior, late-roll filtering, and Loot
   Counter visibility during MS rolls.
5. **QuickBar** - orientation and visible QuickBar commands.
6. **Loot History** - recording filters, report, data health, and maintenance.
7. **LFM Spam** - preview and recruitment controls.
8. **Raid Warning** - templates, preview, permissions, and maintenance.
9. **Help** - current commands, permissions, diagnostics, and feature guidance.

The exact option placement is:

### General

- `showTooltips`
- `minimapButton`

### Master Loot

- `useRaidWarning`
- `announceOnWin`
- `announceOnHold`
- `announceOnBank`
- `announceOnDisenchant`
- `lootWhispers`
- `screenReminder`
- `ignoreStacks`
- `autoMasterLootOnBossTarget`
- `autoMasterLootNoticeSeconds`
- `askGroupLootAfterBossLoot`
- `autoSpamLootOnLootOpened`
- `autoSpamSoftResOnLootOpened`
- existing quiet, standard, verbose, and defaults presets
- existing announcement preview

`useRaidWarning` remains in Master Loot because it controls the shared loot and
countdown announcement channel. Its description must state that shared effect.

### Rolls

- `sortAscending`
- `countdownDuration`
- `countdownSimpleRaidMsg`
- `countdownRollsBlock`
- `showLootCounterDuringMSRoll`

QuickBar, Loot History, LFM Spam, Raid Warning, and Help retain their current
feature-specific settings and actions.

## Shared Visual Contract

Every child panel uses the same structural rules:

- a panel shell sized for the Blizzard Interface Options host;
- one scroll frame inset consistently on all sides;
- one scroll child whose width equals the usable scroll viewport width;
- a single left content margin and right safe area before the scrollbar;
- the same title height, section-title style, body style, and vertical rhythm;
- a text column and a right-aligned control column for dropdowns, edit boxes,
  and command buttons;
- checkbox labels and descriptions aligned from the same text origin;
- controls never anchored beyond the usable content width;
- content height derived from laid-out rows with consistent bottom padding;
- vertical scrolling only when content is taller than the viewport;
- scroll position reset to the top when a different RMA category is shown.

The RMA overview page follows the same typography and margins. It may omit a
scrollbar when all content fits, but its usable width must match the child-page
content width.

## Text Measurement And Clipping

The layout must size descriptive text from the FontString's wrapped height
after applying its final width and localized text. A row may specify a minimum
height, but fixed heights must not be the sole source of truth for body or
description geometry.

The row height is the maximum of:

- the measured text block required by the row;
- the height required by its checkbox, slider, dropdown, edit box, or button;
- the row's explicit minimum height.

This prevents long descriptions from colliding with the following row while
keeping short rows compact. The implementation must remain deterministic after
repeated localization and refresh passes.

The QuickBar orientation row must bind the actual `OrientationStr` label rather
than looking for an undeclared `OrientationTitle`. This removes the observed
label overlap with `Show HIS`.

## Frame And Naming Changes

New General and Rolls panel shells and scroll children are added with RMA names.
Controls moved out of the Master Loot scroll child receive names derived from
their new parent. All Lua references, localization calls, tests, and Interface
Options registration specs must change coherently in the same batch.

The root and existing feature panel identities remain stable. No compatibility
alias or hidden duplicate control is retained solely to preserve an internal
alpha frame name.

## Data And Behavior Flow

Category reorganization changes presentation only:

```text
panel OnShow
-> localize the panel's named controls
-> apply the shared measured row layout
-> bind handlers once
-> read existing option owners
-> refresh current values and dependencies
```

User interaction continues through the existing option setters and events. A
control's new panel does not change the namespace that owns its value.

The existing dependencies remain intact:

- disabling automatic opened-loot announcements disables and clears the
  SoftRes opened-loot announcement option;
- disabling Raid Warning use disables the simple Raid Warning countdown mode;
- changing the minimap option immediately updates the launcher;
- QuickBar orientation and button visibility update the QuickBar owner;
- profile or SavedVariables behavior is unchanged.

## Failure Handling

Registration remains all-or-nothing: if a required panel or content frame is
missing, the registration function returns failure and does not mark the panel
set registered. Layout helpers continue to ignore a missing optional widget
safely, while required controller dependencies remain asserted at load time.

Text measurement must tolerate an unavailable or zero measured height during
initialization by falling back to the row's explicit minimum. A later OnShow
layout pass must remeasure after localization.

No runtime error is emitted merely because content needs scrolling.

## Behavior Delta

### Old behavior

- General, Minimap, Rolls, and Loot Counter options appear under Master Loot.
- The scroll child can be wider than the visible panel.
- Several descriptions are clipped at the current UI scale.
- QuickBar's Orientation label can overlap a later checkbox row.
- Titles and controls use inconsistent viewport margins and spacing.

### New behavior

- Settings appear under General, Master Loot, Rolls, or their existing
  feature-specific category.
- Every page uses the same viewport width, margins, typography, columns, and
  vertical rhythm.
- Wrapped text increases its row height instead of being clipped.
- Orientation and all other labels participate in the same row layout.
- Scrolling stays within the panel and opens at the top of the selected page.

### Reason And Compatibility

The old presentation is confusing and visibly broken. The change is a UX and
maintainability improvement with no SavedVariables, option-value, slash-command,
or wire-format impact. Internal frame names for controls moved to new panels may
change coherently; they are not a supported external addon contract.

## Verification

Automated and static checks must cover:

- Config XML parses and remains free of `<Scripts>` and `<On...>` handlers;
- all registered RMA panels and scroll children exist;
- every option control appears exactly once in the intended category;
- the QuickBar orientation row references `OrientationStr`;
- shared layout uses measured wrapped text with minimum-height fallback;
- scroll-child width does not exceed the configured usable viewport width;
- option ownership, defaults, setter paths, and dependency behavior are
  unchanged;
- Lua 5.1 validation and variadic `xpcall` scan pass;
- TOC validation and `git diff --check` pass.

The in-game smoke test uses the same UI scale as the supplied screenshots and
checks:

1. every RMA category opens at its top;
2. no title, word, description, dropdown, edit box, checkbox, button, or slider
   is clipped, overlapping, or outside the panel;
3. panels share the same margins, typography, control column, and scrollbar;
4. categories contain only the settings listed in this design;
5. changing every moved setting still updates the same feature behavior;
6. `/reload` preserves all existing option values.

## Success Criteria

The work succeeds when Interface Options presents a coherent RMA category tree,
all panels visibly follow one layout system, content remains inside its frame,
supported English text is fully readable at the reproduced UI scale, and no
configuration behavior or persisted value changes.
