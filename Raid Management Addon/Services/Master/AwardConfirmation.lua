-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: direct addon namespace bindings
-- exports: addon.Services.Master.AwardConfirmation
-- events: none
-- notes: owns Master-loot award confirmation, timers, and terminal effects
local addon = select(2, ...)
local Diag = addon.Diag
local format = string.format
local Master = addon.Services.EnsureNamespace("Master")

local AwardConfirmation = Master.AwardConfirmation or {}
Master.AwardConfirmation = AwardConfirmation

local tinsert = table.insert
local tremove = table.remove
local tonumber = tonumber
local tostring = tostring
local type = type
local pcall = pcall

local function requireFunction(deps, name)
	local value = deps[name]
	assert(type(value) == "function", format(Diag.A.MasterAwardConfirmationRequiresFunction, name))
	return value
end

function AwardConfirmation.Create(deps)
	deps = deps or {}
	local scheduleTimer = requireFunction(deps, "scheduleTimer")
	local cancelTimer = requireFunction(deps, "cancelTimer")
	local requestRefresh = requireFunction(deps, "requestRefresh")
	local warnFailure = requireFunction(deps, "warnFailure")
	local warnUncertain = requireFunction(deps, "warnUncertain")
	local warnTimeout = requireFunction(deps, "warnTimeout")
	local warnUnresolved = requireFunction(deps, "warnUnresolved")
	local onUnresolved = requireFunction(deps, "onUnresolved")
	local confirmProvisional = requireFunction(deps, "confirmProvisional")
	local resolveTimeoutEvidence = deps.resolveTimeoutEvidence or function()
		return "unavailable"
	end
	local cancelAttribution = deps.cancelAttribution or function()
		return false
	end
	local timeoutSeconds = tonumber(deps.timeoutSeconds) or 4
	local reconciliationSeconds = tonumber(deps.reconciliationSeconds) or 8
	if reconciliationSeconds <= 0 then
		reconciliationSeconds = 8
	end
	local confirmations = {}
	local owner = {}

	local function safeCall(callback, ...)
		local ok, result = pcall(callback, ...)
		return ok and result
	end

	local function present(callback, ...)
		safeCall(callback, ...)
		safeCall(requestRefresh)
	end

	local function reportUncertain(pending, reason)
		if pending.reconciliationWarned then
			return
		end
		pending.reconciliationWarned = true
		present(warnUncertain, pending, reason)
	end

	local function remove(index)
		local pending = confirmations[index]
		if not pending then
			return nil
		end
		if pending.timeoutHandle then
			safeCall(cancelTimer, pending.timeoutHandle)
			pending.timeoutHandle = nil
		end
		if pending.reconciliationHandle then
			safeCall(cancelTimer, pending.reconciliationHandle)
			pending.reconciliationHandle = nil
		end
		tremove(confirmations, index)
		return pending
	end

	local function find(clearedSlot)
		local slot = tonumber(clearedSlot)
		for i = 1, #confirmations do
			local pending = confirmations[i]
			if not slot or tonumber(pending.itemIndex) == slot then
				return pending, i
			end
		end
		return nil, nil
	end

	local resolveUnresolved
	local handleTimeout

	function owner:Queue(opts)
		if owner:HasInFlight() then
			return nil, "award_in_flight"
		end

		opts = opts or {}
		local pending = {
			itemLink = opts.itemLink,
			itemIndex = tonumber(opts.itemIndex) or opts.itemIndex,
			playerName = opts.playerName,
			rollType = opts.rollType,
			rollValue = opts.rollValue,
			rollSessionId = opts.sessionId and tostring(opts.sessionId) or nil,
			transactionId = opts.transactionId and tostring(opts.transactionId) or nil,
			effect = assert(opts.effect, Diag.A.AwardConfirmationRequiresAnEffect),
		}
		if timeoutSeconds > 0 then
			local scheduled, handle = pcall(scheduleTimer, function()
				handleTimeout(pending)
			end, timeoutSeconds)
			if not scheduled or not handle then
				return nil, "confirmation_schedule_failed"
			end
			pending.timeoutHandle = handle
		end
		tinsert(confirmations, pending)
		return pending
	end

	resolveUnresolved = function(pending)
		for i = #confirmations, 1, -1 do
			if confirmations[i] == pending then
				pending.reconciliationHandle = nil
				remove(i)
				safeCall(cancelAttribution, pending.transactionId)
				pending.effect:MarkUncertain("confirmation_unresolved")
				safeCall(onUnresolved, pending)
				if not pending.unresolvedWarned then
					pending.unresolvedWarned = true
					present(warnUnresolved, pending)
				end
				return true
			end
		end
		return false
	end

	handleTimeout = function(pending)
		local pendingIndex
		for i = #confirmations, 1, -1 do
			if confirmations[i] == pending then
				pendingIndex = i
				break
			end
		end
		if not pendingIndex then
			return false
		end

		pending.timeoutHandle = nil
		local evidenceOk, evidence = pcall(resolveTimeoutEvidence, pending)
		if evidenceOk and evidence == "present" then
			remove(pendingIndex)
			safeCall(cancelAttribution, pending.transactionId)
			pending.effect:Fail("confirmation_timeout_item_present")
			safeCall(warnFailure, pending, "confirmation_timeout_item_present")
			return true
		end
		if evidenceOk and evidence == "absent" then
			local confirmed = owner:Confirm(pending.itemIndex)
			if confirmed == true then
				return true
			end
		else
			pending.effect:MarkUncertain("timeout")
		end

		local expiryOk, expiryHandle = pcall(scheduleTimer, function()
			resolveUnresolved(pending)
		end, reconciliationSeconds)
		if expiryOk and expiryHandle then
			pending.reconciliationHandle = expiryHandle
		else
			resolveUnresolved(pending)
		end
		if not pending.reconciliationWarned then
			pending.reconciliationWarned = true
			present(warnTimeout, timeoutSeconds, pending)
		end
		return true
	end

	function owner:HasInFlight()
		return confirmations[1] ~= nil
	end

	function owner:HasPending()
		return owner:HasInFlight()
	end

	function owner:Fail(reason, transactionId)
		local failed = false
		local resolvedTransactionId = transactionId and tostring(transactionId) or nil
		for i = #confirmations, 1, -1 do
			local candidate = confirmations[i]
			if
				candidate
				and (not resolvedTransactionId or tostring(candidate.transactionId or "") == resolvedTransactionId)
			then
				local pending = remove(i)
				failed = true
				safeCall(cancelAttribution, pending.transactionId)
				pending.effect:Fail(reason)
				safeCall(warnFailure, pending, reason)
			end
		end
		return failed
	end

	function owner:Confirm(clearedSlot)
		local pending, index = find(clearedSlot)
		if not pending then
			return false
		end
		local provisionalOk, provisionalReason = pending.effect:RunCheckpoint(
			"provisional_attribution",
			confirmProvisional,
			pending,
			clearedSlot
		)
		if not provisionalOk then
			pending.effect:MarkUncertain(provisionalReason)
			reportUncertain(pending, provisionalReason)
			return nil, provisionalReason
		end

		local confirmed, confirmReason = pending.effect:Confirm()
		if not confirmed then
			if confirmReason == "timer_schedule_failed" then
				remove(index)
				return nil, confirmReason
			end
			reportUncertain(pending, confirmReason)
			return nil, confirmReason
		end
		remove(index)
		return true
	end

	return owner
end
