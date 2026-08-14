# Task 7 Report: Contracts, Evidence, And Final Coherence

## Status

REVIEW FIX WAVES COMPLETE. Review found a runtime event-order defect, then the
integrated chain exposed a strict checkpoint-result mismatch. Both were
corrected with production-owner Lua behavior tests;
the documentation now records the implemented Tasks 1-6 contracts and the
final branch coherence evidence.

## Delivered

- Added `docs/LOOT_DISTRIBUTION_HARDENING_REPORT.md` with source-grounded
  old/new behavior deltas, compatibility, timing, measured performance, audit,
  validation, and residual live risk.
- Updated architecture, feature API map, validation policy, and raid-recording
  integrity residuals to reflect the current owners and behavior.
- Fixed `CHAT_MSG_LOOT`-first attribution so authoritative chat is staged on the
  unique transaction and cannot consume the pending award before slot evidence.
  Chat-first and slot-first now converge on one finalized record and release the
  exact pending transaction without duplicate callbacks.
- Strengthened the real production-path admission case. Button, manual-grid,
  direct Hold, single-copy, and multi-copy entry each create exactly one attempt,
  physical effect, and confirmation timer; an in-flight duplicate creates none.
- Corrected `FEATURE_API_MAP.md` to separate controller calls from dependencies
  composed into award, trade, and item-selection owners.
- Added one integrated production chain using the real loot service,
  attribution, confirmation, and Master button admission. It proved both event
  orders and exposed the provisional-table versus literal-`true` checkpoint
  mismatch; the controller now adapts successful provisional creation to the
  strict checkpoint contract.

## Exact Evidence

- Confirmation timeout: 4 seconds from
  `C.ML_AWARD_CONFIRM_TIMEOUT_SECONDS`.
- Reconciliation interval: 8 seconds from
  `C.PENDING_AWARD_TTL_SECONDS`; unresolved ownership is bounded to configured
  12 seconds after queue, excluding callback scheduling latency.
- 20-slot measurement: 19 loot-count scans, 20 candidate scans, 20 RMADist
  completion sends, 39 refresh requests. No cache/coalescing abstraction was
  justified.
- RMADist remains protocol v2. The expected-row count is an optional additive
  `WINDOW_BEGIN` field; updated receivers enforce 0..128 and older v2 receivers
  may ignore it. Legacy ITEM messages remain.
- `loot_service_stages_authoritative_before_consumption` executes real
  `Services/Loot/Service.lua` and proves staging occurs before `Remove`.
- `loot_award_attribution_event_order_is_atomic` executes real
  `LootAttribution.lua` for both chat-first and slot-first order, including
  duplicate confirmation and stale grace callback checks.
- `loot_award_event_orders_share_full_production_chain` verifies one canonical
  record, exact pending cleanup, one execution of each checkpoint, harmless
  stale callbacks, released in-flight ownership, and immediate next admission
  for both orders without split fake/manual reconciliation.

## Commit Coherence For `04163f5..HEAD`

- 14 existing runtime Lua files changed: 13 owners plus English localization.
- All changed owners were already referenced by the authoritative TOC; their
  services load before `Controllers\Master.lua`.
- No TOC, XML, frame identity, registry entry, public namespace, slash command,
  or SavedVariables schema changed.
- Exactly six SavedVariables remain declared: `RMA_Raids`, `RMA_Players`,
  `RMA_Reserves`, `RMA_Warnings`, `RMA_Spammer`, `RMA_Options`.
- No untracked runtime files, deleted runtime references, or `Libs/` changes.
- Localization owns all new visible text; XML handler scan remains empty.
- Runtime transaction/evidence state is not persisted. The only wire change is
  the compatible optional RMADist v2 expected-row field.

## Fresh Gates

- `py -3 -m unittest tests.test_loot_distribution_hardening_behavior -q`: PASS,
  31 focused tests.
- `py -3 -m unittest tests.test_runtime_bootstrap_contract tests.test_loot_bans_contract -q`:
  PASS, 48 contract/regression tests.
- `py -3 -m unittest discover -s tests -q`: PASS, 234 tests in 6.883s.
- TOC validator: PASS, 0 errors / 0 warnings.
- Lua 5.1 validator: PASS, 134 files clean.
- variadic `xpcall` scan: PASS, 134 files clean.
- XML handler scan: PASS, no matches (raw `rg` exit 1).
- whole-addon `luacheck` excluding `Libs/**`: PASS, 121 files, 0 warnings / 0 errors.
- `git diff --check 04163f5`: PASS; only configured LF-to-CRLF notices.
- `tools/check-rma.ps1`: absent, not run.
- scoped `stylua --check` on the 14 changed runtime files: NON-BLOCKING exit 1;
  it proposes whole-file CRLF-to-LF normalization and existing broad formatting
  changes. No formatting rewrite was applied.

## Residual Risk

The remaining risks require the final live WotLK test: protected
`GiveMasterLoot`, live slot-clear/loot-window ordering, bag and partner evidence
after trade close, mixed-client RMADist delivery, visible cancellation feedback,
and reload/crash during the runtime-only irreversible/uncertain interval.

runtime smoke: deferred by user until the full refactoring program is complete
