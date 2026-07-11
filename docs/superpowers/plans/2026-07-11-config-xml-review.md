# Config XML Review Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reduce duplicated geometry in `UI/Config.xml`, preserve its complete named-frame contract, and make the existing Lua layout owner safely preserve dialog sizing and text alignment.

**Architecture:** Keep `RMAConfig`, all public panel shells, named child controls, templates, top-level sizes, and structural scroll hierarchy in XML. Use the existing `addon.UI.Layout` API and `Controllers/Config.lua` row descriptions for repeated Interface Options and cleanup-popup geometry; do not introduce another module or a generic UI factory.

**Tech Stack:** WoW 3.3.5a FrameXML, Interface 30300, Lua 5.1, Python 3 `unittest`, repository WotLK validators.

## Global Constraints

- This is an incremental UI refactor, not `GREENFIELD_REWRITE`.
- Keep addon name `Raid Management Addon`, runtime short name `RMA`, `/rma`, `RMA_*` SavedVariables, RMA addon-message prefixes, and user-facing RMA branding unchanged.
- Runtime code must remain compatible with WotLK 3.3.5a, Interface `30300`, and Lua 5.1.
- XML remains layout-only; add no `<Scripts>` blocks or `<On...>` handlers.
- Keep all existing XML `name` values in their current order.
- Keep the compact `RMAConfig` window's static geometry in XML; it is not part of the Interface Options row-layout reduction.
- Keep top-level panel sizes, panel/scroll-child hierarchy, XML templates, and cleanup-popup shell in XML.
- Add no Ace2/Ace3 dependency, Retail/Classic-only API, SavedVariables migration, wire-format change, generic helper module, pass-through wrapper, or TOC entry.
- Real-client smoke is manual acceptance and is reported honestly when not run.

---

### Task 1: Add the Config XML characterization contract

**Files:**
- Create: `tests/test_config_xml_contract.py`
- Read: `Raid Management Addon/UI/Config.xml`

**Interfaces:**
- Consumes: the tracked Config XML document.
- Produces: a stable ordered-name digest and structural assertions used by all later tasks.

- [ ] **Step 1: Create the characterization test**

Create `tests/test_config_xml_contract.py` with this complete content:

```python
from __future__ import annotations

import hashlib
from pathlib import Path
import re
import unittest
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[1]
CONFIG_XML = ROOT / "Raid Management Addon" / "UI" / "Config.xml"
EXPECTED_ORDERED_NAMES_SHA256 = (
    "53f86d9fa781ade75839a4d895840fd1013970add79c98a1bad9ef471fd8528d"
)
REQUIRED_PUBLIC_FRAMES = {
    "RMAConfig",
    "RMAInterfaceOptionsPanel",
    "RMAInterfaceOptionsMasterLootPanel",
    "RMAInterfaceOptionsMasterLootPanelScrollChild",
    "RMAInterfaceOptionsLootHistoryPanel",
    "RMAInterfaceOptionsLootHistoryPanelScrollChild",
    "RMAInterfaceOptionsLFMSpamPanel",
    "RMAInterfaceOptionsLFMSpamPanelScrollChild",
    "RMAInterfaceOptionsRaidWarningPanel",
    "RMAInterfaceOptionsRaidWarningPanelScrollChild",
    "RMAInterfaceOptionsHelpPanel",
    "RMAInterfaceOptionsHelpPanelScrollChild",
    "RMALootHistoryCleanupPopup",
}


def source() -> str:
    return CONFIG_XML.read_text(encoding="utf-8")


class ConfigXmlContractTest(unittest.TestCase):
    def test_xml_parses(self) -> None:
        ET.parse(CONFIG_XML)

    def test_ordered_name_contract_is_unchanged(self) -> None:
        names = re.findall(r'\bname="([^"]+)"', source())
        digest = hashlib.sha256("\n".join(names).encode("utf-8")).hexdigest()
        self.assertEqual(235, len(names))
        self.assertEqual(EXPECTED_ORDERED_NAMES_SHA256, digest)

    def test_required_public_frames_remain_declared(self) -> None:
        names = set(re.findall(r'\bname="([^"]+)"', source()))
        self.assertTrue(REQUIRED_PUBLIC_FRAMES.issubset(names))

    def test_xml_remains_layout_only(self) -> None:
        xml = source()
        self.assertNotRegex(xml, r"<Scripts>|<On[A-Za-z]+>")


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run the characterization test**

Run:

```powershell
py -3 -m unittest tests.test_config_xml_contract -v
```

Expected: four tests pass against the untouched XML.

- [ ] **Step 3: Force-add the ignored test and commit the characterization**

Run:

```powershell
git add -f -- tests/test_config_xml_contract.py
git diff --cached --check
git commit -m "test(ui): Characterize Config XML contract"
```

Expected: one commit containing only `tests/test_config_xml_contract.py`.

---

### Task 2: Make OptionsLayout preserve explicit visual intent

**Files:**
- Modify: `tests/test_config_xml_contract.py`
- Modify: `Raid Management Addon/Modules/UI/OptionsLayout.lua`
- Modify: `Raid Management Addon/Controllers/Config.lua`

**Interfaces:**
- Consumes: `Layout.ApplyRows(frameOrName, rows, cfg)` and existing row tables.
- Produces: optional `row.justifyH`, optional `row.justifyV`, and optional `cfg.preserveFrameSize`; defaults remain `LEFT`, `TOP`, and resize enabled.

- [ ] **Step 1: Write failing source-contract tests**

Add these constants and methods to `tests/test_config_xml_contract.py`:

```python
LAYOUT_LUA = ROOT / "Raid Management Addon" / "Modules" / "UI" / "OptionsLayout.lua"
CONTROLLER_LUA = ROOT / "Raid Management Addon" / "Controllers" / "Config.lua"


class ConfigLayoutOwnershipTest(unittest.TestCase):
    def test_layout_supports_explicit_justification(self) -> None:
        lua = LAYOUT_LUA.read_text(encoding="utf-8")
        self.assertIn("justifyH or \"LEFT\"", lua)
        self.assertIn("justifyV or \"TOP\"", lua)

    def test_layout_can_preserve_xml_owned_frame_size(self) -> None:
        lua = LAYOUT_LUA.read_text(encoding="utf-8")
        self.assertIn("if not (cfg and cfg.preserveFrameSize) then", lua)

    def test_cleanup_popup_selects_preserved_size_and_centered_title(self) -> None:
        lua = CONTROLLER_LUA.read_text(encoding="utf-8")
        self.assertRegex(
            lua,
            r'type = "title"[\s\S]{0,200}?suffix = "Title"[\s\S]{0,200}?justifyH = "CENTER"',
        )
        self.assertIn("preserveFrameSize = true", lua)
```

- [ ] **Step 2: Run the focused tests and verify failure**

Run:

```powershell
py -3 -m unittest tests.test_config_xml_contract.ConfigLayoutOwnershipTest -v
```

Expected: three failures because the optional contracts do not exist yet.

- [ ] **Step 3: Extend `placeText` without changing defaults**

Change the private helper in `OptionsLayout.lua` to:

```lua
local function placeText(parent, widget, x, y, width, height, justifyH, justifyV)
	if place(parent, widget, x, y, width, height) then
		if widget.SetJustifyH then
			widget:SetJustifyH(justifyH or "LEFT")
		end
		if widget.SetJustifyV then
			widget:SetJustifyV(justifyV or "TOP")
		end
	end
end
```

In the `title`, `section`, and `body` branches of `applyRow`, append `row.justifyH, row.justifyV` to each `placeText(...)` call. Do not broaden this option to other row types until a real caller needs it.

- [ ] **Step 4: Add opt-in frame-size preservation**

Replace the unconditional final resize in `Layout.ApplyRows`:

```lua
	setSize(frame, getCfg(cfg, "scrollChildWidth"), height)
```

with:

```lua
	if not (cfg and cfg.preserveFrameSize) then
		setSize(frame, getCfg(cfg, "scrollChildWidth"), height)
	end
```

The returned calculated height remains unchanged.

- [ ] **Step 5: Select the new options only for the cleanup popup**

In `layoutCleanupPopup()` change its title row to:

```lua
			{
				type = "title",
				suffix = "Title",
				leftX = 20,
				width = 340,
				height = 20,
				justifyH = "CENTER",
				gap = 10,
			},
```

Add this field to the popup's final configuration table:

```lua
			preserveFrameSize = true,
```

- [ ] **Step 6: Run focused and Lua compatibility checks**

Run:

```powershell
py -3 -m unittest tests.test_config_xml_contract -v
py -3 .agents\skills\wow-addon-dev-wotlk-v335a\scripts\lint_lua51.py "Raid Management Addon"
git diff --check
```

Expected: seven unit tests pass, Lua 5.1 lint passes, and `git diff --check` exits 0.

- [ ] **Step 7: Commit the reusable layout contract**

Run:

```powershell
git add -f -- tests/test_config_xml_contract.py
git add -- "Raid Management Addon/Modules/UI/OptionsLayout.lua" "Raid Management Addon/Controllers/Config.lua"
git diff --cached --check
git commit -m "refactor(ui): Preserve explicit Config layout intent"
```

Expected: one commit containing the test, layout helper, and Config caller changes.

---

### Task 3: Reduce Interface Options XML geometry

**Files:**
- Modify: `tests/test_config_xml_contract.py`
- Modify: `Raid Management Addon/UI/Config.xml`
- Read: `Raid Management Addon/Controllers/Config.lua:315`

**Interfaces:**
- Consumes: the seven `layout*` functions in `Controllers/Config.lua` and their existing suffix contracts.
- Produces: the same 235 ordered XML names with repeated row geometry removed from Lua-owned regions.

- [ ] **Step 1: Add the failing reduction-budget test**

Add this method to `ConfigXmlContractTest`:

```python
    def test_repeated_geometry_is_reduced(self) -> None:
        xml = source()
        self.assertLessEqual(len(re.findall(r"<Anchor\b", xml)), 80)
        self.assertLessEqual(len(re.findall(r"<Size\b", xml)), 40)
```

- [ ] **Step 2: Verify the budget fails against the baseline**

Run:

```powershell
py -3 -m unittest tests.test_config_xml_contract.ConfigXmlContractTest.test_repeated_geometry_is_reduced -v
```

Expected: failure reporting 224 anchors and/or 110 sizes above budget.

- [ ] **Step 3: Reduce only the Lua-owned panel regions**

In `Config.xml`, preserve the element tags, `name`, `inherits`, control attributes, layer/frame membership, and order, but remove per-row `<Size>` and `<Anchors>` children from named controls inside these exact owner regions:

```text
RMAInterfaceOptionsPanel
RMAInterfaceOptionsMasterLootPanelScrollChild
RMAInterfaceOptionsLootHistoryPanelScrollChild
RMAInterfaceOptionsLFMSpamPanelScrollChild
RMAInterfaceOptionsRaidWarningPanelScrollChild
RMAInterfaceOptionsHelpPanelScrollChild
RMALootHistoryCleanupPopup
```

For a control with no remaining child data, collapse it to the equivalent self-closing declaration. For example:

```xml
<FontString name="$parentOverviewTitle" inherits="GameFontNormalSmall" justifyH="LEFT" />
```

and:

```xml
<Button name="$parentRefreshPreviewBtn" inherits="RMAActionButtonTemplate" />
```

Keep all of the following in XML:

```text
RMAConfig and all of its existing geometry
top-level Interface Options panel sizes
ScrollFrame anchors and sizes
ScrollChild declarations and structural anchors
RMALootHistoryCleanupPopup size, center anchor, backdrop inheritance, and hierarchy
template declarations at the top of Config.xml
control-specific attributes such as letters, numeric, minValue, maxValue, valueStep, and inherits
```

Do not edit `Controllers/Config.lua` merely to satisfy the numeric budget. If a named control is not covered by an existing row description, keep its XML geometry and record it as intentional static layout.

- [ ] **Step 4: Run the contract and inspect measured reduction**

Run:

```powershell
py -3 -m unittest tests.test_config_xml_contract -v
@'
from pathlib import Path
import re
p = Path(r"Raid Management Addon/UI/Config.xml")
s = p.read_text(encoding="utf-8")
print("lines", len(s.splitlines()))
print("anchors", len(re.findall(r"<Anchor\b", s)))
print("sizes", len(re.findall(r"<Size\b", s)))
'@ | py -3 -
```

Expected: all eight tests pass; ordered names remain 235 with digest `53f86d9fa781ade75839a4d895840fd1013970add79c98a1bad9ef471fd8528d`; anchors are at most 80 and sizes at most 40.

- [ ] **Step 5: Review the XML diff for boundary violations**

Run:

```powershell
git diff -- "Raid Management Addon/UI/Config.xml"
rg -n "<Scripts>|<On[A-Za-z]+>" "Raid Management Addon/UI/Config.xml"
```

Expected: the diff removes only redundant geometry or collapses empty declarations; the `rg` command finds no handlers and therefore exits 1.

- [ ] **Step 6: Commit the Config XML reduction**

Run:

```powershell
git add -f -- tests/test_config_xml_contract.py
git add -- "Raid Management Addon/UI/Config.xml"
git diff --cached --check
git commit -m "refactor(ui): Reduce Config XML geometry"
```

Expected: one commit containing only the XML reduction and its budget test.

---

### Task 4: Verify batch coherence and visual contract

**Files:**
- Verify: `Raid Management Addon/UI/Config.xml`
- Verify: `Raid Management Addon/Controllers/Config.lua`
- Verify: `Raid Management Addon/Modules/UI/OptionsLayout.lua`
- Verify: `tests/test_config_xml_contract.py`
- Read: `docs/superpowers/specs/2026-07-11-xml-ui-review-design.md`

**Interfaces:**
- Consumes: the completed Config batch.
- Produces: static verification evidence and an explicit runtime-smoke status.

- [ ] **Step 1: Run the complete static validation stack**

Run:

```powershell
py -3 -m unittest discover -s tests -v
py -3 .agents\skills\wow-addon-dev-wotlk-v335a\scripts\validate_toc.py "Raid Management Addon\Raid Management Addon.toc"
py -3 .agents\skills\wow-addon-dev-wotlk-v335a\scripts\lint_lua51.py "Raid Management Addon"
py -3 .agents\skills\wow-addon-dev-wotlk-v335a\scripts\scan_xpcall.py "Raid Management Addon"
rg -n "<Scripts>|<On[A-Za-z]+>" "Raid Management Addon\UI" -g "*.xml"
luacheck "Raid Management Addon"
stylua --check "Raid Management Addon"
git diff --check
git status --short --branch
```

Expected: unit tests, TOC validation, Lua 5.1 validation, xpcall scan, luacheck, StyLua, and diff checks pass. The XML handler search returns no matches and exits 1. The working tree is clean after the task commits.

- [ ] **Step 2: Perform the architecture/cohesion review**

Confirm all statements are true:

```text
No new Lua or XML module was added.
No TOC or ModuleRegistry entry changed.
RMAConfig retained its static XML geometry.
Only existing ApplyRows-owned regions lost repeated geometry.
All 235 ordered names are preserved.
The cleanup popup retains its XML-owned 380x340 shell.
The cleanup popup title remains centered after Lua layout.
All other text defaults remain LEFT/TOP.
No behavior, persistence, localization, slash command, or wire contract changed.
```

- [ ] **Step 3: Record runtime acceptance status**

If no live client test was requested or performed, report exactly:

```text
runtime smoke: not run; manual acceptance pending
```

If the user chooses to smoke-test, ask them to verify `/rma config`, every Interface Options child panel, the Loot History cleanup popup, and `/reload`; record their result without making client automation part of the static gate.

- [ ] **Step 4: Stop before the next macro-area**

Present the measured Config reduction, validation results, retained static geometry, and runtime-smoke status. Obtain approval before writing the separate implementation plan for the Log family (`LootHistory.xml`, `RaidAttendance.xml`, and `Logger.xml`).

Do not begin the Log-family batch as part of this plan.
