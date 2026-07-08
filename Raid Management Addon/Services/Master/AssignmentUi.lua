-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: local feature = addon.Database.GetFeatureShared()
-- exports: addon.Services.Master.AssignmentUi
-- events: none
-- notes: owns Master assignment dropdown and manual award grid UI orchestration
local addon = select(2, ...)
local feature = addon.Database.GetFeatureShared()

local Master = feature.EnsureServiceNamespace("Master")

local AssignmentUi = Master.AssignmentUi or {}
Master.AssignmentUi = AssignmentUi

local pairs = pairs
local tonumber = tonumber
local tostring = tostring
local type = type
local tinsert = table.insert
local twipe = table.wipe

local GetRaidRosterInfo = assert(_G.GetRaidRosterInfo, "Master assignment UI raid roster API is not initialized")
local UIDropDownMenu_AddButton =
	assert(_G.UIDropDownMenu_AddButton, "Master assignment UI dropdown button API is not initialized")
local UIDropDownMenu_CreateInfo =
	assert(_G.UIDropDownMenu_CreateInfo, "Master assignment UI dropdown info API is not initialized")
local UIDropDownMenu_Initialize =
	assert(_G.UIDropDownMenu_Initialize, "Master assignment UI dropdown init API is not initialized")
local UIDropDownMenu_JustifyText =
	assert(_G.UIDropDownMenu_JustifyText, "Master assignment UI dropdown justify API is not initialized")
local UIDropDownMenu_SetButtonWidth =
	assert(_G.UIDropDownMenu_SetButtonWidth, "Master assignment UI dropdown button-width API is not initialized")
local UIDropDownMenu_SetSelectedValue =
	assert(_G.UIDropDownMenu_SetSelectedValue, "Master assignment UI dropdown selected-value API is not initialized")
local UIDropDownMenu_SetText =
	assert(_G.UIDropDownMenu_SetText, "Master assignment UI dropdown text API is not initialized")
local UIDropDownMenu_SetWidth =
	assert(_G.UIDropDownMenu_SetWidth, "Master assignment UI dropdown width API is not initialized")

local function getAssignmentFieldByKey(controller, targetKey)
	if targetKey == "holder" then
		return {
			stateKey = "holder",
			raidKey = "holder",
			frame = controller.state._dropDownFrameHolder,
			label = controller.L.BtnHold,
		}
	elseif targetKey == "banker" then
		return {
			stateKey = "banker",
			raidKey = "banker",
			frame = controller.state._dropDownFrameBanker,
			label = controller.L.BtnBank,
		}
	elseif targetKey == "disenchanter" then
		return {
			stateKey = "disenchanter",
			raidKey = "disenchanter",
			frame = controller.state._dropDownFrameDisenchanter,
			label = controller.L.BtnDisenchant,
		}
	end
	return nil
end

local function findDropDownField(controller, frameNameFull)
	if not frameNameFull then
		return nil
	end

	local holderName = controller.state._dropDownFrameHolder
			and controller.state._dropDownFrameHolder.GetName
			and controller.state._dropDownFrameHolder:GetName()
		or nil
	local bankerName = controller.state._dropDownFrameBanker
			and controller.state._dropDownFrameBanker.GetName
			and controller.state._dropDownFrameBanker:GetName()
		or nil
	local disenchanterName = controller.state._dropDownFrameDisenchanter
			and controller.state._dropDownFrameDisenchanter.GetName
			and controller.state._dropDownFrameDisenchanter:GetName()
		or nil

	if frameNameFull == holderName then
		return { stateKey = "holder", raidKey = "holder", frame = controller.state._dropDownFrameHolder }
	elseif frameNameFull == bankerName then
		return { stateKey = "banker", raidKey = "banker", frame = controller.state._dropDownFrameBanker }
	elseif frameNameFull == disenchanterName then
		return {
			stateKey = "disenchanter",
			raidKey = "disenchanter",
			frame = controller.state._dropDownFrameDisenchanter,
		}
	end
	return nil
end

local function collectMasterLootCandidates(controller)
	local result = {}
	for i = 1, 40 do
		local name = controller.getMasterLootCandidate(i)
		if name and name ~= "" then
			tinsert(result, {
				name = name,
				index = i,
			})
		end
	end
	return result
end

local function collectRaidGridRosterRows(controller)
	local result = {}
	local seen = {}

	for unit in controller.unitIterator(true) do
		local name = controller.getUnitName(unit)
		if name and name ~= "" and not seen[name] then
			local className = controller.getRaidGridPlayerClass(name)
			if not className then
				local _, classFileName = controller.getUnitClass(unit)
				className = classFileName
			end
			tinsert(result, {
				name = name,
				class = className,
			})
			seen[name] = true
		end
	end

	return result
end

local function hideBlizzardDropDownLists()
	if type(_G.CloseDropDownMenus) == "function" then
		_G.CloseDropDownMenus()
	end
	for i = 1, 2 do
		local list = _G["DropDownList" .. i]
		if list and list.Hide then
			list:Hide()
		end
	end
	_G.UIDROPDOWNMENU_OPEN_MENU = nil
end

local function queueHideBlizzardDropDownLists(controller)
	hideBlizzardDropDownLists()
	controller.scheduleTimer(hideBlizzardDropDownLists, 0)
end

local function refreshDropDowns(controller, force)
	if not controller.state._dropDownsInitialized then
		return
	end
	if not force and not controller.state._dropDownDirty then
		return
	end

	controller:UpdateDropDown(controller.state._dropDownFrameHolder)
	controller:UpdateDropDown(controller.state._dropDownFrameBanker)
	controller:UpdateDropDown(controller.state._dropDownFrameDisenchanter)
	controller.state._dropDownDirty = false
	controller.state._dirtyFlags.dropdowns = false
end

local function ensureRaidGridConfirmPopup(controller)
	if controller.popup.IsDefined("RMA_MASTER_LOOT_GRID_CONFIRM") then
		return true
	end

	return controller.popup.Define("RMA_MASTER_LOOT_GRID_CONFIRM", {
		text = controller.L.PopupRaidGridConfirm or "Give %s to %s?",
		button1 = _G.YES or _G.OKAY,
		button2 = _G.NO or _G.CANCEL,
		timeout = 0,
		whileDead = 1,
		hideOnEscape = 1,
		OnAccept = function(_, data)
			controller:AcceptManualGridAward(data)
		end,
	})
end

local function showManualGridAwardConfirm(controller, itemLink, playerName)
	if not ensureRaidGridConfirmPopup(controller) then
		return false
	end

	local data = {
		itemLink = itemLink,
		itemText = itemLink or controller.L.StrRaidGridTitle,
		playerName = playerName,
	}
	return controller.popup.Show("RMA_MASTER_LOOT_GRID_CONFIRM", data.itemText, playerName, data)
end

local function handleManualGridEntry(controller, entry)
	if type(entry) ~= "table" or not entry.name then
		return false
	end

	local itemLink = controller.getSelectedMasterLootLink()
	if not itemLink then
		return false
	end

	local threshold = _G.MASTER_LOOT_THREHOLD or _G.MASTER_LOOT_THRESHOLD or 4
	if controller.getSelectedMasterLootQuality() >= threshold then
		return showManualGridAwardConfirm(controller, itemLink, entry.name)
	end
	return controller:AcceptManualGridAward({
		itemLink = itemLink,
		playerName = entry.name,
	})
end

local function openAssignmentTargetGrid(controller, targetKey)
	local field = getAssignmentFieldByKey(controller, targetKey)
	if not field then
		return false
	end

	queueHideBlizzardDropDownLists(controller)
	controller:PrepareDropDowns()

	local title = controller.L.StrRaidGridTargetTitle
	if field.label then
		title = title .. ": " .. field.label
	end

	controller.raidGrid.ShowPicker({
		mode = "target",
		title = title,
		emptyText = controller.L.StrRaidGridEmpty,
		entries = controller.assignmentTargets.BuildRows(
			controller.state._dropDownData,
			controller.getRaidGridPlayerClass
		),
		anchor = field.frame or controller.getFrame(),
		onSelect = function(entry)
			return controller:SetAssignmentTarget(targetKey, entry and entry.name)
		end,
	})
	return true
end

local function onClickDropDown(controller, _button, owner, value)
	if not owner or not value or not controller.database.GetCurrentRaid() then
		return
	end

	local field = findDropDownField(controller, owner:GetName())
	if field then
		controller:SetAssignmentTarget(field.stateKey, value)
		return
	end

	UIDropDownMenu_SetText(owner, value)
	UIDropDownMenu_SetSelectedValue(owner, value)
	controller.state._dropDownDirty = true
	controller.state._dirtyFlags.dropdowns = true
	controller.state._dirtyFlags.buttons = true
	hideBlizzardDropDownLists()
	controller.requestRefresh()
end

local function initializeDropDowns(controller)
	if _G.UIDROPDOWNMENU_MENU_LEVEL == 2 then
		local group = _G.UIDROPDOWNMENU_MENU_VALUE
		local members = controller.state._dropDownData[group]
		if type(members) ~= "table" then
			return
		end
		for key in pairs(members) do
			local info = UIDropDownMenu_CreateInfo()
			info.hasArrow = false
			info.notCheckable = 1
			info.text = key
			info.func = function(button, owner, value)
				return onClickDropDown(controller, button, owner, value)
			end
			info.arg1 = _G.UIDROPDOWNMENU_OPEN_MENU
			info.arg2 = key
			UIDropDownMenu_AddButton(info, _G.UIDROPDOWNMENU_MENU_LEVEL)
		end
	end
	if _G.UIDROPDOWNMENU_MENU_LEVEL == 1 then
		for key in pairs(controller.state._dropDownData) do
			if controller.state._dropDownGroupData[key] == true then
				local info = UIDropDownMenu_CreateInfo()
				info.hasArrow = 1
				info.notCheckable = 1
				info.text = (_G.GROUP or "Group") .. " " .. key
				info.value = key
				info.owner = _G.UIDROPDOWNMENU_OPEN_MENU
				UIDropDownMenu_AddButton(info, _G.UIDROPDOWNMENU_MENU_LEVEL)
			end
		end
	end
end

local function configureAssignDropDown(controller, frame)
	if not frame then
		return
	end
	frame:SetWidth(controller.state._assignDropDownButtonWidth)
	UIDropDownMenu_SetWidth(frame, controller.state._assignDropDownWidth)
	UIDropDownMenu_SetButtonWidth(frame, controller.state._assignDropDownButtonWidth)
	UIDropDownMenu_JustifyText(frame, "LEFT")
end

local function hookDropDownOpen(controller, frame, targetKey)
	if not frame then
		return
	end

	local button = _G[frame:GetName() .. "Button"]
	if button and not button._RMAHooked then
		controller.hookScriptSafely(button, "OnClick", function()
			refreshDropDowns(controller, true)
			openAssignmentTargetGrid(controller, targetKey)
		end)
		button._RMAHooked = true
	end
end

function AssignmentUi.CreateController(opts)
	opts = opts or {}

	local controller = {
		state = assert(opts.state, "Master assignment UI state is not initialized"),
		lootState = assert(opts.lootState, "Master assignment UI loot state is not initialized"),
		database = assert(opts.database, "Master assignment UI database helpers are not initialized"),
		raid = assert(opts.raid, "Master assignment UI raid service is not initialized"),
		raidApi = assert(opts.raidApi, "Master assignment UI raid API table is not initialized"),
		assignmentCandidates = assert(
			opts.assignmentCandidates,
			"Master assignment candidate owner is not initialized"
		),
		assignmentTargets = assert(opts.assignmentTargets, "Master assignment target owner is not initialized"),
		debugRaidGrid = assert(opts.debugRaidGrid, "Master debug raid grid owner is not initialized"),
		raidGrid = assert(opts.raidGrid, "Master assignment UI raid grid is not initialized"),
		popup = assert(opts.popup, "Master assignment UI popup helpers are not initialized"),
		requestRefresh = assert(opts.requestRefresh, "Master assignment UI refresh hook is not initialized"),
		scheduleTimer = assert(opts.scheduleTimer, "Master assignment UI timer scheduler is not initialized"),
		hookScriptSafely = assert(opts.hookScriptSafely, "Master assignment UI script binder is not initialized"),
		getFrame = assert(opts.getFrame, "Master assignment UI frame resolver is not initialized"),
		unitIterator = assert(opts.unitIterator, "Master assignment UI unit iterator is not initialized"),
		getUnitName = assert(opts.getUnitName, "Master assignment UI unit-name resolver is not initialized"),
		getUnitClass = assert(opts.getUnitClass, "Master assignment UI unit-class resolver is not initialized"),
		getMasterLootCandidate = assert(
			opts.getMasterLootCandidate,
			"Master assignment UI loot-candidate resolver is not initialized"
		),
		getRaidGridPlayerClass = assert(
			opts.getRaidGridPlayerClass,
			"Master assignment UI class resolver is not initialized"
		),
		getSelectedMasterLootLink = assert(
			opts.getSelectedMasterLootLink,
			"Master assignment UI selected-link resolver is not initialized"
		),
		getSelectedMasterLootQuality = assert(
			opts.getSelectedMasterLootQuality,
			"Master assignment UI selected-quality resolver is not initialized"
		),
		getSelectedMasterLootTexture = assert(
			opts.getSelectedMasterLootTexture,
			"Master assignment UI selected-texture resolver is not initialized"
		),
		getSelectedMasterLootCount = assert(
			opts.getSelectedMasterLootCount,
			"Master assignment UI selected-count resolver is not initialized"
		),
		getRaidGridFrameAnchor = assert(
			opts.getRaidGridFrameAnchor,
			"Master assignment UI anchor resolver is not initialized"
		),
		assignManualItem = assert(
			opts.assignManualItem,
			"Master assignment UI manual-award executor is not initialized"
		),
		isMasterLooter = assert(opts.isMasterLooter, "Master assignment UI master-looter guard is not initialized"),
		isDebugEnabled = assert(opts.isDebugEnabled, "Master assignment UI debug-state resolver is not initialized"),
		L = assert(opts.L, "Master assignment UI localized strings are not initialized"),
	}

	-- Public helper used by the controller refresh loop.
	function controller:UpdateDropDown(frame)
		if not frame or not self.database.GetCurrentRaid() then
			return
		end

		local field = findDropDownField(self, frame:GetName())
		if not field then
			return
		end

		local raidStore = self.database.GetRaidStoreOrNil("Master.AssignmentUi.UpdateDropDown", { "GetRaidByIndex" })
		local raid = raidStore and raidStore:GetRaidByIndex(self.database.GetCurrentRaid()) or nil
		if not raid then
			return
		end
		self.lootState[field.stateKey] = raid[field.raidKey]

		if self.lootState[field.stateKey] and self.raid:GetUnitID(self.lootState[field.stateKey]) == "none" then
			raid[field.raidKey] = nil
			self.lootState[field.stateKey] = nil
		end

		if self.lootState[field.stateKey] then
			UIDropDownMenu_SetText(field.frame, self.lootState[field.stateKey])
			UIDropDownMenu_SetSelectedValue(field.frame, self.lootState[field.stateKey])
			self.state._dirtyFlags.buttons = true
		end
	end

	function controller:SetAssignmentTarget(targetKey, playerName)
		if not playerName or playerName == "" then
			return false
		end

		local field = getAssignmentFieldByKey(self, targetKey)
		if not field then
			return false
		end

		local raidStore =
			self.database.GetRaidStoreOrNil("Master.AssignmentUi.SetAssignmentTarget", { "GetRaidByIndex" })
		local raidId = self.database.GetCurrentRaid()
		local raid = raidStore and raidId and raidStore:GetRaidByIndex(raidId) or nil
		if raid then
			raid[field.raidKey] = playerName
		end
		self.lootState[field.stateKey] = playerName

		if field.frame then
			UIDropDownMenu_SetText(field.frame, playerName)
			UIDropDownMenu_SetSelectedValue(field.frame, playerName)
		end

		self.state._dropDownDirty = true
		self.state._dirtyFlags.dropdowns = true
		self.state._dirtyFlags.buttons = true
		hideBlizzardDropDownLists()
		self.raidGrid.Hide()
		self.requestRefresh()
		return true
	end

	function controller:PrepareDropDowns()
		local rosterVersion = self.raidApi.GetRosterVersion(self.raid)
		if rosterVersion and self.state._cachedRosterVersion == rosterVersion then
			return
		end
		if rosterVersion ~= self.state._cachedRosterVersion then
			self.raidApi.RequestMasterLootCandidateRefresh(self.raid)
		end
		self.state._cachedRosterVersion = rosterVersion
		self.state._dropDownDirty = true
		self.state._dirtyFlags.dropdowns = true

		for i = 1, 8 do
			local names = self.state._dropDownData[i]
			if names then
				twipe(names)
			else
				names = {}
				self.state._dropDownData[i] = names
			end
		end

		self.state._dropDownGroupData = self.state._dropDownGroupData or {}
		twipe(self.state._dropDownGroupData)

		for unit in self.unitIterator(true) do
			local name = self.getUnitName(unit)
			if name and name ~= "" then
				local subgroup = 1
				local idx = tonumber(unit:match("^raid(%d+)$"))
				if idx then
					subgroup = (select(3, GetRaidRosterInfo(idx))) or 1
				end

				self.state._dropDownData[subgroup] = self.state._dropDownData[subgroup] or {}
				self.state._dropDownData[subgroup][name] = name
				self.state._dropDownGroupData[subgroup] = true
			end
		end

		refreshDropDowns(self, true)
	end

	function controller:InitializeDropDowns()
		local frames = {
			{ frame = self.state._dropDownFrameHolder, targetKey = "holder" },
			{ frame = self.state._dropDownFrameBanker, targetKey = "banker" },
			{ frame = self.state._dropDownFrameDisenchanter, targetKey = "disenchanter" },
		}

		for i = 1, #frames do
			local entry = frames[i]
			local frame = entry.frame
			if frame then
				UIDropDownMenu_Initialize(frame, function()
					initializeDropDowns(controller)
				end)
				configureAssignDropDown(self, frame)
				hookDropDownOpen(self, frame, entry.targetKey)
			end
		end

		self.state._dropDownsInitialized = true
		refreshDropDowns(self, true)
	end

	function controller:AcceptManualGridAward(data)
		if type(data) ~= "table" or not data.playerName then
			return false
		end

		local itemLink = data.itemLink or self.getSelectedMasterLootLink()
		if not itemLink then
			return false
		end

		local ok = self.assignManualItem(itemLink, data.playerName)
		if ok then
			self.raidGrid.Hide()
		end
		return ok
	end

	function controller:OpenManualAwardGrid()
		if not self.isMasterLooter() then
			return false
		end
		queueHideBlizzardDropDownLists(self)

		local itemLink = self.getSelectedMasterLootLink()
		local title = itemLink or self.L.StrRaidGridTitle
		local entries =
			self.assignmentCandidates.BuildRows(collectMasterLootCandidates(self), self.getRaidGridPlayerClass)
		local debugFallback = false
		if
			#entries <= 0
			and self.debugRaidGrid.IsFallbackEnabled(
				feature.coreState and feature.coreState.debug or nil,
				self.isDebugEnabled()
			)
		then
			local debugState = feature.coreState and feature.coreState.debug or nil
			local count = self.debugRaidGrid.GetTargetCount(debugState)
			entries = self.debugRaidGrid.BuildRows(count, collectRaidGridRosterRows(self))
			title = title .. " (" .. (self.L.StrRaidGridDebugTitle or "Debug") .. ")"
			debugFallback = true
		end

		self.raidGrid.ShowPicker({
			mode = debugFallback and "debug" or "award",
			title = title,
			texture = self.getSelectedMasterLootTexture(),
			count = self.getSelectedMasterLootCount(),
			emptyText = self.L.StrRaidGridEmpty,
			entries = entries,
			anchor = self.getRaidGridFrameAnchor(),
			closeOnSelect = not debugFallback,
			onSelect = debugFallback and function()
				return false
			end or function(entry)
				return handleManualGridEntry(self, entry)
			end,
		})
		return true
	end

	function controller:OpenDebugRaidGrid(count)
		local debugState = feature.coreState and feature.coreState.debug or nil
		if not debugState then
			feature.coreState.debug = {}
			debugState = feature.coreState.debug
		end
		debugState.raidGridTargetCount = count or 25

		local entries, total = self.debugRaidGrid.BuildRows(count, collectRaidGridRosterRows(self))
		self.raidGrid.ShowPicker({
			mode = "debug",
			title = (self.L.StrRaidGridDebugTitle or "Raid Grid Debug") .. " (" .. tostring(total) .. ")",
			emptyText = self.L.StrRaidGridEmpty,
			entries = entries,
			anchor = self.getRaidGridFrameAnchor(),
			closeOnSelect = false,
			onSelect = function()
				return false
			end,
		})
		return total
	end

	function controller:RefreshManualAwardGrid()
		if self.raidGrid.IsShown() and self.raidGrid.GetMode() == "award" then
			return self:OpenManualAwardGrid()
		end
		return false
	end

	return controller
end

local registry = feature.ModuleRegistry
if type(registry) == "table" and type(registry.AddModule) == "function" and type(registry.SetLoaded) == "function" then
	registry.AddModule("Services/Master/AssignmentUi", {
		deps = {
			"Init",
			"Modules/ModuleRegistry",
			"Services/Master/AssignmentCandidates",
			"Services/Master/AssignmentTargets",
			"Services/Master/DebugRaidGrid",
		},
	})
	registry.SetLoaded("Services/Master/AssignmentUi")
end

return AssignmentUi
