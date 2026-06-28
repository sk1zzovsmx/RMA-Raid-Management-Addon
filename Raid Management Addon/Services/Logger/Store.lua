-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: local feature = addon.Database.GetFeatureShared()
-- exports: publish module APIs on addon.*
-- events: none
local addon = select(2, ...)
local feature = addon.Database.GetFeatureShared()

local Strings = feature.Strings
local Database = feature.Database
local Services = feature.Services

local type, tostring, tonumber = type, tostring, tonumber

-- ----- Internal state ----- --
feature.EnsureServiceNamespace("Logger", "Store")
local Logger = Services.Logger
local Store = Logger.Store
local bossIdx
local lootIdx
local playerIdx
local resolvePlayerNameByNid
local resolvePlayerClassByNid
local resolveLootLooterNid
local resolveLootLooterName
local resolveLootLooterClass
local invalidateIndexes

-- ----- Private helpers ----- --
-- ----- Public methods ----- --

resolvePlayerNameByNid = function(raid, playerNid)
    local player = Store and Store.GetPlayer and Store:GetPlayer(raid, playerNid) or nil
    return player and player.name or nil
end

resolvePlayerClassByNid = function(raid, playerNid)
    local player = Store and Store.GetPlayer and Store:GetPlayer(raid, playerNid) or nil
    return player and player.class or nil
end

resolveLootLooterNid = function(raid, looter)
    local looterNid = tonumber(looter)
    if looterNid and looterNid > 0 then
        return looterNid
    end
    local normalizedName = Strings.NormalizeName(looter, true)
    if not normalizedName or normalizedName == "" then
        return nil
    end

    if raid and raid.players then
        for i = #raid.players, 1, -1 do
            local player = raid.players[i]
            if player and player.name == normalizedName then
                local nid = tonumber(player.playerNid)
                if nid and nid > 0 then
                    return nid
                end
            end
        end
    end
    return nil
end

resolveLootLooterName = function(raid, loot)
    local queries = Database.GetRaidQueriesOrNil()
    if queries and queries.ResolveLootLooterName then
        return queries:ResolveLootLooterName(raid, loot)
    end
    return nil
end

local function ensureRaid(raid)
    local raidStore = Database.GetRaidStoreOrNil("Logger.Store.EnsureRaid", { "NormalizeRaidRecord" })
    if raidStore then
        return raidStore:NormalizeRaidRecord(raid)
    end
    return Database.EnsureRaidSchema(raid)
end

resolveLootLooterClass = function(raid, loot)
    if type(loot) ~= "table" then
        return nil
    end
    local looterNid = tonumber(loot.looterNid)
    if looterNid and looterNid > 0 then
        return resolvePlayerClassByNid(raid, looterNid)
    end
    return nil
end

function Store:GetRaid(rID)
    local raidStore = Database.GetRaidStoreOrNil("Logger.Store.GetRaid", { "GetRaidByIndex" })
    if raidStore then
        local raid = rID and raidStore:GetRaidByIndex(rID) or nil
        if raid then
            ensureRaid(raid)
        end
        return raid
    end
    local raid = rID and Database.EnsureRaidById(rID) or nil
    if raid then
        ensureRaid(raid)
    end
    return raid
end

function Store:GetRaidByNid(raidNid)
    local raidStore = Database.GetRaidStoreOrNil("Logger.Store.GetRaidByNid", { "GetRaidByNid" })
    if raidStore then
        local raid = raidNid and raidStore:GetRaidByNid(raidNid) or nil
        if raid then
            ensureRaid(raid)
        end
        return raid
    end
    local raid = raidNid and Database.EnsureRaidByNid(raidNid) or nil
    if raid then
        ensureRaid(raid)
    end
    return raid
end

invalidateIndexes = function(raid)
    if type(raid) ~= "table" then
        return
    end
    if Database and Database.StripRuntimeRaidCaches then
        Database.StripRuntimeRaidCaches(raid)
        return
    end
    raid._runtime = nil
end

Store._ResolvePlayerNameByNid = resolvePlayerNameByNid
Store._ResolvePlayerClassByNid = resolvePlayerClassByNid
Store._ResolveLootLooterNid = resolveLootLooterNid
Store._ResolveLootLooterName = resolveLootLooterName
Store._ResolveLootLooterClass = resolveLootLooterClass
Store._InvalidateIndexes = invalidateIndexes

bossIdx = function(raid, bossNid)
    local queryNid = tonumber(bossNid)
    if not (raid and queryNid) then
        return nil
    end
    local raidStore = Database.GetRaidStoreOrNil("Logger.Store.BossIdx", { "EnsureRaidRuntime" })
    local runtime = raidStore and raidStore:EnsureRaidRuntime(raid) or nil
    local idxByNid = runtime and runtime.bossIdxByNid or nil
    return idxByNid and idxByNid[queryNid] or nil
end

lootIdx = function(raid, lootNid)
    local queryNid = tonumber(lootNid)
    if not (raid and queryNid) then
        return nil
    end
    local raidStore = Database.GetRaidStoreOrNil("Logger.Store.LootIdx", { "EnsureRaidRuntime" })
    local runtime = raidStore and raidStore:EnsureRaidRuntime(raid) or nil
    local idxByNid = runtime and runtime.lootIdxByNid or nil
    return idxByNid and idxByNid[queryNid] or nil
end

function Store:GetBoss(raid, bossNid)
    local idx = bossIdx(raid, bossNid)
    return idx and raid.bossKills[idx] or nil, idx
end

function Store:GetLoot(raid, lootNid)
    local idx = lootIdx(raid, lootNid)
    return idx and raid.loot[idx] or nil, idx
end

playerIdx = function(raid, playerNid)
    local queryNid = tonumber(playerNid)
    if not (raid and queryNid) then
        return nil
    end
    local raidStore = Database.GetRaidStoreOrNil("Logger.Store.PlayerIdx", { "EnsureRaidRuntime" })
    local runtime = raidStore and raidStore:EnsureRaidRuntime(raid) or nil
    local idxByNid = runtime and runtime.playerIdxByNid or nil
    return idxByNid and idxByNid[queryNid] or nil
end

function Store:GetPlayer(raid, playerNid)
    local idx = playerIdx(raid, playerNid)
    return idx and raid.players[idx] or nil, idx
end

local registry = feature.ModuleRegistry
if type(registry) == "table" and type(registry.AddModule) == "function" and type(registry.SetLoaded) == "function" then
    registry.AddModule("Services/Logger/Store", {
        deps = {
            "Init",
            "Modules/ModuleRegistry",
            "Database/DBRaidQueries",
            "Modules/Strings",
        },
    })
    registry.SetLoaded("Services/Logger/Store")
end

