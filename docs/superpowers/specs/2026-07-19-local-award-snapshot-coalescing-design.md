# Local Award Ownership and Snapshot Coalescing Design

Date: 2026-07-19
Branch: `codex/single-raid-history-sharing`

## Objective

Repair two failures demonstrated by the two-client in-game smoke without changing
the raid schema, SavedVariables, sync protocol, or authority model:

1. A client that is both Raid Leader and Master Looter records one loot row per
   award instead of recording both the local attribution and its own
   `DISTRIBUTION_AWARD`.
2. A replica that is bootstrapping an active raid does not cancel and recreate
   its snapshot request for every newer canonical event until it reaches
   `RATE_LIMIT`.

The separate `record_finalize_failed` HOLD failure is outside this change.

## Evidence

The persisted raid ledger from the failing smoke contains, for each award, one
row created by `LOOT_SLOT_CLEARED` and reconciled by `CHAT_MSG_LOOT`, followed by
a second row created by `DISTRIBUTION_AWARD`. The rows use different session
identifiers (`RS:*` and `session|AT:*`), so the existing session-based fallback
correctly treats them as distinct.

The replica reports `recovering SNAPSHOT_REQUIRED` and later
`failed RATE_LIMIT`. While its snapshot is in flight, each newer event
supersedes the pending recovery and starts another outbound request. The session
allows four outbound operations per target in thirty seconds.

## Design

### Local award ownership

The local attribution flow remains the only persistence owner when the current
client is both the Raid Leader and the sender of the Master Loot distribution
fact. Its provisional record already has a bounded grace fallback when chat
ordering differs or the receipt is missing.

`RecordDistributionAward` will treat that locally produced distribution fact as
already owned and will not call `LogTradeOnlyLoot`. It will report successful
consumption so the distribution retry path does not retry a deliberately skipped
local write.

When the distribution sender is another group member, the Raid Leader continues
to validate and persist `DISTRIBUTION_AWARD` exactly as it does now. This
preserves the supported split-authority case where the Raid Leader and Master
Looter are different clients.

No time-window item deduplication, new transaction identifier, wire change, or
SavedVariables field will be added.

### Active replica snapshot coalescing

This behavior applies only to an ordinary active-raid replica snapshot. Raid
Leader reentry and authority handover keep their existing fail-closed behavior.

When a snapshot is pending and a newer event for the same sender, raid UID, and
authority epoch arrives, the replica will:

1. keep the current snapshot request alive;
2. retain only the newest remote position as a follow-up target;
3. install the valid snapshot it already requested;
4. request the missing event range from the installed sequence through the
   newest retained sequence.

If that range is unavailable or invalid, the existing full-snapshot fallback is
used. Duplicate or older positions do not create another request. A different
sender, raid UID, authority epoch, digest conflict, reentry, or handover follows
the existing rejection and recovery rules.

This bounds a normal bootstrap burst to the in-flight snapshot plus one catch-up
operation when the event range is available, instead of one snapshot per event.

## Error Handling

- A local distribution fact is skipped only when its normalized sender is the
  local Raid Leader. Invalid facts continue to fail validation.
- A remote Master Looter award is never skipped by the local-owner rule.
- Snapshot metadata and digest validation remain mandatory before installation.
- A captured follow-up range uses the existing range validation and snapshot
  fallback; no partial canonical state is accepted.
- Existing suspension behavior for digest conflicts is unchanged.

## Verification

Focused regressions must demonstrate:

1. Local Leader/Master Looter, slot-first ordering: slot, chat, and distribution
   produce one canonical loot row and one counter change.
2. Local Leader/Master Looter, distribution-first ordering: the same award still
   produces one canonical loot row.
3. Split authority: a remote Master Looter award is persisted once by the Raid
   Leader and replicated to an ordinary member.
4. A member snapshot is held while more than four newer events arrive; the
   original snapshot is not cancelled, no `RATE_LIMIT` occurs, one catch-up
   recovery converges to the Leader's final sequence and digest.

After focused tests, run the full relevant Python suite, Lua 5.1 validation, TOC
validation, `xpcall` scan, XML-handler scan, `git diff --check`, and the two-client
in-game smoke.

## In-Game Acceptance

1. B joins before A; A becomes Raid Leader and creates the authoritative raid.
2. A is also Master Looter and awards multiple items during B bootstrap.
3. Each item appears once in A's Loot History.
4. B receives the active raid without `RATE_LIMIT`; its Loot History converges
   to A.
5. With a different Master Looter, the Raid Leader still receives and persists
   each remote award once.

Do not integrate into `codex/loot-bans-optimization` until this smoke is positive.

## Non-Goals

- Fixing the demonstrated HOLD `record_finalize_failed` warning.
- Redesigning Loot Attribution or Distribution Session.
- Raising or disabling communication rate limits.
- Changing history offers, reentry recovery, authority handover, raid schema,
  protocol version, or SavedVariables.
