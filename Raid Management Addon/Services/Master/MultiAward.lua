-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: local feature = addon.Database.GetFeatureShared()
-- exports: addon.Services.Master.MultiAward
-- events: none
-- notes: owns Master multi-award flow state, winner planning, and delayed continuation
local addon = select(2, ...)
local feature = addon.Database.GetFeatureShared()

local Master = feature.EnsureServiceNamespace("Master")
local Services = feature.Services

local MultiAward = Master.MultiAward or {}
Master.MultiAward = MultiAward

local Loot = assert(Services.Loot, "Master multi-award loot service is not initialized")
local L = feature.L
local Diag = feature.Diag

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

local function announceCompletion(controller, ma)
	if not (ma and ma.announceOnWin and not ma.congratsSent) then
		return
	end

	local names = collectWinnerNames(ma)
	if #names <= 0 then
		return
	end

	if type(controller.announce) == "function" then
		if #names == 1 then
			controller.announce(L.ChatAward:format(names[1], ma.itemLink))
		else
			controller.announce(L.ChatAwardMutiple:format(tconcat(names, ", "), ma.itemLink))
		end
	end
	ma.congratsSent = true
end

local function armProgressTimeout(controller, ma)
	if not (ma and ma.active and not controller.lootState.fromInventory) then
		return
	end

	local timeout = tonumber(controller.multiAwardTimeoutSeconds) or 0
	ma.waitingForDecrement = true
	if timeout <= 0 then
		return
	end

	cancelTimeout(controller, ma)
	local expectedLessThan = tonumber(ma.lastCount) or 0
	ma.timeoutHandle = controller.scheduleTimer(function()
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
end

function MultiAward.CreateController(opts)
	opts = opts or {}
	local controller = {
		awardPlanner = assert(opts.awardPlanner, "Master MultiAward award planner is not initialized"),
		inventory = assert(opts.inventory, "Master MultiAward inventory owner is not initialized"),
		lootState = assert(opts.lootState, "Master MultiAward loot state is not initialized"),
		rollSelection = assert(opts.rollSelection, "Master MultiAward roll selection owner is not initialized"),
		scheduleTimer = assert(opts.scheduleTimer, "Master MultiAward timer scheduler is not initialized"),
		cancelTimer = assert(opts.cancelTimer, "Master MultiAward timer canceller is not initialized"),
		announce = opts.announce,
		debug = opts.debug,
		warn = opts.warn,
		registerAwardedItem = assert(
			opts.registerAwardedItem,
			"Master MultiAward awarded-item recorder is not initialized"
		),
		refresh = opts.refresh,
		awardExecutor = assert(opts.awardExecutor, "Master MultiAward award executor is not initialized"),
		itemCount = assert(opts.itemCount, "Master MultiAward item-count owner is not initialized"),
		getAnnounceOnWin = opts.getAnnounceOnWin,
		multiAwardTimeoutSeconds = opts.multiAwardTimeoutSeconds,
		multiAwardDelaySeconds = opts.multiAwardDelaySeconds,
	}

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
		if type(winners) ~= "table" or #winners <= 0 then
			return false
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

		return self.awardExecutor:Assign(itemLink, winners[1].name, self.lootState.currentRollType, winners[1].roll)
	end

	function controller:FinalizeIfDone()
		local ma = self.lootState.multiAward
		if not ma then
			return false
		end

		local total = tonumber(ma.total) or (ma.winners and #ma.winners) or 0
		local pos = tonumber(ma.pos) or 1
		if pos <= total then
			return false
		end

		announceCompletion(self, ma)
		self:Clear(true)
		return true
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

		local result = self:Start(itemLink, available, winners)
		if result then
			self.registerAwardedItem(1)
			local done = self:FinalizeIfDone()
			if not done and self.lootState.multiAward and self.lootState.multiAward.active then
				armProgressTimeout(self, self.lootState.multiAward)
			end
			if type(self.refresh) == "function" then
				self.refresh()
			end
			return true
		end

		self:Clear(true)
		if type(self.refresh) == "function" then
			self.refresh()
		end
		return false
	end

	function controller:TrySingleCopy(itemLink, winnerName)
		local selectedWinner = winnerName or self.lootState.winner
		if not selectedWinner or selectedWinner == "" then
			self.itemCount:Reset()
			if type(self.refresh) == "function" then
				self.refresh()
			end
			return false
		end

		local result = self.awardExecutor:Assign(
			itemLink,
			selectedWinner,
			self.lootState.currentRollType,
			findWinnerRoll(self, selectedWinner)
		)
		if result then
			self.registerAwardedItem(1)
		end
		self.itemCount:Reset()
		if type(self.refresh) == "function" then
			self.refresh()
		end
		return result and true or false
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

		ma.delayHandle = self.scheduleTimer(function()
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

			ma2.currentWinner = e2.name
			self.lootState.currentRollType = ma2.rollType
			if type(self.refresh) == "function" then
				self.refresh()
			end

			local ok = self.awardExecutor:Assign(ma2.itemLink, e2.name, ma2.rollType, e2.roll)
			if ok then
				self.registerAwardedItem(1)
				ma2.pos = idx2 + 1
				local done = self:FinalizeIfDone()
				if not done and self.lootState.multiAward and self.lootState.multiAward.active then
					armProgressTimeout(self, self.lootState.multiAward)
				end
				if type(self.refresh) == "function" then
					self.refresh()
				end
			else
				self:Clear(true)
				if type(self.refresh) == "function" then
					self.refresh()
				end
			end
		end, delay)

		return true
	end

	return controller
end

local registry = feature.ModuleRegistry
if type(registry) == "table" and type(registry.AddModule) == "function" and type(registry.SetLoaded) == "function" then
	registry.AddModule("Services/Master/MultiAward", {
		deps = {
			"Init",
			"Modules/ModuleRegistry",
			"Services/Loot/Service",
			"Services/Loot/AwardPlanner",
			"Services/Loot/Inventory",
			"Services/Master/RollSelection",
		},
	})
	registry.SetLoaded("Services/Master/MultiAward")
end

return MultiAward
