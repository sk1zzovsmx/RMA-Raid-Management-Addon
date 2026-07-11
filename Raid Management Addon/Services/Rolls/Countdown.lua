-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: direct addon namespace bindings
-- exports: addon.Services.Rolls._Countdown
-- events: announces countdown ticks through Services/Chat
-- notes: countdown runtime helpers for rolls service

local addon = select(2, ...)
local L = addon.L
local Services = addon.Services
local Timer = addon.Timer

-- ----- Internal state ----- --
addon.Database.EnsureServiceNamespace("Rolls")
local Rolls = Services.Rolls
local module = Rolls
module._Countdown = module._Countdown or {}

local Countdown = module._Countdown

-- Countdown owns both runtime timers: the announcement ticker and the close timer.
Timer.BindMixin(Countdown, "Rolls.Countdown")

local Chat = Services.Chat
local tonumber = tonumber

-- ----- Private helpers ----- --
local function shouldAnnounceTick(remaining, duration)
	if remaining >= duration then
		return true
	end
	if remaining >= 10 then
		return (remaining % 10 == 0)
	end
	if remaining > 0 and remaining < 10 and remaining % 7 == 0 then
		return true
	end
	if remaining > 0 and remaining >= 5 and remaining % 5 == 0 then
		return true
	end
	return remaining > 0 and remaining <= 3
end

-- ----- Public methods ----- --
function Countdown.Stop(state)
	if state.countdownTicker then
		Countdown:CancelTimer(state.countdownTicker)
	end
	if state.countdownEndTimer then
		Countdown:CancelTimer(state.countdownEndTimer)
	end
	state.countdownTicker = nil
	state.countdownEndTimer = nil
	state.countdownRunning = false
	state.countdownRemaining = 0
end

function Countdown.Start(state, duration, onTick, onComplete)
	Countdown.Stop(state)

	local countdownDuration = tonumber(duration) or 0
	if countdownDuration <= 0 then
		return false
	end

	state.countdownRunning = true
	state.countdownDuration = countdownDuration
	state.countdownRemaining = countdownDuration
	state.countdownExpired = false

	if shouldAnnounceTick(state.countdownRemaining, countdownDuration) then
		Chat:Announce(L.ChatCountdownTic:format(state.countdownRemaining))
	end
	if type(onTick) == "function" then
		onTick(state.countdownRemaining, countdownDuration)
	end

	state.countdownTicker = Countdown:ScheduleRepeatingTimer(function()
		if not state.countdownRunning then
			return
		end
		state.countdownRemaining = state.countdownRemaining - 1
		if state.countdownRemaining > 0 then
			if shouldAnnounceTick(state.countdownRemaining, countdownDuration) then
				Chat:Announce(L.ChatCountdownTic:format(state.countdownRemaining))
			end
			if type(onTick) == "function" then
				onTick(state.countdownRemaining, countdownDuration)
			end
		end
	end, 1)

	state.countdownEndTimer = Countdown:ScheduleTimer(function()
		if not state.countdownRunning then
			return
		end
		Countdown.Stop(state)
		state.countdownExpired = true
		Chat:Announce(L.ChatCountdownEnd)
		if type(onComplete) == "function" then
			onComplete()
		end
	end, countdownDuration)

	return true
end

function Countdown.IsRunning(state)
	return state.countdownRunning == true
end
