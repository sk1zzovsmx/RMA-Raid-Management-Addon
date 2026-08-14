# Master Loot History Synchronization Design

Date: 2026-07-15
Status: Approved direction, pending written-spec review

## Problem

In Group Loot, every client can derive loot records from Blizzard messages. In
Master Loot, only the master looter owns the complete authoritative award
context. Other addon clients therefore need to import the committed Loot
History from that authority.

The current implementation accelerates persistent synchronization when a
remote `ITEM_DONE` message is received. This is not a reliable persistence
boundary: `ITEM_DONE` can precede the authoritative `CHAT_MSG_LOOT` record
commit, and a fixed two-second delay can still request an old snapshot. Raid
requests can also be rejected when the master looter is not raid leader or
assistant.

## Product Contract

After a Master Loot record is visible in client A's Loot History, it must appear
in client B's Loot History within five seconds when the resulting delta or
bootstrap snapshot is at most 47 chunks and both clients:

- run compatible RMA versions;
- are members of the same party or raid;
- identify A as the current master looter; and
- have persistent synchronization enabled.

The contract applies to direct Master Loot awards, Hold awards, later
Hold/trade completion, and clients that join after the raid has started.

The five-second target is a measured normal-operation budget, not a promise for
the artificial 256-chunk safety maximum. Larger valid late-join snapshots stay
atomic and must complete within the existing 30-second request timeout when the
transport queue has no unrelated backlog.

## Scope

- Synchronize canonical Loot History records after they are committed.
- Authorize the actual master looter independently of raid rank.
- Notify peers when the authoritative history revision advances.
- Recover a missed notification or late join through a targeted snapshot or
  delta request.
- Keep imports atomic and idempotent.
- Keep the existing 120-second pull as a fallback.

## Non-goals

- Showing the live Master Loot window or held-item queue on other clients.
- Writing Loot History directly from `RMADist` messages.
- Synchronizing uncommitted loot-window state.
- Introducing Ace2, Ace3, or a new generic networking module.
- Redesigning SavedVariables or changing the raid-history schema.

## Considered Approaches

### Post-commit invalidation followed by pull (selected)

The master broadcasts a small revision notice only after the canonical record
commit. Peers request the existing delta or snapshot when they are behind.
This reuses the established `RMALogSync` importer, validation, lineage, and
deduplication paths.

### Push the complete record

This is faster but would duplicate serialization, validation, reconciliation,
and transaction behavior already owned by `DBSyncer`. It also creates a second
write path into Loot History and is rejected.

### Short periodic polling

This requires little protocol work but adds continuous traffic and visible
latency. It does not solve the current authority and commit-order bugs and is
rejected as the primary mechanism.

## Ownership

- Loot recording remains the sole owner of canonical record creation and sync
  revision advancement.
- `Database/DBSyncer.lua` remains the sole owner of persistent history wire
  messages, requests, deltas, snapshots, imports, and request lifecycle.
- `Modules/Comms.lua` remains the transport queue owner.
- `Services/Loot/DistributionSession.lua` remains live distribution state only
  and no longer triggers persistent-history synchronization.

No new runtime module is required.

## Data Flow

1. The master looter completes an award or Hold transfer.
2. Blizzard confirms the loot through the existing runtime event path.
3. Loot recording appends the canonical record and advances its sync revision.
4. After the commit succeeds, `DBSyncer` broadcasts a compact revision notice
   on the existing `RMALogSync` prefix.
5. A peer validates the real `CHAT_MSG_ADDON` sender as the current master
   looter and checks that the notice describes its current raid lineage.
6. If the announced revision is newer, the peer coalesces nearby notices and
   whispers one synchronization request to the master looter.
7. The master returns an existing delta when possible, otherwise an existing
   snapshot.
8. The peer applies the response atomically, refreshes Loot History, and marks
   the request complete.

The revision notice is advisory. A lost notice cannot corrupt state because
the late-join request and 120-second fallback use the same authoritative pull.

## Revision Notice

Add one backward-compatible `RMALogSync` message kind containing only:

- protocol version;
- authoritative raid lineage/signature;
- committed history revision.

The message must stay below the WotLK 3.3.5a addon-message limit. Unknown
message kinds remain ignored, so older RMA clients continue operating without
a breaking protocol change.

The notice contains no Loot History record and cannot mutate persistence by
itself.

## Authority

For automatic persistent synchronization:

- requests are accepted only from current group members;
- only the current master looter answers group synchronization requests;
- a master looter does not need raid leader or assistant rank;
- responses and revision notices are accepted only from the real current
  master looter resolved from the roster;
- manual or administrative synchronization keeps its existing authorization
  rules unless a focused test proves they conflict with this contract.

This separates loot authority from generic raid leadership without creating a
fail-open path.

## Late Join And Recovery

When a client gains a usable current-raid identity after login, roster change,
zone transition, or raid creation, it sends one coalesced targeted request to
the current master looter. Local login time is not part of the shared raid
identity.

If the peer revision is supported by the master's delta history, the master
sends a delta. Otherwise it sends the current snapshot. A request that times
out may retry once; subsequent recovery is left to the 120-second fallback.

## Transport

Existing snapshot and delta chunks remain below the 3.3.5a per-message byte
limit. Their queue emission must use conservative constant pacing instead of
the current four-message burst. No adaptive token bucket or per-record ACK is
introduced.

Completion of the correlated delta or snapshot request is the acknowledgement.
The sender does not retry unsolicited notices.

## Removal Of The Failed Trigger

The two-second synchronization acceleration attached to remote `ITEM_DONE`
must be removed after the post-commit notice is covered by tests. Any internal
mutation-provenance plumbing introduced solely for that trigger should also be
removed if it has no remaining consumer.

## Failure Handling

- A failed record commit emits no revision notice.
- A stale or duplicate notice is ignored.
- A notice from a non-master sender is ignored and diagnosed.
- A mismatched raid lineage does not overwrite local history.
- A failed delta falls back to the existing snapshot path.
- A partial snapshot never mutates Loot History.
- Queue saturation or request timeout is diagnosed without silently marking
  the request complete.

## Compatibility And Persistence

- No SavedVariables schema change is required.
- Existing explicit `persistentSync = false` remains respected.
- The `RMALogSync` prefix is unchanged.
- The new message kind is additive and ignored by older clients.
- Existing snapshot and delta formats remain unchanged unless implementation
  evidence proves a bounded compatibility fix is necessary.

## Verification

Automated tests must cover:

- no notice before the canonical record commit;
- one notice after a successful revision advance;
- no notice after a failed commit;
- current master looter authorized without leader or assistant rank;
- non-master responder and sender rejected;
- duplicate notices coalesced into one request;
- stale and mismatched-lineage notices ignored;
- delta success and snapshot fallback;
- one retry after timeout and no unbounded retries;
- late join with different local login times;
- direct award, Hold award, and Hold/trade history convergence;
- atomic import and no duplicate Loot History rows;
- disabled persistent synchronization remains a no-op;
- the removed `ITEM_DONE` timer no longer drives persistence.

Run the full Python suite, TOC validation, Lua 5.1 validation, `xpcall` scan,
XML handler scan, lint, and `git diff --check`. Final acceptance requires an
in-game two-client smoke test for direct award, Hold, Hold/trade, and late join.

## Acceptance Criteria

- A committed Master Loot record on A appears on B within five seconds when
  the correlated payload is at most 47 chunks.
- Larger valid late-join snapshots remain atomic and complete within the
  30-second request timeout when the queue has no unrelated backlog.
- B receives the same winner, roll type, roll value, item, and raid association.
- The result is idempotent and contains no duplicate history rows.
- A master looter without raid rank can serve synchronization.
- A late-joining B converges without sharing A's login timestamp.
- Non-authoritative senders cannot modify B's Loot History.
- No live Master Loot UI synchronization is added.
- Integration remains suspended until the two-client smoke test passes.
