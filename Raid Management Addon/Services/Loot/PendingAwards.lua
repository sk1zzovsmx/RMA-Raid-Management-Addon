-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: direct addon namespace bindings
-- exports: addon.Services.Loot.PendingAwards
-- events: no bus events; pending-award helpers only
-- notes: pending-award helpers for loot service

local addon = select(2, ...)
local Diag = addon.Diag
local C = addon.C
local Database = addon.Database
local Item = addon.Item
local Options = addon.Options
local Services = addon.Services
local Strings = addon.Strings
local _, lootState = Database.EnsureLootRuntimeState()

-- ----- Internal state ----- --
addon.Services.EnsureNamespace("Loot")
local Loot = Services.Loot
local module = Loot
module.PendingAwards = module.PendingAwards or {}

local PendingAwards = module.PendingAwards

local tremove = table.remove
local strlower = string.lower
local strsub = string.sub
local tostring, tonumber = tostring, tonumber
local type = type

local PENDING_AWARD_TTL_SECONDS = tonumber(C.PENDING_AWARD_TTL_SECONDS) or 8
local PROVISIONAL_RETENTION_SECONDS = 30
local MAX_PROVISIONAL_AWARDS = 128
local GROUP_LOOT_SESSION_PREFIX = "GL:"

-- ----- Private helpers ----- --
local isDebugEnabled = Options.IsDebugEnabled

local function normalizePendingAwardItemKey(itemLink)
	local itemKey = Item.GetItemStringFromLink(itemLink)
	if itemKey and itemKey ~= "" then
		return itemKey
	end
	return itemLink
end

local function buildPendingAwardKey(itemLink, looter, useRawItemLink)
	local itemKey = useRawItemLink and itemLink or normalizePendingAwardItemKey(itemLink)
	local normalizedLooter = Strings and Strings.NormalizeName and Strings.NormalizeName(looter, true) or looter
	local canonicalLooter = strlower(tostring(normalizedLooter or "")):match("^([^%-]+)") or ""
	return tostring(itemKey) .. "\001" .. canonicalLooter
end

local function getPendingAwardList(itemLink, looter)
	local key = buildPendingAwardKey(itemLink, looter)
	local list = lootState.pendingAwards[key]
	if list then
		return key, list
	end

	local rawLinkKey = buildPendingAwardKey(itemLink, looter, true)
	if rawLinkKey == key then
		return key, nil
	end

	list = lootState.pendingAwards[rawLinkKey]
	if list then
		lootState.pendingAwards[key] = list
		lootState.pendingAwards[rawLinkKey] = nil
	end

	return key, list
end

local function ensurePendingAwardList(itemLink, looter)
	local key, list = getPendingAwardList(itemLink, looter)
	if not list then
		list = {}
		lootState.pendingAwards[key] = list
	end
	return key, list
end

local function normalizePendingAwardTtl(maxAge)
	local ttl = tonumber(maxAge) or PENDING_AWARD_TTL_SECONDS
	if ttl < 0 then
		ttl = 0
	end
	return ttl
end

local function isPendingAwardValid(pending, now, ttl)
	local expiresAt = tonumber(pending and pending.expiresAt) or nil
	return pending and ((expiresAt and now <= expiresAt) or (not expiresAt and (now - (pending.ts or 0)) <= ttl))
end

local function isPendingAwardExpired(pending, now, ttl)
	local expiresAt = tonumber(pending and pending.expiresAt) or nil
	return not pending or ((expiresAt and now > expiresAt) or (not expiresAt and (now - (pending.ts or 0)) > ttl))
end

local function hasResolvedPendingAwardValue(pending)
	return (tonumber(pending and pending.rollValue) or 0) > 0
end

local function isGroupLootSessionId(sessionId)
	return type(sessionId) == "string" and strsub(sessionId, 1, #GROUP_LOOT_SESSION_PREFIX) == GROUP_LOOT_SESSION_PREFIX
end

local function shouldConsiderPendingForMode(pending, allowGroupLootPendingAwards)
	if allowGroupLootPendingAwards ~= false then
		return true
	end
	local sessionId = pending and pending.rollSessionId and tostring(pending.rollSessionId) or nil
	return not isGroupLootSessionId(sessionId)
end

local function consumePendingAwardAt(list, key, index, itemLink, looter, ttl)
	local pending = list[index]
	tremove(list, index)
	local remaining = #list
	if #list == 0 then
		lootState.pendingAwards[key] = nil
	end
	if isDebugEnabled() then
		addon:debug(Diag.D.LogLootPendingAwardConsumed:format(tostring(itemLink), tostring(looter), remaining, ttl))
	end
	return pending
end

local function pruneExpiredPendingAwards(list, now, ttl)
	if type(list) ~= "table" then
		return
	end
	for i = #list, 1, -1 do
		local pending = list[i]
		if isPendingAwardExpired(pending, now, ttl) then
			tremove(list, i)
		end
	end
end

local function findPendingAwardIndex(list, now, ttl, matcher)
	for i = 1, #list do
		local pending = list[i]
		if isPendingAwardValid(pending, now, ttl) and (not matcher or matcher(pending)) then
			return i
		end
	end
	return nil
end

local function findUniqueValidPendingAwardIndex(list, now, ttl)
	local uniqueIndex = nil
	for i = 1, #list do
		local pending = list[i]
		if isPendingAwardValid(pending, now, ttl) then
			if uniqueIndex then
				return nil
			end
			uniqueIndex = i
		end
	end
	return uniqueIndex
end

local function tryUpgradePendingAward(list, rollType, rollValue, rollSessionId, expiresAt, now, counterApplied)
	if not (rollValue and rollValue > 0) then
		return false
	end

	for pass = 1, 2 do
		for i = 1, #list do
			local pending = list[i]
			local pendingType = tonumber(pending and pending.rollType)
			local pendingValue = tonumber(pending and pending.rollValue) or 0
			local pendingSessionId = pending and pending.rollSessionId and tostring(pending.rollSessionId) or nil
			local sameType = pending and pendingType == rollType and pendingValue <= 0
			local sessionMatches = (pass == 1 and rollSessionId and pendingSessionId == rollSessionId)
				or (pass == 2 and ((not rollSessionId) or pendingSessionId == nil or pendingSessionId == ""))

			if sameType and sessionMatches then
				pending.rollValue = rollValue
				pending.ts = now
				if rollSessionId and not pendingSessionId then
					pending.rollSessionId = rollSessionId
				end
				if expiresAt and ((tonumber(pending.expiresAt) or 0) < expiresAt) then
					pending.expiresAt = expiresAt
				end
				if counterApplied == true then
					pending.counterApplied = true
				end
				return true
			end
		end
	end

	return false
end

local function touchPendingAward(pending, now, rollSessionId, expiresAt)
	if not pending then
		return nil
	end

	pending.ts = now
	if rollSessionId and (not pending.rollSessionId or pending.rollSessionId == "") then
		pending.rollSessionId = rollSessionId
	end
	if expiresAt and ((tonumber(pending.expiresAt) or 0) < expiresAt) then
		pending.expiresAt = expiresAt
	end
	return pending
end

-- ----- Public methods ----- --
PendingAwards.NormalizePendingAwardItemKey = normalizePendingAwardItemKey

function PendingAwards.IsMasterLootAwardFailureMessage(message)
	local raw = tostring(message or "")
	local text = strlower(raw)
	if text == "" then
		return false
	end

	local known = {
		_G.ERR_INV_FULL,
		_G.ERR_ITEM_MAX_COUNT,
		_G.ERR_LOOT_LOCKED,
		_G.ERR_LOOT_GONE,
	}
	for i = 1, #known do
		local value = known[i]
		if value and value ~= "" and raw == tostring(value) then
			return true
		end
	end

	return text:find("inventory is full", 1, true) ~= nil
		or text:find("bags are full", 1, true) ~= nil
		or text:find("can't carry", 1, true) ~= nil
		or text:find("cannot carry", 1, true) ~= nil
		or text:find("loot is gone", 1, true) ~= nil
		or text:find("loot locked", 1, true) ~= nil
		or text:find("item is locked", 1, true) ~= nil
		or text:find("player not found", 1, true) ~= nil
end

function PendingAwards.Add(itemLink, looter, rollType, rollValue, rollSessionId, expiresAt, options)
	if not itemLink or not looter then
		return
	end

	local _, list = ensurePendingAwardList(itemLink, looter)
	local now = GetTime()
	local resolvedRollType = tonumber(rollType)
	local resolvedRollValue = tonumber(rollValue)
	local resolvedSessionId = rollSessionId and tostring(rollSessionId) or nil
	local resolvedExpiresAt = tonumber(expiresAt) or nil
	local counterApplied = type(options) == "table" and options.counterApplied == true or false
	local transactionId = type(options) == "table" and options.transactionId or nil

	if
		tryUpgradePendingAward(
			list,
			resolvedRollType,
			resolvedRollValue,
			resolvedSessionId,
			resolvedExpiresAt,
			now,
			counterApplied
		)
	then
		return
	end

	list[#list + 1] = {
		itemLink = itemLink,
		looter = looter,
		rollType = resolvedRollType or rollType,
		rollValue = resolvedRollValue or rollValue,
		rollSessionId = resolvedSessionId,
		expiresAt = resolvedExpiresAt,
		counterApplied = counterApplied,
		transactionId = transactionId and tostring(transactionId) or nil,
		ts = now,
	}
end

local function canonicalWinner(looter)
	local normalized = Strings and Strings.NormalizeName and Strings.NormalizeName(looter, true) or looter
	return strlower(tostring(normalized or "")):match("^([^%-]+)") or ""
end

local function ensureProvisionalStore()
	local store = lootState.provisionalAwards
	if type(store) ~= "table" then
		store = { entries = {} }
		lootState.provisionalAwards = store
	end
	store.entries = type(store.entries) == "table" and store.entries or {}
	return store
end

local function pruneProvisionalAwards(now)
	local entries = ensureProvisionalStore().entries
	for i = #entries, 1, -1 do
		if now > (tonumber(entries[i] and entries[i].retainUntil) or 0) then
			tremove(entries, i)
		end
	end
	while #entries > MAX_PROVISIONAL_AWARDS do
		tremove(entries, 1)
	end
	return entries
end

local function findPendingForConfirmation(itemLink, looter, rollSessionId, transactionId)
	local resolvedTransactionId = transactionId and tostring(transactionId) or nil
	if resolvedTransactionId and resolvedTransactionId ~= "" then
		for _, list in pairs(lootState.pendingAwards) do
			if type(list) == "table" then
				for i = 1, #list do
					local pending = list[i]
					if pending and tostring(pending.transactionId or "") == resolvedTransactionId then
						return pending
					end
				end
			end
		end
	end

	local _, list = getPendingAwardList(itemLink, looter)
	if not list then
		return nil
	end
	local resolvedSessionId = rollSessionId and tostring(rollSessionId) or nil
	if not resolvedSessionId or resolvedSessionId == "" then
		return nil
	end
	for i = 1, #list do
		local pending = list[i]
		if
			pending
			and pending.itemLink == itemLink
			and canonicalWinner(pending.looter) == canonicalWinner(looter)
			and tostring(pending.rollSessionId or "") == resolvedSessionId
		then
			return pending
		end
	end
	return nil
end

local function findProvisional(itemLink, looter, rollSessionId, transactionId)
	local entries = pruneProvisionalAwards(GetTime())
	local resolvedTransactionId = transactionId and tostring(transactionId) or nil
	if resolvedTransactionId and resolvedTransactionId ~= "" then
		for i = 1, #entries do
			if tostring(entries[i].transactionId or "") == resolvedTransactionId then
				return entries[i]
			end
		end
	end
	local resolvedSessionId = rollSessionId and tostring(rollSessionId) or nil
	if not resolvedSessionId or resolvedSessionId == "" then
		return nil
	end
	local itemKey = normalizePendingAwardItemKey(itemLink)
	local winnerKey = canonicalWinner(looter)
	for i = 1, #entries do
		local entry = entries[i]
		if
			entry.itemKey == itemKey
			and entry.itemLink == itemLink
			and entry.winnerKey == winnerKey
			and tostring(entry.rollSessionId or "") == resolvedSessionId
		then
			return entry
		end
	end
	return nil
end

function PendingAwards.ConfirmProvisional(
	itemLink,
	looter,
	rollSessionId,
	clearedSlot,
	transactionId,
	graceSeconds,
	scheduleTimer,
	cancelTimer,
	onFinalize
)
	local pending = findPendingForConfirmation(itemLink, looter, rollSessionId, transactionId)
	if not pending then
		return nil
	end
	local existing = findProvisional(itemLink, looter, rollSessionId, transactionId)
	if existing then
		return existing
	end
	local now = GetTime()
	local provisional = {
		transactionId = transactionId and tostring(transactionId) or pending.transactionId,
		rollSessionId = pending.rollSessionId,
		itemKey = normalizePendingAwardItemKey(pending.itemLink),
		itemLink = pending.itemLink,
		looter = pending.looter,
		winnerKey = canonicalWinner(pending.looter),
		rollType = pending.rollType,
		rollValue = pending.rollValue,
		clearedSlot = tonumber(clearedSlot) or clearedSlot,
		slotConfirmed = true,
		finalized = false,
		reconciled = false,
		createdAt = now,
		retainUntil = now + PROVISIONAL_RETENTION_SECONDS,
		onFinalize = onFinalize,
	}
	local entries = pruneProvisionalAwards(now)
	entries[#entries + 1] = provisional
	pruneProvisionalAwards(now)
	if type(scheduleTimer) ~= "function" then
		return provisional
	end
	local delay = tonumber(graceSeconds) or 0
	if delay < 0 then
		delay = 0
	end
	provisional.graceHandle = scheduleTimer(function()
		provisional.graceHandle = nil
		if provisional.finalized then
			return
		end
		provisional.finalized = true
		provisional.finalizedSource = "LOOT_SLOT_CLEARED"
		if type(provisional.onFinalize) == "function" then
			provisional.recordIndex = provisional.onFinalize(provisional)
		end
	end, delay)
	return provisional
end

function PendingAwards.ReconcileProvisional(itemLink, looter, rollSessionId, transactionId, cancelTimer, onReconcile)
	local pending = findProvisional(itemLink, looter, rollSessionId, transactionId)
	if not (pending and pending.slotConfirmed) then
		return nil
	end
	if pending.graceHandle and type(cancelTimer) == "function" then
		cancelTimer(pending.graceHandle)
		pending.graceHandle = nil
	end
	if not pending.finalized then
		pending.finalized = true
		pending.finalizedSource = "CHAT_MSG_LOOT"
		if type(pending.onFinalize) == "function" then
			pending.recordIndex = pending.onFinalize(pending)
		end
	end
	pending.reconciled = true
	pending.finalizedSource = "CHAT_MSG_LOOT"
	pending.retainUntil = GetTime() + PROVISIONAL_RETENTION_SECONDS
	if type(onReconcile) == "function" then
		onReconcile(pending)
	end
	return pending
end

function PendingAwards.Remove(itemLink, looter, maxAge, rollSessionId, preferResolvedValue, allowGroupLootPendingAwards)
	local ttl = normalizePendingAwardTtl(maxAge)
	local key, list = getPendingAwardList(itemLink, looter)
	if not list then
		return nil
	end

	local now = GetTime()
	local preferredSessionId = rollSessionId and tostring(rollSessionId) or nil
	if preferredSessionId and preferredSessionId ~= "" then
		local sessionIndex = findPendingAwardIndex(list, now, ttl, function(pending)
			return shouldConsiderPendingForMode(pending, allowGroupLootPendingAwards)
				and tostring(pending.rollSessionId or "") == preferredSessionId
		end)
		if sessionIndex then
			return consumePendingAwardAt(list, key, sessionIndex, itemLink, looter, ttl)
		end
	end

	if preferResolvedValue then
		local resolvedIndex = findPendingAwardIndex(list, now, ttl, function(pending)
			return shouldConsiderPendingForMode(pending, allowGroupLootPendingAwards)
				and hasResolvedPendingAwardValue(pending)
		end)
		if resolvedIndex then
			return consumePendingAwardAt(list, key, resolvedIndex, itemLink, looter, ttl)
		end
	end

	local firstValidIndex = findPendingAwardIndex(list, now, ttl, function(pending)
		return shouldConsiderPendingForMode(pending, allowGroupLootPendingAwards)
	end)
	if firstValidIndex then
		return consumePendingAwardAt(list, key, firstValidIndex, itemLink, looter, ttl)
	end

	pruneExpiredPendingAwards(list, now, ttl)
	if #list == 0 then
		lootState.pendingAwards[key] = nil
	end
	return nil
end

function PendingAwards.Refresh(itemLink, looter, maxAge, rollSessionId, expiresAt)
	local ttl = normalizePendingAwardTtl(maxAge)
	local key, list = getPendingAwardList(itemLink, looter)
	if not list then
		return nil
	end

	local now = GetTime()
	local resolvedSessionId = rollSessionId and tostring(rollSessionId) or nil
	local resolvedExpiresAt = tonumber(expiresAt) or nil
	local touched

	if resolvedSessionId and resolvedSessionId ~= "" then
		local sessionIndex = findPendingAwardIndex(list, now, ttl, function(pending)
			return tostring(pending.rollSessionId or "") == resolvedSessionId
		end)
		if sessionIndex then
			touched = list[sessionIndex]
		end
	end

	if not touched then
		local uniqueIndex = findUniqueValidPendingAwardIndex(list, now, ttl)
		if uniqueIndex then
			touched = list[uniqueIndex]
		end
	end

	pruneExpiredPendingAwards(list, now, ttl)
	if #list == 0 then
		lootState.pendingAwards[key] = nil
	end

	if not touched then
		return nil
	end

	return touchPendingAward(touched, now, resolvedSessionId, resolvedExpiresAt)
end

function PendingAwards.Purge(maxAge)
	local ttl = normalizePendingAwardTtl(maxAge)
	local now = GetTime()
	for key, list in pairs(lootState.pendingAwards) do
		if type(list) ~= "table" then
			lootState.pendingAwards[key] = nil
		else
			pruneExpiredPendingAwards(list, now, ttl)
			if #list == 0 then
				lootState.pendingAwards[key] = nil
			end
		end
	end
	pruneProvisionalAwards(now)
end
