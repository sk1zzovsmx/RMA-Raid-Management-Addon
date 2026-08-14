-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: direct addon namespace bindings
-- exports: publish module APIs on addon.*
-- events: listens Logger/Raid/Loot bus refresh events
local addon = select(2, ...)
local L = addon.L
local Diag = addon.Diag

local Controllers = addon.Controllers
local coreState = addon.State
local UI = addon.UI
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
local Events = addon.Events
local Frames = UI.Frames
local GetFrameRef = assert(Frames.GetRef, "Logger frame ref resolver is not initialized")
local SetScriptSafely = assert(Frames.SetScriptSafely, "Logger frame script binder is not initialized")
local SetFrameTitle = assert(Frames.SetFrameTitle, "Logger frame title binder is not initialized")
local BindModuleFrame = assert(Frames.BindModuleFrame, "Logger module frame binder is not initialized")
local MakeModuleFrameGetter =
	assert(Frames.MakeModuleFrameGetter, "Logger module frame getter factory is not initialized")
local MakeFrameGetter = assert(Frames.MakeFrameGetter, "Logger frame getter factory is not initialized")
local C = addon.C
local Database = addon.Database
local Options = addon.Options
local Bus = addon.Bus
local Strings = addon.Strings
local Colors = addon.Colors
local Base64 = addon.Base64
local Timer = addon.Timer
local Sort = addon.Sort
local IgnoredMobs = addon.IgnoredMobs
local Services = addon.Services
local LoggerSvc = assert(Services.Logger, "Logger service namespace is not initialized")
local LoggerStore = assert(LoggerSvc.Store, "Logger store service is not initialized")
local LoggerView = assert(LoggerSvc.View, "Logger view service is not initialized")
local LoggerExport = assert(LoggerSvc.Export, "Logger export service is not initialized")
local LoggerActions = assert(LoggerSvc.Actions, "Logger actions service is not initialized")
local LoggerHelpers = assert(LoggerSvc.Helpers, "Logger helper service is not initialized")
local CalculateColumnWidths = assert(UI.Lists.CalculateColumnWidths, "Logger column layout owner is not initialized")
local ExportDialog = assert(UI.ExportDialog, "Logger export dialog owner is not initialized")
local Raid = assert(Services.Raid, "Logger raid service is not initialized")
local RaidProjections = assert(Raid.Projections, "Logger raid projections service is not initialized")

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
	LoggerClearPlayerSelections = assert(
		InternalEvents.LoggerClearPlayerSelections,
		"Logger controller player selection-clear event is not initialized"
	),
	LoggerSelectItem = assert(
		InternalEvents.LoggerSelectItem,
		"Logger controller item selection event is not initialized"
	),
	LoggerLootChanged = assert(
		InternalEvents.LoggerLootChanged,
		"Logger controller loot-changed event is not initialized"
	),
	LoggerDataChanged = assert(
		InternalEvents.LoggerDataChanged,
		"Logger controller data-changed event is not initialized"
	),
	RaidLootUpdate = assert(
		InternalEvents.RaidLootUpdate,
		"Logger controller raid loot update event is not initialized"
	),
	LoggerRaidOfferReceived = assert(
		InternalEvents.LoggerRaidOfferReceived,
		"Logger controller raid-offer event is not initialized"
	),
	RaidRosterDelta = assert(
		InternalEvents.RaidRosterDelta,
		"Logger controller roster-delta event is not initialized"
	),
}

local rollTypes = addon.C.rollTypes
local lootTypesColored = addon.C.lootTypesColored
local itemColors = addon.C.itemColors
local showLoggerExportFrame
local showLoggerShareFrame
local initializeShareDropdown
local refreshShareFrameState
local setLootEntry

local _G = _G
local tconcat = table.concat
local pairs, type = pairs, type

local tostring, tonumber = tostring, tonumber
local max, floor = math.max, math.floor
local strlower = string.lower
local sort = table.sort
local IsTrashMobName = IgnoredMobs.IsTrashMobName
local GetTrashMobName = IgnoredMobs.GetTrashMobName

Controllers.Logger = Controllers.Logger or {}
local module = Controllers.Logger

module._loggerPanelNames = module._loggerPanelNames or {
	"RMALootHistoryRaids",
	"RMALootHistoryLoot",
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

local function getRaidColumnWidths(frameName)
	local budget = getLoggerListColumnBudget(frameName, LoggerLayout.LOGGER_ROW_LEFT_INSET, 3)
	return CalculateColumnWidths(
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
	return CalculateColumnWidths(
		budget,
		LoggerLayout.LOGGER_LOOT_COLUMN_MIN_WIDTHS,
		LoggerLayout.LOGGER_LOOT_COLUMN_RATIOS,
		{ "icon" }
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

local GetItemIcon = assert(_G.GetItemIcon, "Logger item icon API is not initialized")
local CreateFrame = assert(_G.CreateFrame, "Logger frame creation API is not initialized")
local UIParent = assert(_G.UIParent, "Logger root UI parent is not initialized")
local UnitName = assert(_G.UnitName, "Logger unit-name API is not initialized")
local UnitIsUnit = assert(_G.UnitIsUnit, "Logger unit-identity API is not initialized")
local Group = assert(addon.Group, "Logger group helper owner is not initialized")
local UIDropDownMenu_Initialize =
	assert(_G.UIDropDownMenu_Initialize, "Logger dropdown init API is not initialized")
local UIDropDownMenu_CreateInfo =
	assert(_G.UIDropDownMenu_CreateInfo, "Logger dropdown info API is not initialized")
local UIDropDownMenu_AddButton =
	assert(_G.UIDropDownMenu_AddButton, "Logger dropdown add-button API is not initialized")
local UIDropDownMenu_SetWidth =
	assert(_G.UIDropDownMenu_SetWidth, "Logger dropdown width API is not initialized")
local UIDropDownMenu_SetButtonWidth =
	assert(_G.UIDropDownMenu_SetButtonWidth, "Logger dropdown button-width API is not initialized")
local UIDropDownMenu_SetText = assert(_G.UIDropDownMenu_SetText, "Logger dropdown text API is not initialized")

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

local uiState = UI.ModuleState.Ensure(module)

local function getShareEligibility(raid)
	if not raid then
		return false, L.StrLoggerShareNoRaid
	end
	if not addon.IsInGroup() then
		return false, L.StrLoggerShareRequiresGroup
	end
	local raidStore = Database.GetRaidStore()
	local raidUid = raidStore:GetRaidUid(raid)
	local record = raidUid and raidStore:GetRecord(raidUid) or nil
	if not record or record.status ~= "complete" then
		return false, L.StrLoggerShareCompletedOnly
	end
	return true, nil, raidUid
end

local function collectShareRecipients()
	local recipients = {}
	local groupType, firstIndex, memberCount = Group.GetTypeAndCount()
	if not groupType then
		return recipients
	end
	for i = firstIndex, memberCount do
		local unit = groupType .. i
		if not UnitIsUnit(unit, "player") then
			local name = NormalizeName(UnitName(unit), true)
			if name and Raid:IsGroupMember(name) then
				recipients[#recipients + 1] = name
			end
		end
	end
	sort(recipients, function(a, b)
		return compareStrings(a, b, true)
	end)
	return recipients
end

if not IsPopupDefined("RMALOGGER_RAID_OFFER") then
	DefinePopup("RMALOGGER_RAID_OFFER", {
		text = L.StrLoggerRaidOfferPrompt,
		button1 = L.BtnAccept,
		button2 = L.BtnDecline,
		timeout = 30,
		whileDead = 1,
		hideOnEscape = 1,
		preferredIndex = 3,
		OnAccept = function(_, offer)
			local syncer = Database.GetSyncer()
			if syncer and offer then
				syncer:AcceptHistoricalOffer(offer.sender, offer.offerId)
			end
		end,
		OnCancel = function(_, offer)
			local syncer = Database.GetSyncer()
			if syncer and offer then
				syncer:DeclineHistoricalOffer(offer.sender, offer.offerId)
			end
		end,
	})
end

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
	local raid = store and store:GetRaid(selectedRaid) or nil
	if not raid then
		return nil
	end
	local zone = raid.zone or nil
	local difficulty = RaidProjections.GetDifficultyLabel(raid)
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

	local function clearPlayerSelections()
		local selectedPlayer = module.selectedPlayer ~= nil
		local selectedBossPlayer = module.selectedBossPlayer ~= nil
		clearSelection(module, "selectedPlayer", MS_CTX_RAIDATT)
		clearSelection(module, "selectedBossPlayer", MS_CTX_BOSSATT)
		if selectedPlayer then
			triggerSelectionEvent(module, "selectedPlayer")
		end
		if selectedBossPlayer then
			triggerSelectionEvent(module, "selectedBossPlayer")
		end
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

	initializeShareDropdown = function(frame)
		local dropdown = frame and _G[frame:GetName() .. "RecipientDropDown"] or nil
		if not dropdown then
			return
		end
		UIDropDownMenu_Initialize(dropdown, function(_, level)
			if level and level ~= 1 then
				return
			end
			local recipients = collectShareRecipients()
			for i = 1, #recipients do
				local recipient = recipients[i]
				local info = UIDropDownMenu_CreateInfo()
				info.text = recipient
				info.arg1 = recipient
				info.checked = recipient == module._shareTarget
				info.func = function(_, target)
					module._shareTarget = target
					UIDropDownMenu_SetText(dropdown, target)
					refreshShareFrameState(frame)
				end
				UIDropDownMenu_AddButton(info, level)
			end
		end)
		UIDropDownMenu_SetWidth(dropdown, 220)
		UIDropDownMenu_SetButtonWidth(dropdown, 240)
		UIDropDownMenu_SetText(dropdown, module._shareTarget or L.StrLoggerShareRecipient)
	end

	refreshShareFrameState = function(frame)
		if not frame then
			return
		end
		local raid = module._needRaid()
		local shareAllowed = getShareEligibility(raid)
		local sendButton = _G[frame:GetName() .. "SendBtn"]
		local statusLabel = _G[frame:GetName() .. "Status"]
		local canSend = shareAllowed
			and module._shareTarget ~= nil
			and Raid:IsGroupMember(module._shareTarget)
		UI.Primitives.SetEnabled(sendButton, canSend)
		local syncer = Database.GetSyncer()
		local status = syncer and syncer:GetStatus() or "failed"
		local labels = {
			synchronized = L.RaidSyncStatusUpToDate,
			recovering = L.RaidSyncStatusRecovering,
			handover = L.RaidSyncStatusHandover,
			transferring_history = L.RaidSyncStatusTransferringHistory,
			suspended = L.RaidSyncStatusSuspended,
			failed = L.RaidSyncStatusFailed,
		}
		if statusLabel then
			statusLabel:SetText(L.StrLoggerSyncStatus:format(labels[status] or L.RaidSyncStatusFailed))
		end
	end

	local function bindShareFrame()
		local frame = _G.RMALootHistoryShareFrame
		if not frame then
			return nil
		end
		local frameName = frame:GetName()
		SetFrameTitle("RMALootHistoryShareFrame", L.StrLoggerShareTitle)
		_G[frameName .. "RecipientLabel"]:SetText(L.StrLoggerShareRecipient)
		_G[frameName .. "SendBtn"]:SetText(L.BtnLoggerSendRaid)
		initializeShareDropdown(frame)

		if not frame._RMAShareBound then
			SetScriptSafely(frame, "OnHide", function()
				module._shareTarget = nil
				UIDropDownMenu_SetText(_G[frameName .. "RecipientDropDown"], L.StrLoggerShareRecipient)
			end)
			SetScriptSafely(_G[frameName .. "SendBtn"], "OnClick", function()
				local raid = module._needRaid()
				local shareAllowed, reason, raidUid = getShareEligibility(raid)
				if not shareAllowed then
					addon:warn(reason)
					refreshShareFrameState(frame)
					return false, reason
				end
				if not (module._shareTarget and Raid:IsGroupMember(module._shareTarget)) then
					refreshShareFrameState(frame)
					return false
				end
				local syncer = Database.GetSyncer()
				local offered, offerReason
				if syncer then
					offered, offerReason = syncer:OfferHistoricalRaid(raidUid, module._shareTarget)
				end
				if offered then
					frame:Hide()
					return true
				end
				offerReason = offerReason or L.StrLoggerHistoryShareFailed:format(module._shareTarget)
				addon:warn(offerReason)
				return false, offerReason
			end)
			frame._RMAShareBound = true
		end

		return frame
	end

	showLoggerShareFrame = function()
		local raid = module._needRaid()
		local shareAllowed, reason = getShareEligibility(raid)
		if not shareAllowed then
			addon:warn(reason)
			return false, reason
		end
		local frame = bindShareFrame()
		if not frame then
			return false
		end
		_G[frame:GetName() .. "Summary"]:SetText(L.StrLoggerShareSummary:format(
			tostring(raid.zone or L.StrUnknown),
			RaidProjections.FormatTimestamp(raid.startTime),
			RaidProjections.GetDifficultyLabel(raid),
			#(raid.loot or {})
		))
		refreshShareFrameState(frame)
		frame:Show()
		return true
	end
	module.ShowShareDialog = showLoggerShareFrame

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

	local function setExportModeButtonState(refs, mode)
		local buttons = {
			{ button = refs and refs.lootBtn, mode = "loot" },
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

	local function refreshExportFrame(mode, refs)
		local raid = module._needRaid()
		if not raid then
			addon:error(L.ErrLoggerInvalidRaid)
			return false
		end

		mode = mode or module._loggerExportMode or "loot"
		module._loggerExportMode = mode

		local csv, errCode = Export:BuildCSV(raid, getExportContext())
		if errCode then
			addon:error((L.ErrLoggerExportFailed):format(tostring(errCode)))
			return false
		end

		setExportModeButtonState(refs, mode)
		module._lastExportCSV = csv or ""
		ExportDialog.SetText(refs, module._lastExportCSV)
		return true
	end

	local function bindExportFrame()
		local refs
		refs = ExportDialog.Bind({
			title = L.StrLoggerExportTitle,
			hint = L.StrLoggerExportHint,
			modeButtonText = L.BtnLoggerExportLootCSV,
			onModeButtonClick = function()
				refreshExportFrame("loot", refs)
			end,
			getText = function()
				return module._lastExportCSV or ""
			end,
			adjustScrollBar = true,
		})
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
		if not refreshExportFrame(module._loggerExportMode, refs) then
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
		local raidIndex = btn and btn.GetID and btn:GetID()
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
			id = raidIndex,
			context = (opts and opts.context) or MS_CTX_RAID,
			ordered = ordered,
			isMulti = isMulti,
			isRange = isRange,
			allowDeselect = opts and opts.allowDeselect,
			setFocus = module._SetSelectedRaid,
			mapSelectedToFocus = function(index) return tonumber(index) end,
			isClickedFocused = function(clickedIndex)
				return tonumber(module.selectedRaid) == tonumber(clickedIndex)
			end,
		})

		if Options.IsDebugEnabled() and addon.debug then
			addon:debug(
				(Diag.D.LogLoggerSelectClickRaid):format(
					tostring(raidIndex),
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

	RegisterCallback(LoggerEvents.LoggerClearPlayerSelections, clearPlayerSelections)
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
				_G[n .. "ShareBtn"]:SetText(L.BtnShare)
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
					SetScriptSafely(_G[n .. "ShareBtn"], "OnClick", function()
						showLoggerShareFrame()
					end)
					SetScriptSafely(_G[n .. "DeleteBtn"], "OnClick", function(self, button)
						confirmDeleteSelectedRaids(self, button)
					end)
					bindRaidSortHeaders(n, Raids)
				end
			end,

			getData = function(out)
				RaidProjections.FillRaidList(out)
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
				local raid = sel and Database.EnsureRaidByIndex(sel) or nil
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
				UI.Primitives.SetEnabled(_G[n .. "ShareBtn"], getShareEligibility(raid))

				local ctx = module._msRaidCtx
				local selCount = UI.Selection.GetCount(ctx)
				local canDelete = (selCount and selCount > 0) or false
				if canDelete and Database.GetCurrentRaid() then
					local currentRaidNid = Database.GetRaidNidByIndex(Database.GetCurrentRaid())
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
			transform = function(id) return id end,
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

			local raidIndexes = {}
			local seenIndexes = {}
			for i = 1, #ids do
				local index = tonumber(ids[i])
				if index and not seenIndexes[index] then
					seenIndexes[index] = true
					raidIndexes[#raidIndexes + 1] = index
				end
			end
			if #raidIndexes == 0 then
				return
			end

			-- Safety: never delete the current raid
			local currentRaid = Database.GetCurrentRaid()
			if currentRaid then
				for i = 1, #raidIndexes do
					if tonumber(raidIndexes[i]) == tonumber(currentRaid) then
						return
					end
				end
			end

			local prevFocus = module.selectedRaid
			local raidStore = Database.GetRaidStore()
			local prevFocusKey = prevFocus and raidStore:GetArchiveKeyByIndex(prevFocus) or nil
			module.Actions:DeleteRaidsByIndex(raidIndexes)

			UI.Selection.EnsureState(ctx)

			local raids = Database.GetRaidStore():GetAllRaids()
			local n = #raids
			local newFocus = nil
			if n > 0 then
				newFocus = prevFocusKey and raidStore:GetIndexByArchiveKey(prevFocusKey) or nil
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

	RegisterCallback(LoggerEvents.LoggerDataChanged, function()
		controller:Dirty()
	end)

	RegisterCallback(LoggerEvents.RaidRosterDelta, function()
		if module._shareTarget and not Raid:IsGroupMember(module._shareTarget) then
			module._shareTarget = nil
		end
		local frame = _G.RMALootHistoryShareFrame
		if frame and frame:IsShown() then
			initializeShareDropdown(frame)
			refreshShareFrameState(frame)
		end
		controller:Touch()
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

		local shareFrame = _G.RMALootHistoryShareFrame
		module._shareTarget = nil
		if shareFrame and shareFrame:IsShown() then
			shareFrame:Hide()
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
					Colors.WrapText(nameText, Colors.NormalizeHexColor(itemColors[(it.itemRarity or 1) + 1]))
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
		return Actions:RecordLoot({
			lootNid = lootNid,
			looter = looter,
			rollType = rollType,
			rollValue = rollValue,
			source = source,
			selectedRaid = module.selectedRaid,
			currentRaid = currentRaid,
			raidId = raidIDOverride,
		})
	end

	RegisterCallback(LoggerEvents.LoggerLootChanged, function()
		controller:Dirty()
	end)
	RegisterCallback(LoggerEvents.LoggerDataChanged, function()
		controller:Dirty()
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

RegisterCallback(LoggerEvents.LoggerRaidOfferReceived, function(_, offer)
	if type(offer) ~= "table" or not offer.sender then
		return
	end
	local summary = L.StrLoggerShareSummary:format(
		tostring(offer.zone or L.StrUnknown),
		RaidProjections.FormatTimestamp(offer.startTime),
		RaidProjections.GetDifficultyLabel(offer),
		tonumber(offer.lootCount) or 0
	)
	ShowPopup("RMALOGGER_RAID_OFFER", offer.sender, summary, offer)
end)

module.ToggleLootHistory = function()
	if module._toggleLootHistoryView then
		return module._toggleLootHistoryView()
	end
end

module.Toggle = module.ToggleLootHistory
