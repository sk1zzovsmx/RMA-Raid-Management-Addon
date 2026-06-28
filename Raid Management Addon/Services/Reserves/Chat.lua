-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: local feature = addon.Database.GetFeatureShared()
-- exports: addon.Services.Reserves._Chat
-- events: listens to wow.CHAT_MSG_WHISPER and replies with opt-in SoftRes summaries

local addon = select(2, ...)
local feature = addon.Database.GetFeatureShared()

local L = feature.L
local Bus = feature.Bus
local Comms = feature.Comms
local Events = feature.Events
local Options = feature.Options
local Services = feature.Services
local Strings = feature.Strings

local format = string.format
local len = string.len
local lower = string.lower
local strsub = string.sub
local tostring = tostring
local tonumber = tonumber
local type = type

-- ----- Internal state ----- --
feature.EnsureServiceNamespace("Reserves")
local Reserves = Services.Reserves
local module = Reserves
module._Chat = module._Chat or {}

local MAX_WHISPER_LEN = 255
local REQUEST_COMMANDS = {
    "+softres",
    "+sr",
}
local REQUESTS = {
    ["+sr"] = true,
    ["+softres"] = true,
}
local WHISPER_THROTTLE_SECONDS = 1

-- ----- Private helpers ----- --
local trimText = Strings.TrimText
local whisperQueue = {}
local whisperQueueHead = 1
local whisperQueueTail = 0
local whisperThrottleHandle = nil
local processWhisperQueue

local function hasQueuedWhispers()
    return whisperQueueHead <= whisperQueueTail
end

local function pushQueuedWhisper(target, text)
    whisperQueueTail = whisperQueueTail + 1
    whisperQueue[whisperQueueTail] = {
        target = target,
        text = text,
    }
end

local function popQueuedWhisper()
    if not hasQueuedWhispers() then
        return nil
    end

    local item = whisperQueue[whisperQueueHead]
    whisperQueue[whisperQueueHead] = nil
    whisperQueueHead = whisperQueueHead + 1
    if whisperQueueHead > whisperQueueTail then
        whisperQueueHead = 1
        whisperQueueTail = 0
    end
    return item
end

local function sendWhisperNow(target, text)
    if not (Comms and Comms.SendWhisper) then
        return false
    end
    return Comms.SendWhisper(target, text)
end

local function scheduleWhisperThrottle()
    if whisperThrottleHandle ~= nil then
        return
    end
    if not (module.ScheduleTimer and processWhisperQueue) then
        return
    end

    whisperThrottleHandle = module:ScheduleTimer(processWhisperQueue, WHISPER_THROTTLE_SECONDS)
end

local function parseRequest(text)
    local raw = trimText(text or "")
    if raw == "" then
        return nil
    end

    local normalized = lower(raw)
    if REQUESTS[normalized] == true then
        return normalized, nil
    end

    for i = 1, #REQUEST_COMMANDS do
        local command = REQUEST_COMMANDS[i]
        local commandLen = len(command)
        if strsub(normalized, 1, commandLen + 1) == command .. " " then
            return command, trimText(strsub(raw, commandLen + 2))
        end
    end

    return nil
end

local function canReplyFromCurrentClient()
    local raid = Services and Services.Raid or nil
    if not (raid and raid.GetPlayerRoleState and raid.CanUseCapability) then
        return false
    end

    local role = raid:GetPlayerRoleState()
    if not (role and role.inRaid) then
        return false
    end

    return role.isMasterLooter == true or raid:CanUseCapability("loot") or raid:CanUseCapability("raid_leadership")
end

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

local function buildFallbackItemText(entry)
    local itemName = entry.itemName
    if type(itemName) == "string" and itemName ~= "" then
        return itemName
    end

    local itemId = entry.rawID or entry.itemId
    return format(L.StrReservesItemFallback or "[Item %s]", tostring(itemId or "?"))
end

local function buildItemText(entry)
    local itemText = entry.itemLink
    if type(itemText) ~= "string" or itemText == "" then
        itemText = buildFallbackItemText(entry)
    end

    local suffix = ""
    local quantity = tonumber(entry.quantity) or 1
    local plus = module.IsPlusSystem and module:IsPlusSystem() and (tonumber(entry.plus) or 0) or 0
    if quantity > 1 then
        suffix = suffix .. " x" .. tostring(quantity)
    end
    if plus > 0 then
        suffix = suffix .. " (P+" .. tostring(plus) .. ")"
    end

    local text = itemText .. suffix
    if len(text) <= MAX_WHISPER_LEN - 16 then
        return text
    end
    return buildFallbackItemText(entry) .. suffix
end

processWhisperQueue = function()
    whisperThrottleHandle = nil
    local item = popQueuedWhisper()
    if not item then
        return
    end

    sendWhisperNow(item.target, item.text)
    scheduleWhisperThrottle()
end

local function sendWhisper(target, text)
    if not (Comms and Comms.SendWhisper) then
        return false
    end
    if whisperThrottleHandle ~= nil then
        pushQueuedWhisper(target, text)
        return true
    end

    local ok = sendWhisperNow(target, text)
    scheduleWhisperThrottle()
    return ok
end

local function sendReserveMessages(target, entries)
    sendWhisper(target, L.WhisperSoftResHeader)
    for i = 1, #entries do
        local line = format(L.WhisperSoftResEntry, i, buildItemText(entries[i]))
        if len(line) > MAX_WHISPER_LEN then
            line = format(L.WhisperSoftResEntry, i, buildFallbackItemText(entries[i]))
        end
        sendWhisper(target, line)
    end
end

local function buildReserveAddedMessage(entry)
    local itemText = buildItemText(entry)
    local text = format(L.WhisperSoftResAdded, itemText)
    if len(text) <= MAX_WHISPER_LEN then
        return text
    end
    return format(L.WhisperSoftResAdded, buildFallbackItemText(entry))
end

local requestWhisperReply

local function registerWhisperHandler()
    local eventName = Events and Events.Wow and Events.Wow.ChatMsgWhisper
    if not (eventName and Bus and Bus.RegisterCallback) then
        return
    end

    Bus.RegisterCallback(eventName, function(_, msg, sender)
        requestWhisperReply(msg, sender)
    end)
end

requestWhisperReply = function(msg, sender)
    local command, itemRef = parseRequest(msg)
    if not command then
        return false
    end

    local target = trimText(sender or "")
    if target == "" then
        return true
    end

    local hasItemRef = itemRef and itemRef ~= ""
    if hasItemRef then
        if GetOption("Reserves", "softResWhisperAdds") ~= true then
            return true
        end
    elseif GetOption("Reserves", "softResWhisperReplies") ~= true then
        return true
    end

    if not canReplyFromCurrentClient() then
        return true
    end

    if hasItemRef then
        local ok, reserveEntry
        if module.AddPlayerReserve then
            ok, reserveEntry = module:AddPlayerReserve(target, itemRef)
        end
        if ok and reserveEntry then
            sendWhisper(target, buildReserveAddedMessage(reserveEntry))
        else
            sendWhisper(target, L.WhisperSoftResInvalidItem)
        end
        return true
    end

    local entries = module.GetPlayerReserveEntries and module:GetPlayerReserveEntries(target) or {}
    if #entries <= 0 then
        sendWhisper(target, format(L.WhisperSoftResNone, target))
        return true
    end

    sendReserveMessages(target, entries)
    return true
end

-- ----- Public methods ----- --
-- This service exposes no direct helpers; whisper handling is event-driven.

registerWhisperHandler()

local registry = feature.ModuleRegistry
if type(registry) == "table" and type(registry.AddModule) == "function" and type(registry.SetLoaded) == "function" then
    registry.AddModule("Services/Reserves/Chat", {
        deps = {
            "Init",
            "Modules/ModuleRegistry",
            "Modules/Strings",
            "Modules/Comms",
            "Modules/Events",
            "Modules/Bus",
        },
    })
    registry.SetLoaded("Services/Reserves/Chat")
end

