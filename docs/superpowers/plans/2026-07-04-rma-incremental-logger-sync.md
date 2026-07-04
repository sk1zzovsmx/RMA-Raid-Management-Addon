# RMA Incremental Logger Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add delta-based `RMALogSync` for persistent logger sync while preserving full snapshot fallback for older peers and large divergence.

**Architecture:** Keep `RMALogSync` on the existing prefix and request/snapshot transport, but add protocol v2 message types for delta negotiation. Persist no new SavedVariables; runtime revisions are derived from canonical raid rows and rebuilt from existing `RMA_Raids` data.

**Tech Stack:** WotLK 3.3.5a, Lua 5.1, existing `Comms.Payload`, `Database/DBSyncer.lua`, `Database/DBSyncPayload.lua`, `Database/DBSyncImport.lua`, Python unittest/source checks.

---

## File Structure

- Modify `Raid Management Addon/Database/DBSyncer.lua`: protocol negotiation, request mode, delta send/receive dispatch, full fallback.
- Modify `Raid Management Addon/Database/DBSyncPayload.lua`: build and parse delta payload records.
- Modify `Raid Management Addon/Database/DBSyncImport.lua`: apply delta rows onto the current raid.
- Modify `Raid Management Addon/Database/DBRaidStore.lua`: maintain runtime `syncRevision` and row revision helpers without adding SavedVariables.
- Create `tests/test_incremental_logger_sync_contract.py`: source-level contract tests for protocol fallback and delta payload APIs.

## Protocol

- Keep `COMM_PREFIX = "RMALogSync"`.
- Keep existing protocol v1 request/snapshot parse path unchanged.
- Add `PROTOCOL_VERSION = 2` in `DBSyncer.lua` only after v1 compatibility tests exist.
- Add new message kind `DL` for delta chunks.
- Add request field 9: `sinceRevision`.
- A v2 responder sends full snapshot when `sinceRevision <= 0`, current revision is missing, or delta row count exceeds `MAX_DELTA_ROWS = 50`.
- A v1 or malformed peer is ignored by the v2 path exactly as current version mismatch behavior does today.

## Tasks

### Task 1: Add Contract Tests

**Files:**
- Create: `tests/test_incremental_logger_sync_contract.py`

- [ ] **Step 1: Write failing source contract tests**

```python
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SYNCER = ROOT / "Raid Management Addon" / "Database" / "DBSyncer.lua"
PAYLOAD = ROOT / "Raid Management Addon" / "Database" / "DBSyncPayload.lua"
IMPORT = ROOT / "Raid Management Addon" / "Database" / "DBSyncImport.lua"
STORE = ROOT / "Raid Management Addon" / "Database" / "DBRaidStore.lua"


def read(path):
    return path.read_text(encoding="utf-8")


def test_syncer_defines_v2_delta_protocol_and_full_fallback():
    source = read(SYNCER)
    assert 'local PROTOCOL_VERSION = 2' in source
    assert 'local MSG_DELTA = "DL"' in source
    assert 'MAX_DELTA_ROWS = 50' in source
    assert 'sendSnapshot(target, requestId, mode, raid)' in source
    assert re.search(r"sendDelta\\s*\\(", source)
    assert "sinceRevision" in source


def test_payload_exports_delta_build_parse_api():
    source = read(PAYLOAD)
    assert "function SnapshotPayload.BuildDelta(raid, sinceRevision)" in source
    assert "function SnapshotPayload.ParseDelta(payload)" in source
    assert '"D"' in source
    assert '"LD"' in source


def test_import_applies_delta_without_replacing_full_raid():
    source = read(IMPORT)
    assert "function SnapshotImport.ApplyDeltaToRaid(raid, delta)" in source
    assert "ApplySnapshotToRaid" in source
    assert "ApplyDeltaToRaid" in source


def test_store_exposes_runtime_revision_helpers_without_savedvariable_schema_change():
    source = read(STORE)
    assert "function module:GetRaidSyncRevision(raid)" in source
    assert "function module:TouchRaidSyncRevision(raid, reason)" in source
    assert "syncRevision" in source
    assert "RMA_" not in re.sub(r"RMA_Raids|RMA_Players|RMA_Reserves|RMA_Warnings|RMA_Spammer|RMA_Options", "", source)
```

- [ ] **Step 2: Run and verify RED**

Run:

```powershell
py -3 -m unittest tests.test_incremental_logger_sync_contract
```

Expected: FAIL because v2 delta APIs and message kinds are absent.

### Task 2: Add Runtime Revision Helpers

**Files:**
- Modify: `Raid Management Addon/Database/DBRaidStore.lua`

- [ ] **Step 1: Implement revision helpers**

Add inside the `do` block, near runtime helpers:

```lua
local function ensureSyncRevision(raid)
    if type(raid) ~= "table" then
        return 0
    end
    local runtime = ensureRuntimeTable(raid)
    runtime.syncRevision = tonumber(runtime.syncRevision) or 0
    return runtime.syncRevision
end

function module:GetRaidSyncRevision(raid)
    return ensureSyncRevision(raid)
end

function module:TouchRaidSyncRevision(raid, reason)
    if type(raid) ~= "table" then
        return 0
    end
    local runtime = ensureRuntimeTable(raid)
    runtime.syncRevision = (tonumber(runtime.syncRevision) or 0) + 1
    runtime.lastSyncRevisionReason = tostring(reason or "change")
    return runtime.syncRevision
end
```

- [ ] **Step 2: Touch revision after logger mutations**

In methods that insert, update, delete, or import loot/boss/player rows, call:

```lua
self:TouchRaidSyncRevision(raid, "loot")
```

Use concrete reason strings: `"player"`, `"boss"`, `"loot"`, `"attendance"`, `"snapshot"`.

- [ ] **Step 3: Run checks**

```powershell
py -3 .agents/skills/wow-addon-dev-wotlk-v335a/scripts/lint_lua51.py "Raid Management Addon"
luacheck "Raid Management Addon\Database\DBRaidStore.lua"
```

Expected: both pass.

### Task 3: Add Delta Payload Build And Parse

**Files:**
- Modify: `Raid Management Addon/Database/DBSyncPayload.lua`

- [ ] **Step 1: Add delta builder**

Add public API after `SnapshotPayload.Build`:

```lua
function SnapshotPayload.BuildDelta(raid, sinceRevision)
    if type(raid) ~= "table" then
        return nil
    end
    local revision = Database.GetRaidStoreOrNil("DBSyncPayload.BuildDelta", { "GetRaidSyncRevision" })
        and Database.GetRaidStoreOrNil("DBSyncPayload.BuildDelta", { "GetRaidSyncRevision" }):GetRaidSyncRevision(raid)
        or 0
    local fromRevision = tonumber(sinceRevision) or 0
    if fromRevision < 0 then
        fromRevision = 0
    end

    local lines = {
        packFields(FIELD_SEP, "D", 2, tonumber(raid.raidNid) or 0, fromRevision, revision),
    }

    local lootRows = sortedByNid(raid.loot, "lootNid", "itemName")
    for i = 1, #lootRows do
        local row = lootRows[i]
        local rowRevision = tonumber(row and row.syncRevision) or revision
        if rowRevision > fromRevision then
            lines[#lines + 1] = packFields(
                FIELD_SEP,
                "LD",
                rowRevision,
                tonumber(row.lootNid) or 0,
                tonumber(row.itemId) or 0,
                encodeText(row.itemName),
                encodeText(row.itemString),
                encodeText(row.itemLink),
                tonumber(row.itemRarity) or 0,
                encodeText(row.itemTexture),
                tonumber(row.itemCount) or 1,
                tonumber(row.looterNid) or 0,
                encodeText(row.looterName or row.looter),
                tonumber(row.rollType) or 0,
                tonumber(row.rollValue) or 0,
                tonumber(row.bossNid) or 0,
                tonumber(row.time) or 0
            )
        end
    end

    return tconcat(lines, RECORD_SEP)
end
```

- [ ] **Step 2: Add delta parser**

Add public parser:

```lua
function SnapshotPayload.ParseDelta(payload)
    local text = tostring(payload or "")
    local delta = { header = nil, loot = {} }
    for line in strgmatch(text, "([^\n]+)") do
        local fields = splitFields(line, FIELD_SEP)
        local kind = fields[1]
        if kind == "D" then
            delta.header = {
                protocolVersion = tonumber(fields[2]) or 0,
                raidNid = tonumber(fields[3]) or 0,
                sinceRevision = tonumber(fields[4]) or 0,
                revision = tonumber(fields[5]) or 0,
            }
        elseif kind == "LD" then
            delta.loot[#delta.loot + 1] = {
                syncRevision = tonumber(fields[2]) or 0,
                lootNid = tonumber(fields[3]) or 0,
                itemId = tonumber(fields[4]) or 0,
                itemName = decodeText(fields[5]),
                itemString = decodeText(fields[6]),
                itemLink = decodeText(fields[7]),
                itemRarity = tonumber(fields[8]) or 0,
                itemTexture = decodeText(fields[9]),
                itemCount = tonumber(fields[10]) or 1,
                looterNid = tonumber(fields[11]) or 0,
                looterName = decodeText(fields[12]),
                rollType = tonumber(fields[13]) or 0,
                rollValue = tonumber(fields[14]) or 0,
                bossNid = tonumber(fields[15]) or 0,
                time = tonumber(fields[16]) or 0,
            }
        else
            return nil
        end
    end
    if not delta.header then
        return nil
    end
    return delta
end
```

- [ ] **Step 3: Run checks**

```powershell
py -3 -m unittest tests.test_incremental_logger_sync_contract
py -3 .agents/skills/wow-addon-dev-wotlk-v335a/scripts/lint_lua51.py "Raid Management Addon"
luacheck "Raid Management Addon\Database\DBSyncPayload.lua"
```

Expected: tests still fail until importer and syncer are implemented; Lua gates pass.

### Task 4: Apply Delta

**Files:**
- Modify: `Raid Management Addon/Database/DBSyncImport.lua`

- [ ] **Step 1: Add `ApplyDeltaToRaid`**

Add after `ApplySnapshotToRaid`:

```lua
function SnapshotImport.ApplyDeltaToRaid(raid, delta)
    if not (raid and delta and delta.header) then
        return nil
    end
    raid.loot = raid.loot or {}
    local lootIdx = buildNidIndex(raid.loot, "lootNid")
    for i = 1, #(delta.loot or {}) do
        local src = delta.loot[i]
        local nid = tonumber(src and src.lootNid)
        if nid and nid > 0 then
            local dst = upsertByNid(raid.loot, lootIdx, nid)
            dst.lootNid = nid
            dst.syncRevision = tonumber(src.syncRevision) or tonumber(delta.header.revision) or 0
            dst.itemId = tonumber(src.itemId) or dst.itemId
            dst.itemName = src.itemName or dst.itemName
            dst.itemString = src.itemString or dst.itemString
            dst.itemLink = src.itemLink or dst.itemLink
            dst.itemRarity = tonumber(src.itemRarity) or dst.itemRarity
            dst.itemTexture = src.itemTexture or dst.itemTexture
            dst.itemCount = tonumber(src.itemCount) or dst.itemCount or 1
            dst.looterNid = tonumber(src.looterNid) or dst.looterNid
            dst.rollType = tonumber(src.rollType) or dst.rollType or 0
            dst.rollValue = tonumber(src.rollValue) or dst.rollValue or 0
            dst.bossNid = tonumber(src.bossNid) or dst.bossNid or 0
            dst.time = tonumber(src.time) or dst.time
        end
    end
    applySnapshotNextNids(raid, delta.header)
    return finalizeSnapshotRaid(raid)
end
```

- [ ] **Step 2: Run checks**

```powershell
py -3 -m unittest tests.test_incremental_logger_sync_contract
luacheck "Raid Management Addon\Database\DBSyncImport.lua"
```

Expected: source contract tests still fail only on `DBSyncer.lua`.

### Task 5: Wire V2 Delta Into Syncer

**Files:**
- Modify: `Raid Management Addon/Database/DBSyncer.lua`

- [ ] **Step 1: Add constants**

```lua
local PROTOCOL_VERSION = 2
local MSG_DELTA = "DL"
local MAX_DELTA_ROWS = 50
```

- [ ] **Step 2: Include `sinceRevision` in sync requests**

In `requestLoggerSync`, compute:

```lua
local raidStore = Database.GetRaidStoreOrNil("DBSyncer.RequestLoggerSync", { "GetRaidSyncRevision" })
local sinceRevision = raidStore and raidStore:GetRaidSyncRevision(currentRaid) or 0
```

Pass it into `sendRequest`, and pack it as field 9.

- [ ] **Step 3: Add `sendDelta`**

```lua
local function sendDelta(target, requestId, mode, raid, sinceRevision)
    local payload = SnapshotPayload.BuildDelta(raid, sinceRevision)
    if not payload then
        return false
    end
    local encodedPayload = SnapshotPayload.EncodeText(payload)
    local payloadLen = #encodedPayload
    local totalChunks = floor((payloadLen + MAX_CHUNK_SIZE - 1) / MAX_CHUNK_SIZE)
    if totalChunks < 1 then
        totalChunks = 1
    end
    for idx = 1, totalChunks do
        local fromPos = ((idx - 1) * MAX_CHUNK_SIZE) + 1
        local toPos = fromPos + MAX_CHUNK_SIZE - 1
        local chunk = strsub(encodedPayload, fromPos, toPos)
        local msg = packFields(FIELD_SEP, MSG_DELTA, PROTOCOL_VERSION, requestId, mode, tonumber(raid.raidNid) or 0, idx, totalChunks, chunk)
        sendAddonPayload(target, msg)
    end
    Metrics.RecordOutgoingSnapshot(mode, payloadLen, totalChunks)
    return true
end
```

- [ ] **Step 4: Select full vs delta**

In `handleIncomingRequest`, for `MODE_SYNC`, choose:

```lua
local sinceRevision = tonumber(signature and signature.sinceRevision) or 0
if sinceRevision <= 0 then
    sendSnapshot(rawSender, requestId, mode, raid)
elseif not sendDelta(rawSender, requestId, mode, raid, sinceRevision) then
    sendSnapshot(rawSender, requestId, mode, raid)
end
```

- [ ] **Step 5: Receive `MSG_DELTA`**

Mirror `MSG_SNAPSHOT` parsing and call:

```lua
local deltaPayload = SnapshotPayload.DecodeText(encodedPayload)
local delta = SnapshotPayload.ParseDelta(deltaPayload)
local ok, raid = pcall(SnapshotImport.ApplyDeltaToRaid, currentRaid, delta)
```

If decode, parse, raid mismatch, or apply fails, reject sender and allow next full snapshot request.

- [ ] **Step 6: Run full validation**

```powershell
py -3 -m unittest discover -s tests
py -3 .agents/skills/wow-addon-dev-wotlk-v335a/scripts/validate_toc.py "Raid Management Addon\Raid Management Addon.toc"
py -3 .agents/skills/wow-addon-dev-wotlk-v335a/scripts/lint_lua51.py "Raid Management Addon"
py -3 .agents/skills/wow-addon-dev-wotlk-v335a/scripts/scan_xpcall.py "Raid Management Addon"
luacheck "Raid Management Addon"
git diff --check
```

Expected: all pass. Runtime smoke remains manual acceptance.

## Acceptance Criteria

- Full snapshot behavior still works for request and push.
- Persistent sync sends delta when the peer provides a usable revision.
- Delta apply updates loot rows without replacing player, boss, or attendance tables.
- Malformed v2 delta does not corrupt current raid.
- No new SavedVariables key or non-RMA prefix is introduced.
