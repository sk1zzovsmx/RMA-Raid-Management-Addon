-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: local feature = addon.Database.GetFeatureShared()
-- exports: addon.Services.Master.DebugRaidGrid
-- events: none
-- notes: pure Master debug raid grid row models
local addon = select(2, ...)
local feature = addon.Database.GetFeatureShared()

local Master = feature.EnsureServiceNamespace("Master")

local DebugRaidGrid = Master.DebugRaidGrid or {}
Master.DebugRaidGrid = DebugRaidGrid

local tinsert = table.insert
local type = type
local tostring = tostring
local tonumber = tonumber

-- ----- Internal state ----- --

local DEFAULT_DEBUG_COUNT = 25
local MAX_DEBUG_COUNT = 40
local MIN_DEBUG_COUNT = 1

local DEBUG_CLASSES = {
	"WARRIOR",
	"PALADIN",
	"HUNTER",
	"ROGUE",
	"PRIEST",
	"DEATHKNIGHT",
	"SHAMAN",
	"MAGE",
	"WARLOCK",
	"DRUID",
}

-- ----- Private helpers ----- --
local function clampDebugCount(count)
	local total = tonumber(count) or DEFAULT_DEBUG_COUNT
	total = math.floor(total)
	if total < MIN_DEBUG_COUNT then
		total = MIN_DEBUG_COUNT
	elseif total > MAX_DEBUG_COUNT then
		total = MAX_DEBUG_COUNT
	end
	return total
end

-- ----- Public methods ----- --

function DebugRaidGrid.BuildRows(count, rosterRows)
	local total = clampDebugCount(count)
	local result = {}
	local seen = {}

	if type(rosterRows) == "table" then
		for i = 1, #rosterRows do
			local row = rosterRows[i]
			local name = row and row.name
			if name and name ~= "" and not seen[name] then
				tinsert(result, {
					name = name,
					displayName = name,
					index = #result + 1,
					class = row.class or DEBUG_CLASSES[(#result % #DEBUG_CLASSES) + 1],
					debugOnly = true,
					realRoster = true,
				})
				seen[name] = true
			end
		end
	end

	if #result > total then
		total = #result
	end

	local fakeIndex = 1
	while #result < total do
		local name = "Player" .. tostring(fakeIndex)
		fakeIndex = fakeIndex + 1
		if not seen[name] then
			tinsert(result, {
				name = name,
				displayName = name,
				index = #result + 1,
				class = DEBUG_CLASSES[(#result % #DEBUG_CLASSES) + 1],
				debugOnly = true,
			})
			seen[name] = true
		end
	end

	return result, total
end

function DebugRaidGrid.GetTargetCount(debugState)
	return debugState and debugState.raidGridTargetCount or DEFAULT_DEBUG_COUNT
end

function DebugRaidGrid.IsFallbackEnabled(debugState, debugEnabled)
	if debugState and debugState.raidGridTargetCount then
		return true
	end
	return debugEnabled == true
end

local registry = feature.ModuleRegistry
if type(registry) == "table" and type(registry.AddModule) == "function" and type(registry.SetLoaded) == "function" then
	registry.AddModule("Services/Master/DebugRaidGrid", {
		deps = {
			"Init",
			"Modules/ModuleRegistry",
		},
	})
	registry.SetLoaded("Services/Master/DebugRaidGrid")
end
