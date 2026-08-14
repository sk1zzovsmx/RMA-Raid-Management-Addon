# Live Loot Synchronization Design

Date: 2026-07-19
Status: Approved in conversation; awaiting written-spec review
Branch: `codex/live-loot-sync-reliability`

## Problem

Normal `LOOT_ADDED` events exceed the 243-byte WotLK addon-message limit. The
authority therefore broadcasts only a `HEAD`, after which every replica opens a
targeted `RANGE_REQ` and receives `RANGE_DATA`. Rapid loot creates newer heads
while a recovery is in flight. The current recovery admission logic cancels and
replaces the older request, but cancellation does not refund its rate-limit
slot and already queued response chunks still consume the global communications
queue. Four operations toward one peer in thirty seconds exhaust the session
budget. The newest head is not retained for automatic retry, so the last loot
can remain absent until a later event starts another recovery.

The live path also transfers a verbose JSON representation of a complete loot
event even though several event and display fields are deterministic from
smaller canonical facts already available on every updated RMA client.

## Compatibility Decision

All raid participants are required to update to the new RMA release. The live
raid wire protocol will advance from version 3 (`R3`) to version 4 (`R4`), and
version-3 messages will be rejected as unsupported. No mixed-version fallback,
dual broadcast, negotiation layer, or legacy decoder will be added.

This is a wire-format change only. Existing `RMA_*` SavedVariables, archive
format, active raid records, event reducers, stable entity identifiers, and
canonical digest rules remain compatible. The implementation must not reset,
migrate, or rewrite valid saved raid history merely because the wire version
changes.

## Goals

- Populate every aligned replica's Loot History from one immediate group
  broadcast per normal loot event.
- Send only the compact facts required to reconstruct the existing canonical
  `LOOT_ADDED` event exactly.
- Preserve authority, sequence, epoch, event validation, atomic application,
  and digest verification.
- Detect a lost final live event without waiting for another loot award.
- Keep an in-flight recovery alive while coalescing newer remote positions into
  one catch-up request.
- Retry the latest known live position automatically after temporary queue or
  rate admission failure.
- Prevent completed-history traffic from consuming the live-recovery rate
  budget.
- Keep all traffic bounded and compatible with WotLK 3.3.5a and Lua 5.1.

## Non-goals

- Broadcasting complete raid snapshots to the group.
- Peer-to-peer state merging or multiple writers.
- Per-recipient acknowledgement of every live loot event.
- Removing range or snapshot recovery.
- Changing the SavedVariables schema or canonical raid event vocabulary.
- Deriving canonical values from locale-dependent or asynchronously cached item
  data when that could produce different state on two clients.
- Adding configurable synchronization strategies or user-facing tuning knobs.
- Optimizing unrelated event types unless their existing `EVENT` encoding
  already fits the wire limit.

## Authority And Broadcast Model

The current raid leader remains the only authoritative writer. A live loot
broadcast is sent once to the active group and may be consumed independently by
every RMA replica. Broadcasting does not grant write authority to recipients.

A replica accepts a live loot message only when all of these conditions hold:

- the actual WoW addon-message sender is the currently recognized authority;
- the raid UID and authority epoch match the active replicated stream;
- the event sequence is exactly the replica's next expected sequence;
- the compact payload decodes into a valid `LOOT_ADDED` event;
- applying that event to a detached candidate succeeds; and
- the resulting canonical digest equals the transmitted result digest.

An already-applied position is idempotent. A future position proves a gap and
enters targeted recovery. A same-position digest mismatch suspends
synchronization. Messages from non-authorities, old epochs, other raids, or
malformed bodies fail closed without mutating the store.

## Protocol Version 4

Version 4 retains the existing bounded message families for heads, ranges,
snapshots, historical offers, and results. It adds a compact live-loot body and
uses an `R4` envelope marker for every message kind.

The normal live-loot message contains these event facts:

1. `raidUid`
2. `authorityEpoch`
3. `sequence`
4. `resultDigest`
5. `lootNid`
6. `itemLink`
7. `itemCount`
8. `looterNid`
9. `rollType`
10. `rollValue`
11. `rollSessionId`
12. `bossNid`
13. `time`
14. `source`
15. `itemTexture`
16. `lootSource`, only when present and not reproducible from the synchronized
    raid state

The body is a dense positional JSON array. Optional values use the JSON null
token; positional omission is forbidden. JSON string escaping supplies the
channel-safe representation without Base64 expansion. Numbers use conservative
protocol-only integer and finite-number bounds; the canonical persistence
validator is not tightened by this wire change. The compact body does not use
JSON field names and does not use Deflate compression. The complete encoded
addon message must remain at or below 243 bytes.

When `lootSource` is present it uses a nested positional tuple containing its
known scalar fields plus positional candidate tuples. Unknown keys or values
that cannot be represented exactly make the event non-reconstructible and
force head recovery. A named JSON `lootSource` object is not permitted.

The decoder reconstructs these values rather than transmitting them:

- `eventUid` from raid UID, epoch, and sequence;
- `eventType` as `LOOT_ADDED`;
- `itemId` and `itemString` from `itemLink`;
- `itemName` and `itemRarity` from the transmitted hyperlink only when the
  derived values exactly match the authority's canonical row;
- distribution counters and `nextLootNid` through the existing reducer.

Player and boss display names are not fields of the canonical loot event. The
Loot History read projection continues resolving them from `looterNid` and
`bossNid` after the event has been applied.

The authority uses the compact path only if decoding its own encoded message
reconstructs an event canonically equal to the event it just committed. Any
non-reconstructible field is carried explicitly when the compact schema allows
it. If exact reconstruction or the 243-byte bound cannot be proven, the
authority does not send a partial live event; it uses the coalesced `HEAD`
recovery path.

This self-check keeps the canonical store and digest algorithm unchanged while
removing redundant wire fields from the common case.

## Normal Live Data Flow

For a normal reconstructible loot event:

1. The authority commits the canonical event locally.
2. The version-4 codec builds and self-validates one compact live-loot message.
3. The authority queues one group broadcast.
4. Every aligned replica reconstructs and atomically applies the same canonical
   event.
5. Each successful replica emits the existing logger data-change event and
   displays the loot without opening a request session.

There is no per-recipient response in the successful path. Ten aligned addon
users consume the same one broadcast; they do not create ten range transfers.

## Consolidated Head

Every authoritative commit that leaves the raid active updates one pending head
advertisement. A trailing timer fires 0.25 seconds after the most recent active
commit and broadcasts only the newest `HEAD`. A newer active commit resets the
timer and replaces the stored head; intermediate heads are never queued.

`RAID_CONCLUDED` cancels any pending active head and retains the existing
immediate final-head publication. The active pointer no longer exists after
conclusion, so delaying that final position behind the active-raid timer would
weaken rather than improve the established conclusion recovery contract.

The consolidated head is an integrity and loss-detection signal, not the normal
loot transport. A replica already at the advertised position performs no work.
A replica that missed the final compact event discovers the gap after the
quiet-period head even when no later loot occurs.

If timer scheduling is unavailable, the authority immediately queues the newest
head so loss detection degrades safely instead of disappearing.

## Monotonic Recovery

An ordinary active-raid range or snapshot recovery is never cancelled merely
because a newer valid head for the same authority stream arrives. The recovery
retains one `followUp` position containing only the highest sequence and its
matching digest.

After the current recovery validates and commits:

- if the installed position equals the retained follow-up, synchronization is
  complete;
- if the retained position is newer and the missing events remain available,
  the replica opens exactly one catch-up range;
- if the range is unavailable, the existing snapshot fallback is used;
- if an intervening direct live event satisfies the retained position, the
  pending follow-up is cleared without another request.

Different senders, raid UIDs, authority epochs, handover flows, reentry flows,
and digest conflicts keep their current fail-closed semantics. Handover and
reentry requests are not silently coalesced with ordinary replica recovery.

## Admission Failure And Retry

The replica retains the latest valid remote head when a live request cannot be
admitted because of rate limiting or communication backpressure. It schedules
one retry for that retained target rather than entering a terminal failed state
that requires another loot event. Rate limiting uses the exact returned window
delay; backpressure uses the same 0.25-second bounded delay as the consolidated
head.

The session reports the exact delay until the oldest relevant rate timestamp
expires. A newer head replaces the retained target but does not create an
additional timer. Each retained target receives at most one automatic admission
retry. After that retry starts successfully, the retained admission state is
cleared. If the retry itself cannot be admitted, synchronization enters the
existing failed state and the next consolidated head may establish a new
bounded recovery attempt.

`TIMER_UNAVAILABLE` is a terminal infrastructure failure: the same unavailable
scheduler cannot honestly promise an automatic timer retry. It is reported
without discarding or partially applying canonical data.
Digest conflict, invalid authority, invalid metadata, and rejected canonical
data are terminal safety failures and are never automatically retried.

The existing request timeout behavior remains bounded to one resend of the same
correlated request.

## Rate Isolation

Active-raid range and snapshot operations use a dedicated live-recovery rate
class. Completed-history snapshots use the historical-transfer class. Each
outgoing class permits four operations per target per thirty-second window, and
each incoming class permits six requests per sender per thirty-second window.
A history offer or accepted historical transfer therefore cannot consume the
live raid's request budget.

Ordinary compact broadcasts and consolidated heads are fire-and-forget group
messages and do not allocate request-session rate slots. Incoming request,
assembly, chunk-count, encoded-size, decoded-size, and global queue capacity
bounds remain enforced.

## Exceptional And Late-Join Paths

- A normal compact event over 243 bytes falls back to one consolidated head.
- A replica with a short recoverable gap requests only that contiguous range.
- A replica older than the checkpoint requests a snapshot.
- A client without the active raid uses the existing head discovery and
  snapshot bootstrap.
- A completed raid continues to require the existing explicit historical offer
  and recipient consent.
- A malformed compact event never causes a best-effort partial row; it is
  rejected and later repaired from a valid head, range, or snapshot.

Range and snapshot data remains targeted by whisper and correlated to one
receiver. Only the compact event and consolidated position head are group
broadcasts.

## Component Ownership

- `Database/DBSyncProtocol.lua` owns the `R4` marker, compact live-loot codec,
  exact field bounds, reconstruction, and the 243-byte gate.
- `Database/DBSyncer.lua` owns authority checks, immediate live broadcast,
  consolidated-head scheduling, monotonic follow-up recovery, and retained
  retry targets.
- `Database/DBSyncSession.lua` owns live/history rate classes, admission retry
  delay, request correlation, transfer assembly, expiry, and bounded resend.
- `Database/DBRaidEvents.lua` remains the owner of canonical event validation,
  deterministic event identity, reducers, and digest-relevant semantics.
- `Database/DBRaidStore.lua` remains the owner of atomic authoritative commit,
  replica apply, ranges, snapshots, and SavedVariables integrity.
- `Modules/Comms.lua` retains the global bounded FIFO and 0.10-second pacing;
  this change does not globally accelerate unrelated addon traffic.

No new runtime Lua module, TOC entry, generic retry framework, compatibility
adapter, or user option is introduced.

## Automated Verification

Tests use independent authority and replica fixtures and exercise the real
protocol, sync orchestrator, session admission, store reducer, and communication
queue behavior wherever practical.

Required regressions:

1. A realistic `LOOT_ADDED` that exceeds the version-3 JSON event limit encodes
   as one version-4 compact message no larger than 243 bytes.
2. Decoding the compact message reconstructs a canonical event equal to the
   authority's committed event and produces the same digest on a separate
   replica.
3. One compact group broadcast advances two or more aligned replicas without
   any `RANGE_REQ` or `SNAP_REQ`.
4. Wrong-authority, wrong-raid, old-epoch, malformed, duplicate, future, and
   digest-conflicting compact messages retain existing fail-closed behavior.
5. A non-reconstructible or oversized loot does not send a partial event and
   falls back to one head-driven recovery.
6. Four rapid loot commits do not cancel an in-flight recovery, do not exhaust
   the live budget, retain only the newest head, and converge through at most
   one catch-up range after the current request.
7. A replica that misses the final compact event recovers after the single
   0.25-second consolidated head without requiring a later loot.
8. A temporary live admission failure retains the latest head and retries once
   admission becomes available; newer heads do not multiply retry timers.
9. Historical transfer operations cannot exhaust the live-recovery rate class,
   and live operations cannot bypass either class's bounds.
10. Late join, checkpoint snapshot fallback, authority handover, reentry,
    raid conclusion, and consent-gated historical sharing continue to pass.
11. Version-3 messages are rejected and version-4 messages are accepted.
12. Valid existing `RMA_*` SavedVariables load and retain their records without
    schema mutation or reset.

Implementation follows test-driven development: each behavioral change must be
introduced by a focused failing regression, observed failing for the expected
reason, then satisfied by the minimum runtime change.

## Validation

After focused tests, run:

- the complete Python/Lua test suite;
- TOC validation;
- Lua 5.1 syntax validation;
- Lua 5.1 `xpcall` scan;
- XML script-handler scan;
- focused and whole-addon Luacheck as available;
- StyLua check against the repository baseline;
- `git diff --check`;
- a review of TOC-referenced changed runtime files, untracked runtime files,
  deleted runtime references, and registry/load-order risk.

## Two-Client In-Game Smoke

1. Update both A and B to the same RMA version and reload.
2. A becomes raid leader/master looter and creates the active raid.
3. A awards four items rapidly while B keeps Loot History open.
4. Each item appears once on A and appears promptly on B without a terminal
   `RATE_LIMIT` state.
5. Stop after a final fifth item and verify B receives it without another loot
   being awarded.
6. Temporarily prevent B from receiving one live message, then restore traffic;
   the consolidated head must recover the exact missing range.
7. Join a third updated client C after loot already exists; C bootstraps by
   snapshot and then receives later compact broadcasts directly.
8. Reload B and verify active replica selection, loot rows, sequence, and digest
   remain coherent.
9. Offer a completed historical raid while new active loot is recorded and
   verify the historical transfer does not delay or rate-limit active recovery.

## Behavior Deltas

- Old behavior: normal oversized loot is announced by `HEAD` and recovered by a
  per-recipient range session. New behavior: a reconstructible normal loot is
  sent once as a compact group broadcast and applied directly by every aligned
  replica. Reason: remove avoidable round trips and duplicated transfers.
- Old behavior: every newer head may cancel and replace an ordinary in-flight
  range. New behavior: the current recovery completes while only the newest
  follow-up position is retained. Reason: preserve monotonic progress and rate
  slots.
- Old behavior: a failed live request discards the remote target and waits for a
  later external signal. New behavior: the newest target is retained for one
  bounded automatic retry. Reason: the final loot must not remain permanently
  behind.
- Old behavior: live and historical operations share one outgoing per-peer rate
  budget. New behavior: both stay bounded but use separate classes. Reason:
  historical sharing must not starve active raid replication.
- Old behavior: protocol version 3 is accepted. New behavior: only version 4 is
  accepted. Reason: all participants are required to update and no legacy wire
  support was requested. SavedVariables compatibility is unchanged.

## Acceptance Criteria

- A normal live loot update reaches every aligned updated client through one
  bounded group message.
- The Receiver reconstructs and validates the same canonical event rather than
  trusting partial UI data.
- Broadcast delivery cannot grant authority or create cross-raid mutations.
- A missed intermediate or final loot converges automatically by targeted
  range or snapshot recovery.
- Rapid newer heads do not cancel useful work or multiply requests.
- Temporary rate or queue admission failure does not require another loot event
  to restart synchronization.
- Completed-history traffic cannot consume the live-recovery budget.
- Version-3 wire support is removed without changing valid `RMA_*` persistence.
- No unbounded queue, timer, request, assembly, or retry behavior is introduced.
- Runtime remains compatible with WotLK 3.3.5a, Interface 30300, and Lua 5.1.
