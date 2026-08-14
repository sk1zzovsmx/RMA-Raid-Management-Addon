# RMA Validation Gates

Codex completion and commit readiness are based on static/offline validation.
Real-client testing is manual acceptance and is not a blocking gate unless the
user explicitly asks for it.

## Static Gate

Run the local WotLK validator scripts available in the ignored agent skill
folder:

```powershell
py -3 -m unittest discover -s tests -p "test_*.py" -v
py -3 .agents\skills\wow-addon-dev-wotlk-v335a\scripts\validate_toc.py "Raid Management Addon\Raid Management Addon.toc"
py -3 .agents\skills\wow-addon-dev-wotlk-v335a\scripts\lint_lua51.py "Raid Management Addon"
py -3 .agents\skills\wow-addon-dev-wotlk-v335a\scripts\scan_xpcall.py "Raid Management Addon"
rg -n "<Scripts>|<On[A-Za-z]+>" "Raid Management Addon\UI" -g "*.xml"
luacheck "Raid Management Addon" --exclude-files "Raid Management Addon/Libs/**"
git diff --check
```

The ignored `.agents` directory may be absent from an isolated Git worktree.
When that happens, invoke the same validator scripts from the parent checkout
and keep the addon paths pointed at the worktree under test. This repository
does not currently contain `tools/check-rma.ps1`, so that command is not part
of the available static gate and must not be reported as run.

These static gates cover:

- TOC file existence, references, Interface `30300`, and unsupported TOC
  directives.
- Python behavior and contract tests discovered under `tests/`.
- Lua 5.1 parse compatibility across the addon folder.
- Lua 5.1 `xpcall` extra-argument traps.
- XML script blocks or XML event handlers under `UI/`.
- Whole-addon Lua lint outside vendored `Libs/`.
- Git whitespace errors.

For docs-only edits, also run:

```powershell
git diff --check
git status --short --branch
```

## Export Surface Review

After changing exported `addon.*` module names, slash command routing,
SavedVariables, or addon-message prefixes, review `ARCHITECTURE.md` and
`FEATURE_API_MAP.md` for drift.

## Manual In-Game Acceptance

Static checks cannot prove protected-action, UI, SavedVariables, sync, combat,
or server chat behavior. These checks are useful manual acceptance steps when
requested, but Codex should not block completion on them:

- login with no Lua errors
- `/rma` prints help
- `/rma config`, `/rma ml`, `/rma history`, `/rma attendance`, `/rma res`, and
  `/rma counter` open their expected surfaces
- `/reload` preserves only expected `RMA_*` data
- loot, reserves, logger, warnings, and spammer workflows still operate
- addon-message sync still uses `RMA*` prefixes and handles mismatched versions
  predictably

When no in-game validation was requested or run, report the gap explicitly as:

```text
runtime smoke: not run; manual acceptance pending
```

For the progressive whole-addon refactor, the explicitly agreed status text is:

```text
runtime smoke: deferred by user until the full refactoring program is complete
```
