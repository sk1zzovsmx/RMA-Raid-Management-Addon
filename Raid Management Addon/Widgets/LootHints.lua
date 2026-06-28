-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: local feature = addon.Database.GetFeatureShared()
-- exports: addon.Widgets.LootHints
-- events: none

local addon = select(2, ...)
local feature = addon.Database.GetFeatureShared()

local Widgets = feature.Widgets
local UI = feature.UI
local UIWidgets = UI.Widgets
local Item = feature.Item
local L = feature.L
local Options = feature.Options
local Services = feature.Services

local _G = _G
local type = type
local tostring, tonumber = tostring, tonumber

local registry = feature.ModuleRegistry
if type(registry) == "table" and type(registry.AddModule) == "function" and type(registry.SetLoaded) == "function" then
    registry.AddModule("Widgets/LootHints", {
        deps = {
            "Init",
            "Modules/ModuleRegistry",
            "Modules/Item",
            "Modules/UI/Facade",
            "Modules/UI/Frames",
        },
    })
    registry.SetLoaded("Widgets/LootHints")
end

do
    if UIWidgets and UIWidgets.IsEnabled and not UIWidgets.IsEnabled("LootHints") then
        return
    end

    Widgets.LootHints = Widgets.LootHints or {}
    local module = Widgets.LootHints
    addon.Widgets.LootHints = module

    -- ----- Internal state ----- --
    local hooksBound = false
    local GetOption = Options.GetValue
        or function(namespace, key, defaultValue)
            local cfg = Options and Options.Get and Options.Get(namespace) or nil
            if cfg and cfg.Get then
                local value = cfg:Get(key)
                if value ~= nil then
                    return value
                end
            end
            return defaultValue
        end

    -- ----- Private helpers ----- --
    local function buildLootReserveUiState(itemLink)
        local state = {
            itemId = nil,
            hasReserves = false,
            playerLines = {},
        }
        local itemId = Item.GetItemIdFromLink(itemLink)
        if not itemId then
            return state
        end

        state.itemId = itemId

        local reserves = Services.Reserves
        if not reserves then
            return state
        end

        if reserves.GetPlayersForItem then
            local playerLines = reserves:GetPlayersForItem(itemId, true, true, true, false)
            if type(playerLines) == "table" and #playerLines > 0 then
                state.hasReserves = true
                state.playerLines = playerLines
                return state
            end
        end

        if reserves.HasItemReserves and reserves:HasItemReserves(itemId) then
            state.hasReserves = true
        end

        return state
    end

    local function ensureLootReserveBorder(frame)
        if not frame then
            return nil
        end
        if frame._RMALootReserveBorder ~= nil then
            return frame._RMALootReserveBorder
        end
        if not frame.CreateTexture then
            return nil
        end

        local border = frame:CreateTexture(nil, "OVERLAY")
        border:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
        if border.SetBlendMode then
            border:SetBlendMode("ADD")
        end
        if border.SetVertexColor then
            border:SetVertexColor(1, 0.35, 0.85, 1)
        end
        if border.SetWidth then
            border:SetWidth(42)
        end
        if border.SetHeight then
            border:SetHeight(42)
        end
        border:Hide()
        frame._RMALootReserveBorder = border
        return border
    end

    local function setLootReserveBorder(frame, icon, shown)
        if not frame then
            return
        end

        frame._RMALootReserveMarked = shown == true
        local border = ensureLootReserveBorder(frame)
        if not border then
            return
        end

        if border.ClearAllPoints then
            border:ClearAllPoints()
        end
        if icon then
            border:SetPoint("CENTER", icon, "CENTER", 0, 0)
        else
            border:SetPoint("CENTER", frame, "CENTER", 0, 0)
        end

        if shown then
            border:Show()
        else
            border:Hide()
        end
    end

    local function showLootItemTooltip(frame)
        if not (frame and frame._RMALootItemLink) then
            return
        end
        if GetOption("UI", "showTooltips") ~= true then
            return
        end

        local playerLines = frame._RMALootReservePlayerLines
        if type(playerLines) ~= "table" or #playerLines <= 0 then
            return
        end

        local anchor = frame._RMALootTooltipAnchor or "ANCHOR_CURSOR"
        GameTooltip:SetOwner(frame, anchor)
        GameTooltip:SetHyperlink(frame._RMALootItemLink)

        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(L.StrLootReservedBy, 0.82, 0.58, 1, true)
        for i = 1, #playerLines do
            GameTooltip:AddLine(playerLines[i], 1, 1, 1, true)
        end

        GameTooltip:Show()
    end

    local function bindLootItemTooltip(frame, itemLink, reserveState, anchor)
        if not frame then
            return
        end

        frame._RMALootItemLink = itemLink
        frame._RMALootReservePlayerLines = reserveState and reserveState.playerLines or nil
        frame._RMALootTooltipAnchor = anchor or "ANCHOR_CURSOR"

        if itemLink and GetOption("UI", "showTooltips") then
            UI.Frames.SetScriptSafely(frame, "OnEnter", showLootItemTooltip)
            UI.Frames.SetScriptSafely(frame, "OnLeave", UI.Tooltips.Hide)
        else
            UI.Frames.SetScriptSafely(frame, "OnEnter", nil)
            UI.Frames.SetScriptSafely(frame, "OnLeave", nil)
        end
    end

    local function getLootFrameButton(index)
        local button = _G["LootButton" .. tostring(index)]
        if button then
            return button
        end
        local lootFrame = _G.LootFrame
        if lootFrame and type(lootFrame.buttons) == "table" then
            return lootFrame.buttons[index]
        end
        return nil
    end

    local function getLootFrameButtonSlot(button, fallbackSlot)
        local slot = tonumber(button and button.slot)
        if slot and slot > 0 then
            return slot
        end
        if button and button.GetID then
            slot = tonumber(button:GetID())
            if slot and slot > 0 then
                return slot
            end
        end
        return fallbackSlot
    end

    local function getLootFrameButtonIcon(button, index)
        if not button then
            return nil
        end

        local buttonName = button.GetName and button:GetName() or nil
        if buttonName then
            local icon = _G[buttonName .. "IconTexture"] or _G[buttonName .. "Icon"]
            if icon then
                return icon
            end
        end

        local fallbackName = "LootButton" .. tostring(index)
        return _G[fallbackName .. "IconTexture"] or _G[fallbackName .. "Icon"] or button.IconTexture or button.iconTexture or button.Icon or button.icon
    end

    local function getLootFrameButtonCount(activeCount)
        local buttonCount = tonumber(_G.LOOTFRAME_NUMBUTTONS) or 0
        if activeCount and activeCount > buttonCount then
            buttonCount = activeCount
        end
        if buttonCount > 0 then
            return buttonCount
        end

        buttonCount = 0
        for i = 1, 32 do
            if getLootFrameButton(i) then
                buttonCount = i
            elseif buttonCount > 0 then
                return buttonCount
            end
        end
        return buttonCount
    end

    local function bindLootFrameButtonTooltip(button, itemLink, reserveState, anchor)
        if not button then
            return
        end

        button._RMALootItemLink = itemLink
        button._RMALootReservePlayerLines = reserveState and reserveState.playerLines or nil
        button._RMALootTooltipAnchor = anchor or "ANCHOR_RIGHT"

        if button.HookScript then
            if not button._RMALootReserveTooltipHooked then
                button:HookScript("OnEnter", showLootItemTooltip)
                if UI.Tooltips.Hide then
                    button:HookScript("OnLeave", UI.Tooltips.Hide)
                end
                button._RMALootReserveTooltipHooked = true
            end
        else
            bindLootItemTooltip(button, itemLink, reserveState, anchor)
        end
    end

    -- ----- Public methods ----- --
    module.ApplyLootFrameReserveHints = function()
        if not _G.LootFrame then
            return
        end

        local activeCount = 0
        if type(GetNumLootItems) == "function" then
            activeCount = tonumber(GetNumLootItems()) or 0
        end

        local buttonCount = getLootFrameButtonCount(activeCount)
        for i = 1, buttonCount do
            local button = getLootFrameButton(i)
            if button then
                local slot = getLootFrameButtonSlot(button, i)
                local itemLink = nil
                if type(GetLootSlotLink) == "function" and slot and slot <= activeCount then
                    itemLink = GetLootSlotLink(slot)
                end

                local reserveState = buildLootReserveUiState(itemLink)
                setLootReserveBorder(button, getLootFrameButtonIcon(button, i), reserveState.hasReserves)
                bindLootFrameButtonTooltip(button, itemLink, reserveState, "ANCHOR_RIGHT")
            end
        end
    end

    module.ClearLootFrameReserveHints = function()
        local buttonCount = getLootFrameButtonCount(0)
        for i = 1, buttonCount do
            local button = getLootFrameButton(i)
            if button then
                button._RMALootItemLink = nil
                button._RMALootReservePlayerLines = nil
                setLootReserveBorder(button, nil, false)
            end
        end
    end

    module.EnsureLootFrameHooks = function()
        if hooksBound then
            return
        end
        hooksBound = true

        if type(hooksecurefunc) == "function" and type(_G.LootFrame_Update) == "function" then
            hooksecurefunc("LootFrame_Update", module.ApplyLootFrameReserveHints)
        end
    end

    module.EnsureLootFrameHooks()

    if UIWidgets and UIWidgets.Register then
        UIWidgets.Register("LootHints", module)
    end
end

