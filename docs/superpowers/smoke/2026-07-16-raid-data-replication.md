# Raid Data Replication Smoke Results

Verification timestamp: 2026-07-18T16:36:14+02:00

## Environment

- Branch: `codex/single-raid-history-sharing`
- Protocol/runtime commits verified: `03d10a2` (`HEAD_REQ` protocol),
  `019bfce` (receiver-initiated discovery runtime), `417f82b` (bounded
  unresolved-authority retry), `c0cb9c7` (monotonic active-snapshot repair),
  `5c9ab70` and `2830ad1` (re-entry recovery/cancellation), and `7a7a299`,
  `f3931ab`, `68e796a` (re-entry decision, lifecycle, and attendance ordering)
- Test-gate evidence: `452fda8` (bounded retry/cancellation timing assertions)
- Target runtime: WotLK 3.3.5a build 12340, Interface 30300, Lua 5.1.5
- Verification host: Windows, PowerShell, Python 3.12
- No two-client in-game smoke was run for these commits.

## Automated Validation

| Check | Command | Result |
|---|---|---|
| Full Python/Lua suite | `python -m unittest discover -s tests -v` | PASS -- `375` tests ran in `12.883s`; `OK` |
| TOC validation | `py -3 C:\Users\ferra\Downloads\RMA-Raid Management Addon\.agents\skills\wow-addon-dev-wotlk-v335a\scripts\validate_toc.py "Raid Management Addon/Raid Management Addon.toc"` | PASS -- 0 errors, 0 warnings; 1 file |
| Lua 5.1 validation | `py -3 C:\Users\ferra\Downloads\RMA-Raid Management Addon\.agents\skills\wow-addon-dev-wotlk-v335a\scripts\lint_lua51.py "Raid Management Addon"` | PASS -- 134 files clean |
| Variadic `xpcall` scan | `py -3 C:\Users\ferra\Downloads\RMA-Raid Management Addon\.agents\skills\wow-addon-dev-wotlk-v335a\scripts\scan_xpcall.py "Raid Management Addon"` | PASS -- 134 files clean |
| XML handler scan | `rg -n "<Scripts>\|<On[A-Za-z]+>" "Raid Management Addon/UI" -g "*.xml"` | PASS -- no matches (rg exit 1) |
| Unsupported API scan | `rg -n "C_Timer\|C_AddOns\|Settings\.\|MenuUtil\|SetAtlas\|SetColorTexture\|table\.pack\|table\.unpack\|goto\|_ENV\|//" "Raid Management Addon" -g "*.lua"` | REVIEWED -- the late-join range changes `Init.lua` and `Database/DBSyncer.lua`; matches are pre-existing vendored compatibility APIs, URLs/comments, and diagnostic strings outside the changed lines |
| Diff whitespace check | `git diff --check` | PASS -- exit 0 |
| Repository aggregate validator | `tools/check-rma.ps1` | NOT RUN -- file absent in this worktree |

The worktree does not contain `.agents/skills/wow-addon-dev-wotlk-v335a/scripts/`,
so the installed validator scripts were run from the repository root paths
recorded above; all completed successfully.

## Late-Join Active Bootstrap Gate

- Automated: PASS -- A active first, B recognition only,
  `HEAD_REQ -> HEAD -> SNAP_REQ -> SNAP_DATA`.
- Entry order: PASS -- B before designated A waits; B-as-leader handover keeps
  one stable UID; leader without RMA is not substituted.
- Live WotLK two-client smoke: NOT RUN.
- Integration into `codex/loot-bans-optimization`: BLOCKED until the live smoke
  is positive.

## Required Live Smoke: Group Loot And Raid Leader Authority

Status: NOT RUN -- an authenticated two-client WotLK 3.3.5a group is required.

- [ ] In Group Loot, Raid Leader A enters a recognized raid and creates exactly one active raid.
- [ ] Participant B creates no competing raid and receives A's snapshot.
- [ ] Switching to Master Loot with a different ML does not change database authority.
- [ ] Loot, boss, reload, delta recovery, conclusion, and historical offer/acceptance converge.
- [ ] Change Raid Leader from A to B: only A and B see one local database-authority WARN.
- [ ] During B recovery, trigger Group Loot and a boss/award; after synchronization, Loot History contains one correctly attributed row and no recovered player is overwritten.
- [ ] A offers a historical raid, B accepts it, and B sees it in Loot History.

Record the client build, character names, timestamp, observations, and any Lua
errors before checking these items.

## Integration Gate

**Integration Gate: BLOCKED**

Reason: automated validation is green, but the protocol/runtime commits above
have not passed the required positive two-client in-game smoke.

Do not merge, cherry-pick, rebase, or copy this branch into
`codex/loot-bans-optimization`. The gate may become POSITIVE only after every
unchecked live step above is executed successfully and this artifact records the
corresponding in-game evidence.

## Raid Leader Re-entry Recovery Gate

- Automated: PASS -- write barrier, bounded replica HEAD collection, greatest-sequence snapshot recovery, digest-conflict suspension, popup Yes/No, context mismatch, and no-copy creation.
- Automated evidence: `375` tests in `12.883s`; TOC `1` file, `0` errors and `0` warnings; Lua 5.1 and xpcall `134` files clean.
- Runtime commits: Task 1 `c0cb9c7`; Task 2 `5c9ab70`, `2830ad1`; Task 3 `7a7a299`, `f3931ab`, `68e796a`.
- Live WotLK two-client smoke: NOT RUN.
- Required live path: A creates -> B replicates -> A reloads stale -> A recovers B -> popup Yes -> same UID -> new loot converges.
- Replacement path: popup No -> recovered previous raid concludes -> exactly one new raid is created.
- Historical path: A offers -> B accepts -> completed raid visible in B Loot History.
- Integration into `codex/loot-bans-optimization`: BLOCKED until every live path is positive.

## Observed Live Re-entry Regression And Repair

- Live result at `4212b13`: FAILED -- Replica B did not refresh Loot History; choosing No suspended re-entry with `DIGEST_MISMATCH`; a later Yes emitted a nil `RaidRosterDelta` warning.
- Root causes: replica commits did not invalidate Logger data; equal-position recovery trusted only the stored digest and could skip repair of a corrupted local state alias; runtime-only roster settlement published an empty delta.
- Repair commits: `97c3a7f` (`fix(sync-03): repair reentry replica convergence`) and
  `bc32bd1` (`fix(sync-03): prefer valid remote reentry source`).
- Automated verification: PASS -- `378` tests in `12.597s`; TOC `1` file with `0` errors and `0` warnings; Lua 5.1 and xpcall `134` files clean. The corrupt equal-position recovery case also passed `30/30` consecutive runs.
- Live WotLK two-client re-smoke after `bc32bd1`: NOT RUN.
- Integration into `codex/loot-bans-optimization`: BLOCKED until the re-entry and historical offer/acceptance live paths are both positive.
