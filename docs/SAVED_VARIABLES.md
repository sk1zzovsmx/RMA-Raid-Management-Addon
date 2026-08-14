# RMA SavedVariables Contract

Raid Management Addon uses only `RMA_*` account SavedVariables. This addon
starts clean and must not read, migrate, or write non-RMA SavedVariables unless
an explicit import tool is requested. SavedVariables migrations are reserved for
future `RMA_*` schema evolution, not automatic conversion from other addons or
old project identities.

## Declared Variables

Declared in `Raid Management Addon/Raid Management Addon.toc`:

- `RMA_Raids`
- `RMA_Players`
- `RMA_Reserves`
- `RMA_Warnings`
- `RMA_Spammer`
- `RMA_Options`

## Ownership

`Database/SavedVariables.lua` is the single runtime access boundary for creating,
reading, replacing, or clearing the declared `RMA_*` tables. Feature owners
still own the schema and meaning of their stores:

- `RMA_Raids`: raid history, boss records, loot records, attendance, and raid
  schema data. Schema/model behavior is owned by `Database/DBRaid*` and
  raid/logger/loot services.
- `RMA_Players`: player-level persisted data when required by raid history.
- `RMA_Reserves`: canonical reserve imports, aliases, and reserve state owned by
  `Services/Reserves.lua` and `Services/Reserves/*`.
- `RMA_Warnings`: saved raid warning templates owned by
  `Services/Warnings/Store.lua`.
- `RMA_Spammer`: LFM spammer draft/options owned by `Services/Spammer/Draft.lua`.
- `RMA_Options`: typed option namespaces owned by `Database/DBOptions.lua`.

## Persistence Rules

- Persist only canonical restore-critical data.
- Keep derived indexes, caches, and runtime-only fields out of SavedVariables.
- Strip runtime raid caches before logout.
- Use stable identifiers instead of volatile array indexes for cross-session
  references.
- Any schema change must be deliberate, documented in the change, and validated
  with a reload smoke test.
- Do not write options through ad hoc globals; use the option namespace helpers.
- Option admission is strict: `Database/DBOptions.lua` retains a persisted value
  only when its Lua type matches the registered default. Invalid types are reset
  to independent copies of their defaults, while valid `false` values remain
  unchanged. Unknown option names and non-string keys are removed after all
  namespaces are registered.
- Option admission reads and normalizes only `RMA_Options`; it does not inspect,
  import, or migrate data from any non-RMA SavedVariables.

## Schema Evolution

- Bootstrap initializes missing `RMA_*` tables, option defaults, and current
  schema shape.
- Migrations only transform existing `RMA_*` data from an older RMA schema
  version to the current RMA schema.
- An older RMA build rejects raid records written by a newer raid schema before
  normalization, migration, query cache construction, or save preparation. The
  newer record and any fields unknown to the older build remain untouched.
- Migrations must not read or convert non-RMA keys. If a legacy import is ever
  required, implement it as a separate, explicit importer outside normal startup.
- Schema versions are persistence contracts and do not need to match the addon
  SemVer in the TOC.

## Development Checks

The available TOC validator verifies the declared TOC file and catches malformed
SavedVariables directives. It does not replace an in-game reload smoke test for
persistence behavior:

```powershell
py -3 .agents\skills\wow-addon-dev-wotlk-v335a\scripts\validate_toc.py "Raid Management Addon\Raid Management Addon.toc"
```
