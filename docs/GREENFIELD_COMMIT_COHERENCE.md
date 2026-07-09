# GREENFIELD Commit Coherence Report

This is the current static/offline commit coherence report for the staged
GREENFIELD_REWRITE work. It does not claim live-client acceptance because the
runtime smoke gap is recorded below.

## Current Staged Scope

The current staged set contains the validated GREENFIELD_REWRITE worktree
changes across runtime Lua, TOC, policy docs, user docs, and tests:

- `Raid Management Addon/Database/SavedVariables.lua` added as the single
  runtime owner for public `RMA_*` SavedVariables access.
- `Raid Management Addon/Raid Management Addon.toc` updated for current load
  order and release packaging.
- `Raid Management Addon/Services/Master/Service.lua` deleted as a dead
  pass-through facade.
- `Raid Management Addon/Database/DBSyncer.lua` registers `RMALogSync` before
  logger sync sends or handles addon messages.
- `Raid Management Addon/Controllers/Master.lua` registers
  `RMA-RollWinner` before roll-winner broadcasts.
- Runtime changes across controllers, services, modules, widgets, entry points,
  localization, and database owners are staged with their matching docs/tests.
- `docs/GREENFIELD_REWRITE_CONTRACT.md` and `docs/VALIDATION.md` record current
  owner, validation, behavior-delta, and runtime-smoke policy.
- New tests cover SavedVariables ownership, prefix registration, TOC packaging,
  load-order dependency ordering, deleted Master facade references, and docs
  consistency.

## Unstaged Runtime Scope

No unstaged runtime files remain in the working tree after the full staging
pass.

This report describes the currently staged scope. The working tree has no
unstaged runtime changes outside this staged set.

## TOC And Load Order

Current staged checks require:

- every Lua/XML file referenced by `Raid Management Addon.toc` is tracked for
  release packaging;
- `Database\SavedVariables.lua` loads before option and raid-store users;
- `Widgets\LootHints.lua` loads after reserve sync/service owners it depends on;
- statically declared `ModuleRegistry` dependencies load before their
  consumers.

## Registry And Deleted References

The staged tests require:

- `Services\Master\Service.lua` is not referenced by the TOC;
- `Services/Master/Service` is not referenced as a live registry dependency by
  the staged TradeMenu contract;
- runtime prefix owners register their public addon-message prefixes before
  sending traffic.

## Validation Evidence

Latest validation run for this staged snapshot:

- `py -3 -m unittest discover -s tests` -> 388 tests OK.
- TOC validator -> OK.
- Lua 5.1 lint -> 130 files clean.
- `scan_xpcall.py` -> 130 files clean of variadic `xpcall`.
- XML handler scan -> no matches; command exits 1 when no XML handlers exist.
- `luacheck "Raid Management Addon"` -> 0 warnings / 0 errors.
- `stylua --check` on touched runtime Lua files -> OK.
- `git diff --check` and `git diff --cached --check` -> OK, with only Git CRLF
  conversion warnings reported by status/diff commands.

The reset baseline does not track `tools/check-rma.ps1`; that gate is
documented as unavailable until restored.

## Runtime Smoke Gap

runtime smoke: not run; manual acceptance pending

Static checks cannot prove protected-action behavior, frame creation in a live
3.3.5a client, SavedVariables persistence across `/reload`, sync delivery
between grouped clients, combat behavior, or server chat behavior.

## Residual Risk

- In-game smoke remains manual acceptance.
- Any future staging pass must rerun the same gates and refresh this report or
  replace it with a final coherence report for the actual staged commit.
