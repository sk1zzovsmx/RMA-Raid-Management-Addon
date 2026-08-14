# Phase 1: Persistence Safety - Context

**Gathered:** 2026-08-15
**Status:** Ready for planning

<domain>
## Phase Boundary

Preserve an existing unknown, future-format, malformed, or incorrectly typed `RMA_Raids` value without replacing or mutating it. When the archive cannot be validated, initialize unrelated RMA features normally while raid-history reads, mutation, recording, replication, and import operate in an explicit fail-closed quarantine state.

This phase does not add migrations, archive repair, peer recovery, destructive reset UI, new persistence formats, or changes to SavedVariables other than the existing `RMA_Raids` contract.

</domain>

<decisions>
## Implementation Decisions

### Quarantine notification
- Show one non-blocking chat warning per login or reload; do not show a popup.
- Use warning severity because data is preserved but raid history is unavailable.
- The global quarantine warning is not repeated for every rejected operation. Individual operations still return their stable rejection reason.
- Keep the user-facing warning short: state that raid history is quarantined, include a stable reason category, and instruct the user to restore or correct SavedVariables and then `/reload`.

### Degraded feature behavior
- Configuration, reserves, warnings, spammer, general UI, and other features that do not depend on raid history remain operational.
- Raid-history views may open, but they are read-only and must show an explicit unavailable/quarantine state rather than silently presenting a normal empty history.
- New raid sessions and every raid-history mutation are rejected while quarantined. Do not create a temporary, shadow, or replacement archive.
- Suspend raid-history replication and import while quarantined. Reserve synchronization and loot-distribution synchronization continue normally.

### Diagnostic categories and privacy
- Expose three stable user-facing categories: unsupported/future archive format, corrupt archive structure, and invalid SavedVariable type.
- Show a concise localized message to the user. Keep validator detail in debug logging only.
- Diagnostics may include archive version/format and a stable error code.
- Diagnostics must never include archive contents, player names, loot records, or other persisted user data.
- Provide the quarantine warning in every currently supported locale.

### Recovery behavior
- Recovery requires an external SavedVariables restore or deliberate correction followed by `/reload`; do not add an in-game repair command or destructive reset button.
- When the archive validates after reload, normal operation resumes automatically with no persisted quarantine flag and no extra confirmation.
- If the archive remains invalid, re-enter quarantine and emit the same single warning for the new session.
- Recovery guidance tells the user to back up the SavedVariables file first, restore a compatible value or deliberately remove only `RMA_Raids`, and then `/reload`.
- Never recommend deleting all RMA SavedVariables.

### Codex's Discretion
- Exact internal names for the transient quarantine state and the three stable diagnostic codes.
- Exact localized wording, provided it preserves the decisions above and existing localization conventions.
- The smallest existing UI pattern used to render the read-only quarantine state in raid-history views.
- Test fixture organization and assertion wording.

</decisions>

<specifics>
## Specific Ideas

- Quarantine is session-derived from the current archive validation result, never persisted as a separate flag.
- A rejected archive must remain reference-identical and deeply unchanged across initialization and save preparation.
- The user experience distinguishes "no raid history" from "raid history exists but is unavailable because it is quarantined."

</specifics>

<code_context>
## Existing Code Insights

### Reusable Assets
- `Database/SavedVariables.lua`: already owns all direct public SavedVariables access, tracks `raidArchiveError`, validates in `NormalizeAfterLoad()` and `PrepareForSave()`, and exposes `GetRaidArchiveError()`.
- `Database/DBRaidStore.lua`: already checks `GetRaidArchiveError()` before archive access and returns the quarantine reason, providing the fail-closed store boundary.
- `Init.lua`: `ADDON_LOADED` is the single integration point for normalization result handling, transient state, and the once-per-session warning.
- `addon:warn`, `addon:debug`, `addon.L`, and `addon.Diag`: existing output and localization/diagnostic channels should be reused.
- `tests/lua/harness/30_raid_runtime.lua`: already covers malformed format-1 quarantine, unchanged data, rejected save preparation, and fail-closed reads.

### Established Patterns
- `RMA_Raids == nil` represents a fresh install and may initialize the canonical format-1 archive.
- Invalid format-1 archives are already preserved and quarantined after validation; future-format and non-table values must enter the same safety path before replacement.
- Feature reads already return empty/fail-closed results through the raid-store quarantine guard.
- English localization loads first and supported locale files provide matching user-facing scalar keys under the repository localization contract.

### Integration Points
- Change archive initialization and validation ownership only inside `Database/SavedVariables.lua`.
- Consume the normalization result in `Init.lua` before `State.initialized` is committed.
- Keep store mutation rejection centralized through the existing quarantine guard in `Database/DBRaidStore.lua`.
- Add localized warning strings and diagnostics through the existing localization owners, not inline runtime text.
- Extend the current raid archive harness cases rather than creating a separate test framework.

</code_context>

<deferred>
## Deferred Ideas

None - discussion stayed within the phase boundary. Automatic repair, migration, peer recovery, and destructive reset tooling remain explicitly out of scope.

</deferred>

---

*Phase: 01-persistence-safety*
*Context gathered: 2026-08-15*
