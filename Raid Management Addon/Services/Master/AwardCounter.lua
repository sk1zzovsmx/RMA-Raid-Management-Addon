-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: direct addon namespace bindings
-- exports: addon.Services.Master.AwardCounter
-- events: none
-- notes: pure Master pending-award counter model helpers
local addon = select(2, ...)
local Master = addon.Database.EnsureServiceNamespace("Master")

local AwardCounter = Master.AwardCounter or {}
Master.AwardCounter = AwardCounter

local Item = addon.Item
local GetItemStringFromLink =
	assert(Item.GetItemStringFromLink, "Master award counter item-key resolver is not initialized")

local tinsert = table.insert
local tremove = table.remove
local tostring = tostring
local tonumber = tonumber
local type = type

-- ----- Internal state ----- --

-- ----- Private helpers ----- --
local function ensureState(state)
	if type(state) ~= "table" then
		state = {}
	end
	state.Awards = state.Awards or {}
	return state
end

local function getItemKey(itemLink)
	return GetItemStringFromLink(itemLink) or itemLink
end

local function cancelPending(pending, cancelTimer)
	if pending and pending.timeoutHandle and type(cancelTimer) == "function" then
		cancelTimer(pending.timeoutHandle)
		pending.timeoutHandle = nil
	end
end

-- ----- Public methods ----- --

function AwardCounter.EnsureState(state)
	return ensureState(state)
end

function AwardCounter.Queue(state, opts)
	state = ensureState(state)
	opts = opts or {}
	local pending = {
		itemLink = opts.itemLink,
		itemKey = getItemKey(opts.itemLink),
		itemIndex = tonumber(opts.itemIndex) or opts.itemIndex,
		playerName = opts.playerName,
		rollType = opts.rollType,
		rollValue = opts.rollValue,
		rollSessionId = opts.sessionId and tostring(opts.sessionId) or nil,
		itemCount = tonumber(opts.itemCount) or 1,
		counterApplied = false,
	}
	if pending.itemCount < 1 then
		pending.itemCount = 1
	end
	tinsert(state.Awards, pending)
	return pending
end

function AwardCounter.Remove(state, index, cancelTimer)
	state = ensureState(state)
	local awards = state.Awards
	local pending = awards[index]
	cancelPending(pending, cancelTimer)
	if pending then
		awards[index] = nil
		tremove(awards, index)
	end
	return pending
end

function AwardCounter.Clear(state, reason, cancelTimer)
	state = ensureState(state)
	local removed = {}
	for i = #state.Awards, 1, -1 do
		local pending = AwardCounter.Remove(state, i, cancelTimer)
		if pending then
			pending.clearReason = reason
			removed[#removed + 1] = pending
		end
	end
	return removed
end

function AwardCounter.FindBySlot(state, clearedSlot)
	state = ensureState(state)
	local slot = tonumber(clearedSlot)
	for i = 1, #state.Awards do
		local pending = state.Awards[i]
		if pending and pending.failed ~= true and pending.counterApplied ~= true then
			if not slot or tonumber(pending.itemIndex) == slot then
				return pending, i
			end
		end
	end
	return nil, nil
end

function AwardCounter.HasPending(state)
	state = ensureState(state)
	return state.Awards[1] ~= nil
end

function AwardCounter.Fail(state, reason, cancelTimer)
	state = ensureState(state)
	local failed = {}
	for i = #state.Awards, 1, -1 do
		local pending = AwardCounter.Remove(state, i, cancelTimer)
		if pending then
			pending.failed = true
			pending.failureReason = reason
			failed[#failed + 1] = pending
		end
	end
	return failed
end

function AwardCounter.Confirm(state, clearedSlot, cancelTimer)
	local pending, index = AwardCounter.FindBySlot(state, clearedSlot)
	if not pending then
		return nil
	end
	pending.counterApplied = true
	AwardCounter.Remove(state, index, cancelTimer)
	return pending
end
