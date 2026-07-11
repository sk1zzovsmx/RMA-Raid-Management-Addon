-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: direct addon namespace bindings
-- exports: addon.Services.Master.Assignment
-- events: none
-- notes: pure Master assignment row models and policy
local addon = select(2, ...)
local Master = addon.Services.EnsureNamespace("Master")

local Assignment = Master.Assignment or {}
Master.Assignment = Assignment

local tinsert = table.insert
local pairs = pairs
local type = type
local tostring = tostring
local tonumber = tonumber

-- ----- Public methods ----- --

function Assignment.ResolveClass(classProvider, name)
	if type(classProvider) == "function" then
		return classProvider(name)
	end
	return nil
end

function Assignment.BuildCandidateRows(candidates, classProvider)
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
				class = Assignment.ResolveClass(classProvider, name),
			})
		end
	end
	return result
end

function Assignment.BuildTargetRows(groupedNames, classProvider)
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
					class = Assignment.ResolveClass(classProvider, name),
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
