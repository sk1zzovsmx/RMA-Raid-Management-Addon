-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: direct addon namespace bindings
-- exports: addon.Services.Spammer.Runtime
-- events: owns the bounded LFM delivery lifecycle
local addon = select(2, ...)
local L = addon.L
local Services = addon.Services
local Timer = addon.Timer

addon.Services.EnsureNamespace("Spammer", "Runtime")
local Runtime = Services.Spammer.Runtime or {}
Services.Spammer.Runtime = Runtime
Timer.BindMixin(Runtime, "SpammerRuntime")

local MAX_ATTEMPTS = 30
local MAX_RUNTIME_SECONDS = 1800
local MIN_INTERVAL_SECONDS = 1

local state = {
	ticking = false,
	paused = false,
	countdownRemaining = 0,
	runElapsedSeconds = 0,
	attempts = 0,
	messagesSent = 0,
	durationSeconds = 60,
	output = "",
	channels = {},
	ticker = nil,
	generation = 0,
	queueIndex = 0,
	nextCycleAt = 60,
}
local callbacks = {}

local function copyChannels(source)
	local result = {}
	if type(source) == "table" then
		for i = 1, #source do
			result[#result + 1] = source[i]
		end
	end
	return result
end

local function snapshot()
	return {
		ticking = state.ticking,
		paused = state.paused,
		countdownRemaining = state.countdownRemaining,
		runElapsedSeconds = state.runElapsedSeconds,
		attempts = state.attempts,
		messagesSent = state.messagesSent,
		durationSeconds = state.durationSeconds,
		output = state.output,
		channels = copyChannels(state.channels),
	}
end

local function cancelTicker()
	if state.ticker then
		Runtime:CancelTimer(state.ticker)
		state.ticker = nil
	end
end

local function reportCallbackFailure(callbackName)
	if L and L.WarnSpammerCallbackFailed then
		addon:warn(L.WarnSpammerCallbackFailed, callbackName)
	end
end

local function invokeCallback(callback, callbackName, ...)
	if type(callback) ~= "function" then
		return true
	end
	local ok = pcall(callback, ...)
	if not ok then
		reportCallbackFailure(callbackName)
	end
	return ok
end

local function notifyTick()
	invokeCallback(callbacks.onTick, "onTick", snapshot())
end

local function finish(reason)
	if not state.ticking then
		return
	end
	local terminal = callbacks.onTerminal
	state.ticking, state.paused = false, false
	state.generation = state.generation + 1
	cancelTicker()
	callbacks = {}
	invokeCallback(terminal, "onTerminal", reason, snapshot())
end

local function normalizeDuration(value)
	local duration = tonumber(value) or 60
	if duration < MIN_INTERVAL_SECONDS then
		duration = MIN_INTERVAL_SECONDS
	end
	return math.floor(duration)
end

local function tick(generation)
	if generation ~= state.generation or not state.ticking or state.paused then
		return
	end
	state.runElapsedSeconds = state.runElapsedSeconds + 1
	if state.runElapsedSeconds >= MAX_RUNTIME_SECONDS then
		finish("duration_limit")
		return
	end

	if state.queueIndex == 0 and state.runElapsedSeconds >= state.nextCycleAt then
		state.queueIndex = 1
		state.nextCycleAt = state.runElapsedSeconds + state.durationSeconds
	end
	state.countdownRemaining = math.max(0, state.nextCycleAt - state.runElapsedSeconds)

	if state.queueIndex > 0 then
		if state.attempts >= MAX_ATTEMPTS then
			finish("message_limit")
			return
		end
		local destination = state.channels[state.queueIndex]
		local runGeneration = state.generation
		state.attempts = state.attempts + 1
		local callOk, ok, failureReason = pcall(callbacks.sendFn, state.output, destination)
		if runGeneration ~= state.generation or generation ~= state.generation or not state.ticking then
			return
		end
		if not callOk or ok ~= true then
			finish(callOk and (failureReason or "send_failed") or "send_failed")
			return
		end
		state.messagesSent = state.messagesSent + 1
		state.queueIndex = state.queueIndex + 1
		if state.queueIndex > #state.channels then
			state.queueIndex = 0
		end
		if state.attempts >= MAX_ATTEMPTS then
			finish("message_limit")
			return
		end
	end
	notifyTick()
end

function Runtime:GetState()
	return snapshot()
end

function Runtime:Start(config)
	config = type(config) == "table" and config or {}
	local sendFn = config.sendFn
	if type(sendFn) ~= "function" then
		local Chat = Services.Chat
		if Chat and type(Chat.SendSpamOutput) == "function" then
			sendFn = function(output, destination)
				local destinations = destination and { destination } or {}
				return Chat:SendSpamOutput(output, destinations)
			end
		else
			return false, "missing_transport"
		end
	end
	local channels = copyChannels(config.channels)
	if #channels == 0 then
		channels[1] = false
	end

	cancelTicker()
	local previousGeneration = state.generation
	state.generation = previousGeneration + 1
	local generation = state.generation
	local ok, ticker = pcall(self.ScheduleRepeatingTimer, self, function()
		tick(generation)
	end, 1)
	if not ok or not ticker then
		state.generation = previousGeneration + 2
		state.ticking, state.paused, state.ticker = false, false, nil
		callbacks = {}
		return false, "scheduler_failed"
	end

	local resume = state.ticking and state.paused and config.resetRun == false
	state.ticker = ticker
	if not resume then
		state.durationSeconds = normalizeDuration(config.duration)
		state.output = tostring(config.output or "")
		state.channels = channels
	end
	state.queueIndex = 0
	if config.resetRun ~= false then
		state.runElapsedSeconds, state.attempts, state.messagesSent = 0, 0, 0
	end
	if config.resetCountdown ~= false or state.countdownRemaining <= 0 then
		state.countdownRemaining = state.durationSeconds
		state.nextCycleAt = state.runElapsedSeconds + state.durationSeconds
	end
	callbacks = { sendFn = sendFn, onTick = config.onTick, onTerminal = config.onTerminal or config.onAutoStop }
	state.ticking, state.paused = true, false
	notifyTick()
	return true, snapshot()
end

function Runtime:Stop(resetCountdown, resetRun)
	state.generation = state.generation + 1
	cancelTicker()
	state.ticking, state.paused, state.queueIndex = false, false, 0
	if resetCountdown then
		state.countdownRemaining = 0
	end
	if resetRun then
		state.runElapsedSeconds, state.attempts, state.messagesSent = 0, 0, 0
	end
	callbacks = {}
	return snapshot()
end

function Runtime:Pause()
	if not state.ticking or state.paused then
		return false, snapshot()
	end
	state.generation = state.generation + 1
	cancelTicker()
	state.paused = true
	notifyTick()
	return true, snapshot()
end
