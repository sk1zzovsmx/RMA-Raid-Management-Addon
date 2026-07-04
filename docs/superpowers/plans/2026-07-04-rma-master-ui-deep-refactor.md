# RMA Master UI Deep Refactor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reduce repeated frame lookups, per-refresh closures, and roll model rebuilds in `Controllers/Master.lua` without changing Master Loot workflows.

**Architecture:** Keep XML frame names and controller ownership intact. Introduce a local reference cache and module-scope UI update helpers inside `Master.lua`; do not split files unless a later measured pass proves a cohesive owner.

**Tech Stack:** WotLK 3.3.5a UI, Lua 5.1, existing `UI.Frames`, `UI.Tooltips`, `UI.Primitives`, `MasterService`, source-level Python tests.

---

## File Structure

- Modify `Raid Management Addon/Controllers/Master.lua`: cache named frame refs, hoist update helpers, tighten roll model invalidation.
- Modify `Raid Management Addon/Services/Master/ButtonState.lua`: only if button state token needs a pure helper.
- Create `tests/test_master_ui_refactor_contract.py`: source-level tests proving no XML/script/name changes and helper extraction exists.

## Non-Goals

- Do not rename frames.
- Do not edit XML.
- Do not move domain rules from services into UI.
- Do not change roll winner semantics, multi-award semantics, or chat output.

## Tasks

### Task 1: Add Contract Tests

**Files:**
- Create: `tests/test_master_ui_refactor_contract.py`

- [ ] **Step 1: Write failing tests**

```python
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MASTER = ROOT / "Raid Management Addon" / "Controllers" / "Master.lua"
MASTER_XML = ROOT / "Raid Management Addon" / "UI" / "Master.xml"


def read(path):
    return path.read_text(encoding="utf-8")


def test_master_refactor_keeps_xml_layout_only():
    xml = read(MASTER_XML)
    assert "<Scripts>" not in xml
    assert not re.search(r"<On[A-Za-z]+>", xml)


def test_master_uses_cached_named_refs_for_button_refresh():
    source = read(MASTER)
    assert "local MASTER_REF_SUFFIXES" in source
    assert "local function acquireMasterRefs()" in source
    assert "module._refs" in source
    assert "refs.CountdownBtn" in source
    assert source.count("getNamedPart(") < 20


def test_master_update_helpers_are_not_recreated_inside_refresh_function():
    source = read(MASTER)
    body = source[source.index("local function updateMasterButtonsIfChanged"):]
    body = body[: body.index("updateText(\"countdown\"")]
    assert "local function updateEnabled" not in body
    assert "local function updateGlow" not in body
    assert "local function updateTooltip" not in body
```

- [ ] **Step 2: Run RED**

```powershell
py -3 -m unittest tests.test_master_ui_refactor_contract
```

Expected: FAIL because reference cache and hoisted helpers are absent.

### Task 2: Add Reference Cache

**Files:**
- Modify: `Raid Management Addon/Controllers/Master.lua`

- [ ] **Step 1: Add suffix map**

Near `getNamedPart`:

```lua
local MASTER_REF_SUFFIXES = {
    "AwardBtn",
    "BankBtn",
    "ClearBtn",
    "ConfigBtn",
    "CountdownBtn",
    "DisenchantBtn",
    "FreeBtn",
    "HoldBtn",
    "ItemBtn",
    "LootCounterBtn",
    "MSBtn",
    "OSBtn",
    "ReserveListBtn",
    "RollBtn",
    "SRBtn",
    "SelectItemBtn",
    "SpamLootBtn",
    "Status",
}
```

- [ ] **Step 2: Add cache acquisition**

```lua
local function acquireMasterRefs()
    local frameName = getFrameName()
    if not frameName then
        return nil
    end
    local refs = module._refs
    if type(refs) ~= "table" or refs.frameName ~= frameName then
        refs = { frameName = frameName }
        module._refs = refs
    end
    for i = 1, #MASTER_REF_SUFFIXES do
        local suffix = MASTER_REF_SUFFIXES[i]
        if refs[suffix] == nil then
            refs[suffix] = _G[frameName .. suffix] or false
        end
    end
    return refs
end
```

- [ ] **Step 3: Keep `getNamedPart` as compatibility helper**

Replace `getNamedPart` body:

```lua
local function getNamedPart(suffix)
    local refs = acquireMasterRefs()
    local ref = refs and refs[suffix] or nil
    if ref == false then
        return nil
    end
    return ref
end
```

### Task 3: Hoist Update Helpers

**Files:**
- Modify: `Raid Management Addon/Controllers/Master.lua`

- [ ] **Step 1: Add module-scope helper functions**

Near `requestCoalescedUiRefresh`:

```lua
local function updateEnabledState(cache, key, frame, enabled)
    enabled = enabled and true or false
    if frame and cache[key] ~= enabled then
        Primitives.SetEnabled(frame, enabled)
        cache[key] = enabled
    end
end

local function updateGlowState(cache, key, frame, enabled, r, g, b, style)
    local token = enabled and ("1|" .. tostring(style or "")) or "0"
    if frame and cache[key] ~= token then
        Primitives.SetButtonGlow(frame, enabled, r, g, b, style)
        cache[key] = token
    end
end

local function updateTextState(cache, key, frame, text)
    if frame and cache[key] ~= text then
        frame:SetText(text)
        cache[key] = text
    end
end

local function updateTooltipState(cache, key, frame, title, text)
    if not frame then
        return
    end
    local token = tostring(title or "") .. "\031" .. tostring(text or "")
    if cache[key] ~= token then
        UI.Tooltips.Bind(frame, text, nil, title)
        cache[key] = token
    end
end
```

- [ ] **Step 2: Rewrite `updateMasterButtonsIfChanged` to use refs**

Inside `updateMasterButtonsIfChanged`:

```lua
local refs = acquireMasterRefs()
if not refs then
    return
end
updateTextState(texts, "countdown", refs.CountdownBtn, state.countdownText)
updateTextState(texts, "award", refs.AwardBtn, state.awardText)
updateTextState(texts, "selectItem", refs.SelectItemBtn, state.selectItemText)
updateTextState(texts, "spamLoot", refs.SpamLootBtn, state.spamLootText)
updateTextState(texts, "status", refs.Status, state.statusText)

updateEnabledState(buttons, "selectItem", refs.SelectItemBtn, state.canSelectItem)
updateEnabledState(buttons, "spamLoot", refs.SpamLootBtn, state.canSpamLoot)
updateEnabledState(buttons, "ms", refs.MSBtn, state.canStartRolls)
updateEnabledState(buttons, "os", refs.OSBtn, state.canStartRolls)
updateEnabledState(buttons, "sr", refs.SRBtn, state.canStartSR)
updateEnabledState(buttons, "free", refs.FreeBtn, state.canStartRolls)
updateEnabledState(buttons, "countdown", refs.CountdownBtn, state.canCountdown)
updateEnabledState(buttons, "hold", refs.HoldBtn, state.canHold)
updateEnabledState(buttons, "bank", refs.BankBtn, state.canBank)
updateEnabledState(buttons, "disenchant", refs.DisenchantBtn, state.canDisenchant)
updateEnabledState(buttons, "award", refs.AwardBtn, state.canAward)
updateTextState(texts, "reserveList", refs.ReserveListBtn, state.reserveListText)
updateEnabledState(buttons, "reserveList", refs.ReserveListBtn, state.canReserveList)
updateEnabledState(buttons, "roll", refs.RollBtn, state.canRoll)
updateEnabledState(buttons, "clear", refs.ClearBtn, state.canClear)
```

Keep item button desaturation as a small helper:

```lua
local function updateItemButtonState(cache, itemBtn, enabled)
    enabled = enabled and true or false
    if itemBtn and cache.itemBtn ~= enabled then
        Primitives.SetEnabled(itemBtn, enabled)
        local texture = itemBtn:GetNormalTexture()
        if texture and texture.SetDesaturated then
            texture:SetDesaturated(not enabled)
        end
        cache.itemBtn = enabled
    end
end
```

### Task 4: Tighten Roll Model Invalidation

**Files:**
- Modify: `Raid Management Addon/Controllers/Master.lua`

- [ ] **Step 1: Replace remaining unnecessary `buildRollUiModel(true)` calls**

Use this rule:

- If code just needs the current model after an explicit `invalidateRollUiModel()`, call `buildRollUiModel()`.
- If code is responding to external roll state changes without a nearby invalidation, keep `buildRollUiModel(true)`.

Apply this exact replacement only where an invalidation occurs in the same function:

```lua
invalidateRollUiModel()
local rollModel = buildRollUiModel()
```

- [ ] **Step 2: Keep selected winner and trade notification paths conservative**

Do not change `buildRollUiModel(true)` at:

- selected winner validation before multi-award setup
- trade notification plan construction
- award request paths where roll state can change externally

### Task 5: Validate

- [ ] **Step 1: Run source contract test**

```powershell
py -3 -m unittest tests.test_master_ui_refactor_contract
```

Expected: PASS.

- [ ] **Step 2: Run static gates**

```powershell
py -3 .agents/skills/wow-addon-dev-wotlk-v335a/scripts/validate_toc.py "Raid Management Addon\Raid Management Addon.toc"
py -3 .agents/skills/wow-addon-dev-wotlk-v335a/scripts/lint_lua51.py "Raid Management Addon"
py -3 .agents/skills/wow-addon-dev-wotlk-v335a/scripts/scan_xpcall.py "Raid Management Addon"
luacheck "Raid Management Addon\Controllers\Master.lua"
rg -n "<Scripts>|<On[A-Za-z]+>" "Raid Management Addon\UI" -g "*.xml"
git diff --check
```

Expected: all pass except XML grep may exit 1 with no output, which means no handlers found.

## Acceptance Criteria

- No XML changes.
- No frame name changes.
- `updateMasterButtonsIfChanged` does not create helper closures on every call.
- Button frame lookups use cached refs.
- Roll model cache is invalidated before refresh rebuild, not force-rebuilt repeatedly inside one refresh.
- `/rma ml` runtime smoke remains manual acceptance.
