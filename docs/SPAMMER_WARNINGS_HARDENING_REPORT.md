# Spammer And Warning Hardening Report

## Scope And Outcome

This batch hardens LFM spam delivery, chat-result propagation, and raid-warning
persistence without changing RMA identity, slash commands, addon-message wire
formats, XML frame identities, or the `RMA_Spammer` and `RMA_Warnings`
SavedVariables names. Draft, runtime, transport, store, and controller ownership
is explicit and each terminal result is propagated instead of inferred.

## Behavior Deltas

| Area | Old behavior | New behavior | Compatibility and migration |
|---|---|---|---|
| Persisted drafts and warnings | Sparse, malformed, oversized, duplicate, or unstable stored values could leak into UI/runtime paths. | Drafts normalize text/count/duration/channel fields; warning records normalize densely, reject invalid API writes, preserve edit identity, and apply duplicate-name policy atomically. | Existing `RMA_Spammer` and `RMA_Warnings` tables are normalized in place. No schema version or non-RMA import was added. |
| LFM lifecycle | Generic chat state and callbacks could be stale, reentrant, or unbounded. | `Services.Spammer.Runtime` owns an immutable output/channel snapshot, generation-scoped timer, counters, contained callback dispatch, terminal-once outcomes, and scheduler/send failures. `Controllers.Spammer` calls Runtime directly and owns localized operational feedback. | Chat retains transport/announcement policy only; no lifecycle compatibility wrapper remains. The runtime file is TOC-loaded before controllers. |
| Draft clear | Config mutated the store directly, so a loaded Spammer frame could retain stale fields; window clear also stopped an active run. | Both surfaces use `Controllers.Spammer:RequestClearDraft()`. Clear returns completed canonical state and invalidates the loaded UI immediately. An active run keeps its immutable snapshot and pending callback; later starts use the cleared draft. | Channel selection remains preserved by the established clear contract. No active transport is cancelled or rewritten. |
| Chat delivery | Destination changes and WoW API failures were weakly represented, and callers could announce success after failure. | `Comms.SendChat` validates live raid/party/guild/officer/custom-channel state at the effect boundary, contains API errors, and returns a reason. Chat, spammer runtime, and warning controller preserve terminal results. | No addon-message prefix or payload changed. Local fallback remains explicit when no group announcement channel exists. |
| Warning mutations and feedback | Edits could drift by array position and controller feedback could describe attempted rather than confirmed delivery. | Store-owned candidate publication preserves the intended record and returns mutation details. Warning UI reports confirmed channel/local fallback or the terminal failure reason. | Saved warning content remains compatible after canonical normalization; no channel migration is required. |

## Exact Limits And Channel Policy

- Spammer name, class text, and stored channel names: 64 bytes; message/output:
  255 bytes; role counts: 0-9; draft duration: 1-999 seconds with default 60.
- Active runtime: minimum interval one second, at most 30 delivery attempts and
  at most 1,800 elapsed seconds per run.
- Warning names: 64 bytes; warning content: 255 bytes. Public save/update rejects
  empty, invalid UTF-8, or oversized values rather than silently accepting them.
- Persisted channels are dense, case-insensitively deduplicated strings. Numeric
  channel IDs are discarded during normalization because they are session-local;
  stable built-ins and named channels remain. Named channels resolve to a live
  numeric ID immediately before sending. Raid/party group state, guild membership,
  officer permission, and raid-warning rank are checked live. Whisper validation
  checks only for a non-empty target. SAY, YELL, and EMOTE are delegated to the
  client without a contextual availability check.

## SavedVariables, Wire, TOC, And Registry Coherence

- SavedVariables remain the six TOC-declared `RMA_*` tables. No schema version,
  key name, migration source, or import path changed.
- Addon-message prefixes and payloads are unchanged; this batch changes ordinary
  chat result handling only.
- `Services/Spammer/Runtime.lua` is the only new runtime owner and is referenced
  by the TOC after Draft and before the controllers. All other changed runtime
  files remain TOC-referenced. No runtime files were deleted or left untracked.
- The repository has no separate ModuleRegistry file or registry entry for these
  owners. The TOC remains the authoritative load order, so there is no stale
  registry dependency.
- XML remains layout-only and no frame identity changed. Vendored `Libs/` files
  were not modified.

## Validation Evidence

- Focused TDD RED: the new owner-action case failed because
  `RequestClearDraft` was absent; the Config contract failed because clear still
  called Draft directly. The completed-state assertion then failed because
  `ClearDraft` returned `nil` for canonical text fields.
- Focused GREEN: three focused tests passed after the minimal owner action,
  Config delegation, active-run preservation, and completed normalization.
- Final review `unittest`: 203 tests passed.
- TOC validator: one file, zero errors and warnings.
- Lua 5.1 validator: 134 files clean.
- Lua 5.1 xpcall scan: 134 files clean.
- XML handler scan: no script blocks or event handlers under `UI/`.
- Whole-addon `luacheck` excluding vendored libraries: 121 files, zero warnings
  and zero errors.
- `git diff --check`: passed; Git emitted line-ending conversion notices only.
- `tools/check-rma.ps1`: not run because the repository does not contain it.

Final review RED covered disabled Stop/Resume after clear, missing scheduler and
delivery feedback, collapsed transport reasons, Chat lifecycle wrappers, and
escaping callbacks. Five focused review tests then passed after Runtime became
the direct lifecycle owner, callback dispatch became contained, Chat preserved
the first concrete failure, and the controller centralized localized terminal
feedback.

runtime smoke: deferred by user until the full refactoring program is complete

## Commit Coherence And Residual Risk

The batch changes the TOC-referenced owners `Modules/Comms.lua`,
`Services/Chat.lua`, `Services/Spammer/Draft.lua`,
`Services/Spammer/Runtime.lua`, `Services/Warnings/Store.lua`,
`Controllers/Spammer.lua`, `Controllers/Warnings.lua`, and
`Controllers/Config.lua`, plus English localization, tests, TOC, and final
documentation. There are no untracked runtime files or deleted runtime
references. The remaining risk is live-client behavior: server-specific channel
lists/rank flags, whisper target resolution, SAY/YELL/EMOTE availability enforced
by the client, chat throttling, timer execution across zoning/disconnect, and
visual refresh under real FrameXML. Those checks remain part of the deferred
full-program smoke test.
