# Task 5 Report: Inventory-Evidenced Award Trades

## Status

DONE

## Scope

Implemented Task 5 only. No Task 6 multi-award cancellation, button-state, or
performance-span work was added. No SavedVariables, TOC, XML, frame identity,
slash command, or wire-format contract changed.

## RED Evidence

Command:

```powershell
py -3 -m unittest tests.test_loot_distribution_hardening_behavior.LootDistributionHardeningTests.test_trade_inventory_evidence_requires_a_positive_delta tests.test_loot_distribution_hardening_behavior.LootDistributionHardeningTests.test_award_trade_event_order_is_evidence_gated tests.test_loot_distribution_hardening_behavior.LootDistributionHardeningTests.test_manual_hold_trade_requires_inventory_evidence -v
```

Result: 3 failures, each for the intended missing production behavior:

- `Inventory.CaptureTradeEvidence` did not exist;
- `TradeExecution:GetPendingState` did not exist, so no `requested` state was
  visible before `InitiateTrade`;
- manual Hold candidates contained no inventory evidence.

## Implementation

- `Services.Loot.Inventory` now captures canonical item identity, source
  bag/slot/link/count, and total owned count before pickup. Verification checks
  the normalized expected partner and requires a positive source-stack or
  total-owned delta. The old unconditional one-item resolver was removed.
- `Services.Master.TradeExecution` now creates the pending transaction and
  acquires RMADist session ownership before `InitiateTrade`. It exposes data-only
  pending state and transitions through `requested`, `shown`, `accepted`,
  `verifying`, `uncertain`, `confirmed`, and `failed`.
- Expected `TRADE_SHOW` advances the addon-driven transaction instead of
  failing it. A wrong partner and explicit cancel paths fail and release the
  matching session token.
- Accepted flags record intent only. Deferred settle verifies inventory before
  logger, RMADist `ROLL_END`, raid counter/progress, announcement, or whisper.
  An unverified close remains uncertain, warns once, records no success, and
  retains ownership for evidence-based retry or a later known failure.
- Logger rejection remains retryable. Existing checkpoints prevent already
  completed logger, distribution, counter/progress, and notification work from
  being repeated.
- `Services.Master.Trade` captures the same evidence for manual Hold candidates.
  Manual completion verifies every tracked candidate before logger/counter
  mutation, retains pending state on uncertainty or logger rejection, and keeps
  the existing reason-selection policy.
- Non-award inventory trade flows retain their existing notification path. A
  compatibility-only inventory stub may initiate a request, but settlement
  fails closed when no verification API is available.

## Behavior Matrix Covered

- pending exists before `InitiateTrade`;
- expected and wrong-partner `TRADE_SHOW`;
- cancel before and after show;
- one accepted flag versus both accepted flags;
- accepted close without delta;
- source-stack decrease and total-count decrease;
- canonical source replacement;
- logger rejection and successful retry without duplicate downstream effects;
- manual Hold completion without and with later inventory evidence.

## Validation Evidence

- Targeted Task 5 cases: 3/3 passed.
- Loot-distribution hardening suite: 24/24 passed.
- Raid-recording integrity regressions: 43/43 passed.
- Full Python suite: 227/227 passed.
- TOC validation: 0 errors, 0 warnings.
- Lua 5.1 validation: 134 files clean.
- Lua 5.1 variadic `xpcall` scan: 134 files clean.
- XML handler scan: clean (no matches).
- Whole-addon luacheck excluding `Libs/**`: 0 warnings, 0 errors in 121 files.
- `git diff --check`: passed; Git reported only expected LF/CRLF conversion
  notices.
- `tools/check-rma.ps1`: absent.
- StyLua scoped check: exit 1 because the touched legacy CRLF files would be
  rewritten wholesale. No formatter churn was applied.

## Residual Risk

The WotLK client must still confirm that bag links/counts remain queryable at
the chosen pre-trade and deferred post-close event points, and that a real
successful/canceled trade produces the expected delta and partner identity.
No persistent recovery journal was added, so reload during an uncertain trade
still releases runtime-only evidence.

runtime smoke: deferred by user until the full refactoring program is complete

## Review Fix Wave

The first task review returned three Important findings. All three were fixed
in one bounded TDD wave.

### Additional RED Evidence

The three targeted production-owner cases failed for the intended reasons:

- a nil observed partner returned `trade_transfer_unverified` because expected
  partner data was incorrectly reused as observation;
- nil-partner `TRADE_SHOW` advanced to `shown`;
- a two-candidate manual Hold retry stopped on the first already-logged row;
- the terminal release scenario additionally demonstrated that a failed
  `ReleaseSessionOwnership` would otherwise lose the pending token.

### Fixes

- `VerifyTradeEvidence` now returns `trade_partner_unavailable` when the real
  observed partner is absent. Neither `TRADE_SHOW` nor settle substitutes the
  expected partner. Show remains `requested`; settle remains unconfirmed and
  retryable.
- Manual Hold retry skips `loggedLootNids` already committed and continues the
  remaining candidates. The two-candidate test proves the first logger/counter
  run once and the second logger alone retries before its single counter.
- Session ownership release is a terminal checkpoint. The token is cleared
  only after `ReleaseSessionOwnership` returns exactly `true`. A false/nil
  result retains pending state with `releasePending`; `SettleAcceptedTrade` or
  `FailAcceptedTrade` retries only the release and never repeats inventory
  verification or committed award effects.

### Fresh Review-Wave Validation

- Targeted review cases: 3/3 passed.
- Loot-distribution hardening suite: 24/24 passed.
- Raid-recording integrity regressions: 43/43 passed.
- Full Python suite: 227/227 passed.
- TOC validation: 0 errors, 0 warnings.
- Lua 5.1 validation: 134 files clean.
- Lua 5.1 variadic `xpcall` scan: 134 files clean.
- XML handler scan: clean.
- Whole-addon luacheck excluding `Libs/**`: 0 warnings, 0 errors in 121 files.
- `git diff --check`: passed with only expected LF/CRLF conversion notices.

## Final Partner-Observation Fix

The follow-up review clarified that a partner successfully observed and
validated during `TRADE_SHOW` remains valid evidence after `TRADE_CLOSED`, when
the live trade-frame lookup may legitimately be nil. A revised production-owner
test first failed with `trade_partner_unavailable`. `TradeExecution` now stores
that validated observation in both the pending transaction and its evidence;
deferred settle uses the current observed partner or this previously validated
shown partner. It never falls back to `expectedPartner`. A nil partner at
`TRADE_SHOW` still leaves the transaction in `requested` and cannot confirm.
