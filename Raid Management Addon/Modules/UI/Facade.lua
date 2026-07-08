-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: local feature = addon.Database.GetFeatureShared()
-- exports: addon.UI.Widgets
-- events: none

local addon = select(2, ...)
local feature = addon.Database.GetFeatureShared()

local Features = feature.Features

local type = type

local UI = feature.UI or {}
addon.UI = UI

local Widgets = UI.Widgets or {}
UI.Widgets = Widgets

-- ----- Internal state ----- --
Widgets._registry = Widgets._registry or {}

-- ----- Private helpers ----- --
local function getWidgetEntry(widgetId)
	local entry = Widgets._registry and Widgets._registry[widgetId]
	if type(entry) ~= "table" then
		return nil
	end
	entry.methods = entry.methods or {}
	entry.functions = entry.functions or {}
	return entry
end

local function ensureWidgetEntry(widgetId)
	local entry = getWidgetEntry(widgetId)
	if entry then
		return entry
	end
	entry = {
		methods = {},
		functions = {},
	}
	Widgets._registry[widgetId] = entry
	return entry
end

local function isWidgetEnabled(widgetId)
	if type(Features) ~= "table" then
		return true
	end
	if type(Features.IsEnabled) == "function" then
		return Features:IsEnabled(widgetId)
	end
	local flags = Features.WidgetFlags
	if type(flags) == "table" and flags[widgetId] ~= nil then
		return flags[widgetId] == true
	end
	return true
end

-- ----- Public methods ----- --
function Widgets.IsEnabled(widgetId)
	if type(widgetId) ~= "string" or widgetId == "" then
		return false
	end
	return isWidgetEnabled(widgetId)
end

function Widgets.IsRegistered(widgetId)
	if type(widgetId) ~= "string" or widgetId == "" then
		return false
	end
	local entry = getWidgetEntry(widgetId)
	return entry ~= nil and type(entry.api) == "table"
end

function Widgets.Register(widgetId, apiTable)
	if type(widgetId) ~= "string" or widgetId == "" then
		return false
	end
	if type(apiTable) ~= "table" then
		return false
	end
	if not Widgets.IsEnabled(widgetId) then
		Widgets._registry[widgetId] = nil
		return false
	end
	local entry = ensureWidgetEntry(widgetId)
	entry.api = apiTable
	return true
end

local function registerCallable(widgetId, methodName, fn, style)
	if type(widgetId) ~= "string" or widgetId == "" then
		return false
	end
	if type(methodName) ~= "string" or methodName == "" then
		return false
	end
	if type(fn) ~= "function" then
		return false
	end
	if style ~= "method" and style ~= "function" then
		return false
	end
	if not Widgets.IsEnabled(widgetId) then
		Widgets._registry[widgetId] = nil
		return false
	end
	local entry = getWidgetEntry(widgetId)
	if not entry or type(entry.api) ~= "table" then
		return false
	end
	local bucketName = style == "method" and "methods" or "functions"
	local otherBucketName = style == "method" and "functions" or "methods"
	entry[bucketName][methodName] = fn
	entry[otherBucketName][methodName] = nil
	return true
end

function Widgets.RegisterMethod(widgetId, methodName, fn)
	return registerCallable(widgetId, methodName, fn, "method")
end

function Widgets.RegisterFunction(widgetId, methodName, fn)
	return registerCallable(widgetId, methodName, fn, "function")
end

local function getWidgetFunction(widgetId, methodName, style)
	if type(methodName) ~= "string" or methodName == "" then
		return nil
	end
	if style ~= "method" and style ~= "function" then
		return nil
	end
	if not Widgets.IsEnabled(widgetId) then
		return nil
	end
	local entry = getWidgetEntry(widgetId)
	if not entry or type(entry.api) ~= "table" then
		return nil
	end
	local bucketName = style == "method" and "methods" or "functions"
	local fn = entry[bucketName] and entry[bucketName][methodName]
	if type(fn) ~= "function" then
		return nil
	end
	return fn, entry.api
end

function Widgets.CallMethod(widgetId, methodName, ...)
	local fn, api = getWidgetFunction(widgetId, methodName, "method")
	if not fn then
		return nil
	end
	return fn(api, ...)
end

function Widgets.CallFunction(widgetId, methodName, ...)
	local fn = getWidgetFunction(widgetId, methodName, "function")
	if not fn then
		return nil
	end
	return fn(...)
end

local registry = feature.ModuleRegistry
if type(registry) == "table" and type(registry.AddModule) == "function" and type(registry.SetLoaded) == "function" then
	registry.AddModule("Modules/UI/Facade", { deps = { "Init", "Modules/ModuleRegistry" } })
	registry.SetLoaded("Modules/UI/Facade")
end
