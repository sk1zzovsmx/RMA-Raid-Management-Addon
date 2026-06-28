-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: local feature = addon.Database.GetFeatureShared()
-- exports: addon.Services.Loot._Rules
-- events: no bus events; suggestion-only classification
-- notes: suggestion-only auto-loot classification; never awards or trades items

local addon = select(2, ...)
local feature = addon.Database.GetFeatureShared()

local C = feature.C
local IgnoredItems = feature.IgnoredItems or {}
local Item = feature.Item
local Services = feature.Services

local tonumber, tostring, type = tonumber, tostring, type

-- ----- Internal state ----- --
feature.EnsureServiceNamespace("Loot")
local Loot = Services.Loot
local module = Loot
module._Rules = module._Rules or {}

local Rules = module._Rules

local ACTION_NONE = "none"
local ACTION_SKIP_LOGGER = "skipLogger"
local ACTION_BANK = "bank"
local ACTION_DISENCHANT = "disenchant"
local REASON_NONE = "no_rule"
local REASON_IGNORED_ITEM = "ignored_item"
local REASON_BOE_QUALITY = "boe_quality"
local REASON_ENCHANTING_MATERIAL = "enchanting_material"
local BIND_ON_EQUIP = _G.LE_ITEM_BIND_ON_EQUIP or 2
local MIN_QUALITY_ACTION_RARITY = 3

-- ----- Private helpers ----- --
local function getRollTypes()
    return C and C.rollTypes or {}
end

local function resolveItemId(item)
    local itemId = item and item.itemId
    if itemId then
        return tonumber(itemId)
    end
    if Item and Item.GetItemIdFromLink and item and item.itemLink then
        return tonumber(Item.GetItemIdFromLink(item.itemLink))
    end
    return nil
end

local function resolveItemInfo(item, opts)
    if type(item) ~= "table" then
        return {}
    end

    local allowItemInfo = not (type(opts) == "table" and opts.allowItemInfo == false)
    local allowTooltip = not (type(opts) == "table" and opts.allowTooltip == false)
    local itemId = resolveItemId(item)
    local itemRarity = tonumber(item.itemRarity or item.rarity or item.quality)
    local itemBind = tonumber(item.itemBind or item.bindType or item.bind)
    local itemLink = item.itemLink or item.link

    if allowItemInfo and (not itemRarity or not itemBind) and itemLink and _G.GetItemInfo then
        local _, _, fetchedRarity, _, _, _, _, _, _, _, _, _, _, fetchedBind = _G.GetItemInfo(itemLink)
        itemRarity = itemRarity or tonumber(fetchedRarity)
        itemBind = itemBind or tonumber(fetchedBind)
    end

    if allowTooltip and not itemBind and itemLink and Item and Item.GetItemBindFromTooltip then
        itemBind = tonumber(Item.GetItemBindFromTooltip(itemLink))
    end

    return {
        itemId = itemId,
        itemLink = itemLink,
        itemRarity = itemRarity,
        itemBind = itemBind,
    }
end

local function buildDecision(action, reason, rollType, targetKey, extra)
    local decision = {
        action = action or ACTION_NONE,
        reason = reason or REASON_NONE,
        rollType = rollType,
        targetKey = targetKey,
        automatic = false,
    }
    if type(extra) == "table" then
        for key, value in pairs(extra) do
            decision[key] = value
        end
    end
    return decision
end

local function isIgnoredItem(itemId)
    return type(IgnoredItems.Contains) == "function" and IgnoredItems.Contains(itemId) == true
end
Rules._IsIgnoredItem = isIgnoredItem

local function isEnchantingMaterial(itemId)
    return type(IgnoredItems.IsEnchantingMaterial) == "function" and IgnoredItems.IsEnchantingMaterial(itemId) == true
end

-- ----- Public methods ----- --
function Rules:GetItemSuggestion(item, opts)
    local info = resolveItemInfo(item, opts)
    local rollTypes = getRollTypes()

    if isEnchantingMaterial(info.itemId) then
        return buildDecision(ACTION_DISENCHANT, REASON_ENCHANTING_MATERIAL, rollTypes.DISENCHANT, "disenchanter")
    end

    if isIgnoredItem(info.itemId) then
        return buildDecision(ACTION_SKIP_LOGGER, REASON_IGNORED_ITEM, nil, nil, { skipLogger = true })
    end

    if info.itemBind == BIND_ON_EQUIP and (tonumber(info.itemRarity) or 0) >= MIN_QUALITY_ACTION_RARITY then
        return buildDecision(ACTION_BANK, REASON_BOE_QUALITY, rollTypes.BANK, "banker")
    end

    return buildDecision(ACTION_NONE, REASON_NONE)
end

local registry = feature.ModuleRegistry
if registry and type(registry.AddModule) == "function" and type(registry.SetLoaded) == "function" then
    registry.AddModule("Services/Loot/Rules", {
        deps = {
            "Init",
            "Modules/ModuleRegistry",
            "Modules/C",
            "Modules/Item",
            "Modules/Dataset/IgnoredItems",
        },
    })
    registry.SetLoaded("Services/Loot/Rules")
end

