# RMA Sync Chunk Send Preallocation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Consolidate chunked sync sends into one preallocated helper to reduce duplicate string/table work in snapshot and delta sends.

**Architecture:** `Database/DBSyncer.lua` keeps ownership of sync chunk orchestration. A private `sendChunkedPayload` helper prepares the fixed metadata once, reuses a local message buffer for one send operation, and delegates actual transport to the existing Comms/payload send function.

**Tech Stack:** Lua 5.1, existing RMA sync protocol, LibDeflate-aware payload compression already in the repo, Python source-characterization tests, RMA validation scripts.

---

## File Structure

- Modify: `Raid Management Addon/Database/DBSyncer.lua`
  - Adds a private chunk-send helper and rewires snapshot/delta send paths to call it.
- Create: `tests/test_sync_chunk_send_preallocation_contract.py`
  - Verifies a shared helper exists, snapshot and delta sends use it, and protocol labels remain stable.

## Public Contract

- No chunk wire-field changes.
- No compression header changes.
- No addon-message prefix changes.
- No SavedVariables changes.
- Existing Comms queue behavior remains the only transport path.

## Task 1: Add Source Contract Tests

**Files:**
- Create: `tests/test_sync_chunk_send_preallocation_contract.py`
- Read: `Raid Management Addon/Database/DBSyncer.lua`

- [ ] **Step 1: Write the failing test**

```python
from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[1]
SYNCER = ROOT / "Raid Management Addon" / "Database" / "DBSyncer.lua"


def read_syncer():
    return SYNCER.read_text(encoding="utf-8")


def function_body(src, name):
    match = re.search(r"function\s+DBSyncer\." + name + r"\s*\([^)]*\)(.*?)\nend", src, re.S)
    assert match, name
    return match.group(1)


def test_shared_chunk_send_helper_exists():
    src = read_syncer()
    assert re.search(r"local\s+function\s+sendChunkedPayload\s*\(", src)
    assert "chunkMessageBuffer" in src


def test_snapshot_and_delta_send_paths_use_shared_helper():
    src = read_syncer()
    for name in ("SendSnapshot", "SendDelta"):
        body = function_body(src, name)
        assert "sendChunkedPayload" in body, name


def test_protocol_literals_remain_stable():
    src = read_syncer()
    for literal in ("snapshot", "delta", "chunk", "requestId", "chunkIndex", "totalChunks"):
        assert literal in src
```

- [ ] **Step 2: Run the test and verify RED**

Run:

```powershell
py -3 -m unittest tests.test_sync_chunk_send_preallocation_contract
```

Expected: FAIL because `sendChunkedPayload` is not present yet.

## Task 2: Extract a Shared Chunk Sender

**Files:**
- Modify: `Raid Management Addon/Database/DBSyncer.lua`
- Test: `tests/test_sync_chunk_send_preallocation_contract.py`

- [ ] **Step 1: Add a private message buffer**

Place this near other sync-local state:

```lua
local chunkMessageBuffer = {}
```

- [ ] **Step 2: Add buffer clearing helper**

```lua
local function clearChunkMessageBuffer()
    for key in pairs(chunkMessageBuffer) do
        chunkMessageBuffer[key] = nil
    end
end
```

- [ ] **Step 3: Add the shared chunk sender**

Use the existing local function names for payload encoding, compression, and transport. The important boundary is that this helper owns chunk loop setup and cleanup, while the existing send function still sends each addon message.

```lua
local function sendChunkedPayload(kind, target, distribution, requestId, payload, metadata)
    clearChunkMessageBuffer()

    local encodedPayload = encodeSyncPayload(payload)
    local totalChunks = math.ceil(#encodedPayload / SYNC_CHUNK_SIZE)
    chunkMessageBuffer.kind = kind
    chunkMessageBuffer.requestId = requestId
    chunkMessageBuffer.totalChunks = totalChunks

    if metadata then
        for key, value in pairs(metadata) do
            chunkMessageBuffer[key] = value
        end
    end

    for chunkIndex = 1, totalChunks do
        local startIndex = ((chunkIndex - 1) * SYNC_CHUNK_SIZE) + 1
        local chunkBody = string.sub(encodedPayload, startIndex, startIndex + SYNC_CHUNK_SIZE - 1)
        chunkMessageBuffer.chunkIndex = chunkIndex
        chunkMessageBuffer.chunk = chunkBody
        sendAddonPayload(target, distribution, chunkMessageBuffer)
    end

    clearChunkMessageBuffer()
    return true
end
```

Adjust `encodeSyncPayload`, `SYNC_CHUNK_SIZE`, and `sendAddonPayload` to the exact existing local names in `DBSyncer.lua`; do not create a second transport path.

- [ ] **Step 4: Rewire snapshot send path**

Inside `DBSyncer.SendSnapshot`, replace its local chunk loop with:

```lua
return sendChunkedPayload("snapshot", target, distribution, requestId, snapshotPayload, {
    raidId = raidId,
    compressed = compressionMode,
})
```

Use only metadata fields already emitted by the current snapshot path.

- [ ] **Step 5: Rewire delta send path**

Inside `DBSyncer.SendDelta`, replace its local chunk loop with:

```lua
return sendChunkedPayload("delta", target, distribution, requestId, deltaPayload, {
    raidId = raidId,
    compressed = compressionMode,
})
```

Use only metadata fields already emitted by the current delta path.

- [ ] **Step 6: Run the focused test**

Run:

```powershell
py -3 -m unittest tests.test_sync_chunk_send_preallocation_contract
```

Expected: PASS.

## Task 3: Validate Protocol Preservation

**Files:**
- Read: `Raid Management Addon/Database/DBSyncer.lua`
- Read: `tests/test_sync_chunk_send_preallocation_contract.py`

- [ ] **Step 1: Inspect the diff for protocol-only risk**

Run:

```powershell
git diff -- "Raid Management Addon\Database\DBSyncer.lua"
```

Expected: the diff moves duplicate chunk loop logic into `sendChunkedPayload`; it does not rename payload keys, message kinds, compression keys, or transport calls.

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

- Snapshot and delta chunk sends share one helper.
- The helper clears reusable buffer state before and after each send.
- Existing compression and transport functions remain the only encode/send path.
- No wire field, SavedVariables, addon-message prefix, UI, XML, or TOC changes.
- Focused test and repository gates pass.
