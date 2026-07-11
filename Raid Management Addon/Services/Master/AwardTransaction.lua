-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: direct addon namespace bindings
-- exports: addon.Services.Master.AwardTransaction
-- events: none
-- notes: owns runtime-only Master award transition and terminal policy
local addon = select(2, ...)
local Master = addon.Services.EnsureNamespace("Master")

local AwardTransaction = Master.AwardTransaction or {}
Master.AwardTransaction = AwardTransaction

local type, pcall = type, pcall

local function copy(value, seen)
	if type(value) ~= "table" then
		return value
	end
	seen = seen or {}
	if seen[value] then
		return seen[value]
	end
	local result = {}
	seen[value] = result
	for key, child in pairs(value) do
		result[copy(key, seen)] = copy(child, seen)
	end
	return result
end

local function normalizeWinner(winner)
	if type(winner) ~= "string" then
		return winner
	end
	return winner:match("^%s*(.-)%s*$")
end

function AwardTransaction.CreateExecuting(opts)
	opts = opts or {}
	local normalizedWinner = normalizeWinner(opts.winnerName or opts.winner)
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
	}
	local instance = {}

	local function finish(terminalState, reason, context, callback)
		if state.state ~= "executing" then
			return false, "invalid award transaction transition"
		end
		local terminal = copy(state)
		terminal.state = terminalState
		terminal.failureReason = reason
		if context ~= nil then
			terminal.executorContext = copy(context)
		end
		if type(callback) == "function" then
			local callbackOk, result
			if terminalState == "failed" then
				callbackOk, result = pcall(callback, reason, copy(terminal), context)
			else
				callbackOk, result = pcall(callback, copy(terminal), context)
			end
			if not callbackOk or result == false then
				local label = terminalState == "confirmed" and "confirmation" or "failure"
				return false, callbackOk and ("award " .. label .. " callback rejected") or tostring(result)
			end
		end
		state = terminal
		return true
	end
	function instance:Confirm(context)
		return finish("confirmed", nil, context, opts.onConfirm)
	end
	function instance:Fail(reason, context)
		return finish("failed", reason, context, opts.onFail)
	end
	function instance:GetState()
		return copy(state)
	end

	return instance
end

return AwardTransaction
