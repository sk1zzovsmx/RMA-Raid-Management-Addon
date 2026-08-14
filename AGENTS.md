# Raid Management Addon - AGENTS.md

Project-local instructions for AI coding agents working on Raid Management Addon.
Keep changes grounded in this repository and in the WotLK 3.3.5a client.

Default: these guidelines are binding for project identity, runtime compatibility,
SavedVariables, and release packaging. For everything else, follow the existing
code style unless the user asks for a redesign.

---

## 1) Project Identity

- Addon name: `Raid Management Addon`.
- Runtime short name: `RMA`.
- Addon folder name: `Raid Management Addon`.
- TOC file: `Raid Management Addon.toc`.
- Main slash command: `/rma`.
- Public SavedVariables use only the `RMA_` prefix.
- Addon-message prefixes use the `RMA` prefix.
- User-facing UI, chat text, docs, aliases, frame names, popup keys, and globals
  must not reintroduce old project branding.
- Vendored third-party libraries under `Libs/` may keep their upstream metadata,
  comments, and package identifiers. Do not edit vendored libraries for branding.

Current account SavedVariables:

- `RMA_Raids`
- `RMA_Players`
- `RMA_Reserves`
- `RMA_Warnings`
- `RMA_Spammer`
- `RMA_Options`

This addon starts clean. Do not read, migrate, or write non-RMA SavedVariables
unless the user explicitly asks for an import tool. SavedVariables migrations
are reserved for future `RMA_*` schema evolution, not automatic conversion from
other addons or old project identities.

---

## 2) Work Intake

- Before changing files, inspect the current repository state.
- Keep the requested scope exact. Do not broaden a UI cleanup into a feature
  redesign unless the user asks for it.
- For small, single-file documentation or policy changes, edit directly.
- For multi-file runtime work, first map ownership, write a concise plan, then
  apply small reversible patches.
- Use subagents or worktrees when the user asks for parallel work or when tasks
  can be split into independent read-only reviews or disjoint write scopes.
- Do not add speculative features.
- Prefer code reduction, clearer ownership, and simpler runtime contracts over
  compatibility layers carried only for historical reasons.
- The source addon history is useful context, not a design constraint.

### Simplicity Principles

- Apply KISS (Keep It Simple, Stupid). Choose the simplest design that fully
  meets the current business and runtime requirements. Simplicity does not mean
  avoiding structure or established best practices; every layer, pattern, and
  dependency must earn its cost.
- Apply YAGNI (You Ain't Gonna Need It). Do not add features, extension points,
  configurability, compatibility layers, or optimizations for hypothetical
  future needs. Add them only when a concrete, proven requirement exists.
- Apply DRY (Don't Repeat Yourself) with judgment. Prefer small, clear
  duplication over a premature abstraction. Extract shared behavior only when
  the repeated concept and its stable contract are demonstrated and the
  abstraction provides clear, immediate value.
- During design and review, challenge speculative flexibility, traffic-driven
  optimization without evidence, single-use abstractions, unnecessary design
  patterns, and indirection that makes ownership or data flow harder to follow.

### Proportional Workflow, Verification, And Model Routing

- Keep the workflow proportional to the demonstrated risk. Small, local changes
  do not need a full planning, testing, review, and refix pipeline.
- Start with the narrowest check that can disprove the changed behavior. Run the
  full relevant suite once at the end, or earlier only for cross-cutting,
  persistence, wire-format, load-order, or runtime-safety risk.
- After a failure, identify and fix the evidenced cause, then rerun the failed or
  nearest focused check first. Do not repeatedly rerun the full suite after each
  edit.
- Allow at most two repair cycles for the same failure without new evidence. If
  it still fails, stop the refix loop, reassess the diagnosis, and report the
  blocker or changed understanding before adding more code or tests.
- Do not add tests, abstractions, fallbacks, compatibility layers, or validation
  passes for hypothetical edge cases. Protect current behavior, explicit
  contracts, and demonstrated failure modes.
- Use the minimum set of skills or plugins needed for the task. A plugin must
  not expand a small change into a heavyweight workflow unless a concrete risk
  or a higher-priority instruction requires it.
- Route model use by task difficulty: use GPT-5.6-Luna for bounded searches,
  documentation, mechanical checks, and low-risk edits; GPT-5.6-Terra for normal
  implementation, focused testing, and ordinary debugging; GPT-5.6-Sol for
  architecture, SavedVariables, sync protocols, cross-module correctness, or a
  problem that remains complex after one evidence-based diagnostic pass.
- Do not escalate models or reasoning effort only because a test failed.
  Escalate when new evidence shows greater scope, ambiguity, or runtime risk.

### Task Mode: GREENFIELD_REWRITE

Use `GREENFIELD_REWRITE` only when the user explicitly asks for that exact mode.
Default work remains scoped, conservative, and incremental. In this mode,
`docs/GREENFIELD_REWRITE_CONTRACT.md` is the tracked, committable contract; keep
this AGENTS section aligned with it.

GREENFIELD_REWRITE is product-improvement work, not bug-for-bug reproduction.
Existing project files are behavioral evidence and product-intent evidence, not
an architecture to preserve. The rewrite must keep the public addon contract
stable while improving reliability, runtime safety, raid usability,
maintainability, ownership, and internal data flow.

Contract principle:

- Primary goal: improve the addon, not merely reproduce the old code.
- Compatibility goal: preserve the public/external contract unless a behavior is
  explicitly classified as broken, unsafe, confusing, or obsolete.
- Architecture goal: build one coherent architecture with clear ownership,
  stable data flow, minimal accidental API surface, and appropriate file
  boundaries.
- Anti-goal: do not keep wrappers, file splits, tests, or behavior only because
  the current implementation has them.
- Bug-for-bug preservation is forbidden; broken behavior must be fixed with a
  documented behavior delta.
- A batch is committable only when behavior, architecture, docs, tests, TOC,
  registry, and validation gates agree.

Stable external surface:

- Addon name, folder, TOC metadata, `30300` interface, WotLK 3.3.5a runtime, and
  Lua 5.1 compatibility.
- Runtime short name `RMA`, `/rma`, slash aliases, `RMA_*` SavedVariables,
  addon-message prefixes, and user-visible RMA branding.
- User-facing raid, loot, reserves, logger, attendance, warnings, LFM, minimap,
  config, diagnostics, and sync workflows.
- Persisted `RMA_*` data that existing users already have.
- XML frame identities referenced by runtime Lua, unless migrated in one
  coherent batch with all Lua, docs, tests, and smoke notes updated.

Non-stable implementation surfaces:

- Current file count, folder split, private function names, temporary Bind APIs,
  pass-through wrappers, and ModuleRegistry entries created only by file
  boundaries.
- Tests that lock implementation details rather than user-visible behavior.
- Current bugs, timing flaws, duplicated helper families, UI inconsistencies, or
  accidental behavior.

Before editing in GREENFIELD_REWRITE mode:

1. Inspect the repository and infer language, runtime, structure, entry points,
   behavior, configuration, persistence, tests, and build workflow.
2. Summarize what the project is.
3. Identify preserved external behavior and required public interfaces.
4. Identify the intended product or architecture improvement.
5. Identify data migration risk, WoW runtime risk, tests, smoke checks, and
   likely files to keep, merge, rework, or delete.
6. Propose a new architecture from scratch.

Then rewrite as a clean implementation with one coherent architecture, one
naming system, one data-flow model, and one implementation philosophy. Do not
perform incremental refactoring, optimize for minimal diffs, preserve old file
organization or helper functions unless required, mix old and new architecture,
leave transitional code, leave duplicate implementations, or leave dead code.

Product behavior to preserve and improve includes Master Loot, roll tracking,
Loot Counter, SoftRes/Reserves, Loot History/Logger, Raid Attendance and
Inspect, Raid Warnings, LFM Spam, Minimap, Configuration, Diagnostics, database
access, slash commands, addon-message sync, and widgets. Review these as
product-oriented macro areas rather than isolated file slices.

Every batch must name at least one intended improvement:

- bug fix
- UX improvement
- runtime safety
- data integrity
- performance
- maintainability

When current behavior changes, record the behavior delta: old behavior, new
behavior, reason, whether the old behavior was broken/unsafe/confusing/obsolete,
compatibility impact, migration impact, and tests or smoke checks that prove
the intended behavior.

### Cohesion-First Module Boundaries

Module boundaries are cohesion-first and product-first. The boundary question is
whether the file owns a durable concept, data shape, runtime integration,
feature UI composition, or testable algorithm that deserves its own API and
load-order cost.

Do not split or merge by line count alone. Prefer fewer accidental files, but do
not merge cohesive owners only to reduce count. A new Lua file is allowed only
when it owns a clear concept, policy, data shape, runtime integration boundary,
UI composition owner, or testable algorithm. Small pass-through files default to
merge or delete.

Extraction is allowed only when it reduces caller complexity, stabilizes a
contract, or isolates a real policy/integration boundary. Each TOC entry must
justify its load-order and dependency cost. ModuleRegistry entries must
represent real runtime dependencies, not artifacts of unnecessary file splitting.

Shared logic belongs to the nearest cohesive owner: feature owner,
service/domain owner, UI primitive owner, or runtime infrastructure owner. Do
not add generic `Utils`, `Common`, `Shared`, or catch-all `Helpers` modules just
because code looks similar. Local duplication may remain only when variants have
materially different semantics, caller state, runtime constraints, or failure
behavior.

Facades may stay only when they add validation, compose multiple owners into a
policy, isolate a stable external contract, or reduce caller complexity without
hiding ownership. Pass-through modules, one-function wrappers, single-event
handler files, and files that only rename a concrete owner method are forbidden.
When deleting wrappers, update callers to the real owner, remove stale TOC
entries, remove stale registry dependencies, update generated docs, and record
the reduction.

UI architecture remains explicit: XML owns static layout only; Lua owns
behavior, state, event handlers, row construction, list refresh, dynamic
visibility, and user actions. Feature UI controllers must not own domain rules
that belong in services, and services must not own frame-specific layout
details.

Runtime safety remains binding: Lua is 5.1, WotLK 3.3.5a APIs only, no
unbounded `OnUpdate`, no heavy combat work, and inspect, sync, chat, tooltip,
item-info, and loot operations must be throttled and failure-safe.

GREENFIELD_REWRITE tests should protect behavior, external contracts,
validation gates, and rejected anti-patterns. They must not lock temporary file
splits, private helper names, exact internal Bind APIs, ModuleRegistry entries
that may disappear after consolidation, TOC entries for modules that the
cohesion gate may still merge, current bugs, or accidental implementation
behavior.

The verification target is not merely "tests pass". Each batch must pass
through implementation, behavior delta review, architecture/cohesion review,
quality review, and runtime smoke review when applicable. Then run or explicitly
account for Python tests, `tools/check-rma.ps1`, `stylua --check`, `luacheck`,
TOC validation, Lua 5.1 validation, `xpcall` scan, XML handler scan, and
`git diff --check`.

Before staging or calling the rewrite committable, produce a commit coherence
report covering TOC-referenced changed runtime files, untracked runtime files,
deleted runtime references, registry dependency risk, changed tracked policy
artifacts, validation commands run or not run, and remaining residual risks.

GREENFIELD_REWRITE is complete only when external behavior remains compatible
or behavior deltas are documented, at least one real product/architecture
improvement is delivered, SavedVariables remain safe, `/rma` aliases remain
coherent, addon-message behavior remains compatible or versioned, XML remains
layout-only, Lua remains 5.1-compatible, TOC/load order is valid, no new
pass-through wrapper or accidental public API is introduced, touched code has
clear ownership, tests protect behavior rather than temporary internals,
validation gates are reported honestly, runtime smoke risk is documented, and
residual work is recorded instead of hidden.

---

## 3) Runtime Constraints

- Client/API target: Wrath of the Lich King 3.3.5a.
- TOC Interface: `30300`.
- Runtime Lua: Lua 5.1.
- Do not introduce Ace2 or Ace3 dependencies.
- Do not modify vendored libraries under `Libs/*`.
- Do not use Retail/Classic-only APIs such as `C_Timer`, `C_AddOns`,
  `Settings.*`, `MenuUtil`, `SetAtlas`, or `SetColorTexture`.
- Do not use Lua 5.2+ syntax or APIs such as `goto`, `_ENV`, `table.pack`,
  `table.unpack`, bitwise operators, or `//`.
- Use `unpack` and Blizzard's `bit.*` namespace when needed.
- Avoid `io`, `os`, and `debug` in runtime addon code.
- Respect combat lockdown and protected action rules.
- Keep all runtime code, comments, UI labels, and diagnostics ASCII unless the
  user explicitly asks otherwise.

---

## 4) Repository Shape

This repository intentionally starts as a clean addon project, not as a full
tooling/docs clone.

- Runtime code lives in the repository root and the addon subfolders.
- Keep local Codex state out of Git: `.codex/`, `.agents/`, `.vscode/`, `.venv/`,
  caches, generated logs, and package artifacts.
- Add project-local tools, tests, or docs only when they are useful for the next
  concrete development step.
- Keep release packages focused on the addon folder contents only.
- Do not add old project workflow files unless the user explicitly asks to port
  a specific workflow.

---

## 5) Runtime Architecture

Preserve clear ownership boundaries while the imported code is simplified.

- `Init.lua` owns bootstrap, shared runtime tables, and main event wiring.
- `Database/*` owns persistence contracts, options, schemas, and store access.
- `Modules/*` owns reusable infrastructure and static data.
- `Services/*` owns runtime service and model logic.
- `Controllers/*` owns top-level feature controllers and their frames.
- `Widgets/*` owns feature-specific child widgets.
- `EntryPoints/*` owns slash and minimap entrypoints.
- `UI/*` XML stays layout-only.
- `Raid Management Addon.toc` is the authoritative load order.

Layering rules:

- Services must not call controllers, touch controller frames, or reference
  widgets directly.
- Entry points may call top-level controller `Toggle`, `Show`, or `Hide` methods.
- Controllers may compose widgets and services.
- Widgets should not own persistence.
- Shared UI helpers belong under `Modules/UI/*`.
- Feature-specific UI behavior belongs in `Controllers/*` or `Widgets/*`.
- Prefer event-driven redraws. Avoid feature-frame polling with `OnUpdate`.

---

## 6) Lua Style

- Everything is `local` unless intentionally exported.
- Use `:` only when the function expects `self`.
- Use `.` for plain module functions.
- Do not mechanically convert call style without checking function signatures.
- Public module tables and public exported methods use PascalCase.
- WoW event handler names stay uppercase.
- Local helpers and local variables use camelCase.
- Arrays are 1-indexed.
- If table holes are possible, do not rely on `#t`.
- Use `for i = 1, #arr do ... end` for sequences and `pairs()` for maps.
- Recoverable failure returns `nil, "reason"` or `false` with a localized
  message.
- Programmer errors may use `assert()` or `error()`.

Preferred file header:

```lua
local addon = select(2, ...)
```

Use canonical namespaces where existing code already does:

- `addon.Database`
- `addon.Controllers.*`
- `addon.Services.*`
- `addon.Widgets.*`
- `addon.UI.*`
- `addon.Modules` or concrete shared modules such as `addon.Item`,
  `addon.Sort`, and `addon.Bus`

---

## 7) SavedVariables And Persistence

- Treat fresh SavedVariables as strict mode.
- Store only canonical restore-critical data.
- Avoid persisting duplicated, derived, or runtime-only fields.
- Keep runtime indexes and caches derived from canonical persisted stores.
- Use stable identifiers instead of volatile array indexes for cross-session
  references.
- Any SavedVariables schema change must be deliberate, documented in the change,
  and validated with a reload smoke test.
- Keep bootstrap, RMA schema migrations, and imports separate: bootstrap
  initializes current `RMA_*` keys, migrations evolve existing `RMA_*` schema
  versions, and non-RMA imports must be explicit tools outside normal startup.
- Do not add migrations from non-RMA keys unless explicitly requested as an
  import tool.

Options:

- Keep options under `RMA_Options`.
- Prefer registered option namespaces and typed getter/setter helpers already
  present in the code.
- Do not write options through ad hoc globals.

---

## 8) UI Policy

- XML is layout-only. Do not add XML `<Scripts>` blocks or `<On...>` handlers.
- Lua owns behavior, event binding, localization, and refresh logic.
- Prefer named-frame access patterns that already exist in the code.
- User-facing strings go through `addon.L`.
- Diagnostic templates go through `addon.Diagnose`.
- Keep windows and visible labels branded as Raid Management Addon or RMA only.
- Frame names, XML templates, popup keys, and slash aliases must use RMA naming.
- Keep compact operational UI. Do not add marketing-style screens inside the
  addon.
- In tables and lists, use fixed row heights and stable command columns.
- Do not anchor button columns to variable-width or wrapped text.

---

## 9) Communication And Wire Formats

- Addon-message prefixes must use RMA names.
- Treat sync payload and addon-message wire changes as compatibility-sensitive.
- Do not change wire formats casually.
- If a breaking sync format is required, make the versioning explicit and keep
  the fallback behavior understandable.
- Chat output should go through the chat service where one exists.
- Prefer localized format strings over sentence concatenation.

---

## 10) Validation

Run checks appropriate to the change. For documentation-only edits, at minimum:

```powershell
git diff --check
git status --short --branch
```

For runtime or TOC changes, also run available WotLK 3.3.5a validators for:

- TOC file references and unsupported directives
- Lua 5.1 syntax
- Lua 5.1 `xpcall` extra-argument traps
- XML script handlers
- stale project branding outside `Libs/`

Useful repository searches:

```powershell
rg -n "<Scripts>|<On[A-Za-z]+>" UI -g "*.xml"
rg -n "RMA_|Raid Management Addon|/rma" . -g "*.lua" -g "*.xml" -g "*.toc" -g "*.md" -g "!Libs/**"
```

For retired identifier checks, build the temporary search pattern outside the
repo and do not commit old branding strings into project docs.

Runtime smoke test after relevant changes:

- Login with no Lua errors.
- `/rma` opens the addon.
- Main windows create without missing-frame errors.
- `/reload` preserves expected `RMA_*` SavedVariables.
- Raid, loot, reserves, logger, warnings, and spammer workflows still operate.

---

## 11) Release Policy

- Version metadata lives in `Raid Management Addon.toc`.
- Use SemVer-compatible versions.
- Use alpha versions for internal development baselines.
- Package only the addon project contents required by the WoW client.
- Do not include local Codex state, logs, caches, worktrees, or generated ZIP
  checksums inside the addon package.
