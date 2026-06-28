-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: local feature = addon.Database.GetFeatureShared()
-- exports: publish module APIs on addon.*
-- events: none
local addon = select(2, ...)
local feature = addon.Database.GetFeatureShared()

local Sort = feature.Sort
local Database = feature.Database
local Services = feature.Services
local LootSourceCandidates = feature.LootSourceCandidates

local GetLootSortName = Sort.GetLootSortName

local twipe = table.wipe
local tostring, tonumber = tostring, tonumber
local date, time = date, time
local floor = math.floor

-- ----- Internal state ----- --
feature.EnsureServiceNamespace("Logger", "View")
local Logger = Services.Logger
local View = Logger.View
local Store = Logger.Store
local buildRows
local isBossFightRecord = Database.IsBossFightRecord

-- ----- Private helpers ----- --
local function getOutputCount(out)
    if type(out) ~= "table" then
        return 0
    end
    return #out
end

local function buildRaidListRow(raid, seq, queries)
    if not raid then
        return nil
    end

    local summary = queries and queries.GetRaidSummary and queries:GetRaidSummary(raid) or nil
    local row = {}
    row.id = tonumber(raid.raidNid)
    row.seq = seq
    row.zone = raid.zone
    row.size = (summary and summary.size) or raid.size
    row.difficulty = tonumber((summary and summary.difficulty) or raid.difficulty)
    local mode = row.difficulty and ((row.difficulty == 3 or row.difficulty == 4) and "H" or "N") or "?"
    row.sizeLabel = tostring(row.size or "") .. mode
    row.date = (summary and summary.startTime) or raid.startTime
    row.dateFmt = date("%d/%m/%y %H:%M", row.date)
    return row
end

local function getRaidPerfId(raid)
    return tostring((raid and raid.raidNid) or "?")
end

local function getEquipInspectSnapshot(raid, playerNid)
    local equipInspect = Services.EquipInspect
    local nid = tonumber(playerNid)
    if not nid then
        return nil
    end

    if equipInspect and type(equipInspect.GetSnapshot) == "function" then
        local snapshot = equipInspect:GetSnapshot(raid, nid)
        if snapshot then
            return snapshot
        end
    end

    local inspectData = raid and raid.inspect
    local players = inspectData and inspectData.players
    if type(players) ~= "table" then
        return nil
    end

    return players[nid] or players[tostring(nid)]
end

local function enrichAttendanceRowsWithInspect(raid, out)
    if type(out) ~= "table" then
        return
    end

    for i = 1, #out do
        local row = out[i]
        local rowId = tonumber(row.playerNid) or tonumber(row.id)
        row.playerNid = rowId

        if rowId then
            local snapshot = getEquipInspectSnapshot(raid, rowId)
            row.inspect = snapshot
            if snapshot then
                local avgIlvl = tonumber(snapshot.avgIlvl)
                row.avgIlvl = avgIlvl
                if avgIlvl and avgIlvl > 0 then
                    row.avgIlvlFmt = tostring(floor(avgIlvl + 0.5))
                else
                    row.avgIlvlFmt = ""
                end
                row.specName = snapshot.specName
                row.specFmt = snapshot.specName or ""
                row.secondarySpecName = snapshot.secondarySpecName
                row.secondarySpecIcon = snapshot.secondarySpecIcon
            else
                row.avgIlvl = nil
                row.avgIlvlFmt = ""
                row.specName = nil
                row.specFmt = ""
                row.secondarySpecName = nil
                row.secondarySpecIcon = nil
            end
        else
            row.inspect = nil
            row.avgIlvl = nil
            row.avgIlvlFmt = ""
            row.specName = nil
            row.specFmt = ""
            row.secondarySpecName = nil
            row.secondarySpecIcon = nil
        end
    end
end

local function finishPerf(label, startedAt, raid, out, extraDetails)
    if not (startedAt and addon._PerfFinish) then
        return
    end

    local details = "raid=" .. getRaidPerfId(raid) .. " rows=" .. tostring(getOutputCount(out))
    if extraDetails and extraDetails ~= "" then
        details = details .. " " .. tostring(extraDetails)
    end
    addon:_PerfFinish(label, startedAt, details)
end

-- ----- Public methods ----- --

function View:GetBossModeLabel(bossData)
    if not bossData then
        return "?"
    end
    local mode = bossData.mode
    if not mode and bossData.difficulty then
        mode = (bossData.difficulty == 3 or bossData.difficulty == 4) and "h" or "n"
    end
    return (mode == "h") and "H" or "N"
end

function View:GetRaidDifficultyLabel(raid)
    local diff = tonumber(raid and raid.difficulty)
    local size = tonumber(raid and raid.size)
    if diff == 1 then
        return "10N"
    elseif diff == 2 then
        return "25N"
    elseif diff == 3 then
        return "10H"
    elseif diff == 4 then
        return "25H"
    end
    if size then
        return tostring(size) .. "?"
    end
    return ""
end

buildRows = function(out, list, pred, map)
    if not out then
        return
    end
    twipe(out)
    if not list then
        return
    end
    local n = 0
    for i = 1, #list do
        local e = list[i]
        if (not pred) or pred(e, i) then
            n = n + 1
            out[n] = map(e, i, n)
        end
    end
end

function View:FillBossList(out, raid)
    local perfStart = addon.hasPerf and addon._PerfStart and addon:_PerfStart() or nil
    local queries = Database.GetRaidQueriesOrNil()
    if queries and queries.GetBossKills then
        local result = queries:GetBossKills(raid, out)
        finishPerf("Logger.View.FillBossList", perfStart, raid, out)
        return result
    end
    buildRows(out, raid and raid.bossKills, nil, function(boss, i)
        local it = {}
        it.id = tonumber(boss and boss.bossNid)
        it.seq = i
        it.name = boss and boss.name or ""
        it.time = boss and boss.time or time()
        it.timeFmt = date("%H:%M", it.time)
        it.mode = self:GetBossModeLabel(boss)
        return it
    end)
    finishPerf("Logger.View.FillBossList", perfStart, raid, out)
end

function View:FillRaidAttendeesList(out, raid)
    local perfStart = addon.hasPerf and addon._PerfStart and addon:_PerfStart() or nil
    local queries = Database.GetRaidQueriesOrNil()
    if queries and queries.GetRaidAttendance then
        local result = queries:GetRaidAttendance(raid, out)
        enrichAttendanceRowsWithInspect(raid, out)
        finishPerf("Logger.View.FillRaidAttendeesList", perfStart, raid, out)
        return result
    end
    buildRows(out, raid and raid.players, nil, function(p)
        local it = {}
        it.id = tonumber(p and p.playerNid)
        it.name = p.name
        it.class = p.class
        it.join = p.join
        it.leave = p.leave
        it.joinFmt = p.join and date("%H:%M", p.join) or ""
        it.leaveFmt = p.leave and date("%H:%M", p.leave) or ""
        return it
    end)
    enrichAttendanceRowsWithInspect(raid, out)
    finishPerf("Logger.View.FillRaidAttendeesList", perfStart, raid, out)
end

function View:FillBossAttendeesList(out, raid, bossNid)
    local perfStart = addon.hasPerf and addon._PerfStart and addon:_PerfStart() or nil
    local queries = Database.GetRaidQueriesOrNil()
    if queries and queries.GetBossAttendance then
        local result = queries:GetBossAttendance(raid, bossNid, out)
        finishPerf("Logger.View.FillBossAttendeesList", perfStart, raid, out, "boss=" .. tostring(bossNid or "?"))
        return result
    end
    if not out then
        finishPerf("Logger.View.FillBossAttendeesList", perfStart, raid, out, "boss=" .. tostring(bossNid or "?"))
        return
    end
    twipe(out)
    if not (raid and bossNid) then
        finishPerf("Logger.View.FillBossAttendeesList", perfStart, raid, out, "boss=" .. tostring(bossNid or "?"))
        return
    end
    local bossKill = Store:GetBoss(raid, bossNid)
    if not (bossKill and isBossFightRecord(bossKill) and bossKill.players and raid.players) then
        finishPerf("Logger.View.FillBossAttendeesList", perfStart, raid, out, "boss=" .. tostring(bossNid or "?"))
        return
    end

    local set = {}
    for i = 1, #bossKill.players do
        local playerNid = tonumber(bossKill.players[i])
        if playerNid and playerNid > 0 then
            set[playerNid] = true
        end
    end

    local n = 0
    for i = 1, #raid.players do
        local p = raid.players[i]
        local playerNid = p and tonumber(p.playerNid) or nil
        if p and p.name and playerNid and set[playerNid] then
            n = n + 1
            local it = {}
            it.id = playerNid
            it.name = p.name
            it.class = p.class
            out[n] = it
        end
    end
    finishPerf("Logger.View.FillBossAttendeesList", perfStart, raid, out, "boss=" .. tostring(bossNid or "?"))
end

function View:GetPlayerBossParticipationList(out, raid, playerNid)
    local perfStart = addon.hasPerf and addon._PerfStart and addon:_PerfStart() or nil
    if not out then
        finishPerf("Logger.View.GetPlayerBossParticipationList", perfStart, raid, out, "player=" .. tostring(playerNid or "?"))
        return
    end
    twipe(out)
    local selectedPlayerNid = tonumber(playerNid)
    if not (raid and selectedPlayerNid) then
        finishPerf("Logger.View.GetPlayerBossParticipationList", perfStart, raid, out, "player=" .. tostring(playerNid or "?"))
        return
    end

    local bosses = raid.bossKills or {}
    local n = 0
    for i = 1, #bosses do
        local boss = bosses[i]
        local players = boss and boss.players
        if isBossFightRecord(boss) and type(players) == "table" then
            for j = 1, #players do
                if tonumber(players[j]) == selectedPlayerNid then
                    n = n + 1
                    local it = {}
                    local killTime = tonumber(boss.time) or 0
                    it.id = tonumber(boss.bossNid)
                    it.seq = i
                    it.name = boss.name or ""
                    it.time = killTime
                    it.timeFmt = (killTime > 0) and date("%H:%M", killTime) or ""
                    it.mode = self:GetBossModeLabel(boss)
                    out[n] = it
                    break
                end
            end
        end
    end
    finishPerf("Logger.View.GetPlayerBossParticipationList", perfStart, raid, out, "player=" .. tostring(playerNid or "?"))
end

function View:FillLootList(out, raid, bossNid, playerName)
    local perfStart = addon.hasPerf and addon._PerfStart and addon:_PerfStart() or nil
    local queries = Database.GetRaidQueriesOrNil()
    if queries and queries.GetLoot then
        local result = queries:GetLoot(raid, bossNid, playerName, out)
        finishPerf("Logger.View.FillLootList", perfStart, raid, out, "boss=" .. tostring(bossNid or "?") .. " player=" .. tostring(playerName or ""))
        return result
    end
    local bossFilter = tonumber(bossNid) or bossNid
    local playerFilterNid = Store._ResolveLootLooterNid(raid, playerName)
    buildRows(out, raid and raid.loot, function(v)
        if not v then
            return false
        end
        local okBoss = (not bossFilter) or (bossFilter <= 0) or (tonumber(v.bossNid) == bossFilter)
        local looterNid = tonumber(v.looterNid)
        local looterName = Store._ResolveLootLooterName(raid, v)
        local okPlayer = not playerName or (playerFilterNid and looterNid and playerFilterNid == looterNid) or ((not playerFilterNid) and looterName and looterName == playerName)
        return okBoss and okPlayer
    end, function(v)
        local it = {}
        it.id = v.lootNid
        it.itemId = v.itemId
        it.itemName = v.itemName
        it.itemRarity = v.itemRarity
        it.itemTexture = v.itemTexture
        it.itemLink = v.itemLink
        it.bossNid = v.bossNid
        it.sortName = GetLootSortName(v.itemName, v.itemLink, v.itemId)
        local boss = Store:GetBoss(raid, v.bossNid)
        local sourceName, sourceKind, sourceCandidates, sourceKey = LootSourceCandidates.BuildLootSourceModel(v, boss)
        it.sourceName = sourceName or ""
        it.sourceKind = sourceKind
        it.sourceCandidates = sourceCandidates
        it.sourceKey = sourceKey
        it.looterNid = tonumber(v.looterNid)
        it.looter = Store._ResolveLootLooterName(raid, v) or ""
        it.looterClass = Store._ResolveLootLooterClass(raid, v)
        it.rollType = tonumber(v.rollType) or 0
        it.rollValue = v.rollValue
        it.time = v.time or time()
        it.timeFmt = date("%H:%M", it.time)
        return it
    end)
    finishPerf("Logger.View.FillLootList", perfStart, raid, out, "boss=" .. tostring(bossNid or "?") .. " player=" .. tostring(playerName or ""))
end

function View:FillRaidList(out, contextTag)
    if type(out) ~= "table" then
        return
    end

    local perfStart = addon.hasPerf and addon._PerfStart and addon:_PerfStart() or nil
    twipe(out)
    local raidStore = Database.GetRaidStoreOrNil(contextTag, { "GetAllRaids", "GetRaidByIndex" })
    local raids = raidStore and raidStore:GetAllRaids() or {}
    local queries = Database.GetRaidQueries and Database.GetRaidQueries() or nil
    for i = 1, #raids do
        local raid = (raidStore and raidStore:GetRaidByIndex(i)) or Database.EnsureRaidById(i)
        local row = buildRaidListRow(raid, i, queries)
        if row then
            out[i] = row
        end
    end
    finishPerf("Logger.View.FillRaidList", perfStart, nil, out, "context=" .. tostring(contextTag or ""))
end

local registry = feature.ModuleRegistry
if type(registry) == "table" and type(registry.AddModule) == "function" and type(registry.SetLoaded) == "function" then
    registry.AddModule("Services/Logger/View", {
        deps = {
            "Init",
            "Modules/ModuleRegistry",
            "Modules/Sort",
            "Services/Logger/Store",
            "Modules/LootSourceCandidates",
        },
    })
    registry.SetLoaded("Services/Logger/View")
end

