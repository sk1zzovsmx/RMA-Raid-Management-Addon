# Loot Distribution Hardening Report

## Scope And Outcome

This report covers the progressive hardening in `04163f5..HEAD`. The existing
cohesive owners were extended; no global transaction framework, persistent
recovery journal, generic cache, new frame, or new runtime module was added.

The batch closes the offline-tested integrity path from roll intake through
Master Loot or inventory trade, confirmation, attribution, raid-history effects,
RMADist publication, multi-award progress, and operator feedback. It does not
claim live WotLK client behavior.

## Behavior Deltas And Compatibility

### Roll Freeze And Admission

- Old: roll intake and countdown callbacks could remain effective while winner
  execution began, and repeated entry actions could reach another effect.
- New: `Services.Rolls:FreezeRollIntake("award")` closes intake/countdown and
  preserves one final readable session/model. Button, manual-grid, direct Hold,
  single-copy, and multi-copy entry all use the same admission policy. One
  `AwardConfirmation` in flight rejects another entry with `award_in_flight`.
- Reason: prevent winner drift, stale callback mutation, and duplicate physical
  transfers. Tie reroll remains an explicit new intake window.
- Compatibility: internal behavior only; roll UI/frame identities and public
  commands are unchanged.

### Award Attempts, Confirmation, And Attribution

- Old: terminal effects could partially publish, confirmation ownership could
  be removed before all effects succeeded, and timeout was treated as definite
  failure. Stale pending attribution survived known failures.
- New: `AwardAttempt` owns runtime states `executing`, `confirming`, `uncertain`,
  `confirmed`, and `failed`. Named checkpoints retain completed work and retry
  only the rejected phase. Reentrant terminal transitions fail closed.
  `AwardConfirmation` owns one pending entry until provisional attribution and
  every controller/sequence checkpoint succeeds. Known failure calls
  `LootAttribution.Cancel(transactionId)`, which removes only that transaction.
- Event ordering: an authoritative `CHAT_MSG_LOOT` that arrives before
  `LOOT_SLOT_CLEARED` is staged on the unique transaction-backed pending award;
  it cannot consume or log that award before slot confirmation. Slot-first chat
  continues through the existing provisional path. Both orders converge on one
  finalized record, one reconciliation, exact pending consumption, and no stale
  callback duplication.
- Full-chain verification loads the real loot service, attribution owner,
  confirmation owner, and Master button admission together for both event
  orders. It also found and fixed the controller adapter returning a provisional
  table to a checkpoint contract that requires literal `true`; confirmed
  provisional creation now converts to the accepted checkpoint result.
- Timing: the controller supplies `C.ML_AWARD_CONFIRM_TIMEOUT_SECONDS = 4` and
  `C.PENDING_AWARD_TTL_SECONDS = 8`. At 4 seconds, a target still present is a
  known failure; an absent target retries confirmation; unavailable evidence is
  uncertain. Ambiguous ownership is then retained for at most another 8 seconds
  before `confirmation_unresolved` releases runtime ownership and cancels stale
  attribution. Thus the configured unresolved bound is 12 seconds after queue,
  aside from callback scheduling latency.
- Success timing: `ROLL_END`, `ITEM_DONE`, player counter/sequence progress,
  announcement, whisper, and terminal refresh occur only through confirmed
  checkpoints. A transport rejection remains retryable and cannot repeat an
  already successful checkpoint.
- Compatibility: transaction IDs and checkpoints are runtime-only. No
  SavedVariables schema or supported `_G.RMA` API was added.

### Master-Loot Effect Boundary

- Old: item-ID fallback could accept a same-ID/different-canonical-string slot,
  API/scheduler failures could escape after partial publication, and success
  feedback could precede physical confirmation.
- New: immediately before `GiveMasterLoot`, the controller rechecks Master
  Looter capability, frozen winner eligibility, current Loot Ban state,
  candidate identity, exact intended slot, and duplicate confirmation. When
  both canonical item strings exist they must match exactly; item-ID fallback is
  allowed only when either canonical string is unavailable. Confirmation is
  queued before the protected Lua 5.1 `pcall` effect. Scheduler failure queues
  nothing; API throw/explicit rejection removes the exact confirmation and
  attribution and emits no success.
- Compatibility: client API call and user workflow are unchanged; failure is
  now explicit and conservative.

### RMADist Atomicity And Session Scope

- Old: a partial window could be ended/committed, failed publication could
  consume a revision, and delayed snapshot/session traffic could replace the
  current display or consume ownership.
- New: the sender validates the complete candidate, sends BEGIN, every legacy
  ITEM and WINDOW_ITEM, then END only after all enqueue operations succeed.
  Failed publication is retryable at the same revision. The receiver builds a
  detached candidate and one acceptance path checks authority, session,
  revision, limits, uniqueness, stream state, and tombstones before mutation.
  Zero-row windows are valid; incomplete windows preserve the last complete
  display. Session-end transport failure retains its owner token for retry.
- Wire compatibility: prefix `RMADist` and protocol version `2` are unchanged.
  `WINDOW_BEGIN` appends an optional expected-row count (integer 0..128). Older
  v2 receivers ignore the extra field; updated receivers enforce it. Legacy
  ITEM messages remain intentionally available for mixed-version clients.

### Inventory-Evidenced Trades And Manual Hold

- Old: expected `TRADE_SHOW` could fail an addon-driven attempt; both accepted
  flags plus close implied transfer, and tracked completion could fall back to
  one item without inventory proof.
- New: `TradeExecution` records pending state/evidence before `InitiateTrade`
  and progresses through `requested`, `shown`, `accepted`, `verifying`, then
  `confirmed`, `failed`, or `uncertain`. A validated shown partner may remain
  evidence after the trade frame closes; the expected partner is never used as
  an observed partner. Completion requires a positive matching source-stack or
  total-owned count decrease. Without it, logger, counters, RMADist completion,
  announcement, and whisper do not run. Session release is itself retryable.
  Manual Hold candidates use the same capture/verify functions while retaining
  their separate reason and logger policy; committed rows are skipped on retry.
- Compatibility: event/UI workflow is preserved; false-positive award history
  is replaced by localized uncertainty. No persistence or wire change.

### Multi-Award Cancellation And Performance

- Old: the operator could not stop future entries safely, and the auto-managed
  `LOOT_SLOT_CLEARED` return skipped the total performance-span finish.
- New: while a multi-award is active, the existing Clear action is localized as
  `Cancel Remaining Awards`. It cancels future delay/progress handles, preserves
  confirmed progress, does not claim to reverse the current irreversible
  attempt, refreshes once, and permits a fresh independent sequence. Every
  normal slot-clear return closes `ContinueAward` and `Total` spans.
- Measured 20-slot fixture: 19 loot-count scans, 20 candidate scans, 20 RMADist
  completion sends, and 39 refresh requests. The two refresh families occur at
  distinct winner-transition and confirmation transitions, so the evidence did
  not justify a cache or refresh-coalescing abstraction.
- Compatibility: the existing button/frame is reused; XML remains layout-only.

## Contract And Coherence Audit

- Authoritative TOC: unchanged in `04163f5..HEAD`; every changed runtime file
  already has a TOC entry. Loot, Rolls, Master services load before
  `Controllers\Master.lua`; no new registry or load-order dependency exists.
- Runtime files: 14 existing Lua files changed (13 runtime owners plus English
  localization). No untracked runtime file and no deleted runtime reference
  exists.
- Persistence: TOC still declares exactly `RMA_Raids`, `RMA_Players`,
  `RMA_Reserves`, `RMA_Warnings`, `RMA_Spammer`, and `RMA_Options`. No schema,
  migration, import, or persistent transaction record changed.
- Wire: RMADist remains protocol v2 with one additive optional expected-row
  field. No addon-message prefix changed.
- UI/localization: no XML file changed and the XML handler scan is clean. New
  operator text is defined in `addon.L`; diagnostic templates remain in the
  diagnostic localization owner. No frame identity changed.
- Vendored code: no file under `Raid Management Addon/Libs/` changed.
- Public surface: addon identity, Interface `30300`, `/rma`, frame names,
  SavedVariables, and supported `_G.RMA` surface are unchanged.
- Policy artifacts in the range are the committed design and implementation
  plan plus this synchronized architecture, feature-map, validation, raid
  integrity, and hardening evidence.
- The former bootstrap regex for the private `assignItem` spelling was replaced
  with the production Lua behavior case that exercises shared admission across
  real award entrypoints. Button, manual-grid, direct Hold, single-copy, and
  multi-copy admission each create exactly one `AwardAttempt`, physical effect,
  and confirmation timer; in-flight duplicates create none of them.

## Fresh Validation Evidence

The following gates were rerun from the final Task 7 worktree state:

| Gate | Result |
|---|---|
| `py -3 -m unittest discover -s tests -q` | PASS: 234 tests in 6.883 seconds. |
| TOC validator | PASS: 0 errors, 0 warnings in one TOC. |
| Lua 5.1 validator | PASS: 134 files clean. |
| variadic `xpcall` scan | PASS: 134 files clean. |
| XML handler scan | PASS: no matches (expected `rg` exit 1 normalized to success). |
| whole-addon `luacheck` excluding `Libs/**` | PASS: 121 files, 0 warnings, 0 errors. |
| `git diff --check 04163f5` | PASS; Git reported only configured LF-to-CRLF working-copy notices. |
| `tools/check-rma.ps1` | Absent from this repository; not run. |
| scoped StyLua on the 14 changed runtime Lua files | NON-BLOCKING: exit 1; it proposes whole-file CRLF-to-LF normalization and existing broad formatting changes. No rewrite was applied. |

## Residual Live Risks

- Static/harness tests cannot prove protected `GiveMasterLoot` behavior or the
  live client timing of `LOOT_SLOT_CLEARED`, loot chat, and loot-window closure.
  Both event orders are deterministic in the production-owner Lua harness, but
  their real-client dispatch still needs observation. Server-specific
  addon-channel delivery also remains live risk.
- Real WotLK bag links/counts and partner identity must be checked across
  successful and canceled trade event sequences.
- Mixed-version RMADist behavior is compatibility-designed and offline-tested,
  but still needs two-client observation where available.
- Reload/crash during the narrow interval after an irreversible client effect
  and before confirmation loses runtime-only evidence. This batch deliberately
  adds no persistent recovery journal or SavedVariables migration.
- Visible Cancel Remaining Awards state and truthful uncertain feedback need
  final client UI acceptance.

runtime smoke: deferred by user until the full refactoring program is complete
