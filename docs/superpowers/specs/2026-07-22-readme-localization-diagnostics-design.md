# README, Localization, and Diagnostics Design

## Objective

Bring the addon documentation and text catalogs in line with the current RMA
runtime. The change will document every user-facing feature and command, add
complete user-facing localization for Russian, Simplified Chinese, Spanish,
and French, centralize Lua `assert` messages in the English diagnostics
catalog, and audit the runtime for remaining localizable text.

## Scope

This work covers:

- the repository README and the packaged addon README;
- user-facing English localization and four new WoW locale catalogs;
- English-only technical diagnostics and `assert` contract messages;
- Lua and XML text that can be displayed to an addon user;
- validation of localization keys, format placeholders, TOC load order, Lua
  5.1 compatibility, and XML layout-only policy.

This work does not change SavedVariables, database schemas, sync payloads,
slash-command tokens, import/export formats, gameplay behavior, or vendored
libraries.

## Documentation Design

Both `README.md` files remain in English and contain identical addon-facing
content. The root copy serves repository readers; the packaged copy travels
with the addon. They will be regenerated from a fresh inspection of the
runtime rather than by extending the current feature list without evidence.

The README groups information by user function:

1. compatibility and installation;
2. Master Loot and distribution workflow;
3. rolls, winner selection, and Loot Counter;
4. SoftRes import, aliases, checks, whispers, and synchronization;
5. loot history, raid recording, attendance, inspection, and history sync;
6. Raid Warnings and LFM recruitment;
7. minimap, Quick Bar, and configuration;
8. diagnostics, validation, debug, and performance tools;
9. slash commands grouped under the same functional headings;
10. permissions, SavedVariables, compatibility notes, and runtime limitations.

Each feature description explains both capability and operating logic where
that logic matters to the user: required authority, automatic versus manual
behavior, fallbacks, confirmation steps, and compatibility constraints. The
command reference includes aliases and subcommands proven by the registered
slash handlers. Internal debug-only commands are clearly separated from normal
raid workflows.

## Localization Architecture

`Localization/localization.en.lua` remains the canonical catalog and fallback.
The TOC loads English first, followed by locale-specific files for:

- `ruRU` — Russian;
- `zhCN` — Simplified Chinese;
- `esES` — Spanish;
- `frFR` — French.

Each added file returns immediately unless `GetLocale()` matches its locale,
then overrides `addon.L` entries. The implementation uses the existing
`addon.L` table and does not introduce a localization library or new runtime
service.

All user-visible English keys receive a translated value unless a value must
remain stable for runtime matching. Translated content includes UI labels,
buttons, popup text, tooltips, chat messages, command help, validation output,
and user-facing error messages. The following remain stable and untranslated:

- `/rma` command words and aliases;
- addon-message prefixes, protocol tokens, and wire-format values;
- SavedVariable and schema field names;
- CSV/JSON field contracts and import tokens;
- texture paths, frame names, popup keys, and internal identifiers;
- technical diagnostics and programmer-facing contract failures;
- canonical source strings used to match client events, boss yells, or raid
  identities when translation would change runtime behavior.

Locale files may translate display values for canonical raid or boss data only
when the canonical lookup key remains unchanged. Format placeholders must
preserve their count, conversion type, and positional meaning. WoW color and
hyperlink escape sequences must remain structurally valid.

## Diagnostics and Assert Messages

`Localization/DiagnoseLog.en.lua` remains English-only and is expanded with a
dedicated assertion/contract-message section under the existing `addon.Diag`
namespace. Every explicit programmer-facing message supplied to a runtime Lua
`assert` moves into that catalog and the call site references the corresponding
diagnostic entry.

The implementation preserves the original assertion condition, failure timing,
error level, and message meaning. Dynamic messages use catalog format strings
and local `string.format` only where the existing message contains runtime
values. Assertions without an explicit message do not gain speculative text.
No generic assertion wrapper, dependency-injection framework, or compatibility
layer is added.

Technical strings used by `error()` or diagnostic logging are audited at the
same time. Existing diagnostic log entries remain in `addon.Diag`; user-facing
errors move to `addon.L`; internal state tokens and machine-readable error
codes remain local constants where appropriate. The task does not blindly move
every Lua string into a catalog.

## Localizable-Text Audit

The audit scans non-vendored Lua and XML for text passed to visible surfaces,
including frame labels, popup bodies, tooltips, chat output, slash help, status
messages, and error displays. Each candidate is classified as:

- user-facing and localizable: move to or reference `addon.L`;
- programmer-facing diagnostic: move to or reference `addon.Diag`;
- runtime contract or machine token: keep unchanged;
- empty string, punctuation, number, path, identifier, or data value: keep
  local when localization has no meaning.

The audit must account for concatenated text and formatted fragments, not only
simple `SetText("...")` calls. XML remains layout-only and receives no script
handlers.

## Validation

Validation is complete when fresh checks demonstrate:

- the two README files contain identical addon-facing content;
- every locale catalog has coverage for every translatable English key;
- format placeholders and WoW escape sequences remain compatible with English;
- no explicit literal or concatenated message remains inside runtime `assert`
  calls outside vendored libraries;
- the localizable-text audit has no unexplained user-visible English literals;
- the TOC references every localization file in English-first load order;
- Lua parses under the project Lua 5.1 validator;
- the `xpcall` compatibility scan passes;
- XML contains no script handlers;
- repository tests and `tools/check-rma.ps1`, when present, pass;
- `git diff --check` is clean.

An in-game WotLK 3.3.5a smoke test remains required for final runtime
confidence. It should open `/rma`, inspect each major window in at least English
and one added locale, exercise command help, and confirm that a deliberately
triggered development assertion still reports the cataloged English message.

## Acceptance Criteria

- README content accurately represents the current addon and groups commands
  by function.
- Russian, Simplified Chinese, Spanish, and French users receive translated
  UI, chat, help, and user-facing errors without mixed-English gaps caused by
  missing catalog entries.
- Diagnostics and assertion messages remain technical English and have one
  clear catalog owner.
- Runtime matching, persistence, protocol, and import/export contracts are
  unchanged.
- No new abstraction is introduced solely to support localization or asserts.
- Automated checks and the final report identify any limitation that can only
  be verified in game.
