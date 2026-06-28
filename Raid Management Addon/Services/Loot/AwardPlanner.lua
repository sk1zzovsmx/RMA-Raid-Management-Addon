-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: local feature = addon.Database.GetFeatureShared()
-- exports: addon.Services.Loot._AwardPlanner
-- events: none
-- notes: Award planning helpers split from Services/Loot/Service

local addon = select(2, ...)
local feature = addon.Database.GetFeatureShared()

local L = feature.L
local Item = feature.Item
local Services = feature.Services
local rollTypes = feature.rollTypes
-- ----- Internal state ----- --

feature.EnsureServiceNamespace("Loot")
local Loot = Services.Loot
local module = Loot
module._AwardPlanner = module._AwardPlanner or {}
local AwardPlanner = module._AwardPlanner

-- ----- Private helpers ----- --

local tinsert, tconcat = table.insert, table.concat
local pairs, type, tostring, tonumber = pairs, type, tostring, tonumber

-- ----- Public methods ----- --

function AwardPlanner.BuildTradeInitialOutputPlan(args)
    args = type(args) == "table" and args or {}
    local options = type(args.options) == "table" and args.options or {}
    local itemLink = args.itemLink
    local playerName = args.winnerName or args.playerName
    local rollType = tonumber(args.rollType) or args.rollType

    if args.isAwardRoll and options.announceOnWin then
        return L.ChatAward:format(playerName, itemLink)
    end
    if rollType == rollTypes.HOLD and options.announceOnHold then
        return L.ChatNoneRolledHold:format(itemLink, playerName)
    end
    if rollType == rollTypes.BANK and options.announceOnBank then
        return L.ChatNoneRolledBank:format(itemLink, playerName)
    end
    if rollType == rollTypes.DISENCHANT and options.announceOnDisenchant then
        return L.ChatNoneRolledDisenchant:format(itemLink, playerName)
    end
    return nil
end

function AwardPlanner.BuildTradeKeepWhisperPlan(args)
    args = type(args) == "table" and args or {}
    local rollType = tonumber(args.rollType) or args.rollType
    if rollType == rollTypes.HOLD then
        return L.WhisperHoldTrade:format(args.itemLink)
    end
    if rollType == rollTypes.BANK then
        return L.WhisperBankTrade:format(args.itemLink)
    end
    if rollType == rollTypes.DISENCHANT then
        return L.WhisperDisenchantTrade:format(args.itemLink)
    end
    return nil
end

local function getPlannerRolls(args)
    local selected = type(args.selectedWinners) == "table" and args.selectedWinners or nil
    if selected and #selected > 0 then
        return selected, #selected
    end

    local fallback = type(args.fallbackRolls) == "table" and args.fallbackRolls or {}
    local maxWinners = tonumber(args.maxWinners) or #fallback
    return fallback, maxWinners
end

function AwardPlanner.BuildInventoryMultiWinnerTradePlan(args)
    args = type(args) == "table" and args or {}
    local markers = type(args.raidTargetMarkers) == "table" and args.raidTargetMarkers or {}
    local traderName = args.traderName
    local currentWinner = args.currentWinner
    local rolls, maxWinners = getPlannerRolls(args)
    local winners = {}
    local raidTargets = {}

    if traderName ~= currentWinner then
        raidTargets[#raidTargets + 1] = {
            name = traderName,
            icon = 1,
        }
    end

    for i = 1, maxWinners do
        local roll = rolls[i]
        if roll then
            local name = roll.name
            local rollValue = tonumber(roll.roll) or 0
            if name == traderName then
                if traderName ~= currentWinner then
                    tinsert(winners, "{star} " .. name .. "(" .. rollValue .. ")")
                else
                    tinsert(winners, name .. "(" .. rollValue .. ")")
                end
            elseif name and name ~= "" then
                raidTargets[#raidTargets + 1] = {
                    name = name,
                    icon = i + 1,
                }
                tinsert(winners, tostring(markers[i] or "") .. " " .. name .. "(" .. rollValue .. ")")
            end
        end
    end

    local winnersText = tconcat(winners, ", ")
    return {
        output = L.ChatTradeMutiple:format(winnersText, traderName),
        clearRaidIcons = true,
        raidTargets = raidTargets,
        winnersText = winnersText,
    }
end

function AwardPlanner.BuildTradeNotificationPlan(args)
    args = type(args) == "table" and args or {}
    local keep = not args.isAwardRoll
    local output = AwardPlanner.BuildTradeInitialOutputPlan(args)
    local whisper
    local markerPlan

    if keep then
        whisper = AwardPlanner.BuildTradeKeepWhisperPlan(args)
    elseif (tonumber(args.selectedItemCount) or 1) > 1 then
        markerPlan = AwardPlanner.BuildInventoryMultiWinnerTradePlan({
            currentWinner = args.winnerName,
            traderName = args.traderName,
            selectedWinners = args.selectedWinners,
            fallbackRolls = args.fallbackRolls,
            maxWinners = tonumber(args.maxWinners) or tonumber(args.selectedItemCount) or 0,
            raidTargetMarkers = args.raidTargetMarkers,
        })
        output = markerPlan.output
    end

    return {
        keep = keep,
        output = output,
        whisper = whisper,
        markerPlan = markerPlan,
    }
end

function AwardPlanner.BuildAwardTargetPlan(args)
    args = type(args) == "table" and args or {}
    local target = tonumber(args.selectedItemCount) or 1
    if target < 1 then
        target = 1
    end

    local available = tonumber(args.availableItemCount) or 1
    if available < 1 then
        available = 1
    end

    if target > available then
        target = available
    end

    local rollsCount = tonumber(args.rollsCount)
    if rollsCount and target > rollsCount then
        target = rollsCount
    end

    if target < 1 then
        target = 1
    end

    return {
        target = target,
        available = available,
    }
end

function AwardPlanner.ValidateInventoryTradeSelection(args)
    args = type(args) == "table" and args or {}
    local target = tonumber(args.target) or 1
    local selectedCount = tonumber(args.selectedCount) or 0
    local pickedCount = tonumber(args.pickedCount) or 0

    if selectedCount <= 0 then
        return {
            ok = false,
            errType = "empty_selection",
        }
    end
    if pickedCount < target then
        return {
            ok = false,
            errType = "not_enough_selection",
            wantedCount = target,
            pickedCount = pickedCount,
        }
    end

    return {
        ok = true,
    }
end

function AwardPlanner.BuildMultiAwardWinnersPlan(args)
    args = type(args) == "table" and args or {}
    local target = tonumber(args.target) or 1
    if target < 1 then
        target = 1
    end

    local selectedCount = tonumber(args.selectedCount) or 0
    if selectedCount <= 0 then
        return {
            errType = "empty_selection",
        }
    end

    local awardCount = selectedCount
    if awardCount > target then
        awardCount = target
    end

    local picked = type(args.pickedWinners) == "table" and args.pickedWinners or {}
    if #picked < awardCount then
        return {
            errType = "not_enough_selection",
            wantedCount = awardCount,
            pickedCount = #picked,
        }
    end

    local winners = {}
    for i = 1, awardCount do
        local p = picked[i]
        if p and p.name then
            winners[#winners + 1] = {
                name = p.name,
                roll = tonumber(p.roll) or 0,
            }
        end
    end

    if #winners <= 0 then
        return {
            errType = "empty_winners",
            clearSelection = true,
        }
    end

    return {
        winners = winners,
        clearSelection = true,
    }
end

local function copyArray(values)
    local out = {}
    if type(values) ~= "table" then
        return out
    end
    for i = 1, #values do
        out[i] = values[i]
    end
    return out
end

local function copyMap(values)
    local out = {}
    if type(values) ~= "table" then
        return out
    end
    for key, value in pairs(values) do
        out[key] = value
    end
    return out
end

function AwardPlanner.BuildMultiAwardState(args)
    args = type(args) == "table" and args or {}
    local winners = type(args.winners) == "table" and args.winners or {}
    local itemLink = args.itemLink
    return {
        state = {
            active = true,
            itemLink = itemLink,
            itemKey = Item.GetItemStringFromLink(itemLink) or itemLink,
            lastCount = tonumber(args.available) or 1,
            rollType = args.rollType,
            winners = winners,
            currentWinner = winners[1] and winners[1].name or nil,
            pos = 2,
            total = #winners,
            slotCandidates = copyArray(args.slotCandidates),
            slotCandidateMap = copyMap(args.slotCandidateMap),
            lastClearedSlot = nil,
            waitingForDecrement = false,
            announceOnWin = args.announceOnWin and true or false,
            congratsSent = false,
        },
    }
end

local registry = feature.ModuleRegistry
if type(registry) == "table" and type(registry.AddModule) == "function" and type(registry.SetLoaded) == "function" then
    registry.AddModule("Services/Loot/AwardPlanner", {
        deps = {
            "Init",
            "Modules/ModuleRegistry",
            "Modules/Item",
        },
    })
    registry.SetLoaded("Services/Loot/AwardPlanner")
end

