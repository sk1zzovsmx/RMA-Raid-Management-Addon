# GREENFIELD Commit Coherence Report

This is the current static/offline commit coherence report for the staged
GREENFIELD_REWRITE work. It does not claim live-client acceptance because the
runtime smoke gap is recorded below.

## Current Staged Scope

The attendance-export rewrite is implemented in prior commits. This final
evidence commit records its ownership boundary:

- `Services/Attendance/Export.lua` owns attendance CSV generation.
- `Controllers/Attendance.lua` owns the attendance export command and UI
  action.
- `Services/Logger/Export.lua` and `Controllers/Logger.lua` own logger and
  loot-history export only.
- `docs/ARCHITECTURE.md` records the final attendance and logger ownership
  boundary.

## Unstaged Runtime Scope

No unstaged runtime files remain in the working tree outside the final
documentation evidence for this rewrite.

## TOC And Load Order

The final implementation requires:

- every Lua/XML file referenced by `Raid Management Addon.toc` is tracked for
  release packaging;
- `Database\SavedVariables.lua` loads before option and raid-store users;
- `Widgets\LootHints.lua` loads after reserve sync/service owners it depends on;
- statically declared `ModuleRegistry` dependencies load before their
  consumers.

## Registry And Deleted References

The tests require:

- `Services\Master\Service.lua` is not referenced by the TOC;
- `Services/Master/Service` is not referenced as a live registry dependency by
  the staged TradeMenu contract;
- runtime prefix owners register their public addon-message prefixes before
  sending traffic.

## Validation Evidence

Latest validation run for the attendance-export rewrite evidence commit:

- `py -3 -m unittest discover -s tests` -> 396 tests OK.
- Lua 5.1 lint -> 131 files clean.
- TOC validator -> OK.
- `scan_xpcall.py` -> 131 files clean of variadic `xpcall`.
- `luacheck "Raid Management Addon"` -> 0 warnings / 0 errors.
- `stylua --check` on the seven touched runtime Lua files -> OK.
- `git diff --check` -> no whitespace errors.

`tools/check-rma.ps1` remains unavailable in this reset baseline.

## Runtime Smoke Gap

runtime smoke: not run; manual acceptance pending

Static checks cannot prove protected-action behavior, frame creation in a live
3.3.5a client, SavedVariables persistence across `/reload`, sync delivery
between grouped clients, combat behavior, or server chat behavior.

## Residual Risk

- In-game smoke remains manual acceptance.
- Any future staging pass must rerun the same gates and refresh this report or
  replace it with a final coherence report for the actual staged commit.
