# Raid Leader Re-entry Recovery Design

Date: 2026-07-18
Branch: `codex/single-raid-history-sharing`
Status: Approved
Improvement: data integrity, runtime safety, and raid continuity

## Problem

The Raid Leader is the authoritative writer for both Master Loot and Group Loot,
but the current startup path does not safely distinguish a genuinely new raid
from a reload or reconnect into the same instance. The runtime `currentRaid`
pointer may be absent even when a persisted active raid still exists, and a
returning Leader can advertise or write an older sequence before consulting
replicas that retained newer events.

This creates two separate risks:

- a reload can fail to resume the previous raid or can attempt a duplicate;
- a stale returning Leader can cause a newer replica to request and install an
  older snapshot, losing replicated loot history.

The existing recovery-first authority handover covers a change of Raid Leader.
It does not cover the same Raid Leader returning after a reload, disconnect, or
client crash.

## Goals

- Ask the Raid Leader before resuming a previous raid when zone, raid size, and
  difficulty match the current instance.
- Prevent creation and canonical writes while the returning Leader determines
  the best active copy held by the current group.
- Recover the highest valid sequence without allowing an older snapshot to
  overwrite newer state.
- Fail closed on equal-position digest divergence or ambiguous raid identity.
- Preserve the existing Raid Leader authority model for Master Loot and Group
  Loot.
- Keep late-join active replication and consent-gated historical sharing
  unchanged.

## Non-goals

- Merging divergent raid states.
- Reconstructing loot that was never committed or observed by any replica.
- Automatically importing completed history.
- Adding periodic synchronization, peer-presence tracking, or an unbounded
  `OnUpdate` loop.
- Adding a new persistent raid status such as `interrupted`.
- Changing the `RMA_Raids` SavedVariables schema.

## Chosen Approach

Extend the existing recovery machinery with a same-authority mode. Reuse the
version-3 `HEAD_REQ`, `HEAD`, and snapshot exchange instead of creating a second
recovery protocol.

`HEAD_REQ` remains a request for the receiver's active HEAD, with behavior
determined by the authenticated sender:

- a non-Leader participant whispers `HEAD_REQ` to the Raid Leader for late-join
  bootstrap;
- a Raid Leader in re-entry recovery broadcasts `HEAD_REQ` to the group;
- each current group replica with an active candidate replies to that Leader by
  whisper with its HEAD.

Older clients may ignore the recovery broadcast. Modern clients continue to
receive existing version-3 traffic. No legacy payload is emitted and no
additional SavedVariables are introduced.

Modern HEAD senders include three bounded context fields: zone, raid size, and
difficulty. Receivers continue to accept an otherwise valid legacy version-3
HEAD that omits these fields for normal known-UID synchronization. A HEAD
without context cannot establish an unknown local raid identity during
same-authority recovery; it remains eligible only when the Leader already knows
the matching UID and can validate context from the recovered snapshot. This is
the existing receive-legacy, send-modern compatibility policy.

## Recovery State And Write Barrier

When a recognized raid instance is entered and the local player is the current
Raid Leader, the addon enters re-entry recovery before checking whether it
should create or resume a raid.

While re-entry recovery is open:

- `Raid:Create` and automatic creation are blocked;
- authoritative loot, roster, boss, and attendance mutations are blocked;
- no authoritative `HEAD` or `EVENT` is advertised;
- the physical in-game loot operation is not automated or delayed by RMA;
- recovery snapshot installation is permitted because it is the operation that
  establishes the safe base state.

The barrier is runtime-only. It is released only by a successful recovery and
resume decision, by creation after proving that no valid copy exists, or by an
explicit terminal failure that keeps recording suspended.

The recovery coordinator alone may execute the terminal, atomic transition that
concludes the recovered record and creates its replacement. This narrow path
does not reopen ordinary loot, roster, boss, or attendance writes between the
two operations.

If the actual Raid Leader identity changed while the client was absent, the
existing authority-handover recovery owns the transition. Same-authority
recovery must not bypass or replace a handover.

## Discovery Bounds

The returning Leader sends one group `HEAD_REQ` immediately. If no valid HEAD is
received, it sends at most one retry three seconds later. The collection closes
three seconds after the final request.

The response set is naturally bounded by the maximum raid-group membership.
Concurrent instance-entry signals coalesce into the same recovery attempt.
Late responses from a completed or replaced attempt are ignored. There is no
polling and no recurring announcement.

## Candidate Admission

Every response must pass the existing protocol limits and additionally satisfy
all of these conditions:

- the real addon-message sender is a current member of the same raid group;
- the receiver is still the current Raid Leader and the same recovery attempt
  is active;
- the HEAD describes an active raid;
- the raid identity and authority epoch satisfy the rules below;
- the HEAD is structurally valid and within existing wire bounds.

When the Leader retains a local active raid UID, only HEADs with the exact same
`raidUid` and `authorityEpoch` are candidates. A response for the same UID with
a different epoch is not silently ignored as an older copy: it suspends this
same-authority path so the authority transition can be resolved safely.

When the Leader has no local active raid UID, automatic recovery is allowed
only if every valid response agrees on the same `raidUid`, the same
`authorityEpoch`, and modern HEAD context matching the current zone, raid size,
and difficulty. One valid response is sufficient agreement; two or more
conflicting responses suspend recovery. A context-free legacy HEAD cannot
establish an unknown UID. No majority vote or arbitrary winner is used.

## Candidate Selection And Anti-downgrade Rule

Within one admitted `raidUid + authorityEpoch` pair, select the greatest
sequence.

- Different sequences: select the greatest sequence.
- Same sequence and same digest: treat the candidates as equivalent.
- Same sequence and different digests: suspend synchronization, preserve the
  local archive, and show a WARN to the local Raid Leader.

Snapshot repair is monotonic for the same active identity and epoch:

- incoming sequence greater than local sequence: install after full validation;
- equal sequence and equal digest: no-op;
- equal sequence and different digest: reject as a conflict;
- incoming sequence lower than local sequence: reject as stale.

The returning Leader must never advertise its local HEAD before this comparison
finishes. Replicas must likewise refuse a stale snapshot downgrade even if the
snapshot sender is the current Raid Leader.

## Recovery And Resume Decision

After selecting the best HEAD, the Leader requests and atomically validates the
corresponding snapshot when its local copy is missing or behind. If the local
copy already has the selected position and digest, no snapshot is transferred.

The resume decision is made only after the best recoverable copy is installed.
The recovered raid is eligible for the confirmation popup only when all three
properties exactly match the current instance:

- zone;
- raid size (`10` or `25`);
- difficulty.

The popup displays the recovered raid and those three matching values.

- **Yes:** set the existing persisted raid index as `currentRaid`. Do not copy
  the record, change its UID, or create a revision merely for resuming it.
- **No:** conclude the fully recovered previous raid, then create exactly one
  new active raid.
- Closing or dismissing the popup without choosing: keep recording suspended;
  do not create or mutate a raid implicitly.

If any of zone, size, or difficulty differs, do not show the popup. Conclude the
recovered previous raid and create exactly one new raid.

If neither a valid local candidate nor a valid replica response exists after
the bounded discovery attempt, create exactly one new raid. This is the only
automatic new-raid path during re-entry recovery.

After a successful **Yes** decision or successful creation of the replacement
raid, release the write barrier and advertise one authoritative HEAD. The
same-authority recovery does not increment `authorityEpoch`; a real authority
handover continues to own epoch changes.

## Component Ownership

- `Database/DBSyncer.lua` owns the same-authority recovery attempt, bounded
  `HEAD_REQ` collection, candidate admission, conflict state, best-HEAD
  selection, and snapshot request.
- `Database/DBRaidStore.lua` owns monotonic active-snapshot replacement and
  stale/equal-position rejection.
- `Services/Raid/Session.lua` prevents new-raid creation while recovery or a
  resume decision is pending.
- `Services/Raid/Capabilities.lua` and the existing mutation guards expose no
  authoritative commit capability while the write barrier is active.
- `Services/Raid/State.lua` coordinates current-raid restoration, conclusion,
  and replacement creation through internal events; it does not render UI.
- A focused raid-recovery controller owns the confirmation popup through the
  existing `UI.Popups` API and returns the user's decision through the internal
  event bus.
- `Init.lua` continues to own recognized-instance publication and main WoW
  event wiring.

No generic recovery framework, strategy abstraction, or new synchronization
service is added.

## Warnings And Failure Handling

The local Raid Leader receives a user-visible WARN when recovery is suspended
because of:

- equal sequence with different digests;
- disagreement between replica UID or epoch when no local UID exists;
- the same UID appearing with an unexpected authority epoch;
- snapshot validation or monotonic replacement failure.

The warning states that raid recording remains suspended and that no copy was
overwritten. Essential sync status remains available normally; detailed peer,
HEAD, sequence, digest, timeout, and rejection reasons remain debug-only.

Transport failure or no response consumes the bounded retry. A valid local copy
may still be used after the collection window. Without any valid local or remote
copy, the addon creates a new raid. Malformed, oversized, late, off-group, or
incorrectly targeted messages fail closed.

## Test-driven Coverage

Implementation must begin with failing runtime-harness regressions for these
behaviors:

1. Matching local raid after Leader reload: recovery, popup **Yes**, same UID,
   and no extra revision.
2. Popup **No**: recover the newest copy, conclude it, and create one new raid.
3. Zone, size, or difficulty mismatch: no popup, conclude old, create one new.
4. Stale Leader and ahead replica: recover the greater sequence before writes.
5. Same UID and epoch with different sequences: choose the greatest.
6. Equal sequence with divergent digests: preserve data, suspend, and WARN.
7. Missing local UID with unanimous replicas: recover the agreed identity.
8. Missing local UID with discordant replicas: suspend without choosing.
9. No local or remote candidate: create only after bounded discovery completes.
10. Late, off-group, wrong-UID, wrong-epoch, and stale snapshot input is ignored
    or rejected without mutation.
11. Loot, roster, boss, attendance, creation, HEAD, and EVENT publication remain
    blocked during recovery.
12. Existing participant late-join `HEAD_REQ -> HEAD -> SNAP_REQ -> SNAP_DATA`
    behavior remains intact.
13. Completed historical sharing still requires offer and acceptance.

Focused tests must prove the RED failure before production changes, then pass
after the minimum implementation. The complete Lua suite and WotLK validators
must pass before the branch is considered code-ready.

## Live Smoke Gate

The required two-client WotLK smoke is:

1. A is Raid Leader and creates the active raid; B receives its replica.
2. A commits loot and B reaches the same sequence and digest.
3. A reloads or disconnects and returns while remaining Raid Leader.
4. A creates and writes nothing before recovery completes.
5. A recovers B's greater sequence, confirms **Yes**, and resumes the same UID.
6. New loot committed by A converges to B.
7. Repeat with **No** and verify that the previous raid concludes and exactly
   one new raid is created.
8. A offers a completed historical raid, B accepts, and the raid is visible in
   B's Loot History.

The smoke notes must record observed UID, epoch, sequence, digest, popup choice,
and absence of Lua errors for both clients.

## Behavior Delta

- Old behavior: a returning Raid Leader could fail to restore `currentRaid`,
  create too early, or advertise a stale active record to newer replicas.
- New behavior: the Leader is read-only during bounded peer discovery, repairs
  from the best valid copy, asks before resuming an identical-context raid, and
  cannot downgrade newer state.
- Compatibility impact: additive role-aware use of the existing version-3
  `HEAD_REQ`; existing late-join receive behavior remains supported.
- Migration impact: none; the `RMA_Raids` schema is unchanged.
- Data limitation: events absent from every valid replica remain unrecoverable.

## Integration Gate

Do not integrate, cherry-pick, rebase, or copy this branch into
`codex/loot-bans-optimization` until the complete two-client live smoke is
positive. Automated tests and validators establish code readiness but do not
replace this runtime gate.
