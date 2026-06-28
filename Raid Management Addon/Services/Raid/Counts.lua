-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: local feature = addon.Database.GetFeatureShared()
-- exports: publish module APIs on addon.*
-- events: emits PlayerCountChanged
local addon = select(2, ...)
local feature = addon.Database.GetFeatureShared()

local Events = feature.Events
local Database = feature.Database
local Services = feature.Services

local InternalEvents = Events.Internal

local tostring = tostring
local tonumber = tonumber

local twipe = table.wipe

-- Maps loot type string to the player field name.
local LOOT_FIELD = {
    ms = "countMS",
    os = "countOs",
    free = "countFree",
    sr = "countSR",
}

-- Maps C.rollTypes values to loot type strings (only countable types).
local ROLL_TYPE_TO_LOOT_TYPE = {
    [1] = "ms", -- MAINSPEC
    [2] = "os", -- OFFSPEC
    [3] = "sr", -- RESERVED (SR)
    [4] = "free", -- FREE
}

local function findRaidPlayerByNid(raid, playerNid)
    local nid = tonumber(playerNid)
    if not nid or nid <= 0 then
        return nil
    end

    local players = raid and raid.players or {}
    for i = #players, 1, -1 do
        local player = players[i]
        if player and tonumber(player.playerNid) == nid then
            return player, i
        end
    end
    return nil
end

local function resolveRaidWithSchema(raidNum)
    local resolvedRaidNum = raidNum or Database.GetCurrentRaid()
    local raid = Database.EnsureRaidById(resolvedRaidNum)
    if not raid then
        return nil, nil
    end
    Database.EnsureRaidSchema(raid)
    return raid, resolvedRaidNum
end

local function resolveRaidPlayerByNid(playerNid, raidNum)
    local raid, resolvedRaidNum = resolveRaidWithSchema(raidNum)
    if not raid then
        return nil, nil
    end
    local player = findRaidPlayerByNid(raid, playerNid)
    return player, resolvedRaidNum
end

do
    feature.EnsureServiceNamespace("Raid")
    local Raid = Services.Raid
    local module = Raid
    module._FindRaidPlayerByNid = findRaidPlayerByNid

    -- ----- Internal state ----- --

    -- ----- Private helpers ----- --

    -- ----- Public methods ----- --

    function module:GetLootCounterRows(raidNum, out)
        raidNum = raidNum or Database.GetCurrentRaid()
        local raid = Database.EnsureRaidById(raidNum)
        local rows = out or {}
        if out then
            twipe(rows)
        end
        if not raid or not raid.players then
            return rows
        end

        Database.EnsureRaidSchema(raid)

        local seenByName = {}
        for i = #raid.players, 1, -1 do
            local p = raid.players[i]
            if p and p.name and not seenByName[p.name] then
                seenByName[p.name] = true
                rows[#rows + 1] = {
                    playerNid = tonumber(p.playerNid),
                    name = p.name,
                    class = p.class,
                    msCount = tonumber(p.countMS) or 0,
                    osCount = tonumber(p.countOs) or 0,
                    freeCount = tonumber(p.countFree) or 0,
                    srCount = tonumber(p.countSR) or 0,
                }
            end
        end

        table.sort(rows, function(a, b)
            return tostring(a.name or "") < tostring(b.name or "")
        end)

        return rows
    end

    -- Generic count access by loot type ("ms", "os", "free").
    function module:GetPlayerLootCountByNid(playerNid, lootType, raidNum)
        local player = resolveRaidPlayerByNid(playerNid, raidNum)
        if not player then
            return 0
        end
        local field = LOOT_FIELD[lootType] or "countMS"
        return tonumber(player[field]) or 0
    end

    function module:SetPlayerLootCountByNid(playerNid, lootType, value, raidNum)
        local player, resolvedRaidNum = resolveRaidPlayerByNid(playerNid, raidNum)
        if not player then
            return
        end

        local field = LOOT_FIELD[lootType] or "countMS"
        value = tonumber(value) or 0
        if value < 0 then
            value = 0
        end

        local old = tonumber(player[field]) or 0
        player[field] = value

        if old ~= value then
            local bus = feature.Bus
            bus.TriggerEvent(InternalEvents.PlayerCountChanged, player.name, value, old, resolvedRaidNum)
        end
    end

    function module:AddPlayerLootCountByNid(playerNid, lootType, delta, raidNum)
        raidNum = raidNum or Database.GetCurrentRaid()
        if not raidNum then
            return
        end

        delta = tonumber(delta) or 0
        if delta == 0 then
            return
        end

        local current = module:GetPlayerLootCountByNid(playerNid, lootType, raidNum) or 0
        local nextVal = current + delta
        if nextVal < 0 then
            nextVal = 0
        end

        module:SetPlayerLootCountByNid(playerNid, lootType, nextVal, raidNum)
    end

    local function addPlayerLootCount(name, lootType, delta, raidNum)
        raidNum = raidNum or Database.GetCurrentRaid()
        if not raidNum or not name then
            return
        end

        delta = tonumber(delta) or 0
        if delta == 0 then
            return
        end

        if type(module.CheckPlayer) == "function" then
            local ok, fixed = module:CheckPlayer(name, raidNum)
            if ok and fixed then
                name = fixed
            end
        end

        name = feature.Strings.NormalizeName(name, true)
        if not name then
            return
        end

        local playerNid = module:GetPlayerID(name, raidNum)
        if playerNid <= 0 then
            if type(module.AddPlayer) == "function" then
                module:AddPlayer({ name = name }, raidNum)
                playerNid = module:GetPlayerID(name, raidNum)
                if playerNid <= 0 then
                    return
                end
            else
                return
            end
        end
        module:AddPlayerLootCountByNid(playerNid, lootType, delta, raidNum)
    end

    -- Increments the correct counter based on the C.rollTypes value.
    -- Only MAINSPEC, OFFSPEC, and FREE are tracked; other types are ignored.
    function module:AddPlayerCountForRollType(name, rollType, delta, raidNum)
        local lootType = ROLL_TYPE_TO_LOOT_TYPE[tonumber(rollType)]
        if not lootType then
            return
        end
        addPlayerLootCount(name, lootType, delta, raidNum)
    end

    function module:GetPlayerCount(name, raidNum)
        raidNum = raidNum or Database.GetCurrentRaid()
        if not raidNum then
            return 0
        end
        local playerNid = module:GetPlayerID(name, raidNum)
        if playerNid <= 0 then
            return 0
        end
        return module:GetPlayerLootCountByNid(playerNid, "ms", raidNum)
    end
end

local registry = feature.ModuleRegistry
if type(registry) == "table" and type(registry.AddModule) == "function" and type(registry.SetLoaded) == "function" then
    registry.AddModule("Services/Raid/Counts", {
        deps = {
            "Init",
            "Modules/ModuleRegistry",
            "Modules/Events",
            "Modules/Bus",
            "Modules/Strings",
        },
    })
    registry.SetLoaded("Services/Raid/Counts")
end

