# Master Loot Award Transactions Design

## Goal

Make Master Loot awards transactional and reliably confirmed across loot-window,
inventory-keep, and inventory-trade flows before consolidating them behind one
runtime state-machine owner.

## Constraints

- Target WoW WotLK 3.3.5a, Interface 30300, and Lua 5.1.
- Preserve existing SavedVariables and existing addon-message payloads.
- Keep inbound legacy `ROLL_TICK` and `AWARDED` handlers.
- Do not persist incomplete award transactions across reloads.
- Do not use item ID alone to correlate identical awarded items.
- Keep XML layout-only and preserve current public frame identities.

## Transaction Model

An award transaction is runtime-only and contains:

- `transactionId`: unique identifier for the local award attempt;
- `rollSessionId`: associated roll session when one exists;
- `itemKey` and `itemLink`: stable wire/runtime item correlation;
- `winnerName`: normalized intended recipient;
- `source`: `loot_window`, `inventory_trade`, or `inventory_keep`;
- `state`: current state from the state model below;
- `failureReason`: stable reason code when the transaction fails.

The state progression is:

```text
selected
-> rolling
-> winner_selected
-> executing
-> confirmed
  \-> failed
```

Only `confirmed` is a successful terminal state. `failed` is the unsuccessful
terminal state. A reload discards any non-terminal runtime transaction; it does
not synthesize a persisted award.

## Wire Semantics

- `ROLL_START` means roll intake is active.
- `ROLL_END` means a winner has been selected. It does not mean the item was
  delivered.
- `ITEM_DONE` is emitted only when an award transaction becomes `confirmed`.
- `ITEM_CANCELLED` is emitted when an executing or winner-selected transaction
  becomes `failed`.
- Existing wire message layouts remain unchanged.
- Updated clients handle `ITEM_CANCELLED`; older clients safely ignore the new
  message type.

## Delivery Sequence

### 1. Transactional trade confirmation

Addon-driven inventory trades adopt the staged behavior already used by manual
trades. `TRADE_ACCEPT_UPDATE` with both parties accepted records an accepted,
pending transaction but does not log the award, emit `ITEM_DONE`, increment
award progress, or advance the multi-winner sequence. Settlement after
`TRADE_CLOSED` confirms the transaction only when no failure was observed and
the transfer has supporting completion evidence. Cancellation, error, changed
acceptance, or failed settlement moves it to `failed` and rolls back pending
runtime state.

### 2. Uniform confirmation and failure

Loot-window, inventory-keep, and inventory-trade executors use the same
transition operations for beginning execution, confirming, and failing. These
operations own terminal wire publication, counters, logging dispatch, cleanup,
and multi-award advancement. Executors own only the WoW interaction needed to
attempt delivery.

### 3. Resilient loot-window logging

`LOOT_SLOT_CLEARED` creates a provisional award record associated with the
transaction identity, roll session, item, winner, and cleared slot. A matching
`CHAT_MSG_LOOT` reconciles and confirms that record. If chat is absent after a
short bounded grace period, the provisional evidence is retained and finalized
without duplicating the award. Correlation prioritizes transaction ID and roll
session ID, then item key/link and normalized winner; item ID alone is never
sufficient.

### 4. Countdown and distributed state

Starting a countdown republishes `ROLL_START` with its duration. No outbound
`ROLL_TICK` is restored. Existing receivers continue to process `ROLL_START`;
updated receivers can display the actual countdown duration.

### 5. Atomic remote session lifecycle

Loot-window publication gains an explicit revision/batch lifecycle so receivers
do not expose a partially populated window. Opening publishes a begin marker,
the item rows, and an end marker or equivalent atomic snapshot. Cleanup publishes
an explicit session end/clear unless an inventory award transaction still owns
the session. Existing version handlers remain supported.

### 6. Unified state-machine owner

After the preceding behavior is proven, extract a concrete
`Services.Master.AwardTransaction` owner. Loot-window and trade code become
executors. The owner controls state transitions, invariants, terminal effects,
and idempotency. Controllers continue to orchestrate UI and WoW events without
owning transaction rules.

## Failure And Idempotency Rules

- Confirming or failing a terminal transaction is idempotent.
- A transaction cannot emit both `ITEM_DONE` and `ITEM_CANCELLED`.
- Logger writes and award counters occur at most once per transaction.
- Multi-award advancement occurs only after confirmation.
- A failed award leaves the selected winner visible where retry is safe.
- Timeout and reload cleanup cannot create persisted loot records.
- Duplicate or late chat messages reconcile with an existing provisional or
  confirmed record instead of appending another record.

## Testing Strategy

Each delivery step uses RED-GREEN-REFACTOR and receives an independent commit
and review.

Required behavioral coverage includes:

- both trade parties accepting does not immediately confirm or log;
- successful trade settlement confirms exactly once;
- cancelled or failed trade emits cancellation and does not log;
- loot-window failure cannot emit `ITEM_DONE`;
- `LOOT_SLOT_CLEARED` plus matching chat creates one final record;
- missing chat finalizes one provisional record after the grace period;
- identical item copies for different winners do not merge;
- countdown publication includes duration without `ROLL_TICK` outbound;
- remote opening and closing cannot leave partial or stale session state;
- all three executors satisfy the same state-transition contract.

Full validation must include Python tests, StyLua, Luacheck, Lua 5.1 parsing,
TOC validation, xpcall scanning, XML handler scanning, and `git diff --check`.
An in-game WotLK 3.3.5a smoke test remains required for real trade and loot
event ordering.

## Execution Method

Implementation follows the six steps above using
`superpowers:subagent-driven-development`: one fresh implementer per task,
task-scoped specification and quality review after every commit, correction of
all important findings before continuing, and a whole-branch review at the end.
