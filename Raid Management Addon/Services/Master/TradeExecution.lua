-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: local feature = addon.Database.GetFeatureShared()
-- exports: addon.Services.Master.TradeExecution
-- events: none
-- notes: owns Master inventory trade execution decisions while the controller keeps WoW event handlers
local addon = select(2, ...)
local feature = addon.Database.GetFeatureShared()

local Master = feature.EnsureServiceNamespace("Master")

local TradeExecution = Master.TradeExecution or {}
Master.TradeExecution = TradeExecution

local L = feature.L
local Diag = feature.Diag
local RAID_TARGET_MARKERS = feature.RAID_TARGET_MARKERS
local rollTypes = feature.rollTypes

local tonumber = tonumber
local tostring = tostring
local type = type

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

local function advanceInventoryWinnerSelection(controller, completedWinner)
	if not controller.lootState.fromInventory then
		return
	end
	if (tonumber(controller.lootState.selectedItemCount) or 1) <= 1 then
		return
	end

	local selectedCount = controller.rollUi:GetSelectedCount()
	if selectedCount <= 0 then
		controller.lootState.winner = nil
		return
	end

	controller.rollUi:DeselectWinner(completedWinner)
	local rollModel = controller.buildRollUiModel()
	controller.lootState.winner = rollModel and rollModel.winner or nil
end

local function completeInventoryAwardProgress(controller, completedWinner, rollType, awardedCount)
	if completedWinner and completedWinner ~= "" then
		controller.raid:AddPlayerCountForRollType(
			completedWinner,
			rollType,
			awardedCount,
			controller.database.GetCurrentRaid()
		)
	end

	local done = controller.registerAwardedItem(awardedCount)
	controller.resetTradeState()
	if not done then
		advanceInventoryWinnerSelection(controller, completedWinner)
	end
	if done then
		controller.loot:ClearLoot()
		controller.raid:ClearRaidIcons()
	end
	controller.setScreenshotWarn(false)
	controller.requestRefresh()
	return done
end

local function tryInitiateTrade(controller, itemLink, playerName, isAwardRoll)
	local unit = controller.raid:GetUnitID(playerName)
	if unit == "none" then
		return true, nil
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
		return true, L.ChatTrade:format(playerName, itemLink)
	end

	if not controller:PrepareTradeableItem(itemLink) then
		return false, nil
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
	end

	return true, nil
end

function TradeExecution.CreateController(opts)
	opts = opts or {}

	local wow = assert(opts.wow, "Master trade execution WoW API table is not initialized")
	local controller = {
		trade = assert(opts.trade, "Master trade execution trade owner is not initialized"),
		inventory = assert(opts.inventory, "Master trade execution inventory owner is not initialized"),
		awardPlanner = assert(opts.awardPlanner, "Master trade execution award planner is not initialized"),
		rollUi = assert(opts.rollUi, "Master trade execution roll UI owner is not initialized"),
		raid = assert(opts.raid, "Master trade execution raid service is not initialized"),
		loot = assert(opts.loot, "Master trade execution loot service is not initialized"),
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
		buildRollUiModel = assert(
			opts.buildRollUiModel,
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
	}

	function controller:ResolveWinner(playerName, isAwardRoll)
		if not isAwardRoll then
			return nil
		end

		local winnerModel = self.buildRollUiModel and self.buildRollUiModel() or nil
		local winner = playerName or self.rolls:GetResolvedWinner(winnerModel)
		local multiInventoryAward = self.lootState.fromInventory
			and ((tonumber(self.lootState.selectedItemCount) or 1) > 1)
		if multiInventoryAward then
			local rollModel = self.buildRollUiModel(true)
			local picked = self.rollUi:GetSelectedWinnersOrdered(rollModel and rollModel.rows or nil)
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
			self.loot:SetDistributionState("roll_end", {
				itemLink = itemLink,
				winnerName = winnerName,
				rollValue = rollValue,
				reason = "inventory_trade",
			})
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
			local rollModel = self.buildRollUiModel(true)
			selectedWinners = self.rollUi:GetSelectedWinnersOrdered(rollModel and rollModel.rows or nil)
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
		local awardedCount = self.inventory.ResolveInventoryAwardedCountFromArgs(
			self.lootState.selectedItemCount,
			self.lootState.fromInventory
		)
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

		finalizeTradeNotifications(self, itemLink, winnerName, rollType, rollValue, output, whisper)
		self.loot:SetDistributionState("item_done", {
			itemLink = itemLink,
			winnerName = winnerName,
		})
		completeInventoryAwardProgress(self, winnerName, rollType, awardedCount)
		return true
	end

	function controller:HandleAcceptedAwardTrade(playerAccepted, targetAccepted)
		local tradeWinner = self.lootState.tradeWinner
		if not (self.lootState.trader and tradeWinner and self.lootState.trader ~= tradeWinner) then
			return false
		end
		if playerAccepted ~= 1 or targetAccepted ~= 1 then
			return false
		end

		local itemLink = self.lootState.tradeItemLink or self.loot.GetItemLink()
		local awardedCount = self.inventory.ResolveTradeAwardedCount()
		local rollValue = self.rolls:GetHighestRoll(tradeWinner)
		local lootNid, createdTradeOnly = self.ensureTradeLootContext(
			itemLink,
			tradeWinner,
			self.lootState.currentRollType,
			rollValue,
			awardedCount,
			"TRADE_ACCEPT_NO_CONTEXT"
		)
		if lootNid > 0 and createdTradeOnly and type(self.warn) == "function" then
			self.warn(
				Diag.W.LogTradeNoLootContextTradeOnly:format(
					tostring(lootNid),
					tostring(tradeWinner),
					tostring(itemLink),
					awardedCount
				)
			)
		end

		if type(self.debug) == "function" then
			self.debug(
				Diag.D.LogTradeCompleted:format(
					tostring(self.lootState.currentRollItem),
					tostring(tradeWinner),
					tonumber(self.lootState.currentRollType) or -1,
					rollValue
				)
			)
		end
		if lootNid > 0 then
			local ok = self.requestLoggerLootLog(
				lootNid,
				tradeWinner,
				self.lootState.currentRollType,
				rollValue,
				"TRADE_ACCEPT",
				self.database.GetCurrentRaid()
			)
			if not ok then
				self.error(
					Diag.E.LogTradeLoggerLogFailed:format(
						tostring(self.database.GetCurrentRaid()),
						tostring(lootNid),
						tostring(itemLink)
					)
				)
			end
		elseif type(self.warn) == "function" then
			self.warn(
				Diag.W.LogTradeCurrentRollItemMissingContext:format(
					tostring(tradeWinner),
					tostring(self.lootState.tradeItemId),
					tostring(itemLink)
				)
			)
		end

		self.loot:SetDistributionState("item_done", {
			itemLink = itemLink,
			winnerName = tradeWinner,
		})
		completeInventoryAwardProgress(self, tradeWinner, self.lootState.currentRollType, awardedCount)
		return true
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
			ok, output = tryInitiateTrade(self, itemLink, winnerName, isAwardRoll)
			if not ok then
				return false
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

local registry = feature.ModuleRegistry
if type(registry) == "table" and type(registry.AddModule) == "function" and type(registry.SetLoaded) == "function" then
	registry.AddModule("Services/Master/TradeExecution", {
		deps = {
			"Init",
			"Modules/ModuleRegistry",
		},
	})
	registry.SetLoaded("Services/Master/TradeExecution")
end

return TradeExecution
