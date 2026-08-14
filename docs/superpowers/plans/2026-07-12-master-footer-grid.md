# Master Footer Grid Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restore the Master Loot window to `250 x 480` and expose Loot History, Loot Counter, Import SoftRes, and Loot Bans in a uniform `2 x 2` footer grid.

**Architecture:** Keep static dimensions and anchors in `UI/Master.xml`. Extend the existing Master controller reference, localization, and click-binding paths so the new button delegates directly to `Controllers.Logger:ToggleLootHistory()`.

**Tech Stack:** WoW FrameXML, Lua 5.1, Python `unittest` contract tests, WotLK 3.3.5a Interface 30300.

## Global Constraints

- Preserve WotLK 3.3.5a, Interface 30300, and Lua 5.1 compatibility.
- XML owns static layout only; Lua owns localized text and click behavior.
- All four footer buttons are exactly `113 x 25` with 4-pixel gaps.
- Preserve existing SavedVariables, addon-message formats, and loot behavior.
- Do not modify the user-owned README changes.

---

### Task 1: Implement And Verify The Master Footer Grid

**Files:**
- Modify: `tests/test_loot_bans_contract.py`
- Modify: `Raid Management Addon/UI/Master.xml:82-86,397-437`
- Modify: `Raid Management Addon/Controllers/Master.lua:400-425,1158-1176,1298-1320,2665-2675`

**Interfaces:**
- Consumes: `Controllers.Logger:ToggleLootHistory()`, `L.StrLootHistory`, `GetFrameRef(frame, suffix)`, and `SetScriptSafely(frame, script, handler)`.
- Produces: the `LootHistoryBtn` Master frame reference and click binding; no new public runtime API.

- [ ] **Step 1: Write the failing layout and binding contract**

Add a test that reads `MASTER_XML` and `MASTER`, then asserts:

```python
def test_master_footer_uses_compact_two_by_two_action_grid(self) -> None:
    xml = MASTER_XML.read_text(encoding="utf-8")
    master = MASTER.read_text(encoding="utf-8")

    self.assertRegex(xml, r'<Frame name="RMAMaster"[\s\S]*?<AbsDimension x="250" y="480"')
    for suffix in ("LootHistoryBtn", "LootCounterBtn", "ReserveListBtn", "LootBansBtn"):
        self.assertRegex(
            xml,
            rf'<Button name="\$parent{suffix}"[\s\S]*?<AbsDimension x="113" y="25"',
        )
    self.assertIn('relativeTo="$parentReserveListBtn" relativePoint="TOPLEFT"', xml)
    self.assertIn('relativeTo="$parentLootHistoryBtn" relativePoint="RIGHT"', xml)
    self.assertIn('relativeTo="$parentLootCounterBtn" relativePoint="BOTTOMLEFT"', xml)
    self.assertIn('"LootHistoryBtn",', master)
    self.assertIn('lootHistoryBtn = GetFrameRef(frame, "LootHistoryBtn")', master)
    self.assertIn('Controllers.Logger:ToggleLootHistory()', master)
    self.assertIn('setPartText("LootHistoryBtn", L.StrLootHistory)', master)
```

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```powershell
python -m unittest tests.test_loot_bans_contract.LootBansContractTests.test_master_footer_uses_compact_two_by_two_action_grid -v
```

Expected: FAIL because `RMAMaster` is 350 pixels wide and `LootHistoryBtn` does not exist.

- [ ] **Step 3: Implement the minimal FrameXML grid**

In `UI/Master.xml`, restore:

```xml
<AbsDimension x="250" y="480" />
```

Keep `ReserveListBtn` at `BOTTOMLEFT` offset `10,10`. Add `LootHistoryBtn` at `113 x 25`, anchored `BOTTOMLEFT` to `ReserveListBtn`'s `TOPLEFT` with offset `0,4`. Make `LootCounterBtn` `113 x 25`, anchored left of the history button's right edge with offset `4,0`. Make `LootBansBtn` `113 x 25`, anchored `TOPLEFT` to the counter button's `BOTTOMLEFT` with offset `0,-4`.

- [ ] **Step 4: Bind Loot History through the existing Master controller path**

In `Controllers/Master.lua`:

```lua
-- Add to MASTER_REF_SUFFIXES.
"LootHistoryBtn",

-- Add to uiState.AcquireRefs.
lootHistoryBtn = GetFrameRef(frame, "LootHistoryBtn"),

-- Add to bindMainControlScripts.
SetScriptSafely(refs.lootHistoryBtn, "OnClick", function()
    Controllers.Logger:ToggleLootHistory()
end)

-- Add to frame localization.
setPartText("LootHistoryBtn", L.StrLootHistory)
```

- [ ] **Step 5: Run focused tests and verify GREEN**

Run:

```powershell
python -m unittest tests.test_loot_bans_contract -v
```

Expected: all Loot Bans/Master footer contracts PASS.

- [ ] **Step 6: Run repository validation**

Run:

```powershell
python -m unittest discover -s tests -p "test_*.py"
py -3 .agents/skills/wow-addon-dev-wotlk-v335a/scripts/validate_toc.py "Raid Management Addon/Raid Management Addon.toc"
py -3 .agents/skills/wow-addon-dev-wotlk-v335a/scripts/lint_lua51.py "Raid Management Addon"
py -3 .agents/skills/wow-addon-dev-wotlk-v335a/scripts/scan_xpcall.py "Raid Management Addon"
rg -n "<Scripts>|<On[A-Za-z]+>" "Raid Management Addon/UI" -g "*.xml"
git diff --check
```

Expected: all tests and validators PASS; XML handler search returns no matches.

- [ ] **Step 7: Commit the implementation**

```powershell
git add "Raid Management Addon/UI/Master.xml" "Raid Management Addon/Controllers/Master.lua" tests/test_loot_bans_contract.py
git commit -m "feat(master): Arrange compact footer action grid"
```

- [ ] **Step 8: Record manual smoke requirements**

In the handoff, explicitly mark the following as pending unless tested in the client: the restored `250 x 480` size, exact 2 x 2 alignment, and each button opening the expected existing window.
