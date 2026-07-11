# Award Domain Naming Design

## Objective

Make the Master Loot award services understandable from their names without
changing their ownership, behavior, load order semantics, SavedVariables, wire
formats, or public addon contract.

## Approved Naming Model

| Current owner | New owner | Domain responsibility |
|---|---|---|
| `Services.Loot.AwardPlanner` | unchanged | Builds award targets, winner sets, notifications, and multi-award state. |
| `Services.Master.Award` | `Services.Master.AwardSequence` | Coordinates a sequence containing one or more award attempts. |
| `Services.Master.AwardTransaction` | `Services.Master.AwardAttempt` | Represents one award attempt and its `executing -> confirmed \| failed` lifecycle. |
| `Services.Master.PendingAwardExecution` | `Services.Master.AwardConfirmation` | Waits for the client to confirm or reject an award attempt. |
| `Services.Loot.PendingAwards` | `Services.Loot.LootAttribution` | Correlates observed loot with its winner, roll, session, and provisional record. |

The corresponding files will be renamed to `AwardSequence.lua`,
`AwardAttempt.lua`, `AwardConfirmation.lua`, and `LootAttribution.lua`.
`AwardPlanner.lua` remains unchanged.

## Domain Flow

1. `AwardPlanner` prepares the target and winner plan.
2. `AwardSequence` coordinates the single- or multi-winner award flow.
3. `AwardAttempt` records one attempt and accepts exactly one terminal outcome.
4. `AwardConfirmation` waits for `LOOT_SLOT_CLEARED`, a recognized UI error, or
   a timeout.
5. `LootAttribution` associates the subsequent loot event with the correct
   award metadata.

## Scope

The implementation is a behavior-preserving structural rename. It includes:

- Lua filenames and exported namespace owners;
- TOC entries and load-order references;
- runtime imports, assertions, local bindings, and call sites;
- contract headers, diagnostics identifiers where owner names are embedded,
  tests, and tracked documentation;
- retired-identifier searches proving the old internal names are gone.

The implementation must not change award timing, transaction transitions,
pending-record shapes, event handling, logging behavior, SavedVariables, addon
messages, UI text, or public RMA branding.

## Compatibility And Risk

These service namespaces are internal implementation surfaces. No compatibility
facades or aliases will be retained because they would preserve the ambiguity
the rename is intended to remove. All callers must move in the same coherent
batch.

The principal risks are an omitted TOC path, a stale namespace assertion, or a
missed event-path call site. The data model and runtime algorithms remain
unchanged.

## Verification

The rename is complete only when:

- focused award-attempt, confirmation, attribution, single-award, multi-award,
  and trade-award tests pass;
- TOC, Lua 5.1, `xpcall`, style, and repository checks pass as applicable;
- `git diff --check` passes;
- searches find no retired internal filenames or namespace identifiers;
- the changed runtime set, TOC entries, and service dependencies agree.

In-game verification is limited to the existing Master Loot smoke expectations:
single award, multi-award continuation, failure handling, loot attribution, and
trade attribution. The rename itself introduces no intended behavior delta.
