import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ADDON = ROOT / "Raid Management Addon"
LOOT_COUNTER = ADDON / "Widgets" / "LootCounter.lua"
LOOT_HINTS = ADDON / "Widgets" / "LootHints.lua"
MINIMAP = ADDON / "EntryPoints" / "Minimap.lua"
MASTER = ADDON / "Controllers" / "Master.lua"
LOGGER = ADDON / "Controllers" / "Logger.lua"
ATTENDANCE = ADDON / "Controllers" / "Attendance.lua"
RAID_GRID = ADDON / "Widgets" / "RaidGrid.lua"
RESERVES_UI = ADDON / "Widgets" / "ReservesUI.lua"
FRAMES = ADDON / "Modules" / "UI" / "Frames.lua"


def read(path):
    return path.read_text(encoding="utf-8")


class TooltipOwnershipTest(unittest.TestCase):
    def test_loot_counter_row_buttons_use_shared_tooltip_owner(self):
        loot_counter = read(LOOT_COUNTER)

        self.assertIn('Tooltips.Bind(b, tip, "ANCHOR_RIGHT")', loot_counter)
        self.assertNotIn("GameTooltip:SetOwner", loot_counter)
        self.assertNotIn("GameTooltip:SetText", loot_counter)
        self.assertNotIn("GameTooltip:Show", loot_counter)
        self.assertNotIn("GameTooltip:Hide", loot_counter)

    def test_reserves_header_item_hover_uses_shared_item_tooltip_owner(self):
        frames = read(FRAMES)
        reserves_ui = read(RESERVES_UI)
        start = reserves_ui.index("local function showItemTooltip(owner, row)")
        end = reserves_ui.index("local function insertHeaderItemLink(row)", start)
        show_item_tooltip = reserves_ui[start:end]

        self.assertIn("function Tooltips.ShowItem(owner, itemLink, fallbackTitle, anchor", frames)
        self.assertIn("local ShowItemTooltip = assert(Tooltips.ShowItem", reserves_ui)
        self.assertIn('ShowItemTooltip(owner, link, row._tooltipTitle, "ANCHOR_RIGHT")', show_item_tooltip)
        self.assertNotIn("GameTooltip:SetOwner", show_item_tooltip)
        self.assertNotIn("GameTooltip:SetHyperlink", show_item_tooltip)
        self.assertNotIn("GameTooltip:SetText", show_item_tooltip)
        self.assertNotIn("GameTooltip:Show", show_item_tooltip)

    def test_reserves_item_info_probe_uses_shared_tooltip_owner(self):
        frames = read(FRAMES)
        reserves_ui = read(RESERVES_UI)
        start = reserves_ui.index("local function primeItemInfoQuery(itemId)")
        end = reserves_ui.index("local function queryItemInfo(itemId)", start)
        prime_item_info_query = reserves_ui[start:end]

        self.assertIn("function Tooltips.PrimeItemInfo(itemId)", frames)
        self.assertIn("return Tooltips.PrimeItemInfo(itemId)", prime_item_info_query)
        self.assertNotIn("GameTooltip", prime_item_info_query)

    def test_loot_hints_item_hover_uses_shared_item_tooltip_owner(self):
        frames = read(FRAMES)
        loot_hints = read(LOOT_HINTS)
        start = loot_hints.index("local function showLootItemTooltip(frame)")
        end = loot_hints.index("local function bindLootItemTooltip(frame, itemLink, reserveState, anchor)", start)
        show_loot_item_tooltip = loot_hints[start:end]

        self.assertIn("function Tooltips.ShowItem(owner, itemLink, fallbackTitle, anchor, details)", frames)
        self.assertIn("local Tooltips = UI.Tooltips", loot_hints)
        self.assertIn("local ShowItemTooltip = assert(Tooltips.ShowItem", loot_hints)
        self.assertIn('"Loot hints item tooltip presenter is not initialized"', loot_hints)
        self.assertIn('ShowItemTooltip(frame, frame._RMALootItemLink, nil, anchor, {', show_loot_item_tooltip)
        self.assertNotIn("UI.Tooltips.ShowItem", show_loot_item_tooltip)
        self.assertNotIn("GameTooltip:SetOwner", show_loot_item_tooltip)
        self.assertNotIn("GameTooltip:SetHyperlink", show_loot_item_tooltip)
        self.assertNotIn("GameTooltip:AddLine", show_loot_item_tooltip)
        self.assertNotIn("GameTooltip:Show", show_loot_item_tooltip)

    def test_raid_grid_button_hover_uses_shared_tooltip_owner(self):
        raid_grid = read(RAID_GRID)
        start = raid_grid.index('safeCall(button, "SetScript", "OnEnter", function(self)')
        end = raid_grid.index('safeCall(button, "SetScript", "OnLeave", function(self)', start)
        on_enter = raid_grid[start:end]

        self.assertIn("local ShowTooltipLines = assert(Tooltips.ShowLines", raid_grid)
        self.assertIn("local HideTooltip = assert(Tooltips.Hide", raid_grid)
        self.assertIn("ShowTooltipLines(self, {", on_enter)
        self.assertIn('title = self.fullName or "Unknown"', on_enter)
        self.assertIn("text = getTooltipLine()", on_enter)
        self.assertIn('"Modules/UI/Frames"', raid_grid)
        self.assertNotIn("Tooltips and Tooltips.ShowLines", raid_grid)
        self.assertNotIn("Tooltips and Tooltips.Hide", raid_grid)
        self.assertNotIn("GameTooltip", on_enter)

    def test_minimap_hover_uses_shared_default_anchor_tooltip_owner(self):
        frames = read(FRAMES)
        minimap = read(MINIMAP)
        start = minimap.index('Frames.SetScriptSafely(frame, "OnEnter", function(self)')
        end = minimap.index('Frames.SetScriptSafely(frame, "OnLeave", HideTooltip)', start)
        on_enter = minimap[start:end]

        self.assertIn("if model.defaultAnchor and type(GameTooltip_SetDefaultAnchor) == \"function\" then", frames)
        self.assertIn("local ShowTooltipLines = assert(Tooltips.ShowLines", minimap)
        self.assertIn("local HideTooltip = assert(Tooltips.Hide", minimap)
        self.assertIn("ShowTooltipLines(self, {", on_enter)
        self.assertIn('Frames.SetScriptSafely(frame, "OnLeave", HideTooltip)', minimap)
        self.assertIn("defaultAnchor = true", on_enter)
        self.assertIn("title = addon.WrapTextInColorCode", on_enter)
        self.assertIn("L.StrMinimapLClick", on_enter)
        self.assertNotIn("Tooltips and Tooltips.ShowLines", minimap)
        self.assertNotIn("Tooltips and Tooltips.Hide", minimap)
        self.assertNotIn("GameTooltip", on_enter)

    def test_master_clear_current_item_view_uses_shared_tooltip_owner(self):
        master = read(MASTER)
        start = master.index("Private.ClearCurrentItemView = function(focusItemCount)")
        end = master.index("Private.ResetItemCount = function(focus)", start)
        clear_current_item_view = master[start:end]

        self.assertIn("local Tooltips = UI.Tooltips", master)
        self.assertIn("local BindTooltip = assert(Tooltips.Bind", master)
        self.assertIn('"Master tooltip binder is not initialized"', master)
        self.assertIn("local HideTooltip = assert(Tooltips.Hide", master)
        self.assertIn('"Master tooltip hider is not initialized"', master)
        self.assertIn("HideTooltip()", clear_current_item_view)
        self.assertNotIn("UI.Tooltips.Hide", clear_current_item_view)
        self.assertNotIn("UI.Tooltips.Bind", master)
        self.assertNotIn("GameTooltip", clear_current_item_view)

    def test_attendance_spec_icon_hover_uses_shared_tooltip_owner(self):
        attendance = read(ATTENDANCE)
        start = attendance.index("local function bindAttendanceSpecIconTooltip(icon)")
        end = attendance.index("local function getSpecIcon(row, suffix)", start)
        bind_spec_icon_tooltip = attendance[start:end]

        self.assertIn("local ShowTooltipLines = assert(Tooltips.ShowLines", attendance)
        self.assertIn('"Attendance tooltip line renderer is not initialized"', attendance)
        self.assertIn("local BindTooltip = assert(Tooltips.Bind", attendance)
        self.assertIn('"Attendance tooltip binder is not initialized"', attendance)
        self.assertIn("ShowTooltipLines(self, {", bind_spec_icon_tooltip)
        self.assertIn('"ANCHOR_RIGHT"', bind_spec_icon_tooltip)
        self.assertNotIn("UI.Tooltips.ShowLines", bind_spec_icon_tooltip)
        self.assertNotIn("UI.Tooltips.Bind", bind_spec_icon_tooltip)
        self.assertNotIn("GameTooltip", bind_spec_icon_tooltip)

    def test_attendance_inspect_item_icon_hover_uses_shared_item_tooltip_owner(self):
        attendance = read(ATTENDANCE)
        start = attendance.index("local function getAttendanceInspectIcon(row, index)")
        end = attendance.index("local function clearAttendanceInspectIcons(row)", start)
        inspect_icon_tooltip = attendance[start:end]
        render_start = attendance.index("local function renderAttendanceInspectIcons(row, playerNid, snapshot)")
        render_end = attendance.index("local function makeAttendanceList(cfg, selField, hlOpts)", render_start)
        render_inspect_icons = attendance[render_start:render_end]

        self.assertIn("local ShowItemTooltip = assert(Tooltips.ShowItem", attendance)
        self.assertIn('"Attendance item tooltip renderer is not initialized"', attendance)
        self.assertIn('ShowItemTooltip(self, link, nil, "ANCHOR_LEFT")', inspect_icon_tooltip)
        self.assertIn("local itemLink = item and item.itemLink or nil", render_inspect_icons)
        self.assertIn("icon.texture:SetTexture(item.texture)", render_inspect_icons)
        self.assertNotIn("item and item.link", render_inspect_icons)
        self.assertNotIn("SetTexture(item.icon)", render_inspect_icons)
        self.assertIn("HideTooltip()", inspect_icon_tooltip)
        self.assertNotIn("UI.Tooltips.ShowItem", inspect_icon_tooltip)
        self.assertNotIn("UI.Tooltips.Hide", inspect_icon_tooltip)
        self.assertNotIn("GameTooltip", inspect_icon_tooltip)

    def test_logger_loot_item_hover_uses_shared_item_tooltip_owner(self):
        logger = read(LOGGER)
        start = logger.index("showLootTooltip = function(widget)")
        end = logger.index("buildSourceTooltipModel = function(row)", start)
        show_loot_tooltip = logger[start:end]
        bind_start = logger.index('SetScriptSafely(itemButton, "OnEnter"')
        bind_end = logger.index("local sourceHitBox", bind_start)
        item_button_bindings = logger[bind_start:bind_end]

        self.assertIn("local ShowItemTooltip = assert(Tooltips.ShowItem", logger)
        self.assertIn('ShowItemTooltip(widget, link, nil, "ANCHOR_CURSOR")', show_loot_tooltip)
        self.assertIn("HideTooltip()", item_button_bindings)
        self.assertNotIn("UI.Tooltips.ShowItem", show_loot_tooltip)
        self.assertNotIn("UI.Tooltips.Hide", item_button_bindings)
        self.assertNotIn("GameTooltip", show_loot_tooltip)
        self.assertNotIn("GameTooltip", item_button_bindings)

    def test_logger_source_hover_uses_shared_tooltip_model_owner_without_local_fallback(self):
        logger = read(LOGGER)
        start = logger.index("if sourceHitBox then")
        end = logger.index("-- Size the slot background", start)
        source_hitbox_bindings = logger[start:end]

        self.assertIn("local Tooltips = UI.Tooltips", logger)
        self.assertIn("local BindTooltipModel = assert(Tooltips.BindModel", logger)
        self.assertIn('"Logger source tooltip model binder is not initialized"', logger)
        self.assertIn('BindTooltipModel(sourceHitBox, function(self)', source_hitbox_bindings)
        self.assertIn('end, "ANCHOR_CURSOR")', source_hitbox_bindings)
        self.assertNotIn("if UI.Tooltips and UI.Tooltips.BindModel then", source_hitbox_bindings)
        self.assertNotIn('UI.Frames.SetScriptSafely(sourceHitBox, "OnEnter"', source_hitbox_bindings)
        self.assertNotIn('UI.Frames.SetScriptSafely(sourceHitBox, "OnLeave"', source_hitbox_bindings)

    def test_logger_source_tooltip_does_not_keep_dead_manual_renderer(self):
        logger = read(LOGGER)

        self.assertIn("buildSourceTooltipModel = function(row)", logger)
        self.assertNotIn("local showSourceTooltip", logger)
        self.assertNotIn("showSourceTooltip = function(widget)", logger)
        self.assertNotIn("showSourceTooltip(self)", logger)

    def test_logger_current_raid_button_uses_local_tooltip_binder(self):
        logger = read(LOGGER)
        start = logger.index('localize = function(n)')
        end = logger.index("local frame = _G[n]", start)
        localize_block = logger[start:end]

        self.assertIn("local BindTooltip = assert(Tooltips.Bind", logger)
        self.assertIn('"Logger tooltip binder is not initialized"', logger)
        self.assertIn('BindTooltip(_G[n .. "CurrentBtn"], L.StrRaidsCurrentHelp, nil, L.StrRaidCurrentTitle)', localize_block)
        self.assertNotIn("UI.Tooltips.Bind", localize_block)


if __name__ == "__main__":
    unittest.main()
