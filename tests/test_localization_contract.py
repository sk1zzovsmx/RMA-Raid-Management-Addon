from __future__ import annotations

from pathlib import Path
import re
import shutil
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[1]
ADDON = ROOT / "Raid Management Addon"
TOC = ADDON / "Raid Management Addon.toc"
ROOT_README = ROOT / "README.md"
PACKAGED_README = ADDON / "README.md"
SLASH_EVENTS = ADDON / "EntryPoints" / "SlashEvents.lua"
ENGLISH = ADDON / "Localization" / "localization.en.lua"
DIAGNOSTICS = ADDON / "Localization" / "DiagnoseLog.en.lua"
LOCALES = {
    "ruRU": ADDON / "Localization" / "localization.ru.lua",
    "zhCN": ADDON / "Localization" / "localization.zhCN.lua",
    "esES": ADDON / "Localization" / "localization.es.lua",
    "frFR": ADDON / "Localization" / "localization.fr.lua",
}
SCALAR_ASSIGNMENT = re.compile(
    r'^L\.(?P<key>[A-Za-z][A-Za-z0-9_]*)\s*=\s*(?P<value>"(?:\\.|[^"\\])*")\s*$',
    re.MULTILINE,
)
PRINTF_PLACEHOLDER = re.compile(
    r"%(?:\d+\$)?[-+ #0]*(?:\d+|\*)?(?:\.\d+|\.\*)?[cdeEfgGiouXxqs]"
)
COMMAND_TOKENS = (
    "/rma",
    "HIS",
    "ML",
    "GL",
    "MS",
    "OS",
    "SR",
    "RW",
    "NE",
    "GR",
    "DE",
    "RMA",
    "LFM",
    "SoftRes",
    "CSV",
    "JSON",
)
PARSER_HELP_FORMS = {
    "StrCmdDebug": "debug on|off|level <name|num>|raid|raidgrid",
    "StrCmdPerf": "perf on|off|threshold <ms>|report|audit|items|reset",
    "StrCmdDebugRaidRoll": "roll <1-4|name> [1-100]",
}
MACHINE_HELP_FORMS = {
    "StrCbErrUsage": ("RMA:registerCallback(event, callbacks)",),
    "WarnReservesHeaderHint": ("itemId", "name"),
    "StrReserveListAcceptSRTooltipText": ("+sr [itemLink]",),
    "StrCmdSpecInspect": ("force",),
    "ChatSoftResWhisperHelpAdd": ("+sr", "[itemLink]"),
    "MsgTimerStatsTip": ("sort: age|dur|target",),
    "MsgLogLevelList": ("error, warn, info, debug, trace, spam",),
}
QUARANTINE_KEYS = {
    "MsgRaidHistoryQuarantined",
    "StrRaidArchiveInvalidType",
    "StrRaidArchiveUnsupportedFormat",
    "StrRaidArchiveCorrupt",
    "StrRaidHistoryQuarantined",
    "RaidSyncStatusQuarantined",
}
UNKNOWN_RAID_WARNING_KEY = "MsgRaidInstanceUnsupported"
DIAGNOSTIC_IDENTIFIER = re.compile(
    r"(?<![A-Za-z])(?:raid|nid|schemaVersion|current|required|players|count|loot|bossNid|"
    r"_TrashMob_|bossKills|playerNid|looterNid)(?![A-Za-z])"
)
KEYED_FALSE_FRIENDS = {
    "ruRU": {
        "StrTrashMobName": ("Мусорная толпа",),
        "StrRoll": ("рулон", "прокат"),
        "BtnKeepMasterLoot": ("Мастер-грабитель",),
    },
    "zhCN": {
        "BtnQuickBarML": ("机器学习",),
        "StrTrashMobName": ("垃圾暴民",),
        "StrRoll": ("劳斯莱斯",),
        "StrSpammer": ("垃圾邮件",),
    },
    "esES": {
        "StrTrashMobName": ("mafia de basura",),
        "StrRoll": ("rollo", "rodar"),
        "StrQuickBarSoftResTooltip": ("resolución suave",),
    },
    "frFR": {
        "StrTrashMobName": ("foule poubelle",),
        "StrRoll": ("rouleau", "rouler"),
        "ChatTieReroll": ("cravate",),
    },
}
GLOSSARY_VALUES = {
    "ruRU": {
        "BtnKeepMasterLoot": "Сохранить метод «Ответственный за добычу»",
        "BtnFree": "Свободный ролл",
        "StrTrashMobName": "Трэш-моб",
        "StrTrashMob": "Трэш-моб",
        "StrRoll": "Бросок",
        "StrRolls": "Броски",
    },
    "zhCN": {
        "BtnKeepMasterLoot": "保留队长分配",
        "BtnFree": "自由掷骰",
        "StrTrashMobName": "小怪",
        "StrTrashMob": "小怪",
        "StrRoll": "掷骰",
        "StrRolls": "掷骰",
    },
    "esES": {
        "BtnKeepMasterLoot": "Mantener el modo Botín maestro",
        "BtnFree": "Tirada libre",
        "StrTrashMobName": "Enemigo menor",
        "StrTrashMob": "Enemigo menor",
        "StrRoll": "Tirada",
        "StrRolls": "Tiradas",
    },
    "frFR": {
        "BtnKeepMasterLoot": "Conserver le mode Maître du butin",
        "BtnFree": "Jet libre",
        "StrTrashMobName": "Ennemi mineur",
        "StrTrashMob": "Ennemi mineur",
        "StrRoll": "Jet",
        "StrRolls": "Jets",
    },
}
WOW_TOKEN = re.compile(r"\|c[0-9a-fA-F]{8}[^|]*\|r|\|H[^|]*\|h[^|]*\|h|\{[A-Za-z]+\}")
SLASH_COMMAND = re.compile(r"/rma[ a-z0-9<>\[\]\-|]*")
LOCALIZATION_FALLBACK = re.compile(
    r'(?:L\.[A-Za-z][A-Za-z0-9_]*|\(L\s+and\s+L\.[A-Za-z][A-Za-z0-9_]*\))\s+or\s+"[^"\r\n]*[A-Za-z][^"\r\n]*"'
)


def scalar_assignments(path: Path) -> dict[str, str]:
    return {
        match.group("key"): match.group("value")
        for match in SCALAR_ASSIGNMENT.finditer(path.read_text(encoding="utf-8"))
    }


def placeholders(value: str) -> list[str]:
    return PRINTF_PLACEHOLDER.findall(value)


def unquoted(value: str) -> str:
    return value[1:-1]


def assignment_values(path: Path) -> dict[str, str]:
    source = path.read_text(encoding="utf-8")
    starts = list(re.finditer(r"^L\.([A-Za-z][A-Za-z0-9_]*)\s*=", source, re.MULTILINE))
    values: dict[str, str] = {}
    for index, match in enumerate(starts):
        body_end = starts[index + 1].start() if index + 1 < len(starts) else len(source)
        body = source[match.end() : body_end]
        literals = re.findall(r'"((?:\\.|[^"\\])*)"', body)
        if literals:
            values[match.group(1)] = "".join(literals)
    return values


def newline_escape_structure(value: str) -> list[int]:
    structure: list[int] = []
    index = 0
    while index < len(value):
        if value[index] != "\\":
            index += 1
            continue
        end = index
        while end < len(value) and value[end] == "\\":
            end += 1
        if end < len(value) and value[end] == "n":
            structure.append(end - index)
        index = end + 1
    return structure


def slash_commands(value: str) -> list[str]:
    return [match.rstrip() for match in SLASH_COMMAND.findall(value)]


def wow_tokens(value: str) -> list[str]:
    tokens: list[str] = []
    for token in WOW_TOKEN.findall(value):
        color = re.match(r"\|c([0-9a-fA-F]{8})[^|]*\|r", token)
        tokens.append("|c" + color.group(1) + "|r" if color else token)
    return tokens


def runtime_lua_files() -> list[Path]:
    return [
        path
        for path in sorted(ADDON.rglob("*.lua"))
        if "Libs" not in path.parts and "tests" not in path.parts
    ]


def _long_bracket_end(source: str, start: int) -> int | None:
    match = re.match(r"\[(=*)\[", source[start:])
    if match is None:
        return None
    close = "]" + match.group(1) + "]"
    close_start = source.find(close, start + len(match.group(0)))
    return len(source) if close_start < 0 else close_start + len(close)


def _quoted_string_end(source: str, start: int) -> int:
    quote = source[start]
    index = start + 1
    while index < len(source):
        if source[index] == "\\":
            index += 2
        elif source[index] == quote:
            return index + 1
        else:
            index += 1
    return len(source)


def _masked_comment(source: str) -> str:
    return "".join(char if char in "\r\n" else " " for char in source)


def strip_lua_comments(source: str) -> str:
    output: list[str] = []
    index = 0
    while index < len(source):
        char = source[index]
        if char in "\"'":
            end = _quoted_string_end(source, index)
            output.append(source[index:end])
            index = end
            continue
        if char == "[":
            end = _long_bracket_end(source, index)
            if end is not None:
                output.append(source[index:end])
                index = end
                continue
        if source.startswith("--", index):
            end = _long_bracket_end(source, index + 2)
            if end is None:
                newline = source.find("\n", index + 2)
                end = len(source) if newline < 0 else newline
            output.append(_masked_comment(source[index:end]))
            index = end
            continue
        output.append(char)
        index += 1
    return "".join(output)


def _balanced_call_end(source: str, open_paren: int) -> int:
    depth = 1
    index = open_paren + 1
    while index < len(source):
        char = source[index]
        if char in "\"'":
            index = _quoted_string_end(source, index)
            continue
        if char == "[":
            end = _long_bracket_end(source, index)
            if end is not None:
                index = end
                continue
        if char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
            if depth == 0:
                return index
        index += 1
    raise AssertionError(f"unterminated call at offset {open_paren}")


def extract_balanced_calls(source: str, function_name: str) -> list[str]:
    calls: list[str] = []
    index = 0
    while index < len(source):
        char = source[index]
        if char in "\"'":
            index = _quoted_string_end(source, index)
            continue
        if char == "[":
            end = _long_bracket_end(source, index)
            if end is not None:
                index = end
                continue
        if source.startswith(function_name, index):
            before = source[index - 1] if index > 0 else ""
            after_name = index + len(function_name)
            after = source[after_name] if after_name < len(source) else ""
            if not (before.isalnum() or before == "_") and not (after.isalnum() or after == "_"):
                open_paren = after_name
                while open_paren < len(source) and source[open_paren].isspace():
                    open_paren += 1
                if open_paren < len(source) and source[open_paren] == "(":
                    close_paren = _balanced_call_end(source, open_paren)
                    calls.append(source[open_paren + 1 : close_paren])
                    index = close_paren + 1
                    continue
        index += 1
    return calls


def split_top_level_arguments(call: str) -> list[str]:
    arguments: list[str] = []
    start = 0
    paren_depth = 0
    bracket_depth = 0
    brace_depth = 0
    index = 0
    while index < len(call):
        char = call[index]
        if char in "\"'":
            index = _quoted_string_end(call, index)
            continue
        if char == "[":
            end = _long_bracket_end(call, index)
            if end is not None:
                index = end
                continue
            bracket_depth += 1
        elif char == "]":
            bracket_depth -= 1
        elif char == "(":
            paren_depth += 1
        elif char == ")":
            paren_depth -= 1
        elif char == "{":
            brace_depth += 1
        elif char == "}":
            brace_depth -= 1
        elif char == "," and paren_depth == bracket_depth == brace_depth == 0:
            arguments.append(call[start:index])
            start = index + 1
        index += 1
    arguments.append(call[start:])
    return arguments


DIAGNOSTIC_ASSERTION_KEY = re.compile(r"Diag\.A\.([A-Z][A-Za-z0-9_]*)")
DIRECT_DIAGNOSTIC_ASSERTION = re.compile(r"^\s*Diag\.A\.([A-Z][A-Za-z0-9_]*)\s*$")
FORMAT_CALL_START = re.compile(r"format\s*\(")


def diagnostic_assertion_key(expression: str) -> str | None:
    keys = DIAGNOSTIC_ASSERTION_KEY.findall(expression)
    if len(keys) != 1:
        return None
    direct = DIRECT_DIAGNOSTIC_ASSERTION.match(expression)
    if direct is not None:
        return direct.group(1)

    formatted = FORMAT_CALL_START.match(expression.strip())
    if formatted is None:
        return None
    open_paren = formatted.end() - 1
    try:
        close_paren = _balanced_call_end(expression.strip(), open_paren)
    except AssertionError:
        return None
    if close_paren != len(expression.strip()) - 1:
        return None

    arguments = split_top_level_arguments(expression.strip()[open_paren + 1 : close_paren])
    if len(arguments) < 2 or any(not argument.strip() for argument in arguments):
        return None
    first_argument = DIRECT_DIAGNOSTIC_ASSERTION.match(arguments[0])
    return first_argument.group(1) if first_argument is not None else None


def diagnostic_catalog_keys() -> set[str]:
    return set(
        re.findall(
            r"^Diag\.A\.([A-Z][A-Za-z0-9_]*)\s*=",
            DIAGNOSTICS.read_text(encoding="utf-8"),
            re.MULTILINE,
        )
    )


def registered_primary_commands(path: Path) -> list[str]:
    source = strip_lua_comments(path.read_text(encoding="utf-8"))
    alias_tables = {}
    for match in re.finditer(
        r"local\s+(?P<names>cmd[A-Za-z]+(?:\s*,\s*cmd[A-Za-z]+)*)\s*=\s*"
        r"(?P<values>(?:\s*\{[^}]*\}\s*,?)+)",
        source,
    ):
        names = re.findall(r"cmd[A-Za-z]+", match.group("names"))
        tables = re.findall(r"\{([^}]*)\}", match.group("values"))
        for name, table in zip(names, tables):
            alias_tables[name] = re.findall(r'"([a-z]+)"', table)
    registered_lists = re.findall(r"registerAliases\((cmd[A-Za-z]+),", source)
    commands = []
    for name in registered_lists:
        commands.extend(alias_tables[name])
    return commands


def readme_command_pattern(command: str) -> re.Pattern[str]:
    return re.compile(rf"`/rma {re.escape(command)}(?=[\s`])")


class LocalizationDiagnosticsContractTest(unittest.TestCase):
    def test_balanced_assert_parser_handles_runtime_call_shapes(self) -> None:
        source = r'''
-- assert(false, "ignored comment")
assert(
    ready and nested("escaped \\\"quote\\\", comma", inner(value)),
    string.format("failure (%s), detail", tostring(value))
)
assert(ready)
'''
        calls = extract_balanced_calls(strip_lua_comments(source), "assert")
        self.assertEqual(2, len(calls))
        self.assertEqual(2, len(split_top_level_arguments(calls[0])))
        self.assertEqual(1, len(split_top_level_arguments(calls[1])))

    def test_diagnostics_load_before_init(self) -> None:
        toc = TOC.read_text(encoding="utf-8")
        self.assertLess(toc.index(r"Localization\DiagnoseLog.en.lua"), toc.index("Init.lua"))

    def test_runtime_assert_messages_reference_diagnostic_catalog(self) -> None:
        offenders = []
        inspected_assertions = 0
        catalog_keys = diagnostic_catalog_keys()
        for path in runtime_lua_files():
            source = strip_lua_comments(path.read_text(encoding="utf-8"))
            for call in extract_balanced_calls(source, "assert"):
                inspected_assertions += 1
                args = split_top_level_arguments(call)
                if len(args) == 1:
                    continue
                elif len(args) == 2:
                    key = diagnostic_assertion_key(args[1])
                    if key is None or key not in catalog_keys:
                        offenders.append(f"{path.relative_to(ROOT)}: {args[1].strip()}")
                else:
                    offenders.append(f"{path.relative_to(ROOT)}: too many arguments")
        self.assertGreater(inspected_assertions, 0)
        self.assertEqual([], offenders)

    def test_diagnostic_assertions_allow_only_catalog_references_or_format_calls(self) -> None:
        self.assertEqual(
            "BootstrapMissingService",
            diagnostic_assertion_key("Diag.A.BootstrapMissingService"),
        )
        self.assertEqual(
            "BootstrapMissingService",
            diagnostic_assertion_key("format(Diag.A.BootstrapMissingService, tostring(name))"),
        )
        self.assertEqual(
            "BootstrapMissingService",
            diagnostic_assertion_key(
                'format(Diag.A.BootstrapMissingService, nested(value, tostring(name), "comma, paren"))'
            ),
        )
        for expression in (
            'Diag.A.BootstrapMissingService .. " suffix"',
            '"prefix " .. Diag.A.BootstrapMissingService',
            'format(Diag.A.BootstrapMissingService, tostring(name)) .. " suffix"',
            "format(Diag.A.BootstrapMissingService, value) or fallback()",
            "format(Diag.A.BootstrapMissingService, value) + extra()",
            "format(Diag.A.BootstrapMissingService)",
            "format(Diag.A.BootstrapMissingService, )",
            "Diag.A.BootstrapMissingService .. Diag.A.BootstrapMissingServiceMethod",
            "Diag.A.bootstrapMissingService",
        ):
            self.assertIsNone(diagnostic_assertion_key(expression), expression)

    def test_preloaded_assert_diagnostic_survives_init_bootstrap(self) -> None:
        lua = shutil.which("lua")
        self.assertIsNotNone(lua, "lua command is not available on PATH")
        script = r'''
local addon = {}
local function loadAddonFile(path)
    local chunk = assert(loadfile(path))
    chunk("Raid Management Addon", addon)
end

_G.GetTime = function() return 0 end
_G.GetRealmName = function() return "Test Realm" end
_G.UnitName = function() return "Tester", "Test Realm" end
_G.GetPartyLeaderIndex = function() return 0 end
_G.GetRaidRosterInfo = function() return nil, 0 end
_G.GetNumRaidMembers = function() return 0 end
_G.GetNumPartyMembers = function() return 0 end
_G.DEFAULT_CHAT_FRAME = { AddMessage = function() end }
_G.CreateFrame = function()
    return {
        RegisterEvent = function() end,
        UnregisterEvent = function() end,
        SetScript = function() end,
    }
end
_G.LibStub = function() return {} end

loadAddonFile("Raid Management Addon/Localization/DiagnoseLog.en.lua")
local expected = addon.Diag.A.BootstrapTimeApiNotInitialized
assert(expected == "RMA time API is not initialized")
loadAddonFile("Raid Management Addon/Init.lua")
assert(addon.Diag.A.BootstrapTimeApiNotInitialized == expected)
'''
        result = subprocess.run(
            [lua, "-"],
            cwd=ROOT,
            input=script,
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(0, result.returncode, result.stderr)


class LocalizationReadmeContractTest(unittest.TestCase):
    def test_packaged_readme_matches_repository_readme(self) -> None:
        self.assertEqual(ROOT_README.read_text(encoding="utf-8"), PACKAGED_README.read_text(encoding="utf-8"))

    def test_readme_documents_registered_command_families(self) -> None:
        readme = ROOT_README.read_text(encoding="utf-8")
        commands = registered_primary_commands(SLASH_EVENTS)
        self.assertTrue(commands, "no registered slash aliases were extracted")
        for command in commands:
            self.assertRegex(readme, readme_command_pattern(command), command)

    def test_readme_command_spans_reject_alias_prefixes(self) -> None:
        self.assertIsNone(readme_command_pattern("ver").search("`/rma version`"))
        self.assertIsNone(readme_command_pattern("warn").search("`/rma warning`"))
        self.assertIsNotNone(readme_command_pattern("version").search("`/rma version`"))
        self.assertIsNotNone(readme_command_pattern("warning").search("`/rma warning`"))

    def test_readme_documents_live_command_variants(self) -> None:
        readme = ROOT_README.read_text(encoding="utf-8")
        expected = (
            "`/rma perf on`",
            "`/rma perf off`",
            "`/rma perf threshold <ms>`",
            "`/rma perf th <ms>`",
            "`/rma perf ms <ms>`",
            "`/rma perf report`",
            "`/rma perf stats`",
            "`/rma perf top`",
            "`/rma perf audit`",
            "`/rma perf summary`",
            "`/rma perf items`",
            "`/rma perf item`",
            "`/rma perf tooltip`",
            "`/rma perf reset`",
            "`/rma perf clear`",
            "`/rma perf status`",
            "`/rma validate raids verbose`",
            "`/rma validate raids all`",
            "`/rma debug raid seed`",
            "`/rma debug raid add`",
            "`/rma debug raid clear`",
            "`/rma debug raid reset`",
            "`/rma debug raid rolls [tie]`",
            "`/rma debug raid all [tie]`",
            "`/rma debug raid roll <1-4|name> [1-100]`",
            "`/rma debug raidgrid [1-40]`",
            "`/rma debug timers [reset]`",
            "`/rma lfm toggle`",
            "`/rma lfm show`",
            "`/rma lfm start`",
            "`/rma lfm stop`",
            "`/rma minimap pos`",
            "`/rma minimap pos <deg>`",
        )
        for command in expected:
            self.assertIn(command, readme, command)


class LocalizationContractTest(unittest.TestCase):
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

    def test_raid_archive_quarantine_messages_are_localized_and_data_safe(self) -> None:
        catalogs = {"enUS": ENGLISH, **LOCALES}
        for locale, path in catalogs.items():
            translated = scalar_assignments(path)
            self.assertTrue(QUARANTINE_KEYS.issubset(translated), locale)
            warning = unquoted(translated["MsgRaidHistoryQuarantined"])
            self.assertEqual(["%s", "%s"], placeholders(translated["MsgRaidHistoryQuarantined"]), locale)
            self.assertIn("RMA_Raids", warning, locale)
            self.assertIn("/reload", warning, locale)
            for forbidden_key in (
                "RMA_Players",
                "RMA_Reserves",
                "RMA_Warnings",
                "RMA_Spammer",
                "RMA_Options",
            ):
                self.assertNotIn(forbidden_key, warning, f"{locale}:{forbidden_key}")

    def test_unknown_raid_warning_is_localized_and_non_technical(self) -> None:
        catalogs = {"enUS": ENGLISH, **LOCALES}
        for locale, path in catalogs.items():
            translated = scalar_assignments(path)
            self.assertIn(UNKNOWN_RAID_WARNING_KEY, translated, locale)
            warning = unquoted(translated[UNKNOWN_RAID_WARNING_KEY])
            self.assertEqual([], placeholders(translated[UNKNOWN_RAID_WARNING_KEY]), locale)
            for technical_token in ("mapId", "difficulty", "instanceName"):
                self.assertNotIn(technical_token, warning, f"{locale}:{technical_token}")

    def test_locale_catalogs_only_contain_scalar_translations(self) -> None:
        for path in LOCALES.values():
            source = path.read_text(encoding="utf-8")
            self.assertNotIn("L.RaidZones", source)
            self.assertNotIn("L.BossYells", source)
            lua_syntax = re.sub(r'"(?:\\.|[^"\\])*"', '""', source)
            self.assertTrue(lua_syntax.isascii(), path.name)

    def test_documented_command_tokens_remain_untranslated(self) -> None:
        english = scalar_assignments(ENGLISH)
        for locale, path in LOCALES.items():
            translated = scalar_assignments(path)
            for key, value in english.items():
                english_value = unquoted(value)
                if any(token in english_value for token in COMMAND_TOKENS):
                    for token in COMMAND_TOKENS:
                        if token in english_value:
                            self.assertIn(token, unquoted(translated[key]), f"{locale}:{key}:{token}")

    def test_embedded_parser_help_forms_remain_exact(self) -> None:
        for locale, path in LOCALES.items():
            translated = scalar_assignments(path)
            for key, form in PARSER_HELP_FORMS.items():
                self.assertIn(form, unquoted(translated[key]), f"{locale}:{key}:{form}")

    def test_machine_help_and_diagnostic_identifiers_remain_exact(self) -> None:
        english = assignment_values(ENGLISH)
        for locale, path in LOCALES.items():
            translated = assignment_values(path)
            for key, forms in MACHINE_HELP_FORMS.items():
                for form in forms:
                    self.assertIn(form, translated[key], f"{locale}:{key}:{form}")
            for key, value in english.items():
                if not key.startswith("MsgValidateDetail"):
                    continue
                self.assertEqual(
                    DIAGNOSTIC_IDENTIFIER.findall(value),
                    DIAGNOSTIC_IDENTIFIER.findall(translated[key]),
                    f"{locale}:{key}",
                )

    def test_glossary_labels_keep_their_ui_or_gameplay_meaning(self) -> None:
        for locale, expected in GLOSSARY_VALUES.items():
            translated = scalar_assignments(LOCALES[locale])
            for key, value in expected.items():
                self.assertEqual(value, unquoted(translated[key]), f"{locale}:{key}")

    def test_catalogs_reject_keyed_dictionary_false_friends(self) -> None:
        for locale, keyed_fragments in KEYED_FALSE_FRIENDS.items():
            translated = assignment_values(LOCALES[locale])
            for key, fragments in keyed_fragments.items():
                value = translated[key].casefold()
                for fragment in fragments:
                    self.assertNotIn(fragment.casefold(), value, f"{locale}:{key}:{fragment}")

    def test_locale_gates_run_before_any_localization_assignment(self) -> None:
        for locale, path in LOCALES.items():
            source = path.read_text(encoding="utf-8")
            gate = source.index(f'GetLocale() ~= "{locale}"')
            first_assignment = re.search(r"^L\.[A-Za-z]", source, re.MULTILINE)
            self.assertIsNotNone(first_assignment)
            self.assertLess(gate, first_assignment.start(), locale)

    def test_translations_preserve_lua_newline_escape_structure(self) -> None:
        english = assignment_values(ENGLISH)
        for locale, path in LOCALES.items():
            translated = assignment_values(path)
            for key, value in english.items():
                if not newline_escape_structure(value):
                    continue
                self.assertEqual(
                    newline_escape_structure(value),
                    newline_escape_structure(translated[key]),
                    f"{locale}:{key}",
                )

    def test_command_help_separates_aliases_from_version_help(self) -> None:
        catalogs = {"enUS": ENGLISH, **LOCALES}
        for locale, path in catalogs.items():
            value = assignment_values(path)["StrConfigHelpCommandsBody"]
            self.assertIn("bug/report.\\n/rma version", value, locale)

    def test_command_syntax_and_wow_tokens_remain_ordered(self) -> None:
        english = assignment_values(ENGLISH)
        for locale, path in LOCALES.items():
            translated = assignment_values(path)
            for key, value in english.items():
                if not (
                    slash_commands(value)
                    or wow_tokens(value)
                    or "Aliases: " in value
                ):
                    continue
                self.assertEqual(
                    slash_commands(value),
                    slash_commands(translated[key]),
                    f"{locale}:command:{key}",
                )
                self.assertEqual(
                    wow_tokens(value),
                    wow_tokens(translated[key]),
                    f"{locale}:wow-token:{key}",
                )
                if "Aliases: " in value:
                    aliases = (
                        "config/conf/options/opt; lfm/pug/group/grouper; "
                        "warnings/warning/warn/rw; reserves/res/reserve/sr/softres; "
                        "debug/dbg/debugger; minimap/mm; version/ver/about; bug/report."
                    )
                    self.assertIn(aliases, translated[key], f"{locale}:aliases:{key}")

    def test_rma_branding_and_russian_translation_coverage(self) -> None:
        english = scalar_assignments(ENGLISH)
        same_values = 0
        for locale, path in LOCALES.items():
            translated = scalar_assignments(path)
            for key, value in english.items():
                english_value = unquoted(value)
                translated_value = unquoted(translated[key])
                if "RMA" in english_value:
                    self.assertEqual(
                        english_value.count("RMA"),
                        translated_value.count("RMA"),
                        f"{locale}:{key}",
                    )
                if locale == "ruRU" and english_value == translated_value and re.search(r"[A-Za-z]{3}", english_value):
                    same_values += 1
        self.assertLess(same_values, 80)

    def test_audited_visible_fallbacks_use_localization_keys(self) -> None:
        checks = {
            ADDON / "Controllers" / "Config.lua": (
                'or "Winner announce: %s"',
                'or "Hold announce: %s"',
                'or "Bank announce: %s"',
                'or "Disenchant announce: %s"',
                'or "Countdown: %s sec, %s"',
            ),
            ADDON / "Controllers" / "Master.lua": ('or "Give %s to %s?"',),
            ADDON / "Controllers" / "Logger.lua": ('or "Shared"', 'or "Possible sources:"'),
            ADDON / "Services" / "Raid" / "LootMethod.lua": (
                'or "Boss targeted, auto switch to Master Loot."',
                'or "RMA: Loot method set to Master Loot for %s."',
                'or "Unknown"',
                'or "RMA: Loot method set to Group Loot."',
            ),
            ADDON / "Services" / "Master" / "Messages.lua": (
                'or "%d. %s by %s"',
                'or "Item reserved:"',
            ),
            ADDON / "Services" / "Reserves" / "Chat.lua": ('or "[Item %s]"',),
        }
        for path, literals in checks.items():
            source = path.read_text(encoding="utf-8")
            for literal in literals:
                self.assertNotIn(literal, source, f"{path.name}:{literal}")

    def test_runtime_has_no_english_localization_fallbacks(self) -> None:
        for path in ADDON.rglob("*.lua"):
            if "Libs" in path.parts:
                continue
            matches = LOCALIZATION_FALLBACK.findall(path.read_text(encoding="utf-8"))
            self.assertEqual([], matches, path.relative_to(ADDON))


if __name__ == "__main__":
    unittest.main()
