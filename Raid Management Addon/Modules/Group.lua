-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...); WotLK group and unit APIs
-- shared: addon.Group
-- exports: group type/count and stable unit iteration
-- events: none
local addon = select(2, ...)
local Diag = addon.Diag
local _G = _G

local format = string.format
local GetNumRaidMembers = assert(_G.GetNumRaidMembers, Diag.A.RmaGroupRaidCountApiNotInitialized)
local GetNumPartyMembers = assert(_G.GetNumPartyMembers, Diag.A.RmaGroupPartyCountApiNotInitialized)
local UnitExists = assert(_G.UnitExists, Diag.A.RmaGroupUnitExistsApiNotInitialized)

local Group = addon.Group or {}
addon.Group = Group

function Group.GetNumMembers()
	local raidCount = GetNumRaidMembers()
	if raidCount > 0 then
		return raidCount
	end
	return GetNumPartyMembers()
end

function Group.GetTypeAndCount()
	local raidCount = GetNumRaidMembers()
	if raidCount > 0 then
		return "raid", 1, raidCount
	end
	local partyCount = GetNumPartyMembers()
	if partyCount > 0 then
		return "party", 0, partyCount
	end
	return nil, 0, 0
end

function Group.IterateUnits(excludePets)
	local units = {}
	local owners = {}
	local count = 0
	local raidCount = GetNumRaidMembers()
	if raidCount > 0 then
		for index = 1, raidCount do
			local unit = format("raid%d", index)
			if UnitExists(unit) then
				count = count + 1
				units[count] = unit
			end
			if not excludePets then
				local pet = format("raidpet%d", index)
				if UnitExists(pet) then
					count = count + 1
					units[count] = pet
					owners[count] = unit
				end
			end
		end
	else
		if UnitExists("player") then
			count = count + 1
			units[count] = "player"
		end
		if not excludePets and UnitExists("playerpet") then
			count = count + 1
			units[count] = "playerpet"
			owners[count] = "player"
		end
		local partyCount = GetNumPartyMembers()
		for index = 1, partyCount do
			local unit = format("party%d", index)
			if UnitExists(unit) then
				count = count + 1
				units[count] = unit
			end
			if not excludePets then
				local pet = format("partypet%d", index)
				if UnitExists(pet) then
					count = count + 1
					units[count] = pet
					owners[count] = unit
				end
			end
		end
	end

	local index = 0
	return function()
		index = index + 1
		return units[index], owners[index]
	end
end
