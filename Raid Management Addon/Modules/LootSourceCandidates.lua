-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: direct addon namespace bindings
-- exports: addon.LootSourceCandidates
-- events: none

local addon = select(2, ...)
local Strings = addon.Strings
local NormalizeLower = assert(Strings.NormalizeLower, "Loot source candidate normalizer is not initialized")

local type, tostring, tonumber = type, tostring, tonumber
local strsub = string.sub
local strlen = string.len
local gmatch = string.gmatch
local tconcat = table.concat

-- ----- Internal state ----- --
local LootSourceCandidates = addon.LootSourceCandidates or {}
addon.LootSourceCandidates = LootSourceCandidates
addon.LootSourceCandidates = LootSourceCandidates

local SHARED_SOURCE_LABEL = "Shared"
local SHARED_SOURCE_PREFIX = "Shared:"
local MODE_KEY_ORDER = {
	"normal10",
	"normal20",
	"normal25",
	"normal40",
	"heroic10",
	"heroic25",
}

-- ----- Private helpers ----- --
local function candidateKey(name)
	return NormalizeLower(name, true) or name
end

-- ----- Public methods ----- --
function LootSourceCandidates.GetModeSignature(modes)
	if type(modes) ~= "table" then
		return "any"
	end

	local out = {}
	for i = 1, #MODE_KEY_ORDER do
		local mode = MODE_KEY_ORDER[i]
		if modes[mode] == true then
			out[#out + 1] = mode
		end
	end

	return (#out > 0) and tconcat(out, ",") or "any"
end

function LootSourceCandidates.GetSharedLabel()
	return SHARED_SOURCE_LABEL
end

function LootSourceCandidates.IsLegacySharedText(value)
	local text = Strings.NormalizeText(value, true)
	return type(text) == "string" and strsub(text, 1, strlen(SHARED_SOURCE_PREFIX)) == SHARED_SOURCE_PREFIX
end

function LootSourceCandidates.IsSharedSourceName(value)
	local text = Strings.NormalizeText(value, true)
	return text == SHARED_SOURCE_LABEL or LootSourceCandidates.IsLegacySharedText(text)
end

function LootSourceCandidates.Append(out, seen, rawName, rawNpcId, rawKind, rawSourceKey)
	if type(out) ~= "table" or type(seen) ~= "table" then
		return false
	end

	local name = Strings.NormalizeText(rawName, true)
	if not name then
		return false
	end

	local key = candidateKey(name)
	if seen[key] then
		return false
	end
	seen[key] = true

	local candidate = {
		name = name,
		kind = Strings.NormalizeText(rawKind, true) or "boss",
	}

	local sourceKey = Strings.NormalizeText(rawSourceKey, true)
	if sourceKey then
		candidate.sourceKey = sourceKey
	end

	local npcId = tonumber(rawNpcId) or 0
	if npcId > 0 then
		candidate.npcId = npcId
	end

	out[#out + 1] = candidate
	return true
end

function LootSourceCandidates.ParseSharedText(value)
	local text = Strings.NormalizeText(value, true)
	if not text then
		return nil
	end

	if LootSourceCandidates.IsLegacySharedText(text) then
		text = Strings.NormalizeText(strsub(text, strlen(SHARED_SOURCE_PREFIX) + 1), true)
	end
	if not text or text == SHARED_SOURCE_LABEL then
		return nil
	end

	local out = {}
	local seen = {}
	for name in gmatch(text, "[^/]+") do
		LootSourceCandidates.Append(out, seen, name, nil, "boss")
	end
	return (#out > 0) and out or nil
end

function LootSourceCandidates.Copy(candidates, fallbackText)
	local copied = {}
	local seen = {}

	if type(candidates) == "table" then
		for i = 1, #candidates do
			local candidate = candidates[i]
			if type(candidate) == "table" then
				LootSourceCandidates.Append(
					copied,
					seen,
					candidate.name or candidate.npcName,
					candidate.npcId or candidate.sourceNpcId,
					candidate.kind,
					candidate.sourceKey
				)
			end
		end
	end

	if #copied == 0 then
		local parsed = LootSourceCandidates.ParseSharedText(fallbackText)
		if type(parsed) == "table" then
			for i = 1, #parsed do
				local candidate = parsed[i]
				LootSourceCandidates.Append(
					copied,
					seen,
					candidate.name,
					candidate.npcId,
					candidate.kind,
					candidate.sourceKey
				)
			end
		end
	end

	return (#copied > 0) and copied or nil
end

function LootSourceCandidates.ResolveSourceMetadata(loot, boss)
	local lootSource = type(loot and loot.lootSource) == "table" and loot.lootSource or nil
	local sourceKind = (lootSource and lootSource.kind) or (boss and boss.sourceKind) or nil
	local bossName = boss and boss.name or ""
	local lootSourceName = lootSource and lootSource.sourceName or nil
	local sourceName = lootSourceName or bossName or ""
	local sourceKey = lootSource and lootSource.sourceKey or boss and boss.sourceKey or nil

	if
		sourceKind == "shared"
		or LootSourceCandidates.IsLegacySharedText(sourceName)
		or LootSourceCandidates.IsLegacySharedText(bossName)
	then
		return SHARED_SOURCE_LABEL,
			"shared",
			LootSourceCandidates.Copy(lootSource and lootSource.candidates, lootSourceName or bossName),
			sourceKey
	end

	return sourceName, sourceKind, nil, sourceKey
end
