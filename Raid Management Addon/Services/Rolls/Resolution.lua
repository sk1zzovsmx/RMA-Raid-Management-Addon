-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: direct addon namespace bindings
-- exports: addon.Services.Rolls._Resolution
-- events: none
-- notes: resolution and display helpers for rolls service

local addon = select(2, ...)
local L = addon.L
local Diag = addon.Diag
local Options = addon.Options
local Services = addon.Services

local tconcat = table.concat
local pairs = pairs
local tostring, tonumber = tostring, tonumber

-- ----- Internal state ----- --
addon.Services.EnsureNamespace("Rolls")
local Rolls = Services.Rolls
local module = Rolls
module._Resolution = module._Resolution or {}

local Resolution = module._Resolution
local Strategies = assert(module._Strategies, Diag.A.RollsStrategyHelpersNotInitialized)

-- ----- Private helpers ----- --
local isDebugEnabled = Options.IsDebugEnabled

local function assertContext(ctx)
	assert(type(ctx) == "table", Diag.A.RollsResolutionContextRequired)
	assert(type(ctx.state) == "table", Diag.A.RollsResolutionStateRequired)
	return ctx, ctx.state
end

local normalizeStrategy

local function getResponsePlus(ctx, itemId, response, plusGetter)
	local strategy = normalizeStrategy(ctx, type(ctx) == "table" and ctx.id and ctx or nil)
	return Strategies.GetResponsePlus(strategy, itemId, response, plusGetter)
end

normalizeStrategy = function(ctx, strategyOrUsePlus)
	if type(strategyOrUsePlus) == "table" and strategyOrUsePlus.id then
		return strategyOrUsePlus
	end

	local strategy = Strategies.GetStrategy(ctx or {}, nil)
	if strategyOrUsePlus == true then
		strategy.usePlus = true
	elseif strategyOrUsePlus == false then
		strategy.usePlus = false
	end
	return strategy
end

-- ----- Public methods ----- --
function Resolution.GetBucketPriority(ctx, bucket, rollType)
	local strategy = normalizeStrategy(ctx, type(ctx) == "table" and ctx.id and ctx or nil)
	if not (type(ctx) == "table" and ctx.id) then
		strategy = Strategies.GetStrategy(ctx or {}, rollType)
	end
	return Strategies.GetBucketPriority(strategy, bucket)
end

function Resolution.GetDisplayTier(ctx, response)
	local responseStatus = ctx.responseStatus or {}

	if response.status == responseStatus.ROLL and response.isEligible == true then
		return 1
	end
	if response.bestRoll ~= nil then
		return 2
	end
	if response.status == responseStatus.PASS then
		return 3
	end
	if response.status == responseStatus.CANCELLED then
		return 4
	end
	if response.status == responseStatus.ACTIVE then
		return 5
	end
	if response.status == responseStatus.TIMED_OUT then
		return 6
	end
	return 7
end

function Resolution.BuildResolvedEntries(ctx, itemId, currentRollType)
	local _, state = assertContext(ctx)
	local strategy = Strategies.GetStrategy(ctx, currentRollType)
	local plusGetter = itemId
			and function(name)
				return ctx.getPlusForItem and ctx.getPlusForItem(itemId, name) or 0
			end
		or nil
	local resolved = {}

	for name, response in pairs(state.responsesByPlayer) do
		if ctx.isSelectableRollResponse and ctx.isSelectableRollResponse(response) then
			local responseName = response.name or name
			resolved[#resolved + 1] = {
				name = responseName,
				bucket = response.bucket,
				bucketPriority = Strategies.GetBucketPriority(strategy, response.bucket),
				plus = Strategies.GetResponsePlus(strategy, itemId, {
					name = responseName,
					bucket = response.bucket,
				}, plusGetter),
				roll = tonumber(response.bestRoll) or 0,
				strategy = strategy.id,
			}
		end
	end

	table.sort(resolved, function(a, b)
		return Strategies.CompareEntries(strategy, a, b)
	end)

	return resolved, strategy, plusGetter
end

function Resolution.BuildTieGroups(ctx, resolvedEntries, strategyOrUsePlus)
	local strategy = normalizeStrategy(ctx, strategyOrUsePlus)
	local tieGroupByName = {}
	local groupId = 0
	local i = 1

	while i <= #resolvedEntries do
		local j = i
		while
			j < #resolvedEntries and Strategies.AreEntriesTied(strategy, resolvedEntries[j], resolvedEntries[j + 1])
		do
			j = j + 1
		end

		if j > i then
			groupId = groupId + 1
			for k = i, j do
				tieGroupByName[resolvedEntries[k].name] = groupId
			end
		end

		i = j + 1
	end

	return tieGroupByName
end

function Resolution.BuildResolution(ctx, resolvedEntries, strategyOrUsePlus)
	local strategy = normalizeStrategy(ctx, strategyOrUsePlus)
	local resolution = {
		autoWinners = {},
		tiedNames = {},
		requiresManualResolution = false,
		cutoff = ctx.getExpectedWinnerCount and ctx.getExpectedWinnerCount() or 1,
		topRollName = resolvedEntries[1] and resolvedEntries[1].name or nil,
	}
	local appliedCutoff = resolution.cutoff

	if appliedCutoff > #resolvedEntries then
		appliedCutoff = #resolvedEntries
	end
	if appliedCutoff < 0 then
		appliedCutoff = 0
	end
	if appliedCutoff == 0 then
		return resolution
	end

	local groupStart = appliedCutoff
	local groupEnd = appliedCutoff
	while
		groupStart > 1
		and Strategies.AreEntriesTied(strategy, resolvedEntries[groupStart - 1], resolvedEntries[appliedCutoff])
	do
		groupStart = groupStart - 1
	end
	while
		groupEnd < #resolvedEntries
		and Strategies.AreEntriesTied(strategy, resolvedEntries[groupEnd + 1], resolvedEntries[appliedCutoff])
	do
		groupEnd = groupEnd + 1
	end

	if groupEnd > appliedCutoff then
		resolution.requiresManualResolution = true
		for i = 1, groupStart - 1 do
			local entry = resolvedEntries[i]
			resolution.autoWinners[#resolution.autoWinners + 1] = {
				name = entry.name,
				roll = entry.roll,
			}
		end
		for i = groupStart, groupEnd do
			resolution.tiedNames[#resolution.tiedNames + 1] = resolvedEntries[i].name
		end
	else
		for i = 1, appliedCutoff do
			local entry = resolvedEntries[i]
			resolution.autoWinners[#resolution.autoWinners + 1] = {
				name = entry.name,
				roll = entry.roll,
			}
		end
	end

	if isDebugEnabled() then
		addon:debug(
			Diag.D.LogRollsResolution:format(
				tostring(resolution.topRollName),
				tconcat(resolution.tiedNames, ","),
				tonumber(resolution.cutoff) or 0,
				tostring(resolution.requiresManualResolution)
			)
		)
	end

	return resolution
end

function Resolution.BuildRowCounterText(ctx, itemId, response, currentRollType, plusGetter)
	local counterText = ""
	local rollTypes = ctx.rollTypes or addon.C.rollTypes
	local currentRaid

	if response.bucket == "SR" then
		if
			currentRollType == rollTypes.RESERVED
			and itemId
			and ctx.isPlusSystemEnabled
			and ctx.isPlusSystemEnabled()
		then
			local plus = getResponsePlus(ctx, itemId, response, plusGetter)
			if plus and plus > 0 then
				counterText = string.format("(P+%d)", plus)
			end
		else
			local allowed = tonumber(response.allowedRolls) or 0
			if allowed > 1 then
				local used = tonumber(response.usedRolls) or 0
				counterText = string.format("(%d/%d)", used, allowed)
			end
		end
	elseif
		ctx.shouldShowLootCounterDuringMSRoll
		and ctx.shouldShowLootCounterDuringMSRoll()
		and currentRollType == rollTypes.MAINSPEC
	then
		local raid = ctx.getRaidService and ctx.getRaidService() or nil
		currentRaid = ctx.getCurrentRaid and ctx.getCurrentRaid() or nil
		local count = raid and raid.GetPlayerCount and raid:GetPlayerCount(response.name, currentRaid) or 0
		if count and count > 0 then
			counterText = "+" .. count
		end
	end

	return counterText
end

function Resolution.BuildRowInfoText(ctx, response, isTied)
	local responseStatus = ctx.responseStatus or {}
	local reasonCodes = ctx.reasonCodes or {}

	if response and response.outOfFlowReason == reasonCodes.ROLL_LIMIT then
		return L.StrRollDuplicateTag
	end

	if response and response.isOutOfTime == true then
		return L.StrRollTimedOutTag
	end

	if isTied then
		return L.StrRollTieTag
	end

	if response.status == responseStatus.PASS then
		return L.StrRollPassTag
	elseif response.status == responseStatus.CANCELLED then
		return L.StrRollCancelledTag
	elseif response.status == responseStatus.TIMED_OUT then
		return L.StrRollTimedOutTag
	elseif response.status == responseStatus.INELIGIBLE then
		if response.reason == reasonCodes.NOT_IN_RAID then
			return L.StrRollOutTag
		end
		if response.reason == reasonCodes.REROLL_FILTERED then
			return L.StrRollRerollOnlyTag
		end
		if response.reason == reasonCodes.LOOT_BAN then
			return L.StrRollLootBanTag
		end
		return L.StrRollBlockedTag
	end

	return ""
end
