-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: local feature = addon.Database.GetFeatureShared()
-- exports: addon.Services.Rolls._Strategies
-- events: none
-- notes: roll resolution strategy helpers

local addon = select(2, ...)
local feature = addon.Database.GetFeatureShared()

local Services = feature.Services

local tostring, tonumber, type = tostring, tonumber, type

-- ----- Internal state ----- --
feature.EnsureServiceNamespace("Rolls")
local Rolls = Services.Rolls
local module = Rolls
module._Strategies = module._Strategies or {}

local Strategies = module._Strategies

local STRATEGY_NORMAL = "normal"
local STRATEGY_RESERVED = "reserved"
local STRATEGY_TIE = "tie"
local STRATEGY_RAID_ROLL = "raid_roll"

-- ----- Private helpers ----- --
local function isReservedRoll(ctx, rollType)
	local rollTypes = ctx.rollTypes or feature.rollTypes or {}
	return tonumber(rollType) == rollTypes.RESERVED
end

local function isPlusSystemEnabled(ctx)
	return ctx and ctx.isPlusSystemEnabled and ctx.isPlusSystemEnabled() == true
end

local function isSortAscending(ctx)
	return ctx and ctx.isSortAscending and ctx.isSortAscending() == true
end

local function getSourceRollType(ctx, rollType)
	if ctx and type(ctx.getSourceRollType) == "function" then
		return ctx.getSourceRollType()
	end
	return rollType
end

-- ----- Public methods ----- --
function Strategies.GetStrategy(ctx, rollType)
	ctx = ctx or {}

	local id = STRATEGY_NORMAL
	local state = ctx.state
	local sourceRollType = getSourceRollType(ctx, rollType)

	if ctx.isRaidRollStrategy and ctx.isRaidRollStrategy() == true then
		id = STRATEGY_RAID_ROLL
	elseif state and state.tieReroll then
		id = STRATEGY_TIE
	elseif isReservedRoll(ctx, rollType) then
		id = STRATEGY_RESERVED
	end

	return {
		id = id,
		sourceRollType = sourceRollType,
		wantLow = isSortAscending(ctx),
		usePlus = isPlusSystemEnabled(ctx)
			and (id == STRATEGY_RESERVED or (id == STRATEGY_TIE and isReservedRoll(ctx, sourceRollType))),
	}
end

function Strategies.GetBucketPriority(strategy, bucket)
	if bucket == "INELIGIBLE" then
		return 99
	end
	if strategy and strategy.id == STRATEGY_RESERVED then
		if bucket == "SR" then
			return 1
		end
		return 2
	end
	return 1
end

function Strategies.ShouldUsePlus(strategy, itemId)
	return strategy and strategy.usePlus == true and itemId ~= nil
end

function Strategies.GetResponsePlus(strategy, itemId, response, plusGetter)
	if not Strategies.ShouldUsePlus(strategy, itemId) then
		return 0
	end
	if not (response and response.bucket == "SR" and plusGetter) then
		return 0
	end
	return tonumber(plusGetter(response.name)) or 0
end

function Strategies.CompareEntries(strategy, a, b)
	if a.bucketPriority ~= b.bucketPriority then
		return a.bucketPriority < b.bucketPriority
	end

	if strategy and strategy.usePlus == true and a.bucket == "SR" and b.bucket == "SR" and a.plus ~= b.plus then
		return (tonumber(a.plus) or 0) > (tonumber(b.plus) or 0)
	end

	if a.roll ~= b.roll then
		return strategy and strategy.wantLow == true and (a.roll < b.roll) or (a.roll > b.roll)
	end

	return tostring(a.name) < tostring(b.name)
end

function Strategies.AreEntriesTied(strategy, a, b)
	if not (a and b) then
		return false
	end
	if a.bucketPriority ~= b.bucketPriority or a.bucket ~= b.bucket then
		return false
	end
	if strategy and strategy.usePlus == true and a.bucket == "SR" and a.plus ~= b.plus then
		return false
	end
	return a.roll ~= nil and a.roll == b.roll
end

local registry = feature.ModuleRegistry
if type(registry) == "table" and type(registry.AddModule) == "function" and type(registry.SetLoaded) == "function" then
	registry.AddModule("Services/Rolls/Strategies", {
		deps = {
			"Init",
			"Modules/ModuleRegistry",
		},
	})
	registry.SetLoaded("Services/Rolls/Strategies")
end
