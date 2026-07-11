-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: direct addon namespace bindings
-- exports: addon.Services.Master.Trade
-- events: none
-- notes: pure Master manual-trade matching and manual-accept confirmation flow
local addon = select(2, ...)
local Master = addon.Database.EnsureServiceNamespace("Master")
local Services = addon.Services

local Trade = Master.Trade or {}
Master.Trade = Trade

local Database = addon.Database
local L = addon.L
local Diag = addon.Diag
local LoggerActions = assert(Services.Logger.Actions, "Master trade logger actions service is not initialized")

local type = type
local tonumber = tonumber
local tostring = tostring
local tinsert = table.insert
local strlower = string.lower

local rollTypes = addon.C.rollTypes
local HOLD = rollTypes.HOLD
local MS = rollTypes.MAINSPEC
local OS = rollTypes.OFFSPEC
local SR = rollTypes.RESERVED
local FREE = rollTypes.FREE

local REASON_ORDER = { MS, OS, SR, FREE }
local REASON_LABELS = {}
REASON_LABELS[MS] = L.BtnMS
REASON_LABELS[OS] = L.BtnOS
REASON_LABELS[SR] = L.BtnSR
REASON_LABELS[FREE] = L.BtnFree
REASON_LABELS["MS"] = L.BtnMS
REASON_LABELS["OS"] = L.BtnOS
REASON_LABELS["SR"] = L.BtnSR
REASON_LABELS["Free"] = L.BtnFree

-- ----- Internal state ----- --

-- ----- Private helpers ----- --

local function ensureRaidStore(raidNum)
	if not raidNum then
		return nil
	end
	return Database.EnsureRaidByIndex(raidNum)
end

local function normalizeName(name)
	if type(name) ~= "string" then
		return nil
	end
	return name:gsub("%s*%-[^%-]+$", "")
end

local function isValidReason(reason)
	local reasonType = type(reason)
	if reasonType == "number" then
		for i = 1, #REASON_ORDER do
			if REASON_ORDER[i] == reason then
				return reason
			end
		end
		return nil
	end
	if reasonType == "string" then
		for i = 1, #REASON_ORDER do
			local known = REASON_ORDER[i]
			if reason == REASON_LABELS[known] then
				return known
			end
		end
	end
	return nil
end

local function ensureState()
	local _, lootState = Database.EnsureLootRuntimeState()
	local featureManualTrade = lootState.manualTrade or {}
	lootState.manualTrade = featureManualTrade
	featureManualTrade.active = featureManualTrade.active == true
	featureManualTrade.partnerName = featureManualTrade.partnerName or nil
	featureManualTrade.partnerNameRaw = featureManualTrade.partnerNameRaw
	featureManualTrade.raidId = featureManualTrade.raidId
	featureManualTrade.candidatesBySlot = featureManualTrade.candidatesBySlot or {}
	featureManualTrade.candidates = featureManualTrade.candidates or {}
	featureManualTrade.candidatesByLootNid = featureManualTrade.candidatesByLootNid or {}
	featureManualTrade.selectedReasonByLootNid = featureManualTrade.selectedReasonByLootNid or {}
	featureManualTrade.loggedLootNids = featureManualTrade.loggedLootNids or {}
	featureManualTrade.acceptProcessed = featureManualTrade.acceptProcessed == true
	featureManualTrade.pendingConfirm = featureManualTrade.pendingConfirm == true
	featureManualTrade.localAccepted = featureManualTrade.localAccepted == true
	featureManualTrade.failed = featureManualTrade.failed == true
	featureManualTrade.failureMessage = featureManualTrade.failureMessage
	return featureManualTrade
end

local function findLocalHoldRows(raidNum)
	local raid = ensureRaidStore(raidNum)
	if not raid then
		return nil
	end
	local currentPlayer = normalizeName(Database.GetPlayerName())
	local currentPlayerNid = 0
	local raidService = Services.Raid
	if currentPlayer and raidService and type(raidService.GetPlayerID) == "function" then
		currentPlayerNid = tonumber(raidService:GetPlayerID(currentPlayer, raidNum)) or 0
	end
	local rows = raid.loot
	if type(rows) ~= "table" then
		return {}
	end

	local result = {}
	for i = 1, #rows do
		local row = rows[i]
		local rowNid = tonumber(row and row.lootNid) or 0
		if rowNid > 0 and tonumber(row.rollType) == HOLD then
			local looter = normalizeName(row.looter)
			local holder = normalizeName(row.holder)
			local looterNid = tonumber(row.looterNid) or 0
			local holderNid = tonumber(row.holderNid) or 0
			if
				(currentPlayer and (looter == currentPlayer or holder == currentPlayer))
				or (currentPlayerNid > 0 and looterNid > 0 and looterNid == currentPlayerNid)
				or (currentPlayerNid > 0 and holderNid > 0 and holderNid == currentPlayerNid)
			then
				tinsert(result, row)
			end
		end
	end
	return result
end

local function debugDiagnostic(message)
	if addon.hasDebug and message then
		addon:debug(message)
	end
end

local function logCandidate(state, candidate, reason, raidId)
	local lootNid = tonumber(candidate and candidate.lootNid) or 0
	if lootNid <= 0 or state.loggedLootNids[lootNid] then
		return false
	end

	local ok = LoggerActions:RecordLoot({
		lootNid = lootNid,
		looter = state.partnerName,
		rollType = reason,
		rollValue = 0,
		source = "TRADE_MANUAL_ACCEPT",
		raidId = raidId,
	})

	if ok == true then
		state.loggedLootNids[lootNid] = true
		if addon.hasDebug then
			addon:debug(
				Diag.D.LogManualTradeLogged:format(tostring(lootNid), tostring(state.partnerName), tostring(reason))
			)
		end
		local raid = Services.Raid
		if raid and raid.AddPlayerCountForRollType then
			raid:AddPlayerCountForRollType(state.partnerName, reason, 1, raidId)
		end
		return true
	end

	if addon.hasWarn then
		addon:warn(
			Diag.E.LogTradeLoggerLogFailed:format(
				tostring(raidId),
				tostring(lootNid),
				tostring(candidate and candidate.itemLink)
			)
		)
	end
	return false
end

local function warnMissingReason(candidate)
	local slotLabel = tostring(candidate and candidate.slot or 0)
	debugDiagnostic(Diag.W.LogManualTradeMissingReason:format(slotLabel))
	addon:warn(L.WarnTradeManualReasonMissing:format(slotLabel))
end

local function isMatchingLootRow(row, itemString, itemId, usedLootNids)
	local rowNid = tonumber(row and row.lootNid) or 0
	if rowNid <= 0 or usedLootNids[rowNid] == true then
		return false
	end

	if itemString and itemString ~= "" then
		local rowItemString = row.itemString
		if rowItemString and rowItemString ~= "" then
			return rowItemString == itemString
		end
	end

	local rowItemId = tonumber(row.itemId) or 0
	return rowItemId > 0 and rowItemId == itemId
end

local function hasPlayerTradeItem(tradeItems)
	if type(tradeItems) ~= "table" then
		return false
	end
	for slot = 1, 6 do
		if tradeItems[slot] ~= nil then
			return true
		end
	end
	return false
end

local function shouldKeepAcceptedState(state, source, hasTradeItem)
	if hasTradeItem then
		return false
	end
	if source ~= "TRADE_PLAYER_ITEM_CHANGED" and source ~= "TRADE_TARGET_ITEM_CHANGED" then
		return false
	end
	return state.pendingConfirm == true or state.acceptProcessed == true or state.localAccepted == true
end

local function matchesKnownMessage(raw, messages)
	for i = 1, #messages do
		local message = messages[i]
		if message and message ~= "" and raw == tostring(message) then
			return true
		end
	end
	return false
end

local function isManualTradeFailureMessage(message)
	local raw = tostring(message or "")
	if raw == "" then
		return false
	end

	if
		matchesKnownMessage(raw, {
			_G.ERR_INV_FULL,
			_G.ERR_ITEM_MAX_COUNT,
			_G.ERR_TRADE_BAG_FULL,
			_G.ERR_TRADE_TARGET_BAG_FULL,
			_G.ERR_TRADE_MAX_COUNT_EXCEEDED,
			_G.ERR_TRADE_TARGET_MAX_COUNT_EXCEEDED,
			_G.ERR_TRADE_CANCELLED,
		})
	then
		return true
	end

	local text = strlower(raw)
	return text:find("trade failed", 1, true) ~= nil
		or text:find("trade cancelled", 1, true) ~= nil
		or text:find("inventory is full", 1, true) ~= nil
		or text:find("bags are full", 1, true) ~= nil
		or text:find("doesn't have enough space", 1, true) ~= nil
		or text:find("do not have enough space", 1, true) ~= nil
		or text:find("too many of a unique item", 1, true) ~= nil
		or text:find("trade partner has too many", 1, true) ~= nil
end

-- ----- Public methods ----- --

function Trade.GetReasonOrder()
	return REASON_ORDER
end

function Trade.EnsureState()
	return ensureState()
end

function Trade.IsFailureMessage(message)
	return isManualTradeFailureMessage(message)
end

function Trade.Reset(hideDropdowns, keepAcceptProcessed)
	local state = ensureState()
	if keepAcceptProcessed == true and state.pendingConfirm == true then
		state.active = false
		if hideDropdowns == true then
			state.hidden = true
		end
		return state
	end
	state.active = false
	state.partnerName = nil
	state.partnerNameRaw = nil
	state.raidId = nil
	state.candidatesBySlot = {}
	state.candidates = {}
	state.candidatesByLootNid = {}
	state.loggedLootNids = {}
	state.pendingConfirm = false
	state.localAccepted = false
	state.failed = false
	state.failureMessage = nil
	if keepAcceptProcessed ~= true then
		state.acceptProcessed = false
		state.selectedReasonByLootNid = {}
	end
	if hideDropdowns == true then
		state.hidden = true
	end
	return state
end

function Trade.SetSelectedReason(lootNid, reason)
	local state = ensureState()
	local normalizedReason = isValidReason(reason)
	local key = tonumber(lootNid) or 0
	if key <= 0 or not normalizedReason then
		if key > 0 then
			state.selectedReasonByLootNid[key] = nil
		end
		return false
	end
	state.selectedReasonByLootNid[key] = normalizedReason
	return true
end

function Trade.RefreshCandidate(opts)
	local state = ensureState()
	local tradeItems = opts and opts.tradeItems
	local hasTradeItem = hasPlayerTradeItem(tradeItems)
	if shouldKeepAcceptedState(state, opts and opts.source, hasTradeItem) then
		return state
	end

	state.active = false
	state.partnerName = nil
	state.partnerNameRaw = nil
	state.raidId = Database.GetCurrentRaid()
	state.candidatesBySlot = {}
	state.candidates = {}
	state.candidatesByLootNid = {}
	state.acceptProcessed = false
	state.pendingConfirm = false
	state.localAccepted = false
	state.failed = false
	state.failureMessage = nil

	if not state.raidId then
		debugDiagnostic(Diag.W.LogManualTradeNoCurrentRaid)
		return state
	end

	local partnerName = normalizeName(opts and opts.partnerName)
	if not partnerName or partnerName == "" then
		debugDiagnostic(Diag.W.LogManualTradeNoPartner:format("TRADE"))
		return state
	end
	state.partnerName = partnerName
	state.partnerNameRaw = opts and opts.partnerName

	if not hasTradeItem then
		debugDiagnostic(Diag.W.LogManualTradeNoTradeItems)
		return state
	end

	local rows = findLocalHoldRows(state.raidId) or {}
	if #rows == 0 then
		debugDiagnostic(Diag.W.LogManualTradeNoLocalHold)
		return state
	end

	local usedLootNids = {}
	local matchedAny = false
	for slot = 1, 6 do
		local item = tradeItems[slot]
		if item and (item.itemString or item.itemId) then
			local candidate
			for i = #rows, 1, -1 do
				local row = rows[i]
				if isMatchingLootRow(row, item.itemString, tonumber(item.itemId) or 0, usedLootNids) then
					candidate = row
					usedLootNids[tonumber(row.lootNid) or 0] = true
					break
				end
			end
			if candidate then
				local lootNid = tonumber(candidate.lootNid) or 0
				local c = {
					slot = slot,
					itemLink = item.itemLink,
					itemString = item.itemString,
					itemId = item.itemId,
					lootNid = lootNid,
					reason = state.selectedReasonByLootNid[lootNid],
				}
				state.candidatesBySlot[slot] = c
				state.candidates[#state.candidates + 1] = c
				state.candidatesByLootNid[lootNid] = c
				state.active = true
				matchedAny = true
			end
		end
	end

	if matchedAny then
		state.candidateLootNid = state.candidates[1] and state.candidates[1].lootNid
		if addon.hasDebug then
			addon:debug(
				Diag.D.LogManualTradeCandidateFound:format(
					tostring(partnerName),
					tostring(#state.candidates),
					tostring(state.candidateLootNid)
				)
			)
		end
		return state
	end

	debugDiagnostic(Diag.W.LogManualTradeNoMatch:format(tostring(partnerName), tostring(state.raidId)))
	return state
end

function Trade.ApplyAccept(playerAccepted, targetAccepted, isAddonDriven)
	local state = ensureState()
	if isAddonDriven == true then
		return false
	end
	if state.active ~= true and state.pendingConfirm ~= true then
		return false
	end

	state.localAccepted = playerAccepted == 1
	if state.active ~= true then
		return false, state
	end
	if playerAccepted ~= 1 or targetAccepted ~= 1 then
		return false, state
	end

	if state.acceptProcessed == true then
		return true, state
	end

	if not state.partnerName or state.partnerName == "" then
		return false, state
	end

	local raidId = tonumber(Database.GetCurrentRaid())
	if not raidId then
		return false, state
	end

	local candidates = state.candidates
	if type(candidates) ~= "table" or #candidates <= 0 then
		return false, state
	end

	local hasPendingCandidate = false
	for i = 1, #candidates do
		local candidate = candidates[i]
		if type(candidate) == "table" then
			local lootNid = tonumber(candidate.lootNid) or 0
			local reason = candidate.reason or state.selectedReasonByLootNid[lootNid]
			candidate.reason = reason
			candidate.missingReason = not reason
			if not state.loggedLootNids[lootNid] then
				hasPendingCandidate = true
			end
		end
	end

	if hasPendingCandidate then
		state.acceptProcessed = true
		state.active = false
		state.pendingConfirm = true
		state.failed = false
		state.failureMessage = nil
		state.raidId = raidId
	end
	return hasPendingCandidate, state
end

function Trade.HasClosePending()
	local state = ensureState()
	if state.failed == true then
		return false
	end
	if state.pendingConfirm == true then
		return true
	end
	return state.active == true and state.localAccepted == true
end

function Trade.MarkFailure(message)
	local state = ensureState()
	if not Trade.IsFailureMessage(message) then
		return false, state
	end
	if state.pendingConfirm ~= true and state.acceptProcessed ~= true and state.localAccepted ~= true then
		return false, state
	end

	state.failed = true
	state.failureMessage = message
	state.active = false
	state.pendingConfirm = false
	return true, state
end

function Trade.CancelClose(message)
	local failed = Trade.MarkFailure(message)
	if failed then
		Trade.Reset(true, false)
	end
	return failed
end

function Trade.SettleClose()
	local settled = Trade.PromoteAcceptedToPendingOnClose()
	Trade.Reset(true, true)
	return settled
end

function Trade.PromoteAcceptedToPendingOnClose()
	local state = ensureState()
	if state.failed == true then
		return false, state
	end
	if state.pendingConfirm == true then
		return Trade.CompletePending(), state
	end
	if state.active ~= true then
		return false, state
	end
	if state.localAccepted ~= true then
		return false, state
	end

	local candidates = state.candidates
	local hasPendingCandidate = false
	if type(candidates) ~= "table" then
		return false, state
	end
	for i = 1, #candidates do
		local candidate = candidates[i]
		if type(candidate) == "table" then
			local lootNid = tonumber(candidate.lootNid) or 0
			if not state.loggedLootNids[lootNid] then
				hasPendingCandidate = true
				break
			end
		end
	end

	if not hasPendingCandidate then
		return false, state
	end

	state.pendingConfirm = true
	state.raidId = state.raidId or Database.GetCurrentRaid()
	return Trade.CompletePending(), state
end

function Trade.CompletePending()
	local state = ensureState()
	if state.pendingConfirm ~= true then
		return false
	end
	if state.failed == true then
		state.pendingConfirm = false
		return false
	end

	local raidId = tonumber(state.raidId) or tonumber(Database.GetCurrentRaid())
	if not raidId then
		state.pendingConfirm = false
		return false
	end

	local candidates = state.candidates
	if type(candidates) ~= "table" or #candidates <= 0 then
		state.pendingConfirm = false
		return false
	end

	state.pendingConfirm = false
	local loggedAny = false

	for i = 1, #candidates do
		local candidate = candidates[i]
		if type(candidate) == "table" then
			local lootNid = tonumber(candidate.lootNid) or 0
			local reason = candidate.reason or state.selectedReasonByLootNid[lootNid]
			if reason then
				if logCandidate(state, candidate, reason, raidId) then
					loggedAny = true
				end
			end
		end
	end

	for i = 1, #candidates do
		local candidate = candidates[i]
		if type(candidate) == "table" then
			local lootNid = tonumber(candidate.lootNid) or 0
			local reason = candidate.reason or state.selectedReasonByLootNid[lootNid]
			if not reason then
				warnMissingReason(candidate)
			end
		end
	end

	return loggedAny
end

return Trade
