-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: local feature = addon.Database.GetFeatureShared()
-- exports: publish module APIs on addon.*
-- events: none

local addon = select(2, ...)
local feature = addon.Database.GetFeatureShared()

local type, pairs = type, pairs

local Features = feature.Features or {}
addon.Features = Features

-- ----- Internal state ----- --
Features.WidgetFlags = Features.WidgetFlags or {}
local defaultWidgetFlags = {
	Config = true,
	LootCounter = true,
	Reserves = true,
}

-- ----- Private helpers ----- --
local function applyDefaultProfile()
	local flags = Features.WidgetFlags

	for widgetId in pairs(flags) do
		flags[widgetId] = nil
	end
	for widgetId, enabled in pairs(defaultWidgetFlags) do
		flags[widgetId] = enabled == true
	end

	Features.Profile = "full"
end

-- ----- Public methods ----- --
function Features:IsEnabled(widgetId)
	if type(widgetId) ~= "string" or widgetId == "" then
		return false
	end

	local flag = self.WidgetFlags[widgetId]
	if flag == nil then
		return true
	end
	return flag == true
end

applyDefaultProfile()

do
	local name = "Modules/Features"
	local deps = { "Init" }
	local registry = feature.ModuleRegistry
	if registry then
		registry.AddModule(name, { deps = deps })
		registry.SetLoaded(name)
	else
		addon.ModuleRegistryPendingRegistrations = addon.ModuleRegistryPendingRegistrations or {}
		local pending = addon.ModuleRegistryPendingRegistrations
		pending[#pending + 1] = { name = name, deps = deps, loaded = true }
	end
end
