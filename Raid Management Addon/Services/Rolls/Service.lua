-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: direct addon namespace bindings
-- exports: publish module APIs on addon.*
-- events: emits AddRoll through History; owns countdown facade calls
local addon = select(2, ...)
local L = addon.L
local Diag = addon.Diag

local Database = addon.Database
local Deformat = addon.Deformat
local Options = addon.Options
local Services = addon.Services
local Strings = addon.Strings

local rollTypes = addon.C.rollTypes

local _, lootState = Database.EnsureLootRuntimeState()
lootState.lootCount = tonumber(lootState.lootCount) or 0
lootState.rollsCount = tonumber(lootState.rollsCount) or 0
lootState.selectedItemCount = tonumber(lootState.selectedItemCount) or 1
if lootState.selectedItemCount < 1 then
	lootState.selectedItemCount = 1
end
lootState.itemTraded = tonumber(lootState.itemTraded) or 0
lootState.currentRollItem = tonumber(lootState.currentRollItem) or 0
if lootState.fromInventory == nil then
	lootState.fromInventory = false
end

local GetItemIndex = Database.GetItemIndex

local tconcat = table.concat

local tostring, tonumber = tostring, tonumber

local function getReserveCountForItem(itemId, name)
	local reserves = Services.Reserves
	if reserves and reserves.GetReserveCountForItem then
		return reserves:GetReserveCountForItem(itemId, name) or 0
	end
	return 0
end

local function getPlusForItem(itemId, name)
	local reserves = Services.Reserves
	if reserves and reserves.GetPlusForItem then
		return reserves:GetPlusForItem(itemId, name) or 0
	end
	return 0
end

local function getItemReserveContext(itemId)
	local reserves = Services.Reserves
	if reserves and reserves.GetItemReserveContext then
		return reserves:GetItemReserveContext(itemId)
	end
	return nil
end

local function isPlusSystemEnabled()
	local reserves = Services.Reserves
	if reserves and reserves.GetPlusForItem and reserves.GetImportMode and reserves.IsPlusSystem then
		return reserves:IsPlusSystem() == true
	end
	return false
end

-- =========== Rolls Helpers Module  =========== --
-- Manages roll tracking, response state, and winner determination.
do
	addon.Services.EnsureNamespace("Rolls")
	local Rolls = Services.Rolls
	local module = Rolls

	-- Namespace registration: options that control countdown and roll-response policy.
	Options.RegisterNamespace("Rolls", {
		countdownDuration = 5,
		countdownSimpleRaidMsg = false,
		countdownRollsBlock = true,
	})

	local Countdown = assert(module._Countdown, "Rolls countdown helpers are not initialized")
	local Sessions = assert(module._Sessions, "Rolls session helpers are not initialized")
	local History = assert(module._History, "Rolls history helpers are not initialized")
	local Responses = assert(module._Responses, "Rolls response helpers are not initialized")
	local Strategies = assert(module._Strategies, "Rolls strategy helpers are not initialized")
	local Display = assert(module._Display, "Rolls display helpers are not initialized")
	local reasonCodes = Responses.REASONS
	-- ----- Internal state ----- --
	local state = {
		record = false,
		canRoll = true,
		warned = false,
		rolled = false,
		rolls = {},
		responsesByPlayer = {},
		deniedReasons = {},
		playerCounts = {},
		itemCounts = nil,
		count = 0,
		resolution = nil,
		sessionId = nil,
		manualExclusions = {},
		tieReroll = nil,
		countdownRunning = false,
		countdownDuration = 0,
		countdownRemaining = 0,
		countdownExpired = false,
		countdownTicker = nil,
		countdownEndTimer = nil,
	}
	local newItemCounts, delItemCounts
	if addon.TablePool then
		newItemCounts, delItemCounts = addon.TablePool("k")
	end
	state.itemCounts = newItemCounts and newItemCounts() or {}
	local GetOption = Options.GetValue
	local IsDebugEnabled = Options.IsDebugEnabled

	-- ----- Private helpers ----- --
	local function logRollRecordState(value)
		if IsDebugEnabled() then
			addon:debug(Diag.D.LogRollsRecordState:format(tostring(value)))
		end
	end

	-- ============================================================================
	-- Session helpers
	-- ============================================================================
	local sessionsContext
	local getCurrentRollItemID

	local function getSessionsContext()
		if sessionsContext then
			return sessionsContext
		end

		sessionsContext = {
			state = state,
			lootState = lootState,
			getItem = function(i)
				local loot = Services.Loot
				return loot and loot.GetItem and loot.GetItem(i) or nil
			end,
			getItemIndex = GetItemIndex,
			getCurrentRollItemID = function()
				return getCurrentRollItemID()
			end,
		}
		return sessionsContext
	end

	local function getRollSession()
		return Sessions.GetRollSession(getSessionsContext())
	end

	local function clearTieRerollFilter()
		Sessions.ClearTieRerollFilter(getSessionsContext())
	end

	local function setTieRerollFilter(names)
		return Sessions.SetTieRerollFilter(getSessionsContext(), names)
	end

	local function isTieRerollRestricted(name)
		return Sessions.IsTieRerollRestricted(getSessionsContext(), name)
	end

	local function getManualExclusionEntry(name)
		return Sessions.GetManualExclusionEntry(getSessionsContext(), name)
	end

	local function getActiveRollType()
		return Sessions.GetActiveRollType(getSessionsContext())
	end

	local function getCurrentItemLink()
		return Sessions.GetCurrentItemLink(getSessionsContext())
	end

	local function syncSessionStateFromRollSession(session)
		Sessions.SyncSessionState(getSessionsContext(), session)
	end

	local function normalizeExpectedWinners(count)
		return Sessions.NormalizeExpectedWinners(getSessionsContext(), count)
	end

	local function ensureAdHocRollSession()
		return Sessions.EnsureAdHocRollSession(getSessionsContext())
	end

	local function ensureRollSession(itemLink, rollType, source)
		return Sessions.EnsureRollSession(getSessionsContext(), itemLink, rollType, source)
	end

	local function captureLootRollBossContext(session, source, opts)
		if type(session) ~= "table" or not session.id then
			return 0
		end

		opts = opts or {}
		local raid = Services.Raid
		local raidNum = opts.raidNum or Database.GetCurrentRaid()
		if not raidNum then
			return tonumber(session.bossNid) or 0
		end

		local ttlSeconds = tonumber(opts.ttlSeconds) or 0
		local sessionBossNid = tonumber(session.bossNid) or 0
		if sessionBossNid > 0 and raid and raid.SetBossContextForLootSession then
			raid:SetBossContextForLootSession(raidNum, session.id, sessionBossNid, ttlSeconds)
			return sessionBossNid
		end

		if not (raid and raid.FindAndRememberBossContextForLootSession) then
			return 0
		end

		sessionBossNid = tonumber(raid:FindAndRememberBossContextForLootSession(raidNum, session.id, {
			allowLootWindowContext = source ~= "inventory",
			allowContextRecovery = source ~= "inventory",
			ttlSeconds = ttlSeconds,
		})) or 0

		if sessionBossNid > 0 then
			session.bossNid = sessionBossNid
		end

		return sessionBossNid
	end

	local function ensureLootRollSession(itemLink, rollType, source, opts)
		local session = ensureRollSession(itemLink, rollType, source)
		if not session then
			return nil
		end

		opts = opts or {}
		if opts.fromInventory == true then
			local raid = Services.Raid
			local raidNum = opts.raidNum or Database.GetCurrentRaid()
			local holderName = opts.holderName or Database.GetPlayerName()
			local heldLootNid = 0
			if raid and raid.ResolveHeldLootNid then
				heldLootNid = tonumber(
					raid:ResolveHeldLootNid(itemLink or session.itemLink, session.lootNid, holderName, raidNum)
				) or 0
			end
			session.lootNid = heldLootNid
			lootState.currentRollItem = heldLootNid
		end

		captureLootRollBossContext(session, source, opts)
		syncSessionStateFromRollSession(session)
		return session
	end

	local function updateSessionRollWindow(opened)
		Sessions.UpdateSessionRollWindow(getSessionsContext(), opened)
	end

	local function closeRollSession()
		Sessions.CloseRollSession(getSessionsContext())
	end

	local function getExpectedWinnerCount()
		return Sessions.GetExpectedWinnerCount(getSessionsContext())
	end

	local function getCurrentRollContext(itemLink, rollType)
		return Sessions.GetCurrentRollContext(getSessionsContext(), itemLink, rollType)
	end

	-- ============================================================================
	-- Eligibility helpers
	-- ============================================================================
	local historyContext
	local function logCurrentRollItemId(itemId)
		if IsDebugEnabled() then
			addon:debug(Diag.D.LogRollsCurrentItemId:format(tostring(itemId)))
		end
	end

	getCurrentRollItemID = function()
		return Sessions.GetCurrentRollItemId(getSessionsContext(), logCurrentRollItemId)
	end

	local function getHistoryContext()
		if historyContext then
			return historyContext
		end

		historyContext = {
			state = state,
			lootState = lootState,
			newItemCounts = newItemCounts,
			delItemCounts = delItemCounts,
			getActiveRollType = getActiveRollType,
			getReserveCountForItem = getReserveCountForItem,
			getCurrentWinner = function()
				return lootState.winner
			end,
			getCurrentRollItemID = function()
				return getCurrentRollItemID()
			end,
			getResponseBestRoll = function(name)
				local response = state.responsesByPlayer[name]
				return response and response.bestRoll or nil
			end,
			isSortAscending = function()
				return GetOption("Master", "sortAscending") == true
			end,
		}
		return historyContext
	end

	local function getAllowedRolls(itemId, name)
		return History.GetAllowedRolls(getHistoryContext(), itemId, name)
	end

	local function getLocalPlayerRollCount(itemId)
		return History.GetLocalPlayerRollCount(getHistoryContext(), itemId)
	end

	local function incrementLocalPlayerRollCount(itemId)
		return History.IncrementLocalPlayerRollCount(getHistoryContext(), itemId)
	end

	local function updateLocalRollState(itemId, name)
		return History.UpdateLocalRollState(getHistoryContext(), itemId, name)
	end

	local function acquireItemTracker(itemId)
		return History.AcquireItemTracker(getHistoryContext(), itemId)
	end

	local function getRollTypeBucket(rollType)
		if rollType == rollTypes.MAINSPEC then
			return "MS"
		end
		if rollType == rollTypes.OFFSPEC then
			return "OS"
		end
		return "FREE"
	end

	-- ============================================================================
	-- Response lifecycle / transitions
	-- ============================================================================
	local responseContext

	local function getResponsesContext()
		if responseContext then
			return responseContext
		end

		responseContext = {
			state = state,
			getRollSession = getRollSession,
			clearTieRerollFilter = clearTieRerollFilter,
			getActiveRollType = getActiveRollType,
			getCurrentItemLink = getCurrentItemLink,
			getCurrentRollItemID = function()
				return getCurrentRollItemID()
			end,
			getReserveCountForItem = getReserveCountForItem,
			getRollTypeBucket = getRollTypeBucket,
			acquireItemTracker = acquireItemTracker,
			getManualExclusionEntry = getManualExclusionEntry,
			isTieRerollRestricted = isTieRerollRestricted,
			getRaidService = function()
				return Services.Raid
			end,
			getCurrentRollContext = getCurrentRollContext,
			getLootCount = function()
				return tonumber(lootState.lootCount) or 0
			end,
			addRoll = function(name, roll, itemId)
				return History.AddRoll(getHistoryContext(), name, roll, itemId)
			end,
		}
		return responseContext
	end

	local function clearResponseState(opts)
		return Responses.ClearResponseState(getResponsesContext(), opts)
	end

	local function ensureResponseSession()
		return Responses.EnsureResponseSession(getResponsesContext())
	end

	local function prepareResponseState(context, opts)
		return Responses.PrepareResponseState(getResponsesContext(), context, opts)
	end

	local function refreshMaterializedResponses(itemId, itemLink, rollType)
		return Responses.RefreshMaterializedResponses(getResponsesContext(), itemId, itemLink, rollType)
	end

	local function finalizeMaterializedResponses(itemId, itemLink, rollType)
		return Responses.FinalizeMaterializedResponses(getResponsesContext(), itemId, itemLink, rollType)
	end

	local function submitExplicitResponse(name, status, reason, source)
		return Responses.SubmitExplicitResponse(getResponsesContext(), name, status, reason, source)
	end

	local function submitIncomingRoll(player, roll, source)
		return Responses.SubmitIncomingRoll(getResponsesContext(), player, roll, source)
	end

	-- ============================================================================
	-- Display model / winner policy
	-- ============================================================================
	local displayContext

	local function getDisplayContext()
		if displayContext then
			return displayContext
		end

		displayContext = {
			state = state,
			lootState = lootState,
			rollTypes = rollTypes,
			getCurrentRollContext = getCurrentRollContext,
			prepareResponseState = prepareResponseState,
			refreshMaterializedResponses = refreshMaterializedResponses,
			finalizeMaterializedResponses = finalizeMaterializedResponses,
			strategyHelpers = Strategies,
			getExpectedWinnerCount = getExpectedWinnerCount,
			getPlusForItem = getPlusForItem,
			isPlusSystemEnabled = isPlusSystemEnabled,
			isSortAscending = function()
				return GetOption("Master", "sortAscending") == true
			end,
			shouldShowLootCounterDuringMSRoll = function()
				return GetOption("LootCounter", "showLootCounterDuringMSRoll") == true
			end,
			getRaidService = function()
				return Services.Raid
			end,
			getItemReserveContext = getItemReserveContext,
			getCurrentItemCount = function()
				local loot = Services.Loot
				if loot and loot.GetCurrentItemCount then
					return loot:GetCurrentItemCount()
				end
				return tonumber(lootState.selectedItemCount) or 1
			end,
			getCurrentRaid = function()
				return Database.GetCurrentRaid()
			end,
			getSourceRollType = function()
				return state.tieReroll and state.tieReroll.sourceRollType or getActiveRollType()
			end,
		}
		return displayContext
	end

	-- ============================================================================
	-- Submission / session mutations
	-- ============================================================================
	local function clearRollEntries()
		History.ClearRollEntries(getHistoryContext())
	end

	local function resetRolls()
		clearRollEntries()
		clearResponseState()
		state.rolled = false
		state.warned = false
		state.canRoll = false
		state.countdownExpired = false

		lootState.winner = nil
		lootState.rollWinner = nil
		lootState.rollsCount = 0
		lootState.itemTraded = 0
		lootState.rollStarted = false
		closeRollSession()
		state.record = false
	end

	local function beginRollIntake()
		state.canRoll = true
		state.record = true
		lootState.rollStarted = true
		ensureAdHocRollSession()
		ensureResponseSession()
		state.warned = false
		state.countdownExpired = false

		if state.count == 0 then
			lootState.winner = nil
			lootState.rollWinner = nil
		end

		updateSessionRollWindow(true)
	end

	local function finishRollIntake()
		state.canRoll = false
		state.record = false

		local context = getCurrentRollContext()
		prepareResponseState(context)
		finalizeMaterializedResponses(context.itemId, context.itemLink, context.rollType)
		updateSessionRollWindow(false)
	end

	local function resetForTieReroll(session, reroll, itemId, itemLink, currentRollType)
		clearRollEntries()
		clearResponseState({
			preserveManualExclusions = true,
			preserveTieReroll = true,
		})
		state.sessionId = tostring(session.id)
		state.rolled = false
		state.warned = false
		state.record = true
		state.canRoll = true
		state.countdownExpired = false

		lootState.winner = nil
		lootState.rollWinner = nil
		lootState.rollsCount = 0
		lootState.itemTraded = 0
		lootState.rollStarted = true

		session.active = true
		session.endsAt = nil
		updateSessionRollWindow(true)
		prepareResponseState({
			itemId = itemId,
			itemLink = itemLink,
			rollType = currentRollType,
		}, {
			seedReserved = false,
			seedTieReroll = true,
		})
	end

	-- ----- Public methods ----- --
	function module:Roll(_btn)
		local itemId = getCurrentRollItemID()
		if not itemId then
			return
		end

		local name = Database.GetPlayerName()
		local allowed = getAllowedRolls(itemId, name)
		local used = getLocalPlayerRollCount(itemId)

		if used >= allowed then
			addon:info(L.ChatOnlyRollOnce)
			if IsDebugEnabled() then
				addon:debug(Diag.D.LogRollsBlockedPlayer:format(name, used, allowed))
			end
			return
		end

		RandomRoll(1, 100)
		incrementLocalPlayerRollCount(itemId)
		updateLocalRollState(itemId, name)
		if IsDebugEnabled() then
			addon:debug(Diag.D.LogRollsPlayerRolled:format(name, itemId))
		end
	end

	function module:GetRollStatus()
		local itemId = getCurrentRollItemID()
		local name = Database.GetPlayerName()
		updateLocalRollState(itemId, name)
		return getActiveRollType(), state.record, state.canRoll, state.rolled
	end

	function module:SetRollRecordingEnabled(bool)
		local on = (bool == true)

		if on then
			beginRollIntake()
		else
			finishRollIntake()
		end

		logRollRecordState(bool)
	end

	function module:CHAT_MSG_SYSTEM(msg)
		if not msg or not state.record then
			return
		end
		local player, roll, min, max = Deformat(msg, RANDOM_ROLL_RESULT)
		if not player or not roll or min ~= 1 or max ~= 100 then
			return
		end
		submitIncomingRoll(player, roll, "system_roll")
	end

	function module:SubmitDebugRoll(name, roll)
		local player = Strings.NormalizeName(name, true)
		local value = tonumber(roll)

		if not player or player == "" then
			return false, reasonCodes.INVALID_PLAYER
		end
		if not value or value < 1 or value > 100 then
			return false, reasonCodes.INVALID_ROLL
		end

		return submitIncomingRoll(player, value, "debug_roll")
	end

	function module:GetRolls()
		return History.GetRolls(getHistoryContext())
	end

	function module:GetHighestRoll(name)
		return History.GetHighestRoll(getHistoryContext(), name)
	end

	function module:ClearRolls(_rec)
		resetRolls()
		local raid = Services.Raid
		if raid and raid.ClearRaidIcons then
			raid:ClearRaidIcons()
		end
	end

	function module:BeginTieReroll(names)
		local session = getRollSession() or ensureAdHocRollSession()
		local reroll
		local itemId
		local itemLink
		local currentRollType

		if not session then
			return false
		end
		ensureResponseSession()

		reroll = setTieRerollFilter(names)
		if not (reroll and reroll.ordered and #reroll.ordered > 1) then
			return false
		end

		itemId = getCurrentRollItemID()
		itemLink = getCurrentItemLink()
		currentRollType = getActiveRollType()
		reroll.sourceRollType = currentRollType

		resetForTieReroll(session, reroll, itemId, itemLink, currentRollType)

		if IsDebugEnabled() then
			addon:debug(Diag.D.LogRollsTieReroll:format(tostring(itemLink), tconcat(reroll.ordered, ",")))
		end
		module:GetDisplayModel()
		return true, reroll.ordered
	end

	local function finalizeRollSession()
		finishRollIntake()
		logRollRecordState(false)
		Countdown.Stop(state)
		Display.BuildModel(getDisplayContext())
	end

	function module:ValidateWinner(playerName, itemLink, rollType)
		return Responses.ValidateWinner(getResponsesContext(), playerName, itemLink, rollType)
	end

	-- Public display-model contract for controller/UI consumers. The returned
	-- `resolution` table is a stable part of this API, not an internal detail.
	function module:GetDisplayModel()
		return Display.BuildModel(getDisplayContext())
	end

	function module:GetRollSession()
		return getRollSession()
	end

	function module:SetExpectedWinners(count)
		local session = getRollSession()
		if not session then
			return nil
		end
		session.expectedWinners = normalizeExpectedWinners(count)
		return session.expectedWinners
	end

	function module:EnsureRollSession(itemLink, rollType, source)
		return ensureRollSession(itemLink, rollType, source)
	end

	function module:EnsureLootRollSession(itemLink, rollType, source, opts)
		return ensureLootRollSession(itemLink, rollType, source, opts)
	end

	function module:SyncSessionState(session)
		syncSessionStateFromRollSession(session or getRollSession())
	end

	function module:GetResolvedWinner(model)
		return Display.GetResolvedWinner(getDisplayContext(), model)
	end

	function module:ShouldUseTieReroll(model)
		return Display.ShouldUseTieReroll(getDisplayContext(), model)
	end

	function module:StopCountdown()
		Countdown.Stop(state)
	end

	function module:StartCountdown(duration, onTick, onComplete)
		return Countdown.Start(state, duration, onTick, onComplete)
	end

	function module:IsCountdownRunning()
		return Countdown.IsRunning(state)
	end

	function module:FinalizeRollSession()
		finalizeRollSession()
	end
end
