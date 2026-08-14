# Risk-Guided Rework Simplification Design

**Date:** 2026-07-13
**Status:** Approved in conversation; pending document review
**Historical root:** `78a60c4a9ebced8243297ff731afe036b52f6903`
**Implementation baseline:** `d4029e7`
**Implementation branch:** `codex/rework-simplification`

## 1. Purpose

Simplify the risk-guided addon rework without discarding the reliability and
data-integrity improvements that motivated it.

The audit covered every descendant from `rework-addon` (`78a60c4`) through the
coherent loot baseline (`d4029e7`), the experimental hardening head
(`727ceb8`), and its interrupted uncommitted changes. The result is selective:
the integrated rework contains several justified owners and transactional
boundaries, while the loot recovery work after `d4029e7` requires substantial
removal.

This is not a greenfield rewrite. Work starts from `d4029e7` and proceeds as
small, reversible simplification batches.

## 2. Priorities

Priorities remain, in order:

1. runtime reliability and data integrity;
2. architectural maintainability;
3. performance;
4. user experience.

Simplicity is not allowed to weaken a demonstrated runtime or persistence
invariant. Complexity is retained only where the repository has a concrete
caller, failure boundary, data constraint, or WotLK runtime requirement.

## 3. Stable Contracts

The simplification must not change:

- addon name, folder name, `RMA` short name, `/rma`, or RMA branding;
- Interface `30300`, Lua 5.1 compatibility, or WotLK 3.3.5a API support;
- `RMA_*` SavedVariables names or schemas;
- addon-message prefixes or wire formats;
- public frame identities or XML layout ownership;
- externally visible raid, loot, reserves, logger, warnings, spammer, inspect,
  configuration, diagnostics, and sync workflows;
- required event ordering, persisted revision semantics, or stable IDs;
- validation and resource bounds for untrusted inbound communication.

The work adds no features, migration layers, extension points, or speculative
configuration.

## 4. Branch and History Strategy

`d4029e7` is the implementation baseline because it is the last coherent state
before recovery-of-recovery logic spread across loot owners.

The experimental `codex/loot-distribution-hardening` branch at `727ceb8` and
its uncommitted diff are historical evidence only. They must be archived before
cleanup or deletion, but their runtime changes are not imported wholesale.

Each simplification area is committed independently and must remain safe to
revert. Integration into the user's target branch occurs only after the final
in-game smoke test.

## 5. Architecture Decisions

### 5.1 Options

Replace the namespace-facade enumeration created by `GetNamespaces()` with a
concrete store-owned reset operation. Keep direct option namespace access used
by runtime callers, but remove closure-based facades whose additional methods
exist only for tests.

### 5.2 Dataset activation

`LootSourcesData` and `IgnoredMobs` are the two fixed activation owners. Their
capture/restore contract is mandatory. The coordinator calls that contract
directly and fails fast instead of supporting hypothetical owners through
capability checks and Activate/Deactivate fallbacks.

The last-known-good dataset behavior remains unchanged.

### 5.3 Raid creation and roster state

Raid-session creation uses one transaction boundary. Remove overlapping
insertion/history snapshots within the same Create operation and replace the
family of optional `_...Internal` hooks with the smallest cohesive roster API
needed to capture, restore, reset, and publish roster state.

Append-only import paths may retain the cheaper insertion snapshot because it
has a distinct, demonstrated use.

### 5.4 Raid validation

There must be one canonical policy for validating raid-history structure and
references. Mutation commits use that policy to accept or reject data. The
diagnostic validator may add paths and presentation details, but must not
implement a divergent validity policy.

### 5.5 Logger cleanup

Logger cleanup remains asynchronous and bounded, but its mutation becomes a
single store-owned commit:

1. scan and build a cleanup plan;
2. validate current IDs, revisions, and protected raid identity;
3. build the candidate result detached from canonical history;
4. publish once;
5. emit one completion event.

Do not mutate canonical history and then deep-copy it back on failure. Remove
runtime states such as rollback-uncertain that only arise from the rollback
protocol itself.

### 5.6 Reserves transactions

Reserve mutations and imports preserve canonical values, atomic publication,
cache coherence, bounds, and notification ordering. They do not preserve the
identity of every internal table across rollback when no runtime consumer holds
those references.

Build candidate SavedVariables and derived indexes detached, validate them,
then publish root references and metadata together. Tests assert values,
events, and cache behavior rather than `rawequal` identity.

### 5.7 Sync and communication

Retain:

- authorization and explicit consent;
- sender/request correlation and replay protection;
- request TTLs and terminal lifecycle;
- payload, row, byte, queue, and chunk limits;
- validation before allocation, inflate, import, or publication;
- revision conflict protection.

Remove only unused public test seams and single-use aliases. Security and
resource bounds are not simplification targets.

### 5.8 Inspect scheduling

`InspectCoordinator` remains the shared owner of the global WoW inspect target.
It alone owns global pacing, combat deferral, queue admission, and request
timeout.

The timeout starts when a request becomes active, not when it enters the queue.
`EquipInspect` retains raid/player work, item-information completion, and
snapshot persistence, but loses its second global throttle and combat retry
chain.

### 5.9 Spammer, warnings, and shared text handling

`Spammer.Runtime`, warning storage, and draft normalization remain cohesive
owners. The duplicated UTF-8 safe-prefix implementation moves to the existing
string owner only because it has two proven callers and one stable behavior.
Feature-specific length limits remain local.

### 5.10 Test-only surfaces

Remove or localize public methods and aliases with no runtime caller, including
canonical serialization and request-cancellation seams where behavior can be
tested through the real public workflow.

Tests protect user-visible behavior, external contracts, data invariants, and
rejected unsafe inputs. They do not require temporary facades, private helper
names, exact source layout, or internal table identity.

## 6. Reduced Loot Design

The loot implementation remains based on `d4029e7`. Later commits are treated
as evidence and are not replayed as a series.

### 6.1 Simple admission guards

Retain only demonstrated precondition fixes:

- compare canonical item keys;
- verify the required item count when duplicate copies matter;
- reject a new award while an inventory trade is already in flight;
- perform admission before countdown, UI, or domain mutation.

These checks must be side-effect free.

### 6.2 Session ordering

Implement one small local parser for generated distribution-session IDs. It
validates:

- the encoded authority matches the sender;
- timestamp is finite and non-negative;
- ordinal is a bounded non-negative integer.

Generated sessions are ordered by `(timestamp, ordinal)`. Stale replacements
are rejected. This does not create a new module, registry owner, or public API.

### 6.3 Timer safety

Use a local scheduling helper only at critical timer boundaries. If a required
timer cannot be scheduled:

- terminate the current operation;
- release its ownership and UI state;
- emit one diagnostic or user warning;
- do not create an automatic retry chain.

Award-sequence delay/progress timers and confirmation/attribution deadlines
follow this rule.

### 6.4 Single pending award path

An award may be represented by its attempt plus one pending confirmation or
attribution record appropriate to the current phase. It must not simultaneously
acquire controller admission recovery, terminal-publication recovery,
provisional-capacity ownership, and manual-retry state.

Callback, scheduler, or finalization failure is terminal and observable. The
user may repeat the operation. Remove automatic recovery admission, terminal-
only queues, manual retry APIs, capacity owners, generation counters, and
`retrying`/`exhausted` state families introduced after `d4029e7`.

This deliberately trades automatic recovery from rare transient callback
failures for deterministic cleanup and an understandable user recovery path.

## 7. Mutation and Error Model

All persistent mutations follow:

```text
input -> validation -> detached candidate -> atomic commit -> event/UI
```

Before commit, canonical SavedVariables, runtime indexes, and visible state are
unchanged. After commit, notification or presentation failures are contained
and reported but do not roll back already published canonical data.

Error rules:

- invalid input returns `nil, "reason"` or `false` without mutation;
- stale revision or ownership conflict is rejected without mutation;
- commit failure preserves the previous canonical state;
- critical timer-scheduling failure terminates and cleans up once;
- UI and diagnostic callback failure does not corrupt committed data;
- no indefinite recovery, nested recovery protocol, or rollback-uncertain
  state is introduced.

## 8. Behavior Deltas

| Area | Old behavior | New behavior | Compatibility impact |
|---|---|---|---|
| Loot transient internal failure | Multiple automatic retry and exhausted states after `d4029e7` | Terminal cleanup and one warning; user may retry | No public data or wire change; recovery becomes explicit |
| Inspect timeout | Could start while queued and overlap feature retry pacing | Starts on activation; coordinator owns pacing/combat | Fewer false timeouts; no public API change |
| Logger cleanup failure | Mutate then restore a deep copy, with uncertain rollback states | Detached candidate published once | Same successful result; simpler failure result |
| Reserves rollback | Preserved recursive table identity | Preserves canonical values and coherent roots | No supported consumer impact |
| Internal capability fallback | Continued with partial owner contracts | Required internal dependency fails fast | No supported load-order impact |

No SavedVariables migration is required.

## 9. Verification Strategy

Every batch must include focused behavioral tests before and after the
simplification and run the checks appropriate to its touched files:

- Python unit tests for the affected macro area;
- TOC validation;
- Lua 5.1 syntax validation;
- Lua 5.1 `xpcall` scan;
- XML handler scan;
- retired-branding scan outside vendored libraries;
- `stylua --check` and `luacheck` on touched Lua files;
- `git diff --check`.

After all batches:

1. run the complete automated suite;
2. perform one whole-branch simplicity review;
3. produce a commit-coherence report;
4. run the in-game smoke test;
5. integrate locally only after the user confirms the smoke test.

The smoke test covers login, `/rma`, main frame creation, `/reload`, expected
`RMA_*` persistence, raid recording, loot, reserves, logger, warnings, and
spammer workflows.

## 10. Non-Goals

- No greenfield architecture.
- No feature redesign or new UX workflow.
- No SavedVariables or wire migration.
- No removal of bounded or authorization-sensitive sync protections.
- No deletion of cohesive owners solely to reduce file count.
- No repo-wide formatting rewrite.
- No in-game smoke test before the final integrated candidate.

## 11. Completion Criteria

The rework simplification is complete when:

- all approved simplification batches are committed independently;
- post-`d4029e7` recovery-of-recovery logic is absent;
- required session ordering and timer safety remain behaviorally covered;
- SavedVariables, wire, TOC, XML, and user-visible contracts remain stable;
- the complete automated suite and static validation pass;
- the whole-branch simplicity review has no unresolved required finding;
- the commit-coherence report identifies no stale TOC, registry, or runtime
  reference;
- the user confirms the in-game smoke test;
- only then is the branch integrated locally.
