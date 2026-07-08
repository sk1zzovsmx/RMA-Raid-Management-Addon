-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: local feature = addon.Database.GetFeatureShared()
-- exports: publish module APIs on addon.*
-- events: none

local addon = select(2, ...)
local feature = addon.Database.GetFeatureShared()

local type, tonumber, tostring = type, tonumber, tostring

local Sort = feature.Sort or {}
addon.Sort = Sort

-- ----- Internal state ----- --

-- ----- Private helpers ----- --

-- ----- Public methods ----- --

function Sort.CompareValues(aValue, bValue, asc)
	if asc then
		return aValue < bValue
	end
	return aValue > bValue
end

function Sort.CompareNumbers(aValue, bValue, asc, fallback)
	local defaultValue = (fallback ~= nil) and fallback or 0
	local aNum = tonumber(aValue)
	if aNum == nil then
		aNum = defaultValue
	end
	local bNum = tonumber(bValue)
	if bNum == nil then
		bNum = defaultValue
	end
	return Sort.CompareValues(aNum, bNum, asc)
end

function Sort.GetLootSortName(itemName, itemLink, itemId)
	local name = itemName
	if (not name or name == "") and type(itemLink) == "string" then
		name = itemLink:match("|h%[(.-)%]|h")
	end
	if name and name ~= "" then
		return tostring(name)
	end
	local id = tonumber(itemId)
	if id then
		return ("Item %d"):format(id)
	end
	return "Item ?"
end

do
	local name = "Modules/Sort"
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
