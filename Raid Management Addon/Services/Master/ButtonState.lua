-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: local feature = addon.Database.GetFeatureShared()
-- exports: addon.Services.Master.ButtonState
-- events: none
-- notes: pure Master button and tooltip state models
local addon = select(2, ...)
local feature = addon.Database.GetFeatureShared()

local Services = feature.Services
local Master = Services.Master or {}
Services.Master = Master
addon.Services.Master = Master

local ButtonState = Master.ButtonState or {}
Master.ButtonState = ButtonState

local L = feature.L

local type = type
local tonumber = tonumber

-- ----- Internal state ----- --

-- ----- Private helpers ----- --
local function buildRollModeTooltip(label, needsReserves, selectedItemCount, hasEligibleRaidReserve)
    if needsReserves and not hasEligibleRaidReserve then
        return L.TipMasterSRUnavailable
    end
    if selectedItemCount > 1 then
        return L.TipMasterRollModeMultiple:format(label, selectedItemCount)
    end
    return L.TipMasterRollMode:format(label)
end

local function buildAwardTooltip(lootState, rollModel, isTieReroll, awardTarget, msCount)
    local requiredWinnerCount = tonumber(rollModel and rollModel.requiredWinnerCount) or 1
    if isTieReroll then
        return L.TipMasterReroll
    end

    if lootState.fromInventory then
        if requiredWinnerCount > 1 then
            if msCount >= requiredWinnerCount then
                return L.TipMasterTradeMultiple:format(msCount)
            end
            return L.TipMasterPickWinner
        end
        if awardTarget and awardTarget ~= "" then
            return L.TipMasterTrade:format(awardTarget)
        end
        return L.TipMasterPickWinner
    end

    if requiredWinnerCount > 1 then
        if msCount >= requiredWinnerCount then
            return L.TipMasterAwardMultiple:format(msCount)
        end
        return L.TipMasterPickWinner
    end
    if awardTarget and awardTarget ~= "" then
        return L.TipMasterAward:format(awardTarget)
    end
    return L.TipMasterPickWinner
end

-- ----- Public methods ----- --

function ButtonState.BuildTooltipState(opts)
    opts = opts or {}
    local lootState = opts.lootState or {}
    local selectedItemCount = tonumber(opts.selectedItemCount) or 1
    local hasLootAccess = opts.hasLootAccess == true
    local hasInventoryTradeAccess = opts.hasInventoryTradeAccess == true
    local hasLootSelectionAccess = opts.hasLootSelectionAccess == true or hasLootAccess
    local tooltipState = {
        config = L.TipMasterConfig,
        selectItem = lootState.fromInventory and L.TipMasterRemoveItem or L.TipMasterSelectItem,
        spamLoot = lootState.fromInventory and (opts.hasReadyCheckAccess and L.TipMasterReadyCheck or L.WarnReadyCheckNotAllowed) or L.TipMasterSpamLoot,
        ms = buildRollModeTooltip(L.BtnMS, false, selectedItemCount, opts.hasEligibleRaidReserve),
        os = buildRollModeTooltip(L.BtnOS, false, selectedItemCount, opts.hasEligibleRaidReserve),
        sr = buildRollModeTooltip(L.BtnSR, true, selectedItemCount, opts.hasEligibleRaidReserve),
        free = buildRollModeTooltip(L.BtnFree, false, selectedItemCount, opts.hasEligibleRaidReserve),
        countdown = (opts.countdownRunning or lootState.rollStarted) and L.TipMasterCountdown or L.TipMasterCountdownInactive,
        award = buildAwardTooltip(lootState, opts.rollModel, opts.isTieReroll, opts.awardTarget, opts.msCount),
        roll = L.TipMasterRollSelf,
        clear = L.TipMasterClear,
        hold = lootState.holder and L.TipMasterHold:format(lootState.holder) or L.TipMasterHoldUnset,
        bank = lootState.banker and L.TipMasterBank:format(lootState.banker) or L.TipMasterBankUnset,
        disenchant = lootState.disenchanter and L.TipMasterDisenchant:format(lootState.disenchanter) or L.TipMasterDisenchantUnset,
        reserveList = opts.hasReserves and L.TipMasterReserveList or L.TipMasterReserveImport,
        lootCounter = L.TipMasterLootCounter,
    }

    if not hasLootAccess then
        local itemActionWarning = lootState.fromInventory and (L.WarnInventoryTradeNoPermission or L.WarnMLOnlyMode) or L.WarnMLOnlyMode
        local hasItemActionAccess = lootState.fromInventory and hasInventoryTradeAccess
        local hasSelectionAccess = (lootState.fromInventory and hasInventoryTradeAccess) or ((not lootState.fromInventory) and hasLootSelectionAccess)

        if not hasSelectionAccess then
            tooltipState.selectItem = itemActionWarning
        end
        if not hasItemActionAccess then
            tooltipState.ms = itemActionWarning
            tooltipState.os = itemActionWarning
            tooltipState.sr = itemActionWarning
            tooltipState.free = itemActionWarning
            tooltipState.countdown = itemActionWarning
            tooltipState.award = itemActionWarning
            tooltipState.roll = itemActionWarning
            tooltipState.clear = itemActionWarning
            tooltipState.hold = itemActionWarning
            tooltipState.bank = itemActionWarning
            tooltipState.disenchant = itemActionWarning
        end
    end

    return tooltipState
end

function ButtonState.ResolveAwardSelectionState(rollModel, isTieReroll)
    rollModel = rollModel or {}
    local rollResolution = rollModel.resolution or {}
    local pickMode = rollModel.pickMode == true
    local msCount = pickMode and (tonumber(rollModel.msCount) or 0) or 0
    local canAwardSelection = (not pickMode) or msCount > 0

    if rollResolution.requiresManualResolution and pickMode then
        if isTieReroll then
            canAwardSelection = true
        else
            canAwardSelection = msCount >= (tonumber(rollModel.requiredWinnerCount) or 1)
        end
    end

    return rollResolution, msCount, canAwardSelection
end

function ButtonState.BuildState(opts)
    opts = opts or {}
    local lootState = opts.lootState or {}
    local tooltipState = opts.tooltipState or {}
    local workflowState = opts.workflowState or {}
    local labels = opts.labels or {}
    local hasLootAccess = opts.hasLootAccess == true
    local hasInventoryTradeAccess = opts.hasInventoryTradeAccess == true
    local hasLootSelectionAccess = opts.hasLootSelectionAccess == true or hasLootAccess
    local hasItemActionAccess = (lootState.fromInventory == true and hasInventoryTradeAccess) or hasLootAccess
    local countdownRunning = opts.countdownRunning
    local autoLootSuggestion = opts.autoLootSuggestion
    local suggestedAction = type(autoLootSuggestion) == "table" and autoLootSuggestion.action or nil

    return {
        countdownText = countdownRunning and L.BtnStop or L.BtnCountdown,
        awardText = opts.isTieReroll and L.BtnReroll or (lootState.fromInventory and labels.trade or L.BtnAward),
        selectItemText = lootState.fromInventory and L.BtnRemoveItem or L.BtnSelectItem,
        spamLootText = lootState.fromInventory and labels.readyCheck or L.BtnSpamLoot,
        statusText = opts.statusText,
        configTooltip = tooltipState.config,
        selectItemTooltip = tooltipState.selectItem,
        spamLootTooltip = tooltipState.spamLoot,
        msTooltip = tooltipState.ms,
        osTooltip = tooltipState.os,
        srTooltip = tooltipState.sr,
        freeTooltip = tooltipState.free,
        countdownTooltip = tooltipState.countdown,
        awardTooltip = tooltipState.award,
        rollTooltip = tooltipState.roll,
        clearTooltip = tooltipState.clear,
        holdTooltip = tooltipState.hold,
        bankTooltip = tooltipState.bank,
        disenchantTooltip = tooltipState.disenchant,
        reserveListTooltip = tooltipState.reserveList,
        lootCounterTooltip = tooltipState.lootCounter,
        canSelectItem = (
            ((not lootState.fromInventory) and hasLootSelectionAccess and (tonumber(lootState.lootCount) or 0) > 1)
            or (lootState.fromInventory and hasInventoryTradeAccess and (tonumber(lootState.lootCount) or 0) >= 1)
        ) and not countdownRunning,
        canChangeItem = workflowState.canChangeItem == true,
        canSpamLoot = workflowState.canSpamLoot == true,
        canStartRolls = workflowState.canStartRolls == true,
        canStartSR = workflowState.canStartSR == true,
        canCountdown = hasItemActionAccess and (tonumber(lootState.lootCount) or 0) >= 1 and opts.hasItem and (lootState.rollStarted or countdownRunning),
        canHold = hasItemActionAccess and (tonumber(lootState.lootCount) or 0) >= 1 and lootState.holder,
        canBank = hasItemActionAccess and (tonumber(lootState.lootCount) or 0) >= 1 and lootState.banker,
        canDisenchant = hasItemActionAccess and (tonumber(lootState.lootCount) or 0) >= 1 and lootState.disenchanter,
        canAward = workflowState.canAward == true,
        reserveListText = opts.hasReserves and L.BtnOpenList or L.BtnInsertList,
        canReserveList = workflowState.canReserveList == true,
        canRoll = workflowState.canRollSelf == true,
        canClear = hasItemActionAccess and (tonumber(lootState.rollsCount) or 0) >= 1,
        glowSR = workflowState.canStartSR == true,
        glowHoldSuggestion = hasItemActionAccess and suggestedAction == "hold" and lootState.holder,
        glowBankSuggestion = hasItemActionAccess and suggestedAction == "bank" and lootState.banker,
        glowDisenchantSuggestion = hasItemActionAccess and suggestedAction == "disenchant" and lootState.disenchanter,
    }
end

local registry = feature.ModuleRegistry
if type(registry) == "table" and type(registry.AddModule) == "function" and type(registry.SetLoaded) == "function" then
    registry.AddModule("Services/Master/ButtonState", {
        deps = {
            "Init",
            "Modules/ModuleRegistry",
        },
    })
    registry.SetLoaded("Services/Master/ButtonState")
end

