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
		listenerList = {
			items = {},
			indexByToken = {},
			dispatchDepth = 0,
			dirty = false,
		}
		events[eventName] = listenerList
	end
	return listenerList
end

local function compactListenerList(listenerList)
	local compacted = {}
	local indexByToken = {}

	for i = 1, #listenerList.items do
		local row = listenerList.items[i]
		if row and not row.removed then
			compacted[#compacted + 1] = row
			indexByToken[row.token.t] = #compacted
		end
	end

	listenerList.items = compacted
	listenerList.indexByToken = indexByToken
	listenerList.dirty = false
end

-- ----- Public methods ----- --
function Bus.RegisterCallback(eventName, callback)
	if not eventName or type(callback) ~= "function" then
		error(L.StrCbErrUsage)
	end

	local listenerList = getListenerList(eventName)
	local token = { e = eventName, t = {} }
	local row = {
		token = token,
		callback = callback,
	}
	listenerList.items[#listenerList.items + 1] = row
	listenerList.indexByToken[token.t] = #listenerList.items

	return token
end

function Bus.UnregisterCallback(token)
	if not (token and token.e and token.t) then
		return false
	end

	local listenerList = events[token.e]
	if not listenerList then
		return false
	end

	local index = listenerList.indexByToken[token.t]
	if not index then
		return false
	end

	local row = listenerList.items[index]
	if row then
		row.removed = true
	end
	listenerList.indexByToken[token.t] = nil

	if listenerList.dispatchDepth > 0 then
		listenerList.dirty = true
	else
		compactListenerList(listenerList)
	end

	return true
end

function Bus.TriggerEvent(eventName, ...)
	local listenerList = events[eventName]
	if not listenerList then
		return
	end

	listenerList.dispatchDepth = listenerList.dispatchDepth + 1
	for i = 1, #listenerList.items do
		local row = listenerList.items[i]
		if row and not row.removed then
			local fn = row.callback
			local ok, err = pcall(fn, eventName, ...)
			if not ok then
				addon:error((Diag.E.LogUtilsCallbackExec):format(tostring(fn), tostring(eventName), tostring(err)))
			end
		end
	end
	listenerList.dispatchDepth = listenerList.dispatchDepth - 1

	if listenerList.dispatchDepth == 0 and listenerList.dirty then
		compactListenerList(listenerList)
	end
end
