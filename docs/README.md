# Raid Management Addon Development Docs

This directory documents the current development surface of Raid Management
Addon. The docs are implementation-facing: they describe the runtime layout,
stable external contracts, and current validation options.

## Documents

- `ARCHITECTURE.md` maps the runtime ownership boundaries and TOC load layers.
- `API_SURFACE.md` defines the supported `_G.RMA` and external compatibility surfaces.
- `DEVELOPMENT.md` defines the development workflow for WotLK 3.3.5a work.
- `SAVED_VARIABLES.md` documents the `RMA_*` persistence contract.
- `VALIDATION.md` documents static/offline validation gates and non-blocking
  manual in-game acceptance.

## Tooling

The available local static validators are provided by the ignored agent skill
folder and can be run through the Python launcher:

```powershell
py -3 .agents\skills\wow-addon-dev-wotlk-v335a\scripts\validate_toc.py "Raid Management Addon\Raid Management Addon.toc"
py -3 .agents\skills\wow-addon-dev-wotlk-v335a\scripts\lint_lua51.py "Raid Management Addon"
py -3 .agents\skills\wow-addon-dev-wotlk-v335a\scripts\scan_xpcall.py "Raid Management Addon"
git diff --check
```

Static checks are the required Codex completion gate. In-game validation is a
separate manual acceptance activity and is not required for Codex commit
readiness unless explicitly requested.
