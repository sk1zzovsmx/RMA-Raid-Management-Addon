-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: local feature = addon.Database.GetFeatureShared()
-- exports: publish module APIs on addon.*
-- events: none

local addon = select(2, ...)
local feature = addon.Database.GetFeatureShared()

local type = type

local GetClassColor = feature.GetClassColor
local Colors = feature.Colors or {}
addon.Colors = Colors

-- ----- Internal state ----- --

-- ----- Private helpers ----- --

-- ----- Public methods ----- --

function Colors.NormalizeHexColor(color)
    if type(color) == "string" then
        local hex = color:gsub("^|c", ""):gsub("|r$", ""):gsub("^#", "")
        if #hex == 6 then
            hex = "ff" .. hex
        end
        return hex
    end

    if type(color) == "table" and color.GenerateHexColor then
        local hex = color:GenerateHexColor():gsub("^#", "")
        if #hex == 6 then
            hex = "ff" .. hex
        end
        return hex
    end

    return "ffffffff"
end

function Colors.GetClassColor(className)
    local r, g, b = GetClassColor(className)
    return (r or 1), (g or 1), (b or 1)
end

do
    local name = "Modules/Colors"
    local deps = { "Init" }
    local registry = feature.ModuleRegistry
    if registry then
        registry.AddModule(name, { deps = deps })
        registry.SetLoaded(name)
    else
        addon.ModuleRegistryPendingRegistrations = addon.ModuleRegistryPendingRegistrations or {}
        local pending = addon.ModuleRegistryPendingRegistrations
        pending[#pending + 1] = { name = name, deps = deps, loaded = true }
    end
end

