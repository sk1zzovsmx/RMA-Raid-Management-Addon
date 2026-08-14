# Raid Leader Replication Authority Design

Date: 2026-07-18
Branch: `codex/single-raid-history-sharing`

## Goal

Make active-raid recording work consistently in both Master Loot and Group Loot
by separating raid-database authority from loot-operation permissions.

## Authority Contract

- The current Raid Leader is the sole authority that creates and mutates the
  canonical active raid.
- The authority does not change when the loot method changes.
- The Master Looter may operate Master Loot features, but that role does not own
  the raid database.
- Ordinary RMA clients do not create competing active raids. They automatically
  maintain a local replica received from the Raid Leader.
- If the Raid Leader changes, the new leader first recovers the latest canonical
  state and only then becomes writable. The handover does not create a second
  raid.
- If the Raid Leader does not run RMA, clients do not elect an implicit fallback
  authority. This avoids split-brain databases; fallback election is outside this
  fix.

## Data Flow

1. Inside a recognized raid instance, the Raid Leader creates the active raid in
   either Master Loot or Group Loot.
2. The Raid Leader advertises the authoritative head.
3. Other RMA clients request the missing range or a full snapshot and store the
   result as a replica.
4. Only the Raid Leader commits canonical roster, boss, loot, and conclusion
   events. Replicas apply received authoritative events.
5. Historical raids continue to require explicit offer and recipient consent.

## Recovery-First Handover

The handover has three states:

1. `handover`: the new Raid Leader discovers the best authoritative head.
2. `recovering`: it applies the missing range or full snapshot and canonical
   writes remain closed.
3. `synchronized`: it promotes the recovered record to a new authority epoch,
   then domain owners may replay pending runtime facts.

`DBSyncer` must not stage or replay canonical event payloads during handover.
Those payloads can contain `playerNid`, `bossNid`, or `lootNid` allocated against
the old local state. A newer recovered range or snapshot may already use the
same identifiers for different records. Promotion therefore changes only the
authority epoch and checkpoint of the recovered record; it never merges staged
canonical rows into that record.

While canonical writes are closed, the raid store returns
`AUTHORITY_RECOVERING`. Callers must not treat the mutation as committed and
must not update derived runtime state from it.

## Pending Runtime Facts

Only facts that cannot be reconstructed after recovery may be retained, and
they remain owned by the domain that already understands them. There is no
generic database queue or generic merge/rebase engine.

- Roster and attendance are reconstructed by one normal roster refresh after
  synchronization. Player NIDs and attendance rows are allocated from the
  recovered canonical state. A player who both joins and leaves entirely inside
  the short recovery window may be absent from attendance; this is an accepted
  first-cycle limitation instead of adding a second roster journal.
- Boss kills observed during recovery are retained as a small bounded set of
  pre-NID facts: boss name, difficulty, source NPC identifier, and observation
  time. The Raid service replays them through its normal boss-recording path,
  using its existing deduplication window.
- Group Loot receipts observed during recovery are retained by the Loot service
  as bounded normalized facts that identify the player by name and the item by
  its stable loot/session data, not by canonical NIDs. The normal loot-recording
  path resolves player, boss, and loot NIDs after synchronization and applies
  the associated player counter with the loot transaction. The recovery gate is
  checked before the live receipt consumes workflow, counter, or deduplication
  state.
- Master Loot distribution awards reuse the existing bounded award retry,
  keyed by the stable award identifier. They are not copied into a second
  handover queue.
- Manual history edits and destructive operations are rejected with
  `AUTHORITY_RECOVERING`; the user can retry after synchronization. They are not
  silently queued.
- Raid conclusion is also rejected while recovering and leaves the active raid
  intact. An automatic conclusion caller may perform one limited retry after
  synchronization; a manual conclusion remains an explicit user retry.

Pending facts are memory-only, bound to the active `raidUid`, deduplicated by
their existing stable identity, and limited to 64 facts per domain owner. Boss
facts use the existing 30-second boss window; Group Loot facts use the existing
60-second pending-award lifetime; Master Loot awards keep the existing two
one-second retries. Facts are discarded if the raid changes, authority is lost,
recovery is suspended, or their TTL/retry limit expires. A successful replay
removes the fact. Exhaustion emits optional debug diagnostics without blocking
the rest of synchronization.

Replay ordering is explicit: roster and attendance refresh first, pending boss
facts second, pending Group Loot facts and Master Loot award retries third, and
an automatic conclusion retry last. This ensures loot resolves names and boss
context against the final recovered state. The synchronization-ready
notification must not depend on addon-message polling or unspecified callback
registration order.

## Authority Transition Warning

An authority change emits one local user-facing warning on each involved RMA
client:

- The previous Raid Leader is warned that database authority passed to the new
  Raid Leader and that the local active raid is now a read-only replica.
- The new Raid Leader is warned that database authority was received from the
  previous Raid Leader and that recovery is temporarily blocking canonical
  writes.

The warning is local UI/chat output only; it is not sent to raid chat or over a
new addon-message flow. It is deduplicated by the old/new authority pair so
HEAD announcements, retries, roster refreshes, and repeated capability checks
cannot spam it. Ordinary raid members receive no authority-transition warning.
Recovery success remains visible through essential sync status, while recovery
failure keeps the existing failure diagnostic rather than emitting another
transition warning.

## Runtime Changes

- Raid capabilities expose Raid Leader identity and local Raid Leader status.
- The raid-store authority guard uses Raid Leader status instead of Master
  Looter status.
- Sync authority checks, announcements, recovery, and handover use the Raid
  Leader identity.
- The raid store rejects writes during handover instead of accepting canonical
  payloads for later promotion.
- A synchronization-ready notification lets Raid and Loot replay only their own
  pending facts after the recovered record is promoted.
- The old and new Raid Leaders receive one local warning for each distinct
  database-authority transition; ordinary members receive none.
- Loot-method changes no longer control database authority. Existing loot UI
  permission checks remain based on the Master Looter where appropriate.
- Failed active-raid creation must retain a useful diagnostic reason instead of
  silently reducing every failure to `false`.

## Compatibility And Scope

- No SavedVariables schema or wire-format change.
- No historical-import behavior change.
- No peer election, assistant fallback, periodic polling, generic event queue,
  merge engine, NID rebase layer, or new compatibility layer.
- WotLK 3.3.5a and Lua 5.1 remain mandatory.

## Verification

- Group Loot: Raid Leader entering a recognized raid creates one active raid.
- Master Loot with different Raid Leader and Master Looter: the Raid Leader
  remains database authority and the Master Looter retains loot permissions.
- Ordinary participant: creates no independent raid and converges to the Raid
  Leader through snapshot or delta recovery.
- Raid Leader handover: the new leader recovers the latest state, promotes it
  without staged canonical rows, refreshes the roster, and replays bounded boss
  and loot facts using NIDs allocated from the recovered state.
- Recovery collision regression: if the pre-recovery local state and recovered
  snapshot both expose the same next NID, a pending player/boss/loot fact cannot
  overwrite or alias the recovered row.
- Recovery failure: no pending fact mutates canonical state; pending facts are
  dropped on suspension or identity change with optional diagnostics.
- Recovery entry gate: a Group Loot receipt received while recovering cannot
  pre-consume counters, workflow state, or duplicate markers before replay.
- Authority warning: the previous and new Raid Leaders each see one local
  transition warning, repeated sync traffic does not duplicate it, and ordinary
  members see none.
- Loot-method change: does not replace the raid or change authority.
- Full automated suite and WotLK validators pass.
- Two-client in-game smoke remains mandatory before integration into
  `codex/loot-bans-optimization`.

## Behavior Delta

Previously, active-raid creation and replication authority required the local
client to be Master Looter. Group Loot therefore rejected creation with
`NOT_MASTER_LOOTER`, and the caller hid that reason. After this change, Raid
Leader status controls the active database in every loot mode; Master Looter
status controls only loot-specific operations.

The first handover implementation also staged fully materialized canonical
events before recovery and replayed them after applying a newer snapshot. That
was unsafe because planned NIDs could collide with rows introduced by recovery.
The corrected behavior recovers and promotes first, then rebuilds only bounded
one-shot domain facts through normal owners. This changes no SavedVariables or
wire format and deliberately removes the unsafe staging compatibility path.
