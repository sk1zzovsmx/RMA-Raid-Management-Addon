function cases.loot_award_freezes_roll_intake(addon)
	local Rolls, lootState, scheduled = installLootHardeningRollsFixture(addon)
	local itemLink = "|cffa335ee|Hitem:19019:0:0:0:0:0:0:0|h[Test Item]|h|r"
	local session = Rolls:EnsureRollSession(itemLink, addon.C.rollTypes.FREE, "lootWindow")
	assertTrue(session and session.active == true, "roll session must start active")
	Rolls:SetExpectedWinners(2)

	Rolls:SetRollRecordingEnabled(true)
	assertTrue(Rolls:SubmitDebugRoll("Winner", 90), "initial roll must enter")
	assertTrue(Rolls:SubmitDebugRoll("Runner", 80), "second roll must enter")
	local beforeFreeze = Rolls:GetDisplayModel()
	assertEqual("Winner", Rolls:GetResolvedWinner(beforeFreeze), "initial winner differs")
	assertTrue(
		Rolls:StartCountdown(1, nil, function()
			Rolls:SetRollRecordingEnabled(true)
		end),
		"countdown must start"
	)
	local staleCountdownEnd = scheduled[#scheduled].callback
	staleCountdownEnd()
	local _, expiredRecord, expiredCanRoll = Rolls:GetRollStatus()
	assertEqual(true, expiredRecord, "non-blocking countdown expiry must leave intake open")
	assertEqual(true, expiredCanRoll, "non-blocking countdown expiry must accept rolls")

	local frozen, reason = Rolls:FreezeRollIntake("award")
	assertTrue(frozen ~= nil, reason or "freeze failed")
	assertEqual("award", reason, "freeze reason differs")
	local _, record, canRoll = Rolls:GetRollStatus()
	assertEqual(false, record, "award freeze must stop recording")
	assertEqual(false, canRoll, "award freeze must close intake")
	assertEqual(false, session.active, "award freeze must close the session window")
	assertTrue(session.endsAt ~= nil, "award freeze must record the closed session time")
	assertEqual(session, Rolls:GetRollSession(), "frozen session context must remain available to award consumers")
	local rebuilt = Rolls:GetDisplayModel()
	assertEqual("Winner", Rolls:GetResolvedWinner(rebuilt), "forced rebuild lost frozen winner")
	local rebuiltAgain = Rolls:GetDisplayModel()
	assertEqual("Winner", Rolls:GetResolvedWinner(rebuiltAgain), "repeated rebuild lost frozen winner")
	local frozenAgain, retryReason = Rolls:FreezeRollIntake("award_retry")
	assertTrue(frozenAgain ~= nil, retryReason or "repeated freeze rejected the retained session")
	assertEqual("award_retry", retryReason, "repeated freeze reason differs")
	assertEqual("Winner", Rolls:GetResolvedWinner(frozenAgain), "repeated freeze lost the frozen winner")
	assertEqual(2, frozenAgain.requiredWinnerCount, "repeated freeze lost the winner selection count")
	assertEqual(2, #frozenAgain.rows, "repeated freeze lost the frozen roll selection")
	local _, retryRecord, retryCanRoll = Rolls:GetRollStatus()
	assertEqual(false, retryRecord, "repeated freeze reopened roll recording")
	assertEqual(false, retryCanRoll, "repeated freeze reopened roll intake")
	assertEqual(false, session.active, "repeated freeze reactivated the roll session")

	local selectionState = {}
	local selected = {}
	local selection = {
		EnsureState = function()
			for key in pairs(selected) do
				selected[key] = nil
			end
		end,
		SetAnchor = function(_, name)
			selectionState.anchor = name
		end,
		GetAnchor = function()
			return selectionState.anchor
		end,
		GetCount = function()
			local count = 0
			for _ in pairs(selected) do
				count = count + 1
			end
			return count
		end,
		GetSelected = function()
			local names = {}
			for name in pairs(selected) do
				names[#names + 1] = name
			end
			table.sort(names)
			return names
		end,
		IsSelected = function(_, name)
			return selected[name] == true
		end,
		Toggle = function(_, name, preserve)
			if not preserve then
				for key in pairs(selected) do
					selected[key] = nil
				end
			end
			selected[name] = not selected[name]
		end,
	}
	local rollRows = {
		IsSelectableRow = function(row)
			return row and row.selectionAllowed ~= false
		end,
		BuildSelectionState = function(opts)
			local winners = opts.selectedWinners or {}
			return {
				pickMode = opts.selectionAllowed == true,
				msCount = #winners,
				winnerName = #winners == 1 and winners[1].name or nil,
				selectionAllowed = opts.selectionAllowed == true,
			}
		end,
		BuildModel = function(opts)
			return opts.rows, opts.rows
		end,
	}
	loadAddonFile(addon, "Raid Management Addon/Services/Master/RollSelection.lua")
	local rollSelection = addon.Services.Master.RollSelection.CreateController({
		getDisplayModel = function()
			return Rolls:GetDisplayModel()
		end,
		getSessionKey = function()
			local current = Rolls:GetRollSession()
			return current and current.id or nil
		end,
		isFromInventory = function()
			return true
		end,
		rollRows = rollRows,
		selection = selection,
		state = {},
	})
	local selectionModel = rollSelection:BuildModel(true)
	assertEqual(2, rollSelection:GetSelectedCount(), "forced selection rebuild lost selected count")
	local selectedWinners = rollSelection:GetSelectedWinnersOrdered(selectionModel.rows)
	assertEqual("Winner", selectedWinners[1].name, "forced selection rebuild changed first selected winner")
	assertEqual(90, selectedWinners[1].roll, "forced selection rebuild lost winner roll")
	assertEqual("Runner", selectedWinners[2].name, "forced selection rebuild changed second selected winner")

	loadAddonFile(addon, "Raid Management Addon/Services/Master/AwardSequence.lua")
	local assignedRoll
	local awardSequence = addon.Services.Master.AwardSequence.CreateController({
		awardPlanner = {
			BuildMultiAwardWinnersPlan = function(opts)
				return { winners = opts.pickedWinners }
			end,
			BuildMultiAwardState = function()
				return { state = nil }
			end,
		},
		inventory = {
			BuildMultiAwardSlotCandidates = function()
				return {}, {}
			end,
		},
		lootState = lootState,
		rollSelection = rollSelection,
		scheduleTimer = function()
			return {}
		end,
		cancelTimer = function() end,
		registerAwardedItem = function() end,
		awardExecutor = {
			Assign = function(_, _, _, _, roll)
				assignedRoll = roll
				return true
			end,
		},
		itemCount = { Set = function() end, Reset = function() end },
		createAttempt = function()
			return {
				Confirm = function()
					return true
				end,
				Fail = function()
					return true
				end,
			}
		end,
		getRollSessionId = function()
			return session.id
		end,
		getItemKey = function()
			return "item:19019"
		end,
		getRaidNid = function()
			return 1
		end,
	})
	local planned = awardSequence:BuildWinners(2)
	assertEqual(2, #planned, "AwardSequence lost frozen multi-selection")
	assertEqual("Winner", planned[1].name, "AwardSequence changed first frozen winner")
	assertTrue(awardSequence:TrySingleCopy(itemLink, "Winner"), "single award lookup must execute")
	assertEqual(90, assignedRoll, "single award lookup lost frozen winner roll")

	Rolls:CHAT_MSG_SYSTEM("LatePlayer 100")
	staleCountdownEnd()
	local _, recordAfter, canRollAfter = Rolls:GetRollStatus()
	assertEqual(false, recordAfter, "stale countdown callback reopened recording")
	assertEqual(false, canRollAfter, "stale countdown callback reopened intake")
	assertEqual("Winner", Rolls:GetResolvedWinner(rebuiltAgain), "late roll changed frozen winner")
	assertEqual(2, #Rolls:GetRolls(), "late roll mutated frozen history")
	Rolls:SetRollRecordingEnabled(true)
	local replacement = Rolls:GetRollSession()
	assertTrue(replacement ~= session, "new intake must replace the frozen session")
	assertTrue(replacement.active == true, "replacement session must be active")
	Rolls:ClearRolls()
	assertEqual(nil, Rolls:GetRollSession(), "normal clear must detach the replacement session")
	local missing, missingReason = Rolls:FreezeRollIntake("award")
	assertEqual(nil, missing, "freeze without a retained session must fail")
	assertEqual("no_active_roll_session", missingReason, "missing-session freeze reason differs")
	print("PASS loot_award_freezes_roll_intake")
end

function cases.loot_duplicate_award_is_rejected_in_flight(addon)
	local admissions = {
		{
			"button",
			function(fixture)
				return fixture.master._Private.BtnAward(nil, nil)
			end,
		},
		{
			"manual-grid",
			function(fixture)
				return fixture.master._Private.AcceptManualGridAward({
					itemLink = "item:19019",
					playerName = "Winner",
					rollType = 4,
					rollValue = 90,
				})
			end,
		},
		{
			"hold",
			function(fixture)
				return fixture.master._Private.BtnHold(nil, nil)
			end,
		},
		{
			"single",
			function(fixture)
				return fixture.awardSequence:TrySingleCopy("item:19019", "Winner")
			end,
		},
		{
			"multi",
			function(fixture)
				return fixture.awardSequence:Start("item:19019", 2, {
					{ name = "Winner", roll = 90 },
					{ name = "Runner", roll = 80 },
				})
			end,
		},
	}
	for i = 1, #admissions do
		local name, enter = admissions[i][1], admissions[i][2]
		local admitted = installLootHardeningMasterFixture(newAddon())
		local ok, reason = enter(admitted)
		assertTrue(ok, name .. " admission failed: " .. tostring(reason))
		assertEqual(1, admitted.attempts, name .. " admission created the wrong attempt count")
		assertEqual(1, admitted.assignments, name .. " admission created the wrong physical effect count")
		assertEqual(1, admitted.timers, name .. " admission created the wrong confirmation timer count")
	end

	local fixture = installLootHardeningMasterFixture(addon)
	local master = fixture.master
	local confirmation = master._awardConfirmation
	local pendingEffect = {
		RunCheckpoint = function(_, _, callback, ...)
			return callback(...)
		end,
		Confirm = function()
			return true
		end,
		Fail = function()
			return true
		end,
	}
	assertTrue(
		confirmation:Queue({
			itemLink = "item:19019",
			itemIndex = 1,
			playerName = "Winner",
			effect = pendingEffect,
		}),
		"initial confirmation must enter"
	)
	local baselineTimers = fixture.timers
	local baselineAttempts = fixture.attempts

	local ok, reason = master._Private.BtnAward(nil, nil)
	assertEqual(nil, ok, "button reentry must fail closed")
	assertEqual("award_in_flight", reason, "button reentry reason differs")
	ok, reason = master._Private.AcceptManualGridAward({ itemLink = "item:19019", playerName = "Winner" })
	assertEqual(nil, ok, "manual-grid reentry must fail closed")
	assertEqual("award_in_flight", reason, "manual-grid reentry reason differs")
	ok, reason = master._Private.BtnHold(nil, nil)
	assertEqual(nil, ok, "direct assignment reentry must fail closed")
	assertEqual("award_in_flight", reason, "direct assignment reentry reason differs")
	ok, reason = fixture.awardSequence:TrySingleCopy("item:19019", "Winner")
	assertEqual(nil, ok, "single sequence reentry must fail closed")
	assertEqual("award_in_flight", reason, "single sequence reentry reason differs")
	ok, reason =
		fixture.awardSequence:Start("item:19019", 2, { { name = "Winner", roll = 90 }, { name = "Runner", roll = 80 } })
	assertEqual(nil, ok, "multi sequence reentry must fail closed")
	assertEqual("award_in_flight", reason, "multi sequence reentry reason differs")
	assertEqual(0, fixture.assignments, "duplicate award reached physical assignment")
	assertEqual(baselineAttempts, fixture.attempts, "duplicate award created another attempt")
	assertEqual(baselineTimers, fixture.timers, "duplicate award created another timer")

	assertTrue(confirmation:Confirm(1), "first award must confirm")
	assertEqual(false, confirmation:HasInFlight(), "confirmation must release in-flight guard")
	assertTrue(
		fixture.awardSequence:Start("item:19019", 2, { { name = "Winner", roll = 90 }, { name = "Runner", roll = 80 } }),
		"confirmed multi sequence must start"
	)
	assertEqual(1, fixture.assignments, "first legitimate multi assignment did not execute")
	assertTrue(confirmation:Confirm(1), "first multi assignment must confirm")
	local checkpoints = fixture.lastAttempt:GetState().checkpoints
	assertEqual(true, checkpoints.provisional_attribution, "provisional attribution checkpoint differs")
	assertEqual(true, checkpoints.distribution_notification, "distribution notification checkpoint differs")
	assertEqual(true, checkpoints.player_counter, "player counter checkpoint differs")
	assertTrue(fixture.awardSequence:ContinueOnLootSlotCleared(1), "next multi assignment must schedule")
	fixture.timerCallbacks[#fixture.timerCallbacks]()
	assertEqual(2, fixture.assignments, "legitimate next multi assignment did not execute")
	assertEqual(baselineAttempts + 2, fixture.attempts, "legitimate multi entries must create exactly two attempts")
	print("PASS loot_duplicate_award_is_rejected_in_flight")
end

function cases.loot_direct_assignment_admits_before_mutation(addon)
	local fixture = installLootHardeningMasterFixture(addon)
	local effect = { MarkUncertain = function() end, Fail = function() end }
	assertTrue(
		fixture.master._awardConfirmation:Queue({
			itemLink = "item:19019",
			itemIndex = 1,
			playerName = "Winner",
			effect = effect,
		}),
		"fixture must own one pending award"
	)
	local assignmentsBefore = fixture.assignments
	local rollTypeBefore = fixture.lootState.currentRollType
	local timersBefore = fixture.timers
	local admitted, reason = fixture.master._Private.BtnHold(nil, "LeftButton")
	assertEqual(nil, admitted, "direct assignment must reject")
	assertEqual("award_in_flight", reason, "admission reason differs")
	assertEqual(assignmentsBefore, fixture.assignments, "rejected admission assigned loot")
	assertEqual(rollTypeBefore, fixture.lootState.currentRollType, "rejected admission changed roll type")
	assertEqual(timersBefore, fixture.timers, "rejected admission changed timer ownership")
	print("PASS loot_direct_assignment_admits_before_mutation")
end

function cases.loot_direct_assignment_rejects_in_flight_trade_before_mutation(addon)
	local entries = {
		{
			"hold",
			function(fixture)
				return fixture.master._Private.BtnHold(nil, "LeftButton")
			end,
		},
		{
			"bank",
			function(fixture)
				return fixture.master._Private.BtnBank(nil, "LeftButton")
			end,
		},
		{
			"disenchant",
			function(fixture)
				return fixture.master._Private.BtnDisenchant(nil, "LeftButton")
			end,
		},
	}
	for i = 1, #entries do
		local fixture = installLootHardeningMasterFixture(i == 1 and addon or newAddon())
		fixture.tradeInFlight = true
		local assignmentsBefore = fixture.assignments
		local rollTypeBefore = fixture.lootState.currentRollType
		local timersBefore = fixture.timers
		local refreshesBefore = fixture.refreshCalls
		local admitted, reason = entries[i][2](fixture)
		assertEqual(nil, admitted, entries[i][1] .. " direct assignment must reject")
		assertEqual("trade_in_flight", reason, entries[i][1] .. " admission reason differs")
		assertEqual(assignmentsBefore, fixture.assignments, entries[i][1] .. " rejection assigned loot")
		assertEqual(rollTypeBefore, fixture.lootState.currentRollType, entries[i][1] .. " rejection changed roll type")
		assertEqual(timersBefore, fixture.timers, entries[i][1] .. " rejection changed timer ownership")
		assertEqual(refreshesBefore, fixture.refreshCalls, entries[i][1] .. " rejection refreshed UI state")
	end
	print("PASS loot_direct_assignment_rejects_in_flight_trade_before_mutation")
end

function cases.loot_award_prerequisites_and_sequence_retry_are_ordered(addon)
	local fixture = installLootHardeningMasterFixture(addon)
	local sequence = fixture.awardSequence
	local confirmation = fixture.master._awardConfirmation
	fixture.lootState.selectedItemCount = 3
	assertTrue(
		sequence:Start("item:19019", 3, {
			{ name = "Winner", roll = 90 },
			{ name = "Runner", roll = 80 },
			{ name = "Third", roll = 70 },
		}),
		"multi award must start"
	)

	fixture.rejectDistribution = true
	local confirmed = confirmation:Confirm(1)
	assertEqual(nil, confirmed, "distribution rejection must retain confirmation")
	assertEqual(0, fixture.counterCalls, "counter ran before distribution prerequisite")
	assertEqual(nil, fixture.lootState.itemTraded, "sequence advanced before distribution prerequisite")
	assertEqual(2, fixture.lootState.multiAward.pos, "sequence position changed before prerequisites")

	fixture.rejectDistribution = false
	fixture.rejectCounter = true
	confirmed = confirmation:Confirm(1)
	assertEqual(nil, confirmed, "counter rejection must retain confirmation")
	assertEqual(2, fixture.distributionCalls, "failed distribution should retry once")
	assertEqual(1, fixture.counterCalls, "counter attempt count differs")
	assertEqual(nil, fixture.lootState.itemTraded, "sequence advanced before counter prerequisite")

	fixture.rejectCounter = false
	assertEqual(true, confirmation:Confirm(1), "prerequisite retry must confirm")
	assertEqual(2, fixture.distributionCalls, "completed distribution checkpoint repeated")
	assertEqual(2, fixture.counterCalls, "counter retry count differs")
	assertEqual(1, fixture.lootState.itemTraded, "register checkpoint did not run once")

	assertTrue(sequence:ContinueOnLootSlotCleared(1), "next award must schedule")
	fixture.timerCallbacks[#fixture.timerCallbacks]()
	assertEqual(2, fixture.assignments, "second award did not execute")
	fixture.throwRefresh = true
	assertEqual(nil, confirmation:Confirm(1), "refresh throw must remain retryable")
	assertEqual(2, fixture.lootState.itemTraded, "register checkpoint did not commit before refresh failure")
	assertEqual(3, fixture.lootState.multiAward.pos, "position checkpoint did not commit before refresh failure")
	fixture.throwRefresh = false
	assertEqual(true, confirmation:Confirm(1), "refresh retry must complete")
	assertEqual(3, fixture.distributionCalls, "completed distribution checkpoint repeated during sequence retries")
	assertEqual(3, fixture.counterCalls, "completed counter checkpoint repeated during sequence retries")
	local state = fixture.lastAttempt:GetState()
	assertEqual(true, state.checkpoints.sequence_register_awarded_item, "register checkpoint missing")
	assertEqual(true, state.checkpoints.sequence_position_advance, "position checkpoint missing")
	assertEqual(true, state.checkpoints.sequence_progress_timeout, "progress timeout checkpoint missing")
	assertEqual(true, state.checkpoints.sequence_refresh, "refresh checkpoint missing")
	print("PASS loot_award_prerequisites_and_sequence_retry_are_ordered")
end

function cases.loot_award_finalize_and_single_reset_are_retry_safe(addon)
	local fixture = installLootHardeningMasterFixture(addon)
	fixture.announceOnWin = true
	local confirmation = fixture.master._awardConfirmation
	assertTrue(
		fixture.awardSequence:Start("item:19019", 1, { { name = "Winner", roll = 90 } }),
		"final multi award must start"
	)
	fixture.throwAnnouncement = true
	assertEqual(nil, confirmation:Confirm(1), "announcement throw must remain retryable")
	assertTrue(fixture.lootState.multiAward ~= nil, "announcement failure cleared multi state")
	fixture.throwAnnouncement = false
	fixture.throwItemReset = true
	local resetConfirmed, resetReason = confirmation:Confirm(1)
	assertEqual(nil, resetConfirmed, "item reset throw must remain retryable")
	assertTrue(
		tostring(resetReason):find("item reset exploded", 1, true) ~= nil,
		"unexpected reset failure: " .. tostring(resetReason)
	)
	assertEqual(nil, fixture.lootState.multiAward, "state clear did not commit before reset failure")
	assertEqual(1, fixture.itemResetCalls, "first item reset attempt count differs")
	assertEqual(true, confirmation:Confirm(1), "item reset retry must confirm")
	assertEqual(2, fixture.announcementCalls, "successful announcement repeated after reset retry")
	assertEqual(2, fixture.itemResetCalls, "item reset retry count differs")
	local checkpoints = fixture.lastAttempt:GetState().checkpoints
	assertEqual(true, checkpoints.sequence_cancel_progress_timeout, "timeout cancel checkpoint missing")
	assertEqual(true, checkpoints.sequence_cancel_delay, "delay cancel checkpoint missing")
	assertEqual(true, checkpoints.sequence_clear_state, "state clear checkpoint missing")
	assertEqual(true, checkpoints.sequence_item_count_reset, "item reset checkpoint missing")

	local single = installLootHardeningMasterFixture(addon)
	local singleConfirmation = single.master._awardConfirmation
	assertTrue(single.awardSequence:TrySingleCopy("item:19019", "Winner"), "single award must start")
	single.throwItemReset = true
	assertEqual(nil, singleConfirmation:Confirm(1), "single reset throw must remain retryable")
	assertEqual(true, singleConfirmation:Confirm(1), "single reset retry must confirm")
	assertEqual(2, single.itemResetCalls, "single reset retry count differs")
	assertEqual(
		true,
		single.lastAttempt:GetState().checkpoints.single_item_count_reset,
		"single reset checkpoint missing"
	)
	print("PASS loot_award_finalize_and_single_reset_are_retry_safe")
end

function cases.loot_multi_award_cancellation_preserves_current_and_future_admission(addon)
	local fixture = installLootHardeningMasterFixture(addon)
	local sequence = fixture.awardSequence
	local confirmation = fixture.master._awardConfirmation
	fixture.mutateSelectedCountOnReset = true
	fixture.lootState.selectedItemCount = 3
	fixture.windowItemCount = 2
	assertTrue(
		sequence:Start("item:19019", 3, {
			{ name = "Winner", roll = 90 },
			{ name = "Runner", roll = 80 },
			{ name = "Third", roll = 70 },
		}),
		"multi award must start"
	)
	assertEqual(true, confirmation:Confirm(1), "first award must confirm")
	assertEqual(1, fixture.lootState.itemTraded, "first confirmed award count differs")
	local cancelledBeforeContinuation = #fixture.cancelledTimerHandles
	fixture.windowItemCount = 1
	assertTrue(sequence:ContinueOnLootSlotCleared(1), "next award delay must schedule")
	local refreshBeforeCancel = fixture.refreshCalls
	local cancelled, reason = sequence:CancelRemaining("operator")
	assertEqual(true, cancelled, "future awards must be cancellable during delay")
	assertEqual(nil, reason, "completed current award must not report in-flight ownership")
	assertEqual(refreshBeforeCancel + 1, fixture.refreshCalls, "cancellation must refresh exactly once")
	assertEqual(1, fixture.lootState.itemTraded, "cancellation changed confirmed award count")
	assertEqual(1, fixture.lootState.selectedItemCount, "fixture did not model cancellation item-count reset")
	assertEqual(nil, fixture.lootState.multiAward, "cancellation retained future sequence state")
	assertEqual(
		cancelledBeforeContinuation + 2,
		#fixture.cancelledTimerHandles,
		"progress and delay handles were not both cancelled"
	)
	fixture.timerCallbacks[#fixture.timerCallbacks]()
	assertEqual(1, fixture.assignments, "cancelled delay started the next winner")

	fixture.windowItemCount = 2
	assertTrue(
		sequence:Start("item:19019", 2, {
			{ name = "Fresh", roll = 70 },
			{ name = "FreshTwo", roll = 60 },
		}),
		"fresh sequence must be admitted"
	)
	assertEqual(2, fixture.assignments, "fresh sequence did not execute")
	assertEqual(nil, fixture.lootState.itemTraded, "fresh sequence inherited canceled sequence progress")
	assertEqual(true, confirmation:Confirm(1), "fresh first award must confirm")
	assertEqual(1, fixture.lootState.itemTraded, "fresh sequence reset before its own target")
	fixture.windowItemCount = 1
	assertTrue(sequence:ContinueOnLootSlotCleared(2), "fresh second award must schedule")
	fixture.timerCallbacks[#fixture.timerCallbacks]()
	assertEqual(true, confirmation:Confirm(1), "fresh second award must confirm")
	assertEqual(0, fixture.lootState.itemTraded, "fresh sequence did not reset at its own terminal target")
	assertEqual(1, fixture.rollClearCalls or 0, "fresh sequence cleared rolls before or after its own terminal point")

	local waiting = installLootHardeningMasterFixture(newAddon())
	waiting.lootState.selectedItemCount = 2
	assertTrue(
		waiting.awardSequence:Start("item:19019", 2, {
			{ name = "Winner", roll = 90 },
			{ name = "Runner", roll = 80 },
		}),
		"progress-timeout sequence must start"
	)
	assertEqual(true, waiting.master._awardConfirmation:Confirm(1), "progress-timeout current award must confirm")
	local cancelledBeforeTimeout = #waiting.cancelledTimerHandles
	local timeoutRefreshes = waiting.refreshCalls
	assertEqual(true, waiting.awardSequence:CancelRemaining("operator"), "progress timeout must be cancellable")
	assertEqual(cancelledBeforeTimeout + 1, #waiting.cancelledTimerHandles, "progress timeout handle was not cancelled")
	assertEqual(timeoutRefreshes + 1, waiting.refreshCalls, "timeout cancellation must refresh exactly once")
	waiting.timerCallbacks[#waiting.timerCallbacks]()
	assertEqual(1, waiting.assignments, "cancelled progress timeout started the next winner")

	local current = installLootHardeningMasterFixture(newAddon())
	current.lootState.selectedItemCount = 2
	current.mutateSelectedCountOnReset = true
	assertTrue(
		current.awardSequence:Start("item:19019", 2, {
			{ name = "Winner", roll = 90 },
			{ name = "Runner", roll = 80 },
		}),
		"current-attempt sequence must start"
	)
	local currentCancelled, currentReason = current.awardSequence:CancelRemaining("operator")
	assertEqual(true, currentCancelled, "future entries must cancel while current award is irreversible")
	assertEqual("current_award_in_flight", currentReason, "cancellation must disclose current award ownership")
	assertEqual(1, current.assignments, "cancellation pretended to reverse current assignment")
	assertEqual(true, current.master._awardConfirmation:Confirm(1), "current award must retain confirmation ownership")
	assertEqual(1, current.lootState.itemTraded, "current confirmed award was not preserved")
	assertEqual(false, current.awardSequence:ContinueOnLootSlotCleared(1), "cancelled sequence continued")
	current.windowItemCount = 2
	assertTrue(
		current.awardSequence:Start("item:19019", 2, {
			{ name = "Fresh", roll = 70 },
			{ name = "FreshTwo", roll = 60 },
		}),
		"fresh sequence after current terminal must start"
	)
	assertEqual(nil, current.lootState.itemTraded, "fresh sequence after current terminal inherited old progress")
	assertEqual(true, current.master._awardConfirmation:Confirm(1), "fresh current first award must confirm")
	assertEqual(1, current.lootState.itemTraded, "fresh current sequence reset too early")
	current.windowItemCount = 1
	assertTrue(current.awardSequence:ContinueOnLootSlotCleared(2), "fresh current second award must schedule")
	current.timerCallbacks[#current.timerCallbacks]()
	assertEqual(true, current.master._awardConfirmation:Confirm(1), "fresh current second award must confirm")
	assertEqual(0, current.lootState.itemTraded, "fresh current sequence did not reset at terminal target")
	assertEqual(1, current.rollClearCalls or 0, "fresh current sequence roll reset count differs")
	print("PASS loot_multi_award_cancellation_preserves_current_and_future_admission")
end

function cases.loot_multi_award_clear_button_is_truthful(addon)
	local fixture = installLootHardeningMasterFixture(addon)
	addon.L.BtnCancelRemainingAwards = "Cancel Remaining Awards"
	addon.L.TipMasterCancelRemainingAwards = "Cancel future awards; the current transfer may still finish."
	local buttonState = addon.Services.Master.ButtonState
	fixture.lootState.multiAward = { active = true, cancelled = false }
	local state = buttonState.BuildState({
		lootState = fixture.lootState,
		tooltipState = { clear = "Clear recorded rolls." },
		hasLootAccess = false,
		workflowState = {},
	})
	assertEqual("Cancel Remaining Awards", state.clearText, "active multi-award clear label differs")
	assertEqual(addon.L.TipMasterCancelRemainingAwards, state.clearTooltip, "active multi-award tooltip differs")
	assertEqual(true, state.canClear, "active multi-award cancellation must remain available")

	local clearRollCalls = 0
	addon.Services.Rolls.ClearRolls = function()
		clearRollCalls = clearRollCalls + 1
	end
	local cancelCalls = 0
	fixture.awardSequence.CancelRemaining = function(_, cancelReason)
		cancelCalls = cancelCalls + 1
		assertEqual("operator", cancelReason, "button cancellation reason differs")
		return true
	end
	assertEqual(true, fixture.master._Private.BtnClear(nil, nil), "active clear must return cancellation result")
	assertEqual(1, cancelCalls, "active clear did not delegate to AwardSequence")
	assertEqual(0, clearRollCalls, "active clear erased rolls")
	fixture.lootState.multiAward = nil
	fixture.master._Private.BtnClear(nil, nil)
	assertEqual(1, clearRollCalls, "normal clear-roll behavior changed")
	print("PASS loot_multi_award_clear_button_is_truthful")
end

function cases.loot_slot_clear_perf_spans_close_on_all_exits(addon)
	local fixture = installLootHardeningMasterFixture(addon)
	local finishes = {}
	local starts = 0
	addon.hasPerf = true
	addon._PerfStart = function()
		starts = starts + 1
		return starts
	end
	addon._PerfFinish = function(_, label)
		finishes[#finishes + 1] = label
	end
	fixture.windowItemCount = 1
	assertTrue(
		fixture.awardSequence:Start("item:19019", 2, {
			{ name = "Winner", roll = 90 },
			{ name = "Runner", roll = 80 },
		}),
		"perf sequence must start"
	)
	assertEqual(true, fixture.master:LOOT_SLOT_CLEARED(1), "auto-managed continuation must return its result")
	local finishCounts = {}
	for i = 1, #finishes do
		finishCounts[finishes[i]] = (finishCounts[finishes[i]] or 0) + 1
	end
	assertEqual(1, finishCounts["Master.LOOT_SLOT_CLEARED ContinueAward"], "continuation span did not close")
	assertEqual(1, finishCounts["Master.LOOT_SLOT_CLEARED Total"], "total span did not close")

	fixture.master._awardConfirmation.Confirm = function()
		return nil, "retry"
	end
	finishes = {}
	local ok, failureReason = fixture.master:LOOT_SLOT_CLEARED(1)
	assertEqual(nil, ok, "failed confirmation must preserve nil result")
	assertEqual("retry", failureReason, "failed confirmation reason differs")
	local closedTotal = false
	for i = 1, #finishes do
		if finishes[i] == "Master.LOOT_SLOT_CLEARED Total" then
			closedTotal = true
		end
	end
	assertEqual(true, closedTotal, "failed confirmation exit did not close total span")
	print("PASS loot_slot_clear_perf_spans_close_on_all_exits")
end

function cases.loot_multi_award_twenty_slot_work_is_bounded(addon)
	local fixture = installLootHardeningMasterFixture(addon)
	local winners = {}
	for i = 1, 20 do
		winners[i] = { name = "Winner" .. tostring(i), roll = 101 - i }
	end
	fixture.windowItemCount = 20
	assertTrue(fixture.awardSequence:Start("item:19019", 20, winners), "bounded sequence must start")
	for i = 1, 20 do
		assertEqual(
			true,
			fixture.master._awardConfirmation:Confirm(1),
			"bounded confirmation failed at " .. tostring(i)
		)
		if i < 20 then
			fixture.windowItemCount = 20 - i
			assertTrue(
				fixture.awardSequence:ContinueOnLootSlotCleared(i),
				"bounded continuation failed at " .. tostring(i)
			)
			fixture.timerCallbacks[#fixture.timerCallbacks]()
		end
	end
	assertEqual(19, fixture.lootCountScans, "loot count scans exceed one per continuation")
	assertEqual(20, fixture.candidateScans, "candidate scans exceed initial plus one per continuation")
	assertEqual(20, fixture.distributionCalls, "RMADist completion sends differ from confirmed awards")
	assertEqual(
		39,
		fixture.refreshCalls,
		"refresh requests differ from one transition plus one confirmation per later award"
	)
	print("PASS loot_multi_award_twenty_slot_work_is_bounded scans=19 candidates=20 sends=20 refreshes=39")
end

function cases.loot_slot_clear_stops_after_matched_confirmation_failure(addon)
	local fixture = installLootHardeningMasterFixture(addon)
	local confirmation = fixture.master._awardConfirmation
	local continueCalls = 0
	local continue = fixture.awardSequence.ContinueOnLootSlotCleared
	fixture.awardSequence.ContinueOnLootSlotCleared = function(self, slot)
		continueCalls = continueCalls + 1
		return continue(self, slot)
	end
	fixture.rejectDistribution = true
	assertTrue(
		fixture.awardSequence:Start("item:19019", 2, {
			{ name = "Winner", roll = 90 },
			{ name = "Runner", roll = 80 },
		}),
		"multi award must start"
	)
	local result = fixture.master:LOOT_SLOT_CLEARED(1)
	assertEqual(nil, result, "matched failed confirmation must stop slot processing")
	assertEqual(0, continueCalls, "failed confirmation continued the multi award")
	assertEqual(0, fixture.fetchCalls or 0, "failed confirmation reset loot-window state")
	assertEqual(true, confirmation:HasInFlight(), "failed confirmation lost ownership")
	fixture.timerCallbacks[1]()
	fixture.timerCallbacks[#fixture.timerCallbacks]()
	assertEqual(false, confirmation:HasInFlight(), "unresolved controller confirmation retained ownership")
	assertEqual(nil, fixture.lootState.multiAward, "unresolved controller confirmation kept future multi entries")
	assertEqual("failed", fixture.lastAttempt:GetState().state, "present target timeout must become a known failure")
	print("PASS loot_slot_clear_stops_after_matched_confirmation_failure")
end

function cases.loot_award_confirmation_expiry_is_bounded(addon)
	addon.Services = {
		EnsureNamespace = function(name)
			addon.Services[name] = addon.Services[name] or {}
			return addon.Services[name]
		end,
	}
	loadAddonFile(addon, "Raid Management Addon/Services/Master/AwardAttempt.lua")
	loadAddonFile(addon, "Raid Management Addon/Services/Master/AwardConfirmation.lua")
	local scheduled, warnings, refreshes, unresolved, success, cancelled = {}, 0, 0, 0, 0, 0
	local effect = addon.Services.Master.AwardAttempt.CreateExecuting({
		onConfirm = function()
			success = success + 1
			return true
		end,
		onFail = function()
			cancelled = cancelled + 1
			return true
		end,
	})
	local owner = addon.Services.Master.AwardConfirmation.Create({
		timeoutSeconds = 4,
		reconciliationSeconds = 8,
		scheduleTimer = function(callback, delay)
			scheduled[#scheduled + 1] = { callback = callback, delay = delay }
			return callback
		end,
		cancelTimer = function() end,
		requestRefresh = function()
			refreshes = refreshes + 1
		end,
		warnFailure = function()
			warnings = warnings + 1
		end,
		warnUncertain = function()
			warnings = warnings + 1
		end,
		warnTimeout = function()
			warnings = warnings + 1
		end,
		warnUnresolved = function()
			warnings = warnings + 1
		end,
		onUnresolved = function()
			unresolved = unresolved + 1
		end,
		confirmProvisional = function()
			return true
		end,
	})
	assertTrue(
		owner:Queue({ itemLink = "item:19019", itemIndex = 1, playerName = "Winner", effect = effect }),
		"entry must queue"
	)
	assertEqual(1, #scheduled, "queue must own one confirmation timer")
	scheduled[1].callback()
	assertEqual(2, #scheduled, "timeout must schedule one reconciliation expiry")
	assertEqual(8, scheduled[2].delay, "expiry must use pending-award TTL")
	scheduled[2].callback()
	assertEqual(false, owner:HasInFlight(), "expiry must release ownership")
	local state = effect:GetState()
	assertEqual("uncertain", state.state, "expiry must remain uncertain")
	assertEqual("confirmation_unresolved", state.failureReason, "expiry reason differs")
	assertEqual(1, unresolved, "unresolved owner callback count differs")
	assertEqual(2, warnings, "timeout and unresolved warnings must each emit once")
	assertEqual(2, refreshes, "timeout and unresolved refreshes must each emit once")
	assertEqual(0, success, "expiry published success")
	assertEqual(0, cancelled, "expiry published known-failure cancellation")
	print("PASS loot_award_confirmation_expiry_is_bounded")
end

function cases.loot_award_confirmation_expiry_survives_presentation_failures(addon)
	local function runScenario(mode)
		addon.Services = {
			EnsureNamespace = function(name)
				addon.Services[name] = addon.Services[name] or {}
				return addon.Services[name]
			end,
		}
		loadAddonFile(addon, "Raid Management Addon/Services/Master/AwardAttempt.lua")
		loadAddonFile(addon, "Raid Management Addon/Services/Master/AwardConfirmation.lua")
		local timeoutCallback, scheduleCalls, cleanupCalls, warnCalls, refreshCalls = nil, 0, 0, 0, 0
		local effect = addon.Services.Master.AwardAttempt.CreateExecuting({
			onConfirm = function()
				return true
			end,
		})
		local owner = addon.Services.Master.AwardConfirmation.Create({
			timeoutSeconds = 4,
			reconciliationSeconds = 8,
			scheduleTimer = function(callback)
				scheduleCalls = scheduleCalls + 1
				if scheduleCalls == 1 then
					timeoutCallback = callback
					return callback
				end
				if mode == "throw" then
					error("expiry schedule exploded")
				end
				return nil
			end,
			cancelTimer = function() end,
			requestRefresh = function()
				refreshCalls = refreshCalls + 1
				error("refresh exploded")
			end,
			warnFailure = function() end,
			warnUncertain = function() end,
			warnTimeout = function()
				warnCalls = warnCalls + 1
				error("timeout warning exploded")
			end,
			warnUnresolved = function()
				warnCalls = warnCalls + 1
				error("unresolved warning exploded")
			end,
			onUnresolved = function()
				cleanupCalls = cleanupCalls + 1
				error("cleanup exploded")
			end,
			confirmProvisional = function()
				return true
			end,
		})
		assertTrue(
			owner:Queue({ itemLink = "item:19019", itemIndex = 1, playerName = "Winner", effect = effect }),
			"scenario must queue"
		)
		local ok = pcall(timeoutCallback)
		assertEqual(true, ok, mode .. " timeout path leaked callback failure")
		assertEqual(false, owner:HasInFlight(), mode .. " expiry failure retained ownership")
		assertEqual("uncertain", effect:GetState().state, mode .. " expiry changed terminal state")
		assertEqual("confirmation_unresolved", effect:GetState().failureReason, mode .. " expiry reason differs")
		assertEqual(1, cleanupCalls, mode .. " cleanup callback attempt count differs")
		assertEqual(2, warnCalls, mode .. " presentation warnings did not both attempt")
		assertEqual(2, refreshCalls, mode .. " presentation refreshes did not both attempt")
	end
	runScenario("nil")
	runScenario("throw")
	print("PASS loot_award_confirmation_expiry_survives_presentation_failures")
end

function cases.loot_inventory_slot_validation_is_strict(addon)
	local currentLink
	_G.GetNumLootItems = function()
		return currentLink and 1 or 0
	end
	_G.GetLootSlotLink = function()
		return currentLink
	end
	_G.GetContainerNumSlots = function()
		return 0
	end
	_G.GetContainerItemLink = function()
		return nil
	end
	_G.GetContainerItemInfo = function()
		return nil
	end
	addon.Database = {
		EnsureLootRuntimeState = function()
			return {}, {}, {}
		end,
	}
	addon.Services = {
		EnsureNamespace = function(name)
			addon.Services[name] = addon.Services[name] or {}
			return addon.Services[name]
		end,
	}
	addon.Item = {
		GetItemStringFromLink = function(link)
			return link and link:match("|H(item:[^|]+)|h") or nil
		end,
		GetItemIdFromLink = function(link)
			return tonumber(link and (link:match("item:(%d+)") or link:match("^(%d+)$")))
		end,
	}
	loadAddonFile(addon, "Raid Management Addon/Services/Loot/Inventory.lua")
	local inventory = addon.Services.Loot.Inventory
	local target = "|cffa335ee|Hitem:19019:0:0:0:0:0:0:0|h[Target]|h|r"
	currentLink = "|cffa335ee|Hitem:19019:1:0:0:0:0:0:0|h[Changed]|h|r"
	local ok, reason = inventory.ValidateLootSlot(1, target)
	assertEqual(nil, ok, "same item ID must not override canonical mismatch")
	assertEqual("loot_slot_changed", reason, "canonical mismatch reason differs")
	currentLink = target
	assertEqual(true, inventory.ValidateLootSlot(1, target), "identical canonical item must validate")
	currentLink = nil
	ok, reason = inventory.ValidateLootSlot(1, target)
	assertEqual(nil, ok, "missing slot must reject")
	assertEqual("loot_slot_missing", reason, "missing slot reason differs")
	currentLink = "item:19019"
	assertEqual(
		true,
		inventory.ValidateLootSlot(1, "19019"),
		"item ID fallback must work when canonical data is unavailable"
	)
	print("PASS loot_inventory_slot_validation_is_strict")
end

local function installTradeEvidenceInventory(addon, bags)
	_G.GetNumLootItems = function()
		return 0
	end
	_G.GetLootSlotLink = function()
		return nil
	end
	_G.GetContainerNumSlots = function(bag)
		local rows = bags[bag] or {}
		local highest = 0
		for slot in pairs(rows) do
			if slot > highest then
				highest = slot
			end
		end
		return highest
	end
	_G.GetContainerItemLink = function(bag, slot)
		local row = bags[bag] and bags[bag][slot]
		return row and row.link or nil
	end
	_G.GetContainerItemInfo = function(bag, slot)
		local row = bags[bag] and bags[bag][slot]
		return nil, row and row.count or nil
	end
	addon.Database = addon.Database or {}
	addon.Database.EnsureLootRuntimeState = function()
		return {}, {}, {}
	end
	addon.Services = addon.Services or {}
	addon.Services.EnsureNamespace = function(name)
		addon.Services[name] = addon.Services[name] or {}
		return addon.Services[name]
	end
	addon.Item = {
		GetItemStringFromLink = function(link)
			return link and link:match("|H(item:[^|]+)|h") or nil
		end,
		GetItemIdFromLink = function(link)
			return tonumber(link and (link:match("item:(%d+)") or link:match("^(%d+)$")))
		end,
		IsBagItemSoulbound = function()
			return false
		end,
	}
	loadAddonFile(addon, "Raid Management Addon/Services/Loot/Inventory.lua")
	return addon.Services.Loot.Inventory
end

function cases.loot_award_sequence_schedule_failure_is_terminal(addon)
	local schedulerFailures = {
		{ name = "progress throw", progress = true, flag = "throwNextSchedule" },
		{ name = "progress nil", progress = true, flag = "nilNextSchedule" },
		{ name = "delay throw", progress = false, flag = "throwNextSchedule" },
		{ name = "delay nil", progress = false, flag = "nilNextSchedule" },
	}
	for i = 1, #schedulerFailures do
		local scenario = schedulerFailures[i]
		local fixture = installLootHardeningMasterFixture(i == 1 and addon or newAddon())
		fixture.lootState.selectedItemCount = 2
		fixture.mutateSelectedCountOnReset = true
		fixture.windowItemCount = 2
		local reentrantResult
		fixture.onWarn = function()
			reentrantResult = fixture.awardSequence:ContinueOnLootSlotCleared(1)
		end
		assertTrue(
			fixture.awardSequence:Start("item:19019", 2, {
				{ name = "Winner", roll = 90 },
				{ name = "Runner", roll = 80 },
			}),
			scenario.name .. " sequence must start"
		)
		local result, reason
		if scenario.progress then
			fixture[scenario.flag] = true
			result, reason = fixture.master._awardConfirmation:Confirm(1)
		else
			assertEqual(
				true,
				fixture.master._awardConfirmation:Confirm(1),
				scenario.name .. " first award must confirm"
			)
			fixture.windowItemCount = 1
			fixture[scenario.flag] = true
			result, reason = fixture.awardSequence:ContinueOnLootSlotCleared(1)
		end

		assertEqual(nil, result, scenario.name .. " must reject the sequence")
		assertEqual("timer_schedule_failed", reason, scenario.name .. " reason differs")
		assertEqual(nil, fixture.lootState.multiAward, scenario.name .. " retained ownership")
		assertEqual(1, fixture.warningCount, scenario.name .. " must warn once")
		assertEqual(false, reentrantResult, scenario.name .. " warning observed live sequence ownership")
		assertEqual(0, fixture.activeTimerCount(), scenario.name .. " left an active timer")
		assertEqual(1, fixture.lootState.selectedItemCount, scenario.name .. " did not reset item count")
	end
	print("PASS loot_award_sequence_schedule_failure_is_terminal")
end

function cases.loot_inventory_canonical_match_and_required_count(addon)
	local bags = { [0] = { [1] = { link = "|Hitem:19019:0:0:0:0:0:0:1|h[A]|h", count = 2 } } }
	local inventory = installTradeEvidenceInventory(addon, bags)
	assertTrue(
		inventory.LootLinkMatchesTarget(
			"|Hitem:19019:0:0:0:0:0:0:1|h[A]|h",
			"|cffa335ee|Hitem:19019:0:0:0:0:0:0:1|h[B]|h|r",
			"item:19019:0:0:0:0:0:0:1",
			19019
		),
		"canonical item strings must match"
	)
	local evidence = assert(inventory.CaptureTradeEvidence(bags[0][1].link, 0, 1))
	evidence.expectedPartner = "Winner"
	bags[0][1].count = 1
	local verified, reason = inventory.VerifyTradeEvidence(evidence, "Winner", 2)
	assertEqual(nil, verified, "one transferred copy must not satisfy a two-copy award")
	assertEqual("trade_transfer_unverified", reason, "partial transfer reason differs")
	bags[0][1] = nil
	local awarded
	verified, awarded = inventory.VerifyTradeEvidence(evidence, "Winner", 2)
	assertEqual(true, verified, "two transferred copies must satisfy the required count")
	assertEqual(2, awarded, "required-count evidence differs")
	print("PASS loot_inventory_canonical_match_and_required_count")
end

function cases.loot_trade_inventory_evidence_requires_a_positive_delta(addon)
	local target = "|cffa335ee|Hitem:19019:0:0:0:0:0:0:0|h[Target]|h|r"
	local changed = "|cffa335ee|Hitem:19019:1:0:0:0:0:0:0|h[Changed]|h|r"
	local bags = { [0] = {
		[1] = { link = target, count = 2 },
		[2] = { link = target, count = 3 },
	} }
	local inventory = installTradeEvidenceInventory(addon, bags)
	local evidence, reason = inventory.CaptureTradeEvidence(target, 0, 1)
	assertTrue(evidence ~= nil, reason or "trade evidence capture failed")
	evidence.expectedPartner = "Winner"
	assertEqual(5, evidence.totalCount, "captured total count differs")
	local ok
	ok, reason = inventory.VerifyTradeEvidence(evidence, nil)
	assertEqual(nil, ok, "missing observed partner must not confirm a transfer")
	assertEqual("trade_partner_unavailable", reason, "missing observed partner reason differs")
	ok, reason = inventory.VerifyTradeEvidence(evidence, "Winner")
	assertEqual(nil, ok, "unchanged inventory must not confirm a transfer")
	assertEqual("trade_transfer_unverified", reason, "unchanged inventory reason differs")
	ok, reason = inventory.VerifyTradeEvidence(evidence, "Other")
	assertEqual(nil, ok, "wrong partner must not confirm a transfer")
	assertEqual("trade_partner_changed", reason, "wrong partner reason differs")

	bags[0][1].count = 1
	local awarded
	ok, awarded = inventory.VerifyTradeEvidence(evidence, "Winner")
	assertEqual(true, ok, "source-stack decrease must confirm")
	assertEqual(1, awarded, "source-stack awarded count differs")

	bags[0][1] = { link = target, count = 2 }
	bags[0][2].count = 1
	ok, awarded = inventory.VerifyTradeEvidence(evidence, "Winner")
	assertEqual(true, ok, "total-count decrease must confirm")
	assertEqual(2, awarded, "total-count awarded count differs")

	bags[0][1] = { link = changed, count = 2 }
	bags[0][2].count = 3
	ok, awarded = inventory.VerifyTradeEvidence(evidence, "Winner")
	assertEqual(true, ok, "canonical source replacement must prove the tracked stack left")
	assertEqual(2, awarded, "replacement source awarded count differs")
	print("PASS loot_trade_inventory_evidence_requires_a_positive_delta")
end

local function installAwardTradeFixture(addon, opts)
	opts = opts or {}
	local target = "|cffa335ee|Hitem:19019:0:0:0:0:0:0:0|h[Target]|h|r"
	local bags = opts.bags or { [0] = { [1] = { link = target, count = 2 } } }
	local inventory = installTradeEvidenceInventory(addon, bags)
	local selectedWinners = opts.selectedWinners or { { name = "Winner", roll = 90 } }
	addon.C = {
		RAID_TARGET_MARKERS = {},
		rollTypes = { MAINSPEC = 1, OFFSPEC = 2, RESERVED = 3, FREE = 4, HOLD = 5 },
	}
	addon.L = setmetatable({
		ChatTrade = "%s %s",
		ErrMLInventoryItemMissing = "%s",
		ErrItemStack = "%s",
		ErrNoWinnerSelected = "no winner",
		ErrMLWinnerIneligible = "%s",
		ErrMLWinnerLootBanned = "%s",
		ErrMLWinnerLootBannedWithNote = "%s %s",
		ErrScreenReminder = "screen",
		WarnTradeTransferUnverified = "%s %s",
	}, {
		__index = function(_, key)
			return key .. " %s %s %s %s"
		end,
	})
	addon.Diag = {
		D = setmetatable({ LogTradeCompleted = "%s %s %s %s" }, {
			__index = function(_, key)
				return key .. " %s %s %s %s %s"
			end,
		}),
		W = setmetatable({ LogTradeDelayedOutOfRange = "%s %s" }, {
			__index = function(_, key)
				return key .. " %s %s %s %s %s"
			end,
		}),
		E = setmetatable({ LogTradeLoggerLogFailed = "%s %s %s" }, {
			__index = function(_, key)
				return key .. " %s %s %s %s %s"
			end,
		}),
	}
	loadAddonFile(addon, "Raid Management Addon/Services/Master/TradeExecution.lua")
	local counters = {
		logger = 0,
		raid = 0,
		registered = 0,
		rollEnd = 0,
		itemDone = 0,
		announce = 0,
		whisper = 0,
		release = 0,
		warn = 0,
		clearLoot = 0,
		reset = 0,
		refresh = 0,
		context = 0,
		initiateSawState = nil,
		initiateTrade = 0,
		terminalMessages = {},
	}
	local lootState = {
		fromInventory = true,
		selectedItemCount = opts.selectedItemCount or 1,
		currentRollItem = 10,
		currentItemIndex = 1,
		rollSession = { id = "RS:trade" },
	}
	local itemInfo = {}
	local controller
	local function createAttempt(attemptOpts)
		local state = { state = "executing", checkpoints = {}, executorContext = attemptOpts.executorContext }
		local wrapperEffects = {}
		local attempt
		attempt = {
			Confirm = function(_, context)
				state.state = "confirming"
				if context then
					state.executorContext = deepCopy(context)
				end
				if not wrapperEffects.rollEnd then
					controller.distribution.PublishRollEnd()
					wrapperEffects.rollEnd = true
				end
				if not wrapperEffects.itemDone then
					controller.distribution.PublishItemDone()
					wrapperEffects.itemDone = true
				end
				local invoked, ok = pcall(attemptOpts.onConfirm, attempt, state, nil)
				state.state = invoked and ok == true and "confirmed" or "uncertain"
				return invoked and ok == true and true or nil
			end,
			Fail = function(_, reason)
				state.state = "failed"
				state.reason = reason
				return true
			end,
			GetState = function()
				return state
			end,
		}
		return attempt
	end
	controller = addon.Services.Master.TradeExecution.CreateController({
		lootBans = {
			Get = function()
				return false
			end,
		},
		trade = { Reset = function() end },
		inventory = inventory,
		awardPlanner = {
			BuildTradeNotificationPlan = function()
				return { keep = false, output = "awarded", whisper = "winner whisper", markerPlan = {} }
			end,
		},
		rollSelection = {
			GetSelectedCount = function()
				return #selectedWinners
			end,
			DeselectWinner = function(_, playerName)
				for i = 1, #selectedWinners do
					if selectedWinners[i].name == playerName then
						table.remove(selectedWinners, i)
						break
					end
				end
			end,
			GetSelectedWinnersOrdered = function()
				return selectedWinners
			end,
		},
		raid = {
			GetUnitID = function()
				return "raid1"
			end,
			ClearRaidIcons = function() end,
			AddPlayerCountForRollType = function()
				counters.raid = counters.raid + 1
			end,
		},
		loot = {
			GetItemLink = function()
				return target
			end,
			ClearLoot = function()
				counters.clearLoot = counters.clearLoot + 1
			end,
		},
		distribution = {
			PublishRollEnd = function()
				counters.rollEnd = counters.rollEnd + 1
				counters.terminalMessages[#counters.terminalMessages + 1] = "ROLL_END"
				return true
			end,
			PublishItemDone = function()
				counters.itemDone = counters.itemDone + 1
				counters.terminalMessages[#counters.terminalMessages + 1] = "ITEM_DONE"
				return true
			end,
			AcquireSessionOwnership = function()
				return "owner:1"
			end,
			ReleaseSessionOwnership = function()
				counters.release = counters.release + 1
				return opts.rejectRelease ~= true
			end,
		},
		rolls = {
			EnsureLootRollSession = function() end,
			ValidateWinner = function()
				return { ok = true }
			end,
			GetResolvedWinner = function()
				return "Winner"
			end,
			GetRolls = function()
				return {}
			end,
		},
		comms = {
			SendWhisper = function()
				counters.whisper = counters.whisper + 1
				return true
			end,
		},
		database = {
			GetCurrentRaid = function()
				return 1
			end,
			GetPlayerName = function()
				return "Holder"
			end,
		},
		item = addon.Item,
		lootState = lootState,
		itemInfo = itemInfo,
		wow = {
			ClearCursor = function() end,
			CursorHasItem = function()
				return true
			end,
			GetContainerItemInfo = _G.GetContainerItemInfo,
			GetContainerItemLink = _G.GetContainerItemLink,
			PickupContainerItem = function() end,
			InitiateTrade = function()
				counters.initiateTrade = counters.initiateTrade + 1
				local state = controller:GetPendingState()
				counters.initiateSawState = state and state.state
			end,
			SetRaidTarget = function() end,
			CheckInteractDistance = function()
				if opts.inRange == false then
					return nil
				end
				return 1
			end,
		},
		getOption = function(_, key)
			return key == "ignoreStacks"
		end,
		buildRollSelectionModel = function()
			return { winner = selectedWinners[1] and selectedWinners[1].name or nil, rows = selectedWinners }
		end,
		buildLootRollSessionOptions = function()
			return {}
		end,
		resetTradeState = function()
			counters.reset = counters.reset + 1
		end,
		hideTradeDropdowns = function() end,
		clearLootAndResetRecordedRolls = function() end,
		ensureTradeLootContext = function()
			counters.context = counters.context + 1
			return 10, false
		end,
		requestLoggerLootLog = function()
			counters.logger = counters.logger + 1
			return opts.rejectLogger ~= true
		end,
		registerAwardedItem = function(count)
			counters.registered = counters.registered + count
			return counters.registered >= lootState.selectedItemCount
		end,
		requestRefresh = function()
			counters.refresh = counters.refresh + 1
			return true
		end,
		announce = function()
			counters.announce = counters.announce + 1
			return true
		end,
		isAnnounced = function()
			return false
		end,
		setAnnounced = function() end,
		isScreenshotWarn = function()
			return false
		end,
		setScreenshotWarn = function() end,
		warn = function()
			counters.warn = counters.warn + 1
		end,
		error = function() end,
		createAttempt = createAttempt,
		getItemKey = addon.Item.GetItemStringFromLink,
		canCommitRaidHistory = function()
			return opts.canonicalAuthority ~= false
		end,
	})
	return {
		controller = controller,
		bags = bags,
		counters = counters,
		itemInfo = itemInfo,
		lootState = lootState,
		selectedWinners = selectedWinners,
		target = target,
		opts = opts,
	}
end

function cases.loot_trade_rejects_second_in_flight(addon)
	local fixture = installAwardTradeFixture(addon)
	assertTrue(fixture.controller:TradeItem(fixture.target, "Winner", 1, 99))
	local admitted, reason = fixture.controller:TradeItem(fixture.target, "Winner", 1, 98)
	assertEqual(nil, admitted, "second trade must be rejected")
	assertEqual("trade_in_flight", reason, "second trade reason differs")
	print("PASS loot_trade_rejects_second_in_flight")
end

function cases.loot_trade_required_count_tracks_placed_stack(addon)
	local target = "|cffa335ee|Hitem:19019:0:0:0:0:0:0:0|h[Target]|h|r"
	local sequential = installAwardTradeFixture(addon, {
		bags = { [0] = {
			[1] = { link = target, count = 1 },
			[2] = { link = target, count = 1 },
		} },
		selectedItemCount = 2,
		selectedWinners = { { name = "Winner", roll = 90 }, { name = "Runner", roll = 80 } },
	})
	assertTrue(sequential.controller:TradeItem(sequential.target, "Winner", 1, 90))
	assertTrue(sequential.controller:HandleTradeShow("Winner"))
	assertTrue(sequential.controller:HandleAcceptedAwardTrade(1, 1))
	sequential.bags[0][1] = nil
	local settled, settleReason = sequential.controller:SettleAcceptedTrade("Winner")
	assertEqual(true, settled, settleReason or "one placed copy must settle independently")
	assertEqual(false, sequential.controller:HasInFlightAward(), "first sequential trade retained ownership")
	assertEqual("Runner", sequential.lootState.winner, "first trade did not advance to the second winner")
	assertEqual(1, sequential.counters.registered, "first sequential trade registered the wrong quantity")
	assertEqual(0, sequential.counters.clearLoot, "remaining duplicate copy cleared the loot frame")
	assertTrue(sequential.controller:TradeItem(sequential.target, "Runner", 1, 80), "second winner was not admitted")

	local stack = installAwardTradeFixture(newAddon(), {
		bags = { [0] = { [1] = { link = target, count = 2 } } },
		selectedItemCount = 1,
	})
	assertTrue(stack.controller:TradeItem(stack.target, "Winner", 1, 90))
	assertTrue(stack.controller:HandleTradeShow("Winner"))
	assertTrue(stack.controller:HandleAcceptedAwardTrade(1, 1))
	stack.bags[0][1].count = 1
	local verified, reason = stack.controller:SettleAcceptedTrade("Winner")
	assertEqual(nil, verified, "partial whole-stack transfer must remain uncertain")
	assertEqual("trade_transfer_unverified", reason, "partial whole-stack reason differs")
	stack.bags[0][1] = nil
	assertEqual(true, stack.controller:SettleAcceptedTrade("Winner"), "whole-stack delta must settle")
	assertEqual(false, stack.controller:HasInFlightAward(), "settled duplicate-copy evidence retained ownership")
	assertEqual(2, stack.counters.registered, "whole-stack trade registered the wrong quantity")
	assertEqual(1, stack.counters.clearLoot, "settled whole-stack trade did not clear the loot frame")
	print("PASS loot_trade_required_count_tracks_placed_stack")
end

function cases.loot_out_of_range_trade_can_retry(addon)
	local Rolls = installLootHardeningRollsFixture(addon)
	local target = "|cffa335ee|Hitem:19019:0:0:0:0:0:0:0|h[Target]|h|r"
	local session = Rolls:EnsureRollSession(target, addon.C.rollTypes.FREE, "lootWindow")
	Rolls:SetExpectedWinners(2)
	Rolls:SetRollRecordingEnabled(true)
	assertTrue(Rolls:SubmitDebugRoll("Winner", 90), "first winner roll must enter")
	assertTrue(Rolls:SubmitDebugRoll("Runner", 80), "second winner roll must enter")

	local fixture = installAwardTradeFixture(addon, {
		bags = { [0] = {
			[1] = { link = target, count = 1 },
			[2] = { link = target, count = 1 },
		} },
		selectedItemCount = 2,
		selectedWinners = { { name = "Winner", roll = 90 }, { name = "Runner", roll = 80 } },
		inRange = false,
	})
	local function requestTrade(playerName, roll)
		local frozen, reason = Rolls:FreezeRollIntake("award")
		if not frozen then
			return nil, reason
		end
		return fixture.controller:TradeItem(target, playerName, addon.C.rollTypes.FREE, roll)
	end

	assertTrue(requestTrade("Winner", 90), "out-of-range award request must retain its notification flow")
	assertEqual(0, fixture.counters.initiateTrade, "out-of-range request initiated a trade")
	assertEqual(false, fixture.controller:HasInFlightAward(), "out-of-range request retained pending trade state")
	assertEqual("failed", fixture.controller:GetPendingState().state, "out-of-range terminal attempt state differs")
	assertEqual(false, session.active, "out-of-range request reopened the frozen roll session")

	fixture.opts.inRange = true
	assertTrue(requestTrade("Winner", 90), "in-range retry must be admitted on the frozen roll session")
	assertEqual(1, fixture.counters.initiateTrade, "in-range retry did not initiate trade")
	assertEqual(
		"requested",
		fixture.controller:GetPendingState().state,
		"in-range retry did not establish pending state"
	)
	assertTrue(fixture.controller:HandleTradeShow("Winner"), "first winner trade did not open")
	assertTrue(fixture.controller:HandleAcceptedAwardTrade(1, 1), "first winner trade was not accepted")
	fixture.bags[0][1] = nil
	assertTrue(fixture.controller:SettleAcceptedTrade("Winner"), "first winner trade did not confirm")
	assertEqual("Runner", fixture.lootState.winner, "confirmed first trade did not advance to second winner")
	assertEqual(false, session.active, "first confirmation reactivated the frozen roll session")

	assertTrue(requestTrade("Runner", 80), "second winner was not admitted on the same frozen roll session")
	assertEqual(2, fixture.counters.initiateTrade, "second winner trade did not initiate")
	assertEqual(
		"requested",
		fixture.controller:GetPendingState().state,
		"second winner did not establish pending state"
	)
	print("PASS loot_out_of_range_trade_can_retry")
end

function cases.loot_trade_close_retries_once_after_bag_update(addon)
	local fixture = installLootHardeningMasterFixture(addon)
	local master = fixture.master
	local tradeController = fixture.tradeController
	local ownedCount = 1
	local confirmCalls = 0
	local pendingAcceptedTrade = true

	fixture.tradeInFlight = true
	tradeController.HasPendingAcceptedTrade = function()
		return pendingAcceptedTrade
	end
	tradeController.SettleAcceptedTrade = function()
		if ownedCount > 0 then
			return nil, "trade_transfer_unverified"
		end
		pendingAcceptedTrade = false
		fixture.tradeInFlight = false
		confirmCalls = confirmCalls + 1
		return true
	end

	master:TRADE_CLOSED()
	fixture.runScheduledTimers()
	assertEqual(true, tradeController:HasPendingAcceptedTrade(), "early close settle must remain pending")

	ownedCount = ownedCount - 1
	master:BAG_UPDATE()
	fixture.runScheduledTimers()
	assertEqual(false, tradeController:HasInFlightAward(), "bag update did not settle accepted trade")
	assertEqual(1, confirmCalls, "accepted trade confirmed more than once")

	master:BAG_UPDATE()
	fixture.runScheduledTimers()
	assertEqual(1, confirmCalls, "later bag update repeated settlement")
	print("PASS loot_trade_close_retries_once_after_bag_update")
end

function cases.loot_trade_menu_is_manual_only(addon)
	local fixture = installLootHardeningMasterFixture(addon)
	local master = fixture.master
	local tradeMenu = addon.Widgets.TradeMenu
	local refreshCalls = 0
	local hideCalls = 0

	tradeMenu.RefreshCandidate = function()
		refreshCalls = refreshCalls + 1
	end
	tradeMenu.HideDropdowns = function()
		hideCalls = hideCalls + 1
	end
	fixture.tradeInFlight = true
	master:TRADE_SHOW()
	master:TRADE_PLAYER_ITEM_CHANGED()
	master:TRADE_TARGET_ITEM_CHANGED()
	assertEqual(0, refreshCalls, "addon-driven trade refreshed manual candidates")
	assertEqual(3, hideCalls, "addon-driven trade did not keep manual dropdowns hidden")

	fixture.tradeInFlight = false
	master:TRADE_PLAYER_ITEM_CHANGED()
	assertEqual(1, refreshCalls, "manual trade did not refresh its candidate")
	print("PASS loot_trade_menu_is_manual_only")
end

function cases.loot_award_trade_event_order_is_evidence_gated(addon)
	local fixture = installAwardTradeFixture(addon)
	local trade = fixture.controller
	assertEqual(true, trade:TradeItem(fixture.target, "Winner", 1, 90), "trade request must start")
	assertEqual("requested", fixture.counters.initiateSawState, "pending state must exist before InitiateTrade")
	assertEqual("requested", trade:GetPendingState().state, "initial trade state differs")
	assertEqual(0, fixture.counters.rollEnd, "trade request published ROLL_END before evidence")
	assertEqual(0, fixture.counters.announce, "trade request announced success before evidence")
	assertEqual(true, trade:HandleTradeShow("Winner"), "expected TRADE_SHOW must advance")
	assertEqual("shown", trade:GetPendingState().state, "TRADE_SHOW state differs")
	assertEqual(false, trade:HandleAcceptedAwardTrade(1, 0), "one accepted flag must not complete intent")
	assertEqual("shown", trade:GetPendingState().state, "partial accept changed state")
	assertEqual(true, trade:HandleAcceptedAwardTrade(1, 1), "both accepted flags must advance intent")
	assertEqual("accepted", trade:GetPendingState().state, "accepted state differs")
	assertEqual(nil, trade:SettleAcceptedTrade("Winner"), "close without delta must remain unconfirmed")
	assertEqual("uncertain", trade:GetPendingState().state, "unverified close must be uncertain")
	assertEqual(0, fixture.counters.logger, "unverified close logged success")
	assertEqual(0, fixture.counters.release, "uncertain close released session ownership")
	assertEqual(1, fixture.counters.warn, "uncertain close must warn once")

	fixture.bags[0][1] = nil
	assertEqual(true, trade:SettleAcceptedTrade("Winner"), "later inventory delta must confirm")
	assertEqual("confirmed", trade:GetPendingState().state, "confirmed state differs")
	assertEqual(1, fixture.counters.logger, "confirmed trade logger count differs")
	assertEqual(1, fixture.counters.raid, "confirmed trade counter count differs")
	assertEqual(1, fixture.counters.rollEnd, "confirmed trade ROLL_END count differs")
	assertEqual(1, fixture.counters.itemDone, "confirmed trade ITEM_DONE count differs")
	assertEqual(
		"ITEM_DONE",
		fixture.counters.terminalMessages[#fixture.counters.terminalMessages],
		"ITEM_DONE must remain terminal"
	)
	assertEqual(1, fixture.counters.announce, "confirmed trade announcement count differs")
	assertEqual(1, fixture.counters.whisper, "confirmed trade whisper count differs")
	assertEqual(1, fixture.counters.release, "confirmed trade did not release session ownership")
	assertEqual(false, trade:HasInFlightAward(), "confirmed trade retained award ownership")
	assertEqual(1, fixture.counters.clearLoot, "confirmed trade did not clear the master loot item")
	assertEqual(2, fixture.counters.reset, "confirmed trade did not reset the trade state")
	assertEqual(1, fixture.counters.refresh, "confirmed trade did not refresh the master loot frame")

	local wrong = installAwardTradeFixture(newAddon())
	assertTrue(wrong.controller:TradeItem(wrong.target, "Winner", 1, 90), "wrong-partner scenario did not start")
	assertEqual(true, wrong.controller:HandleTradeShow("Other"), "wrong-partner show must be handled")
	assertEqual("failed", wrong.controller:GetPendingState().state, "wrong partner must fail the request")
	assertEqual(1, wrong.counters.release, "wrong partner retained session ownership")

	local missingShowPartner = installAwardTradeFixture(newAddon())
	assertTrue(missingShowPartner.controller:TradeItem(missingShowPartner.target, "Winner", 1, 90))
	local shown, showReason = missingShowPartner.controller:HandleTradeShow(nil)
	assertEqual(nil, shown, "TRADE_SHOW without an observed partner must not advance")
	assertEqual("trade_partner_unavailable", showReason, "missing TRADE_SHOW partner reason differs")
	assertEqual(
		"requested",
		missingShowPartner.controller:GetPendingState().state,
		"missing partner advanced show state"
	)

	local beforeShowCancel = installAwardTradeFixture(newAddon())
	assertTrue(beforeShowCancel.controller:TradeItem(beforeShowCancel.target, "Winner", 1, 90))
	assertTrue(beforeShowCancel.controller:FailAcceptedTrade("TRADE_REQUEST_CANCEL"), "pre-show cancel must fail")
	assertEqual("failed", beforeShowCancel.controller:GetPendingState().state, "pre-show cancel state differs")
	local afterShowCancel = installAwardTradeFixture(newAddon())
	assertTrue(afterShowCancel.controller:TradeItem(afterShowCancel.target, "Winner", 1, 90))
	assertTrue(afterShowCancel.controller:HandleTradeShow("Winner"))
	assertTrue(afterShowCancel.controller:FailAcceptedTrade("TRADE_CLOSED"), "post-show cancel must fail")
	assertEqual("failed", afterShowCancel.controller:GetPendingState().state, "post-show cancel state differs")

	local missingSettlePartner = installAwardTradeFixture(newAddon())
	assertTrue(missingSettlePartner.controller:TradeItem(missingSettlePartner.target, "Winner", 1, 90))
	assertTrue(missingSettlePartner.controller:HandleTradeShow("Winner"))
	assertTrue(missingSettlePartner.controller:HandleAcceptedAwardTrade(1, 1))
	missingSettlePartner.bags[0][1] = nil
	local settled, settleReason = missingSettlePartner.controller:SettleAcceptedTrade(nil)
	assertEqual(true, settled, settleReason or "validated TRADE_SHOW partner must survive post-close nil lookup")
	assertEqual(1, missingSettlePartner.counters.logger, "validated shown partner did not reach logger")
	assertEqual(1, missingSettlePartner.counters.release, "validated shown partner did not release ownership")

	local retry = installAwardTradeFixture(newAddon(), { rejectLogger = true })
	assertTrue(retry.controller:TradeItem(retry.target, "Winner", 1, 90))
	assertTrue(retry.controller:HandleTradeShow("Winner"))
	assertTrue(retry.controller:HandleAcceptedAwardTrade(1, 1))
	retry.bags[0][1] = nil
	assertEqual(nil, retry.controller:SettleAcceptedTrade("Winner"), "logger rejection must remain retryable")
	assertEqual(1, retry.counters.logger, "logger first attempt count differs")
	assertEqual(0, retry.counters.raid, "counter ran before logger success")
	retry.opts.rejectLogger = false
	assertEqual(true, retry.controller:SettleAcceptedTrade("Winner"), "logger retry must confirm")
	assertEqual(2, retry.counters.logger, "logger retry count differs")
	assertEqual(1, retry.counters.raid, "logger retry duplicated counter")
	assertEqual(1, retry.counters.rollEnd, "logger retry duplicated distribution terminal state")
	assertEqual(1, retry.counters.announce, "logger retry duplicated announcement")

	local releaseRetry = installAwardTradeFixture(newAddon(), { rejectRelease = true })
	assertTrue(releaseRetry.controller:TradeItem(releaseRetry.target, "Winner", 1, 90))
	assertTrue(releaseRetry.controller:HandleTradeShow("Winner"))
	assertTrue(releaseRetry.controller:HandleAcceptedAwardTrade(1, 1))
	releaseRetry.bags[0][1] = nil
	local released, releaseReason = releaseRetry.controller:SettleAcceptedTrade("Winner")
	assertEqual(nil, released, "failed session release must retain terminal ownership")
	assertEqual("session_ownership_release_failed", releaseReason, "release failure reason differs")
	assertEqual(true, releaseRetry.controller:HasInFlightAward(), "release failure orphaned the in-flight owner")
	assertEqual(true, releaseRetry.controller:GetPendingState().releasePending, "release retry state not exposed")
	assertEqual(1, releaseRetry.counters.logger, "release failure repeated logger")
	releaseRetry.opts.rejectRelease = false
	assertEqual(
		true,
		releaseRetry.controller:SettleAcceptedTrade(nil),
		"terminal release retry must succeed without evidence rerun"
	)
	assertEqual(false, releaseRetry.controller:HasInFlightAward(), "successful release retry retained ownership")
	assertEqual(2, releaseRetry.counters.release, "session release retry count differs")
	assertEqual(1, releaseRetry.counters.logger, "session release retry duplicated logger")
	assertEqual(1, releaseRetry.counters.rollEnd, "session release retry duplicated RMADist publication")
	assertEqual(1, releaseRetry.counters.announce, "session release retry duplicated announcement")
	print("PASS loot_award_trade_event_order_is_evidence_gated")
end

function cases.loot_trader_keep_uses_award_callback_contract(addon)
	local fixture = installAwardTradeFixture(addon)
	assertEqual(true, fixture.controller:TradeItem(fixture.target, "Holder", 1, 90), "trader-keep award must settle")
	assertEqual(1, fixture.counters.rollEnd, "trader-keep award published ROLL_END more than once")
	assertEqual(1, fixture.counters.itemDone, "trader-keep award did not publish ITEM_DONE")
	assertEqual(
		"ITEM_DONE",
		fixture.counters.terminalMessages[#fixture.counters.terminalMessages],
		"trader-keep ITEM_DONE must remain terminal"
	)
	assertEqual(1, fixture.counters.clearLoot, "trader-keep award did not clear the master loot item")
	assertEqual(2, fixture.counters.reset, "trader-keep award did not reset the trade state")
	assertEqual(1, fixture.counters.refresh, "trader-keep award did not refresh the master loot frame")
	print("PASS loot_trader_keep_uses_award_callback_contract")
end

function cases.loot_split_master_trade_finalizes_without_local_canonical_writes(addon)
	local accepted = installAwardTradeFixture(addon, { canonicalAuthority = false })
	assertTrue(accepted.controller:TradeItem(accepted.target, "Winner", 1, 90), "split-authority trade did not start")
	assertTrue(accepted.controller:HandleTradeShow("Winner"), "split-authority trade did not observe the partner")
	assertTrue(accepted.controller:HandleAcceptedAwardTrade(1, 1), "split-authority trade did not accept both sides")
	accepted.bags[0][1] = nil
	assertTrue(
		accepted.controller:SettleAcceptedTrade("Winner"),
		"split-authority trade did not finalize from evidence"
	)
	assertEqual(0, accepted.counters.context, "non-authoritative trade created local loot context")
	assertEqual(0, accepted.counters.logger, "non-authoritative trade wrote the local logger")
	assertEqual(0, accepted.counters.raid, "non-authoritative trade wrote the local counter")
	assertEqual(1, accepted.counters.itemDone, "split-authority trade did not publish terminal award facts")
	assertTrue(accepted.counters.registered > 0, "split-authority trade did not advance local UI progress")

	local keep = installAwardTradeFixture(newAddon(), { canonicalAuthority = false })
	assertTrue(keep.controller:TradeItem(keep.target, "Holder", 1, 90), "split-authority trader-keep did not finalize")
	assertEqual(0, keep.counters.context, "non-authoritative trader-keep created local loot context")
	assertEqual(0, keep.counters.logger, "non-authoritative trader-keep wrote the local logger")
	assertEqual(0, keep.counters.raid, "non-authoritative trader-keep wrote the local counter")
	assertEqual(1, keep.counters.itemDone, "split-authority trader-keep did not publish terminal award facts")
	print("PASS loot_split_master_trade_finalizes_without_local_canonical_writes")
end

function cases.loot_manual_hold_trade_requires_inventory_evidence(addon)
	local target = "|cffa335ee|Hitem:19019:0:0:0:0:0:0:0|h[Target]|h|r"
	local bags = { [0] = { [1] = { link = target, count = 1 } } }
	installTradeEvidenceInventory(addon, bags)
	local lootState = {}
	local raid = {
		loot = {
			{
				lootNid = 10,
				rollType = 5,
				looter = "Holder",
				holder = "Holder",
				itemString = "item:19019:0:0:0:0:0:0:0",
				itemId = 19019,
			},
		},
	}
	local loggerCalls, countCalls, warnings = 0, 0, 0
	addon.C = { rollTypes = { MAINSPEC = 1, OFFSPEC = 2, RESERVED = 3, FREE = 4, HOLD = 5 } }
	addon.L = setmetatable({
		BtnMS = "MS",
		BtnOS = "OS",
		BtnSR = "SR",
		BtnFree = "Free",
		WarnTradeManualReasonMissing = "%s",
		WarnTradeTransferUnverified = "%s",
	}, {
		__index = function(_, key)
			return key .. " %s %s"
		end,
	})
	addon.Diag = {
		D = setmetatable({}, {
			__index = function(_, key)
				return key .. " %s %s %s"
			end,
		}),
		W = setmetatable({}, {
			__index = function(_, key)
				return key .. " %s %s %s"
			end,
		}),
		E = setmetatable({}, {
			__index = function(_, key)
				return key .. " %s %s %s"
			end,
		}),
	}
	addon.warn = function()
		warnings = warnings + 1
	end
	addon.Database.EnsureLootRuntimeState = function()
		return {}, lootState, {}
	end
	addon.Database.EnsureRaidByIndex = function()
		return raid
	end
	addon.Database.GetCurrentRaid = function()
		return 1
	end
	addon.Database.GetPlayerName = function()
		return "Holder"
	end
	addon.Services.Logger =
		{ Actions = {
			RecordLoot = function()
				loggerCalls = loggerCalls + 1
				return true
			end,
		} }
	addon.Services.Raid = {
		GetPlayerID = function()
			return 1
		end,
		AddPlayerCountForRollType = function()
			countCalls = countCalls + 1
		end,
	}
	loadAddonFile(addon, "Raid Management Addon/Services/Master/Trade.lua")
	local trade = addon.Services.Master.Trade
	local state = trade.RefreshCandidate({
		source = "TRADE_PLAYER_ITEM_CHANGED",
		partnerName = "Winner",
		tradeItems = { [1] = { itemLink = target, itemString = "item:19019:0:0:0:0:0:0:0", itemId = 19019 } },
	})
	assertEqual(true, state.active, "manual Hold candidate did not activate")
	assertTrue(state.candidates[1].tradeEvidence ~= nil, "manual Hold candidate did not capture evidence")
	assertTrue(trade.SetSelectedReason(10, 1), "manual Hold reason selection failed")
	assertTrue(trade.ApplyAccept(1, 1, false), "manual Hold accept intent failed")
	assertEqual(false, trade.CompletePending(), "manual Hold without delta must not log")
	assertEqual("uncertain", trade.EnsureState().state, "manual Hold without evidence must be uncertain")
	assertEqual(0, loggerCalls, "manual Hold without evidence logged success")
	bags[0][1] = nil
	assertEqual(true, trade.CompletePending(), "manual Hold with later delta must log")
	assertEqual(1, loggerCalls, "manual Hold logger count differs")
	assertEqual(1, countCalls, "manual Hold counter count differs")
	assertEqual("confirmed", trade.EnsureState().state, "manual Hold confirmed state differs")
	assertEqual(1, warnings, "manual Hold uncertainty warning count differs")

	local secondAddon = newAddon()
	local secondTarget = "|cffa335ee|Hitem:18832:0:0:0:0:0:0:0|h[Second]|h|r"
	local secondBags = { [0] = {
		[1] = { link = target, count = 1 },
		[2] = { link = secondTarget, count = 1 },
	} }
	installTradeEvidenceInventory(secondAddon, secondBags)
	local secondLootState = {}
	local secondRaid = {
		loot = {
			{
				lootNid = 10,
				rollType = 5,
				looter = "Holder",
				holder = "Holder",
				itemString = "item:19019:0:0:0:0:0:0:0",
				itemId = 19019,
			},
			{
				lootNid = 11,
				rollType = 5,
				looter = "Holder",
				holder = "Holder",
				itemString = "item:18832:0:0:0:0:0:0:0",
				itemId = 18832,
			},
		},
	}
	local loggerByNid, counterByName, rejectSecond = {}, {}, true
	secondAddon.C = addon.C
	secondAddon.L = addon.L
	secondAddon.Diag = addon.Diag
	secondAddon.warn = function() end
	secondAddon.Database.EnsureLootRuntimeState = function()
		return {}, secondLootState, {}
	end
	secondAddon.Database.EnsureRaidByIndex = function()
		return secondRaid
	end
	secondAddon.Database.GetCurrentRaid = function()
		return 1
	end
	secondAddon.Database.GetPlayerName = function()
		return "Holder"
	end
	secondAddon.Services.Logger = {
		Actions = {
			RecordLoot = function(_, request)
				local nid = request.lootNid
				loggerByNid[nid] = (loggerByNid[nid] or 0) + 1
				if nid == 11 and rejectSecond then
					return false
				end
				return true
			end,
		},
	}
	secondAddon.Services.Raid = {
		GetPlayerID = function()
			return 1
		end,
		AddPlayerCountForRollType = function(_, name)
			counterByName[name] = (counterByName[name] or 0) + 1
		end,
	}
	loadAddonFile(secondAddon, "Raid Management Addon/Services/Master/Trade.lua")
	local secondTrade = secondAddon.Services.Master.Trade
	local secondState = secondTrade.RefreshCandidate({
		source = "TRADE_PLAYER_ITEM_CHANGED",
		partnerName = "Winner",
		tradeItems = {
			[1] = { itemLink = target, itemString = "item:19019:0:0:0:0:0:0:0", itemId = 19019 },
			[2] = { itemLink = secondTarget, itemString = "item:18832:0:0:0:0:0:0:0", itemId = 18832 },
		},
	})
	assertEqual(2, #secondState.candidates, "two-candidate manual fixture differs")
	assertTrue(secondTrade.SetSelectedReason(10, 1))
	assertTrue(secondTrade.SetSelectedReason(11, 1))
	assertTrue(secondTrade.ApplyAccept(1, 1, false))
	secondBags[0][1] = nil
	secondBags[0][2] = nil
	assertEqual(false, secondTrade.CompletePending(), "second logger rejection must retain manual ownership")
	assertEqual(1, loggerByNid[10], "first manual candidate logger count differs")
	assertEqual(1, loggerByNid[11], "second manual candidate first attempt differs")
	assertEqual(1, counterByName.Winner, "first manual candidate counter count differs")
	rejectSecond = false
	assertEqual(true, secondTrade.CompletePending(), "manual partial logger retry must complete remaining candidate")
	assertEqual(1, loggerByNid[10], "manual retry duplicated completed first logger")
	assertEqual(2, loggerByNid[11], "manual retry did not retry second logger exactly once")
	assertEqual(2, counterByName.Winner, "manual retry duplicated or lost a counter")
	print("PASS loot_manual_hold_trade_requires_inventory_evidence")
end

function cases.loot_attribution_cancellation_is_transaction_scoped(addon)
	local lootState = { pendingAwards = {} }
	_G.GetTime = function()
		return 10
	end
	addon.C = { PENDING_AWARD_TTL_SECONDS = 8 }
	addon.Diag = { D = { LogLootPendingAwardConsumed = "%s %s %s %s" } }
	addon.Options = {
		IsDebugEnabled = function()
			return false
		end,
	}
	addon.Strings = {
		NormalizeName = function(value)
			return value
		end,
	}
	addon.Item = {
		GetItemStringFromLink = function(link)
			return link
		end,
	}
	addon.Database = {
		EnsureLootRuntimeState = function()
			return {}, lootState
		end,
	}
	addon.Services = {
		EnsureNamespace = function(name)
			addon.Services[name] = addon.Services[name] or {}
			return addon.Services[name]
		end,
	}
	loadAddonFile(addon, "Raid Management Addon/Services/Loot/LootAttribution.lua")
	local attribution = addon.Services.Loot.LootAttribution
	attribution.Add("item:19019", "Winner", 1, 90, "RS:1", nil, { transactionId = "AT:1" })
	attribution.Add("item:19019", "Winner", 2, 80, "RS:2", nil, { transactionId = "AT:2" })
	attribution.Add("item:18832", "Other", 1, 70, "RS:3", nil, { transactionId = "AT:1" })
	assertEqual(true, attribution.Cancel("AT:1"), "matching transaction must cancel")
	assertEqual(false, attribution.Cancel("AT:1"), "repeated cancellation must be idempotent")
	local remaining = 0
	local remainingTransaction
	for _, list in pairs(lootState.pendingAwards) do
		for i = 1, #list do
			remaining = remaining + 1
			remainingTransaction = list[i].transactionId
		end
	end
	assertEqual(1, remaining, "cancellation removed unrelated pending awards")
	assertEqual("AT:2", remainingTransaction, "wrong transaction survived cancellation")
	print("PASS loot_attribution_cancellation_is_transaction_scoped")
end

function cases.loot_award_attribution_event_order_is_atomic(addon)
	local lootState = { pendingAwards = {} }
	_G.GetTime = function()
		return 10
	end
	addon.C = { PENDING_AWARD_TTL_SECONDS = 8 }
	addon.Diag = { D = { LogLootPendingAwardConsumed = "%s %s %s %s" } }
	addon.Options = {
		IsDebugEnabled = function()
			return false
		end,
	}
	addon.Strings = {
		NormalizeName = function(value)
			return value
		end,
	}
	addon.Item = {
		GetItemStringFromLink = function(link)
			return link
		end,
	}
	addon.Database = {
		EnsureLootRuntimeState = function()
			return {}, lootState
		end,
	}
	addon.Services = {
		EnsureNamespace = function(name)
			addon.Services[name] = addon.Services[name] or {}
			return addon.Services[name]
		end,
	}
	loadAddonFile(addon, "Raid Management Addon/Services/Loot/LootAttribution.lua")
	local attribution = addon.Services.Loot.LootAttribution
	local records, reconciles = 0, 0
	local function finalize(award)
		records = records + 1
		return records
	end
	local function reconcile(award, authoritative)
		reconciles = reconciles + 1
		assertEqual(2, authoritative.itemCount, "authoritative count was not retained")
	end

	-- CHAT_MSG_LOOT first: retain the transaction until slot confirmation, then
	-- finalize exactly once without waiting for another chat event.
	attribution.Add("item:19019", "Winner", 1, 90, "RS:chat", nil, { transactionId = "AT:chat" })
	assertTrue(
		attribution.StageAuthoritative("item:19019", "Winner", {
			itemCount = 2,
		}, reconcile),
		"chat-first award was not staged"
	)
	assertEqual(0, records, "chat-first award finalized before slot evidence")
	local chatFirst = attribution.ConfirmProvisional("item:19019", "Winner", "RS:chat", 1, "AT:chat", 1, function()
		error("chat-first confirmation must not schedule grace")
	end, function() end, finalize)
	assertTrue(chatFirst and chatFirst.finalized, "chat-first award did not confirm")
	assertEqual("CHAT_MSG_LOOT", chatFirst.finalizedSource, "chat-first source differs")
	assertEqual(1, records, "chat-first award record count differs")
	assertEqual(1, reconciles, "chat-first reconciliation count differs")
	assertEqual(
		nil,
		attribution.Remove("item:19019", "Winner", 8, "RS:chat", false, false),
		"chat-first confirmation retained a consumable pending award"
	)
	assertEqual(
		nil,
		attribution.ConfirmProvisional("item:19019", "Winner", "RS:chat", 1, "AT:chat", 1, nil, nil, finalize),
		"duplicate chat-first slot confirmation found a completed pending award"
	)
	assertEqual(1, records, "duplicate chat-first confirmation repeated finalization")
	assertEqual(1, reconciles, "duplicate chat-first confirmation repeated reconciliation")

	-- LOOT_SLOT_CLEARED first: grace remains pending until authoritative chat,
	-- which cancels it and reconciles the same record exactly once.
	local scheduled, cancelled = {}, 0
	attribution.Add("item:19019", "Winner", 1, 80, "RS:slot", nil, { transactionId = "AT:slot" })
	local slotFirst = attribution.ConfirmProvisional(
		"item:19019",
		"Winner",
		"RS:slot",
		1,
		"AT:slot",
		1,
		function(callback)
			scheduled[#scheduled + 1] = callback
			return callback
		end,
		function()
			cancelled = cancelled + 1
		end,
		finalize
	)
	assertTrue(slotFirst and not slotFirst.finalized, "slot-first award finalized before chat/grace")
	assertEqual(
		nil,
		attribution.StageAuthoritative("item:19019", "Winner", { itemCount = 2 }, reconcile),
		"slot-first chat bypassed existing provisional reconciliation"
	)
	local consumed = attribution.Remove("item:19019", "Winner", 8, "RS:slot", false, false)
	assertTrue(consumed ~= nil, "slot-first authoritative resolution did not consume pending")
	assertTrue(
		attribution.ReconcileProvisional("item:19019", "Winner", "RS:slot", "AT:slot", function()
			cancelled = cancelled + 1
		end, function()
			reconciles = reconciles + 1
		end),
		"slot-first chat did not reconcile"
	)
	assertEqual(2, records, "slot-first award record count differs")
	assertEqual(2, reconciles, "slot-first reconciliation count differs")
	assertEqual(1, cancelled, "slot-first grace timer cancellation count differs")
	scheduled[1]()
	assertEqual(2, records, "stale grace callback duplicated the record")
	print("PASS loot_award_attribution_event_order_is_atomic")
end

function cases.loot_attribution_schedule_failure_finalizes_once(addon)
	local lootState = { pendingAwards = {} }
	_G.GetTime = function()
		return 10
	end
	addon.C = { PENDING_AWARD_TTL_SECONDS = 8 }
	addon.Diag = { D = { LogLootPendingAwardConsumed = "%s %s %s %s" } }
	addon.Options = {
		IsDebugEnabled = function()
			return false
		end,
	}
	addon.Strings = {
		NormalizeName = function(value)
			return value
		end,
	}
	addon.Item = {
		GetItemStringFromLink = function(link)
			return link
		end,
	}
	addon.Database = {
		EnsureLootRuntimeState = function()
			return {}, lootState
		end,
	}
	addon.Services = {
		EnsureNamespace = function(name)
			addon.Services[name] = addon.Services[name] or {}
			return addon.Services[name]
		end,
	}
	loadAddonFile(addon, "Raid Management Addon/Services/Loot/LootAttribution.lua")
	local attribution = addon.Services.Loot.LootAttribution
	local failures = {
		{
			name = "scheduler throw",
			schedule = function()
				error("schedule exploded")
			end,
			expectedReason = "timer_schedule_failed",
		},
		{
			name = "scheduler nil",
			schedule = function()
				return nil
			end,
			expectedReason = "timer_schedule_failed",
		},
		{ name = "finalizer throw", throwFinalize = true, expectedReason = "record_finalize_failed" },
	}
	for i = 1, #failures do
		local scenario = failures[i]
		local transactionId = "AT:failure:" .. tostring(i)
		local sessionId = "RS:failure:" .. tostring(i)
		local finalizeCount, failureCount, reconcileCount = 0, 0, 0
		attribution.Add("item:19019", "Winner", 1, 90, sessionId, nil, { transactionId = transactionId })
		local scheduledCallback
		local schedule = scenario.schedule
			or function(callback)
				scheduledCallback = callback
				return callback
			end
		local observedReason
		local provisional = attribution.ConfirmProvisional(
			"item:19019",
			"Winner",
			sessionId,
			1,
			transactionId,
			1,
			schedule,
			function()
				error("failed grace timer must not need cancellation")
			end,
			function()
				finalizeCount = finalizeCount + 1
				if scenario.throwFinalize then
					error("finalize exploded")
				end
				return finalizeCount
			end,
			function(reason)
				failureCount = failureCount + 1
				observedReason = reason
				if reason == "record_finalize_failed" then
					assertEqual(
						nil,
						attribution.Remove("item:19019", "Winner", 8, sessionId, false, false),
						scenario.name .. " reported failure before consuming pending ownership"
					)
				end
			end
		)
		if scheduledCallback then
			scheduledCallback()
		end
		assertTrue(provisional and provisional.finalized, scenario.name .. " did not finalize immediately")
		assertEqual("LOOT_SLOT_CLEARED", provisional.finalizedSource, scenario.name .. " source differs")
		assertEqual(1, finalizeCount, scenario.name .. " finalization count differs")
		assertEqual(1, failureCount, scenario.name .. " must report one failure")
		assertEqual(scenario.expectedReason, observedReason, scenario.name .. " failure reason differs")
		assertEqual(
			nil,
			attribution.Remove("item:19019", "Winner", 8, sessionId, false, false),
			scenario.name .. " retained a consumable pending award"
		)
		local reconciled, reconcileReason = attribution.ReconcileProvisional(
			"item:19019",
			"Winner",
			sessionId,
			transactionId,
			nil,
			function()
				reconcileCount = reconcileCount + 1
			end
		)
		if scenario.throwFinalize then
			assertEqual(nil, reconciled, scenario.name .. " falsely reported handled reconciliation")
			assertEqual("provisional_record_unavailable", reconcileReason, scenario.name .. " fallback reason differs")
			assertEqual(0, reconcileCount, scenario.name .. " applied authoritative data without a record")
		else
			assertTrue(reconciled, scenario.name .. " did not remain authoritatively reconcilable")
			assertEqual(1, reconcileCount, scenario.name .. " reconciliation count differs")
		end
		assertEqual(1, finalizeCount, scenario.name .. " authoritative reconciliation repeated finalization")
		assertEqual(1, failureCount, scenario.name .. " authoritative reconciliation repeated failure reporting")
	end

	local controllerFixture = installLootHardeningMasterFixture(newAddon(), { realLootFlow = true })
	assertTrue(controllerFixture.master._Private.BtnAward(nil, nil), "controller failure fixture admission failed")
	controllerFixture.throwNextSchedule = true
	assertEqual(
		true,
		controllerFixture.master._awardConfirmation:Confirm(1),
		"controller scheduler fallback did not complete confirmation"
	)
	assertEqual(1, controllerFixture.warningCount, "controller scheduler fallback did not warn exactly once")
	assertEqual(1, #controllerFixture.raid.loot, "controller scheduler fallback did not record once")
	assertEqual(
		"LOOT_SLOT_CLEARED",
		controllerFixture.raid.loot[1].source,
		"controller scheduler fallback record source differs"
	)

	local fallbackFailures = {
		{ name = "finalizer throw", throwFinalize = true },
		{ name = "finalizer zero", recordIndex = 0 },
	}
	local parsed = {
		msg = "loot-msg",
		kind = "winner",
		itemLink = "item:19019",
		itemCount = 2,
		playerName = "Winner",
	}
	for i = 1, #fallbackFailures do
		local scenario = fallbackFailures[i]
		local fixture = installLootHardeningMasterFixture(newAddon(), { realLootFlow = true })
		local finalizeCalls = 0
		function fixture.loot:LogTradeOnlyLoot()
			finalizeCalls = finalizeCalls + 1
			if scenario.throwFinalize then
				error("record finalize exploded")
			end
			return scenario.recordIndex
		end
		assertTrue(fixture.master._Private.BtnAward(nil, nil), scenario.name .. " admission failed")
		assertEqual(true, fixture.master._awardConfirmation:Confirm(1), scenario.name .. " confirmation failed")
		fixture.timerCallbacks[#fixture.timerCallbacks]()
		assertEqual(1, finalizeCalls, scenario.name .. " finalizer count differs after grace")
		assertEqual(1, fixture.warningCount, scenario.name .. " warning count differs after grace")
		assertEqual(0, #fixture.raid.loot, scenario.name .. " created an invalid provisional row")
		assertEqual(
			nil,
			fixture.loot.LootAttribution.Remove("item:19019", "Winner", 8, "RS:1", false, false),
			scenario.name .. " retained pending attribution after grace"
		)

		fixture.loot:AddLoot("loot-msg", nil, nil, parsed)
		assertEqual(1, #fixture.raid.loot, scenario.name .. " authoritative fallback row count differs")
		assertEqual("CHAT_MSG_LOOT", fixture.raid.loot[1].source, scenario.name .. " authoritative source differs")
		assertEqual(1, finalizeCalls, scenario.name .. " reconciliation repeated finalization")
		assertEqual(1, fixture.warningCount, scenario.name .. " reconciliation repeated warning")
		assertEqual(
			nil,
			fixture.loot.LootAttribution.Remove("item:19019", "Winner", 8, "RS:1", false, false),
			scenario.name .. " reconciliation restored pending attribution"
		)

		fixture.loot:AddLoot("loot-msg", nil, nil, parsed)
		assertEqual(1, #fixture.raid.loot, scenario.name .. " duplicate authoritative event created another row")
		assertEqual(1, finalizeCalls, scenario.name .. " duplicate event repeated finalization")
		assertEqual(1, fixture.warningCount, scenario.name .. " duplicate event repeated warning")
	end
	print("PASS loot_attribution_schedule_failure_finalizes_once")
end

function cases.loot_attribution_terminal_callbacks_are_contained(addon)
	local lootState = { pendingAwards = {} }
	_G.GetTime = function()
		return 10
	end
	addon.C = { PENDING_AWARD_TTL_SECONDS = 8 }
	addon.Diag = { D = { LogLootPendingAwardConsumed = "%s %s %s %s" } }
	addon.Options = {
		IsDebugEnabled = function()
			return false
		end,
	}
	addon.Strings = {
		NormalizeName = function(value)
			return value
		end,
	}
	addon.Item = {
		GetItemStringFromLink = function(link)
			return link
		end,
	}
	addon.Database = {
		EnsureLootRuntimeState = function()
			return {}, lootState
		end,
	}
	addon.Services = {
		EnsureNamespace = function(name)
			addon.Services[name] = addon.Services[name] or {}
			return addon.Services[name]
		end,
	}
	loadAddonFile(addon, "Raid Management Addon/Services/Loot/LootAttribution.lua")
	local attribution = addon.Services.Loot.LootAttribution

	local authoritativeFailures = {
		{
			name = "finalizer throw",
			finalize = function()
				error("record callback exploded")
			end,
		},
		{
			name = "finalizer zero",
			finalize = function()
				return 0
			end,
		},
	}
	for i = 1, #authoritativeFailures do
		local scenario = authoritativeFailures[i]
		local sessionId = "RS:authoritative:" .. tostring(i)
		local transactionId = "AT:authoritative:" .. tostring(i)
		local finalizeCount, authoritativeCount, warningCount = 0, 0, 0
		attribution.Add("item:19019", "Winner", 1, 90, sessionId, nil, { transactionId = transactionId })
		attribution.StageAuthoritative("item:19019", "Winner", { itemCount = 1 }, function()
			authoritativeCount = authoritativeCount + 1
		end)
		local provisional = attribution.ConfirmProvisional(
			"item:19019",
			"Winner",
			sessionId,
			1,
			transactionId,
			1,
			nil,
			nil,
			function(...)
				finalizeCount = finalizeCount + 1
				return scenario.finalize(...)
			end,
			function()
				warningCount = warningCount + 1
			end
		)
		assertTrue(provisional and provisional.finalized, scenario.name .. " did not become terminal")
		assertEqual(1, finalizeCount, scenario.name .. " finalizer count differs")
		assertEqual(0, authoritativeCount, scenario.name .. " reconciled without a positive record id")
		assertEqual(1, warningCount, scenario.name .. " warning count differs")
		assertEqual(
			nil,
			attribution.Remove("item:19019", "Winner", 8, sessionId, false, false),
			scenario.name .. " retained pending ownership"
		)
		assertEqual(
			nil,
			attribution.ConfirmProvisional(
				"item:19019",
				"Winner",
				sessionId,
				1,
				transactionId,
				1,
				nil,
				nil,
				scenario.finalize
			),
			scenario.name .. " admitted duplicate finalization"
		)
		local reconciled, reconcileReason = attribution.ReconcileProvisional(
			"item:19019",
			"Winner",
			sessionId,
			transactionId,
			nil,
			function()
				authoritativeCount = authoritativeCount + 1
			end
		)
		assertTrue(
			reconciled and reconciled.finalized and reconciled.reconciled,
			scenario.name .. " lost terminal duplicate ownership"
		)
		assertEqual(nil, reconcileReason, scenario.name .. " repeated terminal reason differs")
		assertEqual(0, authoritativeCount, scenario.name .. " applied authoritative data without a positive record id")
		assertEqual(1, finalizeCount, scenario.name .. " repeated finalization")
		assertEqual(1, warningCount, scenario.name .. " repeated warning")
	end

	local finalizeCount, authoritativeCount, warningCount, reentrantResult = 0, 0, 0, true
	attribution.Add("item:18832", "Winner", 1, 80, "RS:post", nil, { transactionId = "AT:post" })
	attribution.StageAuthoritative("item:18832", "Winner", { itemCount = 1 }, function()
		authoritativeCount = authoritativeCount + 1
		reentrantResult = attribution.ConfirmProvisional(
			"item:18832",
			"Winner",
			"RS:post",
			1,
			"AT:post",
			1,
			nil,
			nil,
			function()
				return 99
			end
		)
		error("authoritative callback exploded")
	end)
	local postRecord = attribution.ConfirmProvisional(
		"item:18832",
		"Winner",
		"RS:post",
		1,
		"AT:post",
		1,
		nil,
		nil,
		function()
			finalizeCount = finalizeCount + 1
			return 7
		end,
		function()
			warningCount = warningCount + 1
		end
	)
	assertTrue(
		postRecord and postRecord.finalized and postRecord.reconciled,
		"post-record callback lost terminal state"
	)
	assertEqual(7, postRecord.recordIndex, "post-record callback lost the valid record id")
	assertEqual(nil, reentrantResult, "post-record callback observed live pending ownership")
	assertEqual(1, finalizeCount, "post-record callback repeated record creation")
	assertEqual(1, authoritativeCount, "post-record callback count differs")
	assertEqual(1, warningCount, "post-record callback warning count differs")

	local reconcileCount, reconcileWarnings = 0, 0
	attribution.Add("item:17182", "Winner", 1, 70, "RS:reconcile", nil, { transactionId = "AT:reconcile" })
	local scheduled
	attribution.ConfirmProvisional(
		"item:17182",
		"Winner",
		"RS:reconcile",
		1,
		"AT:reconcile",
		1,
		function(callback)
			scheduled = callback
			return callback
		end,
		nil,
		function()
			return 8
		end,
		function()
			reconcileWarnings = reconcileWarnings + 1
		end
	)
	attribution.StageAuthoritative("item:17182", "Winner", { itemCount = 1 })
	local reconciled = attribution.ReconcileProvisional(
		"item:17182",
		"Winner",
		"RS:reconcile",
		"AT:reconcile",
		nil,
		function()
			reconcileCount = reconcileCount + 1
			error("reconcile callback exploded")
		end
	)
	assertTrue(
		reconciled and reconciled.finalized and reconciled.reconciled,
		"reconcile callback escaped terminal state"
	)
	assertEqual(1, reconcileCount, "reconcile callback count differs")
	assertEqual(1, reconcileWarnings, "reconcile callback warning count differs")
	assertTrue(
		attribution.ReconcileProvisional("item:17182", "Winner", "RS:reconcile", "AT:reconcile", nil, function()
			reconcileCount = reconcileCount + 1
		end),
		"repeat reconcile lost terminal result"
	)
	assertEqual(1, reconcileCount, "repeat reconcile invoked callback")
	assertEqual(1, reconcileWarnings, "repeat reconcile repeated warning")
	if scheduled then
		scheduled()
	end
	assertEqual(1, reconcileCount, "stale timer changed reconciliation")
	print("PASS loot_attribution_terminal_callbacks_are_contained")
end

function cases.loot_service_stages_authoritative_before_consumption(addon)
	local lootState, itemInfo, raidState = {}, {}, {}
	local raid = { loot = {} }
	local raidRecord = { raidUid = "fixture-authoritative", status = "active", state = raid }
	local raidStore = {
		GetActiveRecord = function()
			return raidRecord
		end,
	}
	local staged, removed = 0, 0
	_G.table.wipe = _G.table.wipe
		or function(target)
			for key in pairs(target) do
				target[key] = nil
			end
			return target
		end
	_G.GetLootThreshold = function()
		return 2
	end
	_G.GetItemInfo = function()
		return "Thunderfury", nil, 5, nil, nil, "Weapon", nil, nil, nil, "texture"
	end
	addon.C =
		{ itemColors = {}, rollTypes = {}, PENDING_AWARD_TTL_SECONDS = 8, GROUP_LOOT_PENDING_AWARD_TTL_SECONDS = 60 }
	addon.L = {}
	addon.Diag = { D = setmetatable({}, {
		__index = function()
			return "%s %s %s %s"
		end,
	}) }
	addon.Events = {
		Internal = {
			RaidLootUpdate = "RaidLootUpdate",
			SetItem = "SetItem",
			LootDistributionSessionChanged = "LootDistributionSessionChanged",
		},
	}
	addon.Bus = { TriggerEvent = function() end, RegisterCallback = function() end }
	addon.Deformat = function()
		return nil
	end
	addon.Options = {
		GetValue = function()
			return false
		end,
		NormalizeLoggerLootQualityThreshold = function(value)
			return tonumber(value) or 2
		end,
	}
	addon.Strings = {
		NormalizeName = function(value)
			return value
		end,
	}
	addon.Time = {
		GetCurrentTime = function()
			return 10
		end,
	}
	addon.Timer = {
		BindMixin = function(target)
			function target:ScheduleTimer()
				return {}
			end
			function target:CancelTimer()
				return true
			end
		end,
	}
	addon.Item = {
		GetItemStringFromLink = function()
			return "item:19019"
		end,
		GetItemIdFromLink = function()
			return 19019
		end,
		GetItemKey = function()
			return "item:19019"
		end,
	}
	addon.Database = {
		EnsureLootRuntimeState = function()
			return {}, lootState, itemInfo, raidState
		end,
		GetCurrentRaid = function()
			return 1
		end,
		GetPlayerName = function()
			return "Tester"
		end,
		GetRaidQueries = function()
			return { ResolveLootLooterName = function() end }
		end,
		GetRaidStore = function()
			return raidStore
		end,
	}
	local noopOwner = setmetatable({}, {
		__index = function()
			return function() end
		end,
	})
	local attribution = setmetatable({
		StageAuthoritative = function(_, _, authoritative)
			staged = staged + 1
			assertEqual(2, authoritative.itemCount, "service did not stage authoritative count")
			return true
		end,
		Remove = function()
			removed = removed + 1
			return nil
		end,
	}, getmetatable(noopOwner))
	addon.Services = {
		EnsureNamespace = function(name)
			addon.Services[name] = addon.Services[name] or {}
			return addon.Services[name]
		end,
		Loot = {
			LootAttribution = attribution,
			_PassiveGroupLoot = setmetatable({
				IsPassiveGroupLootMethod = function()
					return false
				end,
				IsPassiveLootWinnerMessage = function()
					return false
				end,
			}, getmetatable(noopOwner)),
			_Tracking = noopOwner,
			_Workflow = noopOwner,
			_Recording = noopOwner,
			_Rules = {
				_IsIgnoredItem = function()
					return false
				end,
			},
			AwardPlanner = noopOwner,
			Inventory = noopOwner,
			DistributionSession = noopOwner,
			_Context = {
				ResolveRaidRecord = function()
					return 1, raid
				end,
			},
		},
	}
	loadAddonFile(addon, "Raid Management Addon/Services/Loot/Service.lua")
	addon.Services.Loot:AddLoot("loot-msg", nil, nil, {
		msg = "loot-msg",
		kind = "winner",
		itemLink = "item:19019",
		itemCount = 2,
		playerName = "Winner",
	})
	assertEqual(1, staged, "authoritative chat was not staged exactly once")
	assertEqual(0, removed, "pending award was consumed before transaction confirmation")
	print("PASS loot_service_stages_authoritative_before_consumption")
end

function cases.loot_award_event_orders_share_full_production_chain(addon)
	local function pendingCount(fixture)
		local count = 0
		for _, list in pairs(fixture.lootState.pendingAwards or {}) do
			count = count + #list
		end
		return count
	end
	local function assertConfirmedOnce(fixture, label)
		assertEqual(1, #fixture.raid.loot, label .. " canonical record count differs")
		local row = fixture.raid.loot[1]
		assertEqual("item:19019", row.itemString, label .. " item key differs")
		assertEqual(2, row.itemCount, label .. " authoritative count differs")
		assertEqual(4, row.rollType, label .. " roll type differs")
		assertEqual(90, row.rollValue, label .. " roll value differs")
		assertEqual("CHAT_MSG_LOOT", row.source, label .. " record source differs")
		assertEqual(0, pendingCount(fixture), label .. " retained pending attribution")
		assertEqual(false, fixture.master._awardConfirmation:HasInFlight(), label .. " retained confirmation")
		assertEqual(1, fixture.assignments, label .. " physical effect count differs")
		assertEqual(1, fixture.attempts, label .. " attempt count differs")
		assertEqual(1, fixture.realProvisionalConfirmCalls, label .. " provisional confirmation count differs")
		assertEqual(1, fixture.distributionCalls, label .. " distribution checkpoint count differs")
		assertEqual(1, fixture.counterCalls, label .. " counter checkpoint count differs")
		local checkpoints = fixture.lastAttempt:GetState().checkpoints
		assertEqual(true, checkpoints.provisional_attribution, label .. " provisional checkpoint missing")
		assertEqual(true, checkpoints.distribution_notification, label .. " distribution checkpoint missing")
		assertEqual(true, checkpoints.player_counter, label .. " counter checkpoint missing")
	end
	local parsed = {
		msg = "loot-msg",
		kind = "winner",
		itemLink = "item:19019",
		itemCount = 2,
		playerName = "Winner",
	}

	local chatFirst = installLootHardeningMasterFixture(addon, { realLootFlow = true })
	assertTrue(chatFirst.master._Private.BtnAward(nil, nil), "chat-first controller admission failed")
	assertEqual(1, chatFirst.assignments, "chat-first controller admission did not reach effect")
	assertEqual(1, chatFirst.realAddPendingCalls, "chat-first admission did not call real loot service")
	assertEqual(1, chatFirst.realAttributionAddCalls, "chat-first admission did not call real attribution owner")
	assertEqual("item:19019", chatFirst.realAddPendingItem, "chat-first pending item differs")
	assertEqual("Winner", chatFirst.realAddPendingWinner, "chat-first pending winner differs")
	assertTrue(
		chatFirst.loot.LootAttribution.Refresh("item:19019", "Winner", 8, "RS:1") ~= nil,
		"chat-first real attribution owner cannot find admitted pending"
	)
	assertEqual(1, pendingCount(chatFirst), "chat-first award did not create pending attribution")
	chatFirst.loot:AddLoot("loot-msg", nil, nil, parsed)
	assertEqual(0, #chatFirst.raid.loot, "chat-first event logged before slot confirmation")
	assertEqual(1, pendingCount(chatFirst), "chat-first event consumed pending before confirmation")
	local chatConfirmed, chatReason = chatFirst.master._awardConfirmation:Confirm(1)
	assertTrue(chatConfirmed, "chat-first confirmation failed: " .. tostring(chatReason))
	assertConfirmedOnce(chatFirst, "chat-first")
	local chatStale = chatFirst.timerCallbacks[chatFirst.realLootSetupTimers + 1]
	chatStale()
	assertEqual(1, #chatFirst.raid.loot, "chat-first stale timeout duplicated record")
	assertEqual(1, chatFirst.realProvisionalConfirmCalls, "chat-first stale timeout repeated confirmation")
	assertEqual(
		false,
		chatFirst.master._awardConfirmation:HasInFlight(),
		"chat-first stale timeout restored confirmation"
	)
	assertTrue(chatFirst.master._Private.BtnAward(nil, nil), "chat-first next award was blocked")
	assertEqual(2, chatFirst.attempts, "chat-first next admission attempt count differs")

	local slotFirst = installLootHardeningMasterFixture(newAddon(), { realLootFlow = true })
	assertTrue(slotFirst.master._Private.BtnAward(nil, nil), "slot-first controller admission failed")
	assertTrue(slotFirst.master._awardConfirmation:Confirm(1), "slot-first confirmation failed")
	assertEqual(0, #slotFirst.raid.loot, "slot-first confirmation logged before chat/grace")
	assertEqual(false, slotFirst.master._awardConfirmation:HasInFlight(), "slot-first confirmation remained in flight")
	local slotGrace = slotFirst.timerCallbacks[slotFirst.realLootSetupTimers + 2]
	slotFirst.loot:AddLoot("loot-msg", nil, nil, parsed)
	assertConfirmedOnce(slotFirst, "slot-first")
	slotGrace()
	assertEqual(1, #slotFirst.raid.loot, "slot-first stale grace callback duplicated record")
	assertEqual(1, slotFirst.realProvisionalConfirmCalls, "slot-first stale grace repeated confirmation")
	assertEqual(
		false,
		slotFirst.master._awardConfirmation:HasInFlight(),
		"slot-first stale grace restored confirmation"
	)
	assertTrue(slotFirst.master._Private.BtnAward(nil, nil), "slot-first next award was blocked")
	assertEqual(2, slotFirst.attempts, "slot-first next admission attempt count differs")
	print("PASS loot_award_event_orders_share_full_production_chain")
end

function cases.loot_master_warns_once_when_authoritative_reconciliation_fails(addon)
	local fixture = installLootHardeningMasterFixture(addon, { realLootFlow = true })
	local finalizeCalls = 0
	local logTradeOnlyLoot = fixture.loot.LogTradeOnlyLoot
	function fixture.loot:LogTradeOnlyLoot(...)
		finalizeCalls = finalizeCalls + 1
		return logTradeOnlyLoot(self, ...)
	end
	local parsed = {
		msg = "loot-msg",
		kind = "winner",
		itemLink = "item:19019",
		itemCount = 2,
		playerName = "Winner",
	}

	assertTrue(fixture.master._Private.BtnAward(nil, nil), "reconcile warning controller admission failed")
	assertTrue(fixture.master._awardConfirmation:Confirm(1), "reconcile warning slot confirmation failed")
	fixture.throwRaidLootUpdateAt = (fixture.raidLootUpdateCount or 0) + 2
	fixture.loot:AddLoot("loot-msg", nil, nil, parsed)
	assertEqual(1, finalizeCalls, "reconcile warning finalization count differs")
	assertEqual(1, #fixture.raid.loot, "reconcile warning canonical record count differs")
	assertEqual(1, fixture.warningCount, "reconcile failure must warn exactly once")
	assertEqual("attribution record_reconcile_failed", fixture.lastWarning, "reconcile failure warning text differs")
	assertEqual(
		nil,
		fixture.loot.LootAttribution.Remove("item:19019", "Winner", 8, "RS:1", false, false),
		"reconcile failure retained pending ownership"
	)

	fixture.loot:AddLoot("loot-msg", nil, nil, parsed)
	assertEqual(1, finalizeCalls, "duplicate authoritative event repeated finalization")
	assertEqual(1, #fixture.raid.loot, "duplicate authoritative event created another record")
	assertEqual(1, fixture.warningCount, "duplicate authoritative event repeated warning")
	print("PASS loot_master_warns_once_when_authoritative_reconciliation_fails")
end

function cases.loot_master_effect_boundary_is_failure_safe(addon)
	local function pendingCount(fixture)
		local count = 0
		for _ in pairs(fixture.pendingAttributions or {}) do
			count = count + 1
		end
		return count
	end
	local function run(configure)
		local target = newAddon()
		local fixture = installLootHardeningMasterFixture(target)
		configure(fixture)
		local ok, reason = fixture.awardSequence:TrySingleCopy("item:19019", "Winner")
		return fixture, ok, reason
	end
	local fixture, ok, reason = run(function(value)
		value.slotValidationResult = nil
		value.slotValidationReason = "loot_slot_changed"
	end)
	assertEqual(nil, ok, "changed slot must fail closed")
	assertEqual("loot_slot_changed", reason, "changed slot reason differs")
	assertEqual(0, fixture.assignments, "changed slot reached GiveMasterLoot")
	assertEqual(0, pendingCount(fixture), "changed slot retained attribution")

	fixture, ok, reason = run(function(value)
		value.permissionDenied = true
	end)
	assertEqual(nil, ok, "permission change must fail closed")
	assertEqual("not_master_looter", reason, "permission reason differs")
	assertEqual(0, fixture.assignments, "permission change reached GiveMasterLoot")

	fixture, ok, reason = run(function(value)
		value.winnerIneligible = true
	end)
	assertEqual(nil, ok, "eligibility change must fail closed")
	assertEqual("winner_ineligible", reason, "eligibility reason differs")

	fixture, ok, reason = run(function(value)
		value.lootBanAtCheck = 2
		value.candidateUnavailable = true
	end)
	assertEqual(nil, ok, "new Loot Ban must fail closed")
	assertEqual("loot_ban", reason, "Loot Ban must retain precedence over candidate failure")

	fixture, ok, reason = run(function(value)
		value.candidateUnavailable = true
	end)
	assertEqual(nil, ok, "candidate change must fail closed")
	assertEqual("candidate_unavailable", reason, "candidate reason differs")

	for _, mode in ipairs({ "nil", "throw" }) do
		fixture, ok, reason = run(function(value)
			value[mode == "nil" and "nilNextSchedule" or "throwNextSchedule"] = true
		end)
		assertEqual(nil, ok, mode .. " scheduler must fail closed")
		assertEqual("confirmation_schedule_failed", reason, mode .. " scheduler reason differs")
		assertEqual(false, fixture.master._awardConfirmation:HasPending(), mode .. " scheduler left confirmation")
		assertEqual(0, pendingCount(fixture), mode .. " scheduler left attribution")
		assertEqual(0, fixture.assignments, mode .. " scheduler reached GiveMasterLoot")
	end

	for _, mode in ipairs({ "throw", "false" }) do
		fixture, ok, reason = run(function(value)
			value[mode == "throw" and "throwGiveMasterLoot" or "rejectGiveMasterLoot"] = true
		end)
		assertEqual(nil, ok, mode .. " GiveMasterLoot must be contained")
		assertEqual("give_master_loot_failed", reason, mode .. " GiveMasterLoot reason differs")
		assertEqual(false, fixture.master._awardConfirmation:HasPending(), mode .. " GiveMasterLoot left confirmation")
		assertEqual(0, pendingCount(fixture), mode .. " GiveMasterLoot left attribution")
	end
	print("PASS loot_master_effect_boundary_is_failure_safe")
end

function cases.loot_master_success_and_timeout_follow_confirmation_evidence(addon)
	local function pendingCount(fixture)
		local count = 0
		for _ in pairs(fixture.pendingAttributions or {}) do
			count = count + 1
		end
		return count
	end
	local fixture = installLootHardeningMasterFixture(addon)
	assertTrue(fixture.awardSequence:TrySingleCopy("item:19019", "Winner"), "award must reach pending confirmation")
	assertEqual(1, fixture.assignments, "physical award count differs")
	assertEqual(0, fixture.rollEndCalls or 0, "ROLL_END published before confirmation")
	assertEqual(0, fixture.distributionCalls, "ITEM_DONE published before confirmation")
	assertEqual(0, fixture.announcementCalls or 0, "announcement published before confirmation")
	assertEqual(0, fixture.whisperCalls or 0, "whisper published before confirmation")
	assertEqual(true, fixture.master._awardConfirmation:Confirm(1), "slot evidence must confirm award")
	assertEqual(1, fixture.rollEndCalls, "ROLL_END must publish exactly once")
	assertEqual(1, fixture.distributionCalls, "ITEM_DONE must publish exactly once")
	assertEqual(1, fixture.announcementCalls, "announcement must publish exactly once")
	assertEqual(1, fixture.whisperCalls, "whisper must publish exactly once")

	local failed = installLootHardeningMasterFixture(newAddon())
	assertTrue(failed.awardSequence:TrySingleCopy("item:19019", "Winner"), "UI failure fixture must queue")
	failed.pendingAttributions["AT:unrelated"] = true
	failed.master:UI_ERROR_MESSAGE("Inventory is full")
	assertEqual(false, failed.master._awardConfirmation:HasPending(), "known UI failure retained confirmation")
	assertEqual(1, pendingCount(failed), "known UI failure removed unrelated attribution")
	assertEqual(true, failed.pendingAttributions["AT:unrelated"], "known UI failure removed wrong transaction")
	assertEqual(0, failed.distributionCalls, "known UI failure published success")

	local present = installLootHardeningMasterFixture(newAddon())
	assertTrue(present.awardSequence:TrySingleCopy("item:19019", "Winner"), "present timeout fixture must queue")
	present.pendingAttributions["AT:unrelated"] = true
	present.timerCallbacks[1]()
	assertEqual(false, present.master._awardConfirmation:HasPending(), "present target timeout retained ownership")
	assertEqual(1, pendingCount(present), "present timeout removed unrelated attribution")
	assertEqual("failed", present.lastAttempt:GetState().state, "present timeout must become known failure")
	assertEqual(0, present.distributionCalls, "present timeout published success")

	local absent = installLootHardeningMasterFixture(newAddon())
	assertTrue(absent.awardSequence:TrySingleCopy("item:19019", "Winner"), "absent timeout fixture must queue")
	absent.slotValidationResult = nil
	absent.slotValidationReason = "loot_slot_missing"
	absent.timerCallbacks[1]()
	assertEqual(false, absent.master._awardConfirmation:HasPending(), "absent target did not retry confirmation")
	assertEqual("confirmed", absent.lastAttempt:GetState().state, "absent target confirmation retry failed")
	assertEqual(1, absent.distributionCalls, "absent target did not publish confirmed success")

	local unavailable = installLootHardeningMasterFixture(newAddon())
	assertTrue(
		unavailable.awardSequence:TrySingleCopy("item:19019", "Winner"),
		"unavailable timeout fixture must queue"
	)
	unavailable.lootState.opened = false
	unavailable.timerCallbacks[1]()
	assertEqual(
		true,
		unavailable.master._awardConfirmation:HasPending(),
		"unavailable loot window resolved prematurely"
	)
	assertEqual("uncertain", unavailable.lastAttempt:GetState().state, "unavailable loot window must remain uncertain")
	assertEqual(0, unavailable.distributionCalls, "unavailable loot window published success")
	unavailable.timerCallbacks[#unavailable.timerCallbacks]()
	assertEqual(false, unavailable.master._awardConfirmation:HasPending(), "uncertain expiry retained ownership")
	assertEqual(0, pendingCount(unavailable), "uncertain expiry retained stale attribution")
	print("PASS loot_master_success_and_timeout_follow_confirmation_evidence")
end

function cases.loot_master_announcement_failure_is_retry_safe(addon)
	local fixture = installLootHardeningMasterFixture(addon)
	assertTrue(fixture.awardSequence:TrySingleCopy("item:19019", "Winner"), "award must reach confirmation")
	fixture.rejectAnnouncement = true
	local confirmed, reason = fixture.master._awardConfirmation:Confirm(1)
	assertEqual(nil, confirmed, "failed announcement must retain confirmation ownership")
	assertEqual("send_failed", reason, "failed announcement reason differs")
	assertEqual("uncertain", fixture.lastAttempt:GetState().state, "failed announcement must remain retryable")
	assertEqual(true, fixture.master._awardConfirmation:HasPending(), "failed announcement released confirmation")
	assertEqual(1, fixture.rollEndCalls, "failed announcement duplicated ROLL_END")
	assertEqual(1, fixture.distributionCalls, "failed announcement duplicated ITEM_DONE")
	assertEqual(1, fixture.counterCalls, "failed announcement duplicated player counter")
	assertEqual(1, fixture.announcementCalls, "failed announcement attempt count differs")
	assertEqual(0, fixture.whisperCalls or 0, "whisper ran after failed announcement")

	fixture.rejectAnnouncement = false
	assertEqual(true, fixture.master._awardConfirmation:Confirm(1), "announcement retry must confirm")
	assertEqual(false, fixture.master._awardConfirmation:HasPending(), "successful retry retained confirmation")
	assertEqual(1, fixture.rollEndCalls, "announcement retry duplicated ROLL_END")
	assertEqual(1, fixture.distributionCalls, "announcement retry duplicated ITEM_DONE")
	assertEqual(1, fixture.counterCalls, "announcement retry duplicated player counter")
	assertEqual(2, fixture.announcementCalls, "announcement retry count differs")
	assertEqual(1, fixture.whisperCalls, "successful retry must whisper exactly once")
	print("PASS loot_master_announcement_failure_is_retry_safe")
end

function cases.warning_controller_reports_terminal_announcement_outcomes(addon)
	local infos, warnings, errors = {}, {}, {}
	local outcome = { true, nil, { sent = true, channel = "RAID", fallback = false } }
	addon.L = {
		MsgWarningAnnounced = "sent %s",
		MsgWarningLocalFallback = "local fallback",
		ErrWarningAnnouncement = "announcement failed: %s",
	}
	addon.info = function(_, message, value)
		infos[#infos + 1] = value and string.format(message, value) or message
	end
	addon.warn = function(_, message)
		warnings[#warnings + 1] = message
	end
	addon.error = function(_, message, value)
		errors[#errors + 1] = value and string.format(message, value) or message
	end
	addon.Controllers = {}
	addon.State.warningsSavedVariablesFresh = false
	addon.Database.RequireServiceMethod = function(_, owner, method)
		return assert(owner[method])
	end
	addon.Services.Chat = {
		AnnounceWarningMessage = function()
			return unpack(outcome)
		end,
	}
	addon.Services.Warnings = {
		Store = {
			GetStore = function()
				return { { name = "Pull", content = "Pull now" } }
			end,
			GetWarning = function(id)
				return id == 1 and { name = "Pull", content = "Pull now" } or nil
			end,
			EnsureDefaultTemplates = function()
				return { added = 0, total = 1 }
			end,
			DeleteWarning = function()
				return { deleted = true, total = 0 }
			end,
			SaveWarning = function()
				return 1
			end,
		},
	}
	addon.Events.Internal = { WarningsDataChanged = "WarningsDataChanged" }
	addon.Bus.RegisterCallback = function() end
	local noopController = { Dirty = function() end }
	addon.UI = {
		Lists = {
			CreateController = function()
				return noopController
			end,
			MakeIndexedRowName = function()
				return "row"
			end,
			CreateRowRenderer = function(callback)
				return callback
			end,
		},
		Frames = {
			MakeModuleFrameGetter = function()
				return function()
					return nil
				end
			end,
		},
		Scaffold = { DefineModule = function() end },
		Primitives = {},
		EditBoxes = {},
		ModuleState = {
			Ensure = function()
				return {}
			end,
		},
	}
	addon.Strings = {
		TrimText = function(value)
			return value or ""
		end,
	}
	loadAddonFile(addon, "Raid Management Addon/Controllers/Warnings.lua")

	local ok, reason, detail = addon.Controllers.Warnings:RequestAnnounce(1)
	assertEqual(true, ok, "successful controller announce result differs")
	assertEqual(true, detail.sent, "controller must preserve delivery detail")
	assertEqual("sent RAID", infos[1], "controller must report confirmed channel delivery")
	outcome = { true, nil, { sent = false, channel = "LOCAL", fallback = true } }
	ok, reason, detail = addon.Controllers.Warnings:RequestAnnounce(1)
	assertEqual(true, ok, "local fallback keeps compatible success result")
	assertEqual("local fallback", warnings[1], "controller must identify local fallback")
	outcome = { nil, "send_failed", { sent = false, channel = "RAID", fallback = false, reason = "send_failed" } }
	ok, reason = addon.Controllers.Warnings:RequestAnnounce(1)
	assertEqual(nil, ok, "controller must preserve terminal failure")
	assertEqual("announcement failed: send_failed", errors[1], "controller must report terminal failure reason")
	print("PASS warning_controller_reports_terminal_announcement_outcomes")
end

function cases.loot_canonical_mutations_advance_revision_before_notification(addon)
	local fixture = installLootHardeningMasterFixture(addon, { realLootFlow = true })
	local loot = fixture.loot
	local recording = loot._Recording
	local function assertNextEventRevision(previousRevision, previousEvents, label)
		assertEqual(previousEvents + 1, #fixture.lootEventRevisions, label .. " event count differs")
		assertTrue(
			fixture.lootEventRevisions[#fixture.lootEventRevisions] > previousRevision,
			label .. " notified before revision advanced"
		)
	end

	local previousRevision = fixture.lootRevision
	local previousEvents = #fixture.lootEventRevisions
	assertTrue(
		loot:LogTradeOnlyLoot("item:19019", "Winner", addon.C.rollTypes.MANUAL, 90, 1, "MASTER_LOOT", 1, 1, "RS:direct")
			> 0,
		"direct Master Loot record was not appended"
	)
	assertNextEventRevision(previousRevision, previousEvents, "direct Master Loot append")

	loot:AddPendingAward(
		"item:19019",
		"Winner",
		addon.C.rollTypes.HOLD,
		0,
		"RS:hold",
		nil,
		{ transactionId = "AT:hold" }
	)
	loot:AddLoot("loot-msg", nil, nil, {
		msg = "loot-msg",
		kind = "winner",
		itemLink = "item:19019",
		itemCount = 2,
		playerName = "Winner",
	})
	previousRevision = fixture.lootRevision
	previousEvents = #fixture.lootEventRevisions
	local provisional = loot.LootAttribution.ConfirmProvisional(
		"item:19019",
		"Winner",
		"RS:hold",
		1,
		"AT:hold",
		1,
		nil,
		nil,
		function()
			return loot:LogTradeOnlyLoot(
				"item:19019",
				"Winner",
				addon.C.rollTypes.HOLD,
				0,
				1,
				"LOOT_SLOT_CLEARED",
				1,
				1,
				"RS:hold"
			)
		end
	)
	assertTrue(provisional and provisional.finalized, "Hold award was not provisionally committed")
	assertEqual(previousEvents + 2, #fixture.lootEventRevisions, "authoritative Hold event count differs")
	assertTrue(
		fixture.lootEventRevisions[previousEvents + 1] > previousRevision,
		"provisional Hold append notified before revision advanced"
	)
	assertTrue(
		fixture.lootEventRevisions[previousEvents + 2] > fixture.lootEventRevisions[previousEvents + 1],
		"authoritative Hold update notified before revision advanced"
	)

	assertTrue(
		loot:LogTradeOnlyLoot(
			"item:19019",
			"Winner",
			addon.C.rollTypes.HOLD,
			0,
			1,
			"LOOT_SLOT_CLEARED",
			1,
			1,
			"RS:trade"
		) > 0,
		"trade fallback record was not appended"
	)
	previousRevision = fixture.lootRevision
	previousEvents = #fixture.lootEventRevisions
	assertTrue(
		loot:LogTradeOnlyLoot("item:19019", "Winner", addon.C.rollTypes.HOLD, 80, 2, "TRADE_ONLY", 1, 1, "RS:trade") > 0,
		"later Hold trade completion was not merged"
	)
	assertNextEventRevision(previousRevision, previousEvents, "Hold trade reconciliation")

	previousRevision = fixture.lootRevision
	previousEvents = #fixture.lootEventRevisions
	local invalid = recording.Append(fixture.raid, nil)
	assertEqual(nil, invalid, "invalid recording append was accepted")
	assertEqual(previousRevision, fixture.lootRevision, "failed commit advanced revision")
	assertEqual(previousEvents, #fixture.lootEventRevisions, "failed commit emitted a notification")
	print("PASS loot_canonical_mutations_advance_revision_before_notification")
end

function cases.loot_semantic_store_failure_is_atomic(addon)
	local fixture = installLootHardeningMasterFixture(addon, { realLootFlow = true })
	local recording = fixture.loot._Recording
	local before = deepCopy(fixture.raid)
	local revisionBefore = fixture.lootRevision
	local eventsBefore = #fixture.lootEventRevisions
	local commitCalls = 0
	fixture.lootStore.CommitAuthoritativeEvent = function()
		commitCalls = commitCalls + 1
		return nil, "INJECTED_STORE_FAILURE"
	end
	local appended = recording.Append(fixture.raid, {
		lootNid = 1,
		itemId = 19019,
		itemName = "Thunderfury",
		itemString = "item:19019",
		itemLink = "item:19019",
		itemCount = 1,
		time = 10,
	})
	assertEqual(nil, appended, "failed loot commit must reject append")
	assertEqual(1, commitCalls, "loot owner must reach semantic store")
	assertTrue(deepEqual(before, fixture.raid), "failed loot commit mutated canonical raid")
	assertEqual(revisionBefore, fixture.lootRevision, "failed loot commit advanced sequence")
	assertEqual(eventsBefore, #fixture.lootEventRevisions, "failed loot commit published an event")

	fixture.lootStore.CommitAuthoritativeEvent = function()
		return { staged = true, eventType = "LOOT_ADDED" }, "HANDOVER_STAGED"
	end
	local stagedOk, staged, _, _, stagingReason = pcall(recording.Append, fixture.raid, {
		lootNid = 1,
		itemId = 19019,
		itemName = "Thunderfury",
		itemString = "item:19019",
		itemLink = "item:19019",
		itemCount = 1,
		time = 10,
	})
	assertTrue(stagedOk, "staged loot commit treated a staging reason as canonical state")
	assertEqual(nil, staged, "staged loot commit reported a canonical append before handover")
	assertEqual("HANDOVER_STAGED", stagingReason, "staged loot commit did not preserve its non-canonical outcome")
	assertTrue(deepEqual(before, fixture.raid), "staged loot commit mutated canonical raid state")
	print("PASS loot_semantic_store_failure_is_atomic")
end

function cases.raid_capabilities_accept_numeric_unit_identity(addon)
	local raidMaster = 2
	local lootMethod = "master"
	local playerRank = 0
	local inRaid = true
	local activeRaid = 1
	local unitOwners = {
		player = "Local",
		raid1 = "Local",
		raid2 = "Disonesta",
		raid3 = "Member",
	}
	local namedUnits = {
		Local = "raid1",
		Disonesta = "raid2",
		Member = "raid3",
	}

	_G.GetLootMethod = function()
		return lootMethod, nil, raidMaster
	end
	_G.UnitIsUnit = function(left, right)
		if unitOwners[left] and unitOwners[left] == unitOwners[right] then
			return 1
		end
		return nil
	end
	_G.UnitName = function(unit)
		return unitOwners[unit]
	end
	_G.GetNumRaidMembers = function()
		return 3
	end
	_G.GetRaidRosterInfo = function(index)
		local names = { "Local", "Disonesta", "Member" }
		return names[index], index == 1 and 2 or 0
	end

	addon.L = {}
	addon.warn = function() end
	addon.Database.GetUnitRank = function(unit)
		return unit == "player" and playerRank or 0
	end
	addon.Database.GetPlayerName = function()
		return "Local"
	end
	addon.Database.GetCurrentRaid = function()
		return activeRaid
	end
	addon.Strings = {
		NormalizeLower = function(value)
			return value and string.lower(string.match(value, "^([^%-]+)") or value) or nil
		end,
	}
	addon.Services.EnsureNamespace = function(name)
		addon.Services[name] = addon.Services[name] or {}
		return addon.Services[name]
	end
	addon.Services.Raid = {
		GetUnitID = function(_, name)
			return namedUnits[name] or "none"
		end,
		IsPlayerInRaid = function()
			return inRaid
		end,
	}

	loadAddonFile(addon, "Raid Management Addon/Services/Raid/Capabilities.lua")
	local Raid = addon.Services.Raid
	assertEqual("Disonesta", Raid:GetMasterLooterName(), "current raid master name differs")
	assertEqual(true, Raid:IsLootAuthority("Disonesta"), "numeric UnitIsUnit result must accept remote master looter")
	assertEqual(false, Raid:IsLootAuthority("Member"), "ordinary raid member must not be loot authority")
	assertEqual(false, Raid:IsLootAuthority("Outsider"), "outsider must not be loot authority")
	assertEqual(false, Raid:IsMasterLooter(), "local player must not own a remote master-loot role")
	playerRank = 2
	assertEqual(true, Raid:CanCommitRaidHistory(), "identified raid leader could not commit raid history")
	assertEqual(false, Raid:CanObservePassiveLoot(), "split raid leader/master looter observed master-loot chat")
	playerRank = 0

	raidMaster = 1
	assertEqual("Local", Raid:GetMasterLooterName(), "local raid master name differs")
	assertEqual(true, Raid:IsMasterLooter(), "numeric UnitIsUnit result must preserve local master-looter detection")

	lootMethod = "group"
	playerRank = 2

	assertEqual("Local", Raid:GetRaidLeaderName(), "group-loot raid leader differs")
	assertEqual(true, Raid:IsRaidLeader(), "group-loot leader must own raid authority")
	assertEqual(false, Raid:IsMasterLooter(), "group loot must not invent a master looter")
	assertEqual(true, Raid:CanObservePassiveLoot(), "group-loot leader could not observe canonical loot")

	inRaid = false
	activeRaid = nil
	playerRank = 0
	assertEqual(false, Raid:IsRaidLeader(), "non-raid Group Loot observer unexpectedly became raid leader")
	assertEqual(true, Raid:CanObservePassiveLoot(), "party/solo Group Loot observation was disabled")
	print("PASS raid_capabilities_accept_numeric_unit_identity")
end

function cases.rma_manual_loot_method_enforces_authority(addon)
	local fixture = {
		inRaid = true,
		isLeader = true,
		lootMethod = "group",
	}
	local calls = {}

	_G.UnitInRaid = function() return fixture.inRaid end
	_G.UnitName = function(unit)
		if unit == "player" then return "Tester" end
		return nil
	end
	_G.SetLootMethod = function(method, masterLooter)
		calls[#calls + 1] = { method = method, masterLooter = masterLooter }
	end
	_G.GetTime = function() return 0 end
	_G.UnitExists = function() return false end
	_G.UnitGUID = function() return nil end
	_G.UnitIsDead = function() return false end

	addon.L = {
		MsgQuickBarLootMethodUnsupported = "RMA: Unsupported loot method.",
		MsgQuickBarRaidRequired = "RMA: You must be in a raid to change the loot method.",
		MsgQuickBarLeaderRequired = "RMA: Only the raid leader can change the loot method.",
		MsgQuickBarPlayerNameUnavailable = "RMA: Your player name is unavailable.",
		MsgQuickBarMasterLootSet = "RMA: Loot method set to Master Loot.",
		MsgQuickBarGroupLootSet = "RMA: Loot method set to Group Loot.",
	}
	addon.Bus.TriggerEvent = function() end
	addon.Database.GetPlayerName = function() return "Tester" end
	addon.Events.Internal = {
		ScreenNotice = "ScreenNotice",
		GroupLootRestoreNeeded = "GroupLootRestoreNeeded",
	}
	addon.Options = {
		RegisterNamespace = function() end,
		GetValue = function() return false end,
	}
	addon.Services.EnsureNamespace = function(name)
		addon.Services[name] = addon.Services[name] or {}
		return addon.Services[name]
	end
	addon.Services.Raid = {
		GetCreatureId = function() return nil end,
		GetPlayerRoleState = function() return { isLeader = fixture.isLeader } end,
		GetLootMethodName = function() return fixture.lootMethod end,
	}
	addon.warn = function() end
	addon.info = function() end

	loadAddonFile(addon, "Raid Management Addon/Services/Raid/LootMethod.lua")
	local Raid = addon.Services.Raid
	assertEqual(false, Raid:RequestLootMethod("freeforall"), "unsupported methods must be rejected")
	fixture.inRaid = false
	assertEqual(false, Raid:RequestLootMethod("master"), "solo players must be rejected")
	fixture.inRaid = true
	fixture.isLeader = false
	assertEqual(false, Raid:RequestLootMethod("group"), "non-leaders must be rejected")
	fixture.isLeader = true
	assertEqual(true, Raid:RequestLootMethod("master"), "leader master-loot request must succeed")
	assertEqual("master", calls[1].method, "master-loot method differs")
	assertEqual("Tester", calls[1].masterLooter, "master looter must be the player")
	fixture.lootMethod = "group"
	assertEqual(true, Raid:RequestLootMethod("group"), "already-active method must be idempotent")
	assertEqual(1, #calls, "idempotent request must not call SetLootMethod")
	print("PASS rma_manual_loot_method_enforces_authority")
end

function cases.rma_quick_bar_routes_actions_and_persists_position(addon)
	local fixture = {
		lootMethod = "group",
		inRaid = true,
		historyToggles = 0,
		reservesToggles = 0,
		warningToggles = 0,
	}
	local minimapStore = { values = {} }
	function minimapStore:Get(key) return self.values[key] end
	function minimapStore:Set(key, value) self.values[key] = value end
	local callbacks = {}

	local function makeWidget(width, height)
		local widget = { width = width or 0, height = height or 0, shown = true, enabled = true }
		function widget:Enable() self.enabled = true end
		function widget:Disable() self.enabled = false end
		function widget:IsEnabled() return self.enabled end
		function widget:SetScript(kind, callback) self[kind] = callback end
		function widget:RegisterForClicks() end
		function widget:SetText(text) self.text = text end
		function widget:SetVertexColor(r, g, b) self.vertexColor = { r, g, b } end
		function widget:ClearAllPoints() self.point = nil end
		function widget:SetPoint(point, relativeTo, relativePoint, x, y)
			self.point, self.relativeTo, self.relativePoint, self.x, self.y = point, relativeTo, relativePoint, x, y
		end
		function widget:SetSize(newWidth, newHeight) self.width, self.height = newWidth, newHeight end
		function widget:GetWidth() return self.width end
		function widget:GetHeight() return self.height end
		function widget:Show() self.shown = true end
		function widget:Hide() self.shown = false end
		function widget:IsShown() return self.shown end
		function widget:Click()
			if self.enabled and self.OnClick then
				self.OnClick(self)
			end
		end
		function widget:MouseDown(button) self.OnMouseDown(self, button) end
		function widget:MouseUp(button) self.OnMouseUp(self, button) end
		return widget
	end
	local function makeFrame(centerX, centerY)
		local frame = makeWidget(206, 32)
		frame.name = "RMAQuickBarFrame"
		frame.shown = false
		frame.centerX, frame.centerY = centerX or 512, centerY or 204
		function frame:GetName() return self.name end
		function frame:GetCenter() return self.centerX, self.centerY end
		function frame:StartMoving() self.moving = true end
		function frame:StopMovingOrSizing() self.moving = false end
		return frame
	end
	local frame = makeFrame()

	local refs = {
		Handle = makeWidget(24, 24),
		ML = makeWidget(32, 24),
		GL = makeWidget(32, 24),
		HIS = makeWidget(38, 24),
		SR = makeWidget(32, 24),
		RW = makeWidget(32, 24),
		Separator1 = makeWidget(),
		Separator2 = makeWidget(),
		Separator3 = makeWidget(),
		MLGlow = makeWidget(50, 50),
		GLGlow = makeWidget(50, 50),
	}
	_G.UIParent = {
		GetWidth = function() return 1024 end,
		GetHeight = function() return 768 end,
		GetCenter = function() return 512, 384 end,
	}
	_G.RMAQuickBarFrame = frame
	addon.Bus = {
		TriggerEvent = function(eventName, ...)
			local callback = callbacks[eventName]
			if callback then callback(...) end
		end,
		RegisterCallback = function(eventName, callback) callbacks[eventName] = callback end,
	}
	installInitStubs(addon)
	loadAddonFile(addon, "Raid Management Addon/Init.lua")
	addon.L = {
		BtnQuickBarML = "ML", BtnQuickBarGL = "GL", BtnQuickBarHIS = "HIS", BtnQuickBarSR = "SR", BtnQuickBarRW = "RW",
		StrQuickBarHandleTooltip = "drag", StrQuickBarMasterLootTooltip = "master", StrQuickBarGroupLootTooltip = "group",
		StrQuickBarHistoryTooltip = "history", StrQuickBarSoftResTooltip = "reserves", StrQuickBarRaidWarningTooltip = "warnings",
		PopupQuickBarMasterLoot = "master?", PopupQuickBarGroupLoot = "group?",
	}
	addon.Options = { RegisterNamespace = function(_, defaults)
		local quickBarKeyCount = 0
		for key in pairs(defaults) do
			assertTrue(
				key == "quickBar" or key == "quickBarX" or key == "quickBarY"
				or key == "quickBarOrientation" or key == "quickBarShowML" or key == "quickBarShowGL"
				or key == "quickBarShowSR" or key == "quickBarShowHIS" or key == "quickBarShowRW",
				"QuickBar options contain an unexpected key"
			)
			quickBarKeyCount = quickBarKeyCount + 1
		end
		assertEqual(9, quickBarKeyCount, "QuickBar options must contain exactly nine keys")
		for key, value in pairs(defaults) do
			if minimapStore.values[key] == nil then minimapStore.values[key] = value end
		end
		return minimapStore
	end }
	addon.UI = {
		Frames = {
			GetRef = function(_, suffix) return refs[suffix] end,
			SetScriptSafely = function(widget, kind, callback) widget:SetScript(kind, callback) end,
			SetShown = function(target, shown) if shown then target:Show() else target:Hide() end end,
		},
		Tooltips = { Bind = function() end },
		Popups = { ShowConfirm = function(key, _, accept) fixture.popupKey, fixture.popupAccept = key, accept end },
	}
	addon.Controllers = {
		Logger = { ToggleLootHistory = function() fixture.historyToggles = fixture.historyToggles + 1 end },
		Warnings = { Toggle = function() fixture.warningToggles = fixture.warningToggles + 1 end },
	}
	addon.Widgets = { ReservesUI = { Toggle = function() fixture.reservesToggles = fixture.reservesToggles + 1 end } }
	addon.Services.Raid = {
		GetLootMethodName = function() return fixture.lootMethod end,
		IsPlayerInRaid = function() return fixture.inRaid end,
		RequestLootMethod = function(_, method)
			fixture.requestedMethod = method
			if not fixture.deferLootMethodUpdate then
				fixture.lootMethod = method
			end
			return true
		end,
	}

	loadAddonFile(addon, "Raid Management Addon/Widgets/QuickBar.lua")
	local widget = addon.Widgets.QuickBar
	widget:EnsureUI()
	assertEqual(false, widget:IsShown(), "QuickBar must default to hidden")
	assertEqual(false, frame:IsShown(), "default-hidden frame must stay hidden")
	assertEqual(0, frame.x, "default X differs")
	assertEqual(-180, frame.y, "default Y differs")
	fixture.deferLootMethodUpdate = true
	refs.ML:Click()
	assertEqual("RMA_QUICK_BAR_MASTER_LOOT", fixture.popupKey, "ML popup key differs")
	fixture.popupAccept()
	assertEqual("master", fixture.requestedMethod, "ML action differs")
	assertEqual(true, refs.MLGlow:IsShown(), "successful ML request must update the glow immediately")
	assertEqual(false, refs.GLGlow:IsShown(), "successful ML request must clear the GL glow immediately")
	fixture.deferLootMethodUpdate = false
	fixture.lootMethod = "master"
	addon:PARTY_LOOT_METHOD_CHANGED()
	fixture.deferLootMethodUpdate = true
	refs.GL:Click()
	fixture.popupAccept()
	assertEqual("group", fixture.requestedMethod, "GL action differs")
	assertEqual(false, refs.MLGlow:IsShown(), "successful GL request must clear the ML glow immediately")
	assertEqual(true, refs.GLGlow:IsShown(), "successful GL request must update the glow immediately")
	fixture.deferLootMethodUpdate = false
	fixture.lootMethod = "group"
	addon:PARTY_LOOT_METHOD_CHANGED()
	refs.HIS:Click()
	refs.SR:Click()
	refs.RW:Click()
	assertEqual(1, fixture.historyToggles, "history toggle count differs")
	assertEqual(1, fixture.reservesToggles, "SoftRes toggle count differs")
	assertEqual(1, fixture.warningToggles, "warning toggle count differs")
	assertEqual(false, refs.MLGlow:IsShown(), "group loot must hide ML glow")
	assertEqual(true, refs.GLGlow:IsShown(), "group loot must show GL glow")
	fixture.lootMethod = "master"
	addon:PARTY_LOOT_METHOD_CHANGED()
	assertEqual(true, refs.MLGlow:IsShown(), "master loot must show ML glow")
	assertEqual(false, refs.GLGlow:IsShown(), "master loot must hide GL glow")
	frame.centerX, frame.centerY = 612, 284
	refs.Handle:MouseDown("LeftButton")
	refs.Handle:MouseUp("LeftButton")
	assertEqual(100, minimapStore:Get("quickBarX"), "saved X differs")
	assertEqual(-100, minimapStore:Get("quickBarY"), "saved Y differs")
	widget:SetShown(true)
	assertEqual(true, minimapStore:Get("quickBar"), "visibility must persist")

	addon.Widgets.QuickBar = nil
	local restoredFrame = makeFrame()
	_G.RMAQuickBarFrame = restoredFrame
	loadAddonFile(addon, "Raid Management Addon/Widgets/QuickBar.lua")
	local restoredWidget = addon.Widgets.QuickBar
	restoredWidget:EnsureUI()
	assertEqual(true, restoredWidget:IsShown(), "saved visibility must restore")
	assertEqual(true, restoredFrame:IsShown(), "saved-visible frame must restore")
	assertEqual(100, restoredFrame.x, "restored X differs")
	assertEqual(-100, restoredFrame.y, "restored Y differs")

	minimapStore:Set("quickBarX", 10000)
	minimapStore:Set("quickBarY", -10000)
	addon.Widgets.QuickBar = nil
	local clampedFrame = makeFrame()
	_G.RMAQuickBarFrame = clampedFrame
	loadAddonFile(addon, "Raid Management Addon/Widgets/QuickBar.lua")
	addon.Widgets.QuickBar:EnsureUI()
	assertEqual(403.5, clampedFrame.x, "clamped X differs")
	assertEqual(-368, clampedFrame.y, "clamped Y differs")
	print("PASS rma_quick_bar_routes_actions_and_persists_position")
end

function cases.rma_quick_bar_configures_layout_and_glow(addon)
	local fixture = { lootMethod = "group", inRaid = false, popupCount = 0 }
	local minimapStore = { values = {} }
	function minimapStore:Get(key) return self.values[key] end
	function minimapStore:Set(key, value) self.values[key] = value end
	local callbacks = {}

	local function makeWidget(width, height)
		local widget = { width = width or 0, height = height or 0, shown = true, enabled = true }
		function widget:Enable() self.enabled = true end
		function widget:Disable() self.enabled = false end
		function widget:IsEnabled() return self.enabled end
		function widget:SetScript(kind, callback) self[kind] = callback end
		function widget:RegisterForClicks() end
		function widget:SetText(text) self.text = text end
		function widget:SetVertexColor(r, g, b) self.vertexColor = { r, g, b } end
		function widget:ClearAllPoints() self.point = nil end
		function widget:SetPoint(point, relativeTo, relativePoint, x, y)
			self.point, self.relativeTo, self.relativePoint, self.x, self.y = point, relativeTo, relativePoint, x, y
		end
		function widget:SetSize(newWidth, newHeight) self.width, self.height = newWidth, newHeight end
		function widget:GetWidth() return self.width end
		function widget:GetHeight() return self.height end
		function widget:Show() self.shown = true end
		function widget:Hide() self.shown = false end
		function widget:IsShown() return self.shown end
		function widget:Click()
			if self.enabled and self.OnClick then
				self.OnClick(self)
			end
		end
		return widget
	end
	local frame = makeWidget(206, 32)
	frame.name = "RMAQuickBarFrame"
	frame.shown = false
	frame.centerX, frame.centerY = 512, 204
	function frame:GetName() return self.name end
	function frame:GetCenter() return self.centerX, self.centerY end
	function frame:StartMoving() self.moving = true end
	function frame:StopMovingOrSizing() self.moving = false end

	local refs = {
		Handle = makeWidget(24, 24),
		ML = makeWidget(32, 24),
		GL = makeWidget(32, 24),
		HIS = makeWidget(38, 24),
		SR = makeWidget(32, 24),
		RW = makeWidget(32, 24),
		Separator1 = makeWidget(),
		Separator2 = makeWidget(),
		Separator3 = makeWidget(),
		MLGlow = makeWidget(50, 50),
		GLGlow = makeWidget(50, 50),
	}
	_G.UIParent = {
		GetWidth = function() return 1024 end,
		GetHeight = function() return 768 end,
		GetCenter = function() return 512, 384 end,
	}
	_G.RMAQuickBarFrame = frame
	addon.Bus = {
		TriggerEvent = function(eventName, ...)
			local callback = callbacks[eventName]
			if callback then callback(...) end
		end,
		RegisterCallback = function(eventName, callback) callbacks[eventName] = callback end,
	}
	installInitStubs(addon)
	loadAddonFile(addon, "Raid Management Addon/Init.lua")
	addon.L = {
		BtnQuickBarML = "ML", BtnQuickBarGL = "GL", BtnQuickBarHIS = "HIS", BtnQuickBarSR = "SR", BtnQuickBarRW = "RW",
		StrQuickBarHandleTooltip = "drag", StrQuickBarMasterLootTooltip = "master", StrQuickBarGroupLootTooltip = "group",
		StrQuickBarHistoryTooltip = "history", StrQuickBarSoftResTooltip = "reserves", StrQuickBarRaidWarningTooltip = "warnings",
		PopupQuickBarMasterLoot = "master?", PopupQuickBarGroupLoot = "group?",
	}
	addon.Options = { RegisterNamespace = function(_, defaults)
		for key, value in pairs(defaults) do
			if minimapStore.values[key] == nil then minimapStore.values[key] = value end
		end
		return minimapStore
	end }
	addon.UI = {
		Frames = {
			GetRef = function(_, suffix) return refs[suffix] end,
			SetScriptSafely = function(widget, kind, callback) widget:SetScript(kind, callback) end,
			SetShown = function(target, shown) if shown then target:Show() else target:Hide() end end,
		},
		Tooltips = { Bind = function() end },
		Popups = {
			ShowConfirm = function()
				fixture.popupCount = fixture.popupCount + 1
			end,
		},
	}
	addon.Controllers = {
		Logger = { ToggleLootHistory = function() end },
		Warnings = { Toggle = function() end },
	}
	addon.Widgets = { ReservesUI = { Toggle = function() end } }
	addon.Services.Raid = {
		GetLootMethodName = function() return fixture.lootMethod end,
		IsPlayerInRaid = function() return fixture.inRaid end,
		RefreshAndPublish = function()
			fixture.rosterRefreshes = (fixture.rosterRefreshes or 0) + 1
			return nil
		end,
		RequestLootMethod = function() return true end,
	}

	loadAddonFile(addon, "Raid Management Addon/Widgets/QuickBar.lua")
	local widget = addon.Widgets.QuickBar
	widget:EnsureUI()
	assertEqual(false, refs.ML:IsEnabled(), "ML must be disabled outside a raid party")
	assertEqual(false, refs.GL:IsEnabled(), "GL must be disabled outside a raid party")
	assertEqual(false, refs.MLGlow:IsShown(), "ML glow must be hidden outside a raid party")
	assertEqual(false, refs.GLGlow:IsShown(), "GL glow must be hidden outside a raid party")
	refs.ML:Click()
	assertEqual(0, fixture.popupCount, "disabled ML must not open a popup")

	fixture.inRaid = true
	addon:RAID_ROSTER_UPDATE(true)
	assertEqual(1, fixture.rosterRefreshes, "raid roster update must refresh the raid service")
	assertEqual(true, refs.ML:IsEnabled(), "ML must enable inside a raid party")
	assertEqual(true, refs.GL:IsEnabled(), "GL must enable inside a raid party")
	assertEqual("horizontal", widget:GetOrientation(), "default orientation differs")
	for _, key in ipairs({ "ML", "GL", "SR", "HIS", "RW" }) do
		assertEqual(true, widget:IsButtonShown(key), key .. " must default visible")
	end

	widget:SetOrientation("vertical")
	assertEqual("vertical", minimapStore:Get("quickBarOrientation"), "vertical orientation must persist")
	assertEqual("TOP", refs.ML.point, "vertical ML anchor differs")
	assertEqual("TOP", refs.GL.point, "vertical GL anchor differs")

	widget:SetButtonShown("GL", false)
	widget:SetButtonShown("HIS", false)
	assertEqual(false, refs.GL:IsShown(), "GL must hide immediately")
	assertEqual(false, refs.HIS:IsShown(), "HIS must hide immediately")
	assertEqual(true, refs.Separator1:IsShown(), "separator before SR must remain")
	assertEqual(true, refs.Separator2:IsShown(), "separator before RW must compact")
	assertEqual(false, refs.Separator3:IsShown(), "unused separator must hide")

	for _, key in ipairs({ "ML", "SR", "RW" }) do
		widget:SetButtonShown(key, false)
	end
	assertEqual(true, refs.Handle:IsShown(), "handle-only mode must keep the icon")
	assertEqual(false, refs.Separator1:IsShown(), "handle-only mode must hide separators")

	widget:SetButtonShown("ML", true)
	fixture.lootMethod = "master"
	widget:RefreshLootMethod()
	assertEqual(true, refs.MLGlow:IsShown(), "Master Loot must show ML glow")
	assertEqual(false, refs.GLGlow:IsShown(), "Master Loot must hide GL glow")
	widget:SetButtonShown("GL", true)
	fixture.lootMethod = "group"
	addon:PARTY_LOOT_METHOD_CHANGED()
	assertEqual(false, refs.MLGlow:IsShown(), "Group Loot must hide ML glow")
	assertEqual(true, refs.GLGlow:IsShown(), "Group Loot must show GL glow")
	fixture.inRaid = false
	addon:RAID_ROSTER_UPDATE(true)
	assertEqual(2, fixture.rosterRefreshes, "leaving the raid party must refresh the raid service")
	assertEqual(false, refs.ML:IsEnabled(), "ML must disable after leaving the raid party")
	assertEqual(false, refs.GL:IsEnabled(), "GL must disable after leaving the raid party")
	assertEqual(false, refs.MLGlow:IsShown(), "ML glow must clear after leaving the raid party")
	assertEqual(false, refs.GLGlow:IsShown(), "GL glow must clear after leaving the raid party")
	refs.GL:Click()
	assertEqual(0, fixture.popupCount, "disabled GL must not open a popup")
	print("PASS rma_quick_bar_configures_layout_and_glow")
end

function cases.rma_minimap_remains_available_without_quick_bar(addon)
	local fixture = { tooltipCalls = 0, configToggles = 0 }
	local minimapStore = { values = {} }
	function minimapStore:Get(key) return self.values[key] end
	function minimapStore:Set(key, value) self.values[key] = value end

	local frame = { shown = false }
	function frame:SetScript(kind, callback) self[kind] = callback end
	function frame:SetUserPlaced() end
	function frame:ClearAllPoints() end
	function frame:SetPoint() end
	function frame:RegisterForClicks() end
	function frame:Show() self.shown = true end
	function frame:Hide() self.shown = false end
	function frame:IsShown() return self.shown end
	_G.RMA_MINIMAP_GUI = frame
	_G.UIParent = {}
	_G.Minimap = { GetCenter = function() return 0, 0 end }
	_G.CreateFrame = function() return {} end
	_G.IsAltKeyDown = function() return false end
	_G.IsShiftKeyDown = function() return false end
	_G.GetCursorPosition = function() return 0, 0 end
	_G.EasyMenu = function(menu) fixture.menu = menu end
	_G.RAID_WARNING = "Raid Warning"

	addon.L = {
		StrLootMaster = "Loot Master",
		StrLootReserve = "Loot Reserve",
		StrLootCounter = "Loot Counter",
		StrLootHistory = "Loot History",
		StrRaidAttendance = "Attendance",
		StrLFMSpam = "LFM Spam",
		StrClearIcons = "Clear Icons",
		StrQuickBar = "Show QuickBar",
		StrMinimapLClick = "left",
		StrMinimapRClick = "right",
		StrMinimapSClick = "shift",
		StrMinimapAClick = "alt",
	}
	addon.Options = {
		RegisterNamespace = function(_, defaults)
			for key, value in pairs(defaults) do
				if minimapStore.values[key] == nil then minimapStore.values[key] = value end
			end
			return minimapStore
		end,
	}
	addon.UI = {
		Frames = {
			Get = function(name) return name == "RMA_MINIMAP_GUI" and frame or nil end,
			SetShown = function(target, shown) if shown then target:Show() else target:Hide() end end,
			SetScriptSafely = function(target, kind, callback) target:SetScript(kind, callback) end,
		},
		Tooltips = {
			ShowLines = function() fixture.tooltipCalls = fixture.tooltipCalls + 1 end,
			Hide = function() end,
		},
	}
	addon.Colors = {
		WrapText = function(text) return text end,
		NormalizeHexColor = function(color) return color end,
	}
	addon.C = { R_COLOR = "ffffffff" }
	addon.Services.Raid = {
		IsPlayerInRaid = function() return false end,
		CanUseCapability = function() return true end,
		CanObservePassiveLoot = function() return false end,
		ClearRaidIcons = function() end,
	}
	addon.Controllers = {
		Master = { Toggle = function() end },
		Logger = { ToggleLootHistory = function() end },
		Attendance = { Toggle = function() end },
		Warnings = { Toggle = function() end },
		Spammer = { Toggle = function() end },
		Config = { Toggle = function() fixture.configToggles = fixture.configToggles + 1 end },
	}
	addon.Widgets = {
		LootCounter = { Toggle = function() end },
		ReservesUI = { Toggle = function() end },
	}

	loadAddonFile(addon, "Raid Management Addon/EntryPoints/Minimap.lua")
	local minimap = addon.Minimap
	assertEqual(frame, minimap:EnsureUI(), "Minimap must bind without QuickBar")
	assertTrue(type(frame.OnEnter) == "function", "Minimap tooltip script must bind")
	assertTrue(type(frame.OnClick) == "function", "Minimap click script must bind")
	frame.OnEnter(frame)
	assertEqual(1, fixture.tooltipCalls, "Minimap tooltip must remain available")
	frame.OnClick(frame, "LeftButton")
	assertTrue(type(fixture.menu) == "table", "Minimap menu must remain available")
	assertEqual("Loot Master", fixture.menu[1].text, "ordinary minimap menu entries must remain available")
	for i = 1, #fixture.menu do
		if fixture.menu[i].text == "Show QuickBar" then
			assertEqual(fixture.menu[#fixture.menu], fixture.menu[i], "QuickBar must be the final minimap row")
			assertEqual(" ", fixture.menu[#fixture.menu - 1].text, "QuickBar separator must precede its row")
			assertEqual(1, fixture.menu[i].disabled, "missing QuickBar menu row must be disabled")
		end
	end
	local quickBarToggles = 0
	addon.Widgets.QuickBar = {
		IsShown = function() return false end,
		SetShown = function(_, shown)
			assertEqual(true, shown, "QuickBar toggle must invert current visibility")
			quickBarToggles = quickBarToggles + 1
		end,
	}
	frame.OnClick(frame, "LeftButton")
	for i = 1, #fixture.menu do
		if fixture.menu[i].text == "Show QuickBar" then
			assertEqual(nil, fixture.menu[i].disabled, "available QuickBar menu row must be enabled")
			fixture.menu[i].func()
		end
	end
	assertEqual(1, quickBarToggles, "available QuickBar menu row must toggle visibility")
	frame.OnClick(frame, "RightButton")
	assertEqual(1, fixture.configToggles, "Minimap right-click must remain available")
	print("PASS rma_minimap_remains_available_without_quick_bar")
end

function cases.rma_quick_bar_slash_routes_show_hide_and_help(addon)
	local fixture = { requestedShown = {}, chatText = "" }
	addon.L = setmetatable({
		StrCmdCommands = "Commands: %s",
		StrCmdQuickBarShow = "show QuickBar",
		StrCmdQuickBarHide = "hide QuickBar",
	}, { __index = function() return "" end })
	addon.State = {}
	addon.Options = { GetValue = function() return nil end }
	addon.UI = {}
	addon.Widgets = {
		LootCounter = {}, ReservesUI = {},
		QuickBar = {
			SetShown = function(_, shown) fixture.requestedShown[#fixture.requestedShown + 1] = shown end,
		},
	}
	addon.Colors = {
		WrapText = function(text) return text end,
		NormalizeHexColor = function(color) return color end,
	}
	addon.Database = {}
	addon.Services = {}
	addon.EntryPoints = { Debug = { Handle = function() end, ShowHelp = function() end } }
	addon.Controllers = { Master = {}, Logger = {}, Attendance = {}, Warnings = {}, Spammer = {}, Config = {} }
	addon.Comms = {}
	addon.Item = {}
	addon.C = { MA_COLOR = "ffffffff" }
	addon.info = function(_, _, text)
		fixture.chatText = fixture.chatText .. tostring(text) .. "\n"
	end
	addon.warn = function() end
	addon.Strings = {
		SplitArgs = function(value)
			value = tostring(value or "")
			local first, rest = string.match(value, "^%s*(%S*)%s*(.-)%s*$")
			return first, rest
		end,
	}
	_G.SlashCmdList = {}

	loadAddonFile(addon, "Raid Management Addon/EntryPoints/SlashEvents.lua")
	SlashCmdList.RMA("quickbar show")
	assertEqual(true, fixture.requestedShown[1], "quickbar show differs")
	SlashCmdList.RMA("quickbar hide")
	assertEqual(false, fixture.requestedShown[2], "quickbar hide differs")
	SlashCmdList.RMA("quickbar")
	SlashCmdList.RMA("quickbar toggle")
	assertEqual(2, #fixture.requestedShown, "invalid arguments must not change visibility")
	SlashCmdList.RMA("help quickbar")
	assertContains(fixture.chatText, "show", "QuickBar help must list show")
	assertContains(fixture.chatText, "hide", "QuickBar help must list hide")
	print("PASS rma_quick_bar_slash_routes_show_hide_and_help")
end

function cases.rma_group_helpers_preserve_wotlk_roster_semantics(addon)
	local raidCount = 2
	local partyCount = 0
	local existingUnits = {
		raid1 = true,
		raid2 = true,
	}
	_G.GetNumRaidMembers = function()
		return raidCount
	end
	_G.GetNumPartyMembers = function()
		return partyCount
	end
	_G.UnitExists = function(unit)
		return existingUnits[unit] == true
	end

	loadAddonFile(addon, "Raid Management Addon/Modules/Group.lua")
	local Group = assert(addon.Group, "group helper owner is missing")
	local groupType, offset, members = Group.GetTypeAndCount()
	assertEqual("raid", groupType, "raid group type differs")
	assertEqual(1, offset, "raid group offset differs")
	assertEqual(2, members, "raid group count differs")

	local raidUnits = {}
	for unit in Group.IterateUnits(true) do
		raidUnits[#raidUnits + 1] = unit
	end
	assertEqual("raid1", raidUnits[1], "first raid unit differs")
	assertEqual("raid2", raidUnits[2], "second raid unit differs")

	raidCount = 0
	partyCount = 2
	existingUnits = {
		player = true,
		playerpet = true,
		party1 = true,
		partypet1 = true,
		party2 = true,
		partypet2 = true,
	}
	groupType, offset, members = Group.GetTypeAndCount()
	assertEqual("party", groupType, "party group type differs")
	assertEqual(0, offset, "party group offset differs")
	assertEqual(2, members, "party group count differs")

	local partyUnits = {}
	local owners = {}
	for unit, owner in Group.IterateUnits(false) do
		partyUnits[#partyUnits + 1] = unit
		owners[unit] = owner
	end
	assertEqual("player", partyUnits[1], "party iterator must begin with player")
	assertEqual("playerpet", partyUnits[2], "party iterator must include player pet")
	assertEqual("party1", partyUnits[3], "party iterator first member differs")
	assertEqual("partypet1", partyUnits[4], "party iterator first pet differs")
	assertEqual("player", owners.playerpet, "player pet owner differs")
	assertEqual("party1", owners.partypet1, "party pet owner differs")
	print("PASS rma_group_helpers_preserve_wotlk_roster_semantics")
end

function cases.rma_colors_own_class_and_markup_helpers(addon)
	addon.C = {
		CLASS_COLORS = {
			UNKNOWN = "ffffffff",
			WARRIOR = "ffc79c6e",
		},
	}
	_G.RAID_CLASS_COLORS = nil
	loadAddonFile(addon, "Raid Management Addon/Modules/Colors.lua")
	local Colors = assert(addon.Colors, "color helper owner is missing")
	local r, g, b, hex = Colors.GetClassColor("Warrior")
	assertTrue(r > 0.77 and r < 0.79, "warrior red component differs")
	assertTrue(g > 0.60 and g < 0.62, "warrior green component differs")
	assertTrue(b > 0.42 and b < 0.44, "warrior blue component differs")
	assertEqual("ffc79c6e", hex, "warrior class hex differs")
	assertEqual("|cffff0000Alert|r", Colors.WrapText("Alert", "ffff0000"), "color markup differs")
	print("PASS rma_colors_own_class_and_markup_helpers")
end

function cases.rma_timer_runs_without_libcompat(addon)
	local now = 0
	local frame = { shown = false }
	function frame:SetScript(kind, callback)
		self[kind] = callback
	end
	function frame:Show()
		self.shown = true
	end
	function frame:Hide()
		self.shown = false
	end
	function frame:IsShown()
		return self.shown
	end
	_G.GetTime = function()
		return now
	end
	_G.CreateFrame = function()
		return frame
	end
	_G.UIParent = {}
	_G.LibStub = nil
	addon.L = {
		MsgTimerStatsTip = "tip",
		MsgTimerStatsSummary = "%d %d %d %d %d",
		MsgTimerStatsRow = "%d %s %s %.1f %.1f",
		MsgTimerStatsReset = "reset",
	}
	addon.EntryPoints = { Debug = { RegisterCommand = function() end } }
	addon.info = function() end
	addon.error = function(_, message)
		fail(message)
	end

	loadAddonFile(addon, "Raid Management Addon/Modules/Timer.lua")
	local owner = {}
	addon.Timer.BindMixin(owner, "TimerTest")
	local oneShotArgs
	owner:ScheduleTimer(function(first, second, third)
		oneShotArgs = { first, second, third }
	end, 1, "alpha", nil, "omega")
	frame.OnUpdate(frame, 0.5)
	assertEqual(nil, oneShotArgs, "one-shot timer fired early")
	now = 1
	frame.OnUpdate(frame, 0.5)
	assertEqual("alpha", oneShotArgs[1], "one-shot first argument differs")
	assertEqual(nil, oneShotArgs[2], "one-shot nil argument differs")
	assertEqual("omega", oneShotArgs[3], "one-shot trailing argument differs")

	local ticks = 0
	local ticker = owner:ScheduleRepeatingTimer(function()
		ticks = ticks + 1
	end, 0.25)
	frame.OnUpdate(frame, 0.25)
	frame.OnUpdate(frame, 0.25)
	assertEqual(2, ticks, "repeating timer tick count differs")
	assertEqual(true, owner:CancelTimer(ticker), "active ticker cancellation must succeed")
	frame.OnUpdate(frame, 0.25)
	assertEqual(2, ticks, "cancelled ticker fired")
	assertEqual(false, owner:CancelTimer(ticker), "ticker cancellation must be deterministic")
	print("PASS rma_timer_runs_without_libcompat")
end

function cases.rma_print_preserves_chat_output_contract(addon)
	installInitStubs(addon)
	local defaultMessages = {}
	_G.DEFAULT_CHAT_FRAME = {
		AddMessage = function(_, message)
			defaultMessages[#defaultMessages + 1] = message
		end,
	}
	loadAddonFile(addon, "Raid Management Addon/Init.lua")
	assertEqual(true, addon:Print("alpha", 2, nil), "default chat print must succeed")
	assertEqual("alpha 2 nil", defaultMessages[1], "default chat print payload differs")

	local customMessages = {}
	local customFrame = {
		AddMessage = function(_, message)
			customMessages[#customMessages + 1] = message
		end,
	}
	assertEqual(true, addon:Print(customFrame, "beta", 3), "custom chat frame print must succeed")
	assertEqual("beta 3", customMessages[1], "custom chat frame print payload differs")
	print("PASS rma_print_preserves_chat_output_contract")
end

function cases.rma_logger_preserves_levels_flags_and_output_contract(addon)
	installInitStubs(addon)
	local messages = {}
	_G.DEFAULT_CHAT_FRAME = {
		AddMessage = function(_, message)
			messages[#messages + 1] = message
		end,
	}
	_G.LibStub = function(name)
		if name == "LibLogger-1.0" then
			fail("Init must not request LibLogger-1.0")
		end
		return {}
	end

	loadAddonFile(addon, "Raid Management Addon/Init.lua")
	assertEqual(3, addon.logLevels.INFO, "INFO level differs")
	assertEqual(4, addon.logLevels.DEBUG, "DEBUG level differs")
	assertEqual(3, addon:GetLogLevel(), "initial log level differs")
	assertTrue(type(addon.hasInfo) == "function", "INFO flag must expose the logger function")
	assertEqual(nil, addon.hasDebug, "DEBUG flag must be disabled at INFO level")

	addon:info("Hello %s", "world")
	addon:debug("hidden")
	assertEqual(1, #messages, "INFO level must suppress DEBUG output")
	assertEqual("Hello world", messages[1], "INFO output differs")

	addon:SetLogLevel(addon.logLevels.DEBUG)
	assertTrue(type(addon.hasDebug) == "function", "DEBUG flag must expose the logger function")
	addon:debug("Value %d", 7)
	assertEqual("|cffd9d919DEBUG:|r Value 7", messages[2], "DEBUG output differs")

	addon:SetLogLevel(addon.logLevels.NONE)
	assertEqual(nil, addon.hasError, "NONE level must disable error flag")
	addon:error("hidden")
	assertEqual(2, #messages, "NONE level must suppress all output")
	print("PASS rma_logger_preserves_levels_flags_and_output_contract")
end
