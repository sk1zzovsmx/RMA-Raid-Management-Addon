-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: local feature = addon.Database.GetFeatureShared()
-- exports: addon.Services.Loot._Records
-- events: no bus events; append/build helpers only
local addon = select(2, ...)
local feature = addon.Database.GetFeatureShared()

local Services = feature.Services
local Database = feature.Database
local Time = feature.Time

local tinsert = table.insert
local tonumber = tonumber
local type = type

feature.EnsureServiceNamespace("Loot")
local Loot = Services.Loot
local module = Loot
module._Records = module._Records or {}

local Records = module._Records

-- ----- Internal state ----- --

-- ----- Private helpers ----- --
local function allocateLootNid(raid, preferredLootNid)
    local preferred = tonumber(preferredLootNid)
    if preferred and preferred > 0 then
        if (tonumber(raid.nextLootNid) or 1) <= preferred then
            raid.nextLootNid = preferred + 1
        end
        return preferred
    end
    local lootNid = tonumber(raid.nextLootNid) or 1
    raid.nextLootNid = lootNid + 1
    return lootNid
end

-- ----- Public methods ----- --
function Records.Build(raid, args)
    if type(raid) ~= "table" or type(args) ~= "table" then
        return nil, 0
    end

    local lootNid = allocateLootNid(raid, args.lootNid)
    local looterNid = tonumber(args.looterNid) or 0
    local row = {
        itemId = args.itemId,
        itemName = args.itemName,
        itemString = args.itemString,
        itemLink = args.itemLink,
        itemRarity = args.itemRarity,
        itemTexture = args.itemTexture,
        itemCount = tonumber(args.itemCount) or 1,
        looterNid = (looterNid > 0) and looterNid or nil,
        rollType = args.rollType,
        rollValue = args.rollValue,
        rollSessionId = args.rollSessionId,
        lootNid = lootNid,
        bossNid = tonumber(args.bossNid) or 0,
        time = tonumber(args.time) or (Time and Time.GetCurrentTime and Time.GetCurrentTime()) or 0,
        source = args.source,
        lootSource = args.lootSource,
    }
    return row, lootNid
end

function Records.Append(raid, args)
    if type(raid) ~= "table" then
        return nil, 0
    end
    raid.loot = raid.loot or {}
    local row, lootNid = Records.Build(raid, args)
    if not row then
        return nil, 0
    end
    tinsert(raid.loot, row)
    local raidStore = Database and Database.GetRaidStoreOrNil and Database.GetRaidStoreOrNil("Loot.Records.Append", { "MarkLootSyncRevision" })
    if raidStore and raidStore.MarkLootSyncRevision then
        raidStore:MarkLootSyncRevision(raid, row, "loot_row")
    end
    return row, lootNid, #raid.loot
end

local registry = feature.ModuleRegistry
if registry and type(registry.AddModule) == "function" and type(registry.SetLoaded) == "function" then
    registry.AddModule("Services/Loot/Records", {
        deps = {
            "Init",
            "Modules/ModuleRegistry",
            "Database/DBRaidStore",
            "Modules/Time",
        },
    })
    registry.SetLoaded("Services/Loot/Records")
end

