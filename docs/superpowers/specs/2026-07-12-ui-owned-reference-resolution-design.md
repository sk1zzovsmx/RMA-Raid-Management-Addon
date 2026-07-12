# UI Owned Reference Resolution Design

## Goal

Fix the Interface > AddOns > RMA layout at its shared root by making
`Frames.GetRef(frameOrName, childName)` prefer the named child owned by the
requested frame over an unrelated global with the same short name.

## Observed Failure

The Config layout asks for short child suffixes such as `Title`, `OpenBtn`, and
`DeleteBtn`. `Frames.GetRef` currently checks `_G[childName]` before
`_G[frameName .. childName]`. On a live WotLK client, generic Blizzard or addon
globals can therefore win the lookup. The Lua layout then positions or updates
the unrelated global while the intended RMA control keeps stale XML geometry.

The supplied screenshots demonstrate the resulting symptoms across every RMA
Interface Options page:

- page titles appear between content sections;
- descriptions and controls retain incorrect positions;
- content crosses or is clipped by the visible panel boundary;
- generic action names are collision-prone across panels.

## Selected Approach

Change the shared resolver order without changing its public signature:

1. Resolve the frame name.
2. If `childName` is already an absolute name beginning with `frameName`, return
   that exact global.
3. Try the owned name `_G[frameName .. childName]`.
4. Preserve the existing compatibility fallback `_G[childName]` only when the
   owned name does not exist.

This is intentionally a global fix. All existing call sites express an owner
frame and a child suffix, so owner-first lookup matches the API's purpose and
also protects Warnings, Spammer, Loot Counter, Reserves, and shared UI scaffolds
from the same class of collision.

## Compatibility Contract

- `Frames.GetRef(frame, "Title")` returns `RMAExampleTitle` when the owner is
  `RMAExample`, even if a global `Title` also exists.
- `Frames.GetRef(frame, "RMAExampleTitle")` continues to support an already
  absolute owned name.
- `Frames.GetRef(frame, "ExternalGlobal")` continues to return the exact global
  when the owner-prefixed name does not exist.
- Invalid or unnamed frames and empty child names continue to return `nil`.
- No frame names, XML identities, controller APIs, SavedVariables, option keys,
  slash commands, addon-message formats, or user-visible strings change.

## Layout Impact

No new layout system is introduced. `Modules/UI/OptionsLayout.lua` continues to
own repeated geometry, and `UI/Config.xml` remains layout-only structural XML.
Once short suffixes resolve to the correct owned controls, the existing row
descriptions apply their intended margins, widths, wrapping bounds, and scroll
child height to the actual RMA widgets.

If live verification shows a remaining independent panel-boundary defect after
the resolver fix, it must be treated as a separate measured geometry issue, not
hidden inside the reference-resolution change.

## Behavior Delta

- Old behavior: a generic global could override the child belonging to the
  supplied owner frame.
- New behavior: an existing owned child always wins; the generic global remains
  a fallback.
- Reason: the old order is ambiguous and causes visible corruption in standard
  WotLK Interface Options.
- Classification: the old behavior is broken and unsafe for reusable short
  suffixes.
- Compatibility impact: intentionally changes only ambiguous collisions;
  unambiguous and fallback lookups remain supported.
- Migration impact: none.

## Verification

Automated verification will include:

- a focused resolver contract test covering owned-child precedence, absolute
  owned names, global fallback, and invalid inputs;
- the existing Config XML/layout contract tests;
- the full Python test suite;
- repository runtime validators for TOC, Lua 5.1, `xpcall`, XML handlers, and
  stale branding;
- `git diff --check`.

The required in-game smoke check is:

1. Open Interface > AddOns > RMA.
2. Inspect the root, Master Loot, Loot History, LFM Spam, Raid Warning, and Help
   pages at the same resolution and UI scale as the supplied screenshots.
3. Confirm titles are at the top, controls remain inside the content boundary,
   text wraps inside the visible width, and each scroll bar reaches all content.
4. Open the standalone `/rma config` window and representative Warnings,
   Spammer, Loot Counter, and Reserves screens to detect shared-resolver
   regressions.
5. Run `/reload` and repeat the Interface Options navigation.

## Risks And Controls

The main risk is a caller that accidentally depended on a generic global even
though an owner-prefixed child also existed. Static call-site review shows the
current callers consistently pass short child suffixes for owned controls.
Focused tests preserve the explicit global fallback, and the full suite plus
in-game smoke checks cover the shared impact.
