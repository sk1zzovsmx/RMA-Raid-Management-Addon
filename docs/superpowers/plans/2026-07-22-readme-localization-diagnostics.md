# README, Localization, and Diagnostics Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Document the complete current RMA feature set, add complete Russian, Simplified Chinese, Spanish, and French user-facing catalogs, centralize technical assertion text, and close remaining localization gaps.

**Architecture:** Keep `addon.L` as the English-first localization table and add four locale-gated override files. Keep technical English under the existing `addon.Diag`/`addon.Diagnose` namespace; load `DiagnoseLog.en.lua` before `Init.lua` so bootstrap assertions can use the same catalog without a wrapper. Protect the result with one static Python contract test and the existing WotLK validation suite.

**Tech Stack:** Lua 5.1, WoW WotLK 3.3.5a Interface 30300, TOC load ordering, Python 3 `unittest`, Markdown.

## Global Constraints

- Addon name is `Raid Management Addon`; runtime short name and public identifiers use `RMA`/`RMA_`.
- Runtime must remain Lua 5.1-compatible and use only WotLK 3.3.5a APIs.
- Do not modify `Raid Management Addon/Libs/**`.
- Do not change SavedVariables, schemas, sync payloads, slash-command tokens, or import/export formats.
- XML remains layout-only; behavior and localization remain in Lua.
- UI, chat, help, tooltips, popup text, and user-facing errors are translated.
- Diagnostics and programmer-facing assertion failures remain English-only.
- English is the canonical fallback; `ruRU`, `zhCN`, `esES`, and `frFR` are complete locale overrides.
- Canonical client-event strings, boss-yell lookup keys, protocol tokens, paths, frame names, popup keys, and machine-readable error codes remain unchanged.
- The root and packaged README remain English and contain identical addon-facing content.

---

### Task 1: Establish localization contracts and complete the user-facing catalogs

**Files:**

- Create: `tests/test_localization_contract.py`
- Create: `Raid Management Addon/Localization/localization.ru.lua`
- Create: `Raid Management Addon/Localization/localization.zhCN.lua`
- Create: `Raid Management Addon/Localization/localization.es.lua`
- Create: `Raid Management Addon/Localization/localization.fr.lua`
- Modify: `Raid Management Addon/Localization/localization.en.lua`
- Modify: `Raid Management Addon/Raid Management Addon.toc`
- Modify only when the audit proves user-visible hard-coded text: non-vendored files under `Raid Management Addon/Controllers/`, `Raid Management Addon/EntryPoints/`, `Raid Management Addon/Modules/`, `Raid Management Addon/Services/`, and `Raid Management Addon/Widgets/`

**Interfaces:**

- Consumes: `addon.L`, WoW global `GetLocale()`, English assignments in `localization.en.lua`.
- Produces: complete scalar localization-key parity for `ruRU`, `zhCN`, `esES`, and `frFR`; locale files that perform no writes under a different client locale; English keys for every audited user-visible runtime string.

- [ ] **Step 1: Add a failing localization contract test**

Create `tests/test_localization_contract.py` with helpers that read non-vendored runtime sources, extract scalar assignments matching `L.<Key> =`, and extract printf placeholders with `%(?:\d+\$)?[-+ #0]*(?:\d+|\*)?(?:\.\d+|\.\*)?[cdeEfgGiouXxqs]`. The test must include these exact contracts:

```python
LOCALES = {
    "ruRU": ADDON / "Localization" / "localization.ru.lua",
    "zhCN": ADDON / "Localization" / "localization.zhCN.lua",
    "esES": ADDON / "Localization" / "localization.es.lua",
    "frFR": ADDON / "Localization" / "localization.fr.lua",
}

def test_toc_loads_english_then_all_locale_overrides(self) -> None:
    toc = (ADDON / "Raid Management Addon.toc").read_text(encoding="utf-8")
    expected = [
        r"Localization\localization.en.lua",
        r"Localization\localization.ru.lua",
        r"Localization\localization.zhCN.lua",
        r"Localization\localization.es.lua",
        r"Localization\localization.fr.lua",
    ]
    positions = [toc.index(path) for path in expected]
    self.assertEqual(sorted(positions), positions)

def test_locale_files_are_gated_and_cover_english_scalar_keys(self) -> None:
    english = scalar_assignments(ENGLISH)
    self.assertGreater(len(english), 800)
    for locale, path in LOCALES.items():
        source = path.read_text(encoding="utf-8")
        self.assertIn(f'GetLocale() ~= "{locale}"', source)
        translated = scalar_assignments(path)
        self.assertEqual(set(english), set(translated), locale)

def test_translations_preserve_printf_contracts(self) -> None:
    english = scalar_assignments(ENGLISH)
    for locale, path in LOCALES.items():
        translated = scalar_assignments(path)
        for key, value in english.items():
            self.assertEqual(placeholders(value), placeholders(translated[key]), f"{locale}:{key}")
```

Also test that each locale file is ASCII-safe Lua syntax apart from translated string contents, does not assign `L.RaidZones` or `L.BossYells`, and contains no command translation such as replacing `/rma`, `MS`, `OS`, `SR`, `CSV`, or `JSON` inside documented command syntax.

- [ ] **Step 2: Run the focused test and confirm the expected failure**

Run:

```powershell
py -3 -m unittest tests.test_localization_contract -v
```

Expected: failure because the four locale files and TOC entries do not exist.

- [ ] **Step 3: Perform the user-visible text audit and complete English ownership**

Scan all non-vendored Lua/XML call sites that can display text:

```powershell
rg -n 'SetText|SetFormattedText|AddMessage|SetTooltip|SetTitle|SetDescription|SendChatMessage|addon:(info|warn|error)|Chat\.' "Raid Management Addon" -g "*.lua" -g "*.xml" -g "!Libs/**" -g "!Localization/**"
rg -n '"[^"\r\n]*[A-Za-z][^"\r\n]*"' "Raid Management Addon" -g "*.lua" -g "!Libs/**" -g "!Localization/**"
```

Classify every candidate under the design rules. Add named `L.<Key>` entries for genuine user-visible prose and replace the call-site literal with that key. Keep empty strings, punctuation, item-count fragments such as `" x"`, paths, identifiers, data values, and machine tokens local. Do not move diagnostic or assertion text in this task.

- [ ] **Step 4: Add four complete locale-gated catalogs and TOC entries**

Each locale file begins with the same minimal contract, changing only the locale code:

```lua
local addon = select(2, ...)

if GetLocale() ~= "ruRU" then
	return
end

local L = addon.L
```

Translate every scalar `L.<Key>` owned by English into natural Russian, Simplified Chinese, Spanish, or French. Preserve `%s`, `%d`, width/precision specifiers, newline structure, WoW color escapes (`|c...|r`), hyperlinks (`|H...|h...|h`), plural/count semantics, and command tokens. Do not copy `RaidZones` or `BossYells`; English remains the canonical runtime lookup data. Add TOC entries immediately after `localization.en.lua` and before runtime modules.

- [ ] **Step 5: Run focused localization and syntax checks**

Run:

```powershell
py -3 -m unittest tests.test_localization_contract -v
py -3 .agents\skills\wow-addon-dev-wotlk-v335a\scripts\validate_toc.py "Raid Management Addon\Raid Management Addon.toc"
py -3 .agents\skills\wow-addon-dev-wotlk-v335a\scripts\lint_lua51.py "Raid Management Addon"
```

Expected: all localization tests pass; both validators exit 0.

- [ ] **Step 6: Commit the localization slice**

```powershell
git add -- "tests/test_localization_contract.py" "Raid Management Addon/Localization" "Raid Management Addon/Raid Management Addon.toc" "Raid Management Addon/Controllers" "Raid Management Addon/EntryPoints" "Raid Management Addon/Modules" "Raid Management Addon/Services" "Raid Management Addon/Widgets"
git commit -m "feat(localization): add complete multilingual catalogs"
```

---

### Task 2: Centralize technical assertion messages in the English diagnostics catalog

**Files:**

- Modify: `tests/test_localization_contract.py`
- Modify: `Raid Management Addon/Localization/DiagnoseLog.en.lua`
- Modify: `Raid Management Addon/Raid Management Addon.toc`
- Modify: `Raid Management Addon/Init.lua`
- Modify: every non-vendored runtime `.lua` file reported by `rg -l '\bassert\s*\(' "Raid Management Addon" -g "*.lua" -g "!Libs/**"`; limit changes in those files to replacing explicit assertion-message expressions and adding a local diagnostic binding or `string.format` binding when required.

**Interfaces:**

- Consumes: the private addon table supplied as `select(2, ...)`, existing `addon.Diagnose`, `addon.Diag`, and the original assertion conditions/messages.
- Produces: `Diag.A.<Key>` English templates available before `Init.lua`; unchanged assertion conditions and failure timing; no explicit literal or concatenated message expression in runtime assertions.

- [ ] **Step 1: Extend the contract test for pre-bootstrap diagnostics and assert ownership**

Add tests that:

```python
def test_diagnostics_load_before_init(self) -> None:
    toc = TOC.read_text(encoding="utf-8")
    self.assertLess(toc.index(r"Localization\DiagnoseLog.en.lua"), toc.index("Init.lua"))

def test_runtime_assert_messages_reference_diagnostic_catalog(self) -> None:
    offenders = []
    for path in runtime_lua_files():
        if "Libs" in path.parts:
            continue
        source = strip_lua_comments(path.read_text(encoding="utf-8"))
        for call in extract_balanced_calls(source, "assert"):
            args = split_top_level_arguments(call)
            if len(args) > 1 and "Diag.A." not in args[1]:
                offenders.append(f"{path.relative_to(ROOT)}: {args[1].strip()}")
    self.assertEqual([], offenders)
```

The balanced-call helper must handle multiline calls, quoted strings, escaped quotes, and nested parentheses so the test does not rely on a single-line regex. Exclude `Libs/**` and `tests/**`.

- [ ] **Step 2: Run the assert contract and confirm it fails**

Run:

```powershell
py -3 -m unittest tests.test_localization_contract.LocalizationDiagnosticsContractTest -v
```

Expected: failure showing current inline assertion messages and the current post-`Init.lua` diagnostic load order.

- [ ] **Step 3: Make the diagnostic catalog safe before bootstrap**

Move `Localization\DiagnoseLog.en.lua` in the TOC to immediately before `Init.lua`. Change its bootstrap from assuming `addon.Diag` exists to idempotently seeding the existing namespaces:

```lua
local addon = select(2, ...)

addon.Diagnose = addon.Diagnose or {}
addon.Diag = addon.Diag or addon.Diagnose

local Diag = addon.Diag
Diag.I = Diag.I or {}
Diag.W = Diag.W or {}
Diag.E = Diag.E or {}
Diag.D = Diag.D or {}
Diag.A = Diag.A or {}
```

Keep `Init.lua` idempotent: its existing `addon.Diagnose = addon.Diagnose or {}` and proxy metatable must preserve the preloaded entries. Add one focused test assertion that a catalog key remains reachable through `addon.Diag.A` after the bootstrap harness loads `Init.lua`.

- [ ] **Step 4: Catalog and replace explicit runtime assertion messages**

Add one PascalCase `Diag.A.<Key>` entry per distinct technical assertion meaning, grouped by owner (`Bootstrap`, `Database`, `Modules`, `Raid`, `Loot`, `Master`, `Rolls`, `Reserves`, `Controllers`, and `Widgets`). Keep the exact English message unless correcting a demonstrable typo. For a static assertion:

```lua
Diag.A.LootRulesItemInfoApiNotInitialized = "Loot rules item info API is not initialized"
```

and at the call site:

```lua
local Diag = addon.Diag
local GetItemInfo = assert(_G.GetItemInfo, Diag.A.LootRulesItemInfoApiNotInitialized)
```

For an existing dynamic message, catalog the complete template and format only at the failure boundary:

```lua
Diag.A.BootstrapMissingService = "RMA missing service: %s"
```

```lua
assert(type(serviceTable) == "table", format(Diag.A.BootstrapMissingService, tostring(serviceName)))
```

Do not add messages to assertions that currently omit one. Do not modify vendored library assertions. Do not replace `assert` with a wrapper and do not alter conditions, returned values, or error levels.

- [ ] **Step 5: Run focused diagnostics, bootstrap, and Lua checks**

Run:

```powershell
py -3 -m unittest tests.test_localization_contract tests.test_runtime_bootstrap_contract tests.test_runtime_foundations_behavior -v
py -3 .agents\skills\wow-addon-dev-wotlk-v335a\scripts\validate_toc.py "Raid Management Addon\Raid Management Addon.toc"
py -3 .agents\skills\wow-addon-dev-wotlk-v335a\scripts\lint_lua51.py "Raid Management Addon"
py -3 .agents\skills\wow-addon-dev-wotlk-v335a\scripts\scan_xpcall.py "Raid Management Addon"
```

Expected: all selected tests pass; all validators exit 0.

- [ ] **Step 6: Commit the diagnostics slice**

```powershell
git add -- "tests/test_localization_contract.py" "Raid Management Addon"
git commit -m "refactor(diagnostics): centralize assertion messages"
```

---

### Task 3: Rebuild both README copies from runtime evidence and run final validation

**Files:**

- Modify: `README.md`
- Modify: `Raid Management Addon/README.md`
- Modify: `tests/test_localization_contract.py`

**Interfaces:**

- Consumes: current TOC metadata, slash registration in `EntryPoints/SlashEvents.lua` and `EntryPoints/Debug.lua`, feature controllers/services/widgets, current SavedVariables, and validated localization catalogs.
- Produces: identical English README content organized by feature; complete command and alias coverage; final static contract proving the packaged README is synchronized.

- [ ] **Step 1: Add a failing README synchronization and command-coverage test**

Add these contracts to `tests/test_localization_contract.py`:

```python
def test_packaged_readme_matches_repository_readme(self) -> None:
    self.assertEqual(ROOT_README.read_text(encoding="utf-8"), PACKAGED_README.read_text(encoding="utf-8"))

def test_readme_documents_registered_command_families(self) -> None:
    readme = ROOT_README.read_text(encoding="utf-8")
    for command in registered_primary_commands(SLASH_EVENTS):
        self.assertIn(f"`/rma {command}", readme, command)
```

The command extractor must read the `cmd*` alias tables consumed by `registerAliases` rather than maintaining a second handwritten command list. Explicitly exclude internal dispatch tokens that are not player commands.

- [ ] **Step 2: Run the README contract and confirm the coverage failure**

Run:

```powershell
py -3 -m unittest tests.test_localization_contract.LocalizationReadmeContractTest -v
```

Expected: at least one command-family coverage failure against the current README or a test failure until the extractor is aligned with the current registration structure.

- [ ] **Step 3: Inventory current behavior and rewrite the English README by function**

Use runtime evidence, not assumptions:

```powershell
rg -n '^local cmd|registerAliases|handle[A-Za-z]+Command|RegisterCommand' "Raid Management Addon/EntryPoints" "Raid Management Addon/Services/Raid/Debug.lua" -g "*.lua"
rg -n '^function |^[A-Za-z0-9_.]+ = function|Options.RegisterNamespace|RegisterCallback|RegisterEvent' "Raid Management Addon/Controllers" "Raid Management Addon/Services" "Raid Management Addon/Widgets" -g "*.lua"
```

Rewrite `README.md` in English with compatibility and installation first, then these functional sections: Master Loot; rolls and Loot Counter; SoftRes/reserves; raid recording, Loot History, Attendance, and inspection; warnings and LFM; minimap and Quick Bar; configuration; diagnostics/validation/debug/performance. Within each section document operating logic, permissions, automation, fallbacks, and limitations, then list that function's slash commands and aliases. Retain explicit SavedVariables and WotLK/Lua constraints. Copy the exact completed content to `Raid Management Addon/README.md` using `apply_patch`, not a shell write command.

- [ ] **Step 4: Run focused documentation and localization checks**

Run:

```powershell
py -3 -m unittest tests.test_localization_contract -v
git diff --check
```

Expected: all focused tests pass and `git diff --check` exits 0.

- [ ] **Step 5: Run the complete repository validation suite**

Run once after all focused checks are green:

```powershell
py -3 -m unittest discover -s tests
py -3 .agents\skills\wow-addon-dev-wotlk-v335a\scripts\validate_toc.py "Raid Management Addon\Raid Management Addon.toc"
py -3 .agents\skills\wow-addon-dev-wotlk-v335a\scripts\lint_lua51.py "Raid Management Addon"
py -3 .agents\skills\wow-addon-dev-wotlk-v335a\scripts\scan_xpcall.py "Raid Management Addon"
rg -n "<Scripts>|<On[A-Za-z]+>" "Raid Management Addon/UI" -g "*.xml"
stylua --check "Raid Management Addon" "tests/lua"
luacheck "Raid Management Addon" "tests/lua"
git diff --check
git status --short --branch
```

Expected: Python tests and available validators pass; XML search returns no matches; format/lint commands pass when installed. If `stylua` or `luacheck` is unavailable, report that exact limitation rather than claiming the gate passed.

- [ ] **Step 6: Perform the final residual-string review and commit**

Re-run the visible-text and assertion searches from Tasks 1 and 2. For every remaining English literal outside localization, confirm it is an allowed path, token, identifier, canonical lookup value, data fragment, debug fixture, or machine-readable code. Record any text that requires an in-game decision rather than adding speculative keys.

```powershell
git add -- "README.md" "Raid Management Addon/README.md" "tests/test_localization_contract.py"
git commit -m "docs(readme): document complete addon workflows"
```

After committing, report that an in-game smoke test is still required: open `/rma`, inspect all major windows in English and at least one added locale, exercise localized command help, and confirm a deliberately triggered development assertion still displays its English catalog message.
