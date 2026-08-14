# Runtime And Data Foundations Coherence Report

## Scope

This report covers the runtime-data-foundations batch from baseline `2cb1184`
through the final batch head. The batch changes bootstrap/event
recovery, option admission, raid-record admission, validation, and queries. It
does not change user-facing feature scope or wire formats.

## Behavior Deltas

### Bootstrap and event dispatch

- Old behavior: a failed `ADDON_LOADED` path could leave initialization marked
  complete or remove the retry event too early; listener removal during a
  dispatch could skip another listener, and nested dispatch or reporting
  failures could corrupt the reusable dispatch snapshot.
- New behavior: initialization uses prepare/commit state, keeps
  `ADDON_LOADED` available after failure, commits steady-state events once, and
  cleans retry state before rethrowing. Each dispatch uses an isolated stable
  snapshot whose registration changes apply to the next notification.
- Reason: runtime safety and recoverability. The old behavior was unsafe after
  partial initialization or callback mutation.
- Compatibility and migration: successful startup order is restored: all
  steady-state runtime events register and the debug registration report
  completes before `RAID_ROSTER_UPDATE(true)`. Retry and rollback retain the
  Task 2 guarantees; no persisted-data migration is involved.
- Evidence: successful-order, bootstrap retry, commit failure, listener
  removal, nested dispatch, and reporting-failure behavior tests pass.

### Typed option admission

- Old behavior: persisted values with the wrong Lua type could survive, nested
  table defaults could alias mutable storage, duplicate key ownership was
  ambiguous, and namespace registry state was exposed.
- New behavior: registered defaults are copied recursively and cycle-safely;
  wrong-type and unknown persisted values are normalized during admission;
  valid `false` values remain valid; conflicting ownership and incompatible
  redeclarations are rejected; registry/query snapshots do not expose internal
  tables.
- Reason: data integrity and deterministic ownership. The old behavior was
  corruptible and ambiguous.
- Compatibility and migration: registered values of the declared type are
  retained. Invalid or unknown `RMA_Options` entries are intentionally removed
  or reset to defaults on load. No non-RMA data is read.
- Evidence: option type, aliasing, cycle, ownership, extension, redeclaration,
  namespace snapshot, and facade behavior tests pass.

### Future raid schemas

- Old behavior: records written with a newer `schemaVersion` could enter repair
  or migration paths and be mutated by an older addon build.
- New behavior: admission, direct migration, queries, validation, and save
  preparation reject future-schema records before mutation. Validation reports
  `SCHEMA_VERSION_FUTURE`, and save failure stops subsequent reserves save work.
- Reason: forward-data safety. Destructive downgrade behavior was unsafe.
- Compatibility and migration: the current raid schema version is unchanged;
  current and older admitted records retain their existing migration path.
  Newer records remain stored untouched until a compatible build is used.
- Evidence: deep preservation across all five public query APIs, unchanged
  caller output buffers on rejection, future-schema diagnostics, and save
  short-circuit behavior tests pass.

### Read-only observation and explicit attendance

- Old behavior: queries normalized canonical records and validation inspected a
  repaired clone, which could hide raw defects. Explicit empty boss attendance
  could be inferred back to the full roster.
- New behavior: query-time indexes are transient/read-only, returned rows and
  reusable output buffers cannot alias canonical data, malformed collections
  are guarded, and validation traverses raw sparse or mapped data to report
  duplicate IDs, low counters, malformed rows, and invalid references. Boss
  attendance is inferred only when the legacy field is absent; an explicit
  empty table remains empty.
- Reason: reliable diagnostics, non-destructive reads, and correct empty-set
  semantics. The previous observation path was both mutating and lossy.
- Compatibility and migration: public query purposes and result shapes remain;
  malformed or unsupported input may now return empty/error results instead of
  being silently repaired. Explicit migration remains the only repair path.
- Evidence: all public query immutability, fresh-index, output-alias,
  malformed-collection, raw-validation, and explicit-empty-attendance tests
  pass.

## Contract And Changed-File Coherence

- `Raid Management Addon.toc` is byte-unchanged in this batch. Interface
  `30300`, the six SavedVariables (`RMA_Raids`, `RMA_Players`, `RMA_Reserves`,
  `RMA_Warnings`, `RMA_Spammer`, and `RMA_Options`), and load order are
  unchanged.
- `/rma`, addon-message prefixes, raid schema version, sync payload format, and
  XML frame identities are unchanged. The only slash-entry change accepts the
  new future-schema diagnostic code while retaining the legacy formatter code.
- No XML or vendored `Libs/` file changed in the batch.
- Changed runtime files are `Init.lua`, `Database/SavedVariables.lua`,
  `Database/DBOptions.lua`, `Database/DBRaidMigrations.lua`,
  `Database/DBRaidStore.lua`, `Database/DBRaidQueries.lua`,
  `Database/DBRaidValidator.lua`, and `EntryPoints/SlashEvents.lua`. Every file
  is present in the unchanged TOC. No runtime file was added, deleted, or left
  unreferenced.
- Documentation changes describe the new persistence and admission/observation
  boundaries. The two README files are unchanged by this worktree and report.
- `docs/VALIDATION.md` was reconciled with the actual static gate by adding the
  required Python unittest discovery command, whole-addon `luacheck` command,
  and an explicit note that `tools/check-rma.ps1` is absent. The ignored
  `.agents` skill directory is not materialized inside Git worktrees, so the
  three validator scripts were invoked from the parent checkout
  (`..\..\.agents\...`) against this worktree. This is a path-location
  substitution, not a gate change.

## Fresh Validation Evidence

Run from `.worktrees/runtime-data-foundations` after the Task 6 review fix on
2026-07-12:

| Command | Result |
|---|---|
| `py -3 -m unittest discover -s tests -p "test_*.py" -v` | PASS: 82 tests in 1.007s |
| `py -3 ..\..\.agents\skills\wow-addon-dev-wotlk-v335a\scripts\validate_toc.py "Raid Management Addon\Raid Management Addon.toc"` | PASS: 0 errors, 0 warnings in 1 file |
| `py -3 ..\..\.agents\skills\wow-addon-dev-wotlk-v335a\scripts\lint_lua51.py "Raid Management Addon"` | PASS: 132 files clean |
| `py -3 ..\..\.agents\skills\wow-addon-dev-wotlk-v335a\scripts\scan_xpcall.py "Raid Management Addon"` | PASS: 132 files clean of variadic `xpcall` |
| `rg -n "<Scripts>\|<On[A-Za-z]+>" "Raid Management Addon\UI" -g "*.xml"` | PASS: no matches (`rg` exit 1, expected for this negative scan) |
| `luacheck "Raid Management Addon" --exclude-files "Raid Management Addon/Libs/**"` | PASS: 0 warnings, 0 errors in 119 files |
| `git diff --check` | PASS: no output |
| `git status --short --branch` | PASS: clean branch before report creation (`## codex/runtime-data-foundations`) |

The brief's worktree-local `.agents` command was also attempted and failed
because that ignored directory does not exist inside the worktree; no validator
failure occurred. The parent-checkout commands above are the completed matrix.
There is no `tools/check-rma.ps1` in this batch and no such result is claimed.

## Residual Risks And Manual Acceptance

- Offline tests cannot prove WoW event timing, protected-action behavior,
  SavedVariables serialization across `/reload`, or interaction with live raid
  records and server addon-message delivery.
- The changed error/retry paths should be exercised with an injected startup
  failure and a subsequent retry in the 3.3.5a client if practical.
- Option normalization and future-schema preservation should be smoke-tested
  with disposable SavedVariables copies before using representative user data.
- Query and validation output should be checked from `/rma validate` against a
  representative raid history, including an explicitly empty boss-attendance
  record.

runtime smoke: not run; manual acceptance pending

## Task 6 Review-Fix Evidence

The Task 6 review found that the Task 2 transaction had moved the initial
`RAID_ROSTER_UPDATE(true)` ahead of successful event registration and its debug
report. A focused regression failed on review head `55ab660` because `roster`
was observed before the first steady-state `register`. The runtime order was
restored without changing the existing cleanup transaction: any later failure
still unregisters events committed by that attempt, restores `ADDON_LOADED`
when needed, clears `State.initializing`, and rethrows the original error.

Validation evidence for the atomic review fix is recorded in the table above
after rerunning the complete matrix on the final fix working tree.
