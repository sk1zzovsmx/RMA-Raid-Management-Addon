-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: direct addon namespace bindings
-- exports: addon.Services.Rolls._History
-- events: emits AddRoll via addon.Bus
-- notes: raw roll history and tracker helpers for rolls service

local addon = select(2, ...)
local Diag = addon.Diag
local Events = addon.Events
local Bus = addon.Bus
local Options = addon.Options
local Services = addon.Services
local InternalEvents = assert(Events.Internal, "Roll history internal events are not initialized")
local TriggerEvent = assert(Bus.TriggerEvent, "Roll history event publisher is not initialized")
local AddRollEvent = assert(InternalEvents.AddRoll, "Roll history add-roll event is not initialized")

local rollTypes = addon.C.rollTypes
local twipe = table.wipe
local tostring, tonumber = tostring, tonumber

-- ----- Internal state ----- --
addon.Services.EnsureNamespace("Rolls")
local Rolls = Services.Rolls
local module = Rolls
module._History = module._History or {}

local History = module._History

-- ----- Private helpers ----- --
local isDebugEnabled = Options.IsDebugEnabled

local function assertContext(ctx)
	assert(type(ctx) == "table", "Rolls history context is required")
	assert(type(ctx.state) == "table", "Rolls history state is required")
	assert(type(ctx.lootState) == "table", "Rolls history loot state is required")
	return ctx, ctx.state, ctx.lootState
end

-- ----- Public methods ----- --
function History.GetAllowedRolls(ctx, itemId, name)
	if not itemId or not name then
		return 1
	end
	if not (ctx.getActiveRollType and ctx.getActiveRollType() == rollTypes.RESERVED) then
		return 1
	end

	local reserves = ctx.getReserveCountForItem and ctx.getReserveCountForItem(itemId, name) or 0
	return (reserves and reserves > 0) and reserves or 1
end

function History.GetLocalPlayerRollCount(ctx, itemId)
	local _, state = assertContext(ctx)

	if not itemId then
		return 0
	end
	return tonumber(state.playerCounts[itemId]) or 0
end

function History.IncrementLocalPlayerRollCount(ctx, itemId)
	local _, state = assertContext(ctx)

	if not itemId then
		return 0
	end
	state.playerCounts[itemId] = (tonumber(state.playerCounts[itemId]) or 0) + 1
	return state.playerCounts[itemId]
end

function History.UpdateLocalRollState(ctx, itemId, name)
	local _, state = assertContext(ctx)
	local allowed
	local used

	if not itemId or not name then
		state.rolled = false
		return false
	end

	allowed = History.GetAllowedRolls(ctx, itemId, name)
	used = History.GetLocalPlayerRollCount(ctx, itemId)
	state.rolled = used >= allowed
	return state.rolled
end

function History.AcquireItemTracker(ctx, itemId)
	local _, state = assertContext(ctx)
	local tracker = state.itemCounts

	if type(tracker) ~= "table" then
		tracker = {}
		state.itemCounts = tracker
	end
	if not itemId then
		return {}
	end
	if not tracker[itemId] then
		tracker[itemId] = ctx.newItemCounts and ctx.newItemCounts() or {}
	end
	return tracker[itemId]
end

function History.ClearRollEntries(ctx)
	local _, state = assertContext(ctx)

	for i = 1, state.count do
		local entry = state.rolls[i]
		if entry then
			twipe(entry)
		end
	end
	twipe(state.rolls)
	twipe(state.playerCounts)
	if ctx.delItemCounts then
		ctx.delItemCounts(state.itemCounts, true)
	end

	state.rolls = {}
	state.playerCounts = {}
	state.itemCounts = ctx.newItemCounts and ctx.newItemCounts() or {}
	state.count = 0
end

function History.AddRoll(ctx, name, roll, itemId, expectedTracker, expectedCount)
	local _, state, lootState = assertContext(ctx)
	local tracker = History.AcquireItemTracker(ctx, itemId)

	roll = tonumber(roll)
	if not roll then
		return false
	end
	if expectedTracker ~= nil then
		if tracker ~= expectedTracker or (tonumber(tracker[name]) or 0) ~= (tonumber(expectedCount) or 0) then
			return false
		end
	end
	state.count = state.count + 1
	lootState.rollsCount = (tonumber(lootState.rollsCount) or 0) + 1

	state.rolls[state.count] = {
		name = name,
		roll = roll,
		itemId = itemId,
	}

	if isDebugEnabled() then
		addon:debug(Diag.D.LogRollsAddEntry:format(name, roll, tostring(itemId)))
	end
	if itemId then
		tracker[name] = (tracker[name] or 0) + 1
	end
	TriggerEvent(AddRollEvent, name, roll)
	return true
end

function History.GetRolls(ctx)
	local _, state = assertContext(ctx)
	return state.rolls
end

function History.GetHighestRoll(ctx, name)
	local _, state, lootState = assertContext(ctx)
	local winnerName = name or (ctx.getCurrentWinner and ctx.getCurrentWinner()) or lootState.winner
	local responseBestRoll
	local wantLow
	local bestRoll = nil
	local sessionItemId

	if not winnerName then
		return 0
	end

	responseBestRoll = ctx.getResponseBestRoll and ctx.getResponseBestRoll(winnerName) or nil
	if responseBestRoll ~= nil then
		return tonumber(responseBestRoll) or 0
	end

	wantLow = ctx.isSortAscending and ctx.isSortAscending() or false
	sessionItemId = ctx.getCurrentRollItemID and ctx.getCurrentRollItemID() or nil

	for i = 1, state.count do
		local entry = state.rolls[i]
		if entry and entry.name == winnerName then
			if (not sessionItemId) or not entry.itemId or (entry.itemId == sessionItemId) then
				if bestRoll == nil then
					bestRoll = entry.roll
				elseif wantLow and entry.roll < bestRoll then
					bestRoll = entry.roll
				elseif (not wantLow) and entry.roll > bestRoll then
					bestRoll = entry.roll
				end
			end
		end
	end

	return bestRoll or 0
end
