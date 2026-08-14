-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: direct addon namespace bindings
-- exports: addon.Services.Reserves._Chat
-- events: listens to wow.CHAT_MSG_WHISPER and replies with opt-in SoftRes summaries

local addon = select(2, ...)
local L = addon.L
local Bus = addon.Bus
local Comms = addon.Comms
local Database = addon.Database
local Events = addon.Events
local Options = addon.Options
local Services = addon.Services
local Strings = addon.Strings
local Time = addon.Time

local format = string.format
local len = string.len
local lower = string.lower
local strsub = string.sub
local tostring = tostring
local tonumber = tonumber
local type = type

-- ----- Internal state ----- --
addon.Services.EnsureNamespace("Reserves")
local Reserves = Services.Reserves
local module = Reserves
module._Chat = module._Chat or {}

local Raid = assert(Services.Raid, "Reserves chat raid service is not initialized")
local GetPlayerRoleState = assert(Raid.GetPlayerRoleState, "Reserves chat raid-role resolver is not initialized")
local CanUseCapability = assert(Raid.CanUseCapability, "Reserves chat raid capability resolver is not initialized")
local SendWhisper = assert(Comms.SendWhisper, "Reserves chat whisper transport is not initialized")
local RegisterCallback = assert(Bus.RegisterCallback, "Reserves chat event bus listener is not initialized")
local WhisperEvent =
	assert(Events.Wow and Events.Wow.ChatMsgWhisper, "Reserves chat whisper event name is not initialized")
local ScheduleTimer = assert(module.ScheduleTimer, "Reserves chat throttle scheduler is not initialized")
local IsPlusSystem = assert(module.IsPlusSystem, "Reserves chat import-mode resolver is not initialized")
local AddPlayerReserve = assert(module.AddPlayerReserve, "Reserves chat add-reserve handler is not initialized")
local GetPlayerReserveEntries =
	assert(module.GetPlayerReserveEntries, "Reserves chat player-reserve lookup is not initialized")
local ResolveWhisperPlayerName =
	assert(module.ResolveWhisperPlayerName, "Reserves chat player identity resolver is not initialized")
local NormalizeWhisperPlayerIdentity =
	assert(module.NormalizeWhisperPlayerIdentity, "Reserves chat identity normalizer is not initialized")
local GetCounts = assert(module.GetCounts, "Reserves chat reserve-count lookup is not initialized")
local GetCurrentTime = assert(Time and Time.GetCurrentTime, "Reserves chat clock is not initialized")
local GetRealmName = assert(Database and Database.GetRealmName, "Reserves chat realm resolver is not initialized")

local MAX_WHISPER_LEN = 255
local MAX_PLAYERS = 1000
local MAX_TOTAL_RESERVES = 5000
local MAX_RESERVES_PER_PLAYER = 20
local MAX_ADMISSION_SENDERS = 1000
local MAX_REQUESTS_PER_WINDOW = 5
local ADMISSION_WINDOW_SECONDS = 10
local MAX_QUEUED_WHISPERS = 100
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
local admissionBySender = {}
local admissionSenderCount = 0
local processWhisperQueue

local function hasQueuedWhispers()
	return whisperQueueHead <= whisperQueueTail
end

local function pushQueuedWhisper(target, text)
	if whisperQueueTail - whisperQueueHead + 1 >= MAX_QUEUED_WHISPERS then
		return false
	end
	whisperQueueTail = whisperQueueTail + 1
	whisperQueue[whisperQueueTail] = {
		target = target,
		text = text,
	}
	return true
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
	return SendWhisper(target, text)
end

local function scheduleWhisperThrottle()
	if whisperThrottleHandle ~= nil then
		return
	end

	whisperThrottleHandle = ScheduleTimer(module, processWhisperQueue, WHISPER_THROTTLE_SECONDS)
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
	local role = GetPlayerRoleState(Raid)
	if not (role and role.inRaid) then
		return false
	end

	return role.isMasterLooter == true or CanUseCapability(Raid, "loot") or CanUseCapability(Raid, "raid_leadership")
end

local GetOption = Options.GetValue

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
	local plus = IsPlusSystem(module) and (tonumber(entry.plus) or 0) or 0
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
	if whisperThrottleHandle ~= nil then
		return pushQueuedWhisper(target, text)
	end

	local ok = sendWhisperNow(target, text)
	scheduleWhisperThrottle()
	return ok
end

local function pruneAdmission(now)
	for key, state in pairs(admissionBySender) do
		if now - state.startedAt >= ADMISSION_WINDOW_SECONDS then
			admissionBySender[key] = nil
			admissionSenderCount = admissionSenderCount - 1
		end
	end
end

local function admitSender(target)
	local now = tonumber(GetCurrentTime(false)) or 0
	local senderKey = Strings.NormalizeLower(target, true)
	if not senderKey or senderKey == "" then
		return false, false
	end
	local state = admissionBySender[senderKey]
	if state and now - state.startedAt >= ADMISSION_WINDOW_SECONDS then
		admissionBySender[senderKey] = nil
		admissionSenderCount = admissionSenderCount - 1
		state = nil
	end
	if not state and admissionSenderCount >= MAX_ADMISSION_SENDERS then
		pruneAdmission(now)
	end
	if not state and admissionSenderCount >= MAX_ADMISSION_SENDERS then
		return false, false
	end
	if not state then
		state = { startedAt = now, count = 0, denied = false }
		admissionBySender[senderKey] = state
		admissionSenderCount = admissionSenderCount + 1
	end
	if state.count >= MAX_REQUESTS_PER_WINDOW then
		if state.denied then
			return false, false
		end
		state.denied = true
		return false, true
	end
	state.count = state.count + 1
	return true, false
end

local function hasMutationCapacity(target)
	local entries = GetPlayerReserveEntries(module, target)
	if #entries >= MAX_RESERVES_PER_PLAYER then
		return false
	end
	local players, totalEntries = GetCounts(module)
	if totalEntries >= MAX_TOTAL_RESERVES then
		return false
	end
	if #entries == 0 and players >= MAX_PLAYERS then
		return false
	end
	return true
end

local function sendReserveMessages(target, entries)
	sendWhisper(target, L.WhisperSoftResHeader)
	local count = #entries
	if count > MAX_RESERVES_PER_PLAYER then count = MAX_RESERVES_PER_PLAYER end
	for i = 1, count do
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
	RegisterCallback(WhisperEvent, function(_, msg, sender)
		requestWhisperReply(msg, sender)
	end)
end

requestWhisperReply = function(msg, sender)
	local command, itemRef = parseRequest(msg)
	if not command then
		return false
	end

	local target = sender
	if type(target) ~= "string" or target == "" then
		return true
	end
	local characterName, senderRealmKey, canonicalSender, localRealmKey =
		NormalizeWhisperPlayerIdentity(module, target, GetRealmName())
	if not canonicalSender then return true end
	local storagePlayerName = ResolveWhisperPlayerName(module, characterName, senderRealmKey, localRealmKey)
	if not storagePlayerName then return true end

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

	local admitted, notifyLimited = admitSender(canonicalSender)
	if not admitted then
		if notifyLimited then sendWhisper(target, L.WhisperSoftResAdmissionLimited) end
		return true
	end

	if hasItemRef then
		if not hasMutationCapacity(storagePlayerName) then
			sendWhisper(target, L.WhisperSoftResCapacity)
			return true
		end
		local ok, reserveEntry = AddPlayerReserve(module, storagePlayerName, itemRef)
		if ok and reserveEntry then
			sendWhisper(target, buildReserveAddedMessage(reserveEntry))
		elseif reserveEntry == "invalid_item" then
			sendWhisper(target, L.WhisperSoftResInvalidItem)
		end
		return true
	end

	local entries = GetPlayerReserveEntries(module, storagePlayerName)
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
