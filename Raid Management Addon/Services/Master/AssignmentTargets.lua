-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: local feature = addon.Database.GetFeatureShared()
-- exports: addon.Services.Master.AssignmentTargets
-- events: none
-- notes: pure Master assignment target row models
local addon = select(2, ...)
local feature = addon.Database.GetFeatureShared()

local Master = feature.EnsureServiceNamespace("Master")

local AssignmentTargets = Master.AssignmentTargets or {}
Master.AssignmentTargets = AssignmentTargets
local AssignmentHelpers = Master.AssignmentHelpers

local tinsert = table.insert
local pairs = pairs
local type = type
local tostring = tostring
local tonumber = tonumber

-- ----- Internal state ----- --

-- ----- Private helpers ----- --
-- ----- Public methods ----- --

function AssignmentTargets.BuildRows(groupedNames, classProvider)
	local result = {}
	if type(groupedNames) ~= "table" then
		return result
	end

	for group = 1, 8 do
		local names = groupedNames[group]
		if type(names) == "table" then
			for name in pairs(names) do
				tinsert(result, {
					name = name,
					displayName = name,
					group = group,
					class = AssignmentHelpers.ResolveClass(classProvider, name),
				})
			end
		end
	end

	table.sort(result, function(a, b)
		if a.group == b.group then
			return tostring(a.name or "") < tostring(b.name or "")
		end
		return (tonumber(a.group) or 0) < (tonumber(b.group) or 0)
	end)
	return result
end

local registry = feature.ModuleRegistry
if type(registry) == "table" and type(registry.AddModule) == "function" and type(registry.SetLoaded) == "function" then
	registry.AddModule("Services/Master/AssignmentTargets", {
		deps = {
			"Init",
			"Modules/ModuleRegistry",
			"Services/Master/AssignmentHelpers",
		},
	})
	registry.SetLoaded("Services/Master/AssignmentTargets")
end
