-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: local feature = addon.Database.GetFeatureShared()
-- exports: addon.Services.Master.AssignmentCandidates
-- events: none
-- notes: pure Master assignment candidate row models
local addon = select(2, ...)
local feature = addon.Database.GetFeatureShared()

local Master = feature.EnsureServiceNamespace("Master")

local AssignmentCandidates = Master.AssignmentCandidates or {}
Master.AssignmentCandidates = AssignmentCandidates
local AssignmentHelpers = Master.AssignmentHelpers

local tinsert = table.insert
local type = type

-- ----- Internal state ----- --

-- ----- Private helpers ----- --
-- ----- Public methods ----- --

function AssignmentCandidates.BuildRows(candidates, classProvider)
	local result = {}
	if type(candidates) ~= "table" then
		return result
	end

	for i = 1, #candidates do
		local candidate = candidates[i]
		local name = candidate and candidate.name
		if name and name ~= "" then
			tinsert(result, {
				name = name,
				displayName = name,
				index = candidate.index or i,
				class = AssignmentHelpers.ResolveClass(classProvider, name),
			})
		end
	end
	return result
end

local registry = feature.ModuleRegistry
if type(registry) == "table" and type(registry.AddModule) == "function" and type(registry.SetLoaded) == "function" then
	registry.AddModule("Services/Master/AssignmentCandidates", {
		deps = {
			"Init",
			"Modules/ModuleRegistry",
			"Services/Master/AssignmentHelpers",
		},
	})
	registry.SetLoaded("Services/Master/AssignmentCandidates")
end
