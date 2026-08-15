# Phase 4: Milestone Verification - Context

**Gathered:** 2026-08-15
**Status:** Ready for planning

<domain>
## Phase Boundary

Close the corrective milestone with reproducible automated and in-game evidence that RMA remains compatible with WotLK 3.3.5a across proprietary runtime hygiene, full available regression coverage, SavedVariables reload and quarantine recovery, localized raid recognition, multi-client synchronization, combat lockdown, and taint-sensitive workflows.

This phase may correct only a failure directly demonstrated by an acceptance gate, including the one known non-ASCII proprietary runtime comment. It does not add features, redesign UI or architecture, broaden protocol behavior, create new compatibility layers, edit vendored libraries, or treat synthetic debug helpers as a substitute for live-client verification.

</domain>

<decisions>
## Implementation Decisions

### Automated acceptance gates
- The final automatic gate includes the complete discoverable Python suite with every Lua-backed case executed through the available LuaJIT runtime, not only tests added in Phases 1-3.
- The final gate also includes the TOC validator, Lua 5.1 validator, variadic-`xpcall` scanner, XML handler scan, forbidden modern API/timer scan, proprietary runtime ASCII scan, stale-branding scan, and `git diff --check`.
- Correct only the single demonstrated non-ASCII comment in `Widgets/LootCounter.lua`; replace its arrow with an ASCII representation. Do not rewrite unrelated comments or localization data.
- The ASCII gate applies to proprietary runtime Lua, comments, diagnostics, and UI text. Intentional non-English localization catalogs and vendored `Libs/` are excluded.
- Branding and retired-identifier checks require zero matches outside `Libs/`. Build any sensitive retired-identifier search pattern outside the repository and do not commit it into project artifacts.
- Any automatic gate failure blocks milestone completion. Diagnose and correct only the evidenced cause, rerun the nearest focused check first, and allow at most two repair cycles for the same failure without new evidence before stopping and reporting the changed understanding.
- Run the full suite once after focused repairs are green. Do not add exclusions, compatibility fallbacks, or weaker assertions merely to obtain a passing result.
- An unavailable required tool or environment is recorded as pending/blocked evidence, never converted into a pass. LuaJIT is already available and should be exposed to the existing Python runner rather than introducing another test framework.

### SavedVariables reload and quarantine recovery
- Perform live-client checks on three isolated profiles: a clean profile with no RMA SavedVariables, a valid profile containing all six canonical `RMA_*` values, and a representative unsupported future-format `RMA_Raids` profile.
- Use a disposable SavedVariables copy and retain a backup before editing. Close the client before copying or changing WTF data. Never use the only copy of real account data for destructive testing.
- The clean profile must log in without Lua errors, initialize only the canonical six `RMA_*` variables, open `/rma`, and create the main windows normally.
- The valid profile must carry a known raid-history record and representative data for the six `RMA_*` variables across logout/login and `/reload`. The known record remains readable and unrelated features remain usable.
- The future-format profile is the one representative manual quarantine case; malformed-format and non-table variants remain covered by automation rather than duplicated manually.
- Quarantine acceptance requires one warning for that login/reload, byte-equivalent preservation of the unsupported archive, visibly unavailable/read-only history, rejected history mutation/replication, and continued operation of configuration, reserves, warnings, spammer, and other unrelated features.
- Recovery requires restoring the valid backup with the client closed and then logging in or reloading. Normal history behavior must resume automatically with no persisted quarantine flag or extra confirmation.
- Never recover by deleting every RMA SavedVariable. Do not commit WTF files, SavedVariables contents, player names, loot records, or other account data as evidence.

### Localized multi-client verification
- Use two real WotLK 3.3.5a clients in the same group/raid: one English authority client and one member client using any one currently supported non-English locale available for the test.
- Automated catalog contracts remain responsible for complete coverage of every supported locale. The live localized client proves actual client/server integration and does not need to replay all 60 catalog strings.
- Both clients must recognize the same supported raid through canonical identity while retaining their localized display names.
- Exercise all three relevant synchronization paths: raid-history synchronization, Reserves metadata/data synchronization, and loot Distribution snapshot synchronization.
- For Reserves and Distribution, prove the first compatible request succeeds, an immediate repeated request does not create duplicate response work, and a new request after at least five seconds succeeds. The observable states on authority and member must converge without protocol-version or payload incompatibility.
- Use one real server-emitted fallback yell for an encounter already present in the verified catalog while the localized client is in the correct canonical raid. The exact payload must record the boss; altered text or the same text outside the expected raid must not create a record.
- Synthetic `/rma debug` helpers may prepare or inspect state but do not satisfy the real multi-client, real raid, or server-emitted yell acceptance step.
- If a suitable supported encounter or localized client is unavailable, retain that item as explicit human verification pending; do not mark `QUAL-03` complete from static evidence alone.

### Combat lockdown, taint, and error evidence
- Start from a clean test session: with the client closed, archive or remove the previous taint log, enable `taintLog 2` and Lua script-error reporting, then `/reload` before beginning the checklist.
- During combat, exercise normal RMA entrypoints and operational UI: `/rma`, minimap and QuickBar access, opening/closing principal windows, selection and refresh interactions, and synchronization requests.
- Operations that are not legal during combat must be deferred or rejected safely. Do not force spell casts, macro execution, targeting, item use, or other protected automation outside RMA's normal behavior.
- Acceptance requires zero new RMA-attributable Lua errors, `ADDON_ACTION_BLOCKED`, `ADDON_ACTION_FORBIDDEN`, protected-action failures, or taint-log entries caused by the tested RMA workflow.
- A warning or taint line is not waived because the UI appears to work. Any attributable result is a blocking gap until its evidenced cause is corrected and the focused live step is repeated from a clean log.
- Record final evidence in a versioned Markdown checklist. Include client build, server/test environment, date, locales, client roles, SavedVariables profile category, numbered steps, expected result, actual pass/fail, and concise notes.
- Reference relevant log filenames or sanitized excerpts/digests only. Do not commit full taint logs, WTF files, account identifiers, character names, loot contents, or other private data.

### Codex's Discretion
- Exact plan decomposition and ordering between the one-line ASCII correction, automated gate execution, checklist creation, and human-verification checkpoints.
- Exact supported non-English locale and fallback encounter used for the live test, based on what the user can run, provided the locked English-authority/non-English-member topology and real server payload remain satisfied.
- Exact Markdown filename and compact checklist layout inside the Phase 4 planning directory.
- Exact commands used to expose `C:\tools\LuaJIT\bin\luajit.exe` as `lua` to the existing Python runner without modifying repository runtime or test contracts.
- Exact sanitized evidence wording and log references, provided every required step has an unambiguous pass/fail result.

</decisions>

<specifics>
## Specific Ideas

- Automatic acceptance is one final reproducible gate, not a new tooling project: reuse the existing Python/unittest discovery, Lua harness, and WotLK validator scripts.
- The known proprietary non-ASCII finding is the arrow in `Raid Management Addon/Widgets/LootCounter.lua:418`; the minimal correction is an ASCII-only comment change.
- The valid reload profile should include one deliberately recognizable history record so persistence is proven by content, not merely by table existence.
- The two live clients should compare visible state after each sync path and record which client initiated the request and which client held authority.
- Taint evidence is attributable only when collected from a freshly archived/cleared log for the exact checklist session.
- A checklist item left pending keeps Phase 4 and the milestone open; it is not silently converted into success by prior static or fixture evidence.

</specifics>

<code_context>
## Existing Code Insights

### Reusable Assets
- `.agents/skills/wow-addon-dev-wotlk-v335a/scripts/validate_toc.py`: validates Interface 30300 metadata, unsupported directives, SavedVariables declarations, and referenced files.
- `.agents/skills/wow-addon-dev-wotlk-v335a/scripts/lint_lua51.py`: validates proprietary runtime and harness syntax against Lua 5.1 constraints.
- `.agents/skills/wow-addon-dev-wotlk-v335a/scripts/scan_xpcall.py`: detects the Lua 5.1 variadic-`xpcall` trap.
- `tests/lua/runtime_harness.lua` and `tests/lua_test_runner.py`: existing behavior execution path; an installed LuaJIT runtime is available at `C:\tools\LuaJIT\bin\luajit.exe`.
- `tests/test_localization_contract.py`: already owns localization and RMA branding contracts and should remain part of full discovery.
- Phase verification reports under `.planning/phases/01-*`, `02-*`, and `03-*`: existing evidence for the corrected persistence, localized recognition, and bounded communication behaviors.
- `AGENTS.md`: already defines the base smoke sequence, six canonical SavedVariables, runtime scans, packaging exclusions, and privacy-safe retired-identifier search policy.

### Established Patterns
- The repository currently contains one demonstrated non-ASCII proprietary runtime comment at `Raid Management Addon/Widgets/LootCounter.lua:418`; intentional locale data and vendored libraries contain non-ASCII bytes by design.
- `Modules/UI/Frames.lua` already uses `InCombatLockdown()` to defer or reject frame work at its shared UI boundary; the live combat test must verify the behavior rather than redesign it speculatively.
- `/rma` debug helpers documented in the README are local synthetic tools and are explicitly not a live-raid smoke test.
- Phase 1 automation covers valid, malformed, non-table, and future-format archives, while the live checklist still needs an actual client reload/quarantine/recovery cycle.
- Phase 2 automation covers all supported locale catalog values and exact instance scoping, while the live checklist still needs one localized client and real server-emitted encounter payload.
- Phase 3 automation proves exact request admission boundaries and no rejected response work, while the live checklist still needs multi-client compatibility and visible convergence.

### Integration Points
- Apply the one-line ASCII comment correction only in `Raid Management Addon/Widgets/LootCounter.lua` and protect it with a repository-level proprietary-runtime scan or focused contract.
- Create the repeatable acceptance checklist under `.planning/phases/04-milestone-verification/`; do not add it to the addon package or runtime TOC.
- Run full Python discovery with LuaJIT visible to the existing runner, then the WotLK validators and repository policy searches from `AGENTS.md`.
- Use client-side SavedVariables files only as external disposable fixtures; record sanitized outcomes in the checklist rather than importing those files into the repository.
- Use clean taint/error logs outside the repository during execution and record only pass/fail plus privacy-safe references in the checklist.
- Treat the live-client steps as blocking human-verification checkpoints in the execution plan; automated agents can prepare exact instructions and evidence fields but cannot assert observed in-game success.

</code_context>

<deferred>
## Deferred Ideas

None - discussion stayed within milestone verification scope. New features, UI redesign, protocol evolution, additional locale support, generic compatibility tooling, and import/migration utilities remain outside this corrective milestone.

</deferred>

---

*Phase: 04-milestone-verification*
*Context gathered: 2026-08-15*
