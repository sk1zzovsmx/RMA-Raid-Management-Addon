# Sync Communications Hardening Report

## Scope And Outcome

This batch hardens `RMALogSync` without changing its prefix, v1/v2 wire fields,
TOC load order, SavedVariables schema, XML frames, or public RMA identity. The
runtime owners remain `Modules/Comms.lua`, `Database/DBSyncer.lua`,
`Database/DBSyncPayload.lua`, `Database/DBSyncImport.lua`, and
`Database/DBRaidStore.lua`.

## Behavior Deltas

| Area | Old behavior | New behavior | Reason and compatibility | Migration and evidence |
|---|---|---|---|---|
| Authorization | Unknown roster state could become accepted after a short fallback; whisper requests and PUSH trust were permissive. | Responders fail closed. Requesters must be current group members. Automatic Master Loot convergence accepts only the uniquely resolved current master looter, including a rank-zero master; other mutating senders retain their existing capability checks. PUSH additionally requires live correlated consent or the configured Require Database source. Consent is single-use. | Prevents untrusted disclosure/mutation without requiring raid leader or assistant rank from the actual master looter. Ambiguous or implicit flows are rejected. | No migration. Tests cover outsiders, officers, a rank-zero master looter, roster-late resolution, collisions, replay, and consent lifecycle. |
| Resource limits | Queue, assemblies, IDs, and decoded payload work lacked a coherent bound. | Queue: 256 entries, one message every 0.10 seconds. Sync: 220 bytes/chunk, 256 chunks, 56,320 encoded bytes, 64 states globally/eight per sender, IDs 64 bytes, decoded payload 65,536 bytes, 4,096 rows/field bytes, delta 50 rows. Requests: six/sender/30 s; replies: four/target/30 s. | Bounds memory/CPU, applies atomic queue backpressure, and keeps addon-message pacing constant. Wire layout is unchanged; oversized traffic fails explicitly. | No migration. Boundary, flood, expiry, FIFO, pacing, and backpressure tests. |
| Compression | `D1:` data could enter an inflate path with no output limit. | `D1:` is rejected before inflate. Requests advertise compression unsupported and outbound traffic uses base64. | Fail-closed compatibility delta: compressed peers must use uncompressed v1/v2 payloads. Vendored LibDeflate has no bounded-output API. | No migration. Decode rejection and fallback tests. |
| Protocol/revisions | Malformed structures and stale, equal, gapped, duplicated, or out-of-order revisions were incompletely rejected. | Pure validation checks protocol, schema, identifiers, references, envelope agreement, ranges, uniqueness, and monotonicity. Legacy v1 revision zero initializes only revision-zero history. Dense delta proof is required; otherwise the sender falls back to a snapshot. | Prevents stale overwrite and ambiguous partial history while retaining v1 initialization and v2 wire compatibility. | Existing data is not rewritten. Validator and fallback tests cover rejection paths. |
| Atomicity | Snapshot/delta work could expose partial canonical edits or indexes after a late failure. | Imports build detached candidates and commit through `DBRaidStore`. Failure restores raid contents/identity, revisions, counters, runtime indexes, or insertion state. Events/UI publication follows success only. | Preserves canonical history integrity. Successful merge semantics remain unchanged. | No schema migration. Injected-failure tests compare canonical state and assert no event. |
| Request lifecycle | Responses were weakly correlated; late/reused packets and duplicate terminal paths could retain or retrigger state. | IDs bind sender, raid, mode, creation time, and terminal state. IDs are unavailable across pending/incoming/consent/outbound/terminal state. Timeout, cancel, complete, and failure deliver once and clean scoped state. | Rejects unsolicited, cross-context, late, and replayed traffic without new wire fields. | No migration. Tests cover mismatches, timeout-late packets, cancellation, duplicate terminal delivery, collisions, and cleanup isolation. |
| Master Loot convergence | Remote `ITEM_DONE` distribution traffic scheduled a fixed two-second persistent pull, coupling persistence to a presentation/session message. | A successful canonical loot-history commit publishes `RaidLootUpdate`. The local master looter advertises the committed revision with advisory `RV`; a peer coalesces the notice, whispers a correlated `RQ` to its validated current master, then validates and imports the matching `SN` or delta. `ITEM_DONE` remains a distribution message but is no longer a persistence trigger. | Makes the committed history revision the synchronization boundary and removes mutation-provenance coupling from the writer path. | No SavedVariables, snapshot, delta, prefix, or TOC schema change. Recording tests cover direct award, provisional Hold completion, and later Hold/trade mutation; the correlated wire/import case covers only `RV` -> targeted `RQ` -> `SN` -> import. |
| Late-join recovery | The periodic pull did not reliably target the current authority when a peer joined after history was recorded. | Raid creation, roster changes, and forwarded zone changes coalesce through the same authority-pull timer used by revision notices. Once current raid identity and the current master looter are usable, the peer sends a targeted request. A correlated targeted timeout retries once, then stops. Disabling persistent sync terminalizes pending automatic requests and rejects their late responses while leaving manual requests intact. | Recovers late peers without a generic retry framework or broadcast history request, and makes the opt-out effective for already-sent automatic work. | No migration. Real-import coverage proves authoritative replacement despite unrelated local history and different local login timestamps; timer tests prove a single bounded retry, cancellation without retry/import, and preserved manual response handling. |

## Trust And Data Flow

Inbound data follows: envelope bounds -> unique roster identity and authority ->
request/PUSH consent correlation -> bounded assembly with stable `SN`/`DL` kind
and protocol version -> transport decode -> pure
payload validation -> detached candidate -> store-owned atomic commit -> one
successful notification. Any earlier failure leaves canonical `RMA_Raids`,
revisions, runtime indexes, and UI state unchanged.

## Commit Coherence

- TOC-referenced changed runtime files since `4d86c60`:
  `Database/DBSyncer.lua`, `Init.lua`, `Localization/DiagnoseLog.en.lua`,
  `Modules/Comms.lua`, `Modules/Events.lua`,
  `Services/Loot/DistributionSession.lua`, `Services/Loot/Recording.lua`,
  `Services/Loot/Service.lua`, and `Services/Raid/Capabilities.lua`; all remain
  referenced by the existing TOC.
- Untracked runtime files: none.
- Deleted runtime references: none.
- ModuleRegistry dependency risk: none; no module boundary, registry entry, or
  load-order dependency changed.
- Tracked documentation and tests changed since `4d86c60`: this report,
  `tests/lua/runtime_harness.lua`,
  `tests/test_raid_recording_integrity_behavior.py`, and
  `tests/test_sync_communications_behavior.py`.
- Compatibility surfaces unchanged: all RMA prefixes including `RMALogSync`,
  v1/v2 fields, Interface `30300`, `/rma`, branding, `RMA_*` SavedVariables,
  TOC entries, and XML frame identities.
- The pre-existing README edits in the primary checkout are not part of this
  isolated worktree or batch.
- The Task 5 verification commit changed only the Lua harness, its Python
  wrapper, and this report. Subsequent review fixes modify existing runtime
  owners without adding a public API, TOC entry, XML, module, schema, or
  SavedVariables field.
- The correlated diagnostics batch changes the existing `DBSyncer` and Config
  owners, diagnostic localization, the Lua harness and Python test wrappers,
  the sync-diagnostics design specification, and this report. It adds no
  public API, TOC entry, protocol field, option, schema, or SavedVariables
  field.

## Correlated Sync Diagnostics Smoke

On both clients A and B, enable debug diagnostics before testing:

```text
/rma debug on
/rma debug level debug
```

Run automatic sync, Require, and Push once each on clients A and B. Compare the
resulting `[SyncTrace]` lines by `req` or `revision`, and record the first missing
expected event together with the preceding event on each client. Do not copy
encoded payloads, parsed rows, item links, or player history into the evidence.

This diagnostic batch changes no protocol or sync behavior. A separate
behavioral fix requires the captured two-client evidence and must not be inferred
from offline traces alone.

## Verification And Residual Risk

Final evidence covers the Python suite, TOC, Lua 5.1, xpcall, XML handlers,
whole-addon luacheck, focused StyLua, branding/identity searches, and
`git diff --check`. `tools/check-rma.ps1` is absent and is not reported as run.
StyLua is assessed against the existing formatting baseline; unrelated runtime
files are not bulk-reformatted.

- Focused correlated round trip: one test passed. It verifies `RV` -> targeted
  `RQ` -> correlated `SN` -> import, preservation of `itemLink`, `looterNid`,
  `rollType`, and `rollValue`, and no second pull/import for an equal revision.
- Focused real-import set: four tests passed, comprising the correlated round
  trip, late-join authoritative replacement, authoritative delta source/local
  raid mapping, and atomic snapshot/delta build/commit failure handling.
- Focused import diagnostics: two tests passed, covering one successful
  correlated snapshot outcome, one failed import outcome, single-emission
  cardinality, and payload confidentiality.
- Python `unittest`: 301 tests passed.
- TOC validator: one TOC passed with zero errors and warnings.
- Lua 5.1 validator: 134 files clean.
- Lua 5.1 xpcall scan: 134 files clean.
- XML handler scan: clean; no script blocks or event handlers under `UI/`.
- Whole-addon `luacheck` excluding vendored libraries: 121 files, zero warnings
  and zero errors.
- `git diff --check`: passed (line-ending conversion notices only).
- Focused `stylua --check`: not clean because the focused legacy runtime files
  retain the repository's existing CRLF/format baseline and compact statement
  style. Task 5 does not modify those three runtime files; no bulk formatting
  rewrite was made, and the Lua syntax and luacheck gates pass.
- Identity review confirms Interface `30300`, the six declared `RMA_*`
  SavedVariables, and `RMALogSync`. The batch has no TOC or SavedVariables diff.
- `tools/check-rma.ps1`: not run because the file does not exist.

Two-client in-game smoke: not run. It remains required before integration and
must cover login, direct award, completed Hold trade, manual trade isolation,
late join, duplicate suppression, persistent-sync opt-out, and `/reload`
SavedVariables preservation. Integration remains suspended pending smoke
approval.

Residual live-client risks are addon-channel throttling/order, realm-name forms
returned by a server, timer scheduling during zoning/disconnect, cross-version
peer interoperability, and UI refresh after successful import. These belong to
the final program smoke test and are not represented as statically verified.
