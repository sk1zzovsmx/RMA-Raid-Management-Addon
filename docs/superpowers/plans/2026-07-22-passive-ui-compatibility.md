# Passive UI Compatibility Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make RMA present itself as ordinary Blizzard-native FrameXML so custom UI suites can skin it through their existing generic or Blizzard hooks, while retaining a correct native 3.3.5a fallback and never detecting a UI suite.

**Architecture:** Shared RMA chrome becomes a thin specialization of Blizzard templates (`UIPanelDialogTemplate` and `UIPanelButtonTemplate`). RMA retains only structural layout and semantic state such as selected/focused rows. Logger-specific backdrop, header, zebra-striping, and border painting are removed so they cannot overwrite a skin applied by another addon.

**Tech Stack:** WoW WotLK 3.3.5a FrameXML, Lua 5.1, Python `unittest` contract tests, repository WotLK validators.

## Global Constraints

- Do not detect ElvUI, Tukui, or any other UI addon.
- Do not add LibSharedMedia, AceGUI, Ace2, Ace3, callbacks, adapters, or a theme setting.
- Do not modify vendored libraries, SavedVariables, addon-message formats, TOC order, slash commands, or feature behavior.
- XML remains layout-only: no `<Scripts>` or `<On...>` handlers.
- Preserve all named frame/template identities used by Lua.
- Preserve semantic visuals: selection, focus, disabled state, class/quality colors, item icons, QuickBar alerts, and other state-bearing effects.
- Treat in-client validation as manual acceptance; static/offline gates determine implementation readiness.

---

### Task 1: Delegate shared dialog and action-button chrome to Blizzard

**Files:**

- Create: `tests/test_passive_ui_compatibility_contract.py`
- Modify: `Raid Management Addon/UI/Templates/Common.xml:4-118`

**Interfaces:**

- Keep `RMAWindowTemplate`, `RMADialogTemplate`, and `RMAActionButtonTemplate` names unchanged.
- `RMADialogTemplate` must inherit `UIPanelDialogTemplate`.
- `RMAActionButtonTemplate` must inherit `UIPanelButtonTemplate`.
- Do not add a Lua API or runtime dependency.

- [ ] **Step 1: Add the failing shared-template contract tests**

Create `tests/test_passive_ui_compatibility_contract.py` with:

```python
from __future__ import annotations

from pathlib import Path
import unittest
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[1]
ADDON = ROOT / "Raid Management Addon"
COMMON_XML = ADDON / "UI" / "Templates" / "Common.xml"


def find_named(path: Path, name: str) -> ET.Element:
    root = ET.parse(path).getroot()
    for node in root.iter():
        if node.attrib.get("name") == name:
            return node
    raise AssertionError(f"{name} is missing from {path}")


def local_tags(node: ET.Element) -> set[str]:
    return {child.tag.rsplit("}", 1)[-1] for child in node.iter()}


class PassiveUiCompatibilityContractTest(unittest.TestCase):
    def test_shared_chrome_inherits_blizzard_templates(self) -> None:
        self.assertEqual(
            "UIPanelDialogTemplate",
            find_named(COMMON_XML, "RMAWindowTemplate").attrib.get("inherits"),
        )
        self.assertEqual(
            "UIPanelDialogTemplate",
            find_named(COMMON_XML, "RMADialogTemplate").attrib.get("inherits"),
        )
        self.assertEqual(
            "UIPanelButtonTemplate",
            find_named(COMMON_XML, "RMAActionButtonTemplate").attrib.get("inherits"),
        )

    def test_shared_specializations_do_not_redeclare_blizzard_chrome(self) -> None:
        dialog_tags = local_tags(find_named(COMMON_XML, "RMADialogTemplate"))
        self.assertNotIn("Backdrop", dialog_tags)

        action_tags = local_tags(find_named(COMMON_XML, "RMAActionButtonTemplate"))
        forbidden = {
            "Layers",
            "NormalTexture",
            "PushedTexture",
            "DisabledTexture",
            "HighlightTexture",
        }
        self.assertFalse(forbidden.intersection(action_tags))


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Prove the new tests fail against the current hand-painted templates**

Run:

```powershell
py -3 -m unittest tests.test_passive_ui_compatibility_contract -v
```

Expected: failures report that `RMADialogTemplate` and `RMAActionButtonTemplate` lack the required inheritance and still declare their own chrome.

- [ ] **Step 3: Replace only the shared decorative template definitions**

In `Common.xml`, keep `RMAWindowTemplate` as-is. Replace the complete `RMADialogTemplate` and `RMAActionButtonTemplate` definitions with:

```xml
	<!-- Compact dialog template: native chrome remains available to UI skin suites. -->
	<Frame name="RMADialogTemplate" inherits="UIPanelDialogTemplate" parent="UIParent" movable="true" enableMouse="true" hidden="true" clampedToScreen="true" virtual="true">
		<Size>
			<AbsDimension x="230" y="385" />
		</Size>
		<Anchors>
			<Anchor point="CENTER" />
		</Anchors>
	</Frame>
	<!-- Standard action button: size is RMA-owned; chrome is Blizzard-owned. -->
	<Button name="RMAActionButtonTemplate" inherits="UIPanelButtonTemplate" virtual="true">
		<Size>
			<AbsDimension x="25" y="25" />
		</Size>
	</Button>
```

Do not alter `RMASelectableRowButtonTemplate`, `RMARaidGridButtonTemplate`, item icons, or effects in this task: those visuals encode selection, class/status, item, or alert state rather than generic window/button chrome.

- [ ] **Step 4: Run the focused contract and existing quick-bar contract**

Run:

```powershell
py -3 -m unittest tests.test_passive_ui_compatibility_contract tests.test_quick_bar_contract -v
```

Expected: all tests pass. This also proves dynamically/indirectly reused `RMAActionButtonTemplate` retains its public name.

- [ ] **Step 5: Commit the shared-template change**

```powershell
git add -- "Raid Management Addon/UI/Templates/Common.xml" "tests/test_passive_ui_compatibility_contract.py"
git commit -m "refactor(ui): delegate shared chrome to Blizzard"
```

---

### Task 2: Remove logger chrome overrides while preserving semantic row state

**Files:**

- Modify: `tests/test_passive_ui_compatibility_contract.py`
- Modify: `Raid Management Addon/UI/Templates/Common.xml:290-327`
- Modify: `Raid Management Addon/UI/Logger.xml:3-141,142-207`
- Modify: `Raid Management Addon/UI/LootHistory.xml:3-63`
- Modify: `Raid Management Addon/UI/RaidAttendance.xml:20-80`
- Modify: `Raid Management Addon/UI/Warnings.xml:3-36`
- Modify: `Raid Management Addon/Modules/UI/Visuals.lua:9-147,367-435`
- Modify: `Raid Management Addon/Controllers/Logger.lua:1244-1255,1659-1671`
- Modify: `Raid Management Addon/Controllers/Attendance.lua:623-632,1194-1210`
- Modify: `tests/lua/harness/30_raid_runtime.lua:876`
- Modify: `tests/lua/harness/70_raid_sync.lua:6443`

**Interfaces:**

- Keep `RMALogPanelTemplate`, `RMALogTableHeaderTemplate`, and every concrete XML frame name unchanged.
- Keep `Rows.StyleLoggerRow(row)` as the sole logger-row semantic marker.
- Remove private/public presentation helpers `Rows.SetLoggerRowIndex`, `Rows.StyleLoggerPanel`, and `Rows.ApplyLoggerSkin` together with all callers.
- No persisted or wire contract changes.

- [ ] **Step 1: Extend the contract tests to describe non-interference**

Add these constants below `COMMON_XML`:

```python
LOGGER_XML = ADDON / "UI" / "Logger.xml"
LOOT_HISTORY_XML = ADDON / "UI" / "LootHistory.xml"
ATTENDANCE_XML = ADDON / "UI" / "RaidAttendance.xml"
WARNINGS_XML = ADDON / "UI" / "Warnings.xml"
VISUALS_LUA = ADDON / "Modules" / "UI" / "Visuals.lua"
LOGGER_LUA = ADDON / "Controllers" / "Logger.lua"
ATTENDANCE_LUA = ADDON / "Controllers" / "Attendance.lua"


def source(path: Path) -> str:
    return path.read_text(encoding="utf-8")
```

Add these methods to `PassiveUiCompatibilityContractTest`:

```python
    def test_logger_panel_and_header_use_blizzard_chrome(self) -> None:
        self.assertEqual(
            "UIPanelDialogTemplate",
            find_named(LOGGER_XML, "RMALogPanelTemplate").attrib.get("inherits"),
        )
        self.assertEqual(
            "UIPanelButtonTemplate",
            find_named(LOGGER_XML, "RMALogTableHeaderTemplate").attrib.get("inherits"),
        )
        self.assertNotIn("Backdrop", local_tags(find_named(LOGGER_XML, "RMALogPanelTemplate")))
        self.assertNotIn("Layers", local_tags(find_named(LOGGER_XML, "RMALogTableHeaderTemplate")))

    def test_list_rows_do_not_paint_decorative_backgrounds(self) -> None:
        row_xml = "\n".join(
            source(path)
            for path in (
                COMMON_XML,
                LOGGER_XML,
                LOOT_HISTORY_XML,
                ATTENDANCE_XML,
                WARNINGS_XML,
            )
        )
        self.assertNotIn("UI-AuctionItemNameFrame", row_xml)
        self.assertNotIn("LoggerBg", row_xml)
        self.assertNotIn("LoggerBottomLine", row_xml)

    def test_logger_runtime_keeps_only_semantic_row_style(self) -> None:
        visuals = source(VISUALS_LUA)
        self.assertIn("function Rows.StyleLoggerRow(row)", visuals)
        self.assertIn('row._RMARowVisualStyle = "logger"', visuals)
        self.assertNotIn("function Rows.SetLoggerRowIndex", visuals)
        self.assertNotIn("function Rows.StyleLoggerPanel", visuals)
        self.assertNotIn("function Rows.ApplyLoggerSkin", visuals)
        self.assertNotIn("_RMALoggerBg", visuals)
        self.assertNotIn("_RMALoggerLine", visuals)

    def test_refresh_paths_only_mark_logger_row_semantics(self) -> None:
        controllers = source(LOGGER_LUA) + source(ATTENDANCE_LUA)
        self.assertIn("Rows.StyleLoggerRow(row)", controllers)
        self.assertNotIn("Rows.SetLoggerRowIndex", controllers)
        self.assertNotIn("Rows.ApplyLoggerSkin", controllers)

    def test_runtime_has_no_custom_ui_adapter_dependency(self) -> None:
        runtime = []
        for path in ADDON.rglob("*"):
            if path.is_file() and path.suffix.lower() in {".lua", ".xml", ".toc"}:
                if "Libs" not in path.relative_to(ADDON).parts:
                    runtime.append(source(path))
        combined = "\n".join(runtime)
        for forbidden in ("ElvUI", "Tukui", "AceGUI", "LibSharedMedia"):
            self.assertNotIn(forbidden, combined)
```

- [ ] **Step 2: Prove the non-interference tests fail first**

Run:

```powershell
py -3 -m unittest tests.test_passive_ui_compatibility_contract -v
```

Expected: the new logger-template, row-decoration, and runtime-helper assertions fail; the no-adapter assertion already passes.

- [ ] **Step 3: Convert logger panels and headers to native specializations**

Replace the two virtual templates at the top of `UI/Logger.xml` with:

```xml
	<Frame name="RMALogPanelTemplate" inherits="UIPanelDialogTemplate" virtual="true" />

	<Button name="RMALogTableHeaderTemplate" inherits="UIPanelButtonTemplate" virtual="true">
		<Size>
			<AbsDimension x="10" y="19" />
		</Size>
	</Button>
```

This intentionally accepts Blizzard's native centered header label and button states. Individual header anchors and widths remain structural and unchanged.

- [ ] **Step 4: Remove only decorative row textures from XML**

Delete the complete texture nodes identified by the following attributes, including empty `<Layer>` containers left behind:

```text
Common.xml:        file="Interface\AuctionFrame\UI-AuctionItemNameFrame"
Logger.xml:        file="Interface\AuctionFrame\UI-AuctionItemNameFrame"
                   name="$parentLoggerBg"
                   name="$parentLoggerBottomLine"
LootHistory.xml:   file="Interface\AuctionFrame\UI-AuctionItemNameFrame"
                   name="$parentLoggerBg"
                   name="$parentLoggerBottomLine"
RaidAttendance.xml:file="Interface\AuctionFrame\UI-AuctionItemNameFrame"
                   name="$parentLoggerBg"
                   name="$parentLoggerBottomLine"
Warnings.xml:      file="Interface\AuctionFrame\UI-AuctionItemNameFrame"
```

Keep all `ARTWORK` content and the selected/focus textures inherited from `RMASelectableRowButtonTemplate`. Do not rename row templates or concrete frames.

- [ ] **Step 5: Reduce logger runtime styling to a semantic marker**

In `Modules/UI/Visuals.lua`:

1. Change the local aliases to:

```lua
local tostring, type = tostring, type
```

2. Delete `LOGGER_HEADER_TAB_INSET`, `loggerHeaderSuffixes`, `resolveLoggerHeaderTab`, and `styleLoggerHeader`.
3. Replace the existing logger-row/panel functions with only:

```lua
function Rows.StyleLoggerRow(row)
	if not row then
		return
	end

	row._RMARowVisualStyle = "logger"
end
```

Retain `isLoggerRow`: `Rows.SetSelected` and `Rows.SetFocused` use it to preserve logger-specific semantic selection/focus colors. Retain `setTextureColor`, which is still used by other semantic effects.

- [ ] **Step 6: Update controllers and Lua harnesses to the smaller interface**

Make these exact caller changes:

```lua
-- Controllers/Logger.lua: remove from BindHandlers
Rows.ApplyLoggerSkin(module._loggerPanelNames)

-- Controllers/Logger.lua: inside cfg.drawRow wrapper
Rows.StyleLoggerRow(row)

-- Controllers/Attendance.lua: inside cfg.drawRow wrapper
Rows.StyleLoggerRow(row)

-- Controllers/Attendance.lua: remove from bindRaidAttendanceFrame
Rows.ApplyLoggerSkin({
	"RMARaidAttendanceRaids",
	"RMARaidAttendanceRaidAttendees",
})
```

In both harness tables replace:

```lua
SetLoggerRowIndex = noop,
ApplyLoggerSkin = noop,
```

with:

```lua
StyleLoggerRow = noop,
```

If either harness currently places the two removed keys on one line, replace that exact pair; do not reformat unrelated harness code.

- [ ] **Step 7: Run focused behavior and XML contracts**

Run:

```powershell
py -3 -m unittest tests.test_passive_ui_compatibility_contract tests.test_quick_bar_contract tests.test_config_xml_contract tests.test_ui_frames_contract -v
```

Expected: all focused tests pass.

- [ ] **Step 8: Run the repository static gate**

Run:

```powershell
py -3 -m unittest discover -s tests -p "test_*.py" -v
py -3 .agents\skills\wow-addon-dev-wotlk-v335a\scripts\validate_toc.py "Raid Management Addon\Raid Management Addon.toc"
py -3 .agents\skills\wow-addon-dev-wotlk-v335a\scripts\lint_lua51.py "Raid Management Addon"
py -3 .agents\skills\wow-addon-dev-wotlk-v335a\scripts\scan_xpcall.py "Raid Management Addon"
rg -n "<Scripts>|<On[A-Za-z]+>" "Raid Management Addon\UI" -g "*.xml"
luacheck "Raid Management Addon" --exclude-files "Raid Management Addon/Libs/**"
stylua --check "Raid Management Addon/Modules/UI/Visuals.lua" "Raid Management Addon/Controllers/Logger.lua" "Raid Management Addon/Controllers/Attendance.lua"
git diff --check
git status --short --branch
```

Expected:

- Unit tests, TOC validation, Lua 5.1 validation, xpcall scan, luacheck, and `git diff --check` pass.
- The XML handler `rg` exits `1` with no output, meaning no handlers were found.
- Record `stylua --check` honestly. The repository has a known line-ending/whole-file formatting baseline; do not bulk-format unrelated code to force a clean result.

- [ ] **Step 9: Commit the non-interference cleanup**

```powershell
git add -- "Raid Management Addon/UI/Templates/Common.xml" "Raid Management Addon/UI/Logger.xml" "Raid Management Addon/UI/LootHistory.xml" "Raid Management Addon/UI/RaidAttendance.xml" "Raid Management Addon/UI/Warnings.xml" "Raid Management Addon/Modules/UI/Visuals.lua" "Raid Management Addon/Controllers/Logger.lua" "Raid Management Addon/Controllers/Attendance.lua" "tests/lua/harness/30_raid_runtime.lua" "tests/lua/harness/70_raid_sync.lua" "tests/test_passive_ui_compatibility_contract.py"
git commit -m "refactor(ui): stop overriding external skins"
```

- [ ] **Step 10: Report manual runtime acceptance without overstating it**

Unless an actual 3.3.5a client was used, report:

```text
runtime smoke: not run; manual acceptance pending
```

Manual comparison checklist:

1. Vanilla UI: `/rma`, `/rma history`, `/rma attendance`, warnings, and QuickBar open without Lua/XML errors; dialogs and buttons use Blizzard-native chrome.
2. ElvUI 6.09 enabled: the same surfaces remain functional; any skin applied by ElvUI or AddOnSkins is not overwritten by RMA after load or refresh.
3. Toggle selections/focus in logger, loot history, attendance, and warnings: semantic state remains visible.
4. Create dynamic Loot Counter controls: buttons use the same `RMAActionButtonTemplate` path as static controls.
5. `/reload`: no behavior or `RMA_*` persistence regression.

## Completion Criteria

- RMA contains no custom-UI detection, adapter, or media dependency.
- Shared dialogs, panels, action buttons, and table headers inherit Blizzard-native templates.
- RMA does not repaint logger panel/header/row chrome at runtime.
- Semantic selection/focus and feature-state visuals remain intact.
- Static gates pass or any pre-existing formatter baseline is reported precisely.
- Manual runtime smoke is either evidenced or explicitly left pending.
