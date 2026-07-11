-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: direct addon namespace bindings
-- exports: publish module APIs on addon.*
-- events: none

local addon = select(2, ...)
local type, tonumber, tostring = type, tonumber, tostring

local Sort = addon.Sort or {}
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
