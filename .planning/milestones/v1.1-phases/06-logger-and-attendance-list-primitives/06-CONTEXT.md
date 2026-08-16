# Phase 6: Logger and Attendance List Primitives - Context

**Gathered:** 2026-08-16
**Status:** Ready for planning

<domain>
## Phase Boundary

Extract only the stable list-layout behavior already duplicated by Logger and Attendance: content-width and column-budget calculation, header and row width application, sort-header binding, and title/empty-state presentation primitives. Preserve every current visible string, numeric layout result, click target, sort rule, and controller-owned feature behavior.

This phase does not create a generic UI framework or configuration DSL, redesign either screen, move feature-specific rendering out of its controller, change XML, or alter localization, SavedVariables, wire protocols, vendored libraries, or supported public entrypoints.

</domain>

<decisions>
## Implementation Decisions

### Shared primitive boundary
- Build a small common core with only the minimal explicit variants already required by Logger or Attendance; do not generalize for hypothetical consumers.
- Expose a few focused operations for width/budget calculation, header layout, row layout, and sort binding. Do not add an all-in-one layout orchestrator or a second convenience layer.
- Keep column descriptors, sort keys, minimum widths, ratios, fallback widths, gutters, gaps, offsets, and controller orchestration inside each controller, including the identical four-column raid descriptors.
- Controllers pass their geometry explicitly. Shared primitives must not hide visual defaults.

### Titles and empty states
- Preserve the exact count-title format `Title (n)`.
- Preserve the exact contextual-title format `Title (n) - Context`, including separator, order, and unmodified context text.
- Allow an explicit optional fallback context so Logger can retain its current empty-hint behavior while Attendance omits it.
- Logger and Attendance continue to choose the localized text and the conditions for each empty state. A shared primitive may only apply the selected text and visibility to the target label.

### Feature-specific columns and interactions
- Logger's item-icon allowance remains an explicit Logger-only variant that contributes to the item header and width budget without becoming a standalone column.
- Logger's Source text widget and Source hit box continue to receive the same calculated width. The common row-width primitive may apply the width to an explicitly named hit box.
- Logger remains responsible for disabling Source sorting when a boss is selected, including mouse state and alpha. The shared sort primitive only performs the stable initial header binding.
- Attendance Spec and Inspect columns share only header/container geometry. Attendance retains icon creation and placement, textures, slot rendering, inspect state, tooltips, and interactions.

### Exact geometry and refresh behavior
- Preserve the existing content-width fallback exactly: use the ScrollFrame width when valid, otherwise the frame width minus the gutter, then enforce the current minimum width of 240.
- Preserve the current proportional allocation exactly: floor each proportional addition and distribute remaining pixels in the same current key order.
- Recalculate widths at the same existing points during localization/load, row drawing, and post-update. Do not add a resize listener, timer, polling loop, or new cache layer.
- Require numeric parity for fallback widths, minimums, ratios, remainders, gaps, offsets, header widths, row widths, and interactive hit-box bounds. Visual or functional approximation is not sufficient.

### Codex's Discretion
- Exact names and file-local organization of the focused shared functions within the existing `addon.UI.Lists` owner.
- Exact test fixture placement and assertion organization, provided regressions prove numeric parity and controller ownership without introducing a new test framework.
- Mechanical extraction order, provided each controller remains operational and verifiable throughout the plan.

</decisions>

<specifics>
## Specific Ideas

- The result should read as a small extension of the existing `addon.UI.Lists` API, not as a declarative list system.
- Some clear duplication is intentionally retained: feature-owned column descriptors and constants are preferred over moving presentation policy into a shared module.
- Shared code may understand an explicitly supplied extra header width or hit-box key because those variants exist today; it must not grow generic hooks for future column types.

</specifics>

<code_context>
## Existing Code Insights

### Reusable Assets
- `Modules/UI/ListController.lua`: already owns `addon.UI.Lists`, including `CalculateColumnWidths`, row rendering, controller creation, sorting, and controller binding. It loads before both controllers and is the established owner for focused shared list primitives.
- `UI.Lists.CalculateColumnWidths`: already implements the required Lua 5.1-compatible minimum, ratio, floor, fixed-key, and remainder behavior. The phase should preserve this algorithm rather than replace it.
- `UI.Frames.SetScriptSafely`: already provides the binding mechanism used by both controllers for sort-header clicks.
- `UI.Primitives.SetShown`: already provides the visibility operation used by empty-state labels.

### Established Patterns
- `Controllers/Logger.lua` and `Controllers/Attendance.lua` duplicate content-width fallback, column-budget calculation, widget/header width application, header placement, row width application, sort binding, count-title formatting, and empty-state label updates.
- Both controllers currently keep feature constants and column descriptor tables local. That ownership remains binding even where the raid column tables are identical.
- Logger requires two proven layout variants: `headerExtraWidthKey` for the item icon allowance and `hitBoxKey` for the Source interaction region.
- Logger dynamically controls Source-header mouse state and alpha outside the initial sort binding; this contextual rule remains Logger-owned.
- Attendance owns substantial Spec/Inspect rendering and tooltip behavior beyond column geometry; none of that behavior belongs in the shared primitive layer.

### Integration Points
- Extend `Raid Management Addon/Modules/UI/ListController.lua` under the existing `addon.UI.Lists` namespace; the TOC already loads it before `Controllers/Logger.lua` and `Controllers/Attendance.lua`.
- Replace only the duplicated helper bodies in the two controllers while leaving their local layout tables, context builders, localization calls, draw-row logic, and post-update behavior in place.
- Preserve Logger's existing calls that update Source sort availability and its item/source row interactions.
- Preserve Attendance's existing Spec/Inspect render path and its contextual title and empty-state selection logic.
- Extend existing Lua-backed UI regressions in `tests/lua/harness/30_raid_runtime.lua` and `tests/lua/harness/70_raid_sync.lua`, and add focused `UI.Lists` parity coverage near the existing ListController harness in `tests/lua/harness/40_inspect_foundations.lua` when appropriate.

</code_context>

<deferred>
## Deferred Ideas

- A generic UI framework, declarative layout DSL, shared column catalog, resize observer, and additional list consumers remain outside this milestone.
- `LibDeflate` replacement and the talent-library stack evaluation remain deferred to the future v1.2 Dependency Optimization milestone.

</deferred>

---

*Phase: 06-logger-and-attendance-list-primitives*
*Context gathered: 2026-08-16*
