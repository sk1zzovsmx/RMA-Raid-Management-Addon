-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: direct addon namespace bindings
-- exports: addon.Services.Master.PendingAwardExecution
-- events: none
-- notes: owns pending master-loot award execution, timers, and terminal effects
local addon = select(2, ...)
local Master = addon.Services.EnsureNamespace("Master")

local PendingAwardExecution = Master.PendingAwardExecution or {}
Master.PendingAwardExecution = PendingAwardExecution

local tinsert = table.insert
local tremove = table.remove
local tonumber = tonumber
local tostring = tostring
local type = type

local function requireFunction(deps, name)
	local value = deps[name]
	assert(type(value) == "function", "Pending award execution requires " .. name)
	return value
end

function PendingAwardExecution.Create(deps)
	deps = deps or {}
	local scheduleTimer = requireFunction(deps, "scheduleTimer")
	local cancelTimer = requireFunction(deps, "cancelTimer")
	local requestRefresh = requireFunction(deps, "requestRefresh")
	local warnFailure = requireFunction(deps, "warnFailure")
	local warnTimeout = requireFunction(deps, "warnTimeout")
	local confirmProvisional = requireFunction(deps, "confirmProvisional")
	local timeoutSeconds = tonumber(deps.timeoutSeconds) or 4
	local awards = {}
	local owner = {}

	local function remove(index)
		local pending = awards[index]
		if not pending then
			return nil
		end
		if pending.timeoutHandle then
			cancelTimer(pending.timeoutHandle)
			pending.timeoutHandle = nil
		end
		tremove(awards, index)
		return pending
	end

	local function find(clearedSlot)
		local slot = tonumber(clearedSlot)
		for i = 1, #awards do
			local pending = awards[i]
			if not slot or tonumber(pending.itemIndex) == slot then
				return pending, i
			end
		end
		return nil, nil
	end

	function owner:Queue(opts)
		opts = opts or {}
		local pending = {
			itemLink = opts.itemLink,
			itemIndex = tonumber(opts.itemIndex) or opts.itemIndex,
			playerName = opts.playerName,
			rollType = opts.rollType,
			rollValue = opts.rollValue,
			rollSessionId = opts.sessionId and tostring(opts.sessionId) or nil,
			transactionId = opts.transactionId and tostring(opts.transactionId) or nil,
			effect = assert(opts.effect, "Pending award execution requires an effect"),
		}
		tinsert(awards, pending)
		if timeoutSeconds > 0 then
			pending.timeoutHandle = scheduleTimer(function()
				for i = #awards, 1, -1 do
					if awards[i] == pending then
						remove(i)
						pending.effect:Fail("timeout")
						warnTimeout(timeoutSeconds, pending)
						requestRefresh()
						return
					end
			end
		end, timeoutSeconds)
		end
		return pending
	end

	function owner:HasPending()
		return awards[1] ~= nil
	end

	function owner:Fail(reason)
		local failed = false
		for i = #awards, 1, -1 do
			local pending = remove(i)
			if pending then
				failed = true
				pending.effect:Fail(reason)
				warnFailure(pending, reason)
			end
		end
		return failed
	end

	function owner:Confirm(clearedSlot)
		local pending, index = find(clearedSlot)
		if not pending then
			return false
		end
		remove(index)
		confirmProvisional(pending, clearedSlot)
		return pending.effect:Confirm()
	end

	return owner
end
