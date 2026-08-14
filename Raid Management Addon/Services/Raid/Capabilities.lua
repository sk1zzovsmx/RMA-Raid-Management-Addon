-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: direct addon namespace bindings
-- exports: publish module APIs on addon.*
-- events: none
local addon = select(2, ...)
local Diag = addon.Diag
local Database = addon.Database
local L = addon.L
local Services = addon.Services
local Strings = addon.Strings

local select = select
local tonumber = tonumber
local tostring = tostring
local type = type
local strmatch = string.match

local GetLootMethod = assert(_G.GetLootMethod, Diag.A.RaidCapabilityLootMethodApiNotInitialized)
local GetNumRaidMembers = assert(_G.GetNumRaidMembers, Diag.A.RaidCapabilityRosterCountApiNotInitialized)
local GetRaidRosterInfo = assert(_G.GetRaidRosterInfo, Diag.A.RaidCapabilityRosterApiNotInitialized)
local UnitIsUnit = assert(_G.UnitIsUnit, Diag.A.RaidCapabilityUnitComparisonApiNotInitialized)
local UnitName = assert(_G.UnitName, Diag.A.RaidCapabilityUnitNameApiNotInitialized)
local GetUnitRank = assert(Database.GetUnitRank, Diag.A.RaidCapabilityGroupRankResolverNotInitialized)
local NormalizeLower = assert(Strings.NormalizeLower, Diag.A.RaidCapabilityNameNormalizerNotInitialized)

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

local function normalizeAuthorityName(value)
	if type(value) ~= "string" or value == "" then
		return nil
	end
	return NormalizeLower(strmatch(value, "^([^%-]+)") or value, true)
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

	local IsPlayerInRaid = assert(module.IsPlayerInRaid, Diag.A.RaidCapabilityRaidMembershipResolverNotInitialized)
	local GetUnitID = assert(module.GetUnitID, Diag.A.RaidCapabilityUnitResolverNotInitialized)
	local function getMasterLooterUnit()
		local method, partyMaster, raidMaster = GetLootMethod()
		if method ~= "master" then
			return nil
		end
		if raidMaster ~= nil then
			return raidMaster == 0 and "player" or "raid" .. tostring(raidMaster)
		end
		if partyMaster ~= nil then
			return partyMaster == 0 and "player" or "party" .. tostring(partyMaster)
		end
		return nil
	end

	-- ----- Public methods ----- --

	function module:GetLootMethodName()
		return readLootMethodName()
	end

	function module:GetMasterLooterName()
		local unit = getMasterLooterUnit()
		local name = unit and UnitName(unit)
		return name and name ~= "" and name or nil
	end

	function module:IsPassiveGroupLootMethod(method)
		return isPassiveGroupLootMethod(method)
	end

	function module:IsMasterLooter()
		local masterUnit = getMasterLooterUnit()
		return masterUnit ~= nil and not not UnitIsUnit(masterUnit, "player")
	end

	function module:GetRaidLeaderName()
		local count = tonumber(GetNumRaidMembers()) or 0
		for i = 1, count do
			local name, rank = GetRaidRosterInfo(i)
			if name and tonumber(rank) == 2 then
				return name
			end
		end
		return nil
	end

	function module:IsRaidLeader()
		return IsPlayerInRaid(module) and (tonumber(GetUnitRank("player", 0)) or 0) >= 2
	end

	function module:CanCommitRaidHistory()
		local syncer = addon.DB and addon.DB.Syncer
		if syncer and type(syncer.IsAuthorityRecovering) == "function" and syncer:IsAuthorityRecovering() then
			return false
		end
		if module:IsRaidLeader() ~= true then
			return false
		end
		local leaderName = normalizeAuthorityName(module:GetRaidLeaderName())
		local playerName = normalizeAuthorityName(Database.GetPlayerName())
		return leaderName ~= nil and playerName ~= nil and leaderName == playerName
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

		local masterUnit = getMasterLooterUnit()
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
		if Database.GetCurrentRaid() == nil then
			if method == "master" then
				return module:CanUseCapability("loot")
			end
			return isPassiveGroupLootMethod(method)
		end
		if method == "master" then
			return module:CanCommitRaidHistory() and module:IsMasterLooter()
		end
		return isPassiveGroupLootMethod(method) and module:CanCommitRaidHistory()
	end
end
