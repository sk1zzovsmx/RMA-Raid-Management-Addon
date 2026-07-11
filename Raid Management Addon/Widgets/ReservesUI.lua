-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: direct addon namespace bindings
-- exports: publish module APIs on addon.*
-- events: listens ReservesDataChanged and GET_ITEM_INFO_RECEIVED
local addon = select(2, ...)
local L = addon.L
local Diag = addon.Diag

local Widgets = addon.Widgets
local UI = addon.UI
local Frames = UI.Frames
local Scaffold = UI.Scaffold
local Popups = assert(UI.Popups, "Reserves UI popup namespace is not initialized")
local DefinePopup = assert(Popups.Define, "Reserves UI popup definer is not initialized")
local DefineConfirmPopup = assert(Popups.DefineConfirm, "Reserves UI confirm popup definer is not initialized")
local IsPopupDefined = assert(Popups.IsDefined, "Reserves UI popup defined-state checker is not initialized")
local ShowPopup = assert(Popups.Show, "Reserves UI popup shower is not initialized")
local ShowConfirmPopup = assert(Popups.ShowConfirm, "Reserves UI confirm popup shower is not initialized")
local Primitives = UI.Primitives
local EditBoxes = UI.EditBoxes
local Tooltips = UI.Tooltips
local HideTooltip = assert(Tooltips.Hide, "Reserves UI tooltip hider is not initialized")
local ShowItemTooltip = assert(Tooltips.ShowItem, "Reserves UI item tooltip presenter is not initialized")
local BindTooltip = assert(Tooltips.Bind, "Reserves UI tooltip binder is not initialized")
local Events = addon.Events
local C = addon.C
local Colors = addon.Colors
local GetClassColor = assert(Colors.GetClassColor, "Reserves UI class-color resolver is not initialized")
local Options = addon.Options
local Bus = addon.Bus
local Services = addon.Services

local _G = _G
local tinsert, twipe = table.insert, table.wipe
local pairs, type = pairs, type
local format = string.format
local tostring, tonumber = tostring, tonumber
local ChatEdit_InsertLink = ChatEdit_InsertLink
local GetTime = assert(_G.GetTime, "Reserves UI time API is not initialized")
local GetItemIcon = GetItemIcon
local GetNumRaidMembers = assert(_G.GetNumRaidMembers, "Reserves UI raid member count API is not initialized")
local IsModifiedClick = IsModifiedClick
local UnitName = assert(_G.UnitName, "Reserves UI unit name API is not initialized")
local UnitInRaid = UnitInRaid
local GetOptionsNamespace = assert(Options.Get, "Reserves UI options namespace resolver is not initialized")
local Reserves = assert(Services.Reserves, "Reserves UI service is not initialized")
local HasReserveData = assert(Reserves.HasData, "Reserves UI data-state resolver is not initialized")
local IsPlusReserveSystem = assert(Reserves.IsPlusSystem, "Reserves UI import-mode resolver is not initialized")
local HasPendingReserveItem = assert(Reserves.HasPendingItem, "Reserves UI pending-item resolver is not initialized")
local RemovePlayerReserve =
	assert(Reserves.RemovePlayerReserve, "Reserves UI remove-reserve handler is not initialized")
local ClearSavedReserves = assert(Reserves.ClearSavedReserves, "Reserves UI clear-saved handler is not initialized")
local GetReserveDisplayList = assert(Reserves.GetDisplayList, "Reserves UI display-list resolver is not initialized")
local GetImportMode = assert(Reserves.GetImportMode, "Reserves UI import-mode getter is not initialized")
local ParseImport = assert(Reserves.ParseImport, "Reserves UI import parser is not initialized")
local RequestApplyImport = assert(Reserves.RequestApplyImport, "Reserves UI import-apply handler is not initialized")
local SetImportMode = assert(Reserves.SetImportMode, "Reserves UI import-mode setter is not initialized")
local Chat = assert(Services.Chat, "Reserves UI chat service is not initialized")
local AnnounceChat = assert(Chat.Announce, "Reserves UI chat announcer is not initialized")
local Raid = assert(Services.Raid, "Reserves UI raid service is not initialized")
local GetPlayerClass = assert(Raid.GetPlayerClass, "Reserves UI raid class resolver is not initialized")

local function getReservesOptions()
	return GetOptionsNamespace("Reserves")
end

local function isWidgetChecked(widget)
	if not widget or not widget.GetChecked then
		return false
	end
	local checked = widget:GetChecked()
	return checked == true or checked == 1
end

local InternalEvents = assert(Events.Internal, "Reserves UI internal events are not initialized")
local RegisterCallback = assert(Bus.RegisterCallback, "Reserves UI event bus listener is not initialized")
local ReservesDataChangedEvent =
	assert(InternalEvents.ReservesDataChanged, "Reserves UI data-changed event is not initialized")

do
	Widgets.ReservesUI = Widgets.ReservesUI or {}
	local module = Widgets.ReservesUI
	local uiState = UI.ModuleState.Ensure(module)

	-- ----- Internal state ----- --

	local getFrame = Frames.MakeModuleFrameGetter(module, "RMAReserveListFrame")
	local scrollFrame, scrollChild
	local reserveHeaders = {}
	local reserveItemRows = {}
	local rowsByItemID = {}
	local collapsedItems = {}
	local isEditMode = false
	local reserveHeaderHeight = 30
	local reservePlayerRowHeight = 24
	local lastQueryAttemptAt = 0
	local CLEAR_SAVED_RESERVES_POPUP_KEY = "RMA_RESERVES_CLEAR_SAVED"
	local REMOVE_RESERVE_ROW_POPUP_KEY = "RMA_RESERVES_REMOVE_ROW"
	local APPLY_RESERVE_EDITS_POPUP_KEY = "RMA_RESERVES_APPLY_EDITS"
	local queryCooldownSeconds = tonumber(C.RESERVES_QUERY_COOLDOWN_SECONDS) or 2
	local fallbackIcon = C.RESERVES_ITEM_FALLBACK_ICON
	local collapseButtonSize = 16
	local collapseExpandedTexture = "Interface\\Buttons\\UI-MinusButton-Up"
	local collapseCollapsedTexture = "Interface\\Buttons\\UI-PlusButton-Up"
	local collapseExpandedPushedTexture = "Interface\\Buttons\\UI-MinusButton-Down"
	local collapseCollapsedPushedTexture = "Interface\\Buttons\\UI-PlusButton-Down"

	-- ----- Private helpers ----- --
	local isDebugEnabled = Options.IsDebugEnabled

	local function hasReserveData()
		return HasReserveData(Reserves)
	end

	local function isPlusReserveMode()
		return IsPlusReserveSystem(Reserves)
	end

	local function applyCollapseButtonState(button, collapsed)
		if not button then
			return
		end

		if collapsed then
			if button.SetNormalTexture then
				button:SetNormalTexture(collapseCollapsedTexture)
			end
			if button.SetPushedTexture then
				button:SetPushedTexture(collapseCollapsedPushedTexture)
			end
		else
			if button.SetNormalTexture then
				button:SetNormalTexture(collapseExpandedTexture)
			end
			if button.SetPushedTexture then
				button:SetPushedTexture(collapseExpandedPushedTexture)
			end
		end
		if button.Show then
			button:Show()
		end
	end

	local function hideItemTooltip()
		HideTooltip()
	end

	local function showItemTooltip(owner, row)
		if not owner or not row then
			return
		end

		local link = row._itemLink
		if (not link or link == "") and row._itemId then
			link = "item:" .. tostring(row._itemId)
		end

		return ShowItemTooltip(owner, link, row._tooltipTitle, "ANCHOR_RIGHT")
	end

	local function insertHeaderItemLink(row)
		local link = row and row._itemLink
		if
			link
			and link ~= ""
			and type(IsModifiedClick) == "function"
			and IsModifiedClick("CHATLINK")
			and type(ChatEdit_InsertLink) == "function"
		then
			ChatEdit_InsertLink(link)
			return true
		end
		return false
	end

	local function getRaidMemberCount()
		local count = tonumber(GetNumRaidMembers()) or 0
		return count > 0 and count or 0
	end

	local function setPlayerNameAnchor(row)
		if not row or not row.nameText then
			return
		end

		row.nameText:ClearAllPoints()
		if row.editSlot then
			row.nameText:SetPoint("LEFT", row.editSlot, "RIGHT", 8, 0)
			return
		end
		row.nameText:SetPoint("LEFT", row, "LEFT", 64, 0)
	end

	function uiState.AcquireRefs(frame)
		return {
			whisperHelpButton = Frames.GetRef(frame, "WhisperHelpButton"),
			importButton = Frames.GetRef(frame, "ImportButton"),
			clearBtn = Frames.GetRef(frame, "ClearBtn"),
			editButton = Frames.GetRef(frame, "EditButton"),
			queryButton = Frames.GetRef(frame, "QueryButton"),
			softResHelpText = Frames.GetRef(frame, "SoftResHelpText"),
			softResStatusText = Frames.GetRef(frame, "SoftResStatusText"),
			softResAccept = Frames.GetRef(frame, "SoftResAccept"),
			softResResponseWisp = Frames.GetRef(frame, "SoftResResponseWisp"),
			softResAcceptStr = Frames.GetRef(frame, "SoftResAcceptStr"),
			softResResponseWispStr = Frames.GetRef(frame, "SoftResResponseWispStr"),
			scrollFrame = frame.ScrollFrame or _G["RMAReserveListFrameScrollFrame"],
			scrollChild = (frame.ScrollFrame and frame.ScrollFrame.ScrollChild) or _G["RMAReserveListFrameScrollChild"],
		}
	end

	local function setPlayerEditState(row)
		if not row then
			return
		end
		local isPlusMode = isPlusReserveMode()
		local currentValue = isPlusMode and (tonumber(row._plus) or 0) or (tonumber(row._quantity) or 1)
		local visibleValue = tostring(currentValue)
		if row.removeButton then
			if isEditMode then
				row.removeButton:Show()
			else
				row.removeButton:Hide()
			end
			Primitives.SetEnabled(row.removeButton, isEditMode)
		end
		if row.quantityEdit then
			if isEditMode then
				if row.quantityText then
					row.quantityText:Hide()
				end
				row.quantityEdit:Show()
				row.quantityEdit:SetNumber(currentValue)
				row.quantityEdit._RMAReserveEditBase = visibleValue
				row.quantityEdit._RMAReserveHasMode = isPlusMode and "plus" or "multi"
			else
				if row.quantityText then
					row.quantityText:Show()
				end
				row.quantityEdit:Hide()
			end
		end
		if row.quantityText then
			if not isEditMode then
				row.quantityText:Show()
			end
		end
	end

	local function applyReservePlayerRowData(row, info, itemInfo)
		if not row or not info then
			return
		end
		local playerName = type(info) == "table" and info.name or info
		local displayName = type(info) == "table" and (info.displayName or info.name) or playerName
		local className = type(info) == "table" and info.class or nil
		if (not className or className == "" or className == "UNKNOWN") and playerName then
			local rosterClass = GetPlayerClass(Raid, playerName)
			if rosterClass and rosterClass ~= "" and rosterClass ~= "UNKNOWN" then
				className = rosterClass
			end
		end
		local quantity = type(info) == "table" and info.quantity or 1
		local plus = type(info) == "table" and tonumber(info.plus) or 0
		local checked = type(info) == "table" and info.checked or true
		local itemData = itemInfo or info

		row._itemId = itemData.itemId
		row._itemLink = itemData.itemLink
		row._itemName = itemData.itemName
		row._playerName = playerName
		row._playerChecked = checked
		row._quantity = quantity
		row._plus = plus
		row._quantityPlayer = quantity

		if row.nameText then
			row.nameText:SetText(displayName or "?")
			local r, g, b = GetClassColor(className)
			row.nameText:SetTextColor(r, g, b)
		end
		if row.quantityText then
			local isPlusMode = isPlusReserveMode()
			row.quantityText:SetText(tostring(isPlusMode and (plus or 0) or (quantity or 1)))
		end
		if row.quantityEdit then
			local isPlusMode = isPlusReserveMode()
			row.quantityEdit:SetText(tostring(isPlusMode and (plus or 0) or (quantity or 1)))
			row.quantityEdit._RMAReserveEditBase = tostring(isPlusMode and (plus or 0) or (quantity or 1))
			row.quantityEdit._RMAReserveHasMode = isPlusMode and "plus" or "multi"
		end

		if row.removeButton then
			row.removeButton:SetText(L.BtnRemoveShort)
			row.removeButton._playerName = playerName
			row.removeButton._itemId = itemData.itemId
			row.removeButton._itemName = itemData.itemName
			row.removeButton._itemLink = itemData.itemLink
		end
		setPlayerEditState(row)
	end

	local function restoreRowEditValue(row)
		if not row or not row.quantityEdit then
			return
		end
		local baseline = row.quantityEdit._RMAReserveEditBase or "1"
		row.quantityEdit:SetText(tostring(baseline))
		row.quantityEdit._RMAReserveEditValue = tostring(baseline)
	end

	local function getReserveRemoveLabel()
		local label = L.BtnDelete
		if label == "BtnDelete" then
			label = L.BtnRemove
			if label == "BtnRemove" then
				label = L.BtnRemoveShort
			end
		end
		return label
	end

	local function showReserveConfirm(key, text, onAccept, cancels, options)
		DefineConfirmPopup(key, text, onAccept, cancels, options)
		return ShowConfirmPopup(key, text, onAccept, cancels, options)
	end

	local function clearReserveRowEditFocus(editBox)
		if editBox then
			editBox:ClearFocus()
		end
	end

	local function buildRowEditCommit(row)
		if not row or not row.quantityEdit or not Reserves then
			return nil
		end

		local isPlusMode = isPlusReserveMode()
		local raw = row.quantityEdit:GetText()
		local nextValue = tonumber(raw)
		if not nextValue then
			restoreRowEditValue(row)
			return nil, "invalid_value"
		end
		nextValue = math.floor(nextValue)
		if isPlusMode then
			if nextValue < 0 then
				nextValue = 0
			end
			row.quantityEdit:SetText(tostring(nextValue))
			return {
				editBox = row.quantityEdit,
				itemId = row._itemId,
				playerName = row._playerName,
				value = nextValue,
				isPlusMode = true,
			}
		end

		if nextValue < 1 then
			nextValue = 1
		end
		row.quantityEdit:SetText(tostring(nextValue))
		return {
			editBox = row.quantityEdit,
			itemId = row._itemId,
			playerName = row._playerName,
			value = nextValue,
			isPlusMode = false,
		}
	end

	local function applyRowEditCommit(edit)
		if not edit or not Reserves then
			return false
		end
		if edit.isPlusMode then
			return Reserves:SetPlayerReservePlus(edit.playerName, edit.itemId, edit.value)
		end
		return Reserves:SetPlayerReserveQuantity(edit.playerName, edit.itemId, edit.value)
	end

	local function commitRowEdit(row)
		local edit, reason = buildRowEditCommit(row)
		if not edit then
			return false, reason
		end
		return applyRowEditCommit(edit)
	end

	local function collectVisibleReserveEdits()
		local edits = {}
		for i = 1, #reserveItemRows do
			local row = reserveItemRows[i]
			local editBox = row and row.quantityEdit
			if editBox then
				local nextValue = tostring(editBox:GetText() or "")
				local baseValue = tostring(editBox._RMAReserveEditBase or "")
				if nextValue ~= baseValue then
					local edit = buildRowEditCommit(row)
					if edit then
						edits[#edits + 1] = edit
					end
				end
			end
		end
		return edits
	end

	local function applyVisibleReserveEdits(edits)
		for i = 1, #edits do
			local edit = edits[i]
			applyRowEditCommit(edit)
			if edit.editBox and edit.editBox._RMAReserveEditBase then
				edit.editBox._RMAReserveEditBase = tostring(edit.value)
			end
		end
	end

	local function getReserveItemConfirmText(itemId, itemName, itemLink)
		if type(itemLink) == "string" and itemLink ~= "" then
			return itemLink
		end
		if type(itemName) == "string" and itemName ~= "" then
			return "[" .. itemName .. "]"
		end
		return tostring(itemId)
	end

	local function confirmRemovePlayerReserveFromUI(playerName, itemId, itemName, itemLink)
		if not playerName or not itemId then
			return false
		end

		local options = {
			button1 = getReserveRemoveLabel(),
			button2 = L.BtnCancel,
		}

		local function onAccept()
			RemovePlayerReserve(Reserves, playerName, itemId)
			module:RequestRefresh("remove_reserve")
		end

		local itemText = getReserveItemConfirmText(itemId, itemName, itemLink)
		local popupText = format(L.StrConfirmRemoveReserveRow, tostring(playerName), itemText)
		if
			showReserveConfirm(REMOVE_RESERVE_ROW_POPUP_KEY, popupText, onAccept, REMOVE_RESERVE_ROW_POPUP_KEY, options)
		then
			return true
		end

		onAccept()
		return true
	end

	local function confirmApplyVisibleReserveEditsFromUI(edits, editButton)
		if #edits == 0 then
			return false
		end

		local options = {
			button1 = L.BtnSave,
			button2 = L.BtnCancel,
		}

		local function onAccept()
			applyVisibleReserveEdits(edits)
			isEditMode = false
			if editButton then
				editButton._RMAReserveEditMode = false
			end
			module:RequestRefresh("commit_reserve_edits")
		end

		local popupText = format(L.StrConfirmApplyReserveEdits, #edits)
		if
			showReserveConfirm(
				APPLY_RESERVE_EDITS_POPUP_KEY,
				popupText,
				onAccept,
				APPLY_RESERVE_EDITS_POPUP_KEY,
				options
			)
		then
			return true
		end

		onAccept()
		return true
	end

	local function applyReserveHeaderData(row, info, isCollapsed)
		if not row or not info then
			return
		end
		local itemIdLabel = format(L.StrReservesItemIdLabel, tostring(info.itemId or "?"))
		local itemFallback = format(L.StrReservesItemFallback, tostring(info.itemId or "?"))
		local icon = info.itemIcon
		if (type(icon) ~= "string" or icon == "") and info.itemId and type(GetItemIcon) == "function" then
			icon = GetItemIcon(info.itemId)
		end
		if type(icon) ~= "string" or icon == "" then
			icon = fallbackIcon
		end

		row._itemId = info.itemId
		row._itemLink = info.itemLink
		row._itemName = info.itemName
		row._tooltipTitle = info.itemLink or info.itemName or itemIdLabel
		row._playersTooltipLines = info.playersTooltipLines
		row._playersTextFull = info.playersTextFull or info.playersText

		local collapsed = isCollapsed == true
		if row.iconTexture then
			row.iconTexture:SetTexture(icon)
			if row.iconTexture.SetTexCoord then
				row.iconTexture:SetTexCoord(0.08, 0.92, 0.08, 0.92)
			end
			row.iconTexture:Show()
		end
		if row.nameText then
			row.nameText:SetText(info.itemLink or info.itemName or itemFallback)
			if row.nameText.GetStringWidth and row.nameText.SetWidth then
				row.nameText:SetWidth((row.nameText:GetStringWidth() or 0) + 6)
			end
		end
		if row.itemNameHotspot and row.nameText and row.nameText.GetWidth then
			row.itemNameHotspot:SetWidth(row.nameText:GetWidth() or 170)
		end
		if row.collapseText then
			row.collapseText:SetText("")
			row.collapseText:Hide()
		end
		applyCollapseButtonState(row.collapseButton, collapsed)
		if row.line then
			row.line:Show()
		end
	end

	local function reserveHeaderOnClick(self)
		local itemId = self and self._itemId
		if not itemId then
			return
		end
		collapsedItems[itemId] = not (collapsedItems[itemId] == true)
		module:RequestRefresh()
	end

	local function reserveHeaderHotspotOnEnter(self)
		showItemTooltip(self, self and self._RMAReserveHeader)
	end

	local function reserveHeaderHotspotOnLeave()
		hideItemTooltip()
	end

	local function reserveHeaderHotspotOnClick(self)
		local header = self and self._RMAReserveHeader
		insertHeaderItemLink(header)
	end

	function uiState.Localize()
		if uiState.Localized then
			if isDebugEnabled() then
				addon:debug(Diag.D.LogReservesUIAlreadyLocalized)
			end
			return
		end
		local frameName = uiState.FrameName
		if not frameName then
			return
		end
		if frameName then
			Frames.SetFrameTitle(frameName, L.StrRaidReserves)
			if isDebugEnabled() then
				addon:debug(Diag.D.LogReservesUILocalized:format(L.StrRaidReserves))
			end
		end
		local clearBtn = frameName and _G[frameName .. "ClearBtn"]
		if clearBtn then
			clearBtn:SetText(L.BtnClear)
		end
		local editButton = frameName and _G[frameName .. "EditButton"]
		if editButton then
			editButton:SetText(L.BtnEdit)
		end
		local queryButton = frameName and _G[frameName .. "QueryButton"]
		if queryButton then
			queryButton:SetText(L.BtnQueryItem)
		end
		local importButton = frameName and _G[frameName .. "ImportButton"]
		if importButton then
			importButton:SetText(L.BtnImport)
		end
		local whisperHelpButton = frameName and _G[frameName .. "WhisperHelpButton"]
		if whisperHelpButton then
			whisperHelpButton:SetText(L.BtnSpamSoftResWhisper)
		end
		local softResAcceptLabel = frameName and _G[frameName .. "SoftResAcceptStr"]
		if softResAcceptLabel then
			softResAcceptLabel:SetText(L.StrReserveListAcceptSR)
		end
		local softResResponseWispLabel = frameName and _G[frameName .. "SoftResResponseWispStr"]
		if softResResponseWispLabel then
			softResResponseWispLabel:SetText(L.StrReserveListResponseWisp)
		end
		local softResHelpText = frameName and _G[frameName .. "SoftResHelpText"]
		if softResHelpText then
			softResHelpText:SetText(L.StrReserveListWhisperHelp)
		end
		uiState.Localized = true
	end

	function uiState.Refresh()
		local frameName = uiState.FrameName
		if not frameName then
			return
		end
		local hasData = hasReserveData()
		if not hasData then
			isEditMode = false
		end
		local clearBtn = _G[frameName .. "ClearBtn"]
		if clearBtn then
			clearBtn:SetText(L.BtnClear)
			if hasData then
				clearBtn:Show()
				Primitives.SetEnabled(clearBtn, true)
			else
				clearBtn:Hide()
				Primitives.SetEnabled(clearBtn, false)
			end
		end
		local editButton = _G[frameName .. "EditButton"]
		if editButton then
			editButton:SetText(L.BtnEdit)
			editButton:Show()
			Primitives.SetEnabled(editButton, hasData)
			if Primitives.SetHighlighted then
				Primitives.SetHighlighted(editButton, isEditMode)
			elseif isEditMode and editButton.LockHighlight then
				editButton:LockHighlight()
			elseif editButton.UnlockHighlight then
				editButton:UnlockHighlight()
			end
			editButton._RMAReserveEditMode = isEditMode
		end
		local queryButton = _G[frameName .. "QueryButton"]
		if queryButton then
			Primitives.SetEnabled(queryButton, hasData)
		end

		local reservesNs = getReservesOptions()
		local softResAcceptEnabled = false
		local softResResponseWispEnabled = false
		local softResAccept = _G[frameName .. "SoftResAccept"]
		if reservesNs then
			local value = reservesNs:Get("softResWhisperAdds")
			if value == nil then
				value = false
			end
			softResAcceptEnabled = value == true
			if softResAccept and softResAccept.SetChecked then
				softResAccept:SetChecked(softResAcceptEnabled)
			end
		end
		local softResResponseWisp = _G[frameName .. "SoftResResponseWisp"]
		if reservesNs then
			local value = reservesNs:Get("softResWhisperReplies")
			if value == nil then
				value = false
			end
			softResResponseWispEnabled = value == true
			if softResResponseWisp and softResResponseWisp.SetChecked then
				softResResponseWisp:SetChecked(softResResponseWispEnabled)
			end
		end
		local whisperHelpButton = _G[frameName .. "WhisperHelpButton"]
		if whisperHelpButton then
			Primitives.SetEnabled(whisperHelpButton, softResAcceptEnabled or softResResponseWispEnabled)
		end
	end

	local function setupReserveRowDecor(row)
		if not row or row._decorInitialized then
			return
		end

		local rowName = row.GetName and row:GetName() or nil
		row.topSeparator = rowName and _G[rowName .. "TopSeparator"] or nil
		row.separator = rowName and _G[rowName .. "BottomSeparator"] or nil

		if row.topSeparator and row.topSeparator.Hide then
			row.topSeparator:Hide()
		end

		row._decorInitialized = true
	end

	local function createReserveHeader(parent, info, yOffset, index)
		local frameName = uiState.FrameName
		if not frameName then
			return nil
		end
		local headerName = frameName .. "ReserveHeader" .. index
		local header = _G[headerName] or CreateFrame("Button", headerName, parent, "RMAReserveHeaderTemplate")
		header:ClearAllPoints()
		header:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -yOffset)
		header._itemId = info.itemId
		if not header._initialized then
			header.itemIconButton = _G[headerName .. "ItemIcon"]
			header.iconTexture = _G[headerName .. "ItemIconIconTexture"]
			header.itemIconNormalTexture = _G[headerName .. "ItemIconNormalTexture"]
			header.nameText = _G[headerName .. "Name"]
			header.line = _G[headerName .. "Line"]
			header.collapseText = _G[headerName .. "Collapse"]
			header.collapseButton = _G[headerName .. "CollapseButton"]
				or CreateFrame("Button", headerName .. "CollapseButton", header)
			header.itemIconHotspot = header.itemIconButton
			header.itemNameHotspot = _G[headerName .. "ItemNameHotspot"]
			if header.collapseText then
				header.collapseText:SetWidth(collapseButtonSize)
				header.collapseText:SetHeight(collapseButtonSize)
				header.collapseText:SetText("")
				header.collapseText:Hide()
			end
			if header.collapseButton then
				header.collapseButton:ClearAllPoints()
				if header.collapseText then
					header.collapseButton:SetPoint("CENTER", header.collapseText, "CENTER", 0, 0)
				else
					header.collapseButton:SetPoint("RIGHT", header, "RIGHT", -2, 0)
				end
				header.collapseButton:SetWidth(collapseButtonSize)
				header.collapseButton:SetHeight(collapseButtonSize)
				Frames.SetScriptSafely(header.collapseButton, "OnClick", reserveHeaderOnClick)
			end
			if header.iconTexture then
				header.iconTexture:SetWidth(26)
				header.iconTexture:SetHeight(26)
			end
			if header.itemIconNormalTexture then
				header.itemIconNormalTexture:SetWidth(32)
				header.itemIconNormalTexture:SetHeight(32)
			end
			if header.itemIconHotspot then
				header.itemIconHotspot._RMAReserveHeader = header
				Frames.SetScriptSafely(header.itemIconHotspot, "OnEnter", reserveHeaderHotspotOnEnter)
				Frames.SetScriptSafely(header.itemIconHotspot, "OnLeave", reserveHeaderHotspotOnLeave)
				Frames.SetScriptSafely(header.itemIconHotspot, "OnClick", reserveHeaderHotspotOnClick)
			end
			if header.itemNameHotspot then
				header.itemNameHotspot._RMAReserveHeader = header
				Frames.SetScriptSafely(header.itemNameHotspot, "OnEnter", reserveHeaderHotspotOnEnter)
				Frames.SetScriptSafely(header.itemNameHotspot, "OnLeave", reserveHeaderHotspotOnLeave)
				Frames.SetScriptSafely(header.itemNameHotspot, "OnClick", reserveHeaderHotspotOnClick)
			end
			Frames.SetScriptSafely(header, "OnClick", nil)
			header._initialized = true
		end

		if header.collapseButton then
			header.collapseButton._itemId = info.itemId
		end
		local collapsed = collapsedItems[info.itemId] == true
		applyReserveHeaderData(header, info, collapsed)

		header:Show()
		return header
	end

	local function createReserveRow(parent, itemInfo, playerInfo, yOffset, index)
		local frameName = uiState.FrameName
		if not frameName then
			return nil
		end
		local rowName = frameName .. "ReserveRow" .. index
		local row = _G[rowName] or CreateFrame("Button", rowName, parent, "RMAReservePlayerRowTemplate")
		row:ClearAllPoints()
		row:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -yOffset)
		row._rawID = itemInfo.itemId

		if
			not row._initialized
			or not row.nameText
			or not row.quantityText
			or not row.quantityEdit
			or not row.removeButton
			or not row.editSlot
		then
			row.background = _G[rowName .. "Background"]
			setupReserveRowDecor(row)
			row.nameText = _G[rowName .. "Name"]
			row.quantityText = _G[rowName .. "Quantity"]
			row.quantityEdit = _G[rowName .. "QuantityEdit"]
			row.removeButton = _G[rowName .. "RemoveBtn"]
			row.editSlot = _G[rowName .. "EditSlot"]
			if row.removeButton then
				row.removeButton:ClearAllPoints()
				row.removeButton:SetPoint("LEFT", row, "LEFT", 40, 0)
				row.removeButton:SetText(getReserveRemoveLabel())
				Frames.SetScriptSafely(row.removeButton, "OnEnter", nil)
				Frames.SetScriptSafely(row.removeButton, "OnLeave", nil)
				Frames.SetScriptSafely(row.removeButton, "OnClick", function()
					local playerName = row._playerName
					local itemId = row._itemId
					local itemName = row._itemName
					local itemLink = row._itemLink
					if not isEditMode or not playerName or not itemId then
						return
					end
					confirmRemovePlayerReserveFromUI(playerName, itemId, itemName, itemLink)
				end)
			end
			if row.quantityEdit then
				Frames.SetScriptSafely(row.quantityEdit, "OnEnterPressed", function(edit)
					if not edit then
						return
					end
					commitRowEdit(edit._RMAReserveRow)
					clearReserveRowEditFocus(edit)
				end)
				Frames.SetScriptSafely(row.quantityEdit, "OnEscapePressed", function(edit)
					if not edit then
						return
					end
					restoreRowEditValue(edit._RMAReserveRow)
					clearReserveRowEditFocus(edit)
				end)
			end
			if row.nameText then
				row.nameText:ClearAllPoints()
				row.nameText:SetWidth(190)
			end
			if row.quantityEdit then
				row.quantityEdit._RMAReserveRow = row
			end
			setPlayerNameAnchor(row)
			row._initialized = true
		end

		applyReservePlayerRowData(row, playerInfo, itemInfo)
		if row.quantityEdit then
			row.quantityEdit._RMAReserveRow = row
		end
		row:Show()
		rowsByItemID[itemInfo.itemId] = rowsByItemID[itemInfo.itemId] or {}
		tinsert(rowsByItemID[itemInfo.itemId], row)
		return row
	end

	local function renderReserveListUI()
		local frame = getFrame()
		if not frame or not scrollChild or not uiState.FrameName then
			return
		end
		for i = 1, #reserveItemRows do
			reserveItemRows[i]:Hide()
		end
		twipe(reserveItemRows)
		twipe(rowsByItemID)

		for i = 1, #reserveHeaders do
			reserveHeaders[i]:Hide()
		end
		twipe(reserveHeaders)

		local yOffset = 0
		local rowIndex = 0
		local headerIndex = 0
		local displayList = GetReserveDisplayList(Reserves)
		local reservedPlayerMap = {}

		for i = 1, #displayList do
			local entry = displayList[i]
			local players = entry and entry.players
			if type(players) == "table" then
				for j = 1, #players do
					local playerInfo = players[j]
					local playerName = type(playerInfo) == "table"
							and (playerInfo.name or playerInfo.playerName or playerInfo.playerNameDisplay)
						or playerInfo
					if type(playerName) == "string" and playerName ~= "" then
						reservedPlayerMap[playerName] = true
					end
				end
			end
		end

		for i = 1, #displayList do
			local entry = displayList[i]
			if entry and entry.itemId then
				headerIndex = headerIndex + 1
				local header = createReserveHeader(scrollChild, entry, yOffset, headerIndex)
				reserveHeaders[#reserveHeaders + 1] = header
				yOffset = yOffset + reserveHeaderHeight

				local players = entry.players or {}
				if collapsedItems[entry.itemId] ~= true then
					for j = 1, #players do
						rowIndex = rowIndex + 1
						local playerEntry = players[j]
						local playerRow = createReserveRow(scrollChild, entry, playerEntry, yOffset, rowIndex)
						reserveItemRows[#reserveItemRows + 1] = playerRow
						yOffset = yOffset + reservePlayerRowHeight
					end
				end
			end
		end

		if scrollFrame and scrollFrame.GetHeight then
			scrollChild:SetHeight(math.max(yOffset, scrollFrame:GetHeight() or 0))
		else
			scrollChild:SetHeight(yOffset)
		end
		if scrollFrame then
			scrollFrame:SetVerticalScroll(0)
			if scrollFrame.UpdateScrollChildRect then
				scrollFrame:UpdateScrollChildRect()
			end
		end

		local frameName = uiState.FrameName
		local statusText = frameName and _G[frameName .. "SoftResStatusText"]
		if statusText then
			local reservedPlayerCount = 0
			for _ in pairs(reservedPlayerMap) do
				reservedPlayerCount = reservedPlayerCount + 1
			end
			statusText:SetText(format(L.StrReserveListStatus, getRaidMemberCount(), reservedPlayerCount))
		end
	end

	local function primeItemInfoQuery(itemId)
		return Tooltips.PrimeItemInfo(itemId)
	end

	local function queryItemInfo(itemId)
		return Reserves:QueryItemInfo(itemId)
	end

	local function queryMissingItems(silent)
		local updated, count = Reserves:QueryMissingItems(silent, function(itemId)
			primeItemInfoQuery(itemId)
		end)

		if updated then
			module:RequestRefresh("query_missing_items")
		end

		return updated, count
	end

	local function shouldThrottleQueryMissingItems()
		local now = GetTime()
		if type(now) ~= "number" then
			return false
		end
		if (now - lastQueryAttemptAt) < queryCooldownSeconds then
			return true
		end
		lastQueryAttemptAt = now
		return false
	end

	local function clearSavedReservesFromUI()
		local out = ClearSavedReserves(Reserves)
		module:Hide()
		module:RequestRefresh("reset_saved")
		return out
	end

	local function confirmClearSavedReservesFromUI()
		if not hasReserveData() then
			return false
		end

		local options = {
			button1 = L.BtnClear,
			button2 = L.BtnCancel,
		}
		ShowConfirmPopup(
			CLEAR_SAVED_RESERVES_POPUP_KEY,
			L.StrConfirmClearReserves,
			clearSavedReservesFromUI,
			CLEAR_SAVED_RESERVES_POPUP_KEY,
			options
		)
		return true
	end

	local function getWhisperTargetName()
		local playerName = UnitName("player")
		if type(playerName) == "string" and playerName ~= "" then
			return playerName
		end
		return "me"
	end

	local function isPlayerInRaid()
		if type(UnitInRaid) == "function" and UnitInRaid("player") then
			return true
		end
		if addon.IsInRaid() then
			return true
		end
		return false
	end

	local function announceSoftResWhisperHelp()
		if not isPlayerInRaid() then
			return false
		end
		local targetName = getWhisperTargetName()
		local reservesNs = getReservesOptions()
		local announced = false
		if reservesNs and reservesNs:Get("softResWhisperReplies") == true then
			AnnounceChat(Chat, format(L.ChatSoftResWhisperHelpQuery, targetName), "RAID")
			announced = true
		end
		if reservesNs and reservesNs:Get("softResWhisperAdds") == true then
			AnnounceChat(Chat, format(L.ChatSoftResWhisperHelpAdd, targetName), "RAID")
			announced = true
		end
		return announced
	end

	-- ----- Public methods ----- --

	local function refreshReservesUi()
		if not uiState.Localized then
			uiState.Localize()
		end
		uiState.Refresh()
		renderReserveListUI()
	end

	local function BindHandlers(_, _, refs)
		scrollFrame = refs.scrollFrame or scrollFrame
		scrollChild = refs.scrollChild or scrollChild

		if refs.whisperHelpButton then
			Frames.SetScriptSafely(refs.whisperHelpButton, "OnClick", function()
				announceSoftResWhisperHelp()
			end)
			if isDebugEnabled() then
				addon:debug(Diag.D.LogReservesBindButton:format("WhisperHelpButton", "AnnounceWhisperHelp"))
			end
		end

		if refs.clearBtn then
			Frames.SetScriptSafely(refs.clearBtn, "OnClick", function()
				confirmClearSavedReservesFromUI()
			end)
			if isDebugEnabled() then
				addon:debug(Diag.D.LogReservesBindButton:format("ClearBtn", "Clear"))
			end
		end

		if refs.editButton then
			Frames.SetScriptSafely(refs.editButton, "OnClick", function()
				if not hasReserveData() then
					return
				end
				if isEditMode then
					local edits = collectVisibleReserveEdits()
					if #edits > 0 then
						if confirmApplyVisibleReserveEditsFromUI(edits, refs.editButton) then
							return
						end
					else
						isEditMode = false
					end
				else
					isEditMode = true
				end
				refs.editButton._RMAReserveEditMode = isEditMode
				module:RequestRefresh("toggle_edit_mode")
			end)
		end

		if refs.queryButton then
			Frames.SetScriptSafely(refs.queryButton, "OnClick", function()
				if shouldThrottleQueryMissingItems() then
					addon:info(L.MsgReserveItemsQueryCooldown, queryCooldownSeconds)
					return
				end
				queryMissingItems(false)
			end)
			if isDebugEnabled() then
				addon:debug(Diag.D.LogReservesBindButton:format("QueryButton", "QueryMissingItems"))
			end
		end

		if refs.importButton then
			Frames.SetScriptSafely(refs.importButton, "OnClick", function()
				module:ToggleImport()
			end)
			if isDebugEnabled() then
				addon:debug(Diag.D.LogReservesBindButton:format("ImportButton", "ToggleImport"))
			end
		end

		if refs.softResAccept then
			Frames.SetScriptSafely(refs.softResAccept, "OnClick", function(self)
				local reservesNs = getReservesOptions()
				if not reservesNs or not reservesNs.Set then
					return
				end
				reservesNs:Set("softResWhisperAdds", isWidgetChecked(self))
				module:RequestRefresh("soft_reserve_add_option")
			end)
			BindTooltip(
				refs.softResAccept,
				L.StrReserveListAcceptSRTooltipText,
				"ANCHOR_RIGHT",
				L.StrReserveListAcceptSRTooltipTitle
			)
		end

		if refs.softResResponseWisp then
			Frames.SetScriptSafely(refs.softResResponseWisp, "OnClick", function(self)
				local reservesNs = getReservesOptions()
				if not reservesNs or not reservesNs.Set then
					return
				end
				reservesNs:Set("softResWhisperReplies", isWidgetChecked(self))
				module:RequestRefresh("soft_reserve_reply_option")
			end)
			BindTooltip(
				refs.softResResponseWisp,
				L.StrReserveListResponseWispTooltipText,
				"ANCHOR_RIGHT",
				L.StrReserveListResponseWispTooltipTitle
			)
		end
	end

	local function loadReservesFrame(frame)
		if isDebugEnabled() then
			addon:debug(Diag.D.LogReservesFrameLoaded)
		end
		uiState.FrameName = Frames.BindModuleFrame(module, frame, {
			enableDrag = true,
			hookOnShow = function()
				if isDebugEnabled() then
					addon:debug(Diag.D.LogReservesShowWindow)
				end
			end,
			hookOnHide = function()
				if isDebugEnabled() then
					addon:debug(Diag.D.LogReservesHideWindow)
				end
			end,
		}) or uiState.FrameName
		uiState.Loaded = uiState.FrameName ~= nil
		if not uiState.Loaded then
			return
		end

		scrollFrame = frame.ScrollFrame or _G["RMAReserveListFrameScrollFrame"]
		scrollChild = scrollFrame and scrollFrame.ScrollChild or _G["RMAReserveListFrameScrollChild"]

		local refreshFrame = CreateFrame("Frame")
		refreshFrame:RegisterEvent("GET_ITEM_INFO_RECEIVED")
		Frames.SetScriptSafely(refreshFrame, "OnEvent", function(_, _, itemId)
			if isDebugEnabled() then
				addon:debug(Diag.D.LogReservesItemInfoReceived:format(itemId))
			end
			if not HasPendingReserveItem(Reserves, itemId) then
				return
			end

			local resolved = queryItemInfo(itemId)
			if not resolved then
				primeItemInfoQuery(itemId)
			end
		end)
	end

	local function OnLoadFrame(frame)
		loadReservesFrame(frame)
		return uiState.FrameName
	end

	Scaffold.DefineModule({
		module = module,
		getFrame = getFrame,
		acquireRefs = uiState.AcquireRefs,
		bind = BindHandlers,
		localize = function()
			uiState.Localize()
		end,
		onLoad = OnLoadFrame,
		refresh = function()
			refreshReservesUi()
		end,
	})

	-- ----- Import widget controller ----- --

	module.Import = module.Import or {}
	local Import = module.Import
	local importUiState = UI.ModuleState.Ensure(Import)
	local getImportFrame = Frames.MakeModuleFrameGetter(Import, "RMAImportWindow")
	local MODE_MULTI, MODE_PLUS = 0, 1
	local importFormat = "json"

	function importUiState.AcquireRefs(frame)
		return {
			cancelButton = _G["RMAImportCancelButton"],
			confirmButton = _G["RMAImportConfirmButton"],
			editBox = _G["RMAImportEditBox"],
			formatCsvButton = _G["RMAImportWindowFormatCsvButton"],
			formatJsonButton = _G["RMAImportWindowFormatJsonButton"],
			modeMultiButton = _G["RMAImportWindowModeMultiButton"],
			modePlusButton = _G["RMAImportWindowModePlusButton"],
			scrollFrame = _G["RMAImportScrollFrame"],
			status = _G["RMAImportWindowStatus"],
			frame = frame,
		}
	end

	local function getImportModeString()
		return GetImportMode(Reserves)
	end

	local setImportMode, setImportFormat, refreshChoiceButtons, importFromEditBox

	local function setImportStatus(text, r, g, b)
		local status = _G["RMAImportWindowStatus"]
		if not status then
			return
		end
		status:SetText(text or "")
		if r and g and b then
			status:SetTextColor(r, g, b)
		end
	end

	local function showReservesListAfterImport()
		Import:Hide()
		local reserveFrame = getFrame()
		if not (reserveFrame and reserveFrame.IsShown and reserveFrame:IsShown()) then
			module:Toggle()
		else
			module:RequestRefresh()
		end
	end

	local function applyParsedImport(parsed)
		local function onImportApplied(ok, nPlayersOrErr, applyErrData)
			if not ok then
				setImportStatus(L.ErrImportReservesEmpty, 1, 0.2, 0.2)
				return false, 0, nPlayersOrErr, applyErrData
			end

			setImportStatus(format(L.SuccessReservesParsed, tostring(nPlayersOrErr)), 0.2, 1, 0.2)
			showReservesListAfterImport()
			return true, nPlayersOrErr
		end

		return RequestApplyImport(Reserves, parsed, nil, function(ok, nPlayersOrErr, applyErrData)
			onImportApplied(ok, nPlayersOrErr, applyErrData)
		end, { reason = "import" })
	end

	local function ensureWrongCSVPopup()
		if IsPopupDefined("RMA_WRONG_CSV_FOR_PLUS") then
			return true
		end

		return DefinePopup("RMA_WRONG_CSV_FOR_PLUS", {
			text = L.ErrCSVWrongForPlus,
			button1 = L.BtnSwitchToMulti,
			button2 = L.BtnCancel,
			timeout = 0,
			whileDead = 1,
			hideOnEscape = 1,
			preferredIndex = 3,
			OnShow = function(self, data)
				if not self or not self.text then
					return
				end
				local text = L.ErrCSVWrongForPlus
				if type(data) == "table" and data.player then
					text = L.ErrCSVWrongForPlusWithPlayer:format(tostring(data.player))
				end
				self.text:SetText(text)
			end,
			OnAccept = function(_, data)
				if type(data) ~= "table" or type(data.csv) ~= "string" then
					return
				end
				setImportMode(MODE_MULTI)
				local parsed = ParseImport(Reserves, data.csv, "multi", { source = "import_window", format = "csv" })
				if not parsed then
					setImportStatus(L.ErrImportReservesEmpty, 1, 0.2, 0.2)
					return
				end

				applyParsedImport(parsed)
			end,
		})
	end

	function importUiState.Localize()
		if importUiState.Localized then
			return
		end
		local frame = getImportFrame()
		if not frame then
			addon:error(Diag.E.LogReservesImportWindowMissing)
			return
		end

		Frames.SetFrameTitle(importUiState.FrameName or frame, L.StrImportReservesTitle)

		local hint = _G["RMAImportWindowHint"]
		if hint then
			hint:SetText(L.StrImportReservesHint)
		end
		local modeLabel = _G["RMAImportWindowModeLabel"]
		if modeLabel then
			modeLabel:SetText(L.StrImportReserveSystemLabel)
		end
		local formatLabel = _G["RMAImportWindowFormatLabel"]
		if formatLabel then
			formatLabel:SetText(L.StrImportFormatLabel)
		end
		local modeMultiButton = _G["RMAImportWindowModeMultiButton"]
		if modeMultiButton then
			modeMultiButton:SetText(L.StrImportModeMulti)
		end
		local modePlusButton = _G["RMAImportWindowModePlusButton"]
		if modePlusButton then
			modePlusButton:SetText(L.StrImportModePlus)
		end
		local formatJsonButton = _G["RMAImportWindowFormatJsonButton"]
		if formatJsonButton then
			formatJsonButton:SetText(L.StrImportFormatJson)
		end
		local formatCsvButton = _G["RMAImportWindowFormatCsvButton"]
		if formatCsvButton then
			formatCsvButton:SetText(L.StrImportFormatCsv)
		end

		local confirmButton = _G["RMAImportConfirmButton"]
		if confirmButton then
			confirmButton:SetText(L.BtnImport)
		end

		local cancelButton = _G["RMAImportCancelButton"]
		if cancelButton then
			cancelButton:SetText(L.BtnClose)
		end

		importUiState.Localized = true
	end

	local function configureImportEditBox(editBox, scrollFrame)
		if not editBox then
			return
		end
		if editBox.SetMultiLine then
			editBox:SetMultiLine(true)
		end
		if editBox.SetWidth then
			editBox:SetWidth(244)
		end
		if scrollFrame and scrollFrame.SetScrollChild then
			scrollFrame:SetScrollChild(editBox)
		end
		if editBox.SetTextInsets then
			editBox:SetTextInsets(8, 8, 8, 8)
		end
		if editBox.SetJustifyH then
			editBox:SetJustifyH("LEFT")
		end
		if editBox.SetJustifyV then
			editBox:SetJustifyV("TOP")
		end
		if editBox.SetWordWrap then
			editBox:SetWordWrap(true)
		end
	end

	local function adjustImportScrollBar(scrollFrame)
		if not (scrollFrame and scrollFrame.GetName) then
			return
		end

		local scrollName = scrollFrame:GetName()
		local scrollBar = scrollFrame.ScrollBar or _G[scrollName .. "ScrollBar"]
		if not scrollBar then
			return
		end

		local upButton = _G[scrollBar:GetName() .. "ScrollUpButton"]
		local downButton = _G[scrollBar:GetName() .. "ScrollDownButton"]
		if upButton then
			upButton:ClearAllPoints()
			upButton:SetPoint("TOP", scrollFrame, "TOPRIGHT", 28, -4)
		end
		if downButton then
			downButton:ClearAllPoints()
			downButton:SetPoint("BOTTOM", scrollFrame, "BOTTOMRIGHT", 28, 8)
		end

		scrollBar:ClearAllPoints()
		scrollBar:SetPoint("TOP", scrollFrame, "TOPRIGHT", 28, -20)
		scrollBar:SetPoint("BOTTOM", scrollFrame, "BOTTOMRIGHT", 28, 24)
	end

	local function bindImportHandlers(_, _, refs)
		configureImportEditBox(refs.editBox, refs.scrollFrame)
		adjustImportScrollBar(refs.scrollFrame)
		Frames.SetScriptSafely(refs.cancelButton, "OnClick", function()
			Import:Hide()
		end)
		Frames.SetScriptSafely(refs.confirmButton, "OnClick", function()
			importFromEditBox()
		end)
		Frames.SetScriptSafely(refs.editBox, "OnEscapePressed", function()
			Import:Hide()
		end)
		Frames.SetScriptSafely(refs.modeMultiButton, "OnClick", function()
			setImportMode(MODE_MULTI)
		end)
		Frames.SetScriptSafely(refs.modePlusButton, "OnClick", function()
			setImportMode(MODE_PLUS)
		end)
		Frames.SetScriptSafely(refs.formatJsonButton, "OnClick", function()
			setImportFormat("json")
		end)
		Frames.SetScriptSafely(refs.formatCsvButton, "OnClick", function()
			setImportFormat("csv")
		end)
		refreshChoiceButtons()
	end

	local function setButtonSelected(button, selected)
		if not button then
			return
		end

		local name = button.GetName and button:GetName()
		if name then
			local suffixes = { "Left", "Middle", "Right" }
			for i = 1, #suffixes do
				local region = _G[name .. suffixes[i]]
				if region and region.SetVertexColor then
					if selected then
						region:SetVertexColor(1, 1, 1)
					else
						region:SetVertexColor(0.45, 0.18, 0.18)
					end
				end
			end
		end
	end

	refreshChoiceButtons = function()
		local mode = getImportModeString()
		setButtonSelected(_G["RMAImportWindowModeMultiButton"], mode ~= "plus")
		setButtonSelected(_G["RMAImportWindowModePlusButton"], mode == "plus")
		setButtonSelected(_G["RMAImportWindowFormatJsonButton"], importFormat == "json")
		setButtonSelected(_G["RMAImportWindowFormatCsvButton"], importFormat == "csv")
	end

	setImportMode = function(modeValue)
		local mode = (modeValue == MODE_PLUS) and "plus" or "multi"
		SetImportMode(Reserves, mode, true)

		refreshChoiceButtons()
	end

	setImportFormat = function(format)
		importFormat = (format == "csv") and "csv" or "json"
		refreshChoiceButtons()
	end

	local function refreshImportFrame()
		if not importUiState.Localized then
			importUiState.Localize()
		end

		refreshChoiceButtons()

		local status = _G["RMAImportWindowStatus"]
		if status and (status:GetText() == nil or status:GetText() == "") then
			status:SetText("")
		end
	end

	local function loadImportFrame(frame)
		importUiState.FrameName = Frames.BindModuleFrame(Import, frame, {
			enableDrag = true,
			hookOnShow = function()
				EditBoxes.Reset(_G["RMAImportEditBox"])
				local editBox = _G["RMAImportEditBox"]
				if editBox then
					editBox:SetFocus()
					editBox:HighlightText()
				end
				setImportStatus("")
				Import:RequestRefresh()
			end,
		}) or importUiState.FrameName
		importUiState.Loaded = importUiState.FrameName ~= nil
		if not importUiState.Loaded then
			return
		end

		Import:RequestRefresh()
	end

	local function onLoadImportFrame(frame)
		loadImportFrame(frame)
		return importUiState.FrameName
	end

	Scaffold.DefineModule({
		module = Import,
		getFrame = getImportFrame,
		acquireRefs = importUiState.AcquireRefs,
		bind = bindImportHandlers,
		localize = function()
			importUiState.Localize()
		end,
		onLoad = onLoadImportFrame,
		refresh = function()
			refreshImportFrame()
		end,
	})

	importFromEditBox = function()
		local editBox = _G["RMAImportEditBox"]
		setImportStatus("")
		if not editBox then
			addon:error(Diag.E.LogReservesImportWindowMissing)
			return false, 0
		end

		local importText = editBox:GetText()
		if type(importText) ~= "string" or not importText:match("%S") then
			setImportStatus(L.ErrImportReservesEmpty, 1, 0.2, 0.2)
			addon:warn(Diag.W.LogReservesImportFailedEmpty)
			return false, 0, "EMPTY"
		end

		if isDebugEnabled() then
			addon:debug(Diag.D.LogSRImportRequested:format(#importText))
		end
		ensureWrongCSVPopup()

		local mode = getImportModeString()
		local parsed, errCode, errData =
			ParseImport(Reserves, importText, mode, { source = "import_window", format = importFormat })
		if not parsed then
			if errCode == "CSV_WRONG_FOR_PLUS" then
				setImportStatus(L.ErrCSVWrongForPlusShort, 1, 0.2, 0.2)
				local popupData = { csv = importText }
				if type(errData) == "table" then
					for key, value in pairs(errData) do
						popupData[key] = value
					end
				end
				if ensureWrongCSVPopup() then
					ShowPopup("RMA_WRONG_CSV_FOR_PLUS", nil, nil, popupData)
				end
				return false, 0, errCode, errData
			end

			local errorText = (errCode == "NO_ROWS") and L.WarnNoValidRows or L.ErrImportReservesEmpty
			setImportStatus(errorText, 1, 0.2, 0.2)
			return false, 0, errCode, errData
		end

		return applyParsedImport(parsed)
	end

	function module:ToggleImport()
		return Import:Toggle()
	end

	RegisterCallback(ReservesDataChangedEvent, function()
		module:RequestRefresh()
	end)
end
