-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: direct addon namespace bindings
-- exports: addon.Services.Master.AwardAttempt
-- events: none
-- notes: owns runtime-only Master award transition and terminal policy
local addon = select(2, ...)
local Master = addon.Services.EnsureNamespace("Master")

local AwardAttempt = Master.AwardAttempt or {}
Master.AwardAttempt = AwardAttempt

local type, pcall = type, pcall

local function copy(value, seen)
	local valueType = type(value)
	if valueType == "function" or valueType == "thread" or valueType == "userdata" then
		return nil
	end
	if valueType ~= "table" then
		return value
	end
	seen = seen or {}
	if seen[value] then
		return seen[value]
	end
	local result = {}
	seen[value] = result
	for key, child in pairs(value) do
		local copiedKey = copy(key, seen)
		local copiedChild = copy(child, seen)
		if copiedKey ~= nil and copiedChild ~= nil then
			result[copiedKey] = copiedChild
		end
	end
	return result
end

local function normalizeWinner(winner)
	if type(winner) ~= "string" then
		return winner
	end
	return winner:match("^%s*(.-)%s*$")
end

function AwardAttempt.CreateExecuting(opts)
	opts = opts or {}
	local normalizedWinner = normalizeWinner(opts.winnerName or opts.winner)
	local checkpoints = {}
	local transitioning = false
	local state = {
		transactionId = opts.transactionId,
		rollSessionId = opts.rollSessionId,
		itemKey = opts.itemKey,
		itemLink = opts.itemLink,
		winner = normalizedWinner,
		winnerName = normalizedWinner,
		source = copy(opts.source),
		state = "executing",
		failureReason = nil,
		executorContext = copy(opts.executorContext),
		checkpoints = {},
	}
	local instance = {}

	local function callbackResult(ok, result, reason, fallbackReason)
		if not ok then
			return nil, tostring(result)
		end
		if result ~= true then
			return nil, reason or fallbackReason
		end
		return true
	end

	local function setContext(context)
		if context ~= nil then
			state.executorContext = copy(context)
		end
	end

	function instance:RunCheckpoint(name, callback, ...)
		if type(name) ~= "string" or name == "" then
			return nil, "checkpoint_name_required"
		end
		if checkpoints[name] == true then
			return true
		end
		if state.state == "confirmed" or state.state == "failed" then
			return nil, "invalid award attempt checkpoint state"
		end
		if type(callback) ~= "function" then
			return nil, "checkpoint_callback_required"
		end
		local ok, result, reason = pcall(callback, ...)
		local accepted, rejectedReason = callbackResult(ok, result, reason, "checkpoint_rejected")
		if not accepted then
			return nil, rejectedReason
		end
		checkpoints[name] = true
		state.checkpoints[name] = true
		return true
	end

	function instance:Confirm(context)
		if transitioning then
			return nil, "award attempt transition in progress"
		end
		if state.state ~= "executing" and state.state ~= "uncertain" then
			return false, "invalid award attempt transition"
		end

		transitioning = true
		state.state = "confirming"
		state.failureReason = nil
		setContext(context)
		local accepted, rejectedReason = true, nil
		if type(opts.onConfirm) == "function" then
			local ok, result, reason = pcall(opts.onConfirm, copy(state), context)
			accepted, rejectedReason = callbackResult(ok, result, reason, "award confirmation callback rejected")
		end
		if accepted then
			state.state = "confirmed"
		else
			state.state = "uncertain"
			state.failureReason = rejectedReason
		end
		transitioning = false
		if not accepted then
			return nil, rejectedReason
		end
		return true
	end

	function instance:MarkUncertain(reason, context)
		if transitioning then
			return nil, "award attempt transition in progress"
		end
		if state.state ~= "executing" and state.state ~= "uncertain" then
			return false, "invalid award attempt transition"
		end
		state.state = "uncertain"
		state.failureReason = reason or state.failureReason or "award outcome uncertain"
		setContext(context)
		return true
	end

	function instance:Fail(reason, context)
		if transitioning then
			return nil, "award attempt transition in progress"
		end
		if state.state ~= "executing" and state.state ~= "uncertain" then
			return false, "invalid award attempt transition"
		end

		transitioning = true
		state.state = "failed"
		state.failureReason = reason
		setContext(context)
		local accepted, rejectedReason = true, nil
		if type(opts.onFail) == "function" then
			local ok, result, callbackReason = pcall(opts.onFail, reason, copy(state), context)
			accepted, rejectedReason = callbackResult(ok, result, callbackReason, "award failure callback rejected")
		end
		transitioning = false
		if not accepted then
			return nil, rejectedReason
		end
		return true
	end
	function instance:GetState()
		return copy(state)
	end

	return instance
end

return AwardAttempt
