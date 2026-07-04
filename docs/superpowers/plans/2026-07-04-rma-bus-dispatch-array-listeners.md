# RMA Bus Dispatch Array Listeners Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the event bus listener map with an array-backed dispatcher that reduces per-event iteration cost while preserving the public Bus contract.

**Architecture:** `Modules/Bus.lua` remains the single owner of in-process addon events. The public API stays `RegisterCallback`, `UnregisterCallback`, and `TriggerEvent`; the internal storage changes to ordered listener arrays with token indexes and deferred compaction during active dispatch.

**Tech Stack:** Lua 5.1, WotLK 3.3.5a addon runtime, Python source-characterization tests, existing RMA validation scripts.

---

## File Structure

- Modify: `Raid Management Addon/Modules/Bus.lua`
  - Owns listener storage, token lifecycle, dispatch ordering, and failure containment.
- Create: `tests/test_bus_dispatch_array_contract.py`
  - Verifies the API surface, no `CallbackHandler` dependency, no protocol/UI changes, and the expected array-backed implementation shape.
- Optional modify: `docs/VALIDATION.md`
  - Add a validation note only if this batch introduces a new bus-specific test command worth documenting.

## Public Contract

- `addon.Bus.RegisterCallback(eventName, callback, owner)` continues to return an opaque token.
- `addon.Bus.UnregisterCallback(token)` continues to accept the token returned by `RegisterCallback`.
- `addon.Bus.TriggerEvent(eventName, ...)` continues to dispatch all registered callbacks for `eventName`.
- Dispatch remains Lua 5.1-compatible and does not introduce `OnUpdate`, timers, Ace, CallbackHandler, or WoW-version-specific APIs.
- Callback errors remain contained so one listener does not prevent later listeners from running.

## Task 1: Characterize Current Bus Contract

**Files:**
- Create: `tests/test_bus_dispatch_array_contract.py`
- Read: `Raid Management Addon/Modules/Bus.lua`

- [ ] **Step 1: Write the failing source contract test**

```python
from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[1]
BUS = ROOT / "Raid Management Addon" / "Modules" / "Bus.lua"


def read_bus():
    return BUS.read_text(encoding="utf-8")


def test_bus_public_api_is_preserved():
    src = read_bus()
    assert re.search(r"function\s+Bus\.RegisterCallback\s*\(", src)
    assert re.search(r"function\s+Bus\.UnregisterCallback\s*\(", src)
    assert re.search(r"function\s+Bus\.TriggerEvent\s*\(", src)


def test_bus_does_not_depend_on_callbackhandler_or_xml_scripts():
    src = read_bus()
    assert "CallbackHandler" not in src
    assert "C_Timer" not in src
    assert "OnUpdate" not in src


def test_bus_uses_array_listener_storage_with_token_index():
    src = read_bus()
    assert "listenerList" in src or "listeners.items" in src
    assert "indexByToken" in src
    assert re.search(r"for\s+i\s*=\s*1\s*,\s*#.*items\s+do", src)


def test_bus_defers_compaction_during_dispatch():
    src = read_bus()
    assert "dispatchDepth" in src
    assert "pendingCompact" in src or "dirty" in src
```

- [ ] **Step 2: Run the new test and verify RED**

Run:

```powershell
py -3 -m unittest tests.test_bus_dispatch_array_contract
```

Expected: FAIL on `test_bus_uses_array_listener_storage_with_token_index` because the current implementation still uses map-style listener storage.

## Task 2: Implement Array-Backed Listener Storage

**Files:**
- Modify: `Raid Management Addon/Modules/Bus.lua`
- Test: `tests/test_bus_dispatch_array_contract.py`

- [ ] **Step 1: Replace the internal storage shape**

Use this storage model inside `Modules/Bus.lua`:

```lua
local listenersByEvent = {}
local nextTokenId = 0

local function getListenerList(eventName)
    local listenerList = listenersByEvent[eventName]
    if not listenerList then
        listenerList = {
            items = {},
            indexByToken = {},
            dispatchDepth = 0,
            dirty = false,
        }
        listenersByEvent[eventName] = listenerList
    end
    return listenerList
end
```

- [ ] **Step 2: Preserve token semantics in `RegisterCallback`**

Implement the registration path so callers still receive an opaque token:

```lua
function Bus.RegisterCallback(eventName, callback, owner)
    if type(eventName) ~= "string" or eventName == "" then
        return nil, "eventName must be a non-empty string"
    end
    if type(callback) ~= "function" then
        return nil, "callback must be a function"
    end

    nextTokenId = nextTokenId + 1
    local token = {
        eventName = eventName,
        id = nextTokenId,
    }
    local listenerList = getListenerList(eventName)
    local row = {
        token = token,
        callback = callback,
        owner = owner,
    }
    listenerList.items[#listenerList.items + 1] = row
    listenerList.indexByToken[token] = #listenerList.items
    return token
end
```

- [ ] **Step 3: Preserve unregister behavior with deferred compaction**

Implement unregister so removal during active dispatch cannot skip the next listener:

```lua
local function compactListenerList(listenerList)
    local compacted = {}
    local indexByToken = {}
    for i = 1, #listenerList.items do
        local row = listenerList.items[i]
        if row then
            compacted[#compacted + 1] = row
            indexByToken[row.token] = #compacted
        end
    end
    listenerList.items = compacted
    listenerList.indexByToken = indexByToken
    listenerList.dirty = false
end

function Bus.UnregisterCallback(token)
    if not token or not token.eventName then
        return false
    end
    local listenerList = listenersByEvent[token.eventName]
    if not listenerList then
        return false
    end
    local index = listenerList.indexByToken[token]
    if not index then
        return false
    end

    listenerList.items[index] = nil
    listenerList.indexByToken[token] = nil
    if listenerList.dispatchDepth > 0 then
        listenerList.dirty = true
    else
        compactListenerList(listenerList)
    end
    return true
end
```

- [ ] **Step 4: Dispatch by array without changing callback arguments**

Keep the existing error handling style in the file. If the current file already has a `safeCall` helper, reuse it:

```lua
function Bus.TriggerEvent(eventName, ...)
    local listenerList = listenersByEvent[eventName]
    if not listenerList then
        return
    end

    listenerList.dispatchDepth = listenerList.dispatchDepth + 1
    for i = 1, #listenerList.items do
        local row = listenerList.items[i]
        if row then
            safeCall(row.callback, row.owner, ...)
        end
    end
    listenerList.dispatchDepth = listenerList.dispatchDepth - 1

    if listenerList.dispatchDepth == 0 and listenerList.dirty then
        compactListenerList(listenerList)
    end
end
```

- [ ] **Step 5: Run the focused test and verify GREEN**

Run:

```powershell
py -3 -m unittest tests.test_bus_dispatch_array_contract
```

Expected: PASS.

## Task 3: Run RMA Gates

**Files:**
- Read: `Raid Management Addon/Modules/Bus.lua`
- Read: `tests/test_bus_dispatch_array_contract.py`

- [ ] **Step 1: Run Python tests**

```powershell
py -3 -m unittest discover -s tests
```

Expected: PASS.

- [ ] **Step 2: Run Lua and addon validators**

```powershell
py -3 .agents/skills/wow-addon-dev-wotlk-v335a/scripts/validate_toc.py "Raid Management Addon\Raid Management Addon.toc"
py -3 .agents/skills/wow-addon-dev-wotlk-v335a/scripts/lint_lua51.py "Raid Management Addon"
py -3 .agents/skills/wow-addon-dev-wotlk-v335a/scripts/scan_xpcall.py "Raid Management Addon"
luacheck "Raid Management Addon"
git diff --check
```

Expected: all commands PASS.

- [ ] **Step 3: Inspect runtime smoke risk**

Manual smoke after copy to the WoW addon folder:

```text
/reload
/rma
Open each main panel once.
```

Expected: no Lua errors; panels still open. If the client is not available, record runtime smoke as not run.

## Acceptance Criteria

- Bus public method names and call signatures remain stable.
- Listener dispatch iterates array storage instead of table-key traversal.
- Unregister during dispatch is safe and does not skip unrelated listeners.
- No XML, SavedVariables, addon-message, slash command, TOC, or UI behavior changes.
- Focused test and repository gates pass.
