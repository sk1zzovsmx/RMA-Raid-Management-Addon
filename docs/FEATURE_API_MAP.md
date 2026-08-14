# RMA Feature API Map

This inventory records the current runtime boundaries before architectural
refactoring. It is descriptive, not a new public API contract. The TOC remains
the load-order authority and all runtime code targets WotLK 3.3.5a / Lua 5.1.

## Interaction Rules

- Commands and queries use direct calls to the owner and return a result.
- Notifications use `addon.Bus` after the state transition succeeds.
- Controllers may compose services and widgets; services must not call
  controllers, widgets, or controller frames.
- `RMA_*` SavedVariables and addon-message payloads are compatibility surfaces.

## Shared Addon-Message Transport

- `addon.Comms.Payload` owns LibSerialize plus LibDeflate addon-channel encoding.
- `addon.Comms` owns destination validation and delegates all outbound scheduling to ChatThrottleLib.
- RMA addon-message protocols use version 5 envelopes and reject earlier versions.
- JSON and Base64 remain import/hash utilities, not addon-message wire codecs.

## Master Loot

`Controllers/Master.lua` is the feature composition root. It owns frame binding,
WoW-event composition, user actions, and the transient UI state. The table
separates methods called by the controller from dependencies that it injects
into cohesive child owners:

| Caller | Owner | Direct calls / composed dependencies | Kind | Purpose |
|---|---|---|---|---|
| Master controller | `Services.Loot` | Direct: `AddItem`, `FetchLoot`, `PrepareItem`, `SelectItem`, `ClearLoot`, `AddPendingAward`, `CancelPendingAward`, `GetAutoLootSuggestion`, `GetCurrentItemCount`, `GetItem`, `GetItemLink`, `GetItemName`, `GetItemTexture`, `GetLootWindowItems`, `ItemExists`, `LogTradeOnlyLoot`, `ScheduleTimer`, `CancelTimer`. `Init.lua`, not Master, calls `AddLoot` for forwarded chat events. | command/query | Build the active loot context, schedule its reconciliation, and cancel only the attribution transaction named by a known terminal failure. |
| Master controller | `Services.Loot.DistributionSession` | Direct: roll/item publication, `RequestSessionEnd`, `Clear`. Composed: award/trade ownership and completion publication. `Services.Loot:FetchLoot` separately owns `BeginWindow`/`PublishWindowItems`. | command/notification | Publish controller-visible distribution transitions while the injected owners retain their own session lifecycles. |
| Master controller | `Services.Loot.Inventory` | Direct: `FindLootSlotIndex`, `ValidateLootSlot`. Composed into `AwardSequence`, `TradeExecution`, and item selection for candidate and inventory-evidence operations. | query/command | Revalidate the irreversible loot-slot boundary and supply evidence APIs to the owners that execute award/trade policy. |
| Master controller | `Services.Loot.AwardPlanner` | Direct: `ValidateInventoryTradeSelection`, `BuildAwardTargetPlan`. Composed into award sequence, trade execution, and item selection. | query | Build deterministic award targets before side effects. |
| Master controller | `Services.Rolls` | `EnsureLootRollSession`, `Roll`, `StartCountdown`, `StopCountdown`, `FreezeRollIntake`, `FinalizeRollSession`, `GetDisplayModel`, `GetResolvedWinner`, `ValidateWinner`, `SyncSessionState` | command/query | Run one roll session and freeze its final immutable award context before any winner effect. |
| Master controller | `Services.Raid` | capability, candidate, context, roster, player-count, and group-loot APIs | command/query | Enforce raid permissions and bridge WoW loot context. |
| Master controller | `Services.Master.*` | `FlowState`, `ButtonState`, `RollRows`, `RollSelection`, `AwardAttempt`, `AwardSequence`, `AwardConfirmation`, `Assignment`, `Messages`, `Trade`, `TradeExecution`, `AwardCounter` | query/command | Own checkpointed award state, single-confirmation admission, future multi-award cancellation, and evidence-gated trade policy outside the controller. |
| Master controller | `Services.Logger.Actions` | `RecordLoot` | command | Persist the completed award in raid history. |
| Master controller | `addon.Bus` | forwarded WoW events, roster delta, set-item, reserves, roll, options, inspect | notification | Refresh UI after completed state transitions. |

### Candidate stable Master contracts

These contracts should be defined only if a caller outside the current owner
needs them. They are domain-shaped and do not create a generic facade:

- `DistributionSession`: lifecycle and transport for an active loot
  distribution; payloads carry `sessionId`, item identity, mode, and revision.
  The shared R5 `WINDOW_BEGIN` body carries an expected-row field that receivers
  enforce before committing the staged window.
- `Rolls`: lifecycle and read model of one roll session; its display model is
  immutable from the controller's perspective.
- `AwardAttempt` and `AwardConfirmation`: runtime-only transaction/checkpoint
  state and one bounded in-flight confirmation. They are internal contracts,
  not persistent recovery records or supported `_G.RMA` API.
- `Inventory`: strict loot-slot comparison and trade evidence capture/query;
  trade acceptance/closure alone is never physical-transfer evidence.
- `AwardPlanner`: pure plan from item, candidates, rule, and selected winners;
  executing the plan remains an explicit side effect.
- `Logger.Actions:RecordLoot`: the single persistence command after an award is
  complete.

## Logger and Attendance

`Controllers/Logger.lua` owns frame composition, selection state, rendering,
popup actions, and refresh subscriptions. `Services.Logger.Store`, `View`,
`Actions`, and `Export` own data retrieval, read models, mutation, and export.
`Services.Raid.Projections` supplies shared raid read models. The controller
must not mutate `RMA_Raids` directly.

Equipment and specialization inspection share `Services.InspectCoordinator`.
Its `Request`, `Release`, and `Cancel` commands serialize the single WoW inspect
target; callers retain ownership of snapshot policy and UI notifications.
`Services.EquipInspect` never replaces a last-known-good equipment snapshot with
cold-cache or timed-out partial data. `Services.SpecInspect` correlates talent
completion to the queued GUID before publishing `SpecInspectUpdated`.

`Modules/Dataset/LootSourcesData.lua` resolves a canonical raid identity and
publishes `ByItemId`, `ByInstance`, active key, and generation only after a
complete detached build. Same-key activation is a no-op. A supported different
key publishes one generation; an unsupported/non-raid identity deliberately
deactivates the dataset; a build error preserves the previous active roots and
generation. `Init.lua` coordinates that lifecycle with `IgnoredMobs` and rolls
both owners back from runtime snapshots if either activation throws or returns
`false`. A canonical raid with no ignored-mob definitions activates an empty,
valid ignored-mob policy rather than rejecting the recognized raid.

## Reserves

`Services/Reserves.lua` is the stateful feature owner for canonical reserve
data and import application. Its children have distinct roles:

- `Reserves/Import.lua`: parse and normalize imported source data.
- `Reserves/Aliases.lua`: resolve player aliases.
- `Reserves/Display.lua`: derive display/read models.
- `Reserves/Sync.lua`: reserve-specific payload and metadata protocol.
- `Reserves/Chat.lua`: bounded, opt-in pre-raid whisper signup and responses.

The parent publishes `ReservesDataChanged` only after a successful state
transition. Splitting the parent is not a goal by itself; a child is justified
only when it owns one of these durable concepts.

Reserve sync publishes only checksum-verified `C2` projections. Imports and UI
batches build detached candidates and publish atomically. Import, participant,
per-player, batch, whisper-admission, and response-queue limits are documented
in `RESERVES_INTEGRITY_REPORT.md`. The Reserves owner also resolves whisper
admission identities to canonical storage participants so Chat never inspects
reserve tables or creates local short/qualified duplicates itself. Inbound and
stored identities share `Reserves:NormalizeWhisperPlayerIdentity`; realm spaces,
apostrophes, and hyphens normalize identically without losing the selected
stored display name.

## Spammer And Raid Warnings

`Services.Spammer.Draft` owns canonical `RMA_Spammer` normalization, preview
construction, and clear semantics. `Services.Spammer.Runtime` owns one immutable
run snapshot, its timer generation, delivery counters, terminal outcomes, and
hard limits. `Controllers.Spammer:RequestClearDraft()` is the single clear
action used by both the Spammer window and Config: it clears and invalidates the
loaded draft UI without stopping or mutating an active run. A later start reads
the cleared canonical draft.

`Services.Warnings.Store` owns normalized `RMA_Warnings` records, duplicate-name
policy, stock templates, previews, and atomic save/delete/clear publication.
Selected warning IDs remain stable across edits; every unchanged row preserves
its table identity, while the edited row alone is atomically replaced.
`Controllers.Warnings` owns frame state and reports only the terminal result
returned by `Services.Chat`; it does not infer delivery success from the
attempted channel.

`Services.Chat` composes chat policy and exposes delivery results.
`Modules.Comms.SendChat` validates the live destination immediately before the
WoW API effect and returns success or a terminal reason. These are internal
owner contracts; they do not add a supported `_G.RMA` API or change addon-message
wire formats.

## Database Synchronization

`Database/DBSyncer.lua` owns generic raid-history synchronization: authorization,
request state, chunk lifecycle, payload import/export coordination, persistence,
and metrics. `Modules/Comms.lua` owns transport selection, queueing, and the
version protocol. `Init.lua` routes inbound addon messages in this order:

Incoming `PUSH` snapshots fail closed before chunk-state allocation. The sender
must resolve uniquely to a current realm-qualified raid roster identity,
must currently be the raid leader or an assistant, and must match either the
target of a live correlated history request or Logger's configured Require
Database player. The configured Push Database player is the default outbound
PUSH target. These consent checks preserve the existing wire format.

History snapshots are accepted only when their revision is newer than the
destination history. Legacy v1 snapshots without a revision may initialize an
empty local history, but cannot overwrite a history whose revision is already
positive. A v2 loot delta is accepted only when `sinceRevision` equals the
local revision and its dense row sequence represents every consecutive
revision through the advertised terminal revision. The raid store assigns one
new revision per loot-row mutation, so repeated revisions, holes, empty
advances, and a missing terminal row are invalid rather than batch semantics.

Requests are locally correlated by request ID, realm-qualified sender, raid,
mode, creation time, and terminal state. IDs cannot be reused while pending,
assembled, consented, outbound, or retained as terminal history. Completion,
failure, cancellation, and timeout deliver at most once and release matching
assembly/consent state. Request state expires after 30 seconds; incomplete
assemblies and outbound PUSH tracking expire after 45 seconds.

Transport is bounded at 220 encoded bytes per chunk, 256 chunks/56,320 encoded
bytes per payload, 64 concurrent incoming assemblies globally and eight per
sender, and 64 bytes per request ID. Parsed payloads are capped at 65,536 bytes,
4,096 rows, 4,096 bytes per encoded field, and 50 rows per delta. Inbound
requests are limited to six per sender per 30 seconds and outbound replies to
four per target per 30 seconds. Compressed `D1:` input is rejected before
inflate because the vendored codec has no bounded-output API; current requests
advertise no compression support and outbound payload fields remain unchanged.

Snapshot and delta imports are detached until a store-owned commit. Commit
postcondition failure restores the canonical raid (or insertion state), its
revision, counters, and runtime indexes; data/UI notifications occur only after
success. When retained per-row revisions cannot prove a dense delta interval,
the responder falls back to a snapshot instead of emitting an ambiguous delta.

1. version protocol;
2. reserve-specific sync;
3. loot distribution session;
4. database sync.

The next guardrail must catalog every prefix with its owner, accepted message
types, protocol version, authorization requirement, and payload size/chunking
policy. It must not alter existing wire payloads as part of the architecture
refactor.

| Prefix | Owner | Compatibility rule |
|---|---|---|
| `RMAVersion` | `Modules/Comms.lua` | Version request and response protocol. |
| `RMAResSync` | `Services/Reserves/Sync.lua` | Requests are accepted from current group members; metadata and data responses require the remote master looter, group leader, or raid assistant. Issued requests expire and are capped at 32; transfer assemblies are capped at 16 globally and 4 per sender. Authorization uses the realm-qualified sender identity. |
| `RMADist` | `Services/Loot/DistributionSession.lua` | Active loot-distribution mutations require the current master looter; snapshot requests are limited to current group members. All ordered state and snapshot responses use one `NORMAL` priority per destination; only out-of-band `HELLO` and `SNAP_REQ` use `ALERT`. A verified session owner may close its established stream after a loot-method transition. |
| `RMARaidSync` | `Database/DBSyncer.lua` | Live raid replication and bounded recovery, including chunked range and snapshot payloads. |

`RMA-RollWinner` was retired after confirming that RMA had no receiver for it,
no repository consumer depended on it, and its unversioned player-name-only
payload could not identify an item or roll session. Winner selection remains
local to the authoritative Master Loot workflow; completed distribution state
continues to use the owned `RMADist` protocol.

## Refactor Gate

Before extracting Master Loot code, each proposed move must state:

1. the single durable owner;
2. the exact callers and returned payload shape;
3. whether it is a command, query, or notification;
4. whether SavedVariables, addon messages, XML frame identities, or slash
   behavior are affected; and
5. the static test plus the manual WotLK smoke scenario that proves it.
