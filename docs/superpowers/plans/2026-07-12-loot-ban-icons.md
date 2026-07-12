# Loot Ban Icons Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show `UI-GroupLoot-Pass-Up` instead of the spec icon for banned Loot Bans RaidGrid entries and add the same status icon immediately left of banned names in Attendance.

**Architecture:** RaidGrid receives a generic `entry.iconOverride` projection and remains unaware of Loot Bans. Master supplies the override for banned rows, while Attendance owns a Lua-created name-cell icon and restores its layout on reused unbanned rows.

**Tech Stack:** World of Warcraft 3.3.5a build 12340, Interface `30300`, Lua 5.1.5, FrameXML, Python 3 `unittest`.

## Global Constraints

- Use texture path `Interface\Buttons\UI-GroupLoot-Pass-Up` exactly.
- RaidGrid must not import or reference `LootBans`; `entry.iconOverride` is generic.
- In Loot Bans RaidGrid, banned rows replace the inspected spec icon; unbanned rows keep their spec icon.
- In Attendance, the Loot Ban icon is additional inside the existing Name cell; existing spec icons and columns remain unchanged.
- Attendance XML remains unchanged and layout-only; Lua creates, binds, shows, hides, and anchors the icon.
- Hovering the Attendance name or Loot Ban icon shows the same title/note tooltip.
- Reused rows and buttons must not retain an override icon, hidden spec, shifted name anchor, or stale tooltip state.
- Preserve RMA identity, Lua 5.1, WotLK 3.3.5a APIs, SavedVariables, wire formats, and existing README state.

---

### Task 1: Generic RaidGrid Icon Override

**Files:**
- Modify: `Raid Management Addon/Widgets/RaidGrid.lua`
- Modify: `Raid Management Addon/Controllers/Master.lua`
- Modify: `tests/test_loot_bans_contract.py`

**Interfaces:**
- Consumes: existing RaidGrid entry table and inspected spec snapshot.
- Produces: optional `entry.iconOverride:string`; Master sets it only for active Loot Ban rows.

- [ ] **Step 1: Add failing projection tests**

Extend `LootBansUiContractTest`:

```python
def test_loot_ban_rows_project_pass_icon_override(self) -> None:
    source = MASTER.read_text(encoding="utf-8")
    self.assertIn('row.iconOverride = "Interface\\\\Buttons\\\\UI-GroupLoot-Pass-Up"', source)

def test_raid_grid_icon_override_precedes_spec_without_ban_policy(self) -> None:
    source = RAID_GRID.read_text(encoding="utf-8")
    self.assertIn("entry.iconOverride", source)
    self.assertRegex(source, r"specIcon\s*=\s*entry\s+and\s+entry\.iconOverride")
    self.assertNotIn("LootBans", source)
```

- [ ] **Step 2: Verify RED**

Run:

```powershell
py -3 -m unittest tests.test_loot_bans_contract.LootBansUiContractTest -v
```

Expected: both new tests fail because the projection does not exist.

- [ ] **Step 3: Implement the minimal generic precedence rule**

In `RaidGrid.Refresh`, initialize the icon from the entry before consulting inspect data:

```lua
local specIcon = entry and entry.iconOverride
if (not specIcon or specIcon == "") and fullName then
    local spec = GetPlayerSpecSnapshot(SpecInspect, fullName)
    specIcon = spec and spec.icon or nil
end
```

This assignment runs for every entry, so a reused button automatically replaces an old override with the current entry's spec or hides the icon.

- [ ] **Step 4: Project the banned-row icon from Master**

Inside the existing `if active then` branch of `Private.BuildLootBanRows` add:

```lua
row.iconOverride = "Interface\\Buttons\\UI-GroupLoot-Pass-Up"
```

Do not set it on unbanned rows.

- [ ] **Step 5: Verify GREEN and compatibility**

```powershell
py -3 -m unittest tests.test_loot_bans_contract.LootBansUiContractTest -v
py -3 -m unittest discover -s tests -p "test_*.py" -v
py -3 "C:\Users\ferra\Downloads\RMA-Raid Management Addon\.agents\skills\wow-addon-dev-wotlk-v335a\scripts\lint_lua51.py" "Raid Management Addon"
git diff --check
```

Expected: all tests and validation pass.

- [ ] **Step 6: Commit**

```powershell
git add -- "Raid Management Addon/Widgets/RaidGrid.lua" "Raid Management Addon/Controllers/Master.lua"
git add -f -- tests/test_loot_bans_contract.py
git commit -m "feat(loot): Show ban icon in RaidGrid"
```

### Task 2: Attendance Name-Cell Loot Ban Icon

**Files:**
- Modify: `Raid Management Addon/Controllers/Attendance.lua`
- Modify: `tests/test_loot_bans_contract.py`

**Interfaces:**
- Consumes: current per-row `lootBanned`, `lootBanNote`, `ui.Name`, and the existing Loot Ban tooltip model.
- Produces: cached `row._RMALootBanIcon` Button with texture, shared tooltip behavior, and reversible name anchoring.

- [ ] **Step 1: Add failing Attendance ownership/reuse tests**

Extend `LootBansAttendanceContractTest`:

```python
def test_attendance_creates_pass_icon_inside_name_cell(self) -> None:
    source = ATTENDANCE.read_text(encoding="utf-8")
    self.assertIn('SetNormalTexture("Interface\\\\Buttons\\\\UI-GroupLoot-Pass-Up")', source)
    self.assertIn("row._RMALootBanIcon", source)
    self.assertIn('SetPoint("LEFT", row, "LEFT", 3, 0)', source)

def test_attendance_restores_name_layout_for_unbanned_reused_rows(self) -> None:
    source = ATTENDANCE.read_text(encoding="utf-8")
    self.assertRegex(source, r"if lootBanned then[\s\S]+_RMALootBanIcon[\s\S]+:Show\(\)")
    self.assertRegex(source, r"else[\s\S]+_RMALootBanIcon[\s\S]+:Hide\(\)")
    self.assertIn('ui.Name:SetPoint("TOPLEFT", row, "TOPLEFT", 3, -1)', source)
```

- [ ] **Step 2: Verify RED**

Run:

```powershell
py -3 -m unittest tests.test_loot_bans_contract.LootBansAttendanceContractTest -v
```

Expected: missing icon and reversible layout assertions fail.

- [ ] **Step 3: Create the cached Lua-owned icon**

Add a helper beside `getAttendanceLootBanHotspot`:

```lua
local function getAttendanceLootBanIcon(row)
    local icon = row._RMALootBanIcon
    if not icon then
        icon = CreateFrame("Button", nil, row)
        icon:SetSize(14, 14)
        icon:SetPoint("LEFT", row, "LEFT", 3, 0)
        icon:SetNormalTexture("Interface\\Buttons\\UI-GroupLoot-Pass-Up")
        icon:EnableMouse(true)
        icon:Hide()
        row._RMALootBanIcon = icon
    end
    return icon
end
```

Bind the icon's `OnEnter` and `OnLeave` through `SetScriptSafely`. Use the same title/note model already used by the name hotspot; update icon active/note fields on every draw.

- [ ] **Step 4: Apply and restore Name-cell layout on every draw**

After obtaining current Loot Ban state:

```lua
local lootBanIcon = getAttendanceLootBanIcon(row)
lootBanIcon._RMALootBanActive = lootBanned
lootBanIcon._RMALootBanNote = lootBanNote
ui.Name:ClearAllPoints()
if lootBanned then
    lootBanIcon:Show()
    ui.Name:SetPoint("TOPLEFT", row, "TOPLEFT", 20, -1)
    ui.Name:SetWidth(63)
else
    lootBanIcon:Hide()
    ui.Name:SetPoint("TOPLEFT", row, "TOPLEFT", 3, -1)
    ui.Name:SetWidth(80)
end
```

The icon tooltip must contain `L.StrLootBanTooltipTitle` and append the note only when present. Existing Attendance spec-icon code remains untouched.

- [ ] **Step 5: Verify GREEN, XML invariance, and full suite**

```powershell
py -3 -m unittest tests.test_loot_bans_contract.LootBansAttendanceContractTest -v
py -3 -m unittest discover -s tests -p "test_*.py" -v
rg -n "<Scripts>|<On[A-Za-z]+>" "Raid Management Addon/UI" -g "*.xml"
py -3 "C:\Users\ferra\Downloads\RMA-Raid Management Addon\.agents\skills\wow-addon-dev-wotlk-v335a\scripts\lint_lua51.py" "Raid Management Addon"
git diff --check
```

Expected: tests and validator pass; XML scan returns no matches; `UI/RaidAttendance.xml` is unchanged.

- [ ] **Step 6: Commit**

```powershell
git add -- "Raid Management Addon/Controllers/Attendance.lua"
git add -f -- tests/test_loot_bans_contract.py
git commit -m "feat(attendance): Show Loot Ban name icon"
```

### Task 3: Final Verification

**Files:**
- Verify only: changed files from Tasks 1-2.

- [ ] **Step 1: Run all static gates available for the delta**

```powershell
py -3 -m unittest discover -s tests -p "test_*.py" -v
py -3 "C:\Users\ferra\Downloads\RMA-Raid Management Addon\.agents\skills\wow-addon-dev-wotlk-v335a\scripts\validate_toc.py" "Raid Management Addon/Raid Management Addon.toc"
py -3 "C:\Users\ferra\Downloads\RMA-Raid Management Addon\.agents\skills\wow-addon-dev-wotlk-v335a\scripts\lint_lua51.py" "Raid Management Addon"
py -3 "C:\Users\ferra\Downloads\RMA-Raid Management Addon\.agents\skills\wow-addon-dev-wotlk-v335a\scripts\scan_xpcall.py" "Raid Management Addon"
luacheck "Raid Management Addon"
git diff --check
git status --short --branch
```

Expected: all available commands pass and the worktree is clean.

- [ ] **Step 2: Record manual smoke as pending unless actually run**

Manual WotLK acceptance checks:

1. Banned Loot Bans RaidGrid entry shows the pass icon instead of spec.
2. Unbanned RaidGrid entry retains spec and reused buttons do not leak the pass icon.
3. Attendance banned row shows pass icon left of gray name and the existing spec icons remain.
4. Name and pass icon show the same note tooltip.
5. Removing the ban hides the icon and restores the original name position/width.

Do not claim these were observed unless tested in the client.
