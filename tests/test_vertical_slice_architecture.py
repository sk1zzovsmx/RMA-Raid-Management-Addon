import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ADDON = ROOT / "Raid Management Addon"
BOUNDARIES = ROOT / "docs" / "FEATURE_BOUNDARIES.md"
ARCHITECTURE = ROOT / "docs" / "ARCHITECTURE.md"
REGISTRY = ADDON / "Modules" / "ModuleRegistry.lua"
CONFIG_CONTROLLER = ADDON / "Controllers" / "Config.lua"
CONFIG_WIDGET = ADDON / "Widgets" / "Config.lua"
MASTER = ADDON / "Controllers" / "Master.lua"
LOGGER = ADDON / "Controllers" / "Logger.lua"
INIT = ADDON / "Init.lua"
MINIMAP = ADDON / "EntryPoints" / "Minimap.lua"
SLASH = ADDON / "EntryPoints" / "SlashEvents.lua"
TOC = ADDON / "Raid Management Addon.toc"
RAID_DEBUG = ADDON / "Services" / "Raid" / "Debug.lua"
OLD_DEBUG = ADDON / "Services" / "Debug.lua"
LOOT_DISTRIBUTION = ADDON / "Services" / "Loot" / "DistributionSession.lua"
LOOT_INVENTORY = ADDON / "Services" / "Loot" / "Inventory.lua"
LOOT_AWARD = ADDON / "Services" / "Loot" / "AwardPlanner.lua"
EVENTS = ADDON / "Modules" / "Events.lua"
LOOT_METHOD = ADDON / "Services" / "Raid" / "LootMethod.lua"
RAID_ATTENDANCE = ADDON / "Services" / "Raid" / "Attendance.lua"
RESERVES_UI = ADDON / "Widgets" / "ReservesUI.lua"
SPAMMER = ADDON / "Controllers" / "Spammer.lua"
WARNINGS = ADDON / "Controllers" / "Warnings.lua"
ROLLS = ADDON / "Services" / "Rolls" / "Service.lua"
RAID_STORE = ADDON / "Database" / "DBRaidStore.lua"
DB_OPTIONS = ADDON / "Database" / "DBOptions.lua"
SAVED_VARIABLES = ADDON / "Database" / "SavedVariables.lua"
LOOT_WORKFLOW = ADDON / "Services" / "Loot" / "Workflow.lua"
UI_FRAMES = ADDON / "Modules" / "UI" / "Frames.lua"
LOGGER_EXPORT = ADDON / "Services" / "Logger" / "Export.lua"


def read(path):
    return path.read_text(encoding="utf-8")


class VerticalSliceArchitectureTest(unittest.TestCase):
    def test_domain_api_names_describe_results_without_argument_or_storage_details(self):
        runtime_sources = "\n".join(
            read(path) for path in ADDON.rglob("*.lua") if "Libs" not in path.parts
        )
        for retired in (
            "ResolveInventoryAwardedCount" + "FromArgs",
            "DeleteRaidAttendee" + "Many",
            "GetPlayerBossParticipation" + "List",
            "BuildLootSource" + "Model",
            "BuildState" + "FromStore",
            "GetTradePlayer" + "Items",
        ):
            self.assertNotIn(retired, runtime_sources)
        for expected in (
            "ResolveInventoryAwardedCount",
            "DeleteRaidAttendees",
            "FillPlayerBossParticipationList",
            "ResolveSourceMetadata",
            "BuildState",
            "GetPlayerTradeItems",
        ):
            self.assertIn(expected, runtime_sources)

    def test_infrastructure_api_names_use_canonical_operations(self):
        runtime_sources = "\n".join(
            read(path) for path in ADDON.rglob("*.lua") if "Libs" not in path.parts
        )
        for retired in (
            "Json.Get" + "Decoded",
            "Options.Add" + "Namespace",
            "Events.GetConfigOption" + "Changed",
            "Events.GetWow" + "Forwarded",
        ):
            self.assertNotIn(retired, runtime_sources)
        for expected in (
            "Json.Decode",
            "Options.RegisterNamespace",
            "Events.BuildConfigOptionChangedName",
            "Events.ResolveWowForwardedName",
        ):
            self.assertIn(expected, runtime_sources)

    def test_raid_lookup_api_names_distinguish_index_from_nid(self):
        store = read(RAID_STORE)
        runtime_sources = "\n".join(
            read(path) for path in ADDON.rglob("*.lua") if "Libs" not in path.parts
        )
        for current in (
            "Ensure" + "RaidById",
            "GetRaidNidBy" + "Id",
            "GetRaidIdBy" + "Nid",
        ):
            self.assertNotIn(current, runtime_sources)
        for expected in (
            "function Database.EnsureRaidByIndex(",
            "function Database.EnsureRaidByNid(",
            "function Database.GetRaidNidByIndex(",
            "function Database.GetRaidIndexByNid(",
        ):
            self.assertIn(expected, store)

    def test_unused_and_pass_through_apis_do_not_return(self):
        forbidden_by_file = {
            LOOT_INVENTORY: ("function Inventory.ResolveInventoryAwardedCount()",),
            RAID_ATTENDANCE: ("function module:GetAttendanceEntry(",),
            RESERVES_UI: ("function module:HideImport()",),
            SPAMMER: ("function module:RequestClear()", "function module:RequestPreview()"),
            WARNINGS: (
                "function module:RequestTemplatePreview()",
                "function module:RequestClearSavedWarnings(",
            ),
            ROLLS: ("function module:SetPlayerResponse(",),
            RAID_STORE: ("function module:StripAllRuntime()",),
            DB_OPTIONS: ("function namespaceMt:GetDefaults()",),
            SAVED_VARIABLES: ("function SavedVariables.WasWarningsFresh()",),
            LOOT_WORKFLOW: (
                "function Workflow.BuildSnapshot(",
                "local function buildSteps(",
                "local function buildSummary(",
            ),
            UI_FRAMES: (
                "function ModuleState.Get(",
                "function ModuleState.Reset(",
                "function Scaffold.EnsureModuleState(",
                "Scaffold.EnsureModuleState(",
            ),
            LOGGER_EXPORT: ("function Export:GetCSV(",),
        }
        for path, forbidden_symbols in forbidden_by_file.items():
            source = read(path)
            for symbol in forbidden_symbols:
                with self.subTest(path=path.name, symbol=symbol):
                    self.assertNotIn(symbol, source)

        runtime_sources = "\n".join(
            read(path) for path in ADDON.rglob("*.lua") if "Libs" not in path.parts
        )
        self.assertNotIn("Scaffold.EnsureModuleState(", runtime_sources)
        self.assertIn("ModuleState.Ensure(", runtime_sources)
        self.assertIn("Export:BuildCSV(raid, getExportContext())", read(LOGGER))

    def test_group_loot_restore_event_is_a_notification(self):
        events = read(EVENTS)
        loot_method = read(LOOT_METHOD)
        master = read(MASTER)
        for source in (events, loot_method, master):
            self.assertNotIn("RequestGroupLootRestorePrompt", source)
        self.assertIn("GroupLootRestoreNeeded", events)
        self.assertIn("TriggerEvent(GroupLootRestoreNeededEvent)", loot_method)
        self.assertIn("RegisterCallback(MasterEvents.GroupLootRestoreNeeded", master)

    def test_removed_command_routing_layers_do_not_return(self):
        runtime_sources = "\n".join(
            read(path)
            for path in ADDON.rglob("*.lua")
            if "Libs" not in path.parts
        )
        for forbidden in (
            "RequestControllerMethod",
            "LoggerLootLogRequest",
            "SetDistributionState",
        ):
            with self.subTest(forbidden=forbidden):
                self.assertNotIn(forbidden, runtime_sources)

    def test_feature_boundary_contract_names_every_product_slice(self):
        content = read(BOUNDARIES)
        for heading in (
            "## Shared Kernel",
            "## Configuration",
            "## Raid",
            "## Master Loot",
            "## Logger And Attendance",
            "## Reserves",
            "## Warnings",
            "## Spammer",
        ):
            with self.subTest(heading=heading):
                self.assertIn(heading, content)

    def test_contract_defines_command_query_notification_semantics(self):
        content = read(BOUNDARIES)
        self.assertIn("### Commands", content)
        self.assertIn("### Queries", content)
        self.assertIn("### Notifications", content)
        self.assertIn("Commands and queries use direct owner calls.", content)
        self.assertIn("Notifications use addon.Bus after the state change succeeds.", content)

    def test_contract_defines_one_way_ui_request_semantics(self):
        content = read(BOUNDARIES)
        self.assertIn("### UI Requests", content)
        self.assertIn("UI requests do not return a value.", content)
        self.assertIn("Commands and queries do not pass through addon.Bus.", content)
        self.assertIn(
            "addon.Bus may carry UI requests only as imperative one-way notifications.",
            content,
        )

    def test_module_registry_is_removed(self):
        self.assertFalse(REGISTRY.exists())
        self.assertNotIn("Modules\\ModuleRegistry.lua", read(TOC))

        forbidden = (
            "ModuleRegistry",
            "ModuleRegistryPendingLoads",
            "ModuleRegistryPendingRegistrations",
            "registerBootstrapModule",
        )
        for path in ADDON.rglob("*.lua"):
            if "Libs" in path.parts:
                continue
            source = read(path)
            with self.subTest(path=path.relative_to(ADDON).as_posix()):
                for token in forbidden:
                    self.assertNotIn(token, source)

    def test_runtime_uses_explicit_addon_dependencies_without_feature_proxy(self):
        forbidden = (
            "GetFeatureShared",
            "local feature =",
            "feature.",
        )
        for path in ADDON.rglob("*.lua"):
            if "Libs" in path.parts:
                continue
            source = read(path)
            with self.subTest(path=path.relative_to(ADDON).as_posix()):
                for token in forbidden:
                    self.assertNotIn(token, source)

    def test_runtime_has_no_unused_feature_flags_or_widget_registry(self):
        self.assertFalse((ADDON / "Modules" / "Features.lua").exists())
        self.assertFalse((ADDON / "Modules" / "UI" / "Facade.lua").exists())
        self.assertNotIn("Modules\\Features.lua", read(TOC))
        self.assertNotIn("Modules\\UI\\Facade.lua", read(TOC))

        forbidden = (
            "addon.Features",
            "UI.Widgets",
            "local UIWidgets",
            "WidgetFlags",
            "RegisterMethod",
            "RegisterFunction",
            "CallMethod",
            "CallFunction",
        )
        for path in ADDON.rglob("*.lua"):
            if "Libs" in path.parts:
                continue
            source = read(path)
            with self.subTest(path=path.relative_to(ADDON).as_posix()):
                for token in forbidden:
                    self.assertNotIn(token, source)

    def test_runtime_requires_the_canonical_raid_store_without_optional_fallbacks(self):
        attendance_store = read(ADDON / "Services" / "Attendance" / "Store.lua")
        logger_store = read(ADDON / "Services" / "Logger" / "Store.lua")
        self.assertNotIn("Database.EnsureRaidByIndex", attendance_store)
        self.assertNotIn("Database.EnsureRaidByNid", logger_store)
        for path in ADDON.rglob("*.lua"):
            if "Libs" in path.parts:
                continue
            source = read(path)
            with self.subTest(path=path.relative_to(ADDON).as_posix()):
                self.assertNotIn("GetRaidStoreOrNil", source)
                self.assertNotIn("LogRaidStoreUnavailable", source)
                self.assertNotIn("LogRaidStoreMethodMissing", source)

    def test_architecture_document_links_the_boundary_contract(self):
        self.assertIn("FEATURE_BOUNDARIES.md", read(ARCHITECTURE))

    def test_config_is_a_top_level_controller(self):
        self.assertTrue(CONFIG_CONTROLLER.exists())
        self.assertFalse(CONFIG_WIDGET.exists())
        config = read(CONFIG_CONTROLLER)
        self.assertIn("Controllers.Config = Controllers.Config or {}", config)
        self.assertNotIn("function module:IsAvailable()", config)
        self.assertNotIn('UIWidgets.Register("Config"', config)
        self.assertIn("Controllers\\Config.lua", read(TOC))

    def test_config_callers_do_not_keep_obsolete_availability_resolvers(self):
        for path in (MASTER, MINIMAP, SLASH):
            source = read(path)
            with self.subTest(path=path.name):
                self.assertNotIn("getConfigController", source)
                self.assertNotIn(":IsAvailable()", source)

    def test_config_callers_use_the_controller_owner(self):
        self.assertIn("Controllers.Config:Toggle()", read(MASTER))
        self.assertIn("Controllers.Config:Toggle()", read(MINIMAP))
        self.assertIn("ConfigController:Toggle()", read(SLASH))
        for path in (MASTER, MINIMAP, SLASH):
            self.assertNotIn('CallMethod("Config"', read(path))

    def test_raid_debug_support_lives_inside_the_raid_slice(self):
        self.assertTrue(RAID_DEBUG.exists())
        self.assertFalse(OLD_DEBUG.exists())
        source = read(RAID_DEBUG)
        self.assertIn("Raid.Debug = Raid.Debug or {}", source)

    def test_no_code_outside_raid_uses_raid_private_helpers(self):
        for path in ADDON.rglob("*.lua"):
            relative = path.relative_to(ADDON).as_posix()
            if relative.startswith("Libs/") or relative.startswith("Services/Raid/"):
                continue
            source = read(path)
            with self.subTest(relative=relative):
                self.assertNotIn("Raid._", source)
                self.assertNotIn("raidService._", source)

    def test_master_loot_cross_owner_contracts_are_explicit(self):
        expected = (
            (LOOT_DISTRIBUTION, "Loot.DistributionSession = Loot.DistributionSession or {}"),
            (LOOT_INVENTORY, "Loot.Inventory = Loot.Inventory or {}"),
            (LOOT_AWARD, "Loot.AwardPlanner = Loot.AwardPlanner or {}"),
        )
        for path, declaration in expected:
            source = read(path)
            with self.subTest(path=path.name):
                self.assertRegex(source, rf"(?m)^\s*{re.escape(declaration)}\s*$")

    def test_retired_master_loot_owner_names_are_absent_from_runtime(self):
        retired = ("_DistributionSession", "_Inventory", "_AwardPlanner")
        for path in ADDON.rglob("*.lua"):
            relative = path.relative_to(ADDON).as_posix()
            if relative.startswith("Libs/"):
                continue
            source = read(path)
            with self.subTest(relative=relative):
                for symbol in retired:
                    self.assertNotIn(symbol, source)
                    self.assertNotIn("lootService." + symbol, source)

    def test_master_and_init_bind_explicit_loot_owners(self):
        master = read(MASTER)
        init = read(INIT)
        master_bindings = (
            'local LootDistribution = assert(Loot.DistributionSession, "Master loot distribution owner is not initialized")',
            'local LootInventory = assert(Loot.Inventory, "Loot inventory owner is not initialized")',
            'local LootAwardPlanner = assert(Loot.AwardPlanner, "Loot award planner owner is not initialized")',
        )
        for binding in master_bindings:
            with self.subTest(binding=binding):
                self.assertRegex(master, rf"(?m)^\s*{re.escape(binding)}\s*$")
        init_binding = "local lootDistribution = lootService and lootService.DistributionSession or nil"
        self.assertRegex(init, rf"(?m)^\s*{re.escape(init_binding)}\s*$")

    def test_logger_loot_controller_assignment_matches_roster_refresh_field(self):
        source = read(LOGGER)
        self.assertIn("local ctrl = listModules[i] and listModules[i]._ctrl", source)
        self.assertIn("Loot._ctrl = controller", source)
        self.assertIn("module.Loot._ctrl.data", source)
        self.assertNotIn("Loot.controller = controller", source)
