-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: local feature = addon.Database.GetFeatureShared()
-- exports: addon.Services.Master.AssignmentHelpers
-- events: none
-- notes: pure Master assignment shared helpers
local addon = select(2, ...)
local feature = addon.Database.GetFeatureShared()

local Services = feature.Services
local Master = Services.Master or {}
Services.Master = Master
addon.Services.Master = Master

local AssignmentHelpers = Master.AssignmentHelpers or {}
Master.AssignmentHelpers = AssignmentHelpers

local type = type

-- ----- Internal state ----- --

-- ----- Private helpers ----- --

-- ----- Public methods ----- --

function AssignmentHelpers.ResolveClass(classProvider, name)
    if type(classProvider) == "function" then
        return classProvider(name)
    end
    return nil
end

local registry = feature.ModuleRegistry
if type(registry) == "table" and type(registry.AddModule) == "function" and type(registry.SetLoaded) == "function" then
    registry.AddModule("Services/Master/AssignmentHelpers", {
        deps = {
            "Init",
            "Modules/ModuleRegistry",
        },
    })
    registry.SetLoaded("Services/Master/AssignmentHelpers")
end

