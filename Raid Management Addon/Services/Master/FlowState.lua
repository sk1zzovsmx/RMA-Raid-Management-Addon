-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: local feature = addon.Database.GetFeatureShared()
-- exports: addon.Services.Master.FlowState
-- events: none
-- notes: pure Master workflow state models
local addon = select(2, ...)
local feature = addon.Database.GetFeatureShared()

local Services = feature.Services
local Master = Services.Master or {}
Services.Master = Master
addon.Services.Master = Master

local FlowState = Master.FlowState or {}
Master.FlowState = FlowState

local SoftRes = Master.SoftRes
local SessionWinners = Master.SessionWinners
local L = feature.L

local type = type
local tonumber = tonumber

-- ----- Internal state ----- --

local DEFAULT_FLOW_STATES = {
    IDLE = "idle",
    LOOT = "loot",
    ROLLING = "rolling",
    COUNTDOWN = "countdown",
    INVENTORY = "inventory",
    MULTI_AWARD = "multi_award",
    TRADE = "trade",
}

-- ----- Private helpers ----- --
local function getAutoLootSuggestionLabel(suggestion)
    if type(suggestion) ~= "table" then
        return nil
    end
    if suggestion.action == "hold" then
        return L.BtnHold
    end
    if suggestion.action == "bank" then
        return L.BtnBank
    end
    if suggestion.action == "disenchant" then
        return L.BtnDisenchant
    end
    if suggestion.action == "skipLogger" then
        return L.StrAutoLootSuggestionSkipLogger
    end
    return nil
end

-- ----- Public methods ----- --

function FlowState.BuildState(opts)
    opts = opts or {}
    local lootState = opts.lootState or feature.lootState or {}
    local flowStates = opts.flowStates or DEFAULT_FLOW_STATES
    local currentFlowState = opts.currentFlowState
    local rollModel = opts.rollModel or {}
    local resolution = rollModel.resolution or {}
    local requiredWinnerCount = tonumber(rollModel.requiredWinnerCount) or 1
    local selectedCount = tonumber(rollModel.msCount) or 0
    local selectionAllowed = rollModel.selectionAllowed == true
    local multiAward = lootState.multiAward
    local displayedWinner = opts.displayedWinner
    local currentTradeWinner = opts.currentTradeWinner
    local currentMultiWinner = opts.currentMultiWinner
    local autoLootSuggestion = opts.autoLootSuggestion
    local hasLootAccess = opts.hasLootAccess == true
    local hasInventoryItemAccess = lootState.fromInventory == true and opts.hasInventoryTradeAccess == true
    local hasItemActionAccess = hasInventoryItemAccess or hasLootAccess
    local countdownRunning = opts.countdownRunning == true
    local lootCount = tonumber(lootState.lootCount) or 0
    local rollsCount = tonumber(lootState.rollsCount) or 0
    local srSummaryText = SoftRes.BuildSummaryText(opts, rollModel)
    local state = {
        name = "ready",
        statusText = L.StrMasterStatusReady,
        sessionWinners = SessionWinners.BuildModel(rollModel),
    }

    if requiredWinnerCount < 1 then
        requiredWinnerCount = 1
    end

    state.canStartRolls = hasItemActionAccess and lootCount >= 1 and not countdownRunning
    state.canStartSR = state.canStartRolls and opts.hasEligibleRaidReserve == true
    state.canChangeItem = (hasLootAccess or opts.hasInventoryTradeAccess == true) and currentFlowState ~= flowStates.COUNTDOWN
    state.canAward = hasItemActionAccess and lootCount >= 1 and rollsCount >= 1 and not countdownRunning and opts.canAwardSelection == true
    state.canReserveList = true
    state.canRollSelf = hasItemActionAccess and opts.record == true and opts.canRoll == true and opts.rolled == false and countdownRunning
    state.canSpamLoot = lootCount >= 1 and ((lootState.fromInventory and opts.hasReadyCheckAccess == true) or ((not lootState.fromInventory) and hasLootAccess))

    if not opts.hasItem then
        state.name = "idle"
        state.statusText = L.StrMasterStatusIdle
        return state
    end

    if currentFlowState == flowStates.MULTI_AWARD then
        local total = tonumber(multiAward and multiAward.total) or (multiAward and multiAward.winners and #multiAward.winners) or requiredWinnerCount
        local position = tonumber(multiAward and multiAward.pos) or tonumber(multiAward and multiAward.index) or 1
        local currentWinner = currentMultiWinner or displayedWinner
        state.name = "multi_award"
        if total < 1 then
            total = requiredWinnerCount
        end
        if position < 1 then
            position = 1
        end
        if currentWinner and currentWinner ~= "" then
            state.statusText = L.StrMasterStatusMultiAward:format(position, total, currentWinner)
            return state
        end
        if selectedCount >= requiredWinnerCount and requiredWinnerCount > 1 then
            state.name = "award_ready"
            state.statusText = L.StrMasterStatusAwardSelection:format(selectedCount)
            return state
        end
        state.name = "select_winners"
        state.statusText = L.StrMasterStatusSelectWinners:format(requiredWinnerCount)
        return state
    end

    if currentFlowState == flowStates.TRADE then
        state.name = "trade"
        if currentTradeWinner and currentTradeWinner ~= "" then
            state.statusText = L.StrMasterStatusTrade:format(currentTradeWinner)
            return state
        end
        state.statusText = L.StrMasterStatusInventory
        return state
    end

    if currentFlowState == flowStates.INVENTORY then
        state.name = "inventory"
        if selectionAllowed and requiredWinnerCount > 1 then
            if selectedCount >= requiredWinnerCount then
                state.name = "award_ready"
                state.statusText = L.StrMasterStatusInventorySelection:format(selectedCount)
                return state
            end
            state.name = "select_winners"
            state.statusText = L.StrMasterStatusSelectWinners:format(requiredWinnerCount)
            return state
        end
        if displayedWinner and displayedWinner ~= "" then
            state.name = "award_ready"
            state.statusText = L.StrMasterStatusInventoryTarget:format(displayedWinner)
            return state
        end
        if selectionAllowed then
            state.name = "select_winner"
            state.statusText = L.StrMasterStatusPickWinner
            return state
        end
        state.statusText = L.StrMasterStatusInventory
        return state
    end

    if currentFlowState == flowStates.COUNTDOWN then
        state.name = "countdown"
        state.statusText = L.StrMasterStatusCountdown
        return state
    end

    if currentFlowState == flowStates.ROLLING then
        state.name = "rolling"
        if not selectionAllowed then
            if rollModel.countdownExpired == true then
                state.name = "countdown_bypassed"
                state.statusText = L.StrMasterStatusRollingBypassed:format(rollsCount)
                return state
            end
            if srSummaryText then
                state.statusText = L.StrMasterStatusRollingWithSummary:format(srSummaryText, rollsCount)
                return state
            end
            state.statusText = L.StrMasterStatusRolling:format(rollsCount)
            return state
        end

        if resolution.requiresManualResolution then
            if requiredWinnerCount > 1 then
                if selectedCount >= requiredWinnerCount then
                    state.name = "award_ready"
                    state.statusText = L.StrMasterStatusAwardSelection:format(selectedCount)
                    return state
                end
                state.name = "select_winners"
                state.statusText = L.StrMasterStatusSelectWinners:format(requiredWinnerCount)
                return state
            end
            state.name = "resolve_tie"
            state.statusText = L.StrMasterStatusResolveTie
            return state
        end

        if requiredWinnerCount > 1 then
            if selectedCount >= requiredWinnerCount then
                state.name = "award_ready"
                state.statusText = L.StrMasterStatusAwardSelection:format(selectedCount)
                return state
            end
            state.name = "select_winners"
            state.statusText = L.StrMasterStatusSelectWinners:format(requiredWinnerCount)
            return state
        end

        if displayedWinner and displayedWinner ~= "" then
            state.name = "award_ready"
            state.statusText = L.StrMasterStatusAwardTarget:format(displayedWinner)
            return state
        end
        state.name = "select_winner"
        state.statusText = L.StrMasterStatusPickWinner
        return state
    end

    local suggestionLabel = getAutoLootSuggestionLabel(autoLootSuggestion)
    if suggestionLabel then
        state.name = "suggestion"
        state.statusText = L.StrMasterStatusSuggestion:format(suggestionLabel)
        return state
    end

    if srSummaryText then
        state.statusText = L.StrMasterStatusReadyWithSummary:format(srSummaryText)
        return state
    end

    return state
end

local registry = feature.ModuleRegistry
if type(registry) == "table" and type(registry.AddModule) == "function" and type(registry.SetLoaded) == "function" then
    registry.AddModule("Services/Master/FlowState", {
        deps = {
            "Init",
            "Modules/ModuleRegistry",
            "Services/Master/SoftRes",
            "Services/Master/SessionWinners",
        },
    })
    registry.SetLoaded("Services/Master/FlowState")
end

