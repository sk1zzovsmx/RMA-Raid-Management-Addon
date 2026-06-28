-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: local feature = addon.Database.GetFeatureShared()
-- exports: addon.UI.Layout
-- events: none
local addon = select(2, ...)
local feature = addon.Database.GetFeatureShared()

local UI = feature.UI or {}
local Frames = UI.Frames

local _G = _G

local pairs, type, tonumber = pairs, type, tonumber
local max = math.max

local Layout = UI.Layout or {}
UI.Layout = Layout

-- ----- Internal state ----- --
local defaults = {
    leftX = 16,
    topY = -16,
    contentWidth = 380,
    scrollChildWidth = 520,
    textWidth = 240,
    commandWidth = 105,
    columnGap = 12,
    rowGap = 8,
    sectionGap = 14,
    bodyGap = 4,
    titleHeight = 24,
    sectionHeight = 16,
    labelHeight = 14,
    descHeight = 24,
    bodyHeight = 44,
    buttonHeight = 25,
    editHeight = 20,
    dropdownHeight = 32,
    bottomPadding = 24,
    minHeight = 0,
}

-- ----- Private helpers ----- --
local function getCfg(cfg, key)
    local value = cfg and cfg[key]
    if value == nil then
        return defaults[key]
    end
    return value
end

local function resolveFrame(frameOrName)
    if type(frameOrName) == "string" then
        return _G[frameOrName]
    end
    return frameOrName
end

local function resolveWidget(frame, suffix)
    if not (frame and suffix) then
        return nil
    end
    if Frames and Frames.GetRef then
        return Frames.GetRef(frame, suffix)
    end
    if frame.GetName then
        local frameName = frame:GetName()
        if frameName then
            return _G[frameName .. suffix]
        end
    end
    return nil
end

local function setSize(widget, width, height)
    if not widget then
        return
    end
    if width and widget.SetWidth then
        widget:SetWidth(width)
    end
    if height and widget.SetHeight then
        widget:SetHeight(height)
    end
end

local function place(parent, widget, x, y, width, height)
    if not (parent and widget) then
        return nil
    end
    if widget.ClearAllPoints then
        widget:ClearAllPoints()
    end
    setSize(widget, width, height)
    if widget.SetPoint then
        widget:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    end
    if widget.Show then
        widget:Show()
    end
    return widget
end

local function placeText(parent, widget, x, y, width, height)
    if place(parent, widget, x, y, width, height) then
        if widget.SetJustifyH then
            widget:SetJustifyH("LEFT")
        end
        if widget.SetJustifyV then
            widget:SetJustifyV("TOP")
        end
    end
end

local function rowGap(row, cfg)
    if row.gap ~= nil then
        return row.gap
    end
    return getCfg(cfg, "rowGap")
end

local function numberOrDefault(value, fallback)
    return tonumber(value) or fallback
end

local function placeButton(parent, button, x, y, width, height)
    place(parent, button, x, y, width, height)
end

local function applyTextRow(frame, row, cfg, cursorY, titleHeight, bodyGap)
    local leftX = row.leftX or getCfg(cfg, "leftX")
    local contentWidth = row.width or getCfg(cfg, "contentWidth")
    local bodyHeight = row.bodyHeight or getCfg(cfg, "bodyHeight")
    placeText(frame, resolveWidget(frame, row.title), leftX, cursorY, contentWidth, titleHeight)
    placeText(frame, resolveWidget(frame, row.body), leftX, cursorY - titleHeight - bodyGap, contentWidth, bodyHeight)
    return titleHeight + bodyGap + bodyHeight
end

local function applyCommandRow(frame, row, cfg, cursorY, titleHeight, bodyGap)
    local leftX = row.leftX or getCfg(cfg, "leftX")
    local textWidth = row.textWidth or getCfg(cfg, "textWidth")
    local commandWidth = row.commandWidth or getCfg(cfg, "commandWidth")
    local columnGap = getCfg(cfg, "columnGap")
    local commandX = leftX + textWidth + columnGap
    local buttonHeight = row.buttonHeight or getCfg(cfg, "buttonHeight")
    local descHeight = row.descHeight or getCfg(cfg, "descHeight")
    local height = row.height or (titleHeight + bodyGap + descHeight)

    placeText(frame, resolveWidget(frame, row.title), leftX, cursorY, textWidth, titleHeight)
    placeText(frame, resolveWidget(frame, row.desc), leftX, cursorY - titleHeight - bodyGap, textWidth, descHeight)
    placeButton(frame, resolveWidget(frame, row.button), commandX, cursorY + (row.buttonYOffset or -4), commandWidth, buttonHeight)
    return height
end

local function applyEditCommandRow(frame, row, cfg, cursorY, titleHeight, bodyGap)
    local leftX = row.leftX or getCfg(cfg, "leftX")
    local textWidth = row.textWidth or getCfg(cfg, "textWidth")
    local commandWidth = row.commandWidth or getCfg(cfg, "commandWidth")
    local columnGap = getCfg(cfg, "columnGap")
    local commandX = leftX + textWidth + columnGap
    local buttonHeight = row.buttonHeight or getCfg(cfg, "buttonHeight")
    local editHeight = row.editHeight or getCfg(cfg, "editHeight")
    local descHeight = row.descHeight or getCfg(cfg, "descHeight")
    local height = row.height or (titleHeight + bodyGap + descHeight)

    placeText(frame, resolveWidget(frame, row.title), leftX, cursorY, textWidth, titleHeight)
    placeText(frame, resolveWidget(frame, row.desc), leftX, cursorY - titleHeight - bodyGap, textWidth, descHeight)
    place(frame, resolveWidget(frame, row.editBox), commandX, cursorY + (row.editYOffset or -2), commandWidth, editHeight)
    placeButton(frame, resolveWidget(frame, row.button), commandX, cursorY - editHeight - (row.buttonGap or 8), commandWidth, buttonHeight)
    return height
end

local function applyEditRow(frame, row, cfg, cursorY, titleHeight, bodyGap)
    local leftX = row.leftX or getCfg(cfg, "leftX")
    local textWidth = row.textWidth or getCfg(cfg, "textWidth")
    local commandWidth = row.commandWidth or getCfg(cfg, "commandWidth")
    local columnGap = getCfg(cfg, "columnGap")
    local commandX = leftX + textWidth + columnGap
    local editHeight = row.editHeight or getCfg(cfg, "editHeight")
    local descHeight = row.descHeight or getCfg(cfg, "descHeight")
    local height = row.height or (titleHeight + bodyGap + descHeight)

    placeText(frame, resolveWidget(frame, row.title), leftX, cursorY, textWidth, titleHeight)
    placeText(frame, resolveWidget(frame, row.desc), leftX, cursorY - titleHeight - bodyGap, textWidth, descHeight)
    place(frame, resolveWidget(frame, row.editBox), commandX, cursorY + (row.editYOffset or -2), commandWidth, editHeight)
    return height
end

local function applyDropDownRow(frame, row, cfg, cursorY, titleHeight, bodyGap)
    local leftX = row.leftX or getCfg(cfg, "leftX")
    local textWidth = row.textWidth or getCfg(cfg, "textWidth")
    local commandWidth = row.commandWidth or getCfg(cfg, "commandWidth")
    local columnGap = getCfg(cfg, "columnGap")
    local commandX = leftX + textWidth + columnGap
    local dropdownHeight = row.dropdownHeight or getCfg(cfg, "dropdownHeight")
    local descHeight = row.descHeight or getCfg(cfg, "descHeight")
    local height = row.height or (titleHeight + bodyGap + descHeight)
    local dropDown = resolveWidget(frame, row.dropdown)

    placeText(frame, resolveWidget(frame, row.title), leftX, cursorY, textWidth, titleHeight)
    placeText(frame, resolveWidget(frame, row.desc), leftX, cursorY - titleHeight - bodyGap, textWidth, descHeight)
    place(frame, dropDown, commandX, cursorY + (row.dropdownYOffset or -4), commandWidth, dropdownHeight)
    if _G.UIDropDownMenu_SetWidth and dropDown then
        _G.UIDropDownMenu_SetWidth(dropDown, row.dropdownTextWidth or commandWidth - 33)
    end
    if _G.UIDropDownMenu_SetButtonWidth and dropDown then
        _G.UIDropDownMenu_SetButtonWidth(dropDown, row.dropdownButtonWidth or commandWidth - 13)
    end
    return height
end

local function applyCheckRow(frame, row, cfg, cursorY, labelHeight, bodyGap)
    local leftX = row.leftX or getCfg(cfg, "leftX")
    local textX = leftX + (row.checkTextOffset or 34)
    local textWidth = row.textWidth or getCfg(cfg, "contentWidth") - (textX - leftX)
    local descHeight = row.descHeight or getCfg(cfg, "descHeight")
    local height = row.height or (labelHeight + bodyGap + descHeight)
    local check = resolveWidget(frame, row.check)

    place(frame, check, leftX, cursorY + (row.checkYOffset or 2), row.checkSize or 26, row.checkSize or 26)
    placeText(frame, resolveWidget(frame, row.label), textX, cursorY, textWidth, labelHeight)
    placeText(frame, resolveWidget(frame, row.desc), textX, cursorY - labelHeight - bodyGap, textWidth, descHeight)
    return height
end

local function applySliderRow(frame, row, cfg, cursorY, titleHeight, bodyGap)
    local leftX = row.leftX or getCfg(cfg, "leftX")
    local contentWidth = row.width or getCfg(cfg, "contentWidth")
    local descHeight = row.descHeight or getCfg(cfg, "descHeight")
    local controlWidth = row.controlWidth or 180
    local height = row.height or 78
    local sliderX = leftX + (row.sliderX or 34)
    local sliderY = cursorY - titleHeight - bodyGap - descHeight - (row.sliderGap or 18)

    placeText(frame, resolveWidget(frame, row.title), leftX, cursorY, contentWidth, titleHeight)
    placeText(frame, resolveWidget(frame, row.desc), leftX + 34, cursorY - titleHeight - bodyGap, contentWidth - 34, descHeight)
    place(frame, resolveWidget(frame, row.control), sliderX, sliderY, controlWidth, row.controlHeight or 15)
    return height
end

local function applyButtonRow(frame, row, cfg, cursorY)
    local leftX = row.leftX or getCfg(cfg, "leftX")
    local buttonWidth = row.buttonWidth or getCfg(cfg, "commandWidth")
    local buttonHeight = row.buttonHeight or getCfg(cfg, "buttonHeight")
    local gap = row.buttonGap or 12
    local buttons = row.buttons or {}

    for i = 1, #buttons do
        placeButton(frame, resolveWidget(frame, buttons[i]), leftX + ((i - 1) * (buttonWidth + gap)), cursorY, buttonWidth, buttonHeight)
    end
    return row.height or buttonHeight
end

local function applyRow(frame, row, cfg, cursorY)
    local rowType = row.type
    local titleHeight = row.titleHeight or getCfg(cfg, "titleHeight")
    local sectionHeight = row.sectionHeight or getCfg(cfg, "sectionHeight")
    local labelHeight = row.labelHeight or getCfg(cfg, "labelHeight")
    local bodyGap = row.bodyGap or getCfg(cfg, "bodyGap")
    local height = row.height
    local computedHeight

    if rowType == "space" then
        height = row.height or row.size or 0
    elseif rowType == "title" then
        height = height or titleHeight
        placeText(frame, resolveWidget(frame, row.suffix), row.leftX or getCfg(cfg, "leftX"), cursorY, row.width or getCfg(cfg, "contentWidth"), height)
    elseif rowType == "section" then
        height = height or sectionHeight
        placeText(frame, resolveWidget(frame, row.suffix), row.leftX or getCfg(cfg, "leftX"), cursorY, row.width or getCfg(cfg, "contentWidth"), height)
    elseif rowType == "body" then
        height = height or row.bodyHeight or getCfg(cfg, "bodyHeight")
        placeText(frame, resolveWidget(frame, row.suffix), row.leftX or getCfg(cfg, "leftX"), cursorY, row.width or getCfg(cfg, "contentWidth"), height)
    elseif rowType == "text" then
        computedHeight = applyTextRow(frame, row, cfg, cursorY, sectionHeight, bodyGap)
        height = height or computedHeight
    elseif rowType == "check" then
        computedHeight = applyCheckRow(frame, row, cfg, cursorY, labelHeight, bodyGap)
        height = height or computedHeight
    elseif rowType == "slider" then
        computedHeight = applySliderRow(frame, row, cfg, cursorY, sectionHeight, bodyGap)
        height = height or computedHeight
    elseif rowType == "command" then
        computedHeight = applyCommandRow(frame, row, cfg, cursorY, titleHeight, bodyGap)
        height = height or computedHeight
    elseif rowType == "editCommand" then
        computedHeight = applyEditCommandRow(frame, row, cfg, cursorY, titleHeight, bodyGap)
        height = height or computedHeight
    elseif rowType == "edit" then
        computedHeight = applyEditRow(frame, row, cfg, cursorY, titleHeight, bodyGap)
        height = height or computedHeight
    elseif rowType == "dropdown" then
        computedHeight = applyDropDownRow(frame, row, cfg, cursorY, titleHeight, bodyGap)
        height = height or computedHeight
    elseif rowType == "buttonRow" then
        computedHeight = applyButtonRow(frame, row, cfg, cursorY)
        height = height or computedHeight
    else
        height = row.height or 0
    end

    return cursorY - numberOrDefault(height, 0) - rowGap(row, cfg)
end

local function copyRow(base, attrs)
    local row = {}
    for key, value in pairs(base or {}) do
        row[key] = value
    end
    for key, value in pairs(attrs or {}) do
        row[key] = value
    end
    return row
end

-- ----- Public methods ----- --
function Layout.TextRow(title, body, attrs)
    return copyRow({
        type = "text",
        title = title,
        body = body,
    }, attrs)
end

function Layout.CheckRow(prefix, attrs)
    return copyRow({
        type = "check",
        check = prefix,
        label = prefix .. "Str",
        desc = prefix .. "Desc",
    }, attrs)
end

function Layout.SliderRow(prefix, control, attrs)
    return copyRow({
        type = "slider",
        title = prefix .. "Str",
        desc = prefix .. "Desc",
        control = control or prefix,
    }, attrs)
end

function Layout.CommandRow(prefix, button, attrs)
    return copyRow({
        type = "command",
        title = prefix .. "Title",
        desc = prefix .. "Desc",
        button = button or (prefix .. "Btn"),
    }, attrs)
end

function Layout.EditCommandRow(prefix, editBox, button, attrs)
    return copyRow({
        type = "editCommand",
        title = prefix .. "Title",
        desc = prefix .. "Desc",
        editBox = editBox or (prefix .. "EditBox"),
        button = button or (prefix .. "Btn"),
    }, attrs)
end

function Layout.EditRow(prefix, editBox, attrs)
    return copyRow({
        type = "edit",
        title = prefix .. "Str",
        desc = prefix .. "Desc",
        editBox = editBox or (prefix .. "EditBox"),
    }, attrs)
end

function Layout.DropDownRow(prefix, dropdown, attrs)
    return copyRow({
        type = "dropdown",
        title = prefix .. "Title",
        desc = prefix .. "Desc",
        dropdown = dropdown or (prefix .. "DropDown"),
    }, attrs)
end

function Layout.ButtonRow(buttons, attrs)
    return copyRow({
        type = "buttonRow",
        buttons = buttons,
    }, attrs)
end

function Layout.ApplyRows(frameOrName, rows, cfg)
    local frame = resolveFrame(frameOrName)
    if not (frame and type(rows) == "table") then
        return 0
    end

    local cursorY = getCfg(cfg, "topY")
    local minY = cursorY
    for i = 1, #rows do
        cursorY = applyRow(frame, rows[i], cfg, cursorY)
        if cursorY < minY then
            minY = cursorY
        end
    end

    local minHeight = getCfg(cfg, "minHeight")
    local bottomPadding = getCfg(cfg, "bottomPadding")
    local height = max(minHeight, -minY + bottomPadding)
    setSize(frame, getCfg(cfg, "scrollChildWidth"), height)
    return height
end

local registry = feature.ModuleRegistry
if type(registry) == "table" and type(registry.AddModule) == "function" and type(registry.SetLoaded) == "function" then
    registry.AddModule("Modules/UI/OptionsLayout", { deps = { "Init", "Modules/ModuleRegistry", "Modules/UI/Frames" } })
    registry.SetLoaded("Modules/UI/OptionsLayout")
end

