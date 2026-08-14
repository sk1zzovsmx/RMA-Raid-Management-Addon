# QuickBar Raid Availability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep QuickBar ML and GL visible but disabled, non-interactive, and without glow unless the player belongs to a raid party.

**Architecture:** `addon.Widgets.QuickBar` remains the sole UI owner. It reads membership through `Raid:IsPlayerInRaid()`, refreshes on bind, the forwarded `Events.Wow.RaidRosterUpdate`, and `Events.Internal.RaidRosterDelta`, and relies on native WotLK `Button:Enable()`/`Disable()` for the grey visual state. `Init.lua` publishes the forwarded event after every `RAID_ROSTER_UPDATE` refresh attempt, including no-op refreshes without a current RMA raid. The Raid service continues to own authority validation and loot-method mutation.

**Tech Stack:** World of Warcraft WotLK 3.3.5a (Interface 30300), Lua 5.1, XML layout-only UI, Python `unittest` plus LuaJIT runtime harness.

## Global Constraints

- Solo and normal parties keep ML/GL visible but disabled; only raid parties enable them.
- Disabled ML/GL show no glow and cannot open confirmation popups.
- HIS, SR, RW, layout, dragging, visibility, and SavedVariables behavior remain unchanged.
- Use `addon.Widgets.QuickBar`; do not reintroduce `addon.Controllers.QuickBar` or a compatibility alias.
- Use only WotLK 3.3.5a APIs and Lua 5.1 syntax; add no polling `OnUpdate`.

---

### Task 1: Gate ML/GL By Raid-Party Membership

**Files:**
- Modify: `tests/lua/harness/60_loot_ui.lua:3367-3688`
- Modify: `tests/lua/harness/30_raid_runtime.lua`
- Modify: `Raid Management Addon/Widgets/QuickBar.lua:16-346`
- Modify: `Raid Management Addon/Init.lua`
- Modify: `Raid Management Addon/Modules/Events.lua`
- Verify: `tests/test_runtime_foundations_behavior.py`

**Interfaces:**
- Consumes: `Raid:IsPlayerInRaid() -> boolean`, `Events.Wow.RaidRosterUpdate`, `Events.Internal.RaidRosterDelta`, WotLK `Button:Enable()` and `Button:Disable()`.
- Produces: `QuickBar:RefreshRaidAvailability() -> boolean`; ML/GL enabled state and glow always match current raid-party membership.

- [ ] **Step 1: Make the QuickBar widget fixtures model native enabled state**

In both QuickBar `makeWidget` helpers in `tests/lua/harness/60_loot_ui.lua`, initialize `enabled = true`, add the native button methods, and make `Click()` ignore disabled buttons:

```lua
local widget = { width = width or 0, height = height or 0, shown = true, enabled = true }
function widget:Enable() self.enabled = true end
function widget:Disable() self.enabled = false end
function widget:IsEnabled() return self.enabled end
function widget:Click()
	if self.enabled and self.OnClick then
		self.OnClick(self)
	end
end
```

Keep non-button texture/frame fixture behavior unchanged.

- [ ] **Step 2: Write the failing raid-availability assertions**

Keep `rma_quick_bar_routes_actions_and_persists_position` in a raid so its existing action assertions remain focused:

```lua
local fixture = {
	lootMethod = "group",
	inRaid = true,
	historyToggles = 0,
	reservesToggles = 0,
	warningToggles = 0,
}
```

Add this method to that case's Raid stub:

```lua
IsPlayerInRaid = function() return fixture.inRaid end,
```

In `rma_quick_bar_configures_layout_and_glow`, start outside a raid and record popup attempts:

```lua
local fixture = { lootMethod = "group", inRaid = false, popupCount = 0 }
```

Use a popup stub that records attempts:

```lua
Popups = {
	ShowConfirm = function()
		fixture.popupCount = fixture.popupCount + 1
	end,
},
```

Add membership and a no-op roster-refresh stub to its Raid stub:

```lua
IsPlayerInRaid = function() return fixture.inRaid end,
RefreshAndPublish = function() return nil end,
```

Immediately after `widget:EnsureUI()`, assert the solo/normal-party state, join a raid, and invoke the real forwarded roster-update path:

```lua
assertEqual(false, refs.ML:IsEnabled(), "ML must be disabled outside a raid party")
assertEqual(false, refs.GL:IsEnabled(), "GL must be disabled outside a raid party")
assertEqual(false, refs.MLGlow:IsShown(), "ML glow must be hidden outside a raid party")
assertEqual(false, refs.GLGlow:IsShown(), "GL glow must be hidden outside a raid party")
refs.ML:Click()
assertEqual(0, fixture.popupCount, "disabled ML must not open a popup")

fixture.inRaid = true
addon:RAID_ROSTER_UPDATE(true)
assertEqual(true, refs.ML:IsEnabled(), "ML must enable inside a raid party")
assertEqual(true, refs.GL:IsEnabled(), "GL must enable inside a raid party")
```

At the end of the case, verify leaving the raid clears availability and glow:

```lua
fixture.inRaid = false
addon:RAID_ROSTER_UPDATE(true)
assertEqual(false, refs.ML:IsEnabled(), "ML must disable after leaving the raid party")
assertEqual(false, refs.GL:IsEnabled(), "GL must disable after leaving the raid party")
assertEqual(false, refs.MLGlow:IsShown(), "ML glow must clear after leaving the raid party")
assertEqual(false, refs.GLGlow:IsShown(), "GL glow must clear after leaving the raid party")
refs.GL:Click()
assertEqual(0, fixture.popupCount, "disabled GL must not open a popup")
```

- [ ] **Step 3: Run the focused test and verify RED**

Run:

```powershell
py -3 -m unittest tests.test_runtime_foundations_behavior.RuntimeFoundationsBehaviorTest.test_quick_bar_configures_layout_and_glow -v
```

Expected: FAIL because ML/GL do not refresh after a no-op real `RAID_ROSTER_UPDATE` path.

- [ ] **Step 4: Implement the minimal event-driven widget behavior**

Seed `Wow.RaidRosterUpdate = "wow.RAID_ROSTER_UPDATE"` in both `Init.lua` and `Modules/Events.lua`. In `Init.lua`, publish `WowEvents.RaidRosterUpdate` after every `RefreshAndPublish()` attempt, including no-op results. In `Raid Management Addon/Widgets/QuickBar.lua`, resolve both roster events and the membership operation with the other dependencies:

```lua
local RaidRosterDelta = assert(
	Events.Internal.RaidRosterDelta,
	"QuickBar raid-roster event is not initialized"
)
local RaidRosterUpdate = assert(
	Events.Wow.RaidRosterUpdate,
	"QuickBar forwarded raid-roster event is not initialized"
)
local IsPlayerInRaid = assert(Raid.IsPlayerInRaid, "QuickBar raid-membership resolver is not initialized")
```

Prevent stale or programmatic click callbacks from opening a popup outside a raid party:

```lua
local function requestWithConfirmation(method, popupKey, text)
	if not IsPlayerInRaid(Raid) or Raid:GetLootMethodName() == method then
		return false
	end
	-- existing confirmation body remains unchanged
end
```

Add the availability refresh and make layout binding call it:

```lua
function module:RefreshRaidAvailability()
	local refs = self.refs
	if not refs then
		return false
	end
	local inRaid = IsPlayerInRaid(Raid) == true
	if inRaid then
		refs.ML:Enable()
		refs.GL:Enable()
	else
		refs.ML:Disable()
		refs.GL:Disable()
	end
	self:RefreshLootMethod()
	return inRaid
end
```

Change `RefreshLayout()` to call `self:RefreshRaidAvailability()` instead of `self:RefreshLootMethod()`. Gate both glow expressions with live raid membership:

```lua
local inRaid = IsPlayerInRaid(Raid) == true
Frames.SetShown(refs.MLGlow, inRaid and method == "master" and self:IsButtonShown("ML"))
Frames.SetShown(refs.GLGlow, inRaid and method == "group" and self:IsButtonShown("GL"))
```

Register both the forwarded WoW event and the existing internal delta without polling:

```lua
Bus.RegisterCallback(RaidRosterDelta, function()
	module:RefreshRaidAvailability()
end)
Bus.RegisterCallback(RaidRosterUpdate, function()
	module:RefreshRaidAvailability()
end)
```

- [ ] **Step 5: Run focused QuickBar tests and verify GREEN**

Run:

```powershell
py -3 -m unittest tests.test_quick_bar_contract tests.test_runtime_foundations_behavior.RuntimeFoundationsBehaviorTest.test_quick_bar_routes_actions_and_persists_position tests.test_runtime_foundations_behavior.RuntimeFoundationsBehaviorTest.test_quick_bar_configures_layout_and_glow -v
```

Expected: all QuickBar contract/action/layout/glow tests PASS.

- [ ] **Step 6: Run full runtime validation**

Run:

```powershell
py -3 -m unittest discover -s tests -q
py -3 .agents/skills/wow-addon-dev-wotlk-v335a/scripts/validate_toc.py "Raid Management Addon/Raid Management Addon.toc"
py -3 .agents/skills/wow-addon-dev-wotlk-v335a/scripts/lint_lua51.py "Raid Management Addon"
py -3 .agents/skills/wow-addon-dev-wotlk-v335a/scripts/scan_xpcall.py "Raid Management Addon"
rg -n "<Scripts>|<On[A-Za-z]+>" "Raid Management Addon/UI" -g "*.xml"
git diff --check
```

Expected: all Python/Lua behavior tests PASS; TOC reports zero errors; all Lua files are 5.1-clean and free of variadic `xpcall`; XML scan returns no matches; whitespace check returns no errors.

- [ ] **Step 7: Commit the behavior**

```powershell
git add -- "Raid Management Addon/Widgets/QuickBar.lua" "tests/lua/harness/60_loot_ui.lua"
git commit -m "fix(quick-bar): disable loot actions outside raids"
```
