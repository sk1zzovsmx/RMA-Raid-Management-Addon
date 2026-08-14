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
| Authorization | Unknown roster state could become accepted after a short fallback; whisper requests and PUSH trust were permissive. | Responders fail closed. Requesters must be current group members; mutating senders resolve uniquely to a realm-qualified roster identity and have leader/assistant authority. PUSH additionally requires live correlated consent or the configured Require Database source. Consent is single-use. | Prevents untrusted disclosure/mutation. Authorized peers keep the same messages; ambiguous or implicit flows are rejected. | No migration. Tests cover outsiders, officers, roster-late resolution, collisions, replay, and consent lifecycle. |
| Resource limits | Queue, assemblies, IDs, and decoded payload work lacked a coherent bound. | Queue: 256 entries, burst 4/0.08 s. Sync: 220 bytes/chunk, 256 chunks, 56,320 encoded bytes, 64 states globally/eight per sender, IDs 64 bytes, decoded payload 65,536 bytes, 4,096 rows/field bytes, delta 50 rows. Requests: six/sender/30 s; replies: four/target/30 s. | Bounds memory/CPU and applies atomic queue backpressure. Wire layout is unchanged; oversized traffic fails explicitly. | No migration. Boundary, flood, expiry, FIFO, and backpressure tests. |
| Compression | `D1:` data could enter an inflate path with no output limit. | `D1:` is rejected before inflate. Requests advertise compression unsupported and outbound traffic uses base64. | Fail-closed compatibility delta: compressed peers must use uncompressed v1/v2 payloads. Vendored LibDeflate has no bounded-output API. | No migration. Decode rejection and fallback tests. |
| Protocol/revisions | Malformed structures and stale, equal, gapped, duplicated, or out-of-order revisions were incompletely rejected. | Pure validation checks protocol, schema, identifiers, references, envelope agreement, ranges, uniqueness, and monotonicity. Legacy v1 revision zero initializes only revision-zero history. Dense delta proof is required; otherwise the sender falls back to a snapshot. | Prevents stale overwrite and ambiguous partial history while retaining v1 initialization and v2 wire compatibility. | Existing data is not rewritten. Validator and fallback tests cover rejection paths. |
| Atomicity | Snapshot/delta work could expose partial canonical edits or indexes after a late failure. | Imports build detached candidates and commit through `DBRaidStore`. Failure restores raid contents/identity, revisions, counters, runtime indexes, or insertion state. Events/UI publication follows success only. | Preserves canonical history integrity. Successful merge semantics remain unchanged. | No schema migration. Injected-failure tests compare canonical state and assert no event. |
| Request lifecycle | Responses were weakly correlated; late/reused packets and duplicate terminal paths could retain or retrigger state. | IDs bind sender, raid, mode, creation time, and terminal state. IDs are unavailable across pending/incoming/consent/outbound/terminal state. Timeout, cancel, complete, and failure deliver once and clean scoped state. | Rejects unsolicited, cross-context, late, and replayed traffic without new wire fields. | No migration. Tests cover mismatches, timeout-late packets, cancellation, duplicate terminal delivery, collisions, and cleanup isolation. |

## Trust And Data Flow

Inbound data follows: envelope bounds -> unique roster identity and authority ->
request/PUSH consent correlation -> bounded assembly with stable `SN`/`DL` kind
and protocol version -> transport decode -> pure
payload validation -> detached candidate -> store-owned atomic commit -> one
successful notification. Any earlier failure leaves canonical `RMA_Raids`,
revisions, runtime indexes, and UI state unchanged.

## Commit Coherence

- TOC-referenced changed runtime files: `Modules/Comms.lua`,
  `Database/DBSyncer.lua`, `Database/DBSyncPayload.lua`,
  `Database/DBSyncImport.lua`, `Database/DBRaidStore.lua`, and
  `Localization/localization.en.lua`; all remain referenced by the existing TOC.
- Untracked runtime files: none.
- Deleted runtime references: none.
- ModuleRegistry dependency risk: none; no module boundary, registry entry, or
  load-order dependency changed.
- Tracked policy artifacts: `docs/FEATURE_API_MAP.md`, `docs/ARCHITECTURE.md`,
  `docs/VALIDATION.md`, this report, and the implementation plan. Behavior tests
  and the runtime harness also changed.
- Compatibility surfaces unchanged: all RMA prefixes including `RMALogSync`,
  v1/v2 fields, Interface `30300`, `/rma`, branding, `RMA_*` SavedVariables,
  TOC entries, and XML frame identities.
- The pre-existing README edits in the primary checkout are not part of this
  isolated worktree or batch.

## Verification And Residual Risk

Final evidence covers the Python suite, TOC, Lua 5.1, xpcall, XML handlers,
whole-addon luacheck, focused StyLua, branding/identity searches, and
`git diff --check`. `tools/check-rma.ps1` is absent and is not reported as run.
StyLua is assessed against the existing formatting baseline; unrelated runtime
files are not bulk-reformatted.

- Python `unittest`: 154 tests passed.
- TOC validator: one TOC passed with zero errors and warnings.
- Lua 5.1 validator: 132 files clean.
- Lua 5.1 xpcall scan: 132 files clean.
- XML handler scan: clean; no script blocks or event handlers under `UI/`.
- Whole-addon `luacheck` excluding vendored libraries: 119 files, zero warnings
  and zero errors.
- `git diff --check`: passed (line-ending conversion notices only).
- Focused `stylua --check`: not clean because the touched legacy runtime files
  retain the repository's existing CRLF/format baseline and compact statement
  style. No bulk formatting rewrite was made; Lua syntax and luacheck gates pass.
- Identity review confirms Interface `30300`, the six declared `RMA_*`
  SavedVariables, and `RMALogSync`. The batch has no TOC or SavedVariables diff.
- `tools/check-rma.ps1`: not run because the file does not exist.

runtime smoke: deferred by user until the full refactoring program is complete

Residual live-client risks are addon-channel throttling/order, realm-name forms
returned by a server, timer scheduling during zoning/disconnect, cross-version
peer interoperability, and UI refresh after successful import. These belong to
the final program smoke test and are not represented as statically verified.
