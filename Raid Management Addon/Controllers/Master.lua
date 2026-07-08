-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: local feature = addon.Database.GetFeatureShared()
-- exports: publish module APIs on addon.*
-- events: listens forwarded loot/trade events and Master bus refresh events
local addon = select(2, ...)
local feature = addon.Database.GetFeatureShared()

local L = feature.L
local Diag = feature.Diag

local UI = feature.UI
local Frames = UI.Frames
local Tooltips = UI.Tooltips
local Lists = assert(UI.Lists, "Master list controller namespace is not initialized")
local CreateListController = assert(Lists.CreateController, "Master roll list controller factory is not initialized")
local CreateRowRenderer = assert(Lists.CreateRowRenderer, "Master roll row renderer factory is not initialized")
local MakeIndexedRowName = assert(Lists.MakeIndexedRowName, "Master indexed row-name factory is not initialized")
local GetFrameRef = assert(Frames.GetRef, "Master frame ref resolver is not initialized")
local GetNamedParts = assert(Frames.GetNamedParts, "Master named frame-parts resolver is not initialized")
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
local Item = feature.Item
local Colors = feature.Colors
local Comms = feature.Comms
local Events = feature.Events
local C = feature.C
local Database = feature.Database
local Options = feature.Options
local Bus = feature.Bus
local Services = feature.Services
local Loot = assert(Services.Loot, "Master loot service is not initialized")
local LootInventory = assert(Loot._Inventory, "Loot inventory helpers are not initialized")
local LootAwardPlanner = assert(Loot._AwardPlanner, "Loot award planner helpers are not initialized")
local Raid = assert(Services.Raid, "Master raid service is not initialized")
local Rolls = assert(Services.Rolls, "Master rolls service is not initialized")
local Chat = assert(Services.Chat, "Master chat service is not initialized")
local MasterService = assert(Services.Master, "Master service namespace is not initialized")

local InternalEvents = assert(Events.Internal, "Master controller internal events are not initialized")
local TriggerEvent = assert(Bus.TriggerEvent, "Master controller event publisher is not initialized")
local RegisterCallback = assert(Bus.RegisterCallback, "Master controller event listener is not initialized")
local GetWowForwarded = assert(Events.GetWowForwarded, "Master controller forwarded-event resolver is not initialized")
local MasterEvents = {
	RequestGroupLootRestorePrompt = assert(
		InternalEvents.RequestGroupLootRestorePrompt,
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
}
local LoggerLootLogRequestEvent =
	assert(InternalEvents.LoggerLootLogRequest, "Master controller logger loot-log request event is not initialized")

local rollTypes = feature.rollTypes
local RAID_TARGET_MARKERS = feature.RAID_TARGET_MARKERS
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
local GetLootSlotInfo = assert(_G.GetLootSlotInfo, "Master controller loot slot info API is not initialized")

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
	feature.Controllers.Master = feature.Controllers.Master or {}
	local module = feature.Controllers.Master
	local uiState = UI.Scaffold.EnsureModuleState(module)

	-- Timer ownership: all Master controller timers (module._PendingCounter, multi-award timeout/delay, loot close).
	feature.Timer.BindMixin(module, "Master")

	-- Namespace registrations owned by the Master controller. Stored on `module`
	-- to avoid extra upvalues because this file is near Lua 5.1's 200 local/upvalue limit.
	-- Lookups happen through inline Options.Get(...) calls at call sites.
	Options.AddNamespace("Master", {
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
	Options.AddNamespace("Loot", {
		lootWhispers = false,
		ignoreStacks = false,
	})

	local GetOption = Options.GetValue

	-- ----- Internal state ----- --
	local getFrame = MakeModuleFrameGetter(module, "RMAMaster")

	local initializeDropDowns, prepareDropDowns, updateDropDowns
	module._dropDownData = module._dropDownData or {}
	module._dropDownGroupData = module._dropDownGroupData or {}
	-- Ensure subgroup tables exist even when the Master UI hasn't been opened yet.
	for i = 1, 8 do
		module._dropDownData[i] = module._dropDownData[i] or {}
	end
	module._dropDownDirty = true
	module._dropDownsInitialized = false

	local updateSelectionFrame
	module._selectionButtons = module._selectionButtons or {}

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

	local assignItem, tradeItem, registerAwardedItem, clearMultiAwardState
	local advanceInventoryWinnerSelection
	local completeInventoryAwardProgress
	local updateRollSessionExpectedWinners
	local Private = {}
	module._awardFlow = module._awardFlow or {}
	module._screenshotWarn = false

	module._announced = false
	module._cachedRosterVersion = nil
	local ROLL_WINNER_PREFIX = "RMA-RollWinner"
	if type(_G.RegisterAddonMessagePrefix) == "function" then
		_G.RegisterAddonMessagePrefix(ROLL_WINNER_PREFIX)
	end
	local ROLL_WINNERS_CTX = "MLRollWinners"
	local ROLL_SELECTION_MODE = {
		AUTO = "AUTO",
		MANUAL_SINGLE = "MANUAL_SINGLE",
		MANUAL_MULTI = "MANUAL_MULTI",
	}
	module._rollUiState = module._rollUiState
		or {
			mode = ROLL_SELECTION_MODE.AUTO,
			sessionKey = nil,
			showRollsOnly = true,
			model = nil,
		}
	module._PendingCounter = MasterService.AwardCounter.EnsureState(module._PendingCounter)
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

	-- ============================================================================
	-- Dropdown / frame helpers
	-- ============================================================================
	local function configureAssignDropDown(frame)
		if not frame then
			return
		end
		frame:SetWidth(module._assignDropDownButtonWidth)
		if UIDropDownMenu_SetWidth then
			UIDropDownMenu_SetWidth(frame, module._assignDropDownWidth)
		end
		if UIDropDownMenu_SetButtonWidth then
			UIDropDownMenu_SetButtonWidth(frame, module._assignDropDownButtonWidth)
		end
		if UIDropDownMenu_JustifyText then
			UIDropDownMenu_JustifyText(frame, "LEFT")
		end
	end

	-- ============================================================================
	-- Roll selection / UI model helpers
	-- ============================================================================
	local function resetRollWinnerSelection(mode)
		UI.Selection.EnsureState(ROLL_WINNERS_CTX)
		UI.Selection.SetAnchor(ROLL_WINNERS_CTX, nil)
		module._rollUiState.mode = mode or ROLL_SELECTION_MODE.AUTO
		module._rollUiState.model = nil
	end

	local function invalidateRollUiModel()
		module._rollUiState.model = nil
	end

	local function getRollSelectionSessionKey()
		local session = GetRollSession(Rolls)
		return session and tostring(session.id) or nil
	end

	local function syncRollSelectionSession()
		local sessionKey = getRollSelectionSessionKey()
		if module._rollUiState.sessionKey == sessionKey then
			return sessionKey
		end
		resetRollWinnerSelection(ROLL_SELECTION_MODE.AUTO)
		module._rollUiState.sessionKey = sessionKey
		return sessionKey
	end

	local isSelectableRollRow = MasterService.RollRows.IsSelectableRow

	local function getSelectedRollWinnersOrdered(rows)
		local selected = {}
		if type(rows) ~= "table" then
			return selected
		end

		for i = 1, #rows do
			local row = rows[i]
			if
				row
				and row.name
				and isSelectableRollRow(row)
				and UI.Selection.IsSelected(ROLL_WINNERS_CTX, row.name)
			then
				selected[#selected + 1] = {
					name = row.name,
					roll = tonumber(row.roll) or 0,
				}
			end
		end

		return selected
	end

	local function replaceRollWinnerSelection(names, mode)
		local lastName = nil

		resetRollWinnerSelection(mode)
		if type(names) ~= "table" then
			return 0
		end

		for i = 1, #names do
			local name = names[i]
			if type(name) == "string" and name ~= "" then
				UI.Selection.Toggle(ROLL_WINNERS_CTX, name, true)
				lastName = name
			end
		end

		UI.Selection.SetAnchor(ROLL_WINNERS_CTX, lastName)
		return UI.Selection.GetCount(ROLL_WINNERS_CTX) or 0
	end

	local function pruneRollWinnerSelection(rows)
		local valid = {}
		local selected = UI.Selection.GetSelected(ROLL_WINNERS_CTX) or {}
		local changed = false
		local ordered

		if type(rows) ~= "table" then
			return 0
		end

		for i = 1, #rows do
			local row = rows[i]
			if row and row.name and isSelectableRollRow(row) then
				valid[row.name] = true
			end
		end

		for i = 1, #selected do
			local name = selected[i]
			if not valid[name] then
				UI.Selection.Toggle(ROLL_WINNERS_CTX, name, true)
				changed = true
			end
		end

		if changed then
			ordered = getSelectedRollWinnersOrdered(rows)
			UI.Selection.SetAnchor(ROLL_WINNERS_CTX, ordered[#ordered] and ordered[#ordered].name or nil)
		end

		return UI.Selection.GetCount(ROLL_WINNERS_CTX) or 0
	end

	local buildRollUiModel, selectRollWinnerRow

	local function applyRollWinnerSelection(name, pickMode, maxSel)
		local isMulti
		local isSelected
		local currentCount

		if not name or name == "" then
			return false
		end

		if not pickMode then
			UI.Selection.Toggle(ROLL_WINNERS_CTX, name, false, false)
			UI.Selection.SetAnchor(ROLL_WINNERS_CTX, name)
			module._rollUiState.mode = ROLL_SELECTION_MODE.MANUAL_SINGLE
			return true
		end

		isMulti = UI.Selection.ResolveModifiers
				and select(1, UI.Selection.ResolveModifiers(ROLL_WINNERS_CTX, { allowRange = false }))
			or ((IsControlKeyDown and IsControlKeyDown()) or false)
		isSelected = UI.Selection.IsSelected(ROLL_WINNERS_CTX, name)
		currentCount = UI.Selection.GetCount(ROLL_WINNERS_CTX) or 0

		if isMulti then
			if (not isSelected) and currentCount >= maxSel then
				if maxSel == 1 then
					replaceRollWinnerSelection({ name }, ROLL_SELECTION_MODE.MANUAL_MULTI)
					return true
				end
				addon:warn(Diag.W.ErrMLMultiSelectTooMany:format(maxSel))
				return false
			end
			UI.Selection.Toggle(ROLL_WINNERS_CTX, name, true, true)
		else
			UI.Selection.Toggle(ROLL_WINNERS_CTX, name, false, false)
		end

		module._rollUiState.mode = ROLL_SELECTION_MODE.MANUAL_MULTI
		if (UI.Selection.GetCount(ROLL_WINNERS_CTX) or 0) > 0 then
			UI.Selection.SetAnchor(ROLL_WINNERS_CTX, name)
		else
			UI.Selection.SetAnchor(ROLL_WINNERS_CTX, nil)
		end
		return true
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

		-- Blizz-like gesture support:
		-- - Click while holding an item on the cursor
		-- - Drag&drop (release) an item onto the button
		local function tryAcceptFromCursor()
			if CursorHasItem and CursorHasItem() then
				Private.TryAcceptInventoryItemFromCursor()
			end
		end

		SetScriptSafely(itemBtn, "OnClick", function()
			tryAcceptFromCursor()
		end)

		SetScriptSafely(itemBtn, "OnReceiveDrag", function()
			tryAcceptFromCursor()
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
			UI.Widgets.Call("Config", "Toggle")
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

	Private.syncRollWinnerSelectionState = function(baseRows, resolution, selectionAllowed, requiredWinnerCount)
		if selectionAllowed then
			pruneRollWinnerSelection(baseRows)
		elseif (UI.Selection.GetCount(ROLL_WINNERS_CTX) or 0) > 0 then
			resetRollWinnerSelection(ROLL_SELECTION_MODE.AUTO)
		end

		local inventoryMultiSelectMode = lootState.fromInventory
			and (requiredWinnerCount > 1 or module._rollUiState.mode == ROLL_SELECTION_MODE.MANUAL_MULTI)
		local pickMode = selectionAllowed and ((not lootState.fromInventory) or inventoryMultiSelectMode)

		if pickMode and module._rollUiState.mode == ROLL_SELECTION_MODE.AUTO then
			local prefillNames = {}
			for i = 1, #(resolution.autoWinners or {}) do
				local winner = resolution.autoWinners[i]
				if winner and winner.name then
					prefillNames[#prefillNames + 1] = winner.name
				end
			end
			replaceRollWinnerSelection(prefillNames, ROLL_SELECTION_MODE.AUTO)
		elseif
			not pickMode
			and module._rollUiState.mode ~= ROLL_SELECTION_MODE.MANUAL_SINGLE
			and (UI.Selection.GetCount(ROLL_WINNERS_CTX) or 0) > 0
		then
			resetRollWinnerSelection(ROLL_SELECTION_MODE.AUTO)
		end

		local selectionState = MasterService.RollRows.BuildSelectionState({
			fromInventory = lootState.fromInventory,
			mode = module._rollUiState.mode,
			resolution = resolution,
			requiredWinnerCount = requiredWinnerCount,
			selectedWinners = getSelectedRollWinnersOrdered(baseRows),
			selectionAllowed = selectionAllowed and true or false,
		})
		if selectionState.resetSelectionToAuto then
			resetRollWinnerSelection(ROLL_SELECTION_MODE.AUTO)
		end
		return selectionState
	end

	Private.decorateRollUiRows = function(baseRows, resolution, selectionState)
		return MasterService.RollRows.BuildModel({
			rows = baseRows,
			resolution = resolution,
			selectionState = selectionState,
			showRollsOnly = module._rollUiState.showRollsOnly == true,
		})
	end

	buildRollUiModel = function(forceRefresh)
		if forceRefresh ~= true and module._rollUiState.model then
			return module._rollUiState.model
		end

		local model = GetDisplayModel(Rolls) or {}
		local baseRows = model.rows or {}
		local resolution = model.resolution or {}
		local selectionAllowed = model.selectionAllowed == true
		local requiredWinnerCount = tonumber(model.requiredWinnerCount) or 1

		syncRollSelectionSession()
		local selectionState =
			Private.syncRollWinnerSelectionState(baseRows, resolution, selectionAllowed, requiredWinnerCount)
		local decoratedRows, visibleRows = Private.decorateRollUiRows(baseRows, resolution, selectionState)

		model.rows = decoratedRows
		model.visibleRows = visibleRows
		model.pickMode = selectionState.pickMode
		model.msCount = selectionState.msCount
		model.highlightTarget = selectionState.highlightTarget
		model.winner = selectionState.winnerName
		model.selectionAllowed = selectionState.selectionAllowed
		model.showRollsOnly = module._rollUiState.showRollsOnly == true
		module._rollUiState.model = model
		return model
	end

	selectRollWinnerRow = function(name)
		local model = buildRollUiModel(true)
		local rows = model and model.rows or {}
		local requiredWinnerCount = tonumber(model and model.requiredWinnerCount) or 1
		local pickMode = model and model.pickMode == true
		local maxSel = requiredWinnerCount
		local row

		if not (model and model.selectionAllowed == true) then
			return false
		end

		if lootState.multiAward and lootState.multiAward.active then
			addon:warn(Diag.W.ErrMLMultiAwardInProgress)
			return false
		end

		for i = 1, #rows do
			if rows[i] and rows[i].name == name then
				row = rows[i]
				break
			end
		end

		if not isSelectableRollRow(row) then
			return false
		end

		if maxSel > #rows then
			maxSel = #rows
		end
		if maxSel < 1 then
			maxSel = 1
		end

		if not applyRollWinnerSelection(name, pickMode, maxSel) then
			return false
		end

		invalidateRollUiModel()
		buildRollUiModel()
		if not pickMode then
			Comms.Sync(ROLL_WINNER_PREFIX, name)
		end
		return true
	end

	local function copyVisibleRollRows(out)
		local model = module._rollUiState.model
		local visibleRows = model and model.visibleRows or {}

		for i = 1, #visibleRows do
			local source = visibleRows[i]
			if source then
				local copy = MasterService.RollRows.BuildListRow(source, i)
				if copy then
					out[#out + 1] = copy
				end
			end
		end
	end

	local function getFocusedRollRowId()
		local model = module._rollUiState.model
		local visibleRows = model and model.visibleRows or nil

		if type(visibleRows) ~= "table" then
			return nil
		end

		for i = 1, #visibleRows do
			local row = visibleRows[i]
			if row and row.isFocused == true then
				return i
			end
		end

		return nil
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
		local model = module._rollUiState.model
		local visibleRows = model and model.visibleRows or nil
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
	UI.Widgets.Call("LootHints", "EnsureLootFrameHooks")

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
		local request = {
			lootNid = lootNid,
			itemID = lootNid,
			looter = looter,
			rollType = rollType,
			rollValue = rollValue,
			source = source,
			raidId = raidId,
			raidID = raidId,
			ok = false,
		}
		TriggerEvent(LoggerLootLogRequestEvent, request)
		return request.ok == true
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
		stopCountdown()
		local duration = GetOption("Rolls", "countdownDuration") or 0
		local blockAfterCountdown = GetOption("Rolls", "countdownRollsBlock") == true

		Rolls:StartCountdown(duration, nil, function()
			-- At zero: either block late rolls or keep intake open and tag late responses as OOT.
			if blockAfterCountdown then
				Rolls:SetRollRecordingEnabled(false)
			end
			refreshRollDisplay()
		end)
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

	local function refreshDropDowns(force)
		if not module._dropDownsInitialized then
			return
		end
		if not force and not module._dropDownDirty then
			return
		end
		updateDropDowns(module._dropDownFrameHolder)
		updateDropDowns(module._dropDownFrameBanker)
		updateDropDowns(module._dropDownFrameDisenchanter)
		module._dropDownDirty = false
		module._dirtyFlags.dropdowns = false
	end

	local function hookDropDownOpen(frame, targetKey)
		if not frame then
			return
		end
		local button = _G[frame:GetName() .. "Button"]
		if button and not button._RMAHooked then
			Frames.HookScriptSafely(button, "OnClick", function()
				refreshDropDowns(true)
				if targetKey and Private.OpenAssignmentTargetGrid then
					Private.OpenAssignmentTargetGrid(targetKey)
				end
			end)
			button._RMAHooked = true
		end
	end

	local function refreshCandidateUiState()
		module._cachedRosterVersion = nil
		RaidApi.RequestMasterLootCandidateRefresh(Raid)
		module._dropDownDirty = true
		module._dirtyFlags.dropdowns = true
		if prepareDropDowns then
			prepareDropDowns()
		end
	end

	function module._PendingCounter:Remove(index)
		return MasterService.AwardCounter.Remove(self, index, function(handle)
			module:CancelTimer(handle)
		end)
	end

	function module._PendingCounter:Clear(reason)
		local removed = MasterService.AwardCounter.Clear(self, reason, function(handle)
			module:CancelTimer(handle)
		end)
		for i = 1, #removed do
			local pending = removed[i]
			if pending and addon.hasDebug then
				addon:debug(
					Diag.W.LogMLAwardCounterFailed:format(
						tostring(pending.itemLink),
						tostring(pending.playerName),
						tostring(reason or "clear")
					)
				)
			end
		end
	end

	function module._PendingCounter:FindBySlot(clearedSlot)
		return MasterService.AwardCounter.FindBySlot(self, clearedSlot)
	end

	function module._PendingCounter:HasPending()
		return MasterService.AwardCounter.HasPending(self)
	end

	function module._PendingCounter:IsFailureMessage(message)
		return Loot:IsMasterLootAwardFailureMessage(message)
	end

	function module._PendingCounter:Fail(reason)
		local failed = MasterService.AwardCounter.Fail(self, reason, function(handle)
			module:CancelTimer(handle)
		end)
		for i = 1, #failed do
			local pending = failed[i]
			addon:warn(
				Diag.W.LogMLAwardCounterFailed:format(
					tostring(pending.itemLink),
					tostring(pending.playerName),
					tostring(reason or "unknown")
				)
			)
		end
		return failed[1] ~= nil
	end

	function module._PendingCounter:Confirm(clearedSlot, source)
		local pending = MasterService.AwardCounter.Confirm(self, clearedSlot, function(handle)
			module:CancelTimer(handle)
		end)
		if not pending then
			return false
		end

		Raid:AddPlayerCountForRollType(
			pending.playerName,
			pending.rollType,
			pending.itemCount or 1,
			Database.GetCurrentRaid()
		)
		if addon.hasDebug then
			addon:debug(
				Diag.D.LogMLAwardCounterConfirmed:format(
					tostring(pending.itemLink),
					tostring(pending.playerName),
					tonumber(pending.rollType) or -1,
					tostring(source or "unknown")
				)
			)
		end
		Loot:SetDistributionState("item_done", {
			itemLink = pending.itemLink,
			winnerName = pending.playerName,
		})
		return true
	end

	function module._PendingCounter:Queue(itemLink, itemIndex, playerName, rollType, rollValue, sessionId)
		local pending = MasterService.AwardCounter.Queue(self, {
			itemLink = itemLink,
			itemIndex = itemIndex,
			playerName = playerName,
			rollType = rollType,
			rollValue = rollValue,
			sessionId = sessionId,
			itemCount = 1,
		})

		local timeout = tonumber(C.ML_AWARD_CONFIRM_TIMEOUT_SECONDS) or 4
		if timeout > 0 then
			local owner = self
			pending.timeoutHandle = module:ScheduleTimer(function()
				local awards = owner.Awards
				for i = #awards, 1, -1 do
					if awards[i] == pending then
						owner:Remove(i)
						addon:warn(
							Diag.W.LogMLAwardCounterTimeout:format(
								timeout,
								tostring(pending.itemLink),
								tostring(pending.playerName),
								tostring(pending.itemIndex or "?")
							)
						)
						module:RequestRefresh()
						return
					end
				end
			end, timeout)
		end
		return pending
	end

	-- ============================================================================
	-- Award / candidate helpers
	-- ============================================================================
	local function buildAssignMessages(itemLink, playerName, rollType)
		return MasterService.AwardMessages.BuildAssignMessages({
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
	local function collectMultiAwardNames(ma)
		local names = {}
		if not ma then
			return names
		end
		local total = ma.total or (ma.winners and #ma.winners) or 0
		for i = 1, total do
			local winner = ma.winners and ma.winners[i]
			if winner and winner.name then
				names[#names + 1] = winner.name
			end
		end
		return names
	end

	local function announceMultiAwardCompletion(ma)
		if not (ma and ma.announceOnWin and not ma.congratsSent) then
			return
		end
		local names = collectMultiAwardNames(ma)
		if #names <= 0 then
			return
		end
		if #names == 1 then
			Announce(Chat, L.ChatAward:format(names[1], ma.itemLink))
		else
			Announce(Chat, L.ChatAwardMutiple:format(table.concat(names, ", "), ma.itemLink))
		end
		ma.congratsSent = true
	end

	local function cancelMultiAwardTimeout(ma)
		if ma and ma.timeoutHandle then
			module:CancelTimer(ma.timeoutHandle)
			ma.timeoutHandle = nil
		end
	end

	local function cancelMultiAwardDelay(ma)
		if ma and ma.delayHandle then
			module:CancelTimer(ma.delayHandle)
			ma.delayHandle = nil
		end
		if ma then
			ma.scheduled = false
		end
	end

	local function armMultiAwardProgressTimeout(ma)
		if not (ma and ma.active and not lootState.fromInventory) then
			return
		end
		local timeout = tonumber(ML_MULTI_AWARD_TIMEOUT_SECONDS) or 0
		ma.waitingForDecrement = true
		if timeout <= 0 then
			return
		end

		cancelMultiAwardTimeout(ma)
		local expectedLessThan = tonumber(ma.lastCount) or 0
		ma.timeoutHandle = module:ScheduleTimer(function()
			local cur = lootState.multiAward
			if cur ~= ma or not (cur and cur.active and cur.waitingForDecrement and not lootState.fromInventory) then
				return
			end
			local observed = Loot:GetLootWindowItemCountByKey(cur.itemKey)
			addon:warn(
				Diag.W.ErrMLMultiAwardInterruptedTimeout:format(
					timeout,
					tostring(cur.itemLink),
					expectedLessThan,
					observed,
					tostring(cur.lastClearedSlot or "?")
				)
			)
			clearMultiAwardState(true)
			module:RequestRefresh()
		end, timeout)
	end

	clearMultiAwardState = function(resetItemCount)
		local ma = lootState.multiAward
		if ma then
			ma.waitingForDecrement = false
			cancelMultiAwardTimeout(ma)
			cancelMultiAwardDelay(ma)
		end
		lootState.multiAward = nil
		module._announced = false
		if resetItemCount then
			Private.ResetItemCount()
		end
	end

	local function finalizeMultiAwardIfDone()
		local ma = lootState.multiAward
		if not ma then
			return false
		end
		local total = ma.total or (ma.winners and #ma.winners) or 0
		local pos = tonumber(ma.pos) or 1
		if pos <= total then
			return false
		end
		announceMultiAwardCompletion(ma)
		clearMultiAwardState(true)
		return true
	end

	local function buildMultiAwardWinners(target)
		local selCount = UI.Selection.GetCount(ROLL_WINNERS_CTX) or 0
		local rollModel
		local picked

		if selCount > 0 then
			rollModel = buildRollUiModel(true)
			picked = getSelectedRollWinnersOrdered(rollModel and rollModel.rows or nil)
		end

		local plan = LootAwardPlanner.BuildMultiAwardWinnersPlan({
			target = target,
			selectedCount = selCount,
			pickedWinners = picked,
		})
		if plan and plan.clearSelection then
			UI.Selection.EnsureState(ROLL_WINNERS_CTX)
			UI.Selection.SetAnchor(ROLL_WINNERS_CTX, nil)
		end
		if plan and plan.errType then
			return nil, plan.errType, plan.wantedCount, plan.pickedCount
		end

		return plan and plan.winners
	end

	local function validateInventoryTradeUiSelection(target)
		local selCount = UI.Selection.GetCount(ROLL_WINNERS_CTX) or 0
		local rollModel
		local picked

		if selCount > 0 then
			rollModel = buildRollUiModel(true)
			picked = getSelectedRollWinnersOrdered(rollModel and rollModel.rows or nil)
		end

		local plan = LootAwardPlanner.ValidateInventoryTradeSelection({
			target = target,
			selectedCount = selCount,
			pickedCount = picked and #picked or 0,
		})
		return plan and plan.ok == true, plan and plan.errType, plan and plan.wantedCount, plan and plan.pickedCount
	end

	local function startMultiAwardSequence(itemLink, available, winners)
		setItemCountValue(#winners, false)
		local candidateSlots, candidateSlotMap = LootInventory.BuildMultiAwardSlotCandidates(itemLink)
		local timeout = tonumber(ML_MULTI_AWARD_TIMEOUT_SECONDS) or 0

		local plan = LootAwardPlanner.BuildMultiAwardState({
			itemLink = itemLink,
			available = available,
			rollType = lootState.currentRollType,
			winners = winners,
			slotCandidates = candidateSlots,
			slotCandidateMap = candidateSlotMap,
			announceOnWin = GetOption("Master", "announceOnWin") == true,
		})
		lootState.multiAward = plan and plan.state or nil
		if addon.hasDebug then
			addon:debug(
				Diag.D.LogMLMultiAwardStarted:format(
					tostring(itemLink),
					#winners,
					available,
					tconcat(candidateSlots, ","),
					timeout
				)
			)
		end

		-- Suppress per-copy ChatAward spam during multi-award; announce once on completion.
		module._announced = true
		return assignItem(itemLink, winners[1].name, lootState.currentRollType, winners[1].roll)
	end

	local function computeTargetAndAvailability()
		local plan = LootAwardPlanner.BuildAwardTargetPlan({
			selectedItemCount = lootState.selectedItemCount,
			availableItemCount = Loot:GetCurrentItemCount(),
			rollsCount = lootState.rollsCount,
		})
		return plan.target, plan.available
	end

	local function tryAwardMultipleCopies(itemLink, target, available)
		local winners, errType, wantedCount, pickedCount = buildMultiAwardWinners(target)
		if errType == "empty_selection" then
			addon:warn(L.ErrNoWinnerSelected)
			Private.ResetItemCount()
			return false
		end
		if errType == "not_enough_selection" then
			addon:warn(Diag.W.ErrMLMultiSelectNotEnough:format(wantedCount or 0, pickedCount or 0))
			Private.ResetItemCount()
			return false
		end
		if errType == "empty_winners" or #winners <= 0 then
			addon:warn(L.ErrNoWinnerSelected)
			Private.ResetItemCount()
			return false
		end

		local result = startMultiAwardSequence(itemLink, available, winners)
		if result then
			registerAwardedItem(1)
			local done = finalizeMultiAwardIfDone()
			if not done and lootState.multiAward and lootState.multiAward.active then
				armMultiAwardProgressTimeout(lootState.multiAward)
			end
			module:RequestRefresh()
			return true
		end

		clearMultiAwardState(true)
		module:RequestRefresh()
		return false
	end

	local function tryAwardSingleCopy(itemLink, winnerName)
		local selectedWinner = winnerName or lootState.winner
		local result =
			assignItem(itemLink, selectedWinner, lootState.currentRollType, Rolls:GetHighestRoll(selectedWinner))
		if result then
			registerAwardedItem(1)
		end
		resetItemCountAndRefresh()
		return result
	end

	local function continueMultiAwardOnLootSlotCleared(clearedSlot)
		local ma = lootState.multiAward
		if not (ma and ma.active and not lootState.fromInventory) then
			return
		end
		local slot = tonumber(clearedSlot)
		if slot then
			ma.lastClearedSlot = slot
		end

		-- Prevent double-scheduling if the loot window fires multiple clear events quickly.
		if ma.scheduled then
			return
		end

		-- Gate: proceed only when the number of copies for this itemKey has decreased since last award.
		local currentCount = Loot:GetLootWindowItemCountByKey(ma.itemKey)
		if ma.lastCount and currentCount >= ma.lastCount then
			return
		end

		ma.waitingForDecrement = false
		cancelMultiAwardTimeout(ma)
		local refreshedSlots, refreshedSlotMap = LootInventory.BuildMultiAwardSlotCandidates(ma.itemLink)
		ma.slotCandidates = refreshedSlots
		ma.slotCandidateMap = refreshedSlotMap
		ma.lastCount = currentCount
		local idx = tonumber(ma.pos) or 1
		local entry = ma.winners and ma.winners[idx]
		if not entry then
			clearMultiAwardState(true)
			module:RequestRefresh()
			return
		end

		ma.scheduled = true
		local delay = tonumber(C.ML_MULTI_AWARD_DELAY) or 0
		if delay < 0 then
			delay = 0
		end

		ma.delayHandle = module:ScheduleTimer(function()
			local ma2 = lootState.multiAward
			if not (ma2 and ma2.active and ma2.scheduled and not lootState.fromInventory) then
				return
			end
			ma2.delayHandle = nil
			ma2.scheduled = false

			local idx2 = tonumber(ma2.pos) or 1
			local e2 = ma2.winners and ma2.winners[idx2]
			if not e2 then
				clearMultiAwardState(true)
				module:RequestRefresh()
				return
			end

			-- Suppress per-copy ChatAward spam during multi-award; announce once on completion.
			module._announced = true
			ma2.currentWinner = e2.name
			lootState.currentRollType = ma2.rollType
			module:RequestRefresh()

			local ok = assignItem(ma2.itemLink, e2.name, ma2.rollType, e2.roll)
			if ok then
				registerAwardedItem(1)
				ma2.pos = idx2 + 1
				local done = finalizeMultiAwardIfDone()
				if not done and lootState.multiAward and lootState.multiAward.active then
					armMultiAwardProgressTimeout(lootState.multiAward)
				end
				module:RequestRefresh()
			else
				clearMultiAwardState(true)
				module:RequestRefresh()
			end
		end, delay)
	end

	-- ============================================================================
	-- Award request / trade-state helpers
	-- ============================================================================
	local function handleAwardRequest()
		local model = buildRollUiModel(true) or {}
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
			resetRollWinnerSelection(ROLL_SELECTION_MODE.AUTO)
			Announce(Chat, L.ChatTieReroll:format(tconcat(rerollNames or {}, ", "), Loot.GetItemLink() or ""))
			Loot:SetDistributionState("tie_start", {
				itemLink = Loot.GetItemLink(),
				names = rerollNames,
			})
			Loot:SetDistributionState("roll_start", {
				itemLink = Loot.GetItemLink(),
				rollType = lootState.currentRollType,
			})
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
			local result = tradeItem(itemLink, winnerName, lootState.currentRollType, Rolls:GetHighestRoll(winnerName))
			resetItemCountAndRefresh()
			return result
		end

		local target, available = module._awardFlow.computeTargetAndAvailability()
		if available > 1 then
			return module._awardFlow.tryMultipleCopies(itemLink, target, available)
		end

		return module._awardFlow.trySingleCopy(itemLink, winnerName)
	end

	module._awardFlow.computeTargetAndAvailability = computeTargetAndAvailability
	module._awardFlow.tryMultipleCopies = tryAwardMultipleCopies
	module._awardFlow.trySingleCopy = tryAwardSingleCopy
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
		UI.Widgets.Call("TradeMenu", "HideDropdowns")
		module:RequestRefresh()
	end

	local function scheduleManualTradeCloseSettle()
		cancelManualTradeCloseSettle()
		if not MasterService.Trade.HasClosePending() then
			MasterService.Trade.Reset(true, true)
			UI.Widgets.Call("TradeMenu", "HideDropdowns")
			return false
		end

		UI.Widgets.Call("TradeMenu", "HideDropdowns")
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
			UI.Widgets.Call("TradeMenu", "HideDropdowns")
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
				if module._selectionFrame then
					module._selectionFrame:Hide()
				end
			end,
		}) or uiState.FrameName
		if not uiState.FrameName then
			return
		end
		uiState.Loaded = true
		UI.Widgets.Call("LootCounter", "AttachToMaster", frame)
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
			if lootState.opened == true then
				Loot:FetchLoot()
			end
		else
			updateSelectionFrame()
			if module._selectionFrame then
				Primitives.Toggle(module._selectionFrame)
			end
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
		local plan = MasterService.LootSpam.BuildPlan({
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
			UI.Widgets.Call("Reserves", "Toggle")
		else
			UI.Widgets.Call("Reserves", "ToggleImport")
		end
	end

	-- Button: Loot Counter
	Private.BtnLootCounter = function(_btn, _button)
		UI.Widgets.Call("LootCounter", "Toggle")
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

			local plan = MasterService.RollAnnouncements.BuildPlan({
				chatKey = chatMsg,
				itemLink = itemLink,
				rollType = rollType,
				selectedItemCount = lootState.selectedItemCount,
				sortAscending = GetOption("Master", "sortAscending") == true,
				srList = srList,
			})
			local message = plan and plan.message or nil

			Announce(Chat, message)
			Loot:SetDistributionState("roll_start", {
				itemLink = itemLink,
				rollType = rollType,
			})
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
			ok = tradeItem(itemLink, target, rollType, 0)
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
			local duration = tonumber(GetOption("Rolls", "countdownDuration")) or 0
			if duration <= 0 then
				finalizeRollSession()
				return
			end
			Rolls:SetRollRecordingEnabled(true)
			module._announced = false
			startCountdown()
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

	-- Selects an item from the item selection frame.
	Private.BtnSelectedItem = function(btn, _button)
		if not btn then
			return
		end
		local index = btn:GetID()
		if index ~= nil then
			module._announced = false
			module._selectionFrame:Hide()
			Loot:SelectItem(index)
			resetItemCountAndRefresh()
		end
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
		prepareDropDowns()
		UIDropDownMenu_Initialize(module._dropDownFrameHolder, initializeDropDowns)
		UIDropDownMenu_Initialize(module._dropDownFrameBanker, initializeDropDowns)
		UIDropDownMenu_Initialize(module._dropDownFrameDisenchanter, initializeDropDowns)
		configureAssignDropDown(module._dropDownFrameHolder)
		configureAssignDropDown(module._dropDownFrameBanker)
		configureAssignDropDown(module._dropDownFrameDisenchanter)
		module._dropDownsInitialized = true
		hookDropDownOpen(module._dropDownFrameHolder, "holder")
		hookDropDownOpen(module._dropDownFrameBanker, "banker")
		hookDropDownOpen(module._dropDownFrameDisenchanter, "disenchanter")
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

		invalidateRollUiModel()
		local rollModel = buildRollUiModel() or {}
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
	-- Initializes the dropdown menus for player selection.
	function initializeDropDowns()
		if UIDROPDOWNMENU_MENU_LEVEL == 2 then
			local g = UIDROPDOWNMENU_MENU_VALUE
			local m = module._dropDownData[g]
			for key in pairs(m) do
				local info = UIDropDownMenu_CreateInfo()
				info.hasArrow = false
				info.notCheckable = 1
				info.text = key
				info.func = Private.OnClickDropDown
				info.arg1 = UIDROPDOWNMENU_OPEN_MENU
				info.arg2 = key
				UIDropDownMenu_AddButton(info, UIDROPDOWNMENU_MENU_LEVEL)
			end
		end
		if UIDROPDOWNMENU_MENU_LEVEL == 1 then
			for key in pairs(module._dropDownData) do
				if module._dropDownGroupData[key] == true then
					local info = UIDropDownMenu_CreateInfo()
					info.hasArrow = 1
					info.notCheckable = 1
					info.text = GROUP .. " " .. key
					info.value = key
					info.owner = UIDROPDOWNMENU_OPEN_MENU
					UIDropDownMenu_AddButton(info, UIDROPDOWNMENU_MENU_LEVEL)
				end
			end
		end
	end

	-- Prepares the data for the dropdowns by fetching the raid roster.
	function prepareDropDowns()
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
			local t = module._dropDownData[i]
			if t then
				twipe(t)
			else
				t = {}
				module._dropDownData[i] = t
			end
		end

		module._dropDownGroupData = module._dropDownGroupData or {}
		twipe(module._dropDownGroupData)

		for unit in addon.UnitIterator(true) do
			local name = UnitName(unit)
			if name and name ~= "" then
				local subgroup = 1

				-- If we are in raid, resolve the real subgroup.
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

	local function getRaidGridPlayerClass(name)
		if Raid and Raid.GetPlayerClass then
			return Raid:GetPlayerClass(name)
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
		if addon.UnitIterator then
			for unit in addon.UnitIterator(true) do
				local name = UnitName(unit)
				if name and name ~= "" and not seen[name] then
					local className = Raid and Raid.GetPlayerClass and Raid:GetPlayerClass(name) or nil
					if not className and UnitClass then
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
		end
		return result
	end

	Private.HideBlizzardDropDownLists = function()
		if type(CloseDropDownMenus) == "function" then
			CloseDropDownMenus()
		end
		for i = 1, 2 do
			local list = _G["DropDownList" .. i]
			if list and list.Hide then
				list:Hide()
			end
		end
		UIDROPDOWNMENU_OPEN_MENU = nil
	end

	Private.QueueHideBlizzardDropDownLists = function()
		Private.HideBlizzardDropDownLists()
		if module.ScheduleTimer then
			module:ScheduleTimer(Private.HideBlizzardDropDownLists, 0)
		end
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
			UI.Widgets.Call("RaidGrid", "Hide")
		end
		return ok
	end

	Private.EnsureRaidGridConfirmPopup = function()
		if IsPopupDefined("RMA_MASTER_LOOT_GRID_CONFIRM") then
			return true
		end

		return DefinePopup("RMA_MASTER_LOOT_GRID_CONFIRM", {
			text = L.PopupRaidGridConfirm or "Give %s to %s?",
			button1 = YES or OKAY,
			button2 = NO or CANCEL,
			timeout = 0,
			whileDead = 1,
			hideOnEscape = 1,
			OnAccept = function(_, data)
				Private.AcceptManualGridAward(data)
			end,
		})
	end

	Private.ShowManualGridAwardConfirm = function(itemLink, playerName)
		if not Private.EnsureRaidGridConfirmPopup() then
			return false
		end

		local data = {
			itemLink = itemLink,
			itemText = itemLink or L.StrRaidGridTitle,
			playerName = playerName,
		}
		return ShowPopup("RMA_MASTER_LOOT_GRID_CONFIRM", data.itemText, playerName, data)
	end

	Private.HandleManualGridEntry = function(entry)
		if type(entry) ~= "table" or not entry.name then
			return false
		end

		local itemLink = Private.GetSelectedMasterLootLink()
		if not itemLink then
			return false
		end

		local threshold = MASTER_LOOT_THREHOLD or MASTER_LOOT_THRESHOLD or 4
		if Private.GetSelectedMasterLootQuality() >= threshold then
			return Private.ShowManualGridAwardConfirm(itemLink, entry.name)
		end
		return Private.AcceptManualGridAward({
			itemLink = itemLink,
			playerName = entry.name,
		})
	end

	Private.OpenManualAwardGrid = function()
		if Raid and Raid.IsMasterLooter and not Raid:IsMasterLooter() then
			return false
		end
		Private.QueueHideBlizzardDropDownLists()

		local itemLink = Private.GetSelectedMasterLootLink()
		local title = itemLink or L.StrRaidGridTitle
		local entries =
			MasterService.AssignmentCandidates.BuildRows(collectMasterLootCandidates(), getRaidGridPlayerClass)
		local debugState = feature.coreState and feature.coreState.debug or nil
		local debugFallback = false
		if #entries <= 0 and MasterService.DebugRaidGrid.IsFallbackEnabled(debugState, isDebugEnabled()) then
			local count = MasterService.DebugRaidGrid.GetTargetCount(debugState)
			entries = MasterService.DebugRaidGrid.BuildRows(count, collectRaidGridRosterRows())
			title = title .. " (" .. (L.StrRaidGridDebugTitle or "Debug") .. ")"
			debugFallback = true
		end
		UI.Widgets.Call("RaidGrid", "ShowPicker", {
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
			end or Private.HandleManualGridEntry,
		})
		return true
	end

	Private.OpenDebugRaidGrid = function(count)
		local debugState = feature.coreState and feature.coreState.debug or nil
		if not debugState then
			feature.coreState.debug = {}
			debugState = feature.coreState.debug
		end
		debugState.raidGridTargetCount = count or 25

		local entries, total = MasterService.DebugRaidGrid.BuildRows(count, collectRaidGridRosterRows())
		UI.Widgets.Call("RaidGrid", "ShowPicker", {
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

	Private.RefreshManualAwardGrid = function()
		if UI.Widgets.Call("RaidGrid", "IsShown") and UI.Widgets.Call("RaidGrid", "GetMode") == "award" then
			return Private.OpenManualAwardGrid()
		end
		return false
	end

	-- Dropdown field metadata: maps frame name suffixes to state keys (lazily bound at runtime).
	local function findDropDownField(frameNameFull)
		if not frameNameFull then
			return nil
		end

		-- Match dropdown frame name to find the field type
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
			return { stateKey = "disenchanter", raidKey = "disenchanter", frame = module._dropDownFrameDisenchanter }
		end
		return nil
	end

	Private.GetAssignmentFieldByKey = function(targetKey)
		if targetKey == "holder" then
			return { stateKey = "holder", raidKey = "holder", frame = module._dropDownFrameHolder, label = L.BtnHold }
		elseif targetKey == "banker" then
			return { stateKey = "banker", raidKey = "banker", frame = module._dropDownFrameBanker, label = L.BtnBank }
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

	Private.SetAssignmentTarget = function(targetKey, playerName)
		if not playerName or playerName == "" then
			return false
		end

		local field = Private.GetAssignmentFieldByKey(targetKey)
		if not field then
			return false
		end

		local raidStore = Database.GetRaidStoreOrNil("Master.SetAssignmentTarget", { "GetRaidByIndex" })
		local raidId = Database.GetCurrentRaid()
		local raid = raidStore and raidId and raidStore:GetRaidByIndex(raidId) or nil
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
		UI.Widgets.Call("RaidGrid", "Hide")
		module:RequestRefresh()
		return true
	end

	Private.OpenAssignmentTargetGrid = function(targetKey)
		local field = Private.GetAssignmentFieldByKey(targetKey)
		if not field then
			return false
		end

		Private.QueueHideBlizzardDropDownLists()
		if prepareDropDowns then
			prepareDropDowns()
		end

		local title = L.StrRaidGridTargetTitle
		if field.label then
			title = title .. ": " .. field.label
		end

		UI.Widgets.Call("RaidGrid", "ShowPicker", {
			mode = "target",
			title = title,
			emptyText = L.StrRaidGridEmpty,
			entries = MasterService.AssignmentTargets.BuildRows(module._dropDownData, getRaidGridPlayerClass),
			anchor = field.frame or getFrame(),
			onSelect = function(entry)
				return Private.SetAssignmentTarget(targetKey, entry and entry.name)
			end,
		})
		return true
	end

	-- OnClick handler for dropdown menu items (consolidated from 3 similar branches).
	Private.OnClickDropDown = function(_button, owner, value)
		if not owner or not value or not Database.GetCurrentRaid() then
			return
		end

		local field = findDropDownField(owner:GetName())
		if field then
			Private.SetAssignmentTarget(field.stateKey, value)
			return
		end

		UIDropDownMenu_SetText(owner, value)
		UIDropDownMenu_SetSelectedValue(owner, value)
		module._dropDownDirty = true
		module._dirtyFlags.dropdowns = true
		module._dirtyFlags.buttons = true
		CloseDropDownMenus()
		module:RequestRefresh()
	end

	-- Updates the text of the dropdowns to reflect the current selection (consolidated from 3 similar branches).
	function updateDropDowns(frame)
		if not frame or not Database.GetCurrentRaid() then
			return
		end

		local field = findDropDownField(frame:GetName())
		if not field then
			return
		end

		-- Sync state from raid data
		local raidStore = Database.GetRaidStoreOrNil("Master.UpdateDropDowns", { "GetRaidByIndex" })
		local raid = raidStore and raidStore:GetRaidByIndex(Database.GetCurrentRaid()) or nil
		if not raid then
			return
		end
		lootState[field.stateKey] = raid[field.raidKey]

		-- Clear if unit is no longer in raid
		if lootState[field.stateKey] and Raid:GetUnitID(lootState[field.stateKey]) == "none" then
			raid[field.raidKey] = nil
			lootState[field.stateKey] = nil
		end

		-- Update UI if value is valid
		if lootState[field.stateKey] then
			UIDropDownMenu_SetText(field.frame, lootState[field.stateKey])
			UIDropDownMenu_SetSelectedValue(field.frame, lootState[field.stateKey])
			module._dirtyFlags.buttons = true
		end
	end

	local function getSelectionButtonRefs(btn)
		return GetNamedParts(btn, {
			name = "Name",
			icon = "Icon",
		})
	end

	local function anchorSelectionFrame()
		if not module._selectionFrame then
			return
		end
		local selectItemBtn = getNamedPart("SelectItemBtn")
		if not selectItemBtn then
			return
		end
		if module._selectionFrame.ClearAllPoints then
			module._selectionFrame:ClearAllPoints()
		end
		if module._selectionFrame.SetPoint then
			module._selectionFrame:SetPoint("TOPLEFT", selectItemBtn, "BOTTOMLEFT", 0, -3)
		end
	end

	local function ensureSelectionButton(index)
		local frameName = getFrameName()
		if not frameName then
			return nil
		end
		local btn = module._selectionButtons[index]
		if btn then
			return btn
		end

		local btnName = frameName .. "ItemSelectionBtn" .. index
		btn = CreateFrame("Button", btnName, module._selectionFrame, "RMAItemSelectionButton")
		btn:SetID(index)
		if btn.RegisterForClicks then
			btn:RegisterForClicks("AnyUp")
		end
		SetScriptSafely(btn, "OnClick", function(self, button)
			Private.BtnSelectedItem(self, button)
		end)
		module._selectionButtons[index] = btn
		return btn
	end

	local function createSelectionFrame()
		if module._selectionFrame == nil then
			local frame = getFrame()
			if not frame then
				return
			end
			local frameName = getFrameName()
			local selectionName = frameName and (frameName .. "ItemSelectionFrame") or nil
			module._selectionFrame = CreateFrame("Frame", selectionName, frame, "RMAItemSelectionFrame")
			module._selectionFrame:Hide()
		end
		anchorSelectionFrame()
		for i = 1, #module._selectionButtons do
			local btn = module._selectionButtons[i]
			if btn then
				btn:Hide()
			end
		end
	end

	-- Updates the item selection frame with the current loot items.
	function updateSelectionFrame()
		createSelectionFrame()
		if not module._selectionFrame then
			return
		end

		local height = 5
		for i = 1, lootState.lootCount do
			local btn = ensureSelectionButton(i)
			if btn then
				local ui = getSelectionButtonRefs(btn)
				btn:Show()
				local itemName = Loot.GetItemName(i)
				local itemNameBtn = ui and ui.name or nil
				local item = Loot.GetItem(i)
				local count = item and item.count or 1
				if itemNameBtn then
					if count and count > 1 then
						itemNameBtn:SetText(itemName .. " x" .. count)
					else
						itemNameBtn:SetText(itemName)
					end
				end
				local itemTexture = Loot.GetItemTexture(i)
				local itemTextureBtn = ui and ui.icon or nil
				if itemTextureBtn then
					itemTextureBtn:SetTexture(itemTexture)
				end
				btn:SetPoint("TOPLEFT", module._selectionFrame, "TOPLEFT", 0, -height)
				height = height + 37
			end
		end
		for i = lootState.lootCount + 1, #module._selectionButtons do
			local btn = module._selectionButtons[i]
			if btn then
				btn:Hide()
			end
		end
		module._selectionFrame:SetHeight(height)
		if lootState.lootCount <= 0 then
			module._selectionFrame:Hide()
		end
	end

	-- ----- Event Handlers & Callbacks ----- --

	-- ============================================================================
	-- Inventory / cursor helpers
	-- ============================================================================
	local function applyInventoryItem(itemLink, totalCount, inBag, inSlot, slotCount)
		if isCountdownRunning() then
			return false
		end
		if not itemLink then
			return false
		end
		local itemCount = tonumber(totalCount) or 1
		if itemCount < 1 then
			itemCount = 1
		end

		-- Clear count:
		local itemCountBox = getNamedPart("ItemCount")
		if itemCountBox then
			UI.EditBoxes.Reset(itemCountBox, true)
		end

		lootState.fromInventory = true
		Loot:AddItem(itemLink, itemCount)
		Loot:PrepareItem()
		module._announced = false

		itemInfo.bagID = inBag
		itemInfo.slotID = inSlot
		itemInfo.count = itemCount
		itemInfo.isStack = (tonumber(slotCount) or 1) > 1

		ClearCursor()
		resetItemCountAndRefresh(true)
		return true
	end

	-- Accept an item currently held on the cursor (bag click-pickup).
	-- This is triggered by ItemBtn's OnClick.
	Private.TryAcceptInventoryItemFromCursor = function()
		if isCountdownRunning() then
			return false
		end
		if not CursorHasItem or not CursorHasItem() then
			return false
		end

		local infoType, itemId, itemLink = GetCursorInfo()
		if infoType ~= "item" then
			return false
		end

		local totalCount, bag, slot, slotCount, hasMatch = LootInventory.FindTradeableInventoryMatch(itemLink, itemId)
		if not totalCount or totalCount < 1 then
			local itemRef = tostring(itemLink or itemId or "unknown")
			if hasMatch then
				addon:warn(L.ErrMLInventorySoulbound:format(itemRef))
				if addon.hasDebug then
					addon:debug(Diag.D.LogMLInventorySoulbound:format(itemRef))
				end
			else
				addon:warn(L.ErrMLInventoryItemMissing:format(itemRef))
			end
			ClearCursor()
			return true
		end

		if not itemLink and bag and slot then
			itemLink = GetContainerItemLink(bag, slot)
		end
		if not itemLink then
			addon:warn(L.ErrMLInventoryItemMissing:format(tostring(itemLink or itemId or "unknown")))
			ClearCursor()
			return true
		end

		return applyInventoryItem(itemLink, totalCount, bag, slot, slotCount)
	end

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
		Loot:PurgePendingAwards(PENDING_AWARD_TTL_SECONDS)
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
		UI.Widgets.Call("LootHints", "ApplyLootFrameReserveHints")
		if canHandleLootWindow() then
			local debugEnabled = isDebugEnabled()
			local raidNum = Database.GetCurrentRaid()
			if Raid.ClearLootWindowBossContext then
				Raid:ClearLootWindowBossContext()
			end
			lootState.opened = true
			module._announced = false
			local perfStep = addon.hasPerf and addon:_PerfStart() or nil
			Loot:SetDistributionState("session")
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
				updateSelectionFrame()
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
		UI.Widgets.Call("RaidGrid", "Hide")
		UI.Widgets.Call("LootHints", "ClearLootFrameReserveHints")
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

	-- LOOT_SLOT_CLEARED: Triggered when an item is looted.
	function module:LOOT_SLOT_CLEARED(clearedSlot)
		local perfTotal = addon.hasPerf and addon:_PerfStart() or nil
		UI.Widgets.Call("LootHints", "ApplyLootFrameReserveHints")
		if canHandleLootWindow() then
			module._PendingCounter:Confirm(clearedSlot, "LOOT_SLOT_CLEARED")
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
				updateSelectionFrame()
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
				continueMultiAwardOnLootSlotCleared(clearedSlot)
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
		if module._PendingCounter:HasPending() and module._PendingCounter:IsFailureMessage(message) then
			failed = module._PendingCounter:Fail(message) or failed
		end
		failed = failManualTrade(message) or failed
		if failed then
			module:RequestRefresh()
		end
	end

	function module:UI_INFO_MESSAGE(arg1, arg2)
		local message = arg2 or arg1
		if failManualTrade(message) then
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
		if lootState.trader and tradeWinner and lootState.trader ~= tradeWinner then
			if playerAccepted == 1 and targetAccepted == 1 then
				local awardedCount = LootInventory.ResolveTradeAwardedCount()
				local rollValue = Rolls:GetHighestRoll(tradeWinner)
				local lootNid, createdTradeOnly = ensureTradeLootContext(
					lootState.tradeItemLink or Loot.GetItemLink(),
					tradeWinner,
					lootState.currentRollType,
					rollValue,
					awardedCount,
					"TRADE_ACCEPT_NO_CONTEXT"
				)
				if lootNid > 0 and createdTradeOnly then
					addon:warn(
						Diag.W.LogTradeNoLootContextTradeOnly:format(
							tostring(lootNid),
							tostring(tradeWinner),
							tostring(lootState.tradeItemLink or Loot.GetItemLink()),
							awardedCount
						)
					)
				end

				if addon.hasDebug then
					addon:debug(
						Diag.D.LogTradeCompleted:format(
							tostring(lootState.currentRollItem),
							tostring(tradeWinner),
							tonumber(lootState.currentRollType) or -1,
							rollValue
						)
					)
				end
				if lootNid > 0 then
					local ok = requestLoggerLootLog(
						lootNid,
						tradeWinner,
						lootState.currentRollType,
						rollValue,
						"TRADE_ACCEPT",
						Database.GetCurrentRaid()
					)

					if not ok then
						addon:error(
							Diag.E.LogTradeLoggerLogFailed:format(
								tostring(Database.GetCurrentRaid()),
								tostring(lootNid),
								tostring(lootState.tradeItemLink or Loot.GetItemLink())
							)
						)
					end
				else
					addon:warn(
						Diag.W.LogTradeCurrentRollItemMissingContext:format(
							tostring(tradeWinner),
							tostring(lootState.tradeItemId),
							tostring(lootState.tradeItemLink or Loot.GetItemLink())
						)
					)
				end

				local completedWinner = tradeWinner
				Loot:SetDistributionState("item_done", {
					itemLink = lootState.tradeItemLink or Loot.GetItemLink(),
					winnerName = completedWinner,
				})
				completeInventoryAwardProgress(completedWinner, lootState.currentRollType, awardedCount)
				RMATradeHandled = true
			end
		end
		if not RMATradeHandled then
			local _, manualState = MasterService.Trade.ApplyAccept(playerAccepted, targetAccepted, isAddonDrivenTrade)
			if manualState then
				UI.Widgets.Call("TradeMenu", "RefreshDropdowns", manualState)
			end
		end
	end

	function module:TRADE_SHOW()
		cancelManualTradeCloseSettle()
		MasterService.Trade.Reset(true, false)
		UI.Widgets.Call("TradeMenu", "RefreshCandidate", "TRADE_SHOW")
	end

	function module:TRADE_PLAYER_ITEM_CHANGED()
		UI.Widgets.Call("TradeMenu", "RefreshCandidate", "TRADE_PLAYER_ITEM_CHANGED")
	end

	function module:TRADE_TARGET_ITEM_CHANGED()
		UI.Widgets.Call("TradeMenu", "RefreshCandidate", "TRADE_TARGET_ITEM_CHANGED")
	end

	-- TRADE_CLOSED: trade window closed (completed or canceled)
	function module:TRADE_CLOSED()
		scheduleManualTradeCloseSettle()
		handleTradeClosedOrCancelled()
	end

	-- TRADE_REQUEST_CANCEL: trade request canceled before opening
	function module:TRADE_REQUEST_CANCEL()
		cancelManualTradeCloseSettle()
		MasterService.Trade.Reset(true, false)
		UI.Widgets.Call("TradeMenu", "HideDropdowns")
		handleTradeClosedOrCancelled()
	end

	-- ============================================================================
	-- Assignment / trade execution
	-- ============================================================================
	-- Assigns an item from the loot window to a player.
	function assignItem(itemLink, playerName, rollType, rollValue)
		local itemIndex = LootInventory.FindLootSlotIndex(itemLink)
		if itemIndex == nil then
			addon:error(L.ErrCannotFindItem:format(itemLink))
			return false
		end

		if not (Raid and Raid.IsMasterLooter and Raid:IsMasterLooter()) then
			addon:warn(L.WarnMLNoPermission)
			refreshCandidateUiState()
			module:RequestRefresh()
			return false
		end

		local validation = Rolls:ValidateWinner(playerName, itemLink, rollType)
		if not (validation and validation.ok == true) then
			addon:warn((validation and validation.warnMessage) or L.ErrMLWinnerIneligible:format(tostring(playerName)))
			refreshCandidateUiState()
			module:RequestRefresh()
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
			Loot:AddPendingAward(itemLink, playerName, rollType, rollValue, session and session.id or nil, nil, {
				counterApplied = true,
			})
			module._PendingCounter:Queue(
				itemLink,
				itemIndex,
				playerName,
				rollType,
				rollValue,
				session and session.id or nil
			)
			GiveMasterLoot(itemIndex, candidateIndex)
			Loot:SetDistributionState("roll_end", {
				itemLink = itemLink,
				winnerName = playerName,
				rollValue = rollValue,
				reason = "master_loot",
			})
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

			if output and not module._announced then
				Announce(Chat, output)
				module._announced = true
			end
			if whisper then
				Comms.SendWhisper(playerName, whisper)
			end
			-- IMPORTANT:
			-- Do NOT force-update an existing raid.loot entry here.
			-- For Master Loot awards from the loot window, the authoritative record is created by Loot:AddLoot()
			-- (also reachable through Raid:AddLoot facade)
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
		return false
	end

	-- ============================================================================
	-- Trade / inventory execution helpers
	-- ============================================================================
	do
		Private.ResolveTradeExecutionWinner = function(playerName, isAwardRoll)
			if not isAwardRoll then
				return nil
			end

			local winnerModel = buildRollUiModel and buildRollUiModel() or nil
			local winner = playerName or Rolls:GetResolvedWinner(winnerModel)
			local multiInventoryAward = lootState.fromInventory and ((tonumber(lootState.selectedItemCount) or 1) > 1)
			if multiInventoryAward then
				local rollModel = buildRollUiModel(true)
				local picked = getSelectedRollWinnersOrdered(rollModel and rollModel.rows or nil)
				if picked[1] and picked[1].name then
					winner = picked[1].name
				end
			end

			return winner
		end

		advanceInventoryWinnerSelection = function(completedWinner)
			if not lootState.fromInventory then
				return
			end
			if (tonumber(lootState.selectedItemCount) or 1) <= 1 then
				return
			end

			local selCount = UI.Selection.GetCount(ROLL_WINNERS_CTX) or 0
			if selCount <= 0 then
				lootState.winner = nil
				return
			end

			if completedWinner and UI.Selection.IsSelected(ROLL_WINNERS_CTX, completedWinner) then
				UI.Selection.Toggle(ROLL_WINNERS_CTX, completedWinner, true)
				if UI.Selection.GetAnchor and UI.Selection.GetAnchor(ROLL_WINNERS_CTX) == completedWinner then
					UI.Selection.SetAnchor(ROLL_WINNERS_CTX, nil)
				end
			end

			invalidateRollUiModel()
			local rollModel = buildRollUiModel()
			lootState.winner = rollModel and rollModel.winner or nil
		end

		completeInventoryAwardProgress = function(completedWinner, rollType, awardedCount)
			if completedWinner and completedWinner ~= "" then
				Raid:AddPlayerCountForRollType(completedWinner, rollType, awardedCount, Database.GetCurrentRaid())
			end

			local done = registerAwardedItem(awardedCount)
			resetTradeState()
			if not done then
				advanceInventoryWinnerSelection(completedWinner)
			end
			if done then
				Loot:ClearLoot()
				Raid:ClearRaidIcons()
			end
			module._screenshotWarn = false
			module:RequestRefresh()
			return done
		end

		Private.PrepareTradeableItem = function(itemLink)
			local itemData = LootInventory.ResolveTradeableInventoryItem(
				itemLink,
				itemInfo.bagID,
				itemInfo.slotID,
				lootState.selectedItemCount
			)
			if not itemData then
				addon:warn(L.ErrMLInventoryItemMissing:format(tostring(itemLink)))
				return false
			end

			itemInfo.bagID = itemData.bag
			itemInfo.slotID = itemData.slot
			itemInfo.slotCount = itemData.slotCount
			itemInfo.isStack = itemData.slotCount > 1
			itemInfo.count = itemData.totalCount

			local ignoreStacks = GetOption("Loot", "ignoreStacks") == true
			if itemInfo.isStack and not ignoreStacks then
				if addon.hasDebug then
					addon:debug(Diag.D.LogTradeStackBlocked:format(tostring(ignoreStacks), tostring(itemLink)))
				end
				addon:warn(L.ErrItemStack:format(itemLink))
				return false
			end

			return true
		end

		Private.TryInitiateTrade = function(itemLink, playerName, isAwardRoll)
			local unit = Raid:GetUnitID(playerName)
			if unit == "none" then
				return true, nil
			end

			if CheckInteractDistance(unit, 2) ~= 1 then
				addon:warn(Diag.W.LogTradeDelayedOutOfRange:format(tostring(playerName), tostring(itemLink)))
				Raid:ClearRaidIcons()
				SetRaidTarget(lootState.trader, 1)
				if isAwardRoll then
					SetRaidTarget(playerName, 4)
				end
				return true, L.ChatTrade:format(playerName, itemLink)
			end

			if not Private.PrepareTradeableItem(itemLink) then
				return false, nil
			end

			local _, startCount = GetContainerItemInfo(itemInfo.bagID, itemInfo.slotID)
			itemInfo.tradeStartCount = tonumber(startCount) or tonumber(itemInfo.slotCount) or 1
			itemInfo.tradeStartBag = itemInfo.bagID
			itemInfo.tradeStartSlot = itemInfo.slotID
			itemInfo.tradeStartItemLink = GetContainerItemLink(itemInfo.bagID, itemInfo.slotID)

			ClearCursor()
			PickupContainerItem(itemInfo.bagID, itemInfo.slotID)
			if CursorHasItem() then
				InitiateTrade(playerName)
				if addon.hasDebug then
					addon:debug(Diag.D.LogTradeInitiated:format(tostring(itemLink), tostring(playerName)))
				end
				if GetOption("Master", "screenReminder") and not module._screenshotWarn then
					addon:warn(L.ErrScreenReminder)
					module._screenshotWarn = true
				end
			end

			return true, nil
		end

		Private.FinalizeTradeNotifications = function(itemLink, playerName, rollType, rollValue, output, whisper)
			if module._announced then
				return true
			end

			if output then
				Announce(Chat, output)
			end
			if whisper then
				if playerName == lootState.trader then
					clearLootAndResetRecordedRolls()
				else
					Comms.SendWhisper(playerName, whisper)
				end
			end
			module._announced = true
			return true
		end

		Private.BeginTradeItemState = function(itemLink, playerName, rollType, rollValue, isAwardRoll)
			MasterService.Trade.Reset(true, false)
			UI.Widgets.Call("TradeMenu", "HideDropdowns")
			Rolls:EnsureLootRollSession(
				itemLink,
				rollType,
				lootState.fromInventory and "inventory" or "lootWindow",
				buildLootRollSessionOptions()
			)

			resetTradeState()

			lootState.trader = Database.GetPlayerName()
			local winnerName = Private.ResolveTradeExecutionWinner(playerName, isAwardRoll)
			lootState.tradeItemLink = itemLink
			lootState.tradeItemId = Item.GetItemIdFromLink(itemLink)

			if isAwardRoll and (not winnerName or winnerName == "") then
				addon:warn(L.ErrNoWinnerSelected)
				resetTradeState()
				return false, nil
			end
			if isAwardRoll then
				local validation = Rolls:ValidateWinner(winnerName, itemLink, rollType)
				if not (validation and validation.ok == true) then
					addon:warn(
						(validation and validation.warnMessage) or L.ErrMLWinnerIneligible:format(tostring(winnerName))
					)
					resetTradeState()
					return false, nil
				end
			end
			lootState.tradeWinner = winnerName
			if isAwardRoll then
				Loot:SetDistributionState("roll_end", {
					itemLink = itemLink,
					winnerName = winnerName,
					rollValue = rollValue,
					reason = "inventory_trade",
				})
			end

			if addon.hasDebug then
				addon:debug(
					Diag.D.LogTradeStart:format(
						tostring(itemLink),
						tostring(lootState.trader),
						tostring(winnerName or playerName),
						tonumber(rollType) or -1,
						tonumber(rollValue) or 0,
						lootState.selectedItemCount or 1
					)
				)
			end

			return true, winnerName
		end

		Private.ApplyTradeMarkerPlan = function(markerPlan)
			if type(markerPlan) ~= "table" then
				return
			end
			if markerPlan.clearRaidIcons then
				Raid:ClearRaidIcons()
			end
			local raidTargets = markerPlan.raidTargets
			if type(raidTargets) ~= "table" then
				return
			end
			for i = 1, #raidTargets do
				local target = raidTargets[i]
				if target and target.name and target.icon then
					SetRaidTarget(target.name, target.icon)
				end
			end
		end

		Private.BuildTradeUiNotificationPlan = function(itemLink, playerName, winnerName, rollType, isAwardRoll)
			local selectedWinners
			local fallbackRolls
			if isAwardRoll and (tonumber(lootState.selectedItemCount) or 1) > 1 then
				local rollModel = buildRollUiModel(true)
				selectedWinners = getSelectedRollWinnersOrdered(rollModel and rollModel.rows or nil)
				fallbackRolls = Rolls:GetRolls()
			end

			local plan = LootAwardPlanner.BuildTradeNotificationPlan({
				itemLink = itemLink,
				playerName = playerName,
				winnerName = winnerName,
				rollType = rollType,
				isAwardRoll = isAwardRoll,
				selectedItemCount = lootState.selectedItemCount,
				traderName = lootState.trader,
				selectedWinners = selectedWinners,
				fallbackRolls = fallbackRolls,
				raidTargetMarkers = RAID_TARGET_MARKERS,
				options = {
					announceOnWin = GetOption("Master", "announceOnWin") == true,
					announceOnHold = GetOption("Master", "announceOnHold") == true,
					announceOnBank = GetOption("Master", "announceOnBank") == true,
					announceOnDisenchant = GetOption("Master", "announceOnDisenchant") == true,
				},
			})

			Private.ApplyTradeMarkerPlan(plan and plan.markerPlan)
			return plan and plan.keep, plan and plan.output, plan and plan.whisper
		end

		Private.CompleteTraderKeepAward = function(itemLink, winnerName, rollType, rollValue, output, whisper)
			if addon.hasDebug then
				addon:debug(Diag.D.LogTradeTraderKeeps:format(tostring(itemLink), tostring(winnerName)))
			end
			local awardedCount =
				LootInventory.ResolveInventoryAwardedCountFromArgs(lootState.selectedItemCount, lootState.fromInventory)
			local lootNid, createdTradeOnly =
				ensureTradeLootContext(itemLink, winnerName, rollType, rollValue, awardedCount, "TRADE_KEEP_NO_CONTEXT")
			if lootNid <= 0 then
				addon:error(
					Diag.E.LogTradeKeepLoggerFailed:format(
						tostring(Database.GetCurrentRaid()),
						tostring(lootNid),
						tostring(itemLink)
					)
				)
			elseif createdTradeOnly ~= true then
				local ok = requestLoggerLootLog(
					lootNid,
					winnerName,
					rollType,
					rollValue,
					"TRADE_KEEP",
					Database.GetCurrentRaid()
				)
				if not ok then
					addon:error(
						Diag.E.LogTradeKeepLoggerFailed:format(
							tostring(Database.GetCurrentRaid()),
							tostring(lootNid),
							tostring(itemLink)
						)
					)
				end
			end

			Private.FinalizeTradeNotifications(itemLink, winnerName, rollType, rollValue, output, whisper)
			Loot:SetDistributionState("item_done", {
				itemLink = itemLink,
				winnerName = winnerName,
			})
			completeInventoryAwardProgress(winnerName, rollType, awardedCount)
			return true
		end

		Private.PrepareExternalAwardTrade = function(itemLink, winnerName, isAwardRoll, output)
			local ok, outputOverride = Private.TryInitiateTrade(itemLink, winnerName, isAwardRoll)
			if not ok then
				return false, output
			end
			return true, outputOverride or output
		end

		-- Trades an item from inventory to a player.
		function tradeItem(itemLink, playerName, rollType, rollValue)
			if itemLink ~= Loot.GetItemLink() then
				return
			end
			local isAwardRoll = (rollType and rollType >= rollTypes.MAINSPEC and rollType <= rollTypes.FREE)
			local ok, winnerName = Private.BeginTradeItemState(itemLink, playerName, rollType, rollValue, isAwardRoll)
			if not ok then
				return false
			end

			local keep, output, whisper =
				Private.BuildTradeUiNotificationPlan(itemLink, playerName, winnerName, rollType, isAwardRoll)

			if not keep and lootState.trader == winnerName then
				return Private.CompleteTraderKeepAward(itemLink, winnerName, rollType, rollValue, output, whisper)
			end

			if not keep then
				ok, output = Private.PrepareExternalAwardTrade(itemLink, winnerName, isAwardRoll, output)
				if not ok then
					return false
				end
			end

			return Private.FinalizeTradeNotifications(
				itemLink,
				winnerName or playerName,
				rollType,
				rollValue,
				output,
				whisper
			)
		end
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
			RegisterCallback(GetWowForwarded(methodName), function(_, ...)
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

		RegisterCallback(MasterEvents.RequestGroupLootRestorePrompt, function()
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
		UI.Widgets.Call("LootHints", "ApplyLootFrameReserveHints")
		requestCoalescedUiRefresh("reserves")
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
		invalidateRollUiModel()
		module._dirtyFlags.rolls = true
		module:RequestRefresh()
	end)
end

local registry = feature.ModuleRegistry
if type(registry) == "table" and type(registry.AddModule) == "function" and type(registry.SetLoaded) == "function" then
	registry.AddModule("Controllers/Master", {
		deps = {
			"Init",
			"Modules/ModuleRegistry",
			"Database/DBOptions",
			"Modules/C",
			"Modules/Timer",
			"Modules/Events",
			"Modules/Bus",
			"Modules/Item",
			"Modules/Colors",
			"Modules/Comms",
			"Modules/UI/Facade",
			"Modules/UI/Frames",
			"Modules/UI/Visuals",
			"Modules/UI/ListController",
			"Modules/UI/MultiSelect",
			"Services/Chat",
			"Services/Loot/State",
			"Services/Loot/Service",
			"Services/Loot/Inventory",
			"Services/Loot/AwardPlanner",
			"Services/Rolls/Service",
			"Services/Raid/State",
			"Services/Raid/Capabilities",
			"Services/Raid/Roster",
			"Services/Raid/LootRecords",
			"Services/Raid/LootMethod",
			"Services/Master/FlowState",
			"Services/Master/ButtonState",
			"Services/Master/RollRows",
			"Services/Master/AssignmentCandidates",
			"Services/Master/AssignmentTargets",
			"Services/Master/DebugRaidGrid",
			"Services/Master/AwardMessages",
			"Services/Master/LootSpam",
			"Services/Master/RollAnnouncements",
			"Services/Master/AwardCounter",
			"Services/Master/Trade",
		},
	})
	registry.SetLoaded("Controllers/Master")
end
