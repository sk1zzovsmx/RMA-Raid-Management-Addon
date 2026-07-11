-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: direct addon namespace bindings
-- exports: addon.Services.Master.TradeExecution
-- events: none
-- notes: owns Master inventory trade execution decisions while the controller keeps WoW event handlers
local addon = select(2, ...)
local Master = addon.Services.EnsureNamespace("Master")

local TradeExecution = Master.TradeExecution or {}
Master.TradeExecution = TradeExecution

local L = addon.L
local Diag = addon.Diag
local RAID_TARGET_MARKERS = addon.C.RAID_TARGET_MARKERS
local rollTypes = addon.C.rollTypes

local tonumber = tonumber
local tostring = tostring
local type = type

local function runCheckpoint(checkpoints, key, callback)
	if checkpoints[key] then
		return true, checkpoints[key].value
	end
	local ok, value = pcall(callback)
	if not ok then
		return false
	end
	checkpoints[key] = { value = value }
	return true, value
end

local function finalizeTradeNotifications(controller, itemLink, playerName, rollType, rollValue, output, whisper)
	if controller.isAnnounced() then
		return true
	end

	if output then
		controller.announce(output)
	end
	if whisper then
		if playerName == controller.lootState.trader then
			controller.clearLootAndResetRecordedRolls()
		else
			controller.comms.SendWhisper(playerName, whisper)
		end
	end
	controller.setAnnounced(true)
	return true
end

local function applyRaidMarkerPlan(controller, markerPlan)
	if type(markerPlan) ~= "table" then
		return
	end
	if markerPlan.clearRaidIcons then
		controller.raid:ClearRaidIcons()
	end
	local raidTargets = markerPlan.raidTargets
	if type(raidTargets) ~= "table" then
		return
	end
	for i = 1, #raidTargets do
		local target = raidTargets[i]
		if target and target.name and target.icon then
			controller.wow.SetRaidTarget(target.name, target.icon)
		end
	end
end

local function advanceInventoryWinnerSelection(controller, completedWinner, checkpoints)
	if not controller.lootState.fromInventory then
		return true
	end
	if (tonumber(controller.lootState.selectedItemCount) or 1) <= 1 then
		return true
	end

	local countReady, selectedCount = runCheckpoint(checkpoints, "selectedWinnerCount", function()
		return controller.rollSelection:GetSelectedCount()
	end)
	if not countReady then
		return false
	end
	if selectedCount <= 0 then
		local cleared = runCheckpoint(checkpoints, "clearSelectedWinner", function()
			controller.lootState.winner = nil
		end)
		return cleared == true
	end

	local deselected = runCheckpoint(checkpoints, "deselectWinner", function()
		controller.rollSelection:DeselectWinner(completedWinner)
	end)
	if not deselected then
		return false
	end
	local modelReady, rollModel = runCheckpoint(checkpoints, "buildNextWinner", controller.buildRollSelectionModel)
	if not modelReady then
		return false
	end
	local assigned = runCheckpoint(checkpoints, "assignNextWinner", function()
		controller.lootState.winner = rollModel and rollModel.winner or nil
	end)
	return assigned == true
end

local function completeInventoryAwardProgress(controller, completedWinner, rollType, awardedCount, raidNid, checkpoints)
	checkpoints = checkpoints or {}
	if completedWinner and completedWinner ~= "" then
		local counted = runCheckpoint(checkpoints, "raidCount", function()
			controller.raid:AddPlayerCountForRollType(
				completedWinner,
				rollType,
				awardedCount,
				raidNid or controller.database.GetCurrentRaid()
			)
		end)
		if not counted then
			return nil, false
		end
	end

	local registered, done = runCheckpoint(checkpoints, "registerAward", function()
		return controller.registerAwardedItem(awardedCount)
	end)
	if not registered then
		return nil, false
	end
	local reset = runCheckpoint(checkpoints, "resetTradeState", controller.resetTradeState)
	if not reset then
		return nil, false
	end
	if not done then
		local advanced = advanceInventoryWinnerSelection(controller, completedWinner, checkpoints)
		if not advanced then
			return nil, false
		end
	end
	if done then
		local clearedLoot = runCheckpoint(checkpoints, "clearLoot", function()
			controller.loot:ClearLoot()
		end)
		if not clearedLoot then
			return nil, false
		end
		local clearedIcons = runCheckpoint(checkpoints, "clearRaidIcons", function()
			controller.raid:ClearRaidIcons()
		end)
		if not clearedIcons then
			return nil, false
		end
	end
	local screenshot = runCheckpoint(checkpoints, "clearScreenshotWarn", function()
		controller.setScreenshotWarn(false)
	end)
	if not screenshot then
		return nil, false
	end
	local refreshed = runCheckpoint(checkpoints, "requestRefresh", controller.requestRefresh)
	if not refreshed then
		return nil, false
	end
	return done, true
end

local function tryInitiateTrade(controller, itemLink, playerName, isAwardRoll)
	local unit = controller.raid:GetUnitID(playerName)
	if unit == "none" then
		return true, nil, false
	end

	if controller.wow.CheckInteractDistance(unit, 2) ~= 1 then
		if type(controller.warn) == "function" then
			controller.warn(Diag.W.LogTradeDelayedOutOfRange:format(tostring(playerName), tostring(itemLink)))
		end
		controller.raid:ClearRaidIcons()
		controller.wow.SetRaidTarget(controller.lootState.trader, 1)
		if isAwardRoll then
			controller.wow.SetRaidTarget(playerName, 4)
		end
		return true, L.ChatTrade:format(playerName, itemLink), false
	end

	if not controller:PrepareTradeableItem(itemLink) then
		return false, nil, false
	end

	local _, startCount = controller.wow.GetContainerItemInfo(controller.itemInfo.bagID, controller.itemInfo.slotID)
	controller.itemInfo.tradeStartCount = tonumber(startCount) or tonumber(controller.itemInfo.slotCount) or 1
	controller.itemInfo.tradeStartBag = controller.itemInfo.bagID
	controller.itemInfo.tradeStartSlot = controller.itemInfo.slotID
	controller.itemInfo.tradeStartItemLink =
		controller.wow.GetContainerItemLink(controller.itemInfo.bagID, controller.itemInfo.slotID)

	controller.wow.ClearCursor()
	controller.wow.PickupContainerItem(controller.itemInfo.bagID, controller.itemInfo.slotID)
	if controller.wow.CursorHasItem() then
		controller.wow.InitiateTrade(playerName)
		if type(controller.debug) == "function" then
			controller.debug(Diag.D.LogTradeInitiated:format(tostring(itemLink), tostring(playerName)))
		end
		if controller.getOption("Master", "screenReminder") and not controller.isScreenshotWarn() then
			if type(controller.warn) == "function" then
				controller.warn(L.ErrScreenReminder)
			end
			controller.setScreenshotWarn(true)
		end
		return true, nil, true
	end

	return false, nil, false
end

function TradeExecution.CreateController(opts)
	opts = opts or {}

	local wow = assert(opts.wow, "Master trade execution WoW API table is not initialized")
	local controller = {
		trade = assert(opts.trade, "Master trade execution trade owner is not initialized"),
		inventory = assert(opts.inventory, "Master trade execution inventory owner is not initialized"),
		awardPlanner = assert(opts.awardPlanner, "Master trade execution award planner is not initialized"),
		rollSelection = assert(opts.rollSelection, "Master trade execution roll selection owner is not initialized"),
		raid = assert(opts.raid, "Master trade execution raid service is not initialized"),
		loot = assert(opts.loot, "Master trade execution loot service is not initialized"),
		distribution = assert(opts.distribution, "Master trade execution distribution owner is not initialized"),
		rolls = assert(opts.rolls, "Master trade execution rolls service is not initialized"),
		comms = assert(opts.comms, "Master trade execution comms service is not initialized"),
		database = assert(opts.database, "Master trade execution database helpers are not initialized"),
		item = assert(opts.item, "Master trade execution item helpers are not initialized"),
		lootState = assert(opts.lootState, "Master trade execution loot state is not initialized"),
		itemInfo = assert(opts.itemInfo, "Master trade execution item state is not initialized"),
		wow = {
			ClearCursor = assert(wow.ClearCursor, "Master trade execution clear-cursor API is not initialized"),
			CursorHasItem = assert(wow.CursorHasItem, "Master trade execution cursor-item API is not initialized"),
			GetContainerItemInfo = assert(
				wow.GetContainerItemInfo,
				"Master trade execution container-item-info API is not initialized"
			),
			GetContainerItemLink = assert(
				wow.GetContainerItemLink,
				"Master trade execution container-item-link API is not initialized"
			),
			InitiateTrade = assert(wow.InitiateTrade, "Master trade execution initiate-trade API is not initialized"),
			PickupContainerItem = assert(
				wow.PickupContainerItem,
				"Master trade execution pickup-container-item API is not initialized"
			),
			SetRaidTarget = assert(wow.SetRaidTarget, "Master trade execution raid-target API is not initialized"),
			CheckInteractDistance = assert(
				wow.CheckInteractDistance,
				"Master trade execution interact-distance API is not initialized"
			),
		},
		getOption = assert(opts.getOption, "Master trade execution option getter is not initialized"),
		buildRollSelectionModel = assert(
			opts.buildRollSelectionModel,
			"Master trade execution roll-model builder is not initialized"
		),
		buildLootRollSessionOptions = assert(
			opts.buildLootRollSessionOptions,
			"Master trade execution roll-session options builder is not initialized"
		),
		resetTradeState = assert(opts.resetTradeState, "Master trade execution trade-state reset is not initialized"),
		hideTradeDropdowns = assert(
			opts.hideTradeDropdowns,
			"Master trade execution trade-menu hider is not initialized"
		),
		clearLootAndResetRecordedRolls = assert(
			opts.clearLootAndResetRecordedRolls,
			"Master trade execution loot-reset helper is not initialized"
		),
		ensureTradeLootContext = assert(
			opts.ensureTradeLootContext,
			"Master trade execution loot-context resolver is not initialized"
		),
		requestLoggerLootLog = assert(
			opts.requestLoggerLootLog,
			"Master trade execution logger request helper is not initialized"
		),
		registerAwardedItem = assert(
			opts.registerAwardedItem,
			"Master trade execution awarded-item recorder is not initialized"
		),
		requestRefresh = assert(opts.requestRefresh, "Master trade execution refresh hook is not initialized"),
		announce = assert(opts.announce, "Master trade execution announcer is not initialized"),
		isAnnounced = assert(opts.isAnnounced, "Master trade execution announce-state getter is not initialized"),
		setAnnounced = assert(opts.setAnnounced, "Master trade execution announce-state setter is not initialized"),
		isScreenshotWarn = assert(
			opts.isScreenshotWarn,
			"Master trade execution screenshot-warning getter is not initialized"
		),
		setScreenshotWarn = assert(
			opts.setScreenshotWarn,
			"Master trade execution screenshot-warning setter is not initialized"
		),
		debug = opts.debug,
		warn = opts.warn,
		error = assert(opts.error, "Master trade execution error reporter is not initialized"),
		createAttempt = assert(opts.createAttempt, "Master trade award-attempt factory is not initialized"),
		getItemKey = assert(opts.getItemKey, "Master trade item-key resolver is not initialized"),
	}
	local pendingAcceptedTrade

	local function createAwardAttempt(itemLink, winner, onConfirm, onFail)
		local session = controller.lootState.rollSession
		local attempt = controller.createAttempt({
			rollSessionId = session and session.id or nil,
			itemKey = controller.getItemKey(itemLink),
			itemLink = itemLink,
			winner = winner,
			source = "inventory_trade",
			executorContext = {
				executor = "trade",
				raidNid = controller.database.GetCurrentRaid(),
				lootNid = controller.lootState.currentRollItem,
			},
			onConfirm = onConfirm,
			onFail = onFail,
		})
		return attempt
	end

	local function releaseSessionOwnership(distribution, pending)
		local token = pending and pending.sessionOwnershipToken
		if not token then
			return false
		end
		pending.sessionOwnershipToken = nil
		return distribution.ReleaseSessionOwnership(token)
	end

	function controller:ResolveWinner(playerName, isAwardRoll)
		if not isAwardRoll then
			return nil
		end

		local winnerModel = self.buildRollSelectionModel and self.buildRollSelectionModel() or nil
		local winner = playerName or self.rolls:GetResolvedWinner(winnerModel)
		local multiInventoryAward = self.lootState.fromInventory
			and ((tonumber(self.lootState.selectedItemCount) or 1) > 1)
		if multiInventoryAward then
			local rollModel = self.buildRollSelectionModel(true)
			local picked = self.rollSelection:GetSelectedWinnersOrdered(rollModel and rollModel.rows or nil)
			if type(picked) == "table" and picked[1] and picked[1].name then
				winner = picked[1].name
			end
		end

		return winner
	end

	function controller:PrepareTradeableItem(itemLink)
		local itemData = self.inventory.ResolveTradeableInventoryItem(
			itemLink,
			self.itemInfo.bagID,
			self.itemInfo.slotID,
			self.lootState.selectedItemCount
		)
		if not itemData then
			if type(self.warn) == "function" then
				self.warn(L.ErrMLInventoryItemMissing:format(tostring(itemLink)))
			end
			return false
		end

		self.itemInfo.bagID = itemData.bag
		self.itemInfo.slotID = itemData.slot
		self.itemInfo.slotCount = itemData.slotCount
		self.itemInfo.isStack = itemData.slotCount > 1
		self.itemInfo.count = itemData.totalCount

		local ignoreStacks = self.getOption("Loot", "ignoreStacks") == true
		if self.itemInfo.isStack and not ignoreStacks then
			if type(self.debug) == "function" then
				self.debug(Diag.D.LogTradeStackBlocked:format(tostring(ignoreStacks), tostring(itemLink)))
			end
			if type(self.warn) == "function" then
				self.warn(L.ErrItemStack:format(itemLink))
			end
			return false
		end

		return true
	end

	function controller:BeginTradeItemState(itemLink, playerName, rollType, rollValue, isAwardRoll)
		self.trade.Reset(true, false)
		self.hideTradeDropdowns()
		self.rolls:EnsureLootRollSession(
			itemLink,
			rollType,
			self.lootState.fromInventory and "inventory" or "lootWindow",
			self.buildLootRollSessionOptions()
		)

		self.resetTradeState()

		self.lootState.trader = self.database.GetPlayerName()
		local winnerName = self:ResolveWinner(playerName, isAwardRoll)
		self.lootState.tradeItemLink = itemLink
		self.lootState.tradeItemId = self.item.GetItemIdFromLink(itemLink)

		if isAwardRoll and (not winnerName or winnerName == "") then
			if type(self.warn) == "function" then
				self.warn(L.ErrNoWinnerSelected)
			end
			self.resetTradeState()
			return false, nil
		end
		if isAwardRoll then
			local validation = self.rolls:ValidateWinner(winnerName, itemLink, rollType)
			if not (validation and validation.ok == true) then
				if type(self.warn) == "function" then
					self.warn(
						(validation and validation.warnMessage) or L.ErrMLWinnerIneligible:format(tostring(winnerName))
					)
				end
				self.resetTradeState()
				return false, nil
			end
		end
		self.lootState.tradeWinner = winnerName
		if isAwardRoll then
			self.distribution.PublishRollEnd(itemLink, winnerName, rollValue, "inventory_trade")
		end

		if type(self.debug) == "function" then
			self.debug(
				Diag.D.LogTradeStart:format(
					tostring(itemLink),
					tostring(self.lootState.trader),
					tostring(winnerName or playerName),
					tonumber(rollType) or -1,
					tonumber(rollValue) or 0,
					self.lootState.selectedItemCount or 1
				)
			)
		end

		return true, winnerName
	end

	function controller:BuildNotificationPlan(itemLink, playerName, winnerName, rollType, isAwardRoll)
		local selectedWinners
		local fallbackRolls
		if isAwardRoll and (tonumber(self.lootState.selectedItemCount) or 1) > 1 then
			local rollModel = self.buildRollSelectionModel(true)
			selectedWinners = self.rollSelection:GetSelectedWinnersOrdered(rollModel and rollModel.rows or nil)
			fallbackRolls = self.rolls:GetRolls()
		end

		local plan = self.awardPlanner.BuildTradeNotificationPlan({
			itemLink = itemLink,
			playerName = playerName,
			winnerName = winnerName,
			rollType = rollType,
			isAwardRoll = isAwardRoll,
			selectedItemCount = self.lootState.selectedItemCount,
			traderName = self.lootState.trader,
			selectedWinners = selectedWinners,
			fallbackRolls = fallbackRolls,
			raidTargetMarkers = RAID_TARGET_MARKERS,
			options = {
				announceOnWin = self.getOption("Master", "announceOnWin") == true,
				announceOnHold = self.getOption("Master", "announceOnHold") == true,
				announceOnBank = self.getOption("Master", "announceOnBank") == true,
				announceOnDisenchant = self.getOption("Master", "announceOnDisenchant") == true,
			},
		})

		applyRaidMarkerPlan(self, plan and plan.markerPlan)
		return plan and plan.keep, plan and plan.output, plan and plan.whisper
	end

	function controller:CompleteTraderKeepAward(itemLink, winnerName, rollType, rollValue, output, whisper)
		if type(self.debug) == "function" then
			self.debug(Diag.D.LogTradeTraderKeeps:format(tostring(itemLink), tostring(winnerName)))
		end
		local awardedCount =
			self.inventory.ResolveInventoryAwardedCount(self.lootState.selectedItemCount, self.lootState.fromInventory)
		local lootNid, createdTradeOnly = self.ensureTradeLootContext(
			itemLink,
			winnerName,
			rollType,
			rollValue,
			awardedCount,
			"TRADE_KEEP_NO_CONTEXT"
		)
		if lootNid <= 0 then
			self.error(
				Diag.E.LogTradeKeepLoggerFailed:format(
					tostring(self.database.GetCurrentRaid()),
					tostring(lootNid),
					tostring(itemLink)
				)
			)
		elseif createdTradeOnly ~= true then
			local ok = self.requestLoggerLootLog(
				lootNid,
				winnerName,
				rollType,
				rollValue,
				"TRADE_KEEP",
				self.database.GetCurrentRaid()
			)
			if not ok then
				self.error(
					Diag.E.LogTradeKeepLoggerFailed:format(
						tostring(self.database.GetCurrentRaid()),
						tostring(lootNid),
						tostring(itemLink)
					)
				)
			end
		end

		return createAwardAttempt(itemLink, winnerName, function(attemptState)
			finalizeTradeNotifications(self, itemLink, winnerName, rollType, rollValue, output, whisper)
			completeInventoryAwardProgress(
				self,
				winnerName,
				rollType,
				awardedCount,
				attemptState.executorContext.raidNid
			)
			return true
		end, function(reason)
			return true
		end):Confirm()
	end

	function controller:HandleAcceptedAwardTrade(playerAccepted, targetAccepted)
		local pending = pendingAcceptedTrade
		if not pending then
			return false
		end
		pending.playerAccepted = playerAccepted == 1
		pending.targetAccepted = targetAccepted == 1
		pending.accepted = pending.playerAccepted and pending.targetAccepted
		if not pending.accepted then
			return false
		end
		return true
	end

	function controller:HasInFlightAward()
		return pendingAcceptedTrade ~= nil
	end

	function controller:HasPendingAcceptedTrade()
		return pendingAcceptedTrade ~= nil and pendingAcceptedTrade.accepted == true
	end

	function controller:SettleAcceptedTrade()
		local pending = pendingAcceptedTrade
		if not pending or pending.accepted ~= true then
			return false
		end
		local confirmed = pending.effect:Confirm()
		if not confirmed then
			return false
		end
		releaseSessionOwnership(self.distribution, pending)
		pendingAcceptedTrade = nil
		return confirmed
	end

	function controller:FailAcceptedTrade(reason)
		local pending = pendingAcceptedTrade
		if not pending then
			return false
		end
		local failed = pending.effect:Fail(reason)
		if not failed then
			return false
		end
		releaseSessionOwnership(self.distribution, pending)
		pendingAcceptedTrade = nil
		return failed == true
	end

	function controller:TradeItem(itemLink, playerName, rollType, rollValue)
		if itemLink ~= self.loot.GetItemLink() then
			return nil
		end

		local isAwardRoll = rollType and rollType >= rollTypes.MAINSPEC and rollType <= rollTypes.FREE
		local ok, winnerName = self:BeginTradeItemState(itemLink, playerName, rollType, rollValue, isAwardRoll)
		if not ok then
			return false
		end

		local keep, output, whisper =
			self:BuildNotificationPlan(itemLink, playerName, winnerName, rollType, isAwardRoll)

		if not keep and self.lootState.trader == winnerName then
			return self:CompleteTraderKeepAward(itemLink, winnerName, rollType, rollValue, output, whisper)
		end

		if not keep then
			local effect
			local pendingContext
			if isAwardRoll and winnerName and winnerName ~= "" then
				effect = createAwardAttempt(itemLink, winnerName, function(attemptState)
					if pendingContext then
						local checkpoints = pendingContext.effectCheckpoints
						local contextReady, contextResult = runCheckpoint(checkpoints, "lootContext", function()
							local lootNid, createdTradeOnly = self.ensureTradeLootContext(
								pendingContext.itemLink,
								pendingContext.winner,
								pendingContext.rollType,
								pendingContext.rollValue,
								pendingContext.awardedCount,
								"TRADE_ACCEPT_NO_CONTEXT"
							)
							return { lootNid = lootNid, createdTradeOnly = createdTradeOnly }
						end)
						if not contextReady then
							return false
						end
						local lootNid = contextResult.lootNid
						local createdTradeOnly = contextResult.createdTradeOnly
						if lootNid <= 0 then
							if type(self.warn) == "function" then
								self.warn(
									Diag.W.LogTradeCurrentRollItemMissingContext:format(
										tostring(pendingContext.winner),
										tostring(pendingContext.tradeItemId),
										tostring(pendingContext.itemLink)
									)
								)
							end
							return false
						end
						if createdTradeOnly and type(self.warn) == "function" then
							self.warn(
								Diag.W.LogTradeNoLootContextTradeOnly:format(
									tostring(lootNid),
									tostring(pendingContext.winner),
									tostring(pendingContext.itemLink),
									pendingContext.awardedCount
								)
							)
						end
						local loggerRan, logged = runCheckpoint(checkpoints, "loggerWrite", function()
							return self.requestLoggerLootLog(
								lootNid,
								pendingContext.winner,
								pendingContext.rollType,
								pendingContext.rollValue,
								"TRADE_ACCEPT",
								pendingContext.raidNid
							)
						end)
						if not loggerRan or not logged then
							if loggerRan then
								checkpoints.loggerWrite = nil
							end
							self.error(
								Diag.E.LogTradeLoggerLogFailed:format(
									tostring(pendingContext.raidNid),
									tostring(lootNid),
									tostring(pendingContext.itemLink)
								)
							)
							return false
						end
						if type(self.debug) == "function" then
							self.debug(
								Diag.D.LogTradeCompleted:format(
									tostring(pendingContext.currentRollItem),
									tostring(pendingContext.winner),
									tonumber(pendingContext.rollType) or -1,
									pendingContext.rollValue
								)
							)
						end
						local _, progressComplete = completeInventoryAwardProgress(
							self,
							pendingContext.winner,
							pendingContext.rollType,
							pendingContext.awardedCount,
							attemptState.executorContext.raidNid,
							checkpoints
						)
						if not progressComplete then
							return false
						end
					end
					return true
				end, function(reason)
					return true
				end)
			end
			local initiated
			ok, output, initiated = tryInitiateTrade(self, itemLink, winnerName, isAwardRoll)
			if not ok then
				if effect then
					effect:Fail("trade_initiation_failed")
				end
				return false
			end
			if initiated and effect then
				local awardedCount = self.inventory.ResolveTradeAwardedCount()
				local sessionOwnershipToken = self.distribution.AcquireSessionOwnership("inventory-award")
				pendingAcceptedTrade = {
					winner = winnerName,
					itemLink = itemLink,
					rollType = rollType,
					rollValue = rollValue,
					awardedCount = awardedCount,
					raidNid = self.database.GetCurrentRaid(),
					currentRollItem = self.lootState.currentRollItem,
					tradeItemId = self.lootState.tradeItemId,
					accepted = false,
					effectCheckpoints = {},
					effect = effect,
					sessionOwnershipToken = sessionOwnershipToken,
				}
				pendingContext = pendingAcceptedTrade
			end
		end

		return finalizeTradeNotifications(
			self,
			itemLink,
			winnerName or playerName,
			rollType,
			rollValue,
			output,
			whisper
		)
	end

	return controller
end

return TradeExecution
