-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: local feature = addon.Database.GetFeatureShared()
-- exports: publish module APIs on addon.*
-- events: none

local addon = select(2, ...)
local feature = addon.Database.GetFeatureShared()

local find, gsub = string.find, string.gsub
local strsub = string.sub
local char, byte = string.char, string.byte

-- ----- Internal state ----- --
local BASE64_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local Base64 = feature.Base64 or {}
addon.Base64 = Base64

-- ----- Private helpers ----- --

-- ----- Public methods ----- --

function Base64.Encode(data)
    return (
        (gsub(data, ".", function(x)
            local out, bits = "", byte(x)
            for i = 8, 1, -1 do
                out = out .. (bits % 2 ^ i - bits % 2 ^ (i - 1) > 0 and "1" or "0")
            end
            return out
        end) .. "0000"):gsub("%d%d%d?%d?%d?%d?", function(x)
            if #x < 6 then
                return ""
            end
            local c = 0
            for i = 1, 6 do
                c = c + (strsub(x, i, i) == "1" and 2 ^ (6 - i) or 0)
            end
            return strsub(BASE64_ALPHABET, c + 1, c + 1)
        end) .. ({ "", "==", "=" })[#data % 3 + 1]
    )
end

function Base64.Decode(data)
    data = gsub(data, "[^" .. BASE64_ALPHABET .. "=]", "")
    return (
        gsub(data, ".", function(x)
            if x == "=" then
                return ""
            end
            local out, f = "", (find(BASE64_ALPHABET, x) - 1)
            for i = 6, 1, -1 do
                out = out .. (f % 2 ^ i - f % 2 ^ (i - 1) > 0 and "1" or "0")
            end
            return out
        end):gsub("%d%d%d?%d?%d?%d?%d?%d?", function(x)
            if #x ~= 8 then
                return ""
            end
            local c = 0
            for i = 1, 8 do
                c = c + (strsub(x, i, i) == "1" and 2 ^ (8 - i) or 0)
            end
            return char(c)
        end)
    )
end

do
    local name = "Modules/Base64"
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

