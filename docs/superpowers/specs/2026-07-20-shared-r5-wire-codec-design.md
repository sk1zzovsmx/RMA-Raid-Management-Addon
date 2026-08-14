# Shared R5 Wire Codec Design

## Objective

Replace RMA-owned serialization, delimiter parsing, Base64 transport encoding,
and outbound chat throttling with the libraries vendored by commit `3e68f57`.
All RMA addon-message protocols move together to a clean version 5 wire format.
The addon is still in alpha, so version 4 and older wire formats are rejected
without a compatibility decoder.

This change improves maintainability and runtime safety by making one shared
codec responsible for binary-safe wire encoding and by making
ChatThrottleLib the sole outbound traffic scheduler.

## Scope

The migration covers these RMA addon-message prefixes:

- `RMARaidSync`
- `RMAResSync`
- `RMADist`
- `RMAVersion`

The prefixes remain stable. Their message representation changes to R5.

The change does not alter SavedVariables, persistence schemas, raid authority
rules, application-level rate limits, or user-facing workflows. Final review
approved one explicit reserves-only exception to the original transfer-policy
scope: `RMAResSync` now accepts `META_ACK` only for a locally issued request,
binds the first valid response source, expires requests after 180 seconds, caps
pending requests at 32, and caps incomplete assemblies at 16 globally and 4 per
sender. No other protocol's transfer admission or request-correlation policy is
changed by this migration.

`Modules/Json.lua` remains available only for external reserves JSON imports.
It is no longer a sync protocol dependency. `Modules/Base64.lua` is removed if
the completed migration leaves it without runtime consumers.

Vendored files under `Libs/` are not modified.

## Shared Wire Codec

`addon.Comms.Payload` remains the stable integration boundary between RMA code
and the vendored libraries. It exposes two operations:

- `Payload.Serialize(value)` serializes a Lua value through `LibSerialize` and
  makes the resulting bytes safe for the WoW addon channel through
  `LibDeflate:EncodeForWoWAddonChannel`.
- `Payload.Deserialize(text)` decodes the addon-channel representation and
  deserializes it through `LibSerialize`.

Both operations validate input and dependency results. Recoverable failures
return `nil, reason`; malformed or unsupported input must not escape as a Lua
error. Callers continue to validate their protocol-specific bodies after
deserialization.

The shared codec does not own compression, chunking, request state, message
schemas, or feature policy. It only owns the serialization-library boundary
and WoW-channel-safe representation.

The following custom payload APIs are removed after their callers migrate:

- `Payload.EncodeText`
- `Payload.DecodeText`
- `Payload.PackFields`
- `Payload.SplitFields`

## R5 Envelope

Every top-level RMA message is a serialized table with these positional fields:

1. protocol version: integer `5`
2. message kind: non-empty string
3. request or correlation identifier, or `false` when unused
4. target name, or `false` when unused
5. protocol-specific body table

Positional fields keep overhead bounded while `false` preserves dense-array
semantics without a JSON-specific null sentinel. Each protocol validates the
exact field count, version, kind, identifiers, target, and body before acting.

`RMARaidSync` changes its marker from `R4` to the numeric R5 envelope and uses
`LibSerialize` values directly. The compact live-loot representation may keep
its validated positional data shape, but it no longer uses custom JSON output
or `addon.Json.NULL`; optional positions use `false`.

`RMAResSync`, `RMADist`, and `RMAVersion` replace delimiter-separated commands
and Base64-escaped fields with the same R5 envelope. Their existing semantic
message kinds and validation rules remain owned by their feature modules.

No R4 or older decoder is retained. Messages with a different version fail
closed as unsupported protocol traffic.

## Transfer And Chunking Flow

Protocol owners retain their current bounded transfer responsibilities:

1. Build and validate the feature-specific body.
2. Serialize the logical transfer payload with the shared codec.
3. Split oversized encoded text into bounded chunks.
4. Wrap each chunk in an R5 protocol envelope.
5. Enqueue all chunks with one stable ChatThrottleLib queue name.
6. On receipt, validate metadata and bounds before allocating assembly state.
7. Reassemble encoded text, deserialize once, and validate the reconstructed
   feature object before applying it.

Existing caps on message bytes, part counts, total encoded bytes, decoded
structure, request lifetime, sender concurrency, and application-level rates
remain binding. Reserves metadata requests are locally issued and correlated,
expire after 180 seconds, and are capped at 32; reserves transfer assemblies
are admitted only up to 16 globally and 4 per sender. Chunk sizes are
recalculated against actual R5 serialized envelopes so every outbound addon
message stays within the WotLK client limit.

## ChatThrottleLib Integration

`Modules/Comms.lua` validates destinations and remains the single RMA transport
facade, but it no longer owns a timer, queue array, queue indices, burst size,
or pacing interval.

All addon traffic uses `ChatThrottleLib:SendAddonMessage`. All ordinary chat
traffic uses `ChatThrottleLib:SendChatMessage`. Direct Blizzard send functions
are not called by RMA runtime code outside the vendored library.

The facade accepts transport policy from callers while providing conservative
defaults:

- `ALERT`: small request/response control traffic and version messages.
- `NORMAL`: live raid and loot events where latency affects active play.
- `BULK`: independently correlated historical ranges, reserve datasets, and
  other chunked transfers with an application-level completion boundary.

Messages belonging to one ordered flow use a stable queue name derived from
the RMA protocol and normalized destination. A stable name orders messages only
inside one ChatThrottleLib priority queue, so a causal state flow must also use
one priority. In particular, every `RMADist` state mutation and snapshot
response uses `NORMAL`; only the out-of-band `HELLO` and `SNAP_REQ` messages use
`ALERT`. `RMADist` does not use `BULK`. This prevents priority scheduling from
overtaking state while still isolating unrelated destinations.

The public RMA helpers may retain names such as `QueueAddonMessage`,
`QueueAddonMessages`, and `SendAddonBatch` to avoid unrelated caller churn,
but they become validation and policy adapters only. They must not implement a
second queue, scheduler, or backpressure model. Batch preflight validates every
entry before the first call into ChatThrottleLib. Transport options fail closed
unless they are `nil` or a table, and an explicit queue name must be a non-empty
string.

## Error Handling

The migration remains fail-closed:

- Missing library dependencies fail during module initialization with a clear
  assertion.
- Serialization errors, decoding errors, unsupported versions, malformed
  envelopes, invalid bodies, oversized payloads, conflicting chunks, and
  unknown requests return existing protocol-level failure reasons where
  possible.
- A malformed message never allocates unbounded assembly state or reaches
  persistence.
- One rejected message does not stop unrelated ChatThrottleLib queues.

ChatThrottleLib acceptance indicates that traffic was handed to the shared
throttler; it does not provide delivery acknowledgement. Existing higher-level
request timeouts and retry policies remain responsible for delivery failure.

## Tests And Validation

Implementation follows test-first changes. Tests protect behavior rather than
the removed custom implementation.

Required automated coverage:

- Shared codec round-trips nested tables, strings, booleans, numbers, and
  optional `false` slots.
- Shared codec rejects malformed addon-channel text and invalid serialized
  data without throwing.
- Each prefix accepts valid R5 messages and rejects other versions.
- Raid live events, range transfers, snapshots, reserves transfers, loot
  distribution snapshots, and version exchange preserve their current
  user-visible behavior through the R5 codec.
- Independently correlated raid/reserves chunk flows stay ordered through
  stable queue names and use `BULK` where their completion boundary makes
  cross-priority delivery safe.
- Every ordered `RMADist` state message, including snapshot responses, uses
  `NORMAL`; only `HELLO` and `SNAP_REQ` use `ALERT`.
- Reserves rejects unsolicited metadata acknowledgements, binds the first valid
  source, expires requests, and enforces 32 pending / 16 global assembly / 4
  per-sender assembly caps before allocation.
- `RMAVersion` requests and acknowledgements both use `ALERT`.
- Invalid scalar transport options and invalid queue names enqueue nothing.
- Batch validation prevents a malformed entry from causing a partial enqueue.
- RMA runtime code contains no custom Comms queue state and no direct calls to
  Blizzard send functions.
- `Modules/Base64.lua` and its TOC entry are removed only if no runtime consumer
  remains.
- `Modules/Json.lua` remains reachable by reserves import and is absent from
  sync protocol dependencies.

Final verification includes the focused Python/Lua behavior tests, the full
relevant test suite, `tools/check-rma.ps1`, TOC validation, Lua 5.1 validation,
the Lua 5.1 `xpcall` scan, XML handler scan, stale-branding scan,
`stylua --check`, `luacheck`, and `git diff --check`. An in-game WotLK 3.3.5a
smoke test remains required to prove actual network behavior.

## Behavior Delta

- Old behavior: four RMA protocols used multiple custom delimiter, Base64, and
  JSON representations; Comms owned a fixed 100 ms single-message queue.
- New behavior: all four protocols use one LibSerialize-based R5 codec and all
  outbound traffic is scheduled by ChatThrottleLib with explicit priorities
  and ordered flow names.
- Reason: remove duplicate protocol infrastructure, share throttling with other
  addons, and use the libraries already vendored for these responsibilities.
- Classification: the old implementation is obsolete after the libraries are
  introduced; its duplicated throttling also cannot coordinate globally with
  other addons.
- Compatibility impact: clients running R4 or older cannot exchange RMA
  protocol messages with R5 clients. Prefix names remain unchanged.
- Migration impact: none for SavedVariables or persisted raid data.
- Proof: automated R5 round-trip, rejection, priority, ordering, chunking, and
  existing workflow behavior tests plus an in-game two-client smoke test.

Final review corrected one ordering assumption: ChatThrottleLib queue names do
not order traffic across its priority classes. Earlier `RMADist` classifications
placed `CLEAR`/`SESSION_END`/single snapshots on `ALERT` and snapshot chunks on
`BULK`, allowing them to overtake `NORMAL` state mutations. The final contract
uses `NORMAL` for the complete ordered distribution flow and reserves `ALERT`
only for `HELLO`/`SNAP_REQ`. This is an internal scheduling correction with no
wire, SavedVariables, or migration impact.

## Runtime Smoke Checks

Use two WotLK 3.3.5a clients running the same R5 build:

1. Login and reload without Lua errors.
2. Confirm `/rma` and normal addon windows still open.
3. Exchange version information.
4. Replicate a live loot event.
5. Complete a range or snapshot recovery.
6. Share reserves data.
7. Run an active loot distribution flow.
8. Confirm bulk transfers do not disconnect either client and do not block a
   live control message to a different peer.
9. Confirm `/reload` preserves all expected `RMA_*` SavedVariables.
