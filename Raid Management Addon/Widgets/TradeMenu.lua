-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: local feature = addon.Database.GetFeatureShared()
-- exports: addon.Widgets.TradeMenu
-- events: none
-- notes: TradeFrame adapter for manual trade candidate dropdowns
local addon = select(2, ...)
local feature = addon.Database.GetFeatureShared()

local Widgets = feature.Widgets
local Item = feature.Item
local L = feature.L
local Services = feature.Services

local MasterService = Services.Master
local _G = _G
local string = string
local type = type
local UI = feature.UI
local UIWidgets = UI and UI.Widgets or nil

local REASON_DROPDOWN_EMPTY_TEXT = ""
local REASON_DROPDOWN_WIDTH = 32
local REASON_DROPDOWN_BUTTON_WIDTH = 32
local REASON_DROPDOWN_BUTTON_RIGHT_OVERHANG = 26
local REASON_DROPDOWN_BUTTON_BOTTOM_OVERHANG = 7
local REASON_DROPDOWN_LIST_WIDTH = 56
local REASON_DROPDOWN_LIST_BUTTON_HEIGHT = 16
local REASON_DROPDOWN_LIST_BORDER_HEIGHT = 15
local REASON_DROPDOWN_LIST_FONT = "RMAManualTradeReasonFont"
local REASON_DROPDOWN_LIST_BASE_FONT = "GameFontHighlightSmallLeft"
local REASON_DROPDOWN_LIST_FONT_PATH = "Fonts\\FRIZQT__.TTF"
local REASON_DROPDOWN_LIST_FONT_SIZE = 9
local REASON_DROPDOWN_LOCKED_TEXT_COLOR = { 0, 1, 0 }
local REASON_DROPDOWN_NEUTRAL_TEXT_COLOR = { 1, 1, 1 }

-- ----- Internal state ----- --

local registry = feature.ModuleRegistry
if type(registry) == "table" and type(registry.AddModule) == "function" and type(registry.SetLoaded) == "function" then
    registry.AddModule("Widgets/TradeMenu", {
        deps = {
            "Init",
            "Modules/ModuleRegistry",
            "Modules/UI/Frames",
            "Services/Master/Service",
        },
    })
    registry.SetLoaded("Widgets/TradeMenu")
end

-- ----- Private helpers ----- --

local function stripRealm(name)
    if type(name) ~= "string" then
        return nil
    end
    return name:gsub("%-.*$", "")
end

local function getReasonDropdownFont()
    local font = _G[REASON_DROPDOWN_LIST_FONT]
    if font ~= nil then
        return font
    end
    local baseFont = _G[REASON_DROPDOWN_LIST_BASE_FONT] or _G.GameFontHighlightSmall
    if type(CreateFont) ~= "function" then
        return baseFont
    end
    font = CreateFont(REASON_DROPDOWN_LIST_FONT)
    if not font then
        return baseFont
    end
    if baseFont and type(font.CopyFontObject) == "function" then
        font:CopyFontObject(baseFont)
    end
    if type(font.SetFont) == "function" then
        local path, _, flags
        if baseFont and type(baseFont.GetFont) == "function" then
            path, _, flags = baseFont:GetFont()
        end
        if type(path) ~= "string" or path == "" then
            path = REASON_DROPDOWN_LIST_FONT_PATH
        end
        if flags ~= nil then
            font:SetFont(path, REASON_DROPDOWN_LIST_FONT_SIZE, flags)
        else
            font:SetFont(path, REASON_DROPDOWN_LIST_FONT_SIZE)
        end
    end
    _G[REASON_DROPDOWN_LIST_FONT] = font
    return font
end

local function getTradePlayerItem(slot)
    local link = type(GetTradePlayerItemLink) == "function" and GetTradePlayerItemLink(slot) or nil
    if type(link) ~= "string" or link == "" then
        return nil
    end
    return {
        slot = slot,
        itemLink = link,
        itemString = Item.GetItemStringFromLink(link),
        itemId = Item.GetItemIdFromLink(link),
    }
end

local function ensureDropdownName(slot)
    return "RMAManualTradeReasonDropDown" .. tostring(slot)
end

local function setDropdownText(dropdown, text)
    if UIDropDownMenu_SetText then
        UIDropDownMenu_SetText(dropdown, text)
    else
        dropdown._dropdownText = text
    end
    dropdown._dropdownText = text
end

local function setDropdownShown(dropdown, shown)
    if dropdown.Show and shown then
        dropdown:Show()
    elseif dropdown.Hide and not shown then
        dropdown:Hide()
    end
    dropdown._shown = shown == true
end

local function findReasonLabel(masterService, reason)
    local reasonOrder = masterService and masterService.GetManualTradeReasonOrder and masterService.GetManualTradeReasonOrder() or nil
    if type(reasonOrder) ~= "table" then
        return ""
    end
    if reason == 0 or reason == nil then
        return ""
    end
    for i = 1, #reasonOrder do
        local value = reasonOrder[i]
        if reason == value then
            if value == feature.rollTypes.MAINSPEC then
                return L.BtnMS
            end
            if value == feature.rollTypes.OFFSPEC then
                return L.BtnOS
            end
            if value == feature.rollTypes.RESERVED then
                return L.BtnSR
            end
            if value == feature.rollTypes.FREE then
                return L.BtnFree
            end
        end
    end
    return tostring(reason or "")
end

local function getReasonText(reason)
    local text = findReasonLabel(MasterService, reason)
    return text ~= "" and text or tostring(reason or "")
end

local function getClosedReasonText(reason)
    local text = getReasonText(reason)
    if reason == feature.rollTypes.FREE and text ~= "" then
        return string.upper(string.sub(text, 1, 2))
    end
    return text
end

local function resolveDropdownMenuLevel(frameOrLevel, level)
    if type(level) == "number" then
        return level
    end
    if type(frameOrLevel) == "number" then
        return frameOrLevel
    end
    if type(UIDROPDOWNMENU_MENU_LEVEL) == "number" then
        return UIDROPDOWNMENU_MENU_LEVEL
    end
    return 1
end

local function compactManualTradeDropdownList(dropdown, level, buttonCount)
    local menuLevel = resolveDropdownMenuLevel(dropdown, level)
    local list = _G["DropDownList" .. tostring(menuLevel)]
    if not list then
        return
    end
    if type(list.SetWidth) == "function" then
        list:SetWidth(REASON_DROPDOWN_LIST_WIDTH)
    end
    local count = tonumber(buttonCount) or 0
    for i = 1, count do
        local button = _G["DropDownList" .. tostring(menuLevel) .. "Button" .. tostring(i)]
        if not button then
            break
        end
        if type(button.SetHeight) == "function" then
            button:SetHeight(REASON_DROPDOWN_LIST_BUTTON_HEIGHT)
        end
        if type(button.SetWidth) == "function" then
            button:SetWidth(REASON_DROPDOWN_LIST_WIDTH)
        end
    end
    if count > 0 and type(list.SetHeight) == "function" then
        list:SetHeight((count * REASON_DROPDOWN_LIST_BUTTON_HEIGHT) + (REASON_DROPDOWN_LIST_BORDER_HEIGHT * 2))
    end
end

local function compactManualTradeDropdownText(dropdownName)
    local text = _G[tostring(dropdownName) .. "Text"]
    local font = getReasonDropdownFont()
    if text and font and type(text.SetFontObject) == "function" then
        text:SetFontObject(font)
    end
end

local function setManualTradeLockTextColor(region, color)
    if not region then
        return
    end
    if type(region.SetTextColor) == "function" then
        region:SetTextColor(color[1], color[2], color[3])
    else
        region._textColor = { color[1], color[2], color[3] }
    end
end

local function setManualTradeLockTextureColor(frame, color)
    if not frame then
        return
    end
    local normalTexture = type(frame.GetNormalTexture) == "function" and frame:GetNormalTexture() or nil
    if normalTexture and type(normalTexture.SetVertexColor) == "function" then
        normalTexture:SetVertexColor(color[1], color[2], color[3])
    end
    frame._vertexColor = { color[1], color[2], color[3] }
end

local function positionDropdown(dropdown, slot, parent)
    if not dropdown or not dropdown.SetPoint then
        return
    end
    if dropdown.ClearAllPoints then
        dropdown:ClearAllPoints()
    end
    local slotFrame = _G["TradePlayerItem" .. tostring(slot)]
    if slotFrame then
        dropdown:SetPoint("BOTTOMRIGHT", slotFrame, "BOTTOMRIGHT", -REASON_DROPDOWN_BUTTON_RIGHT_OVERHANG, -REASON_DROPDOWN_BUTTON_BOTTOM_OVERHANG)
    else
        dropdown:SetPoint("TOPLEFT", parent, "TOPLEFT", 120, -35 - (slot - 1) * 38)
    end
end

local function initDropdown(dropdown, candidate, masterService)
    if not dropdown then
        return
    end
    if UIDropDownMenu_Initialize then
        UIDropDownMenu_Initialize(dropdown, function(frameOrLevel, level)
            local menuLevel = resolveDropdownMenuLevel(frameOrLevel, level)
            local reasonOrder = masterService and masterService.GetManualTradeReasonOrder and masterService.GetManualTradeReasonOrder() or {}
            if menuLevel ~= 1 then
                return
            end
            for i = 1, #reasonOrder do
                local reason = reasonOrder[i]
                local info = UIDropDownMenu_CreateInfo()
                info.arg1 = candidate and candidate.lootNid or nil
                info.arg2 = reason
                info.text = getReasonText(reason)
                info.hasArrow = false
                info.fontObject = getReasonDropdownFont()
                info.notCheckable = 1
                info.func = function(_, argLootNid, argReason)
                    if dropdown._RMAManualTradeLocked == true then
                        return
                    end
                    if masterService and masterService.SetManualTradeReason then
                        masterService.SetManualTradeReason(argLootNid, argReason)
                    end
                    if candidate then
                        candidate.reason = argReason
                        setDropdownText(dropdown, getClosedReasonText(argReason))
                        UIDropDownMenu_SetSelectedValue(dropdown, argReason)
                    end
                    if type(CloseDropDownMenus) == "function" then
                        CloseDropDownMenus()
                    end
                end
                UIDropDownMenu_AddButton(info, menuLevel)
            end
            compactManualTradeDropdownList(dropdown, menuLevel, #reasonOrder)
        end)
    end
end

local function applyManualTradeLock(dropdown, isLocked)
    if not dropdown then
        return
    end
    isLocked = isLocked == true
    dropdown._RMAManualTradeLocked = isLocked
    local dropdownName = type(dropdown.GetName) == "function" and dropdown:GetName() or nil
    if dropdown.Enable then
        dropdown:Enable()
    end
    dropdown._enabled = true
    if dropdown.EnableMouse then
        dropdown:EnableMouse(not isLocked)
    end

    local button = dropdown.Button or (dropdownName and _G[tostring(dropdownName) .. "Button"]) or nil
    if button then
        button._RMAManualTradeLocked = isLocked
        if button.Enable then
            button:Enable()
        end
        button._enabled = true
        if button.EnableMouse then
            button:EnableMouse(not isLocked)
        end
    end

    local color = isLocked and REASON_DROPDOWN_LOCKED_TEXT_COLOR or REASON_DROPDOWN_NEUTRAL_TEXT_COLOR
    local text = dropdownName and _G[tostring(dropdownName) .. "Text"] or nil
    setManualTradeLockTextColor(dropdown, color)
    setManualTradeLockTextColor(text, color)
    setManualTradeLockTextureColor(dropdown, color)
    setManualTradeLockTextureColor(button, color)

    if isLocked and type(CloseDropDownMenus) == "function" then
        CloseDropDownMenus()
    end
end

local function buildDropdown(slot, reasonOrder)
    local dropdownName = ensureDropdownName(slot)
    local dropdown = _G[dropdownName]
    local parent = _G.TradeFrame or _G.UIParent
    local base = type(CreateFrame) == "function" and CreateFrame or nil
    if not dropdown and not base then
        return nil
    end
    if not dropdown then
        dropdown = base("Frame", dropdownName, parent, "UIDropDownMenuTemplate")
    end
    if not dropdown then
        return nil
    end
    if UIDropDownMenu_SetWidth then
        UIDropDownMenu_SetWidth(dropdown, REASON_DROPDOWN_WIDTH, 0)
    end
    if UIDropDownMenu_SetButtonWidth then
        UIDropDownMenu_SetButtonWidth(dropdown, REASON_DROPDOWN_BUTTON_WIDTH)
    end
    compactManualTradeDropdownText(dropdownName)
    positionDropdown(dropdown, slot, parent)
    _G[dropdownName] = dropdown
    dropdown._RMAManualTradeSlot = slot
    dropdown._RMAManualTradeReasonOrder = reasonOrder
    return dropdown
end

local module = Widgets.TradeMenu or {}
Widgets.TradeMenu = module
addon.Widgets.TradeMenu = module

module._dropdowns = module._dropdowns or {}

-- ----- Public methods ----- --

function module.GetTradePlayerItems()
    local items = {}
    for slot = 1, 6 do
        local item = getTradePlayerItem(slot)
        if item then
            items[item.slot] = item
        end
    end
    return items
end

function module.ResolveTradePartnerName()
    local partner
    if _G.TradeFrameRecipientNameText and type(_G.TradeFrameRecipientNameText.GetText) == "function" then
        partner = _G.TradeFrameRecipientNameText:GetText()
    end
    if not partner and type(UnitName) == "function" then
        local npcName = UnitName("NPC")
        if npcName and npcName ~= "" then
            partner = npcName
        end
    end
    if not partner and type(UnitName) == "function" then
        local targetName = UnitName("target")
        if targetName and targetName ~= "" then
            partner = targetName
        end
    end
    return stripRealm(partner)
end

function module.RefreshDropdowns(state)
    local candidates = state and state.candidatesBySlot or {}
    local localAccepted = state and state.localAccepted == true
    for slot = 1, 6 do
        local dropdown = module._dropdowns[slot]
            or buildDropdown(slot, MasterService and MasterService.GetManualTradeReasonOrder and MasterService.GetManualTradeReasonOrder() or nil)
        if not dropdown then
            module._dropdowns[slot] = nil
        else
            module._dropdowns[slot] = dropdown

            local candidate = candidates[slot]
            if candidate then
                dropdown._RMAManualTradeCandidate = candidate
                if UIDropDownMenu_SetSelectedValue then
                    UIDropDownMenu_SetSelectedValue(dropdown, candidate.reason or 0)
                end
                local reasonText = REASON_DROPDOWN_EMPTY_TEXT
                if candidate.reason then
                    reasonText = getClosedReasonText(candidate.reason)
                end
                setDropdownText(dropdown, reasonText)
                initDropdown(dropdown, candidate, MasterService)
                setDropdownShown(dropdown, true)
                applyManualTradeLock(dropdown, localAccepted == true)
            else
                dropdown._RMAManualTradeCandidate = nil
                setDropdownText(dropdown, REASON_DROPDOWN_EMPTY_TEXT)
                setDropdownShown(dropdown, false)
                applyManualTradeLock(dropdown, false)
            end
        end
    end
end

function module.HideDropdowns()
    for slot = 1, 6 do
        local dropdown = module._dropdowns[slot]
        if dropdown then
            setDropdownShown(dropdown, false)
            setDropdownText(dropdown, REASON_DROPDOWN_EMPTY_TEXT)
            dropdown._RMAManualTradeCandidate = nil
            if UIDropDownMenu_SetSelectedValue then
                UIDropDownMenu_SetSelectedValue(dropdown, nil)
            end
            applyManualTradeLock(dropdown, false)
        end
    end
end

function module.RefreshCandidate(source)
    if not MasterService then
        return nil
    end
    local tradeItems = module.GetTradePlayerItems()
    local partnerName = module.ResolveTradePartnerName()
    local state = MasterService.RefreshManualTradeCandidate({
        source = source,
        tradeItems = tradeItems,
        partnerName = partnerName,
    })
    module._state = state
    return module.RefreshDropdowns(state)
end

function module.Reset()
    module._state = nil
    module.HideDropdowns()
end

if UIWidgets and UIWidgets.IsEnabled then
    if UIWidgets.IsEnabled("TradeMenu") ~= false then
        if UIWidgets.Register then
            UIWidgets.Register("TradeMenu", module)
        end
    end
end

