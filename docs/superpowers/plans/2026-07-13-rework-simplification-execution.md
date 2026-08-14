# Rework Simplification Execution Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Execute the four approved simplification plans from `d4029e7`, verify the whole branch once, run the final in-game smoke test, and integrate locally only after smoke approval.

**Architecture:** The implementation is split by independent ownership boundary: runtime/support, raid/history, reserves/sync, and loot distribution. Each sub-plan produces independently tested commits; this execution plan archives the interrupted experiment, enforces order and cross-plan gates, and controls final integration.

**Tech Stack:** Git worktrees, WoW 3.3.5a build 12340, Interface 30300, Lua 5.1.5, Python `unittest`, `stylua`, `luacheck`, repository validators.

## Global Constraints

- Historical root: `78a60c4a9ebced8243297ff731afe036b52f6903`.
- Implementation baseline: `d4029e7`.
- Implementation branch/worktree: `codex/rework-simplification` in `.worktrees/rework-simplification`.
- Integration target: `codex/loot-bans-optimization` in the primary checkout.
- Preserve the interrupted `727ceb8` branch and its tracked dirty diff before implementation.
- Preserve `RMA_*` SavedVariables, wire formats, `/rma`, frame identities, XML layout ownership, and WotLK/Lua 5.1 compatibility.
- Do not add features, migrations, compatibility layers, new generic modules, or speculative recovery.
- Execute exactly one whole-branch simplicity review after all four sub-plans.
- Do not run the in-game smoke test until automated implementation and review are complete.
- Do not integrate before the user confirms the smoke test.

## Plan Map and Order

1. `docs/superpowers/plans/2026-07-13-runtime-support-simplification.md`
2. `docs/superpowers/plans/2026-07-13-raid-history-simplification.md`
3. `docs/superpowers/plans/2026-07-13-reserves-sync-simplification.md`
4. `docs/superpowers/plans/2026-07-13-loot-distribution-simplification.md`

The order is risk-guided: low-risk contracts first, then persistent raid data,
then reserves/sync, and loot last. A failing sub-plan blocks the next one.

---

### Task 1: Archive the Interrupted Loot Experiment Without Altering It

**Files:**
- Preserve: `.worktrees/loot-distribution-hardening/Raid Management Addon/Services/Loot/LootAttribution.lua`
- Preserve: `.worktrees/loot-distribution-hardening/Raid Management Addon/Services/Loot/Service.lua`
- Verify: Git ref `refs/heads/archive/loot-distribution-hardening-20260713`

**Interfaces:**
- Consumes: branch `codex/loot-distribution-hardening` at `727ceb8` plus its tracked dirty diff.
- Produces: an immutable reachable archival commit referenced by `archive/loot-distribution-hardening-20260713`; the original worktree remains dirty and unchanged.

- [ ] **Step 1: Record the original branch, HEAD, and diff checksum**

```powershell
$experimental = "C:\Users\ferra\Downloads\RMA-Raid Management Addon\.worktrees\loot-distribution-hardening"
git -C $experimental status --short --branch
git -C $experimental rev-parse HEAD
$beforePatchId = git -C $experimental diff | git patch-id --stable
```

Expected: branch is `codex/loot-distribution-hardening`, HEAD is `727ceb8...`, and only `LootAttribution.lua` plus `Service.lua` are modified.

- [ ] **Step 2: Create a reachable archive commit without stashing or cleaning the worktree**

```powershell
$archiveCommit = (git -C $experimental stash create "archive interrupted loot hardening 2026-07-13").Trim()
if (-not $archiveCommit) { throw "Expected an interrupted tracked diff to archive" }
git branch archive/loot-distribution-hardening-20260713 $archiveCommit
```

Expected: `git show-ref --verify refs/heads/archive/loot-distribution-hardening-20260713` succeeds.

- [ ] **Step 3: Prove the source worktree was not altered**

```powershell
$afterPatchId = git -C $experimental diff | git patch-id --stable
if ($beforePatchId -ne $afterPatchId) { throw "Archiving changed the interrupted diff" }
git -C $experimental status --short --branch
```

Expected: patch ID is unchanged and the same two files remain modified.

### Task 2: Execute Runtime and Support Simplification

**Files:**
- Follow exactly: `docs/superpowers/plans/2026-07-13-runtime-support-simplification.md`

**Interfaces:**
- Consumes: clean `codex/rework-simplification` after the design commit.
- Produces: direct option/dataset contracts, one inspect scheduler owner, and one shared UTF-8 prefix primitive.

- [ ] **Step 1: Execute every unchecked task in the runtime/support plan using its RED/GREEN cycle**

Run every command and commit specified in `2026-07-13-runtime-support-simplification.md` in order. Stop immediately if an expected RED test does not fail for the stated reason or a GREEN run fails.

- [ ] **Step 2: Run its complete focused gate**

```powershell
py -3 -m unittest tests.test_runtime_foundations_behavior tests.test_inspect_dataset_behavior tests.test_raid_recording_integrity_behavior tests.test_spammer_warnings_behavior -v
git diff --check
```

Expected: all selected tests PASS and `git diff --check` is silent.

### Task 3: Execute Raid and History Simplification

**Files:**
- Follow exactly: `docs/superpowers/plans/2026-07-13-raid-history-simplification.md`

**Interfaces:**
- Consumes: runtime/support plan commits and the existing DB/store contracts.
- Produces: one raid-create rollback boundary, one canonical validator policy, and one store-owned detached cleanup commit.

- [ ] **Step 1: Execute every unchecked task in the raid/history plan using its RED/GREEN cycle**

Run every command and commit specified in `2026-07-13-raid-history-simplification.md` in order. Do not combine its commits.

- [ ] **Step 2: Run its complete focused gate**

```powershell
py -3 -m unittest tests.test_runtime_foundations_behavior tests.test_raid_recording_integrity_behavior tests.test_sync_communications_behavior -v
git diff --check
```

Expected: all selected tests PASS and no whitespace errors are reported.

### Task 4: Execute Reserves and Sync Simplification

**Files:**
- Follow exactly: `docs/superpowers/plans/2026-07-13-reserves-sync-simplification.md`

**Interfaces:**
- Consumes: canonical validation and mutation behavior from the completed earlier plans.
- Produces: detached reserve candidates/indexes and reduced internal sync/test surface without weakening inbound protections.

- [ ] **Step 1: Execute every unchecked task in the reserves/sync plan using its RED/GREEN cycle**

Run every command and commit specified in `2026-07-13-reserves-sync-simplification.md` in order. Any change to wire serialization, checksum output, authorization, consent, replay protection, correlation, or resource limits is out of scope and must be rejected.

- [ ] **Step 2: Run its complete focused gate**

```powershell
py -3 -m unittest tests.test_reserves_integrity_behavior tests.test_sync_communications_behavior -v
git diff --check
```

Expected: all selected tests PASS and no whitespace errors are reported.

### Task 5: Execute Reduced Loot Simplification

**Files:**
- Follow exactly: `docs/superpowers/plans/2026-07-13-loot-distribution-simplification.md`

**Interfaces:**
- Consumes: the `d4029e7` loot baseline plus completed shared-owner simplifications.
- Produces: simple admission guards, validated session order, terminal timer safety, and no recovery-of-recovery state.

- [ ] **Step 1: Execute every unchecked task in the loot plan using its RED/GREEN cycle**

Run every command and commit specified in `2026-07-13-loot-distribution-simplification.md`. Treat commits after `d4029e7` as evidence only; do not cherry-pick them.

- [ ] **Step 2: Run its complete focused gate**

```powershell
py -3 -m unittest tests.test_loot_distribution_hardening_behavior tests.test_loot_bans_contract -v
git diff --check
```

Expected: all selected tests PASS and no whitespace errors are reported.

### Task 6: Perform the Single Whole-Branch Simplicity Review

**Files:**
- Review: every path returned by `git diff --name-only d4029e7..HEAD`
- Review: every new test changed after `d4029e7`

**Interfaces:**
- Consumes: all four completed sub-plans.
- Produces: one `detect-over-engineering` verdict with every required finding fixed before final verification.

- [ ] **Step 1: Establish the exact review scope**

```powershell
git status --short --branch
git diff --stat d4029e7..HEAD
git diff --name-only d4029e7..HEAD
git log --oneline --reverse d4029e7..HEAD
```

Expected: clean worktree and only approved design, plan, runtime, test, localization, and documentation paths.

- [ ] **Step 2: Run `detect-over-engineering` once over the entire branch**

The review must classify each finding with exact `file:line`, evidence, simpler alternative, trade-off, and effort. It must explicitly inspect:

- new single-use wrappers or public test seams;
- duplicated timer, rollback, validation, or scheduler ownership;
- retry/exhausted/generation/capacity state growth;
- source-layout or internal-identity test coupling;
- compatibility fallbacks for mandatory TOC-loaded dependencies.

Expected verdict: `PASS` or `PASS WITH WARNINGS` with no unresolved required simplification. A `SIMPLIFICATION REQUIRED` verdict returns work to the owning sub-plan; do not start a second open-ended review wave.

- [ ] **Step 3: Commit only fixes required by that single review**

Each fix uses its owning focused tests and a separate `refactor(...)`, `fix(...)`, or `test(...)` commit. Do not add recommendations that lack a demonstrated caller, failure, or invariant.

### Task 7: Run Final Automated Verification and Coherence Report

**Files:**
- Verify: `Raid Management Addon/Raid Management Addon.toc`
- Verify: all changed Lua, XML, localization, tests, and tracked policy artifacts.

**Interfaces:**
- Consumes: review-approved branch.
- Produces: automated release candidate and an evidence-backed commit-coherence report in the final handoff.

- [ ] **Step 1: Run the complete automated suite**

Run: `py -3 -m unittest discover -s tests -v`

Expected: all tests PASS; count is at least the baseline 234 plus approved new cases.

- [ ] **Step 2: Run WotLK and repository static gates**

```powershell
py -3 ..\..\.agents\skills\wow-addon-dev-wotlk-v335a\scripts\validate_toc.py "Raid Management Addon/Raid Management Addon.toc"
py -3 ..\..\.agents\skills\wow-addon-dev-wotlk-v335a\scripts\lint_lua51.py "Raid Management Addon"
py -3 ..\..\.agents\skills\wow-addon-dev-wotlk-v335a\scripts\scan_xpcall.py "Raid Management Addon"
rg -n "<Scripts>|<On[A-Za-z]+>" "Raid Management Addon/UI" -g "*.xml"
stylua --check -- "Raid Management Addon"
luacheck "Raid Management Addon" --exclude-files "Raid Management Addon/Libs/**"
git diff --check d4029e7..HEAD
```

Expected: validators report zero errors; XML search returns no handlers; format/lint pass; diff check is silent. If repo-wide `stylua` reports known untouched formatting noise, rerun it on only Lua files returned by `git diff --name-only d4029e7..HEAD` and report both results honestly.

- [ ] **Step 3: Produce the commit-coherence evidence**

```powershell
git status --short --branch
git diff --name-status d4029e7..HEAD
git diff --name-only d4029e7..HEAD -- "Raid Management Addon/*.toc" "Raid Management Addon/**/*.lua" "Raid Management Addon/**/*.xml"
git ls-files --others --exclude-standard
git log --oneline --reverse d4029e7..HEAD
```

Report: changed TOC-referenced runtime files, untracked runtime files, deleted references, registry/load-order risk, policy artifacts, commands run, skipped commands, and residual risks.

### Task 8: Pause for the Final In-Game Smoke Test

**Files:**
- No repository changes.

**Interfaces:**
- Consumes: automated release candidate.
- Produces: explicit user smoke-test approval or concrete failure evidence.

- [ ] **Step 1: Give the user the exact smoke checklist and stop**

Checklist:

```text
[ ] Login produces no Lua errors.
[ ] /rma opens the addon.
[ ] Main windows create without missing-frame errors.
[ ] /reload preserves expected RMA_* SavedVariables.
[ ] Raid creation/replacement and attendance operate.
[ ] Master Loot single, direct target, multi-award, and inventory trade operate.
[ ] Reserves import/edit/sync and whisper handling operate.
[ ] Logger cleanup/rebuild and history display operate.
[ ] Inspect equipment/spec refresh operates in and after combat.
[ ] Warnings and spammer start/pause/stop operate.
```

Do not integrate until the user explicitly confirms the checklist.

### Task 9: Integrate Locally After Smoke Approval

**Files:**
- Preserve local modifications in primary-checkout `README.md` and `Raid Management Addon/README.md`.
- Update branch: `codex/loot-bans-optimization`.

**Interfaces:**
- Consumes: user-approved `codex/rework-simplification` release candidate.
- Produces: local fast-forward integration with the user's pre-existing README work restored.

- [ ] **Step 1: Verify fast-forward eligibility and preserve dirty README work**

```powershell
$root = "C:\Users\ferra\Downloads\RMA-Raid Management Addon"
git -C $root switch codex/loot-bans-optimization
git -C $root merge-base --is-ancestor codex/loot-bans-optimization codex/rework-simplification
if ($LASTEXITCODE -ne 0) { throw "Integration target is no longer an ancestor" }
git -C $root stash push -m "preserve local README edits before rework integration" -- README.md "Raid Management Addon/README.md"
```

Expected: ancestor check succeeds and the README edits are stored in one named stash entry.

- [ ] **Step 2: Fast-forward and restore the user's README edits**

```powershell
git -C $root merge --ff-only codex/rework-simplification
git -C $root stash pop
git -C $root status --short --branch
```

Expected: branch points to the smoke-approved implementation; the two README edits are restored. If stash application conflicts, stop and preserve conflict evidence instead of guessing.

- [ ] **Step 3: Verify the integrated tree without changing it**

```powershell
Push-Location $root
try {
	py -3 -m unittest discover -s tests -v
} finally {
	Pop-Location
}
git -C $root diff --check
git -C $root log -1 --oneline --decorate
```

Expected: complete suite PASS, diff check is silent, and HEAD is the approved simplification tip.
