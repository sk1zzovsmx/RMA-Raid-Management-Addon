-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: local feature = addon.Database.GetFeatureShared()
-- exports: publish module APIs on addon.*
-- events: none
local addon = select(2, ...)
local feature = addon.Database.GetFeatureShared()

local DB = feature.DB
local coreState = feature.coreState
local Database = feature.Database
local Time = feature.Time

local tinsert, tremove = table.insert, table.remove
local pairs, type = pairs, type
local tostring, tonumber = tostring, tonumber
local tconcat = table.concat
local format = string.format

-- Raid storage service.
do
    DB.RaidStore = DB.RaidStore or {}
    local module = DB.RaidStore

    -- ----- Internal state ----- --
    local ROOT_RUNTIME_CACHE_KEYS = {
        _playersByName = true,
        _playerIdxByNid = true,
        _bossIdxByNid = true,
        _lootIdxByNid = true,
    }
    local RUNTIME_INDEX_MAP_KEYS = {
        "playersByName",
        "playerByNid",
        "playerNidByName",
        "playerIdxByNid",
        "bossIdxByNid",
        "bossByNid",
        "bossPlayerSetByBossNid",
        "lootIdxByNid",
        "lootByNid",
        "lootIdxByBossNid",
        "lootIdxByLooterNid",
        "attendanceIdxByPlayerNid",
        "attendanceByPlayerNid",
    }

    local storeState = coreState.raidStore
    if type(storeState) ~= "table" then
        storeState = {}
        coreState.raidStore = storeState
    end

    -- ----- Private helpers ----- --
    local function clearMap(map)
        if type(map) ~= "table" then
            return {}
        end
        for key in pairs(map) do
            map[key] = nil
        end
        return map
    end

    local isBossFightRecord = Database.IsBossFightRecord

    local function createNidAllocator(initialNext)
        local usedNids = {}
        local nextNid = tonumber(initialNext) or 1
        if nextNid < 1 then
            nextNid = 1
        end

        local function markAllocated(nid)
            usedNids[nid] = true
            if nid >= nextNid then
                nextNid = nid + 1
            end
            return nid
        end

        local function allocate(preferred)
            local nid = tonumber(preferred)
            if nid and nid > 0 and not usedNids[nid] then
                return markAllocated(nid)
            end

            while usedNids[nextNid] do
                nextNid = nextNid + 1
            end

            return markAllocated(nextNid)
        end

        local function getNext()
            return nextNid
        end

        return allocate, getNext
    end

    local function ensureRaidsTable()
        if type(RMA_Raids) ~= "table" then
            RMA_Raids = {}
        end
        return RMA_Raids
    end

    local function getSchemaVersion()
        local version = Database.GetRaidSchemaVersion() or 1
        version = tonumber(version) or 1
        if version < 1 then
            version = 1
        end
        return version
    end

    local function getMigrations()
        return Database.GetRaidMigrations()
    end

    local function removeRootRuntimeCaches(raid)
        for key in pairs(ROOT_RUNTIME_CACHE_KEYS) do
            raid[key] = nil
        end
    end

    local function isRuntimeIndexReady(runtime)
        if type(runtime) ~= "table" then
            return false
        end
        for i = 1, #RUNTIME_INDEX_MAP_KEYS do
            if not (type(runtime[RUNTIME_INDEX_MAP_KEYS[i]]) == "table") then
                return false
            end
        end
        return true
    end

    local function ensureRuntimeTable(raid)
        local runtime = raid._runtime
        if type(runtime) ~= "table" then
            runtime = {}
            raid._runtime = runtime
        end
        return runtime
    end

    local function ensureSyncRevision(raid)
        if type(raid) ~= "table" then
            return 0
        end
        local runtime = ensureRuntimeTable(raid)
        runtime.syncRevision = tonumber(runtime.syncRevision) or 0
        if type(runtime.lootSyncRevisionByNid) ~= "table" then
            runtime.lootSyncRevisionByNid = {}
        end
        return runtime.syncRevision
    end

    local function acquireRuntimeIndexMap(runtime, key)
        local map = clearMap(runtime[key])
        runtime[key] = map
        return map
    end

    local function acquireRuntimeIndexMaps(runtime)
        local maps = {}
        for i = 1, #RUNTIME_INDEX_MAP_KEYS do
            local key = RUNTIME_INDEX_MAP_KEYS[i]
            maps[key] = acquireRuntimeIndexMap(runtime, key)
        end
        return maps
    end

    local function appendRuntimeIndexList(indexMap, key, value, dedupe)
        if key == nil or value == nil then
            return
        end
        local list = indexMap[key]
        if type(list) ~= "table" then
            list = {}
            indexMap[key] = list
        end
        if dedupe == true then
            for i = 1, #list do
                if list[i] == value then
                    return
                end
            end
        end
        list[#list + 1] = value
    end

    local function removeRuntimeIndexListValue(indexMap, value)
        if type(indexMap) ~= "table" or value == nil then
            return
        end
        for _, list in pairs(indexMap) do
            if type(list) == "table" then
                for i = #list, 1, -1 do
                    if list[i] == value then
                        tremove(list, i)
                    end
                end
            end
        end
    end

    local function indexLootRuntimeRow(runtime, loot, index, replaceExisting)
        if type(runtime) ~= "table" or type(loot) ~= "table" then
            return false
        end
        local resolvedIndex = tonumber(index)
        if type(resolvedIndex) ~= "number" or resolvedIndex <= 0 then
            return false
        end
        local lootNid = tonumber(loot.lootNid)
        if not lootNid then
            return false
        end

        runtime.lootIdxByNid[lootNid] = resolvedIndex
        runtime.lootByNid[lootNid] = loot

        if replaceExisting then
            removeRuntimeIndexListValue(runtime.lootIdxByBossNid, resolvedIndex)
            removeRuntimeIndexListValue(runtime.lootIdxByLooterNid, resolvedIndex)
        end

        local bossNid = tonumber(loot.bossNid)
        if bossNid and bossNid > 0 then
            appendRuntimeIndexList(runtime.lootIdxByBossNid, bossNid, resolvedIndex, replaceExisting == true)
        end

        local looterNid = tonumber(loot.looterNid)
        if looterNid and looterNid > 0 then
            appendRuntimeIndexList(runtime.lootIdxByLooterNid, looterNid, resolvedIndex, replaceExisting == true)
        end

        return true
    end

    local function normalizeRuntimeState(raid)
        if type(raid) ~= "table" then
            return
        end

        removeRootRuntimeCaches(raid)
        if type(raid._runtime) ~= "table" then
            raid._runtime = nil
        end
    end

    local function stripRuntimeState(raid)
        if type(raid) ~= "table" then
            return
        end
        removeRootRuntimeCaches(raid)
        raid._runtime = nil
    end

    local function buildRuntimeSignature(raid, players, bosses, lootRows, attendance)
        return format(
            "%d|%d|%d|%d|%d|%d|%d",
            #players,
            #bosses,
            #lootRows,
            #attendance,
            tonumber(raid.nextPlayerNid) or 1,
            tonumber(raid.nextBossNid) or 1,
            tonumber(raid.nextLootNid) or 1
        )
    end

    local function getRuntimeCollections(raid)
        return raid.players or {}, raid.bossKills or {}, raid.loot or {}, raid.attendance or {}
    end

    local function buildRaidRuntimeSignature(raid)
        local players, bosses, lootRows, attendance = getRuntimeCollections(raid)
        return buildRuntimeSignature(raid, players, bosses, lootRows, attendance)
    end

    local function refreshRuntimeSignature(raid, runtime)
        runtime.signature = buildRaidRuntimeSignature(raid)
        return runtime.signature
    end

    local function appendNormalizedAttendanceSegment(entry, segment)
        if type(segment) ~= "table" then
            return
        end

        local startTime = tonumber(segment.startTime) or 0
        if startTime <= 0 then
            return
        end

        local out = {
            startTime = startTime,
        }

        local endTime = tonumber(segment.endTime) or 0
        if endTime > startTime then
            out.endTime = endTime
        end

        local subgroup = tonumber(segment.subgroup) or 1
        if subgroup > 1 then
            out.subgroup = subgroup
        end

        if segment.online == false then
            out.online = false
        end

        entry.segments[#entry.segments + 1] = out
    end

    local function normalizeAttendance(attendance, validPlayerNids)
        local out = {}
        if type(attendance) ~= "table" then
            return out
        end

        local seenPlayers = {}
        for i = 1, #attendance do
            local rawEntry = attendance[i]
            local playerNid = type(rawEntry) == "table" and tonumber(rawEntry.playerNid) or 0
            if playerNid > 0 and validPlayerNids[playerNid] and not seenPlayers[playerNid] then
                local entry = {
                    playerNid = playerNid,
                    segments = {},
                }
                seenPlayers[playerNid] = true

                local segments = rawEntry.segments
                if type(segments) == "table" then
                    for j = 1, #segments do
                        appendNormalizedAttendanceSegment(entry, segments[j])
                    end
                end

                if #entry.segments > 0 then
                    out[#out + 1] = entry
                end
            end
        end

        return out
    end

    local function markRaidNidIndexDirty()
        storeState.raidNidIndexDirty = true
    end

    local function buildRaidNidIndexSignature(raids)
        local parts = {}
        for i = 1, #raids do
            local raid = raids[i]
            parts[i] = tostring(type(raid) == "table" and tonumber(raid.raidNid) or "")
        end
        return tconcat(parts, "|")
    end

    local function rebuildRaidNidIndex()
        local raids = ensureRaidsTable()
        local raidIdxByNid = {}
        local allocateRaidNid, getNextRaidNidValue = createNidAllocator(1)

        for i = 1, #raids do
            local raid = module:NormalizeRaidRecord(raids[i])
            if raid then
                local raidNid = allocateRaidNid(raid.raidNid)
                raid.raidNid = raidNid
                raidIdxByNid[raidNid] = i
            end
        end

        storeState.raidIdxByNid = raidIdxByNid
        storeState.nextRaidNid = getNextRaidNidValue()
        storeState.raidNidIndexCount = #raids
        storeState.raidNidIndexSignature = buildRaidNidIndexSignature(raids)
        storeState.raidNidIndexDirty = nil
        return raids, raidIdxByNid
    end

    local function ensureRaidNidIndex()
        local raids = ensureRaidsTable()
        local signature = buildRaidNidIndexSignature(raids)
        if
            storeState.raidNidIndexDirty ~= true
            and type(storeState.raidIdxByNid) == "table"
            and tonumber(storeState.raidNidIndexCount) == #raids
            and storeState.raidNidIndexSignature == signature
        then
            return raids, storeState.raidIdxByNid
        end
        return rebuildRaidNidIndex()
    end

    local function hasRawRaidNid(raids, raidNid)
        for i = 1, #raids do
            local raid = raids[i]
            if type(raid) == "table" and tonumber(raid.raidNid) == raidNid then
                return true, i
            end
        end
        return false, nil
    end

    local function getNextRaidNid(preferred)
        local raids, raidIdxByNid = ensureRaidNidIndex()
        local raidNid = tonumber(preferred)
        if raidNid and raidNid > 0 then
            local cachedIdx = raidIdxByNid[raidNid]
            if cachedIdx and tonumber(raids[cachedIdx] and raids[cachedIdx].raidNid) ~= raidNid then
                markRaidNidIndexDirty()
                raids, raidIdxByNid = rebuildRaidNidIndex()
                cachedIdx = raidIdxByNid[raidNid]
            elseif not cachedIdx then
                local exists = hasRawRaidNid(raids, raidNid)
                if exists then
                    markRaidNidIndexDirty()
                    raids, raidIdxByNid = rebuildRaidNidIndex()
                    cachedIdx = raidIdxByNid[raidNid]
                end
            end

            if not cachedIdx then
                if raidNid >= (tonumber(storeState.nextRaidNid) or 1) then
                    storeState.nextRaidNid = raidNid + 1
                end
                return raidNid
            end
        end

        local nextRaidNid = tonumber(storeState.nextRaidNid) or 1
        if nextRaidNid < 1 then
            nextRaidNid = 1
        end
        while raidIdxByNid[nextRaidNid] or hasRawRaidNid(raids, nextRaidNid) do
            nextRaidNid = nextRaidNid + 1
        end
        storeState.nextRaidNid = nextRaidNid + 1
        return nextRaidNid
    end

    local function buildRuntimeIndexesForNormalizedRaid(raid)
        if not raid then
            return nil
        end

        local runtime = ensureRuntimeTable(raid)
        local maps = acquireRuntimeIndexMaps(runtime)
        local players, bosses, lootRows, attendance = getRuntimeCollections(raid)
        for i = 1, #players do
            local player = players[i]
            if type(player) == "table" then
                if player.name then
                    maps.playersByName[player.name] = player
                end
                local playerNid = tonumber(player.playerNid)
                if playerNid then
                    maps.playerByNid[playerNid] = player
                    if player.name then
                        maps.playerNidByName[player.name] = playerNid
                    end
                    maps.playerIdxByNid[playerNid] = i
                end
            end
        end

        for i = 1, #attendance do
            local entry = attendance[i]
            local playerNid = type(entry) == "table" and tonumber(entry.playerNid) or nil
            if playerNid then
                maps.attendanceIdxByPlayerNid[playerNid] = i
                maps.attendanceByPlayerNid[playerNid] = entry
            end
        end

        for i = 1, #bosses do
            local boss = bosses[i]
            if type(boss) == "table" then
                local bossNid = tonumber(boss.bossNid)
                if bossNid then
                    maps.bossIdxByNid[bossNid] = i
                    maps.bossByNid[bossNid] = boss
                    local attendeeSet = {}
                    local attendees = boss.players
                    if type(attendees) == "table" then
                        for j = 1, #attendees do
                            local playerNid = tonumber(attendees[j])
                            if playerNid and playerNid > 0 then
                                attendeeSet[playerNid] = true
                            end
                        end
                    end
                    maps.bossPlayerSetByBossNid[bossNid] = attendeeSet
                end
            end
        end

        for i = 1, #lootRows do
            indexLootRuntimeRow(runtime, lootRows[i], i, false)
        end

        refreshRuntimeSignature(raid, runtime)

        return runtime
    end

    -- ----- Public methods ----- --
    function module:GetAllRaids()
        local raids = ensureRaidNidIndex()
        return raids
    end

    function module:GetRawRaids()
        return ensureRaidsTable()
    end

    function module:GetRaidByIndex(index)
        local idx = tonumber(index)
        if not idx or idx < 1 then
            return nil, nil
        end

        local raids = ensureRaidNidIndex()
        local raid = raids[idx]
        if not raid then
            return nil, idx
        end
        return self:NormalizeRaidRecord(raid), idx
    end

    function module:GetRaidByNid(raidNid)
        local nid = tonumber(raidNid)
        if not nid then
            return nil, nil, nil
        end

        local raids, raidIdxByNid = ensureRaidNidIndex()
        local idx = raidIdxByNid[nid]
        if idx and tonumber(raids[idx] and raids[idx].raidNid) ~= nid then
            markRaidNidIndexDirty()
            raids, raidIdxByNid = rebuildRaidNidIndex()
            idx = raidIdxByNid[nid]
        elseif not idx then
            local exists = hasRawRaidNid(raids, nid)
            if exists then
                markRaidNidIndexDirty()
                raids, raidIdxByNid = rebuildRaidNidIndex()
                idx = raidIdxByNid[nid]
            end
        end
        if not idx then
            return nil, nil, nid
        end

        local raid = raids[idx]
        if not raid then
            return nil, nil, nid
        end
        return self:NormalizeRaidRecord(raid), idx, nid
    end

    function module:GetRaidNidByIndex(index)
        local raid = self:GetRaidByIndex(index)
        return raid and tonumber(raid.raidNid) or nil
    end

    function module:GetRaidIndexByNid(raidNid)
        local _, idx = self:GetRaidByNid(raidNid)
        return idx
    end

    function module:NormalizeRaidRecord(raid, contextTag, raidIndex)
        if type(raid) ~= "table" then
            return nil
        end

        local schemaVersion = getSchemaVersion()
        local storedSchemaVersion = tonumber(raid.schemaVersion)

        raid.players = (type(raid.players) == "table") and raid.players or {}
        raid.bossKills = (type(raid.bossKills) == "table") and raid.bossKills or {}
        raid.loot = (type(raid.loot) == "table") and raid.loot or {}
        raid.changes = (type(raid.changes) == "table") and raid.changes or {}
        raid.attendance = (type(raid.attendance) == "table") and raid.attendance or {}

        local migrations = getMigrations()
        if migrations and migrations.MigrateRaidToCurrentSchema then
            migrations:MigrateRaidToCurrentSchema(raid, storedSchemaVersion, schemaVersion)
        end

        if not storedSchemaVersion or storedSchemaVersion < schemaVersion then
            raid.schemaVersion = schemaVersion
        else
            raid.schemaVersion = storedSchemaVersion
        end

        local allocatePlayerNid, getNextPlayerNid = createNidAllocator(raid.nextPlayerNid)
        local assignedByRef = {}

        local players = raid.players
        local validPlayerNids = {}
        for i = 1, #players do
            local player = players[i]
            if type(player) == "table" then
                local assigned = assignedByRef[player]
                if assigned then
                    player.playerNid = assigned
                else
                    local playerNid = allocatePlayerNid(player.playerNid)
                    player.playerNid = playerNid
                    assignedByRef[player] = playerNid
                end

                local countMS = tonumber(player.countMS) or 0
                if countMS < 0 then
                    countMS = 0
                end
                player.countMS = countMS
                player.count = nil

                local countOs = tonumber(player.countOs) or 0
                if countOs < 0 then
                    countOs = 0
                end
                player.countOs = countOs

                local countFree = tonumber(player.countFree) or 0
                if countFree < 0 then
                    countFree = 0
                end
                player.countFree = countFree

                local countSR = tonumber(player.countSR) or 0
                if countSR < 0 then
                    countSR = 0
                end
                player.countSR = countSR

                local playerNid = tonumber(player.playerNid)
                if playerNid and playerNid > 0 then
                    validPlayerNids[playerNid] = true
                end
            end
        end

        local allocateBossNid, getNextBossNid = createNidAllocator(raid.nextBossNid)

        local bosses = raid.bossKills
        for i = 1, #bosses do
            local boss = bosses[i]
            if type(boss) == "table" then
                boss.bossNid = allocateBossNid(boss.bossNid)

                local attendees = {}
                local seen = {}
                if isBossFightRecord(boss) then
                    local rawPlayers = boss.players
                    if type(rawPlayers) == "table" then
                        for j = 1, #rawPlayers do
                            local rawPlayer = rawPlayers[j]
                            local playerNid = tonumber(rawPlayer)
                            if playerNid and playerNid > 0 and validPlayerNids[playerNid] and not seen[playerNid] then
                                seen[playerNid] = true
                                attendees[#attendees + 1] = playerNid
                            end
                        end
                    end
                    if #attendees == 0 then
                        local killTime = tonumber(boss.time) or 0
                        for j = 1, #players do
                            local player = players[j]
                            local playerNid = player and tonumber(player.playerNid) or nil
                            if playerNid and validPlayerNids[playerNid] and not seen[playerNid] then
                                local include = true
                                if killTime > 0 then
                                    local joinTime = tonumber(player.join)
                                    if joinTime and joinTime > killTime then
                                        include = false
                                    end
                                    local leaveTime = tonumber(player.leave)
                                    if leaveTime and leaveTime > 0 and leaveTime < killTime then
                                        include = false
                                    end
                                end
                                if include then
                                    seen[playerNid] = true
                                    attendees[#attendees + 1] = playerNid
                                end
                            end
                        end
                    end
                end
                boss.players = attendees
                boss.attendanceMask = nil
            end
        end

        local allocateLootNid, getNextLootNid = createNidAllocator(raid.nextLootNid)

        local lootRows = raid.loot
        for i = 1, #lootRows do
            local loot = lootRows[i]
            if type(loot) == "table" then
                loot.lootNid = allocateLootNid(loot.lootNid)

                local looterNid = tonumber(loot.looterNid)
                if looterNid and looterNid > 0 and validPlayerNids[looterNid] then
                    loot.looterNid = looterNid
                else
                    loot.looterNid = nil
                end
                loot.looter = nil
            end
        end

        raid.attendance = normalizeAttendance(raid.attendance, validPlayerNids)

        raid.nextPlayerNid = getNextPlayerNid()
        raid.nextBossNid = getNextBossNid()
        raid.nextLootNid = getNextLootNid()
        raid.raidNid = tonumber(raid.raidNid)

        normalizeRuntimeState(raid)
        return raid
    end

    function module:EnsureRaidRuntime(raid)
        raid = self:NormalizeRaidRecord(raid)
        if not raid then
            return nil
        end

        local runtime = raid._runtime
        local signature = buildRaidRuntimeSignature(raid)
        if isRuntimeIndexReady(runtime) and runtime.signature == signature then
            return runtime
        end
        return buildRuntimeIndexesForNormalizedRaid(raid)
    end

    function module:GetRaidSyncRevision(raid)
        return ensureSyncRevision(raid)
    end

    function module:SetRaidSyncRevision(raid, revision, reason)
        if type(raid) ~= "table" then
            return 0
        end
        local runtime = ensureRuntimeTable(raid)
        local resolvedRevision = tonumber(revision) or 0
        if resolvedRevision < 0 then
            resolvedRevision = 0
        end
        runtime.syncRevision = resolvedRevision
        runtime.lastSyncRevisionReason = tostring(reason or "sync")
        if type(runtime.lootSyncRevisionByNid) ~= "table" then
            runtime.lootSyncRevisionByNid = {}
        end
        return resolvedRevision
    end

    function module:TouchRaidSyncRevision(raid, reason)
        if type(raid) ~= "table" then
            return 0
        end
        local runtime = ensureRuntimeTable(raid)
        runtime.syncRevision = (tonumber(runtime.syncRevision) or 0) + 1
        local resolvedReason = tostring(reason or "change")
        runtime.lastSyncRevisionReason = resolvedReason
        if type(runtime.lootSyncRevisionByNid) ~= "table" then
            runtime.lootSyncRevisionByNid = {}
        end
        if resolvedReason ~= "loot_row" then
            runtime.fullSyncRevision = runtime.syncRevision
        end
        return runtime.syncRevision
    end

    function module:MarkLootSyncRevision(raid, loot, reason)
        if type(raid) ~= "table" or type(loot) ~= "table" then
            return 0
        end
        local lootNid = tonumber(loot.lootNid)
        if not lootNid or lootNid <= 0 then
            return self:TouchRaidSyncRevision(raid, reason or "loot")
        end
        local revision = self:TouchRaidSyncRevision(raid, reason or "loot_row")
        local runtime = ensureRuntimeTable(raid)
        if type(runtime.lootSyncRevisionByNid) ~= "table" then
            runtime.lootSyncRevisionByNid = {}
        end
        runtime.lootSyncRevisionByNid[lootNid] = revision
        return revision
    end

    function module:SetLootSyncRevision(raid, loot, revision)
        if type(raid) ~= "table" or type(loot) ~= "table" then
            return 0
        end
        local lootNid = tonumber(loot.lootNid)
        if not lootNid or lootNid <= 0 then
            return self:SetRaidSyncRevision(raid, revision, "delta")
        end
        local resolvedRevision = self:SetRaidSyncRevision(raid, revision, "delta")
        local runtime = ensureRuntimeTable(raid)
        if type(runtime.lootSyncRevisionByNid) ~= "table" then
            runtime.lootSyncRevisionByNid = {}
        end
        runtime.lootSyncRevisionByNid[lootNid] = resolvedRevision
        return resolvedRevision
    end

    function module:RequiresFullSyncSince(raid, sinceRevision)
        if type(raid) ~= "table" then
            return true
        end
        local runtime = ensureRuntimeTable(raid)
        local fullSyncRevision = tonumber(runtime.fullSyncRevision) or 0
        return fullSyncRevision > (tonumber(sinceRevision) or 0)
    end

    function module:GetLootSyncRevision(raid, loot)
        if type(raid) ~= "table" or type(loot) ~= "table" then
            return 0
        end
        local lootNid = tonumber(loot.lootNid)
        if not lootNid or lootNid <= 0 then
            return 0
        end
        local runtime = ensureRuntimeTable(raid)
        local revisions = runtime.lootSyncRevisionByNid
        return tonumber(type(revisions) == "table" and revisions[lootNid]) or tonumber(loot.syncRevision) or 0
    end

    function module:UpsertLootIndex(raid, loot, index)
        raid = self:NormalizeRaidRecord(raid)
        if not raid then
            return nil
        end

        local runtime = raid._runtime
        if not isRuntimeIndexReady(runtime) then
            return nil
        end

        local lootRows = raid.loot or {}
        local resolvedIndex = tonumber(index) or #lootRows
        local row = loot or lootRows[resolvedIndex]
        local lootNid = tonumber(row and row.lootNid)
        if not lootNid or resolvedIndex < 1 then
            return nil
        end

        if not indexLootRuntimeRow(runtime, row, resolvedIndex, true) then
            return nil
        end
        refreshRuntimeSignature(raid, runtime)
        return runtime
    end

    function module:StripRuntime(raid)
        if type(raid) ~= "table" then
            return
        end
        stripRuntimeState(raid)
    end

    function module:StripAllRuntime()
        local raids = ensureRaidsTable()
        for i = 1, #raids do
            self:StripRuntime(raids[i])
        end
    end

    function module:NormalizeAllRaids(contextTag)
        local raids = ensureRaidsTable()
        markRaidNidIndexDirty()
        for i = 1, #raids do
            self:NormalizeRaidRecord(raids[i], contextTag, i)
        end
        rebuildRaidNidIndex()
        return raids
    end

    function module:PrepareRaidForSave(raid, raidIndex)
        raid = self:NormalizeRaidRecord(raid, "save", raidIndex)
        if not raid then
            return nil
        end

        self:StripRuntime(raid)

        local migrations = getMigrations()
        if migrations and migrations.CompactRaidForPersistence then
            migrations:CompactRaidForPersistence(raid)
        end

        return raid
    end

    function module:PrepareAllRaidsForSave()
        local raids = ensureRaidsTable()
        for i = 1, #raids do
            self:PrepareRaidForSave(raids[i], i)
        end
    end

    function module:CreateRaidRecord(args)
        args = args or {}

        local raidNid = getNextRaidNid(args.raidNid)
        local startTime = args.startTime
        if startTime == nil then
            startTime = (Time and Time.GetCurrentTime and Time.GetCurrentTime()) or time()
        end

        local raid = {
            schemaVersion = getSchemaVersion(),
            raidNid = raidNid,
            realm = args.realm,
            zone = args.zone,
            size = args.size,
            difficulty = args.difficulty,
            startTime = startTime,
            endTime = args.endTime,
            players = {},
            bossKills = {},
            loot = {},
            changes = {},
            attendance = {},
            nextBossNid = 1,
            nextLootNid = 1,
            nextPlayerNid = 1,
        }

        return self:NormalizeRaidRecord(raid)
    end

    function module:InsertRaid(raid)
        raid = self:NormalizeRaidRecord(raid)
        if not raid then
            return nil, nil
        end

        local raidNid = getNextRaidNid(raid.raidNid)
        raid.raidNid = raidNid

        local raids = ensureRaidsTable()
        tinsert(raids, raid)
        markRaidNidIndexDirty()
        rebuildRaidNidIndex()

        local idx = (storeState.raidIdxByNid and storeState.raidIdxByNid[raidNid]) or #raids
        return raid, idx
    end

    function module:DeleteRaid(raidNid)
        local raid, idx = self:GetRaidByNid(raidNid)
        if not (raid and idx) then
            return false, nil
        end

        local raids = ensureRaidsTable()
        tremove(raids, idx)
        markRaidNidIndexDirty()
        rebuildRaidNidIndex()
        return true, idx
    end
end

local registry = feature.ModuleRegistry
if type(registry) == "table" and type(registry.AddModule) == "function" and type(registry.SetLoaded) == "function" then
    registry.AddModule("Database/DBRaidStore", {
        deps = { "Init", "Modules/ModuleRegistry", "Database/DB", "Database/DBSchema", "Database/DBRaidMigrations", "Modules/Time", "Modules/Strings" },
    })
    registry.SetLoaded("Database/DBRaidStore")
end

