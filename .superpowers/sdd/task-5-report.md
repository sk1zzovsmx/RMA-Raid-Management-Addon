Status: DONE_WITH_CONCERNS

Commits created:
- `70a3fcc` - `refactor(ui): Use explicit widget dispatch registration`

Files changed:
- `Raid Management Addon/Modules/UI/Facade.lua`
- `Raid Management Addon/Widgets/Config.lua`
- `Raid Management Addon/Widgets/LootCounter.lua`
- `Raid Management Addon/Widgets/LootHints.lua`
- `Raid Management Addon/Widgets/RaidGrid.lua`
- `Raid Management Addon/Widgets/ReservesUI.lua`
- `Raid Management Addon/Widgets/TradeMenu.lua`
- `tests/test_ui_frame_helper_ownership.py`
- `tests/test_ui_widget_dispatch_contract.py`

Test commands run and exact pass/fail summary:
- `py -3 -m unittest tests.test_ui_widget_dispatch_contract`
  - Red run before implementation: `FAILED (failures=2)` because `Facade.lua` had no `RegisterMethod`/`RegisterFunction` APIs and widget modules still used ambiguous registration only.
  - Final rerun: `Ran 2 tests in 0.001s` -> `OK`.
- `py -3 -m unittest tests.test_ui_frame_helper_ownership`
  - Red run before implementation: `FAILED (failures=4)` because the widget files had not yet classified method-style vs function-style dispatch callables.
  - Final rerun: `Ran 61 tests in 0.038s` -> `OK`.
- `py -3 -m unittest discover -s tests`
  - Final result after implementation and formatting: `Ran 387 tests in 0.712s` -> `OK`.
- `py -3 .agents\skills\wow-addon-dev-wotlk-v335a\scripts\validate_toc.py "Raid Management Addon\Raid Management Addon.toc"`
  - Final result: `OK: 0 error(s), 0 warning(s) in 1 file(s)`.
- `py -3 .agents\skills\wow-addon-dev-wotlk-v335a\scripts\lint_lua51.py "Raid Management Addon"`
  - Final result: `OK: 136 file(s) clean`.
- `py -3 .agents\skills\wow-addon-dev-wotlk-v335a\scripts\scan_xpcall.py "Raid Management Addon"`
  - Final result: `OK: 136 file(s) clean of variadic xpcall`.
- `luacheck "Raid Management Addon"`
  - Final result: `Total: 0 warnings / 0 errors in 123 files`.
- `stylua --check --line-endings Windows "Raid Management Addon"`
  - First run after implementation: failed with formatting diffs in the touched Lua files.
  - After `stylua --line-endings Windows` on the touched widget/facade files: final rerun passed with exit code `0` and no output.
- `powershell -ExecutionPolicy Bypass -File tools\check-rma.ps1`
  - Unavailable in this checkout. Exact error:
    `L'argomento 'tools\check-rma.ps1' per il parametro -File non esiste. Specificare il percorso di un file con estensione 'ps1' esistente come argomento per il parametro -File.`
- `git diff --check`
  - Final result: passed with exit code `0`.
- `git diff --cached --check`
  - Final result: passed with exit code `0`.

Self-review notes, including runtime smoke gaps:
- `Modules/UI/Facade.lua` now keeps widget owner registration separate from explicit dispatch registration, with style-specific `RegisterMethod` and `RegisterFunction` buckets. `CallMethod` no longer reaches function-style exports, and `CallFunction` no longer reaches method-style exports.
- Widget registration now declares the intended dispatch surface explicitly:
  - method-style: `Config`, `LootCounter`, `Reserves`
  - function-style: `LootHints`, `RaidGrid`, `TradeMenu`
- Public callers remain unchanged: `UI.Widgets.CallMethod(widgetId, methodName, ...)` and `UI.Widgets.CallFunction(widgetId, methodName, ...)`.
- Runtime smoke gap: no live WotLK 3.3.5a login, `/rma`, or `/reload` validation was run in-game during this task. Static gates are green; live widget behavior remains manual acceptance.
- Workspace note: unrelated untracked `.superpowers/sdd/*.diff`, `progress.md`, and earlier task brief/report files were left untouched and were not included in the commit.

---

Fix follow-up for reviewer finding: widget dispatch behavior coverage

- Scope: addressed only the Important test-gap finding from `review-8519f39..70a3fcc.diff`; left the `RaidGrid.ShowPicker` minor note untouched.
- Change made: replaced the source-grep-only `tests/test_ui_widget_dispatch_contract.py` coverage with a focused Python `unittest` that executes `Raid Management Addon/Modules/UI/Facade.lua` through `lua.cmd` in a minimal harness.
- Behavior proved by the new test:
  - `Widgets.RegisterMethod(...)` is callable through `Widgets.CallMethod(...)` and receives the registered widget owner as `self`.
  - `Widgets.RegisterFunction(...)` is callable through `Widgets.CallFunction(...)` without method-style `self`.
  - `CallMethod(...)` does not fall back to function-style registrations.
  - `CallFunction(...)` does not reach method-style registrations.
  - Cross-style calls return `nil` and do not increment invocation counters.
- Commands run for the fix:
  - `py -3 -m unittest tests.test_ui_widget_dispatch_contract` -> `Ran 1 test ... OK`
  - `py -3 -m unittest discover -s tests` -> `Ran 386 tests ... OK`
  - `git diff --check` -> clean after normalizing the new test file to Windows line endings
- Commit for this follow-up fix: `test(ui): cover widget dispatch behavior`.
