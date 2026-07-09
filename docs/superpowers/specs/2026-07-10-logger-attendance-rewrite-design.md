# Logger And Attendance Rewrite Design

Date: 2026-07-10

## Context

The current checkpoint separates Attendance from Logger mechanically: Attendance
has its own controller and services, while Logger no longer owns the
attendance frame workflow. That checkpoint is intentionally treated as a stable
rollback point, not as the final architecture.

The next batch rewrites the internal ownership of Logger and Attendance so the
two features are independent domains. This design preserves public RMA runtime
contracts and keeps UI changes limited to one approved exception: the Raid
Attendance CSV command moves from the Logger window to the Attendance window.

## Goals

- Keep Logger and Attendance as separate product domains.
- Preserve existing frame identities, slash/minimap routing, SavedVariables,
  wire formats, and core behavior.
- Keep the UI visually and operationally equivalent except for moving the Raid
  Attendance CSV command into Attendance.
- Make Logger own only logger, loot history, and logger export behavior.
- Make Attendance own raid attendance lists, attendee actions, inspect/spec row
  presentation, and attendance CSV export.
- Prefer a small number of cohesive files over fragmented one-concept files.
- Use qualitative architecture criteria instead of line-count targets.

## Non-Goals

- No broad visual redesign.
- No SavedVariables migration.
- No sync or addon-message format change.
- No change to the inspect provider contract unless a direct bug is found.
- No new compatibility bridge for old project identities.
- No file splitting solely to reduce line count.

## Architecture

`Controllers/Logger.lua` owns the Logger window and logger workflows only:
loot history rows, filtering, selection, logger-specific actions, and
logger/loot CSV export. It must not own Attendance state, list controllers,
or attendance export commands.

`Controllers/Attendance.lua` owns the Attendance window:
`RMARaidAttendance*` frames, raid selection, attendee selection, list refresh,
delete attendee, force inspect, spec and inspect icon rendering, event-driven
refresh, and the Raid Attendance CSV command.

`Services/Attendance/Store.lua` owns attendance data access helpers such as
raid lookup, player lookup, runtime index invalidation, and difficulty labels.

`Services/Attendance/View.lua` owns Attendance read models for UI lists:
raid rows, attendee rows, and inspect/spec enrichment. It must not touch
frames, widgets, or `_G`.

`Services/Attendance/Actions.lua` owns Attendance mutations such as attendee
deletion and any related schema normalization or sync revision touches. It
must not own frame behavior.

`Services/Attendance/Export.lua` is added as the explicit owner of Raid
Attendance CSV generation. It consumes raid attendance data and returns CSV
strings. It must not touch frames, widgets, or `_G`.

`Services/Logger/Export.lua` remains only for Logger and loot-history export.
It must not call attendance queries or expose `GetRaidAttendanceCSV`.

## Data Flow

Attendance controller input comes from frame events, user actions, slash/minimap
routing, and internal events:

- `RaidCreate`
- `RaidAttendanceChanged`
- `EquipInspectUpdated`
- `EquipInspectCompleted`

The controller delegates data work:

- list models to `Attendance.View`
- raid/player lookup to `Attendance.Store`
- mutating attendee operations to `Attendance.Actions`
- CSV generation to `Attendance.Export`
- force inspect to `Services.EquipInspect`

Logger data flow remains independent:

- logger row models come from `Services/Logger/View.lua`
- logger actions come from `Services/Logger/Actions.lua`
- logger CSV export comes from `Services/Logger/Export.lua`

Logger must not query attendance rows, construct attendance CSV, or invoke
Attendance controller internals.

## UI Behavior

The default rule is UI compatibility: existing frames, layout, columns, labels,
sort behavior, tooltips, and user workflows remain intact.

The approved exception is the Raid Attendance CSV command:

- remove the Raid Attendance CSV button from the Logger UI surface
- add the equivalent command to the Attendance window
- generate the CSV through `Services/Attendance/Export.lua`
- preserve the CSV content and format unless an existing bug is explicitly
  documented and fixed

No other visible UI redesign is part of this batch.

## Behavioral Compatibility

The batch preserves:

- `/rma attendance` behavior
- minimap Attendance entry behavior
- `RMARaidAttendance*` frame identities
- raid and attendee list sorting
- spec icon rendering and tooltip behavior
- inspect item icon rendering and tooltip behavior
- force inspect behavior
- attendee deletion effects on players, attendance rows, boss attendee lists,
  and loot rows
- CSV attendance content format
- existing RMA SavedVariables and wire formats

## Testing Strategy

Ownership tests must verify:

- Logger does not contain `RaidAttendanceBtn`
- Logger does not expose or call `GetRaidAttendanceCSV`
- Logger export does not call attendance queries
- Attendance owns the CSV command
- `Services/Attendance/Export.lua` is in the TOC and ModuleRegistry
- `Services/Attendance/*` do not touch frames, widgets, or `_G`
- `Controllers/Attendance.lua` uses `Attendance.Export` for CSV
- `Controllers/Logger.lua` does not invoke Attendance controller internals

Behavior-oriented tests must verify:

- inspect item icons use `itemLink` and `texture`
- spec icons and tooltip wiring stay in the Attendance controller
- attendee deletion stays in `Attendance.Actions`
- attendance CSV header, rows, and escaping remain equivalent
- TOC order keeps services before controllers and XML before frame binding

## Validation Gates

Final validation for the implementation batch should include:

- `py -3 -m unittest discover -s tests`
- Lua 5.1 lint for the addon
- TOC validation
- `scan_xpcall.py`
- `luacheck "Raid Management Addon"`
- `stylua --check` on touched Lua files
- `git diff --check`

The reset baseline does not currently track `tools/check-rma.ps1`, so that gate
is unavailable unless restored. In-game smoke remains a manual acceptance step
unless explicitly requested as a blocking gate.

## Implementation Order

The implementation plan should be written after this design is approved. The
expected order is:

1. Commit the current mechanical Logger/Attendance split as its own checkpoint.
2. Add `Services/Attendance/Export.lua` and route Attendance CSV through it.
3. Move the Raid Attendance CSV command from Logger UI to Attendance UI.
4. Rewrite Attendance controller internals around the Store/View/Actions/Export
   service boundary.
5. Remove remaining attendance export responsibility from Logger services and
   controller code.
6. Update ownership and behavior tests.
7. Run the validation gates and record any runtime smoke gap honestly.

## Acceptance Criteria

- Logger and Attendance are independent domains.
- Logger no longer owns attendance UI state or attendance CSV generation.
- Attendance owns attendance UI, data presentation, attendee mutations, inspect
  presentation, and attendance CSV generation.
- The only intentional UI change is moving Raid Attendance CSV from Logger to
  Attendance.
- Public RMA contracts remain stable.
- Tests protect the new ownership boundaries and the preserved behavior.
- Static validation gates pass, with unavailable gates and runtime smoke status
  reported explicitly.
