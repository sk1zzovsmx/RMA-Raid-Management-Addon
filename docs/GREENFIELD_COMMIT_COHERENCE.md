# GREENFIELD Commit Coherence Report

This is the current static/offline commit coherence report for the
ModuleRegistry, dependency proxy, unused feature flag, widget registry,
duplicate UI infrastructure, and impossible RaidStore fallback removal batch.
It does not claim live-client acceptance because the runtime smoke gap is
recorded below.

## Current Scope

The batch removes the runtime dependency registry that duplicated the TOC and
the shared dependency proxy and UI dispatch layers that obscured concrete
owners:

- `Modules/ModuleRegistry.lua` is deleted;
- its TOC entry is removed;
- module registration, loaded-state, dependency metadata, and bootstrap queues
  are removed from non-vendored runtime Lua;
- `Database.GetFeatureShared`, its metatable resolver, and every `feature.*`
  binding are removed;
- runtime files bind `addon.Database`, `addon.Services`, `addon.UI`,
  `addon.State`, `addon.C`, and other concrete owners directly;
- the diagnostic proxy is published explicitly as `addon.Diag`;
- `Modules/Features.lua` and its permanently enabled `full` profile are deleted;
- `Modules/UI/Facade.lua` and the string-keyed widget registry are deleted;
- slash commands, minimap actions, and the Master controller call concrete
  `addon.Widgets` owners directly;
- widget modules publish their APIs directly and no longer register duplicate
  method/function metadata;
- Config callers use the always-loaded controller directly and no longer test
  an always-true availability contract;
- Attendance and Logger share `UI.Lists.CalculateColumnWidths` and the concrete
  `UI.ExportDialog` owner in `Modules/UI/Frames.lua`;
- `Database.GetRaidStore()` resolves the canonical `DB.RaidStore` directly and
  fails fast on invalid TOC/load order;
- all consumers and feature stores drop optional store resolution,
  missing-method checks, and alternate empty/schema fallback paths;
- migration compaction and current-schema normalization remain intentionally
  separate;
- tests now verify concrete bindings and behavior instead of registry path
  strings;
- the rewrite contract names the TOC as the sole load-order authority.

The cumulative runtime delta for points 1 through 4 plus the downstream
deduplication pass is 1,248 added or rewritten lines and 4,361 deleted lines, a
net reduction of 3,113 lines. The post-point-3 passes account for a further net
reduction of 556 runtime lines. The two files that were already staged before
these batches remain staged and otherwise untouched by this report.

## TOC And Load Order

The final implementation requires:

- every Lua/XML file referenced by `Raid Management Addon.toc` is tracked for
  release packaging;
- `Database\SavedVariables.lua` loads before option and raid-store users;
- `Widgets\LootHints.lua` loads after reserve sync/service owners it depends on;
- concrete owners load before their consumers through TOC order only.

No runtime module registry, pending-registration queue, or duplicated registry
dependency graph remains.

No feature profile, widget enablement table, runtime widget registry, or generic
widget dispatcher remains. Widget availability is determined by the TOC and
concrete owner initialization.

Runtime dependencies are now visible as direct bindings to concrete addon
namespaces. Constants bind through `addon.C`; shared state binds through
`addon.State`; no service-locator alias remains.

The early-loaded `Database.GetRaidStore()` function resolves `DB.RaidStore` at
call time because SavedVariables loads before the store implementation, but it
does not route through the configurable manager or accept alternate owners.

## Deleted References

Static scans cover `ModuleRegistry`, `ModuleRegistryPendingLoads`,
`ModuleRegistryPendingRegistrations`, and the retired bootstrap registration
helper. The removal guard also verifies that the deleted file and TOC entry do
not return.

The explicit-dependency guard scans for `GetFeatureShared`, `local feature =`,
and `feature.*` across all non-vendored runtime Lua.

The UI dependency guard verifies that `Modules/Features.lua` and
`Modules/UI/Facade.lua` stay deleted and scans for `addon.Features`,
`UI.Widgets`, widget registration calls, and generic widget dispatch calls.

The deduplication guards verify that Config availability resolvers, duplicate
column-width algorithms, duplicate export-frame binding, and
`GetRaidStoreOrNil` do not return. They also verify that migration and live
store attendance normalization remain separate.

## Validation Evidence

Latest validation run for this batch:

- `python -m unittest discover -s tests -p "test_*.py"` -> 434 tests OK;
- TOC validator -> 0 errors and 0 warnings;
- LuaJIT `loadfile` syntax sweep -> 116 non-vendored runtime files clean;
- Lua 5.1 compatibility lint -> 129 Lua files clean;
- variadic `xpcall` scan -> 129 Lua files clean;
- `luacheck "Raid Management Addon"` -> 0 warnings and 0 errors in 116 files;
- `stylua --check "Raid Management Addon"` -> OK;
- XML script-handler scan -> no handlers;
- runtime registry/reference scan -> no matches;
- `git diff --check` and `git diff --cached --check` -> no whitespace errors.

`tools/check-rma.ps1` is unavailable in this checkout.

## Runtime Smoke Gap

runtime smoke: not run; manual acceptance pending

Static checks cannot prove frame creation in a live 3.3.5a client,
SavedVariables persistence across `/reload`, sync delivery between grouped
clients, protected-action behavior, combat behavior, or server chat behavior.

## Residual Risk

- In-game smoke remains manual acceptance.
- Historical plans may still mention the removed diagnostic registry as a
  superseded design decision; current runtime and contract surfaces forbid it.
- Any staging pass must rerun the same gates and refresh this report for the
  actual staged commit.
