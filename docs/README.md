# Raid Management Addon Development Docs

This directory documents the current development surface of Raid Management
Addon after the reset to commit `f964f6c9501e23ac894605fbd19068b462ac8477`.
The docs are implementation-facing: they describe the runtime layout, stable
external contracts, current validation options, and the GREENFIELD_REWRITE
policy surface that was intentionally kept from the newer branch state.

## Documents

- `ARCHITECTURE.md` maps the runtime ownership boundaries and TOC load layers.
- `DEVELOPMENT.md` defines the development workflow for WotLK 3.3.5a work.
- `SAVED_VARIABLES.md` documents the `RMA_*` persistence contract.
- `VALIDATION.md` documents static and in-game validation gates.
- `GREENFIELD_REWRITE_CONTRACT.md` is the preserved rewrite contract and batch
  coherence policy.

## Tooling

This baseline does not currently track project-local Python tooling under
`tools/`. The available local static validators are provided by the ignored
agent skill folder and can be run through the project `.venv`:

```powershell
.\.venv\Scripts\python.exe .agents\skills\wow-addon-dev-wotlk-v335a\scripts\validate_toc.py "Raid Management Addon\Raid Management Addon.toc"
.\.venv\Scripts\python.exe .agents\skills\wow-addon-dev-wotlk-v335a\scripts\lint_lua51.py "Raid Management Addon"
.\.venv\Scripts\python.exe .agents\skills\wow-addon-dev-wotlk-v335a\scripts\scan_xpcall.py "Raid Management Addon"
git diff --check
```

Static checks are necessary but not sufficient for runtime confidence. UI,
combat-lockdown, loot, sync, and SavedVariables behavior still need a real
WotLK 3.3.5a client smoke test.
