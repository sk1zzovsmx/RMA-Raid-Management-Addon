# XML UI Review Design

## Status

Approved in conversation on 2026-07-11.

This design defines a complete, incremental review of the Raid Management Addon XML UI. It is not a `GREENFIELD_REWRITE`. The public RMA contract, WotLK 3.3.5a compatibility, Lua 5.1 compatibility, SavedVariables, addon-message formats, frame identities, and user-facing workflows remain stable.

## Goal

Improve the XML UI across three related dimensions:

1. Reduce duplicated layout declarations and unnecessary XML volume.
2. Make equivalent controls and surfaces visually consistent.
3. Clarify the ownership boundary between static XML layout and Lua behavior.

The work must improve maintainability without turning XML reduction into an end in itself. A smaller file is not a success if the replacement Lua is harder to understand, creates accidental APIs, or hides ownership.

## Current Baseline

The runtime UI contains 13 addon-owned XML files plus the shared `UI/Templates/Common.xml` file. No `<Scripts>` blocks or `<On...>` XML handlers are present.

The largest XML surfaces at review time are:

| Surface | Raw lines | Named elements | Anchors | Sizes |
|---|---:|---:|---:|---:|
| `UI/Config.xml` | 2,432 | 235 | 224 | 110 |
| `UI/Reserves.xml` | 744 | 56 | 64 | 50 |
| `UI/LootHistory.xml` | 713 | 52 | 64 | 47 |
| `UI/Spammer.xml` | 608 | 51 | 54 | 40 |
| `UI/RaidAttendance.xml` | 515 | 56 | 54 | 29 |
| `UI/Master.xml` | 428 | 33 | 36 | 27 |
| `UI/Templates/Common.xml` | 419 | 37 | 50 | 20 |

`Modules/UI/OptionsLayout.lua` already owns repeated Config panel geometry through `Layout.ApplyRows`. `UI/Templates/Common.xml` already owns shared window, dialog, action button, selectable row, scroll frame, text input, and item icon primitives. The review should strengthen these existing boundaries rather than introduce a second UI system.

## Considered Approaches

### Template-first XML consolidation

Expand `Common.xml` and replace repeated declarations with inherited XML templates.

This has low runtime risk, but its reduction potential is limited. It also encourages generic or single-use templates that obscure feature ownership.

### Hybrid XML and Lua ownership

Keep stable static structure and public identities in XML while moving repeated operational geometry and dynamic composition to the nearest Lua owner. Keep shared XML templates limited to durable primitives used by multiple features.

This is the selected approach because it combines meaningful reduction, explicit ownership, visual consistency, and low runtime risk.

### Predominantly Lua-generated UI

Generate most controls and layout in Lua.

This could minimize XML but would hide static structure, increase runtime failure surface, and conflict with the project policy that XML owns static layout. It is rejected.

## Ownership Model

### XML owns

- Public frames and global frame names.
- Static window hierarchy.
- Top-level window dimensions and primary anchors.
- Static visual shells and feature-specific virtual templates.
- Durable shared visual primitives in `Common.xml`.
- Frame identities referenced by Lua, tests, documentation, or the WotLK client.

### Lua UI owners own

- Dynamic row and control creation.
- Repeated geometry for homogeneous panels.
- Column placement and operational spacing.
- Text assignment, localization, visibility, enabled state, events, and refresh.
- Layout variants that depend on runtime state or feature configuration.

### Services own

- Domain rules, persistence, data validation, and transformations.
- Services must not receive frame-specific layout responsibilities during this review.

## Extraction Rules

An extraction or shared primitive is allowed only when it:

- Removes at least two semantically equivalent implementations.
- Reduces caller complexity or stabilizes a real cross-feature contract.
- Has a clear owner and does not create a generic catch-all module.
- Does not add a pass-through wrapper or a template used by only one surface.
- Does not add TOC or ModuleRegistry cost without measurable benefit.
- Preserves relevant global names, `$parent...` identities, and load order.

Similar-looking feature layouts must remain separate when their columns, state, failure handling, or user actions differ. In particular, Loot History and Attendance may share table primitives but must retain feature-specific table composition.

## Visual Contract

Equivalent controls should use consistent:

- Button height, font state, and text padding by button category.
- Window content margins.
- Title and primary command placement.
- Table header, selectable-row, hover, focus, and selected states.
- Form row spacing.
- Scroll frame gutter and scrollbar clearance.
- Typography hierarchy for window title, section title, label, description, and disabled state.

Window dimensions and table column widths remain content-driven. They must not be normalized merely for symmetry.

## Delivery Sequence

Each macro-area is an independent, reversible batch.

1. `Config.xml` and its existing `OptionsLayout` owner.
2. The log family: `LootHistory.xml`, `RaidAttendance.xml`, and `Logger.xml`.
3. `Reserves.xml` and `Widgets/ReservesUI.lua`.
4. `Spammer.xml` and its controller.
5. Operational windows: `Master.xml`, `Warnings.xml`, and `LootCounter.xml`.
6. Final review of `Common.xml`, `RaidGrid.xml`, `ScreenNotice.xml`, and `Minimap.xml`.

The Config batch is the model-validation batch. If it requires excessive configuration, generic APIs, or more Lua complexity than the XML it replaces, that extraction stops and the design is adjusted before proceeding.

## Batch Workflow

For each macro-area:

1. Measure raw lines, structural XML, anchors, sizes, templates, and named elements.
2. Map XML elements to Lua owners and runtime references.
3. Classify declarations as structural, shared visual, feature-specific visual, repeated geometry, or dynamic behavior.
4. Apply the smallest coherent consolidation for that owner.
5. Compare names and required structural order with the pre-change baseline.
6. Review architecture and visual consistency.
7. Run focused and repository-wide validation appropriate to the changed files.
8. Record measured reduction, intentionally retained duplication, and residual runtime smoke risk.

## Failure Handling and Compatibility

- Missing frame or template resolution is a hard failure; do not add nil-tolerant fallbacks to hide it.
- Layout helpers must preserve existing defaults unless a caller explicitly selects a variant.
- No wire format, persistence schema, slash alias, localization key contract, or addon-message change belongs in this review.
- No XML scripts or handlers may be introduced.
- No Retail or Classic-only UI API may be introduced.
- Any intentional visual or behavioral difference requires a documented behavior delta and focused verification.

## Acceptance Criteria

Every batch must satisfy all applicable criteria:

- Duplicated layout declarations are measurably reduced or the audit records why they must remain.
- No required frame, `$parent...` element, or virtual template is lost.
- XML remains layout-only.
- Shared templates represent durable cross-feature concepts.
- Lua layout logic stays with the nearest cohesive controller, widget, or existing UI module.
- No accidental public API, pass-through wrapper, generic helper module, or unnecessary TOC entry is introduced.
- Equivalent controls follow the agreed visual contract.
- TOC validation, XML parsing, Lua 5.1 checks, `xpcall` scan, XML handler scan, repository tests, style checks, and `git diff --check` pass where applicable.
- Runtime smoke requirements and unverified risks are reported honestly.

## Completion Criteria

The review is complete when every macro-area has been classified, each approved consolidation has been implemented and verified, intentionally retained XML has an explicit ownership reason, the shared templates contain no speculative abstractions, and the final UI architecture has one consistent XML/Lua ownership model.
