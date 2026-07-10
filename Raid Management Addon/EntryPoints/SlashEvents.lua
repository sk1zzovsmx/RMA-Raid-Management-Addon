-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: local feature = addon.Database.GetFeatureShared()
-- exports: publish module APIs on addon.*
-- events: owns /rma slash command routing; dispatches Controller, Widget, and sync commands
local addon = select(2, ...)
local feature = addon.Database.GetFeatureShared()

local L = feature.L

local Features = feature.Features
local coreState = feature.coreState
local Options = feature.Options
local UI = feature.UI
local UIWidgets = assert(UI.Widgets, "Slash widget facade is not initialized")
local IsWidgetEnabled = assert(UIWidgets.IsEnabled, "Slash widget enabled resolver is not initialized")
local IsWidgetRegistered = assert(UIWidgets.IsRegistered, "Slash widget registration resolver is not initialized")
local CallWidgetMethod = assert(UIWidgets.CallMethod, "Slash widget method dispatcher is not initialized")
local Colors = feature.Colors
local Strings = feature.Strings
local Database = feature.Database
local Services = feature.Services
local Controllers = feature.Controllers
local MasterController = assert(Controllers.Master, "Slash master controller is not initialized")
local LoggerController = assert(Controllers.Logger, "Slash logger controller is not initialized")
local AttendanceController = assert(Controllers.Attendance, "Slash attendance controller is not initialized")
local WarningsController = assert(Controllers.Warnings, "Slash warnings controller is not initialized")
local SpammerController = assert(Controllers.Spammer, "Slash spammer controller is not initialized")
local ConfigController = assert(Controllers.Config, "Config controller is not initialized")
local Comms = feature.Comms
local Item = feature.Item
local Timer = feature.Timer

local RT_COLOR = feature.RT_COLOR

local pairs, ipairs = pairs, ipairs
local tconcat = table.concat
local sort = table.sort
local format = string.format
local upper = string.upper
local type = type
local tostring, tonumber = tostring, tonumber
local floor = math.floor

-- =========== Slash Commands  =========== --
local function formatValidateRaidDetail(entry)
	local data = entry and entry.data or {}
	local index = tonumber(entry and entry.index) or 0
	local raidNid = tostring((entry and entry.raidNid) or "?")
	local code = entry and entry.code

	if code == "RAID_NOT_TABLE" then
		return L.MsgValidateDetailRaidNotTable:format(index, raidNid)
	end
	if code == "NORMALIZE_FAILED" then
		return L.MsgValidateDetailNormalizeFailed:format(index, raidNid)
	end
	if code == "SCHEMA_MISSING" then
		return L.MsgValidateDetailSchemaMissing:format(index, raidNid)
	end
	if code == "SCHEMA_NEWER" then
		return L.MsgValidateDetailSchemaNewer:format(
			index,
			raidNid,
			tonumber(data.schemaVersion) or 0,
			tonumber(data.currentVersion) or 0
		)
	end
	if code == "COUNTER_TOO_LOW" then
		return L.MsgValidateDetailCounterTooLow:format(
			index,
			raidNid,
			tostring(data.field or "?"),
			tonumber(data.actual) or 0,
			tonumber(data.required) or 0
		)
	end
	if code == "PLAYER_COUNT_TYPE" then
		return L.MsgValidateDetailPlayerCountType:format(index, raidNid, tonumber(data.playerIndex) or 0)
	end
	if code == "PLAYER_COUNT_NEGATIVE" then
		return L.MsgValidateDetailPlayerCountNegative:format(
			index,
			raidNid,
			tonumber(data.playerIndex) or 0,
			tonumber(data.value) or 0
		)
	end
	if code == "LOOT_MISSING_BOSS" then
		return L.MsgValidateDetailLootMissingBoss:format(
			index,
			raidNid,
			tonumber(data.lootIndex) or 0,
			tonumber(data.bossNid) or 0
		)
	end
	if code == "LOOT_UNKNOWN_BOSS_WITHOUT_TRASH" then
		return L.MsgValidateDetailLootNoBossTrash:format(index, raidNid, tonumber(data.lootIndex) or 0)
	end
	if code == "BOSS_ATTENDEE_INVALID" then
		return L.MsgValidateDetailBossAttendeeInvalid:format(
			index,
			raidNid,
			tonumber(data.bossIndex) or 0,
			tonumber(data.attendeeIndex) or 0
		)
	end
	if code == "BOSS_ATTENDEE_MISSING_PLAYER" then
		return L.MsgValidateDetailBossAttendeeMissingPlayer:format(
			index,
			raidNid,
			tonumber(data.bossIndex) or 0,
			tonumber(data.attendeeIndex) or 0,
			tonumber(data.playerNid) or 0
		)
	end
	if code == "LOOT_MISSING_LOOTER" then
		local looterNid = tonumber(data.looterNid)
		if looterNid and looterNid > 0 then
			return L.MsgValidateDetailLootMissingLooterNid:format(
				index,
				raidNid,
				tonumber(data.lootIndex) or 0,
				looterNid
			)
		end
		return L.MsgValidateDetailLootMissingLooter:format(index, raidNid, tonumber(data.lootIndex) or 0)
	end
	if code == "RUNTIME_OUTSIDE" then
		return L.MsgValidateDetailRuntimeOutside:format(index, raidNid, tostring(data.key or "?"))
	end

	return L.MsgValidateDetailUnknown:format(index, raidNid, tostring(code or "UNKNOWN"))
end

-- ----- Internal state ----- --
local slashHandlers = {}

local cmdAchiev, cmdLFM, cmdConfig =
	{ "ach", "achi", "achiev", "achievement" },
	{ "pug", "lfm", "group", "grouper" },
	{ "config", "conf", "options", "opt" }
local cmdWarnings, cmdLogger = { "warning", "warnings", "warn", "rw" }, { "history" }
local cmdAttendance = { "attendance", "attendees", "att" }
local cmdDebug, cmdLoot, cmdCounter = { "debug", "dbg", "debugger" }, { "ml" }, { "counter", "counters", "counts" }
local cmdReserves, cmdMinimap, cmdValidate =
	{ "res", "reserves", "reserve", "sr", "softres" }, { "minimap", "mm" }, { "validate" }
local cmdHelp, cmdBug, cmdVersion = { "help" }, { "bug", "report" }, { "version", "ver", "about" }
local cmdSpecInspect = { "specinspect", "inspectspec" }
local cmdPerf = { "perf", "performance" }

-- ----- Private helpers ----- --
local helpString = "%s: %s"
local function printHelp(cmd, desc)
	addon:info("%s", helpString:format(addon.WrapTextInColorCode(cmd, Colors.NormalizeHexColor(RT_COLOR)), desc))
end

local GetOption = Options.GetValue

local function showHelp()
	addon:info(format(L.StrCmdCommands, "RMA"), "RMA")
	printHelp("help [command]", L.StrCmdHelp)
	printHelp("config", L.StrCmdConfig)
	printHelp("lfm", L.StrCmdGrouper)
	printHelp("ach", L.StrCmdAchiev)
	printHelp("warnings", L.StrCmdWarnings)
	printHelp("history", L.StrCmdLogger)
	printHelp("attendance", L.StrRaidAttendance)
	printHelp("debug", L.StrCmdDebug)
	printHelp("counter", L.StrCmdCounter)
	printHelp("reserves", L.StrCmdReserves)
	printHelp("specinspect [force]", L.StrCmdSpecInspect)
	printHelp("validate", L.StrCmdValidate)
	printHelp("perf", L.StrCmdPerf)
	printHelp("version", L.StrCmdVersion)
	printHelp("bug", L.StrCmdBug)
end

local function showToggleHelp(commandRoot)
	addon:info(format(L.StrCmdCommands, commandRoot), "RMA")
	printHelp("toggle", L.StrCmdToggle)
end

local function showDebugRaidHelp()
	addon:info(format(L.StrCmdCommands, "RMA debug raid"), "RMA")
	printHelp("seed", L.StrCmdDebugRaidSeed)
	printHelp("clear", L.StrCmdDebugRaidClear)
	printHelp("rolls [tie]", L.StrCmdDebugRaidRolls)
	printHelp("roll <1-4|name> [1-100]", L.StrCmdDebugRaidRoll)
end

local debugNoActiveRollReasons = {
	record_inactive = true,
	missing_item = true,
	session_inactive = true,
}

local function reportDebugRaidError(reason, playerRef)
	if reason == "no_current_raid" then
		addon:warn(L.MsgDebugRaidNoCurrent)
		return
	end
	if reason == "invalid_player" or reason == "unknown_player" then
		addon:warn(L.MsgDebugRaidUnknownPlayer, tostring(playerRef or "?"))
		return
	end
	if reason == "invalid_roll" then
		addon:warn(L.MsgDebugRaidInvalidRoll)
		return
	end
	if reason == "raid_service_unavailable" then
		addon:warn(L.MsgFeatureUnavailable, "Debug", "raid")
		return
	end
	if reason == "rolls_service_unavailable" then
		addon:warn(L.MsgFeatureUnavailable, "Debug", "rolls")
		return
	end
	if debugNoActiveRollReasons[reason] then
		addon:warn(L.MsgDebugRaidNoActiveRoll)
		return
	end
	addon:warn(L.MsgDebugRaidRollRejected, tostring(playerRef or "?"), tostring(reason or "unknown"))
end

local function handleDebugRaidCommand(arg)
	local raidCmd, raidArg = Strings.SplitArgs(arg)
	local result
	local err
	local playerRef
	local rollArg

	local debugService = Services.Debug
	if not debugService then
		addon:warn(L.MsgFeatureUnavailable, "Debug", "raid")
		return
	end

	if raidCmd == "" then
		raidCmd = nil
	end
	if not raidCmd or raidCmd == "help" then
		showDebugRaidHelp()
		return
	end

	if raidCmd == "seed" or raidCmd == "add" then
		result, err = debugService:SeedRaidPlayers()
		if not result then
			reportDebugRaidError(err)
			return
		end
		addon:info(L.MsgDebugRaidSeeded, result.total, result.added, result.refreshed)
		return
	end

	if raidCmd == "clear" or raidCmd == "reset" then
		result, err = debugService:ClearRaidPlayers()
		if not result then
			reportDebugRaidError(err)
			return
		end
		addon:info(L.MsgDebugRaidCleared, result.removed, result.blocked)
		if result.clearedRolls then
			addon:info(L.MsgDebugRaidClearResetRolls)
		end
		return
	end

	if raidCmd == "rolls" or raidCmd == "all" then
		local rollsMode, rollsModeExtra = Strings.SplitArgs(raidArg)
		if rollsMode == "" then
			rollsMode = nil
		end
		if (rollsMode and rollsMode ~= "tie") or (rollsModeExtra and rollsModeExtra ~= "") then
			showDebugRaidHelp()
			return
		end

		result, err = debugService:RequestRaidRolls(rollsMode)
		if not result then
			reportDebugRaidError(err)
			return
		end
		if result.submitted <= 0 and result.firstFailure then
			if debugNoActiveRollReasons[result.firstFailure] then
				reportDebugRaidError(result.firstFailure)
			else
				addon:warn(L.MsgDebugRaidRollsPartial, result.submitted, result.total, tostring(result.firstFailure))
			end
			return
		end
		if result.failed > 0 and result.firstFailure then
			addon:warn(L.MsgDebugRaidRollsPartial, result.submitted, result.total, tostring(result.firstFailure))
			return
		end
		if result.tieMode then
			addon:info(
				L.MsgDebugRaidRollsTie,
				result.submitted,
				result.total,
				tonumber(result.tieCount) or 0,
				tonumber(result.tieRoll) or 0
			)
		else
			addon:info(L.MsgDebugRaidRolls, result.submitted, result.total)
		end
		return
	end

	if raidCmd == "roll" then
		playerRef, rollArg = Strings.SplitArgs(raidArg)
		if not playerRef or playerRef == "" then
			showDebugRaidHelp()
			return
		end

		result, err = debugService:RollRaidPlayer(playerRef, rollArg)
		if not result then
			reportDebugRaidError(err, playerRef)
			return
		end
		if not result.ok then
			reportDebugRaidError(result.reason, result.name)
			return
		end

		addon:info(L.MsgDebugRaidRollSingle, result.name, result.roll)
		return
	end

	showDebugRaidHelp()
end

local function getFeatureProfile()
	if type(Features) == "table" then
		return Features.Profile or "full"
	end
	return "full"
end

local function notifyWidgetCallUnavailable(widgetId, methodName)
	if not IsWidgetEnabled(widgetId) then
		addon:warn(L.MsgFeatureDisabledByProfile, widgetId, getFeatureProfile())
		return
	end
	addon:warn(L.MsgFeatureUnavailable, widgetId, methodName)
end

local function callWidgetMethod(widgetId, methodName, ...)
	if not IsWidgetEnabled(widgetId) then
		notifyWidgetCallUnavailable(widgetId, methodName)
		return nil
	end

	if not IsWidgetRegistered(widgetId) then
		notifyWidgetCallUnavailable(widgetId, methodName)
		return nil
	end

	return CallWidgetMethod(widgetId, methodName, ...)
end

local function registerAliases(list, fn)
	for _, cmd in ipairs(list) do
		slashHandlers[cmd] = fn
	end
end

local function isBlank(value)
	return not value or value == ""
end

local function isToggleCommand(sub)
	return isBlank(sub) or sub == "toggle"
end

local function callSyncerMethod(methodName, ...)
	local syncer = Database.GetSyncer()
	local method = syncer and syncer[methodName]
	if type(method) == "function" then
		return method(syncer, ...)
	end
	return nil
end

local function callSyncerMethodWithTarget(methodName, args)
	local raidRefArg, targetArg = Strings.SplitArgs(args)
	callSyncerMethod(methodName, tonumber(raidRefArg), targetArg)
end

local function getVersionInfo()
	local getter = Comms.GetVersionInfo
	if type(getter) == "function" then
		return getter()
	end

	local unknown = tostring(L.StrUnknown)
	local schemaGetter = Database.GetRaidSchemaVersion
	local syncer = Database.GetSyncer()
	local syncGetter = syncer and syncer.GetProtocolVersion

	return {
		addonVersion = unknown,
		interfaceVersion = unknown,
		raidSchemaVersion = type(schemaGetter) == "function" and tostring(schemaGetter() or unknown) or unknown,
		syncProtocolVersion = type(syncGetter) == "function" and tostring(syncGetter(syncer) or unknown) or unknown,
	}
end

local function getLogLevelName(level)
	level = level or (addon.GetLogLevel and addon:GetLogLevel() or nil)
	for name, value in pairs(addon.logLevels or {}) do
		if value == level then
			return tostring(name)
		end
	end
	return tostring(level or L.StrUnknown)
end

local function yesNo(value)
	if value then
		return L.StrYes
	end
	return L.StrNo
end

local function countRaidHistory()
	local raidStore = Database.GetRaidStoreOrNil("SlashEvents.BugReport", { "GetAllRaids" })
	local raids = raidStore and raidStore:GetAllRaids() or nil
	if type(raids) ~= "table" then
		return 0
	end
	return #raids
end

local function countReserves()
	local reserves = assert(Services.Reserves, "Slash reserves service is not initialized")
	local getCounts = assert(reserves.GetCounts, "Slash reserves count resolver is not initialized")
	return getCounts(reserves)
end

local function getCurrentRaidSummary()
	local currentRaid = Database.GetCurrentRaid()
	local raidNid
	local raidStore = Database.GetRaidStoreOrNil("SlashEvents.CurrentRaid", { "GetRaidNidByIndex" })
	if raidStore and currentRaid then
		raidNid = raidStore:GetRaidNidByIndex(currentRaid)
	end
	return tostring(currentRaid or L.StrNone), tostring(raidNid or L.StrNone)
end

local function getRoleState()
	local raid = Services.Raid
	if raid and type(raid.GetPlayerRoleState) == "function" then
		return raid:GetPlayerRoleState() or {}
	end
	return {}
end

local function showVersion()
	local info = getVersionInfo()
	addon:info(L.MsgVersionTitle)
	addon:info(L.MsgVersionAddon:format(info.addonVersion))
	addon:info(L.MsgVersionInterface:format(info.interfaceVersion))
	addon:info(L.MsgVersionRaidSchema:format(info.raidSchemaVersion))
	addon:info(L.MsgVersionSyncProtocol:format(info.syncProtocolVersion))
end

local function showBugReport()
	local reservePlayers, reserveEntries = countReserves()
	local currentRaid, raidNid = getCurrentRaidSummary()
	local role = getRoleState()
	local info = getVersionInfo()

	addon:info(L.MsgBugReportTitle)
	addon:info(L.MsgVersionAddon:format(info.addonVersion))
	addon:info(L.MsgVersionInterface:format(info.interfaceVersion))
	addon:info(L.MsgVersionRaidSchema:format(info.raidSchemaVersion))
	addon:info(L.MsgVersionSyncProtocol:format(info.syncProtocolVersion))
	addon:info(L.MsgBugReportLog:format(getLogLevelName(), yesNo(Options.IsDebugEnabled and Options.IsDebugEnabled())))
	addon:info(L.MsgBugReportCurrentRaid:format(currentRaid, raidNid))
	addon:info(L.MsgBugReportRaidHistory:format(countRaidHistory()))
	addon:info(L.MsgBugReportReserves:format(reservePlayers, reserveEntries))
	addon:info(
		L.MsgBugReportRole:format(
			yesNo(role.inRaid),
			yesNo(role.isLeader),
			yesNo(role.isAssistant),
			yesNo(role.isMasterLooter)
		)
	)
end

local function handleDebugRaidGridCommand(arg)
	local countArg, extra = Strings.SplitArgs(arg)
	local count

	if countArg == "" then
		countArg = nil
	end
	if extra and extra ~= "" then
		addon:warn(L.MsgDebugRaidGridInvalidCount)
		return
	end

	if countArg then
		count = tonumber(countArg)
		if not count or count < 1 or count > 40 or count ~= floor(count) then
			addon:warn(L.MsgDebugRaidGridInvalidCount)
			return
		end
	end

	local shown = MasterController:ShowDebugRaidGrid(count or 25)
	if not shown then
		addon:warn(L.MsgFeatureUnavailable, "Master", "debug raidgrid")
		return
	end
	addon:info(L.MsgDebugRaidGridShown, shown)
end

local function handleDebugCommand(rest)
	local subCmd, arg = Strings.SplitArgs(rest)
	if isBlank(subCmd) then
		subCmd = nil
	end

	if subCmd == "levels" then
		addon:info(L.MsgLogLevelList)
		return
	end

	if subCmd == "level" or subCmd == "lvl" then
		if not arg or arg == "" then
			local lvl = addon.GetLogLevel and addon:GetLogLevel()
			addon:info(L.MsgLogLevelCurrent, getLogLevelName(lvl))
			addon:info(L.MsgLogLevelList)
			return
		end

		local lv = tonumber(arg)
		if not lv and addon.logLevels then
			lv = addon.logLevels[upper(arg)]
		end
		if lv then
			addon:SetLogLevel(lv)
			addon:info(L.MsgLogLevelSet, arg)
		else
			addon:warn(L.MsgLogLevelUnknown, arg)
		end
		return
	end

	if subCmd == "timers" or subCmd == "timer" then
		if arg == "reset" then
			if Timer and Timer.RefreshStats then
				Timer.RefreshStats()
				addon:info(L.MsgTimerStatsReset)
			end
		else
			if Timer and Timer.ShowStats then
				Timer.ShowStats(arg)
			else
				addon:warn(L.MsgTimerModuleUnavailable)
			end
		end
		return
	end

	if subCmd == "raid" or subCmd == "players" then
		handleDebugRaidCommand(arg)
		return
	end

	if subCmd == "raidgrid" or subCmd == "mlgrid" or subCmd == "lootgrid" then
		handleDebugRaidGridCommand(arg)
		return
	end

	if subCmd == "on" then
		Options.SetDebugEnabled(true)
	elseif subCmd == "off" then
		Options.SetDebugEnabled(false)
	else
		Options.SetDebugEnabled(not Options.IsDebugEnabled())
	end

	if Options.IsDebugEnabled() then
		addon:info(L.MsgDebugOn)
	else
		addon:info(L.MsgDebugOff)
	end
end

local function formatPerfThreshold(value)
	local n = tonumber(value) or 0
	if n == floor(n) then
		return tostring(n)
	end
	return format("%.1f", n)
end

local function printPerfReport()
	local getter = addon._PerfGetStats
	local rows = type(getter) == "function" and getter(addon) or nil
	local count = rows and #rows or 0
	if count <= 0 then
		addon:info(L.MsgPerfReportEmpty)
		return
	end

	addon:info(L.MsgPerfReportTitle:format(count))
	for i = 1, count do
		local row = rows[i] or {}
		addon:info(
			L.MsgPerfReportRow:format(
				i,
				tostring(row.label or L.StrUnknown),
				tonumber(row.count) or 0,
				formatPerfThreshold(row.totalMs),
				formatPerfThreshold(row.avgMs),
				formatPerfThreshold(row.maxMs)
			)
		)
	end
end

local function formatPerfAverageBytes(bytes, chunks)
	bytes = tonumber(bytes) or 0
	chunks = tonumber(chunks) or 0
	if chunks <= 0 then
		return "0"
	end
	return tostring(floor((bytes / chunks) + 0.5))
end

local function getPerfSyncMetrics()
	local syncer = Database.GetSyncer()
	local getter = syncer and syncer.GetSyncMetrics
	return type(getter) == "function" and getter(syncer) or {}
end

local function printPerfAudit()
	local getter = addon._PerfGetStats
	local rows = type(getter) == "function" and getter(addon) or nil
	local rowCount = rows and #rows or 0
	local runtimeTotal = 0
	local topRow = rows and rows[1] or nil

	for i = 1, rowCount do
		runtimeTotal = runtimeTotal + (tonumber(rows[i] and rows[i].totalMs) or 0)
	end

	addon:info(
		L.MsgPerfAuditRuntime:format(
			rowCount,
			formatPerfThreshold(runtimeTotal),
			tostring((topRow and topRow.label) or L.StrUnknown),
			formatPerfThreshold(topRow and topRow.totalMs),
			formatPerfThreshold(topRow and topRow.maxMs)
		)
	)

	local syncMetrics = getPerfSyncMetrics()
	addon:info(
		L.MsgPerfAuditSync:format(
			tonumber(syncMetrics.outgoingBytes) or 0,
			tonumber(syncMetrics.outgoingChunks) or 0,
			formatPerfAverageBytes(syncMetrics.outgoingBytes, syncMetrics.outgoingChunks),
			tonumber(syncMetrics.incomingBytes) or 0,
			tonumber(syncMetrics.incomingChunks) or 0,
			formatPerfAverageBytes(syncMetrics.incomingBytes, syncMetrics.incomingChunks)
		)
	)

	local itemModule = Item
	local itemGetter = itemModule and itemModule.GetInfoMetrics
	local itemMetrics = type(itemGetter) == "function" and itemGetter() or {}
	addon:info(
		L.MsgPerfAuditItems:format(
			tonumber(itemMetrics.totalRequests) or 0,
			tonumber(itemMetrics.requestsJoined) or 0,
			tonumber(itemMetrics.pendingRequests) or 0,
			tonumber(itemMetrics.getItemInfoCalls) or 0,
			tonumber(itemMetrics.tooltipProbes) or 0
		)
	)
end

local function printPerfSyncReport()
	local metrics = getPerfSyncMetrics()
	local totalMessages = (tonumber(metrics and metrics.outgoingMessages) or 0)
		+ (tonumber(metrics and metrics.incomingMessages) or 0)
	if totalMessages <= 0 then
		addon:info(L.MsgPerfSyncReportEmpty)
		return
	end

	addon:info(
		L.MsgPerfSyncReportTitle:format(
			tonumber(metrics.outgoingMessages) or 0,
			tonumber(metrics.outgoingChunks) or 0,
			tonumber(metrics.outgoingBytes) or 0,
			tonumber(metrics.outgoingRequests) or 0,
			tonumber(metrics.outgoingSnapshots) or 0,
			tonumber(metrics.incomingMessages) or 0,
			tonumber(metrics.incomingChunks) or 0,
			tonumber(metrics.incomingBytes) or 0,
			tonumber(metrics.incomingRequests) or 0,
			tonumber(metrics.incomingSnapshots) or 0
		)
	)

	local modes = metrics.modes or {}
	for i = 1, #modes do
		local row = modes[i] or {}
		addon:info(
			L.MsgPerfSyncReportRow:format(
				tostring(row.mode or L.StrUnknown),
				tonumber(row.outgoingMessages) or 0,
				tonumber(row.outgoingChunks) or 0,
				tonumber(row.outgoingBytes) or 0,
				tonumber(row.outgoingRequests) or 0,
				tonumber(row.outgoingSnapshots) or 0,
				tonumber(row.incomingMessages) or 0,
				tonumber(row.incomingChunks) or 0,
				tonumber(row.incomingBytes) or 0,
				tonumber(row.incomingRequests) or 0,
				tonumber(row.incomingSnapshots) or 0
			)
		)
	end
end

local function printPerfItemReport()
	local itemModule = Item
	local getter = itemModule and itemModule.GetInfoMetrics
	local metrics = type(getter) == "function" and getter() or {}
	addon:info(
		L.MsgPerfItemReport:format(
			tonumber(metrics.totalRequests) or 0,
			tonumber(metrics.requestsStarted) or 0,
			tonumber(metrics.requestsJoined) or 0,
			tonumber(metrics.requestsImmediate) or 0,
			tonumber(metrics.pendingRequests) or 0,
			tonumber(metrics.callbacks) or 0,
			tonumber(metrics.requestsCompleted) or 0,
			tonumber(metrics.requestTimeouts) or 0,
			tonumber(metrics.requestCancels) or 0,
			tonumber(metrics.getItemInfoCalls) or 0,
			tonumber(metrics.tooltipProbes) or 0
		)
	)
end

local function resetPerfReport()
	local resetter = addon._PerfResetStats
	if type(resetter) == "function" then
		resetter(addon)
	end
	local syncer = Database.GetSyncer()
	local resetSyncMetrics = syncer and syncer.ResetSyncMetrics
	if type(resetSyncMetrics) == "function" then
		resetSyncMetrics(syncer)
	end
	local itemModule = Item
	local resetItemMetrics = itemModule and itemModule.ResetInfoMetrics
	if type(resetItemMetrics) == "function" then
		resetItemMetrics()
	end
	addon:info(L.MsgPerfReportReset)
end

local function getPerfThreshold()
	local threshold = tonumber(coreState and coreState.perfThresholdMs) or 5
	if threshold < 0 then
		return 5
	end
	return threshold
end

local function isPerfEnabled()
	return coreState and coreState.perfEnabled == true
end

local function setPerfEnabled(enabled)
	coreState.perfEnabled = enabled and true or false
	addon.hasPerf = coreState.perfEnabled and true or nil
	return coreState.perfEnabled
end

local function setPerfThreshold(value)
	local threshold = tonumber(value)
	if not threshold or threshold < 0 then
		return nil
	end
	coreState.perfThresholdMs = threshold
	return threshold
end

local function handlePerfCommand(rest)
	local subCmd, arg = Strings.SplitArgs(rest)
	if isBlank(subCmd) then
		subCmd = "status"
	end

	if subCmd == "on" then
		setPerfEnabled(true)
		addon:info(L.MsgPerfOn:format(formatPerfThreshold(getPerfThreshold())))
		return
	end

	if subCmd == "off" then
		setPerfEnabled(false)
		addon:info(L.MsgPerfOff)
		return
	end

	if subCmd == "threshold" or subCmd == "th" or subCmd == "ms" then
		local threshold = setPerfThreshold(arg)
		if not threshold then
			addon:warn(L.MsgPerfThresholdInvalid)
			return
		end
		addon:info(L.MsgPerfThreshold:format(formatPerfThreshold(threshold)))
		return
	end

	if subCmd == "report" or subCmd == "stats" or subCmd == "top" then
		printPerfReport()
		return
	end

	if subCmd == "audit" or subCmd == "summary" then
		printPerfAudit()
		return
	end

	if subCmd == "sync" or subCmd == "payload" or subCmd == "payloads" then
		printPerfSyncReport()
		return
	end

	if subCmd == "items" or subCmd == "item" or subCmd == "tooltip" then
		printPerfItemReport()
		return
	end

	if subCmd == "reset" or subCmd == "clear" then
		resetPerfReport()
		return
	end

	if subCmd == "status" then
		local status = isPerfEnabled() and L.StrEnabled or L.StrDisabled
		addon:info(L.MsgPerfStatus:format(status, formatPerfThreshold(getPerfThreshold())))
		return
	end

	addon:info(format(L.StrCmdCommands, "RMA perf"), "RMA")
	printHelp("on", L.StrCmdPerfOn)
	printHelp("off", L.StrCmdPerfOff)
	printHelp("threshold <ms>", L.StrCmdPerfThreshold)
	printHelp("report", L.StrCmdPerfReport)
	printHelp("audit", L.StrCmdPerfAudit)
	printHelp("sync", L.StrCmdPerfSync)
	printHelp("items", L.StrCmdPerfItems)
	printHelp("reset", L.StrCmdPerfReset)
end

local function handleMinimapCommand(rest)
	local sub, arg = Strings.SplitArgs(rest)
	if sub == "on" then
		addon.Minimap:SetMinimapButtonShown(true)
	elseif sub == "off" then
		addon.Minimap:SetMinimapButtonShown(false)
	elseif sub == "pos" and arg ~= "" then
		local angle = tonumber(arg)
		if angle then
			addon.Minimap:SetPos(angle)
			addon:info(L.MsgMinimapPosSet, angle)
		end
	elseif sub == "pos" then
		addon:info(L.MsgMinimapPosSet, addon.Minimap:GetPos())
	else
		addon:info(format(L.StrCmdCommands, "RMA minimap"), "RMA")
		printHelp("on", L.StrCmdToggle)
		printHelp("off", L.StrCmdToggle)
		printHelp("pos <deg>", L.StrCmdMinimapPos)
	end
end

local function handleAchievementCommand(_, _, raw)
	if not raw or not raw:find("achievement:%d*:") then
		addon:info(format(L.StrCmdCommands, "RMA ach"), "RMA")
		return
	end

	local from, to = raw:find("achievement%:%d*%:")
	if not (from and to) then
		return
	end
	local id = raw:sub(from + 12, to - 1)
	from, to = raw:find("%|cffffff00%|Hachievement%:.*%]%|h%|r")
	local name = (from and to) and raw:sub(from, to) or ""
	printHelp("RMA", name .. " - ID#" .. id)
end

local function handleConfigCommand(rest)
	local sub = Strings.SplitArgs(rest)
	if sub == "reset" then
		if ConfigController:IsAvailable() then
			ConfigController:Default()
		end
	elseif ConfigController:IsAvailable() then
		ConfigController:Toggle()
	end
end

local function handleWarningsCommand(rest)
	local sub = Strings.SplitArgs(rest)
	if isToggleCommand(sub) then
		WarningsController:Toggle()
	elseif sub == "help" then
		addon:info(format(L.StrCmdCommands, "RMA rw"), "RMA")
		printHelp("toggle", L.StrCmdToggle)
		printHelp("[ID]", L.StrCmdWarningAnnounce)
	else
		WarningsController:RequestAnnounce(sub)
	end
end

local function handleLoggerCommand(rest)
	local sub, arg = Strings.SplitArgs(rest)
	if isToggleCommand(sub) then
		LoggerController:ToggleLootHistory()
	elseif sub == "req" then
		callSyncerMethodWithTarget("RequestLoggerReq", arg)
	elseif sub == "push" then
		callSyncerMethodWithTarget("BroadcastLoggerPush", arg)
	elseif sub == "sync" then
		callSyncerMethod("RequestLoggerSync")
	else
		addon:info(format(L.StrCmdCommands, "RMA history"), "RMA")
		printHelp("toggle", L.StrCmdToggle)
		printHelp("req <raidId|raidNid> <player>", L.StrCmdLoggerReq)
		printHelp("push <raidId|raidNid> <player>", L.StrCmdLoggerPush)
		printHelp("sync", L.StrCmdLoggerSync)
	end
end

local function handleAttendanceCommand()
	AttendanceController:Toggle()
end

local function handleLootCommand(rest)
	local sub = Strings.SplitArgs(rest)
	if isToggleCommand(sub) then
		MasterController:Toggle()
	end
end

local function handleCounterCommand(rest)
	local sub = Strings.SplitArgs(rest)
	if isToggleCommand(sub) then
		callWidgetMethod("LootCounter", "Toggle")
	end
end

local function handleSpecInspectCommand(rest)
	local sub = Strings.SplitArgs(rest)
	local service = Services.SpecInspect
	local result
	if not service then
		addon:warn(L.MsgSpecInspectNoService)
		return
	end

	if sub == "force" then
		result = service:ForceRefreshRaidSpecs("slash_force")
	else
		result = service:RefreshRaidSpecs({ reason = "slash" })
	end

	result = result or {}
	addon:info(
		L.MsgSpecInspectRefresh,
		tonumber(result.refreshed) or 0,
		tonumber(result.cached) or 0,
		tonumber(result.skipped) or 0
	)
end

local function formatReserveNameMatches(matches)
	local out = {}
	for i = 1, #(matches or {}) do
		local match = matches[i]
		if match and match.reserveName and match.raidName then
			out[#out + 1] = L.StrSoftResReadinessNameMatch:format(tostring(match.reserveName), tostring(match.raidName))
		end
	end
	return tconcat(out, ", ")
end

local function printReadinessLine(template, ...)
	addon:info(template:format(...))
end

local function formatSoftResHealthSeverity(severity)
	if severity == "error" then
		return L.StrSoftResReadinessHealthError
	end
	if severity == "warning" then
		return L.StrSoftResReadinessHealthWarning
	end
	return L.StrSoftResReadinessHealthOk
end

local function getCurrentSoftResItem()
	local loot = assert(Services.Loot, "Slash softres loot service is not initialized")
	local getItemLink = assert(loot.GetItemLink, "Slash softres loot item resolver is not initialized")
	local getItemIdFromLink = assert(Item.GetItemIdFromLink, "Slash softres item-id resolver is not initialized")
	local link
	local itemId

	link = getItemLink(loot)
	if link then
		itemId = getItemIdFromLink(link)
	end
	return itemId, link
end

local function printSoftResHealthReport(health)
	if type(health) ~= "table" then
		return
	end

	printReadinessLine(L.MsgSoftResReadinessHealth, formatSoftResHealthSeverity(health.severity))
	if (tonumber(health.issueCount) or 0) <= 0 then
		return
	end

	printReadinessLine(L.MsgSoftResReadinessIssues, tonumber(health.issueCount) or 0)
	if health.currentItemIssue == "no_reserves" then
		addon:info(L.MsgSoftResReadinessHealthItemNoReserves)
	elseif health.currentItemIssue == "no_eligible_reservers" then
		addon:info(L.MsgSoftResReadinessHealthItemNoEligible)
	end
	if (tonumber(health.importedPlayersOutsideRaidCount) or 0) > 0 then
		printReadinessLine(
			L.MsgSoftResReadinessHealthImportedOutside,
			tonumber(health.importedPlayersOutsideRaidCount) or 0
		)
	end
	if (tonumber(health.raidPlayersWithoutReserveCount) or 0) > 0 then
		printReadinessLine(L.MsgSoftResReadinessHealthRaidWithout, tonumber(health.raidPlayersWithoutReserveCount) or 0)
	end
	if (tonumber(health.suggestedNameMatchCount) or 0) > 0 then
		printReadinessLine(L.MsgSoftResReadinessHealthNameMatches, tonumber(health.suggestedNameMatchCount) or 0)
	end
end

local function printSoftResReadinessReport()
	local reserves = assert(Services.Reserves, "Slash reserves service is not initialized")
	local getReadinessReport =
		assert(reserves.GetReadinessReport, "Slash reserves readiness reporter is not initialized")
	local itemId
	local itemLink
	local report
	local itemContext
	local rosterReport
	local nameMatchReport

	itemId, itemLink = getCurrentSoftResItem()
	report = getReadinessReport(reserves, itemId)
	if type(report) ~= "table" then
		addon:warn(L.MsgFeatureUnavailable, "Reserves", "check")
		return
	end

	itemContext = report.itemContext or {}
	rosterReport = report.rosterReport or {}
	nameMatchReport = report.nameMatchReport or {}

	addon:info(L.MsgSoftResReadinessTitle)
	if itemLink and itemLink ~= "" then
		printReadinessLine(L.MsgSoftResReadinessCurrentItem, itemLink)
	else
		printReadinessLine(L.MsgSoftResReadinessCurrentItem, L.StrNone)
	end

	if itemId then
		if report.hasItemReserves == true then
			printReadinessLine(
				L.MsgSoftResReadinessItemSummary,
				tonumber(itemContext.presentReserveCount) or 0,
				tonumber(itemContext.totalReserveCount) or 0
			)
			if type(itemContext.presentPlayersText) == "string" and itemContext.presentPlayersText ~= "" then
				printReadinessLine(L.MsgSoftResReadinessItemPresent, itemContext.presentPlayersText)
			end
			if type(itemContext.missingPlayersText) == "string" and itemContext.missingPlayersText ~= "" then
				printReadinessLine(L.MsgSoftResReadinessItemMissing, itemContext.missingPlayersText)
			end
		else
			addon:info(L.MsgSoftResReadinessItemNone)
		end
	end

	if report.hasReserveData ~= true then
		addon:info(L.MsgSoftResReadinessNoData)
		printSoftResHealthReport(report.health)
		return
	end

	printReadinessLine(
		L.MsgSoftResReadinessRosterSummary,
		tonumber(rosterReport.totalReservePlayers) or 0,
		tonumber(rosterReport.presentReservePlayers) or 0,
		tonumber(rosterReport.missingReservePlayers) or 0
	)
	if type(rosterReport.presentPlayersText) == "string" and rosterReport.presentPlayersText ~= "" then
		printReadinessLine(L.MsgSoftResReadinessRosterPresent, rosterReport.presentPlayersText)
	end
	if type(rosterReport.missingPlayersText) == "string" and rosterReport.missingPlayersText ~= "" then
		printReadinessLine(L.MsgSoftResReadinessRosterMissing, rosterReport.missingPlayersText)
	end
	if type(nameMatchReport.aliasMatchesText) == "string" and nameMatchReport.aliasMatchesText ~= "" then
		printReadinessLine(L.MsgSoftResReadinessAliases, nameMatchReport.aliasMatchesText)
	end

	printSoftResHealthReport(report.health)

	local strongText = formatReserveNameMatches(nameMatchReport.strongMatches)
	local weakText = formatReserveNameMatches(nameMatchReport.weakMatches)
	local matchText = strongText
	if weakText ~= "" then
		matchText = matchText ~= "" and (matchText .. ", " .. weakText) or weakText
	end
	if matchText ~= "" then
		printReadinessLine(L.MsgSoftResReadinessNameMatches, matchText)
	end
	if
		type(nameMatchReport.unmatchedReservePlayersText) == "string"
		and nameMatchReport.unmatchedReservePlayersText ~= ""
	then
		printReadinessLine(L.MsgSoftResReadinessUnmatchedReserve, nameMatchReport.unmatchedReservePlayersText)
	end
	if
		type(nameMatchReport.unmatchedRaidPlayersText) == "string"
		and nameMatchReport.unmatchedRaidPlayersText ~= ""
	then
		printReadinessLine(L.MsgSoftResReadinessUnmatchedRaid, nameMatchReport.unmatchedRaidPlayersText)
	end
end

local function handleReservesCommand(rest)
	local sub, arg = Strings.SplitArgs(rest)
	local reserves = assert(Services.Reserves, "Slash reserves service is not initialized")
	local setNameAlias = assert(reserves.SetNameAlias, "Slash reserves alias setter is not initialized")
	local removeNameAlias = assert(reserves.RemoveNameAlias, "Slash reserves alias remover is not initialized")
	local getNameAliases = assert(reserves.GetNameAliases, "Slash reserves alias lister is not initialized")
	local requestSyncMetadata = assert(reserves.RequestSyncMetadata, "Slash reserves sync requester is not initialized")
	local getSyncMetadata = assert(reserves.GetSyncMetadata, "Slash reserves sync metadata reader is not initialized")
	local deleteSyncedReservesCache =
		assert(reserves.DeleteSyncedReservesCache, "Slash reserves sync cache cleaner is not initialized")

	if isToggleCommand(sub) then
		callWidgetMethod("Reserves", "Toggle")
	elseif sub == "import" then
		callWidgetMethod("Reserves", "ToggleImport")
	elseif sub == "check" then
		printSoftResReadinessReport()
	elseif sub == "alias" then
		local reserveName, raidName = Strings.SplitArgs(arg)
		if setNameAlias(reserves, reserveName, raidName) then
			addon:info(L.MsgReservesAliasSet:format(tostring(reserveName), tostring(raidName)))
		else
			addon:warn(L.MsgReservesAliasInvalid)
		end
	elseif sub == "unalias" then
		local reserveName = Strings.SplitArgs(arg)
		if removeNameAlias(reserves, reserveName) then
			addon:info(L.MsgReservesAliasCleared:format(tostring(reserveName)))
		else
			addon:warn(L.MsgReservesAliasInvalid)
		end
	elseif sub == "aliases" then
		local aliases = getNameAliases(reserves)
		local lines = {}
		for reserveKey, raidName in pairs(aliases) do
			lines[#lines + 1] = tostring(reserveKey) .. " -> " .. tostring(raidName)
		end
		sort(lines)
		addon:info(L.MsgReservesAliasesTitle)
		for i = 1, #lines do
			addon:info(lines[i])
		end
		if #lines == 0 then
			addon:info(L.MsgReservesAliasesEmpty)
		end
	elseif sub == "sync" then
		if requestSyncMetadata(reserves) then
			return
		else
			addon:warn(L.MsgFeatureUnavailable, "Reserves", "sync")
		end
	elseif sub == "meta" then
		local meta = getSyncMetadata(reserves)
		addon:info(
			L.MsgReservesSyncMetaLocal:format(
				tostring(meta.source or L.StrUnknown),
				tostring(meta.checksum or L.StrUnknown),
				tostring(meta.mode or L.StrUnknown),
				tonumber(meta.players) or 0,
				tonumber(meta.entries) or 0,
				(meta.runtime and L.StrYes or L.StrNo)
			)
		)
	elseif sub == "clearcache" then
		if deleteSyncedReservesCache(reserves) then
			addon:info(L.MsgReservesSyncCacheCleared)
		else
			addon:warn(L.MsgReservesSyncNoRuntimeCache)
		end
	else
		addon:info(format(L.StrCmdCommands, "RMA res"), "RMA")
		printHelp("toggle", L.StrCmdToggle)
		printHelp("import", L.StrCmdReservesImport)
		printHelp("check", L.StrCmdReservesCheck)
		printHelp("alias <softres-name> <raid-name>", L.StrCmdReservesAlias)
		printHelp("unalias <softres-name>", L.StrCmdReservesUnalias)
		printHelp("aliases", L.StrCmdReservesAliases)
		printHelp("sync", L.StrCmdReservesSync)
		printHelp("meta", L.StrCmdReservesMeta)
		printHelp("clearcache", L.StrCmdReservesClearCache)
	end
end

local function handleValidateCommand(rest)
	local sub, arg = Strings.SplitArgs(rest)
	if sub == "raids" then
		local verboseArg = Strings.SplitArgs(arg)
		local validator = Database.GetRaidValidator()
		if not (validator and validator.ValidateAllRaids) then
			addon:warn(L.MsgValidateUnavailable)
			return
		end

		local report = validator:ValidateAllRaids({
			includeInfo = (verboseArg == "verbose" or verboseArg == "all"),
			maxDetails = 60,
		})
		if not report then
			addon:warn(L.MsgValidateUnavailable)
			return
		end

		local raidsCount = tonumber(report.raids) or 0
		if raidsCount <= 0 then
			addon:info(L.MsgValidateRaidsNoData)
			return
		end

		local summary = L.MsgValidateRaidsSummary:format(
			raidsCount,
			tonumber(report.ok) or 0,
			tonumber(report.warn) or 0,
			tonumber(report.err) or 0,
			tonumber(report.currentSchemaVersion) or 0
		)

		if tonumber(report.err) and report.err > 0 then
			addon:error(summary)
		elseif tonumber(report.warn) and report.warn > 0 then
			addon:warn(summary)
		else
			addon:info(summary)
		end

		local details = report.details or {}
		for i = 1, #details do
			local entry = details[i]
			local line = formatValidateRaidDetail(entry)
			if entry.level == "E" then
				addon:error(line)
			elseif entry.level == "W" then
				addon:warn(line)
			else
				addon:info(line)
			end
		end

		if tonumber(report.truncatedCount) and report.truncatedCount > 0 then
			addon:warn(L.MsgValidateRaidsDetailsTruncated:format(report.truncatedCount))
		end
	else
		addon:info(format(L.StrCmdCommands, "RMA validate"), "RMA")
		printHelp("raids [verbose]", L.StrCmdValidateRaids)
	end
end

local function handleLfmCommand(rest)
	local sub = Strings.SplitArgs(rest)
	if isToggleCommand(sub) or sub == "show" then
		SpammerController:Toggle()
	elseif sub == "start" then
		SpammerController:RequestStart()
	elseif sub == "stop" then
		SpammerController:RequestStop()
	else
		addon:info(format(L.StrCmdCommands, "RMA pug"), "RMA")
		printHelp("toggle", L.StrCmdToggle)
		printHelp("start", L.StrCmdLFMStart)
		printHelp("stop", L.StrCmdLFMStop)
	end
end

local function handleHelpCommand(rest)
	local topic = Strings.SplitArgs(rest)
	if isBlank(topic) then
		showHelp()
		return
	end

	if topic == "history" then
		handleLoggerCommand("help")
	elseif topic == "res" or topic == "reserve" or topic == "reserves" then
		handleReservesCommand("help")
	elseif topic == "ml" then
		showToggleHelp("RMA ml")
	elseif topic == "counter" or topic == "counters" or topic == "counts" then
		showToggleHelp("RMA counter")
	elseif topic == "debug" or topic == "dbg" or topic == "debugger" then
		addon:info(format(L.StrCmdCommands, "RMA debug"), "RMA")
		printHelp("on", L.StrCmdToggle)
		printHelp("off", L.StrCmdToggle)
		printHelp("level <name|num>", L.StrCmdDebugLevel)
		printHelp("raid", L.StrCmdDebugRaid)
		printHelp("raidgrid [1-40]", L.StrCmdDebugRaidGrid)
	elseif topic == "perf" or topic == "performance" then
		handlePerfCommand("help")
	elseif topic == "rw" or topic == "warn" or topic == "warning" or topic == "warnings" then
		handleWarningsCommand("help")
	elseif topic == "attendance" or topic == "attendees" or topic == "att" then
		addon:info(format(L.StrCmdCommands, "RMA attendance"), "RMA")
		printHelp("toggle", L.StrRaidAttendance)
	elseif topic == "lfm" or topic == "pug" or topic == "group" or topic == "grouper" then
		handleLfmCommand("help")
	elseif topic == "specinspect" or topic == "inspectspec" then
		addon:info(format(L.StrCmdCommands, "RMA specinspect"), "RMA")
		printHelp("force", L.StrCmdSpecInspect)
	elseif topic == "config" or topic == "conf" or topic == "options" or topic == "opt" then
		addon:info(format(L.StrCmdCommands, "RMA config"), "RMA")
		printHelp("toggle", L.StrCmdToggle)
		printHelp("reset", L.StrCmdConfigReset)
	elseif topic == "minimap" or topic == "mm" then
		handleMinimapCommand("help")
	elseif topic == "validate" then
		handleValidateCommand("help")
	elseif topic == "version" or topic == "ver" or topic == "about" then
		showVersion()
	elseif topic == "bug" or topic == "report" then
		showBugReport()
	else
		showHelp()
	end
end

local function handleBugCommand()
	showBugReport()
end

local function handleVersionCommand(rest)
	showVersion()
	local sub = Strings.SplitArgs(rest)
	local requester = Comms.RequestVersionCheck
	if sub ~= "local" and type(requester) == "function" then
		requester(Comms)
	end
end

local function handleSlashCommand(msg)
	if isBlank(msg) then
		showHelp()
		return
	end

	local cmd, rest = Strings.SplitArgs(msg)
	if isBlank(cmd) then
		showHelp()
		return
	end

	local fn = slashHandlers[cmd]
	if fn then
		return fn(rest, cmd, msg)
	end
	showHelp()
end

registerAliases(cmdHelp, handleHelpCommand)
registerAliases(cmdBug, handleBugCommand)
registerAliases(cmdVersion, handleVersionCommand)
registerAliases(cmdDebug, handleDebugCommand)
registerAliases(cmdPerf, handlePerfCommand)
registerAliases(cmdMinimap, handleMinimapCommand)
registerAliases(cmdAchiev, handleAchievementCommand)
registerAliases(cmdConfig, handleConfigCommand)
registerAliases(cmdWarnings, handleWarningsCommand)
registerAliases(cmdLogger, handleLoggerCommand)
registerAliases(cmdAttendance, handleAttendanceCommand)
registerAliases(cmdLoot, handleLootCommand)
registerAliases(cmdCounter, handleCounterCommand)
registerAliases(cmdSpecInspect, handleSpecInspectCommand)
registerAliases(cmdReserves, handleReservesCommand)
registerAliases(cmdValidate, handleValidateCommand)
registerAliases(cmdLFM, handleLfmCommand)

-- ----- Public methods ----- --

-- Register slash commands
SLASH_RMA1 = "/rma"
SlashCmdList["RMA"] = function(msg)
	handleSlashCommand(msg)
end

local registry = feature.ModuleRegistry
if type(registry) == "table" and type(registry.AddModule) == "function" and type(registry.SetLoaded) == "function" then
	registry.AddModule("EntryPoints/SlashEvents", {
		deps = {
			"Init",
			"Modules/ModuleRegistry",
			"Database/DB",
			"Database/DBOptions",
			"Database/DBRaidStore",
			"Database/DBRaidValidator",
			"Database/DBSyncer",
			"Modules/C",
			"Modules/Colors",
			"Modules/Strings",
			"Modules/Comms",
			"Modules/Item",
			"Modules/UI/Facade",
			"EntryPoints/Minimap",
			"Services/Debug",
			"Services/SpecInspect",
			"Services/Raid/State",
			"Controllers/Master",
			"Controllers/Logger",
			"Controllers/Attendance",
			"Controllers/Warnings",
			"Controllers/Spammer",
			"Controllers/Config",
		},
	})
	registry.SetLoaded("EntryPoints/SlashEvents")
end
