-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: local feature = addon.Database.GetFeatureShared()
-- exports: addon.Services.Loot._Receipts
-- events: no bus events; pure receipt classification helpers
local addon = select(2, ...)
local feature = addon.Database.GetFeatureShared()

local Item = feature.Item
local Services = feature.Services

local tonumber = tonumber
local tostring = tostring
local type = type

feature.EnsureServiceNamespace("Loot")
local Loot = Services.Loot
local module = Loot
module._Receipts = module._Receipts or {}

local Receipts = module._Receipts

-- ----- Internal state ----- --

-- ----- Private helpers ----- --
local resolveItemKey = Item.GetItemKey
    or function(itemKeyOrLink, itemLink)
        local itemKey = Item.GetItemStringFromLink and Item.GetItemStringFromLink(itemKeyOrLink) or nil
        if itemKey and itemKey ~= "" then
            return itemKey
        end
        itemKey = Item.GetItemStringFromLink and Item.GetItemStringFromLink(itemLink) or nil
        if itemKey and itemKey ~= "" then
            return itemKey
        end
        if itemKeyOrLink and itemKeyOrLink ~= "" then
            return itemKeyOrLink
        end
        return itemLink
    end

local function resolveKind(args)
    if not args.itemLink then
        return "ignored", "missing_item"
    end
    local parsed = args.parsedGroupLoot
    if args.passiveGroupLoot == true and type(parsed) == "table" then
        if parsed.kind == "winner" then
            return "group_winner"
        end
        if parsed.kind == "roll" then
            return "group_roll"
        end
        if parsed.kind == "selection" then
            return "group_selection"
        end
    end
    if args.kind then
        return args.kind
    end
    return "loot_received"
end

-- ----- Public methods ----- --
function Receipts.FromParsedLoot(args)
    args = args or {}
    local kind, reason = resolveKind(args)
    local parsed = args.parsedGroupLoot
    local rollSessionId = args.rollSessionId
    local rollId = args.rollId
    if type(parsed) == "table" then
        rollSessionId = rollSessionId or parsed.sessionId
        rollId = rollId or parsed.rollId
    end
    return {
        kind = kind,
        reason = reason,
        msg = args.msg,
        playerName = args.playerName,
        itemLink = args.itemLink,
        itemString = args.itemString,
        itemKey = resolveItemKey(args.itemString, args.itemLink),
        itemCount = tonumber(args.itemCount) or 1,
        itemId = tonumber(args.itemId) or nil,
        itemName = args.itemName,
        itemRarity = args.itemRarity,
        itemTexture = args.itemTexture,
        itemType = args.itemType,
        rollType = args.rollType,
        rollValue = args.rollValue,
        rollSessionId = rollSessionId and tostring(rollSessionId) or nil,
        rollId = tonumber(rollId) or rollId,
        passiveGroupLoot = args.passiveGroupLoot == true,
        parsedGroupLoot = parsed,
    }
end

function Receipts.ShouldCreateRecord(receipt)
    if type(receipt) ~= "table" then
        return false
    end
    return receipt.kind == "loot_received" or receipt.kind == "group_winner"
end

local registry = feature.ModuleRegistry
if registry and type(registry.AddModule) == "function" and type(registry.SetLoaded) == "function" then
    registry.AddModule("Services/Loot/Receipts", {
        deps = {
            "Init",
            "Modules/ModuleRegistry",
            "Modules/Item",
        },
    })
    registry.SetLoaded("Services/Loot/Receipts")
end

