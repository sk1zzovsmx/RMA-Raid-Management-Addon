# Interface Options Layout And Categories Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reorganize `Interface > AddOns > RMA` by feature ownership and make every RMA options page use one viewport-safe, text-aware visual layout.

**Architecture:** Keep `UI/Config.xml` as the layout-only declaration of panel shells and named controls. Strengthen the existing `addon.UI.Layout` implementation so rows derive their width from the actual scroll viewport and their height from wrapped FontString measurements, then let `Controllers/Config.lua` compose General, Master Loot, Rolls, and existing feature pages through that owner. Preserve all option namespaces, keys, defaults, setters, events, dependencies, and persisted values.

**Tech Stack:** WotLK 3.3.5a FrameXML, Lua 5.1, Blizzard `InterfaceOptions_AddCategory`, Python `unittest`, repository Lua 5.1 behavior harness.

## Global Constraints

- Target WotLK 3.3.5a build 12340, TOC Interface `30300`, and Lua 5.1.
- Keep addon, globals, frames, popup keys, and visible branding on `RMA`/`RMA_` names.
- Do not modify vendored libraries under `Raid Management Addon/Libs/*`.
- Keep XML layout-only; do not add `<Scripts>` or `<On...>` handlers.
- Keep user-facing strings in `addon.L`.
- Do not change option keys, defaults, namespaces, SavedVariables, slash commands, or wire formats.
- Do not add Ace3 as part of this bounded correction.
- Reuse `addon.UI.Layout`; do not introduce another layout module, generic helper namespace, compatibility facade, or duplicate hidden controls.
- Preserve the compact `/rma config` window; this plan changes the Blizzard Interface Options pages only.
- Use focused checks after each task and the full applicable validation gate once at the end.

## File Structure And Ownership

- `Raid Management Addon/Modules/UI/OptionsLayout.lua`: sole owner of row measurement, viewport width resolution, widget placement, and computed content height.
- `Raid Management Addon/UI/Config.xml`: panel shells, scroll hierarchy, FontStrings, and interactive control declarations; no behavior.
- `Raid Management Addon/Controllers/Config.lua`: category registration, per-page row composition, localization, binding, refresh, option dependencies, and scroll reset.
- `Raid Management Addon/Localization/localization.en.lua`: names and descriptions for the new General and Rolls pages and clarified shared announcement behavior.
- `tests/test_config_xml_contract.py`: static category, naming, uniqueness, XML, and controller-layout contracts.
- `tests/lua/harness/70_raid_sync.lua`: Lua behavior cases for measured layout and moved option routing using the established harness.
- `tests/test_runtime_foundations_behavior.py`: Python entrypoints for the new Lua behavior cases.

---

### Task 1: Make The Shared Layout Viewport-Safe And Text-Aware

**Files:**
- Modify: `Raid Management Addon/Modules/UI/OptionsLayout.lua:20-480`
- Modify: `tests/lua/harness/70_raid_sync.lua` near `rma_quick_bar_config_panel_routes_settings`
- Modify: `tests/test_runtime_foundations_behavior.py` near the existing QuickBar config behavior test

**Interfaces:**
- Consumes: `Layout.ApplyRows(frameOrName, rows, cfg) -> number`, existing row constructors, `frame:GetParent()`, `frame:GetWidth()`, and FontString `GetStringHeight()`.
- Produces: the same public `Layout.ApplyRows` and row-constructor signatures; new config keys `fitToViewport: boolean` and `rightPadding: number`. No new public layout API.
- Invariant: when `fitToViewport == true`, the scroll-child width equals its parent scroll frame's positive runtime width, with `cfg.scrollChildWidth` used only as a fallback.
- Invariant: a text-bearing row uses `max(explicit minimum, measured wrapped text height)` after its final width is applied.

- [ ] **Step 1: Add a failing Lua behavior case for viewport width and wrapped text**

Add `cases.rma_options_layout_measures_wrapped_text` to `tests/lua/harness/70_raid_sync.lua`. Use a focused fake Frame/FontString implementation and load the real layout owner:

```lua
function cases.rma_options_layout_measures_wrapped_text(addon)
	local placements = {}
	local function makeWidget(name, measuredHeight)
		local widget = { name = name, measuredHeight = measuredHeight or 12 }
		function widget:GetName() return self.name end
		function widget:GetParent() return self.parent end
		function widget:GetWidth() return self.width or 0 end
		function widget:SetWidth(value) self.width = value end
		function widget:SetHeight(value) self.height = value end
		function widget:GetStringHeight() return self.measuredHeight end
		function widget:ClearAllPoints() end
		function widget:SetPoint(_, _, _, x, y)
			self.x, self.y = x, y
			placements[#placements + 1] = self
		end
		function widget:SetJustifyH() end
		function widget:SetJustifyV() end
		function widget:Show() end
		return widget
	end

	local scrollFrame = makeWidget("TestScrollFrame")
	scrollFrame.width = 360
	local content = makeWidget("TestScrollChild")
	content.parent = scrollFrame
	local refs = {
		FirstTitle = makeWidget("FirstTitle", 14),
		FirstBody = makeWidget("FirstBody", 48),
		SecondTitle = makeWidget("SecondTitle", 14),
		SecondBody = makeWidget("SecondBody", 12),
	}

	addon.UI = {
		Frames = {
			GetRef = function(_, suffix) return refs[suffix] end,
		},
	}
	_G.UIDropDownMenu_SetWidth = function() end
	_G.UIDropDownMenu_SetButtonWidth = function() end
	loadAddonFile(addon, "Raid Management Addon/Modules/UI/OptionsLayout.lua")

	local height = addon.UI.Layout.ApplyRows(content, {
		addon.UI.Layout.TextRow("FirstTitle", "FirstBody", { bodyHeight = 18, gap = 6 }),
		addon.UI.Layout.TextRow("SecondTitle", "SecondBody", { bodyHeight = 18, gap = 0 }),
	}, {
		fitToViewport = true,
		leftX = 16,
		rightPadding = 16,
		scrollChildWidth = 520,
		minHeight = 0,
	})

	assertEqual(360, content.width, "scroll child did not use runtime viewport width")
	assertEqual(328, refs.FirstBody.width, "text exceeded usable viewport width")
	assertTrue(refs.FirstBody.height >= 48, "wrapped body was clipped to its minimum")
	assertTrue(refs.SecondTitle.y < refs.FirstBody.y - refs.FirstBody.height, "rows overlap after measurement")
	assertTrue(height > 0, "layout did not return computed content height")
	print("PASS rma_options_layout_measures_wrapped_text")
end
```

Add the Python entrypoint to `RuntimeFoundationsBehaviorTest`:

```python
def test_options_layout_measures_wrapped_text(self) -> None:
    result = run_lua_case("rma_options_layout_measures_wrapped_text")
    self.assertIn("PASS rma_options_layout_measures_wrapped_text", result.stdout)
```

- [ ] **Step 2: Run the focused test and confirm the old fixed geometry fails**

Run:

```powershell
py -3 -m unittest tests.test_runtime_foundations_behavior.RuntimeFoundationsBehaviorTest.test_options_layout_measures_wrapped_text -v
```

Expected: FAIL because `ApplyRows` still assigns the configured `520` width and clamps the first body to `18` pixels.

- [ ] **Step 3: Add private viewport and text-measurement helpers**

In `OptionsLayout.lua`, keep the helpers private. Add `ceil` to the existing math locals and implement these contracts:

```lua
local max, ceil = math.max, math.ceil

local function getPositiveWidth(widget)
	if not (widget and widget.GetWidth) then
		return nil
	end
	local width = tonumber(widget:GetWidth())
	if width and width > 0 then
		return width
	end
	return nil
end

local function resolveLayoutWidths(frame, cfg)
	local childWidth = getCfg(cfg, "scrollChildWidth")
	if cfg and cfg.fitToViewport == true and frame and frame.GetParent then
		childWidth = getPositiveWidth(frame:GetParent()) or childWidth
	end
	local leftX = getCfg(cfg, "leftX")
	local rightPadding = getCfg(cfg, "rightPadding")
	return childWidth, max(1, childWidth - leftX - rightPadding)
end

local function measureTextHeight(widget, width, minimum)
	minimum = numberOrDefault(minimum, 0)
	if not widget then
		return minimum
	end
	if width and widget.SetWidth then
		widget:SetWidth(width)
	end
	if widget.SetHeight then
		widget:SetHeight(0)
	end
	local measured = widget.GetStringHeight and tonumber(widget:GetStringHeight()) or nil
	return max(minimum, measured and ceil(measured) or 0)
end
```

Place these helpers after the existing `numberOrDefault` definition so their
dependencies are defined before use. Add `rightPadding = 16` to `defaults`.
Calculate the effective `scrollChildWidth` and `contentWidth` once in
`Layout.ApplyRows`, copy them into a task-local effective config table, and pass
that table through `applyRow`. Do not mutate the caller's config table.

- [ ] **Step 4: Make each text-bearing row use measured height**

Refactor `applyTextRow`, `applyCommandRow`, `applyEditCommandRow`, `applyEditRow`, `applyDropDownRow`, `applyCheckRow`, and `applySliderRow` so they:

1. resolve the widget;
2. apply its final width;
3. call `measureTextHeight` with the existing explicit height as a minimum;
4. place it with the measured height;
5. return a row height large enough for both text and its interactive control.

For a text row, use this exact geometry rule:

```lua
local title = resolveWidget(frame, row.title)
local body = resolveWidget(frame, row.body)
local measuredTitleHeight = measureTextHeight(title, contentWidth, titleHeight)
local measuredBodyHeight = measureTextHeight(body, contentWidth, bodyHeight)
placeText(frame, title, leftX, cursorY, contentWidth, measuredTitleHeight)
placeText(frame, body, leftX, cursorY - measuredTitleHeight - bodyGap, contentWidth, measuredBodyHeight)
return measuredTitleHeight + bodyGap + measuredBodyHeight
```

For checkbox, command, edit, dropdown, and slider rows, retain their existing column semantics but compute returned height with `max(textHeight, controlHeight)`. Do not change button, edit-box, slider, or dropdown public behavior.

- [ ] **Step 5: Run the focused layout behavior test**

Run the command from Step 2.

Expected: PASS with runtime width `360`, usable content width `328`, measured body height at least `48`, and no row overlap.

- [ ] **Step 6: Run the nearest existing UI/layout contracts**

Run:

```powershell
py -3 -m unittest tests.test_config_xml_contract tests.test_runtime_foundations_behavior.RuntimeFoundationsBehaviorTest.test_quick_bar_config_panel_routes_settings -v
```

Expected: PASS.

- [ ] **Step 7: Review and commit the shared layout change**

Review `git diff --check` and confirm `Layout` gained no new public method. Then commit only the Task 1 files:

```powershell
git add -- 'Raid Management Addon/Modules/UI/OptionsLayout.lua' 'tests/lua/harness/70_raid_sync.lua' 'tests/test_runtime_foundations_behavior.py'
git commit -m 'fix(ui): measure options rows within viewport'
```

---

### Task 2: Reorganize Options Into General, Master Loot, And Rolls

**Files:**
- Modify: `Raid Management Addon/UI/Config.xml:376-552`
- Modify: `Raid Management Addon/Controllers/Config.lua:75-122, 327-430, 590-790, 970-1160, 1589-1760`
- Modify: `Raid Management Addon/Localization/localization.en.lua:320-396`
- Modify: `tests/test_config_xml_contract.py:14-120`
- Modify: `tests/lua/harness/70_raid_sync.lua` in the Config fixture and behavior cases
- Modify: `tests/test_runtime_foundations_behavior.py` near Config behavior entrypoints

**Interfaces:**
- Consumes: Task 1 `Layout.ApplyRows(..., { fitToViewport = true, ... })` behavior.
- Produces: `RMAInterfaceOptionsGeneralPanel`, `RMAInterfaceOptionsGeneralPanelScrollChild`, `RMAInterfaceOptionsRollsPanel`, and `RMAInterfaceOptionsRollsPanelScrollChild`; per-page suffix arrays used by binding and refresh.
- Preserves: `Options.GetByKey(key)`, `Options.Set(key, value)`, all option owner namespaces/defaults, `BuildConfigOptionChangedName(key)`, and existing dependency behavior.

- [ ] **Step 1: Replace the hash-only XML contract with explicit category and uniqueness assertions**

Remove `EXPECTED_ORDERED_NAMES_SHA256` and `test_ordered_name_contract_is_unchanged`; moving controls coherently makes the full-document name hash an implementation-detail lock.

Extend `REQUIRED_PUBLIC_FRAMES` with:

```python
"RMAInterfaceOptionsGeneralPanel",
"RMAInterfaceOptionsGeneralPanelScrollChild",
"RMAInterfaceOptionsRollsPanel",
"RMAInterfaceOptionsRollsPanelScrollChild",
```

Add helpers and a test that checks each option appears under exactly one intended scroll child:

```python
def frame_region(xml: str, frame_name: str) -> str:
    start = xml.index(f'<Frame name="{frame_name}"')
    next_frame = xml.find('\n\t<Frame name="RMAInterfaceOptions', start + 1)
    return xml[start:] if next_frame < 0 else xml[start:next_frame]


def test_options_are_declared_once_in_their_owner_panel(self) -> None:
    xml = source()
    expected = {
        "RMAInterfaceOptionsGeneralPanel": ("showTooltips", "minimapButton"),
        "RMAInterfaceOptionsRollsPanel": (
            "sortAscending", "countdownDuration", "countdownSimpleRaidMsg",
            "countdownRollsBlock", "showLootCounterDuringMSRoll",
        ),
        "RMAInterfaceOptionsMasterLootPanel": (
            "useRaidWarning", "announceOnWin", "announceOnHold", "announceOnBank",
            "announceOnDisenchant", "lootWhispers", "screenReminder", "ignoreStacks",
            "autoMasterLootOnBossTarget", "autoMasterLootNoticeSecondsEditBox",
            "askGroupLootAfterBossLoot", "autoSpamLootOnLootOpened",
            "autoSpamSoftResOnLootOpened",
        ),
    }
    for panel, suffixes in expected.items():
        region = frame_region(xml, panel)
        for suffix in suffixes:
            self.assertIn(f'$parent{suffix}"', region)
            exact_control = rf'name="[^"]*ScrollChild{re.escape(suffix)}"'
            self.assertEqual(1, len(re.findall(exact_control, xml)))
```

Keep the existing XML parsing, XML-handler, public-frame, QuickBar, and geometry-budget tests.

- [ ] **Step 2: Add a failing controller registration contract**

Add to `ConfigLayoutOwnershipTest`:

```python
def test_general_and_rolls_panels_are_registered_under_rma(self) -> None:
    controller = CONTROLLER_LUA.read_text(encoding="utf-8")
    self.assertIn('frameName = generalPanelFrameName', controller)
    self.assertIn('frameName = rollsPanelFrameName', controller)
    self.assertIn('title = L.StrConfigPanelGeneral', controller)
    self.assertIn('title = L.StrConfigPanelRolls', controller)
```

- [ ] **Step 3: Run the focused static tests and confirm the new categories are absent**

Run:

```powershell
py -3 -m unittest tests.test_config_xml_contract -v
```

Expected: FAIL because General and Rolls frames, strings, and registration specs do not exist.

- [ ] **Step 4: Declare General and Rolls panels and move controls in XML**

In `Config.xml`, use the same panel/scroll hierarchy for General, Master Loot,
Rolls, QuickBar, Loot History, LFM Spam, Raid Warning, and Help:

```xml
<Frame name="RMAInterfaceOptionsGeneralPanel" parent="UIParent" hidden="true">
	<Size><AbsDimension x="560" y="560" /></Size>
	<Frames>
		<ScrollFrame name="$parentScrollFrame" inherits="RMAOptionsScrollFrameTemplate">
			<Anchors>
				<Anchor point="TOPLEFT" />
				<Anchor point="BOTTOMRIGHT"><Offset><AbsDimension x="-42" y="36" /></Offset></Anchor>
			</Anchors>
			<ScrollChild>
				<Frame name="RMAInterfaceOptionsGeneralPanelScrollChild">
					<Size><AbsDimension x="420" y="500" /></Size>
					<Layers>
						<Layer level="ARTWORK">
							<FontString name="$parentTitle" inherits="GameFontNormalLarge" justifyH="LEFT" />
							<FontString name="$parentshowTooltipsStr" inherits="RMAConfigFontStringTemplate" />
							<FontString name="$parentshowTooltipsDesc" inherits="RMAConfigCompactDescriptionFontStringTemplate" />
							<FontString name="$parentminimapButtonStr" inherits="RMAConfigFontStringTemplate" />
							<FontString name="$parentminimapButtonDesc" inherits="RMAConfigCompactDescriptionFontStringTemplate" />
						</Layer>
					</Layers>
					<Frames>
						<CheckButton name="$parentshowTooltips" inherits="RMAConfigCheckButtonTemplate" />
						<CheckButton name="$parentminimapButton" inherits="RMAConfigCheckButtonTemplate" />
					</Frames>
				</Frame>
			</ScrollChild>
		</ScrollFrame>
	</Frames>
</Frame>
```

Create the Rolls panel with the same shell and this exact scroll-child content:

```xml
<Frame name="RMAInterfaceOptionsRollsPanelScrollChild">
	<Size><AbsDimension x="420" y="500" /></Size>
	<Layers>
		<Layer level="ARTWORK">
			<FontString name="$parentTitle" inherits="GameFontNormalLarge" justifyH="LEFT" />
			<FontString name="$parentsortAscendingStr" inherits="RMAConfigFontStringTemplate" />
			<FontString name="$parentsortAscendingDesc" inherits="RMAConfigCompactDescriptionFontStringTemplate" />
			<FontString name="$parentcountdownDurationStr" inherits="GameFontNormalSmall" />
			<FontString name="$parentcountdownDurationDesc" inherits="RMAConfigCompactDescriptionFontStringTemplate" />
			<FontString name="$parentcountdownSimpleRaidMsgStr" inherits="RMAConfigFontStringTemplate" />
			<FontString name="$parentcountdownSimpleRaidMsgDesc" inherits="RMAConfigCompactDescriptionFontStringTemplate" />
			<FontString name="$parentcountdownRollsBlockStr" inherits="RMAConfigFontStringTemplate" />
			<FontString name="$parentcountdownRollsBlockDesc" inherits="RMAConfigCompactDescriptionFontStringTemplate" />
			<FontString name="$parentshowLootCounterDuringMSRollStr" inherits="RMAConfigFontStringTemplate" />
			<FontString name="$parentshowLootCounterDuringMSRollDesc" inherits="RMAConfigCompactDescriptionFontStringTemplate" />
		</Layer>
	</Layers>
	<Frames>
		<CheckButton name="$parentsortAscending" inherits="RMAConfigCheckButtonTemplate" />
		<Slider name="$parentcountdownDuration" inherits="OptionsSliderTemplate"
			minValue="3.0" maxValue="60.0" defaultValue="5.0" valueStep="1.0" />
		<CheckButton name="$parentcountdownSimpleRaidMsg" inherits="RMAConfigCheckButtonTemplate" />
		<CheckButton name="$parentcountdownRollsBlock" inherits="RMAConfigCheckButtonTemplate" />
		<CheckButton name="$parentshowLootCounterDuringMSRoll" inherits="RMAConfigCheckButtonTemplate" />
	</Frames>
</Frame>
```

Move, rather than duplicate, these FontStrings and interactive controls out of
the Master Loot scroll child. General and Rolls controls use names derived from
their new scroll-child parent. Do not add aliases with the retired Master Loot
child name.

- [ ] **Step 5: Add category strings and clarify shared announcement copy**

Add to `localization.en.lua` beside existing panel names:

```lua
L.StrConfigPanelGeneral = "General"
L.StrConfigPanelRolls = "Rolls"
```

Change the Raid Warning description to communicate its shared scope without
changing behavior:

```lua
L.StrConfigUseRaidWarningDesc =
	"Uses Raid Warning for roll countdowns and loot announcements when available."
```

- [ ] **Step 6: Split controller composition by option owner**

Replace the single `optionSuffixes` list with explicit immutable local arrays:

```lua
local generalOptionSuffixes = { "showTooltips", "minimapButton" }
local masterLootOptionSuffixes = {
	"useRaidWarning", "announceOnWin", "announceOnHold", "announceOnBank",
	"announceOnDisenchant", "lootWhispers", "screenReminder", "ignoreStacks",
	"autoMasterLootOnBossTarget", "askGroupLootAfterBossLoot",
	"autoSpamLootOnLootOpened", "autoSpamSoftResOnLootOpened",
}
local rollsOptionSuffixes = {
	"sortAscending", "countdownSimpleRaidMsg", "countdownRollsBlock",
	"showLootCounterDuringMSRoll",
}
```

Add constants for both new panel and content frame names. Change
`collectConfigRefs(frame, suffixes, includeClose)` and
`bindConfigHandlers(frameName, refs, suffixes, includeClose)` to iterate only
the supplied suffix list. The edit box and slider remain optional refs and bind
only on their owning page.

Introduce page-specific layout functions:

```lua
local function layoutGeneralPanel()
	applyOptionsLayout(generalContentFrameName, {
		{ type = "title", suffix = "Title", gap = 16 },
		Layout.CheckRow("showTooltips", { gap = 8 }),
		Layout.CheckRow("minimapButton", { gap = 0 }),
	}, optionsPanelLayoutCfg)
end

local function layoutRollsPanel()
	applyOptionsLayout(rollsContentFrameName, {
		{ type = "title", suffix = "Title", gap = 16 },
		Layout.CheckRow("sortAscending", { gap = 8 }),
		Layout.SliderRow("countdownDuration", "countdownDuration", { gap = 12 }),
		Layout.CheckRow("countdownSimpleRaidMsg", { gap = 8 }),
		Layout.CheckRow("countdownRollsBlock", { gap = 8 }),
		Layout.CheckRow("showLootCounterDuringMSRoll", { gap = 0 }),
	}, optionsPanelLayoutCfg)
end
```

Remove those controls from `layoutMasterLootPanel`. Keep the Master Loot edit
row, presets, and preview on that page.

- [ ] **Step 7: Localize, bind, and refresh each option page independently**

Create `localizeGeneralPanel`, `localizeMasterLootPanel`, and
`localizeRollsPanel`. Each function sets only strings declared by its page and
then calls its matching layout function.

Refactor refresh into a common page operation:

```lua
local function refreshOptionChecks(frameName, suffixes)
	for i = 1, #suffixes do
		local suffix = suffixes[i]
		setChecked(frameName, suffix, GetOptionByKey(suffix) == true)
	end
end
```

Then implement page-specific refresh functions. Master Loot owns the auto-loot
dependency and announcement preview. Rolls owns the countdown slider and the
`countdownSimpleRaidMsg` enabled state. General owns the minimap and tooltip
checkboxes. `refreshInterfaceOptionsPanel` refreshes all three pages safely,
even when only one is visible.

Update `getInterfacePanelSpecs()` so the child order is General, Master Loot,
Rolls, QuickBar, Loot History, LFM Spam, Raid Warning, Help. Each new spec must
use `parent = L.StrConfigPanelTitle` and a dedicated branch that localizes,
binds, refreshes, and hooks OnShow once.

- [ ] **Step 8: Extend the Lua Config fixture and verify moved controls still route by key**

Extract the existing QuickBar Config setup into the file-local helper
`newConfigPanelFixture(addon)`. It must return `callbacks`, `fixture`,
`generalPanel`, `generalRefs`, `rollsPanel`, `rollsRefs`, `quickBarPanel`, and
`quickBarRefs` so the existing QuickBar case and both new cases share the same
complete dependency setup. In that fixture, create fake General and Rolls
panel/content frames. Capture option writes and the minimap call with:

```lua
local writes = {}
addon.Options.Set = function(key, value)
	writes[key] = value
end
addon.Minimap = {
	SetMinimapButtonShown = function(_, shown)
		fixture.minimapShown = shown
	end,
}
```

Add a new case `rma_config_moved_options_preserve_behavior`. Its assertions
after loading `Controllers/Config.lua` and invoking the OptionsLoaded callback
must be:

```lua
assertEqual("General", generalPanel.name, "General panel title differs")
assertEqual("RMA", generalPanel.parent, "General panel parent differs")
assertEqual("Rolls", rollsPanel.name, "Rolls panel title differs")
assertEqual("RMA", rollsPanel.parent, "Rolls panel parent differs")

generalPanel:Show()
generalRefs.minimapButton:Click(false)
assertEqual(false, fixture.minimapShown, "moved minimap option did not update owner")
assertEqual(false, writes.minimapButton, "moved minimap option wrote the wrong key")

rollsPanel:Show()
rollsRefs.countdownDuration.value = 10
rollsRefs.countdownDuration.OnValueChanged(rollsRefs.countdownDuration)
assertEqual(10, writes.countdownDuration, "moved countdown wrote the wrong key")
rollsRefs.countdownRollsBlock:Click(false)
assertEqual(false, writes.countdownRollsBlock, "moved late-roll option wrote the wrong key")
print("PASS rma_config_moved_options_preserve_behavior")
```

The fake refs must use these exact names so `onOptionClick` derives the existing
option keys correctly:

```lua
generalRefs.minimapButton = makeWidget(
	"RMAInterfaceOptionsGeneralPanelScrollChildminimapButton"
)
rollsRefs.countdownDuration = makeWidget(
	"RMAInterfaceOptionsRollsPanelScrollChildcountdownDuration"
)
rollsRefs.countdownRollsBlock = makeWidget(
	"RMAInterfaceOptionsRollsPanelScrollChildcountdownRollsBlock"
)
```

The case must:

- invokes the registered OptionsLoaded callback;
- shows both new panels;
- clicks `minimapButton` under General and asserts the existing minimap owner is called;
- changes the Rolls slider and asserts `Options.Set("countdownDuration", value)`;
- clicks `countdownRollsBlock` and asserts `Options.Set("countdownRollsBlock", false)`;
- verifies the panels have parent `RMA` and titles `General`/`Rolls`.

Expose it through Python:

```python
def test_config_moved_options_preserve_behavior(self) -> None:
    result = run_lua_case("rma_config_moved_options_preserve_behavior")
    self.assertIn("PASS rma_config_moved_options_preserve_behavior", result.stdout)
```

- [ ] **Step 9: Run focused category and behavior tests**

Run:

```powershell
py -3 -m unittest tests.test_config_xml_contract tests.test_runtime_foundations_behavior.RuntimeFoundationsBehaviorTest.test_config_moved_options_preserve_behavior tests.test_runtime_foundations_behavior.RuntimeFoundationsBehaviorTest.test_quick_bar_config_panel_routes_settings -v
```

Expected: PASS. Confirm every moved XML suffix occurs once and the existing QuickBar route remains unchanged.

- [ ] **Step 10: Review and commit the category reorganization**

Inspect the staged diff and confirm it contains no option namespace/default
changes. Then commit only the Task 2 files:

```powershell
git add -- 'Raid Management Addon/UI/Config.xml' 'Raid Management Addon/Controllers/Config.lua' 'Raid Management Addon/Localization/localization.en.lua' 'tests/test_config_xml_contract.py' 'tests/lua/harness/70_raid_sync.lua' 'tests/test_runtime_foundations_behavior.py'
git commit -m 'refactor(ui): organize interface options by owner'
```

---

### Task 3: Unify Panel Presentation And Complete The Runtime Gate

**Files:**
- Modify: `Raid Management Addon/Controllers/Config.lua` layout configuration and panel OnShow hooks
- Modify: `Raid Management Addon/UI/Config.xml` scroll-frame anchors and initial child sizes if the shared contract requires normalization
- Modify: `tests/test_config_xml_contract.py`
- Modify: `tests/lua/harness/70_raid_sync.lua`
- Modify: `tests/test_runtime_foundations_behavior.py`

**Interfaces:**
- Consumes: Task 1 measured `Layout.ApplyRows` and Task 2 page ownership.
- Produces: one `optionsPanelLayoutCfg` selected by every scrollable Interface Options page; `resetPanelScroll(panel)` behavior on page show; QuickBar orientation row explicitly bound to `OrientationStr`.
- Preserves: all panel actions, dropdown choices, maintenance callbacks, confirmation popups, and compact config window behavior.

- [ ] **Step 1: Add failing contracts for one visual configuration and the Orientation label**

Add these assertions to `ConfigLayoutOwnershipTest`:

```python
def test_all_scrollable_panels_use_the_shared_viewport_layout(self) -> None:
    controller = CONTROLLER_LUA.read_text(encoding="utf-8")
    self.assertIn("fitToViewport = true", controller)
    self.assertIn("rightPadding = 16", controller)
    self.assertNotIn("scrollChildWidth = 560", controller)
    self.assertNotIn("scrollChildWidth = 520", controller)

def test_quick_bar_orientation_uses_its_declared_label(self) -> None:
    controller = CONTROLLER_LUA.read_text(encoding="utf-8")
    orientation = controller[controller.index("local function layoutQuickBarPanel") :]
    orientation = orientation[: orientation.index("local function layoutLootHistoryPanel")]
    self.assertIn('title = "OrientationStr"', orientation)
    self.assertNotIn('Layout.DropDownRow("Orientation"', orientation)
```

Add a runtime case that gives a fake panel scroll frame a non-zero vertical
offset, invokes its OnShow hook, and asserts the offset becomes zero:

```lua
function cases.rma_config_panel_resets_scroll_on_show(addon)
	local config = newConfigPanelFixture(addon)
	local scrollFrame = config.makeWidget("RMAInterfaceOptionsRollsPanelScrollFrame")
	scrollFrame.verticalScroll = 120
	function scrollFrame:SetVerticalScroll(value) self.verticalScroll = value end
	config.rollsRefs.ScrollFrame = scrollFrame

	loadAddonFile(addon, "Raid Management Addon/Controllers/Config.lua")
	assert(config.callbacks.OPTIONS)()
	config.rollsPanel:Show()
	assertEqual(0, scrollFrame.verticalScroll, "Rolls panel did not reset scroll on show")
	print("PASS rma_config_panel_resets_scroll_on_show")
end
```

Return `makeWidget` from `newConfigPanelFixture` as `config.makeWidget` for this
case. This is demonstrated reuse inside one test owner, not a runtime
abstraction.

Add the Python entrypoint:

```python
def test_config_panel_resets_scroll_on_show(self) -> None:
    result = run_lua_case("rma_config_panel_resets_scroll_on_show")
    self.assertIn("PASS rma_config_panel_resets_scroll_on_show", result.stdout)
```

- [ ] **Step 2: Run the focused tests and confirm the old presentation fails**

Run:

```powershell
py -3 -m unittest tests.test_config_xml_contract.ConfigLayoutOwnershipTest -v
```

Expected: FAIL because the common config still declares fixed child widths and
QuickBar still asks `DropDownRow` for the undeclared `OrientationTitle`.

- [ ] **Step 3: Normalize the shared panel configuration**

Use one configuration table for General, Master Loot, Rolls, QuickBar, Loot
History, LFM Spam, Raid Warning, and Help:

```lua
local optionsPanelLayoutCfg = {
	fitToViewport = true,
	leftX = 16,
	rightPadding = 16,
	scrollChildWidth = 420,
	contentWidth = 388,
	textWidth = 240,
	commandWidth = 105,
	columnGap = 12,
	rowGap = 8,
	bottomPadding = 28,
	minHeight = 500,
}
```

The `contentWidth` value is a fallback; Task 1 replaces it with the actual
runtime usable width when `fitToViewport` succeeds. Remove page-specific width,
row-gap, and scroll-child-width overrides. Keep only genuine content-specific
minimum heights or row minimums.

The non-scrollable RMA overview must use a separate shallow copy with
`fitToViewport = false`, `contentWidth = 388`, and `scrollChildWidth = 420`.
This gives it the same left/right visual bounds without asking `ApplyRows` to
derive width from `UIParent`. Replace its current `440`/`560` values; retain
only its content-specific row gaps and minimum height.

Change QuickBar's orientation descriptor to name the declared label explicitly:

```lua
{
	type = "dropdown",
	title = "OrientationStr",
	desc = "OrientationDesc",
	dropdown = "OrientationDropDown",
	gap = 8,
},
```

- [ ] **Step 4: Reset each category's scroll position when shown**

Add one private helper in `Controllers/Config.lua`:

```lua
local function resetPanelScroll(panel)
	local scrollFrame = Frames.GetRef(panel, "ScrollFrame")
	if scrollFrame and scrollFrame.SetVerticalScroll then
		scrollFrame:SetVerticalScroll(0)
	end
end
```

Call it from each scrollable panel's existing OnShow hook after localization
and layout but before refresh/action preview. Do not reset while the user is
interacting within an already visible page.

- [ ] **Step 5: Normalize XML viewport anchors and fallback sizes**

Ensure every child panel uses these same ScrollFrame anchors and the same
fallback child width:

```xml
<Anchors>
	<Anchor point="TOPLEFT" />
	<Anchor point="BOTTOMRIGHT">
		<Offset><AbsDimension x="-42" y="36" /></Offset>
	</Anchor>
</Anchors>
```

Keep the scrollbar gutter inside the panel through this `BOTTOMRIGHT` offset.
Initial child heights may differ only as load-time fallbacks; Lua owns final
content height.

Do not add scripts, duplicate templates, or per-panel anchor exceptions.

- [ ] **Step 6: Run focused presentation and Config behavior tests**

Run:

```powershell
py -3 -m unittest tests.test_config_xml_contract tests.test_runtime_foundations_behavior.RuntimeFoundationsBehaviorTest.test_options_layout_measures_wrapped_text tests.test_runtime_foundations_behavior.RuntimeFoundationsBehaviorTest.test_config_moved_options_preserve_behavior tests.test_runtime_foundations_behavior.RuntimeFoundationsBehaviorTest.test_quick_bar_config_panel_routes_settings -v
```

Expected: PASS.

- [ ] **Step 7: Run the full automated suite once**

Run:

```powershell
py -3 -m unittest discover -s tests -v
```

Expected: PASS. If it fails, fix only the evidenced regression and rerun the
failed or nearest focused test before repeating the full suite.

- [ ] **Step 8: Run the complete applicable WotLK/static gate**

Run:

```powershell
py -3 '.agents/skills/wow-addon-dev-wotlk-v335a/scripts/validate_toc.py' 'Raid Management Addon/Raid Management Addon.toc'
py -3 '.agents/skills/wow-addon-dev-wotlk-v335a/scripts/lint_lua51.py' 'Raid Management Addon'
py -3 '.agents/skills/wow-addon-dev-wotlk-v335a/scripts/scan_xpcall.py' 'Raid Management Addon'
rg -n '<Scripts>|<On[A-Za-z]+>' 'Raid Management Addon/UI' -g '*.xml'
powershell -ExecutionPolicy Bypass -File 'tools/check-rma.ps1'
stylua --check 'Raid Management Addon' tests
luacheck 'Raid Management Addon'
git diff --check
git status --short --branch
```

Expected: validators, project checks, formatting, lint, and diff checks pass;
the XML handler search returns no matches. If `stylua` or `luacheck` is not
installed, record that explicitly instead of reporting it as passed.

- [ ] **Step 9: Perform the implementation self-review and behavior-delta check**

Inspect the complete runtime diff and verify:

- no option key/default/namespace, SavedVariable, slash command, or wire format changed;
- every moved control exists once and uses the correct page frame name;
- no panel width exceeds its actual scroll viewport;
- row heights are measured after localization and final width assignment;
- no compatibility alias, duplicate hidden control, new module, or generic helper was added;
- the documented old/new behavior in the approved design still matches the implementation;
- the only remaining unverified item is the in-game visual smoke test.

- [ ] **Step 10: Commit the unified presentation**

```powershell
git add -- 'Raid Management Addon/Controllers/Config.lua' 'Raid Management Addon/UI/Config.xml' 'tests/test_config_xml_contract.py' 'tests/lua/harness/70_raid_sync.lua' 'tests/test_runtime_foundations_behavior.py'
git commit -m 'fix(ui): unify options panel presentation'
```

- [ ] **Step 11: Run the in-game smoke matrix at the reproduced UI scale**

On a WotLK 3.3.5a client using the UI scale from the supplied screenshots:

1. open `Interface > AddOns > RMA` and every child category;
2. confirm each category opens at the top;
3. confirm no title, word, description, dropdown, edit box, checkbox, button,
   slider, scroll child, or scrollbar is clipped, overlapping, or outside the panel;
4. confirm every page shares the same margins, typography, control column, and
   vertical spacing;
5. toggle every moved General and Rolls setting and confirm the owning feature
   updates immediately;
6. exercise Master Loot presets and dependency states;
7. run `/reload` and confirm all option values persist.

Record any visual failure with a screenshot and the affected category. Runtime
smoke remains pending until performed in the client; static checks must not be
reported as proof of the visual result.

## Completion And Coherence Report

Before calling the batch committable, report:

- changed TOC-referenced runtime files: `Modules/UI/OptionsLayout.lua`,
  `Controllers/Config.lua`, `Localization/localization.en.lua`, `UI/Config.xml`;
- whether any untracked or deleted runtime files exist;
- TOC/load-order risk (expected: none, because no TOC entry changes);
- registry risk from the two new Interface Options panels;
- all focused, full-suite, WotLK, formatting, lint, and diff checks run or not run;
- the documented UX behavior delta and unchanged persistence contract;
- in-game smoke status and residual UI-scale/localization risk.
