-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: direct addon namespace bindings
-- exports: publish module APIs on addon.*
-- events: owns /rma slash command routing; dispatches Controller, Widget, and sync commands
local addon = select(2, ...)
local Diag = addon.Diag
local L = addon.L

local coreState = addon.State
local Options = addon.Options
local UI = addon.UI
local Widgets = addon.Widgets
local LootCounterWidget = assert(Widgets.LootCounter, Diag.A.SlashLootCounterWidgetNotInitialized)
local ReservesWidget = assert(Widgets.ReservesUI, Diag.A.SlashReservesWidgetNotInitialized)
local Colors = addon.Colors
local Strings = addon.Strings
local Database = addon.Database
local Services = addon.Services
local DebugEntryPoint = assert(addon.EntryPoints.Debug, Diag.A.DebugEntrypointNotInitialized)
local Controllers = addon.Controllers
local MasterController = assert(Controllers.Master, Diag.A.SlashMasterControllerNotInitialized)
local LoggerController = assert(Controllers.Logger, Diag.A.SlashLoggerControllerNotInitialized)
local AttendanceController = assert(Controllers.Attendance, Diag.A.SlashAttendanceControllerNotInitialized)
local WarningsController = assert(Controllers.Warnings, Diag.A.SlashWarningsControllerNotInitialized)
local SpammerController = assert(Controllers.Spammer, Diag.A.SlashSpammerControllerNotInitialized)
local ConfigController = assert(Controllers.Config, Diag.A.ConfigControllerNotInitialized)
local Comms = addon.Comms
local Item = addon.Item

local MA_COLOR = addon.C.MA_COLOR

local pairs, ipairs = pairs, ipairs
local tconcat = table.concat
local sort = table.sort
local format = string.format
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
	if code == "SCHEMA_VERSION_FUTURE" or code == "SCHEMA_NEWER" then
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
local cmdWarnings, cmdLogger = { "warning", "warnings", "warn", "rw" }, { "logger" }
local cmdAttendance = { "attendance", "attendees", "att" }
local cmdDebug, cmdLoot, cmdCounter = { "debug", "dbg", "debugger" }, { "ml" }, { "counter", "counters", "counts" }
local cmdReserves, cmdMinimap, cmdValidate =
	{ "res", "reserves", "reserve", "sr", "softres" }, { "minimap", "mm" }, { "validate" }
local cmdHelp, cmdBug, cmdVersion = { "help" }, { "bug", "report" }, { "version", "ver", "about" }
local cmdSpecInspect = { "specinspect", "inspectspec" }
local cmdPerf = { "perf", "performance" }
local cmdQuickBar = { "quickbar" }

-- ----- Private helpers ----- --
local helpString = "%s: %s"
local function printHelp(cmd, desc)
	addon:info("%s", helpString:format(Colors.WrapText(cmd, Colors.NormalizeHexColor(MA_COLOR)), desc))
end

local GetOption = Options.GetValue

local function showHelp()
	addon:info(format(L.StrCmdCommands, "RMA"), "RMA")
	printHelp("help [command]", L.StrCmdHelp)
	printHelp("config", L.StrCmdConfig)
	printHelp("lfm", L.StrCmdGrouper)
	printHelp("ach", L.StrCmdAchiev)
	printHelp("warnings", L.StrCmdWarnings)
	printHelp("logger", L.StrCmdLogger)
	printHelp("attendance", L.StrRaidAttendance)
	printHelp("debug", L.StrCmdDebug)
	printHelp("counter", L.StrCmdCounter)
	printHelp("quickbar", L.StrCmdQuickBar)
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

local function showQuickBarHelp()
	addon:info(format(L.StrCmdCommands, "RMA quickbar"), "RMA")
	printHelp("show", L.StrCmdQuickBarShow)
	printHelp("hide", L.StrCmdQuickBarHide)
end

local function handleQuickBarCommand(rest)
	local sub = Strings.SplitArgs(rest)
	local widget = Widgets.QuickBar
	if not (widget and widget.SetShown) then
		addon:warn(L.MsgFeatureUnavailable, "QuickBar", sub or "")
		return
	end
	if sub == "show" then
		widget:SetShown(true)
	elseif sub == "hide" then
		widget:SetShown(false)
	else
		showQuickBarHelp()
	end
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
	local raids = Database.GetRaidStore():GetAllRaids()
	if type(raids) ~= "table" then
		return 0
	end
	return #raids
end

local function countReserves()
	local reserves = assert(Services.Reserves, Diag.A.SlashReservesServiceNotInitialized)
	local getCounts = assert(reserves.GetCounts, Diag.A.SlashReservesCountResolverNotInitialized)
	return getCounts(reserves)
end

local function getCurrentRaidSummary()
	local currentRaid = Database.GetCurrentRaid()
	local raidNid
	if currentRaid then
		raidNid = Database.GetRaidStore():GetRaidNidByIndex(currentRaid)
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
		ConfigController:Default()
	else
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
	local sub = Strings.SplitArgs(rest)
	if isToggleCommand(sub) then
		LoggerController:ToggleLootHistory()
	elseif sub == "share" then
		LoggerController:ShowShareDialog()
	else
		addon:info(format(L.StrCmdCommands, "RMA logger"), "RMA")
		printHelp("toggle", L.StrCmdToggle)
		printHelp("share", L.StrCmdLoggerShare)
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
		LootCounterWidget:Toggle()
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
	local loot = assert(Services.Loot, Diag.A.SlashSoftresLootServiceNotInitialized)
	local getItemLink = assert(loot.GetItemLink, Diag.A.SlashSoftresLootItemResolverNotInitialized)
	local getItemIdFromLink = assert(Item.GetItemIdFromLink, Diag.A.SlashSoftresItemIdResolverNotInitialized)
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
	local reserves = assert(Services.Reserves, Diag.A.SlashReservesServiceNotInitialized)
	local getReadinessReport =
		assert(reserves.GetReadinessReport, Diag.A.SlashReservesReadinessReporterNotInitialized)
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
	local reserves = assert(Services.Reserves, Diag.A.SlashReservesServiceNotInitialized)
	local setNameAlias = assert(reserves.SetNameAlias, Diag.A.SlashReservesAliasSetterNotInitialized)
	local removeNameAlias = assert(reserves.RemoveNameAlias, Diag.A.SlashReservesAliasRemoverNotInitialized)
	local getNameAliases = assert(reserves.GetNameAliases, Diag.A.SlashReservesAliasListerNotInitialized)
	local requestSyncMetadata = assert(reserves.RequestSyncMetadata, Diag.A.SlashReservesSyncRequesterNotInitialized)
	local getSyncMetadata = assert(reserves.GetSyncMetadata, Diag.A.SlashReservesSyncMetadataReaderNotInitialized)
	local deleteSyncedReservesCache =
		assert(reserves.DeleteSyncedReservesCache, Diag.A.SlashReservesSyncCacheCleanerNotInitialized)

	if isToggleCommand(sub) then
		ReservesWidget:Toggle()
	elseif sub == "import" then
		ReservesWidget:ToggleImport()
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
	elseif topic == "quickbar" then
		showQuickBarHelp()
	elseif topic == "debug" or topic == "dbg" or topic == "debugger" then
		DebugEntryPoint.ShowHelp()
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
registerAliases(cmdDebug, DebugEntryPoint.Handle)
registerAliases(cmdPerf, handlePerfCommand)
registerAliases(cmdMinimap, handleMinimapCommand)
registerAliases(cmdAchiev, handleAchievementCommand)
registerAliases(cmdConfig, handleConfigCommand)
registerAliases(cmdWarnings, handleWarningsCommand)
registerAliases(cmdLogger, handleLoggerCommand)
registerAliases(cmdAttendance, handleAttendanceCommand)
registerAliases(cmdLoot, handleLootCommand)
registerAliases(cmdCounter, handleCounterCommand)
registerAliases(cmdQuickBar, handleQuickBarCommand)
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
