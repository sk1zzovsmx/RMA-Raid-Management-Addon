-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: local feature = addon.Database.GetFeatureShared()
-- exports: publish module APIs on addon.*
-- events: no direct bus events; publishes synthetic roster deltas through Services/Raid
local addon = select(2, ...)
local feature = addon.Database.GetFeatureShared()

local Diag = feature.Diag

local Database = feature.Database
local Options = feature.Options
local Services = feature.Services
local Strings = feature.Strings
local Time = feature.Time
local coreState = feature.coreState

local tinsert, tremove = table.insert, table.remove
local pairs, type = pairs, type
local random = math.random
local tostring, tonumber = tostring, tonumber

-- Debug helper module.
-- Seeds a current raid with synthetic players and submits synthetic rolls.
do
    feature.EnsureServiceNamespace("Debug")
    local module = Services.Debug

    -- ----- Internal state ----- --
    local syntheticProfiles = {
        { name = "RMADbgWar", class = "WARRIOR", subgroup = 1 },
        { name = "RMADbgPri", class = "PRIEST", subgroup = 1 },
        { name = "RMADbgMag", class = "MAGE", subgroup = 2 },
        { name = "RMADbgRog", class = "ROGUE", subgroup = 2 },
    }
    local syntheticByName = {}
    local GetOption = Options.GetValue
        or function(namespace, key, defaultValue)
            local cfg = Options and Options.Get and Options.Get(namespace) or nil
            if cfg and cfg.Get then
                local value = cfg:Get(key)
                if value ~= nil then
                    return value
                end
            end
            return defaultValue
        end
    local IsDebugEnabled = Options.IsDebugEnabled or function()
        return false
    end

    -- ----- Private helpers ----- --
    local function getRaidService()
        return Services.Raid
    end

    local function getRollsService()
        return Services.Rolls
    end

    local function normalizeSyntheticName(name)
        return Strings and Strings.NormalizeName and Strings.NormalizeName(name, true) or name
    end

    local function isSyntheticProfileName(name)
        local normalized = normalizeSyntheticName(name)
        return normalized and syntheticByName[normalized] ~= nil
    end

    local function clearTable(map)
        if type(map) ~= "table" then
            return
        end
        for key in pairs(map) do
            map[key] = nil
        end
    end

    local function getDebugState()
        coreState.debug = coreState.debug or {}
        coreState.debug.syntheticByRaid = coreState.debug.syntheticByRaid or {}
        return coreState.debug
    end

    local function getCurrentRaidId()
        return Database.GetCurrentRaid and Database.GetCurrentRaid() or nil
    end

    local function getCurrentRaid()
        local raidId = getCurrentRaidId()
        if not raidId then
            return nil, nil
        end
        return Database.EnsureRaidById(raidId), raidId
    end

    local function getSyntheticStateForRaid(raidId, create)
        local debugState = getDebugState()
        local syntheticByRaid = debugState.syntheticByRaid
        local key = tonumber(raidId) or -1

        if create and type(syntheticByRaid[key]) ~= "table" then
            syntheticByRaid[key] = {}
        end

        return syntheticByRaid[key], key, syntheticByRaid
    end

    local function rebuildSyntheticState(raid, raidId)
        local raidState, raidKey, syntheticByRaid = getSyntheticStateForRaid(raidId, true)
        clearTable(raidState)

        if type(raid) == "table" and type(raid.players) == "table" then
            for i = 1, #raid.players do
                local player = raid.players[i]
                if type(player) == "table" and type(player.name) == "string" and isSyntheticProfileName(player.name) then
                    raidState[normalizeSyntheticName(player.name)] = true
                end
            end
        end

        if next(raidState) == nil then
            syntheticByRaid[raidKey] = nil
        end
    end

    local function buildRosterDeltaEntry(player)
        return {
            name = player.name,
            rank = player.rank or 0,
            subgroup = player.subgroup or 1,
            class = player.class or "UNKNOWN",
            unitID = nil,
        }
    end

    local function findSyntheticPlayer(raid, name)
        local targetName = normalizeSyntheticName(name)
        local players = raid and raid.players or {}
        for i = #players, 1, -1 do
            local player = players[i]
            if type(player) == "table" and normalizeSyntheticName(player.name) == targetName then
                return player, i
            end
        end
        return nil, nil
    end

    local function collectProtectedPlayerNids(raid)
        local protected = {}
        local bossKills = raid and raid.bossKills or {}
        local lootRows = raid and raid.loot or {}

        for i = 1, #bossKills do
            local bossKill = bossKills[i]
            local players = bossKill and bossKill.players or {}
            for j = 1, #players do
                local playerNid = tonumber(players[j])
                if playerNid and playerNid > 0 then
                    protected[playerNid] = true
                end
            end
        end

        for i = 1, #lootRows do
            local loot = lootRows[i]
            local looterNid = loot and tonumber(loot.looterNid) or nil
            if looterNid and looterNid > 0 then
                protected[looterNid] = true
            end
        end

        return protected
    end

    local function hasSyntheticRollEntries()
        local rolls = getRollsService()
        local entries = rolls and rolls.GetRolls and rolls:GetRolls() or nil
        if type(entries) ~= "table" then
            return false
        end

        for i = 1, #entries do
            local entry = entries[i]
            if entry and isSyntheticProfileName(entry.name) then
                return true
            end
        end

        return false
    end

    local function clearSyntheticRollStateIfNeeded()
        local rolls = getRollsService()
        if not (rolls and rolls.ClearRolls and hasSyntheticRollEntries()) then
            return false
        end

        rolls:ClearRolls()
        return true
    end

    local function publishSyntheticDelta(delta, raidId)
        local raidService = getRaidService()
        if raidService and raidService._PublishRosterDelta then
            raidService._PublishRosterDelta(delta, raidId)
        end
    end

    local function ensureCurrentRaidForDebug()
        local raid, raidId = getCurrentRaid()
        if not raidId or type(raid) ~= "table" then
            return nil, nil, "no_current_raid"
        end
        Database.EnsureRaidSchema(raid)
        return raid, raidId, nil
    end

    local function resolveSyntheticProfile(playerRef)
        local index = tonumber(playerRef)
        local normalized = normalizeSyntheticName(playerRef)
        if index and syntheticProfiles[index] then
            return syntheticProfiles[index]
        end
        return syntheticByName[normalized]
    end

    local function buildSyntheticPlayer(profile, existing, now)
        return {
            playerNid = existing and tonumber(existing.playerNid) or nil,
            name = normalizeSyntheticName(profile.name),
            rank = 0,
            subgroup = profile.subgroup or 1,
            class = profile.class or "UNKNOWN",
            join = (existing and existing.join) or now,
            leave = nil,
            count = (existing and tonumber(existing.count)) or 0,
        }
    end

    local function submitSyntheticRoll(profile, roll, raidId)
        local rolls = getRollsService()
        local ok
        local reason

        if not (rolls and rolls.SubmitDebugRoll) then
            return nil, "rolls_service_unavailable"
        end

        ok, reason = rolls:SubmitDebugRoll(profile.name, roll)
        if IsDebugEnabled() then
            addon:debug(Diag.D.LogDebugRaidRoll:format(tostring(raidId), profile.name, roll, tostring(ok), tostring(reason)))
        end

        return {
            raidId = raidId,
            name = profile.name,
            roll = roll,
            ok = ok == true,
            reason = reason,
        }, nil
    end

    local function buildRaidRollBatch(mode)
        local modeText = Strings and Strings.NormalizeLower and Strings.NormalizeLower(mode, true) or nil
        local tieMode = modeText == "tie"
        local total = #syntheticProfiles
        local values = {}
        local tiedIndexes = {}
        local tieCount = 0
        local tieRoll = 0
        local wantLow = GetOption("Master", "sortAscending") == true

        if tieMode and total > 1 then
            tieCount = random(2, 3)
            if tieCount > total then
                tieCount = total
            end

            local selected = 0
            while selected < tieCount do
                local idx = random(1, total)
                if not tiedIndexes[idx] then
                    tiedIndexes[idx] = true
                    selected = selected + 1
                end
            end

            if wantLow then
                tieRoll = random(2, 45)
            else
                tieRoll = random(55, 99)
            end
        else
            tieMode = false
        end

        for i = 1, total do
            if tieMode and tiedIndexes[i] then
                values[i] = tieRoll
            elseif tieMode and wantLow then
                values[i] = random(tieRoll + 1, 100)
            elseif tieMode then
                values[i] = random(1, tieRoll - 1)
            else
                values[i] = random(1, 100)
            end
        end

        return {
            values = values,
            tieMode = tieMode,
            tieCount = tieCount,
            tieRoll = tieRoll,
        }
    end

    for i = 1, #syntheticProfiles do
        local profile = syntheticProfiles[i]
        profile.name = normalizeSyntheticName(profile.name)
        syntheticByName[profile.name] = profile
    end

    -- ----- Public methods ----- --
    function module:SeedRaidPlayers()
        local raidService = getRaidService()
        local raid, raidId, err = ensureCurrentRaidForDebug()
        local delta = {
            joined = {},
            updated = {},
            left = {},
            unresolved = {},
        }
        local now = Time.GetCurrentTime()
        local added = 0
        local refreshed = 0

        if err then
            return nil, err
        end
        if not (raidService and raidService.AddPlayer) then
            return nil, "raid_service_unavailable"
        end

        for i = 1, #syntheticProfiles do
            local profile = syntheticProfiles[i]
            local existing, existingIndex = findSyntheticPlayer(raid, profile.name)
            local player = buildSyntheticPlayer(profile, existing, now)

            if existingIndex and existing and existing.name ~= player.name then
                tremove(raid.players, existingIndex)
                if raidService and raidService.InvalidateRaidRuntime then
                    raidService:InvalidateRaidRuntime(raidId)
                end
            end

            raidService:AddPlayer(player, raidId)
            if IsDebugEnabled() then
                addon:debug(Diag.D.LogDebugRaidSeed:format(tostring(raidId), player.name, player.class))
            end

            if not existing or existing.leave ~= nil then
                added = added + 1
                tinsert(delta.joined, buildRosterDeltaEntry(player))
            else
                refreshed = refreshed + 1
                tinsert(delta.updated, buildRosterDeltaEntry(player))
            end
        end

        raid = Database.EnsureRaidById(raidId)
        rebuildSyntheticState(raid, raidId)
        publishSyntheticDelta(delta, raidId)

        return {
            raidId = raidId,
            added = added,
            refreshed = refreshed,
            total = #syntheticProfiles,
        }
    end

    function module:ClearRaidPlayers()
        local raidService = getRaidService()
        local raid, raidId, err = ensureCurrentRaidForDebug()
        local protectedNids
        local removed = 0
        local blocked = 0
        local clearedRolls = false
        local delta = {
            joined = {},
            updated = {},
            left = {},
            unresolved = {},
        }

        if err then
            return nil, err
        end

        protectedNids = collectProtectedPlayerNids(raid)

        for i = #raid.players, 1, -1 do
            local player = raid.players[i]
            if type(player) == "table" and isSyntheticProfileName(player.name) then
                local playerNid = tonumber(player.playerNid) or 0
                if playerNid > 0 and protectedNids[playerNid] then
                    blocked = blocked + 1
                    if IsDebugEnabled() then
                        addon:debug(Diag.D.LogDebugRaidClearBlocked:format(tostring(raidId), player.name, tostring(playerNid)))
                    end
                else
                    removed = removed + 1
                    tinsert(delta.left, buildRosterDeltaEntry(player))
                    tremove(raid.players, i)
                    if IsDebugEnabled() then
                        addon:debug(Diag.D.LogDebugRaidClearRemoved:format(tostring(raidId), player.name, tostring(playerNid)))
                    end
                end
            end
        end

        if removed > 0 and raidService and raidService.InvalidateRaidRuntime then
            raidService:InvalidateRaidRuntime(raidId)
        end

        rebuildSyntheticState(raid, raidId)

        if removed > 0 then
            clearedRolls = clearSyntheticRollStateIfNeeded()
            publishSyntheticDelta(delta, raidId)
        end

        return {
            raidId = raidId,
            removed = removed,
            blocked = blocked,
            clearedRolls = clearedRolls,
        }
    end

    function module:RollRaidPlayer(playerRef, rollValue)
        local seedResult, seedErr
        local profile = resolveSyntheticProfile(playerRef)
        local roll = tonumber(rollValue)

        if not profile then
            return nil, "unknown_player"
        end

        if roll == nil then
            roll = random(1, 100)
        end
        if roll < 1 or roll > 100 then
            return nil, "invalid_roll"
        end

        seedResult, seedErr = module:SeedRaidPlayers()
        if not seedResult then
            return nil, seedErr
        end

        return submitSyntheticRoll(profile, roll, seedResult.raidId)
    end

    function module:RequestRaidRolls(mode)
        local seedResult, err = module:SeedRaidPlayers()
        local submitted = 0
        local firstFailure = nil
        local rollBatch

        if not seedResult then
            return nil, err
        end

        rollBatch = buildRaidRollBatch(mode)

        for i = 1, #syntheticProfiles do
            local profile = syntheticProfiles[i]
            local result

            result, err = submitSyntheticRoll(profile, rollBatch.values[i], seedResult.raidId)
            if not result then
                return nil, err
            end
            if result.ok then
                submitted = submitted + 1
            elseif not firstFailure then
                firstFailure = result.reason
            end
        end

        return {
            raidId = seedResult.raidId,
            total = #syntheticProfiles,
            submitted = submitted,
            failed = #syntheticProfiles - submitted,
            firstFailure = firstFailure,
            tieMode = rollBatch.tieMode == true,
            tieCount = rollBatch.tieCount or 0,
            tieRoll = rollBatch.tieRoll or 0,
        }
    end
end

local registry = feature.ModuleRegistry
if type(registry) == "table" and type(registry.AddModule) == "function" and type(registry.SetLoaded) == "function" then
    registry.AddModule("Services/Debug", {
        deps = {
            "Init",
            "Modules/ModuleRegistry",
            "Modules/Strings",
            "Modules/Time",
        },
    })
    registry.SetLoaded("Services/Debug")
end

