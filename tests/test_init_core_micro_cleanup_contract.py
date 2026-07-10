from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
ADDON = ROOT / "Raid Management Addon"
INIT = ADDON / "Init.lua"
TOC = ADDON / "Raid Management Addon.toc"
SLASH = ADDON / "EntryPoints" / "SlashEvents.lua"
DB = ADDON / "Database" / "DB.lua"
SAVED_VARIABLES = ADDON / "Database" / "SavedVariables.lua"
DB_OPTIONS = ADDON / "Database" / "DBOptions.lua"
DB_RAID_STORE = ADDON / "Database" / "DBRaidStore.lua"
DB_RAID_QUERIES = ADDON / "Database" / "DBRaidQueries.lua"
DB_RAID_MIGRATIONS = ADDON / "Database" / "DBRaidMigrations.lua"
COLORS = ADDON / "Modules" / "Colors.lua"
COMMS = ADDON / "Modules" / "Comms.lua"
ITEM = ADDON / "Modules" / "Item.lua"
TIMER = ADDON / "Modules" / "Timer.lua"
UI_SCREEN_NOTICE = ADDON / "Modules" / "UI" / "ScreenNotice.lua"
UI_FRAMES = ADDON / "Modules" / "UI" / "Frames.lua"
UI_OPTIONS_LAYOUT = ADDON / "Modules" / "UI" / "OptionsLayout.lua"
LIST_CONTROLLER = ADDON / "Modules" / "UI" / "ListController.lua"
RESERVES_UI = ADDON / "Widgets" / "ReservesUI.lua"
RESERVES_DISPLAY = ADDON / "Services" / "Reserves" / "Display.lua"
RESERVES_SYNC = ADDON / "Services" / "Reserves" / "Sync.lua"
RESERVES_CHAT = ADDON / "Services" / "Reserves" / "Chat.lua"
RESERVES_SERVICE = ADDON / "Services" / "Reserves.lua"
RESERVES_IMPORT = ADDON / "Services" / "Reserves" / "Import.lua"
CHAT = ADDON / "Services" / "Chat.lua"
DB_SYNCER = ADDON / "Database" / "DBSyncer.lua"
DB_SYNC_PAYLOAD = ADDON / "Database" / "DBSyncPayload.lua"
DB_SYNC_IMPORT = ADDON / "Database" / "DBSyncImport.lua"
DEBUG_SERVICE = ADDON / "Services" / "Raid" / "Debug.lua"
SPEC_INSPECT = ADDON / "Services" / "SpecInspect.lua"
EQUIP_INSPECT = ADDON / "Services" / "EquipInspect.lua"
MASTER_CONTROLLER = ADDON / "Controllers" / "Master.lua"
MASTER_TRADE = ADDON / "Services" / "Master" / "Trade.lua"
MASTER_AWARD_COUNTER = ADDON / "Services" / "Master" / "AwardCounter.lua"
LOGGER_CONTROLLER = ADDON / "Controllers" / "Logger.lua"
ATTENDANCE_CONTROLLER = ADDON / "Controllers" / "Attendance.lua"
ATTENDANCE_EXPORT = ADDON / "Services" / "Attendance" / "Export.lua"
LOGGER_ACTIONS = ADDON / "Services" / "Logger" / "Actions.lua"
LOGGER_VIEW = ADDON / "Services" / "Logger" / "View.lua"
LOGGER_EXPORT = ADDON / "Services" / "Logger" / "Export.lua"
LOGGER_STORE = ADDON / "Services" / "Logger" / "Store.lua"
LOOT_HINTS = ADDON / "Widgets" / "LootHints.lua"
LOOT_COUNTER = ADDON / "Widgets" / "LootCounter.lua"
RAID_GRID = ADDON / "Widgets" / "RaidGrid.lua"
CONFIG_CONTROLLER = ADDON / "Controllers" / "Config.lua"
LOOT_SERVICE = ADDON / "Services" / "Loot" / "Service.lua"
LOOT_INVENTORY = ADDON / "Services" / "Loot" / "Inventory.lua"
LOOT_CONTEXT = ADDON / "Services" / "Loot" / "Context.lua"
LOOT_RECORDING = ADDON / "Services" / "Loot" / "Recording.lua"
LOOT_DISTRIBUTION_SESSION = ADDON / "Services" / "Loot" / "DistributionSession.lua"
LOOT_PENDING_AWARDS = ADDON / "Services" / "Loot" / "PendingAwards.lua"
LOOT_PASSIVE_GROUP_LOOT = ADDON / "Services" / "Loot" / "PassiveGroupLoot.lua"
LOOT_RULES = ADDON / "Services" / "Loot" / "Rules.lua"
LOOT_SNAPSHOTS = ADDON / "Services" / "Loot" / "Snapshots.lua"
LOOT_STATE = ADDON / "Services" / "Loot" / "State.lua"
LOOT_TRACKING = ADDON / "Services" / "Loot" / "Tracking.lua"
LOOT_SOURCE_CANDIDATES = ADDON / "Modules" / "LootSourceCandidates.lua"
LOOT_SOURCES = ADDON / "Modules" / "LootSources.lua"
RAID_LOOT_METHOD = ADDON / "Services" / "Raid" / "LootMethod.lua"
RAID_CAPABILITIES = ADDON / "Services" / "Raid" / "Capabilities.lua"
RAID_ATTENDANCE = ADDON / "Services" / "Raid" / "Attendance.lua"
RAID_LOOT_RECORDS = ADDON / "Services" / "Raid" / "LootRecords.lua"
RAID_ROSTER = ADDON / "Services" / "Raid" / "Roster.lua"
RAID_SESSION = ADDON / "Services" / "Raid" / "Session.lua"
RAID_STATE = ADDON / "Services" / "Raid" / "State.lua"
RAID_COUNTS = ADDON / "Services" / "Raid" / "Counts.lua"
ROLLS_RESPONSES = ADDON / "Services" / "Rolls" / "Responses.lua"
ROLLS_SESSIONS = ADDON / "Services" / "Rolls" / "Sessions.lua"
ROLLS_SERVICE = ADDON / "Services" / "Rolls" / "Service.lua"
ROLLS_HISTORY = ADDON / "Services" / "Rolls" / "History.lua"
ROLLS_RESOLUTION = ADDON / "Services" / "Rolls" / "Resolution.lua"


def read(path):
    return path.read_text(encoding="utf-8")


class InitCoreMicroCleanupContractTest(unittest.TestCase):
    def test_attendance_export_owns_raid_attendance_csv_without_frame_access(self):
        attendance_export = read(ATTENDANCE_EXPORT)

        self.assertIn('feature.EnsureServiceNamespace("Attendance", "Export")', attendance_export)
        self.assertIn("function Export:GetRaidAttendanceCSV(raid, context)", attendance_export)
        self.assertIn("queries:GetRaidAttendance(raid, attendanceRows)", attendance_export)
        self.assertIn("finishPerf(\"Attendance.Export.GetRaidAttendanceCSV\"", attendance_export)
        self.assertIn('registry.AddModule("Services/Attendance/Export"', attendance_export)
        self.assertNotIn("_G", attendance_export)
        self.assertNotIn("GetFrame", attendance_export)
        self.assertNotIn("UI.", attendance_export)

    def test_attendance_export_preserves_legacy_csv_header_names(self):
        attendance_export = read(ATTENDANCE_EXPORT)

        self.assertIn(
            '''local HEADER_RAID_ATTENDANCE = {
	"raidNid",
	"raidDate",
	"zone",
	"size",
	"difficulty",
	"playerNid",
	"player",
	"class",
	"join",
	"leave",
	"attendanceSeconds",
	"onlineSeconds",
	"offlineSeconds",
	"segmentCount",
}''',
            attendance_export,
        )

    def test_logger_export_no_longer_owns_raid_attendance_csv(self):
        logger_export = read(LOGGER_EXPORT)

        self.assertIn("function Export:GetCSV(mode, raid, context)", logger_export)
        self.assertIn('if mode == "loot" then', logger_export)
        self.assertNotIn('elseif mode == "raidAttendance" then', logger_export)
        self.assertNotIn("function Export:GetRaidAttendanceCSV", logger_export)
        self.assertNotIn("HEADER_RAID_ATTENDANCE", logger_export)
        self.assertNotIn("GetRaidAttendance(raid", logger_export)
        self.assertNotIn("Logger.Export.GetRaidAttendanceCSV", logger_export)

    def test_public_rma_identity_is_preserved(self):
        init = read(INIT)
        toc = read(TOC)
        slash = read(SLASH)
        self.assertIn("Raid Management Addon", toc)
        self.assertIn("## Interface: 30300", toc)
        self.assertIn("RMA_Raids", toc)
        self.assertIn("RMA_Options", toc)
        self.assertIn('SLASH_RMA1 = "/rma"', slash)
        self.assertIn("SavedVariables.EnsureAll()", init)
        saved_variables = read(SAVED_VARIABLES)
        self.assertIn('ensureTable("RMA_Raids")', saved_variables)
        self.assertIn('ensureTable("RMA_Options")', saved_variables)

    def test_init_uses_lua51_safe_cached_gettime(self):
        src = read(INIT)
        self.assertIn("local GetTime = assert(", src)
        self.assertIn("_G.GetTime", src)
        self.assertIn('"RMA time API is not initialized"', src)
        self.assertNotIn('type(GetTime) ~= "function"', src)
        self.assertNotIn("_ENV", src)
        self.assertNotIn("table.unpack", src)
        self.assertNotIn("C_Timer", src)

    def test_init_depends_on_wotlk_realm_api_without_empty_fallback(self):
        src = read(INIT)
        self.assertIn("local GetRealmName = assert(", src)
        self.assertIn("_G.GetRealmName", src)
        self.assertIn('"RMA realm name API is not initialized"', src)
        self.assertNotIn('GetRealmName and GetRealmName() or ""', src)

    def test_init_resolves_group_rank_with_wow_safe_fallbacks(self):
        src = read(INIT)
        self.assertIn("local UnitIsGroupLeader = _G.UnitIsGroupLeader", src)
        self.assertIn("local UnitIsGroupAssistant = _G.UnitIsGroupAssistant", src)
        self.assertIn("local IsInRaid = _G.IsInRaid", src)
        self.assertIn("local IsRaidLeader = _G.IsRaidLeader", src)
        self.assertIn("local IsRaidOfficer = _G.IsRaidOfficer", src)
        self.assertIn("local IsPartyLeader = _G.IsPartyLeader", src)
        self.assertIn("local GetPartyLeaderIndex = assert(", src)
        self.assertIn("local GetRaidRosterInfo = assert(", src)
        self.assertIn("local GetNumRaidMembers = assert(", src)
        self.assertIn("local GetNumPartyMembers = assert(", src)
        self.assertIn("local function isInRaid()", src)
        self.assertIn("local function isInGroup()", src)
        self.assertIn("local function isGroupLeader(unit)", src)
        self.assertIn("local function isGroupAssistant(unit)", src)
        self.assertIn("function Database.GetUnitRank(unit, fallback)", src)
        self.assertIn("addon.IsInRaid = isInRaid", src)
        self.assertIn("addon.IsInGroup = isInGroup", src)
        self.assertNotIn("addon.Client", src)
        self.assertNotIn("feature.Client", src)
        self.assertNotIn("function Client.", src)
        self.assertNotIn('"RMA raid membership API is not initialized"', src)
        self.assertNotIn('"RMA raid leader API is not initialized"', src)
        self.assertNotIn('"RMA raid officer API is not initialized"', src)
        self.assertNotIn('"RMA party leader API is not initialized"', src)
        self.assertNotIn('"RMA group leader API is not initialized"', src)
        self.assertNotIn('"RMA group assistant API is not initialized"', src)
        self.assertNotIn("addon.UnitIsGroupLeader", src)
        self.assertNotIn("addon.UnitIsGroupAssistant", src)

    def test_addon_event_count_is_not_recomputed_in_debug_log(self):
        src = read(INIT)
        self.assertIn("ADDON_EVENTS_COUNT", src)
        self.assertNotIn("tLength(addonEvents)", src)

    def test_bootstrap_does_not_create_new_generic_utils_or_db_registration_helper(self):
        init = read(INIT)
        db = read(DB)
        self.assertNotIn("addon.Utils", init)
        self.assertNotIn("addon.Helpers", init)
        self.assertNotIn("function Database.RegisterModule", db)

    def test_database_spine_does_not_export_savedvariables_manager_facade(self):
        db = read(DB)
        self.assertNotIn("DBManager.SavedVariables", db)
        self.assertNotIn("SavedVariablesManager", db)
        self.assertIn("function Database.GetRaidStoreOrNil(contextTag, requiredMethods)", db)
        self.assertIn("function Database.GetRaidQueries()", db)
        self.assertNotIn("function Database.GetRaidQueriesOrNil()", db)
        self.assertIn("function Database.GetSyncer()", db)
        self.assertIn("function DBManager.GetDefaultManager()", db)

    def test_bootstrap_does_not_export_unused_global_aliases(self):
        init = read(INIT)
        self.assertNotIn('if key == "tContains"', init)
        self.assertNotIn("return _G.tContains", init)

    def test_class_color_policy_is_owned_by_colors_module(self):
        colors = read(COLORS)
        reserves_display = read(RESERVES_DISPLAY)
        self.assertIn("addon.GetClassColor", colors)
        self.assertIn("function Colors.NormalizeClassToken", colors)
        self.assertIn("function Colors.GetClassColorHex", colors)
        self.assertNotIn("feature.GetClassColor", colors)
        self.assertNotIn("feature.GetClassColor", reserves_display)
        self.assertNotIn("local function normalizeClassToken", reserves_display)
        self.assertIn("Colors.NormalizeClassToken", reserves_display)
        self.assertIn("Colors.GetClassColorHex", reserves_display)
        self.assertIn('"Modules/Colors"', reserves_display)

    def test_group_rank_policy_is_owned_by_database(self):
        chat = read(CHAT)
        syncer = read(DB_SYNCER)
        for src in (chat, syncer):
            self.assertNotIn("feature.UnitIsGroupLeader", src)
            self.assertNotIn("feature.UnitIsGroupAssistant", src)
            self.assertNotIn("UnitIsGroupLeader and UnitIsGroupLeader", src)
            self.assertNotIn("UnitIsGroupAssistant and UnitIsGroupAssistant", src)
        self.assertIn("Database.GetUnitRank", chat)

    def test_raid_migrations_depend_on_loot_source_candidates_without_local_fallback(self):
        migrations = read(DB_RAID_MIGRATIONS)

        self.assertIn('"Modules/LootSourceCandidates"', migrations)
        self.assertIn("local LootSourceCandidates = assert(", migrations)
        self.assertIn("feature.LootSourceCandidates", migrations)
        self.assertIn('"Loot source candidate helpers are not initialized"', migrations)
        self.assertNotIn('if type(LootSourceCandidates) ~= "table" then', migrations)
        self.assertNotIn("SHARED_SOURCE_LABEL_FALLBACK", migrations)

    def test_raid_migrations_depend_on_strings_without_local_normalization_fallbacks(self):
        migrations = read(DB_RAID_MIGRATIONS)

        self.assertIn('"Modules/Strings"', migrations)
        self.assertIn("local Strings = assert(", migrations)
        self.assertIn("feature.Strings", migrations)
        self.assertIn('"String helpers are not initialized"', migrations)
        self.assertIn("local normalizeName = assert(", migrations)
        self.assertIn("Strings.NormalizeName", migrations)
        self.assertIn("local normalizeTextOrNil = assert(", migrations)
        self.assertIn("Strings.NilIfEmpty", migrations)
        self.assertIn("local normalizeTextLower = assert(", migrations)
        self.assertIn("Strings.NormalizeLower", migrations)
        self.assertNotIn("local function normalizeSourceKeyText", migrations)
        self.assertNotIn("local normalizeNameLower = assert(", migrations)
        self.assertNotRegex(
            migrations,
            r"local\s+normalizeName\s*=\s*Strings\.NormalizeName\s+or\s+function",
        )
        self.assertNotRegex(
            migrations,
            r"local\s+normalizeTextOrNil\s*=\s*Strings\.NilIfEmpty\s+or\s+function",
        )

    def test_db_sync_payload_depends_on_dboptions_without_local_fallback(self):
        sync_payload = read(DB_SYNC_PAYLOAD)

        self.assertIn('"Database/DBOptions"', sync_payload)
        self.assertIn("local isDebugEnabled = Options.IsDebugEnabled", sync_payload)
        self.assertNotRegex(sync_payload, r"local\s+isDebugEnabled\s*=\s*Options\.IsDebugEnabled\s+or\s+function")

    def test_db_options_emits_events_through_bus_without_optional_sender_guard(self):
        options = read(DB_OPTIONS)

        self.assertIn("local Bus = feature.Bus", options)
        self.assertIn("local function emit(eventName, ...)", options)
        self.assertIn('assert(Bus.TriggerEvent, "Options event bus sender is not initialized")', options)
        self.assertIn("triggerEvent(eventName, ...)", options)
        self.assertIn("emit(Events.OptionChanged", options)
        self.assertIn("emit(Events.OptionsReset", options)
        self.assertIn("emit(Events.OptionsLoaded)", options)
        self.assertNotIn('Bus and type(Bus.TriggerEvent) == "function"', options)
        self.assertNotRegex(options, r"if\s+Bus\s+and\s+Bus\.TriggerEvent")

    def test_db_sync_payload_depends_on_comms_without_optional_owner_guard(self):
        sync_payload = read(DB_SYNC_PAYLOAD)

        self.assertIn('"Modules/Comms"', sync_payload)
        self.assertIn('local Payload = assert(Comms.Payload, "Comms payload helpers are not initialized")', sync_payload)
        self.assertNotIn("Comms and Comms.Payload", sync_payload)

    def test_loot_distribution_depends_on_comms_without_optional_sender_guards(self):
        distribution = read(LOOT_DISTRIBUTION_SESSION)

        self.assertIn('"Modules/Comms"', distribution)
        self.assertIn('local Payload = assert(Comms.Payload, "Loot distribution payload codec is not initialized")', distribution)
        self.assertIn("local SendSync = assert(", distribution)
        self.assertIn("Comms.Sync", distribution)
        self.assertIn('"Loot distribution sync sender is not initialized"', distribution)
        self.assertIn("local QueueAddonMessage = assert(", distribution)
        self.assertIn("Comms.QueueAddonMessage", distribution)
        self.assertIn('"Loot distribution direct sender is not initialized"', distribution)
        self.assertIn("local ok = SendSync(PREFIX, packFields(...))", distribution)
        self.assertIn("return QueueAddonMessage(PREFIX, packFields(...), channel, target)", distribution)
        self.assertNotIn("local Payload = Comms.Payload", distribution)
        self.assertNotIn("Comms and type(Comms.Sync)", distribution)
        self.assertNotIn("Comms and type(Comms.QueueAddonMessage)", distribution)

    def test_loot_distribution_depends_on_events_and_bus_without_optional_refresh_guards(self):
        distribution = read(LOOT_DISTRIBUTION_SESSION)

        self.assertIn('"Modules/Events"', distribution)
        self.assertIn('"Modules/Bus"', distribution)
        self.assertIn("local InternalEvents = assert(Events.Internal", distribution)
        self.assertIn('"Loot distribution internal events are not initialized"', distribution)
        self.assertIn("local DistributionChangedEvent =", distribution)
        self.assertIn("assert(InternalEvents.LootDistributionSessionChanged", distribution)
        self.assertIn("InternalEvents.LootDistributionSessionChanged", distribution)
        self.assertIn('"Loot distribution change event is not initialized"', distribution)
        self.assertIn("local TriggerEvent = assert(", distribution)
        self.assertIn("Bus.TriggerEvent", distribution)
        self.assertIn('"Loot distribution event bus sender is not initialized"', distribution)
        self.assertIn("TriggerEvent(DistributionChangedEvent, reason, row, state.sessionId)", distribution)
        self.assertNotIn("return internal and internal.LootDistributionSessionChanged", distribution)
        self.assertNotIn("Events.Internal and Events.Internal.LootDistributionSessionChanged", distribution)
        self.assertNotIn('"LootDistributionSessionChanged"', distribution.split("-- ----- Public methods ----- --", 1)[0])
        self.assertNotIn('Bus and type(Bus.TriggerEvent) == "function"', distribution)

    def test_loot_distribution_uses_raid_capability_owner_without_publish_open_fallback(self):
        distribution = read(LOOT_DISTRIBUTION_SESSION)

        self.assertIn("local raid = assert(Services.Raid", distribution)
        self.assertIn('"Loot distribution raid service is not initialized"', distribution)
        self.assertRegex(distribution, r"local\s+CanUseCapability\s*=\s*assert\(")
        self.assertIn("raid.CanUseCapability", distribution)
        self.assertIn('"Loot distribution raid capability resolver is not initialized"', distribution)
        self.assertIn('return CanUseCapability(raid, "loot") == true', distribution)
        self.assertNotIn("local raid = Services and Services.Raid or nil", distribution)
        self.assertNotIn("return true\nend\n\nlocal function triggerChanged", distribution)
        self.assertNotIn("raid:GetPlayerRoleState()", distribution)

    def test_db_sync_payload_uses_declared_raid_queries_owner_without_looter_name_fallback(self):
        sync_payload = read(DB_SYNC_PAYLOAD)

        self.assertIn('"Database/DBRaidQueries"', sync_payload)
        self.assertIn("local queries = Database.GetRaidQueries()", sync_payload)
        self.assertIn("return queries:ResolveLootLooterNameFromMap(loot, playerNameByNid)", sync_payload)
        self.assertNotIn("Database.GetRaidQueriesOrNil()", sync_payload)
        self.assertNotIn("if queries and queries.ResolveLootLooterNameFromMap then", sync_payload)
        self.assertNotIn('return ""\nend\n\nlocal function resolveLootLooterRef', sync_payload)

    def test_db_sync_payload_uses_validated_raid_store_methods_without_optional_method_guards(self):
        sync_payload = read(DB_SYNC_PAYLOAD)

        self.assertIn('Database.GetRaidStoreOrNil("DBSyncPayload.Build", { "GetRaidSyncRevision" })', sync_payload)
        self.assertIn('"DBSyncPayload.BuildDelta"', sync_payload)
        self.assertIn('{ "GetRaidSyncRevision", "GetLootSyncRevision", "RequiresFullSyncSince" }', sync_payload)
        self.assertIn("raidStore:GetRaidSyncRevision(raid)", sync_payload)
        self.assertIn("raidStore:GetLootSyncRevision(raid, row)", sync_payload)
        self.assertIn("raidStore:RequiresFullSyncSince(raid, fromRevision)", sync_payload)
        self.assertNotIn("raidStore and raidStore.GetRaidSyncRevision", sync_payload)
        self.assertNotIn("raidStore and raidStore.GetLootSyncRevision", sync_payload)
        self.assertNotIn("raidStore and raidStore.RequiresFullSyncSince", sync_payload)

    def test_db_sync_import_uses_declared_database_runtime_cache_owner_without_optional_guard(self):
        sync_import = read(DB_SYNC_IMPORT)

        self.assertIn('"Database/DBRaidStore"', sync_import)
        self.assertIn("Database.StripRuntimeRaidCaches(raid)", sync_import)
        self.assertIn("Database.EnsureRaidSchema(raid)", sync_import)
        self.assertNotIn("if Database and Database.StripRuntimeRaidCaches then", sync_import)

    def test_db_sync_import_uses_validated_raid_store_revision_methods_without_optional_method_guards(self):
        sync_import = read(DB_SYNC_IMPORT)

        self.assertIn('Database.GetRaidStoreOrNil("DBSyncImport.ApplySnapshotToRaid", { "SetRaidSyncRevision" })', sync_import)
        self.assertIn('"DBSyncImport.ApplyDeltaToRaid"', sync_import)
        self.assertIn('{ "SetRaidSyncRevision", "SetLootSyncRevision" }', sync_import)
        self.assertIn("raidStore:SetRaidSyncRevision(raid,", sync_import)
        self.assertRegex(sync_import, r"raidStore:SetLootSyncRevision\(\s*raid,\s*dst,")
        self.assertNotIn("raidStore and raidStore.SetRaidSyncRevision", sync_import)
        self.assertNotIn("raidStore and raidStore.SetLootSyncRevision", sync_import)

    def test_db_syncer_depends_on_dboptions_without_local_fallback(self):
        syncer = read(DB_SYNCER)

        self.assertIn('"Database/DBOptions"', syncer)
        self.assertIn("local isDebugEnabled = Options.IsDebugEnabled", syncer)
        self.assertNotRegex(syncer, r"local\s+isDebugEnabled\s*=\s*Options\.IsDebugEnabled\s+or\s+function")

    def test_db_syncer_depends_on_comms_without_sender_normalization_fallback(self):
        syncer = read(DB_SYNCER)

        self.assertIn('"Modules/Comms"', syncer)
        self.assertIn('local Payload = assert(Comms.Payload, "Comms payload helpers are not initialized")', syncer)
        self.assertIn("local normalizeSender = assert(", syncer)
        self.assertIn("Comms.NormalizeSender", syncer)
        self.assertIn('"DBSync sender normalizer is not initialized"', syncer)
        self.assertNotIn("Comms and Comms.Payload", syncer)
        self.assertNotIn("Comms and Comms.NormalizeSender", syncer)
        self.assertNotRegex(
            syncer,
            r"local\s+normalizeSender\s*=\s*Comms\.NormalizeSender\s+or\s+function",
        )

    def test_db_syncer_depends_on_wow_time_and_raid_count_without_zero_fallbacks(self):
        syncer = read(DB_SYNCER)

        self.assertIn("local GetTime = assert(", syncer)
        self.assertIn("_G.GetTime", syncer)
        self.assertIn('"DBSyncer time API is not initialized"', syncer)
        self.assertIn("local GetNumRaidMembers = assert(", syncer)
        self.assertIn("_G.GetNumRaidMembers", syncer)
        self.assertIn('"DBSyncer raid member count API is not initialized"', syncer)
        self.assertIn("tonumber(GetNumRaidMembers()) or 0", syncer)
        self.assertNotIn("Client.GetRaidMemberCount()", syncer)
        self.assertIn("local GetRaidRosterInfo = assert(", syncer)
        self.assertIn("_G.GetRaidRosterInfo", syncer)
        self.assertIn('"DBSyncer raid roster API is not initialized"', syncer)
        self.assertNotIn("return (GetTime and GetTime()) or 0", syncer)
        self.assertNotIn("GetNumRaidMembers and GetNumRaidMembers()", syncer)
        self.assertNotIn("local GetRaidRosterInfo = _G.GetRaidRosterInfo", syncer)

    def test_db_syncer_uses_raid_capability_owner_without_rank_fallback_for_raid_answers(self):
        syncer = read(DB_SYNCER)

        self.assertIn("local raidService = assert(Services.Raid", syncer)
        self.assertIn('"DBSyncer raid service is not initialized"', syncer)
        self.assertRegex(syncer, r"local\s+CanUseCapability\s*=\s*assert\(")
        self.assertIn("raidService.CanUseCapability", syncer)
        self.assertIn('"DBSyncer raid capability resolver is not initialized"', syncer)
        self.assertIn('return CanUseCapability(raidService, "raid_leadership") == true', syncer)
        self.assertNotIn("local raidService = Services and Services.Raid or nil", syncer)
        self.assertNotIn('return Database.GetUnitRank("player", 0) > 0', syncer)

    def test_db_syncer_binds_persistent_sync_callbacks_without_optional_event_fallbacks(self):
        syncer = read(DB_SYNCER)

        self.assertIn('"Modules/Events"', syncer)
        self.assertIn('"Modules/Bus"', syncer)
        self.assertIn("local InternalEvents = assert(Events.Internal", syncer)
        self.assertIn('"DBSyncer internal events are not initialized"', syncer)
        self.assertIn("local RegisterCallback = assert(", syncer)
        self.assertIn("Bus.RegisterCallback", syncer)
        self.assertIn('"DBSyncer event bus listener is not initialized"', syncer)
        self.assertIn("local GetConfigOptionChanged =", syncer)
        self.assertIn("Events.GetConfigOptionChanged", syncer)
        self.assertIn('"DBSyncer config event resolver is not initialized"', syncer)
        self.assertIn("local OptionsLoadedEvent = assert(", syncer)
        self.assertIn("InternalEvents.OptionsLoaded", syncer)
        self.assertIn('"DBSyncer options-loaded event is not initialized"', syncer)
        self.assertIn("local RaidCreateEvent = assert(", syncer)
        self.assertIn("InternalEvents.RaidCreate", syncer)
        self.assertIn('"DBSyncer raid-create event is not initialized"', syncer)
        self.assertIn("RegisterCallback(OptionsLoadedEvent, function()", syncer)
        self.assertIn('local persistentSyncEvent = GetConfigOptionChanged("persistentSync")', syncer)
        self.assertIn("RegisterCallback(persistentSyncEvent, function()", syncer)
        self.assertIn("RegisterCallback(RaidCreateEvent, function()", syncer)
        self.assertNotIn("not (Bus and Bus.RegisterCallback)", syncer)
        self.assertNotIn('or "ConfigpersistentSync"', syncer)
        self.assertNotIn("Events.GetConfigOptionChanged and Events.GetConfigOptionChanged", syncer)
        self.assertNotIn("local InternalEvents = Events.Internal", syncer)
        self.assertNotIn("Bus.RegisterCallback(InternalEvents.", syncer)

    def test_db_syncer_emits_logger_select_raid_through_validated_publisher(self):
        syncer = read(DB_SYNCER)

        self.assertIn('"Modules/Events"', syncer)
        self.assertIn('"Modules/Bus"', syncer)
        self.assertIn("local InternalEvents = assert(Events.Internal", syncer)
        self.assertIn('"DBSyncer internal events are not initialized"', syncer)
        self.assertIn("local TriggerEvent = assert(", syncer)
        self.assertIn("Bus.TriggerEvent", syncer)
        self.assertIn('"DBSyncer event publisher is not initialized"', syncer)
        self.assertIn("local LoggerSelectRaidEvent =", syncer)
        self.assertIn("InternalEvents.LoggerSelectRaid", syncer)
        self.assertIn('"DBSyncer logger-select-raid event is not initialized"', syncer)
        self.assertIn('TriggerEvent(LoggerSelectRaidEvent, selectedRaid, "sync")', syncer)
        self.assertNotIn("local InternalEvents = Events.Internal", syncer)
        self.assertNotIn("Bus.TriggerEvent(InternalEvents.LoggerSelectRaid", syncer)

    def test_db_syncer_depends_on_timer_mixin_without_persistent_sync_scheduler_fallback(self):
        syncer = read(DB_SYNCER)

        self.assertIn('"Modules/Timer"', syncer)
        self.assertIn("local BindTimerMixin = assert(", syncer)
        self.assertIn("Timer.BindMixin", syncer)
        self.assertIn('"DBSyncer timer mixin is not initialized"', syncer)
        self.assertIn('BindTimerMixin(module, "Database/DBSyncer")', syncer)
        self.assertIn("local ScheduleTimer = assert(", syncer)
        self.assertIn("module.ScheduleTimer", syncer)
        self.assertIn('"DBSyncer persistent-sync scheduler is not initialized"', syncer)
        self.assertIn("local CancelTimer = assert(", syncer)
        self.assertIn("module.CancelTimer", syncer)
        self.assertIn('"DBSyncer persistent-sync canceler is not initialized"', syncer)
        self.assertIn("CancelTimer(module, module._persistentSyncHandle)", syncer)
        self.assertIn("module._persistentSyncHandle = ScheduleTimer(module, function()", syncer)
        self.assertNotIn("if Timer and Timer.BindMixin then", syncer)
        self.assertNotIn('Timer.BindMixin(module, "Database/DBSyncer")', syncer)
        self.assertNotIn("module._persistentSyncHandle and module.CancelTimer", syncer)
        self.assertNotIn("or not module.ScheduleTimer", syncer)
        self.assertNotIn("module:ScheduleTimer(function()", syncer)

    def test_init_routes_raid_service_without_private_pass_through(self):
        init = read(INIT)

        self.assertIn('local function getService(serviceName)', init)
        self.assertNotIn('local function getRaidService()', init)
        self.assertNotIn('getRaidService()', init)
        self.assertIn('getService("Raid")', init)

    def test_init_forwards_roster_delta_through_validated_internal_event(self):
        init = read(INIT)

        self.assertIn("local Events = feature.Events", init)
        self.assertIn("local Bus = feature.Bus", init)
        self.assertIn("local InternalEvents = assert(Events.Internal", init)
        self.assertIn('"RMA internal events are not initialized"', init)
        self.assertIn("InternalEvents.RaidRosterDelta", init)
        self.assertIn("Bus.TriggerEvent(", init)
        self.assertNotIn("local InternalEvents = Events.Internal", init)

    def test_debug_service_uses_service_owners_without_private_pass_throughs(self):
        debug_service = read(DEBUG_SERVICE)

        self.assertNotIn("local function getRaidService()", debug_service)
        self.assertNotIn("local function getRollsService()", debug_service)
        self.assertNotIn("getRaidService()", debug_service)
        self.assertNotIn("getRollsService()", debug_service)
        self.assertIn("Services.Raid", debug_service)
        self.assertIn("Services.Rolls", debug_service)

    def test_debug_service_depends_on_dboptions_without_local_fallbacks(self):
        debug_service = read(DEBUG_SERVICE)

        self.assertIn('"Database/DBOptions"', debug_service)
        self.assertIn("local GetOption = Options.GetValue", debug_service)
        self.assertIn("local IsDebugEnabled = Options.IsDebugEnabled", debug_service)
        self.assertNotIn("local GetOption = Options.GetValue\n\t\tor function", debug_service)
        self.assertNotIn("local GetOption = Options.GetValue\r\n\t\tor function", debug_service)
        self.assertNotIn("local IsDebugEnabled = Options.IsDebugEnabled or function", debug_service)

    def test_debug_service_uses_declared_database_current_raid_without_optional_guard(self):
        debug_service = read(DEBUG_SERVICE)

        self.assertIn('"Database/DB"', debug_service)
        self.assertIn("return Database.GetCurrentRaid()", debug_service)
        self.assertNotIn("Database.GetCurrentRaid and Database.GetCurrentRaid() or nil", debug_service)

    def test_debug_service_depends_on_strings_without_local_normalization_fallbacks(self):
        debug_service = read(DEBUG_SERVICE)

        self.assertIn('"Modules/Strings"', debug_service)
        self.assertIn("local NormalizeName = assert(", debug_service)
        self.assertIn("Strings.NormalizeName", debug_service)
        self.assertIn('"Debug synthetic name normalizer is not initialized"', debug_service)
        self.assertIn("local NormalizeLower = assert(", debug_service)
        self.assertIn("Strings.NormalizeLower", debug_service)
        self.assertIn('"Debug mode normalizer is not initialized"', debug_service)
        self.assertNotIn("Strings and Strings.NormalizeName and Strings.NormalizeName(name, true) or name", debug_service)
        self.assertNotIn("Strings and Strings.NormalizeLower and Strings.NormalizeLower(mode, true) or nil", debug_service)

    def test_spec_inspect_depends_on_wotlk_identity_apis_without_local_fallbacks(self):
        spec_inspect = read(SPEC_INSPECT)

        self.assertIn("local GetTime = assert(", spec_inspect)
        self.assertIn("_G.GetTime", spec_inspect)
        self.assertIn('"SpecInspect time API is not initialized"', spec_inspect)
        self.assertIn("local UnitGUID = assert(", spec_inspect)
        self.assertIn("_G.UnitGUID", spec_inspect)
        self.assertIn('"SpecInspect unit GUID API is not initialized"', spec_inspect)
        self.assertNotRegex(
            spec_inspect,
            r"local\s+GetTime\s*=\s*GetTime\s+or\s+addon\.GetTime\s+or\s+_G\.GetTime\s+or\s+function",
        )
        self.assertNotRegex(
            spec_inspect,
            r"local\s+UnitGUID\s*=\s*UnitGUID\s+or\s+addon\.UnitGUID\s+or\s+_G\.UnitGUID\s+or\s+function",
        )

    def test_spec_inspect_depends_on_strings_without_local_normalization_fallback(self):
        spec_inspect = read(SPEC_INSPECT)

        self.assertIn('"Modules/Strings"', spec_inspect)
        self.assertIn("local NormalizeName = assert(", spec_inspect)
        self.assertIn("Strings.NormalizeName", spec_inspect)
        self.assertIn('"SpecInspect name normalizer is not initialized"', spec_inspect)
        self.assertNotIn('type(Strings) == "table" and type(Strings.NormalizeName) == "function"', spec_inspect)
        self.assertNotIn("return Strings.NormalizeName(name, true)", spec_inspect)
        self.assertNotIn("return name\nend\n\nlocal function isNonEmptyString", spec_inspect)

    def test_spec_inspect_binds_and_emits_events_without_optional_bus_guards(self):
        spec_inspect = read(SPEC_INSPECT)

        self.assertIn('"Modules/Events"', spec_inspect)
        self.assertIn('"Modules/Bus"', spec_inspect)
        self.assertIn("local InternalEvents = assert(Events.Internal", spec_inspect)
        self.assertIn('"SpecInspect internal events are not initialized"', spec_inspect)
        self.assertIn("local TriggerEvent = assert(", spec_inspect)
        self.assertIn("Bus.TriggerEvent", spec_inspect)
        self.assertIn('"SpecInspect event publisher is not initialized"', spec_inspect)
        self.assertIn("local RegisterCallback = assert(", spec_inspect)
        self.assertIn("Bus.RegisterCallback", spec_inspect)
        self.assertIn('"SpecInspect event bus listener is not initialized"', spec_inspect)
        self.assertIn("local SpecInspectUpdatedEvent =", spec_inspect)
        self.assertIn("InternalEvents.SpecInspectUpdated", spec_inspect)
        self.assertIn('"SpecInspect update event is not initialized"', spec_inspect)
        self.assertIn("local ReadyCheckEvent =", spec_inspect)
        self.assertIn('Events.GetWowForwarded("READY_CHECK")', spec_inspect)
        self.assertIn('"SpecInspect ready-check event is not initialized"', spec_inspect)
        self.assertIn("TriggerEvent(SpecInspectUpdatedEvent, snapshot.name, snapshot, reason)", spec_inspect)
        self.assertIn("RegisterCallback(ReadyCheckEvent, function()", spec_inspect)
        self.assertNotIn("InternalEvents and InternalEvents.SpecInspectUpdated", spec_inspect)
        self.assertNotIn("local InternalEvents = Events.Internal", spec_inspect)
        self.assertNotIn("if eventName then", spec_inspect)
        self.assertNotIn("Bus.TriggerEvent(eventName", spec_inspect)
        self.assertNotIn("if readyCheckEvent then", spec_inspect)
        self.assertNotIn("Bus.RegisterCallback(readyCheckEvent", spec_inspect)

    def test_equip_inspect_depends_on_wotlk_identity_apis_without_local_fallbacks(self):
        equip_inspect = read(EQUIP_INSPECT)

        self.assertIn("local GetTime = assert(", equip_inspect)
        self.assertIn("_G.GetTime", equip_inspect)
        self.assertIn('"EquipInspect time API is not initialized"', equip_inspect)
        self.assertIn("local UnitGUID = assert(", equip_inspect)
        self.assertIn("_G.UnitGUID", equip_inspect)
        self.assertIn('"EquipInspect unit GUID API is not initialized"', equip_inspect)
        self.assertNotRegex(
            equip_inspect,
            r"local\s+GetTime\s*=\s*GetTime\s+or\s+function",
        )
        self.assertNotRegex(
            equip_inspect,
            r"local\s+UnitGUID\s*=\s*UnitGUID\s+or\s+noop",
        )

    def test_equip_inspect_depends_on_wotlk_eligibility_apis_without_local_fallbacks(self):
        equip_inspect = read(EQUIP_INSPECT)

        required_apis = {
            "UnitExists": "unit existence API",
            "UnitIsConnected": "unit connection API",
            "CheckInteractDistance": "unit range API",
            "CanInspect": "inspect capability API",
            "UnitAffectingCombat": "combat state API",
        }
        for api_name, message_fragment in required_apis.items():
            self.assertRegex(equip_inspect, rf"local\s+{api_name}\s*=\s*assert\(")
            self.assertIn(f"_G.{api_name}", equip_inspect)
            self.assertIn(f'"EquipInspect {message_fragment} is not initialized"', equip_inspect)
            self.assertNotRegex(
                equip_inspect,
                rf"local\s+{api_name}\s*=\s*{api_name}\s+or\s+noop",
            )

    def test_equip_inspect_depends_on_wotlk_lifecycle_apis_without_local_fallbacks(self):
        equip_inspect = read(EQUIP_INSPECT)

        required_apis = {
            "NotifyInspect": "notify inspect API",
            "ClearInspectPlayer": "clear inspect API",
        }
        for api_name, message_fragment in required_apis.items():
            self.assertRegex(equip_inspect, rf"local\s+{api_name}\s*=\s*assert\(")
            self.assertIn(f"_G.{api_name}", equip_inspect)
            self.assertIn(f'"EquipInspect {message_fragment} is not initialized"', equip_inspect)
            self.assertNotRegex(
                equip_inspect,
                rf"local\s+{api_name}\s*=\s*{api_name}\s+or\s+noop",
            )
        self.assertNotIn("if ClearInspectPlayer then", equip_inspect)
        self.assertIn("pcall(ClearInspectPlayer)", equip_inspect)

    def test_equip_inspect_depends_on_wotlk_item_apis_without_local_fallbacks(self):
        equip_inspect = read(EQUIP_INSPECT)

        required_apis = {
            "GetInventoryItemLink": "inventory item link API",
            "GetInventoryItemTexture": "inventory item texture API",
            "GetInventoryItemQuality": "inventory item quality API",
            "GetItemInfo": "item info API",
        }
        for api_name, message_fragment in required_apis.items():
            self.assertRegex(equip_inspect, rf"local\s+{api_name}\s*=\s*assert\(")
            self.assertIn(f"_G.{api_name}", equip_inspect)
            self.assertIn(f'"EquipInspect {message_fragment} is not initialized"', equip_inspect)
            self.assertNotRegex(
                equip_inspect,
                rf"local\s+{api_name}\s*=\s*{api_name}\s+or\s+noop",
            )
        self.assertNotIn("local function noop()", equip_inspect)

    def test_equip_inspect_binds_declared_events_without_optional_callback_guards(self):
        equip_inspect = read(EQUIP_INSPECT)

        self.assertIn('"Modules/Events"', equip_inspect)
        self.assertIn('"Modules/Bus"', equip_inspect)
        self.assertIn("local RegisterCallback = assert(", equip_inspect)
        self.assertIn("Bus.RegisterCallback", equip_inspect)
        self.assertIn('"EquipInspect event bus listener is not initialized"', equip_inspect)
        self.assertIn("local GetWowForwarded = assert(", equip_inspect)
        self.assertIn("Events.GetWowForwarded", equip_inspect)
        self.assertIn('"EquipInspect forwarded-event resolver is not initialized"', equip_inspect)
        self.assertIn("local RaidCreateEvent = assert(", equip_inspect)
        self.assertIn("InternalEvents.RaidCreate", equip_inspect)
        self.assertIn('"EquipInspect raid-create event is not initialized"', equip_inspect)
        self.assertIn('assert(GetWowForwarded("INSPECT_TALENT_READY")', equip_inspect)
        self.assertIn('"EquipInspect talent-ready event is not initialized"', equip_inspect)
        self.assertIn('assert(GetWowForwarded("PLAYER_REGEN_ENABLED")', equip_inspect)
        self.assertIn('"EquipInspect regen-enabled event is not initialized"', equip_inspect)
        self.assertIn("RegisterCallback(inspectReadyEvent, function(_, guid)", equip_inspect)
        self.assertIn("RegisterCallback(playerRegenEnabledEvent, function()", equip_inspect)
        self.assertIn("RegisterCallback(RaidCreateEvent, function(_, raidId)", equip_inspect)
        self.assertNotIn("if Bus and Bus.RegisterCallback", equip_inspect)
        self.assertNotIn("Bus.RegisterCallback(inspectReadyEvent", equip_inspect)
        self.assertNotIn("Events.GetWowForwarded(\"INSPECT_TALENT_READY\")", equip_inspect)

    def test_equip_inspect_emits_declared_events_through_validated_publisher(self):
        equip_inspect = read(EQUIP_INSPECT)

        self.assertIn('"Modules/Events"', equip_inspect)
        self.assertIn('"Modules/Bus"', equip_inspect)
        self.assertIn("local InternalEvents = assert(Events.Internal", equip_inspect)
        self.assertIn('"EquipInspect internal events are not initialized"', equip_inspect)
        self.assertIn("local TriggerEvent = assert(", equip_inspect)
        self.assertIn("Bus.TriggerEvent", equip_inspect)
        self.assertIn('"EquipInspect event publisher is not initialized"', equip_inspect)
        self.assertIn("local EquipInspectStartedEvent =", equip_inspect)
        self.assertIn("InternalEvents.EquipInspectStarted", equip_inspect)
        self.assertIn('"EquipInspect started event is not initialized"', equip_inspect)
        self.assertIn("local EquipInspectCompletedEvent =", equip_inspect)
        self.assertIn("InternalEvents.EquipInspectCompleted", equip_inspect)
        self.assertIn('"EquipInspect completed event is not initialized"', equip_inspect)
        self.assertIn("local EquipInspectUpdatedEvent =", equip_inspect)
        self.assertIn("InternalEvents.EquipInspectUpdated", equip_inspect)
        self.assertIn('"EquipInspect update event is not initialized"', equip_inspect)
        self.assertIn("TriggerEvent(EquipInspectStartedEvent, raidId, reason or \"start\")", equip_inspect)
        self.assertIn("TriggerEvent(EquipInspectCompletedEvent, raidId)", equip_inspect)
        self.assertIn("TriggerEvent(EquipInspectUpdatedEvent, raidId, playerNid, snapshot)", equip_inspect)
        self.assertNotIn("local InternalEvents = Events.Internal", equip_inspect)
        self.assertNotIn("Bus.TriggerEvent(InternalEvents.EquipInspectStarted", equip_inspect)
        self.assertNotIn("Bus.TriggerEvent(InternalEvents.EquipInspectCompleted", equip_inspect)
        self.assertNotIn("Bus.TriggerEvent(InternalEvents.EquipInspectUpdated", equip_inspect)

    def test_master_controller_depends_on_dboptions_without_local_fallback(self):
        master = read(MASTER_CONTROLLER)

        self.assertIn('"Database/DBOptions"', master)
        self.assertIn("local GetOption = Options.GetValue", master)
        self.assertIn("local isDebugEnabled = Options.IsDebugEnabled", master)
        self.assertNotRegex(master, r"local\s+GetOption\s*=\s*Options\.GetValue\s+or\s+function")
        self.assertNotRegex(master, r"local\s+isDebugEnabled\s*=\s*Options\.IsDebugEnabled\s+or\s+function")

    def test_master_controller_depends_on_wotlk_unit_name_api_without_local_optional_branch(self):
        master = read(MASTER_CONTROLLER)

        self.assertIn("local UnitName = assert(", master)
        self.assertIn("_G.UnitName", master)
        self.assertIn('"Master controller unit name API is not initialized"', master)
        self.assertNotIn("local unitName = _G.UnitName", master)
        self.assertNotIn('type(unitName) ~= "function"', master)
        self.assertNotIn('unitName("target")', master)

    def test_master_controller_depends_on_wotlk_master_loot_candidate_api_without_local_fallback(self):
        master = read(MASTER_CONTROLLER)

        self.assertIn("local GetMasterLootCandidate =", master)
        self.assertIn("assert(_G.GetMasterLootCandidate", master)
        self.assertIn("_G.GetMasterLootCandidate", master)
        self.assertIn('"Master controller loot candidate API is not initialized"', master)
        self.assertNotIn('type(GetMasterLootCandidate) ~= "function"', master)

    def test_master_controller_depends_on_wotlk_loot_slot_info_api_without_selected_item_fallback(self):
        master = read(MASTER_CONTROLLER)

        self.assertIn("local GetLootSlotInfo =", master)
        self.assertIn("assert(_G.GetLootSlotInfo", master)
        self.assertIn("_G.GetLootSlotInfo", master)
        self.assertIn('"Master controller loot slot info API is not initialized"', master)
        self.assertNotIn("slot and GetLootSlotInfo", master)

    def test_master_controller_uses_loot_service_item_link_without_selected_item_fallback(self):
        master = read(MASTER_CONTROLLER)

        self.assertIn('local Loot = assert(Services.Loot, "Master loot service is not initialized")', master)
        self.assertIn("return Loot.GetItemLink()", master)
        self.assertNotIn("if Loot and Loot.GetItemLink then", master)

    def test_master_controller_writes_logger_loot_through_actions_service(self):
        master = read(MASTER_CONTROLLER)

        self.assertIn('"Services/Logger/Actions"', master)
        self.assertIn(
            'local LoggerActions = assert(Services.Logger.Actions, "Master logger actions service is not initialized")',
            master,
        )
        self.assertIn("return LoggerActions:RecordLoot({", master)
        self.assertNotIn("LoggerLootLogRequest", master)
        self.assertNotIn("request.ok", master)

    def test_master_controller_registers_bus_callbacks_through_validated_listener(self):
        master = read(MASTER_CONTROLLER)

        self.assertIn("local RegisterCallback = assert(", master)
        self.assertIn("Bus.RegisterCallback", master)
        self.assertIn('"Master controller event listener is not initialized"', master)
        self.assertIn("local GetWowForwarded = assert(", master)
        self.assertIn("Events.GetWowForwarded", master)
        self.assertIn('"Master controller forwarded-event resolver is not initialized"', master)
        self.assertIn("local MasterEvents = {", master)
        for event_name in (
            "GroupLootRestoreNeeded",
            "SetItem",
            "RaidRosterDelta",
            "ReservesDataChanged",
            "AddRoll",
            "ConfigSortAscending",
            "ConfigShowLootCounterDuringMSRoll",
            "SpecInspectUpdated",
        ):
            self.assertIn(f"{event_name} = assert(", master)
            self.assertIn(f"RegisterCallback(MasterEvents.{event_name}", master)

        self.assertIn("RegisterCallback(GetWowForwarded(methodName)", master)
        self.assertNotIn("Bus.RegisterCallback(InternalEvents.", master)
        self.assertNotIn("Bus.RegisterCallback(Events.GetWowForwarded and Events.GetWowForwarded", master)

    def test_master_trade_uses_database_player_name_without_optional_function_guard(self):
        trade = read(MASTER_TRADE)

        self.assertIn('"Database/DB"', trade)
        self.assertIn("local currentPlayer = normalizeName(Database.GetPlayerName())", trade)
        self.assertNotIn('type(Database.GetPlayerName) == "function"', trade)

    def test_master_trade_uses_declared_raid_store_without_optional_guard(self):
        trade = read(MASTER_TRADE)

        self.assertIn('"Database/DBRaidStore"', trade)
        self.assertIn("return Database.EnsureRaidById(raidNum)", trade)
        self.assertNotIn("if Database.EnsureRaidById then", trade)

    def test_master_trade_writes_loot_through_logger_actions(self):
        trade = read(MASTER_TRADE)

        self.assertIn('"Services/Logger/Actions"', trade)
        self.assertIn(
            'local LoggerActions = assert(Services.Logger.Actions, "Master trade logger actions service is not initialized")',
            trade,
        )
        self.assertIn("local ok = LoggerActions:RecordLoot({", trade)
        self.assertNotIn("LoggerLootLogRequest", trade)
        self.assertNotIn("request.ok", trade)
        self.assertNotIn('"Modules/Bus"', trade)
        self.assertNotIn('"Modules/Events"', trade)

    def test_master_award_counter_depends_on_item_without_local_key_fallback(self):
        award_counter = read(MASTER_AWARD_COUNTER)

        self.assertIn('"Modules/Item"', award_counter)
        self.assertIn("local GetItemStringFromLink =", award_counter)
        self.assertIn("assert(Item.GetItemStringFromLink,", award_counter)
        self.assertIn("Item.GetItemStringFromLink", award_counter)
        self.assertIn('"Master award counter item-key resolver is not initialized"', award_counter)
        self.assertIn("return GetItemStringFromLink(itemLink) or itemLink", award_counter)
        self.assertNotIn("Item and Item.GetItemStringFromLink", award_counter)

    def test_logger_depends_on_wotlk_item_icon_api_without_local_fallback(self):
        logger = read(LOGGER_CONTROLLER)

        self.assertIn("local GetItemIcon = assert(", logger)
        self.assertIn("_G.GetItemIcon", logger)
        self.assertIn('"Logger item icon API is not initialized"', logger)
        self.assertIn("local CreateFrame = assert(", logger)
        self.assertIn("_G.CreateFrame", logger)
        self.assertIn('"Logger frame creation API is not initialized"', logger)
        self.assertIn("local UIParent = assert(", logger)
        self.assertIn("_G.UIParent", logger)
        self.assertIn('"Logger root UI parent is not initialized"', logger)
        self.assertNotRegex(
            logger,
            r"local\s+GetItemIcon\s*=\s*_G\.GetItemIcon\s+or\s+function",
        )

    def test_logger_controller_routes_bus_events_through_validated_contract(self):
        logger = read(LOGGER_CONTROLLER)
        attendance = read(ATTENDANCE_CONTROLLER)

        self.assertIn("local InternalEvents = assert(Events.Internal", logger)
        self.assertIn("local TriggerEvent = assert(", logger)
        self.assertIn("Bus.TriggerEvent", logger)
        self.assertIn('"Logger controller event publisher is not initialized"', logger)
        self.assertIn("local RegisterCallback = assert(", logger)
        self.assertIn("Bus.RegisterCallback", logger)
        self.assertIn('"Logger controller event listener is not initialized"', logger)
        self.assertIn("local LoggerEvents = {", logger)

        for event_name in (
            "RaidCreate",
            "LoggerSelectRaid",
            "LoggerSelectBoss",
            "LoggerSelectPlayer",
            "LoggerSelectBossPlayer",
            "LoggerSelectItem",
            "LoggerLootChanged",
            "RaidLootUpdate",
        ):
            self.assertIn(f"{event_name} = assert(", logger)

        self.assertIn("TriggerEvent(eventName, target[key], ...)", logger)
        self.assertIn("TriggerEvent(refreshEvent or LoggerEvents.LoggerSelectRaid, module.selectedRaid)", logger)
        self.assertIn("RegisterCallback(LoggerEvents.LoggerLootChanged", logger)
        for event_name in ("RaidCreate", "EquipInspectUpdated", "EquipInspectCompleted", "RaidAttendanceChanged"):
            self.assertIn(f"{event_name} = assert(", attendance)
        self.assertIn("RegisterCallback(AttendanceEvents.RaidAttendanceChanged", attendance)
        self.assertNotIn("Bus.TriggerEvent(eventName, target[key], ...)", logger)
        self.assertNotIn("Bus.TriggerEvent(refreshEvent or InternalEvents.LoggerSelectRaid", logger)
        self.assertNotIn("Bus.RegisterCallback(InternalEvents.", logger)

    def test_logger_services_depend_on_time_owner_without_raw_time_fallback(self):
        actions = read(LOGGER_ACTIONS)
        view = read(LOGGER_VIEW)

        self.assertIn("local GetCurrentTime = assert(", actions)
        self.assertIn("Time.GetCurrentTime", actions)
        self.assertIn('"Logger actions time provider is not initialized"', actions)
        self.assertIn('"Modules/Time"', actions)
        self.assertNotIn("local time = time", actions)
        self.assertNotIn("or time()", actions)

        self.assertNotIn("local GetCurrentTime = assert(", view)
        self.assertNotIn("Time.GetCurrentTime", view)
        self.assertNotIn('"Logger view time provider is not initialized"', view)
        self.assertNotIn('"Modules/Time"', view)
        self.assertNotIn("date, time = date, time", view)
        self.assertNotIn("or time()", view)

    def test_logger_actions_uses_database_current_raid_without_optional_guard(self):
        actions = read(LOGGER_ACTIONS)

        self.assertIn('"Database/DB"', actions)
        self.assertIn("local currentRaid = Database.GetCurrentRaid()", actions)
        self.assertNotIn("Database.GetCurrentRaid and Database.GetCurrentRaid() or nil", actions)

    def test_logger_actions_uses_raid_store_database_facade_without_store_lookup_fallbacks(self):
        actions = read(LOGGER_ACTIONS)

        self.assertIn('"Database/DBRaidStore"', actions)
        self.assertIn("getCurrentRaidNid = function()", actions)
        self.assertIn("return Database.GetRaidNidById(currentRaid)", actions)
        self.assertIn("restoreCurrentRaidIndex = function(currentRaidNid)", actions)
        self.assertIn("local currentRaidId = Database.GetRaidIdByNid(currentRaidNid)", actions)
        self.assertIn("Database.SetCurrentRaid(currentRaidId)", actions)
        self.assertIn("Database.SetLastBoss(nil)", actions)
        self.assertNotIn("getCurrentRaidNid = function(raidStore)", actions)
        self.assertNotIn("restoreCurrentRaidIndex = function(raidStore, currentRaidNid)", actions)
        self.assertNotIn("if not Database.SetCurrentRaid then", actions)
        self.assertNotIn("if Database.SetLastBoss then", actions)
        self.assertNotIn("and Database.SetLastBoss", actions)
        self.assertNotIn("raidStore and raidStore.GetRaidNidByIndex", actions)
        self.assertNotIn("raidStore and raidStore.GetRaidIndexByNid", actions)

    def test_logger_actions_uses_declared_raid_queries_owner_without_optional_boss_lookup_guards(self):
        actions = read(LOGGER_ACTIONS)

        self.assertIn('"Database/DBRaidQueries"', actions)
        self.assertIn("local queries = Database.GetRaidQueries()", actions)
        self.assertNotIn("Database.GetRaidQueriesOrNil()", actions)
        self.assertNotIn("if queries and queries.FindBossByNid then", actions)
        self.assertNotIn("if queries and queries.FindBossByName then", actions)
        self.assertNotIn("if queries and queries.FindBossBySourceNpcId then", actions)
        self.assertNotIn("if queries and queries.FindBossBySourceKey then", actions)

    def test_logger_actions_uses_declared_raid_store_owner_without_optional_getter_guards(self):
        actions = read(LOGGER_ACTIONS)

        self.assertIn('"Database/DBRaidStore"', actions)
        self.assertIn("Database.EnsureRaidSchema(raid)", actions)
        self.assertNotIn("if Database.EnsureRaidSchema then", actions)
        expected_calls = [
            'Database.GetRaidStoreOrNil("Logger.Actions.MarkLootSyncRevision", { "MarkLootSyncRevision" })',
            'Database.GetRaidStoreOrNil("Logger.Actions.TouchRaidSyncRevision", { "TouchRaidSyncRevision" })',
            'Database.GetRaidStoreOrNil("Logger.Actions.GetRaidHistoryScan", requiredMethods)',
            'Database.GetRaidStoreOrNil("Logger.Actions.RemoveRaidHistoryEntries", requiredMethods)',
            'Database.GetRaidStoreOrNil("Logger.Actions.EnsureLootSources", requiredMethods)',
            'Database.GetRaidStoreOrNil("Logger.Actions.PurgeRaidHistory", requiredMethods)',
        ]
        for call in expected_calls:
            self.assertIn(call, actions)
        self.assertIn("raidStore:MarkLootSyncRevision(raid, loot, reason or \"loot\")", actions)
        self.assertIn("raidStore:TouchRaidSyncRevision(raid, reason or \"loot\")", actions)
        self.assertNotIn("Database\n\t\tand Database.GetRaidStoreOrNil", actions)
        self.assertNotIn("Database.GetRaidStoreOrNil\n\t\t\tand Database.GetRaidStoreOrNil", actions)
        self.assertNotIn("and Database.GetRaidStoreOrNil", actions)
        self.assertNotIn("raidStore and raidStore.MarkLootSyncRevision", actions)
        self.assertNotIn("raidStore and raidStore.TouchRaidSyncRevision", actions)

    def test_config_controller_uses_declared_logger_actions_owner_without_optional_service_guard(self):
        config = read(CONFIG_CONTROLLER)

        self.assertIn('"Services/Logger/Actions"', config)
        self.assertIn("local actions = Services.Logger.Actions", config)
        self.assertNotIn("local actions = Services and Services.Logger and Services.Logger.Actions or nil", config)

    def test_config_controller_binds_options_loaded_without_optional_callback_guard(self):
        config = read(CONFIG_CONTROLLER)

        self.assertIn('"Modules/Events"', config)
        self.assertIn('"Modules/Bus"', config)
        self.assertIn("local InternalEvents = assert(Events.Internal", config)
        self.assertIn('"Config internal events are not initialized"', config)
        self.assertIn("local RegisterCallback = assert(", config)
        self.assertIn("Bus.RegisterCallback", config)
        self.assertIn('"Config event bus listener is not initialized"', config)
        self.assertIn("local OptionsLoadedEvent = assert(", config)
        self.assertIn("InternalEvents.OptionsLoaded", config)
        self.assertIn('"Config options-loaded event is not initialized"', config)
        self.assertIn("RegisterCallback(OptionsLoadedEvent, function()", config)
        self.assertIn("registerInterfaceOptionsPanel()", config)
        self.assertNotIn("if Bus and Bus.RegisterCallback", config)
        self.assertNotIn("local InternalEvents = Events.Internal", config)
        self.assertNotIn("Bus.RegisterCallback(Events.Internal.OptionsLoaded", config)

    def test_config_controller_publishes_option_changes_without_optional_event_guards(self):
        config = read(CONFIG_CONTROLLER)

        self.assertIn("local TriggerEvent = assert(", config)
        self.assertIn("Bus.TriggerEvent", config)
        self.assertIn('"Config event bus sender is not initialized"', config)
        self.assertRegex(config, r"local\s+GetConfigOptionChanged\s*=\s*assert\(")
        self.assertIn("Events.GetConfigOptionChanged", config)
        self.assertIn('"Config option-change event resolver is not initialized"', config)
        self.assertIn("local eventName = GetConfigOptionChanged(key)", config)
        self.assertIn("local eventName = GetConfigOptionChanged(name)", config)
        self.assertIn("TriggerEvent(eventName, value)", config)
        self.assertNotIn("Events.GetConfigOptionChanged and Events.GetConfigOptionChanged", config)
        self.assertNotIn("Bus.TriggerEvent(eventName, value)", config)

    def test_config_controller_resets_defaults_through_declared_options_owner(self):
        config = read(CONFIG_CONTROLLER)

        self.assertIn("local GetOptionNamespaces = assert(", config)
        self.assertIn("Options.GetNamespaces", config)
        self.assertIn('"Config options namespace iterator is not initialized"', config)
        self.assertIn("local SetDebugEnabled = assert(", config)
        self.assertIn("Options.SetDebugEnabled", config)
        self.assertIn('"Config debug option setter is not initialized"', config)
        self.assertIn("for _, ns in pairs(GetOptionNamespaces()) do", config)
        self.assertIn("SetDebugEnabled(false)", config)
        self.assertNotIn("if Options and Options.GetNamespaces then", config)
        self.assertNotIn("Options.SetDebugEnabled(false)", config)

    def test_logger_store_uses_declared_raid_queries_owner_without_optional_looter_name_guard(self):
        store = read(LOGGER_STORE)

        self.assertIn('"Database/DBRaidQueries"', store)
        self.assertIn("local queries = Database.GetRaidQueries()", store)
        self.assertIn("return queries:ResolveLootLooterName(raid, loot)", store)
        self.assertNotIn("Database.GetRaidQueriesOrNil()", store)
        self.assertNotIn("if queries and queries.ResolveLootLooterName then", store)

    def test_logger_store_uses_declared_raid_store_cache_owner_without_manual_fallback(self):
        store = read(LOGGER_STORE)

        self.assertIn('"Database/DBRaidStore"', store)
        self.assertIn("Database.StripRuntimeRaidCaches(raid)", store)
        self.assertNotIn("if Database and Database.StripRuntimeRaidCaches then", store)
        self.assertNotIn("raid._runtime = nil", store)

    def test_logger_store_and_export_use_declared_store_owner_without_optional_method_guards(self):
        store = read(LOGGER_STORE)
        logger_export = read(LOGGER_EXPORT)

        self.assertIn("local Store = Logger.Store", store)
        self.assertIn("local Store = assert(Logger.Store", logger_export)
        self.assertIn('"Services/Logger/Store"', logger_export)
        self.assertIn("local player = Store:GetPlayer(raid, playerNid)", store)
        self.assertIn("local player = Store:GetPlayer(raid, selectedPlayerNid)", logger_export)
        self.assertIn("local boss = Store:GetBoss(raid, bossNid)", logger_export)
        self.assertNotIn("Store and Store.GetPlayer", store)
        self.assertNotIn("Store and Store.GetPlayer", logger_export)
        self.assertNotIn("Store and Store.GetBoss", logger_export)

    def test_loot_and_raid_services_use_declared_raid_store_cache_owner_without_manual_fallbacks(self):
        for source in (read(LOOT_SERVICE), read(RAID_STATE)):
            self.assertIn('"Database/DBRaidStore"', source)
            self.assertIn("Database.StripRuntimeRaidCaches(raid)", source)
            self.assertNotIn("if Database and Database.StripRuntimeRaidCaches then", source)
            self.assertNotIn("raid._runtime = nil", source)

    def test_reserves_ui_depends_on_wow_raid_time_and_unit_apis_without_local_fallbacks(self):
        reserves_ui = read(RESERVES_UI)

        self.assertIn("local GetTime = assert(", reserves_ui)
        self.assertIn("_G.GetTime", reserves_ui)
        self.assertIn('"Reserves UI time API is not initialized"', reserves_ui)
        self.assertIn("local GetNumRaidMembers = assert(", reserves_ui)
        self.assertIn("_G.GetNumRaidMembers", reserves_ui)
        self.assertIn('"Reserves UI raid member count API is not initialized"', reserves_ui)
        self.assertIn("tonumber(GetNumRaidMembers()) or 0", reserves_ui)
        self.assertIn("addon.IsInRaid()", reserves_ui)
        self.assertNotIn("Client.GetRaidMemberCount()", reserves_ui)
        self.assertNotIn("Client.IsInRaid()", reserves_ui)
        self.assertIn("local UnitName = assert(", reserves_ui)
        self.assertIn("_G.UnitName", reserves_ui)
        self.assertIn('"Reserves UI unit name API is not initialized"', reserves_ui)
        self.assertNotIn("local now = GetTime and GetTime() or nil", reserves_ui)
        self.assertNotIn('type(GetNumRaidMembers) == "function"', reserves_ui)
        self.assertNotIn("local unitName = _G.UnitName", reserves_ui)
        self.assertNotIn('type(unitName) == "function" and unitName("player") or nil', reserves_ui)

    def test_reserves_ui_binds_data_changed_event_without_direct_callback_lookup(self):
        reserves_ui = read(RESERVES_UI)

        self.assertIn('"Modules/Events"', reserves_ui)
        self.assertIn('"Modules/Bus"', reserves_ui)
        self.assertIn("local InternalEvents = assert(Events.Internal", reserves_ui)
        self.assertIn('"Reserves UI internal events are not initialized"', reserves_ui)
        self.assertIn("local RegisterCallback = assert(", reserves_ui)
        self.assertIn("Bus.RegisterCallback", reserves_ui)
        self.assertIn('"Reserves UI event bus listener is not initialized"', reserves_ui)
        self.assertIn("local ReservesDataChangedEvent =", reserves_ui)
        self.assertIn("InternalEvents.ReservesDataChanged", reserves_ui)
        self.assertIn('"Reserves UI data-changed event is not initialized"', reserves_ui)
        self.assertIn("RegisterCallback(ReservesDataChangedEvent, function()", reserves_ui)
        self.assertNotIn("local InternalEvents = Events.Internal", reserves_ui)
        self.assertNotIn("Bus.RegisterCallback(InternalEvents.ReservesDataChanged", reserves_ui)

    def test_comms_depends_on_wow_send_and_player_name_apis_without_local_fallbacks(self):
        comms = read(COMMS)

        self.assertIn("local SendAddonMessage = assert(", comms)
        self.assertIn("_G.SendAddonMessage", comms)
        self.assertIn('"Comms addon-message send API is not initialized"', comms)
        self.assertIn("local SendChatMessage = assert(", comms)
        self.assertIn("_G.SendChatMessage", comms)
        self.assertIn('"Comms chat send API is not initialized"', comms)
        self.assertIn("local GetAddOnMetadata = assert(", comms)
        self.assertIn("_G.GetAddOnMetadata", comms)
        self.assertIn('"Comms addon metadata API is not initialized"', comms)
        self.assertIn("local UnitName = assert(", comms)
        self.assertIn("_G.UnitName", comms)
        self.assertIn('"Comms unit name API is not initialized"', comms)
        self.assertIn("local IsInInstance = assert(", comms)
        self.assertIn("_G.IsInInstance", comms)
        self.assertIn('"Comms instance state API is not initialized"', comms)
        self.assertIn("local GetNumRaidMembers = assert(", comms)
        self.assertIn("local GetNumPartyMembers = assert(", comms)
        self.assertIn('"Comms raid member count API is not initialized"', comms)
        self.assertIn('"Comms party member count API is not initialized"', comms)
        self.assertIn("tonumber(GetNumRaidMembers()) or 0", comms)
        self.assertIn("tonumber(GetNumPartyMembers()) or 0", comms)
        self.assertIn("function Comms.RegisterPrefixIfAvailable(prefix)", comms)
        self.assertIn('if type(_G.RegisterAddonMessagePrefix) ~= "function" then', comms)
        self.assertIn("_G.RegisterAddonMessagePrefix(prefix)", comms)
        self.assertIn("Comms.RegisterPrefixIfAvailable(VERSION_PREFIX)", comms)
        self.assertNotIn("Client.GetRaidMemberCount()", comms)
        self.assertNotIn("Client.GetPartyMemberCount()", comms)
        self.assertNotIn("Client.RegisterAddonMessagePrefix", comms)
        self.assertNotIn("local RegisterAddonMessagePrefix = _G.RegisterAddonMessagePrefix", comms)
        self.assertNotIn("local function registerAddonMessagePrefix(prefix)", comms)
        self.assertNotIn('"Comms addon-message prefix registration API is not initialized"', comms)
        self.assertIn('"Modules/Strings"', comms)
        self.assertIn("local NormalizeName = assert(", comms)
        self.assertIn("Strings.NormalizeName", comms)
        self.assertIn('"Comms sender name normalizer is not initialized"', comms)
        self.assertIn("return NormalizeName(short, true) or short", comms)
        self.assertIn("local syncer = Database.GetSyncer()", comms)
        self.assertIn("local getter = Database.GetRaidSchemaVersion", comms)
        self.assertNotIn("local sender = _G.SendAddonMessage", comms)
        self.assertNotIn("local getter = _G.GetAddOnMetadata", comms)
        self.assertNotIn('if type(sender) ~= "function" then', comms)
        self.assertNotIn('if Strings and type(Strings.NormalizeName) == "function" then', comms)
        self.assertNotIn("Database and Database.GetSyncer and Database.GetSyncer()", comms)
        self.assertNotIn("local getter = Database and Database.GetRaidSchemaVersion", comms)
        self.assertNotIn('_G.UnitName and _G.UnitName("player") or nil', comms)
        self.assertNotIn("GetRealNumRaidMembers and GetRealNumRaidMembers()", comms)
        self.assertNotIn("GetNumRaidMembers and GetNumRaidMembers()", comms)
        self.assertNotIn("GetRealNumPartyMembers and GetRealNumPartyMembers()", comms)
        self.assertNotIn("GetNumPartyMembers and GetNumPartyMembers()", comms)
        self.assertNotIn("local register = _G.RegisterAddonMessagePrefix", comms)

    def test_comms_depends_on_timer_mixin_without_queue_scheduler_fallback(self):
        comms = read(COMMS)

        self.assertIn('"Modules/Timer"', comms)
        self.assertIn("local BindTimerMixin = assert(", comms)
        self.assertIn("Timer.BindMixin", comms)
        self.assertIn('"Comms timer mixin is not initialized"', comms)
        self.assertIn('BindTimerMixin(Comms, "Modules/Comms")', comms)
        self.assertIn("local ScheduleTimer = assert(", comms)
        self.assertIn("Comms.ScheduleTimer", comms)
        self.assertIn('"Comms addon-message queue scheduler is not initialized"', comms)
        self.assertIn("Comms._addonQueueTimer = ScheduleTimer(Comms, function()", comms)
        self.assertIn("if not (opts and opts.immediate == true) then", comms)
        self.assertNotIn("if Timer and Timer.BindMixin then", comms)
        self.assertNotIn('Timer.BindMixin(Comms, "Modules/Comms")', comms)
        self.assertNotIn('type(Comms.ScheduleTimer) ~= "function"', comms)
        self.assertNotIn('type(Comms.ScheduleTimer) == "function"', comms)
        self.assertNotIn('type(Comms.CancelTimer) == "function"', comms)

    def test_init_addon_message_uses_database_syncer_owner_without_optional_getter_guard(self):
        init = read(INIT)

        self.assertIn("local syncer = Database.GetSyncer()", init)
        self.assertNotIn("Database.GetSyncer and Database.GetSyncer()", init)

    def test_loot_source_candidates_depends_on_strings_without_key_fallback(self):
        candidates = read(LOOT_SOURCE_CANDIDATES)

        self.assertIn('"Modules/Strings"', candidates)
        self.assertIn("local NormalizeLower = assert(", candidates)
        self.assertIn("Strings.NormalizeLower", candidates)
        self.assertIn('"Loot source candidate normalizer is not initialized"', candidates)
        self.assertIn("return NormalizeLower(name, true) or name", candidates)
        self.assertNotIn("if Strings and Strings.NormalizeLower then", candidates)

    def test_loot_sources_depends_on_strings_without_local_text_fallbacks(self):
        loot_sources = read(LOOT_SOURCES)

        self.assertIn('"Modules/Strings"', loot_sources)
        self.assertIn("local TrimText = assert(", loot_sources)
        self.assertIn("Strings.TrimText", loot_sources)
        self.assertIn('"Loot source text trimmer is not initialized"', loot_sources)
        self.assertIn("local NormalizeLower = assert(", loot_sources)
        self.assertIn("Strings.NormalizeLower", loot_sources)
        self.assertIn('"Loot source text normalizer is not initialized"', loot_sources)
        self.assertIn("return TrimText(value)", loot_sources)
        self.assertIn("return NormalizeLower(text, true)", loot_sources)
        self.assertNotIn("if Strings and Strings.TrimText then", loot_sources)
        self.assertNotIn("if Strings and Strings.NormalizeLower then", loot_sources)
        self.assertNotIn('gsub(tostring(value or ""), "^%s*(.-)%s*$", "%1")', loot_sources)
        self.assertNotIn("strlower(text)", loot_sources)

    def test_timer_depends_on_wotlk_time_api_without_zero_fallback(self):
        timer = read(TIMER)

        self.assertIn("local GetTime = assert(", timer)
        self.assertIn("_G.GetTime", timer)
        self.assertIn('"RMA Timer: GetTime API is not initialized"', timer)
        self.assertIn("local LibStub = assert(", timer)
        self.assertIn("_G.LibStub", timer)
        self.assertIn('"RMA Timer: LibStub API is not initialized"', timer)
        self.assertIn('local libcompat = LibStub("LibCompat-1.0", true)', timer)
        self.assertNotIn("return (GetTime and GetTime()) or 0", timer)
        self.assertNotIn("local LibStub = _G.LibStub", timer)
        self.assertNotIn("LibStub and LibStub", timer)

    def test_item_depends_on_wotlk_time_api_without_zero_fallback(self):
        item = read(ITEM)

        self.assertIn("local GetTime = assert(", item)
        self.assertIn("_G.GetTime", item)
        self.assertIn('"Item cache time API is not initialized"', item)
        self.assertNotIn("local getTime = _G.GetTime", item)
        self.assertNotIn('type(getTime) == "function"', item)
        self.assertNotIn("return 0", item)

    def test_item_depends_on_wotlk_item_info_api_without_local_function_fallback(self):
        item = read(ITEM)

        self.assertIn("local GetItemInfo = assert(", item)
        self.assertIn("_G.GetItemInfo", item)
        self.assertIn('"Item cache item info API is not initialized"', item)
        self.assertNotIn("local getItemInfo = _G.GetItemInfo", item)
        self.assertNotIn('type(getItemInfo) ~= "function"', item)

    def test_logger_export_depends_on_helpers_without_local_format_fallbacks(self):
        logger_export = read(LOGGER_EXPORT)

        self.assertIn('"Services/Logger/Helpers"', logger_export)
        self.assertIn('assert(Logger.Helpers, "Logger export helpers are not initialized")', logger_export)
        self.assertIn("local formatRollTypeForExport = Helpers.FormatRollTypeForExport", logger_export)
        self.assertIn("local formatRollValueForExport = Helpers.FormatRollValueForExport", logger_export)
        self.assertNotRegex(
            logger_export,
            r"local\s+formatRollTypeForExport\s*=\s*Helpers\s+and\s+Helpers\.FormatRollTypeForExport\s+or\s+function",
        )
        self.assertNotRegex(
            logger_export,
            r"local\s+formatRollValueForExport\s*=\s*Helpers\s+and\s+Helpers\.FormatRollValueForExport\s+or\s+function",
        )

    def test_logger_export_uses_declared_raid_queries_owner_without_optional_getter(self):
        logger_export = read(LOGGER_EXPORT)

        self.assertIn('"Database/DBRaidQueries"', logger_export)
        self.assertIn("local queries = Database.GetRaidQueries()", logger_export)
        self.assertNotIn("Database.GetRaidQueriesOrNil()", logger_export)
        self.assertNotIn("if queries and queries.GetLoot then", logger_export)
        self.assertNotIn("if queries and queries.GetRaidAttendance then", logger_export)

    def test_reserves_sync_uses_module_owner_without_private_pass_through(self):
        reserves_sync = read(RESERVES_SYNC)

        self.assertNotIn("local function getReservesService()", reserves_sync)
        self.assertNotIn("getReservesService()", reserves_sync)
        self.assertIn("local service = module", reserves_sync)

    def test_reserves_sync_depends_on_comms_without_send_fallback(self):
        reserves_sync = read(RESERVES_SYNC)

        self.assertIn('"Modules/Comms"', reserves_sync)
        self.assertIn(
            'assert(Comms.SendAddonWhisper, "Reserves sync whisper transport is not initialized")',
            reserves_sync,
        )
        self.assertIn("Comms.RegisterPrefixIfAvailable(PREFIX)", reserves_sync)
        self.assertNotIn("local Client = assert(feature.Client", reserves_sync)
        self.assertNotIn("Client.RegisterAddonMessagePrefix(PREFIX)", reserves_sync)
        self.assertNotIn("local RegisterAddonMessagePrefix = _G.RegisterAddonMessagePrefix", reserves_sync)
        self.assertNotIn('"Reserves sync prefix registration API is not initialized"', reserves_sync)
        self.assertIn('local Payload = assert(Comms.Payload, "Comms payload helpers are not initialized")', reserves_sync)
        self.assertIn("local ok = Comms.Sync(PREFIX, payload.PackFields", reserves_sync)
        self.assertNotIn("local Payload = Comms and Comms.Payload or nil", reserves_sync)
        self.assertNotIn("Payload = Payload or (Comms and Comms.Payload)", reserves_sync)
        self.assertNotIn("Comms and Comms.Sync and Comms.Sync", reserves_sync)
        self.assertNotIn("if _G.RegisterAddonMessagePrefix then", reserves_sync)
        self.assertNotRegex(
            reserves_sync,
            r"local\s+sendAddonWhisper\s*=\s*Comms\s+and\s+Comms\.SendAddonWhisper\s+or\s+function",
        )

    def test_reserves_sync_depends_on_comms_without_sender_normalization_fallback(self):
        reserves_sync = read(RESERVES_SYNC)

        self.assertIn('"Modules/Comms"', reserves_sync)
        self.assertIn("local normalizeSender = assert(", reserves_sync)
        self.assertIn("Comms.NormalizeSender", reserves_sync)
        self.assertIn('"Reserves sync sender normalizer is not initialized"', reserves_sync)
        self.assertNotIn("Comms and Comms.NormalizeSender", reserves_sync)
        self.assertNotRegex(
            reserves_sync,
            r"local\s+normalizeSender\s*=\s*Comms\s+and\s+Comms\.NormalizeSender\s+or\s+function",
        )

    def test_reserves_sync_depends_on_wotlk_unit_name_without_empty_sender_fallback(self):
        reserves_sync = read(RESERVES_SYNC)

        self.assertIn("local UnitName = assert(", reserves_sync)
        self.assertIn("_G.UnitName", reserves_sync)
        self.assertIn('"Reserves sync unit name API is not initialized"', reserves_sync)
        self.assertIn("local GetTime = assert(", reserves_sync)
        self.assertIn("_G.GetTime", reserves_sync)
        self.assertIn('"Reserves sync time API is not initialized"', reserves_sync)
        self.assertIn("return GetTime()", reserves_sync)
        self.assertNotIn('UnitName and UnitName("player") or ""', reserves_sync)
        self.assertNotIn("local timeFn = _G.GetTime", reserves_sync)
        self.assertNotIn('type(timeFn) == "function"', reserves_sync)

    def test_slash_events_uses_database_owners_without_string_dispatch_helper(self):
        slash = read(SLASH)

        self.assertNotIn("local function getDatabaseService(", slash)
        self.assertNotIn("getDatabaseService(", slash)
        self.assertIn('"Database/DB"', slash)
        self.assertIn('"Database/DBSyncer"', slash)
        self.assertIn('"Database/DBRaidValidator"', slash)
        self.assertIn('"Database/DBRaidStore"', slash)
        self.assertIn('"Services/Raid/State"', slash)
        self.assertIn("local syncer = Database.GetSyncer()", slash)
        self.assertIn("local currentRaid = Database.GetCurrentRaid()", slash)
        self.assertIn("local validator = Database.GetRaidValidator()", slash)
        self.assertIn('Database.GetRaidStoreOrNil("SlashEvents.BugReport"', slash)
        self.assertIn('Database.GetRaidStoreOrNil("SlashEvents.CurrentRaid"', slash)
        self.assertIn(
            'local raidStore = Database.GetRaidStoreOrNil("SlashEvents.CurrentRaid", { "GetRaidNidByIndex" })',
            slash,
        )
        self.assertIn("if raidStore and currentRaid then", slash)
        self.assertIn("raidNid = raidStore:GetRaidNidByIndex(currentRaid)", slash)
        self.assertNotIn("Database.GetSyncer and Database.GetSyncer()", slash)
        self.assertNotIn("Database and Database.GetCurrentRaid and Database.GetCurrentRaid()", slash)
        self.assertNotIn("Database.GetRaidValidator and Database.GetRaidValidator()", slash)
        self.assertNotIn("Database.GetRaidStoreOrNil\n\t\t\tand Database.GetRaidStoreOrNil", slash)
        self.assertNotIn("raidStore and currentRaid and raidStore.GetRaidNidByIndex", slash)

    def test_slash_events_uses_declared_debug_service_without_optional_owner_guard(self):
        slash = read(SLASH)

        self.assertIn('"Services/Raid/Debug"', slash)
        self.assertIn('local RaidDebug = assert(Services.Raid.Debug, "Raid debug service is not initialized")', slash)
        self.assertNotIn("Services.Debug", slash)

    def test_slash_events_uses_declared_spec_inspect_service_without_optional_owner_guard(self):
        slash = read(SLASH)

        self.assertIn('"Services/SpecInspect"', slash)
        self.assertIn("local service = Services.SpecInspect", slash)
        self.assertNotIn("local service = Services and Services.SpecInspect or nil", slash)

    def test_slash_events_uses_declared_raid_service_without_optional_owner_guard(self):
        slash = read(SLASH)

        self.assertIn('"Services/Raid/State"', slash)
        self.assertIn("local raid = Services.Raid", slash)
        self.assertNotIn("local raid = Services and Services.Raid or nil", slash)

    def test_slash_reserves_commands_use_runtime_reserves_owner_without_optional_guards(self):
        slash = read(SLASH)

        self.assertIn('assert(Services.Reserves, "Slash reserves service is not initialized")', slash)
        self.assertIn('assert(Services.Loot, "Slash softres loot service is not initialized")', slash)
        self.assertIn('assert(loot.GetItemLink, "Slash softres loot item resolver is not initialized")', slash)
        self.assertIn('assert(Item.GetItemIdFromLink, "Slash softres item-id resolver is not initialized")', slash)
        self.assertIn('assert(reserves.GetCounts, "Slash reserves count resolver is not initialized")', slash)
        self.assertIn(
            'assert(reserves.GetReadinessReport, "Slash reserves readiness reporter is not initialized")',
            slash,
        )
        self.assertIn('assert(reserves.SetNameAlias, "Slash reserves alias setter is not initialized")', slash)
        self.assertIn('assert(reserves.RemoveNameAlias, "Slash reserves alias remover is not initialized")', slash)
        self.assertIn('assert(reserves.GetNameAliases, "Slash reserves alias lister is not initialized")', slash)
        self.assertIn('assert(reserves.RequestSyncMetadata, "Slash reserves sync requester is not initialized")', slash)
        self.assertIn('assert(reserves.GetSyncMetadata, "Slash reserves sync metadata reader is not initialized")', slash)
        self.assertIn(
            'assert(reserves.DeleteSyncedReservesCache, "Slash reserves sync cache cleaner is not initialized")',
            slash,
        )
        self.assertIn("return getCounts(reserves)", slash)
        self.assertIn("report = getReadinessReport(reserves, itemId)", slash)
        self.assertIn("if setNameAlias(reserves, reserveName, raidName) then", slash)
        self.assertIn("if removeNameAlias(reserves, reserveName) then", slash)
        self.assertIn("local aliases = getNameAliases(reserves)", slash)
        self.assertIn("if requestSyncMetadata(reserves) then", slash)
        self.assertIn("local meta = getSyncMetadata(reserves)", slash)
        self.assertIn("if deleteSyncedReservesCache(reserves) then", slash)
        self.assertIn("link = getItemLink(loot)", slash)
        self.assertIn("itemId = getItemIdFromLink(link)", slash)
        self.assertNotIn("local reserves = Services and Services.Reserves", slash)
        self.assertNotIn("local loot = Services and Services.Loot or nil", slash)
        self.assertNotIn("Services and Services.Reserves or nil", slash)
        self.assertNotIn("Item and Item.GetItemIdFromLink", slash)
        self.assertNotIn("reserves and reserves.SetNameAlias", slash)
        self.assertNotIn("reserves and reserves.GetNameAliases", slash)
        self.assertNotIn("reserves and reserves.RequestSyncMetadata", slash)
        self.assertNotIn("reserves and reserves.GetSyncMetadata", slash)
        self.assertNotIn("reserves and reserves.DeleteSyncedReservesCache", slash)

    def test_slash_events_uses_declared_comms_module_without_optional_owner_guard(self):
        slash = read(SLASH)

        self.assertIn('"Modules/Comms"', slash)
        self.assertIn("local getter = Comms.GetVersionInfo", slash)
        self.assertIn("local schemaGetter = Database.GetRaidSchemaVersion", slash)
        self.assertIn("local requester = Comms.RequestVersionCheck", slash)
        self.assertNotIn("local getter = Comms and Comms.GetVersionInfo", slash)
        self.assertNotIn("local schemaGetter = Database and Database.GetRaidSchemaVersion", slash)
        self.assertNotIn("sub ~= \"local\" and Comms and Comms.RequestVersionCheck", slash)

    def test_slash_events_uses_dboptions_get_value_without_local_fallback(self):
        slash = read(SLASH)

        self.assertIn('"Database/DBOptions"', slash)
        self.assertIn("local GetOption = Options.GetValue", slash)
        self.assertNotIn("local GetOption = Options.GetValue\n\tor function", slash)
        self.assertNotIn("local GetOption = Options.GetValue\r\n\tor function", slash)

    def test_loot_hints_depends_on_dboptions_without_local_fallback(self):
        loot_hints = read(LOOT_HINTS)

        self.assertIn('"Database/DBOptions"', loot_hints)
        self.assertIn("local GetOption = Options.GetValue", loot_hints)
        self.assertNotIn("local GetOption = Options.GetValue\n\t\tor function", loot_hints)
        self.assertNotIn("local GetOption = Options.GetValue\r\n\t\tor function", loot_hints)

    def test_loot_hints_depends_on_wotlk_loot_frame_hook_apis_without_silent_skip(self):
        loot_hints = read(LOOT_HINTS)

        self.assertIn("local HookSecureFunc = assert(", loot_hints)
        self.assertIn("_G.hooksecurefunc", loot_hints)
        self.assertIn('"Loot hints secure hook API is not initialized"', loot_hints)
        self.assertIn("assert(_G.LootFrame_Update", loot_hints)
        self.assertIn('"Loot hints loot-frame update API is not initialized"', loot_hints)
        self.assertIn('HookSecureFunc("LootFrame_Update", module.ApplyLootFrameReserveHints)', loot_hints)
        self.assertNotIn('type(hooksecurefunc) == "function"', loot_hints)
        self.assertNotIn('type(_G.LootFrame_Update) == "function"', loot_hints)

    def test_loot_hints_uses_declared_reserves_owner_without_optional_fallbacks(self):
        loot_hints = read(LOOT_HINTS)

        self.assertIn('"Services/Reserves"', loot_hints)
        self.assertIn("local Reserves = assert(Services.Reserves", loot_hints)
        self.assertIn('"Loot hints reserves service is not initialized"', loot_hints)
        self.assertIn("local GetPlayersForItem = assert(Reserves.GetPlayersForItem", loot_hints)
        self.assertIn('"Loot hints reserve player lookup is not initialized"', loot_hints)
        self.assertIn("local HasItemReserves = assert(Reserves.HasItemReserves", loot_hints)
        self.assertIn('"Loot hints reserve-state resolver is not initialized"', loot_hints)
        self.assertIn("local playerLines = GetPlayersForItem(Reserves, itemId, true, true, true, false)", loot_hints)
        self.assertIn("if HasItemReserves(Reserves, itemId) then", loot_hints)
        self.assertNotIn("local reserves = Services.Reserves", loot_hints)
        self.assertNotIn("if not reserves then", loot_hints)
        self.assertNotIn("if reserves.GetPlayersForItem then", loot_hints)
        self.assertNotIn("reserves:GetPlayersForItem", loot_hints)
        self.assertNotIn("reserves.HasItemReserves and reserves:HasItemReserves", loot_hints)

    def test_loot_counter_depends_on_visual_primitives_without_texture_color_fallback(self):
        loot_counter = read(LOOT_COUNTER)

        self.assertIn('"Modules/UI/Visuals"', loot_counter)
        self.assertRegex(loot_counter, r"local\s+setTextureColor\s*=\s*assert\(")
        self.assertIn("Primitives.SetTextureColorRgba", loot_counter)
        self.assertIn('"LootCounter texture-color primitive is not initialized"', loot_counter)
        self.assertNotRegex(
            loot_counter,
            r"local\s+setTextureColor\s*=\s*Primitives\.SetTextureColorRgba\s+or\s+function",
        )

    def test_loot_counter_binds_refresh_events_without_optional_callback_guard(self):
        loot_counter = read(LOOT_COUNTER)

        self.assertIn('"Modules/Events"', loot_counter)
        self.assertIn('"Modules/Bus"', loot_counter)
        self.assertIn("local InternalEvents = assert(Events.Internal", loot_counter)
        self.assertIn('"LootCounter internal events are not initialized"', loot_counter)
        self.assertIn("local RegisterCallback = assert(", loot_counter)
        self.assertIn("Bus.RegisterCallback", loot_counter)
        self.assertIn('"LootCounter event bus listener is not initialized"', loot_counter)
        self.assertIn("local RaidRosterDeltaEvent = assert(", loot_counter)
        self.assertIn("InternalEvents.RaidRosterDelta", loot_counter)
        self.assertIn('"LootCounter roster-delta event is not initialized"', loot_counter)
        self.assertIn("local PlayerCountChangedEvent =", loot_counter)
        self.assertIn("InternalEvents.PlayerCountChanged", loot_counter)
        self.assertIn('"LootCounter count-changed event is not initialized"', loot_counter)
        self.assertIn("local SpecInspectUpdatedEvent =", loot_counter)
        self.assertIn("InternalEvents.SpecInspectUpdated", loot_counter)
        self.assertIn('"LootCounter spec update event is not initialized"', loot_counter)
        self.assertIn("local RaidCreateEvent = assert(", loot_counter)
        self.assertIn("InternalEvents.RaidCreate", loot_counter)
        self.assertIn('"LootCounter raid-create event is not initialized"', loot_counter)
        self.assertIn("RegisterCallback(RaidRosterDeltaEvent, requestRefresh)", loot_counter)
        self.assertIn("RegisterCallback(PlayerCountChangedEvent, requestRefresh)", loot_counter)
        self.assertIn("RegisterCallback(SpecInspectUpdatedEvent, requestRefresh)", loot_counter)
        self.assertIn("RegisterCallback(RaidCreateEvent, requestRefresh)", loot_counter)
        self.assertNotIn("local InternalEvents = Events.Internal", loot_counter)
        self.assertNotIn("Bus.RegisterCallback(InternalEvents.RaidRosterDelta", loot_counter)
        self.assertNotIn("Bus.RegisterCallback(InternalEvents.PlayerCountChanged", loot_counter)
        self.assertNotIn("Bus.RegisterCallback(InternalEvents.SpecInspectUpdated", loot_counter)
        self.assertNotIn("Bus.RegisterCallback(InternalEvents.RaidCreate", loot_counter)

    def test_loot_counter_uses_declared_spec_inspect_owner_without_optional_guard(self):
        loot_counter = read(LOOT_COUNTER)

        self.assertIn('"Services/SpecInspect"', loot_counter)
        self.assertIn("local SpecInspect = assert(Services.SpecInspect", loot_counter)
        self.assertIn('"LootCounter spec inspect service is not initialized"', loot_counter)
        self.assertRegex(loot_counter, r"local\s+GetPlayerSpecSnapshot\s*=\s*assert\(")
        self.assertIn("SpecInspect.GetPlayerSpecSnapshot", loot_counter)
        self.assertIn('"LootCounter spec snapshot resolver is not initialized"', loot_counter)
        self.assertIn("local spec = GetPlayerSpecSnapshot(SpecInspect, name)", loot_counter)
        self.assertNotIn("local specInspect = Services.SpecInspect", loot_counter)
        self.assertNotIn("specInspect and specInspect.GetPlayerSpecSnapshot", loot_counter)

    def test_loot_counter_announces_through_chat_service_without_optional_guard(self):
        loot_counter = read(LOOT_COUNTER)

        self.assertIn('"Services/Chat"', loot_counter)
        self.assertIn("local Chat = assert(Services.Chat", loot_counter)
        self.assertIn('"LootCounter chat service is not initialized"', loot_counter)
        self.assertIn("local AnnounceChat = assert(Chat.Announce", loot_counter)
        self.assertIn('"LootCounter chat announcement service is not initialized"', loot_counter)
        self.assertIn('AnnounceChat(Chat, text, "RAID")', loot_counter)
        self.assertNotIn("local Chat = Services.Chat", loot_counter)
        self.assertNotIn("if Chat and Chat.Announce then", loot_counter)

    def test_loot_counter_uses_declared_raid_service_without_optional_guards(self):
        loot_counter = read(LOOT_COUNTER)

        self.assertIn('"Services/Raid/State"', loot_counter)
        self.assertIn('"Services/Raid/Capabilities"', loot_counter)
        self.assertIn('"Services/Raid/Counts"', loot_counter)
        self.assertIn("local Raid = assert(Services.Raid", loot_counter)
        self.assertIn('"LootCounter raid service is not initialized"', loot_counter)
        self.assertIn("local IsPlayerInRaid = assert(Raid.IsPlayerInRaid", loot_counter)
        self.assertIn('"LootCounter raid membership service is not initialized"', loot_counter)
        self.assertIn("local GetCapabilityState = assert(Raid.GetCapabilityState", loot_counter)
        self.assertIn('"LootCounter raid capability service is not initialized"', loot_counter)
        self.assertIn("local GetLootCounterRows = assert(Raid.GetLootCounterRows", loot_counter)
        self.assertIn('"LootCounter raid count row service is not initialized"', loot_counter)
        self.assertIn("local AddPlayerLootCountByNid =", loot_counter)
        self.assertIn("assert(Raid.AddPlayerLootCountByNid", loot_counter)
        self.assertIn('"LootCounter raid count increment service is not initialized"', loot_counter)
        self.assertIn("local SetPlayerLootCountByNid =", loot_counter)
        self.assertIn("assert(Raid.SetPlayerLootCountByNid", loot_counter)
        self.assertIn('"LootCounter raid count setter service is not initialized"', loot_counter)
        self.assertIn("local GetPlayerClass = assert(Raid.GetPlayerClass", loot_counter)
        self.assertIn('"LootCounter raid class resolver is not initialized"', loot_counter)
        self.assertIn("if not IsPlayerInRaid(Raid) then", loot_counter)
        self.assertIn('local state = GetCapabilityState(Raid, "loot_counter_broadcast")', loot_counter)
        self.assertIn("return GetLootCounterRows(Raid, Database.GetCurrentRaid(), raidPlayers)", loot_counter)
        self.assertIn("AddPlayerLootCountByNid(Raid, nid, lt, 1, Database.GetCurrentRaid())", loot_counter)
        self.assertIn("SetPlayerLootCountByNid(Raid, playerNid, \"ms\", 0, currentRaid)", loot_counter)
        self.assertIn("local class = data and data.class or GetPlayerClass(Raid, name)", loot_counter)
        self.assertNotIn("local raidService = Raid", loot_counter)
        self.assertNotIn("raidService and raidService.IsPlayerInRaid", loot_counter)
        self.assertNotIn("Services.Raid:", loot_counter)

    def test_raid_grid_depends_on_visual_primitives_without_texture_color_fallback(self):
        raid_grid = read(RAID_GRID)

        self.assertIn('"Modules/UI/Visuals"', raid_grid)
        self.assertIn("local setTextureColor = assert(", raid_grid)
        self.assertIn("Primitives.SetTextureColor", raid_grid)
        self.assertIn('"RaidGrid texture-color primitive is not initialized"', raid_grid)
        self.assertNotRegex(
            raid_grid,
            r"local\s+setTextureColor\s*=\s*Primitives\.SetTextureColor\s+or\s+function",
        )

    def test_raid_grid_binds_spec_update_event_without_optional_callback_guard(self):
        raid_grid = read(RAID_GRID)

        self.assertIn('"Modules/Events"', raid_grid)
        self.assertIn('"Modules/Bus"', raid_grid)
        self.assertIn("local InternalEvents = assert(Events.Internal", raid_grid)
        self.assertIn('"RaidGrid internal events are not initialized"', raid_grid)
        self.assertIn("local RegisterCallback = assert(", raid_grid)
        self.assertIn("Bus.RegisterCallback", raid_grid)
        self.assertIn('"RaidGrid event bus listener is not initialized"', raid_grid)
        self.assertIn("local SpecInspectUpdatedEvent =", raid_grid)
        self.assertIn("InternalEvents.SpecInspectUpdated", raid_grid)
        self.assertIn('"RaidGrid spec update event is not initialized"', raid_grid)
        self.assertIn("RegisterCallback(SpecInspectUpdatedEvent, requestSpecRefresh)", raid_grid)
        self.assertNotIn("Events and Events.Internal", raid_grid)
        self.assertNotIn("local InternalEvents = Events.Internal", raid_grid)
        self.assertNotIn("if Bus and InternalEvents", raid_grid)
        self.assertNotIn("Bus.RegisterCallback(InternalEvents.SpecInspectUpdated", raid_grid)

    def test_raid_grid_uses_declared_spec_inspect_owner_without_optional_guard(self):
        raid_grid = read(RAID_GRID)

        self.assertIn('"Services/SpecInspect"', raid_grid)
        self.assertIn("local SpecInspect = assert(Services.SpecInspect", raid_grid)
        self.assertIn('"RaidGrid spec inspect service is not initialized"', raid_grid)
        self.assertRegex(raid_grid, r"local\s+GetPlayerSpecSnapshot\s*=\s*assert\(")
        self.assertIn("SpecInspect.GetPlayerSpecSnapshot", raid_grid)
        self.assertIn('"RaidGrid spec snapshot resolver is not initialized"', raid_grid)
        self.assertIn("local spec = GetPlayerSpecSnapshot(SpecInspect, fullName)", raid_grid)
        self.assertNotIn("Services and Services.SpecInspect", raid_grid)
        self.assertNotIn("Services.SpecInspect.GetPlayerSpecSnapshot", raid_grid)
        self.assertNotIn("Services.SpecInspect:GetPlayerSpecSnapshot(fullName)", raid_grid)

    def test_loot_service_depends_on_dboptions_without_local_fallback(self):
        loot_service = read(LOOT_SERVICE)

        self.assertIn('"Database/DBOptions"', loot_service)
        self.assertIn("local GetOption = Options.GetValue", loot_service)
        self.assertNotRegex(loot_service, r"local\s+GetOption\s*=\s*Options\.GetValue\s+or\s+function")

    def test_loot_service_depends_on_dboptions_without_threshold_policy_fallback(self):
        loot_service = read(LOOT_SERVICE)

        self.assertIn('"Database/DBOptions"', loot_service)
        self.assertIn("local normalizeLoggerLootQualityThreshold = assert(", loot_service)
        self.assertIn("Options.NormalizeLoggerLootQualityThreshold", loot_service)
        self.assertIn('"Loot logger quality threshold normalizer is not initialized"', loot_service)
        self.assertNotRegex(
            loot_service,
            r"local\s+normalizeLoggerLootQualityThreshold\s*=\s*Options\.NormalizeLoggerLootQualityThreshold\s+or\s+function",
        )

    def test_loot_service_depends_on_wotlk_loot_threshold_api_without_default_fallbacks(self):
        loot_service = read(LOOT_SERVICE)

        self.assertIn("local GetLootThreshold = assert(", loot_service)
        self.assertIn("_G.GetLootThreshold", loot_service)
        self.assertIn('"Loot service loot-threshold API is not initialized"', loot_service)
        self.assertNotIn('type(GetLootThreshold) == "function"', loot_service)
        self.assertNotIn("return 2", loot_service)
        self.assertNotIn("GetLootThreshold() or 2", loot_service)

    def test_loot_service_emits_domain_events_through_validated_helpers(self):
        loot_service = read(LOOT_SERVICE)

        self.assertIn('"Modules/Events"', loot_service)
        self.assertIn('"Modules/Bus"', loot_service)
        self.assertIn("local InternalEvents = assert(Events.Internal", loot_service)
        self.assertIn('"Loot service internal events are not initialized"', loot_service)
        self.assertIn("local TriggerEvent = assert(", loot_service)
        self.assertIn("Bus.TriggerEvent", loot_service)
        self.assertIn('"Loot service event publisher is not initialized"', loot_service)
        self.assertIn("local RaidLootUpdateEvent =", loot_service)
        self.assertIn("InternalEvents.RaidLootUpdate", loot_service)
        self.assertIn('"Loot service raid-loot update event is not initialized"', loot_service)
        self.assertIn("local SetItemEvent = assert(", loot_service)
        self.assertIn("InternalEvents.SetItem", loot_service)
        self.assertIn('"Loot service selected-item event is not initialized"', loot_service)
        self.assertIn("TriggerEvent(RaidLootUpdateEvent, raidNum, loot)", loot_service)
        self.assertIn("TriggerEvent(SetItemEvent, itemLink, item)", loot_service)
        self.assertIn("notifyRaidLootUpdate(raidNum, appended)", loot_service)
        self.assertIn("notifySelectedItem(i.itemLink, i)", loot_service)
        self.assertNotIn("local InternalEvents = Events.Internal", loot_service)
        self.assertNotIn("Bus.TriggerEvent(InternalEvents.RaidLootUpdate", loot_service)
        self.assertNotIn("Bus.TriggerEvent(InternalEvents.SetItem", loot_service)

    def test_loot_inventory_depends_on_wotlk_inventory_apis_without_local_fallbacks(self):
        inventory = read(LOOT_INVENTORY)

        required_apis = {
            "GetNumLootItems": "loot count API",
            "GetLootSlotLink": "loot slot link API",
            "GetContainerNumSlots": "container slot count API",
            "GetContainerItemLink": "container item link API",
            "GetContainerItemInfo": "container item info API",
        }
        for api_name, message_fragment in required_apis.items():
            self.assertIn(f"local {api_name}", inventory)
            self.assertIn(f"assert(_G.{api_name}", inventory)
            self.assertIn(f'"Loot inventory {message_fragment} is not initialized"', inventory)

        self.assertNotIn("local GetNumLootItems = _G.GetNumLootItems", inventory)
        self.assertNotIn("local GetLootSlotLink = _G.GetLootSlotLink", inventory)
        self.assertNotIn("local GetContainerNumSlots = _G.GetContainerNumSlots", inventory)
        self.assertNotIn("local GetContainerItemLink = _G.GetContainerItemLink", inventory)
        self.assertNotIn("local GetContainerItemInfo = _G.GetContainerItemInfo", inventory)
        self.assertNotIn("GetNumLootItems() or 0", inventory)
        self.assertNotIn("GetContainerNumSlots(bag) or 0", inventory)

    def test_loot_state_depends_on_wotlk_time_api_without_local_fallback(self):
        loot_state = read(LOOT_STATE)

        self.assertIn("local GetTime = assert(", loot_state)
        self.assertIn("_G.GetTime", loot_state)
        self.assertIn('"Loot state time API is not initialized"', loot_state)
        self.assertNotIn("local GetTime = _G.GetTime", loot_state)
        self.assertNotIn("GetTime and GetTime()", loot_state)

    def test_loot_tracking_depends_on_wotlk_master_loot_candidate_api_without_local_fallback(self):
        tracking = read(LOOT_TRACKING)

        self.assertIn("local GetMasterLootCandidate =", tracking)
        self.assertIn("assert(_G.GetMasterLootCandidate", tracking)
        self.assertIn("_G.GetMasterLootCandidate", tracking)
        self.assertIn('"Loot tracking master-loot candidate API is not initialized"', tracking)
        self.assertNotIn("local getMasterLootCandidate = _G.GetMasterLootCandidate", tracking)
        self.assertNotIn('type(getMasterLootCandidate) ~= "function"', tracking)

    def test_loot_tracking_depends_on_group_count_helper_without_empty_candidate_fallback(self):
        tracking = read(LOOT_TRACKING)

        self.assertIn("local GetNumGroupMembers =", tracking)
        self.assertIn("assert(addon.GetNumGroupMembers", tracking)
        self.assertIn('"Loot tracking group-count helper is not initialized"', tracking)
        self.assertNotIn('type(addon.GetNumGroupMembers) == "function"', tracking)
        self.assertNotIn("local groupCount = 0", tracking)

    def test_loot_tracking_depends_on_wotlk_loot_method_api_without_optional_snapshot_fallback(self):
        tracking = read(LOOT_TRACKING)

        self.assertIn("local GetLootMethod =", tracking)
        self.assertIn("assert(_G.GetLootMethod", tracking)
        self.assertIn('"Loot tracking loot-method API is not initialized"', tracking)
        self.assertNotIn('rawget(_G, "GetLootMethod")', tracking)
        self.assertNotIn('type(getLootMethod) == "function"', tracking)

    def test_loot_recording_receipts_depend_on_item_without_local_key_fallback(self):
        recording = read(LOOT_RECORDING)

        self.assertIn('"Modules/Item"', recording)
        self.assertIn('assert(Item.GetItemKey, "Loot recording item-key resolver is not initialized")', recording)
        self.assertIn("function Recording.FromParsedLoot(args)", recording)
        self.assertIn("function Recording.ShouldCreateRecord(receipt)", recording)
        self.assertNotRegex(
            recording,
            r"local\s+resolveItemKey\s*=\s*Item\.GetItemKey\s+or\s+function",
        )

    def test_loot_distribution_session_depends_on_item_without_local_key_fallback(self):
        distribution = read(LOOT_DISTRIBUTION_SESSION)

        self.assertIn('"Modules/Item"', distribution)
        self.assertIn('assert(Item.GetItemKey, "Loot distribution item-key resolver is not initialized")', distribution)
        self.assertNotRegex(
            distribution,
            r"local\s+resolveItemKey\s*=\s*Item\.GetItemKey\s+or\s+function",
        )

    def test_loot_distribution_session_depends_on_wow_time_api_without_local_fallbacks(self):
        distribution = read(LOOT_DISTRIBUTION_SESSION)

        self.assertIn("local GetTime = assert(", distribution)
        self.assertIn("_G.GetTime", distribution)
        self.assertIn('"Loot distribution time API is not initialized"', distribution)
        self.assertIn("Comms.RegisterPrefixIfAvailable(PREFIX)", distribution)
        self.assertNotIn("local Client = assert(feature.Client", distribution)
        self.assertNotIn("Client.RegisterAddonMessagePrefix(PREFIX)", distribution)
        self.assertNotIn("local RegisterAddonMessagePrefix = _G.RegisterAddonMessagePrefix", distribution)
        self.assertNotIn('"Loot distribution prefix registration API is not initialized"', distribution)
        self.assertNotIn("local getTime = _G.GetTime", distribution)
        self.assertNotIn('type(getTime) == "function"', distribution)
        self.assertNotIn("local register = _G.RegisterAddonMessagePrefix", distribution)
        self.assertNotIn("return 0", distribution)
        self.assertNotIn("or ordinal", distribution)

    def test_loot_distribution_session_builds_session_ids_without_generic_identity_or_zero_time_fallbacks(self):
        distribution = read(LOOT_DISTRIBUTION_SESSION)

        self.assertIn("local GetPlayerName = assert(", distribution)
        self.assertIn("Database.GetPlayerName", distribution)
        self.assertIn('"Loot distribution player-name resolver is not initialized"', distribution)
        self.assertIn('"Loot distribution player name is not initialized"', distribution)
        self.assertIn('"Loot distribution time API returned invalid timestamp"', distribution)
        self.assertNotIn('or "player"', distribution)
        self.assertNotIn("now or 0", distribution)

    def test_loot_recording_records_depend_on_time_owner_without_zero_timestamp_fallback(self):
        recording = read(LOOT_RECORDING)

        self.assertIn("local GetCurrentTime = assert(", recording)
        self.assertIn("Time.GetCurrentTime", recording)
        self.assertIn('"Loot recording time provider is not initialized"', recording)
        self.assertIn('"Loot record timestamp is not initialized"', recording)
        self.assertIn("function Recording.Build(raid, args)", recording)
        self.assertIn("function Recording.Append(raid, args)", recording)
        self.assertNotIn("Time and Time.GetCurrentTime and Time.GetCurrentTime()", recording)
        self.assertNotIn("time = tonumber(args.time) or", recording)

    def test_raid_store_create_raid_record_depends_on_time_owner_without_raw_time_fallback(self):
        store = read(DB_RAID_STORE)

        self.assertIn("local GetCurrentTime = assert(", store)
        self.assertIn("Time.GetCurrentTime", store)
        self.assertIn('"Raid store time provider is not initialized"', store)
        self.assertIn('"Raid start timestamp is not initialized"', store)
        self.assertNotIn("Time and Time.GetCurrentTime and Time.GetCurrentTime()", store)
        self.assertNotIn("or time()", store)

    def test_raid_queries_attendance_depends_on_time_owner_without_raw_time_fallback(self):
        queries = read(DB_RAID_QUERIES)

        self.assertIn("local GetCurrentTime = assert(", queries)
        self.assertIn("Time.GetCurrentTime", queries)
        self.assertIn('"Raid queries time provider is not initialized"', queries)
        self.assertIn('"Modules/Time"', queries)
        self.assertNotIn("local now = time()", queries)
        self.assertNotIn("or time()", queries)

    def test_loot_context_depends_on_strings_without_local_text_fallback(self):
        loot_context = read(LOOT_CONTEXT)

        self.assertIn('"Modules/Strings"', loot_context)
        self.assertIn('assert(Strings.NormalizeText, "Loot context text normalizer is not initialized")', loot_context)
        self.assertNotRegex(
            loot_context,
            r"local\s+NormalizeText\s*=\s*Strings\.NormalizeText\s+or\s+function",
        )

    def test_loot_context_uses_declared_database_owner_without_optional_core_guards(self):
        loot_context = read(LOOT_CONTEXT)

        self.assertNotIn("local GetCurrentRaid = assert(", loot_context)
        self.assertIn("Database.GetCurrentRaid", loot_context)
        self.assertIn('"Loot context current-raid resolver is not initialized"', loot_context)
        self.assertIn("local EnsureRaidById = assert(", loot_context)
        self.assertIn("Database.EnsureRaidById", loot_context)
        self.assertIn('"Loot context raid resolver is not initialized"', loot_context)
        self.assertIn("local EnsureRaidSchema = assert(", loot_context)
        self.assertIn("Database.EnsureRaidSchema", loot_context)
        self.assertIn('"Loot context raid schema normalizer is not initialized"', loot_context)
        self.assertIn("local getCurrentRaid = assert(Database.GetCurrentRaid", loot_context)
        self.assertIn("resolvedRaidNum = getCurrentRaid()", loot_context)
        self.assertIn("local raid = EnsureRaidById(resolvedRaidNum)", loot_context)
        self.assertIn("EnsureRaidSchema(raid)", loot_context)
        self.assertNotIn("core and type(core.GetCurrentRaid)", loot_context)
        self.assertNotIn('type(core.EnsureRaidById) ~= "function"', loot_context)
        self.assertNotIn('type(core.EnsureRaidSchema) == "function"', loot_context)

    def test_loot_recording_reconcile_depends_on_strings_without_local_name_fallback(self):
        recording = read(LOOT_RECORDING)

        self.assertIn('"Modules/Strings"', recording)
        self.assertIn("local NormalizeName = assert(", recording)
        self.assertIn("Strings.NormalizeName", recording)
        self.assertIn('"Loot recording name normalizer is not initialized"', recording)
        self.assertIn("return NormalizeName(name, true)", recording)
        self.assertIn("function Recording.FindTradeOnlyFallback(raid, args)", recording)
        self.assertIn("function Recording.MergeTradeOnlyFallback(row, args)", recording)
        self.assertNotIn("Strings and Strings.NormalizeName", recording)
        self.assertNotIn("return Strings.NormalizeName(name, true) or name", recording)

    def test_loot_recording_reconcile_depends_on_item_without_local_key_fallback(self):
        recording = read(LOOT_RECORDING)

        self.assertIn('"Modules/Item"', recording)
        self.assertIn("local GetItemStringFromLink =", recording)
        self.assertIn("assert(Item.GetItemStringFromLink", recording)
        self.assertIn("Item.GetItemStringFromLink", recording)
        self.assertIn('"Loot recording item-string resolver is not initialized"', recording)
        self.assertIn("local key = GetItemStringFromLink(itemLink)", recording)
        self.assertNotIn("Item and Item.GetItemStringFromLink", recording)

    def test_loot_snapshots_depends_on_item_without_active_consume_key_fallback(self):
        snapshots = read(LOOT_SNAPSHOTS)

        self.assertIn('"Modules/Item"', snapshots)
        self.assertIn("local GetItemStringFromLink = assert(", snapshots)
        self.assertIn("Item.GetItemStringFromLink", snapshots)
        self.assertIn('"Loot snapshot item-key resolver is not initialized"', snapshots)
        self.assertIn("GetItemStringFromLink(itemLink) or itemLink", snapshots)
        self.assertNotIn("Item and Item.GetItemStringFromLink", snapshots)

    def test_loot_pending_awards_depends_on_dboptions_without_local_fallback(self):
        pending_awards = read(LOOT_PENDING_AWARDS)

        self.assertIn('"Database/DBOptions"', pending_awards)
        self.assertIn("local isDebugEnabled = Options.IsDebugEnabled", pending_awards)
        self.assertNotRegex(pending_awards, r"local\s+isDebugEnabled\s*=\s*Options\.IsDebugEnabled\s+or\s+function")

    def test_loot_passive_group_loot_depends_on_dboptions_without_local_fallback(self):
        passive_group_loot = read(LOOT_PASSIVE_GROUP_LOOT)

        self.assertIn('"Database/DBOptions"', passive_group_loot)
        self.assertIn("local isDebugEnabled = Options.IsDebugEnabled", passive_group_loot)
        self.assertNotRegex(passive_group_loot, r"local\s+isDebugEnabled\s*=\s*Options\.IsDebugEnabled\s+or\s+function")

    def test_loot_passive_group_loot_depends_on_wotlk_roll_item_apis_without_local_fallbacks(self):
        passive_group_loot = read(LOOT_PASSIVE_GROUP_LOOT)

        self.assertIn("local GetLootRollItemInfo = assert(", passive_group_loot)
        self.assertIn("_G.GetLootRollItemInfo", passive_group_loot)
        self.assertIn('"Passive group-loot roll item info API is not initialized"', passive_group_loot)
        self.assertIn("local GetLootRollItemLink = assert(", passive_group_loot)
        self.assertIn("_G.GetLootRollItemLink", passive_group_loot)
        self.assertIn('"Passive group-loot roll item link API is not initialized"', passive_group_loot)
        self.assertNotIn("local getInfo = _G.GetLootRollItemInfo", passive_group_loot)
        self.assertNotIn('type(getInfo) ~= "function"', passive_group_loot)
        self.assertNotIn("local getLootRollItemLink = _G.GetLootRollItemLink", passive_group_loot)
        self.assertNotIn('type(getLootRollItemLink) ~= "function"', passive_group_loot)

    def test_loot_passive_group_loot_depends_on_wotlk_loot_method_api_without_optional_method_fallback(self):
        passive_group_loot = read(LOOT_PASSIVE_GROUP_LOOT)
        capabilities = read(RAID_CAPABILITIES)
        toc = read(TOC)

        self.assertIn("function module:IsPassiveGroupLootMethod(method)", capabilities)
        self.assertIn("return isPassiveGroupLootMethod(method)", capabilities)
        self.assertIn("local Raid = assert(Services.Raid", passive_group_loot)
        self.assertIn('"Passive group-loot raid service is not initialized"', passive_group_loot)
        self.assertRegex(passive_group_loot, r"local\s+IsPassiveGroupLootMethod\s*=\s*assert\(")
        self.assertIn("Raid.IsPassiveGroupLootMethod", passive_group_loot)
        self.assertIn('"Passive group-loot method policy resolver is not initialized"', passive_group_loot)
        self.assertIn("return IsPassiveGroupLootMethod(Raid, method) == true", passive_group_loot)
        self.assertIn('"Services/Raid/Capabilities"', passive_group_loot)
        self.assertLess(
            toc.index("Services\\Raid\\Capabilities.lua"),
            toc.index("Services\\Loot\\PassiveGroupLoot.lua"),
        )
        self.assertNotIn("local GetLootMethod = assert(", passive_group_loot)
        self.assertNotIn("_G.GetLootMethod", passive_group_loot)
        self.assertNotIn("local Raid = Services and Services.Raid or nil", passive_group_loot)
        self.assertNotIn("Raid and Raid.GetLootMethodName", passive_group_loot)
        self.assertNotIn("resolvedMethod == \"group\" or resolvedMethod == \"needbeforegreed\"", passive_group_loot)

    def test_loot_passive_group_loot_depends_on_item_owner_without_optional_key_fallback(self):
        passive_group_loot = read(LOOT_PASSIVE_GROUP_LOOT)

        self.assertIn('"Modules/Item"', passive_group_loot)
        self.assertRegex(passive_group_loot, r"local\s+GetItemStringFromLink\s*=\s*assert\(")
        self.assertIn("Item.GetItemStringFromLink", passive_group_loot)
        self.assertIn('"Passive group-loot item-key resolver is not initialized"', passive_group_loot)
        self.assertIn("local itemKey = GetItemStringFromLink(value)", passive_group_loot)
        self.assertIn("local itemKey = GetItemStringFromLink(itemLink)", passive_group_loot)
        self.assertNotIn("Item and Item.GetItemStringFromLink", passive_group_loot)
        self.assertNotIn("Item.GetItemStringFromLink(itemLink)", passive_group_loot)

    def test_loot_rules_depends_on_wotlk_item_info_api_without_global_optional_branch(self):
        loot_rules = read(LOOT_RULES)

        self.assertIn("local GetItemInfo = assert(", loot_rules)
        self.assertIn("_G.GetItemInfo", loot_rules)
        self.assertIn('"Loot rules item info API is not initialized"', loot_rules)
        self.assertNotIn("and _G.GetItemInfo", loot_rules)
        self.assertNotIn("_G.GetItemInfo(itemLink)", loot_rules)

    def test_loot_rules_depends_on_item_owner_without_optional_item_fallbacks(self):
        loot_rules = read(LOOT_RULES)

        self.assertIn('"Modules/Item"', loot_rules)
        self.assertIn("local GetItemIdFromLink = assert(", loot_rules)
        self.assertIn("Item.GetItemIdFromLink", loot_rules)
        self.assertIn('"Loot rules item-id resolver is not initialized"', loot_rules)
        self.assertRegex(loot_rules, r"local\s+GetItemBindFromTooltip\s*=\s*assert\(")
        self.assertIn("Item.GetItemBindFromTooltip", loot_rules)
        self.assertIn('"Loot rules tooltip bind resolver is not initialized"', loot_rules)
        self.assertIn("return tonumber(GetItemIdFromLink(item.itemLink))", loot_rules)
        self.assertIn("itemBind = tonumber(GetItemBindFromTooltip(itemLink))", loot_rules)
        self.assertNotIn("Item and Item.GetItemIdFromLink", loot_rules)
        self.assertNotIn("Item and Item.GetItemBindFromTooltip", loot_rules)

    def test_loot_rules_depends_on_ignored_items_dataset_without_optional_fallbacks(self):
        loot_rules = read(LOOT_RULES)

        self.assertIn('"Modules/Dataset/IgnoredItems"', loot_rules)
        self.assertIn("local IgnoredItems = assert(", loot_rules)
        self.assertIn("feature.IgnoredItems", loot_rules)
        self.assertIn('"Loot rules ignored-items namespace is not initialized"', loot_rules)
        self.assertIn("local ContainsIgnoredItem = assert(", loot_rules)
        self.assertIn("IgnoredItems.Contains", loot_rules)
        self.assertIn('"Loot rules ignored-item dataset is not initialized"', loot_rules)
        self.assertRegex(loot_rules, r"local\s+IsEnchantingMaterial\s*=\s*assert\(")
        self.assertIn("IgnoredItems.IsEnchantingMaterial", loot_rules)
        self.assertIn('"Loot rules enchanting-material dataset is not initialized"', loot_rules)
        self.assertIn("return ContainsIgnoredItem(itemId) == true", loot_rules)
        self.assertIn("return IsEnchantingMaterial(itemId) == true", loot_rules)
        self.assertNotIn('feature.IgnoredItems or {}', loot_rules)
        self.assertNotIn('type(IgnoredItems.Contains) == "function"', loot_rules)
        self.assertNotIn('type(IgnoredItems.IsEnchantingMaterial) == "function"', loot_rules)

    def test_raid_loot_method_depends_on_dboptions_without_local_fallback(self):
        loot_method = read(RAID_LOOT_METHOD)

        self.assertIn('"Database/DBOptions"', loot_method)
        self.assertIn("local GetOption = Options.GetValue", loot_method)
        self.assertNotRegex(loot_method, r"local\s+GetOption\s*=\s*Options\.GetValue\s+or\s+function")

    def test_raid_loot_method_emits_prompts_through_declared_bus_events(self):
        loot_method = read(RAID_LOOT_METHOD)

        self.assertIn('"Modules/Events"', loot_method)
        self.assertIn('"Modules/Bus"', loot_method)
        self.assertIn("local InternalEvents = assert(", loot_method)
        self.assertIn("Events.Internal", loot_method)
        self.assertIn('"Raid loot method event registry is not initialized"', loot_method)
        self.assertIn("local ScreenNoticeEvent = assert(", loot_method)
        self.assertIn("InternalEvents.ScreenNotice", loot_method)
        self.assertIn('"Raid loot method screen notice event is not initialized"', loot_method)
        self.assertIn("local GroupLootRestoreNeededEvent =", loot_method)
        self.assertIn("assert(InternalEvents.GroupLootRestoreNeeded", loot_method)
        self.assertIn("InternalEvents.GroupLootRestoreNeeded", loot_method)
        self.assertIn('"Raid loot method restore notification is not initialized"', loot_method)
        self.assertIn("local TriggerEvent = assert(", loot_method)
        self.assertIn("Bus.TriggerEvent", loot_method)
        self.assertIn('"Raid loot method event bus sender is not initialized"', loot_method)
        self.assertIn("TriggerEvent(ScreenNoticeEvent, message, getAutoMasterLootNoticeSeconds())", loot_method)
        self.assertIn("TriggerEvent(GroupLootRestoreNeededEvent)", loot_method)
        self.assertNotIn("Bus and Bus.TriggerEvent", loot_method)
        self.assertNotIn("Events and Events.Internal", loot_method)

    def test_raid_loot_method_depends_on_wotlk_target_and_time_apis_without_local_fallbacks(self):
        loot_method = read(RAID_LOOT_METHOD)

        required_apis = {
            "GetTime": "time API",
            "SetLootMethod": "setter API",
            "UnitExists": "unit existence API",
            "UnitGUID": "unit GUID API",
            "UnitInRaid": "unit raid-membership API",
            "UnitIsDead": "unit death-state API",
            "UnitName": "unit name API",
        }
        for api_name, message_fragment in required_apis.items():
            self.assertIn(f"local {api_name} = assert(", loot_method)
            self.assertIn(f"_G.{api_name}", loot_method)
            self.assertIn(f'"Raid loot method {message_fragment} is not initialized"', loot_method)
        self.assertNotIn('type(UnitName) == "function" and UnitName("player") or nil', loot_method)
        self.assertNotIn('type(UnitGUID) == "function" and UnitGUID("target") or nil', loot_method)
        self.assertNotIn('type(UnitInRaid) ~= "function"', loot_method)
        self.assertNotIn('type(UnitExists) ~= "function"', loot_method)
        self.assertNotIn('type(UnitIsDead) == "function"', loot_method)
        self.assertNotIn('type(SetLootMethod) ~= "function"', loot_method)
        self.assertNotIn('type(UnitName) == "function" and UnitName("target") or nil', loot_method)
        self.assertNotIn('type(GetTime) == "function" and GetTime() or 0', loot_method)

    def test_raid_loot_method_uses_declared_database_and_creature_id_owners_without_optional_fallbacks(self):
        loot_method = read(RAID_LOOT_METHOD)

        self.assertIn('"Database/DB"', loot_method)
        self.assertIn("local GetCreatureId = assert(", loot_method)
        self.assertIn("feature.GetCreatureId", loot_method)
        self.assertIn('"Raid loot method creature-id helper is not initialized"', loot_method)
        self.assertIn("local dbName = Database.GetPlayerName()", loot_method)
        self.assertIn("local npcId = guid and GetCreatureId(guid) or nil", loot_method)
        self.assertNotIn("if Database and Database.GetPlayerName then", loot_method)
        self.assertNotIn("feature.GetCreatureId and feature.GetCreatureId(guid)", loot_method)

    def test_raid_capabilities_depend_on_wotlk_and_database_owners_without_optional_fallbacks(self):
        capabilities = read(RAID_CAPABILITIES)

        self.assertIn("local GetLootMethod = assert(", capabilities)
        self.assertIn("_G.GetLootMethod", capabilities)
        self.assertIn('"Raid capability loot-method API is not initialized"', capabilities)
        self.assertIn("local UnitIsUnit = assert(", capabilities)
        self.assertIn("_G.UnitIsUnit", capabilities)
        self.assertIn('"Raid capability unit comparison API is not initialized"', capabilities)
        self.assertIn("local GetUnitRank = assert(", capabilities)
        self.assertIn("Database.GetUnitRank", capabilities)
        self.assertIn('"Raid capability group-rank resolver is not initialized"', capabilities)
        self.assertIn("local IsPlayerInRaid = assert(", capabilities)
        self.assertIn("module.IsPlayerInRaid", capabilities)
        self.assertIn('"Raid capability raid-membership resolver is not initialized"', capabilities)
        self.assertIn("local method = select(1, GetLootMethod())", capabilities)
        self.assertIn("local inRaid = IsPlayerInRaid(module)", capabilities)
        self.assertIn('local rank = tonumber(GetUnitRank("player", 0)) or 0', capabilities)
        self.assertNotIn("local getLootMethod = GetLootMethod", capabilities)
        self.assertNotIn("local unitIsUnit = UnitIsUnit", capabilities)
        self.assertNotIn('type(getLootMethod) ~= "function"', capabilities)
        self.assertNotIn('type(module.IsPlayerInRaid) == "function"', capabilities)
        self.assertNotIn("Database.GetUnitRank and", capabilities)

    def test_raid_attendance_depends_on_wow_roster_apis_without_local_fallbacks(self):
        attendance = read(RAID_ATTENDANCE)

        self.assertIn("local GetNumRaidMembers = assert(", attendance)
        self.assertIn('"Raid attendance roster count API is not initialized"', attendance)
        self.assertIn("tonumber(GetNumRaidMembers()) or 0", attendance)
        self.assertNotIn("local Client = assert(feature.Client", attendance)
        self.assertNotIn("Client.GetRaidMemberCount()", attendance)
        self.assertIn("local GetRaidRosterInfo = assert(", attendance)
        self.assertIn("GetRaidRosterInfo,", attendance)
        self.assertIn('"Raid attendance roster info API is not initialized"', attendance)
        self.assertNotRegex(
            attendance,
            r"local\s+GetNumRaidMembers\s*=\s*GetNumRaidMembers\s+or\s+function",
        )
        self.assertNotRegex(
            attendance,
            r"local\s+GetRaidRosterInfo\s*=\s*GetRaidRosterInfo\s+or\s+function",
        )

    def test_raid_attendance_binds_declared_events_without_optional_callback_guards(self):
        attendance = read(RAID_ATTENDANCE)

        self.assertIn('"Modules/Events"', attendance)
        self.assertIn('"Modules/Bus"', attendance)
        self.assertIn("local RegisterCallback = assert(", attendance)
        self.assertIn("Bus.RegisterCallback", attendance)
        self.assertIn('"Raid attendance event bus listener is not initialized"', attendance)
        self.assertIn("local RaidRosterDeltaEvent =", attendance)
        self.assertIn("InternalEvents.RaidRosterDelta", attendance)
        self.assertIn('"Raid attendance roster-delta event is not initialized"', attendance)
        self.assertIn("local RaidCreateEvent = assert(", attendance)
        self.assertIn("InternalEvents.RaidCreate", attendance)
        self.assertIn('"Raid attendance raid-create event is not initialized"', attendance)
        self.assertIn("RegisterCallback(RaidRosterDeltaEvent, handleRosterDelta)", attendance)
        self.assertIn("RegisterCallback(RaidCreateEvent, function(_, raidId)", attendance)
        self.assertNotIn("if Bus and Bus.RegisterCallback", attendance)
        self.assertNotIn("Bus.RegisterCallback(InternalEvents.", attendance)

    def test_raid_attendance_emits_changed_event_through_validated_publisher(self):
        attendance = read(RAID_ATTENDANCE)

        self.assertIn('"Modules/Events"', attendance)
        self.assertIn('"Modules/Bus"', attendance)
        self.assertIn("local InternalEvents = assert(Events.Internal", attendance)
        self.assertIn('"Raid attendance internal events are not initialized"', attendance)
        self.assertIn("local TriggerEvent = assert(", attendance)
        self.assertIn("Bus.TriggerEvent", attendance)
        self.assertIn('"Raid attendance event publisher is not initialized"', attendance)
        self.assertIn("local RaidAttendanceChangedEvent =", attendance)
        self.assertIn("InternalEvents.RaidAttendanceChanged", attendance)
        self.assertIn('"Raid attendance changed event is not initialized"', attendance)
        self.assertIn("TriggerEvent(RaidAttendanceChangedEvent, raidId, reason)", attendance)
        self.assertIn("notifyRaidAttendanceChanged(raidId, reason or \"raid_start\")", attendance)
        self.assertIn("notifyRaidAttendanceChanged(resolvedRaidNum, delta.reason)", attendance)
        self.assertIn("notifyRaidAttendanceChanged(raidId, reason or \"attendance_end\")", attendance)
        self.assertNotIn("local InternalEvents = Events.Internal", attendance)
        self.assertNotIn("Bus.TriggerEvent(InternalEvents.RaidAttendanceChanged", attendance)

    def test_raid_session_depends_on_dboptions_without_local_fallback(self):
        raid_session = read(RAID_SESSION)

        self.assertIn('"Database/DBOptions"', raid_session)
        self.assertIn("local isDebugEnabled = feature.Options.IsDebugEnabled", raid_session)
        self.assertNotRegex(raid_session, r"local\s+isDebugEnabled\s*=\s*feature\.Options\.IsDebugEnabled\s+or\s+function")

    def test_raid_roster_depends_on_dboptions_without_local_fallback(self):
        raid_roster = read(RAID_ROSTER)

        self.assertIn('"Database/DBOptions"', raid_roster)
        self.assertIn("local isDebugEnabled = feature.Options.IsDebugEnabled", raid_roster)
        self.assertNotRegex(raid_roster, r"local\s+isDebugEnabled\s*=\s*feature\.Options\.IsDebugEnabled\s+or\s+function")

    def test_raid_roster_emits_delta_event_without_direct_event_lookup(self):
        raid_roster = read(RAID_ROSTER)

        self.assertIn('"Modules/Events"', raid_roster)
        self.assertIn('"Modules/Bus"', raid_roster)
        self.assertIn("local InternalEvents = assert(Events.Internal", raid_roster)
        self.assertIn('"Raid roster internal events are not initialized"', raid_roster)
        self.assertIn("local TriggerEvent = assert(", raid_roster)
        self.assertIn("Bus.TriggerEvent", raid_roster)
        self.assertIn('"Raid roster event publisher is not initialized"', raid_roster)
        self.assertIn("local RaidRosterDeltaEvent = assert(", raid_roster)
        self.assertIn("InternalEvents.RaidRosterDelta", raid_roster)
        self.assertIn('"Raid roster delta event is not initialized"', raid_roster)
        self.assertIn("TriggerEvent(RaidRosterDeltaEvent, payload, rosterVersion, raidNum)", raid_roster)
        self.assertNotIn("local InternalEvents = Events.Internal", raid_roster)
        self.assertNotIn("Bus.TriggerEvent(InternalEvents.RaidRosterDelta", raid_roster)

    def test_raid_counts_emits_player_count_changed_through_validated_publisher(self):
        raid_counts = read(RAID_COUNTS)

        self.assertIn('"Modules/Events"', raid_counts)
        self.assertIn('"Modules/Bus"', raid_counts)
        self.assertIn("local InternalEvents = assert(Events.Internal", raid_counts)
        self.assertIn('"Raid counts internal events are not initialized"', raid_counts)
        self.assertIn("local TriggerEvent = assert(", raid_counts)
        self.assertIn("Bus.TriggerEvent", raid_counts)
        self.assertIn('"Raid counts event publisher is not initialized"', raid_counts)
        self.assertIn("local PlayerCountChangedEvent =", raid_counts)
        self.assertIn("InternalEvents.PlayerCountChanged", raid_counts)
        self.assertIn('"Raid counts player-count event is not initialized"', raid_counts)
        self.assertIn("TriggerEvent(PlayerCountChangedEvent, player.name, value, old, resolvedRaidNum)", raid_counts)
        self.assertNotIn("local bus = feature.Bus", raid_counts)
        self.assertNotIn("bus.TriggerEvent(InternalEvents.PlayerCountChanged", raid_counts)

    def test_raid_state_depends_on_dboptions_without_local_fallback(self):
        raid_state = read(RAID_STATE)

        self.assertIn('"Database/DBOptions"', raid_state)
        self.assertIn("local isDebugEnabled = feature.Options.IsDebugEnabled", raid_state)
        self.assertNotRegex(raid_state, r"local\s+isDebugEnabled\s*=\s*feature\.Options\.IsDebugEnabled\s+or\s+function")

    def test_raid_state_emits_raid_create_through_validated_publisher(self):
        raid_state = read(RAID_STATE)

        self.assertIn('"Modules/Events"', raid_state)
        self.assertIn('"Modules/Bus"', raid_state)
        self.assertIn("local InternalEvents = assert(Events.Internal", raid_state)
        self.assertIn('"Raid state internal events are not initialized"', raid_state)
        self.assertIn("local TriggerEvent = assert(", raid_state)
        self.assertIn("Bus.TriggerEvent", raid_state)
        self.assertIn('"Raid state event publisher is not initialized"', raid_state)
        self.assertIn("local RaidCreateEvent = assert(", raid_state)
        self.assertIn("InternalEvents.RaidCreate", raid_state)
        self.assertIn('"Raid state raid-create event is not initialized"', raid_state)
        self.assertIn("TriggerEvent(RaidCreateEvent, raidId)", raid_state)
        self.assertIn("notifyRaidCreate(Database.GetCurrentRaid())", raid_state)
        self.assertNotIn("local InternalEvents = Events.Internal", raid_state)
        self.assertNotIn("Bus.TriggerEvent(InternalEvents.RaidCreate", raid_state)

    def test_raid_state_depends_on_loot_namespace_without_empty_table_fallback(self):
        raid_state = read(RAID_STATE)

        self.assertIn('"Services/Loot/Context"', raid_state)
        self.assertIn('"Services/Loot/State"', raid_state)
        self.assertIn('"Services/Loot/Snapshots"', raid_state)
        self.assertIn("local LootService = assert(Services.Loot", raid_state)
        self.assertIn('"Raid state loot namespace is not initialized"', raid_state)
        self.assertNotIn("_ContextBridge", raid_state)
        self.assertIn('assert(LootService._State, "Loot context state owner is not initialized")', raid_state)
        self.assertNotIn("local LootService = Services and Services.Loot or {}", raid_state)

    def test_raid_state_uses_declared_raid_queries_owner_without_optional_getter_guard(self):
        raid_state = read(RAID_STATE)

        self.assertIn('"Database/DBRaidQueries"', raid_state)
        self.assertIn("local queries = Database.GetRaidQueries()", raid_state)
        self.assertIn("return queries:FindBossByNid(raid, bossNid)", raid_state)
        self.assertIn("return queries:FindBossByName(raid, bossName)", raid_state)
        self.assertIn("return queries:FindBossBySourceNpcId(raid, sourceNpcId)", raid_state)
        self.assertIn("return queries:FindBossBySourceKey(raid, sourceKey)", raid_state)
        self.assertNotIn("Database.GetRaidQueriesOrNil and Database.GetRaidQueriesOrNil()", raid_state)
        self.assertNotIn("if queries and queries.FindBossByNid then", raid_state)
        self.assertNotIn("if queries and queries.FindBossByName then", raid_state)
        self.assertNotIn("if queries and queries.FindBossBySourceNpcId then", raid_state)
        self.assertNotIn("if queries and queries.FindBossBySourceKey then", raid_state)

    def test_raid_state_uses_declared_raid_store_lookup_without_optional_function_guard(self):
        raid_state = read(RAID_STATE)

        self.assertIn('"Database/DBRaidStore"', raid_state)
        self.assertIn("local raid = Database.EnsureRaidById(raidNum)", raid_state)
        self.assertIn("local queryRaidNum = tonumber(raidNum) or tonumber(Database.GetCurrentRaid()) or 0", raid_state)
        self.assertIn('local raidStore = Database.GetRaidStoreOrNil("Raid.Create", { "CreateRaidRecord", "InsertRaid" })', raid_state)
        self.assertNotIn(
            'type(Database.EnsureRaidById) == "function" and Database.EnsureRaidById(raidNum) or nil',
            raid_state,
        )
        self.assertNotIn("Database.GetCurrentRaid and Database.GetCurrentRaid()", raid_state)
        self.assertNotIn("Database.GetRaidStoreOrNil\n\t\t\t\tand Database.GetRaidStoreOrNil", raid_state)

    def test_raid_loot_records_uses_declared_raid_queries_owner_without_optional_getter_guard(self):
        loot_records = read(RAID_LOOT_RECORDS)

        self.assertIn('"Database/DBRaidQueries"', loot_records)
        self.assertIn("local queries = Database.GetRaidQueries()", loot_records)
        self.assertIn("return queries:ResolveLootLooterName(raid, entry)", loot_records)
        self.assertNotIn("Database.GetRaidQueriesOrNil and Database.GetRaidQueriesOrNil()", loot_records)
        self.assertNotIn("if queries and queries.ResolveLootLooterName then", loot_records)

    def test_logger_view_uses_declared_raid_queries_owner_without_optional_getter_guard(self):
        logger_view = read(LOGGER_VIEW)

        self.assertIn('"Database/DBRaidQueries"', logger_view)
        self.assertIn("local queries = Database.GetRaidQueries()", logger_view)
        self.assertNotIn("Database.GetRaidQueriesOrNil()", logger_view)
        self.assertNotIn("Database.GetRaidQueries and Database.GetRaidQueries() or nil", logger_view)
        self.assertNotIn("if queries and queries.GetBossKills then", logger_view)
        self.assertNotIn("if queries and queries.GetRaidAttendance then", logger_view)
        self.assertNotIn("if queries and queries.GetBossAttendance then", logger_view)
        self.assertNotIn("if queries and queries.GetLoot then", logger_view)
        self.assertNotIn("queries and queries.GetRaidSummary and", logger_view)

    def test_loot_service_uses_declared_raid_queries_owner_without_optional_getter_guard(self):
        loot_service = read(LOOT_SERVICE)

        self.assertIn('"Database/DBRaidQueries"', loot_service)
        self.assertIn('"Services/Raid/State"', loot_service)
        self.assertIn("local queries = Database.GetRaidQueries()", loot_service)
        self.assertIn("raidNum = Database.GetCurrentRaid(),", loot_service)
        self.assertIn("return queries:ResolveLootLooterName(raid, loot)", loot_service)
        self.assertNotIn("Database.GetRaidQueriesOrNil and Database.GetRaidQueriesOrNil()", loot_service)
        self.assertNotIn("Database.GetCurrentRaid and Database.GetCurrentRaid()", loot_service)
        self.assertNotIn("if queries and queries.ResolveLootLooterName then", loot_service)
        self.assertNotIn("raidService:GetPlayerName(looterNid, raidNum)", loot_service)

    def test_loot_service_uses_declared_raid_store_owner_without_optional_getter_guard(self):
        loot_service = read(LOOT_SERVICE)

        self.assertIn('"Database/DB"', loot_service)
        self.assertIn('"Database/DBRaidStore"', loot_service)
        self.assertIn('local raidStore = Database.GetRaidStoreOrNil("Loot.UpsertLootIndex", { "UpsertLootIndex" })', loot_service)
        self.assertIn("if not raidStore then", loot_service)
        self.assertIn("return raidStore:UpsertLootIndex(raid, lootInfo, index)", loot_service)
        self.assertNotIn("if not (Database and Database.GetRaidStoreOrNil) then", loot_service)
        self.assertNotIn("and Database.GetRaidStoreOrNil", loot_service)
        self.assertNotIn("raidStore and raidStore.UpsertLootIndex", loot_service)

    def test_loot_recording_uses_declared_raid_store_owner_without_optional_getter_guard(self):
        recording = read(LOOT_RECORDING)

        self.assertIn('"Database/DBRaidStore"', recording)
        self.assertIn(
            'local raidStore = Database.GetRaidStoreOrNil("Loot.Recording.Append", { "MarkLootSyncRevision" })',
            recording,
        )
        self.assertFalse((ADDON / "Services" / "Loot" / "Receipts.lua").exists())
        self.assertFalse((ADDON / "Services" / "Loot" / "Records.lua").exists())
        self.assertFalse((ADDON / "Services" / "Loot" / "Reconcile.lua").exists())
        self.assertIn('if raidStore then', recording)
        self.assertIn('raidStore:MarkLootSyncRevision(raid, row, "loot_row")', recording)
        self.assertNotIn("Database\n\t\tand Database.GetRaidStoreOrNil", recording)
        self.assertNotIn("and Database.GetRaidStoreOrNil", recording)
        self.assertNotIn("raidStore and raidStore.MarkLootSyncRevision", recording)

    def test_raid_state_depends_on_wotlk_unit_name_without_loot_context_fallback(self):
        raid_state = read(RAID_STATE)

        self.assertIn("local UnitName = assert(", raid_state)
        self.assertIn("_G.UnitName", raid_state)
        self.assertIn('"Raid state unit name API is not initialized"', raid_state)
        self.assertNotIn('type(UnitName) == "function" and UnitName(unit) or nil', raid_state)

    def test_raid_state_depends_on_wotlk_instance_info_without_event_payload_fallback(self):
        raid_state = read(RAID_STATE)

        self.assertIn("local GetInstanceInfo = assert(", raid_state)
        self.assertIn("_G.GetInstanceInfo", raid_state)
        self.assertIn('"Raid state instance info API is not initialized"', raid_state)
        self.assertNotIn('type(GetInstanceInfo) == "function"', raid_state)
        self.assertNotIn('type(GetInstanceInfo) ~= "function"', raid_state)

    def test_raid_state_uses_declared_creature_id_owner_without_optional_fallback(self):
        raid_state = read(RAID_STATE)

        self.assertIn("local GetCreatureId = assert(", raid_state)
        self.assertIn("feature.GetCreatureId", raid_state)
        self.assertIn('"Raid state creature-id helper is not initialized"', raid_state)
        self.assertIn("local npcId = guid and GetCreatureId(guid) or 0", raid_state)
        self.assertNotIn("guid and GetCreatureId and GetCreatureId(guid)", raid_state)

    def test_ui_frames_depends_on_strings_without_editbox_raw_text_fallback(self):
        ui_frames = read(UI_FRAMES)

        self.assertIn('"Modules/Strings"', ui_frames)
        self.assertRegex(ui_frames, r"local\s+TrimText\s*=\s*assert\(")
        self.assertIn("Strings.TrimText", ui_frames)
        self.assertIn('"UI edit-box text normalizer is not initialized"', ui_frames)
        self.assertIn("local value = TrimText(self.editBox:GetText(), true)", ui_frames)
        self.assertNotIn("local trimText = Strings and Strings.TrimText", ui_frames)
        self.assertNotIn("trimText and trimText(self.editBox:GetText(), true) or self.editBox:GetText()", ui_frames)

    def test_screen_notice_binds_declared_event_without_optional_callback_guard(self):
        screen_notice = read(UI_SCREEN_NOTICE)

        self.assertIn('"Modules/Events"', screen_notice)
        self.assertIn('"Modules/Bus"', screen_notice)
        self.assertIn("local InternalEvents = assert(Events.Internal", screen_notice)
        self.assertIn('"Screen notice internal events are not initialized"', screen_notice)
        self.assertIn("local RegisterCallback = assert(", screen_notice)
        self.assertIn("Bus.RegisterCallback", screen_notice)
        self.assertIn('"Screen notice event bus listener is not initialized"', screen_notice)
        self.assertIn("local ScreenNoticeEvent = assert(", screen_notice)
        self.assertIn("InternalEvents.ScreenNotice", screen_notice)
        self.assertIn('"Screen notice event name is not initialized"', screen_notice)
        self.assertIn("RegisterCallback(ScreenNoticeEvent, showNotice)", screen_notice)
        self.assertNotIn("Events and Events.Internal", screen_notice)
        self.assertNotIn("local InternalEvents = Events.Internal", screen_notice)
        self.assertNotIn("if Bus and Bus.RegisterCallback", screen_notice)
        self.assertNotIn("Bus.RegisterCallback(InternalEvents.ScreenNotice", screen_notice)

    def test_options_layout_depends_on_wotlk_dropdown_sizing_apis_without_optional_guards(self):
        options_layout = read(UI_OPTIONS_LAYOUT)

        self.assertRegex(options_layout, r"local\s+UIDropDownMenu_SetWidth\s*=\s*assert\(")
        self.assertIn("_G.UIDropDownMenu_SetWidth", options_layout)
        self.assertIn('"Options layout dropdown width API is not initialized"', options_layout)
        self.assertRegex(options_layout, r"local\s+UIDropDownMenu_SetButtonWidth\s*=\s*assert\(")
        self.assertIn("_G.UIDropDownMenu_SetButtonWidth", options_layout)
        self.assertIn('"Options layout dropdown button width API is not initialized"', options_layout)
        self.assertIn("UIDropDownMenu_SetWidth(dropDown,", options_layout)
        self.assertIn("UIDropDownMenu_SetButtonWidth(dropDown,", options_layout)
        self.assertNotIn("_G.UIDropDownMenu_SetWidth and dropDown", options_layout)
        self.assertNotIn("_G.UIDropDownMenu_SetButtonWidth and dropDown", options_layout)

    def test_list_controller_depends_on_dboptions_without_local_fallback(self):
        list_controller = read(LIST_CONTROLLER)

        self.assertIn('"Database/DBOptions"', list_controller)
        self.assertIn("local isDebugEnabled = Options.IsDebugEnabled", list_controller)
        self.assertNotRegex(list_controller, r"local\s+isDebugEnabled\s*=\s*Options\.IsDebugEnabled\s+or\s+function")

    def test_reserves_ui_depends_on_dboptions_without_local_fallback(self):
        reserves_ui = read(RESERVES_UI)

        self.assertIn('"Database/DBOptions"', reserves_ui)
        self.assertIn("local isDebugEnabled = Options.IsDebugEnabled", reserves_ui)
        self.assertNotRegex(reserves_ui, r"local\s+isDebugEnabled\s*=\s*Options\.IsDebugEnabled\s+or\s+function")

    def test_reserves_ui_uses_declared_options_namespace_owner_without_optional_get_guard(self):
        reserves_ui = read(RESERVES_UI)

        self.assertIn('"Database/DBOptions"', reserves_ui)
        self.assertRegex(reserves_ui, r"local\s+GetOptionsNamespace\s*=\s*assert\(")
        self.assertIn("Options.Get", reserves_ui)
        self.assertIn('"Reserves UI options namespace resolver is not initialized"', reserves_ui)
        self.assertIn('return GetOptionsNamespace("Reserves")', reserves_ui)
        self.assertIn("local reservesNs = getReservesOptions()", reserves_ui)
        self.assertNotIn("Options and Options.Get", reserves_ui)

    def test_reserves_ui_uses_declared_service_owners_without_optional_guards(self):
        reserves_ui = read(RESERVES_UI)

        self.assertIn('"Services/Chat"', reserves_ui)
        self.assertIn('"Services/Reserves"', reserves_ui)
        self.assertIn('"Services/Raid/Roster"', reserves_ui)
        self.assertIn('"Modules/Colors"', reserves_ui)
        self.assertIn('"Modules/UI/Frames"', reserves_ui)
        self.assertIn("local HideTooltip = assert(Tooltips.Hide", reserves_ui)
        self.assertIn('"Reserves UI tooltip hider is not initialized"', reserves_ui)
        self.assertIn("local ShowItemTooltip = assert(Tooltips.ShowItem", reserves_ui)
        self.assertIn('"Reserves UI item tooltip presenter is not initialized"', reserves_ui)
        self.assertIn("local BindTooltip = assert(Tooltips.Bind", reserves_ui)
        self.assertIn('"Reserves UI tooltip binder is not initialized"', reserves_ui)
        self.assertIn("local GetClassColor = assert(Colors.GetClassColor", reserves_ui)
        self.assertIn('"Reserves UI class-color resolver is not initialized"', reserves_ui)
        self.assertIn("local Reserves = assert(Services.Reserves", reserves_ui)
        self.assertIn('"Reserves UI service is not initialized"', reserves_ui)
        self.assertIn("local HasReserveData = assert(Reserves.HasData", reserves_ui)
        self.assertIn('"Reserves UI data-state resolver is not initialized"', reserves_ui)
        self.assertIn("local IsPlusReserveSystem = assert(Reserves.IsPlusSystem", reserves_ui)
        self.assertIn('"Reserves UI import-mode resolver is not initialized"', reserves_ui)
        self.assertIn("local HasPendingReserveItem = assert(Reserves.HasPendingItem", reserves_ui)
        self.assertIn('"Reserves UI pending-item resolver is not initialized"', reserves_ui)
        self.assertRegex(reserves_ui, r"local\s+RemovePlayerReserve\s*=\s*assert\(Reserves\.RemovePlayerReserve")
        self.assertIn('"Reserves UI remove-reserve handler is not initialized"', reserves_ui)
        self.assertIn("local ClearSavedReserves = assert(Reserves.ClearSavedReserves", reserves_ui)
        self.assertIn('"Reserves UI clear-saved handler is not initialized"', reserves_ui)
        self.assertIn("local GetReserveDisplayList = assert(Reserves.GetDisplayList", reserves_ui)
        self.assertIn('"Reserves UI display-list resolver is not initialized"', reserves_ui)
        self.assertIn("local GetImportMode = assert(Reserves.GetImportMode", reserves_ui)
        self.assertIn('"Reserves UI import-mode getter is not initialized"', reserves_ui)
        self.assertIn("local ParseImport = assert(Reserves.ParseImport", reserves_ui)
        self.assertIn('"Reserves UI import parser is not initialized"', reserves_ui)
        self.assertIn("local RequestApplyImport = assert(Reserves.RequestApplyImport", reserves_ui)
        self.assertIn('"Reserves UI import-apply handler is not initialized"', reserves_ui)
        self.assertIn("local SetImportMode = assert(Reserves.SetImportMode", reserves_ui)
        self.assertIn('"Reserves UI import-mode setter is not initialized"', reserves_ui)
        self.assertIn("local Chat = assert(Services.Chat", reserves_ui)
        self.assertIn('"Reserves UI chat service is not initialized"', reserves_ui)
        self.assertIn("local AnnounceChat = assert(Chat.Announce", reserves_ui)
        self.assertIn('"Reserves UI chat announcer is not initialized"', reserves_ui)
        self.assertIn("local Raid = assert(Services.Raid", reserves_ui)
        self.assertIn('"Reserves UI raid service is not initialized"', reserves_ui)
        self.assertRegex(reserves_ui, r"local\s+GetPlayerClass\s*=\s*assert\(")
        self.assertIn("Raid.GetPlayerClass", reserves_ui)
        self.assertIn('"Reserves UI raid class resolver is not initialized"', reserves_ui)
        self.assertIn("return HasReserveData(Reserves)", reserves_ui)
        self.assertIn("return IsPlusReserveSystem(Reserves)", reserves_ui)
        self.assertIn("if not HasPendingReserveItem(Reserves, itemId) then", reserves_ui)
        self.assertIn("RemovePlayerReserve(Reserves, playerName, itemId)", reserves_ui)
        self.assertIn("local out = ClearSavedReserves(Reserves)", reserves_ui)
        self.assertIn("local displayList = GetReserveDisplayList(Reserves)", reserves_ui)
        self.assertIn("return GetImportMode(Reserves)", reserves_ui)
        self.assertIn('local parsed = ParseImport(Reserves, data.csv, "multi", { source = "import_window", format = "csv" })', reserves_ui)
        self.assertIn("ParseImport(Reserves, importText, mode, { source = \"import_window\", format = importFormat })", reserves_ui)
        self.assertIn("return RequestApplyImport(Reserves, parsed, nil, function(ok, nPlayersOrErr, applyErrData)", reserves_ui)
        self.assertIn("SetImportMode(Reserves, mode, true)", reserves_ui)
        self.assertIn('AnnounceChat(Chat, format(L.ChatSoftResWhisperHelpQuery, targetName), "RAID")', reserves_ui)
        self.assertIn('AnnounceChat(Chat, format(L.ChatSoftResWhisperHelpAdd, targetName), "RAID")', reserves_ui)
        self.assertIn("local r, g, b = GetClassColor(className)", reserves_ui)
        self.assertIn("row.nameText:SetTextColor(r, g, b)", reserves_ui)
        self.assertIn("HideTooltip()", reserves_ui)
        self.assertIn('return ShowItemTooltip(owner, link, row._tooltipTitle, "ANCHOR_RIGHT")', reserves_ui)
        self.assertIn("BindTooltip(\n\t\t\t\trefs.softResAccept", reserves_ui)
        self.assertIn("BindTooltip(\n\t\t\t\trefs.softResResponseWisp", reserves_ui)
        self.assertIn("local rosterClass = GetPlayerClass(Raid, playerName)", reserves_ui)
        self.assertNotIn("local Reserves = Services and Services.Reserves", reserves_ui)
        self.assertNotIn("Tooltips and Tooltips.Hide", reserves_ui)
        self.assertNotIn("Tooltips or not Tooltips.ShowItem", reserves_ui)
        self.assertNotIn("Tooltips and Tooltips.Bind", reserves_ui)
        self.assertNotIn("Colors and Colors.GetClassColor", reserves_ui)
        self.assertNotIn("row.nameText:SetTextColor(1, 1, 1)", reserves_ui)
        self.assertNotIn("Reserves and Reserves.HasData", reserves_ui)
        self.assertNotIn("Reserves and Reserves.IsPlusSystem", reserves_ui)
        self.assertNotIn("Reserves and Reserves.HasPendingItem", reserves_ui)
        self.assertNotIn("Reserves and Reserves.RemovePlayerReserve", reserves_ui)
        self.assertNotIn("Reserves and Reserves.ClearSavedReserves", reserves_ui)
        self.assertNotIn("Reserves and Reserves.GetDisplayList", reserves_ui)
        self.assertNotIn("Reserves and Reserves.GetImportMode", reserves_ui)
        self.assertNotIn("Reserves and Reserves.ParseImport", reserves_ui)
        self.assertNotIn("Reserves and Reserves.RequestApplyImport", reserves_ui)
        self.assertNotIn("Reserves and Reserves.SetImportMode", reserves_ui)
        self.assertNotIn('Reserves:ParseImport(data.csv', reserves_ui)
        self.assertNotIn("Reserves:ParseImport(importText", reserves_ui)
        self.assertNotIn("if not (Chat and Chat.Announce)", reserves_ui)
        self.assertNotIn("Chat:Announce(", reserves_ui)
        self.assertNotIn('reservesNs:Get("srImportMode")', reserves_ui)
        self.assertNotIn('reservesNs:Set("srImportMode"', reserves_ui)
        self.assertNotIn("local Chat = Services and Services.Chat", reserves_ui)
        self.assertNotIn("local raidService = Services and Services.Raid", reserves_ui)
        self.assertNotIn('type(raidService.GetPlayerClass) == "function"', reserves_ui)

    def test_chat_service_depends_on_dboptions_without_local_fallback(self):
        chat = read(CHAT)

        self.assertIn('"Database/DBOptions"', chat)
        self.assertIn("local GetOption = Options.GetValue", chat)
        self.assertNotRegex(chat, r"local\s+GetOption\s*=\s*Options\.GetValue\s+or\s+function")

    def test_chat_service_uses_group_policy_owner_without_local_roster_fallbacks(self):
        chat = read(CHAT)

        self.assertIn("local GetGroupTypeAndCount = assert(", chat)
        self.assertIn("feature.GetGroupTypeAndCount", chat)
        self.assertIn('"Chat group policy helper is not initialized"', chat)
        self.assertNotIn('type(GetGroupTypeAndCount) == "function"', chat)
        self.assertNotIn("type(addon.IsInRaid) == \"function\"", chat)
        self.assertNotIn("type(IsInRaid) == \"function\"", chat)
        self.assertNotIn("type(UnitInRaid) == \"function\"", chat)
        self.assertNotIn("GetRealNumRaidMembers and GetRealNumRaidMembers()", chat)
        self.assertNotIn("GetNumRaidMembers and GetNumRaidMembers()", chat)
        self.assertNotIn("GetRealNumPartyMembers and GetRealNumPartyMembers()", chat)
        self.assertNotIn("GetNumPartyMembers and GetNumPartyMembers()", chat)

    def test_reserves_chat_depends_on_dboptions_without_local_fallback(self):
        reserves_chat = read(RESERVES_CHAT)

        self.assertIn('"Database/DBOptions"', reserves_chat)
        self.assertIn("local GetOption = Options.GetValue", reserves_chat)
        self.assertNotRegex(reserves_chat, r"local\s+GetOption\s*=\s*Options\.GetValue\s+or\s+function")

    def test_reserves_chat_uses_declared_whisper_and_raid_policy_owners_without_optional_guards(self):
        reserves_chat = read(RESERVES_CHAT)

        self.assertIn('"Modules/Comms"', reserves_chat)
        self.assertIn('"Modules/Events"', reserves_chat)
        self.assertIn('"Modules/Bus"', reserves_chat)
        self.assertIn('"Services/Raid/Capabilities"', reserves_chat)
        self.assertIn("local Raid = assert(", reserves_chat)
        self.assertIn("Services.Raid", reserves_chat)
        self.assertIn('"Reserves chat raid service is not initialized"', reserves_chat)
        self.assertIn("local GetPlayerRoleState = assert(", reserves_chat)
        self.assertIn("Raid.GetPlayerRoleState", reserves_chat)
        self.assertIn('"Reserves chat raid-role resolver is not initialized"', reserves_chat)
        self.assertIn("local CanUseCapability = assert(", reserves_chat)
        self.assertIn("Raid.CanUseCapability", reserves_chat)
        self.assertIn('"Reserves chat raid capability resolver is not initialized"', reserves_chat)
        self.assertIn("local SendWhisper = assert(", reserves_chat)
        self.assertIn("Comms.SendWhisper", reserves_chat)
        self.assertIn('"Reserves chat whisper transport is not initialized"', reserves_chat)
        self.assertIn("local RegisterCallback = assert(", reserves_chat)
        self.assertIn("Bus.RegisterCallback", reserves_chat)
        self.assertIn('"Reserves chat event bus listener is not initialized"', reserves_chat)
        self.assertIn("local WhisperEvent =", reserves_chat)
        self.assertIn("assert(Events.Wow and Events.Wow.ChatMsgWhisper", reserves_chat)
        self.assertIn("Events.Wow and Events.Wow.ChatMsgWhisper", reserves_chat)
        self.assertIn('"Reserves chat whisper event name is not initialized"', reserves_chat)
        self.assertIn("local ScheduleTimer = assert(", reserves_chat)
        self.assertIn("module.ScheduleTimer", reserves_chat)
        self.assertIn('"Reserves chat throttle scheduler is not initialized"', reserves_chat)
        self.assertIn("local IsPlusSystem = assert(", reserves_chat)
        self.assertIn("module.IsPlusSystem", reserves_chat)
        self.assertIn('"Reserves chat import-mode resolver is not initialized"', reserves_chat)
        self.assertIn("local AddPlayerReserve = assert(", reserves_chat)
        self.assertIn("module.AddPlayerReserve", reserves_chat)
        self.assertIn('"Reserves chat add-reserve handler is not initialized"', reserves_chat)
        self.assertIn("local GetPlayerReserveEntries =", reserves_chat)
        self.assertIn("assert(module.GetPlayerReserveEntries", reserves_chat)
        self.assertIn("module.GetPlayerReserveEntries", reserves_chat)
        self.assertIn('"Reserves chat player-reserve lookup is not initialized"', reserves_chat)
        self.assertIn("return SendWhisper(target, text)", reserves_chat)
        self.assertIn("ScheduleTimer(module, processWhisperQueue, WHISPER_THROTTLE_SECONDS)", reserves_chat)
        self.assertIn("local role = GetPlayerRoleState(Raid)", reserves_chat)
        self.assertIn('CanUseCapability(Raid, "loot")', reserves_chat)
        self.assertIn('CanUseCapability(Raid, "raid_leadership")', reserves_chat)
        self.assertIn("RegisterCallback(WhisperEvent, function(_, msg, sender)", reserves_chat)
        self.assertIn("local plus = IsPlusSystem(module) and (tonumber(entry.plus) or 0) or 0", reserves_chat)
        self.assertIn("local ok, reserveEntry = AddPlayerReserve(module, target, itemRef)", reserves_chat)
        self.assertIn("local entries = GetPlayerReserveEntries(module, target)", reserves_chat)
        self.assertNotIn("if not (Comms and Comms.SendWhisper) then", reserves_chat)
        self.assertNotIn("local raid = Services and Services.Raid or nil", reserves_chat)
        self.assertNotIn("if not (raid and raid.GetPlayerRoleState and raid.CanUseCapability) then", reserves_chat)
        self.assertNotIn("local eventName = Events and Events.Wow and Events.Wow.ChatMsgWhisper", reserves_chat)
        self.assertNotIn("if not (eventName and Bus and Bus.RegisterCallback) then", reserves_chat)
        self.assertNotIn("if not (module.ScheduleTimer and processWhisperQueue) then", reserves_chat)
        self.assertNotIn("module.IsPlusSystem and module:IsPlusSystem()", reserves_chat)
        self.assertNotIn("if module.AddPlayerReserve then", reserves_chat)
        self.assertNotIn("module.GetPlayerReserveEntries and module:GetPlayerReserveEntries(target) or {}", reserves_chat)

    def test_reserves_service_depends_on_dboptions_without_local_fallback(self):
        reserves_service = read(RESERVES_SERVICE)

        self.assertIn('"Database/DBOptions"', reserves_service)
        self.assertIn("local isDebugEnabled = Options.IsDebugEnabled", reserves_service)
        self.assertNotRegex(reserves_service, r"local\s+isDebugEnabled\s*=\s*Options\.IsDebugEnabled\s+or\s+function")

    def test_reserves_service_depends_on_wotlk_item_info_api_without_local_fallback(self):
        reserves_service = read(RESERVES_SERVICE)

        self.assertIn("local GetItemInfo = assert(", reserves_service)
        self.assertIn("_G.GetItemInfo", reserves_service)
        self.assertIn('"Reserves item info API is not initialized"', reserves_service)
        self.assertNotIn('type(GetItemInfo) == "function"', reserves_service)

    def test_reserves_service_depends_on_strings_without_display_name_fallback(self):
        reserves_service = read(RESERVES_SERVICE)

        self.assertIn('"Modules/Strings"', reserves_service)
        self.assertIn("local NormalizeName = assert(", reserves_service)
        self.assertIn("Strings.NormalizeName", reserves_service)
        self.assertIn('"Reserves display name normalizer is not initialized"', reserves_service)
        self.assertIn("candidate = NormalizeName(candidate, true)", reserves_service)
        self.assertNotIn("if Strings and Strings.NormalizeName then", reserves_service)
        self.assertNotIn("Strings.TrimText(candidate, true)", reserves_service)

    def test_reserves_service_uses_declared_database_raid_owners_without_optional_guards(self):
        reserves_service = read(RESERVES_SERVICE)

        self.assertIn('"Database/DB"', reserves_service)
        self.assertIn('"Database/DBRaidStore"', reserves_service)
        self.assertIn("local currentRaid = Database.GetCurrentRaid()", reserves_service)
        self.assertIn("return Database.EnsureRaidById(currentRaid)", reserves_service)
        self.assertIn("return Database.GetCurrentRaid()", reserves_service)
        self.assertNotIn("Database and Database.GetCurrentRaid and Database.GetCurrentRaid()", reserves_service)
        self.assertNotIn("if Database and Database.EnsureRaidById then", reserves_service)

    def test_reserves_service_emits_data_changed_through_validated_helper(self):
        reserves_service = read(RESERVES_SERVICE)

        self.assertIn('"Modules/Events"', reserves_service)
        self.assertIn('"Modules/Bus"', reserves_service)
        self.assertIn("local InternalEvents = assert(Events.Internal", reserves_service)
        self.assertIn('"Reserves internal events are not initialized"', reserves_service)
        self.assertIn("local TriggerEvent = assert(", reserves_service)
        self.assertIn("Bus.TriggerEvent", reserves_service)
        self.assertIn('"Reserves event publisher is not initialized"', reserves_service)
        self.assertIn("local ReservesDataChangedEvent =", reserves_service)
        self.assertIn("InternalEvents.ReservesDataChanged", reserves_service)
        self.assertIn('"Reserves data-changed event is not initialized"', reserves_service)
        self.assertIn("TriggerEvent(ReservesDataChangedEvent, reason, raidId, mode, nPlayers)", reserves_service)
        self.assertIn("notifyReservesDataChanged(reason, raidId, mode, nPlayers)", reserves_service)
        self.assertNotIn("local InternalEvents = Events.Internal", reserves_service)
        self.assertNotIn("Bus.TriggerEvent(InternalEvents.ReservesDataChanged", reserves_service)

    def test_reserves_import_depends_on_dboptions_without_local_fallback(self):
        reserves_import = read(RESERVES_IMPORT)

        self.assertIn('"Database/DBOptions"', reserves_import)
        self.assertIn("local isDebugEnabled = Options.IsDebugEnabled", reserves_import)
        self.assertNotRegex(reserves_import, r"local\s+isDebugEnabled\s*=\s*Options\.IsDebugEnabled\s+or\s+function")

    def test_reserves_sync_depends_on_strings_without_payload_name_fallback(self):
        reserves_sync = read(RESERVES_SYNC)

        self.assertIn('"Modules/Strings"', reserves_sync)
        self.assertIn("local NormalizeLower = assert(", reserves_sync)
        self.assertIn("Strings.NormalizeLower", reserves_sync)
        self.assertIn('"Reserves sync player normalizer is not initialized"', reserves_sync)
        self.assertIn("local playerKey = NormalizeLower(playerName, true)", reserves_sync)
        self.assertNotIn("Strings and Strings.NormalizeLower and Strings.NormalizeLower(playerName, true)", reserves_sync)
        self.assertNotIn("or playerName", reserves_sync)

    def test_reserves_sync_uses_declared_raid_role_owner_without_open_provider_fallback(self):
        reserves_sync = read(RESERVES_SYNC)

        self.assertIn('"Services/Raid/Capabilities"', reserves_sync)
        self.assertIn("local Raid = assert(", reserves_sync)
        self.assertIn("Services.Raid", reserves_sync)
        self.assertIn('"Reserves sync raid service is not initialized"', reserves_sync)
        self.assertIn("local GetPlayerRoleState = assert(", reserves_sync)
        self.assertIn("Raid.GetPlayerRoleState", reserves_sync)
        self.assertIn('"Reserves sync raid-role resolver is not initialized"', reserves_sync)
        self.assertIn("local role = GetPlayerRoleState(Raid) or {}", reserves_sync)
        self.assertNotIn("local raid = Services and Services.Raid or nil", reserves_sync)
        self.assertNotIn("if not (raid and raid.GetPlayerRoleState) then", reserves_sync)
        self.assertNotIn("return true\n\tend\n\n\tlocal role = raid:GetPlayerRoleState()", reserves_sync)

    def test_rolls_responses_depends_on_dboptions_without_local_fallbacks(self):
        rolls_responses = read(ROLLS_RESPONSES)

        self.assertIn('"Database/DBOptions"', rolls_responses)
        self.assertIn("local GetOption = Options.GetValue", rolls_responses)
        self.assertIn("local IsDebugEnabled = Options.IsDebugEnabled", rolls_responses)
        self.assertNotRegex(rolls_responses, r"local\s+GetOption\s*=\s*Options\.GetValue\s+or\s+function")
        self.assertNotRegex(rolls_responses, r"local\s+IsDebugEnabled\s*=\s*Options\.IsDebugEnabled\s+or\s+function")

    def test_rolls_responses_use_declared_database_and_strings_owners_without_optional_guards(self):
        rolls_responses = read(ROLLS_RESPONSES)

        self.assertIn('"Database/DB"', rolls_responses)
        self.assertIn("local NormalizeName = assert(", rolls_responses)
        self.assertIn("Strings.NormalizeName", rolls_responses)
        self.assertIn('"Roll response name normalizer is not initialized"', rolls_responses)
        self.assertIn("raid:IsSyntheticPlayerActive(name, Database.GetCurrentRaid())", rolls_responses)
        self.assertIn("local player = NormalizeName(name, true)", rolls_responses)
        self.assertNotIn("Database.GetCurrentRaid and Database.GetCurrentRaid()", rolls_responses)
        self.assertNotIn("Strings and Strings.NormalizeName and Strings.NormalizeName(name, true)", rolls_responses)

    def test_rolls_sessions_depends_on_strings_without_local_lowercase_fallback(self):
        rolls_sessions = read(ROLLS_SESSIONS)

        self.assertIn('"Modules/Strings"', rolls_sessions)
        self.assertIn("local NormalizeLower = assert(", rolls_sessions)
        self.assertIn("Strings.NormalizeLower", rolls_sessions)
        self.assertIn('"Roll session candidate normalizer is not initialized"', rolls_sessions)
        self.assertIn("local normalized = NormalizeLower(name)", rolls_sessions)
        self.assertNotIn("Strings and Strings.NormalizeLower and Strings.NormalizeLower(name)", rolls_sessions)
        self.assertNotIn("string.lower(name)", rolls_sessions)

    def test_rolls_service_depends_on_dboptions_without_local_fallbacks(self):
        rolls_service = read(ROLLS_SERVICE)

        self.assertIn('"Database/DBOptions"', rolls_service)
        self.assertIn("local GetOption = Options.GetValue", rolls_service)
        self.assertIn("local IsDebugEnabled = Options.IsDebugEnabled", rolls_service)
        self.assertNotRegex(rolls_service, r"local\s+GetOption\s*=\s*Options\.GetValue\s+or\s+function")
        self.assertNotRegex(rolls_service, r"local\s+IsDebugEnabled\s*=\s*Options\.IsDebugEnabled\s+or\s+function")

    def test_rolls_service_uses_raid_owner_without_private_pass_through(self):
        rolls_service = read(ROLLS_SERVICE)

        self.assertNotIn("local function getRaidService()", rolls_service)
        self.assertNotIn("getRaidService()", rolls_service)
        self.assertIn("local raid = Services.Raid", rolls_service)

    def test_rolls_service_uses_database_roll_context_without_optional_database_guards(self):
        rolls_service = read(ROLLS_SERVICE)

        self.assertIn('"Database/DB"', rolls_service)
        self.assertIn("local raidNum = opts.raidNum or Database.GetCurrentRaid()", rolls_service)
        self.assertIn("local holderName = opts.holderName or Database.GetPlayerName()", rolls_service)
        self.assertIn("return Database.GetCurrentRaid()", rolls_service)
        self.assertNotIn("Database.GetCurrentRaid and Database.GetCurrentRaid()", rolls_service)
        self.assertNotIn("Database.GetPlayerName and Database.GetPlayerName()", rolls_service)

    def test_rolls_history_depends_on_dboptions_without_local_fallback(self):
        rolls_history = read(ROLLS_HISTORY)

        self.assertIn('"Database/DBOptions"', rolls_history)
        self.assertIn("local isDebugEnabled = Options.IsDebugEnabled", rolls_history)
        self.assertNotRegex(rolls_history, r"local\s+isDebugEnabled\s*=\s*Options\.IsDebugEnabled\s+or\s+function")

    def test_rolls_history_emits_add_roll_without_optional_event_guard(self):
        rolls_history = read(ROLLS_HISTORY)

        self.assertIn('"Modules/Events"', rolls_history)
        self.assertIn('"Modules/Bus"', rolls_history)
        self.assertIn("local InternalEvents = assert(Events.Internal", rolls_history)
        self.assertIn('"Roll history internal events are not initialized"', rolls_history)
        self.assertIn("local TriggerEvent = assert(", rolls_history)
        self.assertIn("Bus.TriggerEvent", rolls_history)
        self.assertIn('"Roll history event publisher is not initialized"', rolls_history)
        self.assertIn("local AddRollEvent = assert(", rolls_history)
        self.assertIn("InternalEvents.AddRoll", rolls_history)
        self.assertIn('"Roll history add-roll event is not initialized"', rolls_history)
        self.assertIn("TriggerEvent(AddRollEvent, name, roll)", rolls_history)
        self.assertNotIn("Events and Events.Internal", rolls_history)
        self.assertNotIn("local InternalEvents = Events.Internal", rolls_history)
        self.assertNotIn("if InternalEvents and InternalEvents.AddRoll", rolls_history)
        self.assertNotIn("Bus.TriggerEvent(InternalEvents.AddRoll", rolls_history)

    def test_rolls_resolution_depends_on_dboptions_without_local_fallback(self):
        rolls_resolution = read(ROLLS_RESOLUTION)

        self.assertIn('"Database/DBOptions"', rolls_resolution)
        self.assertIn("local isDebugEnabled = Options.IsDebugEnabled", rolls_resolution)
        self.assertNotRegex(rolls_resolution, r"local\s+isDebugEnabled\s*=\s*Options\.IsDebugEnabled\s+or\s+function")


if __name__ == "__main__":
    unittest.main()
