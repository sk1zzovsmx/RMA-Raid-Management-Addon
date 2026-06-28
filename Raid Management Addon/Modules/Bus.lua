-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: local feature = addon.Database.GetFeatureShared()
-- exports: publish module APIs on addon.*
-- events: owns addon.Bus callback registration and dispatch

local addon = select(2, ...)
local feature = addon.Database.GetFeatureShared()

local L = feature.L
local Diag = feature.Diag

local type, pairs, pcall, tostring = type, pairs, pcall, tostring

local Bus = feature.Bus or {}
addon.Bus = Bus

-- ----- Internal state ----- --
local events = Bus._events or {}
Bus._events = events

-- ----- Private helpers ----- --
-- ----- Public methods ----- --
function Bus.RegisterCallback(eventName, callback)
    if not eventName or type(callback) ~= "function" then
        error(L.StrCbErrUsage)
    end

    local listeners = events[eventName]
    if not listeners then
        listeners = {}
        events[eventName] = listeners
    end

    local token = {}
    listeners[token] = callback

    return { e = eventName, t = token }
end

-- Reusable dispatch buffers keyed by nesting depth to keep nested TriggerEvent()
-- calls isolated while still avoiding per-fire table allocation.
local dispatchStack = {}
local dispatchDepth = 0

function Bus.TriggerEvent(eventName, ...)
    local listeners = events[eventName]
    if not listeners then
        return
    end

    local dispatchBuf
    local dispatchCount = 0
    local depth

    dispatchDepth = dispatchDepth + 1
    depth = dispatchDepth
    dispatchBuf = dispatchStack[depth]
    if not dispatchBuf then
        dispatchBuf = {}
        dispatchStack[depth] = dispatchBuf
    end

    for token in pairs(listeners) do
        dispatchCount = dispatchCount + 1
        dispatchBuf[dispatchCount] = token
    end

    for i = 1, dispatchCount do
        local token = dispatchBuf[i]
        dispatchBuf[i] = nil
        local fn = listeners[token]
        if fn then
            local ok, err = pcall(fn, eventName, ...)
            if not ok then
                addon:error((Diag.E.LogUtilsCallbackExec):format(tostring(fn), tostring(eventName), tostring(err)))
            end
        end
    end

    dispatchDepth = depth - 1
end

local registry = feature.ModuleRegistry
if registry then
    registry.AddModule("Modules/Bus", { deps = { "Init", "Modules/ModuleRegistry" } })
    registry.SetLoaded("Modules/Bus")
end

