-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: direct addon namespace bindings
-- exports: addon.LootSources
-- events: none

local addon = select(2, ...)
local Strings = assert(addon.Strings, "Loot source string helpers are not initialized")
local LootSourceCandidates = addon.LootSourceCandidates
local TrimText = assert(Strings.TrimText, "Loot source text trimmer is not initialized")
local NormalizeLower = assert(Strings.NormalizeLower, "Loot source text normalizer is not initialized")

local type, tonumber, tostring = type, tonumber, tostring
local pairs = pairs
local tconcat = table.concat

local LootSourcesData = addon.LootSourcesData or {}
addon.LootSourcesData = LootSourcesData
local LootSources = addon.LootSources or {}
addon.LootSources = LootSources

-- ----- Internal state ----- --
local GET_CANDIDATES_CACHE_SIZE_LIMIT = 2048
local GET_CANDIDATES_CACHE = {}
local GET_CANDIDATES_CACHE_SIZE = 0
local GET_CANDIDATES_CACHE_HIT = {}
local FIND_SOURCE_CACHE_LIMIT = 512
local FIND_SOURCE_CACHE = {}
local FIND_SOURCE_CACHE_SIZE = 0
local LAST_DATA_GENERATION = type(LootSourcesData.GetGeneration) == "function" and LootSourcesData.GetGeneration() or 0

local VALID_SOURCE_KINDS = {
	boss = true,
	trash = true,
}

local VALID_MODE_KEYS = {
	normal10 = true,
	normal20 = true,
	normal25 = true,
	normal40 = true,
	heroic10 = true,
	heroic25 = true,
}

-- ----- Private helpers ----- --
local function clearResolverCaches()
	GET_CANDIDATES_CACHE = {}
	GET_CANDIDATES_CACHE_HIT = {}
	GET_CANDIDATES_CACHE_SIZE = 0
	FIND_SOURCE_CACHE = {}
	FIND_SOURCE_CACHE_SIZE = 0
end

local function refreshDataGeneration()
	local currentGeneration = type(LootSourcesData.GetGeneration) == "function" and LootSourcesData.GetGeneration() or 0
	if currentGeneration ~= LAST_DATA_GENERATION then
		clearResolverCaches()
		LAST_DATA_GENERATION = currentGeneration
	end
end

local function trimText(value)
	return TrimText(value)
end

local function normalizeText(value)
	local text = trimText(value)
	if text == "" then
		return nil
	end
	return NormalizeLower(text, true)
end

local function copyModes(modes)
	if type(modes) ~= "table" then
		return nil
	end

	local copied = {}
	for key, value in pairs(modes) do
		copied[key] = value
	end
	return copied
end

local function buildCandidateSourceKey(candidate)
	local raidKey = normalizeText(candidate and candidate.raid) or "unknown"
	local kind = normalizeText(candidate and candidate.kind) or "boss"
	local npcId = tonumber(candidate and (candidate.npcId or candidate.sourceNpcId)) or 0
	local sourceName = normalizeText(candidate and (candidate.npcName or candidate.name)) or "unknown"
	return tconcat({
		raidKey,
		kind,
		tostring(npcId),
		sourceName,
		LootSourceCandidates.GetModeSignature(candidate and candidate.modes),
	}, "|")
end

local function copyCandidate(candidate)
	local modes = copyModes(candidate.modes)
	return {
		npcId = tonumber(candidate.npcId),
		npcName = candidate.npcName,
		raid = candidate.raid,
		kind = candidate.kind,
		modes = modes,
		shared = candidate.shared == true,
		note = candidate.note,
		sourceKey = candidate.sourceKey or buildCandidateSourceKey({
			npcId = candidate.npcId,
			npcName = candidate.npcName,
			raid = candidate.raid,
			kind = candidate.kind,
			modes = modes,
		}),
	}
end

local function copyCandidates(candidates)
	local copied = {}
	for i = 1, #candidates do
		copied[#copied + 1] = copyCandidate(candidates[i])
	end
	return copied
end

local function cloneResolvedResult(result)
	if type(result) ~= "table" then
		return nil
	end

	local resolved = {
		reason = result.reason,
		confidence = result.confidence,
	}

	local copiedCandidate = copyCandidate(result)
	for key, value in pairs(copiedCandidate) do
		resolved[key] = value
	end

	if type(result.candidates) == "table" then
		resolved.candidates = copyCandidates(result.candidates)
	end

	return resolved
end

local function isValidCandidate(candidate)
	if type(candidate) ~= "table" or VALID_SOURCE_KINDS[candidate.kind] ~= true then
		return false
	end

	local npcId = tonumber(candidate.npcId)
	if not npcId or npcId <= 0 then
		return false
	end

	return normalizeText(candidate.npcName) ~= nil and normalizeText(candidate.raid) ~= nil
end

local function getCacheKeyFromContext(itemId, context, modeKey)
	local normalizedRaid = context.normalizedRaid or normalizeText(context.raid)
	if not normalizedRaid then
		normalizedRaid = context.normalizedZoneName or normalizeText(context.zoneName)
	end
	if not normalizedRaid then
		normalizedRaid = context.normalizedInstanceName or normalizeText(context.instanceName)
	end
	return table.concat({
		tostring(itemId),
		tostring(modeKey or ""),
		normalizedRaid or "",
		tostring(tonumber(context.raidSize) or 0),
		tostring(tonumber(context.difficulty) or 0),
		tostring(tonumber(context.recentSourceNpcId) or 0),
		context.normalizedRecentSourceName or normalizeText(context.recentSourceName) or "",
	}, "|")
end

local function cacheFindSourceResult(itemId, context, modeKey, result)
	local cacheKey = getCacheKeyFromContext(itemId, context, modeKey)
	if not FIND_SOURCE_CACHE[cacheKey] then
		FIND_SOURCE_CACHE_SIZE = FIND_SOURCE_CACHE_SIZE + 1
	end
	FIND_SOURCE_CACHE[cacheKey] = cloneResolvedResult(result)
	if FIND_SOURCE_CACHE_SIZE > FIND_SOURCE_CACHE_LIMIT then
		FIND_SOURCE_CACHE = {}
		FIND_SOURCE_CACHE_SIZE = 0
	end
	return true
end

local function getCachedFindSourceResult(itemId, context, modeKey)
	local cacheKey = getCacheKeyFromContext(itemId, context, modeKey)
	local cached = FIND_SOURCE_CACHE[cacheKey]
	if cached then
		return cloneResolvedResult(cached)
	end
	return nil
end

local function getModeKey(context)
	if type(context) ~= "table" then
		return nil
	end

	if type(context.mode) == "string" then
		local mode = normalizeText(context.mode)
		if VALID_MODE_KEYS[mode] == true then
			return mode
		end
	end

	local raidSize = tonumber(context.raidSize)
	local difficulty = tonumber(context.difficulty)
	if raidSize ~= 10 and raidSize ~= 20 and raidSize ~= 25 and raidSize ~= 40 then
		if difficulty == 3 or difficulty == 5 then
			raidSize = 10
		elseif difficulty == 4 or difficulty == 6 then
			raidSize = 25
		end
	end

	if raidSize ~= 10 and raidSize ~= 20 and raidSize ~= 25 and raidSize ~= 40 then
		return nil
	end

	local heroic = difficulty == 5 or difficulty == 6
	if context.isHeroic == true or context.heroic == true then
		heroic = true
	end

	if raidSize == 20 or raidSize == 40 then
		return "normal" .. tostring(raidSize)
	end

	return (heroic and "heroic" or "normal") .. tostring(raidSize)
end

local function parseModeKey(modeKey)
	if type(modeKey) ~= "string" then
		return nil, nil
	end
	local difficulty, sizeText = modeKey:match("^(.-)(%d+)$")
	if difficulty ~= "normal" and difficulty ~= "heroic" then
		return nil, nil
	end
	return difficulty, tonumber(sizeText)
end

local function normalizeLookupContext(context)
	if type(context) ~= "table" then
		return {
			raid = nil,
			zoneName = nil,
			instanceName = nil,
			raidSize = 0,
			difficulty = 0,
			recentSourceNpcId = 0,
			recentSourceName = nil,
			normalizedRaid = nil,
			normalizedZoneName = nil,
			normalizedInstanceName = nil,
			normalizedRecentSourceName = nil,
			isHeroic = false,
		}
	end

	return {
		raid = context.raid,
		zoneName = context.zoneName,
		instanceName = context.instanceName,
		raidSize = tonumber(context.raidSize) or 0,
		difficulty = tonumber(context.difficulty) or 0,
		recentSourceNpcId = tonumber(context.recentSourceNpcId) or 0,
		recentSourceName = context.recentSourceName,
		normalizedRaid = normalizeText(context.raid),
		normalizedZoneName = normalizeText(context.zoneName),
		normalizedInstanceName = normalizeText(context.instanceName),
		normalizedRecentSourceName = normalizeText(context.recentSourceName),
		isHeroic = context.isHeroic == true or context.heroic == true,
		mode = context.mode,
	}
end

local function matchesRaidContext(candidate, context)
	if type(context) ~= "table" then
		return true
	end

	local candidateRaid = candidate.raidNormalized or normalizeText(candidate.raid)
	if not candidateRaid then
		return true
	end

	local raid = context.normalizedRaid or normalizeText(context.raid)
	local zoneName = context.normalizedZoneName or normalizeText(context.zoneName)
	local instanceName = context.normalizedInstanceName or normalizeText(context.instanceName)

	if not raid and not zoneName and not instanceName then
		return true
	end

	return candidateRaid == raid or candidateRaid == zoneName or candidateRaid == instanceName
end

local function matchesModeContext(candidate, modeKey)
	if not modeKey then
		return true
	end

	if type(candidate.modes) ~= "table" then
		return true
	end

	return candidate.modes[modeKey] == true
end

local function filterCandidates(candidates, context, modeKey)
	local filtered = {}
	for i = 1, #candidates do
		local candidate = candidates[i]
		if matchesRaidContext(candidate, context) and matchesModeContext(candidate, modeKey) then
			filtered[#filtered + 1] = candidate
		end
	end
	return filtered
end

local function getIndexedCandidates(itemId, context, modeKey)
	local index = LootSourcesData.ByInstance
	if type(index) ~= "table" then
		return nil
	end

	local normalizedContext = normalizeLookupContext(context)
	local raidKey = normalizedContext.normalizedRaid
		or normalizedContext.normalizedZoneName
		or normalizedContext.normalizedInstanceName
	if not raidKey then
		return nil
	end

	local difficulty, size = parseModeKey(modeKey)
	if not difficulty or not size then
		return nil
	end

	local byRaid = index[raidKey]
	if type(byRaid) ~= "table" then
		return nil
	end

	local byDifficulty = byRaid[difficulty]
	local candidatesByItem

	if type(byDifficulty) == "table" then
		local bySize = byDifficulty[size]
		if bySize then
			candidatesByItem = bySize[itemId]
			if type(candidatesByItem) == "table" and #candidatesByItem > 0 then
				return candidatesByItem
			end
		end

		local byAnySize = byDifficulty[0]
		if byAnySize then
			candidatesByItem = byAnySize[itemId]
			if type(candidatesByItem) == "table" and #candidatesByItem > 0 then
				return candidatesByItem
			end
		end
	end

	local byAnyDifficulty = byRaid["any"]
	if type(byAnyDifficulty) == "table" then
		local byAnySize = byAnyDifficulty[size]
		if byAnySize then
			candidatesByItem = byAnySize[itemId]
			if type(candidatesByItem) == "table" and #candidatesByItem > 0 then
				return candidatesByItem
			end
		end

		local byFallback = byAnyDifficulty[0]
		if byFallback then
			candidatesByItem = byFallback[itemId]
			if type(candidatesByItem) == "table" and #candidatesByItem > 0 then
				return candidatesByItem
			end
		end
	end

	return nil
end

local function withConfidence(candidate, confidence)
	local resolved = copyCandidate(candidate)
	resolved.confidence = confidence
	return resolved
end

local function withSharedContext(candidate, candidates)
	local resolved = withConfidence(candidate, "shared-context")
	resolved.shared = true
	resolved.note = "Shared"
	resolved.candidates = copyCandidates(candidates)
	return resolved
end

local function buildSharedSourceKey(candidates)
	local keys = {}
	for i = 1, #candidates do
		local candidate = candidates[i]
		if type(candidate) == "table" then
			keys[#keys + 1] = candidate.sourceKey or buildCandidateSourceKey(candidate)
		end
	end
	return (#keys > 0) and ("shared|" .. tconcat(keys, ";")) or nil
end

local function buildSharedSource(candidates)
	return {
		reason = "shared",
		npcId = 0,
		npcName = "Shared",
		raid = candidates[1] and candidates[1].raid or nil,
		kind = "shared",
		confidence = "shared",
		shared = true,
		note = "Shared",
		sourceKey = buildSharedSourceKey(candidates),
		candidates = copyCandidates(candidates),
	}
end

local function findRecentSourceCandidate(candidates, context)
	if type(context) ~= "table" then
		return nil
	end

	local recentSourceNpcId = tonumber(context.recentSourceNpcId) or 0
	if recentSourceNpcId > 0 then
		for i = 1, #candidates do
			if tonumber(candidates[i].npcId) == recentSourceNpcId then
				return candidates[i]
			end
		end
	end

	local recentSourceName = context.normalizedRecentSourceName or normalizeText(context.recentSourceName)
	if recentSourceName then
		for i = 1, #candidates do
			local normalizedNpcName = candidates[i].npcNameNormalized or normalizeText(candidates[i].npcName)
			if normalizedNpcName == recentSourceName then
				return candidates[i]
			end
		end
	end

	return nil
end

local function findSharedTrashCandidate(candidates)
	local sharedNpcId
	local sharedCandidate
	for i = 1, #candidates do
		local candidate = candidates[i]
		if candidate.kind ~= "trash" then
			return nil
		end

		local npcId = tonumber(candidate.npcId)
		if not npcId then
			return nil
		end

		if sharedNpcId and sharedNpcId ~= npcId then
			return nil
		end

		sharedNpcId = npcId
		sharedCandidate = sharedCandidate or candidate
	end

	return sharedCandidate
end

local function getCachedCandidates(itemId, sources)
	if itemId <= 0 then
		return {}
	end

	if GET_CANDIDATES_CACHE_HIT[itemId] then
		return copyCandidates(GET_CANDIDATES_CACHE[itemId] or {})
	end

	local candidates = {}
	for i = 1, #sources do
		local candidate = sources[i]
		if isValidCandidate(candidate) then
			candidates[#candidates + 1] = copyCandidate(candidate)
		end
	end

	if GET_CANDIDATES_CACHE_SIZE >= GET_CANDIDATES_CACHE_SIZE_LIMIT then
		GET_CANDIDATES_CACHE = {}
		GET_CANDIDATES_CACHE_HIT = {}
		GET_CANDIDATES_CACHE_SIZE = 0
	end

	if GET_CANDIDATES_CACHE_HIT[itemId] == nil then
		GET_CANDIDATES_CACHE_HIT[itemId] = true
		GET_CANDIDATES_CACHE_SIZE = GET_CANDIDATES_CACHE_SIZE + 1
		GET_CANDIDATES_CACHE[itemId] = candidates
	end

	return copyCandidates(candidates)
end

local function setDataForTests(byItemId)
	assert(
		type(LootSourcesData._SetActiveIndexForTests) == "function",
		"Loot source test data lifecycle is not initialized"
	)
	LootSourcesData._SetActiveIndexForTests(byItemId)
	clearResolverCaches()
	LAST_DATA_GENERATION = LootSourcesData.GetGeneration()
end

-- ----- Public methods ----- --
function LootSources.GetCandidates(itemId, context, modeKey)
	refreshDataGeneration()
	local numericItemId = tonumber(itemId)
	if not numericItemId then
		return {}
	end

	if modeKey == nil and type(context) == "table" then
		modeKey = getModeKey(context)
	end

	if type(context) == "table" and modeKey then
		local indexedCandidates = getIndexedCandidates(numericItemId, context, modeKey)
		if indexedCandidates then
			return copyCandidates(indexedCandidates)
		end
	end

	local byItemId = LootSourcesData.ByItemId
	local sources = type(byItemId) == "table" and byItemId[numericItemId] or nil
	if type(sources) ~= "table" then
		return {}
	end

	return getCachedCandidates(numericItemId, sources)
end

function LootSources.FindSource(itemId, context)
	refreshDataGeneration()
	local numericItemId = tonumber(itemId)
	if not numericItemId then
		return { reason = "missing", candidates = {} }
	end

	local normalizedContext = normalizeLookupContext(context)
	local modeKey = getModeKey(context)
	local cached = getCachedFindSourceResult(numericItemId, normalizedContext, modeKey)
	if cached then
		return cached
	end

	local candidates = filterCandidates(
		LootSources.GetCandidates(numericItemId, normalizedContext, modeKey),
		normalizedContext,
		modeKey
	)
	if #candidates == 0 then
		local missing = { reason = "missing", candidates = {} }
		cacheFindSourceResult(numericItemId, normalizedContext, modeKey, missing)
		return missing
	end

	if #candidates == 1 then
		local exact = withConfidence(candidates[1], "exact")
		cacheFindSourceResult(numericItemId, normalizedContext, modeKey, exact)
		return exact
	end

	local sharedTrashCandidate = findSharedTrashCandidate(candidates)
	if sharedTrashCandidate then
		local sharedTrash = withConfidence(sharedTrashCandidate, "shared-trash")
		cacheFindSourceResult(numericItemId, normalizedContext, modeKey, sharedTrash)
		return sharedTrash
	end

	local recentSourceCandidate = findRecentSourceCandidate(candidates, normalizedContext)
	if recentSourceCandidate then
		local sharedContext = withSharedContext(recentSourceCandidate, candidates)
		cacheFindSourceResult(numericItemId, normalizedContext, modeKey, sharedContext)
		return sharedContext
	end

	local shared = buildSharedSource(candidates)
	cacheFindSourceResult(numericItemId, normalizedContext, modeKey, shared)
	return shared
end

LootSources._SetDataForTests = setDataForTests
