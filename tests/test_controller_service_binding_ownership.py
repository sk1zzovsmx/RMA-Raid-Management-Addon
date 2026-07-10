import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ADDON = ROOT / "Raid Management Addon"
TOC = ADDON / "Raid Management Addon.toc"
WARNINGS = ADDON / "Controllers" / "Warnings.lua"
SPAMMER = ADDON / "Controllers" / "Spammer.lua"
MASTER = ADDON / "Controllers" / "Master.lua"
LOGGER = ADDON / "Controllers" / "Logger.lua"
ATTENDANCE = ADDON / "Controllers" / "Attendance.lua"
ATTENDANCE_EXPORT = ADDON / "Services" / "Attendance" / "Export.lua"
ATTENDANCE_SERVICES = (
    ADDON / "Services" / "Attendance" / "Store.lua",
    ADDON / "Services" / "Attendance" / "View.lua",
    ADDON / "Services" / "Attendance" / "Actions.lua",
    ATTENDANCE_EXPORT,
)
MASTER_AWARD = ADDON / "Services" / "Master" / "Award.lua"


def read(path):
    return path.read_text(encoding="utf-8")


class ControllerServiceBindingOwnershipTest(unittest.TestCase):
    def test_attendance_export_is_declared_service_boundary(self):
        attendance = read(ATTENDANCE)
        attendance_export = read(ATTENDANCE_EXPORT)

        self.assertIn(
            'local AttendanceExport = assert(AttendanceSvc.Export, "Attendance export service is not initialized")',
            attendance,
        )
        self.assertIn("module.Export = AttendanceExport", attendance)
        self.assertIn('"Services/Attendance/Export"', attendance)
        self.assertIn("local Export = Attendance.Export", attendance_export)

    def test_attendance_export_is_not_owned_by_logger_controller_or_service(self):
        attendance = read(ATTENDANCE)
        logger = read(ROOT / "Raid Management Addon" / "Services" / "Logger" / "Export.lua")

        self.assertIn("AttendanceExport:GetRaidAttendanceCSV(raid, getAttendanceExportContext())", attendance)
        self.assertNotIn("GetRaidAttendanceCSV", logger)
        self.assertNotIn("raidAttendance", logger)

    def test_attendance_services_do_not_touch_frames_or_widgets(self):
        for service in ATTENDANCE_SERVICES:
            content = read(service)
            with self.subTest(service=service.name):
                for forbidden in (
                    "_G",
                    "GetFrame",
                    "SetScript",
                    "UI.",
                    "Controllers.",
                    "Widgets.",
                    "CreateFrame",
                    "UIParent",
                ):
                    with self.subTest(forbidden=forbidden):
                        self.assertNotIn(forbidden, content)

    def test_logger_does_not_invoke_attendance_domain(self):
        logger = read(ADDON / "Controllers" / "Logger.lua")

        for forbidden in (
            "Controllers.Attendance",
            "AttendanceExport",
            "AttendanceSvc",
            "GetRaidAttendanceCSV",
            "GetRaidAttendance(",
        ):
            with self.subTest(forbidden=forbidden):
                self.assertNotIn(forbidden, logger)

    def test_warnings_controller_binds_chat_service_without_local_api_table(self):
        warnings = read(WARNINGS)

        self.assertIn('local Chat = assert(Services.Chat, "Warnings controller chat service is not initialized")', warnings)
        self.assertIn(
            'local AnnounceWarningMessage = requireServiceMethod("Chat", Chat, "AnnounceWarningMessage")',
            warnings,
        )
        self.assertIn("AnnounceWarningMessage(Chat, warning.content)", warnings)
        self.assertNotIn("local ChatApi = {", warnings)
        self.assertNotIn("ChatApi.", warnings)

    def test_warnings_controller_binds_warning_store_without_local_api_table(self):
        warnings = read(WARNINGS)

        self.assertIn(
            'local WarningsSvc = assert(Services.Warnings, "Warnings controller service namespace is not initialized")',
            warnings,
        )
        self.assertIn(
            'local WarningStore = assert(WarningsSvc.Store, "Warnings controller store service is not initialized")',
            warnings,
        )
        self.assertNotIn("local WarningsSvc = Services.Warnings", warnings)
        self.assertNotIn("WarningsSvc and WarningsSvc.Store or nil", warnings)
        for method_name in (
            "GetStore",
            "GetWarning",
            "EnsureDefaultTemplates",
            "BuildTemplatePreview",
            "ClearSavedWarnings",
            "DeleteWarning",
            "SaveWarning",
        ):
            with self.subTest(method_name=method_name):
                expected = 'local {0} = requireServiceMethod("Warnings.Store", WarningStore, "{0}")'.format(method_name)
                self.assertIn(expected, warnings)

        self.assertIn("local warning = GetWarning(wID)", warnings)
        self.assertIn("local warnings = GetStore()", warnings)
        self.assertIn("local result = EnsureDefaultTemplates()", warnings)
        self.assertIn('return BuildTemplatePreview(L.StrConfigRaidWarningPreviewEmpty or "")', warnings)
        self.assertIn("local result = ClearSavedWarnings(includeStock)", warnings)
        self.assertIn("local deleteResult = DeleteWarning(selectedID)", warnings)
        self.assertIn("local savedID, reason = SaveWarning(wContent, wName, wID, isEdit)", warnings)
        self.assertNotIn("local WarningStoreApi = {", warnings)
        self.assertNotIn("WarningStoreApi.", warnings)

    def test_spammer_controller_binds_chat_service_without_local_api_table(self):
        spammer = read(SPAMMER)

        self.assertIn('local Chat = assert(Services.Chat, "Spammer controller chat service is not initialized")', spammer)
        for method_name in (
            "GetSpamRuntimeState",
            "StartSpamCycle",
            "StopSpamCycle",
            "PauseSpamCycle",
        ):
            with self.subTest(method_name=method_name):
                expected = 'local {0} = requireServiceMethod("Chat", Chat, "{0}")'.format(method_name)
                self.assertIn(expected, spammer)

        self.assertIn("local runtime = GetSpamRuntimeState(Chat)", spammer)
        self.assertIn("StartSpamCycle(Chat, {", spammer)
        self.assertIn("StopSpamCycle(Chat, true, true)", spammer)
        self.assertIn("local pausedOk = PauseSpamCycle(Chat)", spammer)
        self.assertNotIn("local ChatApi = {", spammer)
        self.assertNotIn("ChatApi.", spammer)

    def test_spammer_controller_binds_draft_service_without_optional_owner_guard(self):
        spammer = read(SPAMMER)

        self.assertIn(
            'local SpammerSvc = assert(Services.Spammer, "Spammer controller service namespace is not initialized")',
            spammer,
        )
        self.assertIn(
            'local DraftSvc = assert(SpammerSvc.Draft, "Spammer controller draft service is not initialized")',
            spammer,
        )
        self.assertNotIn("local SpammerSvc = Services.Spammer", spammer)
        self.assertNotIn("SpammerSvc and SpammerSvc.Draft or nil", spammer)

    def test_logger_controller_binds_helpers_without_optional_fallbacks(self):
        logger = read(LOGGER)

        self.assertIn(
            'local LoggerSvc = assert(Services.Logger, "Logger service namespace is not initialized")',
            logger,
        )
        self.assertIn(
            'local LoggerHelpers = assert(LoggerSvc.Helpers, "Logger helper service is not initialized")',
            logger,
        )
        self.assertIn("return LoggerHelpers.NormalizeRollValue(value)", logger)
        self.assertIn("local rt = LoggerHelpers.NormalizeRollType(it.rollType)", logger)
        self.assertIn("ui.Roll:SetText(LoggerHelpers.FormatRollValueForRow(it.rollValue))", logger)
        self.assertIn("local aType = LoggerHelpers.GetRollTypeSortValue(a and a.rollType)", logger)
        self.assertIn("local aRoll = LoggerHelpers.GetRollSortValue(a and a.rollValue)", logger)
        self.assertNotIn("Services.Logger and Services.Logger.Helpers or nil", logger)
        self.assertNotIn("LoggerHelpers = Helpers", logger)
        self.assertNotIn("LoggerHelpers and LoggerHelpers.", logger)

    def test_logger_controller_binds_logger_subservices_at_boundary(self):
        logger = read(LOGGER)

        for service_name in ("Store", "View", "Export", "Actions"):
            with self.subTest(service_name=service_name):
                expected = (
                    'local Logger{0} = assert(LoggerSvc.{0}, "Logger {1} service is not initialized")'
                ).format(service_name, service_name.lower())
                self.assertIn(expected, logger)
                self.assertNotIn("local {0} = LoggerSvc.{0}".format(service_name), logger)

        self.assertIn("module.Store = LoggerStore", logger)
        self.assertIn("module.View = LoggerView", logger)
        self.assertIn("module.Export = LoggerExport", logger)
        self.assertIn("module.Actions = LoggerActions", logger)
        self.assertIn("local Store = LoggerStore", logger)
        self.assertIn("local View = LoggerView", logger)
        self.assertIn("local Export = LoggerExport", logger)
        self.assertIn("local Actions = LoggerActions", logger)

    def test_attendance_controller_binds_equip_inspect_without_optional_noop(self):
        attendance = read(ATTENDANCE)

        self.assertIn(
            'local EquipInspect = assert(Services.EquipInspect, "Attendance equip-inspect service is not initialized")',
            attendance,
        )
        self.assertIn(
            'local ForceInspectPlayer = assert(EquipInspect.ForcePlayer, "Attendance force-inspect method is not initialized")',
            attendance,
        )
        self.assertIn("ForceInspectPlayer(EquipInspect, selectedRaid, selectedPlayer)", attendance)
        self.assertIn('"Services/EquipInspect"', attendance)
        self.assertNotIn("if Services.EquipInspect and Services.EquipInspect.ForcePlayer then", attendance)
        self.assertNotIn("Services.EquipInspect:ForcePlayer", attendance)

    def test_attendance_requests_logger_player_selection_clear_through_internal_event(self):
        logger = read(LOGGER)
        attendance = read(ATTENDANCE)

        self.assertIn('clearSelection(module, "selectedPlayer", MS_CTX_RAIDATT)', logger)
        self.assertIn('clearSelection(module, "selectedBossPlayer", MS_CTX_BOSSATT)', logger)
        self.assertIn('triggerSelectionEvent(module, "selectedPlayer")', logger)
        self.assertIn('triggerSelectionEvent(module, "selectedBossPlayer")', logger)
        self.assertIn("LoggerClearPlayerSelections = assert(", logger)
        self.assertIn("RegisterCallback(LoggerEvents.LoggerClearPlayerSelections, clearPlayerSelections)", logger)
        self.assertIn("LoggerClearPlayerSelections = assert(", attendance)
        self.assertIn("TriggerEvent(AttendanceEvents.LoggerClearPlayerSelections)", attendance)
        self.assertNotIn("Controllers.Logger", attendance)
        self.assertNotIn("ClearLoggerPlayerSelections", attendance)
        self.assertNotIn('"Controllers/Logger"', attendance)

    def test_logger_controller_binds_raid_service_without_direct_service_calls(self):
        logger = read(LOGGER)
        attendance = read(ATTENDANCE)

        self.assertIn(
            'local Raid = assert(Services.Raid, "Logger raid service is not initialized")',
            logger,
        )
        self.assertIn("Raid:GetPlayerClass(it.looter)", logger)
        self.assertIn('local Raid = assert(Services.Raid, "Attendance raid service is not initialized")', attendance)
        self.assertIn("Raid:UpdateRaidRoster()", attendance)
        self.assertIn('"Services/Raid/State"', logger)
        self.assertIn('"Services/Raid/Attendance"', attendance)
        self.assertNotIn("Services.Raid:", logger)
        self.assertNotIn("local Raid = Services.Raid", logger)

    def test_master_controller_binds_chat_service_without_local_api_table(self):
        master = read(MASTER)
        multi_award = read(MASTER_AWARD)

        self.assertIn('local Chat = assert(Services.Chat, "Master chat service is not initialized")', master)
        self.assertIn('local Announce = requireServiceMethod("Chat", Chat, "Announce")', master)
        self.assertIn('Announce(Chat, plan.header, "RAID")', master)
        self.assertIn("controller.announce(L.ChatAward:format(names[1], ma.itemLink))", multi_award)
        self.assertNotIn("local Chat = Services.Chat", master)
        self.assertNotIn("local ChatApi = {", master)
        self.assertNotIn("ChatApi.", master)

    def test_master_controller_binds_core_services_at_boundary(self):
        master = read(MASTER)

        expected_bindings = (
            'local Loot = assert(Services.Loot, "Master loot service is not initialized")',
            'local Raid = assert(Services.Raid, "Master raid service is not initialized")',
            'local Rolls = assert(Services.Rolls, "Master rolls service is not initialized")',
            'local Chat = assert(Services.Chat, "Master chat service is not initialized")',
        )
        for binding in expected_bindings:
            with self.subTest(binding=binding):
                self.assertIn(binding, master)

        self.assertNotIn("local Loot = Services.Loot", master)
        self.assertNotIn("local Raid = Services.Raid", master)
        self.assertNotIn("local Rolls = Services.Rolls", master)
        self.assertNotIn("local Chat = Services.Chat", master)

    def test_master_controller_binds_rolls_service_without_optional_guards(self):
        master = read(MASTER)

        for method_name in (
            "GetRollSession",
            "GetDisplayModel",
            "BeginTieReroll",
        ):
            with self.subTest(method_name=method_name):
                expected = 'local {0} = requireServiceMethod("Rolls", Rolls, "{0}")'.format(method_name)
                self.assertIn(expected, master)

        self.assertIn("local session = GetRollSession(Rolls)", master)
        self.assertIn("return GetDisplayModel(Rolls)", master)
        self.assertIn("RollSelectionService.CreateController({", master)
        self.assertIn("BeginTieReroll(Rolls, resolution.tiedNames)", master)
        self.assertNotIn("Rolls and Rolls.GetRollSession", master)
        self.assertNotIn("Rolls and Rolls.GetDisplayModel", master)
        self.assertNotIn("Rolls and Rolls.BeginTieReroll", master)

    def test_master_controller_binds_multi_award_service_without_local_helpers(self):
        master = read(MASTER)

        self.assertIn(
            'local AwardService = assert(MasterService.Award, "Master award service is not initialized")',
            master,
        )
        self.assertNotIn("local AwardService = MasterService.Award", master)
        self.assertNotIn("local function collectMultiAwardNames", master)
        self.assertNotIn("local function announceMultiAwardCompletion", master)
        self.assertNotIn("local function armMultiAwardProgressTimeout", master)
        self.assertNotIn("local function buildMultiAwardWinners", master)
        self.assertNotIn("local function startMultiAwardSequence", master)
        self.assertNotIn("local function continueMultiAwardOnLootSlotCleared", master)
        self.assertIn("awardController = AwardService.CreateController({", master)
        self.assertIn("awardPlanner = LootAwardPlanner", master)
        self.assertIn("inventory = LootInventory", master)
        self.assertIn("lootState = lootState", master)
        self.assertIn("rollSelection = rollSelectionController", master)
        self.assertIn("awardExecutor = {", master)
        self.assertIn("Assign = function(_, itemLink, playerName, rollType, rollValue)", master)
        self.assertIn("itemCount = {", master)
        self.assertIn("Set = function(_, count, focus)", master)
        self.assertIn("Reset = function(_, focus)", master)
        self.assertIn("registerAwardedItem = registerAwardedItem", master)
        self.assertIn("return awardController:TryMultipleCopies(itemLink, target, available)", master)
        self.assertIn("return awardController:TrySingleCopy(itemLink, winnerName)", master)
        self.assertIn("return awardController:ContinueOnLootSlotCleared(clearedSlot)", master)

    def test_spammer_controller_reads_chat_runtime_state_without_private_facade(self):
        spammer = read(SPAMMER)

        self.assertNotIn("local function getSpamRuntimeState()", spammer)
        self.assertNotIn("getSpamRuntimeState()", spammer)
        self.assertGreaterEqual(spammer.count("GetSpamRuntimeState(Chat)"), 5)


if __name__ == "__main__":
    unittest.main()
