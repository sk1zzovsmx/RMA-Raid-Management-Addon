# Passive UI Compatibility Design

**Date:** 2026-07-22
**Status:** Approved

## Objective

Make Raid Management Addon passively compatible with custom user interfaces
without detecting them, depending on them, or implementing per-UI adapters.
RMA must render as a complete Blizzard-native WotLK 3.3.5a interface when no
external skin is present and must avoid fighting an external skinner that can
recognize standard Blizzard controls.

The success criterion is not that RMA always looks like ElvUI, Tukui, or any
other specific UI. The success criterion is:

> RMA renders correctly with Blizzard-native controls and does not obstruct an
> external UI that is capable of skinning those controls.

## Context

RMA already inherits Blizzard window and font objects in many places, including
`UIPanelDialogTemplate` and the `GameFont*` family. It also defines shared RMA
templates and applies some decorative textures, backdrop colors, border colors,
and row styling directly.

Custom UIs on WotLK 3.3.5a do not expose a universal active-theme contract.
Some skin known addons explicitly, some hook shared widget frameworks, and some
skin Blizzard controls. Merely omitting a texture does not make WoW select the
active custom UI's texture. Passive compatibility therefore depends on using
recognizable native controls and avoiding later decorative overrides.

## Decisions

- Use passive compatibility rather than guaranteed visual matching.
- Use Blizzard-native presentation as the complete fallback.
- Do not detect ElvUI, Tukui, or any other UI.
- Do not add a theme selector, theme state, or SavedVariables.
- Do not add an RMA skin adapter or a new public skinning API.
- Do not add Ace2, Ace3, AceGUI, LibSharedMedia, or another UI dependency.
- Preserve stable RMA frame names so an external project may target them.
- Keep runtime visual ownership limited to information-bearing state.

LibSharedMedia is intentionally excluded. It makes registered media available
but does not skin windows or buttons, and RMA currently has no status-bar use
that justifies the dependency.

## Architecture

`UI/Templates/Common.xml` remains the shared visual skeleton. RMA templates
become structural specializations of canonical Blizzard templates:

- `RMAWindowTemplate` keeps RMA sizing, title placement, dragging, and window
  behavior while inheriting the Blizzard window presentation.
- `RMADialogTemplate` uses a standard Blizzard dialog presentation.
- `RMAActionButtonTemplate` inherits a Blizzard button template and adds only
  RMA-required size or layout rules.
- Checkboxes, edit boxes, scrollbars, and dropdowns use their WotLK 3.3.5a
  Blizzard templates where their existing behavior permits it.
- Text uses global `GameFont*` objects.

The resulting ownership flow is:

```text
Blizzard template -> structural RMA specialization -> optional external skin
```

No controller or service selects a visual theme. Controllers continue to own
feature behavior, services continue to own domain behavior, XML remains
layout-only, and `Modules/UI/Visuals.lua` retains only semantic visual logic.

## Semantic Versus Decorative Presentation

RMA continues to control presentation that conveys operational information:

- class and item-quality colors;
- current selection and keyboard/mouse focus;
- enabled and disabled state;
- warnings, errors, confirmations, and progress state;
- loot, reserve, inspect, and raid indicators;
- item, specialization, and action icons.

Presentation delegated to Blizzard templates or external skinners includes:

- window backgrounds and borders;
- button chrome;
- checkbox, edit-box, scrollbar, and dropdown chrome;
- decorative panel fills and separators;
- base fonts and non-semantic text colors.

Each existing texture or color override must be classified before removal.
Functional icons and state cues must not be removed by a broad texture cleanup.

## Runtime Behavior

The load path contains no custom-UI branch:

1. WoW creates RMA frames from Blizzard-based templates.
2. RMA attaches behavior, localized text, and feature state.
3. An installed custom UI may post-process controls it recognizes.
4. RMA refreshes semantic state without restoring decorative presentation.

Dynamically created controls use the same shared templates as XML-created
controls. A refresh must not reset an externally changed background, border,
font, or button texture unless that property communicates current feature
state.

If an external skinner supports only part of the interface, RMA remains usable
because every control has a Blizzard-native fallback. External skinning is an
optional post-processing layer, never a runtime requirement.

## Scope

Implementation proceeds from shared controls outward:

1. Inventory decorative texture and color ownership.
2. Normalize shared window, dialog, and button templates.
3. Normalize standard controls and their dynamic counterparts.
4. Remove or narrow runtime decorative overrides.
5. Inspect individual windows for spacing or clipping regressions.

The work may adjust dimensions or anchors only where native Blizzard chrome
requires it. It must not redesign feature layout, change table-column behavior,
or alter raid workflows.

The following are out of scope:

- SavedVariables or option changes;
- sync, chat, slash command, or wire-format changes;
- feature behavior changes;
- an ElvUI_AddOnSkins module;
- guaranteed matching with any specific custom UI;
- vendored library changes.

## Failure Handling And Risks

There is no optional integration to initialize and therefore no external-UI
error path. Missing or invalid Blizzard template references are load-time
defects and must be caught during validation and in-game smoke testing.

The principal risk is visual regression rather than domain failure:

- native borders may consume more space;
- labels may clip or overlap;
- buttons may change size or text padding;
- dynamic controls may differ from XML controls;
- a runtime refresh may accidentally restore decorative properties;
- removing a texture may erase a semantic state cue.

Mitigation is a shared-template-first implementation, explicit classification
of every removed override, focused checks after each shared control change, and
a final window-by-window smoke pass.

## Verification

Automated checks include:

- existing Python behavior and contract tests;
- `tools/check-rma.ps1` when available and relevant;
- TOC reference and load-order validation;
- Lua 5.1 syntax validation;
- Lua 5.1 `xpcall` scan;
- XML script-handler scan;
- `stylua --check` and `luacheck` where configured;
- `git diff --check`;
- a focused scan confirming no new ElvUI, Tukui, AceGUI, or modern WoW API
  dependency;
- a focused review of decorative texture overrides that remain in shared UI
  templates and runtime visual refreshes.

In-game smoke testing uses two configurations:

1. WotLK 3.3.5a with the Blizzard UI only.
2. WotLK 3.3.5a with ElvUI 6.09.

Both configurations verify that `/rma` opens the addon and that windows,
dialogs, dragging, close buttons, action buttons, scrolling, dropdowns, edit
boxes, checkboxes, selections, and dynamically created rows work without Lua
errors. The ElvUI pass additionally verifies that opening or refreshing RMA
does not restore decorative properties over an external skin.

Visual matching with ElvUI is observational information, not a release gate.
The release gate is correct Blizzard fallback behavior plus non-interference
with external post-processing.

## Acceptance Criteria

- RMA loads and remains fully usable without any custom UI.
- Shared RMA controls are based on appropriate WotLK 3.3.5a Blizzard templates.
- No custom-UI detection, adapter, theme state, or external UI dependency is
  introduced.
- Decorative refresh logic does not overwrite external post-processing.
- Class, quality, selection, warning, and other semantic cues remain clear.
- Static and dynamically created controls follow the same template contracts.
- No persistence, protocol, command, or feature behavior changes.
- Automated validation passes and both in-game smoke configurations are
  accounted for honestly.
