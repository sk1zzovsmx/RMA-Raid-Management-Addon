# RMA Validation Gates

Validation is split into static gates and real-client smoke tests. Passing
static gates does not prove WotLK runtime behavior.

## Static Gate

This reset baseline does not track the later repo-local `tools/check-rma.ps1`
gate. Run the local WotLK validator scripts that are available in the ignored
agent skill folder:

```powershell
.\.venv\Scripts\python.exe .agents\skills\wow-addon-dev-wotlk-v335a\scripts\validate_toc.py "Raid Management Addon\Raid Management Addon.toc"
.\.venv\Scripts\python.exe .agents\skills\wow-addon-dev-wotlk-v335a\scripts\lint_lua51.py "Raid Management Addon"
.\.venv\Scripts\python.exe .agents\skills\wow-addon-dev-wotlk-v335a\scripts\scan_xpcall.py "Raid Management Addon"
rg -n "<Scripts>|<On[A-Za-z]+>" "Raid Management Addon\UI" -g "*.xml"
git diff --check
```

These static gates cover:

- TOC file existence, references, Interface `30300`, and unsupported TOC
  directives.
- Lua 5.1 parse compatibility across the addon folder.
- Lua 5.1 `xpcall` extra-argument traps.
- XML script blocks or XML event handlers under `UI/`.
- Git whitespace errors.

The later GREENFIELD_REWRITE checker surface is documented as a desired gate in
`GREENFIELD_REWRITE_CONTRACT.md`, but the corresponding project-local scripts
are not present in this reset baseline.

For docs-only edits, also run:

```powershell
git diff --check
git status --short --branch
```

## Export Surface Review

After changing exported `addon.*` module names, slash command routing,
SavedVariables, or addon-message prefixes, review `ARCHITECTURE.md` and the
GREENFIELD_REWRITE contract for drift. If a real API extractor is restored
later, document its exact command here.

## In-Game Runtime Gate

Run this after runtime, TOC, SavedVariables, sync, combat, or UI changes:

- login with no Lua errors
- `/rma` prints help
- `/rma config`, `/rma ml`, `/rma history`, `/rma attendance`, `/rma res`, and
  `/rma counter` open their expected surfaces
- `/reload` preserves only expected `RMA_*` data
- loot, reserves, logger, warnings, and spammer workflows still operate
- addon-message sync still uses `RMA*` prefixes and handles mismatched versions
  predictably

Record which parts were static-only and which were validated in the real client.
