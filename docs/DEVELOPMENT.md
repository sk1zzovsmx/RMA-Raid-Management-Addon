# RMA Development Workflow

Keep changes grounded in the current addon and the WotLK 3.3.5a client. This
repository starts clean; do not add compatibility layers or migrations for
non-RMA historical state unless explicitly requested.

## Before Editing

1. Inspect the working tree:

```powershell
git status --short --branch
rg --files
```

2. Map ownership through the TOC and the relevant namespace:

- persistence and schema: `Database/*`
- shared helpers/static data: `Modules/*`
- service/model logic: `Services/*`
- top-level feature frames: `Controllers/*`
- child UI widgets: `Widgets/*`
- slash/minimap entrypoints: `EntryPoints/*`
- XML layout: `UI/*`

3. For multi-file runtime changes, write a concise plan before patching.

## Runtime Constraints

- Target client: WotLK 3.3.5a
- TOC Interface: `30300`
- Lua runtime: Lua 5.1
- No Ace2 or Ace3 dependency introduction
- No runtime use of `io`, `os`, or `debug`
- No Retail/Classic-only APIs such as `C_Timer`, `C_AddOns`, `Settings.*`,
  `MenuUtil`, `SetAtlas`, `SetColorTexture`, or `SetMask`
- No Lua 5.2+ syntax/APIs such as `goto`, `_ENV`, `table.pack`,
  `table.unpack`, `bit32`, bitwise operators, or integer division
- Use global `unpack` and Blizzard `bit.*` when needed

## Coding Rules

- Default to `local`; export deliberately through `addon.*` namespaces.
- Public module tables and exported methods use PascalCase.
- Use `:` only when the function expects `self`; use `.` for plain module
  functions.
- Keep arrays 1-indexed. If holes are possible, do not rely on `#t`.
- Recoverable failures return `nil, "reason"` or `false` with a localized
  message.
- User-facing strings go through `addon.L`.
- Diagnostic templates go through `addon.Diagnose`.
- XML is layout-only; bind behavior in Lua.

## Local Checks

This reset baseline does not track `tools/check-rma.ps1`. Use the available
WotLK validator scripts from the ignored local skill folder:

```powershell
.\.venv\Scripts\python.exe .agents\skills\wow-addon-dev-wotlk-v335a\scripts\validate_toc.py "Raid Management Addon\Raid Management Addon.toc"
.\.venv\Scripts\python.exe .agents\skills\wow-addon-dev-wotlk-v335a\scripts\lint_lua51.py "Raid Management Addon"
.\.venv\Scripts\python.exe .agents\skills\wow-addon-dev-wotlk-v335a\scripts\scan_xpcall.py "Raid Management Addon"
```

If a repo-local checker or API extractor is reintroduced, document it here and
keep `VALIDATION.md` aligned.

For documentation-only changes, also run:

```powershell
git diff --check
git status --short --branch
```

## Manual In-Game Acceptance

Static checks cannot prove protected-action, UI, SavedVariables, sync, or server
chat behavior. In-game validation is manual acceptance, not a blocking Codex
gate. When requested, test in a WotLK 3.3.5a client:

- login with no Lua errors
- `/rma` opens help
- main windows create without missing-frame errors
- `/reload` preserves expected `RMA_*` SavedVariables
- raid, loot, reserves, logger, warnings, and spammer workflows still operate
