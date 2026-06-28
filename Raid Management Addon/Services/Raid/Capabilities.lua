-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: local feature = addon.Database.GetFeatureShared()
-- exports: publish module APIs on addon.*
-- events: none
local addon = select(2, ...)
local feature = addon.Database.GetFeatureShared()

local Database = feature.Database
local L = feature.L
local Services = feature.Services

local select = select
local tonumber = tonumber
local tostring = tostring
local type = type

local getLootMethod = GetLootMethod
local unitIsUnit = UnitIsUnit

local function readLootMethodName()
    if type(getLootMethod) ~= "function" then
        return nil
    end
    local method = select(1, getLootMethod())
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
    feature.EnsureServiceNamespace("Raid")
    local Raid = Services.Raid
    local module = Raid

    -- ----- Internal state ----- --

    -- ----- Private helpers ----- --
    local function showMasterOnlyWarning()
        addon:warn(L.WarnMLOnlyMode or L.WarnMLNoPermission)
    end

    -- ----- Public methods ----- --

    function module:GetLootMethodName()
        return readLootMethodName()
    end

    function module:IsMasterLooter()
        local method, partyMaster, raidMaster = getLootMethod()
        if method ~= "master" then
            return false
        end
        if partyMaster then
            if partyMaster == 0 or unitIsUnit("party" .. tostring(partyMaster), "player") then
                return true
            end
        end
        if raidMaster then
            if raidMaster == 0 or unitIsUnit("raid" .. tostring(raidMaster), "player") then
                return true
            end
        end
        return false
    end

    function module:GetPlayerRoleState()
        local inRaid = type(module.IsPlayerInRaid) == "function" and module:IsPlayerInRaid() or false
        local rank = Database.GetUnitRank and (tonumber(Database.GetUnitRank("player", 0)) or 0) or 0
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

        if capability == "raid_leadership" or capability == "loot_counter_broadcast" or capability == "raid_warning" or capability == "raid_icons" then
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

local registry = feature.ModuleRegistry
if type(registry) == "table" and type(registry.AddModule) == "function" and type(registry.SetLoaded) == "function" then
    registry.AddModule("Services/Raid/Capabilities", {
        deps = {
            "Init",
            "Modules/ModuleRegistry",
        },
    })
    registry.SetLoaded("Services/Raid/Capabilities")
end

