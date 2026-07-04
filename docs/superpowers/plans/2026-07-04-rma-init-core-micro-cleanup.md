# RMA Init Core Micro Cleanup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Apply low-risk `Init.lua` and core registration micro-cleanups without changing addon identity, slash commands, SavedVariables, or load order.

**Architecture:** `Init.lua` remains the bootstrap owner. This batch only removes repeated tiny work and clarifies registration helpers where existing callers already share the same pattern; it does not split files or redesign bootstrap.

**Tech Stack:** Lua 5.1, WotLK 3.3.5a globals, existing RMA bootstrap/module registry, Python source-characterization tests, RMA validation scripts.

---

## File Structure

- Modify: `Raid Management Addon/Init.lua`
  - Cache hot globals, simplify event seed counts, and keep addon identity exports stable.
- Optional modify: `Raid Management Addon/Database/DB.lua`
  - Add a tiny module-registration helper only if multiple existing database files use identical registration boilerplate.
- Create: `tests/test_init_core_micro_cleanup_contract.py`
  - Verifies `RMA` identity, `/rma` contract markers, Lua 5.1-safe helper choices, and absence of broad bootstrap redesign.

## Public Contract

- `_G.RMA` remains exported.
- `/rma` and slash aliases remain coherent.
- `RMA_*` SavedVariables remain unchanged.
- TOC load order remains unchanged unless validation proves an accidental stale entry exists.
- No XML changes.
- No retail-only APIs.

## Task 1: Add Bootstrap Contract Tests

**Files:**
- Create: `tests/test_init_core_micro_cleanup_contract.py`
- Read: `Raid Management Addon/Init.lua`
- Read: `Raid Management Addon/Raid Management Addon.toc`

- [ ] **Step 1: Write the source contract test**

```python
from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[1]
INIT = ROOT / "Raid Management Addon" / "Init.lua"
TOC = ROOT / "Raid Management Addon" / "Raid Management Addon.toc"


def read(path):
    return path.read_text(encoding="utf-8")


def test_public_rma_identity_is_preserved():
    src = read(INIT)
    toc = read(TOC)
    assert "_G.RMA" in src
    assert "Raid Management Addon" in toc
    assert "## Interface: 30300" in toc


def test_init_uses_lua51_safe_cached_gettime():
    src = read(INIT)
    assert "local GetTime = _G.GetTime" in src
    assert "_ENV" not in src
    assert "table.unpack" not in src
    assert "C_Timer" not in src


def test_addon_event_count_is_not_recomputed_in_bootstrap_loop():
    src = read(INIT)
    assert "ADDON_EVENTS_COUNT" in src
    assert "tLength(addonEvents)" not in src


def test_bootstrap_does_not_create_new_generic_utils_module():
    src = read(INIT)
    assert "addon.Utils" not in src
    assert "addon.Helpers" not in src
```

- [ ] **Step 2: Run the test and verify RED**

Run:

```powershell
py -3 -m unittest tests.test_init_core_micro_cleanup_contract
```

Expected: FAIL on `GetTime` cache or event count marker if not already implemented.

## Task 2: Cache Hot Bootstrap Globals

**Files:**
- Modify: `Raid Management Addon/Init.lua`
- Test: `tests/test_init_core_micro_cleanup_contract.py`

- [ ] **Step 1: Add `GetTime` cache near existing global aliases**

```lua
local GetTime = _G.GetTime
```

- [ ] **Step 2: Replace repeated `_G.GetTime()` in loot runtime setup**

In `EnsureLootRuntimeState`, replace:

```lua
state.updatedAt = _G.GetTime()
```

with:

```lua
state.updatedAt = GetTime()
```

Do not change the shape of the loot runtime state table.

- [ ] **Step 3: Run the focused test**

```powershell
py -3 -m unittest tests.test_init_core_micro_cleanup_contract
```

Expected: `test_init_uses_lua51_safe_cached_gettime` PASS.

## Task 3: Avoid Recomputing Addon Event Count

**Files:**
- Modify: `Raid Management Addon/Init.lua`
- Test: `tests/test_init_core_micro_cleanup_contract.py`

- [ ] **Step 1: Add a fixed local count after the `addonEvents` table**

```lua
local ADDON_EVENTS_COUNT = #addonEvents
```

- [ ] **Step 2: Replace event count recomputation**

Replace:

```lua
for i = 1, addon.tLength(addonEvents) do
```

with:

```lua
for i = 1, ADDON_EVENTS_COUNT do
```

If the current code uses a different loop shape, keep the existing loop behavior and only replace the repeated count expression.

- [ ] **Step 3: Run the focused test**

```powershell
py -3 -m unittest tests.test_init_core_micro_cleanup_contract
```

Expected: event count assertion PASS.

## Task 4: Evaluate Tiny Database Registration Helper

**Files:**
- Read: `Raid Management Addon/Database/DB.lua`
- Read: `Raid Management Addon/Database/*.lua`
- Optional modify: `Raid Management Addon/Database/DB.lua`
- Test: `tests/test_init_core_micro_cleanup_contract.py`

- [ ] **Step 1: Search for duplicate database registration boilerplate**

Run:

```powershell
rg -n "addon\.Database|Database\.[A-Za-z]+|Register" "Raid Management Addon\Database" -g "*.lua"
```

Expected: output shows whether repeated registration code exists.

- [ ] **Step 2: Add helper only if at least three identical call sites exist**

If the search shows three or more identical registration blocks, add this helper to `DB.lua`:

```lua
function Database.RegisterModule(name, module)
    if type(name) ~= "string" or name == "" then
        return nil, "name must be a non-empty string"
    end
    if type(module) ~= "table" then
        return nil, "module must be a table"
    end
    Database[name] = module
    return module
end
```

If fewer than three call sites exist, leave `DB.lua` unchanged and record "helper not added: insufficient duplicate registration boilerplate" in the batch closeout.

- [ ] **Step 3: Do not rewrite existing public module names**

Keep these namespaces stable if present:

```lua
addon.Database
addon.Database.RaidStore
addon.Database.RaidQueries
addon.Database.RaidMigrations
```

Do not rename public database tables for this micro-cleanup batch.

## Task 5: Run Full Validation

**Files:**
- Read: `Raid Management Addon/Init.lua`
- Optional read: `Raid Management Addon/Database/DB.lua`
- Read: `tests/test_init_core_micro_cleanup_contract.py`

- [ ] **Step 1: Verify identity and load-order diff**

```powershell
git diff -- "Raid Management Addon\Init.lua" "Raid Management Addon\Database\DB.lua" "Raid Management Addon\Raid Management Addon.toc"
```

Expected: no `_G.RMA`, `/rma`, SavedVariables, TOC load-order, or addon-message prefix changes.

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

- `Init.lua` uses a cached `GetTime` where it is repeatedly called.
- Bootstrap event count is not recomputed through a helper during registration.
- No broad bootstrap redesign, file split, or public namespace rename.
- Optional database registration helper is added only if it removes real repeated boilerplate.
- No SavedVariables, addon-message, slash command, TOC, XML, or UI behavior changes.
- Focused test and repository gates pass.
