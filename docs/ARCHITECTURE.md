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

- `Init.lua` seeds `addon.Database`, `addon.Services`, `addon.Controllers`,
  `addon.Widgets`, `addon.UI`, `addon.Events`, `addon.State`, and the main event
  dispatcher.
- `Database/*` owns persistence contracts, the single SavedVariables access
  boundary, raid schema, raid-record accessors exposed by
  `Database/DBRaidStore.lua`, sync payload import/export, and database service
  lookup.
- `Modules/*` owns shared helpers, constants, event names, communication,
  item/string/time utilities, static datasets, module registry, and shared UI
  helpers. `Modules/UI/Frames.lua` owns shared frame getters, module-frame
  binding, popup wrappers, tooltip wrappers, and frame-script safety helpers.
- `Services/*` owns runtime logic and models. Services must not call
  controllers, own controller frames, or reference widgets directly.
- `Controllers/*` owns top-level feature frames and composes widgets/services.
- `Widgets/*` owns reusable feature UI components. Widgets should not own
  persistence.
- `EntryPoints/*` owns `/rma` routing and the minimap entrypoint.
- `UI/*` is layout-only.

## Feature Areas

- Raid state and attendance: `Services/Raid/*`, with active raid session state
  owned by `Services/Raid/State.lua`, plus `Services/EquipInspect.lua`,
  `Services/SpecInspect.lua`, `Controllers/Logger.lua`, and attendance XML.
- Master loot: `Controllers/Master.lua`, `Services/Master/*`,
  `Services/Loot/*` with runtime loot state owned by
  `Services/Loot/State.lua`, `Services/Rolls/*`, `Widgets/RaidGrid.lua`,
  `Widgets/LootHints.lua`, and master/raid-grid XML.
- Loot history/logger: `Services/Logger/*`, `Controllers/Logger.lua`,
  `Database/DBRaid*`, `Database/DBSync*`, and logger/history XML.
- Reserves and SoftRes: `Services/Reserves.lua`, `Services/Reserves/*`,
  `Widgets/ReservesUI.lua`, and reserves XML.
- Raid warnings: `Controllers/Warnings.lua`, `Services/Warnings/Store.lua`,
  and warnings XML.
- LFM spammer: `Controllers/Spammer.lua`, `Services/Spammer/Draft.lua`, and
  spammer XML.
- Configuration: `Widgets/Config.lua`, `Database/DBOptions.lua`, and config XML.

## Event Flow

`Init.lua` registers WoW events after `ADDON_LOADED`, forwards selected events
through `addon.Bus`, and delegates feature-specific work to services. Keep new
cross-feature notifications event-driven where practical and avoid feature-frame
polling.

## Export Surface

The stable external contract is `/rma`, `RMA_*` SavedVariables, RMA-prefixed
addon-message channels, TOC metadata, and user-visible RMA branding. Internal
`addon.*` module exports are implementation surfaces unless a caller contract is
explicitly documented in a future change.
