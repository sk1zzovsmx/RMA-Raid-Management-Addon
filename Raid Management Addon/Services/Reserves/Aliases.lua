-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: local feature = addon.Database.GetFeatureShared()
-- exports: addon.Services.Reserves._Aliases
-- events: no bus events; alias helpers only
-- notes: reserves name-alias helpers

local addon = select(2, ...)
local feature = addon.Database.GetFeatureShared()

local Strings = feature.Strings
local Services = feature.Services

local pairs, tostring, type = pairs, tostring, type
local sort = table.sort

-- ----- Internal state ----- --
feature.EnsureServiceNamespace("Reserves")
local Reserves = Services.Reserves
local module = Reserves
module._Aliases = module._Aliases or {}

local Aliases = module._Aliases

-- ----- Private helpers ----- --
local normalizeName = Strings.NormalizeName
local normalizeKey = Strings.NormalizeLower

Aliases._NormalizeKey = normalizeKey

local function buildNameIndex(players)
	local byKey = {}
	for i = 1, #(players or {}) do
		local name = players[i]
		local key = normalizeKey(name)
		if key and not byKey[key] then
			byKey[key] = name
		end
	end
	return byKey
end

local function compareAliasMatch(a, b)
	if a.reserveName ~= b.reserveName then
		return tostring(a.reserveName) < tostring(b.reserveName)
	end
	return tostring(a.raidName) < tostring(b.raidName)
end

-- ----- Public methods ----- --
function Aliases.CopyAliasMap(aliasMap)
	local out = {}
	for reserveKey, raidName in pairs(aliasMap or {}) do
		local key = normalizeKey(reserveKey)
		local value = normalizeName(raidName)
		if key and value then
			out[key] = value
		end
	end
	return out
end

function Aliases.BuildAliasState(aliasMap)
	local state = {
		byReserveKey = {},
		reserveKeyByRaidKey = {},
	}

	for reserveKey, raidName in pairs(aliasMap or {}) do
		local normalizedReserveKey = normalizeKey(reserveKey)
		local raidDisplayName = normalizeName(raidName)
		local raidKey = normalizeKey(raidDisplayName)
		if normalizedReserveKey and raidKey and raidDisplayName then
			state.byReserveKey[normalizedReserveKey] = raidDisplayName
			state.reserveKeyByRaidKey[raidKey] = normalizedReserveKey
		end
	end

	return state
end

function Aliases.ResolveReserveKey(aliasState, reserveData, playerName)
	local playerKey = normalizeKey(playerName)
	if not playerKey then
		return nil
	end
	if type(reserveData) == "table" and reserveData[playerKey] then
		return playerKey
	end

	local state = aliasState or {}
	local reserveKey = state.reserveKeyByRaidKey and state.reserveKeyByRaidKey[playerKey] or nil
	if reserveKey and type(reserveData) == "table" and reserveData[reserveKey] then
		return reserveKey
	end
	return nil
end

function Aliases.GetAliasMatches(aliasState, reservePlayers, raidPlayers)
	local state = aliasState or {}
	local reserveByKey = buildNameIndex(reservePlayers)
	local raidByKey = buildNameIndex(raidPlayers)
	local matches = {}

	for reserveKey, raidName in pairs(state.byReserveKey or {}) do
		local reserveName = reserveByKey[reserveKey]
		local raidKey = normalizeKey(raidName)
		local raidDisplayName = raidKey and raidByKey[raidKey] or nil
		if reserveName and raidDisplayName then
			matches[#matches + 1] = {
				reserveName = reserveName,
				raidName = raidDisplayName,
				reserveKey = reserveKey,
				raidKey = raidKey,
			}
		end
	end

	sort(matches, compareAliasMatch)
	return matches
end

function Aliases.SetAlias(aliasMap, reserveName, raidName)
	if type(aliasMap) ~= "table" then
		return false, "invalid_map"
	end
	local reserveKey = normalizeKey(reserveName)
	local raidDisplayName = normalizeName(raidName)
	if not reserveKey or not raidDisplayName then
		return false, "invalid_name"
	end
	aliasMap[reserveKey] = raidDisplayName
	return true
end

function Aliases.ClearAlias(aliasMap, reserveName)
	if type(aliasMap) ~= "table" then
		return false, "invalid_map"
	end
	local reserveKey = normalizeKey(reserveName)
	if not reserveKey then
		return false, "invalid_name"
	end
	aliasMap[reserveKey] = nil
	return true
end

local registry = feature.ModuleRegistry
if type(registry) == "table" and type(registry.AddModule) == "function" and type(registry.SetLoaded) == "function" then
	registry.AddModule("Services/Reserves/Aliases", {
		deps = {
			"Init",
			"Modules/ModuleRegistry",
			"Modules/Strings",
		},
	})
	registry.SetLoaded("Services/Reserves/Aliases")
end
