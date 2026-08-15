# Phase 4: Milestone Verification - Research

**Researched:** 2026-08-15
**Domain:** WotLK 3.3.5a release validation, Lua 5.1 regression execution, SavedVariables safety, multi-client synchronization, combat lockdown, and taint evidence
**Confidence:** HIGH

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

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

### Deferred Ideas (OUT OF SCOPE)

None - discussion stayed within milestone verification scope. New features, UI redesign, protocol evolution, additional locale support, generic compatibility tooling, and import/migration utilities remain outside this corrective milestone.
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|---|---|---|
| QUAL-01 | Proprietary runtime Lua contains no non-ASCII characters outside localization data explicitly intended for non-English clients. | A repository scan excluding `Localization/` and `Libs/` finds exactly one `U+2192` at `Widgets/LootCounter.lua:418`; the correction is one comment-only replacement followed by the same zero-match scan. |
| QUAL-02 | The TOC validator, Lua 5.1 validator, variadic-`xpcall` scanner, XML handler scan, branding scan, and complete available automated test suite pass after the corrections. | Static gates already pass. The complete LuaJIT-backed discovery currently runs 507 tests in about 13 seconds and demonstrates six failing, stale harness contracts; their evidence and minimum likely fixes are mapped below. |
| QUAL-03 | A documented in-game smoke test verifies clean login, `/rma`, window creation, valid and quarantined SavedVariables reload, localized raid recognition, loot/reserve workflows, multi-client sync, combat lockdown, and taint behavior. | The recommended `04-IN-GAME-CHECKLIST.md` structure separates single-client profile safety, two-client localized sync/yell behavior, and clean combat/taint evidence. Every row remains `PENDING` until observed in a real client. |
</phase_requirements>

## Summary

Phase 4 is a verification-and-evidence phase, not a tooling or architecture phase. Reuse Python 3.12, the existing `unittest` suite, the existing Lua harness, LuaJIT 2.1, and the three WotLK validators. The only demonstrated proprietary runtime hygiene change is the ASCII replacement at `Widgets/LootCounter.lua:418`. Static compatibility gates are already clean: TOC reports 0 errors/0 warnings, Lua 5.1 lint reports 147 addon-plus-harness files clean, variadic `xpcall` reports 137 addon files clean, and XML/modern-API scans return no prohibited matches.

Fresh full discovery exposed a previously hidden integration problem because prior phase verification ran focused owner suites. With LuaJIT exposed as `lua`, 507 tests run in 13.2 seconds and six fail. Source inspection shows one obsolete destructive archive expectation and five incomplete/stale fixtures after the Phase 1 and Phase 2 contracts changed. These are demonstrated test-suite gaps, not evidence for a broad runtime refactor. The planner should repair each focused contract, rerun only the six methods, then run full discovery once.

`QUAL-03` remains genuinely manual. Automated agents can create the checklist and exact commands, but cannot claim a real server yell, two-client state convergence, SavedVariables writeback, combat-lockdown safety, or taint cleanliness. A missing locale/client/encounter is a blocking `PENDING`, not an approval substitute.

**Primary recommendation:** Use two plans: first close the one-line ASCII issue and six evidenced harness gaps before running one final automatic gate; then create and execute a blocking, privacy-safe in-game checklist whose incomplete rows keep Phase 4 open.

## Standard Stack

### Core

| Tool | Version / path | Purpose | Why standard here |
|---|---|---|---|
| Python | 3.12.13 at the bundled Codex runtime path | `unittest` discovery, validators, deterministic repository scans | Already runs every repository test wrapper and all three validators; no dependency installation is needed. |
| LuaJIT | 2.1.1720049189 at `C:\tools\LuaJIT\bin\luajit.exe` | Execute Lua 5.1 behavior cases | Reports `_VERSION == "Lua 5.1"` and passes the harness's `lua_51_smoke` contract. |
| `tests/lua_test_runner.py` | repository-owned | Resolve a command named `lua` and spawn each Lua case | Existing Python/Lua integration seam; preserve it rather than altering runner contracts. |
| `unittest` | Python standard library | Complete automated suite | `python -m unittest discover -s tests -p "test_*.py"` discovers all current tests. |
| WotLK validator scripts | repository skill copies | TOC, Lua 5.1 syntax, and variadic-`xpcall` gates | Already tailored to Interface 30300 and this repository. |
| Real WotLK clients | build 3.3.5a / Interface 30300 | SavedVariables, localization, addon-message transport, combat, taint | These runtime properties cannot be substituted by the harness. |

### Supporting

| Tool | Purpose | When to use |
|---|---|---|
| `rg` | XML, forbidden API, feature `OnUpdate`, branding, and scope scans | Read-only policy gates; exclude `**/Libs/**` explicitly. |
| `git diff --check` | Whitespace/patch sanity | At the focused correction and final gate. |
| External temporary `lua.exe` hard link | Make `shutil.which("lua")` resolve LuaJIT | Create outside the repository and prepend both the alias directory and LuaJIT DLL directory to `PATH`. |
| Clean `Logs/taint.log` plus script-error UI | Attribute live failures to the exact session | Archive/clear before the test, run with other addons disabled where practical, inspect only after the tested workflow. |

No packages, alternate test framework, generic release script, or new addon diagnostic subsystem is warranted.

## Validation Baseline and Demonstrated Gaps

### Fresh baseline

| Gate | Fresh result | Planning implication |
|---|---|---|
| Complete `unittest` discovery with LuaJIT | 507 run, 501 pass, 6 fail, ~13.2 s | Blocking; repair the six evidenced test contracts before the final gate. |
| TOC validator | 0 errors, 0 warnings | Re-run unchanged after corrections. |
| Lua 5.1 lint on addon plus `tests/lua` | 147 files clean | Re-run both trees because harness files will change. |
| Variadic `xpcall` scanner | 137 addon files clean | Re-run addon tree. |
| Proprietary XML handler scan | zero matches | Scan all proprietary XML, not only one file. |
| Forbidden modern API scan | zero matches outside `Libs/` | Keep `C_Timer`, `C_AddOns`, `Settings.*`, `MenuUtil`, `SetAtlas`, and `SetColorTexture` at zero. |
| Proprietary `OnUpdate` inventory | exactly one match, `Modules/Timer.lua:164` | This is the established shared scheduler; zero feature-frame polling is the contract. Do not remove it speculatively. |
| Proprietary runtime ASCII scan | one match: `Widgets/LootCounter.lua:418`, `U+2192` | Replace only the arrow and require zero after exclusion of `Localization/` and `Libs/`. |

### Six failing contracts and minimum likely scope

| Failing case | Evidence | Classification | Minimum correction to plan |
|---|---|---|---|
| `instance_datasets_share_canonical_identity` | The fixture replaces `addon.L` and `addon.Diag` with narrow tables, then exercises the new unknown-raid warning path; `Init.lua:971` receives a nil warning template. | Incomplete Phase 2 fixture | Seed the warning and diagnostic keys required by the exercised path; do not guard or weaken production logging. |
| `unknown_raid_retry_recovers_without_warning_spam` | Its diagnostic fixture defines three templates but omits `LogRaidUnknownInstance`; debug mode intentionally exercises `Init.lua:974`. | Incomplete Phase 2 fixture | Add the missing ASCII diagnostic format to the fixture, retaining assertions for one warning and one diagnostic. |
| `bootstrap_raid_archive_quarantine_is_degraded_and_recovers` | `newAddon()` intentionally has no `L` table; this case assigns through `fixtureAddon.L` before loading `Init.lua`. | Fixture initialization error | Initialize the case-local localization table before assigning quarantine labels; do not add a production fallback. |
| `raid_replication_archive_reload` | It expects an unsupported beta array to reset to format 1, directly contradicting PERS-01 and current quarantine behavior. | Obsolete pre-Phase-1 test contract | Start this reload-position case from nil or an explicit valid canonical archive, rename the Python method away from “beta resets,” and leave unsupported/future preservation to the dedicated Phase 1 cases. Do not restore destructive migration. |
| `raid_session_uses_transient_canonical_identity` | The historical fixture record has no `size` or `difficulty`, so `Session.Check()` correctly sees a semantic mismatch and creates. | Unrealistic Phase 2 fixture | Give the historical record the same valid size/difficulty as the first bound canonical context; retain the assertions that localized-name-only change does not create and canonical identity change does. |
| `raid_live_sync_group_loot_leader_authority` | The fixture calls `ScheduleInstanceChecks()` without the Init-owned canonical context commit introduced in Phase 2, so neither client reaches `Create`. | Stale integration fixture | Explicitly commit the recognized ICC context for both clients before scheduling; retain all authority, R5 snapshot, and convergence assertions. |

Run these exact six Python methods first after repair. Only after they all pass should full discovery run again. If any focused method still fails twice without new evidence, stop instead of adding runtime fallbacks.

## Architecture Patterns

### Pattern 1: External runner alias, unchanged repository contract

`tests/lua_test_runner.py` deliberately calls `shutil.which("lua")`. Create an idempotent hard link outside the worktree and prepend its directory plus the LuaJIT binary directory to the current process `PATH`:

```powershell
$pythonExe = 'C:\Users\Massimo\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe'
$luaBin = 'C:\tools\LuaJIT\bin'
$aliasDir = Join-Path ([System.IO.Path]::GetTempPath()) 'rma-phase4-lua-alias'
New-Item -ItemType Directory -Path $aliasDir -Force | Out-Null
$luaAlias = Join-Path $aliasDir 'lua.exe'
if (-not (Test-Path -LiteralPath $luaAlias)) {
    New-Item -ItemType HardLink -Path $luaAlias -Target (Join-Path $luaBin 'luajit.exe') | Out-Null
}
$env:PATH = $aliasDir + ';' + $luaBin + ';' + $env:PATH
& $pythonExe -m unittest discover -s tests -p 'test_*.py'
```

The LuaJIT directory must remain on `PATH` so its adjacent DLLs resolve. Do not copy or rename binaries inside the repository.

### Pattern 2: Focused disproof, then one full gate

1. Replace the one arrow and run only the proprietary ASCII scan.
2. Repair each demonstrated fixture contract and run the six failing Python methods together.
3. Run complete discovery once.
4. Run static validators and policy scans once on the final tree.
5. Record command, exit status, count, and concise result in the phase summary/checklist; do not paste entire logs.

This follows the repository's two-repair-cycle rule and keeps runtime edits driven by evidence.

### Pattern 3: Manual evidence is a blocking checkpoint

Create `.planning/phases/04-milestone-verification/04-IN-GAME-CHECKLIST.md` with metadata followed by numbered rows containing `Expected`, `Actual`, `Status`, and privacy-safe `Evidence`. Initial status is `PENDING`. The executor may prepare commands and fixtures, but the user must supply observed results. Do not prefill `PASS` from static tests or prior approval.

Recommended checklist groups:

1. Preflight: exact commit/version, build, server environment, date, roles/locales, RMA-only addon profile where practical, client closed for backup/log handling, `/console scriptErrors 1`, `/console taintLog 2`, then `/reload`.
2. Clean profile: only the six canonical `RMA_*` keys appear; login, `/rma`, minimap/QuickBar, and principal windows produce no Lua errors.
3. Valid profile: a recognizable history marker plus representative values for all six variables survives logout/login and `/reload` and remains usable.
4. Future profile: one warning, archive block/sanitized digest preserved, history visibly read-only, history mutation/replication rejected, unrelated features usable.
5. Recovery: restore the valid backup with client closed; normal history returns without a persisted quarantine flag or confirmation.
6. Localized raid/yell: English authority plus one supported non-English member enter the same canonical raid; display names remain local; one real catalogued server yell records only exact text in correct scope.
7. Multi-client sync: raid history, Reserves, and Distribution converge with compatible R5 behavior.
8. Combat/taint: exercise normal entrypoints, windows, selection/refresh, and sync during combat; inspect script errors and the clean-session taint log after combat/logout.

### Pattern 4: Real request-boundary observation

Use normal wire paths with debug logging enabled for observation, not synthetic debug data:

- Reserves requester: run `/rma reserves sync`, repeat immediately, then repeat after at least five seconds. On the authority, the first and post-expiry `META_REQ`/`DATA_REQ` paths may produce response work; the immediate equivalent request must be rate-limited. Compare `/rma reserves meta` and visible reserve state.
- Distribution requester: invoke `/run RMA.Services.Loot.DistributionSession.RequestSnapshot()` three times with the same timing. `RMA` is the production global exported by `Init.lua`; this calls the real R5 `SNAP_REQ` path. On the authority, `LogDistributionSnapshotSent` must occur for the first and post-expiry request, not for the immediate duplicate; visible distribution models converge.
- Raid history: use the normal Logger/current-raid sharing or synchronization UI/entrypoint and compare the recognizable record on both clients. In quarantine, the same history operation must remain unavailable/rejected while Reserves and Distribution stay independent.

Debug output is observational evidence only. The clients must actually exchange messages and converge.

## Don't Hand-Roll

| Problem | Do not build | Use instead | Reason |
|---|---|---|---|
| Lua 5.1 behavior execution | New Python-to-Lua adapter or alternate framework | Existing `lua_test_runner.py` plus external LuaJIT alias | Preserves 507 existing contracts and introduces no repository tool. |
| TOC/Lua/xpcall validation | New regex suite | Existing skill scripts | They already encode Interface 30300 and Lua 5.1 traps. |
| Future archive inspection/recovery | In-addon migration, repair button, or import utility | Disposable external SavedVariables profile plus backup/restore | Migration and import are explicitly out of scope; quarantine must remain fail-closed. |
| Sync-rate testing | New debug wire protocol or payload | Production `/rma reserves sync` and `DistributionSession.RequestSnapshot()` paths | Wire version and payloads are compatibility-sensitive. |
| Taint suppression | Error swallowing, `pcall` around secure calls, or warning exemptions | Clean log, normal operations, and existing `InCombatLockdown()` boundary | A suppressed error is not evidence of safety and may spread taint. |
| Locale coverage replay | Manual execution of all 60 strings | Existing catalog contracts plus one real localized server yell | Automation owns completeness; live testing owns integration. |

## Common Pitfalls

### Treating a failing old assertion as a product regression

The archive-reload case still demands the destructive behavior Phase 1 intentionally removed. Restoring that behavior would violate PERS-01. Update the test purpose to valid canonical reload continuity and retain the dedicated unsupported-archive cases.

### Weakening production logging to satisfy narrow fixtures

Three failures are missing `L`/`Diag` fixture keys. Adding nil guards in `Init.lua` would hide broken load-order contracts. Complete the fixtures instead.

### Running only focused Phase 1–3 suites

Focused owner suites previously passed while six cross-phase cases remained broken. `QUAL-02` requires full discovery with Lua-backed cases, so the final gate must be repository-wide.

### Misinterpreting the shared timer `OnUpdate`

The only proprietary `OnUpdate` is the established scheduler in `Modules/Timer.lua`. Phase 4 must reject new feature polling, not delete the shared WotLK-compatible timer engine.

### Calling a missing tool a pass

LuaJIT is available and must be exposed as `lua`. If a real localized client, encounter, second client, or taint environment is unavailable, leave the matching row `PENDING` and the phase open.

### Contaminated taint evidence

Old logs and other addons make attribution ambiguous. Archive or clear the prior log with the client closed, prefer an RMA-only addon profile, reload after enabling taint/script errors, and inspect only the new session. Any RMA-attributable `ADDON_ACTION_BLOCKED`, `ADDON_ACTION_FORBIDDEN`, protected failure, Lua error, or taint line blocks acceptance.

### Unsafe SavedVariables handling

WoW writes SavedVariables on logout/reload. Never edit while the client is open and never test on the only copy. Use three isolated disposable profiles. Record only a sanitized marker or digest; do not commit WTF data.

### File hash versus archive equivalence

The whole SavedVariables file can change because unrelated canonical owners persist normally. For the future-format profile, preserve and compare the isolated `RMA_Raids` serialized block or its privacy-safe digest before and after; do not require unrelated file bytes to remain static and do not normalize the archive to make comparison easier.

### Rate-limit observability without convergence

A debug rejection alone is insufficient. Record both no duplicate response work and visible post-request convergence on both clients, then prove admission resumes after at least five seconds.

## Exact Automated Gate

Use the bundled Python executable (stored in `$pythonExe` above) and the external Lua alias. After focused fixes are green:

```powershell
& $pythonExe -m unittest discover -s tests -p 'test_*.py'
& $pythonExe '.agents/skills/wow-addon-dev-wotlk-v335a/scripts/validate_toc.py' 'Raid Management Addon/Raid Management Addon.toc'
& $pythonExe '.agents/skills/wow-addon-dev-wotlk-v335a/scripts/lint_lua51.py' 'Raid Management Addon' 'tests/lua'
& $pythonExe '.agents/skills/wow-addon-dev-wotlk-v335a/scripts/scan_xpcall.py' 'Raid Management Addon'
rg -n '<Scripts>|<On[A-Za-z]+>' 'Raid Management Addon' -g '*.xml' -g '!**/Libs/**'
rg -n 'C_Timer|C_AddOns|Settings\.|MenuUtil|SetAtlas|SetColorTexture' 'Raid Management Addon' -g '*.lua' -g '*.xml' -g '!**/Libs/**'
rg -n 'SetScript\s*\(\s*["'']OnUpdate["'']' 'Raid Management Addon' -g '*.lua' -g '!**/Libs/**'
git diff --check
```

Interpretation:

- XML and forbidden-modern-API commands must return zero matches.
- The proprietary `OnUpdate` inventory must return exactly `Modules/Timer.lua:164` and no feature owner.
- The ASCII scan should be a small Python read of proprietary `.lua` files that excludes top-level `Localization` and `Libs` and fails if any code point exceeds 127. After the arrow correction it must report zero.
- The retired-identifier pattern must be supplied from a temporary external file or process variable and searched across proprietary `.lua`, `.xml`, `.toc`, and `.md` paths with `Libs/` excluded. Do not write the sensitive pattern into this plan, research, tests, or other repository artifacts.
- A normal `rg` zero-match exit code is `1`; the gate wrapper/checklist must distinguish this expected no-match result from execution failure (`2+`).

## Minimal Plan Decomposition

### Plan 04-01: Close automated blockers

1. Replace the single arrow comment and prove zero proprietary non-ASCII hits.
2. Repair the six demonstrated harness contracts without production fallbacks or weakened assertions; run their six Python methods.
3. Run full discovery once, then every static/policy gate. Record concise evidence and stop if any blocker remains.

Likely files: `Widgets/LootCounter.lua`, `tests/lua/harness/20_raid_database.lua`, `30_raid_runtime.lua`, `40_inspect_foundations.lua`, `70_raid_sync.lua`, and the one stale Python test method name in `tests/test_raid_replication_behavior.py`.

### Plan 04-02: Obtain live milestone evidence

1. Create `04-IN-GAME-CHECKLIST.md` with all rows `PENDING`, exact metadata fields, expected/actual/status/evidence columns, and privacy rules.
2. Human checkpoint: complete clean/valid/future/recovery SavedVariables and base UI checks.
3. Human checkpoint: complete English-authority/non-English-member localized raid/yell, three sync paths, request timing, combat, and clean taint/error evidence; only then change every row to `PASS` and satisfy QUAL-03.

If the live environment demonstrates a failure, add only the minimum evidenced runtime correction and focused retest. Do not pre-plan speculative runtime edits.

## Open Questions / Human Inputs

1. Which supported non-English client is available (`frFR`, `esES`, `ruRU`, or `zhCN`)? This may remain a checklist placeholder until execution.
2. Which verified fallback encounter can the server emit during the test window? Select one already present in the 60-entry evidence catalog; do not add locale data for convenience.
3. What normal UI action will initiate current-raid history sync on the chosen server/client setup? Prefer the existing Logger share/sync control; record the exact action in the checklist.

None of these questions blocks automated Plan 04-01 or checklist creation. They do block final `QUAL-03` acceptance if unresolved.

## Sources

### Primary (HIGH confidence)

- `.planning/phases/04-milestone-verification/04-CONTEXT.md` - locked acceptance choices and privacy constraints.
- `.planning/REQUIREMENTS.md` and `.planning/ROADMAP.md` - QUAL-01 through QUAL-03 and milestone boundary.
- `AGENTS.md` - WotLK/Lua 5.1, ownership, SavedVariables, UI, wire, and validation policies.
- `.agents/skills/wow-addon-dev-wotlk-v335a/references/lua-51-compatibility.md` - Lua 5.1 and variadic-`xpcall` constraints.
- `.agents/skills/wow-addon-dev-wotlk-v335a/references/frame-xml-cookbook.md` - secure UI, combat-lockdown, taint, and `OnUpdate` guidance.
- Repository source and fresh command output dated 2026-08-15 - 507-test baseline, six failure traces, static-validator results, ASCII code point inventory, and `OnUpdate` inventory.
- Phase 1–3 verification reports - automated coverage already established and live gaps explicitly deferred to Phase 4.

## Metadata

**Confidence breakdown:**

- Automated stack and commands: HIGH - executed locally against the current branch.
- Six failure classifications: HIGH - each trace was connected to current line-numbered runtime and fixture source.
- WotLK compatibility/static gates: HIGH - repository validators and project skill references agree.
- Live checklist design: HIGH for required observations, MEDIUM for the exact available locale/encounter and server UI action until the user supplies the environment.

**Research date:** 2026-08-15
**Valid until:** Current branch changes; rerun the baseline if runtime/test files change before execution.
