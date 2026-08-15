# Phase 4 In-Game Acceptance Checklist

Checklist revision: 1

This document records only human-observed WotLK 3.3.5a results. Automated
evidence from Plan 04-01 does not satisfy or prefill any row below.

## Acceptance Rules

- Valid row statuses are `PASS`, `FAIL`, and `PENDING` only.
- Every required row must be human-observed `PASS` to satisfy `QUAL-03`.
- An unavailable client, locale, encounter, log environment, or observation
  remains `PENDING` and keeps Phase 4 open.
- A `FAIL` blocks completion and requires an evidence-driven gap plan. Do not
  weaken the expected result or infer a later `PASS` from automated tests.
- Edit or copy SavedVariables only while every affected client is closed. Use
  disposable copies and retain a valid backup.
- Never commit WTF files, SavedVariables contents, full logs, account or
  character names, loot records, or private identifiers.
- Evidence may contain only sanitized markers or digests, concise excerpts,
  and external log filenames that disclose no private identifier.
- This checklist is planning evidence. Do not add it to the addon TOC or a
  release package, and do not create repository fixtures from client data.

## Test Metadata

Complete these fields from the exact live session before marking rows `PASS`.

| Field | Recorded value |
|---|---|
| Tested Git commit | PENDING |
| Addon TOC version | PENDING (repository preparation value: `0.1.0-alpha.1`) |
| Client build | PENDING (expected WotLK 3.3.5a build `12340`) |
| TOC Interface | PENDING (expected `30300`) |
| Server/test environment | PENDING (sanitized description only) |
| Test date | PENDING |
| Addon profile | PENDING (RMA-only where practical) |
| SavedVariables profile category | PENDING (clean / valid / future / recovered-valid) |
| English authority locale/role | PENDING |
| Non-English member locale/role | PENDING |
| Canonical raid under test | PENDING |
| Catalogued fallback encounter | PENDING |
| Clean taint-log session | PENDING |
| External fresh taint-log filename | PENDING (filename only) |

## Single-Client and SavedVariables Observations

Use three isolated profile categories: clean, valid, and unsupported future
`RMA_Raids`. The valid profile must include representative values for all six
canonical keys and one recognizable sanitized history marker. Compare only a
privacy-safe digest of the isolated future `RMA_Raids` serialized block; the
whole SavedVariables file may legitimately change.

| No. | Profile | Expected | Actual | Status | Evidence |
|---:|---|---|---|---|---|
| 1 | Preflight | With the client closed, a disposable test copy and separate valid backup exist; no sole real-data copy is edited. | PENDING | PENDING | PENDING |
| 2 | Preflight | Exact commit, TOC version, build `12340`, Interface `30300`, sanitized environment, date, and addon profile are recorded above. | PENDING | PENDING | PENDING |
| 3 | Clean | Login produces no RMA Lua error and initializes only `RMA_Raids`, `RMA_Players`, `RMA_Reserves`, `RMA_Warnings`, `RMA_Spammer`, and `RMA_Options` as public RMA SavedVariables. | PENDING | PENDING | PENDING |
| 4 | Clean | `/rma`, minimap/QuickBar, and principal windows open normally without missing-frame or RMA Lua errors. | PENDING | PENDING | PENDING |
| 5 | Valid | Before reload, representative values for all six canonical variables and the sanitized history marker are readable; unrelated features are usable. | PENDING | PENDING | PENDING |
| 6 | Valid | After `/reload` and a logout/login cycle, all representative values and the marker remain readable and unrelated features remain usable. | PENDING | PENDING | PENDING |
| 7 | Future | Installing the unsupported future-format `RMA_Raids` profile with the client closed produces exactly one quarantine warning for the observed login/reload cycle. | PENDING | PENDING | PENDING |
| 8 | Future | The isolated future archive-block digest is equivalent before and after; history is visibly read-only/unavailable and history mutation and replication are rejected. | PENDING | PENDING | PENDING |
| 9 | Future | Configuration, Reserves, warnings, spammer, and other unrelated features continue to operate while raid history is quarantined. | PENDING | PENDING | PENDING |
| 10 | Recovered valid | After restoring the valid backup with the client closed, login and `/reload` restore normal history automatically, with no persisted quarantine flag or extra confirmation and without deleting the six keys. | PENDING | PENDING | PENDING |

## Localized, Multi-Client, Combat, and Taint Observations

Use two real WotLK 3.3.5a clients in the same real group or raid: one English
authority and one supported non-English member. Synthetic debug injection is
not evidence for a real server yell, live synchronization, combat, or taint.

| No. | Area | Expected | Actual | Status | Evidence |
|---:|---|---|---|---|---|
| 11 | Clean-session preflight | With both clients closed, the prior taint log is archived or removed; `/console scriptErrors 1` and `/console taintLog 2` are enabled, followed by `/reload`; locales, roles, raid, encounter, and the external fresh-log filename are recorded above. | PENDING | PENDING | PENDING |
| 12 | Canonical localized raid | English authority and supported non-English member resolve the same supported canonical raid while each retains its localized display name. | PENDING | PENDING | PENDING |
| 13 | Real scoped yell | One exact, real server-emitted yell already present in the verified catalog records the selected encounter inside its expected canonical raid. | PENDING | PENDING | PENDING |
| 14 | Altered-yell control | An altered form of the catalogued yell does not record an encounter. | PENDING | PENDING | PENDING |
| 15 | Raid-scope control | The same exact yell outside its expected canonical raid does not record an encounter. | PENDING | PENDING | PENDING |
| 16 | Raid-history sync | The normal raid-history share/sync path converges the recognizable sanitized record exactly once on both clients with no protocol error. | PENDING | PENDING | PENDING |
| 17 | Quarantine independence | While raid history is quarantined and its sync is unavailable, Reserves and Distribution remain independently usable. | PENDING | PENDING | PENDING |
| 18 | Reserves first request | The member's first `/rma reserves sync` causes compatible authority response work and visible state convergence; `/rma reserves meta` agrees with the visible state. | PENDING | PENDING | PENDING |
| 19 | Reserves immediate repeat | An immediately repeated equivalent request causes no duplicate response work and does not disturb converged state. | PENDING | PENDING | PENDING |
| 20 | Reserves after five seconds | A new equivalent request after at least five seconds is admitted, causes compatible response work, and preserves visible convergence. | PENDING | PENDING | PENDING |
| 21 | Distribution first request | The member's first `/run RMA.Services.Loot.DistributionSession.RequestSnapshot()` causes one compatible authority snapshot response and visible model convergence. | PENDING | PENDING | PENDING |
| 22 | Distribution immediate repeat | An immediately repeated equivalent snapshot request causes no duplicate response work and does not disturb converged state. | PENDING | PENDING | PENDING |
| 23 | Distribution after five seconds | A new snapshot request after at least five seconds is admitted, causes a compatible authority response, and preserves visible convergence. | PENDING | PENDING | PENDING |
| 24 | Combat UI and sync | During combat, `/rma`, minimap/QuickBar, principal window open/close, selection/refresh, and normal sync requests operate or defer/reject safely without forcing protected automation. | PENDING | PENDING | PENDING |
| 25 | Lua and protected errors | The exact test session produces zero new RMA-attributable Lua errors, `ADDON_ACTION_BLOCKED`, `ADDON_ACTION_FORBIDDEN`, or protected-action failures. | PENDING | PENDING | PENDING |
| 26 | Fresh taint log | Inspection after combat/logout finds zero RMA-attributable taint lines in the fresh exact-session log. | PENDING | PENDING | PENDING |

## Result

- `QUAL-03`: PENDING
- Blocking rows: 1-26
- Completion rule: change `QUAL-03` to `PASS` only after every row above contains
  a human-supplied Actual result, privacy-safe Evidence, and Status `PASS`.
