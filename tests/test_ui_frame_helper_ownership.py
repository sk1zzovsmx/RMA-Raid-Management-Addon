import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ADDON = ROOT / "Raid Management Addon"
INIT = ADDON / "Init.lua"
TOC = ADDON / "Raid Management Addon.toc"
FRAMES = ADDON / "Modules" / "UI" / "Frames.lua"
EFFECTS = ADDON / "Modules" / "UI" / "Effects.lua"
VISUALS = ADDON / "Modules" / "UI" / "Visuals.lua"
LIST_CONTROLLER = ADDON / "Modules" / "UI" / "ListController.lua"
MINIMAP = ADDON / "EntryPoints" / "Minimap.lua"
SLASH_EVENTS = ADDON / "EntryPoints" / "SlashEvents.lua"
WARNINGS = ADDON / "Controllers" / "Warnings.lua"
MASTER = ADDON / "Controllers" / "Master.lua"
LOOT_HINTS = ADDON / "Widgets" / "LootHints.lua"
LOOT_COUNTER = ADDON / "Widgets" / "LootCounter.lua"
RESERVES_UI = ADDON / "Widgets" / "ReservesUI.lua"
CONFIG = ADDON / "Widgets" / "Config.lua"
TRADE_MENU = ADDON / "Widgets" / "TradeMenu.lua"
ITEM_SELECTION = ADDON / "Widgets" / "ItemSelection.lua"


def read(path):
    return path.read_text(encoding="utf-8")


class UIFrameHelperOwnershipTest(unittest.TestCase):
    def test_module_frame_getter_is_owned_by_shared_ui_frames(self):
        init = read(INIT)
        frames = read(FRAMES)

        self.assertRegex(frames, r"function\s+Frames\.MakeModuleFrameGetter\s*\(")
        self.assertIn("Frames.MakeFrameGetter(globalFrameName)", frames)

        self.assertNotIn("local function makeModuleFrameGetter", init)
        self.assertNotIn('if key == "MakeModuleFrameGetter"', init)
        self.assertNotIn("addon.UI and addon.UI.Frames and addon.UI.Frames.MakeModuleFrameGetter", init)
        self.assertNotIn("Database.MakeModuleFrameGetter = makeModuleFrameGetter", init)
        self.assertNotIn("Database.MakeModuleFrameGetter = Frames.MakeModuleFrameGetter", frames)

    def test_feature_files_get_module_frame_getters_from_ui_frames_owner(self):
        feature_files = [WARNINGS, MASTER, LOOT_COUNTER, RESERVES_UI, CONFIG, ADDON / "Controllers" / "Spammer.lua", ADDON / "Controllers" / "Logger.lua"]
        for path in feature_files:
            with self.subTest(path=path.name):
                src = read(path)
                self.assertNotIn("feature.MakeModuleFrameGetter", src)

        self.assertIn('local getFrame = Frames.MakeModuleFrameGetter(module, "RMAWarnings")', read(WARNINGS))
        self.assertIn('local getFrame = MakeModuleFrameGetter(module, "RMAMaster")', read(MASTER))
        self.assertIn('local getFrame = Frames.MakeModuleFrameGetter(module, "RMASpammer")', read(ADDON / "Controllers" / "Spammer.lua"))
        self.assertIn('local getFrame = MakeModuleFrameGetter(module, "RMALootHistory")', read(ADDON / "Controllers" / "Logger.lua"))
        self.assertIn('local getFrame = Frames.MakeModuleFrameGetter(module, "RMALootCounterFrame")', read(LOOT_COUNTER))
        self.assertIn('local getFrame = Frames.MakeModuleFrameGetter(module, "RMAReserveListFrame")', read(RESERVES_UI))
        self.assertIn('local getImportFrame = Frames.MakeModuleFrameGetter(Import, "RMAImportWindow")', read(RESERVES_UI))
        self.assertIn('local getFrame = Frames.MakeModuleFrameGetter(module, "RMAConfig")', read(CONFIG))

    def test_logger_gets_frame_refs_through_local_frame_owner_binding(self):
        logger = read(ADDON / "Controllers" / "Logger.lua")

        self.assertIn("local Frames = UI.Frames", logger)
        self.assertIn("local GetFrameRef = assert(Frames.GetRef", logger)
        self.assertIn('"Logger frame ref resolver is not initialized"', logger)
        self.assertIn('history = GetFrameRef(frame, "History")', logger)
        self.assertIn('raids = GetFrameRef(frame, "RMALootHistoryRaids")', logger)
        self.assertNotIn("UI.Frames.GetRef", logger)

    def test_logger_binds_frame_scripts_and_titles_through_local_frame_owner_bindings(self):
        logger = read(ADDON / "Controllers" / "Logger.lua")

        self.assertIn("local GetFrame = assert(Frames.Get", logger)
        self.assertIn('"Logger frame resolver is not initialized"', logger)
        self.assertIn("local SetScriptSafely = assert(Frames.SetScriptSafely", logger)
        self.assertIn('"Logger frame script binder is not initialized"', logger)
        self.assertIn("local SetFrameTitle = assert(Frames.SetFrameTitle", logger)
        self.assertIn('"Logger frame title binder is not initialized"', logger)
        self.assertIn("local EnableDrag = assert(Frames.EnableDrag", logger)
        self.assertIn('"Logger frame drag binder is not initialized"', logger)
        self.assertIn('local frame = GetFrame("RMAExportFrame")', logger)
        self.assertIn('SetScriptSafely(_G[n .. "CurrentBtn"], "OnClick"', logger)
        self.assertIn("SetFrameTitle(refs.frame, L.StrLoggerExportTitle)", logger)
        self.assertIn("EnableDrag(refs.frame)", logger)
        self.assertNotIn("UI.Frames.Get", logger)
        self.assertNotIn("UI.Frames.SetScriptSafely", logger)
        self.assertNotIn("UI.Frames.SetFrameTitle", logger)
        self.assertNotIn("UI.Frames.EnableDrag", logger)

    def test_logger_binds_module_frames_through_local_frame_owner_bindings(self):
        logger = read(ADDON / "Controllers" / "Logger.lua")

        self.assertIn("local BindModuleFrame = assert(Frames.BindModuleFrame", logger)
        self.assertIn('"Logger module frame binder is not initialized"', logger)
        self.assertIn("local MakeModuleFrameGetter =", logger)
        self.assertIn("assert(Frames.MakeModuleFrameGetter", logger)
        self.assertIn('"Logger module frame getter factory is not initialized"', logger)
        self.assertIn("local MakeFrameGetter = assert(Frames.MakeFrameGetter", logger)
        self.assertIn('"Logger frame getter factory is not initialized"', logger)
        self.assertIn('local getFrame = MakeModuleFrameGetter(module, "RMALootHistory")', logger)
        self.assertIn('local getAttendanceFrame = MakeFrameGetter(ATTENDANCE_FRAME_NAME)', logger)
        self.assertIn("uiState.FrameName = BindModuleFrame(module, frame, {", logger)
        self.assertIn("attendanceUi.FrameName = BindModuleFrame(nil, frame, {", logger)
        self.assertNotIn("UI.Frames.BindModuleFrame", logger)
        self.assertNotIn("UI.Frames.MakeFrameGetter", logger)
        self.assertNotIn('local getFrame = Frames.MakeModuleFrameGetter', logger)

    def test_shared_ui_frames_does_not_import_database_after_alias_removal(self):
        frames = read(FRAMES)

        self.assertNotIn("local Database = feature.Database", frames)
        self.assertNotIn("Database.MakeModuleFrameGetter", frames)

    def test_shared_ui_frames_depends_on_wotlk_frame_apis_without_optional_globals(self):
        frames = read(FRAMES)

        self.assertIn("local CreateFrame = assert(", frames)
        self.assertIn("_G.CreateFrame", frames)
        self.assertIn('"UI frame creation API is not initialized"', frames)
        self.assertIn("local InCombatLockdown = assert(", frames)
        self.assertIn("_G.InCombatLockdown", frames)
        self.assertIn('"UI combat-lockdown API is not initialized"', frames)
        self.assertNotIn("local CreateFrame = _G.CreateFrame", frames)
        self.assertNotIn("local InCombatLockdown = _G.InCombatLockdown", frames)
        self.assertNotIn("_G.CreateFrame then", frames)

    def test_list_controller_depends_on_wotlk_create_frame_api_without_raw_binding(self):
        list_controller = read(LIST_CONTROLLER)

        self.assertIn("local CreateFrame = assert(", list_controller)
        self.assertIn("_G.CreateFrame", list_controller)
        self.assertIn('"List controller frame creation API is not initialized"', list_controller)
        self.assertNotIn("local CreateFrame = _G.CreateFrame", list_controller)

    def test_master_controller_depends_on_wotlk_create_frame_api_without_fallback_binding(self):
        master = read(MASTER)
        item_selection = read(ITEM_SELECTION)

        self.assertIn("local CreateFrame = assert(", master)
        self.assertIn("_G.CreateFrame", master)
        self.assertIn('"Master controller frame creation API is not initialized"', master)
        self.assertIn('row = CreateFrame("Button", btnName, parent, "RMASelectPlayerTemplate")', master)
        self.assertIn("createFrame = CreateFrame", master)
        self.assertIn('controller.createFrame("Button", btnName, state.frame, "RMAItemSelectionButton")', item_selection)
        self.assertIn('controller.createFrame("Frame", selectionName, frame, "RMAItemSelectionFrame")', item_selection)
        self.assertNotIn("local createFrame = _G.CreateFrame", master)
        self.assertNotIn('type(createFrame) == "function"', master)

    def test_enable_drag_uses_guarded_frame_script_owner(self):
        frames = read(FRAMES)
        start = frames.index("function Frames.EnableDrag(frame, dragButton)")
        end = frames.index("function Popups.DefineConfirm", start)
        enable_drag = frames[start:end]

        self.assertIn('Frames.SetScriptSafely(frame, "OnDragStart", function(self)', enable_drag)
        self.assertIn('Frames.SetScriptSafely(frame, "OnDragStop", function(self)', enable_drag)
        self.assertNotIn('frame:SetScript("OnDragStart"', enable_drag)
        self.assertNotIn('frame:SetScript("OnDragStop"', enable_drag)

    def test_shared_tooltip_bindings_use_guarded_frame_script_owner(self):
        frames = read(FRAMES)
        bind_model_start = frames.index("function Tooltips.BindModel(frame, modelProvider, anchor)")
        bind_start = frames.index("function Tooltips.Bind(frame, text, anchor, title)")
        refresher_start = frames.index("function Frames.MakeEventDrivenRefresher", bind_start)
        bind_model = frames[bind_model_start:bind_start]
        bind = frames[bind_start:refresher_start]

        self.assertIn('Frames.SetScriptSafely(frame, "OnEnter", function(self)', bind_model)
        self.assertIn('Frames.SetScriptSafely(frame, "OnLeave", Tooltips.Hide)', bind_model)
        self.assertNotIn('frame:SetScript("OnEnter"', bind_model)
        self.assertNotIn('frame:SetScript("OnLeave"', bind_model)

        self.assertIn('Frames.SetScriptSafely(frame, "OnEnter", showTooltip)', bind)
        self.assertIn('Frames.SetScriptSafely(frame, "OnLeave", Tooltips.Hide)', bind)
        self.assertNotIn('frame:SetScript("OnEnter"', bind)
        self.assertNotIn('frame:SetScript("OnLeave"', bind)

    def test_bind_module_frame_hook_options_use_guarded_hook_owner(self):
        frames = read(FRAMES)
        start = frames.index("function Frames.BindModuleFrame(module, frame, opts)")
        end = frames.index("local function makeUIFrameController", start)
        bind_module_frame = frames[start:end]

        self.assertIn('Frames.HookScriptSafely(frame, "OnShow", opts.hookOnShow)', bind_module_frame)
        self.assertIn('Frames.HookScriptSafely(frame, "OnHide", opts.hookOnHide)', bind_module_frame)
        self.assertNotIn('frame:HookScript("OnShow"', bind_module_frame)
        self.assertNotIn('frame:HookScript("OnHide"', bind_module_frame)

    def test_edit_box_bindings_use_guarded_frame_script_owner(self):
        frames = read(FRAMES)
        start = frames.index("function EditBoxes.BindHandlers(frameName, specs, requestRefreshFn)")
        end = frames.index("local registry = feature.ModuleRegistry", start)
        bind_handlers = frames[start:end]

        self.assertIn('Frames.SetScriptSafely(editBox, "OnEscapePressed", spec.onEscape)', bind_handlers)
        self.assertIn('Frames.SetScriptSafely(editBox, "OnEnterPressed", spec.onEnter)', bind_handlers)
        self.assertIn('Frames.SetScriptSafely(editBox, "OnEditFocusLost", spec.onFocusLost)', bind_handlers)
        self.assertIn('Frames.SetScriptSafely(editBox, "OnTextChanged", function(_, isUserInput)', bind_handlers)
        self.assertNotIn("editBox:SetScript(", bind_handlers)

    def test_event_driven_refresher_uses_guarded_show_hook_owner(self):
        frames = read(FRAMES)
        start = frames.index("function Frames.MakeEventDrivenRefresher(targetOrGetter, updateFn)")
        end = frames.index("function Frames.MakeFrameGetter", start)
        refresher = frames[start:end]

        self.assertIn('Frames.HookScriptSafely(target, "OnShow", function()', refresher)
        self.assertNotIn('target:HookScript("OnShow"', refresher)

    def test_event_driven_refresher_uses_guarded_driver_update_binding(self):
        frames = read(FRAMES)
        start = frames.index("function Frames.MakeEventDrivenRefresher(targetOrGetter, updateFn)")
        end = frames.index("function Frames.MakeFrameGetter", start)
        refresher = frames[start:end]

        self.assertIn('Frames.SetScriptSafely(driver, "OnUpdate", nil)', refresher)
        self.assertIn('Frames.SetScriptSafely(driver, "OnUpdate", run)', refresher)
        self.assertNotIn('driver:SetScript("OnUpdate"', refresher)

    def test_minimap_scripts_use_shared_frame_binding_owner(self):
        minimap = read(MINIMAP)
        start = minimap.index("local function loadMinimapFrame(frame)")
        end = minimap.index("function module:BindUI()", start)
        load_frame = minimap[start:end]

        self.assertIn('Frames.SetScriptSafely(frame, "OnMouseDown"', load_frame)
        self.assertIn('Frames.SetScriptSafely(self, "OnUpdate", moveButton)', load_frame)
        self.assertIn('Frames.SetScriptSafely(self, "OnUpdate", nil)', load_frame)
        self.assertIn('Frames.SetScriptSafely(frame, "OnClick"', load_frame)
        self.assertIn('Frames.SetScriptSafely(frame, "OnEnter"', load_frame)
        self.assertIn('Frames.SetScriptSafely(frame, "OnLeave"', load_frame)
        self.assertNotIn(":SetScript(", load_frame)
        self.assertNotIn(".SetScript(", load_frame)

    def test_slash_minimap_commands_route_through_minimap_owner(self):
        minimap = read(MINIMAP)
        slash_events = read(SLASH_EVENTS)
        start = slash_events.index("local function handleMinimapCommand(rest)")
        end = slash_events.index("local function handleAchievementCommand", start)
        handle_minimap = slash_events[start:end]

        self.assertIn("function module:SetMinimapButtonShown(show)", minimap)
        self.assertIn("function module:GetPos()", minimap)
        self.assertIn("addon.Minimap:SetMinimapButtonShown(true)", handle_minimap)
        self.assertIn("addon.Minimap:SetMinimapButtonShown(false)", handle_minimap)
        self.assertIn("addon.Minimap:GetPos()", handle_minimap)
        self.assertNotIn('setOption("Minimap", "minimapButton"', handle_minimap)
        self.assertNotIn("Frames.SetShown(RMA_MINIMAP_GUI", handle_minimap)

    def test_slash_events_declares_minimap_owner_dependency(self):
        toc = read(TOC)
        slash_events = read(SLASH_EVENTS)
        start = slash_events.index('registry.AddModule("EntryPoints/SlashEvents"')
        registry = slash_events[start:]

        self.assertLess(toc.index("EntryPoints\\Minimap.lua"), toc.index("EntryPoints\\SlashEvents.lua"))
        self.assertIn('"EntryPoints/Minimap"', registry)

    def test_slash_events_registry_omits_unused_frame_dependency(self):
        slash_events = read(SLASH_EVENTS)
        start = slash_events.index('registry.AddModule("EntryPoints/SlashEvents"')
        registry = slash_events[start:]

        self.assertNotIn("local Frames = UI.Frames", slash_events)
        self.assertNotIn("UI.Frames", slash_events)
        self.assertNotIn('"Modules/UI/Frames"', registry)
        self.assertIn('"Modules/UI/Facade"', registry)

    def test_slash_events_uses_declared_widget_facade_without_optional_dispatch_guards(self):
        slash_events = read(SLASH_EVENTS)

        self.assertIn('local UIWidgets = assert(UI.Widgets, "Slash widget facade is not initialized")', slash_events)
        self.assertIn(
            'local IsWidgetEnabled = assert(UIWidgets.IsEnabled, "Slash widget enabled resolver is not initialized")',
            slash_events,
        )
        self.assertIn(
            'local IsWidgetRegistered = assert(UIWidgets.IsRegistered, "Slash widget registration resolver is not initialized")',
            slash_events,
        )
        self.assertIn(
            'local CallWidgetMethod = assert(UIWidgets.CallMethod, "Slash widget method dispatcher is not initialized")',
            slash_events,
        )
        self.assertIn("if not IsWidgetEnabled(widgetId) then", slash_events)
        self.assertIn("if not IsWidgetRegistered(widgetId) then", slash_events)
        self.assertIn("return CallWidgetMethod(widgetId, methodName, ...)", slash_events)
        self.assertNotIn("UIWidgets and type(UIWidgets.IsEnabled)", slash_events)
        self.assertNotIn("UIWidgets and type(UIWidgets.IsRegistered)", slash_events)
        self.assertNotIn("UIWidgets and type(UIWidgets.Call)", slash_events)
        self.assertNotIn("UIWidgets.Call(", slash_events)

    def test_trade_menu_registry_omits_unused_frame_dependency(self):
        trade_menu = read(TRADE_MENU)
        start = trade_menu.index('registry.AddModule("Widgets/TradeMenu"')
        registry = trade_menu[start:]

        self.assertNotIn("local Frames = UI.Frames", trade_menu)
        self.assertNotIn("UI.Frames", trade_menu)
        self.assertNotIn('"Modules/UI/Frames"', registry)
        self.assertIn('"Modules/UI/Facade"', registry)
        self.assertIn('"Services/Master/Trade"', registry)

    def test_trade_menu_uses_declared_ui_widget_facade_owner(self):
        trade_menu = read(TRADE_MENU)

        self.assertIn("local UIWidgets = UI.Widgets", trade_menu)
        self.assertIn('UIWidgets.Register("TradeMenu", module)', trade_menu)
        self.assertIn('UIWidgets.RegisterFunction("TradeMenu", "HideDropdowns", module.HideDropdowns)', trade_menu)
        self.assertIn('UIWidgets.RegisterFunction("TradeMenu", "RefreshDropdowns", module.RefreshDropdowns)', trade_menu)
        self.assertIn('UIWidgets.RegisterFunction("TradeMenu", "RefreshCandidate", module.RefreshCandidate)', trade_menu)
        self.assertIn('UIWidgets.IsEnabled("TradeMenu")', trade_menu)
        self.assertNotIn("UI and UI.Widgets or nil", trade_menu)
        self.assertNotIn("if UIWidgets and UIWidgets.IsEnabled then", trade_menu)
        self.assertNotIn("if UIWidgets.Register then", trade_menu)

    def test_loot_hints_uses_declared_ui_widget_facade_owner(self):
        loot_hints = read(LOOT_HINTS)
        start = loot_hints.index('registry.AddModule("Widgets/LootHints"')
        registry = loot_hints[start:]

        self.assertIn('"Modules/UI/Facade"', registry)
        self.assertIn("local UIWidgets = UI.Widgets", loot_hints)
        self.assertIn('if not UIWidgets.IsEnabled("LootHints") then', loot_hints)
        self.assertIn('UIWidgets.Register("LootHints", module)', loot_hints)
        self.assertIn(
            'UIWidgets.RegisterFunction("LootHints", "ApplyLootFrameReserveHints", module.ApplyLootFrameReserveHints)',
            loot_hints,
        )
        self.assertIn(
            'UIWidgets.RegisterFunction("LootHints", "ClearLootFrameReserveHints", module.ClearLootFrameReserveHints)',
            loot_hints,
        )
        self.assertIn(
            'UIWidgets.RegisterFunction("LootHints", "EnsureLootFrameHooks", module.EnsureLootFrameHooks)',
            loot_hints,
        )
        self.assertNotIn("UIWidgets and UIWidgets.IsEnabled", loot_hints)
        self.assertNotIn("UIWidgets and UIWidgets.Register", loot_hints)

    def test_raid_grid_uses_declared_ui_widget_facade_owner(self):
        raid_grid = read(ADDON / "Widgets" / "RaidGrid.lua")
        start = raid_grid.index('registry.AddModule("Widgets/RaidGrid"')
        registry = raid_grid[start:]

        self.assertIn('"Modules/UI/Facade"', registry)
        self.assertIn("local UIWidgets = UI.Widgets", raid_grid)
        self.assertIn('if not UIWidgets.IsEnabled("RaidGrid") then', raid_grid)
        self.assertIn('UIWidgets.Register("RaidGrid", module)', raid_grid)
        self.assertIn('UIWidgets.RegisterFunction("RaidGrid", "ShowPicker", module.ShowPicker)', raid_grid)
        self.assertIn('UIWidgets.RegisterFunction("RaidGrid", "Hide", module.Hide)', raid_grid)
        self.assertIn('UIWidgets.RegisterFunction("RaidGrid", "IsShown", module.IsShown)', raid_grid)
        self.assertIn('UIWidgets.RegisterFunction("RaidGrid", "GetMode", module.GetMode)', raid_grid)
        self.assertNotIn("UIWidgets and UIWidgets.IsEnabled", raid_grid)
        self.assertNotIn("UIWidgets and UIWidgets.Register", raid_grid)

    def test_raid_grid_depends_on_wotlk_create_frame_api_without_button_fallback(self):
        raid_grid = read(ADDON / "Widgets" / "RaidGrid.lua")

        self.assertIn("local CreateFrame = assert(", raid_grid)
        self.assertIn("_G.CreateFrame", raid_grid)
        self.assertIn('"RaidGrid button creation API is not initialized"', raid_grid)
        self.assertIn('button = CreateFrame("Button", buttonName, frame, "RMARaidGridButtonTemplate")', raid_grid)
        self.assertNotIn("if not button and _G.CreateFrame then", raid_grid)
        self.assertNotIn("_G.CreateFrame(", raid_grid)

    def test_raid_grid_frame_title_uses_shared_frame_owner_without_global_fallback(self):
        raid_grid = read(ADDON / "Widgets" / "RaidGrid.lua")

        self.assertIn("local SetFrameTitle = assert(Frames.SetFrameTitle", raid_grid)
        self.assertIn('"RaidGrid frame title service is not initialized"', raid_grid)
        self.assertIn('SetFrameTitle(frame, L.StrRaidGridSelectorTitle or "Grid Selector")', raid_grid)
        self.assertNotIn("if Frames and Frames.SetFrameTitle then", raid_grid)
        self.assertNotIn('safeCall(_G.RMARaidGridFrameTitle, "SetText"', raid_grid)

    def test_trade_menu_depends_on_wotlk_trade_item_link_api_without_local_fallback(self):
        trade_menu = read(TRADE_MENU)

        self.assertIn("local GetTradePlayerItemLink = assert(", trade_menu)
        self.assertIn("_G.GetTradePlayerItemLink", trade_menu)
        self.assertIn('"Trade menu item link API is not initialized"', trade_menu)
        self.assertNotIn('type(GetTradePlayerItemLink) == "function" and GetTradePlayerItemLink(slot) or nil', trade_menu)

    def test_trade_menu_depends_on_wotlk_unit_name_api_without_partner_resolution_fallback(self):
        trade_menu = read(TRADE_MENU)

        self.assertIn("local UnitName = assert(", trade_menu)
        self.assertIn("_G.UnitName", trade_menu)
        self.assertIn('"Trade menu unit name API is not initialized"', trade_menu)
        self.assertNotIn('type(UnitName) == "function"', trade_menu)

    def test_trade_menu_depends_on_wotlk_create_frame_api_without_dropdown_fallback(self):
        trade_menu = read(TRADE_MENU)

        self.assertIn("local CreateFrame = assert(", trade_menu)
        self.assertIn("_G.CreateFrame", trade_menu)
        self.assertIn('"Trade menu frame creation API is not initialized"', trade_menu)
        self.assertIn("local UIParent = assert(", trade_menu)
        self.assertIn("_G.UIParent", trade_menu)
        self.assertIn('"Trade menu root UI parent is not initialized"', trade_menu)
        self.assertNotIn('type(CreateFrame) == "function" and CreateFrame or nil', trade_menu)
        self.assertNotIn("_G.TradeFrame or _G.UIParent", trade_menu)
        self.assertNotIn("if not dropdown and not base then", trade_menu)

    def test_config_minimap_checkbox_sets_owner_state_directly(self):
        toc = read(TOC)
        config = read(CONFIG)
        start = config.index("local function onOptionClick(btn, frameName)")
        end = config.index("local function bindInterfaceOptionsPanel(panel)", start)
        on_option_click = config[start:end]
        registry_start = config.index('registry.AddModule("Widgets/Config"')
        registry = config[registry_start:]

        self.assertLess(toc.index("EntryPoints\\Minimap.lua"), toc.index("Widgets\\Config.lua"))
        self.assertIn("addon.Minimap:SetMinimapButtonShown(value)", on_option_click)
        self.assertNotIn("addon.Minimap:ToggleMinimapButton()", on_option_click)
        self.assertIn('"EntryPoints/Minimap"', registry)

    def test_minimap_owner_does_not_keep_obsolete_toggle_wrapper(self):
        minimap = read(MINIMAP)

        self.assertIn("function module:SetMinimapButtonShown(show)", minimap)
        self.assertNotIn("function module:ToggleMinimapButton()", minimap)
        self.assertNotIn("self:SetMinimapButtonShown(nextValue)", minimap)

    def test_minimap_menu_avoids_private_pass_through_routing_wrappers(self):
        minimap = read(MINIMAP)

        self.assertNotIn("local function getRaidService()", minimap)
        self.assertNotIn("local function callControllerMethod(", minimap)
        self.assertNotIn("local function toggleLootCounterWidget()", minimap)
        self.assertIn("local Raid = assert(Services.Raid", minimap)
        self.assertIn('"Services/Raid/State"', minimap)
        self.assertIn('"Services/Raid/Capabilities"', minimap)
        self.assertIn('Database.RequestControllerMethod("Master", "Toggle")', minimap)
        self.assertIn('callWidgetMethod("LootCounter", "Toggle")', minimap)

    def test_widget_facade_separates_method_and_function_calls(self):
        facade = read(ADDON / "Modules" / "UI" / "Facade.lua")

        self.assertIn("local function registerCallable(widgetId, methodName, fn, style)", facade)
        self.assertIn("local function getWidgetFunction(widgetId, methodName, style)", facade)
        self.assertIn("function Widgets.RegisterMethod(widgetId, methodName, fn)", facade)
        self.assertIn("function Widgets.RegisterFunction(widgetId, methodName, fn)", facade)
        self.assertIn("function Widgets.CallMethod(widgetId, methodName, ...)", facade)
        self.assertIn("function Widgets.CallFunction(widgetId, methodName, ...)", facade)
        self.assertIn('local fn, api = getWidgetFunction(widgetId, methodName, "method")', facade)
        self.assertIn('local fn = getWidgetFunction(widgetId, methodName, "function")', facade)
        self.assertIn("return fn(api, ...)", facade)
        self.assertIn("return fn(...)", facade)
        self.assertNotIn("function Widgets.Call(", facade)
        self.assertNotIn("SELF_METHODS", facade)
        self.assertNotIn("methodName] == true", facade)

    def test_widget_call_sites_use_explicit_method_or_function_dispatch(self):
        runtime_files = [
            path
            for path in ADDON.rglob("*.lua")
            if "Libs" not in path.parts
        ]
        for path in runtime_files:
            src = read(path)
            with self.subTest(path=path.relative_to(ADDON)):
                self.assertNotIn("UI.Widgets.Call(", src)
                self.assertNotIn("UIWidgets.Call(", src)

        master = read(MASTER)
        minimap = read(MINIMAP)
        slash_events = read(SLASH_EVENTS)
        reserves_ui = read(RESERVES_UI)

        for call in (
            'UI.Widgets.CallMethod("Config", "Toggle")',
            'UI.Widgets.CallMethod("LootCounter", "AttachToMaster", frame)',
            'UI.Widgets.CallMethod("Reserves", "Toggle")',
            'UI.Widgets.CallMethod("Reserves", "ToggleImport")',
            'UI.Widgets.CallMethod("LootCounter", "Toggle")',
        ):
            self.assertIn(call, master)

        for call in (
            'UI.Widgets.CallFunction("LootHints", "EnsureLootFrameHooks")',
			'UI.Widgets.CallFunction("TradeMenu", "HideDropdowns")',
			'UI.Widgets.CallFunction("TradeMenu", "RefreshDropdowns", manualState)',
			'UI.Widgets.CallFunction("TradeMenu", "RefreshCandidate", "TRADE_SHOW")',
			'UI.Widgets.CallFunction("RaidGrid", "ShowPicker", {',
			'UI.Widgets.CallFunction("RaidGrid", "Hide")',
			'UI.Widgets.CallFunction("RaidGrid", "IsShown")',
			'UI.Widgets.CallFunction("RaidGrid", "GetMode")',
            'UI.Widgets.CallFunction("LootHints", "ApplyLootFrameReserveHints")',
        ):
            self.assertIn(call, master)

        self.assertIn("return UIWidgets.CallMethod(widgetId, methodName, ...)", minimap)
        self.assertIn("return CallWidgetMethod(widgetId, methodName, ...)", slash_events)
        self.assertIn('UIWidgets.CallMethod("Reserves", "ToggleImport")', reserves_ui)

    def test_slash_events_routes_controllers_without_private_pass_through_wrapper(self):
        slash_events = read(SLASH_EVENTS)

        self.assertNotIn("local function callControllerMethod(", slash_events)
        self.assertNotIn("callControllerMethod(", slash_events)
        self.assertIn('Database.RequestControllerMethod("Master", "ShowDebugRaidGrid", count or 25)', slash_events)
        self.assertIn('Database.RequestControllerMethod("Warnings", "Toggle")', slash_events)
        self.assertIn('Database.RequestControllerMethod("Spammer", "RequestStart")', slash_events)

    def test_slash_events_uses_item_module_without_private_pass_through_wrapper(self):
        slash_events = read(SLASH_EVENTS)

        self.assertNotIn("local function getItemModule()", slash_events)
        self.assertNotIn("getItemModule()", slash_events)
        self.assertIn("local itemModule = Item", slash_events)

    def test_config_panel_routes_controllers_without_private_pass_through_wrapper(self):
        config = read(CONFIG)

        self.assertNotIn("local function requestController(", config)
        self.assertNotIn("requestController(", config)
        self.assertNotIn("if Database and Database.RequestControllerMethod then", config)
        self.assertIn('Database.RequestControllerMethod("Logger", "RequestRefresh", "maintenance")', config)
        self.assertIn('Database.RequestControllerMethod("Spammer", "RequestStart")', config)
        self.assertIn('Database.RequestControllerMethod("Warnings", "RequestTemplatePreview")', config)

    def test_config_logger_panel_uses_logger_owners_without_private_accessors(self):
        config = read(CONFIG)

        self.assertNotIn("local function getLoggerActions()", config)
        self.assertNotIn("getLoggerActions()", config)
        self.assertNotIn("local function getLoggerSyncer()", config)
        self.assertNotIn("getLoggerSyncer()", config)
        self.assertIn('"Database/DB"', config)
        self.assertIn('"Database/DBSyncer"', config)
        self.assertIn('"Services/Raid/State"', config)
        self.assertIn('"Services/Logger/Actions"', config)
        self.assertIn("local actions = Services.Logger.Actions", config)
        self.assertNotIn("local actions = Services and Services.Logger and Services.Logger.Actions or nil", config)
        self.assertIn("local syncer = Database.GetSyncer()", config)
        self.assertIn("local currentRaid = Database.GetCurrentRaid()", config)
        self.assertNotIn("Database.GetSyncer and Database.GetSyncer()", config)
        self.assertNotIn("Database.GetCurrentRaid and Database.GetCurrentRaid()", config)

    def test_config_options_reads_use_dboptions_key_index_without_local_fallback(self):
        config = read(CONFIG)

        self.assertIn('"Database/DBOptions"', config)
        self.assertIn("local GetOptionByKey = Options.GetByKey", config)
        self.assertNotIn("local GetOptionByKey = Options.GetByKey\n\t\tor function", config)
        self.assertNotIn("local GetOptionByKey = Options.GetByKey\r\n\t\tor function", config)

    def test_config_options_writes_use_dboptions_key_index_without_local_helper(self):
        config = read(CONFIG)

        self.assertIn('"Database/DBOptions"', config)
        self.assertNotIn("local function getOptionConfig(key)", config)
        self.assertNotIn("local function setOption(key, value)", config)
        self.assertIn('Options.Set("autoSpamSoftResOnLootOpened", false)', config)
        self.assertIn("Options.Set(key, value)", config)

    def test_config_options_layout_uses_stable_cfg_without_private_factory(self):
        config = read(CONFIG)

        self.assertNotIn("local function getOptionsPanelLayoutCfg()", config)
        self.assertNotIn("getOptionsPanelLayoutCfg()", config)
        self.assertIn('local Layout = assert(UI.Layout, "Config options layout owner is not initialized")', config)
        self.assertIn(
            'local ApplyOptionsRows = assert(Layout.ApplyRows, "Config options row layout applier is not initialized")',
            config,
        )
        self.assertIn("return ApplyOptionsRows(frameName, rows, cfg)", config)
        self.assertNotIn("if Layout and Layout.ApplyRows then", config)
        self.assertNotIn("return Layout.ApplyRows(frameName, rows, cfg)", config)
        self.assertNotIn("return 0", config)
        self.assertIn("local optionsPanelLayoutCfg = {", config)
        self.assertGreaterEqual(config.count("applyOptionsLayout("), 6)
        self.assertGreaterEqual(config.count("optionsPanelLayoutCfg"), 5)

    def test_config_option_click_resolves_frame_without_private_helper(self):
        config = read(CONFIG)
        start = config.index("local function onOptionClick(btn, frameName)")
        end = config.index("local function bindConfigHandlers(frameName, refs, includeClose)", start)
        on_option_click = config[start:end]

        self.assertNotIn("local function getButtonFrameName", config)
        self.assertNotIn("getButtonFrameName(", config)
        self.assertIn("local parent = btn:GetParent()", on_option_click)
        self.assertIn("frameName = parent and parent.GetName and parent:GetName() or nil", on_option_click)

    def test_config_logger_quality_uses_dboptions_normalizer_without_local_fallback(self):
        config = read(CONFIG)

        self.assertIn('"Database/DBOptions"', config)
        self.assertIn("local NormalizeLoggerLootQualityThreshold = Options.NormalizeLoggerLootQualityThreshold", config)
        self.assertNotIn("local normalizeLoggerLootQualityThreshold = Options.NormalizeLoggerLootQualityThreshold", config)
        self.assertNotIn("loggerLootQualityOptions[i].value == threshold", config)

    def test_warnings_frame_hooks_use_shared_hook_owner(self):
        frames = read(FRAMES)
        warnings = read(WARNINGS)
        start = warnings.index("local function BindHandlers(_, frame, refs)")
        end = warnings.index("Frames.SetScriptSafely(refs.announceBtn", start)
        bind_handlers = warnings[start:end]

        self.assertRegex(frames, r"function\s+Frames\.HookScriptSafely\s*\(")
        self.assertIn('Frames.HookScriptSafely(frame, "OnShow"', bind_handlers)
        self.assertIn('Frames.HookScriptSafely(frame, "OnHide"', bind_handlers)
        self.assertNotIn("frame:HookScript", bind_handlers)
        self.assertNotIn("if frame.HookScript then", bind_handlers)

    def test_loot_hints_tooltip_hooks_use_shared_hook_owner(self):
        loot_hints = read(LOOT_HINTS)
        start = loot_hints.index("local function bindLootFrameButtonTooltip")
        end = loot_hints.index("-- ----- Public methods ----- --", start)
        bind_tooltip = loot_hints[start:end]

        self.assertIn("local Frames = UI.Frames", loot_hints)
        self.assertIn("local SetScriptSafely = assert(Frames.SetScriptSafely", loot_hints)
        self.assertIn('"Loot hints frame script binder is not initialized"', loot_hints)
        self.assertIn("local HookScriptSafely = assert(Frames.HookScriptSafely", loot_hints)
        self.assertIn('"Loot hints frame hook binder is not initialized"', loot_hints)
        self.assertIn("local HideTooltip = assert(Tooltips.Hide", loot_hints)
        self.assertIn('"Loot hints tooltip hider is not initialized"', loot_hints)
        self.assertIn('HookScriptSafely(button, "OnEnter", showLootItemTooltip)', bind_tooltip)
        self.assertIn('HookScriptSafely(button, "OnLeave", HideTooltip)', bind_tooltip)
        self.assertIn('SetScriptSafely(frame, "OnEnter", showLootItemTooltip)', loot_hints)
        self.assertNotIn("UI.Frames.SetScriptSafely", loot_hints)
        self.assertNotIn("UI.Frames.HookScriptSafely", loot_hints)
        self.assertNotIn("UI.Tooltips.Hide", loot_hints)
        self.assertNotIn("button:HookScript", bind_tooltip)
        self.assertNotIn("if button.HookScript then", bind_tooltip)

    def test_loot_counter_row_and_master_bindings_use_shared_frame_owner(self):
        loot_counter = read(LOOT_COUNTER)
        start = loot_counter.index("local function ensureRow(i, rowHeight)")
        end = loot_counter.index("local function announceCounts()", start)
        row_and_attach = loot_counter[start:end]

        self.assertIn('Frames.SetScriptSafely(sec.plus, "OnClick"', row_and_attach)
        self.assertIn('Frames.SetScriptSafely(sec.minus, "OnClick"', row_and_attach)
        self.assertIn('Frames.SetScriptSafely(row.reset, "OnClick"', row_and_attach)
        self.assertIn('Frames.HookScriptSafely(frame, "OnHide"', row_and_attach)
        self.assertNotIn(":SetScript(", row_and_attach)
        self.assertNotIn(":HookScript(", row_and_attach)

    def test_loot_counter_header_documents_stable_ui_ownership(self):
        loot_counter = read(LOOT_COUNTER)
        header = loot_counter.split("\nlocal addon = select(2, ...)", 1)[0]

        self.assertNotIn("temporary exception", header)
        self.assertNotIn("rolled back", header)
        self.assertNotIn("migration is reintroduced", header)
        self.assertIn("XML owns the top-level LootCounter frame", header)
        self.assertIn("Lua owns dynamic LootCounter section, header, and row construction", header)

    def test_reserves_header_bindings_use_shared_frame_owner(self):
        reserves_ui = read(RESERVES_UI)
        start = reserves_ui.index("local function createReserveHeader(parent, info, yOffset, index)")
        end = reserves_ui.index("local function createReserveRow(parent, itemInfo, playerInfo, yOffset, index)", start)
        header_block = reserves_ui[start:end]

        self.assertIn('Frames.SetScriptSafely(header.collapseButton, "OnClick", reserveHeaderOnClick)', header_block)
        self.assertIn('Frames.SetScriptSafely(header.itemIconHotspot, "OnEnter", reserveHeaderHotspotOnEnter)', header_block)
        self.assertIn('Frames.SetScriptSafely(header.itemIconHotspot, "OnLeave", reserveHeaderHotspotOnLeave)', header_block)
        self.assertIn('Frames.SetScriptSafely(header.itemIconHotspot, "OnClick", reserveHeaderHotspotOnClick)', header_block)
        self.assertIn('Frames.SetScriptSafely(header.itemNameHotspot, "OnEnter", reserveHeaderHotspotOnEnter)', header_block)
        self.assertIn('Frames.SetScriptSafely(header.itemNameHotspot, "OnLeave", reserveHeaderHotspotOnLeave)', header_block)
        self.assertIn('Frames.SetScriptSafely(header.itemNameHotspot, "OnClick", reserveHeaderHotspotOnClick)', header_block)
        self.assertIn('Frames.SetScriptSafely(header, "OnClick", nil)', header_block)
        self.assertNotIn(":SetScript(", header_block)

    def test_reserves_player_row_bindings_use_shared_frame_owner(self):
        reserves_ui = read(RESERVES_UI)
        start = reserves_ui.index("local function createReserveRow(parent, itemInfo, playerInfo, yOffset, index)")
        end = reserves_ui.index("local function renderReserveListUI()", start)
        row_block = reserves_ui[start:end]

        self.assertIn('Frames.SetScriptSafely(row.removeButton, "OnEnter", nil)', row_block)
        self.assertIn('Frames.SetScriptSafely(row.removeButton, "OnLeave", nil)', row_block)
        self.assertIn('Frames.SetScriptSafely(row.removeButton, "OnClick"', row_block)
        self.assertIn('Frames.SetScriptSafely(row.quantityEdit, "OnEnterPressed"', row_block)
        self.assertIn('Frames.SetScriptSafely(row.quantityEdit, "OnEscapePressed"', row_block)
        self.assertNotIn(":SetScript(", row_block)

    def test_reserves_main_control_bindings_use_shared_frame_owner(self):
        reserves_ui = read(RESERVES_UI)
        start = reserves_ui.index("local function BindHandlers(_, _, refs)")
        end = reserves_ui.index("local function loadReservesFrame(frame)", start)
        bind_handlers = reserves_ui[start:end]

        self.assertIn('Frames.SetScriptSafely(refs.whisperHelpButton, "OnClick"', bind_handlers)
        self.assertIn('Frames.SetScriptSafely(refs.clearBtn, "OnClick"', bind_handlers)
        self.assertIn('Frames.SetScriptSafely(refs.editButton, "OnClick"', bind_handlers)
        self.assertIn('Frames.SetScriptSafely(refs.queryButton, "OnClick"', bind_handlers)
        self.assertIn('Frames.SetScriptSafely(refs.importButton, "OnClick"', bind_handlers)
        self.assertIn('Frames.SetScriptSafely(refs.softResAccept, "OnClick"', bind_handlers)
        self.assertIn('Frames.SetScriptSafely(refs.softResResponseWisp, "OnClick"', bind_handlers)
        self.assertNotIn(":SetScript(", bind_handlers)

    def test_reserves_item_info_refresh_event_uses_shared_frame_owner(self):
        reserves_ui = read(RESERVES_UI)
        start = reserves_ui.index("local function loadReservesFrame(frame)")
        end = reserves_ui.index("local function OnLoadFrame(frame)", start)
        load_frame = reserves_ui[start:end]

        self.assertIn('refreshFrame:RegisterEvent("GET_ITEM_INFO_RECEIVED")', load_frame)
        self.assertIn('Frames.SetScriptSafely(refreshFrame, "OnEvent"', load_frame)
        self.assertNotIn('refreshFrame:SetScript("OnEvent"', load_frame)

    def test_config_interface_panel_hooks_use_shared_hook_owner(self):
        config = read(CONFIG)
        start = config.index("local function bindInterfaceOptionsPanel(panel)")
        end = config.index("local function OnLoadFrame(frame)", start)
        interface_panel_bindings = config[start:end]

        self.assertEqual(interface_panel_bindings.count('Frames.HookScriptSafely(panel, "OnShow"'), 6)
        self.assertNotIn('panel:HookScript("OnShow"', interface_panel_bindings)

    def test_config_interface_panel_registration_depends_on_wotlk_options_api_without_silent_fallback(self):
        config = read(CONFIG)
        start = config.index("local function registerInterfaceOptionsPanel()")
        end = config.index("local function OnLoadFrame(frame)", start)
        registration = config[start:end]

        self.assertIn("local InterfaceOptions_AddCategory =", config)
        self.assertIn("assert(_G.InterfaceOptions_AddCategory", config)
        self.assertIn("_G.InterfaceOptions_AddCategory", config)
        self.assertIn('"Config interface options registration API is not initialized"', config)
        self.assertIn("InterfaceOptions_AddCategory(panel)", registration)
        self.assertNotIn("local addCategory = _G.InterfaceOptions_AddCategory", registration)
        self.assertNotIn('if type(addCategory) ~= "function" then', registration)

    def test_master_dropdown_hooks_use_shared_hook_owner(self):
        master = read(MASTER)
        start = master.index("local function hookDropDownOpen(frame, targetKey)")
        end = master.index("Private.PrepareDropDowns = function()", start)
        dropdown_hook = master[start:end]

        self.assertIn("local Frames = UI.Frames", master)
        self.assertIn('Frames.HookScriptSafely(button, "OnClick"', dropdown_hook)
        self.assertIn("button._RMAHooked = true", dropdown_hook)
        self.assertNotIn('button:HookScript("OnClick"', dropdown_hook)

    def test_master_frame_bindings_use_local_shared_frame_owner_bindings(self):
        master = read(MASTER)
        item_selection = read(ITEM_SELECTION)

        self.assertIn("local GetFrameRef = assert(Frames.GetRef", master)
        self.assertIn('"Master frame ref resolver is not initialized"', master)
        self.assertIn("local SetScriptSafely = assert(Frames.SetScriptSafely", master)
        self.assertIn('"Master frame script binder is not initialized"', master)
        self.assertIn("local BindModuleFrame = assert(Frames.BindModuleFrame", master)
        self.assertIn('"Master module frame binder is not initialized"', master)
        self.assertIn("local MakeModuleFrameGetter =", master)
        self.assertIn("assert(Frames.MakeModuleFrameGetter", master)
        self.assertIn('"Master module frame getter factory is not initialized"', master)
        self.assertIn("local SetFrameTitle = assert(Frames.SetFrameTitle", master)
        self.assertIn('"Master frame title binder is not initialized"', master)
        self.assertIn('local getFrame = MakeModuleFrameGetter(module, "RMAMaster")', master)
        self.assertIn('configBtn = GetFrameRef(frame, "ConfigBtn")', master)
        self.assertIn("getNamedParts = Frames.GetNamedParts", master)
        self.assertIn("return controller.getNamedParts(button, {", item_selection)
        self.assertIn('SetScriptSafely(itemBtn, "OnClick"', master)
        self.assertIn("uiState.FrameName = BindModuleFrame(module, frame, {", master)
        self.assertIn("SetFrameTitle(frameName, L.StrLootMaster)", master)
        self.assertNotIn("UI.Frames.GetRef", master)
        self.assertNotIn("UI.Frames.SetScriptSafely", master)
        self.assertNotIn("UI.Frames.BindModuleFrame", master)
        self.assertNotIn("UI.Frames.SetFrameTitle", master)
        self.assertNotIn('local getFrame = Frames.MakeModuleFrameGetter', master)

    def test_master_roll_list_uses_declared_list_controller_without_optional_guard(self):
        master = read(MASTER)

        self.assertIn("local Lists = assert(UI.Lists", master)
        self.assertIn('"Master list controller namespace is not initialized"', master)
        self.assertIn("local CreateListController = assert(Lists.CreateController", master)
        self.assertIn('"Master roll list controller factory is not initialized"', master)
        self.assertIn("local CreateRowRenderer = assert(Lists.CreateRowRenderer", master)
        self.assertIn('"Master roll row renderer factory is not initialized"', master)
        self.assertIn("local MakeIndexedRowName = assert(Lists.MakeIndexedRowName", master)
        self.assertIn('"Master indexed row-name factory is not initialized"', master)
        self.assertIn("module._rollListController = CreateListController({", master)
        self.assertIn('rowName = MakeIndexedRowName("PlayerBtn")', master)
        self.assertIn("drawRow = CreateRowRenderer(drawRollRow)", master)
        self.assertNotIn("if UI.Lists and UI.Lists.CreateController", master)
        self.assertNotIn("UI.Lists.CreateController", master)
        self.assertNotIn("UI.Lists.CreateRowRenderer", master)
        self.assertNotIn("UI.Lists.MakeIndexedRowName", master)

    def test_visuals_row_click_binding_depends_on_shared_frame_owner(self):
        toc = read(TOC)
        visuals = read(VISUALS)
        start = visuals.index("function Rows.DrawMasterRollRow(row, data, onClick)")
        row_name_match = re.search(r"\n\s*row\.playerName = data\.name", visuals[start:])
        self.assertIsNotNone(row_name_match)
        end = start + row_name_match.start()
        row_click_binding = visuals[start:end]

        self.assertLess(toc.index("Modules\\UI\\Frames.lua"), toc.index("Modules\\UI\\Visuals.lua"))
        self.assertRegex(visuals, r"registry\.AddModule\(\s*\"Modules/UI/Visuals\"")
        self.assertIn('"Modules/UI/Frames"', visuals)
        self.assertEqual(visuals.count("local Frames = UI.Frames"), 1)
        self.assertIn("local Frames = UI.Frames", visuals)
        self.assertIn('Frames.SetScriptSafely(row, "OnClick", onClick)', row_click_binding)
        self.assertNotIn("row:SetScript", row_click_binding)
        self.assertNotIn("if Frames and Frames.SetScriptSafely then", row_click_binding)

    def test_list_controller_frame_bindings_use_shared_frame_owner(self):
        list_controller = read(LIST_CONTROLLER)
        start = list_controller.index("function Lists.CreateController(cfg)")
        end = list_controller.index("fetchRows = function()", start)
        controller_bindings = list_controller[start:end]

        self.assertIn('"Modules/UI/Frames"', list_controller)
        self.assertIn('Frames.SetScriptSafely(defer, "OnUpdate"', controller_bindings)
        self.assertIn('Frames.HookScriptSafely(frame, "OnShow"', controller_bindings)
        self.assertIn('Frames.HookScriptSafely(frame, "OnHide"', controller_bindings)
        self.assertNotIn(":SetScript(", controller_bindings)
        self.assertNotIn(":HookScript(", controller_bindings)

    def test_effects_resize_hook_uses_shared_hook_owner_without_hiding_drivers(self):
        toc = read(TOC)
        effects = read(EFFECTS)
        start = effects.index("local function ensureGlow(button)")
        end = effects.index("function Effects.SetButtonGlow", start)
        ensure_glow = effects[start:end]

        self.assertLess(toc.index("Modules\\UI\\Frames.lua"), toc.index("Modules\\UI\\Effects.lua"))
        self.assertIn("local Frames = UI.Frames", effects)
        self.assertIn('"Modules/UI/Frames"', effects)
        self.assertIn('Frames.HookScriptSafely(button, "OnSizeChanged"', ensure_glow)
        self.assertNotIn('button:HookScript("OnSizeChanged"', ensure_glow)
        self.assertIn('local SetScriptSafely = assert(Frames.SetScriptSafely, "Effects frame script binder is not initialized")', effects)
        self.assertIn('SetScriptSafely(glow.procFrame, "OnUpdate", nil)', effects)
        self.assertIn('SetScriptSafely(procFrame, "OnUpdate", onProcGlowUpdate)', effects)
        self.assertIn('SetScriptSafely(frame, "OnUpdate", nil)', effects)
        self.assertIn('SetScriptSafely(frame, "OnUpdate", onTimedFadeUpdate)', effects)
        self.assertNotIn(':SetScript("OnUpdate"', effects)

    def test_widget_registration_uses_feature_module_api_without_pass_through_tables(self):
        frames = read(FRAMES)
        loot_counter = read(LOOT_COUNTER)
        config = read(CONFIG)
        reserves_ui = read(RESERVES_UI)

        self.assertNotIn("function Scaffold.CreateWidgetApi", frames)
        self.assertNotIn("Scaffold.CreateWidgetApi", loot_counter)
        self.assertNotIn("Scaffold.CreateWidgetApi", config)
        self.assertNotIn("Scaffold.CreateWidgetApi", reserves_ui)

        self.assertIn("function module:AttachToMaster(masterFrame)", loot_counter)
        self.assertIn('UIWidgets.Register("LootCounter", module)', loot_counter)
        self.assertIn('UIWidgets.RegisterMethod("LootCounter", "Toggle", module.Toggle)', loot_counter)
        self.assertIn('UIWidgets.RegisterMethod("LootCounter", "AttachToMaster", module.AttachToMaster)', loot_counter)
        self.assertNotIn('UIWidgets.Register("LootCounter", {', loot_counter)

        self.assertIn("function module:Default()", config)
        self.assertIn('UIWidgets.Register("Config", module)', config)
        self.assertIn('UIWidgets.RegisterMethod("Config", "Toggle", module.Toggle)', config)
        self.assertIn('UIWidgets.RegisterMethod("Config", "Default", module.Default)', config)
        self.assertNotIn('UIWidgets.Register("Config", {', config)

        self.assertIn("function module:ToggleImport()", reserves_ui)
        self.assertIn("function module:HideImport()", reserves_ui)
        self.assertIn('UIWidgets.Register("Reserves", module)', reserves_ui)
        self.assertIn('UIWidgets.RegisterMethod("Reserves", "Toggle", module.Toggle)', reserves_ui)
        self.assertIn('UIWidgets.RegisterMethod("Reserves", "ToggleImport", module.ToggleImport)', reserves_ui)
        self.assertNotIn('UIWidgets.Register("Reserves", {', reserves_ui)

    def test_warnings_owns_its_list_panel_binding_without_single_use_scaffold(self):
        frames = read(FRAMES)
        warnings = read(WARNINGS)

        self.assertNotIn("function Scaffold.CreateListPanel", frames)
        self.assertNotIn("bootstrapModuleUi", frames)
        self.assertNotIn("Scaffold.CreateListPanel", warnings)
        self.assertNotIn("panelScaffold", warnings)

        self.assertIn("local function bindWarningsListPanel(frame)", warnings)
        self.assertIn("Frames.BindModuleFrame(module, frame, {", warnings)
        self.assertIn("controller:OnLoad(frame)", warnings)
        self.assertIn("local function refreshWarningsListPanel()", warnings)
        self.assertIn("uiState.Refresh()", warnings)


if __name__ == "__main__":
    unittest.main()
