-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: direct addon namespace bindings
-- exports: publish module APIs on addon.*
-- events: listens forwarded loot/trade events and Master bus refresh events
local addon = select(2, ...)
local L = addon.L
local Diag = addon.Diag
local DebugEntryPoint = assert(addon.EntryPoints.Debug, "Master debug entrypoint is not initialized")

local UI = addon.UI
local Frames = UI.Frames
local Tooltips = UI.Tooltips
local Lists = assert(UI.Lists, "Master list controller namespace is not initialized")
local CreateListController = assert(Lists.CreateController, "Master roll list controller factory is not initialized")
local CreateRowRenderer = assert(Lists.CreateRowRenderer, "Master roll row renderer factory is not initialized")
local MakeIndexedRowName = assert(Lists.MakeIndexedRowName, "Master indexed row-name factory is not initialized")
local GetFrameRef = assert(Frames.GetRef, "Master frame ref resolver is not initialized")
local SetScriptSafely = assert(Frames.SetScriptSafely, "Master frame script binder is not initialized")
local BindModuleFrame = assert(Frames.BindModuleFrame, "Master module frame binder is not initialized")
local MakeModuleFrameGetter =
	assert(Frames.MakeModuleFrameGetter, "Master module frame getter factory is not initialized")
local SetFrameTitle = assert(Frames.SetFrameTitle, "Master frame title binder is not initialized")
local BindTooltip = assert(Tooltips.Bind, "Master tooltip binder is not initialized")
local HideTooltip = assert(Tooltips.Hide, "Master tooltip hider is not initialized")
local Primitives = UI.Primitives
local Rows = UI.Rows
local Popups = assert(UI.Popups, "Master popup namespace is not initialized")
local DefinePopup = assert(Popups.Define, "Master popup definer is not initialized")
local IsPopupDefined = assert(Popups.IsDefined, "Master popup defined-state checker is not initialized")
local ShowPopup = assert(Popups.Show, "Master popup shower is not initialized")
local ShowConfirmPopup = assert(Popups.ShowConfirm, "Master confirm popup shower is not initialized")
local Item = addon.Item
local Colors = addon.Colors
local Comms = addon.Comms
local Events = addon.Events
local C = addon.C
local Database = addon.Database
local Options = addon.Options
local Bus = addon.Bus
local Services = addon.Services
local Controllers = addon.Controllers
local Widgets = addon.Widgets
local Loot = assert(Services.Loot, "Master loot service is not initialized")
local LootDistribution = assert(Loot.DistributionSession, "Master loot distribution owner is not initialized")
local LootInventory = assert(Loot.Inventory, "Loot inventory owner is not initialized")
local LootAwardPlanner = assert(Loot.AwardPlanner, "Loot award planner owner is not initialized")
local LootAttribution = assert(Loot.LootAttribution, "Loot attribution owner is not initialized")
local Raid = assert(Services.Raid, "Master raid service is not initialized")
assert(Raid.LootBans, "Master loot bans service is not initialized")
local Rolls = assert(Services.Rolls, "Master rolls service is not initialized")
local Chat = assert(Services.Chat, "Master chat service is not initialized")
local LoggerActions = assert(Services.Logger.Actions, "Master logger actions service is not initialized")
local MasterService = assert(Services.Master, "Master service namespace is not initialized")
local RollSelectionService = assert(MasterService.RollSelection, "Master Roll Selection service is not initialized")
local AwardSequenceService = assert(MasterService.AwardSequence, "Master award sequence service is not initialized")
local AssignmentService = assert(MasterService.Assignment, "Master assignment service is not initialized")
local RaidDebug = assert(Services.Raid.Debug, "Raid debug service is not initialized")
local TradeExecutionService = assert(MasterService.TradeExecution, "Master trade execution service is not initialized")
local ItemSelectionWidget = assert(addon.Widgets.ItemSelection, "Master item selection widget is not initialized")

local InternalEvents = assert(Events.Internal, "Master controller internal events are not initialized")
local TriggerEvent = assert(Bus.TriggerEvent, "Master controller event publisher is not initialized")
local RegisterCallback = assert(Bus.RegisterCallback, "Master controller event listener is not initialized")
local ResolveWowForwardedName =
	assert(Events.ResolveWowForwardedName, "Master controller forwarded-event resolver is not initialized")
local MasterEvents = {
	GroupLootRestoreNeeded = assert(
		InternalEvents.GroupLootRestoreNeeded,
		"Master controller group-loot restore prompt event is not initialized"
	),
	SetItem = assert(InternalEvents.SetItem, "Master controller set-item event is not initialized"),
	RaidRosterDelta = assert(
		InternalEvents.RaidRosterDelta,
		"Master controller raid roster delta event is not initialized"
	),
	ReservesDataChanged = assert(
		InternalEvents.ReservesDataChanged,
		"Master controller reserves data changed event is not initialized"
	),
	AddRoll = assert(InternalEvents.AddRoll, "Master controller add-roll event is not initialized"),
	ConfigSortAscending = assert(
		InternalEvents.ConfigSortAscending,
		"Master controller sort setting event is not initialized"
	),
	ConfigShowLootCounterDuringMSRoll = assert(
		InternalEvents.ConfigShowLootCounterDuringMSRoll,
		"Master controller loot-counter setting event is not initialized"
	),
	SpecInspectUpdated = assert(
		InternalEvents.SpecInspectUpdated,
		"Master controller spec inspect update event is not initialized"
	),
	LootBansChanged = assert(
		InternalEvents.LootBansChanged,
		"Master controller loot bans changed event is not initialized"
	),
}
local rollTypes = addon.C.rollTypes
local PENDING_AWARD_TTL_SECONDS = C.PENDING_AWARD_TTL_SECONDS
local ML_MULTI_AWARD_TIMEOUT_SECONDS = C.ML_MULTI_AWARD_TIMEOUT_SECONDS
local LOOT_CONTEXT_SESSION_TTL_SECONDS =
	math.max(tonumber(C.GROUP_LOOT_PENDING_AWARD_TTL_SECONDS) or 60, tonumber(C.BOSS_EVENT_CONTEXT_TTL_SECONDS) or 30)

local isDebugEnabled = Options.IsDebugEnabled

local function isTraceEnabled()
	return addon.hasTrace ~= nil
end

local _, lootState, itemInfo = Database.EnsureLootRuntimeState()
lootState.lootCount = tonumber(lootState.lootCount) or 0
lootState.rollsCount = tonumber(lootState.rollsCount) or 0
lootState.selectedItemCount = tonumber(lootState.selectedItemCount) or 1
if lootState.selectedItemCount < 1 then
	lootState.selectedItemCount = 1
end
if lootState.fromInventory == nil then
	lootState.fromInventory = false
end

local tinsert, tconcat, twipe = table.insert, table.concat, table.wipe
local pairs, select, next = pairs, select, next

local tostring, tonumber = tostring, tonumber
local CreateFrame = assert(_G.CreateFrame, "Master controller frame creation API is not initialized")
local UnitName = assert(_G.UnitName, "Master controller unit name API is not initialized")
local GetMasterLootCandidate =
	assert(_G.GetMasterLootCandidate, "Master controller loot candidate API is not initialized")
local GetRaidRosterInfo = assert(_G.GetRaidRosterInfo, "Master controller raid roster API is not initialized")
local GetLootSlotInfo = assert(_G.GetLootSlotInfo, "Master controller loot slot info API is not initialized")
local GiveMasterLoot = assert(_G.GiveMasterLoot, "Master controller loot assignment API is not initialized")
local UIDropDownMenu_AddButton =
	assert(_G.UIDropDownMenu_AddButton, "Master controller dropdown button API is not initialized")
local UIDropDownMenu_CreateInfo =
	assert(_G.UIDropDownMenu_CreateInfo, "Master controller dropdown info API is not initialized")
local UIDropDownMenu_Initialize =
	assert(_G.UIDropDownMenu_Initialize, "Master controller dropdown init API is not initialized")
local UIDropDownMenu_JustifyText =
	assert(_G.UIDropDownMenu_JustifyText, "Master controller dropdown justify API is not initialized")
local UIDropDownMenu_SetButtonWidth =
	assert(_G.UIDropDownMenu_SetButtonWidth, "Master controller dropdown button-width API is not initialized")
local UIDropDownMenu_SetSelectedValue =
	assert(_G.UIDropDownMenu_SetSelectedValue, "Master controller dropdown selected-value API is not initialized")
local UIDropDownMenu_SetText =
	assert(_G.UIDropDownMenu_SetText, "Master controller dropdown text API is not initialized")
local UIDropDownMenu_SetWidth =
	assert(_G.UIDropDownMenu_SetWidth, "Master controller dropdown width API is not initialized")
local TradeExecutionWow = {
	ClearCursor = assert(_G.ClearCursor, "Master trade execution clear-cursor API is not initialized"),
	CursorHasItem = assert(_G.CursorHasItem, "Master trade execution cursor-item API is not initialized"),
	GetContainerItemInfo = assert(
		_G.GetContainerItemInfo,
		"Master trade execution container-item-info API is not initialized"
	),
	GetContainerItemLink = assert(
		_G.GetContainerItemLink,
		"Master trade execution container-item-link API is not initialized"
	),
	InitiateTrade = assert(_G.InitiateTrade, "Master trade execution initiate-trade API is not initialized"),
	PickupContainerItem = assert(
		_G.PickupContainerItem,
		"Master trade execution pickup-container-item API is not initialized"
	),
	SetRaidTarget = assert(_G.SetRaidTarget, "Master trade execution raid-target API is not initialized"),
	CheckInteractDistance = assert(
		_G.CheckInteractDistance,
		"Master trade execution interact-distance API is not initialized"
	),
}

local requireServiceMethod = Database.RequireServiceMethod

local RaidApi = {
	GetRosterVersion = requireServiceMethod("Raid", Raid, "GetRosterVersion"),
	RequestMasterLootCandidateRefresh = requireServiceMethod("Raid", Raid, "RequestMasterLootCandidateRefresh"),
	FindMasterLootCandidateIndex = requireServiceMethod("Raid", Raid, "FindMasterLootCandidateIndex"),
	CanResolveMasterLootCandidates = requireServiceMethod("Raid", Raid, "CanResolveMasterLootCandidates"),
	CanUseCapability = requireServiceMethod("Raid", Raid, "CanUseCapability"),
	EnsureMasterOnlyAccess = requireServiceMethod("Raid", Raid, "EnsureMasterOnlyAccess"),
}
local GetRollSession = requireServiceMethod("Rolls", Rolls, "GetRollSession")
local GetDisplayModel = requireServiceMethod("Rolls", Rolls, "GetDisplayModel")
local BeginTieReroll = requireServiceMethod("Rolls", Rolls, "BeginTieReroll")
local Announce = requireServiceMethod("Chat", Chat, "Announce")

-- =========== Master Looter Frame Module  =========== --
do
	addon.Controllers.Master = addon.Controllers.Master or {}
	local module = addon.Controllers.Master
	local uiState = UI.ModuleState.Ensure(module)

	-- Timer ownership: pending award execution, multi-award timeout/delay, and loot close.
	addon.Timer.BindMixin(module, "Master")

	-- Namespace registrations owned by the Master controller. Stored on `module`
	-- to avoid extra upvalues because this file is near Lua 5.1's 200 local/upvalue limit.
	-- Lookups happen through inline Options.Get(...) calls at call sites.
	Options.RegisterNamespace("Master", {
		sortAscending = false,
		useRaidWarning = true,
		screenReminder = true,
		announceOnWin = true,
		announceOnHold = true,
		announceOnBank = false,
		announceOnDisenchant = false,
		autoSpamLootOnLootOpened = false,
		autoSpamSoftResOnLootOpened = false,
	})
	Options.RegisterNamespace("Loot", {
		lootWhispers = false,
		ignoreStacks = false,
	})

	local GetOption = Options.GetValue

	-- ----- Internal state ----- --
	local getFrame = MakeModuleFrameGetter(module, "RMAMaster")

	module._dropDownData = module._dropDownData or {}
	module._dropDownGroupData = module._dropDownGroupData or {}
	-- Ensure subgroup tables exist even when the Master UI hasn't been opened yet.
	for i = 1, 8 do
		module._dropDownData[i] = module._dropDownData[i] or {}
	end
	module._dropDownDirty = true
	module._dropDownsInitialized = false

	module._itemSelectionState = module._itemSelectionState or { buttons = {} }

	module._lastUIState = module._lastUIState
		or {
			buttons = {},
			texts = {},
			tooltips = {},
			rollStatus = {},
			glows = {},
		}
	module._dirtyFlags = module._dirtyFlags
		or {
			itemCount = true,
			dropdowns = true,
			winner = true,
			rolls = true,
			buttons = true,
		}

	local assignItem, registerAwardedItem, clearMultiAwardState
	local updateRollSessionExpectedWinners
	local Private = {}
	local nextAwardAttemptId = 1
	local function createAwardAttempt(opts)
		opts = opts or {}
		local onConfirm = opts.onConfirm
		local onFail = opts.onFail
		local terminalEffects = {}
		opts.transactionId = "AT:" .. tostring(nextAwardAttemptId)
		nextAwardAttemptId = nextAwardAttemptId + 1
		opts.onConfirm = function(state, context)
			if type(onConfirm) == "function" and onConfirm(state, context) == false then
				return false
			end
			if not terminalEffects.itemDone then
				local ok, result =
					pcall(LootDistribution.PublishItemDone, state.itemKey or state.itemLink, state.winner)
				if not ok or result == false then
					return false
				end
				terminalEffects.itemDone = true
			end
			if state.source == "master_loot" and not terminalEffects.raidCount then
				local ok, result = pcall(
					Raid.AddPlayerCountForRollType,
					Raid,
					state.winner,
					state.executorContext and state.executorContext.rollType,
					1,
					state.executorContext and state.executorContext.raidNid
				)
				if not ok or result == false then
					return false
				end
				terminalEffects.raidCount = true
			end
			return true
		end
		opts.onFail = function(reason, state, context)
			if type(onFail) == "function" and onFail(reason, state, context) == false then
				return false
			end
			if not terminalEffects.itemCancelled then
				local ok, result =
					pcall(LootDistribution.PublishItemCancelled, state.itemKey or state.itemLink, state.winner, reason)
				if not ok or result == false then
					return false
				end
				terminalEffects.itemCancelled = true
			end
			return true
		end
		return MasterService.AwardAttempt.CreateExecuting(opts)
	end
	module._awardFlow = module._awardFlow or {}
	module._screenshotWarn = false

	module._announced = false
	module._cachedRosterVersion = nil
	module._rollSelectionState = module._rollSelectionState
		or {
			mode = RollSelectionService.Mode.AUTO,
			sessionKey = nil,
			showRollsOnly = true,
			model = nil,
		}
	module._awardConfirmation = MasterService.AwardConfirmation.Create({
		timeoutSeconds = C.ML_AWARD_CONFIRM_TIMEOUT_SECONDS,
		scheduleTimer = function(callback, delay)
			return module:ScheduleTimer(callback, delay)
		end,
		cancelTimer = function(handle)
			return module:CancelTimer(handle)
		end,
		requestRefresh = function()
			module:RequestRefresh()
		end,
		confirmProvisional = function(pending, clearedSlot)
			return LootAttribution.ConfirmProvisional(
				pending.itemLink,
				pending.playerName,
				pending.rollSessionId,
				clearedSlot,
				pending.transactionId,
				1,
				function(callback, delay)
					return Loot:ScheduleTimer(callback, delay)
				end,
				function(handle)
					return Loot:CancelTimer(handle)
				end,
				function(award)
					return Loot:LogTradeOnlyLoot(
						award.itemLink,
						award.looter,
						award.rollType,
						award.rollValue,
						1,
						"LOOT_SLOT_CLEARED",
						nil,
						nil,
						award.rollSessionId
					)
				end
			)
		end,
		warnFailure = function(pending, reason)
			addon:warn(
				Diag.W.LogMLAwardConfirmationFailed:format(
					tostring(pending.itemLink),
					tostring(pending.playerName),
					tostring(reason or "unknown")
				)
			)
		end,
		warnTimeout = function(timeout, pending)
			addon:warn(
				Diag.W.LogMLAwardConfirmationTimeout:format(
					timeout,
					tostring(pending.itemLink),
					tostring(pending.playerName),
					tostring(pending.itemIndex or "?")
				)
			)
		end,
	})
	module._FLOW_STATES = module._FLOW_STATES
		or {
			IDLE = "idle",
			LOOT = "loot",
			ROLLING = "rolling",
			COUNTDOWN = "countdown",
			INVENTORY = "inventory",
			MULTI_AWARD = "multi_award",
			TRADE = "trade",
		}
	module._flowState = module._flowState or module._FLOW_STATES.IDLE
	module._rollAnnouncementKeys = module._rollAnnouncementKeys
		or {
			[rollTypes.MAINSPEC] = "ChatRollMS",
			[rollTypes.OFFSPEC] = "ChatRollOS",
			[rollTypes.RESERVED] = "ChatRollSR",
			[rollTypes.FREE] = "ChatRollFree",
		}
	module._assignDropDownWidth = 132
	module._assignDropDownButtonWidth = 152

	-- ----- Private helpers ----- --

	local function getFrameName()
		return uiState.FrameName
	end

	local MASTER_REF_SUFFIXES = {
		"AwardBtn",
		"BankBtn",
		"ClearBtn",
		"ConfigBtn",
		"CountdownBtn",
		"DisenchantBtn",
		"FreeBtn",
		"HoldBtn",
		"ItemBtn",
		"LootCounterBtn",
		"LootBansBtn",
		"MSBtn",
		"OSBtn",
		"ReserveListBtn",
		"RollBtn",
		"SRBtn",
		"SelectItemBtn",
		"SpamLootBtn",
		"Status",
	}

	local function acquireMasterRefs()
		local frameName = getFrameName()
		if not frameName then
			return nil
		end
		local refs = module._refs
		if type(refs) ~= "table" or refs.frameName ~= frameName then
			refs = { frameName = frameName }
			module._refs = refs
		end
		for i = 1, #MASTER_REF_SUFFIXES do
			local suffix = MASTER_REF_SUFFIXES[i]
			if refs[suffix] == nil then
				refs[suffix] = _G[frameName .. suffix] or false
			end
		end
		return refs
	end

	local function getNamedPart(suffix)
		local refs = acquireMasterRefs()
		if refs and refs[suffix] == nil then
			refs[suffix] = _G[refs.frameName .. suffix] or false
		end
		local ref = refs and refs[suffix] or nil
		if ref == false then
			return nil
		end
		return ref
	end

	-- Module-level helper: wrap a click handler ensuring master-only access.
	local function wrapMasterOnlyClick(handler, allowInventoryTrade)
		return function(...)
			if allowInventoryTrade == true and lootState.fromInventory == true then
				if RaidApi.CanUseCapability(Raid, "inventory_trade") then
					return handler(...)
				end
				addon:warn(L.WarnInventoryTradeNoPermission or L.WarnMLOnlyMode)
				return
			end
			if not RaidApi.EnsureMasterOnlyAccess(Raid) then
				return
			end
			return handler(...)
		end
	end

	-- Module-level helper: ensure spam-loot access rules.
	local function ensureSpamLootAccess()
		if lootState.fromInventory == true then
			if RaidApi.CanUseCapability(Raid, "ready_check") then
				return true
			end
			addon:warn(L.WarnReadyCheckNotAllowed)
			return false
		end
		return RaidApi.EnsureMasterOnlyAccess(Raid)
	end

	local function canHandleLootWindow()
		if Raid.IsMasterLooter and Raid:IsMasterLooter() then
			return true
		end
		return Raid.CanObservePassiveLoot and Raid:CanObservePassiveLoot() or false
	end

	local function canUseItemSelection()
		if lootState.fromInventory == true then
			return RaidApi.CanUseCapability(Raid, "inventory_trade")
		end
		return canHandleLootWindow()
	end

	local function ensureItemSelectionAccess()
		if lootState.fromInventory == true then
			if RaidApi.CanUseCapability(Raid, "inventory_trade") then
				return true
			end
			addon:warn(L.WarnInventoryTradeNoPermission or L.WarnMLOnlyMode)
			return false
		end
		if canHandleLootWindow() then
			return true
		end
		return RaidApi.EnsureMasterOnlyAccess(Raid)
	end

	local function canAutoManageLootFrame()
		return Raid.IsMasterLooter and Raid:IsMasterLooter() or false
	end

	local function getRaidGridPlayerClass(name)
		if Raid and Raid.GetPlayerClass then
			return Raid:GetPlayerClass(name)
		end
		return nil
	end

	local refreshDropDowns

	local function getAssignmentFieldByKey(targetKey)
		if targetKey == "holder" then
			return {
				stateKey = "holder",
				raidKey = "holder",
				frame = module._dropDownFrameHolder,
				label = L.BtnHold,
			}
		elseif targetKey == "banker" then
			return {
				stateKey = "banker",
				raidKey = "banker",
				frame = module._dropDownFrameBanker,
				label = L.BtnBank,
			}
		elseif targetKey == "disenchanter" then
			return {
				stateKey = "disenchanter",
				raidKey = "disenchanter",
				frame = module._dropDownFrameDisenchanter,
				label = L.BtnDisenchant,
			}
		end
		return nil
	end

	local function findDropDownField(frameNameFull)
		if not frameNameFull then
			return nil
		end

		local holderName = module._dropDownFrameHolder
				and module._dropDownFrameHolder.GetName
				and module._dropDownFrameHolder:GetName()
			or nil
		local bankerName = module._dropDownFrameBanker
				and module._dropDownFrameBanker.GetName
				and module._dropDownFrameBanker:GetName()
			or nil
		local disenchanterName = module._dropDownFrameDisenchanter
				and module._dropDownFrameDisenchanter.GetName
				and module._dropDownFrameDisenchanter:GetName()
			or nil

		if frameNameFull == holderName then
			return { stateKey = "holder", raidKey = "holder", frame = module._dropDownFrameHolder }
		elseif frameNameFull == bankerName then
			return { stateKey = "banker", raidKey = "banker", frame = module._dropDownFrameBanker }
		elseif frameNameFull == disenchanterName then
			return {
				stateKey = "disenchanter",
				raidKey = "disenchanter",
				frame = module._dropDownFrameDisenchanter,
			}
		end
		return nil
	end

	local function collectMasterLootCandidates()
		local result = {}
		for i = 1, 40 do
			local name = GetMasterLootCandidate(i)
			if name and name ~= "" then
				tinsert(result, {
					name = name,
					index = i,
				})
			end
		end
		return result
	end

	local function collectRaidGridRosterRows()
		local result = {}
		local seen = {}

		for unit in addon.UnitIterator(true) do
			local name = UnitName(unit)
			if name and name ~= "" and not seen[name] then
				local className = getRaidGridPlayerClass(name)
				if not className then
					local _, classFileName = UnitClass(unit)
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

	Private.BuildLootBanRows = function()
		local rows = collectRaidGridRosterRows()
		for i = 1, #rows do
			local row = rows[i]
			local active, note = Raid.LootBans.Get(row.name)
			if active then
				row.textColor = { r = 0.5, g = 0.5, b = 0.5 }
				row.tooltipLines = { { text = L.StrLootBanTooltipTitle } }
				if note then
					row.tooltipLines[#row.tooltipLines + 1] = { text = note }
				end
			end
		end
		return rows
	end

	Private.EnsureLootBanEditorPopup = function()
		if IsPopupDefined("RMA_LOOT_BAN_EDITOR") then
			return true
		end

		return DefinePopup("RMA_LOOT_BAN_EDITOR", {
			text = L.PopupLootBanApply,
			button1 = L.BtnApplyBan,
			button2 = _G.CANCEL or L.BtnCancel,
			button3 = L.BtnRemoveBan,
			timeout = 0,
			whileDead = 1,
			hideOnEscape = 1,
			hasEditBox = 1,
			OnShow = function(self, data)
				if type(data) ~= "table" then
					return
				end
				local active, note = Raid.LootBans.Get(data.name)
				data.active = active
				if self.text and self.text.SetText then
					local template = active and L.PopupLootBanUpdate or L.PopupLootBanApply
					self.text:SetText(template:format(data.name))
				end
				if self.button1 and self.button1.SetText then
					self.button1:SetText(active and L.BtnUpdateBan or L.BtnApplyBan)
				end
				if self.button3 then
					if self.button3.SetText then
						self.button3:SetText(L.BtnRemoveBan)
					end
					if active and self.button3.Show then
						self.button3:Show()
					elseif self.button3.Hide then
						self.button3:Hide()
					end
				end
				if self.editBox then
					self.editBox:SetMaxLetters(240)
					self.editBox:SetText(note or "")
					self.editBox:SetFocus()
					self.editBox:HighlightText()
				end
			end,
			OnHide = function(self)
				if self.editBox then
					self.editBox:SetText("")
					self.editBox:ClearFocus()
				end
			end,
			OnAccept = function(self, data)
				if type(data) ~= "table" or not data.name then
					return
				end
				local note = self.editBox and self.editBox:GetText() or nil
				local ok, err = Raid.LootBans.Set(data.name, note)
				if ok then
					return
				end
				if self.text and self.text.SetText then
					self.text:SetText(err == "note_non_ascii" and L.ErrLootBanNoteAscii or L.ErrLootBanNoteTooLong)
				end
				return true
			end,
			OnAlt = function(_, data)
				if type(data) == "table" and data.active then
					Raid.LootBans.Remove(data.name)
				end
			end,
		})
	end

	Private.OpenLootBanEditor = function(entry)
		if type(entry) ~= "table" or not entry.name or not Private.EnsureLootBanEditorPopup() then
			return false
		end
		return ShowPopup("RMA_LOOT_BAN_EDITOR", nil, nil, { name = entry.name })
	end

	function module:OpenLootBansGrid()
		return Widgets.RaidGrid.ShowPicker({
			mode = "lootBan",
			title = L.StrLootBansTitle,
			emptyText = L.StrLootBansEmpty,
			entries = Private.BuildLootBanRows(),
			closeOnSelect = false,
			anchor = Private.GetRaidGridFrameAnchor(),
			onSelect = Private.OpenLootBanEditor,
		})
	end

	Private.HideBlizzardDropDownLists = function()
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

	Private.QueueHideBlizzardDropDownLists = function()
		Private.HideBlizzardDropDownLists()
		module:ScheduleTimer(Private.HideBlizzardDropDownLists, 0)
	end

	local function updateAssignmentDropDown(frame)
		if not frame or not Database.GetCurrentRaid() then
			return
		end

		local field = findDropDownField(frame:GetName())
		if not field then
			return
		end

		local raid = Database.GetRaidStore():EnsureRaidByIndex(Database.GetCurrentRaid())
		if not raid then
			return
		end
		lootState[field.stateKey] = raid[field.raidKey]

		if lootState[field.stateKey] and Raid:GetUnitID(lootState[field.stateKey]) == "none" then
			raid[field.raidKey] = nil
			lootState[field.stateKey] = nil
		end

		if lootState[field.stateKey] then
			UIDropDownMenu_SetText(field.frame, lootState[field.stateKey])
			UIDropDownMenu_SetSelectedValue(field.frame, lootState[field.stateKey])
			module._dirtyFlags.buttons = true
		end
	end

	local function setAssignmentTarget(targetKey, playerName)
		if not playerName or playerName == "" then
			return false
		end

		local field = getAssignmentFieldByKey(targetKey)
		if not field then
			return false
		end

		local raidId = Database.GetCurrentRaid()
		local raid = raidId and Database.GetRaidStore():EnsureRaidByIndex(raidId) or nil
		if raid then
			raid[field.raidKey] = playerName
		end
		lootState[field.stateKey] = playerName

		if field.frame then
			UIDropDownMenu_SetText(field.frame, playerName)
			UIDropDownMenu_SetSelectedValue(field.frame, playerName)
		end

		module._dropDownDirty = true
		module._dirtyFlags.dropdowns = true
		module._dirtyFlags.buttons = true
		Private.HideBlizzardDropDownLists()
		Widgets.RaidGrid.Hide()
		module:RequestRefresh()
		return true
	end

	local function ensureRaidGridConfirmPopup()
		if IsPopupDefined("RMA_MASTER_LOOT_GRID_CONFIRM") then
			return true
		end

		return DefinePopup("RMA_MASTER_LOOT_GRID_CONFIRM", {
			text = L.PopupRaidGridConfirm or "Give %s to %s?",
			button1 = _G.YES or _G.OKAY,
			button2 = _G.NO or _G.CANCEL,
			timeout = 0,
			whileDead = 1,
			hideOnEscape = 1,
			OnAccept = function(_, data)
				Private.AcceptManualGridAward(data)
			end,
		})
	end

	Private.ShowManualGridAwardConfirm = function(itemLink, playerName)
		if not ensureRaidGridConfirmPopup() then
			return false
		end

		local data = {
			itemLink = itemLink,
			itemText = itemLink or L.StrRaidGridTitle,
			playerName = playerName,
		}
		return ShowPopup("RMA_MASTER_LOOT_GRID_CONFIRM", data.itemText, playerName, data)
	end

	local function handleManualGridEntry(entry)
		if type(entry) ~= "table" or not entry.name then
			return false
		end

		local itemLink = Private.GetSelectedMasterLootLink()
		if not itemLink then
			return false
		end

		local threshold = _G.MASTER_LOOT_THREHOLD or _G.MASTER_LOOT_THRESHOLD or 4
		if Private.GetSelectedMasterLootQuality() >= threshold then
			return Private.ShowManualGridAwardConfirm(itemLink, entry.name)
		end
		return Private.AcceptManualGridAward({
			itemLink = itemLink,
			playerName = entry.name,
		})
	end

	local function openAssignmentTargetGrid(targetKey)
		local field = getAssignmentFieldByKey(targetKey)
		if not field then
			return false
		end

		Private.QueueHideBlizzardDropDownLists()
		Private.PrepareDropDowns()

		local title = L.StrRaidGridTargetTitle
		if field.label then
			title = title .. ": " .. field.label
		end

		Widgets.RaidGrid.ShowPicker({
			mode = "target",
			title = title,
			emptyText = L.StrRaidGridEmpty,
			entries = AssignmentService.BuildTargetRows(module._dropDownData, getRaidGridPlayerClass),
			anchor = field.frame or getFrame(),
			onSelect = function(entry)
				return setAssignmentTarget(targetKey, entry and entry.name)
			end,
		})
		return true
	end

	Private.OnClickDropDown = function(_button, owner, value)
		if not owner or not value or not Database.GetCurrentRaid() then
			return
		end

		local field = findDropDownField(owner:GetName())
		if field then
			setAssignmentTarget(field.stateKey, value)
			return
		end

		UIDropDownMenu_SetText(owner, value)
		UIDropDownMenu_SetSelectedValue(owner, value)
		module._dropDownDirty = true
		module._dirtyFlags.dropdowns = true
		module._dirtyFlags.buttons = true
		Private.HideBlizzardDropDownLists()
		module:RequestRefresh()
	end

	Private.InitializeDropDownMenu = function()
		if _G.UIDROPDOWNMENU_MENU_LEVEL == 2 then
			local group = _G.UIDROPDOWNMENU_MENU_VALUE
			local members = module._dropDownData[group]
			if type(members) ~= "table" then
				return
			end
			for key in pairs(members) do
				local info = UIDropDownMenu_CreateInfo()
				info.hasArrow = false
				info.notCheckable = 1
				info.text = key
				info.func = function(button, owner, value)
					return Private.OnClickDropDown(button, owner, value)
				end
				info.arg1 = _G.UIDROPDOWNMENU_OPEN_MENU
				info.arg2 = key
				UIDropDownMenu_AddButton(info, _G.UIDROPDOWNMENU_MENU_LEVEL)
			end
		end
		if _G.UIDROPDOWNMENU_MENU_LEVEL == 1 then
			for key in pairs(module._dropDownData) do
				if module._dropDownGroupData[key] == true then
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

	local function configureAssignDropDown(frame)
		if not frame then
			return
		end
		frame:SetWidth(module._assignDropDownButtonWidth)
		UIDropDownMenu_SetWidth(frame, module._assignDropDownWidth)
		UIDropDownMenu_SetButtonWidth(frame, module._assignDropDownButtonWidth)
		UIDropDownMenu_JustifyText(frame, "LEFT")
	end

	local function hookDropDownOpen(frame, targetKey)
		if not frame then
			return
		end

		local button = _G[frame:GetName() .. "Button"]
		if button and not button._RMAHooked then
			Frames.HookScriptSafely(button, "OnClick", function()
				refreshDropDowns(true)
				openAssignmentTargetGrid(targetKey)
			end)
			button._RMAHooked = true
		end
	end

	Private.PrepareDropDowns = function()
		local rosterVersion = RaidApi.GetRosterVersion(Raid)
		if rosterVersion and module._cachedRosterVersion == rosterVersion then
			return
		end
		if rosterVersion ~= module._cachedRosterVersion then
			RaidApi.RequestMasterLootCandidateRefresh(Raid)
		end
		module._cachedRosterVersion = rosterVersion
		module._dropDownDirty = true
		module._dirtyFlags.dropdowns = true

		for i = 1, 8 do
			local names = module._dropDownData[i]
			if names then
				twipe(names)
			else
				names = {}
				module._dropDownData[i] = names
			end
		end

		module._dropDownGroupData = module._dropDownGroupData or {}
		twipe(module._dropDownGroupData)

		for unit in addon.UnitIterator(true) do
			local name = UnitName(unit)
			if name and name ~= "" then
				local subgroup = 1
				local idx = tonumber(unit:match("^raid(%d+)$"))
				if idx then
					subgroup = (select(3, GetRaidRosterInfo(idx))) or 1
				end

				module._dropDownData[subgroup] = module._dropDownData[subgroup] or {}
				module._dropDownData[subgroup][name] = name
				module._dropDownGroupData[subgroup] = true
			end
		end

		refreshDropDowns(true)
	end

	Private.InitializeDropDowns = function()
		local frames = {
			{ frame = module._dropDownFrameHolder, targetKey = "holder" },
			{ frame = module._dropDownFrameBanker, targetKey = "banker" },
			{ frame = module._dropDownFrameDisenchanter, targetKey = "disenchanter" },
		}

		for i = 1, #frames do
			local entry = frames[i]
			local frame = entry.frame
			if frame then
				UIDropDownMenu_Initialize(frame, Private.InitializeDropDownMenu)
				configureAssignDropDown(frame)
				hookDropDownOpen(frame, entry.targetKey)
			end
		end

		module._dropDownsInitialized = true
		refreshDropDowns(true)
	end

	Private.AcceptManualGridAward = function(data)
		if type(data) ~= "table" or not data.playerName then
			return false
		end

		local itemLink = data.itemLink or Private.GetSelectedMasterLootLink()
		if not itemLink then
			return false
		end

		lootState.currentRollType = rollTypes.MANUAL
		local ok = assignItem(itemLink, data.playerName, rollTypes.MANUAL, 0)
		if ok then
			Widgets.RaidGrid.Hide()
		end
		return ok
	end

	Private.OpenManualAwardGrid = function()
		if not (Raid and Raid.IsMasterLooter and Raid:IsMasterLooter()) then
			return false
		end
		Private.QueueHideBlizzardDropDownLists()

		local itemLink = Private.GetSelectedMasterLootLink()
		local title = itemLink or L.StrRaidGridTitle
		local entries = AssignmentService.BuildCandidateRows(collectMasterLootCandidates(), getRaidGridPlayerClass)
		local debugFallback = false
		if
			#entries <= 0
			and RaidDebug.IsRaidGridDebugFallbackEnabled(addon.State and addon.State.debug or nil, isDebugEnabled())
		then
			local debugState = addon.State and addon.State.debug or nil
			local count = RaidDebug.GetRaidGridDebugTargetCount(debugState)
			entries = RaidDebug.BuildRaidGridDebugRows(count, collectRaidGridRosterRows())
			title = title .. " (" .. (L.StrRaidGridDebugTitle or "Debug") .. ")"
			debugFallback = true
		end

		Widgets.RaidGrid.ShowPicker({
			mode = debugFallback and "debug" or "award",
			title = title,
			texture = Private.GetSelectedMasterLootTexture(),
			count = Private.GetSelectedMasterLootCount(),
			emptyText = L.StrRaidGridEmpty,
			entries = entries,
			anchor = Private.GetRaidGridFrameAnchor(),
			closeOnSelect = not debugFallback,
			onSelect = debugFallback and function()
				return false
			end or function(entry)
				return handleManualGridEntry(entry)
			end,
		})
		return true
	end

	Private.RefreshManualAwardGrid = function()
		if Widgets.RaidGrid.IsShown() and Widgets.RaidGrid.GetMode() == "award" then
			return Private.OpenManualAwardGrid()
		end
		return false
	end

	Private.OpenDebugRaidGrid = function(count)
		local debugState = addon.State and addon.State.debug or nil
		if not debugState then
			addon.State.debug = {}
			debugState = addon.State.debug
		end
		debugState.raidGridTargetCount = count or 25

		local entries, total = RaidDebug.BuildRaidGridDebugRows(count, collectRaidGridRosterRows())
		Widgets.RaidGrid.ShowPicker({
			mode = "debug",
			title = (L.StrRaidGridDebugTitle or "Raid Grid Debug") .. " (" .. tostring(total) .. ")",
			emptyText = L.StrRaidGridEmpty,
			entries = entries,
			anchor = Private.GetRaidGridFrameAnchor(),
			closeOnSelect = false,
			onSelect = function()
				return false
			end,
		})
		return total
	end

	-- ============================================================================
	-- Roll selection / UI model helpers
	-- ============================================================================
	local function getRollSelectionSessionKey()
		local session = GetRollSession(Rolls)
		return session and tostring(session.id) or nil
	end

	local buildRollSelectionModel, selectRollWinnerRow
	local rollSelectionController = RollSelectionService.CreateController({
		getDisplayModel = function()
			return GetDisplayModel(Rolls)
		end,
		getSessionKey = getRollSelectionSessionKey,
		isFromInventory = function()
			return lootState.fromInventory == true
		end,
		isSelectionBlocked = function()
			return lootState.multiAward and lootState.multiAward.active
		end,
		onSelectionBlocked = function()
			addon:warn(Diag.W.ErrMLMultiAwardInProgress)
		end,
		rollRows = MasterService.RollRows,
		selection = UI.Selection,
		state = module._rollSelectionState,
		warnTooMany = function(maxSel)
			addon:warn(Diag.W.ErrMLMultiSelectTooMany:format(maxSel))
		end,
	})
	local awardController
	local tradeExecutionController
	local itemSelectionController

	local function invalidateRollSelectionModel()
		return rollSelectionController:Invalidate()
	end

	-- ============================================================================
	-- UI binding helpers
	-- ============================================================================
	function uiState.AcquireRefs(frame)
		return {
			configBtn = GetFrameRef(frame, "ConfigBtn"),
			selectItemBtn = GetFrameRef(frame, "SelectItemBtn"),
			spamLootBtn = GetFrameRef(frame, "SpamLootBtn"),
			msBtn = GetFrameRef(frame, "MSBtn"),
			osBtn = GetFrameRef(frame, "OSBtn"),
			srBtn = GetFrameRef(frame, "SRBtn"),
			freeBtn = GetFrameRef(frame, "FreeBtn"),
			countdownBtn = GetFrameRef(frame, "CountdownBtn"),
			awardBtn = GetFrameRef(frame, "AwardBtn"),
			rollBtn = GetFrameRef(frame, "RollBtn"),
			clearBtn = GetFrameRef(frame, "ClearBtn"),
			holdBtn = GetFrameRef(frame, "HoldBtn"),
			bankBtn = GetFrameRef(frame, "BankBtn"),
			disenchantBtn = GetFrameRef(frame, "DisenchantBtn"),
			reserveListBtn = GetFrameRef(frame, "ReserveListBtn"),
			lootCounterBtn = GetFrameRef(frame, "LootCounterBtn"),
			lootBansBtn = GetFrameRef(frame, "LootBansBtn"),
		}
	end

	local function initItemButtonScripts()
		local itemBtn = getNamedPart("ItemBtn")
		if not itemBtn or itemBtn._RMAMlInvDropInit then
			return
		end

		itemBtn._RMAMlInvDropInit = true
		itemBtn:RegisterForClicks("AnyUp")
		itemBtn:RegisterForDrag("LeftButton")

		SetScriptSafely(itemBtn, "OnClick", function()
			itemSelectionController:TryAcceptFromCursor()
		end)

		SetScriptSafely(itemBtn, "OnReceiveDrag", function()
			itemSelectionController:TryAcceptFromCursor()
		end)
	end

	local function bindMainControlScripts(frame, refs)
		if not (frame and refs) then
			return
		end
		if frame._RMABound then
			return
		end

		SetScriptSafely(refs.configBtn, "OnClick", function()
			Controllers.Config:Toggle()
		end)
		SetScriptSafely(refs.selectItemBtn, "OnClick", function(self, button)
			if not ensureItemSelectionAccess() then
				return
			end
			Private.BtnSelectItem(self, button)
		end)
		SetScriptSafely(refs.spamLootBtn, "OnClick", function(self, button)
			if not ensureSpamLootAccess() then
				return
			end
			Private.BtnSpamLoot(self, button)
		end)
		SetScriptSafely(
			refs.msBtn,
			"OnClick",
			wrapMasterOnlyClick(function(self, button)
				Private.BtnMS(self, button)
			end, true)
		)
		SetScriptSafely(
			refs.osBtn,
			"OnClick",
			wrapMasterOnlyClick(function(self, button)
				Private.BtnOS(self, button)
			end, true)
		)
		SetScriptSafely(
			refs.srBtn,
			"OnClick",
			wrapMasterOnlyClick(function(self, button)
				Private.BtnSR(self, button)
			end, true)
		)
		SetScriptSafely(
			refs.freeBtn,
			"OnClick",
			wrapMasterOnlyClick(function(self, button)
				Private.BtnFree(self, button)
			end, true)
		)
		if refs.countdownBtn and refs.countdownBtn.RegisterForClicks then
			local ok = pcall(function()
				refs.countdownBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
			end)
			if not ok then
				-- Keep left-click behavior even on clients/templates that reject custom click registration.
				refs.countdownBtn:RegisterForClicks("LeftButtonUp")
			end
		end
		SetScriptSafely(
			refs.countdownBtn,
			"OnClick",
			wrapMasterOnlyClick(function(self, button)
				Private.BtnCountdown(self, button)
			end, true)
		)
		SetScriptSafely(
			refs.awardBtn,
			"OnClick",
			wrapMasterOnlyClick(function(self, button)
				Private.BtnAward(self, button)
			end, true)
		)
		SetScriptSafely(
			refs.rollBtn,
			"OnClick",
			wrapMasterOnlyClick(function(self, button)
				Rolls:Roll(self, button)
			end, true)
		)
		SetScriptSafely(
			refs.clearBtn,
			"OnClick",
			wrapMasterOnlyClick(function(self, button)
				Private.BtnClear(self, button)
			end, true)
		)
		SetScriptSafely(
			refs.holdBtn,
			"OnClick",
			wrapMasterOnlyClick(function(self, button)
				Private.BtnHold(self, button)
			end, true)
		)
		SetScriptSafely(
			refs.bankBtn,
			"OnClick",
			wrapMasterOnlyClick(function(self, button)
				Private.BtnBank(self, button)
			end, true)
		)
		SetScriptSafely(
			refs.disenchantBtn,
			"OnClick",
			wrapMasterOnlyClick(function(self, button)
				Private.BtnDisenchant(self, button)
			end, true)
		)
		SetScriptSafely(
			refs.reserveListBtn,
			"OnClick",
			wrapMasterOnlyClick(function(self, button)
				Private.BtnReserveList(self, button)
			end)
		)
		SetScriptSafely(refs.lootCounterBtn, "OnClick", function(self, button)
			Private.BtnLootCounter(self, button)
		end)
		SetScriptSafely(refs.lootBansBtn, "OnClick", function()
			module:OpenLootBansGrid()
		end)

		frame._RMABound = true
	end

	-- ============================================================================
	-- Flow / session helpers
	-- ============================================================================
	local function setItemCountValue(count, focus)
		local frame = getFrame()
		if not frame then
			return
		end
		uiState.FrameName = uiState.FrameName or (frame.GetName and frame:GetName()) or uiState.FrameName
		local frameName = getFrameName() or frame:GetName()
		if not frameName or frameName ~= frame:GetName() then
			return
		end
		local itemCountBox = getNamedPart("ItemCount")
		if not itemCountBox then
			return
		end
		count = tonumber(count) or 1
		if count < 1 then
			count = 1
		end
		lootState.selectedItemCount = count
		updateRollSessionExpectedWinners()
		UI.EditBoxes.SetValue(itemCountBox, count, focus)
		module._lastUIState.itemCountText = tostring(count)
		module._dirtyFlags.itemCount = false
	end

	local function isCountdownRunning()
		return Rolls:IsCountdownRunning() == true
	end

	local function computeFlowState()
		if lootState.multiAward and lootState.multiAward.active and not lootState.fromInventory then
			return module._FLOW_STATES.MULTI_AWARD
		end
		if lootState.trader then
			return module._FLOW_STATES.TRADE
		end
		if lootState.fromInventory then
			return module._FLOW_STATES.INVENTORY
		end
		if isCountdownRunning() then
			return module._FLOW_STATES.COUNTDOWN
		end
		if lootState.rollStarted then
			return module._FLOW_STATES.ROLLING
		end
		if (lootState.lootCount or 0) > 0 then
			return module._FLOW_STATES.LOOT
		end
		return module._FLOW_STATES.IDLE
	end

	local function syncFlowState()
		local nextState = computeFlowState()
		if module._flowState ~= nextState then
			module._flowState = nextState
			module._dirtyFlags.buttons = true
		end
		return module._flowState
	end

	local function getCurrentMultiAwardWinner()
		local ma = lootState.multiAward
		if ma and ma.active and not lootState.fromInventory then
			return ma.currentWinner
		end
		return nil
	end

	local function getCurrentTradeWinner()
		if lootState.trader then
			return lootState.tradeWinner
		end
		return nil
	end

	buildRollSelectionModel = function(forceRefresh)
		return rollSelectionController:BuildModel(forceRefresh)
	end

	selectRollWinnerRow = function(name)
		return rollSelectionController:SelectWinnerRow(name)
	end

	local function copyVisibleRollRows(out)
		return rollSelectionController:CopyVisibleRows(out)
	end

	local function getFocusedRollRowId()
		return rollSelectionController:GetFocusedRowId()
	end

	local function onRollRowClick(self)
		if selectRollWinnerRow(self.playerName) then
			module:RequestRefresh()
		end
	end

	local function drawRollRow(row, data)
		Rows.DrawMasterRollRow(row, data, onRollRowClick)
	end

	Private.RenderRollRowsFallback = function(frameName)
		local visibleRows = rollSelectionController:GetVisibleRows()
		if type(visibleRows) ~= "table" or #visibleRows <= 0 or type(frameName) ~= "string" or frameName == "" then
			return false
		end

		local parent = _G[frameName .. "ScrollFrameScrollChild"] or _G[frameName]
		if not parent then
			return false
		end

		for i = 1, #visibleRows do
			local btnName = frameName .. "PlayerBtn" .. i
			local row = _G[btnName]
			if not row then
				row = CreateFrame("Button", btnName, parent, "RMASelectPlayerTemplate")
			end
			if row then
				if row.SetID then
					row:SetID(i)
				end
				drawRollRow(row, visibleRows[i])
				if row.Show then
					row:Show()
				end
			end
		end
		return true
	end

	module._rollListController = CreateListController({
		keyName = "MasterRolls",
		rowName = MakeIndexedRowName("PlayerBtn"),
		rowTmpl = "RMASelectPlayerTemplate",
		_rowParts = { "Name", "Roll", "Counter", "Info", "Star", "SpecIcon" },
		getData = copyVisibleRollRows,
		drawRow = CreateRowRenderer(drawRollRow),
		highlightFn = function(_, data)
			return data and data.isSelected == true
		end,
		focusId = getFocusedRollRowId,
	})

	local function buildAutoLootSuggestionToken(suggestion)
		if type(suggestion) ~= "table" then
			return ""
		end
		return tostring(suggestion.action or "")
			.. "|"
			.. tostring(suggestion.reason or "")
			.. "|"
			.. tostring(suggestion.targetKey or "")
	end

	module._Private = Private

	local function resetItemCountAndRefresh(focus)
		Private.ResetItemCount(focus)
		module:RequestRefresh()
	end

	updateRollSessionExpectedWinners = function(count)
		return Rolls:SetExpectedWinners(count)
	end

	local function buildLootRollSessionOptions()
		return {
			fromInventory = lootState.fromInventory == true,
			holderName = Database.GetPlayerName(),
			raidNum = Database.GetCurrentRaid(),
			ttlSeconds = LOOT_CONTEXT_SESSION_TTL_SECONDS,
		}
	end

	local function requestLoggerLootLog(lootNid, looter, rollType, rollValue, source, raidId)
		return LoggerActions:RecordLoot({
			lootNid = lootNid,
			looter = looter,
			rollType = rollType,
			rollValue = rollValue,
			source = source,
			raidId = raidId,
		})
	end

	local function ensureTradeLootContext(itemLink, playerName, rollType, rollValue, awardedCount, source)
		local session = Rolls:GetRollSession()
		local sessionLootNid = session and tonumber(session.lootNid) or 0
		local currentLootNid = tonumber(lootState.currentRollItem) or 0
		local lootNid = 0

		if lootState.fromInventory then
			local holderName = lootState.trader or Database.GetPlayerName() or playerName
			local preferredLootNid = sessionLootNid > 0 and sessionLootNid or currentLootNid
			local raidNum = Database.GetCurrentRaid()
			if itemLink and raidNum and Raid.ResolveHeldLootNid then
				lootNid = tonumber(Raid:ResolveHeldLootNid(itemLink, preferredLootNid, holderName, raidNum)) or 0
			end
		else
			lootNid = sessionLootNid > 0 and sessionLootNid or currentLootNid
		end

		if
			lootNid <= 0
			and not lootState.fromInventory
			and session
			and session.id
			and Raid.GetLootNidByRollSessionId
		then
			lootNid = Raid:GetLootNidByRollSessionId(session.id, Database.GetCurrentRaid(), playerName)
		end

		local createdTradeOnly = false
		if lootNid <= 0 and Loot and Loot.LogTradeOnlyLoot then
			local created = Loot:LogTradeOnlyLoot(
				itemLink,
				playerName,
				rollType,
				rollValue,
				awardedCount,
				source,
				Database.GetCurrentRaid(),
				session and session.bossNid or nil,
				session and session.id or nil
			) or 0
			created = tonumber(created) or 0
			if created > 0 then
				lootNid = created
				createdTradeOnly = true
			end
		end

		if lootNid > 0 then
			lootState.currentRollItem = lootNid
			if session then
				session.lootNid = lootNid
				Rolls:SyncSessionState(session)
			end
		end

		return lootNid, createdTradeOnly
	end

	local function stopCountdown()
		Rolls:StopCountdown()
	end

	local function refreshRollDisplay()
		Rolls:GetDisplayModel()
		module:RequestRefresh()
	end

	local function resetRecordedRolls()
		Rolls:ClearRolls()
		Rolls:SetRollRecordingEnabled(false)
	end

	local function clearLootAndResetRecordedRolls()
		Loot:ClearLoot()
		resetRecordedRolls()
	end

	local function startCountdown()
		local duration = tonumber(GetOption("Rolls", "countdownDuration")) or 0
		if duration <= 0 then
			return false
		end
		local blockAfterCountdown = GetOption("Rolls", "countdownRollsBlock") == true

		stopCountdown()
		local started = Rolls:StartCountdown(duration, nil, function()
			-- At zero: either block late rolls or keep intake open and tag late responses as OOT.
			if blockAfterCountdown then
				Rolls:SetRollRecordingEnabled(false)
			end
			refreshRollDisplay()
		end)
		if not started then
			return false
		end

		Rolls:SetRollRecordingEnabled(true)
		LootDistribution.PublishRollStart(Loot.GetItemLink(), lootState.currentRollType, duration)
		return true
	end

	local function finalizeRollSession()
		Rolls:FinalizeRollSession()
		module:RequestRefresh()
	end

	local function requestCoalescedUiRefresh(reason)
		if module._refreshHandle then
			if reason ~= nil then
				module._refreshReason = reason
			end
			return
		end

		module._refreshReason = reason
		module._refreshHandle = module:ScheduleTimer(function()
			local refreshReason = module._refreshReason
			module._refreshHandle = nil
			module._refreshReason = nil
			module:RequestRefresh(refreshReason)
		end, 0)

		if not module._refreshHandle then
			local refreshReason = module._refreshReason
			module._refreshReason = nil
			module:RequestRefresh(refreshReason)
		end
	end

	local function updateEnabledState(cache, key, frame, enabled)
		enabled = enabled and true or false
		if frame and cache[key] ~= enabled then
			Primitives.SetEnabled(frame, enabled)
			cache[key] = enabled
		end
	end

	local function updateGlowState(cache, key, frame, enabled, r, g, b, style)
		local token = enabled and ("1|" .. tostring(style or "")) or "0"
		if frame and cache[key] ~= token then
			Primitives.SetButtonGlow(frame, enabled, r, g, b, style)
			cache[key] = token
		end
	end

	local function updateTextState(cache, key, frame, text)
		if frame and cache[key] ~= text then
			frame:SetText(text)
			cache[key] = text
		end
	end

	local function updateTooltipState(cache, key, frame, title, text)
		if not frame then
			return
		end
		local token = tostring(title or "") .. "\031" .. tostring(text or "")
		if cache[key] ~= token then
			BindTooltip(frame, text, nil, title)
			cache[key] = token
		end
	end

	local function updateItemButtonState(cache, itemBtn, enabled)
		enabled = enabled and true or false
		if itemBtn and cache.itemBtn ~= enabled then
			Primitives.SetEnabled(itemBtn, enabled)
			local texture = itemBtn:GetNormalTexture()
			if texture and texture.SetDesaturated then
				texture:SetDesaturated(not enabled)
			end
			cache.itemBtn = enabled
		end
	end

	local function updateMasterButtonsIfChanged(state)
		local buttons = module._lastUIState.buttons
		local texts = module._lastUIState.texts
		local tooltips = module._lastUIState.tooltips
		local glows = module._lastUIState.glows
		local refs = acquireMasterRefs()
		if not refs then
			return
		end

		updateTextState(texts, "countdown", refs.CountdownBtn, state.countdownText)
		updateTextState(texts, "award", refs.AwardBtn, state.awardText)
		updateTextState(texts, "selectItem", refs.SelectItemBtn, state.selectItemText)
		updateTextState(texts, "spamLoot", refs.SpamLootBtn, state.spamLootText)
		updateTextState(texts, "status", refs.Status, state.statusText)

		updateEnabledState(buttons, "selectItem", refs.SelectItemBtn, state.canSelectItem)
		updateEnabledState(buttons, "spamLoot", refs.SpamLootBtn, state.canSpamLoot)
		updateEnabledState(buttons, "ms", refs.MSBtn, state.canStartRolls)
		updateEnabledState(buttons, "os", refs.OSBtn, state.canStartRolls)
		updateEnabledState(buttons, "sr", refs.SRBtn, state.canStartSR)
		updateEnabledState(buttons, "free", refs.FreeBtn, state.canStartRolls)
		updateEnabledState(buttons, "countdown", refs.CountdownBtn, state.canCountdown)
		updateEnabledState(buttons, "hold", refs.HoldBtn, state.canHold)
		updateEnabledState(buttons, "bank", refs.BankBtn, state.canBank)
		updateEnabledState(buttons, "disenchant", refs.DisenchantBtn, state.canDisenchant)
		updateEnabledState(buttons, "award", refs.AwardBtn, state.canAward)
		updateTextState(texts, "reserveList", refs.ReserveListBtn, state.reserveListText)
		updateEnabledState(buttons, "reserveList", refs.ReserveListBtn, state.canReserveList)
		updateEnabledState(buttons, "roll", refs.RollBtn, state.canRoll)
		updateEnabledState(buttons, "clear", refs.ClearBtn, state.canClear)
		updateItemButtonState(buttons, refs.ItemBtn, state.canChangeItem)
		updateGlowState(glows, "sr", refs.SRBtn, state.glowSR, 0.20, 0.60, 1.00, "buttonOverlay")
		updateGlowState(
			glows,
			"holdSuggestion",
			refs.HoldBtn,
			state.glowHoldSuggestion,
			0.85,
			0.85,
			0.85,
			"buttonOverlay"
		)
		updateGlowState(
			glows,
			"bankSuggestion",
			refs.BankBtn,
			state.glowBankSuggestion,
			1.00,
			0.65,
			0.20,
			"buttonOverlay"
		)
		updateGlowState(
			glows,
			"disenchantSuggestion",
			refs.DisenchantBtn,
			state.glowDisenchantSuggestion,
			0.55,
			0.75,
			1.00,
			"buttonOverlay"
		)

		updateTooltipState(tooltips, "config", refs.ConfigBtn, L.BtnConfigure, state.configTooltip)
		updateTooltipState(tooltips, "selectItem", refs.SelectItemBtn, state.selectItemText, state.selectItemTooltip)
		updateTooltipState(tooltips, "spamLoot", refs.SpamLootBtn, state.spamLootText, state.spamLootTooltip)
		updateTooltipState(tooltips, "ms", refs.MSBtn, L.BtnMS, state.msTooltip)
		updateTooltipState(tooltips, "os", refs.OSBtn, L.BtnOS, state.osTooltip)
		updateTooltipState(tooltips, "sr", refs.SRBtn, L.BtnSR, state.srTooltip)
		updateTooltipState(tooltips, "free", refs.FreeBtn, L.BtnFree, state.freeTooltip)
		updateTooltipState(tooltips, "countdown", refs.CountdownBtn, state.countdownText, state.countdownTooltip)
		updateTooltipState(tooltips, "award", refs.AwardBtn, state.awardText, state.awardTooltip)
		updateTooltipState(tooltips, "roll", refs.RollBtn, L.BtnRoll, state.rollTooltip)
		updateTooltipState(tooltips, "clear", refs.ClearBtn, L.BtnClear, state.clearTooltip)
		updateTooltipState(tooltips, "hold", refs.HoldBtn, L.BtnHold, state.holdTooltip)
		updateTooltipState(tooltips, "bank", refs.BankBtn, L.BtnBank, state.bankTooltip)
		updateTooltipState(tooltips, "disenchant", refs.DisenchantBtn, L.BtnDisenchant, state.disenchantTooltip)
		updateTooltipState(
			tooltips,
			"reserveList",
			refs.ReserveListBtn,
			state.reserveListText,
			state.reserveListTooltip
		)
		updateTooltipState(tooltips, "lootCounter", refs.LootCounterBtn, L.BtnLootCounter, state.lootCounterTooltip)
	end

	function refreshDropDowns(force)
		if not module._dropDownsInitialized then
			return
		end
		if not force and not module._dropDownDirty then
			return
		end
		updateAssignmentDropDown(module._dropDownFrameHolder)
		updateAssignmentDropDown(module._dropDownFrameBanker)
		updateAssignmentDropDown(module._dropDownFrameDisenchanter)
		module._dropDownDirty = false
		module._dirtyFlags.dropdowns = false
	end

	local function refreshCandidateUiState()
		module._cachedRosterVersion = nil
		module._dropDownDirty = true
		module._dirtyFlags.dropdowns = true
		Private.PrepareDropDowns()
	end

	-- ============================================================================
	-- Award / candidate helpers
	-- ============================================================================
	local function buildAssignMessages(itemLink, playerName, rollType)
		return MasterService.Messages.BuildAssignMessages({
			itemLink = itemLink,
			lootWhispers = GetOption("Loot", "lootWhispers") == true,
			options = {
				announceOnBank = GetOption("Master", "announceOnBank") == true,
				announceOnDisenchant = GetOption("Master", "announceOnDisenchant") == true,
				announceOnHold = GetOption("Master", "announceOnHold") == true,
				announceOnWin = GetOption("Master", "announceOnWin") == true,
			},
			playerName = playerName,
			rollType = rollType,
		})
	end

	-- ============================================================================
	-- Multi-award helpers
	-- ============================================================================
	local function validateInventoryTradeUiSelection(target)
		local selCount = rollSelectionController:GetSelectedCount()
		local rollModel
		local picked

		if selCount > 0 then
			rollModel = buildRollSelectionModel(true)
			picked = rollSelectionController:GetSelectedWinnersOrdered(rollModel and rollModel.rows or nil)
		end

		local plan = LootAwardPlanner.ValidateInventoryTradeSelection({
			target = target,
			selectedCount = selCount,
			pickedCount = picked and #picked or 0,
		})
		return plan and plan.ok == true, plan and plan.errType, plan and plan.wantedCount, plan and plan.pickedCount
	end

	local function computeTargetAndAvailability()
		local plan = LootAwardPlanner.BuildAwardTargetPlan({
			selectedItemCount = lootState.selectedItemCount,
			availableItemCount = Loot:GetCurrentItemCount(),
			rollsCount = lootState.rollsCount,
		})
		return plan.target, plan.available
	end

	-- ============================================================================
	-- Award request / trade-state helpers
	-- ============================================================================
	local function handleAwardRequest()
		local model = buildRollSelectionModel(true) or {}
		local resolution = model.resolution or {}
		local requiredWinnerCount = tonumber(model.requiredWinnerCount) or 1
		local winnerName = model.winner or lootState.winner
		local rerollNames
		local rerollStarted

		if not RaidApi.EnsureMasterOnlyAccess(Raid) then
			return false
		end
		if isCountdownRunning() then
			addon:warn(Diag.W.LogMLCountdownActive)
			return
		end
		if lootState.multiAward and lootState.multiAward.active and not lootState.fromInventory then
			addon:warn(Diag.W.ErrMLMultiAwardInProgress)
			return
		end
		if lootState.lootCount <= 0 or lootState.rollsCount <= 0 then
			if addon.hasDebug then
				addon:debug(Diag.D.LogMLAwardBlocked:format(lootState.lootCount or 0, lootState.rollsCount or 0))
			end
			return
		end
		if Rolls:ShouldUseTieReroll(model) then
			rerollStarted, rerollNames = BeginTieReroll(Rolls, resolution.tiedNames)
			if not rerollStarted then
				addon:warn(L.ErrMLWinnerTieUnresolved)
				return false
			end
			module._announced = false
			rollSelectionController:ResetSelection(RollSelectionService.Mode.AUTO)
			Announce(Chat, L.ChatTieReroll:format(tconcat(rerollNames or {}, ", "), Loot.GetItemLink() or ""))
			LootDistribution.PublishTieStart(Loot.GetItemLink(), rerollNames)
			LootDistribution.PublishRollStart(Loot.GetItemLink(), lootState.currentRollType)
			if addon.hasDebug then
				addon:debug(
					Diag.I.LogMLTieReroll:format(tostring(Loot.GetItemLink() or ""), tconcat(rerollNames or {}, ","))
				)
			end
			module:RequestRefresh()
			return true
		end
		if resolution.requiresManualResolution then
			if model.pickMode then
				if (tonumber(model.msCount) or 0) < requiredWinnerCount then
					addon:warn(L.ErrMLWinnerTieUnresolved)
					return
				end
			elseif not winnerName then
				addon:warn(L.ErrMLWinnerTieUnresolved)
				return
			end
		end
		if not winnerName then
			addon:warn(L.ErrNoWinnerSelected)
			return
		end

		lootState.winner = winnerName
		stopCountdown()
		local itemLink = Loot.GetItemLink()
		if addon.hasDebug then
			addon:debug(
				Diag.D.LogMLAwardRequested:format(
					tostring(winnerName),
					tonumber(lootState.currentRollType) or -1,
					Rolls:GetHighestRoll(winnerName) or 0,
					tostring(itemLink)
				)
			)
		end

		if lootState.fromInventory == true then
			local targetCount = tonumber(lootState.selectedItemCount) or 1
			if targetCount > 1 then
				local okSelection, errType, wantedCount, pickedCount = validateInventoryTradeUiSelection(targetCount)
				if not okSelection then
					if errType == "not_enough_selection" then
						addon:warn(Diag.W.ErrMLMultiSelectNotEnough:format(wantedCount or 0, pickedCount or 0))
					else
						addon:warn(L.ErrNoWinnerSelected)
					end
					Private.ResetItemCount()
					return false
				end
			end
			local result = tradeExecutionController:TradeItem(
				itemLink,
				winnerName,
				lootState.currentRollType,
				Rolls:GetHighestRoll(winnerName)
			)
			resetItemCountAndRefresh()
			return result
		end

		local target, available = computeTargetAndAvailability()
		if available > 1 then
			return awardController:TryMultipleCopies(itemLink, target, available)
		end

		return awardController:TrySingleCopy(itemLink, winnerName)
	end

	module._awardFlow.handleRequest = handleAwardRequest

	local function resetTradeState()
		lootState.trader = nil
		lootState.tradeWinner = nil
		lootState.winner = nil
		lootState.tradeItemId = nil
		lootState.tradeItemLink = nil
		itemInfo.tradeStartCount = nil
		itemInfo.tradeStartItemLink = nil
		itemInfo.tradeStartBag = nil
		itemInfo.tradeStartSlot = nil
		module._screenshotWarn = false
	end

	local function handleTradeClosedOrCancelled()
		resetTradeState()
		module:RequestRefresh()
	end

	local manualTradeCloseSettleHandle

	local function cancelManualTradeCloseSettle()
		if manualTradeCloseSettleHandle then
			module:CancelTimer(manualTradeCloseSettleHandle)
			manualTradeCloseSettleHandle = nil
		end
	end

	local function completeManualTradeCloseSettle()
		manualTradeCloseSettleHandle = nil
		MasterService.Trade.SettleClose()
		tradeExecutionController:SettleAcceptedTrade()
		Widgets.TradeMenu.HideDropdowns()
		module:RequestRefresh()
	end

	local function scheduleManualTradeCloseSettle()
		cancelManualTradeCloseSettle()
		if not MasterService.Trade.HasClosePending() and not tradeExecutionController:HasPendingAcceptedTrade() then
			MasterService.Trade.Reset(true, true)
			Widgets.TradeMenu.HideDropdowns()
			return false
		end

		Widgets.TradeMenu.HideDropdowns()
		manualTradeCloseSettleHandle = module:ScheduleTimer(completeManualTradeCloseSettle, 0)
		if not manualTradeCloseSettleHandle then
			completeManualTradeCloseSettle()
		end
		return true
	end

	local function failManualTrade(message)
		local failed = MasterService.Trade.CancelClose(message)
		if failed then
			cancelManualTradeCloseSettle()
			Widgets.TradeMenu.HideDropdowns()
			return true
		end
		return false
	end

	registerAwardedItem = function(count)
		local targetCount = tonumber(lootState.selectedItemCount) or 1
		if targetCount < 1 then
			targetCount = 1
		end
		local increment = tonumber(count) or 1
		if increment < 1 then
			increment = 1
		end
		lootState.itemTraded = (lootState.itemTraded or 0) + increment
		if lootState.itemTraded >= targetCount then
			lootState.itemTraded = 0
			resetRecordedRolls()
			return true
		end
		return false
	end

	awardController = AwardSequenceService.CreateController({
		awardPlanner = LootAwardPlanner,
		inventory = LootInventory,
		lootState = lootState,
		rollSelection = rollSelectionController,
		scheduleTimer = function(callback, delay)
			return module:ScheduleTimer(callback, delay)
		end,
		cancelTimer = function(handle)
			return module:CancelTimer(handle)
		end,
		announce = function(message, channel)
			return Announce(Chat, message, channel)
		end,
		debug = addon.hasDebug and function(message)
			return addon:debug(message)
		end or nil,
		warn = function(message)
			return addon:warn(message)
		end,
		registerAwardedItem = registerAwardedItem,
		refresh = function()
			return module:RequestRefresh()
		end,
		awardExecutor = {
			Assign = function(_, itemLink, playerName, rollType, rollValue)
				local effect = _.effect
				_.effect = nil
				return assignItem(itemLink, playerName, rollType, rollValue, effect)
			end,
		},
		itemCount = {
			Set = function(_, count, focus)
				return setItemCountValue(count, focus)
			end,
			Reset = function(_, focus)
				return Private.ResetItemCount(focus)
			end,
		},
		getAnnounceOnWin = function()
			return GetOption("Master", "announceOnWin") == true
		end,
		multiAwardTimeoutSeconds = ML_MULTI_AWARD_TIMEOUT_SECONDS,
		multiAwardDelaySeconds = C.ML_MULTI_AWARD_DELAY,
		createAttempt = createAwardAttempt,
		getRollSessionId = function()
			local session = lootState.rollSession
			return session and session.id or nil
		end,
		getItemKey = function(itemLink)
			return Item.GetItemStringFromLink(itemLink) or itemLink
		end,
		getRaidNid = function()
			return Database.GetCurrentRaid()
		end,
	})
	tradeExecutionController = TradeExecutionService.CreateController({
		lootBans = Raid.LootBans,
		trade = MasterService.Trade,
		inventory = LootInventory,
		awardPlanner = LootAwardPlanner,
		rollSelection = rollSelectionController,
		raid = Raid,
		loot = Loot,
		distribution = LootDistribution,
		rolls = Rolls,
		comms = Comms,
		database = Database,
		item = Item,
		lootState = lootState,
		itemInfo = itemInfo,
		wow = TradeExecutionWow,
		getOption = GetOption,
		buildRollSelectionModel = buildRollSelectionModel,
		buildLootRollSessionOptions = buildLootRollSessionOptions,
		resetTradeState = resetTradeState,
		hideTradeDropdowns = function()
			return Widgets.TradeMenu.HideDropdowns()
		end,
		clearLootAndResetRecordedRolls = clearLootAndResetRecordedRolls,
		ensureTradeLootContext = ensureTradeLootContext,
		requestLoggerLootLog = requestLoggerLootLog,
		registerAwardedItem = registerAwardedItem,
		requestRefresh = function()
			return module:RequestRefresh()
		end,
		announce = function(message, channel)
			return Announce(Chat, message, channel)
		end,
		isAnnounced = function()
			return module._announced == true
		end,
		setAnnounced = function(value)
			module._announced = value == true
		end,
		isScreenshotWarn = function()
			return module._screenshotWarn == true
		end,
		setScreenshotWarn = function(value)
			module._screenshotWarn = value == true
		end,
		debug = addon.hasDebug and function(message)
			return addon:debug(message)
		end or nil,
		warn = function(message)
			return addon:warn(message)
		end,
		error = function(message)
			return addon:error(message)
		end,
		createAttempt = createAwardAttempt,
		getItemKey = function(itemLink)
			return Item.GetItemStringFromLink(itemLink) or itemLink
		end,
	})
	itemSelectionController = ItemSelectionWidget.CreateController({
		state = module._itemSelectionState,
		createFrame = CreateFrame,
		getFrame = getFrame,
		getFrameName = getFrameName,
		getNamedParts = Frames.GetNamedParts,
		setScriptSafely = SetScriptSafely,
		getSelectItemButton = function()
			return getNamedPart("SelectItemBtn")
		end,
		clearItemCountInput = function()
			local itemCountBox = getNamedPart("ItemCount")
			if itemCountBox then
				UI.EditBoxes.Reset(itemCountBox, true)
			end
		end,
		getLootItem = function(index)
			return Loot.GetItem(index)
		end,
		getLootItemName = function(index)
			return Loot.GetItemName(index)
		end,
		getLootItemTexture = function(index)
			return Loot.GetItemTexture(index)
		end,
		addLootItem = function(itemLink, count)
			return Loot:AddItem(itemLink, count)
		end,
		prepareLootItem = function()
			return Loot:PrepareItem()
		end,
		inventory = LootInventory,
		lootState = lootState,
		itemInfo = itemInfo,
		isCountdownRunning = isCountdownRunning,
		onSelectLootItem = function(index)
			module._announced = false
			Loot:SelectItem(index)
			resetItemCountAndRefresh()
		end,
		onInventoryItemApplied = function(focus)
			return resetItemCountAndRefresh(focus)
		end,
		setAnnounced = function(value)
			module._announced = value == true
		end,
		L = L,
		wow = {
			ClearCursor = assert(_G.ClearCursor, "Master item selection clear-cursor API is not initialized"),
			CursorHasItem = assert(_G.CursorHasItem, "Master item selection cursor-item API is not initialized"),
			GetCursorInfo = assert(_G.GetCursorInfo, "Master item selection cursor-info API is not initialized"),
			GetContainerItemLink = assert(
				_G.GetContainerItemLink,
				"Master item selection container-item-link API is not initialized"
			),
		},
		debug = addon.hasDebug and function(message)
			return addon:debug(message)
		end or nil,
		warn = function(message)
			return addon:warn(message)
		end,
	})

	clearMultiAwardState = function(resetItemCount)
		return awardController:Clear(resetItemCount)
	end

	local function setCurrentItemView(itemName, itemLink, itemTexture, itemColor)
		if not (itemName and itemLink and itemTexture and itemColor) then
			return false
		end

		local frame = getFrame()
		if not frame then
			return false
		end
		uiState.FrameName = uiState.FrameName or (frame.GetName and frame:GetName()) or uiState.FrameName
		local frameName = getFrameName() or frame:GetName()
		if not frameName or frameName ~= frame:GetName() then
			return false
		end

		local currentItemLink = getNamedPart("Name")
		local currentItemBtn = getNamedPart("ItemBtn")
		if not (currentItemLink and currentItemBtn) then
			return false
		end

		currentItemLink:SetText(addon.WrapTextInColorCode(itemName, Colors.NormalizeHexColor(itemColor)))
		currentItemBtn:SetNormalTexture(itemTexture)

		if GetOption("UI", "showTooltips") then
			currentItemBtn.tooltip_item = itemLink
			BindTooltip(currentItemBtn, nil, "ANCHOR_CURSOR")
		end
		return true
	end

	local function refreshMasterFrame()
		local perfStart = addon.hasPerf and addon:_PerfStart() or nil
		uiState.Refresh()
		if perfStart then
			addon:_PerfFinish(
				"Master.RefreshUI",
				perfStart,
				"items=" .. tostring(lootState.lootCount or 0) .. " rolls=" .. tostring(lootState.rollsCount or 0)
			)
		end
	end

	Private.RefreshFrame = refreshMasterFrame

	Private.ClearCurrentItemView = function(focusItemCount)
		local frame = getFrame()
		if not frame then
			return false
		end
		uiState.FrameName = uiState.FrameName or (frame.GetName and frame:GetName()) or uiState.FrameName
		local frameName = getFrameName() or frame:GetName()
		if not frameName or frameName ~= frame:GetName() then
			return false
		end

		local currentItemLink = getNamedPart("Name")
		local currentItemBtn = getNamedPart("ItemBtn")
		if not (currentItemLink and currentItemBtn) then
			return false
		end

		currentItemLink:SetText(L.StrNoItemSelected)
		currentItemBtn:SetNormalTexture("Interface\\PaperDoll\\UI-Backpack-EmptySlot")
		currentItemBtn.tooltip_item = nil
		HideTooltip()

		local mf = module.frame
		if mf and frameName == mf:GetName() then
			local itemCountBox = getNamedPart("ItemCount")
			if itemCountBox then
				UI.EditBoxes.Reset(itemCountBox, focusItemCount and true or false)
			end
		end
		return true
	end

	Private.ResetItemCount = function(focus)
		-- During multi-award from loot window we keep ItemCount stable (target N) to avoid
		-- mid-sequence clamping to the remaining copies.
		if lootState.multiAward and lootState.multiAward.active and not lootState.fromInventory then
			return
		end
		setItemCountValue(Loot:GetCurrentItemCount() or 1, focus)
	end

	local function loadMasterFrame(frame)
		uiState.FrameName = BindModuleFrame(module, frame, {
			enableDrag = true,
			hookOnHide = function()
				itemSelectionController:HideFrame()
			end,
		}) or uiState.FrameName
		if not uiState.FrameName then
			return
		end
		uiState.Loaded = true
		Widgets.LootCounter:AttachToMaster(frame)
		initItemButtonScripts()
		if module._rollListController and module._rollListController.OnLoad and not frame._RMARollListBound then
			module._rollListController:OnLoad(frame)
			frame._RMARollListBound = true
		end
	end

	Private.LoadFrame = loadMasterFrame

	local function BindHandlers(_, frame, refs)
		bindMainControlScripts(frame, refs)
	end

	local function Localize()
		local ok = pcall(uiState.Localize)
		if not ok then
			addon:error(Diag.E.LogMasterUILocalizationFailed)
		end
	end

	local function OnLoadFrame(frame)
		loadMasterFrame(frame)
		return uiState.FrameName
	end

	UI.Scaffold.DefineModule({
		module = module,
		getFrame = getFrame,
		acquireRefs = uiState.AcquireRefs,
		bind = BindHandlers,
		localize = Localize,
		onLoad = OnLoadFrame,
		refresh = function()
			refreshMasterFrame()
		end,
	})

	-- ============================================================================
	-- Button handlers
	-- ============================================================================
	-- Button: Select/Remove Item
	Private.BtnSelectItem = function(btn, _button)
		if btn == nil or lootState.lootCount <= 0 then
			return
		end
		if isCountdownRunning() then
			return
		end
		clearMultiAwardState(false)
		if lootState.fromInventory == true then
			clearLootAndResetRecordedRolls()
			module._announced = false
			lootState.fromInventory = false
			itemInfo.count = 0
			itemInfo.isStack = nil
			itemInfo.bagID = nil
			itemInfo.slotID = nil
			itemSelectionController:Reset()
			if lootState.opened == true then
				Loot:FetchLoot()
			end
		else
			itemSelectionController:UpdateFrame()
			itemSelectionController:ToggleFrame()
		end
		module:RequestRefresh()
	end

	-- Button: Spam Loot Links or Do Ready Check
	Private.BtnSpamLoot = function(btn, _button)
		if btn == nil or lootState.lootCount <= 0 then
			return
		end
		if lootState.fromInventory == true then
			local canReadyCheck = RaidApi.CanUseCapability(Raid, "ready_check")
			if not canReadyCheck then
				addon:warn(L.WarnReadyCheckNotAllowed)
				return
			end
			Announce(Chat, L.ChatReadyCheck)
			DoReadyCheck()
		else
			Private.AnnounceLootLinks(false)
		end
	end

	Private.GetLootSpamSourceName = function()
		local name = UnitName("target")
		if type(name) ~= "string" or name == "" then
			return nil
		end
		if name == _G.UNKNOWNOBJECT or name == _G.UNKNOWNBEING or name == _G.UKNOWNBEING then
			return nil
		end
		return name
	end

	Private.AnnounceLootLinks = function(includeSoftRes)
		if lootState.fromInventory == true or lootState.lootCount <= 0 then
			return false
		end

		local reserves = Services.Reserves
		local hasReserveData = includeSoftRes == true and reserves and reserves.HasData and reserves:HasData() or false
		local items = {}
		for i = 1, lootState.lootCount do
			local itemLink = Loot.GetItemLink(i)
			if itemLink then
				local item = Loot.GetItem(i)
				local count = item and item.count or 1
				local spamItem = {
					count = count,
					index = i,
					itemLink = itemLink,
				}

				if hasReserveData and reserves.FormatReservedPlayersLine then
					local itemId = Item.GetItemIdFromLink(itemLink)
					local srList = itemId and reserves:FormatReservedPlayersLine(itemId, false, false, false, true)
						or ""
					if srList and srList ~= "" then
						spamItem.reservedPlayers = srList
					end
				end
				items[#items + 1] = spamItem
			end
		end
		local plan = MasterService.Messages.BuildLootSpamPlan({
			items = items,
			sourceName = Private.GetLootSpamSourceName(),
		})
		Announce(Chat, plan.header, "RAID")
		for i = 1, #(plan.lootLines or {}) do
			Announce(Chat, plan.lootLines[i], "RAID")
		end
		if plan.reservedHeader then
			Announce(Chat, plan.reservedHeader, "RAID")
			for i = 1, #(plan.reservedLines or {}) do
				Announce(Chat, plan.reservedLines[i], "RAID")
			end
		end
		return true
	end

	-- Button: Reserve List (contextual)
	Private.BtnReserveList = function(_btn, _button)
		local reserves = Services.Reserves
		if reserves and reserves.HasData and reserves:HasData() then
			Widgets.ReservesUI:Toggle()
		else
			Widgets.ReservesUI:ToggleImport()
		end
	end

	-- Button: Loot Counter
	Private.BtnLootCounter = function(_btn, _button)
		Widgets.LootCounter:Toggle()
	end

	-- ============================================================================
	-- Roll announcement / assignment helpers
	-- ============================================================================
	-- Generic function to announce a roll for the current item and reopen intake.
	-- Countdown remains a separate explicit action on the Countdown button.
	local function announceRoll(rollType, chatMsg)
		if isCountdownRunning() then
			return false
		end

		if lootState.lootCount >= 1 then
			module._announced = false
			lootState.currentRollType = rollType
			Rolls:ClearRolls()
			Rolls:SetRollRecordingEnabled(true)
			lootState.itemTraded = 0

			local itemLink = Loot.GetItemLink()
			local itemID = Item.GetItemIdFromLink(itemLink)
			Rolls:EnsureLootRollSession(
				itemLink,
				rollType,
				lootState.fromInventory and "inventory" or "lootWindow",
				buildLootRollSessionOptions()
			)
			local srList = nil
			if rollType == rollTypes.RESERVED then
				local reserves = Services.Reserves
				srList = reserves
						and reserves.FormatReservedPlayersLine
						and reserves:FormatReservedPlayersLine(itemID, false, false, false, true)
					or ""
			end

			local plan = MasterService.Messages.BuildRollAnnouncementPlan({
				chatKey = chatMsg,
				itemLink = itemLink,
				rollType = rollType,
				selectedItemCount = lootState.selectedItemCount,
				sortAscending = GetOption("Master", "sortAscending") == true,
				srList = srList,
			})
			local message = plan and plan.message or nil

			Announce(Chat, message)
			LootDistribution.PublishRollStart(itemLink, rollType)
			local itemCountBox = getNamedPart("ItemCount")
			if itemCountBox then
				itemCountBox:ClearFocus()
			end
			local session = Rolls:GetRollSession()
			if session and tonumber(session.lootNid) then
				lootState.currentRollItem = session.lootNid
			else
				lootState.currentRollItem = 0
			end
			module:RequestRefresh()
		end
	end

	local function assignToTarget(rollType, targetKey)
		if lootState.lootCount <= 0 or not lootState[targetKey] then
			return
		end
		stopCountdown()
		local itemLink = Loot.GetItemLink()
		if not itemLink then
			return
		end
		lootState.currentRollType = rollType
		local target = lootState[targetKey]
		local ok
		if lootState.fromInventory then
			ok = tradeExecutionController:TradeItem(itemLink, target, rollType, 0)
		else
			ok = assignItem(itemLink, target, rollType, 0)
		end
		if ok and not lootState.fromInventory then
			module._announced = false
			Rolls:ClearRolls()
		end
		module:RequestRefresh()
		return ok
	end

	Private.BtnMS = function(_btn, _button)
		return announceRoll(rollTypes.MAINSPEC, module._rollAnnouncementKeys[rollTypes.MAINSPEC])
	end

	Private.BtnOS = function(_btn, _button)
		return announceRoll(rollTypes.OFFSPEC, module._rollAnnouncementKeys[rollTypes.OFFSPEC])
	end

	Private.BtnSR = function(_btn, _button)
		return announceRoll(rollTypes.RESERVED, module._rollAnnouncementKeys[rollTypes.RESERVED])
	end

	Private.BtnFree = function(_btn, _button)
		return announceRoll(rollTypes.FREE, module._rollAnnouncementKeys[rollTypes.FREE])
	end

	-- Button: left click starts/stops countdown, right click finalizes rolls immediately.
	Private.BtnCountdown = function(_btn, button)
		if isCountdownRunning() then
			finalizeRollSession()
		elseif not lootState.rollStarted then
			return
		elseif button == "RightButton" then
			finalizeRollSession()
		else
			if not startCountdown() then
				finalizeRollSession()
				return
			end
			module._announced = false
			module:RequestRefresh()
		end
	end

	-- Button: Clear Rolls
	Private.BtnClear = function(_btn, _button)
		module._announced = false
		Rolls:ClearRolls()
		module:RequestRefresh()
	end

	-- Button: Award/Trade
	Private.BtnAward = function(_btn, _button)
		return module._awardFlow.handleRequest()
	end

	-- Button: Hold item
	Private.BtnHold = function(_btn, _button)
		return assignToTarget(rollTypes.HOLD, "holder")
	end

	-- Button: Bank item
	Private.BtnBank = function(_btn, _button)
		return assignToTarget(rollTypes.BANK, "banker")
	end

	-- Button: Disenchant item
	Private.BtnDisenchant = function(_btn, _button)
		return assignToTarget(rollTypes.DISENCHANT, "disenchanter")
	end

	-- Localizes UI frame elements.
	function uiState.Localize()
		if uiState.Localized then
			return
		end
		local frameName = getFrameName()
		if not frameName then
			return
		end

		local function setPartText(suffix, text)
			local part = getNamedPart(suffix)
			if part and part.SetText then
				part:SetText(text)
			end
			return part
		end

		setPartText("ConfigBtn", L.BtnConfigure)
		setPartText("SelectItemBtn", L.BtnSelectItem)
		setPartText("SpamLootBtn", L.BtnSpamLoot)
		setPartText("MSBtn", L.BtnMS)
		setPartText("OSBtn", L.BtnOS)
		setPartText("SRBtn", L.BtnSR)
		setPartText("FreeBtn", L.BtnFree)
		setPartText("CountdownBtn", L.BtnCountdown)
		setPartText("AwardBtn", L.BtnAward)
		setPartText("RollBtn", L.BtnRoll)
		setPartText("ClearBtn", L.BtnClear)
		setPartText("HoldBtn", L.BtnHold)
		setPartText("BankBtn", L.BtnBank)
		setPartText("DisenchantBtn", L.BtnDisenchant)
		setPartText("Name", L.StrNoItemSelected)

		local status = getNamedPart("Status")
		if status then
			if status.SetWordWrap then
				status:SetWordWrap(true)
			end
			if status.SetNonSpaceWrap then
				status:SetNonSpaceWrap(false)
			end
			if status.SetText then
				status:SetText(L.StrMasterStatusIdle)
			end
		end

		setPartText("RollsHeaderPlayer", L.StrPlayer)
		setPartText("RollsHeaderInfo", L.StrInfo)
		setPartText("RollsHeaderCounter", L.StrCounter)
		setPartText("RollsHeaderRoll", L.StrRolls)
		setPartText("ReserveListBtn", L.BtnInsertList)
		setPartText("LootCounterBtn", L.BtnLootCounter)
		setPartText("LootBansBtn", L.BtnLootBans)
		SetFrameTitle(frameName, L.StrLootMaster)

		local function requestItemCountRefresh()
			module._announced = false
			module._dirtyFlags.itemCount = true
			module._dirtyFlags.buttons = true
			module:RequestRefresh()
		end

		UI.EditBoxes.BindHandlers(frameName, {
			{
				suffix = "ItemCount",
				onEnter = function(self)
					self:ClearFocus()
					requestItemCountRefresh()
				end,
				onFocusLost = function()
					requestItemCountRefresh()
				end,
			},
		}, requestItemCountRefresh)
		if next(module._dropDownData) == nil then
			for i = 1, 8 do
				module._dropDownData[i] = {}
			end
		end
		module._dropDownFrameHolder = getNamedPart("HoldDropDown")
		module._dropDownFrameBanker = getNamedPart("BankDropDown")
		module._dropDownFrameDisenchanter = getNamedPart("DisenchantDropDown")
		Private.PrepareDropDowns()
		Private.InitializeDropDowns()
		refreshDropDowns(true)
		uiState.Localized = true
	end

	-- ============================================================================
	-- Roll frame / rendering helpers
	-- ============================================================================
	local function updateItemCountFromBox(itemCountBox)
		-- While a multi-award sequence is running from the loot window, ItemCount represents
		-- the target number of copies to distribute (not the remaining copies). Ignore edits.
		if lootState.multiAward and lootState.multiAward.active and not lootState.fromInventory then
			return
		end
		if not itemCountBox or not itemCountBox:IsVisible() then
			return
		end
		local rawCount = itemCountBox:GetText()
		if rawCount ~= module._lastUIState.itemCountText then
			module._lastUIState.itemCountText = rawCount
			module._dirtyFlags.itemCount = true
		end
		if module._dirtyFlags.itemCount then
			local count = tonumber(rawCount)
			if count and count > 0 then
				lootState.selectedItemCount = count
				updateRollSessionExpectedWinners()
				if lootState.fromInventory and itemInfo.count and itemInfo.count ~= lootState.selectedItemCount then
					if itemInfo.count < lootState.selectedItemCount then
						lootState.selectedItemCount = itemInfo.count
						updateRollSessionExpectedWinners()
						itemCountBox:SetNumber(itemInfo.count)
						module._lastUIState.itemCountText = tostring(itemInfo.count)
					end
				end
			end
			module._dirtyFlags.itemCount = false
		end
	end

	local function updateRollStatusState()
		local rollType, record, canRoll, rolled = Rolls:GetRollStatus()
		local rollStatus = module._lastUIState.rollStatus
		if
			rollStatus.record ~= record
			or rollStatus.canRoll ~= canRoll
			or rollStatus.rolled ~= rolled
			or rollStatus.rollType ~= rollType
		then
			rollStatus.record = record
			rollStatus.canRoll = canRoll
			rollStatus.rolled = rolled
			rollStatus.rollType = rollType
			module._dirtyFlags.rolls = true
			module._dirtyFlags.buttons = true
		end
		return record, canRoll, rolled
	end

	local function flagButtonsOnChange(key, value)
		if module._lastUIState[key] ~= value then
			module._lastUIState[key] = value
			module._dirtyFlags.buttons = true
		end
	end

	local function updateRollListRefreshToken(rollModel)
		rollModel = rollModel or {}
		local token = tostring(rollModel.selectionAllowed == true)
			.. "|"
			.. tostring(rollModel.pickMode == true)
			.. "|"
			.. tostring(rollModel.highlightTarget or "")
			.. "|"
			.. tostring(tonumber(rollModel.msCount) or 0)
		if module._lastUIState.rollListRefreshToken ~= token then
			module._lastUIState.rollListRefreshToken = token
			module._dirtyFlags.rolls = true
		end
	end

	-- Refreshes the UI once (event-driven; coalesced via module:RequestRefresh()).
	function uiState.Refresh()
		if not uiState.Localized then
			uiState.Localize()
		end
		local currentFlowState = syncFlowState()
		local itemCountBox = getNamedPart("ItemCount")
		updateItemCountFromBox(itemCountBox)

		if module._dropDownDirty then
			module._dirtyFlags.dropdowns = true
		end

		local record, canRoll, rolled = updateRollStatusState()
		if module._lastUIState.rollsCount ~= lootState.rollsCount then
			module._lastUIState.rollsCount = lootState.rollsCount
			module._dirtyFlags.rolls = true
			module._dirtyFlags.buttons = true
		end

		invalidateRollSelectionModel()
		local rollModel = buildRollSelectionModel() or {}
		updateRollListRefreshToken(rollModel)

		local displayedWinner = getCurrentTradeWinner() or getCurrentMultiAwardWinner()
		if not (displayedWinner and displayedWinner ~= "") then
			displayedWinner = Rolls:GetResolvedWinner(rollModel)
		end
		if module._lastUIState.winner ~= displayedWinner then
			module._lastUIState.winner = displayedWinner
			module._dirtyFlags.winner = true
			module._dirtyFlags.buttons = true
		end

		flagButtonsOnChange("lootCount", lootState.lootCount)
		flagButtonsOnChange("fromInventory", lootState.fromInventory)
		flagButtonsOnChange("holder", lootState.holder)
		flagButtonsOnChange("banker", lootState.banker)
		flagButtonsOnChange("disenchanter", lootState.disenchanter)

		local reserves = Services.Reserves
		local hasReserves = reserves and reserves.HasData and reserves:HasData() or false
		flagButtonsOnChange("hasReserves", hasReserves)

		local hasItem = Loot.ItemExists() or false
		flagButtonsOnChange("hasItem", hasItem)

		local itemId
		if hasItem then
			itemId = Item.GetItemIdFromLink(Loot.GetItemLink())
		end
		local hasItemReserves = itemId and reserves and reserves.HasItemReserves and reserves:HasItemReserves(itemId)
			or false
		flagButtonsOnChange("hasItemReserves", hasItemReserves)
		local hasEligibleRaidReserve = hasItemReserves
		local hasLootAccess = RaidApi.CanUseCapability(Raid, "loot")
		local hasReadyCheckAccess = RaidApi.CanUseCapability(Raid, "ready_check")
		if hasItemReserves and reserves and reserves.HasCurrentRaidPlayersForItem and itemId then
			hasEligibleRaidReserve = reserves:HasCurrentRaidPlayersForItem(itemId)
		end
		local autoLootSuggestion = Loot.GetAutoLootSuggestion and Loot:GetAutoLootSuggestion() or nil
		local countdownRunning = isCountdownRunning()
		local hasInventoryTradeAccess = RaidApi.CanUseCapability(Raid, "inventory_trade")
		local hasLootSelectionAccess = canUseItemSelection()
		flagButtonsOnChange("hasEligibleRaidReserve", hasEligibleRaidReserve)
		flagButtonsOnChange("hasLootAccess", hasLootAccess)
		flagButtonsOnChange("hasLootSelectionAccess", hasLootSelectionAccess)
		flagButtonsOnChange("hasInventoryTradeAccess", hasInventoryTradeAccess)
		flagButtonsOnChange("hasReadyCheckAccess", hasReadyCheckAccess)
		flagButtonsOnChange("autoLootSuggestion", buildAutoLootSuggestionToken(autoLootSuggestion))
		flagButtonsOnChange("countdownRun", countdownRunning)
		flagButtonsOnChange("module._flowState", currentFlowState)

		local isTieReroll = Rolls:ShouldUseTieReroll(rollModel)
		local rollResolution, msCount, canAwardSelection =
			MasterService.ButtonState.ResolveAwardSelectionState(rollModel, isTieReroll)
		local workflowState = MasterService.FlowState.BuildState({
			autoLootSuggestion = autoLootSuggestion,
			canAwardSelection = canAwardSelection,
			canRoll = canRoll,
			countdownRunning = countdownRunning,
			currentFlowState = currentFlowState,
			currentMultiWinner = getCurrentMultiAwardWinner(),
			currentTradeWinner = getCurrentTradeWinner(),
			displayedWinner = displayedWinner,
			flowStates = module._FLOW_STATES,
			hasEligibleRaidReserve = hasEligibleRaidReserve,
			hasItem = hasItem,
			hasInventoryTradeAccess = hasInventoryTradeAccess,
			hasLootAccess = hasLootAccess,
			hasReadyCheckAccess = hasReadyCheckAccess,
			lootState = lootState,
			record = record,
			rollModel = rollModel,
			rolled = rolled,
		})
		local statusText = workflowState.statusText
		local selectedItemCount = tonumber(lootState.selectedItemCount) or 1
		local awardTarget = displayedWinner or getCurrentTradeWinner() or getCurrentMultiAwardWinner()
		if selectedItemCount < 1 then
			selectedItemCount = 1
		end

		local tooltipState = MasterService.ButtonState.BuildTooltipState({
			awardTarget = awardTarget,
			banker = lootState.banker,
			countdownRunning = countdownRunning,
			disenchanter = lootState.disenchanter,
			fromInventory = lootState.fromInventory,
			hasEligibleRaidReserve = hasEligibleRaidReserve,
			hasInventoryTradeAccess = hasInventoryTradeAccess,
			hasLootAccess = hasLootAccess,
			hasLootSelectionAccess = hasLootSelectionAccess,
			hasReadyCheckAccess = hasReadyCheckAccess,
			hasReserves = hasReserves,
			holder = lootState.holder,
			isTieReroll = isTieReroll,
			lootState = lootState,
			msCount = msCount,
			rollModel = rollModel,
			rollStarted = lootState.rollStarted,
			selectedItemCount = selectedItemCount,
			workflowState = workflowState,
		})

		flagButtonsOnChange("msCount", msCount)
		flagButtonsOnChange("manualResolution", rollResolution.requiresManualResolution == true)
		flagButtonsOnChange("workflowState", workflowState.name)
		flagButtonsOnChange("statusText", statusText)

		if module._dirtyFlags.buttons then
			updateMasterButtonsIfChanged(MasterService.ButtonState.BuildState({
				canAwardSelection = canAwardSelection,
				canRoll = canRoll,
				autoLootSuggestion = autoLootSuggestion,
				banker = lootState.banker,
				countdownRunning = countdownRunning,
				currentFlowState = currentFlowState,
				disenchanter = lootState.disenchanter,
				fromInventory = lootState.fromInventory,
				hasItem = hasItem,
				hasInventoryTradeAccess = hasInventoryTradeAccess,
				hasLootAccess = hasLootAccess,
				hasLootSelectionAccess = hasLootSelectionAccess,
				hasReadyCheckAccess = hasReadyCheckAccess,
				hasReserves = hasReserves,
				holder = lootState.holder,
				isTieReroll = isTieReroll,
				labels = {
					readyCheck = READY_CHECK,
					trade = TRADE,
				},
				lootCount = lootState.lootCount,
				lootState = lootState,
				record = record,
				rolled = rolled,
				rollStarted = lootState.rollStarted,
				rollsCount = lootState.rollsCount,
				statusText = statusText,
				tooltipState = tooltipState,
				workflowState = workflowState,
			}))
			module._dirtyFlags.buttons = false
		end

		local rollListDirty = module._dirtyFlags.rolls or module._dirtyFlags.winner
		if module._rollListController and rollListDirty then
			if module._rollListController.Dirty then
				module._rollListController:Dirty()
			end
			local updated
			if module._rollListController.UpdateNow then
				updated = module._rollListController:UpdateNow()
			end
			local frameName = getFrameName and getFrameName() or uiState.FrameName
			if updated == false or not (frameName and _G[frameName .. "PlayerBtn1"]) then
				Private.RenderRollRowsFallback(frameName)
			end
		end

		module._dirtyFlags.rolls = false
		module._dirtyFlags.winner = false
	end

	-- ============================================================================
	-- Dropdown / item selection helpers
	-- ============================================================================
	Private.GetRaidGridFrameAnchor = function()
		local selectedButton = LootFrame and LootFrame.selectedLootButton or nil
		if selectedButton and (not selectedButton.IsShown or selectedButton:IsShown()) then
			return selectedButton
		end
		if LootFrame and (not LootFrame.IsShown or LootFrame:IsShown()) then
			return LootFrame
		end
		return getFrame()
	end

	Private.GetSelectedMasterLootSlot = function()
		if LootFrame and LootFrame.selectedSlot then
			return LootFrame.selectedSlot
		end
		if LootFrame and LootFrame.selectedLootButton and LootFrame.selectedLootButton.GetID then
			local slot = LootFrame.selectedLootButton:GetID()
			if slot and slot > 0 then
				return slot
			end
		end
		return nil
	end

	Private.GetSelectedMasterLootLink = function()
		local slot = Private.GetSelectedMasterLootSlot()
		if slot and GetLootSlotLink then
			local link = GetLootSlotLink(slot)
			if link then
				return link
			end
		end
		return Loot.GetItemLink()
	end

	Private.GetSelectedMasterLootQuality = function()
		if LootFrame and LootFrame.selectedQuality then
			return tonumber(LootFrame.selectedQuality) or 0
		end
		local slot = Private.GetSelectedMasterLootSlot()
		if slot then
			local _, _, _, quality = GetLootSlotInfo(slot)
			return tonumber(quality) or 0
		end
		return 0
	end

	Private.GetSelectedMasterLootTexture = function()
		local slot = Private.GetSelectedMasterLootSlot()
		if slot then
			local texture = GetLootSlotInfo(slot)
			return texture
		end
		return nil
	end

	Private.GetSelectedMasterLootCount = function()
		local slot = Private.GetSelectedMasterLootSlot()
		if slot then
			local _, _, quantity = GetLootSlotInfo(slot)
			return tonumber(quantity) or nil
		end
		return nil
	end

	-- ----- Event Handlers & Callbacks ----- --
	-- ============================================================================
	-- Loot window helpers / event flow
	-- ============================================================================
	local function refreshAndMaybeShowLootFrame(shouldShow)
		local frame
		if shouldShow then
			frame = (module.EnsureUI and module:EnsureUI()) or getFrame()
		else
			frame = getFrame()
		end
		if not shouldShow then
			return frame, false
		end

		if not frame then
			return nil, false
		end

		-- Request while hidden to refresh immediately on OnShow (avoid an extra refresh).
		module:RequestRefresh()
		if frame and not frame:IsShown() then
			frame:Show()
		end
		return frame, true
	end

	local function handleLootOpenedVisibility()
		local shouldShow = (lootState.lootCount or 0) >= 1
		if shouldShow then
			refreshAndMaybeShowLootFrame(true)
		else
			-- Keep state dirty for the next time the frame is shown.
			module:RequestRefresh()
		end
	end

	local function handleLootSlotClearedVisibility()
		local shouldShow = (lootState.lootCount or 0) >= 1
		local frame, shown = refreshAndMaybeShowLootFrame(shouldShow)
		if shown then
			return
		end

		if frame then
			frame:Hide()
		end
		if addon.hasDebug then
			addon:debug(Diag.D.LogMLLootWindowEmptied)
		end
	end

	local function completeLootClosedCleanup()
		lootState.opened = false
		LootAttribution.Purge(PENDING_AWARD_TTL_SECONDS)
		LootDistribution.RequestSessionEnd()
		local frame = getFrame()
		if frame then
			frame:Hide()
		end
		clearLootAndResetRecordedRolls()
		module:RequestRefresh()
	end

	local function cancelLootClosedCleanup()
		if lootState.closeTimer then
			module:CancelTimer(lootState.closeTimer)
			lootState.closeTimer = nil
		end
	end

	local function scheduleLootClosedCleanup()
		-- Cancel any scheduled close timer and schedule a new one.
		cancelLootClosedCleanup()

		lootState.closeTimer = module:ScheduleTimer(function()
			lootState.closeTimer = nil
			completeLootClosedCleanup()
		end, 0.1)
	end

	-- ----- Public methods ----- --

	-- LOOT_OPENED: Triggered when the loot window opens.
	function module:LOOT_OPENED()
		local perfTotal = addon.hasPerf and addon:_PerfStart() or nil
		cancelLootClosedCleanup()
		Widgets.LootHints.ApplyLootFrameReserveHints()
		if canHandleLootWindow() then
			local debugEnabled = isDebugEnabled()
			local raidNum = Database.GetCurrentRaid()
			if Raid.ClearLootWindowBossContext then
				Raid:ClearLootWindowBossContext()
			end
			lootState.opened = true
			module._announced = false
			local perfStep = addon.hasPerf and addon:_PerfStart() or nil
			LootDistribution.Clear()
			Loot:FetchLoot()
			if canAutoManageLootFrame() and GetOption("Master", "autoSpamLootOnLootOpened") == true then
				Private.AnnounceLootLinks(GetOption("Master", "autoSpamSoftResOnLootOpened") == true)
			end
			if Raid.NotifyLootWindowOpened then
				Raid:NotifyLootWindowOpened()
			end
			if perfStep then
				addon:_PerfFinish(
					"Master.LOOT_OPENED FetchLoot",
					perfStep,
					"items=" .. tostring(lootState.lootCount or 0)
				)
			end
			if raidNum and Raid.EnsureLootWindowItemContext and Loot.GetLootWindowItems then
				perfStep = addon.hasPerf and addon:_PerfStart() or nil
				Raid:EnsureLootWindowItemContext(raidNum, Loot:GetLootWindowItems(), {
					ttlSeconds = LOOT_CONTEXT_SESSION_TTL_SECONDS,
					source = "LOOT_OPENED",
				})
				if perfStep then
					addon:_PerfFinish("Master.LOOT_OPENED LootContext", perfStep, "raid=" .. tostring(raidNum))
				end
			end
			perfStep = addon.hasPerf and addon:_PerfStart() or nil
			if canAutoManageLootFrame() then
				itemSelectionController:UpdateFrame()
			end
			if perfStep then
				addon:_PerfFinish(
					"Master.LOOT_OPENED SelectionFrame",
					perfStep,
					"items=" .. tostring(lootState.lootCount or 0)
				)
			end
			if debugEnabled then
				if isTraceEnabled() then
					addon:trace(
						Diag.D.LogMLLootOpenedTrace:format(lootState.lootCount or 0, tostring(lootState.fromInventory))
					)
				end
				if addon.hasDebug then
					addon:debug(
						Diag.D.LogMLLootOpenedInfo:format(
							lootState.lootCount or 0,
							tostring(lootState.fromInventory),
							tostring(UnitName("target"))
						)
					)
				end
			end
			perfStep = addon.hasPerf and addon:_PerfStart() or nil
			if canAutoManageLootFrame() then
				handleLootOpenedVisibility()
			end
			if perfStep then
				addon:_PerfFinish(
					"Master.LOOT_OPENED Visibility",
					perfStep,
					"items=" .. tostring(lootState.lootCount or 0)
				)
			end
			if perfTotal then
				addon:_PerfFinish("Master.LOOT_OPENED Total", perfTotal, "items=" .. tostring(lootState.lootCount or 0))
			end
		end
	end

	-- LOOT_CLOSED: Triggered when the loot window closes.
	function module:LOOT_CLOSED()
		Widgets.RaidGrid.Hide()
		Widgets.LootHints.ClearLootFrameReserveHints()
		if canHandleLootWindow() or lootState.opened == true then
			if Raid.ClearLootWindowBossContext then
				Raid:ClearLootWindowBossContext()
			end
			if isDebugEnabled() then
				if isTraceEnabled() then
					addon:trace(Diag.D.LogMLLootClosed:format(tostring(lootState.opened), lootState.lootCount or 0))
					addon:trace(Diag.D.LogMLLootClosedCleanup)
				end
			end
			clearMultiAwardState(false)
			scheduleLootClosedCleanup()
		end
	end

	function module:OPEN_MASTER_LOOT_LIST()
		Private.OpenManualAwardGrid()
	end

	function module:UPDATE_MASTER_LOOT_LIST()
		Private.RefreshManualAwardGrid()
	end

	function module:ShowDebugRaidGrid(count)
		return Private.OpenDebugRaidGrid(count)
	end

	DebugEntryPoint.RegisterCommand("raidgrid", "raidgrid [1-40]", L.StrCmdDebugRaidGrid, function(argument)
		local count = argument ~= "" and tonumber(argument) or 25
		if not count or count < 1 or count > 40 or count ~= math.floor(count) then
			addon:warn(L.MsgDebugRaidGridInvalidCount)
			return
		end
		local shown = module:ShowDebugRaidGrid(count)
		if shown then
			addon:info(L.MsgDebugRaidGridShown, shown)
		else
			addon:warn(L.MsgFeatureUnavailable, "Master", "debug raidgrid")
		end
	end)

	-- LOOT_SLOT_CLEARED: Triggered when an item is looted.
	function module:LOOT_SLOT_CLEARED(clearedSlot)
		local perfTotal = addon.hasPerf and addon:_PerfStart() or nil
		Widgets.LootHints.ApplyLootFrameReserveHints()
		if canHandleLootWindow() then
			module._awardConfirmation:Confirm(clearedSlot)
			if canAutoManageLootFrame() then
				local perfStep = addon.hasPerf and addon:_PerfStart() or nil
				Loot:FetchLoot()
				if perfStep then
					addon:_PerfFinish(
						"Master.LOOT_SLOT_CLEARED FetchLoot",
						perfStep,
						"slot=" .. tostring(clearedSlot or "?") .. " items=" .. tostring(lootState.lootCount or 0)
					)
				end
				if isDebugEnabled() then
					if isTraceEnabled() then
						addon:trace(Diag.D.LogMLLootSlotCleared:format(lootState.lootCount or 0))
					end
				end
				perfStep = addon.hasPerf and addon:_PerfStart() or nil
				itemSelectionController:UpdateFrame()
				if perfStep then
					addon:_PerfFinish(
						"Master.LOOT_SLOT_CLEARED SelectionFrame",
						perfStep,
						"slot=" .. tostring(clearedSlot or "?")
					)
				end
				Private.ResetItemCount()
				handleLootSlotClearedVisibility()
				if (tonumber(lootState.lootCount) or 0) <= 0 and Raid.NotifyLootWindowCleared then
					Raid:NotifyLootWindowCleared()
				end
				-- Continue a multi-award sequence (loot window only).
				return awardController:ContinueOnLootSlotCleared(clearedSlot)
			end
			if perfTotal then
				addon:_PerfFinish(
					"Master.LOOT_SLOT_CLEARED Total",
					perfTotal,
					"slot=" .. tostring(clearedSlot or "?") .. " items=" .. tostring(lootState.lootCount or 0)
				)
			end
		end
	end

	function module:UI_ERROR_MESSAGE(message)
		local failed = false
		if module._awardConfirmation:HasPending() and LootAttribution.IsMasterLootAwardFailureMessage(message) then
			failed = module._awardConfirmation:Fail(message) or failed
		end
		failed = failManualTrade(message) or failed
		if MasterService.Trade.IsFailureMessage(message) then
			failed = tradeExecutionController:FailAcceptedTrade(message) or failed
		end
		if failed then
			module:RequestRefresh()
		end
	end

	function module:UI_INFO_MESSAGE(arg1, arg2)
		local message = arg2 or arg1
		local failed = failManualTrade(message)
		if MasterService.Trade.IsFailureMessage(message) then
			failed = tradeExecutionController:FailAcceptedTrade(message) or failed
		end
		if failed then
			module:RequestRefresh()
		end
	end

	function module:PLAYER_TARGET_CHANGED()
		if Raid.HandleAutoMasterLootTargetChanged then
			Raid:HandleAutoMasterLootTargetChanged()
		end
	end

	function module:TRADE_ACCEPT_UPDATE(playerAccepted, targetAccepted)
		local tradeWinner = getCurrentTradeWinner()
		local RMATradeHandled = false
		local isAddonDrivenTrade = lootState.trader ~= nil and tradeWinner ~= nil
		if isTraceEnabled() then
			addon:trace(
				Diag.D.LogTradeAcceptUpdate:format(
					tostring(lootState.trader),
					tostring(tradeWinner),
					tostring(playerAccepted),
					tostring(targetAccepted)
				)
			)
		end
		RMATradeHandled = tradeExecutionController:HandleAcceptedAwardTrade(playerAccepted, targetAccepted)
		if not RMATradeHandled then
			local _, manualState = MasterService.Trade.ApplyAccept(playerAccepted, targetAccepted, isAddonDrivenTrade)
			if manualState then
				Widgets.TradeMenu.RefreshDropdowns(manualState)
			end
		end
	end

	function module:TRADE_SHOW()
		cancelManualTradeCloseSettle()
		tradeExecutionController:FailAcceptedTrade("TRADE_SHOW")
		MasterService.Trade.Reset(true, false)
		Widgets.TradeMenu.RefreshCandidate("TRADE_SHOW")
	end

	function module:TRADE_PLAYER_ITEM_CHANGED()
		Widgets.TradeMenu.RefreshCandidate("TRADE_PLAYER_ITEM_CHANGED")
	end

	function module:TRADE_TARGET_ITEM_CHANGED()
		Widgets.TradeMenu.RefreshCandidate("TRADE_TARGET_ITEM_CHANGED")
	end

	-- TRADE_CLOSED: trade window closed (completed or canceled)
	function module:TRADE_CLOSED()
		if tradeExecutionController:HasInFlightAward() and not tradeExecutionController:HasPendingAcceptedTrade() then
			tradeExecutionController:FailAcceptedTrade("TRADE_CLOSED")
		end
		scheduleManualTradeCloseSettle()
		handleTradeClosedOrCancelled()
	end

	-- TRADE_REQUEST_CANCEL: trade request canceled before opening
	function module:TRADE_REQUEST_CANCEL()
		cancelManualTradeCloseSettle()
		tradeExecutionController:FailAcceptedTrade("TRADE_REQUEST_CANCEL")
		MasterService.Trade.Reset(true, false)
		Widgets.TradeMenu.HideDropdowns()
		handleTradeClosedOrCancelled()
	end

	-- ============================================================================
	-- Assignment / trade execution
	-- ============================================================================
	-- Assigns an item from the loot window to a player.
	function assignItem(itemLink, playerName, rollType, rollValue, effect)
		local rollSession = Rolls:GetRollSession()
		effect = effect
			or createAwardAttempt({
				rollSessionId = rollSession and rollSession.id or nil,
				itemKey = Item.GetItemStringFromLink(itemLink) or itemLink,
				itemLink = itemLink,
				winner = playerName,
				source = "master_loot",
				executorContext = {
					executor = "loot_window",
					rollType = rollType,
					raidNid = Database.GetCurrentRaid(),
				},
			})
		local itemIndex = LootInventory.FindLootSlotIndex(itemLink)
		if itemIndex == nil then
			addon:error(L.ErrCannotFindItem:format(itemLink))
			effect:Fail("item_not_found")
			return false
		end

		if not (Raid and Raid.IsMasterLooter and Raid:IsMasterLooter()) then
			addon:warn(L.WarnMLNoPermission)
			refreshCandidateUiState()
			module:RequestRefresh()
			effect:Fail("not_master_looter")
			return false
		end

		local validation = Rolls:ValidateWinner(playerName, itemLink, rollType)
		if not (validation and validation.ok == true) then
			addon:warn((validation and validation.warnMessage) or L.ErrMLWinnerIneligible:format(tostring(playerName)))
			refreshCandidateUiState()
			module:RequestRefresh()
			effect:Fail("winner_ineligible")
			return false
		end

		local candidateIndex = RaidApi.FindMasterLootCandidateIndex(Raid, itemLink, playerName)
		if candidateIndex then
			-- Mark this award as addon-driven so AddLoot() won't classify it as MANUAL
			local session = Rolls:EnsureLootRollSession(
				itemLink,
				rollType,
				lootState.fromInventory and "inventory" or "lootWindow",
				buildLootRollSessionOptions()
			)
			local attemptState = effect and effect:GetState() or nil
			local transactionId = attemptState and attemptState.transactionId or tostring(effect or {})
			Loot:AddPendingAward(itemLink, playerName, rollType, rollValue, session and session.id or nil, nil, {
				counterApplied = true,
				transactionId = transactionId,
			})
			module._awardConfirmation:Queue({
				itemLink = itemLink,
				itemIndex = itemIndex,
				playerName = playerName,
				rollType = rollType,
				rollValue = rollValue,
				sessionId = session and session.id or nil,
				effect = effect,
				transactionId = transactionId,
			})
			GiveMasterLoot(itemIndex, candidateIndex)
			LootDistribution.PublishRollEnd(itemLink, playerName, rollValue, "master_loot")
			if addon.hasDebug then
				addon:debug(
					Diag.D.LogMLAwarded:format(
						tostring(itemLink),
						tostring(playerName),
						tonumber(rollType) or -1,
						tonumber(rollValue) or 0,
						tonumber(itemIndex) or -1,
						tonumber(candidateIndex) or -1
					)
				)
			end
			local output, whisper = buildAssignMessages(itemLink, playerName, rollType)

			local suppressAwardAnnouncement = lootState.multiAward
				and lootState.multiAward.active
				and not lootState.fromInventory
			if output and not module._announced and not suppressAwardAnnouncement then
				Announce(Chat, output)
				module._announced = true
			end
			if whisper then
				Comms.SendWhisper(playerName, whisper)
			end
			-- IMPORTANT:
			-- Do NOT force-update an existing raid.loot entry here.
			-- For Master Loot awards from the loot window, the authoritative record is created by Loot:AddLoot()
			-- from the LOOT_ITEM / LOOT_ITEM_MULTIPLE chat event, where we also apply the pending rollType/rollValue.
			--
			-- If multiple identical items are distributed across different roll types ("partial award" workflow),
			-- using a pre-resolved lootNid can overwrite previous entries when matching by itemId only.
			-- Keeping the logging entirely event-driven avoids that class of data corruption.
			return true
		end

		if not RaidApi.CanResolveMasterLootCandidates(Raid, itemLink) then
			addon:warn(L.WarnMLNoCandidatesAvailable)
		else
			addon:warn(L.WarnMLWinnerNoCandidate:format(tostring(playerName)))
		end
		refreshCandidateUiState()
		module:RequestRefresh()
		effect:Fail("candidate_unavailable")
		return false
	end

	-- ============================================================================
	-- Bus callbacks
	-- ============================================================================
	do
		local GROUP_LOOT_RESTORE_POPUP_KEY = "RMA_CONFIRM_GROUP_LOOT_RESTORE"

		Private.RestoreGroupLootFromPopup = function()
			if Raid and Raid.RestoreGroupLoot then
				Raid:RestoreGroupLoot("popup")
			end
		end

		Private.RegisterWowForwarded = function(methodName)
			RegisterCallback(ResolveWowForwardedName(methodName), function(_, ...)
				local fn = module[methodName]
				if fn then
					fn(module, ...)
				end
			end)
		end

		Private.RegisterWowForwarded("LOOT_OPENED")
		Private.RegisterWowForwarded("LOOT_CLOSED")
		Private.RegisterWowForwarded("LOOT_SLOT_CLEARED")
		Private.RegisterWowForwarded("OPEN_MASTER_LOOT_LIST")
		Private.RegisterWowForwarded("UPDATE_MASTER_LOOT_LIST")
		Private.RegisterWowForwarded("PLAYER_TARGET_CHANGED")
		Private.RegisterWowForwarded("UI_ERROR_MESSAGE")
		Private.RegisterWowForwarded("UI_INFO_MESSAGE")
		Private.RegisterWowForwarded("TRADE_ACCEPT_UPDATE")
		Private.RegisterWowForwarded("TRADE_SHOW")
		Private.RegisterWowForwarded("TRADE_PLAYER_ITEM_CHANGED")
		Private.RegisterWowForwarded("TRADE_REQUEST_CANCEL")
		Private.RegisterWowForwarded("TRADE_TARGET_ITEM_CHANGED")
		Private.RegisterWowForwarded("TRADE_CLOSED")

		RegisterCallback(MasterEvents.GroupLootRestoreNeeded, function()
			ShowConfirmPopup(
				GROUP_LOOT_RESTORE_POPUP_KEY,
				L.PopupGroupLootRestoreText,
				Private.RestoreGroupLootFromPopup,
				GROUP_LOOT_RESTORE_POPUP_KEY,
				{
					button1 = L.BtnGroupLoot,
					button2 = L.BtnKeepMasterLoot,
				}
			)
		end)
	end

	RegisterCallback(MasterEvents.SetItem, function(_, itemLink, itemData)
		if itemLink ~= nil and type(itemLink) ~= "string" then
			addon:warn(Diag.W.LogMLSetItemPayloadInvalid:format(tostring(itemLink), type(itemData)))
			return
		end
		if itemData ~= nil and type(itemData) ~= "table" then
			addon:warn(Diag.W.LogMLSetItemPayloadInvalid:format(tostring(itemLink), type(itemData)))
			return
		end

		if module._lastUIState.currentItemLink ~= itemLink then
			module._announced = false
			module._lastUIState.currentItemLink = itemLink
		end

		if itemData and itemData.itemName and itemData.itemTexture and itemData.itemColor and itemData.itemLink then
			setCurrentItemView(itemData.itemName, itemData.itemLink, itemData.itemTexture, itemData.itemColor)
			Private.ResetItemCount()
		else
			Private.ClearCurrentItemView(true)
		end

		module:RequestRefresh()
	end)

	RegisterCallback(MasterEvents.RaidRosterDelta, function(_, delta, rosterVersion, raidId)
		local raidIdType = type(raidId)
		if type(delta) ~= "table" then
			addon:warn(
				Diag.W.LogMLRaidRosterDeltaPayloadInvalid:format(type(delta), tostring(rosterVersion), tostring(raidId))
			)
			return
		end
		if type(rosterVersion) ~= "number" then
			addon:warn(
				Diag.W.LogMLRaidRosterDeltaPayloadInvalid:format(type(delta), tostring(rosterVersion), tostring(raidId))
			)
			return
		end
		if raidId == nil then
			addon:warn(
				Diag.W.LogMLRaidRosterDeltaPayloadInvalid:format(type(delta), tostring(rosterVersion), tostring(raidId))
			)
			return
		end
		if raidIdType ~= "number" and raidIdType ~= "string" then
			addon:warn(
				Diag.W.LogMLRaidRosterDeltaPayloadInvalid:format(type(delta), tostring(rosterVersion), tostring(raidId))
			)
			return
		end

		refreshCandidateUiState()
		requestCoalescedUiRefresh("raid-roster")
	end)

	-- Keep Master UI in sync when SoftRes data changes (import/clear), event-driven.
	RegisterCallback(MasterEvents.ReservesDataChanged, function()
		Widgets.LootHints.ApplyLootFrameReserveHints()
		requestCoalescedUiRefresh("reserves")
	end)

	RegisterCallback(MasterEvents.LootBansChanged, function()
		if Widgets.RaidGrid.IsShown() and Widgets.RaidGrid.GetMode() == "lootBan" then
			Widgets.RaidGrid.Refresh(Private.BuildLootBanRows())
		end
		requestCoalescedUiRefresh("loot-bans")
	end)

	RegisterCallback(MasterEvents.AddRoll, function(_, name, roll)
		if type(name) ~= "string" or name == "" or tonumber(roll) == nil then
			addon:warn(Diag.W.LogMLAddRollPayloadInvalid:format(tostring(name), tostring(roll)))
			return
		end
		requestCoalescedUiRefresh("roll")
	end)

	RegisterCallback(MasterEvents.ConfigSortAscending, function()
		requestCoalescedUiRefresh("sort")
	end)

	-- Redraw after toggling the optional +N column in the MS roll list.
	RegisterCallback(MasterEvents.ConfigShowLootCounterDuringMSRoll, function()
		requestCoalescedUiRefresh("roll-counter")
	end)

	RegisterCallback(MasterEvents.SpecInspectUpdated, function()
		invalidateRollSelectionModel()
		module._dirtyFlags.rolls = true
		module:RequestRefresh()
	end)
end
