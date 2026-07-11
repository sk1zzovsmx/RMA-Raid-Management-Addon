-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: direct addon namespace bindings
-- exports: addon.Services.Rolls._Responses
-- events: announces countdown blocks and whispers denial reasons
-- notes: response and eligibility helpers for rolls service

local addon = select(2, ...)
local L = addon.L
local Diag = addon.Diag
local Comms = addon.Comms
local Database = addon.Database
local Options = addon.Options
local Services = addon.Services
local Strings = addon.Strings
local Chat = Services.Chat
local NormalizeName = assert(Strings.NormalizeName, "Roll response name normalizer is not initialized")

local twipe = table.wipe
local pairs, next = pairs, next
local tostring, tonumber = tostring, tonumber

-- ----- Internal state ----- --
addon.Database.EnsureServiceNamespace("Rolls")
local Rolls = Services.Rolls
local module = Rolls
module._Responses = module._Responses or {}
local Responses = module._Responses

Responses.STATUS = Responses.STATUS
	or {
		ACTIVE = "ACTIVE",
		ROLL = "ROLL",
		PASS = "PASS",
		CANCELLED = "CANCELLED",
		TIMED_OUT = "TIMED_OUT",
		INELIGIBLE = "INELIGIBLE",
	}

Responses.REASONS = Responses.REASONS
	or {
		ELIGIBLE = "eligible",
		RESERVED = "reserved",
		FALLBACK = "fallback",
		INELIGIBLE = "ineligible",
		UNINITIALIZED = "uninitialized",
		NAME_UNRESOLVED = "name_unresolved",
		MISSING_ITEM = "missing_item",
		NOT_IN_RAID = "not_in_raid",
		MANUAL_EXCLUSION = "manual_exclusion",
		REROLL_FILTERED = "reroll_filtered",
		SESSION_INACTIVE = "session_inactive",
		ROLL_LIMIT = "roll_limit",
		PLAYER_PASS = "player_pass",
		PLAYER_CANCEL = "player_cancel",
		TIMED_OUT = "timed_out",
		MISSING_ROLL_RESPONSE = "missing_roll_response",
		NO_ACTIVE_RESPONSE = "no_active_response",
		STATE_TRANSITION_DENIED = "state_transition_denied",
		RECORD_INACTIVE = "record_inactive",
		INVALID_PLAYER = "invalid_player",
		INVALID_ROLL = "invalid_roll",
	}

local RESPONSE_STATUS = Responses.STATUS
local reasonCodes = Responses.REASONS
local GetOption = Options.GetValue
local IsDebugEnabled = Options.IsDebugEnabled

local RESPONSE_TRANSITIONS = {
	[RESPONSE_STATUS.ACTIVE] = {
		[RESPONSE_STATUS.ACTIVE] = true,
		[RESPONSE_STATUS.ROLL] = true,
		[RESPONSE_STATUS.PASS] = true,
		[RESPONSE_STATUS.TIMED_OUT] = true,
		[RESPONSE_STATUS.INELIGIBLE] = true,
	},
	[RESPONSE_STATUS.ROLL] = {
		[RESPONSE_STATUS.ROLL] = true,
		[RESPONSE_STATUS.PASS] = true,
		[RESPONSE_STATUS.CANCELLED] = true,
		[RESPONSE_STATUS.INELIGIBLE] = true,
	},
	[RESPONSE_STATUS.PASS] = {
		[RESPONSE_STATUS.PASS] = true,
		[RESPONSE_STATUS.ROLL] = true,
		[RESPONSE_STATUS.CANCELLED] = true,
		[RESPONSE_STATUS.INELIGIBLE] = true,
	},
	[RESPONSE_STATUS.CANCELLED] = {
		[RESPONSE_STATUS.CANCELLED] = true,
		[RESPONSE_STATUS.ROLL] = true,
		[RESPONSE_STATUS.PASS] = true,
		[RESPONSE_STATUS.INELIGIBLE] = true,
	},
	[RESPONSE_STATUS.TIMED_OUT] = {
		[RESPONSE_STATUS.TIMED_OUT] = true,
	},
	[RESPONSE_STATUS.INELIGIBLE] = {
		[RESPONSE_STATUS.INELIGIBLE] = true,
		[RESPONSE_STATUS.ACTIVE] = true,
		[RESPONSE_STATUS.ROLL] = true,
	},
}

-- ----- Private helpers ----- --
local function assertContext(ctx)
	assert(type(ctx) == "table", "Rolls response context is required")
	assert(type(ctx.state) == "table", "Rolls response state is required")
	return ctx, ctx.state
end

local function isRollSubmissionOpen(state)
	return state.record == true and state.canRoll == true
end

local function canTransitionResponseState(fromStatus, toStatus)
	local allowed

	if not toStatus then
		return false
	end

	fromStatus = fromStatus or RESPONSE_STATUS.ACTIVE
	if fromStatus == toStatus then
		return true
	end

	allowed = RESPONSE_TRANSITIONS[fromStatus]
	return allowed and allowed[toStatus] == true or false
end

local function getOrCreateResponse(state, name)
	local response = state.responsesByPlayer[name]
	if response then
		return response
	end

	response = {
		name = name,
		status = RESPONSE_STATUS.ACTIVE,
		explicitStatus = nil,
		bucket = "INELIGIBLE",
		reason = reasonCodes.UNINITIALIZED,
		bestRoll = nil,
		lastRoll = nil,
		usedRolls = 0,
		allowedRolls = 0,
		source = nil,
		updatedAt = nil,
		isEligible = false,
		isOutOfTime = false,
		outOfFlowReason = nil,
		outOfFlowCount = 0,
		outOfFlowLastRoll = nil,
		outOfFlowLastReason = nil,
		outOfFlowLastSource = nil,
	}
	state.responsesByPlayer[name] = response
	return response
end

local function buildEligibilityResult(
	opts,
	candidateOk,
	bucket,
	candidateReason,
	allowedRolls,
	usedRolls,
	itemId,
	itemLink,
	canSubmit,
	submitReason
)
	local result = {
		candidateOk = candidateOk == true,
		bucket = bucket or "INELIGIBLE",
		reason = candidateReason,
		allowedRolls = allowedRolls or 0,
		usedRolls = usedRolls or 0,
		itemId = itemId,
		itemLink = itemLink,
	}

	result.canSubmit = result.candidateOk == true and canSubmit ~= false
	result.submitReason = submitReason or candidateReason
	if opts and opts.mode == "submission" then
		result.ok = result.canSubmit == true
		if not result.ok then
			result.reason = result.submitReason
		end
	else
		result.ok = result.candidateOk == true
	end
	return result
end

local function getEligibilityBaseReason(currentRollType, bucket)
	if currentRollType == addon.C.rollTypes.RESERVED then
		return bucket == "SR" and reasonCodes.RESERVED or reasonCodes.FALLBACK
	end
	return reasonCodes.ELIGIBLE
end

local function isAwardRollType(rollType)
	local rollTypes = addon.C.rollTypes
	return rollType == rollTypes.MAINSPEC
		or rollType == rollTypes.OFFSPEC
		or rollType == rollTypes.RESERVED
		or rollType == rollTypes.FREE
end

local function traceEligibility(name, eligibility)
	if IsDebugEnabled() then
		addon:debug(
			Diag.D.LogRollsEligibility:format(
				tostring(name),
				tostring(eligibility.ok),
				tostring(eligibility.bucket),
				tostring(eligibility.reason),
				tonumber(eligibility.usedRolls) or 0,
				tonumber(eligibility.allowedRolls) or 0
			)
		)
	end
end

local function getDenialMessage(reason)
	if reason == reasonCodes.NOT_IN_RAID then
		return L.ChatRollNotInRaid
	end
	if reason == reasonCodes.MANUAL_EXCLUSION then
		return L.ChatRollExcluded
	end
	if reason == reasonCodes.ROLL_LIMIT then
		return L.ChatOnlyRollOnce
	end
	if reason == reasonCodes.SESSION_INACTIVE then
		return L.ChatRollInactive
	end
	if reason == reasonCodes.REROLL_FILTERED then
		return L.ChatRollTieOnly
	end
	return nil
end

local function getAwardValidationMessage(reason, playerName)
	if reason == reasonCodes.NAME_UNRESOLVED then
		return L.ErrMLWinnerNameUnresolved
	end
	if reason == reasonCodes.MANUAL_EXCLUSION then
		return L.ErrMLWinnerExcluded:format(tostring(playerName))
	end
	if reason == reasonCodes.NOT_IN_RAID then
		return L.ErrMLWinnerNotInRaid:format(tostring(playerName))
	end
	if reason == reasonCodes.PLAYER_PASS then
		return L.ErrMLWinnerPassed:format(tostring(playerName))
	end
	if reason == reasonCodes.PLAYER_CANCEL then
		return L.ErrMLWinnerCancelled:format(tostring(playerName))
	end
	if reason == reasonCodes.TIMED_OUT then
		return L.ErrMLWinnerTimedOut:format(tostring(playerName))
	end
	if reason == reasonCodes.MISSING_ROLL_RESPONSE then
		return L.ErrMLWinnerNoRoll:format(tostring(playerName))
	end
	return L.ErrMLWinnerIneligible:format(tostring(playerName))
end

local function buildWinnerValidationResult(ok, reason, playerName, eligibility, response)
	return {
		ok = ok == true,
		reason = reason,
		eligibility = eligibility,
		response = response,
		warnMessage = (ok == true) and nil or getAwardValidationMessage(reason, playerName),
	}
end

local function getAwardValidationResponseReason(response, eligibility)
	if eligibility and eligibility.ok ~= true then
		return eligibility.reason or reasonCodes.INELIGIBLE
	end
	if not response then
		return reasonCodes.MISSING_ROLL_RESPONSE
	end
	if response.status == RESPONSE_STATUS.PASS then
		return reasonCodes.PLAYER_PASS
	end
	if response.status == RESPONSE_STATUS.CANCELLED then
		return reasonCodes.PLAYER_CANCEL
	end
	if response.status == RESPONSE_STATUS.TIMED_OUT then
		return reasonCodes.TIMED_OUT
	end
	if response.status == RESPONSE_STATUS.INELIGIBLE then
		return response.reason or (eligibility and eligibility.reason) or reasonCodes.INELIGIBLE
	end
	if not Responses.IsSelectableRollResponse(response) then
		return response.reason or reasonCodes.MISSING_ROLL_RESPONSE
	end
	return nil
end

local function seedReservedCandidates(ctx, itemId, itemLink, rollType)
	local reserves
	local players

	if not itemId or rollType ~= addon.C.rollTypes.RESERVED then
		return
	end

	reserves = Services.Reserves
	if not (reserves and reserves.GetPlayersForItem) then
		return
	end

	players = reserves:GetPlayersForItem(itemId, false, false, false) or {}
	for i = 1, #players do
		local name = players[i]
		if type(name) == "string" and name ~= "" then
			Responses.SyncResponseEligibility(ctx, name, itemId, itemLink, rollType, "reserve_seed")
		end
	end
end

local function seedTieRerollCandidates(ctx, itemId, itemLink, rollType)
	local _, state = assertContext(ctx)
	local reroll = state.tieReroll

	if not (reroll and reroll.ordered) then
		return
	end

	for i = 1, #reroll.ordered do
		local name = reroll.ordered[i]
		if type(name) == "string" and name ~= "" then
			Responses.SyncResponseEligibility(ctx, name, itemId, itemLink, rollType, "tie_reroll")
		end
	end
end

local function applyAcceptedRollResponse(ctx, name, roll, eligibility, source, isOutOfTime)
	local _, state = assertContext(ctx)
	local response = getOrCreateResponse(state, name)
	local wantLow = GetOption("Master", "sortAscending") == true
	local nextUsedRolls = (eligibility and tonumber(eligibility.usedRolls) or 0) + 1

	if response.bestRoll == nil then
		response.bestRoll = roll
	elseif wantLow then
		if roll < response.bestRoll then
			response.bestRoll = roll
		end
	elseif roll > response.bestRoll then
		response.bestRoll = roll
	end

	response.lastRoll = roll
	response.status = RESPONSE_STATUS.ROLL
	response.explicitStatus = nil
	response.bucket = eligibility and eligibility.bucket or response.bucket
	response.reason = eligibility and eligibility.reason or reasonCodes.ELIGIBLE
	response.allowedRolls = eligibility and eligibility.allowedRolls or response.allowedRolls or 0
	response.usedRolls = nextUsedRolls
	response.source = source or "system_roll"
	response.updatedAt = GetTime()
	response.isEligible = true
	response.isOutOfTime = isOutOfTime == true

	if IsDebugEnabled() then
		addon:debug(
			Diag.D.LogRollsResponse:format(
				tostring(name),
				tostring(response.status),
				tostring(response.bucket),
				tostring(response.bestRoll),
				tostring(response.lastRoll)
			)
		)
	end
end

local function applyExplicitResponse(ctx, name, status, eligibility, reason, source)
	local _, state = assertContext(ctx)
	local response = getOrCreateResponse(state, name)

	response.bestRoll = nil
	response.lastRoll = nil
	response.status = status
	response.explicitStatus = status
	response.bucket = eligibility and eligibility.bucket or response.bucket
	response.reason = reason
	response.allowedRolls = eligibility and eligibility.allowedRolls or response.allowedRolls or 0
	response.usedRolls = eligibility and eligibility.usedRolls or response.usedRolls or 0
	response.source = source or reason
	response.updatedAt = GetTime()
	response.isEligible = eligibility and eligibility.ok == true or false
	response.isOutOfTime = false

	if IsDebugEnabled() then
		addon:debug(
			Diag.D.LogRollsResponse:format(
				tostring(name),
				tostring(response.status),
				tostring(response.bucket),
				tostring(response.bestRoll),
				tostring(response.lastRoll)
			)
		)
	end

	return response
end

local function recordOutOfFlowAttempt(state, player, reason, roll, source)
	local response = state.responsesByPlayer[player]
	if not response then
		return
	end
	if response.bestRoll == nil and not Responses.IsExplicitResponseStatus(response.explicitStatus) then
		return
	end

	response.outOfFlowReason = reason
	response.outOfFlowCount = (tonumber(response.outOfFlowCount) or 0) + 1
	response.outOfFlowLastRoll = tonumber(roll)
	response.outOfFlowLastReason = reason
	response.outOfFlowLastSource = source
	response.updatedAt = GetTime()
end

-- ----- Public methods ----- --

function Responses.ClearResponseState(ctx, opts)
	local _, state = assertContext(ctx)

	opts = opts or {}
	twipe(state.responsesByPlayer)
	twipe(state.deniedReasons)
	if not opts.preserveManualExclusions then
		twipe(state.manualExclusions)
	end
	if not opts.preserveTieReroll and ctx.clearTieRerollFilter then
		ctx.clearTieRerollFilter()
	end
	state.resolution = nil
	state.sessionId = nil
end

function Responses.IsExplicitResponseStatus(status)
	return status == RESPONSE_STATUS.PASS or status == RESPONSE_STATUS.CANCELLED
end

function Responses.IsSelectableRollResponse(response)
	return response
		and response.status == RESPONSE_STATUS.ROLL
		and response.bestRoll ~= nil
		and response.isEligible == true
		and response.isOutOfTime ~= true
end

function Responses.EnsureResponseSession(ctx)
	local _, state = assertContext(ctx)
	local session = ctx.getRollSession and ctx.getRollSession() or nil
	local sessionId = session and tostring(session.id) or nil

	if state.sessionId == sessionId then
		return session
	end

	Responses.ClearResponseState(ctx, {
		preserveManualExclusions = true,
	})
	state.sessionId = sessionId
	return session
end

function Responses.BuildCandidateEligibility(ctx, name, itemId, itemLink, rollType, opts)
	local _, state = assertContext(ctx)
	local currentRollType = tonumber(rollType)
		or (ctx.getActiveRollType and ctx.getActiveRollType())
		or addon.C.rollTypes.FREE
	local currentItemLink = itemLink or (ctx.getCurrentItemLink and ctx.getCurrentItemLink())
	local currentItemId = tonumber(itemId)
	local allowedRolls = 1
	local usedRolls = 0
	local bucket = ctx.getRollTypeBucket and ctx.getRollTypeBucket(currentRollType) or "FREE"
	local isReservedRoll = false
	local hasItemReserve = false

	if not currentItemId and currentItemLink then
		currentItemId = addon.Item.GetItemIdFromLink(currentItemLink)
	end
	if not currentItemId and ctx.getCurrentRollItemID then
		currentItemId = ctx.getCurrentRollItemID()
	end
	if currentItemId then
		currentItemId = tonumber(currentItemId)
	end

	if currentRollType == addon.C.rollTypes.RESERVED and currentItemId then
		isReservedRoll = true
		local reserveCount = ctx.getReserveCountForItem and ctx.getReserveCountForItem(currentItemId, name) or 0
		if reserveCount and reserveCount > 0 then
			bucket = "SR"
			allowedRolls = reserveCount
			hasItemReserve = true
		else
			bucket = "INELIGIBLE"
			allowedRolls = 0
		end
	end

	if not name or name == "" then
		return buildEligibilityResult(
			opts,
			false,
			"INELIGIBLE",
			reasonCodes.NAME_UNRESOLVED,
			0,
			0,
			currentItemId,
			currentItemLink,
			false,
			reasonCodes.NAME_UNRESOLVED
		)
	end

	if not currentItemId then
		return buildEligibilityResult(
			opts,
			false,
			"INELIGIBLE",
			reasonCodes.MISSING_ITEM,
			0,
			0,
			nil,
			currentItemLink,
			false,
			reasonCodes.MISSING_ITEM
		)
	end

	local tracker = ctx.acquireItemTracker and ctx.acquireItemTracker(currentItemId) or {}
	local currentResponse
	local raid
	local unitId
	local isSyntheticPlayer
	local manualExclusion

	usedRolls = tracker[name] or 0
	currentResponse = state.responsesByPlayer[name]
	if
		currentResponse
		and currentResponse.bestRoll == nil
		and Responses.IsExplicitResponseStatus(currentResponse.explicitStatus)
	then
		usedRolls = usedRolls - 1
		if usedRolls < 0 then
			usedRolls = 0
		end
	end

	if opts and opts.requireOpenSession and not isRollSubmissionOpen(state) then
		return buildEligibilityResult(
			opts,
			true,
			bucket,
			getEligibilityBaseReason(currentRollType, bucket),
			allowedRolls,
			usedRolls,
			currentItemId,
			currentItemLink,
			false,
			reasonCodes.SESSION_INACTIVE
		)
	end

	raid = ctx.getRaidService and ctx.getRaidService() or nil
	unitId = raid and raid.GetUnitID and raid:GetUnitID(name) or "none"
	isSyntheticPlayer = raid
		and raid.IsSyntheticPlayerActive
		and raid:IsSyntheticPlayerActive(name, Database.GetCurrentRaid())
	if (not unitId or unitId == "none") and not isSyntheticPlayer then
		return buildEligibilityResult(
			opts,
			false,
			bucket,
			reasonCodes.NOT_IN_RAID,
			allowedRolls,
			usedRolls,
			currentItemId,
			currentItemLink,
			false,
			reasonCodes.NOT_IN_RAID
		)
	end

	manualExclusion = ctx.getManualExclusionEntry and ctx.getManualExclusionEntry(name)
	if manualExclusion then
		return buildEligibilityResult(
			opts,
			false,
			bucket,
			reasonCodes.MANUAL_EXCLUSION,
			allowedRolls,
			usedRolls,
			currentItemId,
			currentItemLink,
			false,
			reasonCodes.MANUAL_EXCLUSION
		)
	end

	if isReservedRoll and not hasItemReserve then
		return buildEligibilityResult(
			opts,
			false,
			bucket,
			reasonCodes.INELIGIBLE,
			allowedRolls,
			usedRolls,
			currentItemId,
			currentItemLink,
			false,
			reasonCodes.INELIGIBLE
		)
	end

	if ctx.isTieRerollRestricted and ctx.isTieRerollRestricted(name) then
		return buildEligibilityResult(
			opts,
			false,
			bucket,
			reasonCodes.REROLL_FILTERED,
			allowedRolls,
			usedRolls,
			currentItemId,
			currentItemLink,
			false,
			reasonCodes.REROLL_FILTERED
		)
	end

	local candidateReason = getEligibilityBaseReason(currentRollType, bucket)
	local canSubmit = usedRolls < allowedRolls
	local submitReason = canSubmit and candidateReason or reasonCodes.ROLL_LIMIT

	return buildEligibilityResult(
		opts,
		true,
		bucket,
		candidateReason,
		allowedRolls,
		usedRolls,
		currentItemId,
		currentItemLink,
		canSubmit,
		submitReason
	)
end

function Responses.SyncResponseEligibility(ctx, name, itemId, itemLink, rollType, source)
	local _, state = assertContext(ctx)
	local eligibility = Responses.BuildCandidateEligibility(ctx, name, itemId, itemLink, rollType)
	local response = getOrCreateResponse(state, name)

	response.bucket = eligibility.bucket
	response.allowedRolls = eligibility.allowedRolls
	response.usedRolls = eligibility.usedRolls
	response.isEligible = eligibility.ok == true
	response.name = name
	if source then
		response.source = source
	end
	response.updatedAt = GetTime()

	if response.bestRoll ~= nil then
		response.explicitStatus = nil
		response.status = eligibility.ok and RESPONSE_STATUS.ROLL or RESPONSE_STATUS.INELIGIBLE
		response.reason = eligibility.reason
		return response, eligibility
	end

	if eligibility.ok ~= true then
		if response.status ~= RESPONSE_STATUS.TIMED_OUT then
			response.status = RESPONSE_STATUS.INELIGIBLE
		end
	elseif Responses.IsExplicitResponseStatus(response.explicitStatus) then
		response.status = response.explicitStatus
	elseif response.status ~= RESPONSE_STATUS.TIMED_OUT then
		response.status = eligibility.ok and RESPONSE_STATUS.ACTIVE or RESPONSE_STATUS.INELIGIBLE
	end

	if response.status == RESPONSE_STATUS.TIMED_OUT then
		response.reason = reasonCodes.TIMED_OUT
	elseif response.status == RESPONSE_STATUS.PASS then
		response.reason = reasonCodes.PLAYER_PASS
	elseif response.status == RESPONSE_STATUS.CANCELLED then
		response.reason = reasonCodes.PLAYER_CANCEL
	else
		response.reason = eligibility.reason
	end

	return response, eligibility
end

function Responses.PrepareResponseState(ctx, context, opts)
	opts = opts or {}

	Responses.EnsureResponseSession(ctx)
	if opts.seedReserved ~= false then
		seedReservedCandidates(ctx, context.itemId, context.itemLink, context.rollType)
	end
	if opts.seedTieReroll == true then
		seedTieRerollCandidates(ctx, context.itemId, context.itemLink, context.rollType)
	end
end

function Responses.RefreshMaterializedResponses(ctx, itemId, itemLink, rollType)
	local _, state = assertContext(ctx)

	for name in pairs(state.responsesByPlayer) do
		Responses.SyncResponseEligibility(ctx, name, itemId, itemLink, rollType)
	end
end

function Responses.FinalizeMaterializedResponses(ctx, itemId, itemLink, rollType)
	local _, state = assertContext(ctx)

	Responses.RefreshMaterializedResponses(ctx, itemId, itemLink, rollType)
	for name, response in pairs(state.responsesByPlayer) do
		if response.bestRoll == nil and response.status == RESPONSE_STATUS.ACTIVE then
			response.status = RESPONSE_STATUS.TIMED_OUT
			response.reason = reasonCodes.TIMED_OUT
			response.updatedAt = GetTime()
			if IsDebugEnabled() then
				addon:debug(Diag.D.LogRollsTimedOut:format(tostring(name)))
			end
		end
	end
end

function Responses.SubmitExplicitResponse(ctx, name, status, reason, source)
	local _, state = assertContext(ctx)
	local player = NormalizeName(name, true)
	local context
	local eligibility
	local response

	if not isRollSubmissionOpen(state) then
		return false, reasonCodes.SESSION_INACTIVE
	end

	if not player or player == "" then
		return false, reasonCodes.NAME_UNRESOLVED
	end

	context = ctx.getCurrentRollContext and ctx.getCurrentRollContext() or nil
	if not context or not context.itemId or ((ctx.getLootCount and ctx.getLootCount()) or 0) == 0 then
		return false, reasonCodes.MISSING_ITEM
	end

	Responses.PrepareResponseState(ctx, context)
	eligibility = Responses.BuildCandidateEligibility(ctx, player, context.itemId, context.itemLink, context.rollType)
	traceEligibility(player, eligibility)
	if eligibility.ok ~= true then
		state.deniedReasons[player] = eligibility.reason
		return false, eligibility.reason
	end

	response, eligibility =
		Responses.SyncResponseEligibility(ctx, player, context.itemId, context.itemLink, context.rollType, source)
	if
		status == RESPONSE_STATUS.CANCELLED
		and not (response and (response.bestRoll ~= nil or Responses.IsExplicitResponseStatus(response.explicitStatus)))
	then
		return false, reasonCodes.NO_ACTIVE_RESPONSE
	end
	if not canTransitionResponseState(response and response.status, status) then
		return false, reasonCodes.STATE_TRANSITION_DENIED
	end

	applyExplicitResponse(ctx, player, status, eligibility, reason, source)
	return true, nil
end

function Responses.SubmitIncomingRoll(ctx, player, roll, source)
	local _, state = assertContext(ctx)
	local context
	local eligibility
	local denyMessage
	local denyKey
	local isOutOfTime
	local isDebugSource = source == "debug_roll"

	if not state.record then
		return false, reasonCodes.RECORD_INACTIVE
	end

	context = ctx.getCurrentRollContext and ctx.getCurrentRollContext() or nil
	if not context or not context.itemId or ((ctx.getLootCount and ctx.getLootCount()) or 0) == 0 then
		addon:warn(Diag.W.LogRollsMissingItem)
		return false, reasonCodes.MISSING_ITEM
	end

	Responses.PrepareResponseState(ctx, context)

	eligibility = Responses.BuildCandidateEligibility(ctx, player, context.itemId, context.itemLink, context.rollType, {
		mode = "submission",
		requireOpenSession = true,
	})
	traceEligibility(player, eligibility)
	if not eligibility.ok then
		recordOutOfFlowAttempt(state, player, eligibility.reason, roll, source)
		if eligibility.reason == reasonCodes.SESSION_INACTIVE and not state.warned and not isDebugSource then
			Chat:Announce(L.ChatCountdownBlock)
			state.warned = true
		end
		denyMessage = getDenialMessage(eligibility.reason)
		denyKey = tostring(player) .. ":" .. tostring(eligibility.reason)
		if
			denyMessage
			and not state.deniedReasons[denyKey]
			and not isDebugSource
			and Comms
			and type(Comms.SendWhisper) == "function"
		then
			Comms.SendWhisper(player, denyMessage)
			state.deniedReasons[denyKey] = true
		end
		if IsDebugEnabled() then
			addon:debug(
				Diag.D.LogRollsDeniedPlayer:format(
					player,
					tonumber(eligibility.usedRolls) or 0,
					tonumber(eligibility.allowedRolls) or 0
				)
			)
		end
		return false, eligibility.reason
	end

	if IsDebugEnabled() then
		addon:debug(
			Diag.D.LogRollsAcceptedPlayer:format(
				player,
				(tonumber(eligibility.usedRolls) or 0) + 1,
				tonumber(eligibility.allowedRolls) or 0
			)
		)
	end
	if
		not canTransitionResponseState(
			state.responsesByPlayer[player] and state.responsesByPlayer[player].status,
			RESPONSE_STATUS.ROLL
		)
	then
		return false, reasonCodes.STATE_TRANSITION_DENIED
	end

	isOutOfTime = state.countdownExpired == true
	if ctx.addRoll then
		ctx.addRoll(player, roll, context.itemId)
	end
	applyAcceptedRollResponse(ctx, player, tonumber(roll), eligibility, source or "system_roll", isOutOfTime)
	return true, nil
end

function Responses.ValidateWinner(ctx, playerName, itemLink, rollType)
	local _, state = assertContext(ctx)
	local context = ctx.getCurrentRollContext and ctx.getCurrentRollContext(itemLink, rollType)
		or {
			itemId = nil,
			itemLink = itemLink,
			rollType = rollType,
		}
	local eligibility =
		Responses.BuildCandidateEligibility(ctx, playerName, context.itemId, context.itemLink, context.rollType)
	local response = state.responsesByPlayer[playerName]
	local reason

	if not playerName or playerName == "" then
		return buildWinnerValidationResult(false, reasonCodes.NAME_UNRESOLVED, playerName, eligibility, response)
	end

	if ctx.getRollSession and ctx.getRollSession() then
		Responses.PrepareResponseState(ctx, context, {
			seedTieReroll = true,
		})
		response = select(
			1,
			Responses.SyncResponseEligibility(
				ctx,
				playerName,
				context.itemId,
				context.itemLink,
				context.rollType,
				"award_validation"
			)
		)
	end

	if not isAwardRollType(context.rollType) then
		if eligibility.ok == true then
			return buildWinnerValidationResult(true, nil, playerName, eligibility, response)
		end
		return buildWinnerValidationResult(
			false,
			eligibility.reason or reasonCodes.INELIGIBLE,
			playerName,
			eligibility,
			response
		)
	end

	reason = getAwardValidationResponseReason(response, eligibility)
	if reason then
		return buildWinnerValidationResult(false, reason, playerName, eligibility, response)
	end
	return buildWinnerValidationResult(true, nil, playerName, eligibility, response)
end
