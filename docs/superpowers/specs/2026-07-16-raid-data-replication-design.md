# Raid Data Replication Design

Date: 2026-07-16
Status: Approved

## Problem

Raid Management Addon needs reliable and efficient synchronization of active
raid data between addon users, plus consent-gated sharing of completed raid
history. The design must tolerate missed addon messages, reloads, late joins,
Master Looter changes, partial transfers, and malformed input without exposing
partially imported SavedVariables.

The current beta storage and wire contracts are not compatibility constraints.
The existing contents of `RMA_Raids` may be discarded when the new format is
first loaded. Public RMA branding, the `RMA_Raids` SavedVariable name, WotLK
3.3.5a support, Interface 30300, Lua 5.1, and the `/rma` entrypoint remain
stable.

## Goals

- Synchronize the active raid automatically from one authoritative writer.
- Use small live updates during normal operation.
- Repair missed updates through range recovery or a full snapshot.
- Preserve synchronization position across `/reload`.
- Transfer completed raids only after explicit recipient consent.
- Keep imports atomic and fail closed on conflicts or invalid data.
- Keep runtime and persistence contracts simple enough for WoW 3.3.5a.

## Non-goals

- Peer-to-peer merging of raid databases.
- Automatic synchronization of complete raid history.
- A permanent global event ledger.
- Conflict-free replicated data types or distributed consensus.
- Per-chunk acknowledgements.
- Migration or backup of the previous beta `RMA_Raids` contents.
- A configurable selection of synchronization strategies.

## Reference Models

The design combines established behaviors rather than copying one addon:

- Core Loot Manager uses an immutable event ledger, automatic synchronization,
  access control, and state reconstruction. RMA adopts ordered authoritative
  events, but scopes the ledger to the active raid and compacts it.
- Gargul gives loot entries stable checksums and broadcasts explicit add, edit,
  and delete actions. RMA adopts stable entity identity and small semantic
  operations.
- RCLootCouncil uses a request, consent, compressed bulk transfer, and terminal
  acknowledgement for history synchronization. RMA adopts consent and snapshot
  transfer for completed raids.

Primary references:

- https://github.com/CoreLootManager/CoreLootManager/blob/master/ARCHITECTURE.md
- https://github.com/papa-smurf/Gargul/blob/master/Classes/AwardedLoot.lua
- https://github.com/evil-morfar/RCLootCouncil2/blob/develop/Modules/Sync.lua

## Architecture

RMA uses primary-replica synchronization. The current Master Looter is the only
writer for the active raid. Other clients are replicas. A replica never merges
an independently edited copy into the authoritative active raid.

The active raid stores both materialized state and a bounded ordered event log.
Events provide efficient live replication and short-gap recovery. Snapshots
provide bootstrap, checkpoint recovery, and repair after incompatibility.

Completed raids are immutable snapshots. Their active event logs are discarded
after compaction and are not transferred with raid history.

## Persistent Store

`RMA_Raids` becomes a versioned archive:

```lua
RMA_Raids = {
    formatVersion = 1,
    activeRaidUid = nil,
    raids = {
        [raidUid] = {
            status = "active",
            authorityEpoch = 1,
            sequence = 1,
            digest = "89abcdef:2048",
            state = {
                realm = "Realm",
                zone = "Icecrown Citadel",
                size = 25,
                difficulty = 4,
                startTime = 0,
                endTime = nil,
                players = {},
                bossKills = {},
                attendance = {},
                loot = {},
            },
            checkpointSequence = 0,
            events = {
                {
                    eventType = "RAID_CREATED",
                    sequence = 1,
                    resultDigest = "89abcdef:2048",
                },
            },
        },
    },
}
```

The store uses the `raids` map key plus its position in `order` as the local
Loot History row identity. The source `raidUid` remains the replication and wire
identity and may therefore differ from a local conflict-variant archive key.
History selection, export, sharing, and deletion resolve the clicked row through
its numeric `order` index and archive key; `raidNid` is replicated display/domain
data, not a unique history-row key.

`state` keeps the canonical raid document fields at its root. This preserves a
simple read contract for existing feature services while the archive record
owns replication metadata. RMA does not persist a second flattened projection,
an adapter copy, or aliases for these fields.

`raidUid` is an opaque ASCII value of at most 40 bytes. The authority generates
it when creating a raid from creator identity, server time, a monotonic local
counter, and a session nonce, then verifies that it does not already exist in
the local archive. Consumers compare it as an exact string and do not parse its
parts. It remains unchanged across all replicas and historical shares.

`sequence` is the raid revision. A separate duplicate revision counter is not
stored. `authorityEpoch` identifies the current writer generation. Canonical
state encoding sorts map keys, preserves array order, uses explicit type tags,
and length-prefixes strings so separate clients produce the same bytes. The
`digest` is `<adler32-hex>:<canonical-byte-count>`, calculated with the bundled
LibDeflate Adler-32 implementation. It detects transfer corruption and state
divergence; it is not an authentication mechanism. Local UI state and derived
indexes are excluded from the canonical bytes.

Derived raid indexes live only in a private `DBRaidStore` weak-key cache keyed
by the canonical state table. They are never attached to a state, record,
snapshot, event, or SavedVariables value. Admission rejects private keys
recursively instead of filtering them during digesting or transfer, so malformed
persisted and remote inputs fail closed.

Player, boss, and loot entries use stable identifiers assigned by the
authority. Runtime query indexes and sorted UI views are derived from the
persisted maps.

When `RMA_Raids.formatVersion` is absent or unsupported, RMA replaces
`RMA_Raids` with an empty format-version-1 archive. No beta migration or backup
is performed.

A supported format-version-1 archive is validated in its persisted shape before
normalization or runtime-index rebuilding. Invalid order, provenance, digest,
record, or active-pointer data is quarantined in place: the raw `RMA_Raids`
table remains unchanged, save and mutation paths fail closed, and diagnostics
expose the validation reason. Recovery never silently normalizes or resets a
supported but invalid archive and introduces no additional SavedVariable.

## Event Model

Each active-raid event contains:

```text
raidUid
authorityEpoch
sequence
eventUid
eventType
payload
resultDigest
```

`eventUid` is deterministic from `raidUid`, `authorityEpoch`, and `sequence`.
It makes duplicate delivery idempotent.

The initial semantic event vocabulary is limited to:

- raid created;
- raid metadata updated;
- player added or updated;
- player departed;
- boss recorded or updated;
- attendance updated;
- loot added or updated;
- loot deleted;
- raid concluded.

Generic table-path patches are forbidden. Each event has an explicit schema and
reducer.

For each local authoritative mutation, the store copies the raid candidate,
applies the event, validates the complete result, calculates the digest, appends
the event, and atomically replaces the persisted raid record. State cannot
advance without its event, and an event cannot be committed without its state.

## Checkpoint And Compaction

The persisted active log retains at most 512 events after the most recent
checkpoint. At the limit, current materialized state becomes the new checkpoint,
`checkpointSequence` advances to the current sequence, and earlier events are
discarded. A client older than the checkpoint must recover through a snapshot.

When a raid concludes, its final state, epoch, sequence, and digest remain. The
event log is emptied and the raid becomes immutable. Historical sharing sends
only this canonical snapshot.

## Wire Protocol

The replacement wire protocol is version 3. Every envelope carries
`protocolVersion = 3`; receivers reject every other version before decoding its
message body. Version 3 is intentionally incompatible with the previous beta
protocol, whose payloads cannot mutate the new store.

Message kinds:

- `HEAD`: raid UID, epoch, sequence, checkpoint, digest, and status;
- `EVENT`: one authoritative semantic operation;
- `RANGE_REQ`: request for a missing contiguous event range;
- `RANGE_DATA`: encoded and chunked response containing ordered events;
- `SNAP_REQ`: request for a complete raid snapshot;
- `SNAP_DATA`: encoded and chunked snapshot response;
- `OFFER`: bounded summary of a completed raid offered to one recipient;
- `RESULT`: terminal outcome after a correlated import.

Live `EVENT` messages are broadcast once to the current party or raid. Range,
snapshot, offer, and result traffic uses targeted whispers where appropriate.
Every payload stays within the WotLK addon-message limit. Large range and
snapshot data is encoded for the addon channel, chunked, queued, and throttled.
Transfer bodies are never Deflate-compressed because the bundled LibDeflate
decompressor cannot cap output allocation before inflate. Hard encoded and
decoded limits are enforced before structured body parsing.

There is no acknowledgement for every event or chunk. Completion is inferred
from validated assembly and expressed by one terminal `RESULT` when a
user-visible historical transfer completes.

## Live Replication

The Master Looter commits an event locally before broadcasting it. A replica
accepts it only when:

- the real WoW addon-message sender is the current authority;
- raid UID and authority epoch match;
- the event sequence is exactly the next expected sequence;
- event type and payload validate;
- applying the event to a candidate succeeds; and
- the resulting digest equals the transmitted digest.

A duplicate committed `eventUid` is a no-op. A future sequence creates a gap;
the replica requests the missing range by whisper. If the range predates the
checkpoint, cannot be assembled, or fails validation, the replica requests a
snapshot. A snapshot replaces local synchronized state only after complete
validation and atomic commit.

There is no periodic full-database polling. On load, reload, roster change, or
late join, the authority advertises `HEAD`. Matching UID, epoch, sequence, and
digest require no transfer. A short gap uses range recovery; an unknown or
incompatible state uses a snapshot.

## Authority Handover

When the game selects a new Master Looter, messages from the previous authority
are immediately rejected. The new Master enters a handover state, gathers peer
heads, prefers the previous authority when available, and otherwise selects the
valid state with the highest sequence. It recovers a range or snapshot before
publishing a new epoch.

Syncable local changes produced during the brief handover are staged in bounded
runtime memory. After the base state is established, the new authority increments
`authorityEpoch`, assigns new sequences, commits the staged events, and
broadcasts them. The physical in-game loot award is not blocked by handover.

If two candidates report the same raid UID, epoch, and sequence with different
digests, automatic synchronization is suspended. RMA does not merge or select a
winner. It preserves local data, exposes a clear conflict state, and requires an
explicit recovery source.

If no peer answers, the new Master may continue from its own valid local replica.

## Historical Sharing

Any current group member may offer a completed raid to another current group
member. `OFFER` contains only its opaque offer ID, intended recipient, UID,
authority epoch, sequence, digest, and a short display summary. The epoch is
summary metadata required to correlate the later bounded snapshot session; no
raid history is sent before consent.

Acceptance causes the recipient to request a complete snapshot from the offer
sender. After atomic import, the recipient returns `RESULT` and both clients show
the outcome.

Historical import rules:

- unknown `raidUid`: import the snapshot;
- known UID with the same digest: report already present and do nothing;
- known source UID with a different digest: preserve both completed snapshots,
  report a conflict, select the new Loot History row, and show a warning;
- reimporting either source-UID/digest pair creates no third copy.

The first imported snapshot may retain its source UID as the archive key. A
divergent variant uses a deterministic bounded local archive key and persists
`sourceRaidUid` plus `conflictOfRaidUid`. These are restore-critical provenance
fields inside the existing format-v1 `RMA_Raids.raids` records; no new
SavedVariable or top-level schema is introduced. `archive.order` includes both
rows, while the derived runtime `raidNid` index excludes conflict variants so a
remote duplicate NID cannot replace the canonical runtime lookup. Snapshots and
offers expose the canonical source as `raidUid` and strip both provenance
fields; remote provenance is discarded before validation and rebuilt only after
import. The final locally annotated candidate is revalidated before its single
archive assignment. Reload validates and preserves both rows, while all runtime
indexes are rebuilt.

Offers, requests, assemblies, and results expire from runtime memory and never
enter SavedVariables. The recipient's incoming consent/UI offer lasts exactly
30 seconds, so `AcceptHistoricalOffer` fails after that window. Independently,
the sender retains the outgoing offer correlation for 65 seconds; this is not a
longer UI consent window, but enough grace to recognize the Session retry when
the first SNAP_REQ is lost and the 30-second timer fires with scheduling jitter.
Expiration is fail-closed at the boundary (`expiresAt <= now`), so the receiver
cannot accept at exactly 30 seconds.
Once the request arrives, both peers use the same 65-second accepted lifetime.
`DECLINED` is valid only for the offer ID while offered; import outcomes and
`FAILED` are valid only for the exact accepted request ID. Invalid
state/outcome/ID combinations are ignored without changing visible feedback.
Both peers receive localized visible feedback for every terminal outcome.

## Security And Bounds

- Sender identity comes from the WoW event, never from a payload field.
- Live events are accepted only from the current Master Looter.
- Offers and targeted history requests require current group membership at send
  and acceptance time.
- Offer display text permits UTF-8/high bytes but rejects C0 controls, DEL, and
  WoW `|` markup before it reaches popup formatting.
- Old authority epochs are rejected.
- Message size, field count, entity count, chunk count, range length, and
  concurrent assemblies are bounded before expensive allocation.
- Incoming request and outgoing target rates are bounded.
- Partial, timed-out, malformed, or conflicting data never mutates the store.
- A timed-out correlated transfer receives at most one targeted retry.
- Runtime staging and assembly tables have fixed capacity and expiry.

## User Feedback And Diagnostics

Normal users see only these states:

- synchronized;
- recovering data;
- changing Master Looter;
- transferring historical raid;
- synchronization suspended; or
- a concrete terminal failure.

Request IDs, epoch, sequence, digest, chunk, retry, rate-limit, and import details
are emitted only when debug diagnostics are enabled.

## Component Ownership

- `DBRaidStore.lua`: SavedVariables, materialized state, atomic commits,
  checkpointing, compaction, and snapshot replacement.
- `DBRaidEvents.lua`: semantic event schemas, deterministic reducers, canonical
  digest input, and event validation.
- `DBSyncProtocol.lua`: wire encoding and decoding for the defined message kinds.
- `DBSyncSession.lua`: request IDs, missing ranges, channel-safe encoding,
  chunk assembly, timeout, rate limiting, capacity, and one retry.
- `DBSyncer.lua`: authority policy, handover, live orchestration, history offers,
  and user-facing outcomes.
- `DBRaidQueries.lua`: read-only domain queries and UI projections.
- `DBRaidValidator.lua`: complete canonical raid validation.

The old migration owner, overlapping `PUSH`/`REQ`/`SYNC` modes, duplicate import
commit paths, and unconsumed wrappers or metric layers are removed. No module is
created per message kind.

## Automated Verification

Tests must simulate independent clients and cover:

- deterministic UID and event identity contracts;
- identical reducers and digests on separate replicas;
- idempotent duplicate delivery;
- rejected out-of-order, wrong-authority, old-epoch, malformed, and oversized
  events;
- atomic commit and rollback;
- checkpoint creation and snapshot fallback;
- contiguous range recovery;
- reload without loss of epoch, sequence, digest, or event range;
- late join with matching head, recoverable gap, and snapshot bootstrap;
- bounded assembly, expiration, and one retry;
- authority handover and replay of staged events;
- same-sequence digest conflict suspension;
- history offer acceptance, decline, expiry, duplicate import, and conflict;
- reset of an unsupported beta store;
- wire-size compliance and Lua 5.1 behavior.

Run the complete Python/Lua suite, TOC validation, Lua 5.1 validation, `xpcall`
scan, XML handler scan, StyLua, Luacheck, and `git diff --check`.

## In-Game Smoke Gate

With two compatible WotLK 3.3.5a clients:

1. A becomes Master Looter and creates the raid.
2. A records boss and loot data; B receives it without opening RMA windows.
3. B reloads and recovers only missing state.
4. A late-joining client recovers by range or snapshot.
5. Master Looter changes from A to B; B completes handover.
6. B records new loot; A converges on the new epoch.
7. The raid concludes and its event log compacts.
8. While B is offline or reset, A creates and completes a second raid; verify
   that second raid's source UID is absent from B before any offer.
9. A offers that second completed raid to B; decline changes no data.
10. B accepts a new offer and the raid appears in Loot History.
11. Reoffering the same UID and digest reports already present and creates no duplicate.
12. A valid divergent digest preserves both rows with a warning; a partial
    transfer or invalid digest leaves SavedVariables unchanged.
13. Reload preserves completed raids but no offers or transfer sessions.

No integration into `codex/loot-bans-optimization` is allowed until this smoke
test is positive.

## Behavior Deltas

- Old behavior: beta `RMA_Raids` records are normalized and migrated in place.
  New behavior: unsupported beta storage is reset to the new empty archive.
  Reason: explicitly authorized clean beta baseline. Compatibility impact:
  destructive to beta raid history. Migration impact: none by design.
- Old behavior: live synchronization uses overlapping request, push, revision,
  delta, and snapshot paths. New behavior: one authoritative active-raid event
  stream with range and snapshot recovery. Reason: deterministic ownership and
  fewer overlapping state machines.
- Old behavior: historical push may depend on configured pre-consent. New
  behavior: completed raids always require an explicit targeted offer and
  recipient acceptance.
- Old behavior: runtime-only revision metadata returns to zero after reload.
  New behavior: epoch, sequence, digest, checkpoint, and active events are
  canonical persisted fields.

## Acceptance Criteria

- The active raid has one authoritative writer and deterministic replicas.
- Normal live updates use bounded semantic events, not full database transfer.
- Missing events recover by range and fall back safely to a snapshot.
- Reload and late join preserve or recover synchronization position.
- Master Looter handover cannot accept writes from the previous authority.
- Completed raids are immutable snapshots shared only after consent.
- Same UID and digest is idempotent; same UID with different digest is rejected.
- Invalid or incomplete input cannot partially mutate `RMA_Raids`.
- The active ledger is bounded and removed when the raid concludes.
- No global event ledger, peer merge, per-chunk acknowledgement, or alternative
  strategy framework is introduced.
- Runtime remains Lua 5.1 and WotLK 3.3.5a compatible.
- Integration remains blocked until the multi-client in-game smoke is positive.
