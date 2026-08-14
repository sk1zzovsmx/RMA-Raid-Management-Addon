# Loot Bans Optimization Audit Design

## Objective

Verify the complete Loot Bans implementation and apply only conservative,
demonstrable optimizations that preserve its approved behavior, public addon
contract, persisted data, wire formats, UI, and WotLK 3.3.5a compatibility.

The audit must separate measured improvements from theoretical cleanup. Code
reduction is useful only when it lowers runtime cost, ownership ambiguity, or
maintenance risk without weakening a behavior or validation boundary.

## Binding Behavior

The audit must preserve:

- realm-scoped optional `RMA_Players[realm][playerName].lootBan` metadata;
- the 240-ASCII-character optional note contract;
- fail-closed reads of malformed persisted ban records;
- local-only administrative state with no addon-message synchronization;
- visible pre-banned rolls with their numeric value and Info tag `BAN`;
- `BLK` for unrelated ineligible responses;
- no transient eligible state for a recorded banned roll;
- ordinary structural-denial precedence for submission, and `LOOT_BAN`
  precedence for non-submission sync and winner validation;
- duplicate roll limits and transactional History/tracker/event consistency;
- final ban guards on loot-window awards, delayed multi-awards, and inventory
  trades;
- generic RaidGrid `entry.iconOverride` behavior;
- Loot Ban editor, gray names, pass icons, tooltips, current-state Attendance,
  and reusable-row restoration;
- RMA identity, `/rma`, `RMA_*`, Interface `30300`, Lua 5.1, WotLK 3.3.5a,
  XML layout-only policy, and existing frame/wire identities.

## Audit Boundaries

### Persistent Domain

Review `Services/Raid/LootBans.lua` for normalization, validation, lookup cost,
record ownership, fail-closed behavior, and event publication. It must remain
the only runtime writer of `lootBan` metadata.

### Roll Lifecycle

Review eligibility, submission, blocked-response materialization, History
transactions, tracker forwarding, duplicate handling, Info projection,
visibility, winner resolution, and tie exclusion. Optimization must not weaken
transactional atomicity or change reason precedence.

### Award And Trade

Review single award, initial and delayed multi-award, and inventory trade
guards. Similar code may be consolidated only if the resulting owner remains
clear and every physical effect boundary retains a final check.

### UI

Review RaidGrid projection, popup behavior, Attendance icon/hotspot ownership,
tooltip composition, name-cell layout, refresh events, and reused row/button
state. UI optimization must not add XML scripts, polling, or persistence.

### Tests And Load Order

Review executable Lua harnesses, structural contracts, duplication, TOC order,
and dependency assertions. Test cleanup must retain the ability to detect the
historical popup, transient eligibility, transaction-forwarding, tooltip,
icon-reuse, and column-geometry regressions.

## Candidate Classification

Each candidate is classified on five axes:

1. Correctness: inconsistent state, bypass, missing guard, or unprotected
   behavior.
2. Runtime: repeated lookup, normalization, allocation, scan, or redraw in a
   frequent path.
3. Ownership: duplicated policy or persistence access outside its owner.
4. Complexity: branching or contracts more complicated than required.
5. Tests: redundant harness code or implementation-only assertions that fail
   to protect behavior.

An optimization is applied only when it:

- has a concrete benefit supported by code evidence or measurement;
- preserves every binding behavior above;
- is small, cohesive, reversible, and independently reviewable;
- has RED/GREEN coverage or a reproducible before/after measurement;
- introduces no pass-through wrapper, compatibility alias, catch-all helper,
  or speculative feature.

Candidates with low ROI, ambiguous ownership, or behavior risk are rejected
and recorded rather than implemented.

## Baseline And Measurements

Before edits, record:

- current branch and dirty state;
- full and Loot Bans-focused test counts;
- TOC/Lua 5.1/`xpcall`/Luacheck/XML validation results;
- changed-slice Lua and Python SLOC;
- occurrences of `LootBans.Get`, `LootBans.IsActive`, `LOOT_BAN`, tooltip
  bindings, and persistent `lootBan` writes;
- caller maps for persistence, roll intake, award/trade, and UI refresh.

After each accepted patch, rerun focused gates and update the measured delta.
The final report must distinguish executed reduction from theoretical
potential and must not use line count alone as justification.

## Likely Candidates To Verify

The initial candidate list is investigative, not pre-approved implementation:

- repeated note length/ASCII scans or name normalization;
- repeated Loot Ban lookups in hot award, trade, roll, and UI paths;
- duplicated final-guard warning composition;
- complexity introduced by submission-only eligibility and transactional roll
  intake;
- duplicated Attendance tooltip/click plumbing;
- redundant setup in the Loot Bans Lua behavioral harness.

Each may be retained unchanged if measurement or ownership review shows that
consolidation would reduce clarity or weaken a boundary.

## Verification

Every applied batch must pass its focused behavior tests. Final static
verification must account for:

- `py -3 -m unittest discover -s tests -p "test_*.py" -v`;
- `tools/check-rma.ps1` when present;
- `stylua --check` and `luacheck`, with unavailable tools or repository EOL
  drift reported honestly;
- TOC validation;
- Lua 5.1 validation;
- Lua 5.1 variadic `xpcall` scan;
- XML handler scan;
- persistent-writer ownership scan;
- stale branding scan;
- `git diff --check` and final status.

Manual WotLK acceptance remains separate and includes the editor popup, pass
icons, tooltips, `/reload` persistence, visible `BAN` rolls, blocked awards,
delayed multi-awards, and inventory trades. Static completion is not evidence
that this smoke was run.

## Completion Report

The final report must include:

- the boundary/caller map;
- baseline and final measurements;
- verified findings and fixes;
- accepted optimizations and their measured benefit;
- rejected candidates with reasons;
- validation commands run or unavailable;
- manual smoke status;
- residual risks.

The audit is complete when all applied changes are behavior-preserving, every
binding invariant remains covered, and no unmeasured optimization claim is
presented as fact.
