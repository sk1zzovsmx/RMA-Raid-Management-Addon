# RMA Product Improvement Greenfield Contract

This is the executable external-behavior and product-improvement contract for rewriting or heavily refactoring **Raid Management Addon** from a clean implementation.

The current implementation is a behavioral reference and a source of product intent. It is **not** an architectural blueprint, and it must not be preserved bug-for-bug. The rewrite must keep the public addon contract stable while making the addon better: more reliable in raid, easier to maintain, safer under WoW 3.3.5a runtime constraints, clearer in UI/data flow, and less coupled internally.

## Contract Principle

- `primary_goal`: `improve the addon, not merely reproduce the old code`
- `compatibility_goal`: `preserve the public/external contract unless a behavior is explicitly classified as broken, unsafe, or obsolete`
- `architecture_goal`: `build one coherent architecture with clear ownership, stable data flow, minimal accidental API surface, and appropriate file boundaries`
- `anti_goal`: `do not keep wrappers, file splits, tests, or behavior only because the current implementation has them`
- `bug_for_bug_policy`: `forbidden; broken behavior must be fixed with a documented behavior delta`
- `committable_standard`: `a batch is committable only when behavior, architecture, docs, tests, TOC, registry, and validation gates agree`

## Identity

These values are externally visible and must remain stable unless an intentional release-level migration is documented.

- `addon_name`: `Raid Management Addon`
- `runtime_short_name`: `RMA`
- `addon_folder`: `Raid Management Addon`
- `toc_file`: `Raid Management Addon.toc`
- `interface`: `30300`
- `lua_runtime`: `Lua 5.1`
- `wow_target`: `Wrath of the Lich King 3.3.5a`
- `version`: `0.1.0-alpha.1`
- `main_command`: `/rma`

## Stable External Surface

The following are stable compatibility surfaces:

- addon folder name
- TOC metadata required by the 3.3.5a client
- SavedVariables names
- `/rma` slash command and aliases
- addon-message prefixes and compatibility behavior
- user-facing raid, loot, reserves, logger, attendance, warnings, LFM, minimap, config, diagnostics, and sync workflows
- persisted `RMA_*` data that existing users already have
- XML frame identities that are referenced by runtime Lua, unless migrated in one coherent batch

The following are **not** stable compatibility surfaces:

- current file count
- current folder split
- current private function names
- current ModuleRegistry entries created only because of file boundaries
- current pass-through wrappers
- current temporary Bind APIs
- current tests that lock implementation details rather than user-visible behavior
- current bugs, timing flaws, duplicated helper families, or UI inconsistencies

## SavedVariables

RMA must use only the following account SavedVariables:

- `RMA_Raids`
- `RMA_Players`
- `RMA_Reserves`
- `RMA_Warnings`
- `RMA_Spammer`
- `RMA_Options`

## SavedVariable Ownership

- `semantic_owner`: `Database persistence boundary`
- `default_file_owner`: `Raid Management Addon/Database/SavedVariables.lua`
- `ownership_rule`: `all reads, creation, replacement, clearing, and migration of RMA SavedVariables must go through one persistence owner`
- `migration_policy`: `migrations are allowed only for RMA_* schema evolution; no hidden import or migration from non-RMA SavedVariables during normal startup`
- `data_loss_policy`: `destructive migration is forbidden unless it is explicit, opt-in, documented, and guarded`
- `idempotency_policy`: `startup and migration code must be safe across repeated /reload cycles`

## Slash Commands

- `/rma`

## Command Alias Contract

The slash command owner may be rewritten, but command aliases must remain available and discoverable through help unless explicitly deprecated with a compatibility note.

- `ach`: `ach`, `achi`, `achiev`, `achievement`
- `attendance`: `attendance`, `attendees`, `att`
- `bug`: `bug`, `report`
- `config`: `config`, `conf`, `options`, `opt`
- `counter`: `counter`, `counters`, `counts`
- `debug`: `debug`, `dbg`, `debugger`
- `help`: `help`
- `history`: `history`
- `lfm`: `pug`, `lfm`, `group`, `grouper`
- `loot`: `ml`
- `minimap`: `minimap`, `mm`
- `perf`: `perf`, `performance`
- `reserves`: `res`, `reserves`, `reserve`, `sr`, `softres`
- `specinspect`: `specinspect`, `inspectspec`
- `validate`: `validate`
- `version`: `version`, `ver`, `about`
- `warnings`: `warning`, `warnings`, `warn`, `rw`

## Slash Command Ownership

- `single_owner_rule`: `there must be one slash-dispatch owner for /rma`
- `default_owner`: `Raid Management Addon/EntryPoints/SlashCommandHandlers.lua`
- `handler_policy`: `slash handlers should dispatch to cohesive feature owners; they must not become the business-logic owner for raid, loot, reserves, logger, inspect, or UI state`
- `help_policy`: `help output must reflect actual enabled commands and aliases`
- `disabled_feature_policy`: `commands for disabled or unavailable features must fail gracefully with a clear local message, not a Lua error`

## Addon Message Prefixes

The following prefixes are externally visible protocol identifiers and must remain stable unless a versioned protocol migration is documented:

- `RMADist`
- `RMALogSync`
- `RMAResSync`
- `RMAVersion`

## Addon Message Policy

- `protocol_owner`: `Comms/sync boundary`
- `validation_rule`: `all inbound addon messages must validate prefix, sender context, payload shape, version, and feature target before mutating state`
- `compatibility_rule`: `payload format changes require versioned decode/encode or an explicit protocol bump with graceful rejection of incompatible peers`
- `safety_rule`: `malformed, oversized, stale, duplicate, cross-raid, or unauthorized messages must be ignored or reported locally without corrupting SavedVariables`
- `throttle_rule`: `sync and distribution traffic must respect 3.3.5a chat/addon-message constraints and must not spam the group`

## XML Policy

- `layout_only`: `true`
- `script_handler_count`: `0`
- `rule`: `XML may define layout, templates, frame names, anchors, dimensions, and static visual structure only`
- `forbidden`: `XML <Scripts>, <OnLoad>, <OnClick>, <OnShow>, <OnHide>, or other script handlers`
- `lua_binding_rule`: `all behavior, event binding, state updates, button actions, list refreshes, and dynamic text/icon updates must be bound from Lua`
- `ui_migration_rule`: `renaming XML frames is allowed only in a coherent batch that updates all Lua references, docs, tests, and smoke notes`

## Product Behavior Contract

The rewrite must preserve the intended user workflows while improving correctness and usability.

### Master Loot

- `/rma ml` opens or toggles the Master Loot workflow.
- Supports loot selection from open loot, dragged item links, and eligible inventory trade items.
- Supports MS, OS, SoftRes, and Free roll contexts.
- Supports countdowns, late-roll blocking when configured, duplicate-roll handling, pass/cancel states, tie detection, and tie reroll flow.
- Supports winner selection, hold, bank, disenchant, and trade reminders where the player has permission.
- Must never bypass Blizzard protected-action, loot-permission, or combat-lockdown rules.
- Must keep UI state, local bookkeeping, announcements, and persisted loot history consistent.

### Roll Tracking

- Tracks system roll messages for the active item/session.
- Separates current-session roll state from persisted raid history.
- Handles duplicate, blocked, late, cancelled, pass, timeout, and reroll-only states clearly.
- Sorting and display must follow configuration.

### Loot Counter

- `/rma counter` opens or toggles the Loot Counter.
- Tracks MS, OS, and Free counts per player.
- Supports manual correction, one-player reset, all-player reset, and permitted announcements.
- Must not desync counts from awards created by the Master Loot workflow.

### SoftRes / Reserves

- `/rma res` opens or toggles reserves.
- `/rma res import` opens import.
- Supports CSV/JSON import, Multi-reserve mode, Plus System mode, name aliases, item IDs, item names, quantities, plus values, and item-source metadata where available.
- `/rma res check` reports reserve readiness for the current item and raid.
- Sync must be validated, version-aware, and safe against stale or malformed payloads.
- Whisper features must be opt-in, throttled, and permission-safe.

### Loot History / Logger

- `/rma history` opens or toggles Loot History.
- Stores raid sessions, roster snapshots, boss/trash entries, loot entries, winners, roll type, roll value, item identity, and source where available.
- Supports edit, cleanup, export, validation, rebuild, and sync actions.
- Data model must be stable, migratable, and resilient to partial/incomplete raid records.
- Logger sync must reject incompatible, cross-raid, malformed, duplicate, or unsafe payloads.

### Raid Attendance and Inspect

- `/rma attendance` opens Raid Attendance.
- The attendance UI must make the raid/session list and player list clear. Target structure:
  - subframe tabs or equivalent navigation: `Raid List` and `Player List`
  - raid list rows: `RAID1`, `RAID2`, etc., with useful session context
  - player rows: `Player`, `Join`, `Leave`, `Inspect item/spec/status` fields or equivalent readable columns
- Attendance records join/leave segments, boss attendees, raid attendees, class, specialization, inspected item level, and inspect status when available.
- Inspect must be snapshot-based, not continuous polling.
- Automatic inspect may run at raid creation/start after a safe delay.
- Manual inspect may be forced with `/rma specinspect force` or explicit UI action.
- Inspect queue must be throttled, must pause or retry during combat/uninspectable states, and must handle timeout/failure without blocking the addon.
- Persisted inspect data belongs to the raid/session snapshot and must not be confused with live-only runtime status.

### Raid Warnings

- `/rma rw`, `/rma warn`, `/rma warning`, and `/rma warnings` open or control Raid Warnings.
- Supports stock templates, create/edit/delete, preview, and announce.
- Announcement must respect raid leader/assistant permissions and use safe fallback chat behavior where appropriate.

### LFM Spam

- `/rma lfm`, `/rma pug`, `/rma group`, and `/rma grouper` open or control LFM.
- Supports preview, start, stop, raid name, composition, roles, custom text, duration, and channels.
- Must enforce message length limits, duration caps, throttling, and safe stop behavior.
- `/rma ach` extracts achievement IDs for placeholders.

### Minimap

- Minimap button remains available.
- Left/right click behavior may be improved, but must preserve quick access to core RMA windows.
- `/rma minimap on|off|pos <deg>` remains supported.

### Configuration

- `/rma config` opens configuration.
- `/rma config reset` restores defaults.
- Configuration must use stable option ownership, safe defaults, and clear feature grouping.
- Changing options must update runtime behavior without requiring unsafe reloads unless the option explicitly says otherwise.

### Diagnostics and Maintenance

- `/rma version`, `/rma bug`, `/rma validate`, `/rma perf`, and `/rma debug` remain local diagnostics unless explicitly performing a documented sync request.
- Diagnostics must not mutate live raid data except for explicit debug/test helpers.
- Debug/test helpers must be gated and must not run accidentally in normal use.

## Improvement-First Policy

Each rewrite/refactor batch must name at least one intended improvement:

- `bug_fix`: fixes incorrect, fragile, or inconsistent behavior
- `ux_improvement`: makes the addon easier to understand or operate during raid
- `runtime_safety`: reduces Lua errors, protected-action risk, combat-lockdown risk, inspect/sync risk, or chat spam risk
- `data_integrity`: improves validation, migrations, schemas, or corruption resistance
- `performance`: removes wasteful scans, unbounded updates, or repeated expensive work
- `maintainability`: improves cohesion, ownership, testability, naming, or dependency direction

A batch that only moves code without improving behavior, safety, or maintainability is not sufficient.

## Behavior Delta Policy

When current behavior is changed, the batch must record:

- old behavior
- new behavior
- reason for change
- whether the old behavior was a bug, unsafe behavior, confusing UX, or obsolete implementation detail
- compatibility impact
- migration impact, if any
- tests or smoke checks that prove the intended behavior

External command/SavedVariables/protocol changes require a stronger compatibility note than private implementation changes.

## Module Boundary Policy

- `boundary_rule`: `cohesion-first, product-first`
- `boundary_question`: `does this file own a durable concept, data shape, runtime integration, feature UI composition, or testable algorithm that deserves its own API and load-order cost?`
- `file_count_policy`: `prefer fewer accidental files, but do not merge cohesive owners only to reduce count`
- `new_file_gate`: `a new Lua file must own a clear concept, policy, data shape, runtime integration boundary, UI composition owner, or testable algorithm`
- `thin_file_policy`: `small files are allowed only with a clear conceptual reason; small pass-through files default to merge/delete`
- `line_count_policy`: `do not split or merge by line count alone`
- `api_surface_policy`: `extraction is allowed only when it reduces caller complexity, stabilizes a contract, or isolates a real policy/integration boundary`
- `toc_complexity_policy`: `each TOC entry must justify its load-order and dependency cost`
- `registry_policy`: `ModuleRegistry entries must represent real runtime dependencies, not artifacts of unnecessary file splitting`

## Recommended Macro Areas

Review and rewrite in product-oriented areas rather than isolated files:

- Bootstrap / Init / Feature profile
- Database / SavedVariables / schema / migrations / validation
- Raid Session / Roster / Attendance / Inspect
- Master Loot / Roll workflow / Loot service
- Loot Counter
- Reserves / SoftRes / aliases / sync / whisper
- Logger / Loot History / export / sync
- Chat / Comms / addon-message protocols
- UI frames / widgets / controllers
- Minimap / slash entrypoints
- Warnings / LFM Spam
- Diagnostics / debug / performance
- Cross-cutting helpers, timers, events, strings, sorting, item utilities

## Shared Logic and DRY Policy

- Repeated helper logic must be reviewed for shared semantics before extraction.
- Shared logic belongs to the nearest cohesive owner: feature owner, service/domain owner, UI primitive owner, or runtime infrastructure owner.
- Do not add generic `Utils`, `Common`, `Shared`, or catch-all `Helpers` modules just because code looks similar.
- Local duplication may remain only when variants have materially different semantics, caller state, runtime constraints, or failure behavior.
- DRY convergence must reduce duplicated semantics, caller complexity, public API surface, dependency count, or defect risk.

## Facade and Wrapper Policy

- Facades may stay only when they add validation, compose multiple owners into policy, isolate a stable external contract, or reduce caller complexity without hiding ownership.
- Pass-through modules, one-function wrappers, single-event handler files, and files that only rename a concrete owner method are forbidden.
- When deleting wrappers, update callers to the real owner, remove stale TOC entries, remove stale registry dependencies, update generated docs, and record the reduction.

## UI Architecture Policy

- XML owns static layout only.
- Lua owns behavior, state, event handlers, row construction, list refresh, dynamic visibility, and user actions.
- Feature UI controllers must not own domain rules that belong in services.
- Services must not own frame-specific layout details.
- UI primitives may exist only when they reduce repeated UI semantics without becoming a catch-all UI facade.
- Runtime windows must fail gracefully if an optional widget/frame is disabled or unavailable.

## Runtime Safety Policy

- Target Lua is Lua 5.1; do not use modern Lua features unavailable to WoW 3.3.5a.
- Do not rely on APIs unavailable to WotLK 3.3.5a unless a compatibility wrapper is provided and tested.
- Avoid unbounded `OnUpdate`, repeated full scans, and heavy work during combat.
- Inspect, sync, chat, tooltip, item-info, and loot operations must be throttled and failure-safe.
- Protected actions and loot assignment must respect Blizzard permissions and combat restrictions.
- All external event handlers must tolerate missing/partial data and must not throw Lua errors during raid.

## Test Architecture Lock Policy

GREENFIELD_REWRITE tests should protect:

- public slash command aliases and dispatch behavior
- SavedVariables ownership and migration behavior
- addon-message prefix/protocol validation
- raid/session/attendance/inspect behavior
- master loot and roll workflow behavior
- reserves import/check/sync behavior
- logger/history/export/sync behavior
- XML no-script policy
- Lua 5.1 compatibility
- TOC/load-order validity
- rejected anti-patterns: pass-through wrappers, accidental public APIs, XML handlers, unsafe xpcall usage, stale TOC references

Tests must **not** lock:

- temporary file splits
- private helper names
- exact internal Bind APIs
- ModuleRegistry entries that may disappear after consolidation
- TOC entries for modules that the cohesion gate may still merge
- current bugs or accidental implementation behavior

## Verification Status

- `goal`: `passing tests is required but not sufficient; each batch must also be architecturally defensible and product-improving`
- `review_steps`: `implementation`, `behavior delta review`, `architecture/cohesion review`, `quality review`, `runtime smoke review when applicable`
- `gate_stack`: `Python tests`, `tools/check-rma.ps1`, `stylua --check`, `luacheck`, `TOC validator`, `Lua 5.1 validator`, `xpcall scan`, `XML handler scan`, `git diff --check`

## Validation Commands

Run or explicitly report why a command could not be run:

- `py -3 -m unittest discover -s tests`
- `powershell -ExecutionPolicy Bypass -File tools\check-rma.ps1`
- `stylua --check "Raid Management Addon"`
- `luacheck "Raid Management Addon"`
- `py -3 .agents\skills\wow-addon-dev-wotlk-v335a\scripts\validate_toc.py "Raid Management Addon\Raid Management Addon.toc"`
- `py -3 .agents\skills\wow-addon-dev-wotlk-v335a\scripts\lint_lua51.py "Raid Management Addon"`
- `py -3 .agents\skills\wow-addon-dev-wotlk-v335a\scripts\scan_xpcall.py "Raid Management Addon"`
- `rg -n "<Scripts>|<On[A-Za-z]+>" "Raid Management Addon\UI" -g "*.xml"`
- `git diff --check`

## Runtime Smoke Checklist

Static validation is not enough for WoW runtime behavior. Runtime-critical batches must include a smoke note for relevant cases:

- open `/rma`, `/rma config`, `/rma ml`, `/rma counter`, `/rma history`, `/rma attendance`, `/rma res`, `/rma rw`, `/rma lfm`
- start and resolve MS/OS/SoftRes/Free roll sessions
- handle tie reroll and late-roll blocking
- award or select an item only when Blizzard permissions allow it
- verify inventory trade reminder/path for tradeable items
- switch loot method where permitted and restore expected state
- import SoftRes data and check current item reserves
- run reserves sync with compatible grouped client
- run version sync with compatible and incompatible client versions
- run logger sync/request/push with matching raid context
- create a raid/session, confirm attendance join/leave segments, and confirm inspect snapshot status without continuous polling
- verify no Lua errors during `/reload`, group changes, combat entry/exit, inspect timeout, and missing item info

## Audit and Documentation Artifacts

The rewrite should update tracked artifacts as applicable:

- `README.md`
- `docs/ARCHITECTURE.md`
- `docs/DEVELOPMENT.md`
- `docs/SAVED_VARIABLES.md`
- `docs/VALIDATION.md`
- generated API/reference docs if present in the project tooling

Separate behavior matrices, product-improvement logs, cohesion audits, or
residual-work maps should be added only when a real batch produces enough
evidence to justify a dedicated artifact.

If `AGENTS.md` remains ignored, tracked docs/tests/tools must carry the committable GREENFIELD_REWRITE policy, or `AGENTS.md` must be made intentionally trackable.

## Batch Workflow

Before implementation:

- identify macro area
- identify preserved external behavior
- identify intended improvement
- identify data migration risk
- identify WoW runtime risk
- identify tests and smoke checks
- identify likely files to keep, merge, rework, or delete

During implementation:

- work in small vertical slices where possible
- keep domain policy out of UI glue
- keep frame layout out of services
- remove pass-through wrappers as they are encountered
- update TOC and registry dependencies in the same batch as file changes
- update tests when behavior is intentionally improved

After implementation:

- produce behavior delta report
- produce cohesion/file-boundary report for touched areas
- produce DRY/wrapper reduction report when applicable
- run validation gates or report unavailable gates
- update docs and residual work map

## Commit Coherence Policy

A rewrite batch is not committable until the following are coherent:

- TOC references
- runtime Lua/XML files
- deleted/renamed file references
- ModuleRegistry dependencies
- SavedVariables ownership
- generated docs or API references
- tests
- tools/check scripts
- policy docs
- README command/feature documentation

Before staging or calling the rewrite committable, produce a commit coherence report covering:

- TOC-referenced changed runtime files
- untracked runtime files
- deleted runtime references
- registry dependency risk
- changed tracked policy artifacts
- validation commands run/not run
- remaining residual risks

## Definition of Done

A GREENFIELD_REWRITE batch is complete only when:

- external behavior remains compatible or behavior deltas are explicitly documented
- at least one real product/architecture improvement is delivered
- SavedVariables remain safe and migratable
- `/rma` commands and aliases remain coherent
- addon-message behavior remains compatible or safely versioned
- XML remains layout-only
- Lua remains 5.1-compatible
- TOC/load order is valid
- no new pass-through wrapper or accidental public API is introduced
- touched code has clear ownership
- tests protect behavior rather than temporary internals
- validation gates are run or honestly reported as unavailable
- runtime smoke risk is documented for in-game-only behavior
- residual work is recorded instead of hidden
