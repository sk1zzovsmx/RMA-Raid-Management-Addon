-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: direct addon namespace bindings
-- exports: publish module APIs on addon.*
-- events: listens Raid/Attendance/Inspect bus refresh events
local addon = select(2, ...)
local L = addon.L
local Diag = addon.Diag
local Controllers = addon.Controllers
local UI = addon.UI
local Rows = UI.Rows
local Frames = UI.Frames
local Tooltips = UI.Tooltips
local Events = addon.Events
local Bus = addon.Bus
local Database = addon.Database
local Services = addon.Services
local Timer = addon.Timer
local Sort = addon.Sort
local Colors = addon.Colors
local CalculateColumnWidths =
	assert(UI.Lists.CalculateColumnWidths, "Attendance column layout owner is not initialized")
local ExportDialog = assert(UI.ExportDialog, "Attendance export dialog owner is not initialized")

local GetFrameRef = assert(Frames.GetRef, "Attendance frame ref resolver is not initialized")
local SetScriptSafely = assert(Frames.SetScriptSafely, "Attendance frame script binder is not initialized")
local SetFrameTitle = assert(Frames.SetFrameTitle, "Attendance frame title binder is not initialized")
local BindModuleFrame = assert(Frames.BindModuleFrame, "Attendance module frame binder is not initialized")
local MakeFrameGetter = assert(Frames.MakeFrameGetter, "Attendance frame getter factory is not initialized")
local ShowItemTooltip = assert(Tooltips.ShowItem, "Attendance item tooltip renderer is not initialized")
local ShowTooltipLines = assert(Tooltips.ShowLines, "Attendance tooltip line renderer is not initialized")
local HideTooltip = assert(Tooltips.Hide, "Attendance tooltip hide service is not initialized")
local BindTooltipModel = assert(Tooltips.BindModel, "Attendance tooltip model binder is not initialized")

local InternalEvents = assert(Events.Internal, "Attendance controller internal events are not initialized")
local TriggerEvent = assert(Bus.TriggerEvent, "Attendance controller event publisher is not initialized")
local RegisterCallback = assert(Bus.RegisterCallback, "Attendance controller event listener is not initialized")
local AttendanceEvents = {
	RaidCreate = assert(InternalEvents.RaidCreate, "Attendance controller raid-create event is not initialized"),
	RaidAttendanceChanged = assert(
		InternalEvents.RaidAttendanceChanged,
		"Attendance controller raid attendance changed event is not initialized"
	),
	EquipInspectUpdated = assert(
		InternalEvents.EquipInspectUpdated,
		"Attendance controller equip inspect update event is not initialized"
	),
	EquipInspectCompleted = assert(
		InternalEvents.EquipInspectCompleted,
		"Attendance controller equip inspect completion event is not initialized"
	),
	LoggerClearPlayerSelections = assert(
		InternalEvents.LoggerClearPlayerSelections,
		"Attendance controller logger selection-clear event is not initialized"
	),
	LootBansChanged = assert(InternalEvents.LootBansChanged, "Attendance Loot Ban event is not initialized"),
}

local AttendanceSvc = assert(Services.Attendance, "Attendance service namespace is not initialized")
local AttendanceStore = assert(AttendanceSvc.Store, "Attendance store service is not initialized")
local AttendanceView = assert(AttendanceSvc.View, "Attendance view service is not initialized")
local AttendanceActions = assert(AttendanceSvc.Actions, "Attendance actions service is not initialized")
local AttendanceExport = assert(AttendanceSvc.Export, "Attendance export service is not initialized")
local EquipInspect = assert(Services.EquipInspect, "Attendance equip-inspect service is not initialized")
local ForceInspectPlayer = assert(EquipInspect.ForcePlayer, "Attendance force-inspect method is not initialized")
local Raid = assert(Services.Raid, "Attendance raid service is not initialized")
local RaidProjections = assert(Raid.Projections, "Attendance raid projections service is not initialized")
local LootBans = assert(Raid.LootBans, "Attendance Loot Ban owner is not initialized")

local _G = _G
local type, tostring, tonumber = type, tostring, tonumber
local floor, max = math.floor, math.max
local CreateFrame = assert(_G.CreateFrame, "Attendance frame creation API is not initialized")
local CompareNumbers = Sort.CompareNumbers
local CompareValues = Sort.CompareValues

Controllers.Attendance = Controllers.Attendance or {}
local module = Controllers.Attendance
Timer.BindMixin(module, "Attendance")

module.Store = AttendanceStore
module.View = AttendanceView
module.Actions = AttendanceActions
module.Export = AttendanceExport

local ATTENDANCE_FRAME_NAME = "RMARaidAttendance"
local ATTENDANCE_RAIDS_FRAME = "RMARaidAttendanceRaids"
local ATTENDANCE_PLAYERS_FRAME = "RMARaidAttendanceRaidAttendees"

local AttendanceLayout = {
	COMPACT_ROW_HEIGHT = 22,
	LIST_WIDTH_FALLBACK = 240,
	SCROLLBAR_GUTTER_WIDTH = 24,
	ROW_LEFT_INSET = 3,
	ROW_COLUMN_GAP = 6,
	HEADER_COLUMN_GAP = 6,
	PANEL_SCROLL_LEFT_OFFSET = 3,
	HEADER_TOP_OFFSET = -25,
	RAID_INSPECT_SLOTS = { 1, 2, 3, 15, 5, 9, 10, 6, 7, 8, 11, 12, 13, 14, 16, 17, 18 },
	RAID_INSPECT_ICON_SIZE = 18,
	RAID_INSPECT_ICON_GAP = 1,
	RAID_INSPECT_ICON_LEFT_OFFSET = 1,
	RAID_SPEC_ICON_SIZE = 17,
	RAID_SPEC_ICON_GAP = 1,
	RAID_SPEC_ICON_LEFT_OFFSET = 1,
	RAID_COLUMN_MIN_WIDTHS = {
		id = 24,
		date = 88,
		zone = 128,
		size = 36,
	},
	RAID_COLUMN_RATIOS = {
		date = 0.20,
		zone = 0.66,
		size = 0.14,
	},
	ATTENDANCE_COLUMN_MIN_WIDTHS = {
		name = 68,
		join = 39,
		leave = 39,
		ilvl = 30,
		spec = 37,
		inspect = 324,
	},
	ATTENDANCE_COLUMN_RATIOS = {
		name = 0,
		join = 0,
		leave = 0,
		ilvl = 0,
		spec = 0,
		inspect = 1,
	},
}

local RAID_LAYOUT_COLUMNS = {
	{ headerSuffix = "HeaderNum", rowKey = "ID", widthKey = "id", trailingGap = true, sortKey = "id" },
	{ headerSuffix = "HeaderDate", rowKey = "Date", widthKey = "date", trailingGap = true, sortKey = "date" },
	{ headerSuffix = "HeaderZone", rowKey = "Zone", widthKey = "zone", trailingGap = true, sortKey = "zone" },
	{ headerSuffix = "HeaderSize", rowKey = "Size", widthKey = "size", trailingGap = false, sortKey = "size" },
}

local ATTENDANCE_LAYOUT_COLUMNS = {
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

local function compareStrings(aValue, bValue, asc)
	return CompareValues(tostring(aValue or ""), tostring(bValue or ""), asc)
end

local function setWidgetWidth(widget, width)
	if widget and widget.SetWidth then
		widget:SetWidth(width)
	end
end

local function setHeaderWidth(widget, width, includeTrailingGap)
	local gap = includeTrailingGap and AttendanceLayout.HEADER_COLUMN_GAP or 0
	setWidgetWidth(widget, (tonumber(width) or 0) + gap)
end

local function getListContentWidth(frameName)
	if not frameName then
		return AttendanceLayout.LIST_WIDTH_FALLBACK
	end

	local scroll = _G[frameName .. "ScrollFrame"]
	local width = scroll and scroll.GetWidth and scroll:GetWidth() or nil
	if type(width) ~= "number" or width <= 0 then
		local frame = _G[frameName]
		width = frame and frame.GetWidth and frame:GetWidth() or nil
		if type(width) == "number" and width > AttendanceLayout.SCROLLBAR_GUTTER_WIDTH then
			width = width - AttendanceLayout.SCROLLBAR_GUTTER_WIDTH
		end
	end

	width = tonumber(width) or AttendanceLayout.LIST_WIDTH_FALLBACK
	return max(AttendanceLayout.LIST_WIDTH_FALLBACK, floor(width))
end

local function getColumnBudget(frameName, leadOffset, gapCount)
	local budget = getListContentWidth(frameName)
		- (tonumber(leadOffset) or 0)
		- ((tonumber(gapCount) or 0) * AttendanceLayout.ROW_COLUMN_GAP)
	return max(AttendanceLayout.LIST_WIDTH_FALLBACK, floor(budget))
end

local function getLayoutColumnWidth(widths, column)
	return tonumber(widths and widths[column.widthKey]) or 0
end

local function positionHeader(header, frameName, offsetX, width, includeTrailingGap)
	local frame = frameName and _G[frameName] or nil
	if not (header and frame) then
		return
	end

	header:ClearAllPoints()
	header:SetPoint("TOPLEFT", frame, "TOPLEFT", offsetX, AttendanceLayout.HEADER_TOP_OFFSET)
	setHeaderWidth(header, width, includeTrailingGap)
end

local function applyHeaderColumnWidths(frameName, widths, columns, startOffset)
	local offset = tonumber(startOffset) or AttendanceLayout.PANEL_SCROLL_LEFT_OFFSET
	for i = 1, #columns do
		local column = columns[i]
		positionHeader(
			_G[frameName .. column.headerSuffix],
			frameName,
			offset,
			getLayoutColumnWidth(widths, column),
			column.trailingGap
		)
		offset = offset + getLayoutColumnWidth(widths, column)
		if column.trailingGap then
			offset = offset + AttendanceLayout.HEADER_COLUMN_GAP
		end
	end
end

local function applyRowColumnWidths(ui, widths, columns)
	if not ui then
		return
	end
	for i = 1, #columns do
		local column = columns[i]
		setWidgetWidth(ui[column.rowKey], getLayoutColumnWidth(widths, column))
	end
end

local function getRaidColumnWidths(frameName)
	return CalculateColumnWidths(
		getColumnBudget(frameName, AttendanceLayout.ROW_LEFT_INSET, 3),
		AttendanceLayout.RAID_COLUMN_MIN_WIDTHS,
		AttendanceLayout.RAID_COLUMN_RATIOS,
		{ "id" }
	)
end

local function getAttendanceColumnWidths(frameName)
	return CalculateColumnWidths(
		getColumnBudget(frameName, AttendanceLayout.ROW_LEFT_INSET, 5),
		AttendanceLayout.ATTENDANCE_COLUMN_MIN_WIDTHS,
		AttendanceLayout.ATTENDANCE_COLUMN_RATIOS
	)
end

local function applyRaidListColumnWidths(frameName)
	applyHeaderColumnWidths(
		frameName,
		getRaidColumnWidths(frameName),
		RAID_LAYOUT_COLUMNS,
		AttendanceLayout.PANEL_SCROLL_LEFT_OFFSET + AttendanceLayout.ROW_LEFT_INSET
	)
end

local function applyRaidRowColumnWidths(ui, frameName)
	applyRowColumnWidths(ui, getRaidColumnWidths(frameName), RAID_LAYOUT_COLUMNS)
end

local function applyAttendanceListColumnWidths(frameName)
	applyHeaderColumnWidths(
		frameName,
		getAttendanceColumnWidths(frameName),
		ATTENDANCE_LAYOUT_COLUMNS,
		AttendanceLayout.PANEL_SCROLL_LEFT_OFFSET + AttendanceLayout.ROW_LEFT_INSET
	)
end

local function applyAttendanceRowColumnWidths(ui, frameName)
	applyRowColumnWidths(ui, getAttendanceColumnWidths(frameName), ATTENDANCE_LAYOUT_COLUMNS)
end

local function bindSortHeaders(frameName, columns, listRef, boundFlag)
	local frame = frameName and _G[frameName] or nil
	if not frame or not listRef or type(listRef.Sort) ~= "function" then
		return
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

local function setFrameLabel(frameName, suffix, text)
	local label = frameName and _G[frameName .. suffix] or nil
	if not label then
		return
	end
	if label.SetText then
		label:SetText(text)
	end
end

local function setPanelTitle(frameName, text)
	setFrameLabel(frameName, "Title", text)
end

local function setFrameHint(frameName, suffix, text)
	local label = frameName and _G[frameName .. suffix] or nil
	if not label then
		return
	end
	if label.SetText then
		label:SetText(text or "")
	end
	UI.Primitives.SetShown(label, text ~= nil and text ~= "")
end

local function getCountTitle(baseText, count)
	return ("%s (%d)"):format(tostring(baseText or ""), tonumber(count) or 0)
end

local function getCountContextTitle(baseText, count, contextText)
	local title = getCountTitle(baseText, count)
	if contextText and contextText ~= "" then
		return ("%s - %s"):format(title, contextText)
	end
	return title
end

local function getRaidContextLabel(selectedRaid)
	if not selectedRaid then
		return nil
	end
	local raid = AttendanceStore:GetRaid(selectedRaid)
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

local function getRaidAttendeesEmptyStateText(count, selectedRaid)
	if (tonumber(count) or 0) > 0 then
		return nil
	end
	if not selectedRaid then
		return L.StrLoggerEmptyRaidAttendeesSelectRaid
	end
	return L.StrLoggerEmptyRaidAttendees
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

local function getAttendanceInspectIcon(row, index)
	if not row then
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
	icon:SetSize(AttendanceLayout.RAID_INSPECT_ICON_SIZE, AttendanceLayout.RAID_INSPECT_ICON_SIZE)
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
			if link then
				ShowItemTooltip(self, link, nil, "ANCHOR_LEFT")
			end
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

local function bindAttendanceSpecIconTooltip(icon)
	BindTooltipModel(icon, function(self)
		local specName = self and self._RMASpecName or nil
		if not specName or specName == "" then
			return nil
		end
		return {
			title = specName,
			lines = {},
			anchor = "ANCHOR_RIGHT",
		}
	end, "ANCHOR_RIGHT")
end

local function getSpecIcon(row, suffix)
	if not row then
		return nil
	end
	local cacheKey = suffix == "SecondarySpecIcon" and "_RMAAttendanceSecondarySpecIcon" or "_RMAAttendanceSpecIcon"
	if row[cacheKey] then
		return row[cacheKey]
	end

	local rowName = row.GetName and row:GetName() or nil
	local iconName = rowName and (rowName .. suffix) or nil
	local icon = iconName and _G[iconName] or nil
	if not icon then
		return nil
	end
	icon:EnableMouse(true)
	icon:SetSize(AttendanceLayout.RAID_SPEC_ICON_SIZE, AttendanceLayout.RAID_SPEC_ICON_SIZE)
	icon.texture = iconName and _G[iconName .. "Texture"] or nil
	if not icon.texture then
		return nil
	end
	icon.texture:SetAllPoints(icon)
	icon.texture:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	bindAttendanceSpecIconTooltip(icon)
	row[cacheKey] = icon
	return icon
end

local function setSpecIconTexture(icon, iconPath, specName, desaturate)
	if not icon or not icon.texture then
		return
	end
	icon._RMASpecName = specName
	if iconPath then
		icon.texture:SetTexture(iconPath)
		if icon.texture.SetDesaturated then
			icon.texture:SetDesaturated(desaturate and true or false)
		end
		icon:Show()
	else
		icon.texture:SetTexture(nil)
		icon:Hide()
	end
end

local function clearAttendanceSpecIcons(row)
	if not row then
		return
	end
	local primaryIcon = row._RMAAttendanceSpecIcon
	local secondaryIcon = row._RMAAttendanceSecondarySpecIcon
	setSpecIconTexture(primaryIcon, nil, nil, false)
	setSpecIconTexture(secondaryIcon, nil, nil, false)
end

local function setAttendanceSpecIcon(row, primarySpecIcon, secondarySpecIcon, primarySpecName, secondarySpecName)
	local primaryIcon = getSpecIcon(row, "SpecIcon")
	local secondaryIcon = getSpecIcon(row, "SecondarySpecIcon")
	if not primarySpecIcon and not secondarySpecIcon then
		clearAttendanceSpecIcons(row)
		return
	end
	setSpecIconTexture(primaryIcon, primarySpecIcon, primarySpecName, false)
	setSpecIconTexture(secondaryIcon, secondarySpecIcon, secondarySpecName, true)
end

local function renderAttendanceInspectIcons(row, playerNid, snapshot)
	clearAttendanceInspectIcons(row)
	local items = snapshot and snapshot.items or nil
	if type(items) ~= "table" then
		local ui = row and row._p or nil
		if ui and ui.InspectStatus then
			ui.InspectStatus:SetText(getInspectStatusLabel(snapshot and snapshot.status, snapshot and snapshot.reason))
		end
		return
	end

	local ui = row and row._p or nil
	if ui and ui.InspectStatus then
		ui.InspectStatus:SetText("")
	end

	local count = 0
	local x = AttendanceLayout.RAID_INSPECT_ICON_LEFT_OFFSET
	for i = 1, #AttendanceLayout.RAID_INSPECT_SLOTS do
		local slotId = AttendanceLayout.RAID_INSPECT_SLOTS[i]
		local item = items[slotId]
		local itemLink = item and item.itemLink or nil
		if itemLink then
			count = count + 1
			local icon = getAttendanceInspectIcon(row, count)
			if icon then
				icon._RMAItemLink = itemLink
				icon._RMAPlayerNid = playerNid
				icon:ClearAllPoints()
				icon:SetPoint("LEFT", ui.InspectStatus, "LEFT", x, 0)
				if icon.texture then
					icon.texture:SetTexture(item.texture)
				end
				icon:Show()
				x = x + AttendanceLayout.RAID_INSPECT_ICON_SIZE + AttendanceLayout.RAID_INSPECT_ICON_GAP
			end
		end
	end

	if count == 0 and ui and ui.InspectStatus then
		ui.InspectStatus:SetText(getInspectStatusLabel(snapshot and snapshot.status, snapshot and snapshot.reason))
	end
end

local function makeAttendanceList(cfg, selField, hlOpts)
	hlOpts = hlOpts or {}
	local transform = hlOpts.transform
	local debugTag = hlOpts.debugTag or "AttendanceSelect"

	if cfg.rightInset == nil then
		cfg.rightInset = 0
	end
	if cfg.drawRow then
		local drawRow = cfg.drawRow
		local rowHeight = cfg.rowHeight or AttendanceLayout.COMPACT_ROW_HEIGHT
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
		local value = module[selField]
		if value == nil then
			return nil
		end
		return transform and transform(value) or value
	end

	cfg.focusId = resolve
	cfg.highlightId = resolve
	cfg.focusKey = function()
		return tostring(resolve() or "nil")
	end
	cfg.highlightDebugInfo = function()
		return ("%s=%s"):format(selField, tostring(resolve()))
	end
	cfg.highlightDebugTag = debugTag
	return UI.Lists.CreateController(cfg)
end

local attendanceUi = module._attendanceUi or {
	Loaded = false,
	Bound = false,
	FrameName = nil,
}
module._attendanceUi = attendanceUi

module.attendanceSelectedRaid = module.attendanceSelectedRaid or nil
module.attendanceSelectedPlayer = module.attendanceSelectedPlayer or nil

local getAttendanceFrame = MakeFrameGetter(ATTENDANCE_FRAME_NAME)
local attendanceRaidsController
local attendancePlayersController

local function getAttendanceRaid()
	local raidId = module.attendanceSelectedRaid
	if not raidId then
		return nil
	end
	return AttendanceStore:GetRaid(raidId), raidId
end

local function getAttendanceExportContext()
	return {
		raidId = module.attendanceSelectedRaid,
		selectedPlayerNid = module.attendanceSelectedPlayer,
	}
end

local function bindAttendanceExportFrame()
	return ExportDialog.Bind({
		title = L.BtnLoggerExportRaidAttendanceCSV,
		hint = L.StrLoggerExportHint,
		getText = function()
			return module._lastAttendanceExportCSV or ""
		end,
	})
end

local function showAttendanceExport()
	local raid = getAttendanceRaid()
	if not raid then
		addon:error(L.ErrLoggerInvalidRaid)
		return false
	end

	local csv, errCode = AttendanceExport:BuildCSV(raid, getAttendanceExportContext())
	if errCode then
		addon:error((L.ErrLoggerExportFailed):format(tostring(errCode)))
		return false
	end

	local refs = bindAttendanceExportFrame()
	if not (refs and refs.frame) then
		return false
	end

	module._lastAttendanceExportCSV = csv or ""
	ExportDialog.SetText(refs, module._lastAttendanceExportCSV)
	refs.frame:Show()
	return true
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
		attendancePlayersController:Dirty()
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
	local raidId = btn and btn.GetID and btn:GetID()
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

local function showAttendanceLootBanTooltip(self)
	if self._RMALootBanActive then
		local lines = {}
		if self._RMALootBanNote and self._RMALootBanNote ~= "" then
			lines[#lines + 1] = { text = self._RMALootBanNote }
		end
		ShowTooltipLines(self, {
			title = L.StrLootBanTooltipTitle,
			lines = lines,
		})
	end
end

local function bindAttendanceLootBanTarget(target, row)
	target._RMARow = row
	if target._RMALootBanTooltipBound then
		return true
	end
	local enterBound = SetScriptSafely(target, "OnEnter", showAttendanceLootBanTooltip)
	local leaveBound = SetScriptSafely(target, "OnLeave", HideTooltip)
	local clickBound = SetScriptSafely(target, "OnClick", function(self, button)
		local rowOnClick = self._RMARow and self._RMARow:GetScript("OnClick") or nil
		if rowOnClick then
			rowOnClick(self._RMARow, button)
		end
	end)
	target._RMALootBanTooltipBound = enterBound and leaveBound and clickBound
	return target._RMALootBanTooltipBound
end

local function getAttendanceLootBanHotspot(row, ui)
	local hotspot = row._RMALootBanHotspot
	if not hotspot then
		hotspot = CreateFrame("Button", nil, row)
		hotspot:EnableMouse(true)
		hotspot:RegisterForClicks("AnyUp")
		hotspot:SetAllPoints(ui.Name)
		row._RMALootBanHotspot = hotspot
	end

	bindAttendanceLootBanTarget(hotspot, row)
	return hotspot
end

local function getAttendanceLootBanIcon(row)
	local icon = row._RMALootBanIcon
	if not icon then
		icon = CreateFrame("Button", nil, row)
		icon:SetSize(14, 14)
		icon:SetPoint("LEFT", row, "LEFT", 3, 0)
		icon:SetNormalTexture("Interface\\Buttons\\UI-GroupLoot-Pass-Up")
		icon:EnableMouse(true)
		icon:RegisterForClicks("AnyUp")
		icon:Hide()
		row._RMALootBanIcon = icon
	end

	bindAttendanceLootBanTarget(icon, row)
	return icon
end

local function refreshRaidAttendanceLayout()
	local refs = attendanceUi.refs or {}
	local history = refs.history
	UI.Primitives.SetShown(refs.raids, true)
	UI.Primitives.SetShown(refs.raidAttendees, true)

	placePanel(refs.raids, "TOPLEFT", history, "TOPLEFT", 0, 0, 335, 430)
	placePanel(refs.raidAttendees, "TOPLEFT", refs.raids, "TOPRIGHT", 7, 0, 607, 430)

	applyRaidListColumnWidths(ATTENDANCE_RAIDS_FRAME)
	applyAttendanceListColumnWidths(ATTENDANCE_PLAYERS_FRAME)
end

local function isViewingCurrentRaid()
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

function module.RequestRefresh()
	if module._attendanceUiHandle then
		module:CancelTimer(module._attendanceUiHandle)
		module._attendanceUiHandle = nil
	end
	module._attendanceUiHandle = module:ScheduleTimer(function()
		module._attendanceUiHandle = nil
		if not isViewingCurrentRaid() then
			return
		end
		markAttendanceListsDirty()
	end, 0.25)
end

local function updateRaidAttendanceFromRoster()
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

	local delta = Raid:RefreshAndPublish()
	module.attendanceSelectedPlayer = nil
	markAttendanceListsDirty()
	return delta
end

local function deleteSelectedRaidAttendancePlayer()
	local selectedRaid = module.attendanceSelectedRaid
	local playerNid = module.attendanceSelectedPlayer
	if not (selectedRaid and playerNid) then
		return
	end

	local raid = AttendanceStore:GetRaid(selectedRaid)
	local raidNid = tonumber(raid and raid.raidNid)
	if not raidNid then
		addon:warn(L.MsgAttendanceRemoveFailed)
		return
	end

	local removed = AttendanceActions:DeleteRaidAttendance(raidNid, { playerNid })
	if removed and removed > 0 then
		module.attendanceSelectedPlayer = nil
		TriggerEvent(AttendanceEvents.LoggerClearPlayerSelections)
		markAttendanceListsDirty()
		addon:info(L.MsgAttendanceRemoved:format(removed))
	else
		addon:warn(L.MsgAttendanceRemoveFailed)
	end
end

local function showForceInspectFeedback(ok, status)
	if status == "queued" then
		addon:info(L.StrInspectQueued)
		return
	end
	if status == "pending" then
		addon:info(L.StrInspectPending)
		return
	end
	if not ok then
		local warnings = {
			missing_unit = L.MsgForceInspectMissingUnit,
			offline = L.MsgForceInspectOffline,
			out_of_range = L.MsgForceInspectOutOfRange,
			cannot_inspect = L.MsgForceInspectCannotInspect,
			notify_failed = L.MsgForceInspectNotifyFailed,
		}
		addon:warn(warnings[status] or L.StrInspectNotInspected)
	end
end

attendanceRaidsController = makeAttendanceList(
	{
		keyName = "RaidAttendanceRaidsList",
		poolTag = "attendance-raids",
		_rowParts = { "ID", "Date", "Zone", "Size" },

		localize = function(n)
			setPanelTitle(n, L.StrRaidsList)
			_G[n .. "HeaderNum"]:SetText(L.StrNumber)
			_G[n .. "HeaderDate"]:SetText(L.StrDate)
			_G[n .. "HeaderZone"]:SetText(L.StrZone)
			_G[n .. "HeaderSize"]:SetText(L.StrSize)
			UI.Primitives.SetShown(_G[n .. "CurrentBtn"], false)
			UI.Primitives.SetShown(_G[n .. "DeleteBtn"], false)
			applyRaidListColumnWidths(n)
			bindSortHeaders(n, RAID_LAYOUT_COLUMNS, module.AttendanceRaids, "_RMAAttendanceRaidHeadersBound")
		end,

		getData = function(out)
			RaidProjections.FillRaidList(out)
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
			setPanelTitle(n, getCountTitle(L.StrRaidsList, count))
			setFrameHint(n, "EmptyState", count == 0 and L.StrLoggerEmptyRaids or nil)
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
	{
		transform = function(id) return id end,
		debugTag = "RaidAttendanceSelectRaid",
	}
)

module.AttendanceRaids = module.AttendanceRaids or {}
UI.Lists.BindController(module.AttendanceRaids, attendanceRaidsController)

attendancePlayersController = makeAttendanceList({
	keyName = "RaidAttendancePlayersList",
	poolTag = "attendance-players",
	_rowParts = { "Name", "Join", "Leave", "Ilvl", "Spec", "InspectStatus" },

	localize = function(n)
		local frame = _G[n]
		setPanelTitle(n, L.StrRaidAttendees)
		_G[n .. "HeaderName"]:SetText(L.StrName)
		_G[n .. "HeaderJoin"]:SetText(L.StrJoin)
		_G[n .. "HeaderLeave"]:SetText(L.StrLeave)
		_G[n .. "HeaderIlvl"]:SetText(L.StrIlvl)
		_G[n .. "HeaderSpec"]:SetText(L.StrSpec)
		_G[n .. "HeaderInspect"]:SetText(L.StrInspectItems)
		applyAttendanceListColumnWidths(n)
		if _G[n .. "AddBtn"] then
			_G[n .. "AddBtn"]:SetText(L.BtnUpdate)
			SetScriptSafely(_G[n .. "AddBtn"], "OnClick", updateRaidAttendanceFromRoster)
		end
		if _G[n .. "DeleteBtn"] then
			_G[n .. "DeleteBtn"]:SetText(L.BtnDelete)
			SetScriptSafely(_G[n .. "DeleteBtn"], "OnClick", deleteSelectedRaidAttendancePlayer)
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
				local ok, status = ForceInspectPlayer(EquipInspect, selectedRaid, selectedPlayer)
				showForceInspectFeedback(ok, status)
				if attendancePlayersController then
					attendancePlayersController:Dirty()
				end
			end)
		end
		local exportBtn = frame and GetFrameRef(frame, "ExportBtn") or nil
		if exportBtn then
			exportBtn:SetText(L.BtnLoggerExportRaidAttendanceCSV)
			SetScriptSafely(exportBtn, "OnClick", showAttendanceExport)
		end
		bindSortHeaders(n, ATTENDANCE_LAYOUT_COLUMNS, attendancePlayersController, "_RMAAttendanceHeadersBound")
	end,

	getData = function(out)
		local raid = getAttendanceRaid()
		if not raid then
			return
		end
		AttendanceView:FillRaidAttendeesList(out, raid)
	end,

	rowName = UI.Lists.MakeIndexedRowName("PlayerBtn"),
	rowTmpl = "RMARaidAttendancePlayerRowTemplate",
	rowHeight = AttendanceLayout.COMPACT_ROW_HEIGHT + 1,
	drawRow = UI.Lists.CreateRowRenderer(function(row, it)
		if not row._RMAAttendanceBound then
			SetScriptSafely(row, "OnClick", function(self, button)
				selectAttendancePlayer(self, button)
			end)
			row._RMAAttendanceBound = true
		end
		local ui = row._p
		local hotspot = getAttendanceLootBanHotspot(row, ui)
		local lootBanIcon = getAttendanceLootBanIcon(row)
		applyAttendanceRowColumnWidths(ui, ATTENDANCE_PLAYERS_FRAME)
		local calculatedNameWidth = ui.Name:GetWidth()
		local lootBanNameInset = 17
		local rowId = it.id or it.playerNid
		if rowId then
			row:SetID(tonumber(rowId) or rowId)
		end
		row._RMAPlayerNid = rowId
		ui.Name:SetText(it.name)
		local lootBanned, lootBanNote = LootBans.Get(it.name)
		hotspot._RMALootBanActive = lootBanned
		hotspot._RMALootBanNote = lootBanNote
		lootBanIcon._RMALootBanActive = lootBanned
		lootBanIcon._RMALootBanNote = lootBanNote
		ui.Name:ClearAllPoints()
		if lootBanned then
			row._RMALootBanIcon:Show()
			ui.Name:SetPoint("TOPLEFT", row, "TOPLEFT", 20, -1)
			ui.Name:SetWidth(calculatedNameWidth - lootBanNameInset)
			ui.Name:SetVertexColor(0.5, 0.5, 0.5)
		else
			row._RMALootBanIcon:Hide()
			ui.Name:SetPoint("TOPLEFT", row, "TOPLEFT", 3, -1)
			ui.Name:SetWidth(calculatedNameWidth)
			local r, g, b = Colors.GetClassColor(it.class)
			ui.Name:SetVertexColor(r, g, b)
		end
		ui.Join:SetText(it.joinFmt)
		ui.Leave:SetText(it.leaveFmt)
		ui.Ilvl:SetText(it.avgIlvlFmt or "")
		setAttendanceSpecIcon(
			row,
			it.inspect and it.inspect.specIcon,
			it.inspect and it.inspect.secondarySpecIcon,
			it.inspect and it.inspect.specName,
			it.inspect and it.inspect.secondarySpecName
		)
		renderAttendanceInspectIcons(row, row._RMAPlayerNid, it.inspect)
	end),

	postUpdate = function(n)
		applyAttendanceListColumnWidths(n)
		local count = 0
		if attendancePlayersController and attendancePlayersController.data then
			count = #attendancePlayersController.data
		end
		setPanelTitle(
			n,
			getCountContextTitle(L.StrRaidAttendees, count, getRaidContextLabel(module.attendanceSelectedRaid))
		)
		setFrameHint(n, "EmptyState", getRaidAttendeesEmptyStateText(count, module.attendanceSelectedRaid))

		local currentRaid = Database.GetCurrentRaid()
		local canUpdate = addon.IsInRaid()
			and currentRaid
			and module.attendanceSelectedRaid
			and (tonumber(currentRaid) == tonumber(module.attendanceSelectedRaid))
		UI.Primitives.SetEnabled(_G[n .. "AddBtn"], canUpdate)
		UI.Primitives.SetEnabled(_G[n .. "DeleteBtn"], module.attendanceSelectedPlayer ~= nil)
		UI.Primitives.SetEnabled(
			_G[n .. "ForceInspectBtn"],
			currentRaid
					and module.attendanceSelectedPlayer
					and module.attendanceSelectedRaid
					and tonumber(module.attendanceSelectedRaid) == tonumber(currentRaid)
					and true
				or false
		)
		UI.Primitives.SetEnabled(_G[n .. "ExportBtn"], module.attendanceSelectedRaid ~= nil)
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
}, "attendanceSelectedPlayer", { debugTag = "RaidAttendanceSelectPlayer" })

module.AttendancePlayers = module.AttendancePlayers or {}
UI.Lists.BindController(module.AttendancePlayers, attendancePlayersController)

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

	Rows.ApplyLoggerSkin({
		"RMARaidAttendanceRaids",
		"RMARaidAttendanceRaidAttendees",
	})
	refreshRaidAttendanceLayout()
	attendanceUi.Bound = true
	return frame
end

function module.Toggle()
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

RegisterCallback(AttendanceEvents.RaidCreate, function(_, raidId)
	local frame = getAttendanceFrame()
	if not (frame and frame.IsShown and frame:IsShown()) then
		return
	end
	module.attendanceSelectedRaid = tonumber(raidId) or raidId
	module.attendanceSelectedPlayer = nil
	markAttendanceListsDirty()
end)

RegisterCallback(AttendanceEvents.EquipInspectUpdated, function(_, raidNid)
	local raidId = raidNid and Database.GetRaidIndexByNid(raidNid) or nil
	if not (module.attendanceSelectedRaid and tonumber(module.attendanceSelectedRaid) == tonumber(raidId)) then
		return
	end
	if attendancePlayersController then
		attendancePlayersController:Dirty()
	end
end)

RegisterCallback(AttendanceEvents.EquipInspectCompleted, function(_, raidNid)
	local raidId = raidNid and Database.GetRaidIndexByNid(raidNid) or nil
	if not (module.attendanceSelectedRaid and tonumber(module.attendanceSelectedRaid) == tonumber(raidId)) then
		return
	end
	if attendancePlayersController then
		attendancePlayersController:Dirty()
	end
end)

RegisterCallback(AttendanceEvents.RaidAttendanceChanged, function(_, raidNid)
	local raidId = raidNid and Database.GetRaidIndexByNid(raidNid) or nil
	if not (module.attendanceSelectedRaid and tonumber(module.attendanceSelectedRaid) == tonumber(raidId)) then
		return
	end
	markAttendanceListsDirty()
end)

RegisterCallback(AttendanceEvents.LootBansChanged, function()
	markAttendanceListsDirty()
end)
