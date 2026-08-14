# RMA Validation Gates

Codex completion and commit readiness are based on static/offline validation.
Real-client testing is manual acceptance and is not a blocking gate unless the
user explicitly asks for it.

## Static Gate

Run the local WotLK validator scripts available in the ignored agent skill
folder:

```powershell
py -3 -m unittest discover -s tests -p "test_*.py" -v
py -3 .agents\skills\wow-addon-dev-wotlk-v335a\scripts\validate_toc.py "Raid Management Addon\Raid Management Addon.toc"
py -3 .agents\skills\wow-addon-dev-wotlk-v335a\scripts\lint_lua51.py "Raid Management Addon"
py -3 .agents\skills\wow-addon-dev-wotlk-v335a\scripts\scan_xpcall.py "Raid Management Addon"
rg -n "<Scripts>|<On[A-Za-z]+>" "Raid Management Addon\UI" -g "*.xml"
luacheck "Raid Management Addon" --exclude-files "Raid Management Addon/Libs/**"
git diff --check
```

The ignored `.agents` directory may be absent from an isolated Git worktree.
When that happens, invoke the same validator scripts from the parent checkout
and keep the addon paths pointed at the worktree under test. This repository
does not currently contain `tools/check-rma.ps1`, so that command is not part
of the available static gate and must not be reported as run.

These static gates cover:

- TOC file existence, references, Interface `30300`, and unsupported TOC
  directives.
- Python behavior and contract tests discovered under `tests/`.
- The shared R5 wire contract: LibSerialize plus LibDeflate encoding belongs to
  `addon.Comms.Payload`; destination validation belongs to `addon.Comms`; and
  ChatThrottleLib is the sole outbound scheduler.
- Lua 5.1 parse compatibility across the addon folder.
- Lua 5.1 `xpcall` extra-argument traps.
- XML script blocks or XML event handlers under `UI/`.
- Whole-addon Lua lint outside vendored `Libs/`.
- Git whitespace errors.

For Reserves integrity changes, the behavior suite additionally proves failed
sync-cache mutations do not persist, `C2` transfers verify before publication,
async imports and UI batches roll back atomically, import/storage limits reject
before aggregation, and whisper signup remains pre-raid opt-in while admission
and replies stay bounded.

For inspect and instance-dataset hardening, the behavior suite proves cold item
information cannot publish partial equipment, inspect ownership is serialized
and GUID-correlated, localized raids resolve through stable map IDs, dataset
build faults preserve exact active root/generation/attribution identity, and a
cross-owner activation failure restores the prior loot-source and ignored-mob
state.

For spammer and raid-warning hardening, the behavior suite proves persisted
drafts/templates normalize to bounded UTF-8-safe shapes, active LFM runs use an
immutable snapshot with terminal-once callbacks and hard caps, chat destinations
are validated at the effect boundary; selected warning IDs and unchanged-row
identities are preserved, while the edited row alone is atomically replaced.
Config clear invalidates loaded UI without stopping the active run. It also
covers clear before and after frame creation, enabled Stop/Resume actions after
clear, pending callbacks, direct Runtime ownership, contained callback failures,
concrete transport reasons, exactly-once controller feedback, and a later headless
start from canonical SavedVariables.

For loot-distribution hardening, the behavior suite proves roll intake freezes
before award execution, every award entry shares one in-flight admission gate,
terminal effects retry by named checkpoint, and known failures cancel only their
transaction attribution. It also covers strict final loot-slot validation,
4-second confirmation plus bounded 8-second reconciliation, atomic/current
RMADist windows, inventory-evidenced addon and manual Hold trades, truthful
multi-award cancellation, closed performance spans, and the measured 20-slot
bound of 19 loot-count scans, 20 candidate scans, 20 completion sends, and 39
refresh requests.

For docs-only edits, also run:

```powershell
git diff --check
git status --short --branch
```

## Export Surface Review

After changing exported `addon.*` module names, slash command routing,
SavedVariables, or addon-message prefixes, review `ARCHITECTURE.md` and
`API_SURFACE.md` for drift.

## Manual In-Game Acceptance

Static checks cannot prove protected-action, UI, SavedVariables, sync, combat,
or server chat behavior. These checks are useful manual acceptance steps when
requested, but Codex should not block completion on them:

- login with no Lua errors
- `/rma` prints help
- `/rma config`, `/rma ml`, `/rma history`, `/rma attendance`, `/rma res`, and
  `/rma counter` open their expected surfaces
- `/reload` preserves only expected `RMA_*` data
- loot, reserves, logger, warnings, and spammer workflows still operate
- addon-message sync still uses `RMA*` prefixes and handles mismatched versions
  predictably

When no in-game validation was requested or run, report the gap explicitly as:

```text
runtime smoke: not run; manual acceptance pending
```

For the progressive whole-addon refactor, the explicitly agreed status text is:

```text
runtime smoke: deferred by user until the full refactoring program is complete
```
