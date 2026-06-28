-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: local feature = addon.Database.GetFeatureShared()
-- exports: addon.Services.Loot._Reconcile
-- events: no bus events; reconciliation helpers only
local addon = select(2, ...)
local feature = addon.Database.GetFeatureShared()

local Item = feature.Item
local Services = feature.Services
local Strings = feature.Strings

local tonumber = tonumber
local tostring = tostring
local type = type

feature.EnsureServiceNamespace("Loot")
local Loot = Services.Loot
local module = Loot
module._Reconcile = module._Reconcile or {}

local Reconcile = module._Reconcile

-- ----- Internal state ----- --

-- ----- Private helpers ----- --
local function itemKey(itemLink, itemString)
    if itemString and itemString ~= "" then
        return itemString
    end
    if Item and Item.GetItemStringFromLink then
        local key = Item.GetItemStringFromLink(itemLink)
        if key and key ~= "" then
            return key
        end
    end
    return itemLink
end

local function normalizeName(name)
    if Strings and Strings.NormalizeName then
        return Strings.NormalizeName(name, true) or name
    end
    return name
end

local function strongerRollValue(current, incoming)
    local currentValue = tonumber(current) or 0
    local incomingValue = tonumber(incoming) or 0
    if incomingValue > currentValue then
        return incoming
    end
    return current
end

-- ----- Public methods ----- --
function Reconcile.FindTradeOnlyFallback(raid, args)
    if type(raid) ~= "table" or type(args) ~= "table" then
        return nil
    end

    local targetSessionId = args.rollSessionId and tostring(args.rollSessionId) or nil
    local targetItemKey = itemKey(args.itemLink, args.itemString)
    local targetLooterNid = tonumber(args.looterNid) or 0
    local targetLooter = normalizeName(args.looter)
    local targetBossNid = tonumber(args.bossNid) or 0
    local lootList = raid.loot or {}

    for i = #lootList, 1, -1 do
        local row = lootList[i]
        if row and row.source then
            local sameSession = targetSessionId and targetSessionId ~= "" and tostring(row.rollSessionId or "") == targetSessionId
            local sameItem = itemKey(row.itemLink, row.itemString) == targetItemKey
            local sameBoss = targetBossNid <= 0 or tonumber(row.bossNid) == targetBossNid
            local sameLooter = true
            if targetLooterNid > 0 then
                sameLooter = tonumber(row.looterNid) == targetLooterNid
            elseif targetLooter and row.looter then
                sameLooter = normalizeName(row.looter) == targetLooter
            end
            if sameItem and sameBoss and sameLooter and (sameSession or (not targetSessionId or targetSessionId == "")) then
                return row, i
            end
        end
    end
    return nil
end

function Reconcile.MergeTradeOnlyFallback(row, args)
    if type(row) ~= "table" or type(args) ~= "table" then
        return nil
    end
    if args.rollType ~= nil then
        row.rollType = tonumber(args.rollType) or args.rollType
    end
    row.rollValue = strongerRollValue(row.rollValue, args.rollValue)
    if args.rollSessionId and (not row.rollSessionId or row.rollSessionId == "") then
        row.rollSessionId = tostring(args.rollSessionId)
    end
    if args.itemCount and (tonumber(args.itemCount) or 0) > (tonumber(row.itemCount) or 0) then
        row.itemCount = tonumber(args.itemCount) or row.itemCount
    end
    return row
end

function Reconcile.ShouldSkipPassiveDuplicate(args)
    if type(args) ~= "table" then
        return false
    end
    local passive = args.PassiveGroupLoot
    local rollOutcome = args.rollOutcome
    if not (args.passiveGroupLoot and passive and passive.HasLoggedPassiveLoot) then
        return false
    end
    if (rollOutcome and rollOutcome.consumedPendingAward) and not (args.isPassiveWinnerMessage and args.rollSessionId) then
        return false
    end
    return passive.HasLoggedPassiveLoot(args.itemLink, args.playerName, args.rollSessionId) == true
end

function Reconcile.MarkPassiveLogged(args)
    if type(args) ~= "table" then
        return
    end
    local passive = args.PassiveGroupLoot
    if args.passiveGroupLoot and args.isPassiveWinnerMessage and passive and passive.RememberLoggedPassiveLoot then
        passive.RememberLoggedPassiveLoot(args.itemLink, args.playerName, args.rollSessionId)
    end
end

local registry = feature.ModuleRegistry
if registry and type(registry.AddModule) == "function" and type(registry.SetLoaded) == "function" then
    registry.AddModule("Services/Loot/Reconcile", {
        deps = {
            "Init",
            "Modules/ModuleRegistry",
            "Modules/Item",
            "Modules/Strings",
        },
    })
    registry.SetLoaded("Services/Loot/Reconcile")
end

