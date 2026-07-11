-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: direct addon namespace bindings
-- exports: publish module APIs on addon.*
-- events: owns addon.Bus callback registration and dispatch

local addon = select(2, ...)
local L = addon.L
local Diag = addon.Diag

local type, pcall, tostring = type, pcall, tostring

local Bus = addon.Bus or {}
addon.Bus = Bus

-- ----- Internal state ----- --
local events = Bus._events or {}
Bus._events = events

-- ----- Private helpers ----- --
local function getListenerList(eventName)
	local listenerList = events[eventName]
	if not listenerList then
		listenerList = {}
		events[eventName] = listenerList
	end
	return listenerList
end

-- ----- Public methods ----- --
function Bus.RegisterCallback(eventName, callback)
	if not eventName or type(callback) ~= "function" then
		error(L.StrCbErrUsage)
	end

	local listenerList = getListenerList(eventName)
	listenerList[#listenerList + 1] = callback
end

function Bus.TriggerEvent(eventName, ...)
	local listenerList = events[eventName]
	if not listenerList then
		return
	end

	for i = 1, #listenerList do
		local fn = listenerList[i]
		local ok, err = pcall(fn, eventName, ...)
		if not ok then
			addon:error((Diag.E.LogUtilsCallbackExec):format(tostring(fn), tostring(eventName), tostring(err)))
		end
	end
end
