# Master Footer Grid Design

## Goal

Restore the Master Loot window to its original `250 x 480` size and replace the
three-button footer with a compact two-column, two-row action grid.

## Layout

All four buttons use `113 x 25` dimensions and a `4` pixel horizontal and
vertical gap:

```text
[ Loot History   ] [ Loot Counter ]
[ Import SoftRes ] [ Loot Bans    ]
```

The bottom row remains 10 pixels above the window bottom. `Import SoftRes`
remains 10 pixels from the left edge. The upper row is anchored 4 pixels above
the bottom row. This keeps every control within the restored 250-pixel width.

## Behavior

- `Loot History` calls the existing `Controllers.Logger:ToggleLootHistory()`
  workflow.
- `Loot Counter`, `Import SoftRes`, and `Loot Bans` retain their current
  behavior.
- Existing Master controller frame-reference and binding conventions remain in
  use; no new persistence or runtime service is introduced.
- XML continues to own static geometry only, while Lua owns text and click
  behavior.

## Compatibility And Scope

- Target remains WotLK 3.3.5a, Interface 30300, and Lua 5.1.
- No SavedVariables, addon-message formats, loot policy, or roll behavior
  changes.
- No unrelated Master window redesign is included.

## Verification

- Add a contract test that first fails against the current three-button footer
  and checks the restored frame width, four equal button sizes, grid anchors,
  localized Loot History label, and existing logger toggle call.
- Run the focused UI/Loot Bans contracts, the complete Python suite, XML handler
  scan, Lua 5.1 checks, TOC validation, and `git diff --check`.
- In-game smoke remains required to visually confirm the 2 x 2 alignment and
  that each button opens the expected window.
