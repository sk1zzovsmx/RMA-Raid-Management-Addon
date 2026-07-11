-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...); LibStub("LibCompat-1.0")
-- shared: direct addon namespace bindings
-- exports: addon.Timer (mixin: ScheduleTimer/CancelTimer; static: RefreshStats/ShowStats)
-- events: none (purely a timer mixin; does not emit Bus events)
local addon = select(2, ...)
local L = addon.L
local DebugEntryPoint = assert(addon.EntryPoints.Debug, "Timer debug entrypoint is not initialized")

local type, pairs, select, rawget, rawset, tostring, tonumber = type, pairs, select, rawget, rawset, tostring, tonumber
local pcall, error = pcall, error
local format = string.format
local tsort = table.sort
local GetTime = assert(_G.GetTime, "RMA Timer: GetTime API is not initialized")

local LibStub = assert(_G.LibStub, "RMA Timer: LibStub API is not initialized")
local libcompat = LibStub("LibCompat-1.0", true)
assert(libcompat, "RMA Timer: LibCompat-1.0 missing")

local lcNewTimer = libcompat.NewTimer
local lcNewTicker = libcompat.NewTicker
local lcCancelTimer = libcompat.CancelTimer

local Timer = addon.Timer or {}
addon.Timer = Timer

-- ----- Internal state ----- --
local stats = {
	created = 0,
	cancelled = 0,
	completed = 0,
	active = 0,
	maxActive = 0,
}
Timer._stats = stats
Timer._targets = Timer._targets or {}

local mixin = {}

-- ----- Private helpers ----- --
local function now()
	return GetTime()
end

local function getState(self)
	local s = rawget(self, "_timerState")
	if not s then
		-- Embed should run before use, but keep a safe fallback state.
		s = { name = tostring(self), active = {}, count = 0, totalCreated = 0 }
		rawset(self, "_timerState", s)
	end
	return s
end

local function registerHandle(state, handle, kind, duration)
	state.active[handle] = { kind = kind, duration = duration, createdAt = now() }
	state.count = (state.count or 0) + 1
	state.totalCreated = (state.totalCreated or 0) + 1

	stats.created = stats.created + 1
	stats.active = stats.active + 1
	if stats.active > stats.maxActive then
		stats.maxActive = stats.active
	end
end

local function unregisterHandle(state, handle, reason)
	if not handle or not state.active[handle] then
		return false
	end
	state.active[handle] = nil
	if state.count and state.count > 0 then
		state.count = state.count - 1
	end
	if stats.active > 0 then
		stats.active = stats.active - 1
	end
	if reason == "cancel" then
		stats.cancelled = stats.cancelled + 1
	else
		stats.completed = stats.completed + 1
	end
	return true
end

local function invokeCallback(callback, args, n, targetName)
	local ok, err
	if args == nil then
		ok, err = pcall(callback)
	elseif n == 1 then
		ok, err = pcall(callback, args[1])
	elseif n == 2 then
		ok, err = pcall(callback, args[1], args[2])
	elseif n == 3 then
		ok, err = pcall(callback, args[1], args[2], args[3])
	else
		ok, err = pcall(callback, unpack(args, 1, n))
	end
	if not ok and addon and addon.error then
		addon:error(format("Timer[%s]: callback error: %s", tostring(targetName), tostring(err)))
	end
end

-- ----- Mixin methods ----- --
function mixin:ScheduleTimer(callback, delay, ...)
	if type(callback) ~= "function" then
		error("ScheduleTimer: callback must be a function", 2)
	end
	if type(delay) ~= "number" or delay < 0 then
		error("ScheduleTimer: delay must be a non-negative number", 2)
	end

	local state = getState(self)
	local n = select("#", ...)
	local args
	if n > 0 then
		args = { ... }
	end

	local handle
	local oneShotCallback = function()
		unregisterHandle(state, handle, "done")
		invokeCallback(callback, args, n, state.name)
	end

	handle = lcNewTimer(delay, oneShotCallback)
	if handle then
		registerHandle(state, handle, "timer", delay)
	end
	return handle
end

function mixin:ScheduleRepeatingTimer(callback, interval, ...)
	if type(callback) ~= "function" then
		error("ScheduleRepeatingTimer: callback must be a function", 2)
	end
	if type(interval) ~= "number" or interval <= 0 then
		error("ScheduleRepeatingTimer: interval must be a positive number", 2)
	end

	local state = getState(self)
	local n = select("#", ...)
	local args
	if n > 0 then
		args = { ... }
	end

	local handle
	local repeatingCallback = function(t)
		invokeCallback(callback, args, n, state.name)
		-- LibCompat decrements _iterations after the callback; 1 means last tick.
		if t and t._iterations == 1 then
			unregisterHandle(state, handle, "done")
		end
	end

	handle = lcNewTicker(interval, repeatingCallback)
	if handle then
		registerHandle(state, handle, "ticker", interval)
	end
	return handle
end

function mixin:CancelTimer(handle)
	if not handle then
		return false
	end
	local state = getState(self)
	if state.active[handle] then
		unregisterHandle(state, handle, "cancel")
		lcCancelTimer(handle, true)
		return true
	end
	return false
end

-- ----- Public methods ----- --
function Timer.BindMixin(target, name)
	if type(target) ~= "table" then
		error("Timer.BindMixin: target must be a table", 2)
	end
	if rawget(target, "ScheduleTimer") then
		return target
	end

	local stateName = (type(name) == "string" and name ~= "") and name or tostring(target)
	rawset(target, "_timerState", {
		name = stateName,
		active = {},
		count = 0,
		totalCreated = 0,
	})

	for methodName, fn in pairs(mixin) do
		rawset(target, methodName, fn)
	end

	Timer._targets[stateName] = target
	return target
end

function Timer.RefreshStats()
	stats.created = 0
	stats.cancelled = 0
	stats.completed = 0
	stats.maxActive = stats.active
	for _, target in pairs(Timer._targets) do
		local state = rawget(target, "_timerState")
		if state then
			state.totalCreated = state.count or 0
		end
	end
end

local function buildDumpRows()
	local rows = {}
	local idx = 0
	local nowT = now()
	for targetName, target in pairs(Timer._targets) do
		local state = rawget(target, "_timerState")
		if state then
			for _, info in pairs(state.active) do
				idx = idx + 1
				rows[idx] = {
					target = targetName,
					kind = info.kind or "?",
					age = nowT - (info.createdAt or nowT),
					duration = info.duration or 0,
				}
			end
		end
	end
	return rows
end

function Timer.ShowStats(sortBy)
	if not (addon and addon.info) then
		return
	end

	local rows = buildDumpRows()
	local key = "age"
	local k = tostring(sortBy or ""):lower()
	if k == "duration" or k == "dur" then
		key = "duration"
	elseif k == "target" or k == "name" then
		key = "target"
	end

	tsort(rows, function(a, b)
		local av, bv = a[key], b[key]
		if av == bv then
			return (a.age or 0) > (b.age or 0)
		end
		if type(av) == "string" then
			return tostring(av) < tostring(bv)
		end
		return (tonumber(av) or 0) > (tonumber(bv) or 0)
	end)

	addon:info(L.MsgTimerStatsSummary, stats.active, stats.maxActive, stats.created, stats.cancelled, stats.completed)

	local limit = 15
	if #rows < limit then
		limit = #rows
	end
	for i = 1, limit do
		local r = rows[i]
		addon:info(L.MsgTimerStatsRow, i, r.target, r.kind, r.age, r.duration)
	end

	addon:info(L.MsgTimerStatsTip)
end

DebugEntryPoint.RegisterCommand("timers", "timers [reset]", L.MsgTimerStatsTip, function(argument)
	if argument == "reset" then
		Timer.RefreshStats()
		addon:info(L.MsgTimerStatsReset)
		return
	end
	Timer.ShowStats(argument)
end)
