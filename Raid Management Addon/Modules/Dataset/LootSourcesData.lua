-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: direct addon namespace bindings
-- exports: addon.LootSourcesData (active raid item source index and lifecycle)
-- events: none
-- notes: static raid item source data for Vanilla through Wrath of the Lich King

local addon = select(2, ...)
local pairs = pairs
local tostring = tostring
local tonumber = tonumber
local tconcat = table.concat
local strlower = string.lower
local gsub = string.gsub
local LootSourceCandidates = addon.LootSourceCandidates

-- ----- Internal state ----- --
local LootSourcesData = addon.LootSourcesData or {}
addon.LootSourcesData = LootSourcesData
LootSourcesData.ByItemId = nil
LootSourcesData.ByInstance = nil

local ByItemId
local ByInstance
local rawByInstance = {}
local activeInstanceKey
local generation = 0
local BOSS_SOURCE_KIND = "boss"
local UNKNOWN_MODE_SIZE = 0
local UNKNOWN_MODE_DIFFICULTY = "any"

-- ----- Private helpers ----- --
local function isBossSource(source)
	return source.kind == BOSS_SOURCE_KIND
end

local function trimText(value)
	if value == nil then
		return nil
	end
	return gsub(tostring(value), "^%s*(.-)%s*$", "%1")
end

local function normalizeText(value)
	local text = trimText(value)
	if text == nil or text == "" then
		return nil
	end
	return strlower(text)
end

local function copyModes(modes)
	if type(modes) ~= "table" then
		return nil
	end
	local copied = {}
	for mode, enabled in pairs(modes) do
		if type(mode) == "string" and enabled == true and (mode:match("^normal%d+$") or mode:match("^heroic%d+$")) then
			copied[mode] = true
		end
	end
	return copied
end

local function buildSourceKey(raidName, source)
	local raidKey = normalizeText(raidName) or "unknown"
	local kind = normalizeText(source and source.kind) or BOSS_SOURCE_KIND
	local npcId = tonumber(source and (source.npcId or source.sourceNpcId)) or 0
	local sourceName = normalizeText(source and (source.npcName or source.name)) or "unknown"
	return tconcat(
		{ raidKey, kind, tostring(npcId), sourceName, LootSourceCandidates.GetModeSignature(source and source.modes) },
		"|"
	)
end

local function parseMode(mode)
	if type(mode) ~= "string" then
		return nil, nil
	end
	local difficulty, sizeText = mode:match("^(.-)(%d+)$")
	if difficulty ~= "normal" and difficulty ~= "heroic" then
		return nil, nil
	end
	local size = tonumber(sizeText)
	return difficulty, size
end

local function getOrCreateModeSizeBucket(raidEntry, difficulty, size, itemId)
	local byDifficulty = raidEntry[difficulty]
	if byDifficulty == nil then
		byDifficulty = {}
		raidEntry[difficulty] = byDifficulty
	end

	local bySize = byDifficulty[size]
	if bySize == nil then
		bySize = {}
		byDifficulty[size] = bySize
	end

	local byItemId = bySize[itemId]
	if byItemId == nil then
		byItemId = {}
		bySize[itemId] = byItemId
	end

	return byItemId
end

local function addItemSource(itemId, source, raidName)
	local numericItemId = tonumber(itemId)
	if not numericItemId then
		return
	end

	local npcId = tonumber(source.npcId)
	if not npcId or npcId <= 0 then
		return
	end

	local itemSources = ByItemId[numericItemId]
	if not itemSources then
		itemSources = {}
		ByItemId[numericItemId] = itemSources
	end

	local modes = copyModes(source.modes)
	local candidate = {
		npcId = npcId,
		npcName = tostring(source.name or ""),
		npcNameNormalized = normalizeText(source.name),
		raid = tostring(raidName or ""),
		raidNormalized = normalizeText(raidName),
		kind = source.kind or BOSS_SOURCE_KIND,
		modes = modes,
	}
	candidate.sourceKey = source.sourceKey or buildSourceKey(raidName, candidate)

	itemSources[#itemSources + 1] = candidate
end

local function addSourceToInstanceIndex(candidate, itemId)
	local raidKey = candidate.raidNormalized
	if not raidKey then
		return
	end

	local raidEntry = ByInstance[raidKey]
	if raidEntry == nil then
		raidEntry = {}
		ByInstance[raidKey] = raidEntry
	end

	local wasIndexed = false
	if type(candidate.modes) == "table" then
		for mode in pairs(candidate.modes) do
			local difficulty, size = parseMode(mode)
			if difficulty and size then
				local byItemIdBySize = getOrCreateModeSizeBucket(raidEntry, difficulty, size, itemId)
				byItemIdBySize[#byItemIdBySize + 1] = candidate

				local byItemIdByAnySize = getOrCreateModeSizeBucket(raidEntry, difficulty, UNKNOWN_MODE_SIZE, itemId)
				byItemIdByAnySize[#byItemIdByAnySize + 1] = candidate

				local byItemIdByAnyDiff = getOrCreateModeSizeBucket(raidEntry, UNKNOWN_MODE_DIFFICULTY, size, itemId)
				byItemIdByAnyDiff[#byItemIdByAnyDiff + 1] = candidate

				local byItemIdByFallback =
					getOrCreateModeSizeBucket(raidEntry, UNKNOWN_MODE_DIFFICULTY, UNKNOWN_MODE_SIZE, itemId)
				byItemIdByFallback[#byItemIdByFallback + 1] = candidate

				wasIndexed = true
			end
		end
	end

	if not wasIndexed then
		local byItemIdByFallback =
			getOrCreateModeSizeBucket(raidEntry, UNKNOWN_MODE_DIFFICULTY, UNKNOWN_MODE_SIZE, itemId)
		byItemIdByFallback[#byItemIdByFallback + 1] = candidate
	end
end

local function markSharedItemSources()
	for _, itemSources in pairs(ByItemId) do
		local bossKeys = {}
		local bossCount = 0
		for i = 1, #itemSources do
			local source = itemSources[i]
			if isBossSource(source) then
				local key = tostring(source.raid or "") .. ":" .. tostring(source.npcId or "")
				if not bossKeys[key] then
					bossKeys[key] = true
					bossCount = bossCount + 1
				end
			end
		end

		if bossCount > 1 then
			for i = 1, #itemSources do
				local source = itemSources[i]
				if isBossSource(source) then
					source.shared = true
					source.note = "Shared"
				end
			end
		end
	end
end

local function buildInstanceIndex()
	ByInstance = {}

	for itemId, itemSources in pairs(ByItemId) do
		for i = 1, #itemSources do
			addSourceToInstanceIndex(itemSources[i], itemId)
		end
	end
end

local function loadRaidLootSources(raidLootSources)
	for i = 1, #raidLootSources do
		local raid = raidLootSources[i]
		local raidName = type(raid) == "table" and raid.name or nil
		local sources = type(raid) == "table" and type(raid.sources) == "table" and raid.sources or {}
		for j = 1, #sources do
			local source = sources[j]
			local items = type(source) == "table" and type(source.items) == "table" and source.items or {}
			for k = 1, #items do
				local item = items[k]
				if type(item) == "table" then
					addItemSource(item[1], {
						npcId = source.npcId,
						name = source.name,
						kind = source.kind,
						modes = item[2],
					}, raidName)
				end
			end
		end
	end
end

local RawSources = LootSourcesData.Raw or {}
for i = 1, #RawSources do
	local raid = RawSources[i]
	local raidKey = normalizeText(type(raid) == "table" and raid.name or nil)
	if raidKey then
		assert(rawByInstance[raidKey] == nil, "duplicate normalized loot-source raid name: " .. raidKey)
		rawByInstance[raidKey] = raid
	end
end

-- ----- Public methods ----- --
function LootSourcesData.DeactivateInstance()
	if activeInstanceKey == nil then
		return false
	end

	ByItemId = nil
	ByInstance = nil
	LootSourcesData.ByItemId = nil
	LootSourcesData.ByInstance = nil
	activeInstanceKey = nil
	generation = generation + 1
	return true
end

function LootSourcesData.ActivateInstance(instanceName)
	local instanceKey = normalizeText(instanceName)
	if instanceKey ~= nil and instanceKey == activeInstanceKey then
		return true
	end

	local wasActive = activeInstanceKey ~= nil
	LootSourcesData.DeactivateInstance()
	local raid = instanceKey and rawByInstance[instanceKey] or nil
	if raid == nil then
		return false, "unsupported-instance"
	end

	ByItemId = {}
	ByInstance = {}
	local function buildRequestedInstance()
		loadRaidLootSources({ raid })
		markSharedItemSources()
		buildInstanceIndex()
	end
	local buildOk, buildError = pcall(buildRequestedInstance)
	if not buildOk then
		ByItemId = nil
		ByInstance = nil
		LootSourcesData.ByItemId = nil
		LootSourcesData.ByInstance = nil
		activeInstanceKey = nil
		error(buildError, 0)
	end
	LootSourcesData.ByItemId = ByItemId
	LootSourcesData.ByInstance = ByInstance
	activeInstanceKey = instanceKey
	if not wasActive then
		generation = generation + 1
	end
	return true
end

function LootSourcesData.GetActiveInstanceKey()
	return activeInstanceKey
end

function LootSourcesData.GetGeneration()
	return generation
end

function LootSourcesData._SetActiveIndexForTests(byItemId)
	ByItemId = byItemId or {}
	ByInstance = {}
	LootSourcesData.ByItemId = ByItemId
	LootSourcesData.ByInstance = ByInstance
	activeInstanceKey = "__test__"
	generation = generation + 1
end

function LootSourcesData._HasGeneratedRootsForTests()
	return ByItemId ~= nil or ByInstance ~= nil
end
