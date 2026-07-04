# RMA Sync Outgoing Rate Limit Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a per-target outgoing sync throttle so logger sync requests and pushes cannot flood addon messages.

**Architecture:** `Database/DBSyncer.lua` remains the sync orchestration owner. The throttle is an internal policy helper used only before outbound request/push sends; receive handlers, wire payload shape, compression, and import behavior stay unchanged.

**Tech Stack:** Lua 5.1, WotLK addon messages, existing RMA Comms queue, Python source-characterization tests, RMA validation scripts.

---

## File Structure

- Modify: `Raid Management Addon/Database/DBSyncer.lua`
  - Adds outgoing rate-limit constants, target key normalization, and a send gate before outbound sync traffic.
- Create: `tests/test_sync_outgoing_rate_limit_contract.py`
  - Verifies the throttle is present, used only by outbound request/push paths, and does not change wire field names.
- Optional modify: `Raid Management Addon/Localization/DiagnoseLog.en.lua`
  - Add one diagnostic format string only if user-visible throttle logging is already routed through diagnostics in `DBSyncer.lua`.

## Public Contract

- No SavedVariables schema changes.
- No addon-message prefix changes.
- No sync wire-field changes for `snapshot`, `delta`, `logger_req`, `logger_push`, chunk headers, compression headers, or request identifiers.
- Incoming messages continue to be processed even if the local sender is currently throttled.
- Throttle state is runtime-only and resets on reload.

## Task 1: Add Source Contract Tests

**Files:**
- Create: `tests/test_sync_outgoing_rate_limit_contract.py`
- Read: `Raid Management Addon/Database/DBSyncer.lua`

- [ ] **Step 1: Write the failing test**

```python
from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[1]
SYNCER = ROOT / "Raid Management Addon" / "Database" / "DBSyncer.lua"


def read_syncer():
    return SYNCER.read_text(encoding="utf-8")


def test_outgoing_rate_limit_policy_exists():
    src = read_syncer()
    assert "OUTGOING_RATE_WINDOW_SECONDS" in src
    assert "OUTGOING_RATE_MAX_PER_TARGET" in src
    assert re.search(r"local\s+function\s+allowOutgoingRequest\s*\(", src)
    assert "outgoingRateState" in src


def test_outgoing_gate_is_applied_to_request_and_push_paths():
    src = read_syncer()
    for name in ("RequestLoggerReq", "BroadcastLoggerPush"):
        match = re.search(r"function\s+DBSyncer\." + name + r"\s*\([^)]*\)(.*?)\nend", src, re.S)
        assert match, name
        body = match.group(1)
        assert "allowOutgoingRequest" in body, name


def test_rate_limit_does_not_touch_incoming_handlers():
    src = read_syncer()
    for name in ("HandleLoggerReq", "HandleLoggerPush", "HandleSnapshot", "HandleDelta"):
        match = re.search(r"function\s+DBSyncer\." + name + r"\s*\([^)]*\)(.*?)\nend", src, re.S)
        if match:
            assert "allowOutgoingRequest" not in match.group(1), name


def test_wire_format_names_are_not_renamed():
    src = read_syncer()
    for literal in ("logger_req", "logger_push", "snapshot", "delta", "chunk"):
        assert literal in src
```

- [ ] **Step 2: Run the test and verify RED**

Run:

```powershell
py -3 -m unittest tests.test_sync_outgoing_rate_limit_contract
```

Expected: FAIL on the missing throttle constants/helper.

## Task 2: Implement Runtime-Only Outgoing Throttle

**Files:**
- Modify: `Raid Management Addon/Database/DBSyncer.lua`
- Test: `tests/test_sync_outgoing_rate_limit_contract.py`

- [ ] **Step 1: Add constants and state near other sync constants**

```lua
local OUTGOING_RATE_WINDOW_SECONDS = 30
local OUTGOING_RATE_MAX_PER_TARGET = 4
local outgoingRateState = {}
```

- [ ] **Step 2: Add target normalization and policy helper**

Use `GetTime` from `_G` if the file already caches globals; otherwise add `local GetTime = _G.GetTime` near existing global caches.

```lua
local function normalizeOutgoingTarget(target, distribution)
    if target and target ~= "" then
        return tostring(target)
    end
    if distribution and distribution ~= "" then
        return tostring(distribution)
    end
    return "GROUP"
end

local function allowOutgoingRequest(target, distribution)
    local key = normalizeOutgoingTarget(target, distribution)
    local now = GetTime()
    local state = outgoingRateState[key]
    if not state or now - state.windowStart >= OUTGOING_RATE_WINDOW_SECONDS then
        outgoingRateState[key] = {
            windowStart = now,
            count = 1,
        }
        return true
    end

    if state.count >= OUTGOING_RATE_MAX_PER_TARGET then
        return false, key
    end

    state.count = state.count + 1
    return true
end
```

- [ ] **Step 3: Gate outbound logger requests**

Inside `DBSyncer.RequestLoggerReq`, add the guard before calling the Comms send function:

```lua
local allowed, rateKey = allowOutgoingRequest(target, distribution)
if not allowed then
    logSyncDiagnostic("sync_outgoing_rate_limited", rateKey)
    return false, "rate_limited"
end
```

Use the file's existing diagnostic/log function name. If no diagnostic helper exists, return `false, "rate_limited"` without chat spam.

- [ ] **Step 4: Gate outbound logger pushes**

Inside `DBSyncer.BroadcastLoggerPush`, add the same guard before payload assembly or chunk send:

```lua
local allowed, rateKey = allowOutgoingRequest(target, distribution)
if not allowed then
    logSyncDiagnostic("sync_outgoing_rate_limited", rateKey)
    return false, "rate_limited"
end
```

- [ ] **Step 5: Run the focused test**

Run:

```powershell
py -3 -m unittest tests.test_sync_outgoing_rate_limit_contract
```

Expected: PASS.

## Task 3: Validate Behavior Boundaries

**Files:**
- Read: `Raid Management Addon/Database/DBSyncer.lua`
- Read: `tests/test_sync_outgoing_rate_limit_contract.py`

- [ ] **Step 1: Verify no wire-format diff**

Run:

```powershell
git diff -- "Raid Management Addon\Database\DBSyncer.lua"
```

Expected: only policy helper and outbound guards are changed; no message names, chunk header keys, compression keys, SavedVariables names, or addon-message prefixes are renamed.

- [ ] **Step 2: Run repository tests**

```powershell
py -3 -m unittest discover -s tests
```

Expected: PASS.

- [ ] **Step 3: Run addon validation**

```powershell
py -3 .agents/skills/wow-addon-dev-wotlk-v335a/scripts/validate_toc.py "Raid Management Addon\Raid Management Addon.toc"
py -3 .agents/skills/wow-addon-dev-wotlk-v335a/scripts/lint_lua51.py "Raid Management Addon"
py -3 .agents/skills/wow-addon-dev-wotlk-v335a/scripts/scan_xpcall.py "Raid Management Addon"
luacheck "Raid Management Addon"
git diff --check
```

Expected: all commands PASS.

## Acceptance Criteria

- Outbound logger request and push paths are rate-limited per normalized target.
- Incoming sync handlers remain unthrottled.
- No wire format, SavedVariables, slash command, TOC, XML, or UI layout changes.
- Throttle state is runtime-only.
- Focused test and repository gates pass.
