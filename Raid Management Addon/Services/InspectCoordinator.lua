-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: direct addon namespace bindings
-- exports: addon.Services.InspectCoordinator
-- events: listens wow.PLAYER_REGEN_ENABLED
-- notes: serializes RMA use of the client-global inspect target

local addon = select(2, ...)
local Services, Events, Bus, Timer = addon.Services, addon.Events, addon.Bus, addon.Timer
local GetTime = assert(_G.GetTime, "InspectCoordinator time API is not initialized")
local UnitAffectingCombat = assert(_G.UnitAffectingCombat, "InspectCoordinator combat API is not initialized")
local ClearInspectPlayer = assert(_G.ClearInspectPlayer, "InspectCoordinator clear API is not initialized")
local RegisterCallback = assert(Bus.RegisterCallback, "InspectCoordinator event listener is not initialized")
local ResolveWowForwardedName =
	assert(Events.ResolveWowForwardedName, "InspectCoordinator event resolver is not initialized")

local REQUEST_TIMEOUT_SECONDS = 8
local MIN_START_INTERVAL_SECONDS = 1.75
local MAX_QUEUED_REQUESTS = 40

Services.EnsureNamespace("InspectCoordinator")
local module = Services.InspectCoordinator
Timer.BindMixin(module, "InspectCoordinator")

local active
local queue = {}
local lastStartedAt
local drainHandle
local drain

local function now()
	return tonumber(GetTime()) or 0
end

local function cancelHandle(handle)
	if handle then
		module:CancelTimer(handle)
	end
end

local function finish(request, reason, clear)
	if request.finished then
		return
	end
	request.finished = true
	cancelHandle(request.deadlineHandle)
	request.deadlineHandle = nil
	if clear then
		pcall(ClearInspectPlayer)
	end
	if request.onFinish then
		pcall(request.onFinish, reason)
	end
end

local function schedule(delay, callback)
	local ok, handle = pcall(module.ScheduleTimer, module, callback, delay)
	if not ok or not handle then
		return nil
	end
	return handle
end

local function expire(request)
	if request.finished or active ~= request then
		return
	end
	active = nil
	finish(request, "timeout", true)
	drain()
end

local function start(request)
	active = request
	lastStartedAt = now()
	request.deadlineHandle = schedule(REQUEST_TIMEOUT_SECONDS, function()
		expire(request)
	end)
	if not request.deadlineHandle then
		request.startError = "timer_failed"
		active = nil
		finish(request, "timer_failed", false)
		drain()
		return
	end
	local ok = pcall(request.onStart)
	if not ok and active == request then
		active = nil
		finish(request, "start_failed", true)
		drain()
	end
end

drain = function()
	if active or UnitAffectingCombat("player") or drainHandle then
		return
	end
	while queue[1] and queue[1].finished do
		table.remove(queue, 1)
	end
	local request = queue[1]
	if not request then
		return
	end
	local wait = lastStartedAt and (MIN_START_INTERVAL_SECONDS - (now() - lastStartedAt)) or 0
	if wait > 0 then
		drainHandle = schedule(wait, function()
			drainHandle = nil
			drain()
		end)
		if not drainHandle then
			table.remove(queue, 1)
			request.startError = "timer_failed"
			finish(request, "timer_failed", false)
			drain()
		end
		return
	end
	table.remove(queue, 1)
	start(request)
end

function module:Request(owner, unit, guid, onStart, onFinish, category)
	if owner == nil or type(onStart) ~= "function" then
		return false, "invalid_request"
	end
	if #queue >= MAX_QUEUED_REQUESTS then
		return false, "queue_full"
	end
	local request = {
		owner = owner,
		category = category or owner,
		unit = unit,
		guid = guid,
		onStart = onStart,
		onFinish = onFinish,
	}
	queue[#queue + 1] = request
	drain()
	if request.startError then
		return false, request.startError
	end
	return true, active == request and "active" or "queued"
end

function module:IsOwner(owner, guid)
	return active ~= nil and active.owner == owner and (guid == nil or active.guid == guid)
end

function module:IsCategoryOwner(category)
	return active ~= nil and active.category == category
end

function module:Release(owner, guid)
	if not self:IsOwner(owner, guid) then
		return false
	end
	local request = active
	active = nil
	finish(request, "complete", true)
	drain()
	return true
end

function module:Cancel(owner)
	local cancelled = false
	for i = #queue, 1, -1 do
		if queue[i].owner == owner then
			local request = table.remove(queue, i)
			finish(request, "cancelled", false)
			cancelled = true
		end
	end
	if active and active.owner == owner then
		local request = active
		active = nil
		finish(request, "cancelled", true)
		cancelled = true
		drain()
	end
	return cancelled
end

local regenEvent = assert(ResolveWowForwardedName("PLAYER_REGEN_ENABLED"), "InspectCoordinator regen event missing")
RegisterCallback(regenEvent, function()
	drain()
end)
