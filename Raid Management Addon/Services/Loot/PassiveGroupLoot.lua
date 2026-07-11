-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: direct addon namespace bindings
-- exports: addon.Services.Loot._PassiveGroupLoot
-- events: no bus events; passive group-loot helpers only
-- notes: passive group-loot parser/state helpers for loot service

local addon = select(2, ...)
local Diag = addon.Diag
local C = addon.C
local Database = addon.Database
local Deformat = addon.Deformat
local Item = addon.Item
local Options = addon.Options
local Services = addon.Services
local Strings = addon.Strings
local _, lootState, _, raidState = Database.EnsureLootRuntimeState()
local ITEM_LINK_PATTERN = addon.C.ITEM_LINK_PATTERN
local rollTypes = addon.C.rollTypes

-- ----- Internal state ----- --
addon.Services.EnsureNamespace("Loot")
local Loot = Services.Loot
local module = Loot
module._PassiveGroupLoot = module._PassiveGroupLoot or {}

local PassiveGroupLoot = module._PassiveGroupLoot

local tremove = table.remove
local strmatch = string.match
local strlen = string.len
local tonumber, tostring = tonumber, tostring
local type, pairs, select, next = type, pairs, select, next
local _G = _G
local GetLootRollItemInfo = assert(_G.GetLootRollItemInfo, "Passive group-loot roll item info API is not initialized")
local GetLootRollItemLink = assert(_G.GetLootRollItemLink, "Passive group-loot roll item link API is not initialized")
local GetItemStringFromLink =
	assert(Item.GetItemStringFromLink, "Passive group-loot item-key resolver is not initialized")
local Raid = assert(Services.Raid, "Passive group-loot raid service is not initialized")
local IsPassiveGroupLootMethod =
	assert(Raid.IsPassiveGroupLootMethod, "Passive group-loot method policy resolver is not initialized")

local GROUP_LOOT_PENDING_AWARD_TTL_SECONDS = tonumber(C.GROUP_LOOT_PENDING_AWARD_TTL_SECONDS) or 60
local GROUP_LOOT_ROLL_GRACE_SECONDS = tonumber(C.GROUP_LOOT_ROLL_GRACE_SECONDS) or 10

local buildParsedGroupLootResult
local rememberParsedGroupLootResult

-- ----- Private helpers ----- --
local isDebugEnabled = Options.IsDebugEnabled

local function getPassiveLootRollState()
	raidState.passiveLootRolls = raidState.passiveLootRolls or {}
	local state = raidState.passiveLootRolls
	state.byItemKey = state.byItemKey or {}
	state.bySessionId = state.bySessionId or {}
	state.byRollId = state.byRollId or {}
	state.nextSessionId = tonumber(state.nextSessionId) or 1
	if state.nextSessionId < 1 then
		state.nextSessionId = 1
	end
	return state
end

local function removePassiveLootRollEntry(state, entry)
	if type(state) ~= "table" or type(entry) ~= "table" then
		return
	end

	if entry.sessionId then
		state.bySessionId[entry.sessionId] = nil
	end
	if entry.rollId then
		state.byRollId[entry.rollId] = nil
	end

	local itemKey = entry.itemKey
	local list = itemKey and state.byItemKey[itemKey] or nil
	if type(list) ~= "table" then
		return
	end

	for i = #list, 1, -1 do
		local candidate = list[i]
		if candidate == entry or (candidate and candidate.sessionId == entry.sessionId) then
			tremove(list, i)
		end
	end

	if #list == 0 then
		state.byItemKey[itemKey] = nil
	end
end

local function purgeExpiredPassiveLootRolls(now)
	local state = getPassiveLootRollState()
	local currentTime = tonumber(now) or GetTime()

	for itemKey, list in pairs(state.byItemKey) do
		if type(list) ~= "table" then
			state.byItemKey[itemKey] = nil
		else
			for i = #list, 1, -1 do
				local entry = list[i]
				local expiresAt = tonumber(entry and entry.expiresAt) or 0
				if not entry or expiresAt <= currentTime then
					removePassiveLootRollEntry(state, entry)
				end
			end
		end
	end
end

local function purgePassiveLootRollEntry(state, entry, currentTime)
	local resolvedState = state or getPassiveLootRollState()
	local resolvedNow = tonumber(currentTime) or GetTime()
	if type(entry) ~= "table" then
		return false
	end

	local expiresAt = tonumber(entry.expiresAt) or 0
	if expiresAt <= resolvedNow then
		removePassiveLootRollEntry(resolvedState, entry)
		return true
	end

	return false
end

local function getActivePassiveLootRollByItemKey(itemKey)
	local state = getPassiveLootRollState()
	local list = state.byItemKey[itemKey]
	if type(list) ~= "table" then
		return nil
	end

	local currentTime = GetTime()
	local activeEntry = nil

	for i = #list, 1, -1 do
		local candidate = list[i]
		local expired = purgePassiveLootRollEntry(state, candidate, currentTime)
		if not expired then
			if activeEntry ~= nil then
				return nil
			end
			activeEntry = candidate
		end
	end

	return activeEntry
end

local function getActivePassiveLootRollByRollId(rollId)
	local state = getPassiveLootRollState()
	local resolvedRollId = tonumber(rollId)
	if not resolvedRollId then
		return nil
	end

	local entry = state.byRollId[resolvedRollId]
	if not entry then
		return nil
	end

	if purgePassiveLootRollEntry(state, entry) then
		return nil
	end

	return entry
end

local function getLoggedPassiveLootState()
	raidState.loggedPassiveLoot = raidState.loggedPassiveLoot or {}
	return raidState.loggedPassiveLoot
end

local function buildLoggedPassiveLootKey(itemLink, looter)
	local itemKey = PassiveGroupLoot.GetPassiveLootRollItemKey(itemLink)
	local normalizedLooter = Strings.NormalizeName(looter, true) or looter
	return tostring(itemKey) .. "\001" .. tostring(normalizedLooter)
end

local function purgeExpiredLoggedPassiveLoot(now)
	local state = getLoggedPassiveLootState()
	local currentTime = tonumber(now) or GetTime()

	for key, list in pairs(state) do
		if type(list) ~= "table" then
			state[key] = nil
		else
			for i = #list, 1, -1 do
				local marker = list[i]
				local expiresAt = tonumber(marker and marker.expiresAt) or 0
				if not marker or expiresAt <= currentTime then
					tremove(list, i)
				end
			end

			if #list == 0 then
				state[key] = nil
			end
		end
	end
end

local function packValues(...)
	return {
		n = select("#", ...),
		...,
	}
end

local localizedDeformatCache = {}
local localizedFormatCaptures = {
	c = { pattern = "(.)", numeric = false },
	d = { pattern = "(-?%d+)", numeric = true },
	f = { pattern = "(-?%d+%.?%d*)", numeric = true },
	g = { pattern = "(-?%d+%.?%d*)", numeric = true },
	i = { pattern = "(-?%d+)", numeric = true },
	s = { pattern = "(.-)", numeric = false },
}

local function escapeLuaPatternText(text)
	return (text:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1"))
end

local function compileLocalizedDeformatPattern(pattern)
	local cached = localizedDeformatCache[pattern]
	if cached then
		return cached
	end

	local luaPattern = { "^" }
	local captures = {}
	local nextIndex = 1
	local maxIndex = 0
	local cursor = 1

	while cursor <= strlen(pattern) do
		local percentIndex = string.find(pattern, "%", cursor, true)
		if not percentIndex then
			luaPattern[#luaPattern + 1] = escapeLuaPatternText(string.sub(pattern, cursor))
			break
		end

		if percentIndex > cursor then
			luaPattern[#luaPattern + 1] = escapeLuaPatternText(string.sub(pattern, cursor, percentIndex - 1))
		end

		local marker = string.sub(pattern, percentIndex + 1, percentIndex + 1)
		if marker == "%" then
			luaPattern[#luaPattern + 1] = "%%"
			cursor = percentIndex + 2
		else
			local placeholder = string.sub(pattern, percentIndex + 1)
			local explicitIndex, explicitFlags, explicitType = strmatch(placeholder, "^(%d+)%$([%-%d%.]*)([cdfgis])")
			local flags = nil
			local formatType = explicitType
			local targetIndex = nil

			if formatType then
				targetIndex = tonumber(explicitIndex)
				cursor = percentIndex + #explicitIndex + #explicitFlags + 3
			else
				flags, formatType = strmatch(placeholder, "^([%-%d%.]*)([cdfgis])")
				if not formatType then
					luaPattern[#luaPattern + 1] = "%%"
					cursor = percentIndex + 1
				else
					targetIndex = nextIndex
					nextIndex = nextIndex + 1
					cursor = percentIndex + #flags + 2
				end
			end

			if formatType then
				local capture = localizedFormatCaptures[formatType]
				luaPattern[#luaPattern + 1] = capture.pattern
				captures[#captures + 1] = {
					targetIndex = targetIndex,
					numeric = capture.numeric,
				}
				if targetIndex > maxIndex then
					maxIndex = targetIndex
				end
			end
		end
	end

	luaPattern[#luaPattern + 1] = "$"
	cached = {
		captures = captures,
		maxIndex = maxIndex,
		matchPattern = table.concat(luaPattern),
	}
	localizedDeformatCache[pattern] = cached
	return cached
end

local function tryLocalizedDeformatValues(pattern, msg)
	local compiled = compileLocalizedDeformatPattern(pattern)
	if not compiled or compiled.maxIndex < 1 then
		return nil
	end

	local matches = packValues(strmatch(msg, compiled.matchPattern))
	if matches.n == 0 or matches[1] == nil then
		return nil
	end

	local values = { n = compiled.maxIndex }
	for i = 1, #compiled.captures do
		local capture = compiled.captures[i]
		local value = matches[i]
		if capture.numeric then
			value = tonumber(value) or value
		end
		values[capture.targetIndex] = value
	end
	return values
end

local function tryDeformatValues(pattern, msg)
	if type(pattern) ~= "string" or pattern == "" or type(msg) ~= "string" or msg == "" then
		return nil
	end

	if type(Deformat) == "function" then
		local values = packValues(Deformat(msg, pattern))
		if values.n > 0 and values[1] ~= nil then
			return values
		end
	end

	return tryLocalizedDeformatValues(pattern, msg)
end

local function normalizeLootPlayerName(name)
	return Strings.NormalizeName(name, true) or name
end

local GROUP_LOOT_RULES = {
	{
		rollType = rollTypes.NEED,
		label = "NE",
		selectionGroupPattern = LOOT_ROLL_NEED,
		selectionSelfPattern = LOOT_ROLL_NEED_SELF,
		rollPattern = LOOT_ROLL_ROLLED_NEED,
		rollSelfPattern = _G["LOOT_ROLL_ROLLED_NEED_SELF"],
		winnerPatterns = {
			{ group = LOOT_ROLL_WON_NO_SPAM_NEED, self = LOOT_ROLL_YOU_WON_NO_SPAM_NEED },
		},
	},
	{
		rollType = rollTypes.GREED,
		label = "GR",
		selectionGroupPattern = LOOT_ROLL_GREED,
		selectionSelfPattern = LOOT_ROLL_GREED_SELF,
		rollPattern = LOOT_ROLL_ROLLED_GREED,
		rollSelfPattern = _G["LOOT_ROLL_ROLLED_GREED_SELF"],
		winnerPatterns = {
			{ group = LOOT_ROLL_WON_NO_SPAM_GREED, self = LOOT_ROLL_YOU_WON_NO_SPAM_GREED },
		},
	},
	{
		rollType = rollTypes.DISENCHANT,
		label = "DE",
		selectionGroupPattern = LOOT_ROLL_DISENCHANT,
		selectionSelfPattern = LOOT_ROLL_DISENCHANT_SELF,
		rollPattern = LOOT_ROLL_ROLLED_DE,
		rollSelfPattern = _G["LOOT_ROLL_ROLLED_DE_SELF"] or _G["LOOT_ROLL_ROLLED_DISENCHANT_SELF"],
		winnerPatterns = {
			{ group = LOOT_ROLL_WON_NO_SPAM_DE, self = LOOT_ROLL_YOU_WON_NO_SPAM_DE },
			{ group = LOOT_ROLL_WON_NO_SPAM_DISENCHANT, self = LOOT_ROLL_YOU_WON_NO_SPAM_DISENCHANT },
		},
	},
}

local function getGroupLootRule(rollType)
	local resolvedRollType = tonumber(rollType)
	for i = 1, #GROUP_LOOT_RULES do
		local rule = GROUP_LOOT_RULES[i]
		if rule.rollType == resolvedRollType then
			return rule
		end
	end
	return nil
end

local function isGroupLootItemLink(value)
	if type(value) ~= "string" or value == "" then
		return false
	end

	if strmatch(value, ITEM_LINK_PATTERN) then
		return true
	end

	local itemKey = GetItemStringFromLink(value)
	if itemKey and itemKey ~= "" then
		return true
	end

	return false
end

-- Reusable buffer for numeric values extracted from loot messages (GC reduction).
local numbersBuffer = {}

local function extractGroupLootPatternValues(values)
	local playerName
	local itemLink
	local nCount = 0

	-- Reuse static buffer; wipe previous contents.
	for k in pairs(numbersBuffer) do
		numbersBuffer[k] = nil
	end

	if not values then
		return nil, nil, numbersBuffer
	end

	for i = 1, values.n do
		local value = values[i]
		local numberValue = tonumber(value)
		if numberValue ~= nil then
			nCount = nCount + 1
			numbersBuffer[nCount] = numberValue
		elseif not itemLink and isGroupLootItemLink(value) then
			itemLink = value
		elseif not playerName and type(value) == "string" and value ~= "" then
			playerName = normalizeLootPlayerName(value)
		end
	end

	return playerName, itemLink, numbersBuffer
end

local function resolveGroupLootNumericFields(numbers, singleNumberMode)
	local count = #numbers
	if count >= 2 then
		return numbers[1], numbers[count] or 0
	end
	if count == 1 then
		if singleNumberMode == "roll_id" then
			return numbers[1], 0
		end
		return nil, numbers[1] or 0
	end
	return nil, 0
end

local function parseGroupLootSelection(msg, rule)
	local values = tryDeformatValues(rule.selectionSelfPattern, msg)
	if values then
		local _, itemLink, numbers = extractGroupLootPatternValues(values)
		if itemLink then
			return Database.GetPlayerName(), itemLink, numbers[1] or nil
		end
	end

	values = tryDeformatValues(rule.selectionGroupPattern, msg)
	if values then
		local playerName, itemLink, numbers = extractGroupLootPatternValues(values)
		if playerName and itemLink then
			return playerName, itemLink, numbers[1] or nil
		end
	end

	return nil
end

local function parseGroupLootRollPattern(msg, pattern, rollType, isSelf)
	local values = tryDeformatValues(pattern, msg)
	if not values then
		return nil
	end

	local playerName, itemLink, numbers = extractGroupLootPatternValues(values)
	local rollId, rollValue = resolveGroupLootNumericFields(numbers, "roll_value")
	if not itemLink then
		return nil
	end
	if isSelf then
		playerName = Database.GetPlayerName()
	end
	if not playerName then
		return nil
	end

	return playerName, itemLink, rollType, rollValue, rollId
end

local function parseGroupLootRoll(msg)
	for i = 1, #GROUP_LOOT_RULES do
		local rule = GROUP_LOOT_RULES[i]
		local playerName, itemLink, rollType, rollValue, rollId =
			parseGroupLootRollPattern(msg, rule.rollPattern, rule.rollType, false)
		if itemLink then
			return playerName, itemLink, rollType, rollValue, rollId
		end

		playerName, itemLink, rollType, rollValue, rollId =
			parseGroupLootRollPattern(msg, rule.rollSelfPattern, rule.rollType, true)
		if itemLink then
			return playerName, itemLink, rollType, rollValue, rollId
		end
	end

	return nil
end

local function parseGroupLootWinnerPattern(msg, groupPattern, selfPattern, rollType)
	local values = tryDeformatValues(selfPattern, msg)
	if values then
		local _, itemLink, numbers = extractGroupLootPatternValues(values)
		local rollId, rollValue = resolveGroupLootNumericFields(numbers, "roll_value")
		if itemLink then
			return Database.GetPlayerName(), itemLink, rollType, rollValue, rollId
		end
	end

	values = tryDeformatValues(groupPattern, msg)
	if values then
		local playerName, itemLink, numbers = extractGroupLootPatternValues(values)
		local rollId, rollValue = resolveGroupLootNumericFields(numbers, "roll_value")
		if playerName and itemLink then
			return playerName, itemLink, rollType, rollValue, rollId
		end
	end

	return nil
end

local function parseGroupLootWinner(msg)
	for i = 1, #GROUP_LOOT_RULES do
		local rule = GROUP_LOOT_RULES[i]
		for j = 1, #rule.winnerPatterns do
			local patterns = rule.winnerPatterns[j]
			local playerName, itemLink, resolvedRollType, resolvedRollValue, resolvedRollId =
				parseGroupLootWinnerPattern(msg, patterns.group, patterns.self, rule.rollType)
			if itemLink then
				return playerName, itemLink, resolvedRollType, resolvedRollValue, resolvedRollId
			end
		end
	end

	local values = tryDeformatValues(LOOT_ROLL_YOU_WON, msg)
	if values and values.n >= 2 then
		return Database.GetPlayerName(), values[2], nil, nil, tonumber(values[1]) or nil
	end
	if values and values.n >= 1 then
		return Database.GetPlayerName(), values[1], nil, nil, nil
	end

	values = tryDeformatValues(LOOT_ROLL_WON, msg)
	if values and values.n >= 3 then
		return normalizeLootPlayerName(values[2]), values[3], nil, nil, tonumber(values[1]) or nil
	end
	if values and values.n >= 2 then
		return normalizeLootPlayerName(values[1]), values[2], nil, nil, nil
	end

	return nil
end

local lastWinnerParse = {
	msg = nil,
	parsed = false,
	playerName = nil,
	itemLink = nil,
	rollType = nil,
	rollValue = nil,
	rollId = nil,
}

local function parseGroupLootWinnerCached(msg)
	if lastWinnerParse.msg == msg then
		if lastWinnerParse.parsed then
			return lastWinnerParse.playerName,
				lastWinnerParse.itemLink,
				lastWinnerParse.rollType,
				lastWinnerParse.rollValue,
				lastWinnerParse.rollId
		end
		return nil
	end

	local playerName, itemLink, rollType, rollValue, rollId = parseGroupLootWinner(msg)
	lastWinnerParse.msg = msg
	lastWinnerParse.parsed = itemLink ~= nil
	lastWinnerParse.playerName = playerName
	lastWinnerParse.itemLink = itemLink
	lastWinnerParse.rollType = rollType
	lastWinnerParse.rollValue = rollValue
	lastWinnerParse.rollId = rollId
	return playerName, itemLink, rollType, rollValue, rollId
end

local function queuePendingPassiveAward(owner, itemLink, looter, rollType, rollValue, rollId, refreshLogged)
	local rollSessionId, expiresAt = PassiveGroupLoot.ResolvePassivePendingAwardContext(itemLink, rollId)
	local upgraded = owner:UpgradeLoggedPassiveLootRoll(itemLink, looter, rollType, rollValue, rollSessionId)
	if not upgraded then
		owner:AddPendingAward(itemLink, looter, rollType, rollValue, rollSessionId, expiresAt)
	elseif refreshLogged and type(owner.RefreshPendingAward) == "function" then
		owner:RefreshPendingAward(itemLink, looter, GROUP_LOOT_PENDING_AWARD_TTL_SECONDS, rollSessionId, expiresAt)
	end
	return upgraded
end

local function observeGroupLootWinnerMessage(owner, msg)
	if type(msg) ~= "string" or msg == "" or not PassiveGroupLoot.IsPassiveGroupLootMethod() then
		return nil
	end

	local playerName, itemLink, winnerRollType, winnerRollValue, winnerRollId = parseGroupLootWinnerCached(msg)
	if not (playerName and itemLink) then
		return nil
	end

	local canQueuePendingAward = owner and type(owner.AddPendingAward) == "function"
	local rule = getGroupLootRule(winnerRollType)
	local winnerTypeLabel = (rule and rule.label) or "msg-generic"
	local winnerRollLabel = (winnerRollValue ~= nil) and tostring(winnerRollValue) or "msg-none"
	if canQueuePendingAward and (winnerRollType ~= nil or winnerRollValue ~= nil) then
		queuePendingPassiveAward(owner, itemLink, playerName, winnerRollType, winnerRollValue, winnerRollId, true)
	end
	if isDebugEnabled() then
		addon:debug(
			Diag.D.LogLootGroupWinnerDetected:format(
				tostring(playerName),
				winnerTypeLabel,
				winnerRollLabel,
				tostring(itemLink)
			)
		)
	end
	local parsed =
		buildParsedGroupLootResult("winner", msg, playerName, itemLink, winnerRollType, winnerRollValue, winnerRollId)
	rememberParsedGroupLootResult(parsed)
	return "winner", parsed
end

local function getLootRollItemInfo(rollId)
	local texture, name, count, quality = GetLootRollItemInfo(rollId)
	return name, quality, texture, count
end

local function resolvePassiveLootRollEntry(itemLink, rollId)
	return PassiveGroupLoot.GetPassiveLootRollEntryByRollId(rollId)
		or PassiveGroupLoot.GetPassiveLootRollEntry(itemLink)
end

buildParsedGroupLootResult = function(kind, msg, playerName, itemLink, rollType, rollValue, rollId)
	local entry = resolvePassiveLootRollEntry(itemLink, rollId)
	local resolvedItemLink = (entry and entry.itemLink) or itemLink
	return {
		kind = kind,
		msg = msg,
		playerName = playerName,
		itemLink = resolvedItemLink,
		itemKey = (entry and entry.itemKey) or PassiveGroupLoot.GetPassiveLootRollItemKey(resolvedItemLink),
		rollType = rollType,
		rollValue = rollValue,
		rollId = (entry and entry.rollId) or rollId,
		sessionId = entry and entry.sessionId or nil,
		expiresAt = entry and entry.expiresAt or nil,
		bossNid = entry and entry.bossNid or nil,
		itemName = entry and entry.itemName or nil,
		itemRarity = entry and entry.itemRarity or nil,
		itemTexture = entry and entry.itemTexture or nil,
		itemCount = entry and entry.itemCount or nil,
		isPassiveWinner = kind == "winner",
	}
end

rememberParsedGroupLootResult = function(result)
	if type(result) ~= "table" then
		return
	end

	local entry = resolvePassiveLootRollEntry(result.itemLink, result.rollId)
	if not entry then
		return
	end

	local playerName = result.playerName
	if type(playerName) ~= "string" or playerName == "" then
		return
	end

	if result.kind == "winner" then
		entry.winner = {
			playerName = playerName,
			rollType = result.rollType,
			rollValue = result.rollValue,
			rollId = result.rollId,
		}
		return
	end

	if (tonumber(result.rollValue) or 0) > 0 then
		entry.rollsByPlayer = entry.rollsByPlayer or {}
		entry.rollsByPlayer[playerName] = {
			rollType = result.rollType,
			rollValue = result.rollValue,
			rollId = result.rollId,
		}
		return
	end

	entry.choicesByPlayer = entry.choicesByPlayer or {}
	entry.choicesByPlayer[playerName] = {
		rollType = result.rollType,
		rollId = result.rollId,
	}
end

-- ----- Public methods ----- --
function PassiveGroupLoot.IsPassiveGroupLootMethod(method)
	return IsPassiveGroupLootMethod(Raid, method) == true
end

function PassiveGroupLoot.GetPassiveLootRollItemKey(itemLink)
	local itemKey = GetItemStringFromLink(itemLink)
	if itemKey and itemKey ~= "" then
		return itemKey
	end
	return itemLink
end

function PassiveGroupLoot.GetPassiveLootRollEntry(itemLink)
	local itemKey = PassiveGroupLoot.GetPassiveLootRollItemKey(itemLink)
	return getActivePassiveLootRollByItemKey(itemKey)
end

function PassiveGroupLoot.GetPassiveLootRollEntryByRollId(rollId)
	return getActivePassiveLootRollByRollId(rollId)
end

function PassiveGroupLoot.ConsumePassiveLootRollEntry(sessionId)
	if type(sessionId) ~= "string" or sessionId == "" then
		return nil
	end

	local state = getPassiveLootRollState()
	local entry = state.bySessionId[sessionId]
	if not entry then
		return nil
	end
	if purgePassiveLootRollEntry(state, entry) then
		return nil
	end

	removePassiveLootRollEntry(state, entry)
	return entry
end

function PassiveGroupLoot.RememberLoggedPassiveLoot(itemLink, looter, rollSessionId)
	if not itemLink or not looter then
		return
	end

	local now = GetTime()
	purgeExpiredLoggedPassiveLoot(now)

	local state = getLoggedPassiveLootState()
	local key = buildLoggedPassiveLootKey(itemLink, looter)
	local list = state[key]
	if type(list) ~= "table" then
		list = {}
		state[key] = list
	end

	local resolvedSessionId = rollSessionId and tostring(rollSessionId) or nil
	local expiresAt = now + GROUP_LOOT_PENDING_AWARD_TTL_SECONDS
	for i = 1, #list do
		local marker = list[i]
		if marker and tostring(marker.rollSessionId or "") == tostring(resolvedSessionId or "") then
			marker.rollSessionId = resolvedSessionId
			marker.expiresAt = expiresAt
			return
		end
	end

	list[#list + 1] = {
		rollSessionId = resolvedSessionId,
		expiresAt = expiresAt,
	}
end

function PassiveGroupLoot.HasLoggedPassiveLoot(itemLink, looter, rollSessionId)
	if not itemLink or not looter then
		return false
	end

	purgeExpiredLoggedPassiveLoot()

	local state = getLoggedPassiveLootState()
	local list = state[buildLoggedPassiveLootKey(itemLink, looter)]
	if type(list) ~= "table" or #list == 0 then
		return false
	end

	local resolvedSessionId = rollSessionId and tostring(rollSessionId) or nil
	if resolvedSessionId and resolvedSessionId ~= "" then
		for i = 1, #list do
			local marker = list[i]
			if marker and tostring(marker.rollSessionId or "") == resolvedSessionId then
				return true
			end
		end
		return false
	end

	return #list == 1
end

function PassiveGroupLoot.IsPassiveLootWinnerMessage(msg)
	local _, itemLink = parseGroupLootWinnerCached(msg)
	return itemLink ~= nil
end

function PassiveGroupLoot.ParseGroupLootWinner(msg)
	return parseGroupLootWinnerCached(msg)
end

function PassiveGroupLoot.ResolvePassivePendingAwardContext(itemLink, rollId)
	local entry = PassiveGroupLoot.GetPassiveLootRollEntryByRollId(rollId)
		or PassiveGroupLoot.GetPassiveLootRollEntry(itemLink)
	if entry then
		return entry.sessionId, tonumber(entry.expiresAt) or nil
	end
	return nil, GetTime() + GROUP_LOOT_PENDING_AWARD_TTL_SECONDS
end

function PassiveGroupLoot.AddPassiveLootRoll(owner, rollId, rollTime)
	local currentRaidId = Database.GetCurrentRaid()
	if not currentRaidId or not PassiveGroupLoot.IsPassiveGroupLootMethod() then
		return nil
	end

	local resolvedRollId = tonumber(rollId)
	if not resolvedRollId then
		return nil
	end

	local itemLink = GetLootRollItemLink(resolvedRollId)
	if type(itemLink) ~= "string" or itemLink == "" then
		return nil
	end

	purgeExpiredPassiveLootRolls()
	local state = getPassiveLootRollState()
	local existing = state.byRollId[resolvedRollId]
	local durationSeconds = (tonumber(rollTime) or 0) / 1000
	if durationSeconds < 0 then
		durationSeconds = 0
	end
	local expiresAt = GetTime() + durationSeconds + GROUP_LOOT_ROLL_GRACE_SECONDS

	if existing then
		existing.itemLink = itemLink
		existing.itemKey = PassiveGroupLoot.GetPassiveLootRollItemKey(itemLink)
		local itemName, itemRarity, itemTexture, itemCount = getLootRollItemInfo(resolvedRollId)
		existing.itemName = itemName or existing.itemName
		existing.itemRarity = itemRarity or existing.itemRarity
		existing.itemTexture = itemTexture or existing.itemTexture
		existing.itemCount = tonumber(itemCount) or existing.itemCount
		existing.startedAt = tonumber(existing.startedAt) or GetTime()
		existing.expiresAt = expiresAt
		return existing
	end

	local itemKey = PassiveGroupLoot.GetPassiveLootRollItemKey(itemLink)
	local itemName, itemRarity, itemTexture, itemCount = getLootRollItemInfo(resolvedRollId)
	local list = state.byItemKey[itemKey]
	if type(list) ~= "table" then
		list = {}
		state.byItemKey[itemKey] = list
	end

	local entry = {
		rollId = resolvedRollId,
		itemLink = itemLink,
		itemKey = itemKey,
		itemName = itemName,
		itemRarity = itemRarity,
		itemTexture = itemTexture,
		itemCount = tonumber(itemCount) or nil,
		sessionId = "GL:" .. tostring(state.nextSessionId),
		startedAt = GetTime(),
		expiresAt = expiresAt,
		bossNid = nil,
		choicesByPlayer = {},
		rollsByPlayer = {},
		winner = nil,
	}
	state.nextSessionId = state.nextSessionId + 1
	list[#list + 1] = entry
	state.bySessionId[entry.sessionId] = entry
	state.byRollId[resolvedRollId] = entry
	return entry
end

function PassiveGroupLoot.ObserveGroupLootMessage(owner, msg)
	if type(msg) ~= "string" or msg == "" or not PassiveGroupLoot.IsPassiveGroupLootMethod() then
		return nil
	end

	local canQueuePendingAward = owner and type(owner.AddPendingAward) == "function"
	if canQueuePendingAward then
		for i = 1, #GROUP_LOOT_RULES do
			local rule = GROUP_LOOT_RULES[i]
			local playerName, itemLink, rollId = parseGroupLootSelection(msg, rule)
			if playerName and itemLink then
				local rollSessionId, expiresAt = PassiveGroupLoot.ResolvePassivePendingAwardContext(itemLink, rollId)
				owner:AddPendingAward(itemLink, playerName, rule.rollType, 0, rollSessionId, expiresAt)
				if isDebugEnabled() then
					addon:debug(
						Diag.D.LogLootGroupSelectionQueued:format(rule.label, tostring(playerName), tostring(itemLink))
					)
				end
				local parsed =
					buildParsedGroupLootResult("selection", msg, playerName, itemLink, rule.rollType, 0, rollId)
				rememberParsedGroupLootResult(parsed)
				return "selection", parsed
			end
		end

		local rollPlayer, rollItemLink, rollType, rollValue, rollId = parseGroupLootRoll(msg)
		if rollPlayer and rollItemLink and rollType then
			local rule = getGroupLootRule(rollType)
			queuePendingPassiveAward(owner, rollItemLink, rollPlayer, rollType, rollValue, rollId, false)
			if isDebugEnabled() then
				addon:debug(
					Diag.D.LogLootGroupSelectionQueued:format(
						(rule and rule.label) or "?",
						tostring(rollPlayer),
						tostring(rollItemLink)
					)
				)
			end
			local parsed =
				buildParsedGroupLootResult("roll", msg, rollPlayer, rollItemLink, rollType, rollValue, rollId)
			rememberParsedGroupLootResult(parsed)
			return "selection", parsed
		end
	end

	return observeGroupLootWinnerMessage(owner, msg)
end

function PassiveGroupLoot.ObserveGroupLootWinnerMessage(owner, msg)
	return observeGroupLootWinnerMessage(owner, msg)
end

function PassiveGroupLoot.AddGroupLootMessage(owner, msg)
	local observedType = PassiveGroupLoot.ObserveGroupLootMessage(owner, msg)
	return observedType
end
