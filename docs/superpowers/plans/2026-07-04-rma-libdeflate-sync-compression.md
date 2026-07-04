# RMA LibDeflate Sync Compression Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Compress large logger sync payloads with vendored LibDeflate while preserving Base64-only compatibility.

**Architecture:** Add a payload codec wrapper in `DBSyncPayload.lua` that can emit codec-tagged payload text. The existing Base64 path remains the default fallback and decoder accepts both uncompressed v1 text and compressed v2 text.

**Tech Stack:** WotLK 3.3.5a, Lua 5.1, existing vendored `LibDeflate`, existing `Comms.Payload`, source-level Python tests, Lua validation.

---

## File Structure

- Modify `Raid Management Addon/Database/DBSyncPayload.lua`: codec detection, compressed encode/decode helpers.
- Modify `Raid Management Addon/Database/DBSyncer.lua`: advertise compression support on protocol v2 requests and send compressed snapshot/delta chunks only to v2-capable peers.
- Modify `Raid Management Addon/Localization/DiagnoseLog.en.lua`: add debug labels for compression fallback if missing.
- Create `tests/test_libdeflate_sync_compression_contract.py`: source-level contract tests for codec tags and fallback.

## Codec Contract

- Base64-only text remains valid and undecorated.
- Compressed text is prefixed with `D1:`.
- Encoded compressed payload flow: `LibDeflate:CompressDeflate(payload)` then `LibDeflate:EncodeForWoWAddonChannel(compressed)`.
- Decode flow: if text starts with `D1:`, decode/decompress with LibDeflate; otherwise use existing Base64 decode.
- If LibDeflate is absent or compression fails, sender falls back to existing Base64 text.

## Tasks

### Task 1: Add Contract Tests

**Files:**
- Create: `tests/test_libdeflate_sync_compression_contract.py`

- [ ] **Step 1: Write failing tests**

```python
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PAYLOAD = ROOT / "Raid Management Addon" / "Database" / "DBSyncPayload.lua"
SYNCER = ROOT / "Raid Management Addon" / "Database" / "DBSyncer.lua"


def read(path):
    return path.read_text(encoding="utf-8")


def test_payload_supports_tagged_libdeflate_codec_and_base64_fallback():
    source = read(PAYLOAD)
    assert 'local COMPRESSED_PREFIX = "D1:"' in source
    assert "function SnapshotPayload.EncodeTransportText(value, opts)" in source
    assert "function SnapshotPayload.DecodeTransportText(value)" in source
    assert "CompressDeflate" in source
    assert "EncodeForWoWAddonChannel" in source
    assert "DecodeForWoWAddonChannel" in source
    assert "DecompressDeflate" in source
    assert "SnapshotPayload.EncodeText(value)" in source
    assert "SnapshotPayload.DecodeText(value)" in source


def test_syncer_uses_transport_codec_for_snapshot_and_delta_chunks():
    source = read(SYNCER)
    assert "EncodeTransportText" in source
    assert "DecodeTransportText" in source
    assert "supportsCompression" in source
```

- [ ] **Step 2: Run RED**

```powershell
py -3 -m unittest tests.test_libdeflate_sync_compression_contract
```

Expected: FAIL because codec wrapper APIs are absent.

### Task 2: Add Codec Wrapper

**Files:**
- Modify: `Raid Management Addon/Database/DBSyncPayload.lua`

- [ ] **Step 1: Add LibDeflate resolver**

Near private helpers:

```lua
local COMPRESSED_PREFIX = "D1:"

local function getLibDeflate()
    local libstub = _G.LibStub
    if type(libstub) ~= "function" then
        return nil
    end
    local ok, lib = pcall(libstub, "LibDeflate", true)
    if ok and lib then
        return lib
    end
    return nil
end
```

- [ ] **Step 2: Add transport encode/decode**

```lua
function SnapshotPayload.EncodeTransportText(value, opts)
    local input = tostring(value or "")
    if opts and opts.compress == true then
        local lib = getLibDeflate()
        if lib and type(lib.CompressDeflate) == "function" and type(lib.EncodeForWoWAddonChannel) == "function" then
            local okCompress, compressed = pcall(lib.CompressDeflate, lib, input)
            if okCompress and compressed then
                local okEncode, encoded = pcall(lib.EncodeForWoWAddonChannel, lib, compressed)
                if okEncode and encoded and encoded ~= "" then
                    return COMPRESSED_PREFIX .. encoded, "deflate"
                end
            end
        end
    end
    return encodeText(input), "base64"
end

function SnapshotPayload.DecodeTransportText(value)
    local input = tostring(value or "")
    if input:sub(1, #COMPRESSED_PREFIX) == COMPRESSED_PREFIX then
        local lib = getLibDeflate()
        if not lib then
            return nil
        end
        local body = input:sub(#COMPRESSED_PREFIX + 1)
        local okDecode, compressed = pcall(lib.DecodeForWoWAddonChannel, lib, body)
        if not (okDecode and compressed) then
            return nil
        end
        local okInflate, inflated = pcall(lib.DecompressDeflate, lib, compressed)
        if okInflate and inflated then
            return inflated
        end
        return nil
    end
    return decodeText(input)
end
```

- [ ] **Step 3: Preserve old public API**

Leave:

```lua
function SnapshotPayload.EncodeText(value)
    return encodeText(value)
end

function SnapshotPayload.DecodeText(value)
    return decodeText(value)
end
```

Existing callers outside sync remain unaffected.

### Task 3: Wire Compression Into Syncer

**Files:**
- Modify: `Raid Management Addon/Database/DBSyncer.lua`

- [ ] **Step 1: Advertise support**

In request signatures:

```lua
supportsCompression = true
```

Pack field 10 as `1` when compression is supported.

- [ ] **Step 2: Encode snapshots through transport wrapper**

Replace:

```lua
local encodedPayload = SnapshotPayload.EncodeText(payload)
```

with:

```lua
local encodedPayload = SnapshotPayload.EncodeTransportText(payload, { compress = supportsCompression == true })
```

- [ ] **Step 3: Decode snapshots through transport wrapper**

Replace:

```lua
local payload = SnapshotPayload.DecodeText(encodedPayload)
```

with:

```lua
local payload = SnapshotPayload.DecodeTransportText(encodedPayload)
```

- [ ] **Step 4: Run tests and Lua gates**

```powershell
py -3 -m unittest tests.test_libdeflate_sync_compression_contract
py -3 .agents/skills/wow-addon-dev-wotlk-v335a/scripts/lint_lua51.py "Raid Management Addon"
luacheck "Raid Management Addon\Database\DBSyncPayload.lua" "Raid Management Addon\Database\DBSyncer.lua"
git diff --check
```

Expected: all pass.

## Acceptance Criteria

- Base64-only payloads still decode.
- Compressed payloads use `D1:` prefix and decode only through LibDeflate.
- Sender falls back to Base64 when LibDeflate is unavailable.
- Compression does not affect `Comms.Payload.EncodeText` for other protocols.
- No vendored library files are modified.
