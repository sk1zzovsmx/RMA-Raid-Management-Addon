-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: local feature = addon.Database.GetFeatureShared()
-- exports: publish module APIs on addon.*
-- events: none
local addon = select(2, ...)
local feature = addon.Database.GetFeatureShared()

local L = feature.L
local DB = feature.DB
local Database = feature.Database
local IgnoredMobs = feature.IgnoredMobs

local pairs, type, tonumber = pairs, type, tonumber
local strsub = string.sub
local tostring = tostring
local IsTrashMobName = IgnoredMobs.IsTrashMobName

-- Read-only raid validation service.
do
    DB.RaidValidator = DB.RaidValidator or {}
    local module = DB.RaidValidator

    -- ----- Internal state ----- --

    -- ----- Private helpers ----- --
    local function deepCopy(value, seen)
        if type(value) ~= "table" then
            return value
        end

        seen = seen or {}
        if seen[value] then
            return seen[value]
        end

        local out = {}
        seen[value] = out
        for key, item in pairs(value) do
            if key ~= "_runtime" then
                out[deepCopy(key, seen)] = deepCopy(item, seen)
            end
        end
        return out
    end

    local function ensureNormalizedClone(raid)
        local clone = deepCopy(raid)
        if type(clone) ~= "table" then
            return nil
        end

        local raidStore = Database.GetRaidStoreOrNil("DBRaidValidator.EnsureNormalizedClone", { "NormalizeRaidRecord" })
        if raidStore then
            clone = raidStore:NormalizeRaidRecord(clone)
        end

        if type(clone) ~= "table" then
            return nil
        end

        clone.players = (type(clone.players) == "table") and clone.players or {}
        clone.bossKills = (type(clone.bossKills) == "table") and clone.bossKills or {}
        clone.loot = (type(clone.loot) == "table") and clone.loot or {}
        clone.changes = (type(clone.changes) == "table") and clone.changes or {}

        return clone
    end

    local function pushDetail(result, level, code, data)
        local details = result.details
        details[#details + 1] = {
            level = level,
            code = code,
            data = data or {},
        }

        if level == "E" then
            result.err = result.err + 1
        elseif level == "W" then
            result.warn = result.warn + 1
        else
            result.ok = result.ok + 1
        end
    end

    local function validateRaidSourceKeys(result, raid)
        for key in pairs(raid) do
            if type(key) == "string" and strsub(key, 1, 1) == "_" and key ~= "_runtime" then
                pushDetail(result, "E", "RUNTIME_OUTSIDE", { key = key })
            end
        end
    end

    local function validateSchemaVersion(result, normalized, currentSchemaVersion)
        local schemaVersion = tonumber(normalized.schemaVersion)
        if not schemaVersion then
            pushDetail(result, "E", "SCHEMA_MISSING")
        elseif schemaVersion > currentSchemaVersion then
            pushDetail(result, "E", "SCHEMA_NEWER", {
                schemaVersion = schemaVersion,
                currentVersion = currentSchemaVersion,
            })
        else
            result.ok = result.ok + 1
        end
    end

    local function validatePlayers(result, players)
        local maxPlayerNid = 0
        local playerByNid = {}

        for i = 1, #players do
            local player = players[i]
            if type(player) == "table" then
                local playerNid = tonumber(player.playerNid) or 0
                if playerNid > maxPlayerNid then
                    maxPlayerNid = playerNid
                end
                if playerNid > 0 then
                    playerByNid[playerNid] = true
                end

                local countMS = tonumber(player.countMS)
                if countMS == nil then
                    pushDetail(result, "E", "PLAYER_COUNT_TYPE", { playerIndex = i })
                elseif countMS < 0 then
                    pushDetail(result, "E", "PLAYER_COUNT_NEGATIVE", {
                        playerIndex = i,
                        value = countMS,
                    })
                else
                    result.ok = result.ok + 1
                end
            end
        end

        return maxPlayerNid, playerByNid
    end

    local function validateBosses(result, bosses, playerByNid)
        local maxBossNid = 0
        local bossByNid = {}
        local hasTrashBoss = false

        for i = 1, #bosses do
            local boss = bosses[i]
            if type(boss) == "table" then
                local bossNid = tonumber(boss.bossNid) or 0
                if bossNid > maxBossNid then
                    maxBossNid = bossNid
                end
                if bossNid > 0 then
                    bossByNid[bossNid] = true
                end
                if IsTrashMobName(boss.name) then
                    hasTrashBoss = true
                end

                local attendees = boss.players
                if type(attendees) == "table" then
                    for j = 1, #attendees do
                        local attendeeNid = tonumber(attendees[j]) or 0
                        if attendeeNid <= 0 then
                            pushDetail(result, "E", "BOSS_ATTENDEE_INVALID", {
                                bossIndex = i,
                                attendeeIndex = j,
                            })
                        elseif not playerByNid[attendeeNid] then
                            pushDetail(result, "E", "BOSS_ATTENDEE_MISSING_PLAYER", {
                                bossIndex = i,
                                attendeeIndex = j,
                                playerNid = attendeeNid,
                            })
                        else
                            result.ok = result.ok + 1
                        end
                    end
                end
            end
        end

        return maxBossNid, bossByNid, hasTrashBoss
    end

    local function validateAttendance(result, attendance, playerByNid)
        if type(attendance) ~= "table" then
            return
        end

        for i = 1, #attendance do
            local entry = attendance[i]
            if type(entry) == "table" then
                local playerNid = tonumber(entry.playerNid) or 0
                if playerNid <= 0 then
                    pushDetail(result, "E", "ATTENDANCE_PLAYER_INVALID", { attendanceIndex = i })
                elseif not playerByNid[playerNid] then
                    pushDetail(result, "E", "ATTENDANCE_PLAYER_MISSING", {
                        attendanceIndex = i,
                        playerNid = playerNid,
                    })
                else
                    result.ok = result.ok + 1
                end

                local segments = entry.segments
                if type(segments) == "table" then
                    for j = 1, #segments do
                        local segment = segments[j]
                        if type(segment) == "table" then
                            local startTime = tonumber(segment.startTime) or 0
                            local endTime = tonumber(segment.endTime) or 0
                            if startTime <= 0 then
                                pushDetail(result, "E", "ATTENDANCE_SEGMENT_START_INVALID", {
                                    attendanceIndex = i,
                                    segmentIndex = j,
                                })
                            elseif endTime > 0 and endTime < startTime then
                                pushDetail(result, "E", "ATTENDANCE_SEGMENT_END_INVALID", {
                                    attendanceIndex = i,
                                    segmentIndex = j,
                                })
                            else
                                result.ok = result.ok + 1
                            end
                        end
                    end
                end
            end
        end
    end

    local function validateLootRows(result, lootRows, bossByNid, playerByNid, hasTrashBoss)
        local maxLootNid = 0

        for i = 1, #lootRows do
            local loot = lootRows[i]
            if type(loot) == "table" then
                local lootNid = tonumber(loot.lootNid) or 0
                if lootNid > maxLootNid then
                    maxLootNid = lootNid
                end

                local lootBossNid = tonumber(loot.bossNid) or 0
                if lootBossNid > 0 and not bossByNid[lootBossNid] then
                    pushDetail(result, "E", "LOOT_MISSING_BOSS", {
                        lootIndex = i,
                        bossNid = lootBossNid,
                    })
                elseif lootBossNid <= 0 and not hasTrashBoss then
                    pushDetail(result, "W", "LOOT_UNKNOWN_BOSS_WITHOUT_TRASH", {
                        lootIndex = i,
                    })
                else
                    result.ok = result.ok + 1
                end

                local looterNid = tonumber(loot.looterNid) or 0
                if looterNid > 0 and not playerByNid[looterNid] then
                    pushDetail(result, "E", "LOOT_MISSING_LOOTER", {
                        lootIndex = i,
                        looterNid = looterNid,
                    })
                elseif looterNid <= 0 then
                    pushDetail(result, "W", "LOOT_MISSING_LOOTER", {
                        lootIndex = i,
                    })
                else
                    result.ok = result.ok + 1
                end
            end
        end

        return maxLootNid
    end

    local function validateNidCounter(result, normalized, field, required)
        local actual = tonumber(normalized[field]) or 0
        if actual < required then
            pushDetail(result, "E", "COUNTER_TOO_LOW", {
                field = field,
                actual = actual,
                required = required,
            })
        else
            result.ok = result.ok + 1
        end
    end

    local function validateNidCounters(result, normalized, maxPlayerNid, maxBossNid, maxLootNid)
        validateNidCounter(result, normalized, "nextPlayerNid", maxPlayerNid + 1)
        validateNidCounter(result, normalized, "nextBossNid", maxBossNid + 1)
        validateNidCounter(result, normalized, "nextLootNid", maxLootNid + 1)
    end

    -- ----- Public methods ----- --
    function module:GetRaidRecordValidation(raid, index, currentSchemaVersion)
        local raidNid = type(raid) == "table" and tonumber(raid.raidNid) or nil
        local result = {
            index = tonumber(index) or 0,
            raidNid = raidNid,
            ok = 0,
            warn = 0,
            err = 0,
            details = {},
        }

        if type(raid) ~= "table" then
            pushDetail(result, "E", "RAID_NOT_TABLE")
            return result
        end

        -- Validate source keys directly (without normalization side effects).
        validateRaidSourceKeys(result, raid)

        local normalized = ensureNormalizedClone(raid)
        if type(normalized) ~= "table" then
            pushDetail(result, "E", "NORMALIZE_FAILED")
            return result
        end

        validateSchemaVersion(result, normalized, currentSchemaVersion)

        local players = normalized.players
        local bosses = normalized.bossKills
        local lootRows = normalized.loot
        local attendance = normalized.attendance

        local maxPlayerNid, playerByNid = validatePlayers(result, players)
        validateAttendance(result, attendance, playerByNid)
        local maxBossNid, bossByNid, hasTrashBoss = validateBosses(result, bosses, playerByNid)
        local maxLootNid = validateLootRows(result, lootRows, bossByNid, playerByNid, hasTrashBoss)
        validateNidCounters(result, normalized, maxPlayerNid, maxBossNid, maxLootNid)

        return result
    end

    function module:ValidateAllRaids(opts)
        opts = opts or {}
        local includeInfo = opts.includeInfo == true
        local maxDetails = tonumber(opts.maxDetails) or 40
        if maxDetails < 1 then
            maxDetails = 1
        end

        local currentSchemaVersion = Database.GetRaidSchemaVersion() or 1
        currentSchemaVersion = tonumber(currentSchemaVersion) or 1
        if currentSchemaVersion < 1 then
            currentSchemaVersion = 1
        end

        local raidStore = Database.GetRaidStoreOrNil("DBRaidValidator.ValidateAllRaids", { "GetRawRaids" })
        local raids = raidStore and raidStore:GetRawRaids() or {}
        raids = (type(raids) == "table") and raids or {}
        local report = {
            raids = #raids,
            ok = 0,
            warn = 0,
            err = 0,
            currentSchemaVersion = currentSchemaVersion,
            details = {},
            truncatedCount = 0,
        }

        for i = 1, #raids do
            local raidResult = self:GetRaidRecordValidation(raids[i], i, currentSchemaVersion)
            report.ok = report.ok + (raidResult.ok or 0)
            report.warn = report.warn + (raidResult.warn or 0)
            report.err = report.err + (raidResult.err or 0)

            local details = raidResult.details or {}
            for j = 1, #details do
                local entry = details[j]
                if entry.level ~= "I" or includeInfo then
                    if #report.details < maxDetails then
                        report.details[#report.details + 1] = {
                            level = entry.level,
                            code = entry.code,
                            data = entry.data,
                            index = raidResult.index,
                            raidNid = raidResult.raidNid,
                        }
                    else
                        report.truncatedCount = report.truncatedCount + 1
                    end
                end
            end
        end

        return report
    end
end

local registry = feature.ModuleRegistry
if type(registry) == "table" and type(registry.AddModule) == "function" and type(registry.SetLoaded) == "function" then
    registry.AddModule("Database/DBRaidValidator", {
        deps = { "Init", "Modules/ModuleRegistry", "Database/DB", "Database/DBSchema", "Database/DBRaidMigrations", "Database/DBRaidStore", "Modules/Dataset/IgnoredMobs" },
    })
    registry.SetLoaded("Database/DBRaidValidator")
end

