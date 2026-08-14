# Runtime And Data Foundations Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make addon bootstrap recoverable and make option and raid-history reads preserve validated canonical data without destructive normalization.

**Architecture:** Keep `SavedVariables.lua` as the global persistence boundary, `DBOptions.lua` as the typed option owner, and `DBRaidStore.lua` as the raid mutation owner. Introduce behavior tests through the installed Lua 5.1 runner, then separate admission/migration from read-only validation and queries so unsupported or malformed data cannot be changed by observation.

**Tech Stack:** WoW 3.3.5a, Interface `30300`, Lua 5.1, Python `unittest`, local `lua` runner, `luacheck`, StyLua, and repository WotLK validators.

## Global Constraints

- Preserve addon name `Raid Management Addon`, runtime name `RMA`, `/rma`, and Interface `30300`.
- Preserve the six declared `RMA_*` SavedVariables; do not read or migrate non-RMA globals.
- Preserve existing raid schema and wire formats; this batch does not increment the schema version.
- Use Lua 5.1 syntax and WotLK 3.3.5a APIs only.
- Do not modify vendored libraries under `Raid Management Addon/Libs/`.
- Keep XML layout-only and all runtime text ASCII.
- Preserve the existing uncommitted README changes outside every task commit.
- Record each intentional behavior correction in the plan's final behavior-delta report.

---

### Task 1: Add A Lua Behavior-Test Harness

**Files:**
- Create: `tests/lua_test_runner.py`
- Create: `tests/lua/runtime_harness.lua`
- Create: `tests/test_runtime_foundations_behavior.py`

**Interfaces:**
- Consumes: the `lua` command available on `PATH`, addon chunks loaded with `loadfile`, and the standard `(addonName, addonTable)` varargs used by addon files.
- Produces: `run_lua_case(case_name: str) -> subprocess.CompletedProcess[str]` and isolated Lua cases selected through `arg[1]`.

- [ ] **Step 1: Create the Python runner and an initially failing smoke test**

  Implement `run_lua_case` so it runs `lua tests/lua/runtime_harness.lua <case>`, captures text output, and raises an assertion containing stdout/stderr on nonzero exit. Add `test_harness_executes_lua_51` that requests `lua_51_smoke`.

- [ ] **Step 2: Run the focused test and verify the missing harness case fails**

  Run: `py -3 -m unittest tests.test_runtime_foundations_behavior.RuntimeFoundationsBehaviorTest.test_harness_executes_lua_51 -v`

  Expected: FAIL because `runtime_harness.lua` does not yet recognize `lua_51_smoke`.

- [ ] **Step 3: Implement isolated addon loading in the Lua harness**

  Add assertion helpers, reset `_G.RMA_*` globals between cases, create a minimal addon table with `State`, `Database`, `Services`, `Events`, and `Bus`, and load target files with:

  ```lua
  local chunk = assert(loadfile(path))
  chunk("Raid Management Addon", addon)
  ```

  The `lua_51_smoke` case must assert `_VERSION == "Lua 5.1"` and print `PASS lua_51_smoke`.

- [ ] **Step 4: Run the focused test and the existing suite**

  Run: `py -3 -m unittest tests.test_runtime_foundations_behavior -v`

  Expected: PASS.

  Run: `py -3 -m unittest discover -s tests -p "test_*.py" -v`

  Expected: all existing 56 tests plus the new smoke test pass.

- [ ] **Step 5: Commit the harness**

  Stage only the three new test files and commit:

  ```text
  test(runtime): Add Lua behavior harness
  ```

---

### Task 2: Make Bootstrap Retry-Safe And Event Dispatch Stable

**Files:**
- Modify: `Raid Management Addon/Init.lua`
- Modify: `tests/lua/runtime_harness.lua`
- Modify: `tests/test_runtime_foundations_behavior.py`

**Interfaces:**
- Consumes: `addon:ADDON_LOADED(loadedAddon)` and `addon:RegisterEvent`/`addon:UnregisterEvent`.
- Produces: an initialization transaction that marks completion and unregisters `ADDON_LOADED` only after every required owner succeeds; event dispatch uses a stable listener snapshot for the current notification.

- [ ] **Step 1: Add failing bootstrap and listener-mutation cases**

  Add `bootstrap_retries_after_failure` with a stubbed `SavedVariables.NormalizeAfterLoad` that fails once, then succeeds. Assert the first call leaves `ADDON_LOADED` registered, the second completes initialization, and runtime events are registered exactly once.

  Add `listener_removal_does_not_skip_next` with two listeners on one event. The first unregisters itself. Assert both receive the current event and only the second receives the next event.

- [ ] **Step 2: Verify both cases fail against the baseline**

  Run: `py -3 -m unittest tests.test_runtime_foundations_behavior -v`

  Expected: FAIL showing premature `ADDON_LOADED` removal and a skipped second listener.

- [ ] **Step 3: Refactor initialization into prepare/commit phases**

  In `Init.lua`, keep an `addon.State.initializing` re-entry guard and set `addon.State.initialized` only after all current initialization calls succeed. Clear `initializing` on failure, keep `ADDON_LOADED` registered, and rethrow the original error so diagnostics remain visible. Unregister `ADDON_LOADED` and register steady-state events only in the successful commit phase.

- [ ] **Step 4: Dispatch over a stable listener snapshot**

  Copy the current listener sequence into a reusable scratch array before callbacks run, clear the scratch tail after dispatch, and call the snapshot entries in order. Registration changes made by a callback affect the next event, not the event currently being delivered.

- [ ] **Step 5: Run focused and full verification**

  Run the focused behavior file, the full Python suite, `luacheck "Raid Management Addon/Init.lua"`, the Lua 5.1 validator, and the `xpcall` scanner.

  Expected: all commands pass with no Lua 5.1 violations.

- [ ] **Step 6: Commit the recoverability fix**

  Commit the focused tests and `Init.lua` as:

  ```text
  fix(runtime): Make bootstrap and dispatch retry-safe
  ```

---

### Task 3: Enforce Typed And Isolated Option Defaults

**Files:**
- Modify: `Raid Management Addon/Database/DBOptions.lua`
- Modify: `tests/lua/runtime_harness.lua`
- Modify: `tests/test_runtime_foundations_behavior.py`
- Modify: `docs/SAVED_VARIABLES.md`

**Interfaces:**
- Consumes: `Options.RegisterNamespace(name, defaults)`, namespace `Get`, `Set`, `ResetDefaults`, and `Options.EnsureLoaded`.
- Produces: recursive copies of table defaults, type-normalized persisted values, collision rejection, and an immutable namespace-registry snapshot.

- [ ] **Step 1: Add failing option-corruption cases**

  Cover these exact behaviors:

  - persisted string `"false"` for a boolean default becomes the boolean default;
  - persisted `false` remains `false`;
  - a mutated nested table returned from storage does not mutate `_defaults`, and `ResetDefaults` creates a clean independent table;
  - duplicate ownership of the same option key across namespaces raises a stable error;
  - mutating the result of `GetNamespaces()` cannot change registered namespaces or `GetByKey` results.

- [ ] **Step 2: Verify the option cases fail**

  Run: `py -3 -m unittest tests.test_runtime_foundations_behavior -v`

  Expected: FAIL for type corruption, default aliasing, silent collision, and mutable registry exposure.

- [ ] **Step 3: Add a cycle-safe option-value copier**

  Replace the shallow default copy path with a local recursive copier that preserves scalar values, copies keys and values, and uses a `seen` table. Use it when registering defaults, applying missing/defaulted values, returning `All()`, resetting defaults, and returning registry metadata.

- [ ] **Step 4: Normalize persisted values during load**

  For every registered key, retain a stored value only when its Lua type matches the declared default type. Replace mismatches with a copied default. Preserve valid `false`. Remove unknown string keys from strict storage; also remove non-string keys so `RMA_Options` contains only registered option names.

- [ ] **Step 5: Reject ambiguous ownership**

  During `RegisterNamespace`, reject a key already owned by a different namespace. Permit same-namespace extension only for a new key; reject an incompatible repeated declaration instead of silently keeping the old default.

- [ ] **Step 6: Document the normalization behavior and verify**

  Update `docs/SAVED_VARIABLES.md` to state that invalid option types and unknown keys are reset during admission without reading any non-RMA data. Run focused tests, the full suite, `luacheck` on `DBOptions.lua`, StyLua focused check, and `git diff --check`.

- [ ] **Step 7: Commit typed option admission**

  Commit as:

  ```text
  fix(options): Normalize persisted values safely
  ```

---

### Task 4: Reject Future Raid Schemas Without Mutation

**Files:**
- Modify: `Raid Management Addon/Database/DBRaidStore.lua`
- Modify: `Raid Management Addon/Database/DBRaidMigrations.lua`
- Modify: `Raid Management Addon/Database/DBRaidQueries.lua`
- Modify: `Raid Management Addon/Database/DBRaidValidator.lua`
- Modify: `tests/lua/runtime_harness.lua`
- Modify: `tests/test_runtime_foundations_behavior.py`
- Modify: `docs/SAVED_VARIABLES.md`

**Interfaces:**
- Consumes: raid records with `schemaVersion` and `Database.GetRaidSchemaVersion()`.
- Produces: `NormalizeRaidRecord` returns `nil, "unsupported raid schema"` for future records without changing them; validators report `SCHEMA_VERSION_FUTURE`; queries reject unsupported records without mutation.

- [ ] **Step 1: Add a deep-equality future-schema regression case**

  Build a future-schema raid containing fields unknown to the current addon, duplicate-looking IDs, and explicit attendance. Deep-copy it, then call normalization, one query, validation, and save preparation independently. Assert every call leaves the original deeply equal to its copy and returns the future-schema error or validation detail.

- [ ] **Step 2: Verify destructive normalization occurs on the baseline**

  Run the focused future-schema test.

  Expected: FAIL because current normalization rewrites canonical collections even when `schemaVersion` is newer.

- [ ] **Step 3: Gate admission before migrations or normalization**

  In `NormalizeRaidRecord`, parse the stored version before any table creation, ID allocation, cache construction, or migration. Return `nil, "unsupported raid schema"` when it exceeds the current version. Make `MigrateRaidToCurrentSchema` return the same stable failure if called directly with a future version.

- [ ] **Step 4: Propagate rejection through callers**

  Queries must not normalize unsupported input. Validator must inspect and report the future version without calling the normalizer. Save preparation must skip mutation of unsupported records and return a failure that `PrepareAllRaidsForSave` reports without altering the record.

- [ ] **Step 5: Document forward-schema preservation and verify**

  State in `docs/SAVED_VARIABLES.md` that data written by a newer RMA schema is preserved untouched and rejected for mutation by older builds. Run focused/full tests and all database-file validators.

- [ ] **Step 6: Commit forward-schema protection**

  Commit as:

  ```text
  fix(database): Preserve future-schema raid data
  ```

---

### Task 5: Make Raid Validation And Queries Read-Only

**Files:**
- Modify: `Raid Management Addon/Database/DBRaidStore.lua`
- Modify: `Raid Management Addon/Database/DBRaidQueries.lua`
- Modify: `Raid Management Addon/Database/DBRaidValidator.lua`
- Modify: `tests/lua/runtime_harness.lua`
- Modify: `tests/test_runtime_foundations_behavior.py`
- Modify: `docs/ARCHITECTURE.md`

**Interfaces:**
- Consumes: admitted canonical raid records and raw records supplied to diagnostics.
- Produces: query functions that never alter canonical fields; a raw validator that reports duplicate IDs, low counters, and invalid references; explicit empty boss attendance remains empty.

- [ ] **Step 1: Add failing read-only and raw-validation cases**

  For each public query (`GetRaidSummary`, `GetBossKills`, `GetRaidAttendance`, `GetBossAttendance`, and `GetLoot`), snapshot the input and assert deep equality after the call. Add validator cases for duplicate player/boss/loot IDs, counters below maxima, invalid attendee IDs, invalid looter IDs, and malformed rows. Add separate cases proving an explicit empty boss `players = {}` stays empty while an absent legacy `players` field may be inferred during explicit migration.

- [ ] **Step 2: Verify current queries mutate and validator hides defects**

  Run the focused database cases.

  Expected: FAIL because queries normalize records and validation repairs its clone before inspection.

- [ ] **Step 3: Separate admission from runtime-index preparation**

  Keep schema migration and canonical repair in the explicit store admission path. Give queries a read-only accessor that can use an existing valid `_runtime` index or build a transient index without assigning canonical IDs, clearing fields, or changing counters.

- [ ] **Step 4: Validate raw structures before any repair**

  Replace `ensureNormalizedClone` as the validator entry path with typed, non-mutating traversal of raw players, bosses, loot, and attendance. Track seen IDs and maxima locally, emit existing detail shapes plus stable codes for duplicates and invalid references, and never call `NormalizeRaidRecord` from validation.

- [ ] **Step 5: Preserve explicit empty attendance**

  In explicit migration/normalization, infer boss attendance only when the legacy `players` field is absent. An empty table is a canonical empty set. If every supplied reference is invalid, keep the filtered set empty and let validation report the invalid references rather than replacing it with the roster.

- [ ] **Step 6: Update architecture documentation and verify**

  Document admission versus query/validation ownership in `docs/ARCHITECTURE.md`. Run focused/full tests, database-file `luacheck`, focused StyLua checks, TOC/Lua/xpcall validators, and `git diff --check`.

- [ ] **Step 7: Commit read-only database observation**

  Commit as:

  ```text
  refactor(database): Separate admission from observation
  ```

---

### Task 6: Produce The Foundation Batch Coherence Report

**Files:**
- Create: `docs/RUNTIME_DATA_FOUNDATIONS_REPORT.md`
- Modify: `docs/VALIDATION.md` only if the actual commands differ from the documented gate.

**Interfaces:**
- Consumes: final task diffs, test results, TOC, runtime file list, and behavior changes.
- Produces: a reviewable batch report with behavior deltas, validation evidence, unchanged external contracts, and residual client-only risks.

- [ ] **Step 1: Run the complete validation matrix**

  Run:

  ```powershell
  py -3 -m unittest discover -s tests -p "test_*.py" -v
  py -3 .agents\skills\wow-addon-dev-wotlk-v335a\scripts\validate_toc.py "Raid Management Addon\Raid Management Addon.toc"
  py -3 .agents\skills\wow-addon-dev-wotlk-v335a\scripts\lint_lua51.py "Raid Management Addon"
  py -3 .agents\skills\wow-addon-dev-wotlk-v335a\scripts\scan_xpcall.py "Raid Management Addon"
  rg -n "<Scripts>|<On[A-Za-z]+>" "Raid Management Addon\UI" -g "*.xml"
  luacheck "Raid Management Addon" --exclude-files "Raid Management Addon/Libs/**"
  git diff --check
  git status --short --branch
  ```

  Expected: tests and validators pass; the XML search returns no matches; only the preserved README edits or intentional batch files remain visible.

- [ ] **Step 2: Review external and persistence contracts**

  Confirm no changes to TOC SavedVariables, `/rma`, addon-message prefixes, schema version, XML frame identities, or vendored files. Confirm every changed runtime file is TOC-referenced and no deleted owner remains referenced.

- [ ] **Step 3: Write behavior deltas and residual risks**

  Record bootstrap retry behavior, invalid option normalization, future-schema rejection, read-only queries/validation, explicit empty attendance, commands run, and the required statement `runtime smoke: not run; manual acceptance pending` unless a real client smoke was performed.

- [ ] **Step 4: Commit the coherence report**

  Commit as:

  ```text
  docs(database): Record foundation batch verification
  ```

## Follow-On Plans

After this plan is green, create and approve separate implementation plans for:

1. raid recording, logger reconciliation, and attendance;
2. loot, rolls, award, and trade effect safety;
3. sync authorization, bounded assembly, revision monotonicity, and atomic import;
4. reserves, warnings, spammer, inspection, and datasets;
5. controller/widget composition, measured performance work, and raid UX.

The synchronization plan must begin with the confirmed fail-open responder grace window, unsolicited PUSH persistence, non-atomic imports, stale revision overwrites, unbounded chunks/payloads, and outsider whisper disclosure. Snapshot merge-versus-replace semantics require an explicit product decision before implementation.
