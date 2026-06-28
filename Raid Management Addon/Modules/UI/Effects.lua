-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: local feature = addon.Database.GetFeatureShared()
-- exports: addon.UI.Effects
-- events: none; owns UI effect OnUpdate drivers

local addon = select(2, ...)
local feature = addon.Database.GetFeatureShared()

local floor = math.floor
local max = math.max
local min = math.min
local lower = string.lower
local pairs = pairs
local tonumber, type = tonumber, type

local UI = feature.UI or {}
local Effects = UI.Effects or {}
UI.Effects = Effects

-- ----- Internal state ----- --
local DEFAULT_GLOW_METHOD = "Proc"
local FRAME_LEVEL_OFFSETS = {
    frame = 6,
    ring = 7,
    proc = 8,
    button = 9,
}
local PROC_LAYER_SIZES = { 7, 6, 5, 4 }
local MAX_PROC_LINES = 8
local BUTTON_OVERLAY_SCALE = 1.78

local METHOD_VISUALS = {
    ACShine = {
        flags = { base = false, ring = false, proc = true, button = false },
        defaults = { glowType = "ACShine" },
        pulse = {
            ring = { min = 0.0, max = 0.0, fadeIn = 0.0, fadeOut = 0.0 },
            frame = { min = 0.0, max = 0.0, fadeIn = 0.0, fadeOut = 0.0 },
            fill = { min = 0.0, max = 0.0, fadeIn = 0.0, fadeOut = 0.0 },
            button = { min = 0.0, max = 0.0, fadeIn = 0.0, fadeOut = 0.0 },
        },
    },
    Pixel = {
        flags = { base = false, ring = true, proc = false, button = false },
        defaults = { glowType = "Pixel", glowBorder = true },
        pulse = {
            ring = { min = 0.26, max = 0.66, fadeIn = 0.16, fadeOut = 0.30 },
            frame = { min = 0.0, max = 0.0, fadeIn = 0.0, fadeOut = 0.0 },
            fill = { min = 0.0, max = 0.0, fadeIn = 0.0, fadeOut = 0.0 },
            button = { min = 0.0, max = 0.0, fadeIn = 0.0, fadeOut = 0.0 },
        },
    },
    Proc = {
        flags = { base = true, ring = true, proc = false, button = false },
        defaults = { glowType = "Proc" },
        pulse = {
            frame = { min = 0.34, max = 0.58, fadeIn = 0.22, fadeOut = 0.42 },
            fill = { min = 0.01, max = 0.04, fadeIn = 0.24, fadeOut = 0.48 },
            ring = { min = 0.28, max = 0.62, fadeIn = 0.18, fadeOut = 0.34 },
            button = { min = 0.0, max = 0.0, fadeIn = 0.0, fadeOut = 0.0 },
        },
    },
    buttonOverlay = {
        flags = { base = false, ring = false, proc = false, button = true },
        defaults = { glowType = "buttonOverlay" },
        pulse = {
            button = { min = 0.36, max = 0.74, fadeIn = 0.20, fadeOut = 0.36 },
            frame = { min = 0.0, max = 0.0, fadeIn = 0.0, fadeOut = 0.0 },
            fill = { min = 0.0, max = 0.0, fadeIn = 0.0, fadeOut = 0.0 },
            ring = { min = 0.0, max = 0.0, fadeIn = 0.0, fadeOut = 0.0 },
        },
    },
}

Effects.GlowMethods = {
    canonical = { "ACShine", "Pixel", "Proc", "buttonOverlay" },
    types = METHOD_VISUALS,
    defaultSettings = {},
}

local function copyColor(color)
    return {
        color[1] or 1,
        color[2] or 1,
        color[3] or 1,
        color[4] or 1,
    }
end

local function copyInto(dst, src)
    for k, v in pairs(src) do
        dst[k] = v
    end
end

local function createBaseSubGlowDefaults()
    return {
        glow = false,
        glowBorder = false,
        glowColor = { 1, 1, 1, 1 },
        glowDuration = 1,
        glowFrequency = 0.25,
        glowLength = 10,
        glowLines = 8,
        glowScale = 1,
        glowThickness = 1,
        glowXOffset = 0,
        glowYOffset = 0,
        useGlowColor = false,
        type = "subglow",
    }
end

local function buildMethodDefaults(methodKey, options)
    local method = METHOD_VISUALS[methodKey]
    local settings = {}
    copyInto(settings, createBaseSubGlowDefaults())
    copyInto(settings, method.defaults)
    if options then
        copyInto(settings, options)
    end
    settings.glowColor = copyColor(settings.glowColor)
    return settings
end

for methodKey, _ in pairs(METHOD_VISUALS) do
    Effects.GlowMethods.defaultSettings[methodKey] = buildMethodDefaults(methodKey)
end

-- ----- Private helpers ----- --
local function resolveMethodKey(methodName)
    if METHOD_VISUALS[methodName] then
        return methodName
    end

    local lowered = lower(tostring(methodName or ""))
    for key, _ in pairs(METHOD_VISUALS) do
        if lower(key) == lowered then
            return key
        end
    end

    return DEFAULT_GLOW_METHOD
end

local function resolveMethod(methodName, options)
    local methodKey = resolveMethodKey(methodName)
    local methodCfg = METHOD_VISUALS[methodKey]
    local settings = buildMethodDefaults(methodKey, options)
    return methodKey, methodCfg, settings
end

-- ----- Public methods ----- --
local function setFrameLayer(frame, button, levelOffset)
    frame:SetFrameStrata(button:GetFrameStrata())
    frame:SetFrameLevel((button:GetFrameLevel() or 1) + levelOffset)
end

local function clamp(value, minValue, maxValue)
    if value < minValue then
        return minValue
    end
    if value > maxValue then
        return maxValue
    end
    return value
end

local function applyDynamicSettings(button, methodCfg, settings)
    local width = button:GetWidth() or 36
    local height = button:GetHeight() or 36
    local shortSide = width
    if height < shortSide then
        shortSide = height
    end
    local perimeter = 2 * (width + height)

    local dynamic = {}
    copyInto(dynamic, settings)

    if methodCfg.flags.ring then
        dynamic.glowThickness = clamp(floor(shortSide * 0.07 + 0.5), 1, 3)
    end

    if methodCfg.flags.proc then
        dynamic.glowLines = clamp(floor(perimeter / 26 + 0.5), 4, MAX_PROC_LINES)
        dynamic.glowFrequency = clamp(0.18 + shortSide / 130, 0.25, 1.25)
        dynamic.glowScale = clamp(settings.glowScale * (0.75 + shortSide / 120), 0.7, 1.8)
    elseif methodCfg.flags.button then
        dynamic.glowScale = clamp(settings.glowScale * (0.92 + shortSide / 140), 0.85, 1.8)
    else
        dynamic.glowScale = clamp(settings.glowScale * (0.86 + shortSide / 150), 0.8, 1.5)
    end

    return dynamic
end

local function configurePulsePair(animIn, animOut, pulseCfg, durationScale)
    animIn:SetDuration(pulseCfg.fadeIn * durationScale)
    animIn:SetChange(pulseCfg.max - pulseCfg.min)
    animOut:SetDuration(pulseCfg.fadeOut * durationScale)
    animOut:SetChange(pulseCfg.min - pulseCfg.max)
end

local function applyPulseConfig(glow, methodCfg, settings)
    local pulse = methodCfg.pulse
    local durationScale = settings.glowDuration

    configurePulsePair(glow.anim.frameIn, glow.anim.frameOut, pulse.frame, durationScale)
    configurePulsePair(glow.anim.fillIn, glow.anim.fillOut, pulse.fill, durationScale)
    configurePulsePair(glow.anim.ringIn, glow.anim.ringOut, pulse.ring, durationScale)
    configurePulsePair(glow.anim.buttonIn, glow.anim.buttonOut, pulse.button, durationScale)

    glow.frame:SetAlpha(pulse.frame.min)
    glow.fill:SetAlpha(pulse.fill.min)
    glow.ringFrame:SetAlpha(pulse.ring.min)
    glow.buttonTexture:SetAlpha(pulse.button.min)
end

local function applyGlowColor(glow, r, g, b)
    glow.fill:SetVertexColor(r, g, b, 1)

    glow.ringEdges.top:SetVertexColor(r, g, b, 1)
    glow.ringEdges.bottom:SetVertexColor(r, g, b, 1)
    glow.ringEdges.left:SetVertexColor(r, g, b, 1)
    glow.ringEdges.right:SetVertexColor(r, g, b, 1)

    glow.buttonTexture:SetVertexColor(r, g, b, 1)
end

local function updateGlowGeometry(glow, button, settings)
    local xOffset = settings.glowXOffset
    local yOffset = settings.glowYOffset

    local ringFrame = glow.ringFrame
    local thickness = floor(settings.glowThickness + 0.5)
    if thickness < 1 then
        thickness = 1
    end

    ringFrame:ClearAllPoints()
    ringFrame:SetPoint("TOPLEFT", button, "TOPLEFT", xOffset, yOffset)
    ringFrame:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", xOffset, yOffset)

    glow.ringEdges.top:ClearAllPoints()
    glow.ringEdges.top:SetPoint("TOPLEFT", ringFrame, "TOPLEFT", 0, 0)
    glow.ringEdges.top:SetPoint("TOPRIGHT", ringFrame, "TOPRIGHT", 0, 0)
    glow.ringEdges.top:SetHeight(thickness)

    glow.ringEdges.bottom:ClearAllPoints()
    glow.ringEdges.bottom:SetPoint("BOTTOMLEFT", ringFrame, "BOTTOMLEFT", 0, 0)
    glow.ringEdges.bottom:SetPoint("BOTTOMRIGHT", ringFrame, "BOTTOMRIGHT", 0, 0)
    glow.ringEdges.bottom:SetHeight(thickness)

    glow.ringEdges.left:ClearAllPoints()
    glow.ringEdges.left:SetPoint("TOPLEFT", ringFrame, "TOPLEFT", 0, 0)
    glow.ringEdges.left:SetPoint("BOTTOMLEFT", ringFrame, "BOTTOMLEFT", 0, 0)
    glow.ringEdges.left:SetWidth(thickness)

    glow.ringEdges.right:ClearAllPoints()
    glow.ringEdges.right:SetPoint("TOPRIGHT", ringFrame, "TOPRIGHT", 0, 0)
    glow.ringEdges.right:SetPoint("BOTTOMRIGHT", ringFrame, "BOTTOMRIGHT", 0, 0)
    glow.ringEdges.right:SetWidth(thickness)

    glow.procFrame:ClearAllPoints()
    glow.procFrame:SetPoint("TOPLEFT", button, "TOPLEFT", xOffset, yOffset)
    glow.procFrame:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", xOffset, yOffset)

    local width = button:GetWidth() or 36
    local height = button:GetHeight() or 36
    local overlayScale = BUTTON_OVERLAY_SCALE * settings.glowScale
    local overlaySize = max(width, height) * overlayScale

    glow.buttonTexture:SetWidth(overlaySize)
    glow.buttonTexture:SetHeight(overlaySize)
    glow.buttonTexture:ClearAllPoints()
    glow.buttonTexture:SetPoint("CENTER", glow.buttonFrame, "CENTER", xOffset, yOffset)
end

local PROC_GLOW_UPDATE_INTERVAL = 1 / 30 -- cap sparkle updates at ~30 FPS

local function onProcGlowUpdate(self, elapsed)
    local info = self.info
    local timers = self.timer
    local sparkles = self.sparkles

    -- Accumulate elapsed time and skip frames to reduce SetPoint overhead.
    info._elapsed = (info._elapsed or 0) + elapsed
    if info._elapsed < PROC_GLOW_UPDATE_INTERVAL then
        return
    end
    local dt = info._elapsed
    info._elapsed = 0

    local width = self:GetWidth() or 0
    local height = self:GetHeight() or 0
    if width ~= info.width or height ~= info.height then
        if width * height == 0 then
            return
        end
        info.width = width
        info.height = height
        info.perimeter = 2 * (width + height)
        info.bottomLim = height * 2 + width
        info.rightLim = height + width
        info.space = info.perimeter / info.N
    end

    local period = info.period
    local texIndex = 0
    for i = 1, 4 do
        timers[i] = (timers[i] + dt / (period * i)) % 1

        for k = 1, info.N do
            texIndex = texIndex + 1
            local texture = sparkles[texIndex]
            local position = (info.space * k + info.perimeter * timers[i]) % info.perimeter
            if position > info.bottomLim then
                texture:SetPoint("CENTER", self, "BOTTOMRIGHT", -position + info.bottomLim, 0)
            elseif position > info.rightLim then
                texture:SetPoint("CENTER", self, "TOPRIGHT", 0, -position + info.rightLim)
            elseif position > info.height then
                texture:SetPoint("CENTER", self, "TOPLEFT", position - info.height, 0)
            else
                texture:SetPoint("CENTER", self, "BOTTOMLEFT", 0, position)
            end
        end
    end
end

local function stopProcGlow(glow)
    glow.procFrame:SetScript("OnUpdate", nil)
    for i = 1, #glow.procFrame.sparkles do
        glow.procFrame.sparkles[i]:Hide()
    end
    glow.procFrame:Hide()
end

local function startProcGlow(glow, settings, r, g, b)
    local procFrame = glow.procFrame
    local info = procFrame.info
    local sparkles = procFrame.sparkles

    local groups = floor(settings.glowLines + 0.5)
    if groups < 1 then
        groups = 1
    elseif groups > MAX_PROC_LINES then
        groups = MAX_PROC_LINES
    end

    local frequency = settings.glowFrequency
    if frequency <= 0 then
        frequency = 1
    end

    info.N = groups
    info.period = 1 / frequency

    local scale = settings.glowScale * settings.glowThickness
    local maxSparkles = groups * 4

    for layer = 1, 4 do
        local size = PROC_LAYER_SIZES[layer] * scale
        local offset = (layer - 1) * groups
        for i = 1, groups do
            local index = offset + i
            local sparkle = sparkles[index]
            sparkle:SetWidth(size)
            sparkle:SetHeight(size)
            sparkle:SetVertexColor(r, g, b, 1)
            sparkle:Show()
        end
    end

    for i = maxSparkles + 1, #sparkles do
        sparkles[i]:Hide()
    end

    procFrame.timer[1], procFrame.timer[2], procFrame.timer[3], procFrame.timer[4] = 0, 0.125, 0.25, 0.375
    procFrame:Show()
    procFrame:SetScript("OnUpdate", onProcGlowUpdate)
    onProcGlowUpdate(procFrame, 0)
end

local function stopAllGlow(glow)
    glow.framePulse:Stop()
    glow.fillPulse:Stop()
    glow.ringPulse:Stop()
    glow.buttonPulse:Stop()

    stopProcGlow(glow)

    glow.frame:Hide()
    glow.ringFrame:Hide()
    glow.buttonFrame:Hide()
end

local function onTimedFadeUpdate(frame, elapsed)
    local fade = frame and frame._RMATimedFade
    if not fade then
        if frame and frame.SetScript then
            frame:SetScript("OnUpdate", nil)
        end
        return
    end

    fade.elapsed = (fade.elapsed or 0) + (tonumber(elapsed) or 0)
    if fade.elapsed >= fade.duration then
        frame._RMATimedFade = nil
        frame:SetScript("OnUpdate", nil)
        if fade.onDone then
            fade.onDone(frame)
        end
        return
    end

    if fade.elapsed <= fade.holdSeconds or fade.fadeSeconds <= 0 then
        frame:SetAlpha(1)
    else
        frame:SetAlpha(max(1 - ((fade.elapsed - fade.holdSeconds) / fade.fadeSeconds), 0))
    end
end

local function startBaseGlow(glow)
    glow.frame:Show()
    glow.framePulse:Play()
    glow.fillPulse:Play()
end

local function startRingGlow(glow)
    glow.ringFrame:Show()
    glow.ringPulse:Play()
end

local function startButtonGlow(glow)
    glow.buttonFrame:Show()
    glow.buttonPulse:Play()
end

local function ensureGlow(button)
    local glow = button._RMAGlow
    if glow then
        return glow
    end

    local glowFrame = CreateFrame("Frame", nil, button)
    glowFrame:SetPoint("TOPLEFT", button, "TOPLEFT", 0, 0)
    glowFrame:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", 0, 0)
    setFrameLayer(glowFrame, button, FRAME_LEVEL_OFFSETS.frame)
    glowFrame:Hide()

    local fill = glowFrame:CreateTexture(nil, "ARTWORK")
    fill:SetPoint("TOPLEFT", glowFrame, "TOPLEFT", 1, -1)
    fill:SetPoint("BOTTOMRIGHT", glowFrame, "BOTTOMRIGHT", -1, 1)
    fill:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
    fill:SetBlendMode("ADD")

    local ringFrame = CreateFrame("Frame", nil, button)
    setFrameLayer(ringFrame, button, FRAME_LEVEL_OFFSETS.ring)
    ringFrame:Hide()

    local ringTop = ringFrame:CreateTexture(nil, "OVERLAY")
    ringTop:SetTexture("Interface\\Buttons\\WHITE8x8")
    ringTop:SetBlendMode("ADD")

    local ringBottom = ringFrame:CreateTexture(nil, "OVERLAY")
    ringBottom:SetTexture("Interface\\Buttons\\WHITE8x8")
    ringBottom:SetBlendMode("ADD")

    local ringLeft = ringFrame:CreateTexture(nil, "OVERLAY")
    ringLeft:SetTexture("Interface\\Buttons\\WHITE8x8")
    ringLeft:SetBlendMode("ADD")

    local ringRight = ringFrame:CreateTexture(nil, "OVERLAY")
    ringRight:SetTexture("Interface\\Buttons\\WHITE8x8")
    ringRight:SetBlendMode("ADD")

    local procFrame = CreateFrame("Frame", nil, button)
    setFrameLayer(procFrame, button, FRAME_LEVEL_OFFSETS.proc)
    procFrame:Hide()
    procFrame.info = {
        width = 0,
        height = 0,
        perimeter = 0,
        bottomLim = 0,
        rightLim = 0,
        space = 0,
        N = 8,
        period = 1,
    }
    procFrame.timer = { 0, 0.125, 0.25, 0.375 }
    procFrame.sparkles = {}

    for i = 1, MAX_PROC_LINES * 4 do
        local sparkle = procFrame:CreateTexture(nil, "OVERLAY")
        sparkle:SetTexture("Interface\\ItemSocketingFrame\\UI-ItemSockets")
        sparkle:SetTexCoord(0.3984375, 0.4453125, 0.40234375, 0.44921875)
        sparkle:SetBlendMode("ADD")
        sparkle:Hide()
        procFrame.sparkles[i] = sparkle
    end

    local buttonFrame = CreateFrame("Frame", nil, button)
    buttonFrame:SetPoint("TOPLEFT", button, "TOPLEFT", 0, 0)
    buttonFrame:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", 0, 0)
    setFrameLayer(buttonFrame, button, FRAME_LEVEL_OFFSETS.button)
    buttonFrame:Hide()

    local buttonTexture = buttonFrame:CreateTexture(nil, "OVERLAY")
    buttonTexture:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
    buttonTexture:SetBlendMode("ADD")

    local framePulse = glowFrame:CreateAnimationGroup()
    framePulse:SetLooping("REPEAT")
    local frameIn = framePulse:CreateAnimation("Alpha")
    frameIn:SetOrder(1)
    local frameOut = framePulse:CreateAnimation("Alpha")
    frameOut:SetOrder(2)

    local fillPulse = fill:CreateAnimationGroup()
    fillPulse:SetLooping("REPEAT")
    local fillIn = fillPulse:CreateAnimation("Alpha")
    fillIn:SetOrder(1)
    local fillOut = fillPulse:CreateAnimation("Alpha")
    fillOut:SetOrder(2)

    local ringPulse = ringFrame:CreateAnimationGroup()
    ringPulse:SetLooping("REPEAT")
    local ringIn = ringPulse:CreateAnimation("Alpha")
    ringIn:SetOrder(1)
    local ringOut = ringPulse:CreateAnimation("Alpha")
    ringOut:SetOrder(2)

    local buttonPulse = buttonTexture:CreateAnimationGroup()
    buttonPulse:SetLooping("REPEAT")
    local buttonIn = buttonPulse:CreateAnimation("Alpha")
    buttonIn:SetOrder(1)
    local buttonOut = buttonPulse:CreateAnimation("Alpha")
    buttonOut:SetOrder(2)

    glow = {
        frame = glowFrame,
        fill = fill,
        ringFrame = ringFrame,
        ringEdges = {
            top = ringTop,
            bottom = ringBottom,
            left = ringLeft,
            right = ringRight,
        },
        procFrame = procFrame,
        buttonFrame = buttonFrame,
        buttonTexture = buttonTexture,
        framePulse = framePulse,
        fillPulse = fillPulse,
        ringPulse = ringPulse,
        buttonPulse = buttonPulse,
        anim = {
            frameIn = frameIn,
            frameOut = frameOut,
            fillIn = fillIn,
            fillOut = fillOut,
            ringIn = ringIn,
            ringOut = ringOut,
            buttonIn = buttonIn,
            buttonOut = buttonOut,
        },
        methodKey = DEFAULT_GLOW_METHOD,
        settings = buildMethodDefaults(DEFAULT_GLOW_METHOD),
        lastColor = { 1, 0.82, 0 },
    }

    button._RMAGlow = glow

    button:HookScript("OnSizeChanged", function(self)
        local currentGlow = self._RMAGlow
        local methodCfg = METHOD_VISUALS[currentGlow.methodKey]
        currentGlow.settings = applyDynamicSettings(self, methodCfg, currentGlow.settings)
        updateGlowGeometry(currentGlow, self, currentGlow.settings)
        if methodCfg.flags.proc and currentGlow.procFrame:IsShown() then
            local c = currentGlow.lastColor
            startProcGlow(currentGlow, currentGlow.settings, c[1], c[2], c[3])
        end
    end)

    updateGlowGeometry(glow, button, glow.settings)
    return glow
end

function Effects.SetButtonGlow(button, enabled, r, g, b, methodName, options)
    local glow = ensureGlow(button)

    if not enabled then
        stopAllGlow(glow)
        return
    end

    local methodKey, methodCfg, settings = resolveMethod(methodName, options)
    settings = applyDynamicSettings(button, methodCfg, settings)
    glow.methodKey = methodKey
    glow.settings = settings

    setFrameLayer(glow.frame, button, FRAME_LEVEL_OFFSETS.frame)
    setFrameLayer(glow.ringFrame, button, FRAME_LEVEL_OFFSETS.ring)
    setFrameLayer(glow.procFrame, button, FRAME_LEVEL_OFFSETS.proc)
    setFrameLayer(glow.buttonFrame, button, FRAME_LEVEL_OFFSETS.button)

    updateGlowGeometry(glow, button, settings)
    applyPulseConfig(glow, methodCfg, settings)

    local color = settings.useGlowColor and settings.glowColor or { r or 1, g or 0.82, b or 0 }
    glow.lastColor = { color[1], color[2], color[3] }
    applyGlowColor(glow, color[1], color[2], color[3])

    stopAllGlow(glow)

    if methodCfg.flags.proc then
        startProcGlow(glow, settings, color[1], color[2], color[3])
        return
    end

    if methodCfg.flags.button then
        startButtonGlow(glow)
        return
    end

    if methodCfg.flags.ring then
        startRingGlow(glow)
    end

    if methodCfg.flags.base then
        startBaseGlow(glow)
    end
end

function Effects.SetTimedFade(frame, duration, fadeSeconds, onDone)
    if not (frame and frame.SetScript and frame.SetAlpha) then
        return false
    end

    local holdSeconds = max(tonumber(duration) or 1, 0.1)
    local resolvedFadeSeconds = min(max(tonumber(fadeSeconds) or 0, 0), 5)

    frame._RMATimedFade = {
        elapsed = 0,
        duration = holdSeconds + resolvedFadeSeconds,
        holdSeconds = holdSeconds,
        fadeSeconds = resolvedFadeSeconds,
        onDone = type(onDone) == "function" and onDone or nil,
    }
    frame:SetAlpha(1)
    frame:SetScript("OnUpdate", onTimedFadeUpdate)
    return true
end

local registry = feature.ModuleRegistry
if type(registry) == "table" and type(registry.AddModule) == "function" and type(registry.SetLoaded) == "function" then
    registry.AddModule("Modules/UI/Effects", { deps = { "Init", "Modules/ModuleRegistry" } })
    registry.SetLoaded("Modules/UI/Effects")
end

