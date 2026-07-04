# RMA DB Validation Query Optimization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reduce avoidable database validation and query work without changing persisted `RMA_*` data shape or user-visible raid results.

**Architecture:** Database ownership stays split by existing responsibility: validator validates records, queries read canonical stores and runtime indexes, migrations evolve saved data only when required. This batch adds characterization tests first, then applies local micro-optimizations only where outputs remain byte-for-byte compatible.

**Tech Stack:** Lua 5.1, RMA `Database/*` modules, Python source and behavior tests, existing RMA validation scripts.

---

## File Structure

- Modify: `Raid Management Addon/Database/DBRaidValidator.lua`
  - Cache string helpers and avoid avoidable temporary tables where validation output stays identical.
- Modify: `Raid Management Addon/Database/DBRaidQueries.lua`
  - Prefer existing runtime indexes for repeated lookups; do not persist new derived data.
- Modify: `Raid Management Addon/Database/DBRaidMigrations.lua`
  - Skip expensive migration/compaction work when records are already at the current schema version and have no migration work.
- Create: `tests/test_db_validation_query_optimization_contract.py`
  - Verifies no non-RMA SavedVariables, no schema-version bump without explicit migration, stable public query methods, and optimization helpers.

## Public Contract

- No new SavedVariables names.
- No migration from non-RMA keys.
- No schema-version bump unless a migration body and tests are added in the same batch.
- Query outputs remain compatible for existing callers.
- Validation error codes and diagnostic keys remain stable unless a documented behavior delta is added.

## Task 1: Add Contract Tests

**Files:**
- Create: `tests/test_db_validation_query_optimization_contract.py`
- Read: `Raid Management Addon/Database/DBRaidValidator.lua`
- Read: `Raid Management Addon/Database/DBRaidQueries.lua`
- Read: `Raid Management Addon/Database/DBRaidMigrations.lua`

- [ ] **Step 1: Write the failing test**

```python
from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[1]
DB = ROOT / "Raid Management Addon" / "Database"
VALIDATOR = DB / "DBRaidValidator.lua"
QUERIES = DB / "DBRaidQueries.lua"
MIGRATIONS = DB / "DBRaidMigrations.lua"


def read(path):
    return path.read_text(encoding="utf-8")


def test_validator_caches_hot_string_helpers():
    src = read(VALIDATOR)
    assert "local strsub = string.sub" in src


def test_queries_prefer_runtime_indexes_for_hot_lookup_paths():
    src = read(QUERIES)
    assert "runtime" in src
    assert "ByNid" in src or "byNid" in src
    assert re.search(r"function\s+.*Get.*By.*\(", src)


def test_migrations_have_current_schema_fast_path():
    src = read(MIGRATIONS)
    assert "currentSchemaVersion" in src or "CURRENT_SCHEMA_VERSION" in src
    assert "alreadyCurrent" in src or "isCurrentSchema" in src


def test_no_non_rma_savedvariables_are_introduced():
    combined = "\n".join(read(path) for path in (VALIDATOR, QUERIES, MIGRATIONS))
    forbidden = ("KRT_", "Karazhan", "KaraRaid", "KRaid")
    for token in forbidden:
        assert token not in combined
```

- [ ] **Step 2: Run the test and verify RED**

Run:

```powershell
py -3 -m unittest tests.test_db_validation_query_optimization_contract
```

Expected: FAIL on at least one optimization marker because this batch has not been implemented.

## Task 2: Optimize Validator Hot Paths Conservatively

**Files:**
- Modify: `Raid Management Addon/Database/DBRaidValidator.lua`
- Test: `tests/test_db_validation_query_optimization_contract.py`

- [ ] **Step 1: Cache string helpers at file scope**

Near existing local aliases, add:

```lua
local strsub = string.sub
local strlen = string.len
```

- [ ] **Step 2: Replace hot `string.sub` calls**

For validation loops that repeatedly inspect source keys or IDs, replace:

```lua
local prefix = string.sub(sourceKey, 1, 4)
```

with:

```lua
local prefix = strsub(sourceKey, 1, 4)
```

Only apply this in loops or helpers called per raid/player/loot row. Do not mechanically rewrite unrelated one-off calls.

- [ ] **Step 3: Keep validation result shape identical**

If a helper currently returns:

```lua
return false, {
    code = "invalid_source",
    details = details,
}
```

keep the same return shape. Do not flatten or rename `code`, `details`, `field`, or localized diagnostic keys in this batch.

- [ ] **Step 4: Run focused test**

```powershell
py -3 -m unittest tests.test_db_validation_query_optimization_contract
```

Expected: validator helper assertion PASS.

## Task 3: Prefer Existing Runtime Indexes in Query Paths

**Files:**
- Modify: `Raid Management Addon/Database/DBRaidQueries.lua`
- Test: `tests/test_db_validation_query_optimization_contract.py`

- [ ] **Step 1: Identify one hot lookup that scans a table despite an index**

Use this command:

```powershell
rg -n "for .*pairs|for .*ipairs|ByNid|byNid|runtime" "Raid Management Addon\Database\DBRaidQueries.lua"
```

Expected: output shows scan-based query helpers and any existing runtime indexes.

- [ ] **Step 2: Add indexed fast path without changing fallback behavior**

For a lookup by stable player or raid identifier, use this pattern:

```lua
local runtime = raid and raid.runtime
local byNid = runtime and runtime.playersByNid
if byNid and nid then
    local indexed = byNid[nid]
    if indexed then
        return indexed
    end
end

for i = 1, #players do
    local player = players[i]
    if player and player.nid == nid then
        return player
    end
end
return nil
```

Use the exact index table names already present in the repository. Do not create persisted indexes under `RMA_Raids`.

- [ ] **Step 3: Run focused test**

```powershell
py -3 -m unittest tests.test_db_validation_query_optimization_contract
```

Expected: query optimization assertion PASS.

## Task 4: Add Current-Schema Migration Fast Path

**Files:**
- Modify: `Raid Management Addon/Database/DBRaidMigrations.lua`
- Test: `tests/test_db_validation_query_optimization_contract.py`

- [ ] **Step 1: Add a local predicate**

Use the existing schema-version constant name in the file:

```lua
local function isCurrentSchema(raid)
    return raid and raid.schemaVersion == CURRENT_SCHEMA_VERSION
end
```

If the file uses `currentSchemaVersion` instead of `CURRENT_SCHEMA_VERSION`, use that exact name.

- [ ] **Step 2: Guard the migration entry point**

At the start of the raid migration function, after nil/type validation:

```lua
if isCurrentSchema(raid) then
    return raid, false
end
```

Return the same tuple shape already used by the function. If current code returns `changed` first, preserve that order exactly.

- [ ] **Step 3: Run focused test**

```powershell
py -3 -m unittest tests.test_db_validation_query_optimization_contract
```

Expected: migration fast-path assertion PASS.

## Task 5: Run Full Validation

**Files:**
- Read: `Raid Management Addon/Database/DBRaidValidator.lua`
- Read: `Raid Management Addon/Database/DBRaidQueries.lua`
- Read: `Raid Management Addon/Database/DBRaidMigrations.lua`
- Read: `tests/test_db_validation_query_optimization_contract.py`

- [ ] **Step 1: Verify no SavedVariables or schema drift**

```powershell
git diff -- "Raid Management Addon\Database\DBRaidValidator.lua" "Raid Management Addon\Database\DBRaidQueries.lua" "Raid Management Addon\Database\DBRaidMigrations.lua"
```

Expected: no new `RMA_*` keys, no non-RMA keys, no schema-version bump without migration tests.

- [ ] **Step 2: Run tests and validators**

```powershell
py -3 -m unittest discover -s tests
py -3 .agents/skills/wow-addon-dev-wotlk-v335a/scripts/validate_toc.py "Raid Management Addon\Raid Management Addon.toc"
py -3 .agents/skills/wow-addon-dev-wotlk-v335a/scripts/lint_lua51.py "Raid Management Addon"
py -3 .agents/skills/wow-addon-dev-wotlk-v335a/scripts/scan_xpcall.py "Raid Management Addon"
luacheck "Raid Management Addon"
git diff --check
```

Expected: all commands PASS.

## Acceptance Criteria

- Validator hot paths avoid repeated global string lookups.
- Query hot paths use existing runtime indexes before falling back to scans.
- Current-schema migrations return early without rewriting persisted raid data.
- No SavedVariables, wire, UI, XML, TOC, slash command, or addon-message changes.
- Focused test and repository gates pass.
