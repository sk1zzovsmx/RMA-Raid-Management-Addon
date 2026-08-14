# Shared R5 Wire Codec Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace every custom RMA addon-message codec and the custom Comms scheduler with one LibSerialize-based R5 wire codec and ChatThrottleLib.

**Architecture:** `addon.Comms.Payload` is the sole adapter for LibSerialize plus LibDeflate addon-channel encoding, while `addon.Comms` validates destinations and delegates outbound scheduling to ChatThrottleLib. `RMARaidSync`, `RMAResSync`, `RMADist`, and `RMAVersion` retain their public prefixes and feature-owned validation, but exchange dense R5 envelopes and reject every older wire representation.

**Tech Stack:** Lua 5.1, WoW 3.3.5a API, LibStub, LibSerialize, LibDeflate, ChatThrottleLib, Python unittest, repository Lua runtime harness.

## Global Constraints

- Target Interface `30300` and Lua 5.1.5 only.
- Keep addon name `Raid Management Addon`, runtime short name `RMA`, `/rma`, `RMA_*` SavedVariables, and existing addon-message prefixes.
- Do not modify vendored files under `Raid Management Addon/Libs/`.
- Do not add Ace2, Ace3, Retail, or Classic-only APIs.
- All four RMA protocols move to version `5`; do not retain an R4 or older decoder.
- Do not change SavedVariables schemas, persistence contracts, authority policy, correlation policy, transfer caps, or application-level rate limits.
- `Modules/Json.lua` remains for external reserves JSON imports only.
- `Modules/Base64.lua` remains because reserves import and stable runtime hashes still consume it; remove only its Comms dependency.
- Preserve ASCII in runtime code, comments, diagnostics, and UI text.
- Use TDD: each production change follows a focused test that failed for the expected missing behavior.

---

## File Structure

- `Raid Management Addon/Modules/Comms.lua`: shared wire codec, ChatThrottleLib adapter, R5 version exchange, and transport validation.
- `Raid Management Addon/Database/DBSyncProtocol.lua`: R5 raid envelope and compact live-loot schema.
- `Raid Management Addon/Database/DBSyncSession.lua`: bounded transfer chunking through the shared codec and BULK transport policy.
- `Raid Management Addon/Services/Reserves/Sync.lua`: R5 reserves messages and structured transfer payload.
- `Raid Management Addon/Services/Loot/DistributionSession.lua`: R5 distribution messages and snapshot transfer.
- `Raid Management Addon/Raid Management Addon.toc`: retain needed general codecs; document authoritative load order through references only.
- `tests/lua/runtime_harness.lua`: real-library codec fixtures and behavior cases for transport and all four protocols.
- `tests/test_sync_communications_behavior.py`: shared codec, ChatThrottleLib, raid sync, reserves sync, and version exchange cases.
- `tests/test_loot_distribution_hardening_behavior.py`: distribution R5 behavior cases.
- `tests/test_runtime_bootstrap_contract.py`: source/load-order contract that rejects direct Blizzard sends and obsolete custom payload APIs.

---

### Task 1: Shared codec and ChatThrottleLib transport

**Files:**
- Modify: `tests/lua/runtime_harness.lua`
- Modify: `tests/test_sync_communications_behavior.py`
- Modify: `Raid Management Addon/Modules/Comms.lua`

**Interfaces:**
- Consumes: `LibStub("LibSerialize")`, `LibStub("LibDeflate")`, `_G.ChatThrottleLib`.
- Produces: `Payload.Serialize(value) -> encodedText | nil, reason`.
- Produces: `Payload.Deserialize(encodedText) -> value | nil, reason`.
- Produces: `Comms.QueueAddonMessage(prefix, msg, channel, target, opts)` where `opts.priority` is `ALERT`, `NORMAL`, or `BULK`, and `opts.queueName` optionally overrides the stable flow name.
- Produces: `Comms.QueueAddonMessages(prefix, messages, channel, target, opts)` with full input preflight before the first library call.
- Produces: `Comms.SendAddonBatch(prefix, messages, target, opts)` and existing `Comms.Sync`, `SendAddonWhisper`, `SendChat`, and `SendWhisper` adapters.

- [ ] **Step 1: Add failing shared-codec and throttler behavior cases**

Add Python entrypoints:

```python
def test_shared_wire_codec_round_trips_and_fails_closed(self) -> None:
    self.assert_case("comms_shared_wire_codec_round_trip_and_rejection")

def test_comms_routes_prioritized_flows_through_chat_throttle(self) -> None:
    self.assert_case("comms_chat_throttle_priority_and_queue_names")

def test_comms_batch_preflight_prevents_malformed_partial_enqueue(self) -> None:
    self.assert_case("comms_batch_preflight_prevents_malformed_partial_enqueue")
```

Add harness cases that load real `LibStub`, `LibSerialize`, and `LibDeflate`, install a recording `_G.ChatThrottleLib`, load `Modules/Comms.lua`, then assert this contract:

```lua
local value = { 5, "EVENT", false, "Peer", { count = 2, enabled = true, nested = { "a", false, "b" } } }
local encoded = assert(addon.Comms.Payload.Serialize(value))
assertTrue(type(encoded) == "string" and encoded ~= "", "wire codec returned no text")
assertTrue(deepEqual(value, assert(addon.Comms.Payload.Deserialize(encoded))), "wire round trip changed values")
assertEqual(nil, addon.Comms.Payload.Deserialize("\001broken"), "malformed payload was accepted")

assertTrue(addon.Comms.QueueAddonMessage("RMARaidSync", "live", "WHISPER", "Peer", { priority = "NORMAL" }))
assertTrue(addon.Comms.QueueAddonMessages(
    "RMARaidSync",
    { "part-1", "part-2" },
    "WHISPER",
    "Peer",
    { priority = "BULK" }
))
assertEqual("NORMAL", calls[1].priority, "live priority differs")
assertEqual("BULK", calls[2].priority, "bulk priority differs")
assertEqual(calls[2].queueName, calls[3].queueName, "batch flow name changed")
assertEqual("RMARaidSync:WHISPER:peer", calls[2].queueName, "stable flow name differs")

local before = #calls
local queued, reason = addon.Comms.QueueAddonMessages("RMARaidSync", { "valid", false }, "RAID")
assertEqual(false, queued, "malformed batch was accepted")
assertEqual("invalid", reason, "malformed batch reason differs")
assertEqual(before, #calls, "malformed batch partially enqueued")
```

- [ ] **Step 2: Run the focused tests and verify RED**

Run:

```powershell
py -3 -m unittest tests.test_sync_communications_behavior.SyncCommunicationsBehaviorTests.test_shared_wire_codec_round_trips_and_fails_closed tests.test_sync_communications_behavior.SyncCommunicationsBehaviorTests.test_comms_routes_prioritized_flows_through_chat_throttle tests.test_sync_communications_behavior.SyncCommunicationsBehaviorTests.test_comms_batch_preflight_prevents_malformed_partial_enqueue -v
```

Expected: FAIL because `Payload.Serialize`, `Payload.Deserialize`, and ChatThrottleLib routing do not exist and the current batch implementation owns `_addonQueue` state.

- [ ] **Step 3: Replace custom payload helpers and queue state with library adapters**

Bind dependencies at module initialization:

```lua
local LibSerialize = assert(LibStub("LibSerialize"), "LibSerialize is not initialized")
local LibDeflate = assert(LibStub("LibDeflate"), "LibDeflate is not initialized")
local ChatThrottleLib = assert(_G.ChatThrottleLib, "ChatThrottleLib is not initialized")
local WIRE_VERSION = 5
local VALID_PRIORITIES = { ALERT = true, NORMAL = true, BULK = true }
```

Implement the shared codec exactly at the library boundary:

```lua
function Payload.Serialize(value)
    local okSerialize, serialized = pcall(LibSerialize.Serialize, LibSerialize, value)
    if not okSerialize or type(serialized) ~= "string" or serialized == "" then
        return nil, "SERIALIZE_FAILED"
    end
    local okEncode, encoded = pcall(LibDeflate.EncodeForWoWAddonChannel, LibDeflate, serialized)
    if not okEncode or type(encoded) ~= "string" or encoded == "" then
        return nil, "CHANNEL_ENCODE_FAILED"
    end
    return encoded
end

function Payload.Deserialize(text)
    if type(text) ~= "string" or text == "" then
        return nil, "MALFORMED_PAYLOAD"
    end
    local okDecode, serialized = pcall(LibDeflate.DecodeForWoWAddonChannel, LibDeflate, text)
    if not okDecode or type(serialized) ~= "string" or serialized == "" then
        return nil, "CHANNEL_DECODE_FAILED"
    end
    local okCall, success, value = pcall(LibSerialize.Deserialize, LibSerialize, serialized)
    if not okCall or success ~= true then
        return nil, "DESERIALIZE_FAILED"
    end
    return value
end
```

Replace `_addonQueue`, timer binding, `sendAddonMessageNow`, flushing, and pacing constants with these transport rules:

```lua
local function stableQueueName(prefix, channel, target)
    return tostring(prefix) .. ":" .. tostring(channel) .. ":" .. string.lower(tostring(target or "group"))
end

local function normalizeTransportOptions(prefix, channel, target, opts)
	if opts ~= nil and type(opts) ~= "table" then return nil, "invalid_options" end
    local priority = opts and opts.priority or "NORMAL"
    if not VALID_PRIORITIES[priority] then return nil, "invalid_priority" end
	local queueName = opts and opts.queueName
	if queueName ~= nil and (type(queueName) ~= "string" or queueName == "") then
		return nil, "invalid_queue_name"
	end
    return priority, queueName or stableQueueName(prefix, channel, target)
end

function Comms.QueueAddonMessage(prefix, msg, channel, target, opts)
    if type(prefix) ~= "string" or prefix == "" or type(channel) ~= "string" or channel == ""
        or type(msg) ~= "string" or msg == "" then
        return false, "invalid"
    end
    local priority, queueName = normalizeTransportOptions(prefix, channel, target, opts)
    if not priority then return false, queueName end
    local ok = pcall(
        ChatThrottleLib.SendAddonMessage,
        ChatThrottleLib,
        priority,
        prefix,
        msg,
        channel,
        target,
        queueName
    )
    return ok == true, ok and nil or "send_failed"
end
```

`QueueAddonMessages` must first validate every dense entry and transport option, then call `QueueAddonMessage` with the same resolved `priority` and `queueName`. `SendChat` must retain destination/rank/channel validation and call:

```lua
ChatThrottleLib:SendChatMessage(
    bypass == true and "ALERT" or "NORMAL",
    "RMA",
    tostring(msg),
    destination,
    language,
    resolvedTarget,
    stableQueueName("RMAChat", destination, resolvedTarget)
)
```

Remove `Payload.EncodeText`, `DecodeText`, `PackFields`, `SplitFields`, `Comms.FlushAddonQueue`, all `_addonQueue*` fields, and the Timer dependency from `Modules/Comms.lua`.

Convert `RMAVersion` immediately to the shared R5 envelope:

```lua
local function buildVersionPayload(kind)
    local info = Comms.GetVersionInfo()
    return Payload.Serialize({ WIRE_VERSION, kind, false, false, info })
end
```

`HandleVersionMessage` deserializes once, requires a dense five-slot envelope, requires version `5`, validates `REQ` or `ACK`, and validates the body fields before responding. Both the outbound `REQ` and `ACK` use `ALERT` priority.

- [ ] **Step 4: Run focused tests and verify GREEN**

Run the Step 2 command.

Expected: PASS; the recording throttler sees stable queue names and correct priorities, malformed batches enqueue nothing, and the real library codec round-trips without errors.

- [ ] **Step 5: Run the nearest existing Comms and version behavior tests**

Run:

```powershell
py -3 -m unittest tests.test_sync_communications_behavior -v
```

Expected: tests unrelated to the intentionally removed custom queue pass; the two obsolete constant-pacing/backpressure tests have been replaced by the three behavior tests above.

- [ ] **Step 6: Commit Task 1**

```powershell
git add -- 'Raid Management Addon/Modules/Comms.lua' 'tests/lua/runtime_harness.lua' 'tests/test_sync_communications_behavior.py'
git commit -m "refactor(comms): use shared wire and throttle libraries"
```

---

### Task 2: Migrate every RMA protocol to clean R5 envelopes

**Files:**
- Modify: `tests/lua/runtime_harness.lua`
- Modify: `tests/test_raid_replication_behavior.py`
- Modify: `tests/test_sync_communications_behavior.py`
- Modify: `tests/test_loot_distribution_hardening_behavior.py`
- Modify: `Raid Management Addon/Database/DBSyncProtocol.lua`
- Modify: `Raid Management Addon/Database/DBSyncSession.lua`
- Modify: `Raid Management Addon/Services/Reserves/Sync.lua`
- Modify: `Raid Management Addon/Services/Loot/DistributionSession.lua`

**Interfaces:**
- Consumes: Task 1 `Payload.Serialize`, `Payload.Deserialize`, and Comms transport options.
- Produces: `Protocol.VERSION = 5` and dense envelope `{ 5, kind, requestIdOrFalse, targetOrFalse, body }`.
- Produces: R5-only receivers for `RMARaidSync`, `RMAResSync`, `RMADist`, and `RMAVersion`.
- Preserves: feature validation, request correlation, sender authority, chunk caps, decoded caps, retry policy, and state application APIs.

- [ ] **Step 1: Add failing R5 protocol behavior tests**

Add or update harness cases and Python entrypoints to assert:

```lua
local wire = assert(protocol.Encode("HEAD_REQ", nil, nil, {}))
local raw = assert(addon.Comms.Payload.Deserialize(wire))
assertEqual(5, raw[1], "raid wire version differs")
assertEqual("HEAD_REQ", raw[2], "raid message kind differs")
assertEqual(false, raw[3], "missing request id is not dense")
assertEqual(false, raw[4], "missing target is not dense")
assertEqual(nil, protocol.Decode("R4\tHEAD_REQ\t-\t-\t{}"), "R4 wire was accepted")
```

Add one end-to-end R5 assertion for each feature:

```lua
assertR5Envelope(sentRaid.message, "EVENT")
assertR5Envelope(sentReserves.message, "META_REQ")
assertR5Envelope(sentDistribution.message, "WINDOW_BEGIN")
assertR5Envelope(sentVersion.message, "REQ")
```

For reserves chunk tests, assert chunks use `BULK`, share one queue name, reassemble out of order within existing rules, and reconstruct the same canonical state. Distribution snapshot chunks and all other ordered distribution mutations use `NORMAL` and one stable queue per destination; only `HELLO` and `SNAP_REQ` use `ALERT`. Add explicit rejection cases for version `4`, sparse envelopes, wrong kinds, excess parts, oversized chunks, and malformed encoded text.

- [ ] **Step 2: Run the protocol tests and verify RED**

Run:

```powershell
py -3 -m unittest tests.test_raid_replication_behavior tests.test_sync_communications_behavior tests.test_loot_distribution_hardening_behavior -v
```

Expected: FAIL because raid sync still emits `R4` JSON/tab messages, reserves and distribution still emit delimiter/Base64 messages, and existing fixtures do not supply the Task 1 codec contract.

- [ ] **Step 3: Convert DB raid sync to the R5 envelope**

In `DBSyncProtocol.lua`, remove the `addon.Json` dependency, JSON encoder functions, `WIRE_MARKER`, and delimiter parsing. Keep feature validators and compact reconstruction. Replace JSON null slots with `false`:

```lua
local function compactSlot(value)
    if value == nil then return false end
    return value
end
```

Make body serialization use the shared codec:

```lua
Protocol.VERSION = 5

function Protocol.EncodeBody(body)
    if type(body) ~= "table" then return nil, "INVALID_MESSAGE_BODY" end
    return Payload.Serialize(body)
end

function Protocol.DecodeBody(text)
    local body, reason = Payload.Deserialize(text)
    if type(body) ~= "table" then return nil, reason or "MALFORMED_MESSAGE_BODY" end
    return body
end
```

Make `encodeBodyForKind` return a Lua table: compact live loot returns its validated 16-slot array, live-loot part returns its six-slot array, and other kinds return the original validated body. Serialize the top-level envelope once:

```lua
function Protocol.Encode(kind, requestId, target, body)
    if not MESSAGE_SCHEMAS[kind] then return nil, "UNKNOWN_MESSAGE_KIND" end
    requestId = requestId or false
    target = target or false
    local valid, reason = validateBody(kind, body)
    if not valid then return nil, reason end
    local encodedBody, bodyReason = encodeBodyForKind(kind, body)
    if not encodedBody then return nil, bodyReason end
    local message, encodeReason = Payload.Serialize({ 5, kind, requestId, target, encodedBody })
    if not message then return nil, encodeReason end
    if #message > MAX_MESSAGE_BYTES then return nil, "MESSAGE_TOO_LARGE" end
    return message
end
```

`Protocol.Decode` calls `Payload.Deserialize`, requires exactly five dense slots, requires version `5`, converts `false` request/target to the existing internal sentinel semantics, reconstructs kind-specific bodies, and runs `validateEnvelope` plus `validateBody` before returning the named envelope table.

In `DBSyncSession.lua`, remove its direct `LibDeflate` dependency. `encodeTransferText` becomes `Protocol.EncodeBody` plus existing encoded-size checks; `decodeTransferText` performs existing input bounds then `Protocol.DecodeBody`. Queue requests/live messages with `NORMAL`; queue range/snapshot chunk batches with `{ priority = "BULK", queueName = "RMARaidSync:WHISPER:" .. normalizedTarget }`.

- [ ] **Step 4: Convert reserves sync to structured R5 messages**

Replace `FIELD_SEP`, `FORMAT_COMPACT`, `FORMAT_VERIFIED`, line serialization, and Base64 payload transport with one canonical transfer table:

```lua
local function buildTransfer(data, mode)
    local projection, reason = module.BuildCanonicalProjection(data)
    if not projection then return nil, reason end
    local transfer = { mode = mode == "plus" and "plus" or "multi", players = {} }
    for i = 1, #projection do
        local sourcePlayer = projection[i]
        local player = { name = sourcePlayer.name, rows = {} }
        transfer.players[i] = player
        for j = 1, #sourcePlayer.rows do
            local sourceRow = sourcePlayer.rows[j]
            player.rows[j] = {
                rawID = sourceRow.rawID,
                quantity = sourceRow.quantity,
                plus = sourceRow.plus,
                class = sourceRow.class,
                spec = sourceRow.spec,
                note = sourceRow.note,
                source = sourceRow.source,
            }
        end
    end
    return transfer
end
```

All command sends use this exact adapter:

```lua
local function encodeMessage(kind, requestId, target, body)
    return requirePayload().Serialize({ 5, kind, requestId or false, target or false, body or {} })
end
```

`HandleMessage` deserializes once, requires five dense fields and version `5`, validates the message kind and target, then dispatches metadata/request/chunk/done/error behavior using named body fields. `DATA_CHUNK` bodies are `{ index, count, chunk }`; `DATA_DONE` carries `{ checksum = checksum }`. Use `ALERT` for metadata, requests, done, and error; use one `BULK` queue name for data chunks. Reserves owns a bounded wrapping request-ID sequence, accepts `META_ACK` only for an issued metadata request, binds the first valid response source, expires requests after 180 seconds, caps pending requests at 32, and admits assemblies only up to 16 globally and 4 per sender. Preserve the 64-chunk, 24,000-byte, checksum, and sender validation bounds.

- [ ] **Step 5: Convert loot distribution to structured R5 messages**

Remove `SEP`, `SNAP_ROW_SEP`, protocol version `2`, Base64 field helpers, and split scratch buffers. Use a single adapter:

```lua
local function encodeMessage(kind, requestId, target, body)
    return Payload.Serialize({ 5, kind, requestId or false, target or false, body or {} })
end
```

Use these exact positional message bodies in the listed order; optional scalar values use `false`:

| Kind | Positional body fields |
|---|---|
| `CLEAR` | `{ sessionId = sessionId }` |
| `ITEM` | `{ sessionId, itemKey, count, quality, itemLink, itemName, itemTexture, slot }` |
| `WINDOW_BEGIN` | `{ sessionId, revision, expectedRows }` |
| `WINDOW_ITEM` | `{ sessionId, revision, itemKey, count, quality, itemLink, itemName, itemTexture, slot }` |
| `WINDOW_END` | `{ sessionId, revision }` |
| `SESSION_END` | `{ sessionId, revision }` |
| `ROLL_START` | `{ sessionId, itemKey, rollType, duration }` |
| `ROLL_END` | `{ sessionId, itemKey, winnerName, rollValue, reason }` |
| `ITEM_DONE` | `{ sessionId, itemKey, winnerName }` |
| `ITEM_CANCELLED` | `{ sessionId, itemKey, winnerName, reason }` |
| `ROLL_TICK` | `{ sessionId, itemKey, remaining }` |
| `TIE_START` | `{ sessionId, itemKey, tieNamesText }` |
| `AWARDED` | `{ sessionId, itemKey, winnerName, rollType, rollValue }` |
| `HELLO` | `{}` |
| `SNAP_REQ` | `{}` with request ID in envelope slot 3 |
| `SNAP` | `{ sessionId, snapshot }` with request ID in envelope slot 3 |
| `SNAP_CHUNK` | `{ sessionId, index, count, chunk }` with request ID in envelope slot 3 |

Each handler receives the decoded body instead of delimiter fields and preserves all current authority, session, revision, row, stream, tombstone, and state-transition checks. A snapshot is an ordered array of closed row tables with the fields `itemKey`, `count`, `quality`, `itemLink`, `itemName`, `itemTexture`, `slot`, `state`, `rollType`, `duration`, `winnerName`, `rollValue`, `reason`, `remaining`, and `tieNamesText`. Serialize that array through `Payload.Serialize`; chunk envelopes carry `{ sessionId, index, count, chunk }`. ChatThrottleLib does not preserve ordering across priority classes, so every ordered distribution mutation and snapshot response (`CLEAR`, item/window/roll/award changes, `SESSION_END`, `SNAP`, and `SNAP_CHUNK`) uses `NORMAL` and one stable queue per destination. Only out-of-band `HELLO` and `SNAP_REQ` use `ALERT`; `RMADist` never uses `BULK`. Keep the existing incoming snapshot/window/stream caps and TTLs.

- [ ] **Step 6: Run focused protocol tests and verify GREEN**

Run the Step 2 command.

Expected: PASS; every recorded RMA message is an R5 shared-codec envelope, R4/delimited traffic fails closed, and all existing state-machine behaviors remain green.

- [ ] **Step 7: Commit Task 2**

```powershell
git add -- 'Raid Management Addon/Database/DBSyncProtocol.lua' 'Raid Management Addon/Database/DBSyncSession.lua' 'Raid Management Addon/Services/Reserves/Sync.lua' 'Raid Management Addon/Services/Loot/DistributionSession.lua' 'tests/lua/runtime_harness.lua' 'tests/test_raid_replication_behavior.py' 'tests/test_sync_communications_behavior.py' 'tests/test_loot_distribution_hardening_behavior.py'
git commit -m "refactor(sync): migrate all RMA protocols to R5"
```

---

### Task 3: Remove obsolete protocol infrastructure and verify runtime contracts

**Files:**
- Modify: `Raid Management Addon/Raid Management Addon.toc` only if dependency order/comments need correction; retain `Modules/Base64.lua` and `Modules/Json.lua`.
- Modify: `tests/test_runtime_bootstrap_contract.py`
- Modify: `docs/ARCHITECTURE.md`
- Modify: `docs/API_SURFACE.md`
- Modify: `docs/FEATURE_API_MAP.md`
- Modify: `docs/VALIDATION.md`

**Interfaces:**
- Consumes: completed Task 1 and Task 2 runtime.
- Produces: load-order/source contracts proving no custom wire codec or Comms scheduler remains.
- Produces: documentation declaring R5, shared serialization ownership, and ChatThrottleLib priorities.

- [ ] **Step 1: Add failing source and TOC contract tests**

Add these assertions:

```python
comms = (ADDON / "Modules" / "Comms.lua").read_text(encoding="utf-8")
protocol = (ADDON / "Database" / "DBSyncProtocol.lua").read_text(encoding="utf-8")
runtime_sources = "\n".join(
    path.read_text(encoding="utf-8")
    for path in ADDON.rglob("*.lua")
    if "Libs" not in path.parts
)

for obsolete in ("_addonQueue", "PackFields", "SplitFields", "EncodeText", "DecodeText", 'WIRE_MARKER = "R4"'):
    self.assertNotIn(obsolete, comms + protocol)
self.assertIn('LibStub("LibSerialize")', comms)
self.assertIn('LibStub("LibDeflate")', comms)
self.assertIn("ChatThrottleLib.SendAddonMessage", comms)
self.assertNotIn("pcall(SendAddonMessage", runtime_sources)
self.assertNotIn("pcall(SendChatMessage", runtime_sources)
self.assertIn("Modules\\Base64.lua", toc)
self.assertIn("Modules\\Json.lua", toc)
```

Exclude vendored libraries from the direct-send scan. Add checks that `DBSyncProtocol.lua` does not reference `addon.Json` and that `Reserves/Import.lua` still does.

- [ ] **Step 2: Run the contract test and verify RED**

Run:

```powershell
py -3 -m unittest tests.test_runtime_bootstrap_contract -v
```

Expected: FAIL until all obsolete helper names/direct sends are removed and the ownership contract is explicit.

- [ ] **Step 3: Complete cleanup and documentation**

Run searches and remove only obsolete protocol code revealed by them:

```powershell
rg -n '_addonQueue|FlushAddonQueue|Payload\.(EncodeText|DecodeText|PackFields|SplitFields)|WIRE_MARKER|FORMAT_COMPACT|FORMAT_VERIFIED|SNAP_ROW_SEP' 'Raid Management Addon' -g '*.lua' -g '!Libs/**'
rg -n 'SendAddonMessage|SendChatMessage' 'Raid Management Addon' -g '*.lua' -g '!Libs/**'
```

The first command must return no obsolete protocol infrastructure. The second may show dependency assertions or documentation comments but no runtime invocation outside ChatThrottleLib. Keep Base64 and JSON TOC entries because non-wire consumers remain.

Update architecture/API docs with these exact ownership statements:

```markdown
- `addon.Comms.Payload` owns LibSerialize plus LibDeflate addon-channel encoding.
- `addon.Comms` owns destination validation and delegates all outbound scheduling to ChatThrottleLib.
- RMA addon-message protocols use version 5 envelopes and reject earlier versions.
- JSON and Base64 remain import/hash utilities, not addon-message wire codecs.
```

- [ ] **Step 4: Run the focused contract test and full relevant suite**

Run:

```powershell
py -3 -m unittest tests.test_runtime_bootstrap_contract -v
py -3 -m unittest discover -s tests -p 'test_*.py' -v
```

Expected: PASS with no Python or Lua harness errors.

- [ ] **Step 5: Run repository and WotLK validators**

Run:

```powershell
& '.\tools\check-rma.ps1'
py -3 '.agents\skills\wow-addon-dev-wotlk-v335a\scripts\validate_toc.py' 'Raid Management Addon\Raid Management Addon.toc'
py -3 '.agents\skills\wow-addon-dev-wotlk-v335a\scripts\lint_lua51.py' 'Raid Management Addon'
py -3 '.agents\skills\wow-addon-dev-wotlk-v335a\scripts\scan_xpcall.py' 'Raid Management Addon'
rg -n '<Scripts>|<On[A-Za-z]+>' 'Raid Management Addon\UI' -g '*.xml'
rg -n 'RMA_|Raid Management Addon|/rma' . -g '*.lua' -g '*.xml' -g '*.toc' -g '*.md' -g '!Libs/**'
stylua --check 'Raid Management Addon'
luacheck 'Raid Management Addon'
git diff --check
git status --short --branch
```

Expected: all installed validators pass; XML scan finds no script handlers; branding scan contains only current RMA identity. If `stylua` or `luacheck` is unavailable, record that exact limitation rather than claiming success.

- [ ] **Step 6: Record the required two-client smoke result**

Verify on two WotLK 3.3.5a clients running the same R5 build: login/reload, `/rma`, version exchange, live loot replication, range or snapshot recovery, reserves sharing, an active distribution whose complete ordered state flow stays on `NORMAL` while `HELLO`/`SNAP_REQ` remain `ALERT`, concurrent independently correlated `BULK` recovery and `ALERT` control flows, and `RMA_*` SavedVariables persistence. Record observed results in a new `docs/superpowers/smoke/2026-07-20-shared-r5-wire-codec.md`; if no client is available, mark every in-game row `NOT RUN` and state that residual risk explicitly.

- [ ] **Step 7: Commit Task 3 metadata and cleanup**

```powershell
git add -- 'Raid Management Addon/Raid Management Addon.toc' 'tests/test_runtime_bootstrap_contract.py' 'docs/ARCHITECTURE.md' 'docs/API_SURFACE.md' 'docs/FEATURE_API_MAP.md' 'docs/VALIDATION.md' 'docs/superpowers/smoke/2026-07-20-shared-r5-wire-codec.md'
git commit -m "docs(comms): declare shared R5 wire contract"
```

Before staging, omit `Raid Management Addon.toc` if its content did not change. The final handoff must report changed TOC-referenced runtime files, untracked runtime files, deleted references, library/load-order risk, every validation command run or not run, the two-client smoke status, and remaining residual risks.
