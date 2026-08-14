# RMA Runtime Architecture

Raid Management Addon targets WotLK 3.3.5a, Interface `30300`, and Lua 5.1. The
TOC is the authoritative load order and the addon folder is `Raid Management
Addon/`. This document reflects the reset baseline at
`f964f6c9501e23ac894605fbd19068b462ac8477` plus the preserved docs contract.

## Runtime Identity

- Addon title: `Raid Management Addon`
- Runtime short name/global: `RMA`
- Main slash command: `/rma`
- SavedVariables prefix: `RMA_`
- Addon-message prefix family: `RMA*`

## TOC Layers

`Raid Management Addon/Raid Management Addon.toc` is organized into explicit
layers:

1. Third-party libraries under `Libs/`.
2. Bootstrap and base database setup: `Init.lua`, `Database/DB.lua`,
   `Database/SavedVariables.lua`, `Database/DBOptions.lua`.
3. Localization and diagnostics.
4. Shared XML templates and lightweight XML-only frames.
5. Shared modules, runtime services, widgets, controllers, and entry points.
6. Concrete XML UI frames loaded after their Lua owners.

Do not add behavior to XML. XML defines layout; Lua owns event binding,
localization, refresh logic, and frame behavior.

## Namespace Ownership

Product-oriented dependency and communication rules are defined in
[`FEATURE_BOUNDARIES.md`](FEATURE_BOUNDARIES.md). The directory layers describe
runtime placement; the feature boundaries describe workflow and data ownership.

- `Init.lua` seeds `addon.Database`, `addon.Services`, `addon.Controllers`,
  `addon.Widgets`, `addon.UI`, `addon.Events`, `addon.State`, and the main event
  dispatcher. `addon.Services.EnsureNamespace` owns creation of nested service
  namespaces; service initialization does not depend on `addon.Database`.
- `Database/*` owns persistence contracts, the single SavedVariables access
  boundary, raid schema, raid-record accessors exposed by
  `Database/DBRaidStore.lua`, sync payload import/export, and database service
  lookup. `addon.Database` is the internal facade used by runtime callers;
  concrete owners live under `addon.DB` and are resolved directly without a
  replaceable manager layer.
  Raid admission is the only path allowed to migrate, repair, assign canonical
  IDs, or advance counters. `DBRaidQueries.lua` observes admitted records without
  mutation, using a bounded transient index owned by `DBRaidStore.lua`. Read
  indexes contain positions and scalar identifiers only, never mutable aliases
  to canonical SavedVariables rows, and are rebuilt for each observation so
  same-length content changes cannot reuse stale lookups. Reusable query output
  buffers are accepted only when caller-owned; canonical collections and rows
  are replaced before output writes so row clearing cannot mutate persisted
  data. `DBRaidValidator.lua`
  traverses raw records in deterministic key order before repair so diagnostics
  retain sparse/map entries, malformed keys and rows, duplicate IDs, invalid
  references, malformed nested collections, and low counters. An explicit empty
  boss attendance table is canonical; roster
  inference is reserved for admission of legacy bosses whose `players` field is
  absent.
  Raid-history synchronization is fail-closed and transactional. `DBSyncer.lua`
  owns authorization, bounded request/chunk state, correlation, and terminal
  delivery; `DBSyncPayload.lua` parses and validates detached snapshots/deltas;
  `DBSyncImport.lua` builds candidates; and `DBRaidStore.lua` alone commits or
  rolls back canonical history and its runtime revision indexes. No inbound
  packet mutates `RMA_Raids` before trust, limits, protocol, schema, raid
  identity, references, and revision monotonicity have all passed.
- `Modules/*` owns shared helpers, constants, event names, communication,
  item/string/time utilities, static datasets, module registry, and shared UI
  helpers. `Modules/UI/Frames.lua` owns shared frame getters, module-frame
  binding, popup wrappers, tooltip wrappers, and frame-script safety helpers.
  `Modules/Comms.lua` owns a bounded FIFO addon-message queue (256 entries),
  draining four messages every 0.08 seconds and returning backpressure before
  accepting an atomic batch that cannot fit.
- `Services/*` owns runtime logic and models. Services must not call
  controllers, own controller frames, or reference widgets directly.
- `Controllers/*` owns top-level feature frames and composes widgets/services.
- `Widgets/*` owns reusable feature UI components. Widgets should not own
  persistence.
- `EntryPoints/*` owns `/rma` routing and the minimap entrypoint.
- `UI/*` is layout-only.

## Feature Areas

- Raid attendance: `Services/Raid/Attendance.lua`,
  `Services/EquipInspect.lua`, `Services/SpecInspect.lua`,
  `Services/Attendance/*`, `Services/Attendance/Export.lua`,
  `Controllers/Attendance.lua`, and attendance XML.
- Raid diagnostics: `Services/Raid/Debug.lua` owns synthetic roster, roll, and
  RaidGrid debug support under `addon.Services.Raid.Debug`.
- Master loot: `Controllers/Master.lua`, `Services/Master/*`,
  `Services/Loot/*` with runtime loot state owned by
  `Services/Loot/State.lua`, `Services/Rolls/*`, `Widgets/RaidGrid.lua`,
  `Widgets/LootHints.lua`, and master/raid-grid XML.
- Loot history/logger: `Services/Logger/*`, `Controllers/Logger.lua`,
  and loot-history XML. Logger export covers logger and loot-history data only.
- Reserves and SoftRes: `Services/Reserves.lua`, `Services/Reserves/*`,
  `Widgets/ReservesUI.lua`, and reserves XML.
- Raid warnings: `Controllers/Warnings.lua`, `Services/Warnings/Store.lua`,
  and warnings XML.
- LFM spammer: `Controllers/Spammer.lua`, `Services/Spammer/Draft.lua`, and
  spammer XML.
- Configuration: `Controllers/Config.lua`, `Database/DBOptions.lua`, and config XML.

## Event Flow

`Init.lua` registers WoW events after `ADDON_LOADED`, forwards selected events
through `addon.Bus`, and delegates feature-specific work to services. Keep new
cross-feature notifications event-driven where practical and avoid feature-frame
polling.

## Export Surface

The stable external contract is `/rma`, `RMA_*` SavedVariables, RMA-prefixed
addon-message channels, TOC metadata, and user-visible RMA branding. Internal
`addon.*` module exports are implementation surfaces unless a caller contract is
explicitly documented. The supported `_G.RMA` surface and expansion policy are
defined in [`API_SURFACE.md`](API_SURFACE.md).
