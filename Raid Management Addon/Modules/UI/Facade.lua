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

local SELF_METHODS = {
	ApplyMasterLootPreset = true,
	AttachToMaster = true,
	Default = true,
	EnsureUI = true,
	HideImport = true,
	RequestLoggerMaintenance = true,
	RequestLoggerSyncPanelAction = true,
	RequestRaidWarningPanelAction = true,
	RequestSpammerPanelAction = true,
	Show = true,
	Toggle = true,
	ToggleImport = true,
}

-- ----- Private helpers ----- --
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
	local api = Widgets._registry and Widgets._registry[widgetId]
	return type(api) == "table"
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
	Widgets._registry[widgetId] = apiTable
	return true
end

function Widgets.Call(widgetId, methodName, ...)
	if not Widgets.IsEnabled(widgetId) then
		return nil
	end
	local api = Widgets._registry and Widgets._registry[widgetId]
	if type(api) ~= "table" then
		return nil
	end
	local fn = api[methodName]
	if type(fn) ~= "function" then
		return nil
	end
	if SELF_METHODS[methodName] == true then
		return fn(api, ...)
	end
	return fn(...)
end

local registry = feature.ModuleRegistry
if type(registry) == "table" and type(registry.AddModule) == "function" and type(registry.SetLoaded) == "function" then
	registry.AddModule("Modules/UI/Facade", { deps = { "Init", "Modules/ModuleRegistry" } })
	registry.SetLoaded("Modules/UI/Facade")
end
