-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: direct addon namespace bindings
-- exports: publish module APIs on addon.*
-- events: none
local addon = select(2, ...)
local Database = addon.Database
local L = addon.L
local Services = addon.Services

local select = select
local tonumber = tonumber
local tostring = tostring
local type = type

local GetLootMethod = assert(_G.GetLootMethod, "Raid capability loot-method API is not initialized")
local UnitIsUnit = assert(_G.UnitIsUnit, "Raid capability unit comparison API is not initialized")
local GetUnitRank = assert(Database.GetUnitRank, "Raid capability group-rank resolver is not initialized")

local function readLootMethodName()
	local method = select(1, GetLootMethod())
	if type(method) ~= "string" or method == "" then
		return nil
	end
	return method
end

local function isPassiveGroupLootMethod(method)
	local resolvedMethod = method or readLootMethodName()
	return resolvedMethod == "group" or resolvedMethod == "needbeforegreed"
end

do
	addon.Services.EnsureNamespace("Raid")
	local Raid = Services.Raid
	local module = Raid

	-- ----- Internal state ----- --

	-- ----- Private helpers ----- --
	local function showMasterOnlyWarning()
		addon:warn(L.WarnMLOnlyMode or L.WarnMLNoPermission)
	end

	local IsPlayerInRaid = assert(module.IsPlayerInRaid, "Raid capability raid-membership resolver is not initialized")
	local GetUnitID = assert(module.GetUnitID, "Raid capability unit resolver is not initialized")

	-- ----- Public methods ----- --

	function module:GetLootMethodName()
		return readLootMethodName()
	end

	function module:IsPassiveGroupLootMethod(method)
		return isPassiveGroupLootMethod(method)
	end

	function module:IsMasterLooter()
		local method, partyMaster, raidMaster = GetLootMethod()
		if method ~= "master" then
			return false
		end
		if partyMaster then
			if partyMaster == 0 or UnitIsUnit("party" .. tostring(partyMaster), "player") then
				return true
			end
		end
		if raidMaster then
			if raidMaster == 0 or UnitIsUnit("raid" .. tostring(raidMaster), "player") then
				return true
			end
		end
		return false
	end

	function module:IsGroupMember(name)
		local unit = GetUnitID(module, name)
		return unit ~= nil and unit ~= "none"
	end

	function module:IsLootAuthority(name)
		local unit = GetUnitID(module, name)
		if not unit or unit == "none" then
			return false
		end

		local method, partyMaster, raidMaster = GetLootMethod()
		if method ~= "master" then
			return false
		end

		local masterUnit
		if partyMaster ~= nil then
			masterUnit = partyMaster == 0 and "player" or "party" .. tostring(partyMaster)
		elseif raidMaster ~= nil then
			masterUnit = raidMaster == 0 and "player" or "raid" .. tostring(raidMaster)
		end
		return masterUnit ~= nil and not not UnitIsUnit(unit, masterUnit)
	end

	function module:IsReservesAuthority(name)
		local unit = GetUnitID(module, name)
		if not unit or unit == "none" then
			return false
		end
		if module:IsLootAuthority(name) then
			return true
		end
		return (tonumber(GetUnitRank(unit, 0)) or 0) > 0
	end

	function module:GetPlayerRoleState()
		local inRaid = IsPlayerInRaid(module)
		local rank = tonumber(GetUnitRank("player", 0)) or 0
		local isLeader = rank >= 2
		local isAssistant = rank == 1
		return {
			inRaid = inRaid,
			rank = rank,
			isLeader = isLeader,
			isAssistant = isAssistant,
			hasRaidLeadership = inRaid and rank > 0,
			hasGroupLeadership = rank > 0,
			isMasterLooter = module:IsMasterLooter(),
		}
	end

	function module:GetCapabilityState(capability)
		local role = module:GetPlayerRoleState()
		local state = {
			capability = capability,
			allowed = false,
			reason = "unknown_capability",
			role = role,
		}

		if capability == "loot" then
			if not role.inRaid or role.isMasterLooter then
				state.allowed = true
				state.reason = nil
			else
				state.reason = "missing_master_looter"
			end
			return state
		end

		if capability == "inventory_trade" then
			if not role.inRaid or role.isMasterLooter or role.hasRaidLeadership then
				state.allowed = true
				state.reason = nil
			else
				state.reason = "missing_loot_or_leadership"
			end
			return state
		end

		if
			capability == "raid_leadership"
			or capability == "loot_counter_broadcast"
			or capability == "raid_warning"
			or capability == "raid_icons"
		then
			if not role.inRaid then
				state.reason = "not_in_raid"
			elseif role.hasRaidLeadership then
				state.allowed = true
				state.reason = nil
			else
				state.reason = "missing_leadership"
			end
			return state
		end

		if capability == "group_leadership" or capability == "ready_check" then
			if role.hasGroupLeadership then
				state.allowed = true
				state.reason = nil
			else
				state.reason = "missing_group_leadership"
			end
			return state
		end

		return state
	end

	function module:CanUseCapability(capability)
		local state = module:GetCapabilityState(capability)
		return state and state.allowed == true
	end

	function module:EnsureMasterOnlyAccess()
		if not module:CanUseCapability("loot") then
			showMasterOnlyWarning()
			return false
		end
		return true
	end

	function module:CanObservePassiveLoot()
		local method = readLootMethodName()
		if method == "master" then
			return module:CanUseCapability("loot")
		end
		return isPassiveGroupLootMethod(method)
	end
end
