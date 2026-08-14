# Inspect And Dataset Hardening Report

## Scope

This batch improves runtime safety, data integrity, and maintainability for the
equipment/spec inspection pipeline and instance-scoped loot attribution. It
does not change SavedVariables schemas, addon-message formats, slash commands,
or user-facing frame identities.

## Behavior Deltas

### Complete equipment snapshots

- Old: a cold `GetItemInfo` result could be confused with an empty slot or let
  incomplete equipment replace the canonical snapshot.
- New: occupied cold slots remain bounded runtime work. Only a complete set
  publishes `ready` and average item level; timeout or raid disappearance keeps
  the last known good snapshot.
- Reason: partial equipment is unsafe for attendance and loot decisions.
- Compatibility/migration: no persisted shape or migration change.

### One global inspect owner

- Old: equipment inspection and LibGroupTalents refresh could overlap, clear
  each other's target, or accept completion for a different GUID.
- New: `Services/InspectCoordinator.lua` serializes target ownership, combat
  deferral, timeout, cancellation, and clearing. Completion is GUID-correlated;
  terminal timer failures release ownership.
- Reason: WoW exposes one client-global inspect target.
- Compatibility/migration: snapshot/UI contracts remain compatible; the
  coordinator is internal runtime infrastructure.

### Locale-independent instance identity

- Old: activation depended on English raid names.
- New: supported 3.3.5a map IDs resolve canonical dataset keys, with bounded
  normalized-name fallback. Unknown/non-raid identity fails closed and
  deliberately deactivates instance data.
- Reason: attribution must not depend on client locale.
- Compatibility/migration: canonical attribution formats are unchanged.

### Atomic dataset publication

- Old: activation cleared the active loot index before building its replacement;
  a build error lost the last known good attribution.
- New: supported data builds into detached `ByItemId` and `ByInstance` roots.
  Successful different-key activation swaps roots/key and increments one
  generation. Same-key activation is a no-op. Build errors preserve exact root,
  generation, active-key, and attribution identity. Unsupported identity is a
  deliberate deactivation, distinct from build failure. `Init.lua` restores
  both LootSourcesData and IgnoredMobs from exact runtime snapshots when either
  owner throws or returns `false`; roots, canonical keys, and generations are
  restored together. A recognized raid without special ignored mobs publishes
  a valid empty ignored-mob set.
- Reason: readers observe an old or new complete generation, never a partial
  transition.
- Compatibility/migration: duplicate valid definitions remain explicit
  candidates; nil items and malformed sources remain skipped.

## Architecture And Coherence

- TOC: `Services/InspectCoordinator.lua` loads immediately before
  `SpecInspect.lua` and `EquipInspect.lua`; all changed runtime files are
  TOC-referenced. No runtime file is untracked or deleted.
- Registry/namespaces: the coordinator registers only
  `addon.Services.InspectCoordinator` through the existing Services owner. No
  ModuleRegistry dependency, pass-through facade, or public global was added.
- SavedVariables: TOC declarations and all `RMA_*` schemas are unchanged.
  Queues, ownership, candidate indexes, and generations remain runtime-only.
- Wire/UI: no prefix, payload, XML handler, frame identity, slash alias, or
  localization contract changed.
- Vendored libraries: unchanged; LibGroupTalents is coordinated from
  first-party code.

## Automated Evidence

`tests/test_inspect_dataset_behavior.py` and the Lua harness cover cold-cache
resolution, timeout/cancellation, occupied-versus-empty slots, equipment/spec
interleaving, GUID mismatch, combat deferral, coordinator cleanup,
nil/throw failures from equipment-owned handoff, combat-retry, and item-info
timers (including reentrant terminal callbacks),
locale-independent identity, shared dataset activation, fault-injected index
construction, duplicate/nil/malformed definitions, and cross-owner rollback.

Final static-gate evidence:

- Python unittest: 191 passed.
- TOC validation: 0 errors, 0 warnings.
- Lua 5.1 validation: 133 files clean.
- Lua 5.1 `xpcall` scan: 133 files clean.
- XML script/handler scan: no matches.
- whole-addon `luacheck` excluding vendored `Libs`: 0 warnings/errors in
  120 files.
- `git diff --check`: passed.
- `stylua --check`: not clean, including pre-existing repository-wide line
  ending/format drift; no mass-format rewrite was applied. The semantic Lua
  validators and luacheck are clean.
- `tools/check-rma.ps1`: unavailable in this repository and not run.

## Residual Client Risk

Static tests cannot reproduce server-specific inspect throttling, item-cache
timing, combat transitions, or exact LibGroupTalents callback ordering. Manual
acceptance should cover attendance equipment, spec icons, rapid player changes,
localized raid entry/exit, and `/reload`.

runtime smoke: deferred by user until the full refactoring program is complete
