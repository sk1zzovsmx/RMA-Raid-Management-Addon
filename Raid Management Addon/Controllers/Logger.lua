-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: local feature = addon.Database.GetFeatureShared()
-- exports: publish module APIs on addon.*
-- events: listens Logger/Raid/Loot bus refresh events
local addon = select(2, ...)
local feature = addon.Database.GetFeatureShared()

local L = feature.L
local Diag = feature.Diag

local Controllers = feature.Controllers
local coreState = feature.coreState
local UI = feature.UI
local Rows = UI.Rows
local Popups = assert(UI.Popups, "Logger popup namespace is not initialized")
local DefinePopup = assert(Popups.Define, "Logger popup definer is not initialized")
local IsPopupDefined = assert(Popups.IsDefined, "Logger popup defined-state checker is not initialized")
local ShowPopup = assert(Popups.Show, "Logger popup shower is not initialized")
local HidePopup = assert(Popups.Hide, "Logger popup hider is not initialized")
local ResizePopup = assert(Popups.Resize, "Logger popup resizer is not initialized")
local ShowConfirmPopup = assert(Popups.ShowConfirm, "Logger confirm popup shower is not initialized")
local ShowEditBoxPopup = assert(Popups.ShowEditBox, "Logger edit-box popup shower is not initialized")
local Tooltips = UI.Tooltips
local ShowItemTooltip = assert(Tooltips.ShowItem, "Logger item tooltip renderer is not initialized")
local ShowTooltipLines = assert(Tooltips.ShowLines, "Logger tooltip line renderer is not initialized")
local HideTooltip = assert(Tooltips.Hide, "Logger tooltip hide service is not initialized")
local BindTooltip = assert(Tooltips.Bind, "Logger tooltip binder is not initialized")
local BindTooltipModel = assert(Tooltips.BindModel, "Logger source tooltip model binder is not initialized")
local Events = feature.Events
local Frames = UI.Frames
local GetFrame = assert(Frames.Get, "Logger frame resolver is not initialized")
local GetFrameRef = assert(Frames.GetRef, "Logger frame ref resolver is not initialized")
local SetScriptSafely = assert(Frames.SetScriptSafely, "Logger frame script binder is not initialized")
local SetFrameTitle = assert(Frames.SetFrameTitle, "Logger frame title binder is not initialized")
local EnableDrag = assert(Frames.EnableDrag, "Logger frame drag binder is not initialized")
local BindModuleFrame = assert(Frames.BindModuleFrame, "Logger module frame binder is not initialized")
local MakeModuleFrameGetter =
	assert(Frames.MakeModuleFrameGetter, "Logger module frame getter factory is not initialized")
local MakeFrameGetter = assert(Frames.MakeFrameGetter, "Logger frame getter factory is not initialized")
local C = feature.C
local Database = feature.Database
local Options = feature.Options
local Bus = feature.Bus
local Strings = feature.Strings
local Colors = feature.Colors
local Base64 = feature.Base64
local Timer = feature.Timer
local Sort = feature.Sort
local IgnoredMobs = feature.IgnoredMobs
local Services = feature.Services
local LoggerSvc = assert(Services.Logger, "Logger service namespace is not initialized")
local LoggerStore = assert(LoggerSvc.Store, "Logger store service is not initialized")
local LoggerView = assert(LoggerSvc.View, "Logger view service is not initialized")
local LoggerExport = assert(LoggerSvc.Export, "Logger export service is not initialized")
local LoggerActions = assert(LoggerSvc.Actions, "Logger actions service is not initialized")
local LoggerHelpers = assert(LoggerSvc.Helpers, "Logger helper service is not initialized")
local EquipInspect = assert(Services.EquipInspect, "Logger equip-inspect service is not initialized")
local ForceInspectPlayer = assert(EquipInspect.ForcePlayer, "Logger force-inspect method is not initialized")
local Raid = assert(Services.Raid, "Logger raid service is not initialized")

local NormalizeName = Strings.NormalizeName
local NormalizeLower = Strings.NormalizeLower
local TrimText = Strings.TrimText

local CompareValues = Sort.CompareValues
local CompareNumbers = Sort.CompareNumbers
local function compareStrings(aValue, bValue, asc)
	return CompareValues(tostring(aValue or ""), tostring(bValue or ""), asc)
end
local GetLootSortName = Sort.GetLootSortName

local function compareLootTie(a, b, asc)
	local aName = strlower(tostring((a and a.sortName) or ""))
	local bName = strlower(tostring((b and b.sortName) or ""))
	if aName ~= bName then
		return CompareValues(aName, bName, asc)
	end

	local aItemId = tonumber(a and a.itemId) or 0
	local bItemId = tonumber(b and b.itemId) or 0
	if aItemId ~= bItemId then
		return CompareValues(aItemId, bItemId, asc)
	end

	return CompareNumbers(a and a.id, b and b.id, asc, 0)
end

local InternalEvents = assert(Events.Internal, "Logger controller internal events are not initialized")
local TriggerEvent = assert(Bus.TriggerEvent, "Logger controller event publisher is not initialized")
local RegisterCallback = assert(Bus.RegisterCallback, "Logger controller event listener is not initialized")
local LoggerEvents = {
	RaidCreate = assert(InternalEvents.RaidCreate, "Logger controller raid-create event is not initialized"),
	LoggerSelectRaid = assert(
		InternalEvents.LoggerSelectRaid,
		"Logger controller raid selection event is not initialized"
	),
	LoggerSelectBoss = assert(
		InternalEvents.LoggerSelectBoss,
		"Logger controller boss selection event is not initialized"
	),
	LoggerSelectPlayer = assert(
		InternalEvents.LoggerSelectPlayer,
		"Logger controller player selection event is not initialized"
	),
	LoggerSelectBossPlayer = assert(
		InternalEvents.LoggerSelectBossPlayer,
		"Logger controller boss-player selection event is not initialized"
	),
	LoggerSelectItem = assert(
		InternalEvents.LoggerSelectItem,
		"Logger controller item selection event is not initialized"
	),
	RaidRosterDelta = assert(
		InternalEvents.RaidRosterDelta,
		"Logger controller raid roster delta event is not initialized"
	),
	LoggerLootLogRequest = assert(
		InternalEvents.LoggerLootLogRequest,
		"Logger controller loot-log request event is not initialized"
	),
	RaidLootUpdate = assert(
		InternalEvents.RaidLootUpdate,
		"Logger controller raid loot update event is not initialized"
	),
	EquipInspectUpdated = assert(
		InternalEvents.EquipInspectUpdated,
		"Logger controller equip inspect update event is not initialized"
	),
	EquipInspectCompleted = assert(
		InternalEvents.EquipInspectCompleted,
		"Logger controller equip inspect completion event is not initialized"
	),
	RaidAttendanceChanged = assert(
		InternalEvents.RaidAttendanceChanged,
		"Logger controller raid attendance changed event is not initialized"
	),
}

local rollTypes = feature.rollTypes
local lootTypesColored = feature.lootTypesColored
local itemColors = feature.itemColors
local showLoggerExportFrame
local setLootEntry

local _G = _G
local tconcat = table.concat
local pairs, type = pairs, type

local tostring, tonumber = tostring, tonumber
local max, floor = math.max, math.floor
local strlower = string.lower
local IsTrashMobName = IgnoredMobs.IsTrashMobName
local GetTrashMobName = IgnoredMobs.GetTrashMobName

Controllers.Logger = Controllers.Logger or {}
local module = Controllers.Logger

module._loggerPanelNames = module._loggerPanelNames
	or {
		"RMALootHistoryRaids",
		"RMALootHistoryLoot",
		"RMARaidAttendanceRaids",
		"RMARaidAttendanceRaidAttendees",
	}

-- Uniform fields: grouped layout constants for Logger row/list sizing and inspect/spec icon layout.
local LoggerLayout = {
	LOGGER_COMPACT_ROW_HEIGHT = 22,
	LOGGER_LOOT_ROW_HEIGHT = 32,
	LOGGER_LIST_WIDTH_FALLBACK = 240,
	LOGGER_SCROLLBAR_GUTTER_WIDTH = 24,
	LOGGER_ROW_LEFT_INSET = 3,
	LOGGER_ROW_COLUMN_GAP = 6,
	LOGGER_HEADER_COLUMN_GAP = 6,
	LOGGER_LOOT_NAME_LEFT_OFFSET = 34,
	LOGGER_PANEL_SCROLL_LEFT_OFFSET = 3,
	LOGGER_HEADER_TOP_OFFSET = -25,
	LOGGER_ATTENDANCE_TIME_COLUMN_MIN_WIDTH = 56,
	LOGGER_LOOT_COLUMN_MIN_WIDTHS = {
		icon = 30,
		item = 165,
		source = 105,
		winner = 86,
		type = 45,
		roll = 38,
		time = 48,
	},
	LOGGER_LOOT_COLUMN_RATIOS = {
		item = 0.34,
		source = 0.22,
		winner = 0.18,
		type = 0.08,
		roll = 0.07,
		time = 0.11,
	},
	LOGGER_ATTENDANCE_COMPACT_COLUMN_MIN_WIDTHS = {
		name = 106,
		join = 56,
		leave = 56,
	},
	LOGGER_ATTENDANCE_COMPACT_COLUMN_RATIOS = {
		name = 0.56,
		join = 0.22,
		leave = 0.22,
	},
	LOGGER_ATTENDANCE_COLUMN_MIN_WIDTHS = {
		name = 68,
		join = 39,
		leave = 39,
		ilvl = 30,
		spec = 37,
		inspect = 324,
	},
	LOGGER_ATTENDANCE_COLUMN_RATIOS = {
		name = 0,
		join = 0,
		leave = 0,
		ilvl = 0,
		spec = 0,
		inspect = 1,
	},
	LOGGER_RAID_COLUMN_MIN_WIDTHS = {
		id = 24,
		date = 88,
		zone = 128,
		size = 36,
	},
	LOGGER_RAID_COLUMN_RATIOS = {
		date = 0.20,
		zone = 0.66,
		size = 0.14,
	},
	RAID_INSPECT_SLOTS = { 1, 2, 3, 15, 5, 9, 10, 6, 7, 8, 11, 12, 13, 14, 16, 17, 18 },
	RAID_INSPECT_ICON_SIZE = 18,
	RAID_INSPECT_ICON_GAP = 1,
	RAID_SPEC_ICON_SIZE = 17,
	RAID_SPEC_ICON_GAP = 1,
	RAID_INSPECT_ICON_LEFT_OFFSET = 1,
	RAID_SPEC_ICON_LEFT_OFFSET = 1,
}

module._selectionEvents = module._selectionEvents
	or {
		selectedRaid = LoggerEvents.LoggerSelectRaid,
		selectedBoss = LoggerEvents.LoggerSelectBoss,
		selectedPlayer = LoggerEvents.LoggerSelectPlayer,
		selectedBossPlayer = LoggerEvents.LoggerSelectBossPlayer,
		selectedItem = LoggerEvents.LoggerSelectItem,
	}

local function triggerSelectionEvent(target, key, ...)
	local eventName = module._selectionEvents[key]
	if not eventName then
		return
	end
	TriggerEvent(eventName, target[key], ...)
end

local function getActionCommitOpts(extra)
	local opts = {
		selectionState = module,
		triggerSelectionEvent = triggerSelectionEvent,
	}
	if type(extra) == "table" then
		for key, value in pairs(extra) do
			opts[key] = value
		end
	end
	return opts
end

local function setWidgetWidth(widget, width)
	if widget and widget.SetWidth then
		widget:SetWidth(width)
	end
end

local function setHeaderWidth(widget, width, includeTrailingGap)
	local gap = includeTrailingGap and LoggerLayout.LOGGER_HEADER_COLUMN_GAP or 0
	setWidgetWidth(widget, (tonumber(width) or 0) + gap)
end

local function positionLoggerHeader(header, frameName, offsetX, width, includeTrailingGap)
	local frame = frameName and _G[frameName] or nil
	if not (header and frame) then
		return
	end

	header:ClearAllPoints()
	header:SetPoint("TOPLEFT", frame, "TOPLEFT", offsetX, LoggerLayout.LOGGER_HEADER_TOP_OFFSET)
	setHeaderWidth(header, width, includeTrailingGap)
end

local function positionLoggerHeaderColumns(frameName, columns, startOffset)
	local offset = tonumber(startOffset) or LoggerLayout.LOGGER_PANEL_SCROLL_LEFT_OFFSET
	for i = 1, #columns do
		local column = columns[i]
		positionLoggerHeader(column.header, frameName, offset, column.width, column.trailingGap)
		offset = offset + (tonumber(column.width) or 0)
		if column.trailingGap then
			offset = offset + LoggerLayout.LOGGER_HEADER_COLUMN_GAP
		end
	end
end

local function getLoggerLayoutColumnWidth(widths, column, isHeader)
	local width = tonumber(widths and widths[column.widthKey]) or 0
	if isHeader and column.headerExtraWidthKey then
		width = width + (tonumber(widths and widths[column.headerExtraWidthKey]) or 0)
	end
	return width
end

local function buildLoggerHeaderColumns(frameName, widths, columns)
	local headers = {}
	for i = 1, #columns do
		local column = columns[i]
		headers[#headers + 1] = {
			header = _G[frameName .. column.headerSuffix],
			width = getLoggerLayoutColumnWidth(widths, column, true),
			trailingGap = column.trailingGap,
		}
	end
	return headers
end

local function applyLoggerRowColumnWidths(ui, widths, columns)
	if not ui then
		return
	end
	for i = 1, #columns do
		local column = columns[i]
		local width = getLoggerLayoutColumnWidth(widths, column, false)
		setWidgetWidth(ui[column.rowKey], width)
		if column.hitBoxKey then
			setWidgetWidth(ui[column.hitBoxKey], width)
		end
	end
end

local function getLoggerListContentWidth(frameName)
	if not frameName then
		return LoggerLayout.LOGGER_LIST_WIDTH_FALLBACK
	end

	local scroll = _G[frameName .. "ScrollFrame"]
	local width = scroll and scroll.GetWidth and scroll:GetWidth() or nil
	if type(width) ~= "number" or width <= 0 then
		local frame = _G[frameName]
		width = frame and frame.GetWidth and frame:GetWidth() or nil
		if type(width) == "number" and width > LoggerLayout.LOGGER_SCROLLBAR_GUTTER_WIDTH then
			width = width - LoggerLayout.LOGGER_SCROLLBAR_GUTTER_WIDTH
		end
	end

	width = tonumber(width) or LoggerLayout.LOGGER_LIST_WIDTH_FALLBACK
	return max(LoggerLayout.LOGGER_LIST_WIDTH_FALLBACK, floor(width))
end

local function getLoggerListColumnBudget(frameName, leadOffset, gapCount, returnedWidthOffset)
	local width = getLoggerListContentWidth(frameName)
	local budget = width
		- (tonumber(leadOffset) or 0)
		- ((tonumber(gapCount) or 0) * LoggerLayout.LOGGER_ROW_COLUMN_GAP)
	budget = budget + (tonumber(returnedWidthOffset) or 0)
	return max(LoggerLayout.LOGGER_LIST_WIDTH_FALLBACK, floor(budget))
end

local function calculateLoggerColumnWidths(totalWidth, minWidths, ratios, fixedKeys)
	local widths = {}
	local variableKeys = {}
	local fixed = {}
	local usedWidth = 0
	local ratioTotal = 0

	if fixedKeys then
		for i = 1, #fixedKeys do
			fixed[fixedKeys[i]] = true
		end
	end

	for key, minWidth in pairs(minWidths) do
		local width = tonumber(minWidth) or 0
		widths[key] = width
		usedWidth = usedWidth + width
		if not fixed[key] then
			variableKeys[#variableKeys + 1] = key
			ratioTotal = ratioTotal + (tonumber(ratios[key]) or 0)
		end
	end

	local extraWidth = floor((tonumber(totalWidth) or 0) - usedWidth)
	if extraWidth <= 0 or ratioTotal <= 0 then
		return widths
	end

	local allocated = 0
	for i = 1, #variableKeys do
		local key = variableKeys[i]
		local ratio = (tonumber(ratios[key]) or 0) / ratioTotal
		local addition = floor(extraWidth * ratio)
		widths[key] = widths[key] + addition
		allocated = allocated + addition
	end

	local remainder = extraWidth - allocated
	if remainder > 0 then
		for i = 1, #variableKeys do
			local key = variableKeys[i]
			widths[key] = widths[key] + 1
			remainder = remainder - 1
			if remainder <= 0 then
				break
			end
		end
	end

	return widths
end

local function getRaidColumnWidths(frameName)
	local budget = getLoggerListColumnBudget(frameName, LoggerLayout.LOGGER_ROW_LEFT_INSET, 3)
	return calculateLoggerColumnWidths(
		budget,
		LoggerLayout.LOGGER_RAID_COLUMN_MIN_WIDTHS,
		LoggerLayout.LOGGER_RAID_COLUMN_RATIOS,
		{ "id" }
	)
end

local function getLootColumnWidths(frameName)
	local budget = getLoggerListColumnBudget(
		frameName,
		LoggerLayout.LOGGER_LOOT_NAME_LEFT_OFFSET,
		5,
		LoggerLayout.LOGGER_LOOT_COLUMN_MIN_WIDTHS.icon
	)
	return calculateLoggerColumnWidths(
		budget,
		LoggerLayout.LOGGER_LOOT_COLUMN_MIN_WIDTHS,
		LoggerLayout.LOGGER_LOOT_COLUMN_RATIOS,
		{ "icon" }
	)
end

local function isAttendanceInspectPanel(frameName)
	return frameName == "RMARaidAttendanceRaidAttendees"
end

local function getAttendanceColumnWidths(frameName)
	local isInspectPanel = isAttendanceInspectPanel(frameName)
	local gapCount = isInspectPanel and 5 or 2
	local budget = getLoggerListColumnBudget(frameName, LoggerLayout.LOGGER_ROW_LEFT_INSET, gapCount)
	if not isInspectPanel then
		return calculateLoggerColumnWidths(
			budget,
			LoggerLayout.LOGGER_ATTENDANCE_COMPACT_COLUMN_MIN_WIDTHS,
			LoggerLayout.LOGGER_ATTENDANCE_COMPACT_COLUMN_RATIOS
		)
	end
	return calculateLoggerColumnWidths(
		budget,
		LoggerLayout.LOGGER_ATTENDANCE_COLUMN_MIN_WIDTHS,
		LoggerLayout.LOGGER_ATTENDANCE_COLUMN_RATIOS
	)
end

local RAID_LAYOUT_COLUMNS = {
	{ headerSuffix = "HeaderNum", rowKey = "ID", widthKey = "id", trailingGap = true, sortKey = "id" },
	{ headerSuffix = "HeaderDate", rowKey = "Date", widthKey = "date", trailingGap = true, sortKey = "date" },
	{ headerSuffix = "HeaderZone", rowKey = "Zone", widthKey = "zone", trailingGap = true, sortKey = "zone" },
	{ headerSuffix = "HeaderSize", rowKey = "Size", widthKey = "size", trailingGap = false, sortKey = "size" },
}

local LOOT_LAYOUT_COLUMNS = {
	{
		headerSuffix = "HeaderItem",
		rowKey = "Name",
		widthKey = "item",
		headerExtraWidthKey = "icon",
		trailingGap = true,
		sortKey = "id",
	},
	{
		headerSuffix = "HeaderSource",
		rowKey = "Source",
		hitBoxKey = "SourceHitBox",
		widthKey = "source",
		trailingGap = true,
		sortKey = "source",
	},
	{ headerSuffix = "HeaderWinner", rowKey = "Winner", widthKey = "winner", trailingGap = true, sortKey = "winner" },
	{ headerSuffix = "HeaderType", rowKey = "Type", widthKey = "type", trailingGap = true, sortKey = "type" },
	{ headerSuffix = "HeaderRoll", rowKey = "Roll", widthKey = "roll", trailingGap = true, sortKey = "roll" },
	{ headerSuffix = "HeaderTime", rowKey = "Time", widthKey = "time", trailingGap = false, sortKey = "time" },
}

local ATTENDANCE_COMPACT_LAYOUT_COLUMNS = {
	{ headerSuffix = "HeaderName", rowKey = "Name", widthKey = "name", trailingGap = true },
	{ headerSuffix = "HeaderJoin", rowKey = "Join", widthKey = "join", trailingGap = true },
	{ headerSuffix = "HeaderLeave", rowKey = "Leave", widthKey = "leave", trailingGap = false },
}

local ATTENDANCE_INSPECT_LAYOUT_COLUMNS = {
	{ headerSuffix = "HeaderName", rowKey = "Name", widthKey = "name", trailingGap = true, sortKey = "name" },
	{ headerSuffix = "HeaderJoin", rowKey = "Join", widthKey = "join", trailingGap = true, sortKey = "join" },
	{ headerSuffix = "HeaderLeave", rowKey = "Leave", widthKey = "leave", trailingGap = true, sortKey = "leave" },
	{ headerSuffix = "HeaderIlvl", rowKey = "Ilvl", widthKey = "ilvl", trailingGap = true, sortKey = "ilvl" },
	{ headerSuffix = "HeaderSpec", rowKey = "Spec", widthKey = "spec", trailingGap = true, sortKey = "spec" },
	{
		headerSuffix = "HeaderInspect",
		rowKey = "InspectStatus",
		widthKey = "inspect",
		trailingGap = false,
	},
}

local function getAttendanceLayoutColumns(frameName)
	if isAttendanceInspectPanel(frameName) then
		return ATTENDANCE_INSPECT_LAYOUT_COLUMNS
	end
	return ATTENDANCE_COMPACT_LAYOUT_COLUMNS
end

local function applyLoggerHeaderColumnWidths(frameName, widths, columns, startOffset)
	if not frameName then
		return
	end
	positionLoggerHeaderColumns(frameName, buildLoggerHeaderColumns(frameName, widths, columns), startOffset)
end

local function applyRaidListColumnWidths(frameName)
	if not frameName then
		return
	end
	local widths = getRaidColumnWidths(frameName)
	applyLoggerHeaderColumnWidths(
		frameName,
		widths,
		RAID_LAYOUT_COLUMNS,
		LoggerLayout.LOGGER_PANEL_SCROLL_LEFT_OFFSET + LoggerLayout.LOGGER_ROW_LEFT_INSET
	)
end

local function applyRaidRowColumnWidths(ui, frameName)
	applyLoggerRowColumnWidths(ui, getRaidColumnWidths(frameName), RAID_LAYOUT_COLUMNS)
end

local function applyLootListColumnWidths(frameName)
	if not frameName then
		return
	end
	local widths = getLootColumnWidths(frameName)
	applyLoggerHeaderColumnWidths(frameName, widths, LOOT_LAYOUT_COLUMNS, LoggerLayout.LOGGER_PANEL_SCROLL_LEFT_OFFSET)
end

local function applyLootRowColumnWidths(ui, frameName)
	applyLoggerRowColumnWidths(ui, getLootColumnWidths(frameName), LOOT_LAYOUT_COLUMNS)
end

local function applyAttendanceListColumnWidths(frameName)
	if not frameName then
		return
	end
	local widths = getAttendanceColumnWidths(frameName)
	local columns = getAttendanceLayoutColumns(frameName)
	applyLoggerHeaderColumnWidths(
		frameName,
		widths,
		columns,
		LoggerLayout.LOGGER_PANEL_SCROLL_LEFT_OFFSET + LoggerLayout.LOGGER_ROW_LEFT_INSET
	)
end

local function applyAttendanceRowColumnWidths(ui, frameName)
	local columns = getAttendanceLayoutColumns(frameName)
	applyLoggerRowColumnWidths(ui, getAttendanceColumnWidths(frameName), columns)
end

local bindAttendanceSpecIconTooltip

local function getInspectStatusLabel(status, reason)
	local safeStatus = status and tostring(status):lower() or ""
	if safeStatus == "ready" then
		return ""
	end
	if safeStatus == "" then
		return L.StrInspectNotInspected
	end
	if safeStatus == "queued" then
		return L.StrInspectQueued
	end
	if safeStatus == "pending" then
		return L.StrInspectPending
	end
	if safeStatus == "skipped" then
		if reason and reason ~= "" then
			return (L.StrInspectSkippedReason):format(reason)
		end
		return L.StrInspectSkipped
	end
	if safeStatus == "timeout" then
		return L.StrInspectTimeout
	end
	if safeStatus == "failed" then
		if reason and reason ~= "" then
			return (L.StrInspectFailedReason):format(reason)
		end
		return L.StrInspectFailed
	end
	return tostring(status)
end

local function getAttendanceInspectIcon(row, index, ui)
	if not row or not ui then
		return nil
	end
	row._RMAAttendanceInspectIcons = row._RMAAttendanceInspectIcons or {}
	local list = row._RMAAttendanceInspectIcons
	local icon = list[index]
	if icon then
		return icon
	end

	local rowName = row.GetName and row:GetName() or nil
	local iconName = rowName and (rowName .. "InspectItemIcon" .. tostring(index)) or nil
	icon = iconName and _G[iconName] or nil
	if not icon then
		return nil
	end
	icon:EnableMouse(true)
	icon:SetSize(LoggerLayout.RAID_INSPECT_ICON_SIZE, LoggerLayout.RAID_INSPECT_ICON_SIZE)
	icon:SetID(index)
	icon.texture = iconName and _G[iconName .. "Texture"] or nil
	if not icon.texture then
		return nil
	end
	icon.texture:SetAllPoints(icon)
	icon.texture:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	if not icon:GetScript("OnEnter") then
		SetScriptSafely(icon, "OnEnter", function(self)
			local link = self._RMAItemLink
			if not link then
				return
			end
			ShowItemTooltip(self, link, nil, "ANCHOR_LEFT")
		end)
	end
	if not icon:GetScript("OnLeave") then
		SetScriptSafely(icon, "OnLeave", function()
			HideTooltip()
		end)
	end
	list[index] = icon
	return icon
end

local function clearAttendanceInspectIcons(row)
	if not row or not row._RMAAttendanceInspectIcons then
		return
	end

	for i = 1, #row._RMAAttendanceInspectIcons do
		local icon = row._RMAAttendanceInspectIcons[i]
		if icon then
			icon:Hide()
			icon._RMAItemLink = nil
			icon._RMAPlayerNid = nil
			if icon.texture then
				if icon.texture.SetDesaturated then
					icon.texture:SetDesaturated(false)
				end
				icon.texture:SetTexture(nil)
			end
		end
	end
end

local GetItemIcon = assert(_G.GetItemIcon, "Logger item icon API is not initialized")
local CreateFrame = assert(_G.CreateFrame, "Logger frame creation API is not initialized")
local UIParent = assert(_G.UIParent, "Logger root UI parent is not initialized")

local function getAttendanceSpecIcon(row)
	if not row then
		return nil
	end
	if row._RMAAttendanceSpecIcon then
		return row._RMAAttendanceSpecIcon
	end

	local rowName = row.GetName and row:GetName() or nil
	local iconName = rowName and (rowName .. "SpecIcon") or nil
	local icon = iconName and _G[iconName] or nil
	if not icon then
		return nil
	end
	icon:EnableMouse(true)
	icon:SetSize(LoggerLayout.RAID_SPEC_ICON_SIZE, LoggerLayout.RAID_SPEC_ICON_SIZE)
	icon.texture = iconName and _G[iconName .. "Texture"] or nil
	if not icon.texture then
		return nil
	end
	icon.texture:SetAllPoints(icon)
	icon.texture:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	bindAttendanceSpecIconTooltip(icon)
	row._RMAAttendanceSpecIcon = icon
	return icon
end

local function getAttendanceSecondarySpecIcon(row)
	if not row then
		return nil
	end
	if row._RMAAttendanceSecondarySpecIcon then
		return row._RMAAttendanceSecondarySpecIcon
	end

	local rowName = row.GetName and row:GetName() or nil
	local iconName = rowName and (rowName .. "SecondarySpecIcon") or nil
	local icon = iconName and _G[iconName] or nil
	if not icon then
		return nil
	end
	icon:EnableMouse(true)
	icon:SetSize(LoggerLayout.RAID_SPEC_ICON_SIZE, LoggerLayout.RAID_SPEC_ICON_SIZE)
	icon.texture = iconName and _G[iconName .. "Texture"] or nil
	if not icon.texture then
		return nil
	end
	icon.texture:SetAllPoints(icon)
	icon.texture:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	bindAttendanceSpecIconTooltip(icon)
	row._RMAAttendanceSecondarySpecIcon = icon
	return icon
end

bindAttendanceSpecIconTooltip = function(icon)
	if not icon or not icon.SetScript then
		return
	end

	SetScriptSafely(icon, "OnEnter", function(self)
		local specName = self and self._RMASpecName
		if not (specName and specName ~= "") then
			return
		end
		ShowTooltipLines(self, {
			anchor = "ANCHOR_LEFT",
			title = specName,
		})
	end)
	SetScriptSafely(icon, "OnLeave", function()
		HideTooltip()
	end)
end

local function setAttendanceSpecIconTexture(icon, iconPath, specName, desaturate)
	if not icon or not icon.texture then
		return
	end
	if iconPath and iconPath ~= "" then
		icon.texture:SetTexture(iconPath)
		icon:Show()
		icon._RMASpecName = specName
	else
		icon:Hide()
		icon.texture:SetTexture(nil)
		icon._RMASpecName = nil
	end
	if icon.texture.SetDesaturated then
		icon.texture:SetDesaturated(desaturate and true or false)
	end
end

local function clearAttendanceSpecIcons(row)
	if not row then
		return
	end

	local icon = row._RMAAttendanceSpecIcon
	if icon then
		icon:Hide()
		icon._RMASpecName = nil
		if icon.texture then
			icon.texture:SetTexture(nil)
			if icon.texture.SetDesaturated then
				icon.texture:SetDesaturated(false)
			end
		end
	end

	local secondaryIcon = row._RMAAttendanceSecondarySpecIcon
	if secondaryIcon then
		secondaryIcon:Hide()
		secondaryIcon._RMASpecName = nil
		if secondaryIcon.texture then
			secondaryIcon.texture:SetTexture(nil)
			if secondaryIcon.texture.SetDesaturated then
				secondaryIcon.texture:SetDesaturated(false)
			end
		end
	end
end

local function setAttendanceSpecIcon(row, ui, primarySpecIcon, secondarySpecIcon, primarySpecName, secondarySpecName)
	if ui and ui.Spec and ui.Spec.SetText then
		ui.Spec:SetText("")
	end

	local primaryIcon = getAttendanceSpecIcon(row)
	local secondaryIcon = getAttendanceSecondarySpecIcon(row)
	if not primaryIcon or not secondaryIcon then
		return
	end
	if not (ui and ui.Spec) then
		clearAttendanceSpecIcons(row)
		return
	end

	primaryIcon:ClearAllPoints()
	primaryIcon:SetPoint("TOPLEFT", ui.Spec, "TOPLEFT", LoggerLayout.RAID_SPEC_ICON_LEFT_OFFSET, -1)
	secondaryIcon:ClearAllPoints()
	secondaryIcon:SetPoint(
		"TOPLEFT",
		ui.Spec,
		"TOPLEFT",
		LoggerLayout.RAID_SPEC_ICON_LEFT_OFFSET + LoggerLayout.RAID_SPEC_ICON_SIZE + LoggerLayout.RAID_SPEC_ICON_GAP,
		-1
	)

	setAttendanceSpecIconTexture(primaryIcon, primarySpecIcon, primarySpecName, false)
	setAttendanceSpecIconTexture(secondaryIcon, secondarySpecIcon, secondarySpecName, true)
end

local function renderAttendanceInspectIcons(row, ui, playerNid, snapshot)
	if not row then
		return
	end
	clearAttendanceInspectIcons(row)
	if not ui or not playerNid then
		if ui and ui.InspectStatus then
			ui.InspectStatus:SetText("")
		end
		return
	end

	local status = snapshot and snapshot.status
	local reason = snapshot and snapshot.reason
	local label = getInspectStatusLabel(status, reason)
	if ui.InspectStatus then
		ui.InspectStatus:SetText(label)
	end

	if not snapshot or tostring(status or ""):lower() ~= "ready" then
		return
	end

	local items = snapshot.items
	if type(items) ~= "table" then
		return
	end

	local x = LoggerLayout.RAID_INSPECT_ICON_LEFT_OFFSET
	local count = 0
	for i = 1, #LoggerLayout.RAID_INSPECT_SLOTS do
		local slot = LoggerLayout.RAID_INSPECT_SLOTS[i]
		local item = items[slot]
		if item and (item.texture or item.itemLink) then
			count = count + 1
			local icon = getAttendanceInspectIcon(row, count, ui)
			if not icon then
				break
			end
			icon._RMAItemLink = item.itemLink
			icon._RMAPlayerNid = playerNid
			local iconTexture = item.texture
			if not iconTexture and item.itemId then
				iconTexture = GetItemIcon(item.itemId)
			end
			if icon.texture then
				icon.texture:SetTexture(iconTexture or 134400)
				if icon.texture.SetDesaturated then
					icon.texture:SetDesaturated(false)
				end
			end
			icon:ClearAllPoints()
			icon:SetPoint("TOPLEFT", ui.InspectStatus, "TOPLEFT", x, -1)
			icon:Show()
			x = x + LoggerLayout.RAID_INSPECT_ICON_SIZE + LoggerLayout.RAID_INSPECT_ICON_GAP
		end
	end
end

local function bindLoggerSortHeaders(frameName, columns, listRef, boundFlag)
	local frame = frameName and _G[frameName] or nil
	if not frame or not listRef or type(listRef.Sort) ~= "function" then
		return
	end
	if not boundFlag then
		boundFlag = "_RMABound"
	end
	if frame[boundFlag] then
		return
	end

	for i = 1, #columns do
		local column = columns[i]
		if column.sortKey then
			local headerButton = column.headerSuffix and _G[frameName .. column.headerSuffix] or nil
			if headerButton then
				local sortKey = column.sortKey
				SetScriptSafely(headerButton, "OnClick", function()
					listRef:Sort(sortKey)
				end)
			end
		end
	end
	frame[boundFlag] = true
end

local function bindRaidSortHeaders(frameName, listRef)
	return bindLoggerSortHeaders(frameName, RAID_LAYOUT_COLUMNS, listRef, "_RMABound")
end

local uiState = UI.Scaffold.EnsureModuleState(module)

local function getCountTitle(baseText, count)
	return ("%s (%d)"):format(tostring(baseText or ""), tonumber(count) or 0)
end

local function getContextTitle(baseText, contextText, emptyHint)
	local suffix = contextText
	if not suffix or suffix == "" then
		suffix = emptyHint
	end
	if suffix and suffix ~= "" then
		return ("%s - %s"):format(baseText, suffix)
	end
	return baseText
end

local function getCountContextTitle(baseText, count, contextText, emptyHint)
	return getContextTitle(getCountTitle(baseText, count), contextText, emptyHint)
end

local function getRaidContextLabel(selectedRaid)
	if not selectedRaid then
		return nil
	end
	local store = module.Store
	local view = module.View
	local raid = store and store:GetRaid(selectedRaid) or nil
	if not raid then
		return nil
	end
	local zone = raid.zone or nil
	local difficulty = view and view:GetRaidDifficultyLabel(raid) or ""
	if zone and zone ~= "" and difficulty ~= "" then
		return ("%s %s"):format(zone, difficulty)
	end
	if zone and zone ~= "" then
		return zone
	end
	if difficulty ~= "" then
		return difficulty
	end
	return nil
end

local function getBossContextLabel(selectedRaid, selectedBoss)
	if not (selectedRaid and selectedBoss) then
		return nil
	end
	local store = module.Store
	local view = module.View
	local raid = store and store:GetRaid(selectedRaid) or nil
	local boss = raid and store:GetBoss(raid, selectedBoss) or nil
	if not boss then
		return nil
	end
	local name = boss.name
	if not name or name == "" then
		name = L.StrTrashMob
	end
	local mode = view and view:GetBossModeLabel(boss) or nil
	if mode and mode ~= "" then
		return ("%s %s"):format(name, mode)
	end
	return name
end

local function getPlayerContextLabel(selectedRaid, playerNid)
	if not (selectedRaid and playerNid) then
		return nil
	end
	local store = module.Store
	local raid = store and store:GetRaid(selectedRaid) or nil
	local player = raid and store:GetPlayer(raid, playerNid) or nil
	if player and player.name and player.name ~= "" then
		return L.StrLoggerLabelPlayer:format(player.name)
	end
	return nil
end

local function getLootPanelContextLabel(sel)
	local parts = {}
	local bossLabel = getBossContextLabel(sel.selectedRaid, sel.selectedBoss)
	local playerLabel = getPlayerContextLabel(sel.selectedRaid, sel.selectedBossPlayer or sel.selectedPlayer)

	if bossLabel and bossLabel ~= "" then
		parts[#parts + 1] = bossLabel
	end
	if playerLabel and playerLabel ~= "" then
		parts[#parts + 1] = playerLabel
	end
	if #parts > 0 then
		return tconcat(parts, " | ")
	end
	return getRaidContextLabel(sel.selectedRaid)
end

local function getRaidAttendeesEmptyStateText(count, selectedRaid)
	if (tonumber(count) or 0) > 0 then
		return nil
	end
	if not selectedRaid then
		return L.StrLoggerEmptyRaidAttendeesSelectRaid
	end
	return L.StrLoggerEmptyRaidAttendees
end

local function getLootEmptyStateText(count, sel)
	if (tonumber(count) or 0) > 0 then
		return nil
	end
	if not sel.selectedRaid then
		return L.StrLoggerEmptyLootSelectRaid
	end
	if sel.selectedBoss or sel.selectedBossPlayer or sel.selectedPlayer then
		return L.StrLoggerEmptyLootFiltered
	end
	return L.StrLoggerEmptyLoot
end

local function normalizeLoggerRollValue(value)
	return LoggerHelpers.NormalizeRollValue(value)
end

local function isValidRollValue(text)
	local value = normalizeLoggerRollValue(text)
	if not value or value < 0 then
		return false
	end
	return true, value
end

local function placePanel(frame, point, relativeTo, relativePoint, x, y, width, height)
	if not frame then
		return
	end
	if frame.ClearAllPoints then
		frame:ClearAllPoints()
	end
	if frame.SetPoint then
		frame:SetPoint(point, relativeTo, relativePoint, x, y)
	end
	if frame.SetSize then
		frame:SetSize(width, height)
	elseif frame.SetWidth and frame.SetHeight then
		frame:SetWidth(width)
		frame:SetHeight(height)
	end
end

-- Timer ownership: refresh debounce for roster-bound lists.
Timer.BindMixin(module, "Logger")

-- Logger frame module.
do
	-- ----- Internal state ----- --
	local getFrame = MakeModuleFrameGetter(module, "RMALootHistory")
	-- Import service modules (extracted to Services/Logger/).
	local Store = LoggerStore
	local View = LoggerView
	local Export = LoggerExport
	local Actions = LoggerActions

	module.Store = LoggerStore
	module.View = LoggerView
	module.Export = LoggerExport
	module.Actions = LoggerActions

	-- ----- Private helpers ----- --

	function uiState.AcquireRefs(frame)
		return {
			history = GetFrameRef(frame, "History"),
			raids = GetFrameRef(frame, "RMALootHistoryRaids"),
			loot = GetFrameRef(frame, "RMALootHistoryLoot"),
		}
	end

	local function ensureSubmoduleOnLoad(moduleRef, frame)
		if not (moduleRef and frame) then
			return
		end
		if frame._RMAOnLoadBound then
			return
		end
		if moduleRef._LoadFrame then
			moduleRef._LoadFrame(frame)
		elseif moduleRef.OnLoad then
			moduleRef:OnLoad(frame)
		else
			return
		end
		frame._RMAOnLoadBound = true
	end

	local function clearSelection(target, key, multiSelectCtx)
		target[key] = nil
		if multiSelectCtx then
			UI.Selection.EnsureState(multiSelectCtx)
		end
	end

	module._setFrameLabel = function(frameName, suffix, text)
		local label = frameName and _G[frameName .. suffix] or nil
		if not label then
			return nil
		end
		if label.GetText and label:GetText() == text then
			return label
		end
		label:SetText(text)
		return label
	end

	module._setPanelTitle = function(frameName, text)
		module._setFrameLabel(frameName, "Title", text)
	end

	module._setFrameHint = function(frameName, suffix, text)
		local label = module._setFrameLabel(frameName, suffix, text or "")
		if label then
			UI.Primitives.SetShown(label, type(text) == "string" and text ~= "")
		end
	end

	local function applyFocusedMultiSelect(opts)
		if not opts then
			return nil, 0
		end

		local id = opts.id
		local ctx = opts.context
		if not (id and ctx and opts.setFocus) then
			return nil, 0
		end

		local function setFocusFromSelected(selectedId)
			if opts.mapSelectedToFocus then
				opts.setFocus(opts.mapSelectedToFocus(selectedId))
				return
			end
			opts.setFocus(selectedId)
		end

		if opts.isRange then
			local action, count = UI.Selection.SelectRange(ctx, opts.ordered, id, opts.isMulti)
			setFocusFromSelected(id)
			return action, count
		end

		local allowDeselect = opts.allowDeselect
		if allowDeselect == nil then
			allowDeselect = true
		end

		local action, count = UI.Selection.Toggle(ctx, id, opts.isMulti, allowDeselect)
		if action == "SINGLE_DESELECT" then
			opts.setFocus(nil)
		elseif action == "TOGGLE_OFF" then
			local clickedWasFocused = false
			if opts.isClickedFocused then
				clickedWasFocused = opts.isClickedFocused(id) and true or false
			elseif opts.getFocus then
				clickedWasFocused = (opts.getFocus() == id)
			end

			if clickedWasFocused then
				local selected = UI.Selection.GetSelected(ctx)
				setFocusFromSelected(selected[1])
			end
		else
			setFocusFromSelected(id)
		end

		if (tonumber(count) or 0) > 0 then
			UI.Selection.SetAnchor(ctx, id)
		else
			UI.Selection.SetAnchor(ctx, nil)
		end

		return action, count
	end

	local function applyModuleFocusedMultiSelect(id, context, ordered, isMulti, isRange, focusKey)
		return applyFocusedMultiSelect({
			id = id,
			context = context,
			ordered = ordered,
			isMulti = isMulti,
			isRange = isRange,
			getFocus = function()
				return module[focusKey]
			end,
			setFocus = function(value)
				module[focusKey] = value
			end,
		})
	end

	-- ----- Public methods ----- --

	module.selectedRaid = nil
	module.selectedBoss = nil
	module.selectedPlayer = nil
	module.selectedBossPlayer = nil
	module.selectedItem = nil
	module.activeTab = module.activeTab or "loot"
	module._SetSelectedRaid = function(raidId)
		if raidId == nil then
			module.selectedRaid = nil
		else
			module.selectedRaid = tonumber(raidId) or raidId
		end
		coreState.selectedRaid = module.selectedRaid
		return module.selectedRaid
	end

	-- Multi-select context keys (runtime-only)
	-- NOTE: selection state lives in MultiSelect module and is keyed by these context strings.
	module._msRaidCtx = module._msRaidCtx or "LoggerRaids"
	module._msBossCtx = module._msBossCtx or "LoggerBosses"
	module._msBossAttCtx = module._msBossAttCtx or "LoggerBossAttendees"
	module._msRaidAttCtx = module._msRaidAttCtx or "LoggerRaidAttendees"
	module._msLootCtx = module._msLootCtx or "LoggerLoot"

	local MS_CTX_RAID = module._msRaidCtx
	local MS_CTX_BOSS = module._msBossCtx
	local MS_CTX_BOSSATT = module._msBossAttCtx
	local MS_CTX_RAIDATT = module._msRaidAttCtx
	local MS_CTX_LOOT = module._msLootCtx

	-- Multi-select modifier scopes (input policy by panel/list)
	module._msRaidScopeHistory = module._msRaidScopeHistory or "LoggerRaidsHistory"
	module._msBossScope = module._msBossScope or "LoggerBosses"
	module._msBossAttScope = module._msBossAttScope or "LoggerBossAttendees"
	module._msRaidAttScope = module._msRaidAttScope or "LoggerRaidAttendees"
	module._msLootScope = module._msLootScope or "LoggerLoot"

	local MS_SCOPE_RAID_HISTORY = module._msRaidScopeHistory
	local MS_SCOPE_BOSS = module._msBossScope
	local MS_SCOPE_BOSSATT = module._msBossAttScope
	local MS_SCOPE_RAIDATT = module._msRaidAttScope
	local MS_SCOPE_LOOT = module._msLootScope

	UI.Selection.SetModifierPolicy(MS_SCOPE_RAID_HISTORY, { allowMulti = true, allowRange = true })
	UI.Selection.SetModifierPolicy(MS_SCOPE_BOSS, { allowMulti = true, allowRange = true })
	UI.Selection.SetModifierPolicy(MS_SCOPE_BOSSATT, { allowMulti = true, allowRange = true })
	UI.Selection.SetModifierPolicy(MS_SCOPE_RAIDATT, { allowMulti = true, allowRange = true })
	UI.Selection.SetModifierPolicy(MS_SCOPE_LOOT, { allowMulti = true, allowRange = true })

	-- Clears selections that depend on the currently focused raid (boss/player/loot panels).
	-- Intentionally does NOT clear the raid selection itself.
	local function clearSelections()
		clearSelection(module, "selectedBoss", MS_CTX_BOSS)
		clearSelection(module, "selectedPlayer", MS_CTX_RAIDATT)
		clearSelection(module, "selectedBossPlayer", MS_CTX_BOSSATT)
		clearSelection(module, "selectedItem", MS_CTX_LOOT)
	end

	local function setPanelVisible(frame, visible)
		if not frame then
			return
		end
		UI.Primitives.SetShown(frame, visible)
	end

	local function refreshLoggerTabLayout()
		local refs = module.refs or {}
		local history = refs.history

		setPanelVisible(refs.raids, true)
		setPanelVisible(refs.loot, true)

		placePanel(refs.raids, "TOPLEFT", history, "TOPLEFT", 0, 0, 335, 430)
		placePanel(refs.loot, "TOPLEFT", refs.raids, "TOPRIGHT", 7, 0, 600, 430)
		applyRaidListColumnWidths("RMALootHistoryRaids")
		applyLootListColumnWidths("RMALootHistoryLoot")
	end

	local rosterUiRefreshDebounceSeconds = 0.25

	module._isLoggerViewingCurrentRaid = function()
		local frame = module.frame or getFrame()
		if not (frame and frame.IsShown and frame:IsShown()) then
			return false
		end
		local currentRaid = Database.GetCurrentRaid()
		return currentRaid and module.selectedRaid and tonumber(module.selectedRaid) == tonumber(currentRaid)
	end

	local function refreshRosterBoundLists()
		local listModules = { module.Raids, module.Loot }
		for i = 1, #listModules do
			local ctrl = listModules[i] and listModules[i]._ctrl
			if ctrl and ctrl.Dirty then
				ctrl:Dirty()
			end
		end
	end

	module._requestRosterBoundListsRefresh = function()
		if module._rosterUiHandle then
			module:CancelTimer(module._rosterUiHandle)
			module._rosterUiHandle = nil
		end
		module._rosterUiHandle = module:ScheduleTimer(function()
			module._rosterUiHandle = nil
			if not module._isLoggerViewingCurrentRaid() then
				return
			end
			refreshRosterBoundLists()
		end, rosterUiRefreshDebounceSeconds)
	end

	-- Logger helpers: resolve current raid/boss/loot and run raid actions with a single refresh.
	module._needRaid = function()
		local rID = module.selectedRaid
		local raid = rID and Store:GetRaid(rID) or nil
		return raid, rID
	end

	module._runWithSelectedRaid = function(fn, refreshEvent)
		local raid, rID = module._needRaid()
		if not raid then
			return
		end
		fn(raid, rID)
		if refreshEvent ~= false then
			TriggerEvent(refreshEvent or LoggerEvents.LoggerSelectRaid, module.selectedRaid)
		end
	end

	local function getExportFrameRefs()
		local frame = GetFrame("RMAExportFrame")
		if not frame then
			return nil
		end

		return {
			frame = frame,
			hint = GetFrameRef(frame, "Hint"),
			lootBtn = GetFrameRef(frame, "LootBtn"),
			raidAttendanceBtn = GetFrameRef(frame, "RaidAttendanceBtn"),
			output = GetFrameRef(frame, "Output"),
			outputScroll = GetFrameRef(frame, "OutputScroll"),
			closeBtn = GetFrameRef(frame, "CloseBtn"),
		}
	end

	local function setExportModeButtonState(refs, mode)
		local buttons = {
			{ button = refs and refs.lootBtn, mode = "loot" },
			{ button = refs and refs.raidAttendanceBtn, mode = "raidAttendance" },
		}

		for i = 1, #buttons do
			local entry = buttons[i]
			local button = entry.button
			if button then
				if entry.mode == mode then
					if button.LockHighlight then
						button:LockHighlight()
					end
				elseif button.UnlockHighlight then
					button:UnlockHighlight()
				end
			end
		end
	end

	local function getExportContext()
		return {
			raidId = module.selectedRaid,
			selectedBossNid = module.selectedBoss,
			selectedPlayerNid = module.selectedBossPlayer or module.selectedPlayer,
		}
	end

	local function setExportText(refs, text)
		local output = refs and refs.output
		if not output then
			return
		end

		if output.SetTextInsets then
			output:SetTextInsets(8, 8, 8, 8)
		end
		if output.SetJustifyH then
			output:SetJustifyH("LEFT")
		end
		if output.SetJustifyV then
			output:SetJustifyV("TOP")
		end
		module._lastExportCSV = text or ""
		output:SetText(module._lastExportCSV)
		output:SetCursorPosition(0)
		output:HighlightText()
		if output.SetFocus then
			output:SetFocus()
		end

		local scroll = refs.outputScroll
		if scroll and scroll.UpdateScrollChildRect then
			scroll:UpdateScrollChildRect()
		end
		if scroll and scroll.SetVerticalScroll then
			scroll:SetVerticalScroll(0)
		end
	end

	local function adjustExportScrollBar(refs)
		local scroll = refs and refs.outputScroll
		if not (scroll and scroll.GetName) then
			return
		end

		local scrollName = scroll:GetName()
		local scrollBar = scroll.ScrollBar or _G[scrollName .. "ScrollBar"]
		if not scrollBar then
			return
		end

		local upButton = _G[scrollBar:GetName() .. "ScrollUpButton"]
		local downButton = _G[scrollBar:GetName() .. "ScrollDownButton"]
		if upButton then
			upButton:ClearAllPoints()
			upButton:SetPoint("TOP", scroll, "TOPRIGHT", 10, -4)
		end
		if downButton then
			downButton:ClearAllPoints()
			downButton:SetPoint("BOTTOM", scroll, "BOTTOMRIGHT", 10, 8)
		end

		scrollBar:ClearAllPoints()
		scrollBar:SetPoint("TOP", scroll, "TOPRIGHT", 10, -20)
		scrollBar:SetPoint("BOTTOM", scroll, "BOTTOMRIGHT", 10, 24)
	end

	local function refreshExportFrame(mode)
		local refs = getExportFrameRefs()
		if not refs then
			return false
		end

		local raid = module._needRaid()
		if not raid then
			addon:error(L.ErrLoggerInvalidRaid)
			return false
		end

		mode = mode or module._loggerExportMode or "loot"
		module._loggerExportMode = mode

		local csv, errCode = Export:GetCSV(mode, raid, getExportContext())
		if errCode then
			addon:error((L.ErrLoggerExportFailed):format(tostring(errCode)))
			return false
		end

		setExportModeButtonState(refs, mode)
		adjustExportScrollBar(refs)
		setExportText(refs, csv)
		return true
	end

	local function bindExportFrame()
		local refs = getExportFrameRefs()
		if not refs or refs.frame._RMABound then
			return refs
		end

		SetFrameTitle(refs.frame, L.StrLoggerExportTitle)
		EnableDrag(refs.frame)

		if refs.hint then
			refs.hint:SetText(L.StrLoggerExportHint)
		end
		if refs.lootBtn then
			refs.lootBtn:SetText(L.BtnLoggerExportLootCSV)
			SetScriptSafely(refs.lootBtn, "OnClick", function()
				refreshExportFrame("loot")
			end)
		end
		if refs.raidAttendanceBtn then
			refs.raidAttendanceBtn:SetText(L.BtnLoggerExportRaidAttendanceCSV)
			SetScriptSafely(refs.raidAttendanceBtn, "OnClick", function()
				refreshExportFrame("raidAttendance")
			end)
		end
		if refs.output and refs.output.SetTextInsets then
			refs.output:SetTextInsets(8, 8, 8, 8)
		end
		if refs.output and refs.output.SetWordWrap then
			refs.output:SetWordWrap(true)
		end
		if refs.output then
			SetScriptSafely(refs.output, "OnTextChanged", function(self, userInput)
				if userInput then
					self:SetText(module._lastExportCSV or "")
					self:SetCursorPosition(0)
					self:HighlightText()
				end
			end)
		end
		adjustExportScrollBar(refs)
		if refs.closeBtn then
			refs.closeBtn:SetText(L.BtnClose)
			SetScriptSafely(refs.closeBtn, "OnClick", function()
				refs.frame:Hide()
			end)
		end

		refs.frame._RMABound = true
		return refs
	end

	showLoggerExportFrame = function()
		local raid = module._needRaid()
		if not raid then
			addon:error(L.ErrLoggerInvalidRaid)
			return false
		end

		local refs = bindExportFrame()
		if not (refs and refs.frame) then
			return false
		end

		module._loggerExportMode = "loot"
		if not refreshExportFrame(module._loggerExportMode) then
			return false
		end
		refs.frame:Show()
		return true
	end

	module._resetSelections = function()
		clearSelections()
	end

	local function loadLoggerFrame(frame)
		uiState.FrameName = BindModuleFrame(module, frame, {
			enableDrag = true,
			hookOnShow = function()
				if not module.selectedRaid then
					module._SetSelectedRaid(Database.GetCurrentRaid())
				end
				clearSelections()
				refreshLoggerTabLayout()
				triggerSelectionEvent(module, "selectedRaid", "ui")
			end,
			hookOnHide = function()
				module._SetSelectedRaid(Database.GetCurrentRaid())
				clearSelections()
			end,
		}) or uiState.FrameName
		uiState.Loaded = uiState.FrameName ~= nil
		if not uiState.Loaded then
			return
		end
		SetFrameTitle(uiState.FrameName, L.StrLootHistory)
	end

	local function refreshLoggerFrame()
		local frame = getFrame()
		if not frame then
			return
		end
		if not module.selectedRaid then
			module._SetSelectedRaid(Database.GetCurrentRaid())
		end
		clearSelections()
		refreshLoggerTabLayout()
		triggerSelectionEvent(module, "selectedRaid", "ui")
	end

	local function BindHandlers(_, _frame, refs)
		local onLoadPairs = {
			{ moduleRef = module.Raids, frameRef = refs.raids },
			{ moduleRef = module.Loot, frameRef = refs.loot },
		}
		for i = 1, #onLoadPairs do
			local pair = onLoadPairs[i]
			ensureSubmoduleOnLoad(pair.moduleRef, pair.frameRef)
		end
		Rows.ApplyLoggerSkin(module._loggerPanelNames)
		refreshLoggerTabLayout()
	end

	local function OnLoadFrame(frame)
		loadLoggerFrame(frame)
		return uiState.FrameName
	end

	UI.Scaffold.DefineModule({
		module = module,
		getFrame = getFrame,
		acquireRefs = uiState.AcquireRefs,
		bind = BindHandlers,
		onLoad = OnLoadFrame,
		refresh = function()
			refreshLoggerFrame()
		end,
	})

	local baseToggleLoggerFrame = module.Toggle
	module._toggleLootHistoryView = function()
		module.activeTab = "loot"
		if baseToggleLoggerFrame then
			return baseToggleLoggerFrame(module)
		end
	end

	-- Selectors
	module._selectRaid = function(btn, button, opts)
		if button and button ~= "LeftButton" then
			return
		end
		local raidNid = btn and btn.GetID and btn:GetID()
		if not raidNid then
			return
		end
		local raidIndex = raidNid and Database.GetRaidIdByNid(raidNid) or nil
		if not raidIndex then
			return
		end

		local modifierScope = (opts and opts.modifierScope) or module._msRaidScopeHistory or MS_SCOPE_RAID_HISTORY
		local isMulti, isRange = UI.Selection.ResolveModifiers(modifierScope, opts)
		local prevFocus = module.selectedRaid

		local ordered = opts and opts.ordered or nil
		if not ordered then
			ordered = module.Raids and module.Raids._ctrl and module.Raids._ctrl.data or nil
		end
		local action, count = applyFocusedMultiSelect({
			id = raidNid,
			context = (opts and opts.context) or MS_CTX_RAID,
			ordered = ordered,
			isMulti = isMulti,
			isRange = isRange,
			allowDeselect = opts and opts.allowDeselect,
			setFocus = module._SetSelectedRaid,
			mapSelectedToFocus = function(nid)
				return nid and Database.GetRaidIdByNid(nid) or nil
			end,
			isClickedFocused = function(clickedNid)
				local selectedRaidNid = module.selectedRaid and Database.GetRaidNidById(module.selectedRaid) or nil
				return selectedRaidNid == clickedNid
			end,
		})

		if Options.IsDebugEnabled() and addon.debug then
			addon:debug(
				(Diag.D.LogLoggerSelectClickRaid):format(
					tostring(raidNid),
					isMulti and 1 or 0,
					isRange and 1 or 0,
					tostring(action),
					tonumber(count) or 0,
					tostring(module.selectedRaid)
				)
			)
		end

		-- If the focused raid changed, reset dependent selections (boss/player/loot panels).
		if prevFocus ~= module.selectedRaid then
			clearSelections()
		end

		triggerSelectionEvent(module, "selectedRaid", "ui")
	end

	-- Item: left select, right menu
	do
		local quickRollTypes = {
			{ rollType = rollTypes.MAINSPEC, label = L.BtnMS, suffix = "MS" },
			{ rollType = rollTypes.OFFSPEC, label = L.BtnOS, suffix = "OS" },
			{ rollType = rollTypes.RESERVED, label = L.BtnSR, suffix = "SR" },
			{ rollType = rollTypes.FREE, label = L.BtnFree, suffix = "Free" },
			{ rollType = rollTypes.BANK, label = L.BtnBank, suffix = "Bank" },
			{ rollType = rollTypes.DISENCHANT, label = L.BtnDisenchant, suffix = "DE" },
			{ rollType = rollTypes.HOLD, label = L.BtnHold, suffix = "Hold" },
		}
		local ROLLTYPE_POPUP_KEY = "RMALOGGER_ITEM_EDIT_ROLL_PICK"
		local ROLLTYPE_PICKER_FRAME = "RMALootHistoryRollTypePickerFrame"
		local ROLLTYPE_BUTTON_MIN_WIDTH = 42
		local ROLLTYPE_BUTTON_MAX_WIDTH = 54
		local ROLLTYPE_BUTTON_HEIGHT = 22
		local ROLLTYPE_BUTTON_SPACING = 3
		local ROLLTYPE_PICKER_SIDE_PADDING = 24
		local ROLLTYPE_PICKER_TOP_OFFSET = 8
		local ROLLTYPE_POPUP_EXTRA_HEIGHT = 16

		local function applySelectedLootRollType(lootNid, rollType)
			if not lootNid then
				addon:error(L.ErrLoggerInvalidItem)
				return
			end
			setLootEntry(lootNid, nil, rollType, nil, "LOGGER_EDIT_ROLLTYPE")
		end

		local function getItemMenuFrame()
			return _G.RMALootHistoryItemMenuFrame
				or CreateFrame("Frame", "RMALootHistoryItemMenuFrame", UIParent, "UIDropDownMenuTemplate")
		end

		local function ensureRollTypeInsertedFrame()
			local frame = _G[ROLLTYPE_PICKER_FRAME]
			if not frame then
				return nil
			end

			if frame._buttons and frame._initialized then
				return frame
			end

			frame._buttons = frame._buttons or {}
			local frameName = frame.GetName and frame:GetName() or ROLLTYPE_PICKER_FRAME
			local count = #quickRollTypes
			for i = 1, count do
				local entry = quickRollTypes[i]
				local rollType = entry.rollType
				local button = _G[frameName .. entry.suffix]
				if button then
					button:SetText(entry.label)
					SetScriptSafely(button, "OnClick", function(btn)
						local parent = btn and btn.GetParent and btn:GetParent() or nil
						applySelectedLootRollType(parent and parent.lootNid, rollType)
						HidePopup(ROLLTYPE_POPUP_KEY)
					end)
				end
				frame._buttons[i] = button
			end
			frame._initialized = true
			return frame
		end

		local function layoutRollTypeInsertedFrame(popup, picker)
			local count = #quickRollTypes
			local spacing = ROLLTYPE_BUTTON_SPACING
			local sidePadding = ROLLTYPE_PICKER_SIDE_PADDING
			local popupWidth = popup:GetWidth()

			local available = popupWidth - (sidePadding * 2) - (spacing * (count - 1))
			local buttonWidth = math.floor(available / count)
			if buttonWidth < ROLLTYPE_BUTTON_MIN_WIDTH then
				buttonWidth = ROLLTYPE_BUTTON_MIN_WIDTH
				local minPopupWidth = (buttonWidth * count) + (spacing * (count - 1)) + (sidePadding * 2)
				if popupWidth < minPopupWidth then
					popup:SetWidth(minPopupWidth)
					popupWidth = popup:GetWidth()
					available = popupWidth - (sidePadding * 2) - (spacing * (count - 1))
					buttonWidth = math.floor(available / count)
				end
			end
			if buttonWidth > ROLLTYPE_BUTTON_MAX_WIDTH then
				buttonWidth = ROLLTYPE_BUTTON_MAX_WIDTH
			end
			if buttonWidth < ROLLTYPE_BUTTON_MIN_WIDTH then
				buttonWidth = ROLLTYPE_BUTTON_MIN_WIDTH
			end

			local rowWidth = (buttonWidth * count) + (spacing * (count - 1))
			picker:SetWidth(rowWidth)
			picker:SetHeight(ROLLTYPE_BUTTON_HEIGHT)

			local prevButton
			for i = 1, count do
				local button = picker._buttons and picker._buttons[i]
				if button then
					button:ClearAllPoints()
					button:SetWidth(buttonWidth)
					button:SetHeight(ROLLTYPE_BUTTON_HEIGHT)
					if i == 1 then
						button:SetPoint("LEFT", picker, "LEFT", 0, 0)
					else
						button:SetPoint("LEFT", prevButton, "RIGHT", spacing, 0)
					end
					prevButton = button
				end
			end
		end

		local function ensureRollTypePopup()
			if IsPopupDefined(ROLLTYPE_POPUP_KEY) then
				return true
			end

			ensureRollTypeInsertedFrame()

			return DefinePopup(ROLLTYPE_POPUP_KEY, {
				text = L.StrEditItemRollType,
				button1 = L.BtnCancel,
				timeout = 0,
				whileDead = 1,
				hideOnEscape = 1,
				wide = 1,
				preferredIndex = 3,
				OnShow = function(self, data)
					local itemId = data and data.itemId or module.selectedItem
					local picker = ensureRollTypeInsertedFrame()
					if not picker then
						return
					end
					self._RMAExtraHeight = picker:GetHeight() + ROLLTYPE_POPUP_EXTRA_HEIGHT

					if not self._RMASavedSetHeight then
						self._RMASavedSetHeight = self.SetHeight
						self.SetHeight = function(dialog, h)
							local base = dialog._RMASavedSetHeight
							if not base then
								return
							end
							local extra = dialog._RMAExtraHeight or 0
							return base(dialog, h + extra)
						end
					end

					if self.text then
						self.text:SetWidth(self:GetWidth() - 36)
					end
					ResizePopup(self, self.which)
					layoutRollTypeInsertedFrame(self, picker)

					picker.lootNid = itemId
					picker:SetParent(self)
					picker:ClearAllPoints()
					if self.text then
						picker:SetPoint("TOP", self.text, "BOTTOM", 0, -ROLLTYPE_PICKER_TOP_OFFSET)
					else
						picker:SetPoint("TOP", self, "TOP", 0, -44)
					end
					picker:SetFrameLevel((self:GetFrameLevel() or 1) + 1)
					picker:Show()
				end,
				OnHide = function(self)
					if self._RMASavedSetHeight then
						self.SetHeight = self._RMASavedSetHeight
						self._RMASavedSetHeight = nil
					end
					self._RMAExtraHeight = nil
					local picker = _G[ROLLTYPE_PICKER_FRAME]
					if picker then
						picker.lootNid = nil
						picker:Hide()
						picker:SetParent(UIParent)
					end
				end,
			})
		end

		local function openItemRollTypePopup()
			local lootNid = module.selectedItem
			if not lootNid then
				addon:error(L.ErrLoggerInvalidItem)
				return
			end

			if not ensureRollTypePopup() then
				return
			end

			CloseDropDownMenus()
			ShowPopup(ROLLTYPE_POPUP_KEY, nil, nil, {
				itemId = lootNid,
			})
		end

		local openItemWinnerPopup
		local openItemRollValuePopup

		local function openItemMenu()
			local f = getItemMenuFrame()

			EasyMenu({
				{
					text = L.StrEditItemLooter,
					notCheckable = 1,
					func = openItemWinnerPopup,
				},
				{
					text = L.StrEditItemRollType,
					notCheckable = 1,
					func = openItemRollTypePopup,
				},
				{
					text = L.StrEditItemRollValue,
					notCheckable = 1,
					func = openItemRollValuePopup,
				},
			}, f, "cursor", 0, 0, "MENU")
		end

		module._selectItem = function(btn, button)
			local id = btn and btn.GetID and btn:GetID()
			if not id then
				return
			end

			-- NOTE: Multi-select is maintained in MultiSelect module (context = MS_CTX_LOOT).
			if button == "LeftButton" then
				local isMulti, isRange = UI.Selection.ResolveModifiers(MS_SCOPE_LOOT)

				local ordered = module.Loot and module.Loot._ctrl and module.Loot._ctrl.data or nil
				local action, count =
					applyModuleFocusedMultiSelect(id, MS_CTX_LOOT, ordered, isMulti, isRange, "selectedItem")

				if Options.IsDebugEnabled() and addon.debug then
					addon:debug(
						(Diag.D.LogLoggerSelectClickLoot):format(
							tostring(id),
							isMulti and 1 or 0,
							isRange and 1 or 0,
							tostring(action),
							tonumber(count) or 0,
							tostring(module.selectedItem)
						)
					)
				end

				triggerSelectionEvent(module, "selectedItem")
			elseif button == "RightButton" then
				-- Context menu works on a single focused row.
				local action, count = UI.Selection.Toggle(MS_CTX_LOOT, id, false)
				module.selectedItem = id

				if Options.IsDebugEnabled() and addon.debug then
					addon:debug(
						(Diag.D.LogLoggerSelectClickContextMenu):format(
							tostring(id),
							tostring(action),
							tonumber(count) or 0
						)
					)
				end

				triggerSelectionEvent(module, "selectedItem")
				openItemMenu()
			end
		end

		-- Keep row hover neutral; item tooltip is bound to icon hover only.
		module._onLootRowEnter = function(_row)
			-- No-op.
		end

		module._onLootRowLeave = function(_row)
			-- No-op.
		end

		local function validateRollValue(_, text)
			local ok, value = isValidRollValue(text)
			if not ok then
				addon:error(L.ErrLoggerInvalidRollValue)
				return false
			end
			return true, value
		end

		openItemWinnerPopup = function()
			ShowEditBoxPopup("RMALOGGER_ITEM_EDIT_WINNER", L.StrEditItemLooterHelp, function(self, text)
				local winner, err = Actions:ResolveLootEditWinner(self.raidId, self.lootNid, text)
				if not winner then
					addon:error(err or L.ErrLoggerWinnerEmpty)
					return
				end

				setLootEntry(self.lootNid, winner, nil, nil, "LOGGER_EDIT_WINNER")
			end, function(self)
				self.raidId = module.selectedRaid
				self.lootNid = module.selectedItem
			end)
		end

		openItemRollValuePopup = function()
			ShowEditBoxPopup("RMALOGGER_ITEM_EDIT_VALUE", L.StrEditItemRollValueHelp, function(self, text)
				setLootEntry(self.lootNid, nil, nil, text, "LOGGER_EDIT_ROLLVALUE")
			end, function(self)
				self.lootNid = module.selectedItem
			end, validateRollValue)
		end
	end
end

-- Shared factory for Logger list controllers with standardized highlight/focus config.
local function makeLoggerList(cfg, selField, msCtxField, hlOpts)
	hlOpts = hlOpts or {}
	local transform = hlOpts.transform
	local debugTag = hlOpts.debugTag or "LoggerSelect"

	-- Logger XML already reserves a right scrollbar column via ScrollFrame anchors.
	-- Keep ListController from subtracting a second right inset in Logger tables.
	if cfg.rightInset == nil then
		cfg.rightInset = 0
	end
	if cfg.drawRow then
		local drawRow = cfg.drawRow
		local rowHeight = cfg.rowHeight
			or (
				cfg.poolTag == "logger-loot" and LoggerLayout.LOGGER_LOOT_ROW_HEIGHT
				or LoggerLayout.LOGGER_COMPACT_ROW_HEIGHT
			)
		cfg.drawRow = function(row, it, visibleIndex)
			Rows.SetLoggerRowIndex(row, visibleIndex)
			if row.SetHeight then
				row:SetHeight(rowHeight)
			end
			drawRow(row, it, visibleIndex)
			return rowHeight
		end
	end

	local function resolve()
		local v = module[selField]
		if v == nil then
			return nil
		end
		return transform and transform(v) or v
	end

	if msCtxField then
		cfg.highlightFn = function(id)
			return UI.Selection.IsSelected(module[msCtxField], id)
		end
		cfg.highlightKey = function()
			return UI.Selection.GetVersion(module[msCtxField])
		end
		cfg.highlightDebugInfo = function()
			return ("ctx=%s selectedCount=%d"):format(
				tostring(module[msCtxField]),
				UI.Selection.GetCount(module[msCtxField])
			)
		end
	else
		cfg.highlightId = resolve
		cfg.highlightDebugInfo = function()
			return ("%s=%s"):format(selField, tostring(resolve()))
		end
	end

	cfg.focusId = resolve
	cfg.focusKey = function()
		return tostring(resolve() or "nil")
	end
	cfg.highlightDebugTag = debugTag
	return UI.Lists.CreateController(cfg)
end

-- Raids list.
do
	module.Raids = module.Raids or {}
	local Raids = module.Raids
	local Store = module.Store
	local View = module.View
	local controller
	local setCurrentRaidFromLogger
	local confirmDeleteSelectedRaids
	controller = makeLoggerList(
		{
			keyName = "RaidsList",
			poolTag = "logger-raids",
			_rowParts = { "ID", "Date", "Zone", "Size" },

			localize = function(n)
				local title = _G[n .. "Title"]
				if title then
					title:SetText(L.StrRaidsList)
				end
				_G[n .. "HeaderNum"]:SetText(L.StrNumber)
				_G[n .. "HeaderDate"]:SetText(L.StrDate)
				_G[n .. "HeaderZone"]:SetText(L.StrZone)
				_G[n .. "HeaderSize"]:SetText(L.StrSize)
				applyRaidListColumnWidths(n)
				_G[n .. "CurrentBtn"]:SetText(L.StrSetCurrent)
				local del = _G[n .. "DeleteBtn"]
				if del then
					del:SetText(L.BtnDelete)
				end
				BindTooltip(_G[n .. "CurrentBtn"], L.StrRaidsCurrentHelp, nil, L.StrRaidCurrentTitle)

				local frame = _G[n]
				if frame and not frame._RMABound then
					SetScriptSafely(_G[n .. "CurrentBtn"], "OnClick", function(self, button)
						setCurrentRaidFromLogger(self, button)
					end)
					SetScriptSafely(_G[n .. "DeleteBtn"], "OnClick", function(self, button)
						confirmDeleteSelectedRaids(self, button)
					end)
					bindRaidSortHeaders(n, Raids)
				end
			end,

			getData = function(out)
				View:FillRaidList(out, "Logger.Raids.GetData")
			end,

			rowName = UI.Lists.MakeIndexedRowName("RaidBtn"),
			rowTmpl = "RMALogRaidRowTemplate",

			drawRow = UI.Lists.CreateRowRenderer(function(row, it)
				if not row._RMABound then
					SetScriptSafely(row, "OnClick", function(self, button)
						module._selectRaid(self, button)
					end)
					row._RMABound = true
				end
				local ui = row._p
				applyRaidRowColumnWidths(ui, "RMALootHistoryRaids")
				ui.ID:SetText(it.seq or it.id)
				ui.Date:SetText(it.dateFmt)
				ui.Zone:SetText(it.zone)
				ui.Size:SetText(it.sizeLabel or it.size)
			end),

			postUpdate = function(n)
				applyRaidListColumnWidths(n)

				local sel = module.selectedRaid
				local raid = sel and Database.EnsureRaidById(sel) or nil
				local count = controller and controller.data and #controller.data or 0

				local canSetCurrent = false
				if sel and raid and sel ~= Database.GetCurrentRaid() then
					-- This button is intended to resolve duplicate raid creation while actively raiding.
					if not addon.IsInRaid() then
						canSetCurrent = false
					elseif Raid:IsRaidExpired(sel) then
						canSetCurrent = false
					else
						local instanceName, instanceType, instanceDiff, _, _, dynDiff, isDyn = GetInstanceInfo()
						if isDyn then
							instanceDiff = instanceDiff + (2 * dynDiff)
						end
						if instanceType == "raid" then
							local raidSize = tonumber(raid.size)
							local groupSize = Raid:GetRaidSize()
							local zoneOk = (not raid.zone) or (raid.zone == instanceName)
							local raidDiff = tonumber(raid.difficulty)
							local curDiff = tonumber(instanceDiff)
							local diffOk = raidDiff and curDiff and (raidDiff == curDiff)
							canSetCurrent = zoneOk and raidSize and (raidSize == groupSize) and diffOk
						end
					end
				end

				UI.Primitives.SetEnabled(_G[n .. "CurrentBtn"], canSetCurrent)

				local ctx = module._msRaidCtx
				local selCount = UI.Selection.GetCount(ctx)
				local canDelete = (selCount and selCount > 0) or false
				if canDelete and Database.GetCurrentRaid() then
					local currentRaidNid = Database.GetRaidNidById(Database.GetCurrentRaid())
					local ids = UI.Selection.GetSelected(ctx)
					for i = 1, #ids do
						if currentRaidNid and tonumber(ids[i]) == tonumber(currentRaidNid) then
							canDelete = false
							break
						end
					end
				end
				local delBtn = _G[n .. "DeleteBtn"]
				UI.Primitives.SetButtonCount(delBtn, L.BtnDelete, selCount)
				UI.Primitives.SetEnabled(delBtn, canDelete)
				module._setPanelTitle(n, getCountTitle(L.StrRaidsList, count))
				module._setFrameHint(n, "EmptyState", count == 0 and L.StrLoggerEmptyRaids or nil)
			end,

			sorters = {
				id = function(a, b, asc)
					return CompareNumbers(a.seq or a.id, b.seq or b.id, asc, 0)
				end,
				date = function(a, b, asc)
					return CompareNumbers(a.date, b.date, asc, 0)
				end,
				zone = function(a, b, asc)
					return compareStrings(a.zone, b.zone, asc)
				end,
				size = function(a, b, asc)
					return CompareNumbers(a.size, b.size, asc, 0)
				end,
			},
		},
		"selectedRaid",
		"_msRaidCtx",
		{
			transform = function(id)
				return Database.GetRaidNidById(id)
			end,
		}
	)

	Raids._ctrl = controller
	UI.Lists.BindController(Raids, controller)

	function setCurrentRaidFromLogger(btn)
		if not btn then
			return
		end
		local sel = module.selectedRaid
		if not sel then
			return
		end
		if module.Actions:SetCurrentRaid(sel) then
			-- Context change: clear dependent selections and redraw all module panels.
			module._SetSelectedRaid(sel)
			module._resetSelections()
			triggerSelectionEvent(module, "selectedRaid", "ui")
		end
	end

	do
		local function deleteRaids()
			local ctx = module._msRaidCtx
			local ids = UI.Selection.GetSelected(ctx)
			if not (ids and #ids > 0) then
				return
			end

			local raidNids = {}
			local seenNids = {}
			for i = 1, #ids do
				local nid = tonumber(ids[i])
				if nid and not seenNids[nid] then
					seenNids[nid] = true
					raidNids[#raidNids + 1] = nid
				end
			end
			if #raidNids == 0 then
				return
			end

			-- Safety: never delete the current raid
			local currentRaidNid = Database.GetRaidNidById(Database.GetCurrentRaid())
			if currentRaidNid then
				for i = 1, #raidNids do
					if tonumber(raidNids[i]) == tonumber(currentRaidNid) then
						return
					end
				end
			end

			local prevFocus = module.selectedRaid
			local prevFocusNid = prevFocus and Database.GetRaidNidById(prevFocus) or nil
			for i = 1, #raidNids do
				module.Actions:DeleteRaidByNid(raidNids[i])
			end

			UI.Selection.EnsureState(ctx)

			local raidStore = Database.GetRaidStoreOrNil("Logger.Raids.DeleteRaids", { "GetAllRaids" })
			local raids = raidStore and raidStore:GetAllRaids() or {}
			local n = #raids
			local newFocus = nil
			if n > 0 then
				newFocus = prevFocusNid and Database.GetRaidIdByNid(prevFocusNid) or nil
				if not newFocus then
					local base = tonumber(prevFocus) or n
					if base > n then
						base = n
					end
					if base < 1 then
						base = 1
					end
					newFocus = base
				end
			end

			module._SetSelectedRaid(newFocus)
			module._resetSelections()
			controller:Dirty()
			triggerSelectionEvent(module, "selectedRaid", "ui")
		end

		function confirmDeleteSelectedRaids(btn)
			local ctx = module._msRaidCtx
			if btn and UI.Selection.GetCount(ctx) > 0 then
				ShowConfirmPopup("RMALOGGER_DELETE_RAID", L.StrConfirmDeleteRaid, deleteRaids)
			end
		end
	end

	RegisterCallback(LoggerEvents.RaidCreate, function(_, num)
		-- Context change: selecting a different raid must clear dependent selections.
		module._SetSelectedRaid(tonumber(num))
		module._resetSelections()
		controller:Dirty()
		triggerSelectionEvent(module, "selectedRaid", "ui")
	end)

	RegisterCallback(LoggerEvents.LoggerSelectRaid, function(_, raidId, reason)
		local raidIdType = type(raidId)
		if raidId ~= nil and raidIdType ~= "number" and raidIdType ~= "string" then
			addon:warn(Diag.W.LogLoggerSelectRaidPayloadInvalid:format(tostring(raidId), tostring(reason)))
			return
		end
		if reason ~= nil and reason ~= "ui" and reason ~= "sync" then
			addon:warn(Diag.W.LogLoggerSelectRaidPayloadInvalid:format(tostring(raidId), tostring(reason)))
			return
		end

		local prevRaid = module.selectedRaid
		module._SetSelectedRaid(raidId)

		if prevRaid ~= module.selectedRaid then
			module._resetSelections()
		end

		if reason == "sync" then
			local raid = module.selectedRaid and Store:GetRaid(module.selectedRaid) or nil
			if raid and Store._InvalidateIndexes then
				Store._InvalidateIndexes(raid)
			end
		end

		if reason == "sync" then
			-- Sync can change raid rows; force data refetch instead of highlight-only refresh.
			controller:Dirty()
		else
			controller:Touch()
		end
	end)

	RegisterCallback(LoggerEvents.RaidRosterDelta, function(_, delta, rosterVersion, raidId)
		local raidIdType = type(raidId)
		if type(delta) ~= "table" then
			return
		end
		if type(rosterVersion) ~= "number" then
			return
		end
		if raidId == nil then
			return
		end
		if raidIdType ~= "number" and raidIdType ~= "string" then
			return
		end
		local loggerOpen = module._isLoggerViewingCurrentRaid()
		local attendanceViewOpen = module._isRaidAttendanceViewingCurrentRaid
		local attendanceRefresh = module._requestAttendanceBoundListsRefresh
		local attendanceOpen = attendanceViewOpen and attendanceViewOpen()
		if loggerOpen then
			module._requestRosterBoundListsRefresh()
		end
		if attendanceOpen and attendanceRefresh then
			attendanceRefresh()
		end
	end)
end

-- Loot list.
do
	module.Loot = module.Loot or {}
	local Loot = module.Loot
	local View = module.View
	local Actions = module.Actions
	local sortLoot
	local showLootTooltip
	local buildSourceTooltipModel
	local confirmDeleteSelectedLootItems

	local function updateSourceHeaderState(frameName)
		local header = frameName and _G[frameName .. "HeaderSource"]
		if not header then
			return
		end

		local canSortSource = module.selectedBoss == nil
		if header.EnableMouse then
			header:EnableMouse(canSortSource)
		end
		if header.SetAlpha then
			header:SetAlpha(canSortSource and 1 or 0.6)
		end
	end

	local controller
	controller = makeLoggerList({
		keyName = "LootList",
		poolTag = "logger-loot",
		_rowParts = {
			"Name",
			"Source",
			"SourceHitBox",
			"Winner",
			"Type",
			"Roll",
			"Time",
			"ItemIconTexture",
			"ItemNormalTexture",
		},

		localize = function(n)
			local title = _G[n .. "Title"]
			if title then
				title:SetText(L.StrRaidLoot)
			end
			_G[n .. "ExportBtn"]:SetText(L.BtnExport)
			_G[n .. "ClearBtn"]:SetText(L.BtnClear)
			_G[n .. "AddBtn"]:SetText(L.BtnAdd)
			_G[n .. "EditBtn"]:SetText(L.BtnEdit)
			_G[n .. "HeaderItem"]:SetText(L.StrItem)
			_G[n .. "HeaderSource"]:SetText(L.StrSource)
			_G[n .. "HeaderWinner"]:SetText(L.StrWinner)
			_G[n .. "HeaderType"]:SetText(L.StrType)
			_G[n .. "HeaderRoll"]:SetText(L.StrRoll)
			_G[n .. "HeaderTime"]:SetText(L.StrTime)
			applyLootListColumnWidths(n)

			_G[n .. "ClearBtn"]:Disable()
			_G[n .. "AddBtn"]:Disable()
			local del = _G[n .. "DeleteBtn"]
			if del then
				del:SetText(L.BtnDelete)
			end
			_G[n .. "EditBtn"]:Disable()
			UI.Primitives.SetEnabled(_G[n .. "ExportBtn"], module.selectedRaid ~= nil)
			updateSourceHeaderState(n)

			local frame = _G[n]
			if frame and not frame._RMABound then
				SetScriptSafely(_G[n .. "ExportBtn"], "OnClick", function()
					showLoggerExportFrame()
				end)
				SetScriptSafely(_G[n .. "DeleteBtn"], "OnClick", function()
					confirmDeleteSelectedLootItems()
				end)
				bindLoggerSortHeaders(n, LOOT_LAYOUT_COLUMNS, {
					Sort = function(_, key)
						sortLoot(key)
					end,
				}, "_RMABound")
				frame._RMABound = true
			end
		end,

		getData = function(out)
			local raid = module._needRaid()
			if not raid then
				return
			end

			View:FillLootList(out, raid, nil, nil)
		end,

		rowName = UI.Lists.MakeIndexedRowName("ItemBtn"),
		rowTmpl = "RMALootHistoryLootRowTemplate",

		drawRow = UI.Lists.CreateRowRenderer(function(row, it)
			local ui = row._p
			applyLootRowColumnWidths(ui, "RMALootHistoryLoot")
			if not row._RMABound then
				if row.RegisterForClicks then
					row:RegisterForClicks("AnyUp")
				end
				SetScriptSafely(row, "OnClick", function(self, button)
					module._selectItem(self, button)
				end)
				SetScriptSafely(row, "OnEnter", function(self)
					module._onLootRowEnter(self)
				end)
				SetScriptSafely(row, "OnLeave", function(self)
					module._onLootRowLeave(self)
				end)
				local itemButton = row.GetName and _G[row:GetName() .. "Item"] or nil
				if itemButton and itemButton.EnableMouse then
					itemButton:EnableMouse(true)
				end
				if itemButton and itemButton.RegisterForClicks then
					itemButton:RegisterForClicks("AnyUp")
				end
				if itemButton then
					itemButton._RMARow = row
					SetScriptSafely(itemButton, "OnClick", function(_, button)
						module._selectItem(row, button)
					end)
					SetScriptSafely(itemButton, "OnEnter", function(self)
						showLootTooltip(self)
					end)
					SetScriptSafely(itemButton, "OnLeave", function()
						HideTooltip()
					end)
				end
				local sourceHitBox = row.GetName and _G[row:GetName() .. "SourceHitBox"] or nil
				if sourceHitBox and sourceHitBox.EnableMouse then
					sourceHitBox:EnableMouse(true)
				end
				if sourceHitBox then
					sourceHitBox._RMARow = row
					BindTooltipModel(sourceHitBox, function(self)
						return buildSourceTooltipModel(self and self._RMARow)
					end, "ANCHOR_CURSOR")
				end

				-- Size the slot background to the button and the icon inset to reveal it.
				if ui.ItemNormalTexture and ui.ItemNormalTexture.SetSize then
					ui.ItemNormalTexture:SetSize(26, 26)
				end
				if ui.ItemIconTexture and ui.ItemIconTexture.SetSize then
					ui.ItemIconTexture:SetSize(20, 20)
				end
				row._RMABound = true
			end

			local itemButton = row.GetName and _G[row:GetName() .. "Item"] or nil
			if itemButton then
				itemButton._RMARow = row
				if itemButton.EnableMouse then
					itemButton:EnableMouse(true)
				end
			end
			local sourceHitBox = row.GetName and _G[row:GetName() .. "SourceHitBox"] or nil
			if sourceHitBox then
				sourceHitBox._RMARow = row
			end

			-- Preserve a tooltip-ready hyperlink on the pooled row.
			row._itemLink = it.itemLink
			local itemId = tonumber(it.itemId)
			row._itemTooltipLink = it.itemLink or (itemId and itemId > 0 and ("item:" .. itemId) or nil)
			local nameText = it.itemLink or it.itemName or ("[Item " .. (it.itemId or "?") .. "]")
			if it.itemLink then
				ui.Name:SetText(nameText)
			else
				ui.Name:SetText(
					addon.WrapTextInColorCode(nameText, Colors.NormalizeHexColor(itemColors[(it.itemRarity or 1) + 1]))
				)
			end

			local selectedBoss = module.selectedBoss
			if selectedBoss and tonumber(it.bossNid) == tonumber(selectedBoss) then
				ui.Source:SetText("")
				row._sourceCandidates = nil
			else
				ui.Source:SetText(it.sourceName or "")
				row._sourceCandidates = it.sourceCandidates
			end
			row._sourceKind = it.sourceKind
			row._sourceName = it.sourceName
			row._sourceKey = it.sourceKey
			ui.Source:SetVertexColor(0.86, 0.82, 0.72)

			local winnerClass = it.looterClass or Raid:GetPlayerClass(it.looter)
			local r, g, b = Colors.GetClassColor(winnerClass)
			ui.Winner:SetText(it.looter or "")
			ui.Winner:SetVertexColor(r, g, b)

			local rt = LoggerHelpers.NormalizeRollType(it.rollType)
			it.rollType = rt
			ui.Type:SetText((rt and lootTypesColored[rt]) or "")
			ui.Roll:SetText(LoggerHelpers.FormatRollValueForRow(it.rollValue))
			ui.Roll:SetVertexColor(0.95, 0.95, 0.95)
			ui.Time:SetText(it.timeFmt)
			ui.Time:SetVertexColor(0.86, 0.82, 0.72)

			local icon = it.itemTexture
			if not icon and it.itemId then
				icon = GetItemIcon(it.itemId)
			end
			if not icon then
				icon = C.RESERVES_ITEM_FALLBACK_ICON
			end
			ui.ItemIconTexture:SetTexture(icon)
			ui.ItemIconTexture:SetTexCoord(0.08, 0.92, 0.08, 0.92)
		end),

		postUpdate = function(n)
			applyLootListColumnWidths(n)
			updateSourceHeaderState(n)

			local lootSelCount = UI.Selection.GetCount(module._msLootCtx)
			local exportBtn = _G[n .. "ExportBtn"]
			local delBtn = _G[n .. "DeleteBtn"]
			local count = controller and controller.data and #controller.data or 0
			UI.Primitives.SetEnabled(exportBtn, module.selectedRaid ~= nil)
			UI.Primitives.SetButtonCount(delBtn, L.BtnDelete, lootSelCount)
			UI.Primitives.SetEnabled(delBtn, (lootSelCount or 0) > 0)
			module._setPanelTitle(n, getCountContextTitle(L.StrRaidLoot, count, getLootPanelContextLabel(module), nil))
			module._setFrameHint(n, "EmptyState", getLootEmptyStateText(count, module))
		end,

		sorters = {
			id = function(a, b, asc)
				return compareLootTie(a, b, asc)
			end,
			source = function(a, b, asc)
				local aSource = strlower(tostring((a and a.sourceName) or ""))
				local bSource = strlower(tostring((b and b.sourceName) or ""))
				if aSource ~= bSource then
					return CompareValues(aSource, bSource, asc)
				end
				return compareLootTie(a, b, asc)
			end,
			winner = function(a, b, asc)
				local aWinner = strlower(tostring((a and a.looter) or ""))
				local bWinner = strlower(tostring((b and b.looter) or ""))
				if aWinner ~= bWinner then
					return CompareValues(aWinner, bWinner, asc)
				end
				return compareLootTie(a, b, asc)
			end,
			type = function(a, b, asc)
				local aType = LoggerHelpers.GetRollTypeSortValue(a and a.rollType)
				local bType = LoggerHelpers.GetRollTypeSortValue(b and b.rollType)
				if aType ~= bType then
					return CompareValues(aType, bType, asc)
				end
				return compareLootTie(a, b, asc)
			end,
			roll = function(a, b, asc)
				local aRoll = LoggerHelpers.GetRollSortValue(a and a.rollValue)
				local bRoll = LoggerHelpers.GetRollSortValue(b and b.rollValue)
				if aRoll ~= bRoll then
					return CompareValues(aRoll, bRoll, asc)
				end
				return compareLootTie(a, b, asc)
			end,
			time = function(a, b, asc)
				local aTime = tonumber(a and a.time) or 0
				local bTime = tonumber(b and b.time) or 0
				if aTime ~= bTime then
					return CompareValues(aTime, bTime, asc)
				end
				return compareLootTie(a, b, asc)
			end,
		},
	}, "selectedItem", "_msLootCtx")

	Loot._ctrl = controller
	UI.Lists.BindController(Loot, controller)

	sortLoot = function(key)
		if key == "source" and module.selectedBoss then
			return
		end
		controller:Sort(key)
	end

	showLootTooltip = function(widget)
		if not widget then
			return
		end

		local row = widget._RMARow
		if not row then
			row = widget
			-- Climb parents until we find the pooled row carrying tooltip data.
			while row and not (row._itemTooltipLink or row._itemLink) do
				row = row.GetParent and row:GetParent() or nil
			end
		end
		if not row then
			return
		end

		local link = row._itemTooltipLink or row._itemLink
		if not link then
			return
		end

		ShowItemTooltip(widget, link, nil, "ANCHOR_CURSOR")
	end

	buildSourceTooltipModel = function(row)
		if not row then
			return nil
		end

		local candidates = row._sourceCandidates
		if type(candidates) ~= "table" or #candidates == 0 then
			return nil
		end

		local lines = {}
		for i = 1, #candidates do
			local candidate = candidates[i]
			local name = candidate and (candidate.name or candidate.npcName)
			if name and name ~= "" then
				lines[#lines + 1] = name
			end
		end
		if #lines == 0 then
			return nil
		end

		return {
			title = L.StrLoggerSharedSource or "Shared",
			titleColor = { 1, 0.82, 0 },
			heading = L.StrLoggerSharedSourceTooltipSources or "Possible sources:",
			headingColor = { 0.86, 0.82, 0.72 },
			lineColor = { 1, 1, 1 },
			lines = lines,
			anchor = "ANCHOR_CURSOR",
		}
	end

	do
		local function deleteItem()
			module._runWithSelectedRaid(function(_, rID)
				local ctx = module._msLootCtx
				local selected = UI.Selection.GetSelected(ctx)
				if not selected or #selected == 0 then
					return
				end

				local removed = Actions:DeleteLootMany(rID, selected, getActionCommitOpts())
				if removed > 0 then
					UI.Selection.EnsureState(ctx)
					module.selectedItem = nil
					triggerSelectionEvent(module, "selectedItem")

					if Options.IsDebugEnabled() and addon.debug then
						addon:debug((Diag.D.LogLoggerSelectDeleteItems):format(removed))
					end
				end
			end)
		end

		confirmDeleteSelectedLootItems = function()
			if UI.Selection.GetCount(module._msLootCtx) > 0 then
				ShowConfirmPopup("RMALOGGER_DELETE_ITEM", L.StrConfirmDeleteItem, deleteItem)
			end
		end
	end

	setLootEntry = function(lootNid, looter, rollType, rollValue, source, raidIDOverride)
		local currentRaid = nil
		if not raidIDOverride then
			currentRaid = Database.GetCurrentRaid()
		end
		local raidID = Actions:ResolveLootEditRaidId(source, module.selectedRaid, currentRaid, raidIDOverride)
		local ok = Actions:SetLootEntry(raidID, lootNid, looter, rollType, rollValue, source)
		if ok then
			controller:Dirty()
		end
		return ok
	end

	RegisterCallback(LoggerEvents.LoggerLootLogRequest, function(_, request)
		if type(request) ~= "table" then
			addon:error(Diag.E.LogLoggerLootLogRequestPayloadInvalid:format(type(request)))
			return
		end
		local raidId = request.raidId or request.raidID
		local lootNid = request.lootNid or request.itemID
		request.ok = setLootEntry(lootNid, request.looter, request.rollType, request.rollValue, request.source, raidId)
			== true
	end)

	local lootUiRefreshDebounceSeconds = 0.10

	local function reset()
		controller:Dirty()
	end

	local function requestLootRefresh(_, raidId)
		local selectedRaid = tonumber(module.selectedRaid)
		local eventRaid = tonumber(raidId)
		if eventRaid and selectedRaid and eventRaid ~= selectedRaid then
			return
		end

		if module._lootUiHandle then
			return
		end
		module._lootUiHandle = module:ScheduleTimer(function()
			module._lootUiHandle = nil
			controller:Dirty()
		end, lootUiRefreshDebounceSeconds)
	end

	local resetEvents = {
		LoggerEvents.LoggerSelectRaid,
		LoggerEvents.LoggerSelectBoss,
		LoggerEvents.LoggerSelectPlayer,
		LoggerEvents.LoggerSelectBossPlayer,
	}
	for i = 1, #resetEvents do
		RegisterCallback(resetEvents[i], reset)
	end
	RegisterCallback(LoggerEvents.RaidLootUpdate, requestLootRefresh)
	RegisterCallback(LoggerEvents.LoggerSelectItem, function()
		controller:Touch()
	end)
end

-- Dedicated Raid Attendance frame.
local function initializeRaidAttendanceFrame()
	local ATTENDANCE_FRAME_NAME = "RMARaidAttendance"
	local ATTENDANCE_RAIDS_FRAME = "RMARaidAttendanceRaids"
	local ATTENDANCE_PLAYERS_FRAME = "RMARaidAttendanceRaidAttendees"

	local getAttendanceFrame = MakeFrameGetter(ATTENDANCE_FRAME_NAME)
	local Store = module.Store
	local View = module.View
	local Actions = module.Actions
	local attendanceUi = module._attendanceUi or {
		Loaded = false,
		Bound = false,
		FrameName = nil,
	}
	module._attendanceUi = attendanceUi

	module.attendanceSelectedRaid = module.attendanceSelectedRaid or nil
	module.attendanceSelectedPlayer = module.attendanceSelectedPlayer or nil

	local attendanceRaidsController
	local attendancePlayersController
	local updateRaidAttendanceFromRoster
	local deleteSelectedRaidAttendancePlayer

	local function getAttendanceRaid()
		local raidId = module.attendanceSelectedRaid
		if not raidId then
			return nil
		end
		return Store:GetRaid(raidId), raidId
	end

	local function markAttendanceListsDirty()
		if attendanceRaidsController then
			attendanceRaidsController:Dirty()
		end
		if attendancePlayersController then
			attendancePlayersController:Dirty()
		end
	end

	local function touchAttendanceSelectionLists()
		if attendanceRaidsController then
			attendanceRaidsController:Touch()
		end
		if attendancePlayersController then
			attendancePlayersController:Touch()
		end
	end

	local function setAttendanceSelectedRaid(raidId)
		module.attendanceSelectedRaid = raidId and (tonumber(raidId) or raidId) or nil
		module.attendanceSelectedPlayer = nil
		touchAttendanceSelectionLists()
	end

	local function selectAttendanceRaid(btn, button)
		if button and button ~= "LeftButton" then
			return
		end
		local raidNid = btn and btn.GetID and btn:GetID()
		local raidId = raidNid and Database.GetRaidIdByNid(raidNid) or nil
		setAttendanceSelectedRaid(raidId)
	end

	local function selectAttendancePlayer(btn, button)
		if button and button ~= "LeftButton" then
			return
		end
		local playerNid = btn and btn.GetID and btn:GetID()
		module.attendanceSelectedPlayer = playerNid and (tonumber(playerNid) or playerNid) or nil
		if attendancePlayersController then
			attendancePlayersController:Touch()
		end
	end

	local function setAttendancePanelVisible(frame, visible)
		if frame then
			UI.Primitives.SetShown(frame, visible)
		end
	end

	local function refreshRaidAttendanceLayout()
		local refs = attendanceUi.refs or {}
		local history = refs.history
		setAttendancePanelVisible(refs.raids, true)
		setAttendancePanelVisible(refs.raidAttendees, true)

		placePanel(refs.raids, "TOPLEFT", history, "TOPLEFT", 0, 0, 335, 430)
		placePanel(refs.raidAttendees, "TOPLEFT", refs.raids, "TOPRIGHT", 7, 0, 607, 430)

		applyRaidListColumnWidths(ATTENDANCE_RAIDS_FRAME)
		applyAttendanceListColumnWidths(ATTENDANCE_PLAYERS_FRAME)
	end

	module._isRaidAttendanceViewingCurrentRaid = function()
		local frame = getAttendanceFrame()
		if not (frame and frame.IsShown and frame:IsShown()) then
			return false
		end
		local currentRaid = Database.GetCurrentRaid()
		if not (currentRaid and module.attendanceSelectedRaid) then
			return false
		end
		return tonumber(module.attendanceSelectedRaid) == tonumber(currentRaid)
	end

	module._requestAttendanceBoundListsRefresh = function()
		if module._attendanceUiHandle then
			module:CancelTimer(module._attendanceUiHandle)
			module._attendanceUiHandle = nil
		end
		module._attendanceUiHandle = module:ScheduleTimer(function()
			module._attendanceUiHandle = nil
			if not module._isRaidAttendanceViewingCurrentRaid() then
				return
			end
			markAttendanceListsDirty()
		end, 0.25)
	end

	attendanceRaidsController = makeLoggerList(
		{
			keyName = "RaidAttendanceRaidsList",
			poolTag = "logger-attendance-raids",
			_rowParts = { "ID", "Date", "Zone", "Size" },

			localize = function(n)
				module._setPanelTitle(n, L.StrRaidsList)
				_G[n .. "HeaderNum"]:SetText(L.StrNumber)
				_G[n .. "HeaderDate"]:SetText(L.StrDate)
				_G[n .. "HeaderZone"]:SetText(L.StrZone)
				_G[n .. "HeaderSize"]:SetText(L.StrSize)
				UI.Primitives.SetShown(_G[n .. "CurrentBtn"], false)
				UI.Primitives.SetShown(_G[n .. "DeleteBtn"], false)
				applyRaidListColumnWidths(n)
				bindRaidSortHeaders(n, module.AttendanceRaids)
			end,

			getData = function(out)
				View:FillRaidList(out, "Logger.Attendance.Raids.GetData")
			end,

			rowName = UI.Lists.MakeIndexedRowName("RaidBtn"),
			rowTmpl = "RMALogRaidRowTemplate",

			drawRow = UI.Lists.CreateRowRenderer(function(row, it)
				if not row._RMAAttendanceBound then
					SetScriptSafely(row, "OnClick", function(self, button)
						selectAttendanceRaid(self, button)
					end)
					row._RMAAttendanceBound = true
				end
				local ui = row._p
				applyRaidRowColumnWidths(ui, ATTENDANCE_RAIDS_FRAME)
				ui.ID:SetText(it.seq or it.id)
				ui.Date:SetText(it.dateFmt)
				ui.Zone:SetText(it.zone)
				ui.Size:SetText(it.sizeLabel or it.size)
			end),

			postUpdate = function(n)
				applyRaidListColumnWidths(n)
				local count = 0
				if attendanceRaidsController and attendanceRaidsController.data then
					count = #attendanceRaidsController.data
				end
				module._setPanelTitle(n, getCountTitle(L.StrRaidsList, count))
				module._setFrameHint(n, "EmptyState", count == 0 and L.StrLoggerEmptyRaids or nil)
			end,

			sorters = {
				id = function(a, b, asc)
					return CompareNumbers(a.seq or a.id, b.seq or b.id, asc, 0)
				end,
				date = function(a, b, asc)
					return CompareNumbers(a.date, b.date, asc, 0)
				end,
				zone = function(a, b, asc)
					return compareStrings(a.zone, b.zone, asc)
				end,
				size = function(a, b, asc)
					return CompareNumbers(a.size, b.size, asc, 0)
				end,
			},
		},
		"attendanceSelectedRaid",
		nil,
		{
			transform = function(id)
				return Database.GetRaidNidById(id)
			end,
			debugTag = "RaidAttendanceSelectRaid",
		}
	)

	module.AttendanceRaids = module.AttendanceRaids or {}
	UI.Lists.BindController(module.AttendanceRaids, attendanceRaidsController)

	attendancePlayersController = makeLoggerList({
		keyName = "RaidAttendancePlayersList",
		poolTag = "logger-attendance-players",
		_rowParts = { "Name", "Join", "Leave", "Ilvl", "Spec", "InspectStatus" },

		localize = function(n)
			module._setPanelTitle(n, L.StrRaidAttendees)
			_G[n .. "HeaderName"]:SetText(L.StrName)
			_G[n .. "HeaderJoin"]:SetText(L.StrJoin)
			_G[n .. "HeaderLeave"]:SetText(L.StrLeave)
			_G[n .. "HeaderIlvl"]:SetText(L.StrIlvl)
			_G[n .. "HeaderSpec"]:SetText(L.StrSpec)
			_G[n .. "HeaderInspect"]:SetText(L.StrInspectItems)
			applyAttendanceListColumnWidths(n)
			if _G[n .. "AddBtn"] then
				_G[n .. "AddBtn"]:SetText(L.BtnUpdate)
				SetScriptSafely(_G[n .. "AddBtn"], "OnClick", function()
					updateRaidAttendanceFromRoster()
				end)
			end
			if _G[n .. "DeleteBtn"] then
				_G[n .. "DeleteBtn"]:SetText(L.BtnDelete)
				SetScriptSafely(_G[n .. "DeleteBtn"], "OnClick", function()
					deleteSelectedRaidAttendancePlayer()
				end)
			end
			local forceBtn = _G[n .. "ForceInspectBtn"]
			if forceBtn then
				forceBtn:SetText(L.BtnForceInspect)
				SetScriptSafely(forceBtn, "OnClick", function()
					local selectedRaid = module.attendanceSelectedRaid
					local selectedPlayer = module.attendanceSelectedPlayer
					if not (selectedRaid and selectedPlayer) then
						return
					end
					local currentRaid = Database.GetCurrentRaid()
					if not (currentRaid and tonumber(currentRaid) == tonumber(selectedRaid)) then
						return
					end
					ForceInspectPlayer(EquipInspect, selectedRaid, selectedPlayer)
					if attendancePlayersController then
						attendancePlayersController:Dirty()
					end
				end)
			end

			local frame = _G[n]
			if frame and not frame._RMAAttendanceBound then
				bindLoggerSortHeaders(
					n,
					ATTENDANCE_INSPECT_LAYOUT_COLUMNS,
					attendancePlayersController,
					"_RMAAttendanceBound"
				)
			end
		end,

		getData = function(out)
			local raid = getAttendanceRaid()
			if not raid then
				return
			end
			View:FillRaidAttendeesList(out, raid)
		end,

		rowName = UI.Lists.MakeIndexedRowName("PlayerBtn"),
		rowTmpl = "RMARaidAttendancePlayerRowTemplate",
		rowHeight = LoggerLayout.LOGGER_COMPACT_ROW_HEIGHT + 1,
		drawRow = UI.Lists.CreateRowRenderer(function(row, it)
			if not row._RMAAttendanceBound then
				SetScriptSafely(row, "OnClick", function(self, button)
					selectAttendancePlayer(self, button)
				end)
				row._RMAAttendanceBound = true
			end
			local ui = row._p
			applyAttendanceRowColumnWidths(ui, ATTENDANCE_PLAYERS_FRAME)
			local rowId = it.id or it.playerNid
			if rowId then
				row:SetID(tonumber(rowId) or rowId)
			end
			row._RMAPlayerNid = rowId
			ui.Name:SetText(it.name)
			local r, g, b = Colors.GetClassColor(it.class)
			ui.Name:SetVertexColor(r, g, b)
			ui.Join:SetText(it.joinFmt)
			ui.Leave:SetText(it.leaveFmt)
			ui.Ilvl:SetText(it.avgIlvlFmt or "")
			setAttendanceSpecIcon(
				row,
				ui,
				it.inspect and it.inspect.specIcon,
				it.inspect and it.inspect.secondarySpecIcon,
				it.inspect and it.inspect.specName,
				it.inspect and it.inspect.secondarySpecName
			)
			renderAttendanceInspectIcons(row, ui, row._RMAPlayerNid, it.inspect)
		end),

		postUpdate = function(n)
			applyAttendanceListColumnWidths(n)
			local count = 0
			if attendancePlayersController and attendancePlayersController.data then
				count = #attendancePlayersController.data
			end
			local title =
				getCountContextTitle(L.StrRaidAttendees, count, getRaidContextLabel(module.attendanceSelectedRaid), nil)
			module._setPanelTitle(n, title)
			module._setFrameHint(n, "EmptyState", getRaidAttendeesEmptyStateText(count, module.attendanceSelectedRaid))

			local addBtn = _G[n .. "AddBtn"]
			if addBtn then
				local currentRaid = Database.GetCurrentRaid()
				local canUpdate = addon.IsInRaid()
					and currentRaid
					and module.attendanceSelectedRaid
					and (tonumber(currentRaid) == tonumber(module.attendanceSelectedRaid))
				UI.Primitives.SetEnabled(addBtn, canUpdate)
			end
			local deleteBtn = _G[n .. "DeleteBtn"]
			if deleteBtn then
				UI.Primitives.SetEnabled(deleteBtn, module.attendanceSelectedPlayer ~= nil)
			end
			local forceBtn = _G[n .. "ForceInspectBtn"]
			if forceBtn then
				local currentRaid = Database.GetCurrentRaid()
				local canForce = currentRaid
					and module.attendanceSelectedPlayer
					and module.attendanceSelectedRaid
					and tonumber(module.attendanceSelectedRaid) == tonumber(currentRaid)
				UI.Primitives.SetEnabled(forceBtn, canForce and true or false)
			end
		end,

		sorters = {
			name = function(a, b, asc)
				return compareStrings(a.name, b.name, asc)
			end,
			join = function(a, b, asc)
				return CompareNumbers(a.join, b.join, asc, 0)
			end,
			leave = function(a, b, asc)
				local missing = asc and math.huge or -math.huge
				return CompareNumbers(a.leave, b.leave, asc, missing)
			end,
			ilvl = function(a, b, asc)
				return CompareNumbers(a.avgIlvl, b.avgIlvl, asc, 0)
			end,
			spec = function(a, b, asc)
				return compareStrings(a.specName, b.specName, asc)
			end,
		},
	}, "attendanceSelectedPlayer", nil, { debugTag = "RaidAttendanceSelectPlayer" })

	module.AttendancePlayers = module.AttendancePlayers or {}
	UI.Lists.BindController(module.AttendancePlayers, attendancePlayersController)

	updateRaidAttendanceFromRoster = function()
		local selectedRaid = tonumber(module.attendanceSelectedRaid)
		if not selectedRaid then
			return
		end
		if not addon.IsInRaid() then
			addon:warn(Diag.W.ErrLoggerUpdateRosterNotInRaid)
			return
		end
		if not (Database.GetCurrentRaid() and tonumber(Database.GetCurrentRaid()) == selectedRaid) then
			addon:warn(Diag.W.ErrLoggerUpdateRosterNotCurrent)
			return
		end

		Raid:UpdateRaidRoster()
		module.attendanceSelectedPlayer = nil
		markAttendanceListsDirty()
	end

	deleteSelectedRaidAttendancePlayer = function()
		local selectedRaid = module.attendanceSelectedRaid
		local playerNid = module.attendanceSelectedPlayer
		if not (selectedRaid and playerNid) then
			return
		end

		local removed =
			Actions:DeleteRaidAttendeeMany(selectedRaid, { playerNid }, getActionCommitOpts({ clearPlayers = true }))
		if removed and removed > 0 then
			module.attendanceSelectedPlayer = nil
			markAttendanceListsDirty()
		end
	end

	local function bindRaidAttendanceFrame()
		if attendanceUi.Bound then
			return getAttendanceFrame()
		end

		local frame = getAttendanceFrame()
		if not frame then
			return nil
		end

		attendanceUi.FrameName = BindModuleFrame(nil, frame, {
			enableDrag = true,
			hookOnShow = function()
				if not module.attendanceSelectedRaid then
					module.attendanceSelectedRaid = Database.GetCurrentRaid()
				end
				refreshRaidAttendanceLayout()
				markAttendanceListsDirty()
			end,
			hookOnHide = function()
				module.attendanceSelectedRaid = Database.GetCurrentRaid()
				module.attendanceSelectedPlayer = nil
			end,
		}) or ATTENDANCE_FRAME_NAME
		attendanceUi.Loaded = true
		SetFrameTitle(frame, L.StrRaidAttendance)

		attendanceUi.refs = {
			history = GetFrameRef(frame, "History"),
			raids = GetFrameRef(frame, ATTENDANCE_RAIDS_FRAME),
			raidAttendees = GetFrameRef(frame, ATTENDANCE_PLAYERS_FRAME),
		}

		attendanceRaidsController:OnLoad(attendanceUi.refs.raids)
		attendancePlayersController:OnLoad(attendanceUi.refs.raidAttendees)

		Rows.ApplyLoggerSkin(module._loggerPanelNames)
		refreshRaidAttendanceLayout()
		attendanceUi.Bound = true
		return frame
	end

	module._toggleRaidAttendanceView = function()
		local frame = bindRaidAttendanceFrame()
		if not frame then
			return
		end
		if frame:IsShown() then
			frame:Hide()
			return
		end
		frame:Show()
	end

	RegisterCallback(LoggerEvents.RaidCreate, function(_, raidId)
		local frame = getAttendanceFrame()
		if not (frame and frame.IsShown and frame:IsShown()) then
			return
		end
		module.attendanceSelectedRaid = tonumber(raidId) or raidId
		module.attendanceSelectedPlayer = nil
		markAttendanceListsDirty()
	end)
	RegisterCallback(LoggerEvents.EquipInspectUpdated, function(_, raidId)
		if not (module.attendanceSelectedRaid and tonumber(module.attendanceSelectedRaid) == tonumber(raidId)) then
			return
		end
		if attendancePlayersController then
			attendancePlayersController:Dirty()
		end
	end)
	RegisterCallback(LoggerEvents.EquipInspectCompleted, function(_, raidId)
		if not (module.attendanceSelectedRaid and tonumber(module.attendanceSelectedRaid) == tonumber(raidId)) then
			return
		end
		if attendancePlayersController then
			attendancePlayersController:Dirty()
		end
	end)
	RegisterCallback(LoggerEvents.RaidAttendanceChanged, function(_, raidId)
		if not (module.attendanceSelectedRaid and tonumber(module.attendanceSelectedRaid) == tonumber(raidId)) then
			return
		end
		markAttendanceListsDirty()
	end)
end

initializeRaidAttendanceFrame()

module.ToggleLootHistory = function()
	if module._toggleLootHistoryView then
		return module._toggleLootHistoryView()
	end
end

module.ToggleRaidAttendance = function()
	if module._toggleRaidAttendanceView then
		return module._toggleRaidAttendanceView()
	end
end

module.Toggle = module.ToggleLootHistory

local registry = feature.ModuleRegistry
if type(registry) == "table" and type(registry.AddModule) == "function" and type(registry.SetLoaded) == "function" then
	registry.AddModule("Controllers/Logger", {
		deps = {
			"Init",
			"Modules/ModuleRegistry",
			"Database/DBOptions",
			"Modules/C",
			"Modules/Timer",
			"Modules/Events",
			"Modules/Bus",
			"Modules/Strings",
			"Modules/Colors",
			"Modules/Base64",
			"Modules/Sort",
			"Modules/Dataset/IgnoredMobs",
			"Modules/UI/Frames",
			"Modules/UI/Visuals",
			"Modules/UI/ListController",
			"Modules/UI/MultiSelect",
			"Services/EquipInspect",
			"Services/Raid/State",
			"Services/Logger/Store",
			"Services/Logger/View",
			"Services/Logger/Export",
			"Services/Logger/Helpers",
			"Services/Logger/Actions",
		},
	})
	registry.SetLoaded("Controllers/Logger")
end
