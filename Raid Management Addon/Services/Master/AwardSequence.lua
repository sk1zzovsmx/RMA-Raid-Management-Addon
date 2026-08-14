-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: direct addon namespace bindings
-- exports: addon.Services.Master.AwardSequence
-- events: none
-- notes: owns Master loot award orchestration, including single and multi-copy awards
local addon = select(2, ...)
local Master = addon.Services.EnsureNamespace("Master")
local Services = addon.Services

local AwardSequence = Master.AwardSequence or {}
Master.AwardSequence = AwardSequence

local Loot = assert(Services.Loot, "Master award loot service is not initialized")
local Raid = assert(Services.Raid, "Master award raid service is not initialized")
local LootBans = assert(Raid.LootBans, "Master award loot bans owner is not initialized")
local L = addon.L
local Diag = addon.Diag

local tonumber = tonumber
local tostring = tostring
local tconcat = table.concat
local type = type

local function getSelectedWinners(controller)
	local selectedCount = controller.rollSelection:GetSelectedCount()
	if selectedCount <= 0 then
		return selectedCount, nil
	end

	local rollModel = controller.rollSelection:BuildModel(true)
	local picked = controller.rollSelection:GetSelectedWinnersOrdered(rollModel and rollModel.rows or nil)
	return selectedCount, picked
end

local function findWinnerRoll(controller, winnerName)
	local model = controller.rollSelection:BuildModel(true)
	local rows = model and model.rows or nil
	if type(rows) ~= "table" then
		return 0
	end

	for i = 1, #rows do
		local row = rows[i]
		if row and row.name == winnerName then
			return tonumber(row.roll) or 0
		end
	end

	return 0
end

local function collectWinnerNames(ma)
	local names = {}
	if not ma then
		return names
	end

	local total = tonumber(ma.total) or (ma.winners and #ma.winners) or 0
	for i = 1, total do
		local winner = ma.winners and ma.winners[i]
		if winner and winner.name then
			names[#names + 1] = winner.name
		end
	end
	return names
end

local function cancelTimeout(controller, ma)
	if ma and ma.timeoutHandle then
		controller.cancelTimer(ma.timeoutHandle)
		ma.timeoutHandle = nil
	end
end

local function cancelDelay(controller, ma)
	if ma and ma.delayHandle then
		controller.cancelTimer(ma.delayHandle)
		ma.delayHandle = nil
	end
	if ma then
		ma.scheduled = false
	end
end

local function stopAfterScheduleFailure(controller, ma, refreshNow)
	if not ma then
		return nil, "timer_schedule_failed"
	end
	local reportWarning = ma.cancelReason ~= "timer_schedule_failed"
	local timeoutHandle = ma.timeoutHandle
	local delayHandle = ma.delayHandle
	ma.timeoutHandle = nil
	ma.delayHandle = nil
	ma.scheduled = false
	ma.waitingForDecrement = false
	ma.active = false
	ma.cancelled = true
	ma.cancelReason = "timer_schedule_failed"
	if controller.lootState.multiAward == ma then
		controller.lootState.multiAward = nil
	end
	if timeoutHandle then
		pcall(controller.cancelTimer, timeoutHandle)
	end
	if delayHandle and delayHandle ~= timeoutHandle then
		pcall(controller.cancelTimer, delayHandle)
	end
	pcall(controller.itemCount.Reset, controller.itemCount)
	if reportWarning and type(controller.warn) == "function" then
		pcall(controller.warn, L.WarnMLMultiAwardTimerScheduleFailed)
	end
	if refreshNow and type(controller.refresh) == "function" then
		pcall(controller.refresh)
	end
	return nil, "timer_schedule_failed"
end

local function announceCompletion(controller, ma)
	if not (ma and ma.announceOnWin and not ma.congratsSent) then
		return true
	end

	local names = collectWinnerNames(ma)
	if #names <= 0 then
		return true
	end

	if type(controller.announce) == "function" then
		local result
		if #names == 1 then
			result = controller.announce(L.ChatAward:format(names[1], ma.itemLink))
		else
			result = controller.announce(L.ChatAwardMutiple:format(tconcat(names, ", "), ma.itemLink))
		end
		if result == false then
			return nil, "sequence_announcement_rejected"
		end
	end
	ma.congratsSent = true
	return true
end

local function armProgressTimeout(controller, ma)
	if not (ma and ma.active and not controller.lootState.fromInventory) then
		return true
	end

	local timeout = tonumber(controller.multiAwardTimeoutSeconds) or 0
	ma.waitingForDecrement = true
	if timeout <= 0 then
		return true
	end

	cancelTimeout(controller, ma)
	local expectedLessThan = tonumber(ma.lastCount) or 0
	local scheduled, handle = pcall(controller.scheduleTimer, function()
		local cur = controller.lootState.multiAward
		if
			cur ~= ma
			or not (cur and cur.active and cur.waitingForDecrement and not controller.lootState.fromInventory)
		then
			return
		end

		local observed = Loot:GetLootWindowItemCountByKey(cur.itemKey)
		if type(controller.warn) == "function" then
			controller.warn(
				Diag.W.ErrMLMultiAwardInterruptedTimeout:format(
					timeout,
					tostring(cur.itemLink),
					expectedLessThan,
					observed,
					tostring(cur.lastClearedSlot or "?")
				)
			)
		end
		controller:Clear(true)
		if type(controller.refresh) == "function" then
			controller.refresh()
		end
	end, timeout)
	if not scheduled or not handle then
		return stopAfterScheduleFailure(controller, ma, true)
	end
	ma.timeoutHandle = handle
	return true
end

function AwardSequence.CreateController(opts)
	opts = opts or {}
	local controller = {
		awardPlanner = assert(opts.awardPlanner, "Master award planner is not initialized"),
		inventory = assert(opts.inventory, "Master award inventory owner is not initialized"),
		lootState = assert(opts.lootState, "Master award loot state is not initialized"),
		rollSelection = assert(opts.rollSelection, "Master award roll selection owner is not initialized"),
		scheduleTimer = assert(opts.scheduleTimer, "Master award timer scheduler is not initialized"),
		cancelTimer = assert(opts.cancelTimer, "Master award timer canceller is not initialized"),
		announce = opts.announce,
		debug = opts.debug,
		warn = opts.warn,
		registerAwardedItem = assert(opts.registerAwardedItem, "Master award awarded-item recorder is not initialized"),
		beginAwardSequence = opts.beginAwardSequence or function() return true end,
		refresh = opts.refresh,
		awardExecutor = assert(opts.awardExecutor, "Master award executor is not initialized"),
		itemCount = assert(opts.itemCount, "Master award item-count owner is not initialized"),
		getAnnounceOnWin = opts.getAnnounceOnWin,
		multiAwardTimeoutSeconds = opts.multiAwardTimeoutSeconds,
		multiAwardDelaySeconds = opts.multiAwardDelaySeconds,
		createAttempt = assert(opts.createAttempt, "Master award attempt factory is not initialized"),
		admitAward = opts.admitAward or function() return true end,
		hasInFlight = opts.hasInFlight or function() return false end,
		getRollSessionId = assert(opts.getRollSessionId, "Master award roll-session resolver is not initialized"),
		getItemKey = assert(opts.getItemKey, "Master award item-key resolver is not initialized"),
		getRaidNid = assert(opts.getRaidNid, "Master award raid resolver is not initialized"),
		lootBans = LootBans,
	}

	local function validateLootBan(self, playerName)
		local active, note = self.lootBans.Get(playerName)
		if active then
			if type(self.warn) == "function" then
				self.warn(
					note and L.ErrMLWinnerLootBannedWithNote:format(playerName, note)
						or L.ErrMLWinnerLootBanned:format(playerName)
				)
			end
			return false
		end
		return true
	end

	local function buildEffect(itemLink, winnerName, onConfirm, onFail)
		local attempt
		attempt = controller.createAttempt({
			rollSessionId = controller.getRollSessionId(),
			itemKey = controller.getItemKey(itemLink),
			itemLink = itemLink,
			winner = winnerName,
			source = "master_loot",
			executorContext = {
				executor = "loot_window",
				rollType = controller.lootState.currentRollType,
				raidNid = controller.getRaidNid(),
			},
			onConfirm = function()
				return onConfirm(attempt)
			end,
			onFail = function(reason)
				return onFail(attempt, reason)
			end,
		})
		return attempt
	end

	local function confirmMultiAttempt(self, attempt, ma, nextPosition)
		local registered, registerReason = attempt:RunCheckpoint("sequence_register_awarded_item", function()
			self.registerAwardedItem(1, ma.total)
			return true
		end)
		if not registered then
			return nil, registerReason
		end
		if ma.cancelled then
			return true
		end

		if nextPosition ~= nil then
			local advanced, advanceReason = attempt:RunCheckpoint("sequence_position_advance", function()
				ma.pos = nextPosition
				return true
			end)
			if not advanced then
				return nil, advanceReason
			end
		end

		local total = tonumber(ma.total) or (ma.winners and #ma.winners) or 0
		local pos = tonumber(ma.pos) or 1
		if pos > total then
			local announced, announceReason = attempt:RunCheckpoint("sequence_completion_announce", function()
				return announceCompletion(self, ma)
			end)
			if not announced then
				return nil, announceReason
			end
			local timeoutCancelled, timeoutReason =
				attempt:RunCheckpoint("sequence_cancel_progress_timeout", function()
					cancelTimeout(self, ma)
					ma.waitingForDecrement = false
					return true
				end)
			if not timeoutCancelled then
				return nil, timeoutReason
			end
			local delayCancelled, delayReason = attempt:RunCheckpoint("sequence_cancel_delay", function()
				cancelDelay(self, ma)
				return true
			end)
			if not delayCancelled then
				return nil, delayReason
			end
			local cleared, clearReason = attempt:RunCheckpoint("sequence_clear_state", function()
				ma.active = false
				if self.lootState.multiAward == ma then
					self.lootState.multiAward = nil
				end
				return true
			end)
			if not cleared then
				return nil, clearReason
			end
			local reset, resetReason = attempt:RunCheckpoint("sequence_item_count_reset", function()
				self.itemCount:Reset()
				return true
			end)
			if not reset then
				return nil, resetReason
			end
		else
			local armed, armReason = attempt:RunCheckpoint("sequence_progress_timeout", function()
				return armProgressTimeout(self, ma)
			end)
			if not armed then
				return nil, armReason
			end
		end

		return attempt:RunCheckpoint("sequence_refresh", function()
			if type(self.refresh) == "function" then
				local result = self.refresh()
				if result == false then
					return nil, "sequence_refresh_rejected"
				end
			end
			return true
		end)
	end

	function controller:Clear(resetItemCount)
		local ma = self.lootState.multiAward
		if ma then
			ma.waitingForDecrement = false
			cancelTimeout(self, ma)
			cancelDelay(self, ma)
		end
		self.lootState.multiAward = nil
		if resetItemCount then
			self.itemCount:Reset()
		end
	end

	function controller:CancelRemaining(reason)
		local ma = self.lootState.multiAward
		if not (ma and ma.active and not ma.cancelled) then
			return false, "no_active_multi_award"
		end

		local currentAwardInFlight = self.hasInFlight() == true
		ma.cancelled = true
		ma.cancelReason = reason
		ma.active = false
		ma.waitingForDecrement = false
		cancelTimeout(self, ma)
		cancelDelay(self, ma)
		if self.lootState.multiAward == ma then
			self.lootState.multiAward = nil
		end
		self.itemCount:Reset()
		if type(self.refresh) == "function" then
			self.refresh()
		end
		if currentAwardInFlight then
			return true, "current_award_in_flight"
		end
		return true
	end

	function controller:BuildWinners(target)
		local selectedCount, picked = getSelectedWinners(self)
		local plan = self.awardPlanner.BuildMultiAwardWinnersPlan({
			target = target,
			selectedCount = selectedCount,
			pickedWinners = picked,
		})
		if plan and plan.clearSelection then
			self.rollSelection:ClearAnchor()
		end
		if plan and plan.errType then
			return nil, plan.errType, plan.wantedCount, plan.pickedCount
		end
		return plan and plan.winners
	end

	function controller:Start(itemLink, available, winners)
		local admitted, admissionReason = self.admitAward()
		if not admitted then
			return nil, admissionReason
		end
		if type(winners) ~= "table" or #winners <= 0 then
			return false
		end
		for i = 1, #winners do
			if not validateLootBan(self, winners[i].name) then
				return nil, "loot_ban"
			end
		end

		self.itemCount:Set(#winners, false)
		local candidateSlots, candidateSlotMap = self.inventory.BuildMultiAwardSlotCandidates(itemLink)
		local timeout = tonumber(self.multiAwardTimeoutSeconds) or 0
		local plan = self.awardPlanner.BuildMultiAwardState({
			itemLink = itemLink,
			available = available,
			rollType = self.lootState.currentRollType,
			winners = winners,
			slotCandidates = candidateSlots,
			slotCandidateMap = candidateSlotMap,
			announceOnWin = type(self.getAnnounceOnWin) == "function" and self.getAnnounceOnWin() == true,
		})
		self.lootState.multiAward = plan and plan.state or nil

		if type(self.debug) == "function" then
			self.debug(
				Diag.D.LogMLMultiAwardStarted:format(
					tostring(itemLink),
					#winners,
					available,
					tconcat(candidateSlots or {}, ","),
					timeout
				)
			)
		end

		if not validateLootBan(self, winners[1].name) then
			self:Clear(true)
			return nil, "loot_ban"
		end

		local multiState = self.lootState.multiAward
		self.beginAwardSequence(#winners)
		local effect = buildEffect(itemLink, winners[1].name, function(attempt)
			return confirmMultiAttempt(self, attempt, multiState, nil)
		end, function(_, reason)
			self:Clear(true)
			if type(self.refresh) == "function" then
				self.refresh()
			end
			return reason ~= nil
		end)
		self.awardExecutor.effect = effect
		return self.awardExecutor:Assign(itemLink, winners[1].name, self.lootState.currentRollType, winners[1].roll)
	end

	function controller:TryMultipleCopies(itemLink, target, available)
		local winners, errType, wantedCount, pickedCount = self:BuildWinners(target)
		if errType == "empty_selection" then
			if type(self.warn) == "function" then
				self.warn(L.ErrNoWinnerSelected)
			end
			self.itemCount:Reset()
			return false
		end
		if errType == "not_enough_selection" then
			if type(self.warn) == "function" then
				self.warn(Diag.W.ErrMLMultiSelectNotEnough:format(wantedCount or 0, pickedCount or 0))
			end
			self.itemCount:Reset()
			return false
		end
		if errType == "empty_winners" or type(winners) ~= "table" or #winners <= 0 then
			if type(self.warn) == "function" then
				self.warn(L.ErrNoWinnerSelected)
			end
			self.itemCount:Reset()
			return false
		end

		local result, reason = self:Start(itemLink, available, winners)
		if result then
			return true
		end

		self:Clear(true)
		if type(self.refresh) == "function" then
			self.refresh()
		end
		return result, reason
	end

	function controller:TrySingleCopy(itemLink, winnerName)
		local admitted, admissionReason = self.admitAward()
		if not admitted then
			return nil, admissionReason
		end
		local selectedWinner = winnerName or self.lootState.winner
		if not selectedWinner or selectedWinner == "" then
			self.itemCount:Reset()
			if type(self.refresh) == "function" then
				self.refresh()
			end
			return false
		end
		if not validateLootBan(self, selectedWinner) then
			return nil, "loot_ban"
		end

		local effect = buildEffect(itemLink, selectedWinner, function(attempt)
			local registered, registerReason = attempt:RunCheckpoint("single_register_awarded_item", function()
				self.registerAwardedItem(1, 1)
				return true
			end)
			if not registered then
				return nil, registerReason
			end
			local reset, resetReason = attempt:RunCheckpoint("single_item_count_reset", function()
				self.itemCount:Reset()
				return true
			end)
			if not reset then
				return nil, resetReason
			end
			return attempt:RunCheckpoint("single_refresh", function()
				if type(self.refresh) == "function" then
					local result = self.refresh()
					if result == false then
						return nil, "single_refresh_rejected"
					end
				end
				return true
			end)
		end, function(_, reason)
			self.itemCount:Reset()
			if type(self.refresh) == "function" then
				self.refresh()
			end
			return reason ~= nil
		end)
		self.awardExecutor.effect = effect
		local result, reason = self.awardExecutor:Assign(
			itemLink,
			selectedWinner,
			self.lootState.currentRollType,
			findWinnerRoll(self, selectedWinner)
		)
		if result then
			return true
		end
		return result, reason
	end

	function controller:ContinueOnLootSlotCleared(clearedSlot)
		local ma = self.lootState.multiAward
		if not (ma and ma.active and not self.lootState.fromInventory) then
			return false
		end

		local slot = tonumber(clearedSlot)
		if slot then
			ma.lastClearedSlot = slot
		end
		if ma.scheduled then
			return false
		end

		local currentCount = Loot:GetLootWindowItemCountByKey(ma.itemKey)
		if ma.lastCount and currentCount >= ma.lastCount then
			return false
		end

		ma.waitingForDecrement = false
		cancelTimeout(self, ma)
		local refreshedSlots, refreshedSlotMap = self.inventory.BuildMultiAwardSlotCandidates(ma.itemLink)
		ma.slotCandidates = refreshedSlots
		ma.slotCandidateMap = refreshedSlotMap
		ma.lastCount = currentCount

		local idx = tonumber(ma.pos) or 1
		local entry = ma.winners and ma.winners[idx]
		if not entry then
			self:Clear(true)
			if type(self.refresh) == "function" then
				self.refresh()
			end
			return false
		end

		ma.scheduled = true
		local delay = tonumber(self.multiAwardDelaySeconds) or 0
		if delay < 0 then
			delay = 0
		end

		local scheduled, handle = pcall(self.scheduleTimer, function()
			local ma2 = self.lootState.multiAward
			if not (ma2 and ma2.active and ma2.scheduled and not self.lootState.fromInventory) then
				return
			end

			ma2.delayHandle = nil
			ma2.scheduled = false

			local idx2 = tonumber(ma2.pos) or 1
			local e2 = ma2.winners and ma2.winners[idx2]
			if not e2 then
				self:Clear(true)
				if type(self.refresh) == "function" then
					self.refresh()
				end
				return
			end
			if not validateLootBan(self, e2.name) then
				self:Clear(true)
				if type(self.refresh) == "function" then
					self.refresh()
				end
				return nil, "loot_ban"
			end
			local admitted, admissionReason = self.admitAward()
			if not admitted then
				self:Clear(true)
				if type(self.refresh) == "function" then
					self.refresh()
				end
				return nil, admissionReason
			end

			ma2.currentWinner = e2.name
			self.lootState.currentRollType = ma2.rollType
			if type(self.refresh) == "function" then
				self.refresh()
			end

			local effect = buildEffect(ma2.itemLink, e2.name, function(attempt)
				return confirmMultiAttempt(self, attempt, ma2, idx2 + 1)
			end, function(_, reason)
				self:Clear(true)
				if type(self.refresh) == "function" then
					self.refresh()
				end
				return reason ~= nil
			end)
			self.awardExecutor.effect = effect
			local ok = self.awardExecutor:Assign(ma2.itemLink, e2.name, ma2.rollType, e2.roll)
			if not ok then
				effect:Fail("execution_failed")
			end
		end, delay)
		if not scheduled or not handle then
			return stopAfterScheduleFailure(self, ma, true)
		end
		ma.delayHandle = handle

		return true
	end

	return controller
end

return AwardSequence
