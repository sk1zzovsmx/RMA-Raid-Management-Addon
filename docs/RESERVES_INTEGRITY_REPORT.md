# Reserves Integrity Hardening Report

## Outcome

The Reserves owner now validates detached candidates before publication, verifies
reserve synchronization with canonical `C2` checksums, applies asynchronous
imports and UI batches atomically, bounds all import and whisper resources, and
keeps rejected operations from changing `RMA_Reserves` or runtime cache
ownership.

The public `RMA_Reserves` SavedVariables key and schema are unchanged. The
`RMAResSync` prefix, message kinds, and field layout are unchanged. No TOC entry,
XML frame identity, slash command, or ModuleRegistry dependency changed.

## Behavior Deltas

- Failed and no-op edits previously promoted synced runtime data into local
  persisted ownership. They now validate against a detached candidate and leave
  SavedVariables, cache ownership, indexes, and events unchanged.
- Quantity, plus, removal, batch, and import publication now share one graph
  transaction. Persistence, option-mode, or index faults restore exact
  SavedVariables/runtime/cache identities; observer failures are contained only
  after commit.
- Whisper additions now mutate a detached clone of the active local or synced
  dataset and use the same transaction. A persistence/index failure returns
  `publish_failed`, preserves cache ownership and graph identity, and produces
  no success or invalid-item whisper.
- Alias set/removal publication snapshots its option map, rebuilds indexes
  before commit visibility, rolls the option back on failure, and notifies
  observers only after commit.
- Reserve sync previously trusted transfer metadata and decoded rows without a
  reproducible integrity projection. `C2` metadata now covers a bounded,
  length-framed canonical projection and every inbound payload is recomputed
  before publication.
- Compatibility is asymmetric by design. A new sender remains usable by an old
  receiver because the old receiver treats the checksum as opaque and falls
  back to the existing noncompact payload when it sees capability `C2`. An old
  sender is rejected by a new receiver before allocation because legacy
  untagged checksums depend on Lua map iteration order and cannot be verified.
- Asynchronous imports previously retained caller-owned rows/options and could
  expose partial publication on scheduler or persistence faults. Inputs are now
  snapshotted, generations make stale callbacks terminal, and publication
  restores exact SavedVariables/runtime graph identity on failure.
- Public synchronous and asynchronous import entrypoints now independently
  validate and clone canonical input before publication or timer allocation.
  They enforce 1,000 players, 5,000 rows, 20 reserves per player, bounded text
  and integers, dense sequences, and unique player/item identities even when a
  caller bypasses the text parser.
  Canonical names and every persisted text field use the parser's printable
  ASCII rules; participants must contain one to twenty dense reserve rows.
- Compressed encoded imports previously used an inflate API without a bounded
  output contract. They now fail closed as `COMPRESSED_UNSUPPORTED`. Ordinary
  CSV and uncompressed Base64 JSON remain supported.
- Bulk UI edits previously invoked row mutations incrementally. One strict,
  dense batch of at most 500 commands is now validated against a detached
  candidate and either publishes once or preserves all original state and edit
  controls.
- Whisper signup remains opt-in and may be used before the sender joins the
  raid. Short local names and explicit local-realm names resolve to the same
  realm-qualified admission identity, while different realms remain distinct.
  Storage resolution is owned by `Services/Reserves.lua`: an exact qualified
  participant wins; otherwise a local sender reuses one unambiguous existing
  short-name participant or creates the established short form when no
  same-character qualified collision exists. Ambiguous or cross-realm-only
  local matches fail closed, and new cross-realm participants remain qualified.
  `NormalizeWhisperPlayerIdentity` is the single normalization contract for
  inbound sender names and stored display/key identities. It splits at the
  first character/realm separator, preserves the stored display selected for
  mutation, and rejects multiple stored keys that collapse to one normalized
  character/realm identity.
  Admission allows five
  commands per ten-second window, at most 1,000 live sender windows, and one
  denial reply per exceeded window. Runtime admission state expires after ten
  seconds and is not persisted.
- Whisper mutation is rejected before `AddPlayerReserve` when the canonical
  store already has 1,000 participants, 5,000 reserve rows, or the sender has 20
  reserve rows. Sender identities are valid UTF-8 and at most 64 bytes;
  malformed UTF-8, control-bearing, delimiter-bearing, empty, overlong, or
  boundary-punctuation identities
  are dropped silently before options, rate state, timers, replies, or mutation.
  Reply listings expose at most 20 rows and the throttle queue retains at most
  100 messages.

## Import And Storage Limits

| Resource | Limit |
|---|---:|
| Encoded input | 262,144 bytes |
| Decoded Base64 JSON | 131,072 bytes |
| CSV fields per row | 32 |
| Imported rows / stored reserve rows | 5,000 |
| Participants | 1,000 |
| Distinct reserves per participant | 20 |
| Player and short fields | 64 ASCII bytes |
| Notes | 256 ASCII bytes |
| Quantity / plus | 0..100 |
| Atomic UI batch | 500 commands |
| Whisper response queue | 100 messages |

## Atomicity And Compatibility

Validation, canonical projection, and candidate construction happen before
SavedVariables mutation. Persistence and index failures restore the exact
pre-operation table graph; successful operations persist before notifying
observers. Observer failures after commit are contained and do not misreport a
committed operation as rolled back.

No SavedVariables migration is required. Reload reconstructs runtime indexes
from the same canonical `RMA_Reserves` data. Whisper rate state and sync assembly
state are runtime-only. Compressed import remains unsupported until a concrete
bounded-output decompression API is available.

## Commit Coherence

Changed TOC-referenced runtime files are:

- `Services/Reserves.lua`
- `Services/Reserves/Chat.lua`
- `Services/Reserves/Import.lua`
- `Services/Reserves/Sync.lua`
- `Widgets/ReservesUI.lua`
- `Localization/localization.en.lua`

All were already referenced by `Raid Management Addon.toc`. There are no new or
untracked runtime files, deleted runtime references, TOC changes, or registry
dependency changes. The only new tracked test surface is
`tests/test_reserves_integrity_behavior.py`; the existing Lua runtime harness was
extended. This report and the final API, architecture, and validation contracts
are the changed tracked policy artifacts.

## Validation

- Python discovery: 172 tests passed.
- TOC validation: 0 errors and 0 warnings.
- Lua 5.1 syntax: 132 files clean.
- Lua 5.1 `xpcall` scan: 132 files clean.
- XML handler scan: clean.
- Whole-addon `luacheck`, excluding vendored libraries: 119 files, 0 warnings
  and 0 errors.
- `git diff --check`: clean, with expected line-ending conversion warnings.
- `stylua --check` remains noisy against legacy CRLF/whole-file formatting; no
  mass formatting is part of this batch.
- `tools/check-rma.ps1` is not present.
- runtime smoke: deferred by user until the full refactoring program is complete

Residual risk is limited to real-client timer, whisper transport, item-link,
SavedVariables reload, and UI interaction behavior, which requires the deferred
WotLK 3.3.5a smoke test.
