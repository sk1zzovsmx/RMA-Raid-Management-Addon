-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: local feature = addon.Database.GetFeatureShared()
-- exports: addon.Services.Master.RollAnnouncements
-- events: none
-- notes: pure Master roll announcement message-plan service
local addon = select(2, ...)
local feature = addon.Database.GetFeatureShared()

local Services = feature.Services
local Master = Services.Master or {}
Services.Master = Master
addon.Services.Master = Master

local RollAnnouncements = Master.RollAnnouncements or {}
Master.RollAnnouncements = RollAnnouncements

local L = feature.L
local rollTypes = feature.rollTypes

local tonumber = tonumber
local type = type

-- ----- Internal state ----- --

-- ----- Private helpers ----- --
local function resolveSuffix(sortAscending)
    if sortAscending == true then
        return "Low"
    end
    return "High"
end

local function getTemplate(key)
    if type(key) ~= "string" or key == "" then
        return nil
    end
    return L[key]
end

-- ----- Public methods ----- --

function RollAnnouncements.BuildPlan(opts)
    opts = opts or {}
    local chatKey = opts.chatKey
    local suffix = resolveSuffix(opts.sortAscending)
    local itemLink = opts.itemLink
    local selectedItemCount = tonumber(opts.selectedItemCount) or 1
    if selectedItemCount < 1 then
        selectedItemCount = 1
    end

    local message
    if opts.rollType == rollTypes.RESERVED then
        local srList = opts.srList or ""
        if selectedItemCount > 1 then
            message = getTemplate(chatKey .. "Multiple" .. suffix):format(srList, itemLink, selectedItemCount)
        else
            message = getTemplate(chatKey):format(srList, itemLink)
        end
        return {
            message = message,
            srList = srList,
            suffix = suffix,
        }
    end

    if selectedItemCount > 1 then
        message = getTemplate(chatKey .. "Multiple" .. suffix):format(itemLink, selectedItemCount)
    else
        message = getTemplate(chatKey):format(itemLink)
    end
    return {
        message = message,
        suffix = suffix,
    }
end

local registry = feature.ModuleRegistry
if type(registry) == "table" and type(registry.AddModule) == "function" and type(registry.SetLoaded) == "function" then
    registry.AddModule("Services/Master/RollAnnouncements", {
        deps = {
            "Init",
            "Modules/ModuleRegistry",
        },
    })
    registry.SetLoaded("Services/Master/RollAnnouncements")
end

