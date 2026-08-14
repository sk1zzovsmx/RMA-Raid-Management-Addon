# Loot Distribution Hardening Design

## Status

Approved direction: progressive hardening inside the existing cohesive owners.
This is an incremental refactor, not `GREENFIELD_REWRITE`.

## Goal

Close the remaining end-to-end integrity gap between roll intake, winner
selection, the irreversible master-loot or inventory-trade effect, confirmation,
raid-history attribution, distribution messages, and operator feedback.

The design prioritizes:

1. runtime reliability and data integrity;
2. maintainable ownership and explicit state transitions;
3. measured performance work;
4. recoverable, truthful UX.

## Context And Verified Risks

The current implementation already has useful owners: `Services.Rolls`,
`Services.Master.AwardAttempt`, `AwardSequence`, `AwardConfirmation`,
`TradeExecution`, `Services.Loot.LootAttribution`, `Inventory`, and
`DistributionSession`. It also has atomic logger mutations and final Loot Ban
guards. The remaining risk is coordination across those owners.

The repository audit verified these concrete failures:

- roll intake can remain open after countdown expiry while winner selection and
  award are allowed;
- repeated award actions can queue multiple effects for the same loot slot;
- the loot slot is not strictly revalidated immediately before
  `GiveMasterLoot`;
- `GiveMasterLoot`, confirmation scheduling, and terminal callbacks can fail
  after partial state publication;
- success messages and RMADist winner state are published before physical
  confirmation;
- failed confirmations can leave stale pending attribution;
- a confirmation is removed before its terminal work is known to have
  completed;
- an award timeout is treated as a definite failure even though the physical
  transfer may already have happened;
- RMADist can commit a partial loot window and can accept stale session traffic;
- `TRADE_SHOW` currently fails the addon-driven trade it is expected to open;
- accepted-plus-closed trade events are treated as transfer proof without an
  inventory delta;
- the visible UI cannot cancel the remaining portion of a multi-award;
- the `LOOT_SLOT_CLEARED` performance measurement is skipped on an early return.

## Considered Approaches

### A. Harden Existing Owners Incrementally (Selected)

Extend the existing owners with explicit states, transaction keys, final
revalidation, bounded uncertainty, and behavior tests. Keep the Master
controller as composition/event integration while moving no unrelated UI.

This has the lowest migration and load-order risk and preserves existing public
contracts.

### B. Add One New Global Loot Transaction Orchestrator

A single orchestrator could unify master loot, inventory trade, RMADist, and
logger checkpoints. It would also duplicate responsibilities already owned by
several services, create a large new API, and require a broad rewrite of the
Master controller. Rejected as unnecessary architecture.

### C. Apply Independent Defensive Patches

Local guards around `GiveMasterLoot`, `TRADE_SHOW`, and announcements would be
smaller initially. They would not define one coherent lifecycle, would leave
partial terminal effects and stale attribution ambiguous, and would be harder
to test. Rejected because the verified failures are coupled state transitions.

## Architecture And Ownership

No generic transaction framework or catch-all helper is added.

- `Services.Rolls` owns roll intake and exposes one atomic freeze operation.
- `Services.Master.AwardAttempt` owns one award transaction, reentrancy guards,
  terminal checkpoints, and the `executing`, `confirming`, `uncertain`,
  `confirmed`, and `failed` states.
- `Services.Master.AwardConfirmation` owns the bounded in-flight confirmation
  queue, uniqueness keys, timers, retry/uncertainty policy, and matching of
  `LOOT_SLOT_CLEARED` to the intended transaction.
- `Services.Loot.LootAttribution` owns transaction-addressable cancellation and
  reconciliation of pending/provisional attribution.
- `Services.Loot.Inventory` owns strict item identity checks and inventory
  evidence snapshots for both master-loot slots and inventory trades.
- `Services.Master.AwardSequence` owns only single/multi award sequencing and
  cancellation of future entries. It does not infer physical success.
- `Services.Master.TradeExecution` owns the addon-driven inventory-trade state
  machine and completion evidence.
- `Services.Master.Trade` applies the same evidence rule to manual Hold-item
  trades without sharing unrelated award sequencing.
- `Services.Loot.DistributionSession` remains the RMADist wire/session owner and
  becomes the sole acceptance reducer for incoming session mutations.
- `Controllers.Master` remains the WoW event/UI composition boundary and calls
  the owners above. It must not become the transaction state owner.

## Roll Freeze And Award Entry

Before resolving any winner or starting an award, the Master controller calls a
single `Services.Rolls:FreezeRollIntake("award")` operation. The operation:

- disables recording and candidate intake;
- stops the countdown and invalidates its callbacks;
- closes the current roll-session window;
- rebuilds the final immutable display/resolution model once;
- returns that final session/model or `nil, reason`.

After the freeze, later system-roll messages cannot mutate the awarded
resolution. Tie reroll remains an explicit new intake window and must be frozen
again before its winner is awarded.

Award entry fails closed while `AwardConfirmation:HasInFlight()` is true. The
same guard covers button, manual grid, single-copy, and multi-copy entrypoints.
The next multi-award entry is allowed only after the previous transaction is
confirmed or definitively failed.

## Master-Loot Transaction

### Pre-effect phase

The transaction is created before any irreversible action. Its stable runtime
key contains transaction ID, roll-session ID, canonical item key, winner, source,
and intended loot slot.

Immediately before `GiveMasterLoot`, the implementation rechecks:

- current master-looter capability;
- frozen winner eligibility and current Loot Ban state;
- current master-loot candidate identity/index;
- current loot-slot link against the canonical target key;
- absence of another in-flight confirmation for the same transaction/slot.

If both item links have canonical item strings, they must match exactly. Item-ID
fallback is allowed only when at least one canonical string is unavailable.

Pending attribution and confirmation queue publication are atomic from the
caller's perspective. Timer scheduling failure publishes neither. A protected
`GiveMasterLoot` failure cancels the matching confirmation and
`LootAttribution` transaction and returns a stable reason.

### Confirmation phase

`LOOT_SLOT_CLEARED` is evidence, not an unqualified success signal. The
confirmation owner matches the transaction by slot, item identity, session, and
transaction ID before executing terminal checkpoints.

The pending confirmation remains owned until every required checkpoint reports
success. Successful checkpoints are remembered and skipped on retry. The
minimum checkpoints are:

1. provisional attribution confirmation;
2. confirmed RMADist roll/item publication;
3. raid roll-type counter mutation;
4. sequence progress/item-count mutation;
5. success announcement and winner whisper;
6. UI refresh/terminal release.

Reentrant `Confirm`/`Fail` calls are rejected while a transition is running.
Callback errors are contained with Lua 5.1 `pcall`, recorded as an uncertain
result, and never repeat already completed checkpoints.

Success announcements, winner whispers, `ROLL_END`, and `ITEM_DONE` occur only
from confirmed checkpoints. Known pre-effect/client rejection produces no
success output.

### Timeout and uncertainty

The existing four-second timeout no longer means definite failure. It moves the
transaction to `uncertain`, warns the operator exactly once, and starts a bounded
reconciliation window aligned with the pending-attribution TTL.

During reconciliation:

- later slot-clear or authoritative loot-chat evidence may confirm the attempt;
- a strict check proving the target item still occupies the intended loot slot
  may fail it and permit retry;
- ambiguous loss of the loot window remains uncertain and produces no success
  announcement or counter mutation.

When the bounded window expires, runtime ownership is released with an explicit
uncertain terminal result. No persistent recovery journal is introduced in this
batch. Reload during this narrow irreversible interval remains an explicitly
documented residual risk for the final in-game smoke.

Known failure, duplicate rejection, and definitive timeout resolution call
`LootAttribution.Cancel(transactionId)` so a later unrelated receipt cannot
consume stale roll metadata.

## RMADist Atomicity And Session Acceptance

`DistributionSession` routes every incoming mutation through one acceptance
decision using trusted sender, session ID, revision, stream state, and
tombstones. Delayed atomic messages from an ended or superseded session cannot
replace or mutate the active display.

Window publication remains protocol version 2. `WINDOW_BEGIN` gains an additive
optional expected-row count. Existing version-2 receivers ignore the extra
field; new receivers enforce it when present. This is a compatible extension,
not a breaking format change.

The sender:

- computes the complete row set first;
- sends `WINDOW_BEGIN(session, revision, expectedRows)`;
- requires every `WINDOW_ITEM` enqueue to succeed;
- sends `WINDOW_END` only after all rows enqueue successfully;
- returns `nil, reason` on the first failure.

The receiver stages rows without touching the active model. `WINDOW_END`
commits only when revision, row count, byte limits, uniqueness, sender, and
session all match. An incomplete/expired window is discarded and the last
complete display remains visible. A zero-row window is a valid complete
snapshot.

Snapshots cannot resurrect a tombstoned session or replace a higher committed
revision. Session-end send failure remains retryable; it does not permanently
set the end-requested latch. Display clearing must not silently invalidate an
outstanding session-ownership token.

Legacy `ITEM` messages remain during this batch for compatibility. Their removal
requires a separate protocol decision and evidence that mixed addon versions no
longer need them.

## Inventory Trade State And Transfer Evidence

`TradeExecution` uses these runtime states:

`idle -> requested -> shown -> accepted -> verifying -> confirmed`

Any state may move to `failed` when a known failure occurs. A post-effect result
without sufficient evidence moves to `uncertain`, not `confirmed`.

The pending attempt and pre-trade evidence are stored before `InitiateTrade` so
the expected `TRADE_SHOW` event advances `requested -> shown` rather than
destroying the attempt.

Evidence captures:

- expected trade partner;
- canonical item key;
- source bag/slot link and stack count;
- total owned count for the canonical item;
- transaction and roll-session IDs.

Both accepted flags are intent, not completion proof. After `TRADE_CLOSED` and
the existing deferred settle point, confirmation requires a positive matching
inventory delta: the source slot/count or total owned count must show that the
tracked item left the player's inventory. The unconditional awarded-count
fallback of one is removed for tracked trades.

If evidence is absent, logger history, counters, RMADist completion, and success
notifications do not run. The operator receives one localized uncertain/failure
message and may retry only after the owner proves the item is still available.

Manual Hold-item trades use the same item-evidence capture/query functions from
`Inventory`, but keep their separate reason-selection and logger policy in
`Services.Master.Trade`.

Checkpointed logger/context/count/reset steps remain idempotent. A failed step
keeps bounded runtime ownership for retry and cannot release RMADist session
ownership as if the transfer were fully recorded.

## Multi-Award Recovery UX

No new marketing-style UI or new top-level frame is added.

While a multi-award is active, the existing Clear action becomes a localized
Cancel Remaining Awards action. It:

- cancels the future delay and progress-timeout handles;
- preserves already confirmed awards;
- does not pretend to cancel an irreversible in-flight current award;
- prevents the next winner from starting;
- refreshes the item count, selection, and status;
- permits a fresh sequence after the current attempt reaches a terminal state.

The UI must distinguish `pending`, `uncertain`, `failed`, and `confirmed` with
truthful localized feedback. XML remains layout-only; the change is controller
behavior and existing button text/state only.

## Performance Policy

This batch fixes measurement before optimization. `LOOT_SLOT_CLEARED` must always
close its total performance span, including the auto-managed early-return path.
Behavior tests count item scans, candidate scans, RMADist enqueues, and refresh
requests for a realistic bounded multi-slot fixture.

Optimization is allowed only when the measurement demonstrates repeated work.
The first candidates are reuse of the already rebuilt loot-window snapshot and
coalescing duplicate refresh requests. No cache, generic performance module, or
new `OnUpdate` loop is added speculatively.

## Persistence, Compatibility, And Reload

- No SavedVariable name or schema changes.
- No persistent award journal or migration is added.
- Runtime transaction IDs remain runtime-only and must be unique for the active
  addon session.
- `/rma`, frame identities, XML structure, addon prefix, and existing public
  namespaces remain stable.
- RMADist stays protocol version 2 with an additive optional field.
- No vendored library is modified.
- All runtime code remains Lua 5.1 and WotLK 3.3.5a compatible.

## Behavior Deltas

| Old behavior | New behavior | Reason |
|---|---|---|
| Winner selection can coexist with open late-roll intake. | Award entry freezes intake and resolves one final model. | Prevent winner drift after the decision. |
| Repeated clicks can queue duplicate physical effects. | One in-flight confirmation blocks all award entrypoints. | Prevent duplicate item transfer and attribution. |
| Success is announced after calling the API. | Success is announced only after confirmed checkpoints. | Eliminate false-success UX. |
| Confirmation timeout means cancellation. | Timeout means bounded uncertainty until evidence resolves it. | The irreversible API may already have succeeded. |
| Failed attempts leave pending attribution until incidental purge. | Known failures cancel attribution by transaction ID. | Prevent stale metadata corrupting later loot. |
| Partial RMADist windows can replace complete state. | Only complete expected-row windows commit. | Preserve remote display integrity. |
| Delayed session messages can switch active display. | One reducer rejects stale/tombstoned session mutations. | Prevent state resurrection. |
| `TRADE_SHOW` fails addon-driven trades. | Expected `TRADE_SHOW` advances the trade state. | Match WotLK event order. |
| Accept plus close implies completed trade. | Matching inventory delta is required. | Prevent false logger/counter awards. |
| Multi-award can only time out. | Operator can cancel remaining awards. | Provide safe recovery from a wrong sequence. |

## Test Strategy

Tests use production Lua owners through the existing Lua harness. Source-string
assertions remain only for external load-order/XML contracts.

Required behavior matrices:

1. award freezes intake; late rolls and stale countdown callbacks cannot change
   the winner;
2. double click/manual-grid reentry produces one API call and one transaction;
3. scheduler/API/final-slot/candidate failures publish no success and cancel
   attribution;
4. slot-clear, chat-first, slot-first, UI-error, timeout, and reconciliation
   ordering are idempotent;
5. partial terminal checkpoint failure retries without repeating completed
   effects;
6. RMADist partial send, missing row, duplicate row, stale revision, stale
   session, tombstone, snapshot resurrection, zero-row window, and retryable end;
7. `requested -> shown -> accepted -> verifying -> confirmed` trade ordering;
8. canceled accepted trade without inventory delta produces no logger/counter
   success;
9. manual Hold trade applies the same evidence rule;
10. multi-award cancel stops future callbacks and preserves confirmed progress;
11. performance spans close on every branch and bounded fixtures expose exact
    scan/send/refresh counts.

Every runtime change follows RED-GREEN-REFACTOR. Each task receives an
independent spec/quality review, followed by a whole-batch review.

## Validation And Runtime Smoke

Offline gates:

- complete Python unittest suite;
- TOC validation;
- Lua 5.1 syntax validation;
- variadic `xpcall` scan;
- XML handler scan;
- whole-addon luacheck excluding `Libs/**`;
- `git diff --check`;
- commit-coherence review for TOC, deleted/untracked runtime files, docs, and
  residual risk.

`tools/check-rma.ps1` is run only if it exists. StyLua remains scoped to touched
files because repository-wide legacy line-ending churn is not part of this
batch.

The in-game smoke remains deferred until the complete refactoring program, then
must include real master-loot confirmation/failure, multi-award cancellation,
RMADist between mixed clients where available, successful/canceled inventory
trade, reload preservation of canonical `RMA_*` data, and visible truthful
feedback.

Exact status phrase for interim reports:

`runtime smoke: deferred by user until the full refactoring program is complete`

## Out Of Scope

- persistent recovery journal or SavedVariable migration;
- removal of legacy RMADist `ITEM` messages;
- broad decomposition of the 3,645-line Master controller by size alone;
- PASS/CANCELLED roll-response product UI without a concrete caller;
- generic transaction, retry, cache, or performance frameworks;
- unrelated Logger, Raid, Reserves, Spammer, Warnings, Inspect, or XML redesign.

## Completion Criteria

This batch is complete when all verified effect boundaries fail closed, winner
state cannot drift after award entry, duplicate effects are rejected, success is
confirmation-backed, uncertain outcomes remain truthful and bounded, stale
attribution cannot leak, RMADist commits only complete current sessions, trade
completion requires item evidence, remaining multi-awards are cancellable, the
hot path is measured on all exits, documentation matches the implemented
contracts, all offline gates pass, and the deferred live-client risks are stated
without claiming a smoke test was run.
