# Task 4 Report: Version-3 Wire Codec

## Status

Complete. Implemented the closed version-3 raid replication codec only. No transfer sessions, timers, compression, chunk assembly state, authority policy, or sync orchestration were added.

## Files

- Created `Raid Management Addon/Database/DBSyncProtocol.lua`.
- Updated `Raid Management Addon/Raid Management Addon.toc` to load the codec after `DBRaidEvents.lua`.
- Updated `tests/lua/runtime_harness.lua` with the two requested protocol cases.
- Updated `tests/test_raid_replication_behavior.py` with Python entrypoints for both cases.
- Included the authoritative closed-schema clarification in `docs/superpowers/plans/2026-07-16-raid-data-replication.md` as directed.

## RED Evidence

Command:

```powershell
py -3 -m unittest tests.test_raid_replication_behavior -v
```

Result before production code: 21 tests run, 19 passed, and exactly the two new protocol tests failed. Both failures were the expected `cannot open Raid Management Addon/Database/DBSyncProtocol.lua: No such file or directory` error.

## GREEN Evidence

Focused new cases:

```powershell
py -3 -m unittest tests.test_raid_replication_behavior.RaidReplicationBehaviorTests.test_version_3_protocol_round_trips_every_closed_message_kind tests.test_raid_replication_behavior.RaidReplicationBehaviorTests.test_version_3_protocol_rejects_invalid_envelopes_and_bodies -v
```

Result: 2 tests passed.

Focused replication suite after final edits:

```powershell
py -3 -m unittest tests.test_raid_replication_behavior -v
```

Result: 21 tests passed.

Coverage includes all eight message kinds, protocol version 3, version rejection before body decoding, unknown kinds, exact body keys, envelope cardinality, envelope addressing rules, canonical event validation, numeric/range/part bounds, non-ASCII raid UID rejection, malformed JSON, and exact 255-byte acceptance with 256-byte rejection.

## Full-Suite Evidence

```powershell
py -3 -m unittest discover -s tests -p "test_*.py"
```

Result: 336 tests passed in 9.044 seconds.

## Validation Evidence

- TOC validator: `OK: 0 error(s), 0 warning(s) in 1 file(s)`.
- Lua 5.1 validator: `OK: 136 file(s) clean`.
- Lua 5.1 variadic `xpcall` scan: `OK: 136 file(s) clean of variadic xpcall`.
- `stylua --check Raid Management Addon/Database/DBSyncProtocol.lua`: passed.
- `luacheck Raid Management Addon/Database/DBSyncProtocol.lua`: `0 warnings / 0 errors`.
- XML script-handler scan: no matches.
- `git diff --check`: passed; only Git's existing LF-to-CRLF checkout notices were emitted.

## Self-Review

- The envelope is fixed to exactly five tab-separated fields and rejects non-v3 messages before `DecodeBody` is called.
- Each message kind has a closed outer schema and all documented bounds/enums are enforced on both encode and decode.
- `EVENT` delegates complete event validation to `DB.RaidEvents.ValidateEvent` and additionally requires `resultDigest`.
- JSON encoding is deterministic for map keys, escapes envelope-breaking control characters, rejects unsupported/cyclic values, and remains Lua 5.1 compatible.
- The codec only owns wire validation and serialization. It does not access LibDeflate or introduce session/transfer ownership.
- TOC order satisfies the canonical-event dependency and introduces no registry or SavedVariables changes.

## Concerns / Residual Risk

- An in-game two-client WotLK smoke test was not performed in this task; it belongs to the later session/orchestration tasks.
- Task 5 must dynamically preflight chunk sizes through `Protocol.Encode`; the documented 220-byte chunk maximum is not a promise that every maximum-sized chunk fits after metadata overhead.

## Review Fixes

Addressed every focused Task 4 review finding:

- `DecodeBody` now rejects every raw byte from `0x00` through `0x1F` with the stable reason `MALFORMED_MESSAGE_BODY_CONTROL` before calling `Json.Decode`.
- Tests inject raw NUL (`0x00`), unit separator (`0x1F`), vertical tab (`0x0B`), newline (`0x0A`), and carriage return (`0x0D`) into otherwise valid JSON body text and assert that JSON decoding is never invoked.
- The wire-limit test now keeps `requestId = "request-fixed"` and `target = "Target"` unchanged. A 100-byte OFFER zone produces exactly 255 bytes and succeeds; adding one byte to the same valid-schema zone produces 256 bytes and returns `MESSAGE_TOO_LARGE`.
- Table-driven negative coverage now includes HEAD status, digest, RESULT outcome, authority epoch, sequence/checkpoint relationships, range ordering/length, part index/count, chunk limits, reason limits, broadcast addressing, and targeted request/target requirements.
- Positive edge assertions cover one-byte and 220-byte chunks plus a 96-byte RESULT reason; negative assertions cover 221-byte chunks and 97-byte reasons.

Fresh review RED:

```powershell
py -3 -m unittest tests.test_raid_replication_behavior.RaidReplicationBehaviorTests.test_version_3_protocol_round_trips_every_closed_message_kind tests.test_raid_replication_behavior.RaidReplicationBehaviorTests.test_version_3_protocol_rejects_invalid_envelopes_and_bodies -v
```

Result: boundary/schema case passed; invalid-body case failed because raw NUL returned `INVALID_MESSAGE_BODY` instead of `MALFORMED_MESSAGE_BODY_CONTROL`, proving the missing pre-decode guard.

Review GREEN with the same command: 2 tests passed in 0.073 seconds.

Final focused suite:

```powershell
py -3 -m unittest tests.test_raid_replication_behavior -v
```

Result: 21 tests passed in 1.001 seconds after final test refactoring.

Final full suite (run once after GREEN):

```powershell
py -3 -m unittest discover -s tests -p "test_*.py"
```

Result: 336 tests passed in 9.057 seconds.

Final validators:

- TOC: `OK: 0 error(s), 0 warning(s) in 1 file(s)`.
- Lua 5.1: `OK: 136 file(s) clean`.
- Variadic `xpcall`: `OK: 136 file(s) clean of variadic xpcall`.
- StyLua check: passed.
- Luacheck: `0 warnings / 0 errors in 1 file`.
- `git diff --check`: passed; only Git LF-to-CRLF checkout notices were emitted.
