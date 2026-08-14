# Raid Recording Integrity Report

## Scope And Outcome

This report verifies the final raid-recording integrity branch state. The batch
improves runtime safety, data integrity, recoverability,
and maintainability across roster recording, attendance, raid replacement,
logger cleanup/rebuild, loot recording, and equipment-inspect persistence.

The batch changes internal mutation ownership and failure behavior. It does not
change the stable external addon contract: addon identity, `/rma`, Interface
`30300`, the six `RMA_*` SavedVariables, addon-message prefixes or wire formats,
TOC load order, XML frame identities, or the persisted raid schema version.

## Behavior Deltas

### Roster And Attendance

- Roster refresh publication is now owned by `Raid:RefreshAndPublish()`. A real
  roster change emits one `RaidRosterDelta`; a no-op emits nothing. Dispatcher,
  retry, Attendance, and Logger callers no longer publish independently.
- Session-ending roster changes retain the old raid identity long enough to
  publish one finalized `left` delta with `sessionEnded = true`.
- Attendance seed, join, leave, subgroup, online, and close handling is
  idempotent. Duplicate joins, duplicate leaves, rank-only changes, and other
  no-ops neither mutate canonical attendance nor advance synchronization state.
- Subgroup and online transitions close and reopen attendance monotonically;
  replacement segments cannot overlap or move backward.
- Attendance deletion now removes only selected attendance evidence. It
  preserves player identity, boss membership, loot attribution, and inspect
  snapshots. The former user-reachable cascade-delete behavior was removed.

### Raid Session Replacement

- A replacement raid is prepared, admitted, and selected before the old session
  is finalized. Nil returns, exceptions, partial insertion, index mutation, and
  selection failure restore the prior raids, indexes, counters, current raid,
  attendance, realm-player metadata, revisions, and event state.
- Successful replacement preserves the established event context: attendance
  close observers see the old raid as current before the new `RaidCreate` event.

### Logger Cleanup, Rebuild, And Loot Recording

- Raid-history cleanup now plans work and commits through store-owned commands
  keyed by stable NIDs. It no longer mutates raw SavedVariables arrays directly.
- Cleanup never stages the active raid for deletion, revalidates the protected
  current `raidNid` immediately before apply, and the store independently
  refuses that protected NID. A current-raid change makes an async plan conflict
  without deleting or publishing stale work.
- Synchronous and asynchronous cleanup have explicit complete, failed, and
  cancelled terminal states. Callback delivery is exactly once. A failed
  transaction publishes no success event; uncertain rollback is reported rather
  than hidden.
- Deleted raids require full synchronization. Surviving raids touched by one
  cleanup transaction advance once. No-op cleanup does not advance revisions.
- Logger rebuild and `RecordLoot` stage and validate canonical rows before one
  protected store commit. Verification failures, invalid/sparse canonical
  collections, revision conflicts, touch failures, or index-rebuild failures
  restore canonical state and publish no committed-change event.
- Asynchronous rebuild detects a changed base revision and terminates with a
  conflict instead of overwriting concurrent loot recording. Public repair
  counters include only committed or successfully unchanged work.

### Equipment Inspect

- Inspect queues, timers, callbacks, and delayed work use stable `raidNid`
  identity and re-resolve the raid before effects. Deleted raids are cancelled
  as orphans rather than redirecting work after array reorder.
- Blizzard's global inspect target is serialized across raids with deterministic
  handoff and bounded combat retry behavior. Scheduling is deterministic FIFO
  within each raid queue, with round-robin requeue across raids. Thus requests
  `A1, A2, B1` run as `A1, B1, A2`; this intentional policy prevents one busy
  raid from starving another and is not global request-order FIFO.
- A ready equipment/spec snapshot is last-known-good canonical data. Timeout,
  offline, out-of-range, skipped, and other transient attempt states do not
  replace it or advance the raid revision.
- Ready snapshot persistence is store-owned, semantically idempotent, and
  rollback-safe. Save preparation removes transient/legacy inspect fields and
  implausible uptime timestamps without changing the schema version.

## Synchronization And Event Contracts

- `syncRevision` advances exactly once for each completed canonical mutation
  covered by this batch and does not advance for rejected, rolled-back,
  conflicted, transient, or no-op work.
- Row-representable loot mutations use loot-scoped revision marking. Mutations
  that cannot be represented safely as a row delta, including raid deletion and
  structural history repair, require full synchronization.
- `RaidRosterDelta` is emitted once by the roster owner after a completed
  mutation. Its existing payload and roster-version shape remain compatible.
- `RaidAttendanceChanged` carries stable `raidNid` plus the mutation reason;
  controllers resolve that identity to a transient array index only at the UI
  boundary.
- `LoggerDataChanged` describes a completed store-owned batch and includes its
  reason/result. `LoggerLootChanged` is emitted only after a loot mutation is
  committed. Cancelled, failed, conflicted, and rolled-back work emits neither
  success notification.
- These are internal `addon.Bus` contracts. No addon-message prefix, payload,
  chunking rule, protocol version, or remote-import behavior changed.

## Atomicity Guarantees

- Raid replacement restores the canonical raid history, selection, last-boss,
  attendance, revision, and metadata state covered by the injected failure
  matrix when pre-publication creation, insertion, selection, finalization, or
  runtime preparation fails. Timer side effects already observed externally are
  outside the rollback contract.
- Logger cleanup captures a cohesive store snapshot before applying its plan.
  Failed apply restores raids, nested history, revisions, NID counters, indexes,
  and current selection; restore failure is surfaced as rollback uncertainty.
- Logger history commits validate stable identity and base revision, replace
  canonical nested state once, advance synchronization once, and rebuild exact
  indexes in the same protected transaction.
- Ready inspect persistence compares compact canonical snapshots before commit
  and restores the snapshot plus synchronization metadata after partial failure.
- Events and UI success feedback occur only after the corresponding canonical
  transaction reaches a successful terminal state.

### Loot Award And Trade Completion

- Master Loot now freezes roll intake, revalidates permission, winner, Loot Ban,
  candidate, and exact loot-slot identity immediately before the protected
  client effect, then records success only after confirmation checkpoints.
- Known award failures cancel only their transaction-scoped pending attribution.
  An initial 4-second timeout enters evidence-based handling and, when still
  ambiguous, retains ownership for a bounded 8-second reconciliation period
  without recording or announcing success.
- Addon-driven and manual Hold trades require a positive matching source-stack
  or total-owned inventory delta. Accepted/closed trade events alone cannot
  mutate raid history, counters, or RMADist completion state.
- Logger mutations remain store-owned and atomic; the new effect boundary
  ensures those mutations are not requested from unconfirmed physical awards.

## External Contract And Coherence Review

- TOC metadata is unchanged: title `Raid Management Addon`, Interface `30300`,
  version `0.1.0-alpha.1`, and the same six SavedVariables.
- The TOC file and XML files have no batch diff. XML remains layout-only and all
  existing frame identities remain unchanged.
- No SavedVariables declaration or persisted raid schema-version change exists.
  Inspect save admission only removes non-canonical/transient legacy fields.
- No prefix or breaking wire-format change exists. RMADist remains protocol v2;
  `WINDOW_BEGIN` adds an optional expected-row field that old v2 receivers may
  ignore and updated receivers enforce before committing a staged window.
- Every changed runtime Lua file is explicitly referenced by the authoritative
  TOC. The TOC validator also reports no missing file or unsupported directive.
- `docs/ARCHITECTURE.md`, `docs/FEATURE_API_MAP.md`, and `docs/VALIDATION.md`
  now include the subsequent loot-distribution owner, evidence, timing, and
  validation contracts.

## Fresh Validation Evidence

Commands were rerun against the final `loot-distribution-hardening` Task 7
worktree state.

| Command | Result |
|---|---|
| `py -3 -m unittest discover -s tests -q` | PASS: 234 tests, 0 failures/errors |
| `py -3 C:\Users\ferra\Downloads\RMA-Raid Management Addon\.agents\skills\wow-addon-dev-wotlk-v335a\scripts\validate_toc.py 'Raid Management Addon/Raid Management Addon.toc'` | PASS: 0 errors, 0 warnings |
| `py -3 C:\Users\ferra\Downloads\RMA-Raid Management Addon\.agents\skills\wow-addon-dev-wotlk-v335a\scripts\lint_lua51.py 'Raid Management Addon'` | PASS: 134 files clean |
| `py -3 C:\Users\ferra\Downloads\RMA-Raid Management Addon\.agents\skills\wow-addon-dev-wotlk-v335a\scripts\scan_xpcall.py 'Raid Management Addon'` | PASS: 134 files clean of variadic `xpcall` |
| `rg -n '<Scripts>\|<On[A-Za-z]+>' 'Raid Management Addon/UI' -g '*.xml'` | PASS: no matches |
| whole-addon `luacheck` excluding `Libs/**` | PASS: 0 warnings, 0 errors in 121 files |
| `stylua --check` on the 14 changed loot-distribution runtime Lua files | NON-BLOCKING BASELINE: exit 1; formatter proposes legacy whole-file/CRLF normalization and broad pre-existing formatting changes, so no runtime formatting rewrite was applied |
| `git diff --check 04163f5` | PASS |

The ignored `.agents` directory is absent from this isolated worktree. The same
project-local validator scripts were therefore invoked from the parent checkout
with addon paths still rooted in this worktree, as allowed by `VALIDATION.md`.
`tools/check-rma.ps1` is not present and was not run.

## Residual Risks And Deferred Scope

- Static and harness validation cannot prove protected-action behavior, frame
  lifecycle, inspect-server timing, raid event ordering, chat feedback, or
  SavedVariables behavior in the actual 3.3.5a client.
- Sync transport authorization, PUSH consent, chunk/payload limits, remote
  revision monotonicity, and atomic remote import remain deferred.
- The offline loot/roll/award/trade integrity matrices are complete, including
  a full production-owner chain where chat-first and slot-first attribution
  converge on one record without premature pending consumption, duplicate
  checkpoints, retained confirmation ownership, or blocked next admission.
  Remaining risk is live-client behavior around
  protected `GiveMasterLoot`, real `LOOT_SLOT_CLEARED` and trade event timing,
  bag visibility after trade close,
  mixed-version addon-channel delivery, and reload/crash during the narrow
  runtime-only uncertain interval; no persistent recovery journal was added.
- SpecInspect unresolved-GUID callbacks and unrelated UI redesign remain
  deferred.
- Broad StyLua conformance remains legacy cleanup work; applying it in this batch
  would create unrelated whole-file and line-ending churn.

runtime smoke: deferred by user until the full refactoring program is complete
