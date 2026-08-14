# Task 4 Report: Live Spammer Channel Selector

## Implemented

- Replaced the fixed `Chat1` through `Chat8`, Guild, and Yell checkbuttons with one layout-only WotLK `UIDropDownMenuTemplate` frame.
- Added a controller-local `{ value, text, checked, disabled }` option model rebuilt whenever the menu opens.
- Populated options from the WotLK `GetChannelList()` `{ id, name }` pair shape, followed by `YELL` and `GUILD`.
- Kept saved but currently unavailable channel names visible as checked, disabled rows with a localized unavailable suffix.
- Preserved name-based `Draft.GetChannels` and `Draft.SetChannelChecked` persistence; rendering does not add or remove saved choices.
- Guarded disabled and locked dropdown callbacks so only an enabled user click can call `Draft.SetChannelChecked`.
- Reused `setInputsLocked` to enable and disable the dropdown during active runs.
- Corrected `Comms` channel resolution to iterate WotLK channel pairs while retaining exact-name, ambiguity, and delivery-failure behavior.

## TDD Evidence

### RED

Command:

```powershell
py -3 -m unittest tests.test_spammer_warnings_behavior -q
```

Expected failures observed before runtime changes:

- `channel dropdown must be initialized`
- `ambiguous channel names must fail closed: expected nil, got true`

The first proved the fixed checkbox controller could not expose the live/saved option model. The second proved the three-column `Comms` iteration skipped duplicate names in WotLK pair-shaped rows.

### GREEN

Command:

```powershell
py -3 -m unittest tests.test_spammer_warnings_behavior -q
```

Result: `Ran 13 tests ... OK`.

### Review Fix: Kept-Open WotLK Click State

The follow-up review found that `UIDropDownMenu` keeps the menu open and supplies the new checked state as the fourth callback argument. The harness was changed first to model `func(self, arg1, arg2, checked)`, click the same live row twice, and exercise the live row while the run lock is active.

RED command:

```powershell
py -3 -m unittest tests.test_spammer_warnings_behavior -q
```

Expected failure observed before the callback fix:

- `second live channel click must remove the kept-open choice: expected false, got true`

The controller callback now forwards WotLK's authoritative `checked` argument to `Draft.SetChannelChecked` instead of toggling the stale menu-build snapshot. Disabled and locked callbacks remain guarded.

GREEN result: `Ran 13 tests ... OK`. The test now proves add, remove, locked no-op, dropdown disable on start, and dropdown enable on stop.

## Validation

- `py -3 -m unittest tests.test_config_xml_contract -q` - 10 tests passed.
- `py -3 -m unittest discover -s tests -q` - 270 tests passed.
- WotLK TOC validator - 1 file clean, 0 errors, 0 warnings.
- Lua 5.1 validator - 134 files clean.
- Lua 5.1 `xpcall` scan - 134 files clean.
- `luacheck` on the two touched runtime Lua files - 0 warnings, 0 errors.
- XML script-handler scan - no matches.
- Retired fixed channel-control scan - no matches.
- `git diff --check` - passed.

The focused, XML contract, full, Lua 5.1, `xpcall`, XML handler, `luacheck`, and diff validations above were rerun after the review fix with the same passing results.

`tools/check-rma.ps1` and a repository StyLua configuration are not present in this worktree. A direct default `stylua --check` was not used as a gate because it requested whole-file line-ending/format normalization outside Task 4's scoped changes.

## Files Changed

- `Raid Management Addon/UI/Spammer.xml`
- `Raid Management Addon/Controllers/Spammer.lua`
- `Raid Management Addon/Modules/Comms.lua`
- `Raid Management Addon/Localization/localization.en.lua`
- `tests/lua/runtime_harness.lua`
- `tests/test_spammer_warnings_behavior.py`
- `.superpowers/sdd/task-4-report.md`

## Self-Review

- KISS/YAGNI: no polling, membership cache, migration, new service, or public API was added.
- Ownership: the controller owns transient display choices, Draft owns persistence, Comms owns send-time channel resolution, and XML owns layout only.
- WotLK/Lua 5.1: uses only 3.3.5a dropdown and chat APIs, pair-shaped channel rows, Lua 5.1 syntax, and no variadic `xpcall`.
- SavedVariables: no schema or canonical channel-name contract changed.

## Residual Risk

- The menu layout and multi-select interaction still require the normal in-game WotLK 3.3.5a smoke test; the local harness cannot render Blizzard dropdown templates.
