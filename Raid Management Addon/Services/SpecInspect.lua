-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: local feature = addon.Database.GetFeatureShared()
-- exports: addon.Services.SpecInspect
-- events: listens wow.READY_CHECK and LibGroupTalents callbacks; emits SpecInspectUpdated
-- notes: runtime-only spec display cache backed by LibGroupTalents-1.0

local addon = select(2, ...)
local feature = addon.Database.GetFeatureShared()

local Database = feature.Database
local Services = feature.Services
local Events = feature.Events
local Bus = feature.Bus
local Strings = feature.Strings

local GetTime = GetTime or addon.GetTime or _G.GetTime or function()
    return 0
end
local UnitGUID = UnitGUID or addon.UnitGUID or _G.UnitGUID or function()
    return nil
end

local type = type
local tonumber = tonumber
local tostring = tostring
local string_lower = string.lower

local InternalEvents = Events.Internal
local STALE_AFTER_SECONDS = 1800

-- ----- Internal state ----- --

local lgt = LibStub("LibGroupTalents-1.0", true)

local cache = {}
local scratchPlayers = {}
local emitDisplayUpdate

-- ----- Private helpers ----- --

local function now()
    return tonumber(GetTime()) or 0
end

local function normalizeName(name)
    if type(Strings) == "table" and type(Strings.NormalizeName) == "function" then
        return Strings.NormalizeName(name, true)
    end
    return name
end

local function isNonEmptyString(value)
    return type(value) == "string" and value ~= ""
end

local function normalizeRole(role)
    if role == "TANK" or role == "HEALER" or role == "DAMAGER" then
        return role
    end
    if type(role) == "string" then
        local lowered = string_lower(role)
        if lowered == "tank" then
            return "TANK"
        end
        if lowered == "healer" then
            return "HEALER"
        end
        if lowered == "melee" or lowered == "caster" then
            return "DAMAGER"
        end
    end
    return nil
end

local function normalizePlayerRow(row)
    if type(row) == "string" then
        return normalizeName(row)
    end
    if type(row) == "table" and isNonEmptyString(row.name) then
        return normalizeName(row.name)
    end
    return nil
end

local function getClassForPlayer(name)
    local raidService = Services.Raid
    if raidService and type(raidService.GetPlayerClass) == "function" then
        return raidService:GetPlayerClass(name) or "UNKNOWN"
    end
    return "UNKNOWN"
end

local function isCompleteSnapshot(snapshot)
    return type(snapshot) == "table"
        and isNonEmptyString(snapshot.specName)
        and isNonEmptyString(snapshot.icon)
        and isNonEmptyString(snapshot.class)
        and isNonEmptyString(snapshot.guid)
        and tonumber(snapshot.updatedAt) ~= nil
end

local function isSnapshotStale(snapshot)
    local t = tonumber(snapshot and snapshot.updatedAt) or 0
    return (now() - t) > STALE_AFTER_SECONDS
end

local function snapshotDisplayEqual(lhs, rhs)
    if lhs == rhs then
        return true
    end
    if type(lhs) ~= "table" or type(rhs) ~= "table" then
        return false
    end
    return lhs.specName == rhs.specName and lhs.icon == rhs.icon and lhs.role == rhs.role and lhs.class == rhs.class
end

local function dominantTalentTab(specName, t1, t2, t3)
    local points = { tonumber(t1) or 0, tonumber(t2) or 0, tonumber(t3) or 0 }
    local best = points[1]
    local bestTab = 1
    local tied = false

    for tab = 2, 3 do
        local value = points[tab]
        if value > best then
            best = value
            bestTab = tab
            tied = false
        elseif value == best then
            tied = true
        end
    end

    if tied then
        return nil, specName
    end
    return bestTab, specName
end

local function getTalentGroupCount(unit)
    if lgt and type(lgt.GetNumTalentGroups) == "function" then
        return tonumber(lgt:GetNumTalentGroups(unit)) or 1
    end
    return 1
end

local function getActiveTalentGroup(unit)
    if lgt and type(lgt.GetActiveTalentGroup) == "function" then
        return tonumber(lgt:GetActiveTalentGroup(unit)) or 1
    end
    return 1
end

local function buildGroupSpecIcon(unit, group, dominantTab, specName)
    if not isNonEmptyString(specName) or not lgt or type(lgt.GetTalentTabInfo) ~= "function" then
        return nil
    end

    local icon
    if type(dominantTab) == "number" then
        local tabName, tabIcon = lgt:GetTalentTabInfo(unit, dominantTab, group)
        if tabName == specName and isNonEmptyString(tabIcon) then
            icon = tabIcon
        end
    end
    if not isNonEmptyString(icon) then
        for tab = 1, 3 do
            local tabName, tabIcon = lgt:GetTalentTabInfo(unit, tab, group)
            if tabName == specName and isNonEmptyString(tabIcon) then
                icon = tabIcon
                break
            end
        end
    end
    if not isNonEmptyString(icon) then
        return nil
    end

    return icon
end

local function buildTalentGroupSnapshot(unit, group)
    local specName, t1, t2, t3 = lgt:GetUnitTalentSpec(unit, group)
    if not isNonEmptyString(specName) then
        return nil
    end
    local dominantTab, specNameNormalized = dominantTalentTab(specName, t1, t2, t3)
    specName = specNameNormalized
    local icon = buildGroupSpecIcon(unit, group, dominantTab, specName)
    return {
        group = group,
        specName = specName,
        specIcon = icon,
        mainTalentTree = dominantTab,
        points = { tonumber(t1) or 0, tonumber(t2) or 0, tonumber(t3) or 0 },
    }
end

local function findSecondaryGroup(snapshot)
    local groups = type(snapshot) == "table" and snapshot.groups
    if type(groups) ~= "table" then
        return nil
    end
    local activeGroup = tonumber(snapshot.activeGroup) or 1
    local numGroups = tonumber(snapshot.numGroups) or 0
    if numGroups > 0 then
        for group = 1, numGroups do
            if group ~= activeGroup and type(groups[group]) == "table" then
                return groups[group]
            end
        end
    else
        for group, groupSnapshot in pairs(groups) do
            if group ~= activeGroup and type(groupSnapshot) == "table" then
                return groupSnapshot
            end
        end
    end
    return nil
end

local function rebuildSnapshotFromLibrary(name, unit, reason, silent)
    local canReadTalents = lgt and type(lgt.GetUnitTalentSpec) == "function"
    if not canReadTalents or not isNonEmptyString(name) or not isNonEmptyString(unit) then
        return nil
    end

    local activeGroup = getActiveTalentGroup(unit)
    local numGroups = getTalentGroupCount(unit)
    local groups = {}
    for group = 1, tonumber(numGroups) or 1 do
        groups[group] = buildTalentGroupSnapshot(unit, group)
    end

    local activeSnapshot = groups[activeGroup] or groups[1]
    if type(activeSnapshot) ~= "table" then
        return nil
    end

    local secondarySnapshot = nil
    local compatSnapshot = {
        name = name,
        guid = UnitGUID(unit),
        specName = activeSnapshot.specName,
        icon = activeSnapshot.specIcon,
        role = nil,
        class = getClassForPlayer(name),
        updatedAt = now(),
        refreshReason = reason or "library",
        activeGroup = activeGroup,
        numGroups = numGroups,
        groups = groups,
        mainTalentTree = activeSnapshot.mainTalentTree,
    }
    if type(compatSnapshot.role) ~= "string" then
        if type(lgt.GetUnitRole) == "function" then
            compatSnapshot.role = normalizeRole(lgt:GetUnitRole(unit))
        end
    end

    local role
    if type(compatSnapshot.role) == "string" then
        role = compatSnapshot.role
    end
    compatSnapshot.role = role

    secondarySnapshot = findSecondaryGroup({
        activeGroup = activeGroup,
        groups = groups,
        numGroups = numGroups,
    })
    if type(secondarySnapshot) == "table" then
        compatSnapshot.secondarySpecName = secondarySnapshot.specName
        compatSnapshot.secondaryIcon = secondarySnapshot.specIcon
        compatSnapshot.secondaryGroup = secondarySnapshot.group
        compatSnapshot.secondaryMainTalentTree = secondarySnapshot.mainTalentTree
    end

    local previous = cache[name]
    local snapshot = compatSnapshot

    cache[name] = snapshot
    if not silent and emitDisplayUpdate and not snapshotDisplayEqual(previous, snapshot) then
        emitDisplayUpdate(snapshot, reason or "library")
    end
    return snapshot
end

local function clearScratchPlayers()
    for i = #scratchPlayers, 1, -1 do
        scratchPlayers[i] = nil
    end
end

local function getCurrentUnit(name)
    local raidService = Services.Raid
    if raidService and type(raidService.GetUnitID) == "function" then
        return raidService:GetUnitID(name)
    end
    return nil
end

local function getDisplaySnapshotMaybeCached(name, unit, reason)
    local cached = cache[name]
    if cached and isCompleteSnapshot(cached) and cached.guid == UnitGUID(unit) and not isSnapshotStale(cached) then
        return cached
    end
    return rebuildSnapshotFromLibrary(name, unit, reason)
end

local function shouldRefreshSnapshot(cached, snapshot, unit, opts)
    if opts and opts.force == true then
        return true
    end
    if type(snapshot) ~= "table" then
        return true
    end
    if not isCompleteSnapshot(snapshot) then
        return true
    end
    local guid = UnitGUID(unit)
    if snapshot.guid ~= guid then
        return true
    end
    if type(cached) == "table" and cached.guid and guid and cached.guid ~= guid then
        return true
    end
    if type(cached) == "table" then
        return isSnapshotStale(cached)
    end
    return false
end

emitDisplayUpdate = function(snapshot, reason)
    local eventName = InternalEvents and InternalEvents.SpecInspectUpdated
    if eventName then
        Bus.TriggerEvent(eventName, snapshot.name, snapshot, reason)
    end
end

local function refreshPlayerWithCache(name, opts)
    local raidService = Services.Raid
    if type(raidService) ~= "table" then
        return false, "missing_raid"
    end

    local unit = raidService.GetUnitID and raidService:GetUnitID(name)
    if not isNonEmptyString(unit) or unit == "none" then
        return false, "missing_unit"
    end
    if not lgt then
        return false, "missing_library"
    end

    local reason = isNonEmptyString(opts and opts.reason) and tostring(opts.reason) or "refresh"
    local cached = cache[name]
    local priorSnapshot = getDisplaySnapshotMaybeCached(name, unit, reason)
    local needsRefresh = shouldRefreshSnapshot(cached, priorSnapshot, unit, opts)

    if needsRefresh and type(lgt.RefreshTalentsByUnit) == "function" then
        lgt:RefreshTalentsByUnit(unit)
        if type(priorSnapshot) == "table" then
            priorSnapshot.refreshReason = reason
        end
        return true, "queued"
    end

    if type(priorSnapshot) == "table" then
        priorSnapshot.refreshReason = reason
    else
        priorSnapshot = rebuildSnapshotFromLibrary(name, unit, reason)
        if not priorSnapshot then
            return false, "missing_snapshot"
        end
    end

    return true, "cached"
end

-- ----- Public methods ----- --

do
    feature.EnsureServiceNamespace("SpecInspect")
    local module = Services.SpecInspect

    function module:GetPlayerSpecSnapshot(name)
        local playerName = normalizeName(name)
        if not isNonEmptyString(playerName) then
            return nil
        end
        if type(cache[playerName]) == "table" then
            return cache[playerName]
        end

        local unit = getCurrentUnit(playerName)
        if not isNonEmptyString(unit) or unit == "none" then
            return nil
        end

        local ok, spec = pcall(rebuildSnapshotFromLibrary, playerName, unit, "cache_getter", true)
        if not ok then
            return nil
        end
        return spec
    end

    function module:GetUnitTalentSnapshot(unit, playerName, reason, silent)
        local name = normalizePlayerRow(playerName)
        if not isNonEmptyString(name) then
            name = unit
        end
        if not isNonEmptyString(name) or not isNonEmptyString(unit) then
            return nil
        end

        local ok, snapshot = pcall(rebuildSnapshotFromLibrary, name, unit, reason or "unit", silent)
        if not ok then
            return nil
        end
        return snapshot
    end

    function module:RefreshPlayer(name, opts)
        local playerName = normalizeName(name)
        if not isNonEmptyString(playerName) then
            return false, "missing_name"
        end

        return refreshPlayerWithCache(playerName, opts or {})
    end

    function module:RefreshRaidSpecs(opts)
        local raidService = Services.Raid
        local result = { refreshed = 0, cached = 0, skipped = 0 }
        if not raidService or type(raidService.GetPlayers) ~= "function" then
            result.skipped = 1
            return result
        end

        local currentRaidId = Database.GetCurrentRaid()
        clearScratchPlayers()
        local players = raidService:GetPlayers(currentRaidId, nil, scratchPlayers)
        if type(players) ~= "table" then
            result.skipped = 1
            return result
        end

        for i = 1, #players do
            local playerName = normalizePlayerRow(players[i])
            if isNonEmptyString(playerName) then
                local ok, state = module:RefreshPlayer(playerName, opts)
                if ok and state == "queued" then
                    result.refreshed = result.refreshed + 1
                elseif ok then
                    result.cached = result.cached + 1
                else
                    result.skipped = result.skipped + 1
                end
            end
        end

        return result
    end

    function module:ForceRefreshRaidSpecs(reason)
        return module:RefreshRaidSpecs({ force = true, reason = reason or "force_refresh" })
    end

    local function playerNameByUnit(unitID)
        local raidService = Services.Raid
        local hasGetPlayers = raidService and type(raidService.GetPlayers) == "function"
        local hasGetUnitID = raidService and type(raidService.GetUnitID) == "function"
        local canReadRoster = hasGetPlayers and hasGetUnitID
        if not canReadRoster then
            return nil
        end

        local currentRaidId = Database.GetCurrentRaid()
        clearScratchPlayers()
        local players = raidService:GetPlayers(currentRaidId, nil, scratchPlayers)
        if type(players) ~= "table" then
            return nil
        end

        for i = 1, #players do
            local playerName = normalizePlayerRow(players[i])
            if isNonEmptyString(playerName) and raidService:GetUnitID(playerName) == unitID then
                return playerName
            end
        end
        return nil
    end

    local function handleLibraryUpdate(_, guid, unitID)
        local playerName = playerNameByUnit(unitID)
        if not isNonEmptyString(playerName) then
            playerName = normalizeName(guid)
        end
        if not isNonEmptyString(playerName) then
            return
        end

        local snapshot = rebuildSnapshotFromLibrary(playerName, unitID, "update")
        if not snapshot then
            return
        end
    end

    local function handleUpdateComplete()
        local raidService = Services.Raid
        if not raidService or type(raidService.GetPlayers) ~= "function" then
            return
        end

        local currentRaidId = Database.GetCurrentRaid()
        clearScratchPlayers()
        local players = raidService:GetPlayers(currentRaidId, nil, scratchPlayers)
        if type(players) ~= "table" then
            return
        end

        for i = 1, #players do
            local playerName = normalizePlayerRow(players[i])
            if isNonEmptyString(playerName) then
                local unit = raidService:GetUnitID(playerName)
                if isNonEmptyString(unit) and unit ~= "none" then
                    rebuildSnapshotFromLibrary(playerName, unit, "update_complete")
                end
            end
        end
    end

    local readyCheckEvent = Events.GetWowForwarded("READY_CHECK")
    if readyCheckEvent then
        Bus.RegisterCallback(readyCheckEvent, function()
            module:RefreshRaidSpecs({ reason = "ready_check" })
        end)
    end

    if type(lgt) == "table" and type(lgt.RegisterCallback) == "function" then
        lgt.RegisterCallback(module, "LibGroupTalents_Update", handleLibraryUpdate)
        lgt.RegisterCallback(module, "LibGroupTalents_UpdateComplete", handleUpdateComplete)
    end
end

local registry = feature.ModuleRegistry
if type(registry) == "table" and type(registry.AddModule) == "function" and type(registry.SetLoaded) == "function" then
    registry.AddModule("Services/SpecInspect", {
        deps = {
            "Init",
            "Modules/ModuleRegistry",
            "Modules/Events",
            "Modules/Bus",
            "Modules/Strings",
            "Services/Raid/Roster",
        },
    })
    registry.SetLoaded("Services/SpecInspect")
end

