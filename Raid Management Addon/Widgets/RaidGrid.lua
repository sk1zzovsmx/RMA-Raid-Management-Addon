-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: local feature = addon.Database.GetFeatureShared()
-- exports: addon.Widgets.RaidGrid
-- events: listens SpecInspectUpdated
-- ui ownership: XML owns fixed picker skeletons; Lua owns dynamic buttons, data, and selection.

local addon = select(2, ...)
local feature = addon.Database.GetFeatureShared()

local Widgets = feature.Widgets
local UI = feature.UI
local Frames = UI.Frames
local UIWidgets = UI.Widgets
local Primitives = UI.Primitives
local Services = feature.Services
local Colors = feature.Colors
local L = feature.L
local Events = feature.Events
local Bus = feature.Bus

local _G = _G
local tinsert = table.insert
local type, tostring, tonumber = type, tostring, tonumber
local strmatch, strlen, strsub = string.match, string.len, string.sub
local ceil, floor, min, max = math.ceil, math.floor, math.min, math.max
local InternalEvents = Events and Events.Internal or nil

local registry = feature.ModuleRegistry
if type(registry) == "table" and type(registry.AddModule) == "function" and type(registry.SetLoaded) == "function" then
    registry.AddModule("Widgets/RaidGrid", {
        deps = {
            "Init",
            "Modules/ModuleRegistry",
            "Modules/Bus",
            "Modules/Colors",
            "Services/SpecInspect",
            "Modules/UI/Facade",
            "Modules/UI/Visuals",
        },
    })
    registry.SetLoaded("Widgets/RaidGrid")
end

do
    if UIWidgets and UIWidgets.IsEnabled and not UIWidgets.IsEnabled("RaidGrid") then
        return
    end

    Widgets.RaidGrid = Widgets.RaidGrid or {}
    local module = Widgets.RaidGrid
    addon.Widgets.RaidGrid = module

    -- ----- Internal state ----- --
    local CFG = {
        maxCols = 5,
        buttonWidth = 150,
        buttonHeight = 28,
        gapX = 5,
        gapY = 4,
        padding = 22,
        headerHeight = 80,
        footerPadding = 18,
        maxNameLen = 15,
        buttonAlpha = 0.16,
        buttonHoverAlpha = 0.35,
        specIconSize = 16,
        specIconGap = 4,
    }

    local frame
    local activeConfig
    local entries = {}
    local buttons = {}

    -- ----- Private helpers ----- --

    local function safeCall(obj, methodName, ...)
        local fn = obj and obj[methodName]
        if type(fn) == "function" then
            return fn(obj, ...)
        end
        return nil
    end

    local function setSize(obj, width, height)
        if not obj then
            return
        end
        if obj.SetSize then
            obj:SetSize(width, height)
        else
            safeCall(obj, "SetWidth", width)
            safeCall(obj, "SetHeight", height)
        end
    end

    local setTextureColor = Primitives.SetTextureColor
        or function(texture, r, g, b, a)
            if texture and texture.SetTexture then
                texture:SetTexture(r, g, b, a)
            end
        end

    local function shortName(name)
        if not name then
            return ""
        end
        return strmatch(tostring(name), "^[^-]+") or tostring(name)
    end

    local function trimName(name)
        local value = shortName(name)
        if strlen(value) > CFG.maxNameLen then
            return strsub(value, 1, CFG.maxNameLen - 3) .. "..."
        end
        return value
    end

    local function getEntryName(entry)
        return entry and (entry.displayName or entry.name) or ""
    end

    local function getClassColor(entry)
        local className = entry and entry.class
        if className and Colors and Colors.GetClassColor then
            return Colors.GetClassColor(className)
        end
        if className and _G.RAID_CLASS_COLORS and _G.RAID_CLASS_COLORS[className] then
            local color = _G.RAID_CLASS_COLORS[className]
            return color.r or 1, color.g or 0.82, color.b or 0
        end
        return 1, 0.82, 0
    end

    local function getTooltipLine()
        if activeConfig and activeConfig.mode == "target" then
            return L.TipRaidGridClickTarget
        end
        if activeConfig and activeConfig.mode == "debug" then
            return L.TipRaidGridClickDebug
        end
        return L.TipRaidGridClickAward
    end

    local function updateButtonColor(button, hovered)
        if not button or not button.bg then
            return
        end
        if hovered then
            setTextureColor(button.bg, 0.02, 0.25, 0.55, CFG.buttonHoverAlpha)
        else
            setTextureColor(button.bg, 0, 0, 0, CFG.buttonAlpha)
        end
    end

    local function getTextWidth(textFrame, fallbackText)
        if textFrame and textFrame.GetStringWidth then
            return tonumber(textFrame:GetStringWidth()) or 0
        end
        return min(CFG.buttonWidth - 8, strlen(tostring(fallbackText or "")) * 8)
    end

    local function layoutButtonText(button, label, hasSpecIcon)
        if not button or not button.text then
            return
        end

        safeCall(button.text, "ClearAllPoints")
        if hasSpecIcon and button.specIcon then
            local textWidth = getTextWidth(button.text, label)
            local groupWidth = CFG.specIconSize + CFG.specIconGap + textWidth
            local iconLeft = floor((CFG.buttonWidth - groupWidth) / 2)
            if iconLeft < 4 then
                iconLeft = 4
            end

            safeCall(button.specIcon, "ClearAllPoints")
            safeCall(button.specIcon, "SetPoint", "LEFT", button, "LEFT", iconLeft, 0)
            safeCall(button.text, "SetPoint", "LEFT", button.specIcon, "RIGHT", CFG.specIconGap, 0)
            safeCall(button.text, "SetWidth", max(20, CFG.buttonWidth - iconLeft - CFG.specIconSize - CFG.specIconGap - 4))
            safeCall(button.text, "SetJustifyH", "LEFT")
            return
        end

        safeCall(button.text, "SetPoint", "CENTER", button, "CENTER", 0, 0)
        safeCall(button.text, "SetWidth", CFG.buttonWidth - 8)
        safeCall(button.text, "SetJustifyH", "CENTER")
    end

    local function selectEntry(entry)
        if not entry then
            return nil
        end

        local result
        if activeConfig and type(activeConfig.onSelect) == "function" then
            result = activeConfig.onSelect(entry, activeConfig)
        end
        if not (activeConfig and activeConfig.closeOnSelect == false) and result ~= false then
            module.Hide()
        end
        return result
    end

    local function createButton(index)
        local buttonName = "RMARaidGridButton" .. tostring(index)
        local button = _G[buttonName]
        if not button and _G.CreateFrame then
            button = _G.CreateFrame("Button", buttonName, frame, "RMARaidGridButtonTemplate")
        end
        if not button then
            return nil
        end

        setSize(button, CFG.buttonWidth, CFG.buttonHeight)
        safeCall(button, "RegisterForClicks", "LeftButtonUp")

        local bg = _G[buttonName .. "Bg"]
        local topLine = _G[buttonName .. "TopLine"]
        local bottomLine = _G[buttonName .. "BottomLine"]
        local highlight = _G[buttonName .. "Highlight"]
        local text = _G[buttonName .. "Text"]
        local specIcon = _G[buttonName .. "SpecIcon"]
        if not bg or not topLine or not bottomLine or not highlight or not text or not specIcon then
            return nil
        end

        button.bg = bg
        button.topLine = topLine
        button.bottomLine = bottomLine
        button.highlight = highlight
        button.text = text
        button.specIcon = specIcon
        setSize(button.specIcon, CFG.specIconSize, CFG.specIconSize)
        safeCall(button.specIcon, "SetTexCoord", 0.08, 0.92, 0.08, 0.92)
        safeCall(button.specIcon, "Hide")
        buttons[index] = button
        updateButtonColor(button, false)

        safeCall(button, "SetScript", "OnEnter", function(self)
            updateButtonColor(self, true)
            if _G.GameTooltip and _G.GameTooltip.SetOwner then
                _G.GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                if _G.GameTooltip.AddLine then
                    _G.GameTooltip:AddLine(self.fullName or "Unknown", 1, 1, 1)
                    _G.GameTooltip:AddLine(getTooltipLine(), 0.75, 0.75, 0.75)
                end
                if _G.GameTooltip.Show then
                    _G.GameTooltip:Show()
                end
            end
        end)
        safeCall(button, "SetScript", "OnLeave", function(self)
            updateButtonColor(self, false)
            if _G.GameTooltip and _G.GameTooltip.Hide then
                _G.GameTooltip:Hide()
            end
        end)
        safeCall(button, "SetScript", "OnClick", function(self)
            selectEntry(self.entry)
        end)

        return button
    end

    local function ensureFrame()
        if frame then
            return frame
        end

        frame = _G.RMARaidGridFrame
        if not frame then
            return nil
        end
        frame.buttons = buttons

        frame.icon = _G.RMARaidGridFrameIcon
        frame.contextTitle = _G.RMARaidGridFrameContextTitle
        frame.count = _G.RMARaidGridFrameCount
        frame.divider = _G.RMARaidGridFrameDivider
        frame.empty = _G.RMARaidGridFrameEmpty
        frame.closeButton = _G.RMARaidGridFrameCloseButton
        if not frame.icon or not frame.contextTitle or not frame.count or not frame.divider or not frame.empty or not frame.closeButton then
            frame = nil
            return nil
        end

        safeCall(frame, "Hide")
        safeCall(frame, "SetFrameStrata", "FULLSCREEN_DIALOG")
        safeCall(frame, "SetToplevel", true)
        safeCall(frame, "SetClampedToScreen", true)
        safeCall(frame, "SetMovable", true)
        safeCall(frame, "EnableMouse", true)
        safeCall(frame, "RegisterForDrag", "LeftButton")
        safeCall(frame, "SetScript", "OnDragStart", function(self)
            if self.StartMoving then
                self:StartMoving()
            end
        end)
        safeCall(frame, "SetScript", "OnDragStop", function(self)
            if self.StopMovingOrSizing then
                self:StopMovingOrSizing()
            end
        end)
        if frame.closeButton then
            safeCall(frame.closeButton, "SetScript", "OnClick", function()
                module.Hide()
            end)
        end
        if Frames and Frames.SetFrameTitle then
            Frames.SetFrameTitle(frame, L.StrRaidGridSelectorTitle or "Grid Selector")
        else
            safeCall(_G.RMARaidGridFrameTitle, "SetText", L.StrRaidGridSelectorTitle or "Grid Selector")
        end
        setTextureColor(frame.divider, 1, 0.82, 0, 0.35)

        if type(_G.UISpecialFrames) == "table" then
            tinsert(_G.UISpecialFrames, "RMARaidGridFrame")
        end

        return frame
    end

    local function updateHeader(width)
        local title = activeConfig and activeConfig.title or L.StrRaidGridTitle
        local texture = activeConfig and activeConfig.texture or nil
        local count = activeConfig and tonumber(activeConfig.count) or nil

        if texture then
            safeCall(frame.icon, "SetTexture", texture)
            safeCall(frame.icon, "Show")
            safeCall(frame.contextTitle, "ClearAllPoints")
            safeCall(frame.contextTitle, "SetPoint", "LEFT", frame.icon, "RIGHT", 8, 0)
            safeCall(frame.contextTitle, "SetWidth", max(100, width - 120))
        else
            safeCall(frame.icon, "Hide")
            safeCall(frame.contextTitle, "ClearAllPoints")
            safeCall(frame.contextTitle, "SetPoint", "TOPLEFT", frame, "TOPLEFT", 22, -38)
            safeCall(frame.contextTitle, "SetWidth", max(100, width - 70))
        end

        safeCall(frame.contextTitle, "SetText", title or L.StrRaidGridTitle)
        if count and count > 1 then
            safeCall(frame.count, "SetText", "x" .. tostring(count))
            safeCall(frame.count, "Show")
        else
            safeCall(frame.count, "SetText", "")
            safeCall(frame.count, "Hide")
        end
    end

    local function positionFrame(anchor)
        safeCall(frame, "ClearAllPoints")
        safeCall(frame, "SetPoint", "CENTER", _G.UIParent, "CENTER", 0, 0)
        if anchor and anchor.GetFrameLevel then
            safeCall(frame, "SetFrameLevel", (anchor:GetFrameLevel() or 1) + 50)
        else
            safeCall(frame, "SetFrameLevel", 100)
        end
        safeCall(frame, "Raise")
    end

    local function normalizeConfig(selfOrConfig, maybeConfig)
        if selfOrConfig == module then
            return maybeConfig
        end
        return selfOrConfig
    end

    -- ----- Public methods ----- --
    function module.ShowPicker(selfOrConfig, maybeConfig)
        local config = normalizeConfig(selfOrConfig, maybeConfig) or {}
        local source = type(config.entries) == "table" and config.entries or {}

        if not ensureFrame() then
            return false
        end
        activeConfig = config
        entries = {}
        for i = 1, #source do
            entries[i] = source[i]
        end
        if not module.Refresh() then
            return false
        end
        positionFrame(config.anchor)
        safeCall(frame, "Show")
        return true
    end

    function module.Refresh(selfOrEntries, maybeEntries)
        local overrideEntries = selfOrEntries
        if selfOrEntries == module then
            overrideEntries = maybeEntries
        end
        if type(overrideEntries) == "table" then
            entries = {}
            for i = 1, #overrideEntries do
                entries[i] = overrideEntries[i]
            end
        end

        if not ensureFrame() then
            return false
        end
        local count = #entries
        local cols = min(CFG.maxCols, max(1, count))
        local rows = max(1, ceil(count / cols))
        local width = (CFG.padding * 2) + (cols * CFG.buttonWidth) + (max(0, cols - 1) * CFG.gapX)
        local height = CFG.headerHeight + CFG.padding + (rows * CFG.buttonHeight) + (max(0, rows - 1) * CFG.gapY) + CFG.footerPadding

        setSize(frame, width, height)
        updateHeader(width)

        if count <= 0 then
            safeCall(frame.empty, "SetText", (activeConfig and activeConfig.emptyText) or L.StrRaidGridEmpty)
            safeCall(frame.empty, "Show")
        else
            safeCall(frame.empty, "Hide")
        end

        for i = 1, #buttons do
            safeCall(buttons[i], "Hide")
        end

        for i = 1, count do
            local entry = entries[i]
            local button = buttons[i] or createButton(i)
            if not button then
                return false
            end
            local col = (i - 1) % cols
            local row = ceil(i / cols) - 1
            local x = CFG.padding + (col * (CFG.buttonWidth + CFG.gapX))
            local y = -(CFG.headerHeight + (row * (CFG.buttonHeight + CFG.gapY)))
            local r, g, b = getClassColor(entry)
            local fullName = getEntryName(entry)
            local specIcon

            if Services and Services.SpecInspect and Services.SpecInspect.GetPlayerSpecSnapshot and fullName then
                local spec = Services.SpecInspect:GetPlayerSpecSnapshot(fullName)
                specIcon = spec and spec.icon or nil
            end

            safeCall(button, "ClearAllPoints")
            safeCall(button, "SetPoint", "TOPLEFT", frame, "TOPLEFT", x, y)
            button.entry = entry
            button.fullName = fullName
            local buttonLabel = trimName(button.fullName)
            safeCall(button.text, "SetText", buttonLabel)
            safeCall(button.text, "SetTextColor", r, g, b)
            if button.specIcon then
                if specIcon and specIcon ~= "" then
                    safeCall(button.specIcon, "SetTexture", specIcon)
                    safeCall(button.specIcon, "Show")
                    layoutButtonText(button, buttonLabel, true)
                else
                    safeCall(button.specIcon, "Hide")
                    layoutButtonText(button, buttonLabel, false)
                end
            end
            updateButtonColor(button, false)
            safeCall(button, "Show")
        end

        return true
    end

    function module.Hide()
        if frame then
            safeCall(frame, "Hide")
        end
    end

    function module.IsShown()
        return frame and frame.IsShown and frame:IsShown() or false
    end

    function module.GetMode()
        return activeConfig and activeConfig.mode or nil
    end

    local function requestSpecRefresh()
        if module.IsShown() then
            module.Refresh()
        end
    end

    if Bus and InternalEvents and InternalEvents.SpecInspectUpdated then
        Bus.RegisterCallback(InternalEvents.SpecInspectUpdated, requestSpecRefresh)
    end

    if UIWidgets and UIWidgets.Register then
        UIWidgets.Register("RaidGrid", module)
    end
end

