-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: local feature = addon.Database.GetFeatureShared()
-- exports: publish module APIs on addon.*
-- events: none
local addon = select(2, ...)
local feature = addon.Database.GetFeatureShared()

local L = feature.L
local Diag = feature.Diag

local Database = feature.Database
local Services = feature.Services

local pairs = pairs
local tonumber = tonumber
local type = type

do
    feature.EnsureServiceNamespace("Raid")
    local Raid = Services.Raid
    local module = Raid

    -- ----- Internal state ----- --
    local raidInstanceCheckHandles = {}
    local RAID_INSTANCE_CHECK_DELAYS = { 0.3, 0.8, 1.5, 2.5, 3.5 }

    -- ----- Private helpers ----- --
    local isDebugEnabled = feature.Options.IsDebugEnabled or function()
        return false
    end

    local function cancelRaidInstanceChecks()
        for idx, handle in pairs(raidInstanceCheckHandles) do
            module:CancelTimer(handle)
            raidInstanceCheckHandles[idx] = nil
        end
    end

    local function runLiveRaidInstanceCheck()
        local instanceName, instanceType, instanceDiff = GetInstanceInfo()
        if instanceType ~= "raid" then
            return
        end
        if L.RaidZones[instanceName] == nil then
            return
        end
        module:Check(instanceName, instanceDiff)
    end

    local function createRaidSessionWithReason(instanceName, newSize, instanceDiff, isCreate)
        local created = module:Create(instanceName, newSize, instanceDiff)
        if not created then
            return false
        end
        addon:info(L.StrNewRaidSessionChange)
        local template = isCreate and Diag.D.LogRaidSessionCreate or Diag.D.LogRaidSessionChange
        if isDebugEnabled() then
            addon:debug(template:format(tostring(instanceName), newSize, tonumber(instanceDiff) or -1))
        end
        return true
    end

    -- ----- Public methods ----- --

    function module:InvalidateRaidRuntime(raidNum)
        local raid = Database.EnsureRaidById(raidNum)
        if raid then
            if type(module._InvalidateRaidRuntimeInternal) == "function" then
                module._InvalidateRaidRuntimeInternal(raid)
            end
        end
    end

    function module:CancelInstanceChecks()
        cancelRaidInstanceChecks()
    end

    function module:ScheduleInstanceChecks()
        cancelRaidInstanceChecks()

        -- Immediate live check, then short retries to catch delayed server fallback updates.
        runLiveRaidInstanceCheck()

        for i = 1, #RAID_INSTANCE_CHECK_DELAYS do
            local idx = i
            local delaySeconds = RAID_INSTANCE_CHECK_DELAYS[idx]
            raidInstanceCheckHandles[idx] = module:ScheduleTimer(function()
                raidInstanceCheckHandles[idx] = nil
                runLiveRaidInstanceCheck()
            end, delaySeconds)
        end
    end

    -- Checks the current raid status and creates a new session if needed.
    function module:Check(instanceName, instanceDiff)
        instanceDiff = module._ResolveRaidDifficultyInternal(instanceDiff)
        local newSize = module._GetRaidSizeFromDifficultyInternal(instanceDiff)
        if isDebugEnabled() then
            addon:debug(Diag.D.LogRaidCheck:format(tostring(instanceName), tostring(instanceDiff), tostring(Database.GetCurrentRaid())))
        end
        if not newSize then
            return
        end

        if not Database.GetCurrentRaid() then
            module:Create(instanceName, newSize, instanceDiff)
            return
        end

        local current = Database.EnsureRaidById(Database.GetCurrentRaid())
        if not current then
            createRaidSessionWithReason(instanceName, newSize, instanceDiff, true)
            return
        end

        local shouldCreate = current.zone ~= instanceName or tonumber(current.size) ~= newSize or tonumber(current.difficulty) ~= instanceDiff

        if shouldCreate then
            createRaidSessionWithReason(instanceName, newSize, instanceDiff, false)
        end
    end

    -- ----- Boss helpers (merged from Raid/Boss.lua) ----- --

    function module:GetBossByNid(bossNid, raidNum)
        raidNum = raidNum or Database.GetCurrentRaid()
        local raid = raidNum and Database.EnsureRaidById(raidNum)
        if not raid or bossNid == nil then
            return nil
        end

        Database.EnsureRaidSchema(raid)

        bossNid = tonumber(bossNid) or 0
        if bossNid <= 0 then
            return nil
        end

        local bosses = raid.bossKills
        for i = 1, #bosses do
            local b = bosses[i]
            if b and tonumber(b.bossNid) == bossNid then
                return b, i
            end
        end
        return nil
    end

    function module:ClearRaidIcons()
        local players = module:GetPlayers()
        for i = 1, #players do
            SetRaidTarget("raid" .. tostring(i), 0)
        end
    end
end

local registry = feature.ModuleRegistry
if type(registry) == "table" and type(registry.AddModule) == "function" and type(registry.SetLoaded) == "function" then
    registry.AddModule("Services/Raid/Session", {
        deps = {
            "Init",
            "Modules/ModuleRegistry",
        },
    })
    registry.SetLoaded("Services/Raid/Session")
end

