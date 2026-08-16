# Phase 7: UI Simplification Verification - Context

**Gathered:** 2026-08-16
**Status:** Ready for planning

<domain>
## Phase Boundary

Close the v1.1 UI Simplification milestone with reproducible evidence that the Phase 5 runtime-surface cleanup and Phase 6 Logger/Attendance primitive consolidation preserve the addon's existing UI, localization, runtime, persistence, communication, public-entrypoint, vendored-library, and WotLK 3.3.5a contracts.

This phase may correct only a regression directly demonstrated by an acceptance gate. It does not add features, redesign UI or architecture, broaden protocols, change SavedVariables, edit vendored libraries, introduce compatibility layers, or begin the deferred dependency-optimization work.

</domain>

<decisions>
## Implementation Decisions

### Automated acceptance gate
- Use the complete discoverable Python suite with every Lua-backed case executed through the existing LuaJIT-compatible runner; milestone-specific tests alone are insufficient.
- Run all applicable WotLK 3.3.5a static gates: TOC validation, Lua 5.1 lint, variadic-`xpcall` scan, XML layout-only scan, forbidden modern API scan, proprietary runtime hygiene checks, and `git diff --check`.
- Compare the completed v1.1 runtime against the exact pre-Phase 5 baseline. XML, TOC, localization, `Libs/`, the six canonical SavedVariables, version-5 wire contracts, and supported public entrypoints must remain unchanged; functional-equivalence exceptions are not accepted for these protected surfaces.
- After any failure, diagnose and repeat the nearest focused check first. Run one complete automatic gate only after focused repairs are green; do not repeatedly run the full suite after each edit.
- The final report must record the baseline/final Git range, exact commands or reproducible command forms, test and validator counts, protected surfaces inspected, and unambiguous results.

### Live-client verification
- Reuse the Phase 6 approved Logger and Attendance in-game smoke evidence; do not repeat those complete checks without a new failure or relevant code change.
- Exercise Screen Notice through a normal operational loot/raid path that publishes the internal event. A synthetic debug invocation alone does not satisfy the observed check.
- Exercise Trade through both a successful completion and an uncertain or failed verification followed by retry. The uncertain attempt must not be recorded prematurely, and the successful retry must complete normally.
- Exercise Loot initialization after login or `/reload` while a raid is active. Normal loot-facing UI/state must remain coherent and no Lua error may occur.
- Record only what was actually observed in the client. Existing Phase 5 automation and Phase 6 approval may be cited, but they must not be relabeled as a new live observation.

### Failure and unavailable-test policy
- Any automated or live regression attributable to the v1.1 simplification blocks completion and authorizes only a correction targeted at the evidenced cause.
- After a correction, repeat the failed or nearest focused test first, then the single final automatic gate. Do not repeat unrelated live checks unless the change can affect them.
- Allow at most two repair cycles for the same failure without new evidence. If it still fails, stop, reassess the diagnosis, and report the blocker rather than layering further speculative fixes.
- A live step that cannot be executed because its required environment or scenario is unavailable is recorded as `DEFERRED` with an explicit residual risk. It is never converted into `PASS`.
- Consistent with the previously approved accepted-risk policy, the phase may close with clearly documented `DEFERRED` live evidence when all available automatic and observed checks pass and no known regression remains.

### Final evidence report
- Produce one versioned phase acceptance report organized into `AUTOMATED`, `OBSERVED`, and `DEFERRED` sections.
- Each check records its expected result, actual result, evidence or sanitized reference, and final disposition.
- Do not commit WTF files, SavedVariables contents, full taint/error logs, account identifiers, character names, loot contents, or other private client data. Store only concise sanitized references, excerpts, or digests when useful.
- End with an explicit mapping to `QUAL-01` and `QUAL-02`, a milestone go/no-go disposition, and a list of residual risks. A test summary without a formal conclusion is insufficient.

### Codex's Discretion
- Exact plan decomposition and ordering between baseline comparison, automatic gates, report preparation, and human checkpoints.
- Exact report filename and compact table layout inside the Phase 7 planning directory.
- Exact focused checks used after a demonstrated failure, provided they are the narrowest checks that can disprove the repair.
- Exact sanitized wording for client evidence and residual risks.

</decisions>

<specifics>
## Specific Ideas

- Use commit `539a651d961bdfab25a7a7ebf849041f1a3ec75e` as the pre-Phase 5 runtime baseline; it is the parent of the first Phase 5 implementation commit.
- The intended v1.1 production diff is limited to six runtime files: `Modules/UI/ScreenNotice.lua`, `Services/Master/Trade.lua`, `Services/Loot/State.lua`, `Modules/UI/ListController.lua`, `Controllers/Logger.lua`, and `Controllers/Attendance.lua`.
- Treat the approved Phase 6 observation that Force Inspect updates the Attendance row, while `Pending` appears only as immediate chat feedback, as valid existing `OBSERVED` evidence.
- Keep Phase 7 an acceptance exercise, not a new test framework or compatibility-tooling project.

</specifics>

<code_context>
## Existing Code Insights

### Reusable Assets
- `.agents/skills/wow-addon-dev-wotlk-v335a/scripts/validate_toc.py`: validates Interface 30300 metadata, SavedVariables declarations, unsupported directives, and TOC references.
- `.agents/skills/wow-addon-dev-wotlk-v335a/scripts/lint_lua51.py`: validates runtime and harness syntax against Lua 5.1 constraints.
- `.agents/skills/wow-addon-dev-wotlk-v335a/scripts/scan_xpcall.py`: detects Lua 5.1 variadic-`xpcall` hazards.
- `tests/lua/runtime_harness.lua`, `tests/lua_test_runner.py`, and Python unittest discovery: existing complete behavior-execution path; the Phase 6 final baseline is 512 tests.
- `tests/test_localization_contract.py`, `tests/test_runtime_bootstrap_contract.py`, `tests/test_runtime_foundations_behavior.py`, and `tests/test_sync_communications_behavior.py`: existing owners for localization, bootstrap, removed-surface, shared-UI, and compatibility assertions.
- `.planning/phases/05-runtime-surface-cleanup/05-VERIFICATION.md`: passed goal-backward verification for the three removed exports/forwarders and their retained owner paths.
- `.planning/phases/06-logger-and-attendance-list-primitives/06-VERIFICATION.md`: passed automated and human verification for shared primitives, Logger, Attendance, and Force Inspect behavior.

### Established Patterns
- Phase 5 already proves the internal Screen Notice producer/listener path, private Trade state ownership, direct Loot context-state normalization, and absence of the three retired APIs.
- Phase 6 already proves exact numeric list geometry, sort binding, Logger Source hit-box behavior, Attendance Spec/Inspect ownership, contextual titles, and empty states.
- The authoritative TOC declares exactly `RMA_Raids`, `RMA_Players`, `RMA_Reserves`, `RMA_Warnings`, `RMA_Spammer`, and `RMA_Options`.
- Raid history, Reserves, and Distribution retain their established RMA-prefixed version-5 wire owners; Phase 7 verifies these contracts rather than exercising protocol evolution.
- Prior milestone verification distinguishes `AUTOMATED`, `OBSERVED`, and `DEFERRED` evidence and never fabricates live success.

### Integration Points
- Compare `539a651^0..HEAD` or the equivalent fixed baseline/final range while separating production, test, and planning changes.
- Reuse the existing LuaJIT shim outside the repository so the Python runner finds `lua.exe` with its adjacent `lua51.dll`; do not alter repository test contracts for the local runtime.
- Extend existing focused tests only if an acceptance gate demonstrates an uncovered regression. Do not add speculative coverage during a green verification run.
- Place the sanitized final acceptance evidence under `.planning/phases/07-ui-simplification-verification/`; it must not enter the addon TOC or release package.
- Treat live Screen Notice, Trade, and Loot checks as human checkpoints. Automated agents may prepare exact steps and evidence fields but cannot claim the observations themselves.

</code_context>

<deferred>
## Deferred Ideas

- `LibDeflate` replacement and byte-compatible addon-channel codec/Adler32 evaluation remain in the future v1.2 Dependency Optimization milestone.
- `LibGroupTalents`, `LibTalentQuery`, `LibBabble-TalentTree`, and `CallbackHandler` remain one future dependency-stack decision against `InspectCoordinator`.
- General UI redesign, new compatibility tooling, protocol evolution, SavedVariables migration, and vendored-library edits remain outside this phase.

</deferred>

---

*Phase: 07-ui-simplification-verification*
*Context gathered: 2026-08-16*
