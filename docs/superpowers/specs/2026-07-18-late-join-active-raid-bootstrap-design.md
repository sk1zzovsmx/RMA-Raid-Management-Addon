# Late-Join Active Raid Bootstrap Design

Date: 2026-07-18
Branch: `codex/single-raid-history-sharing`
Improvement: bug fix, runtime safety, and data integrity

## Problem

Active-raid replication is currently push-only. If Raid Leader A already owns an
active raid before participant B enters the instance or reloads, B cannot create
an authoritative raid and has no way to ask A for the current active state. A
does not observe B's local world transition, so no HEAD is announced and B's
database remains empty.

The existing flow after a HEAD is healthy:

`HEAD -> SNAP_REQ -> SNAP_DATA -> active replica import`

The missing operation is receiver-initiated discovery before the HEAD.

## Authority And Persistence Contract

- The Raid Leader remains the sole authority for the active raid in both Master
  Loot and Group Loot.
- B never creates or stages a competing raid.
- When A and B are members of the same raid group, B may persist a read-only
  replica of A's active raid in `RMA_Raids`.
- The replica uses the same stable raid identity, authority epoch, sequence, and
  digest as A's record.
- When A concludes the raid, the conclusion replicates to B and the same record
  becomes visible as completed history in Loot History.
- A raid that is already completed before discovery is not imported
  automatically. Historical transfer remains offer-and-consent only.

## Chosen Design

Add a modern `HEAD_REQ` discovery message to the existing version-3 sync
protocol.

1. B detects a recognized raid instance while it has no active local raid and
   is not the Raid Leader.
2. B sends `HEAD_REQ` directly to the currently identified Raid Leader.
3. A accepts the request only when the sender is a current raid-group member and
   A is the current Raid Leader.
4. If A owns an active raid, A publishes the existing HEAD.
5. B authenticates the HEAD as coming from the identified Raid Leader and uses
   the existing snapshot bootstrap flow.
6. A completed HEAD never enters this discovery path, preserving historical
   consent.

`HEAD_REQ` is additive. Older receivers may ignore the unknown message; modern
senders continue to accept the existing version-3 messages. No SavedVariables
schema change is required.

### Component Ownership

- `Init.lua`, which already owns instance recognition, publishes an internal
  `RaidInstanceRecognized` event after a recognized instance is confirmed. This
  covers zone entry and `PLAYER_ENTERING_WORLD` after reload without making the
  database layer call WoW instance APIs.
- `DBSyncProtocol.lua` owns the closed empty body for `HEAD_REQ`. It uses the
  fire-and-forget envelope (`requestId = "-"`, `target = "-"`); the actual
  transport is a whisper to the identified Raid Leader.
- `DBSyncer.lua` owns discovery state, sends the whisper, validates incoming
  requests, and invokes the existing `AdvertiseHead()` response on the Raid
  Leader.
- `DBSyncSession.lua` remains unchanged because `HEAD_REQ` has no correlated
  payload response. The following `SNAP_REQ/SNAP_DATA` exchange continues to use
  its existing correlation, limits, and timeout handling.

## Retry And Bounds

- One discovery request is sent immediately when `RaidInstanceRecognized`
  arrives.
- At most one retry is sent three seconds later if B still has no active
  replica.
- A valid HEAD or installed active snapshot terminates pending discovery.
- Concurrent instance-entry signals coalesce into the same bounded discovery
  attempt.
- No periodic announcement, polling loop, or unbounded `OnUpdate` is added.

## Entry Order And Authority

Instance entry order does not determine database authority. The current Raid
Leader does.

- If B enters the instance first while A is already the Raid Leader but remains
  outside, B does not create a raid. Its discovery request may receive no HEAD
  because A has no active raid yet. When A enters, A creates the authoritative
  raid and the existing `RaidCreate` announcement bootstraps B.
- If B is the actual Raid Leader when B enters, B creates the authoritative
  raid. If leadership later moves to A, the existing recovery-first handover
  transfers authority over that same stable raid identity; A must not create a
  duplicate.
- If the current Raid Leader does not have RMA, no participant may create an
  authoritative raid on the leader's behalf. Recording begins only when an
  RMA-enabled Raid Leader becomes authoritative.

## Alternatives Rejected

### Group HELLO broadcast

This would let A answer without a direct target, but every addon client would
process discovery traffic. A direct request to the known Raid Leader is smaller
and has clearer ownership.

### Periodic authoritative HEAD

Periodic announcements would eventually converge, but add continuous traffic
and polling despite a concrete receiver-side event. This conflicts with the
event-driven synchronization policy.

## Failure Handling

- Missing or ambiguous Raid Leader identity: fail without creating local data;
  the single retry may try again after roster state settles.
- Sender outside the raid group: reject the request.
- Receiver is not the Raid Leader: ignore/reject without replying.
- A has no active raid: no HEAD is sent and B remains empty.
- Transport failure or missing response: consume the bounded retry and stop.
- Malformed, oversized, or incorrectly targeted messages: reject through the
  existing closed protocol validation.

## Tests

The regression must use the real in-process two-peer transport in this temporal
order:

1. Construct A with an already-active authoritative raid.
2. Construct B with no active raid.
3. Trigger only B's recognized-instance entry/discovery path.
4. Assert `HEAD_REQ -> HEAD -> SNAP_REQ -> SNAP_DATA`.
5. Assert B persists the same active raid identity, sequence, and digest.
6. Assert B performs no successful authoritative create.
7. Assert repeated entry signals produce no more than the bounded attempts.

Additional ordering regressions must prove:

- B enters before an already-designated A, then imports A's raid after A enters;
- B enters as the actual Raid Leader, then A takes leadership through handover
  without creating a second raid;
- a non-leader never substitutes for a Raid Leader without RMA.

Existing tests must continue proving that completed raids require explicit
offer acceptance and that Group Loot does not change Raid Leader authority.

## Behavior Delta

- Old behavior: a late participant without a local raid attempted creation,
  received an authority rejection, and remained empty until A happened to emit
  another authoritative event.
- New behavior: the participant asks the Raid Leader for the active HEAD and
  installs a read-only replica through the existing authenticated snapshot flow.
- Reason: the old push-only bootstrap was incomplete for portal entry and
  reload, because those events occur only on B.
- Compatibility impact: additive modern discovery message; existing receive
  behavior is preserved.
- Migration impact: none.
- Runtime proof: automated two-peer regression plus the required live WotLK
  smoke with B entering and reloading after A's raid is active.

## Integration Gate

The branch must not be integrated into `codex/loot-bans-optimization` until the
two-client live smoke confirms that B receives A's active raid and the existing
historical offer/acceptance workflow remains positive.
