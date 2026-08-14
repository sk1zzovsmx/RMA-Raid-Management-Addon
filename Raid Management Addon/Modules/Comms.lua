-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: direct addon namespace bindings
-- exports: publish module APIs on addon.*
-- events: owns addon-message send helpers and RMAVersion payload handling

local addonName = ...
local addon = select(2, ...)
local type, tostring, tonumber = type, tostring, tonumber
local pcall = pcall
local select = select
local strfind, strmatch, strsub = string.find, string.match, string.sub
local strbyte = string.byte
local tconcat = table.concat
local floor = math.floor
local _G = _G
local SendAddonMessage = assert(_G.SendAddonMessage, "Comms addon-message send API is not initialized")
local SendChatMessage = assert(_G.SendChatMessage, "Comms chat send API is not initialized")
local GetAddOnMetadata = assert(_G.GetAddOnMetadata, "Comms addon metadata API is not initialized")
local UnitName = assert(_G.UnitName, "Comms unit name API is not initialized")
local IsInInstance = assert(_G.IsInInstance, "Comms instance state API is not initialized")
local GetNumRaidMembers = assert(_G.GetNumRaidMembers, "Comms raid member count API is not initialized")
local GetNumPartyMembers = assert(_G.GetNumPartyMembers, "Comms party member count API is not initialized")
local GetChannelList = _G.GetChannelList
local IsInGuild = _G.IsInGuild
local GetGuildInfo = _G.GetGuildInfo
local GuildControlGetRankFlags = _G.GuildControlGetRankFlags

local Comms = addon.Comms or {}
addon.Comms = Comms
Comms.Payload = Comms.Payload or {}
local Payload = Comms.Payload
local L = addon.L
local Database = addon.Database
local Strings = addon.Strings
local NormalizeName = assert(Strings.NormalizeName, "Comms sender name normalizer is not initialized")
local Timer = addon.Timer
local BindTimerMixin = assert(Timer.BindMixin, "Comms timer mixin is not initialized")

Comms._addonQueue = Comms._addonQueue or {}
Comms._addonQueueHead = tonumber(Comms._addonQueueHead) or 1
Comms._addonQueueTail = tonumber(Comms._addonQueueTail) or #Comms._addonQueue
Comms._addonQueueTimer = Comms._addonQueueTimer

local COMMS_ADDON_QUEUE_BURST = 1
local COMMS_ADDON_QUEUE_MAX = 256
local COMMS_ADDON_QUEUE_DELAY_SECONDS = 0.10
local packFieldsBuffer = {}

BindTimerMixin(Comms, "Modules/Comms")
local ScheduleTimer = assert(Comms.ScheduleTimer, "Comms addon-message queue scheduler is not initialized")

-- ----- Internal state ----- --

local VERSION_PREFIX = "RMAVersion"
local MSG_VERSION_REQ = "REQ"
local MSG_VERSION_ACK = "ACK"

-- ----- Private helpers ----- --

local function getUnknownText()
	return tostring((L and L.StrUnknown) or "unknown")
end

local function getBase64()
	return addon.Base64 or addon.Base64
end

local function encodeCommsPayloadText(value)
	local base64 = getBase64()
	local encode = base64 and base64.Encode
	if type(encode) ~= "function" then
		return ""
	end

	local ok, out = pcall(encode, tostring(value or ""))
	if ok and out then
		return out
	end
	return ""
end

local function decodeCommsPayloadText(value)
	local input = tostring(value or "")
	if input == "" then
		return ""
	end

	local base64 = getBase64()
	local decode = base64 and base64.Decode
	if type(decode) ~= "function" then
		return nil
	end

	local ok, out = pcall(decode, input)
	if ok and out then
		return out
	end
	return nil
end

local function splitCommsPayloadFields(text, sep, out)
	local fields = out or {}
	local delimiter = tostring(sep or "|")
	local input = tostring(text or "")
	local n = 0

	if delimiter == "" then
		fields[1] = input
		for i = 2, #fields do
			fields[i] = nil
		end
		return fields, 1
	end

	local startPos = 1
	while true do
		local fromPos, toPos = strfind(input, delimiter, startPos, true)
		if not fromPos then
			n = n + 1
			fields[n] = strsub(input, startPos)
			break
		end
		n = n + 1
		fields[n] = strsub(input, startPos, fromPos - 1)
		startPos = toPos + 1
	end

	for i = n + 1, #fields do
		fields[i] = nil
	end

	return fields, n
end

local function packCommsPayloadFields(sep, ...)
	local delimiter = tostring(sep or "|")
	local n = select("#", ...)
	for i = 1, n do
		packFieldsBuffer[i] = tostring(select(i, ...) or "")
	end
	local result = tconcat(packFieldsBuffer, delimiter, 1, n)
	for i = 1, n do
		packFieldsBuffer[i] = nil
	end
	return result
end

function Comms.RegisterPrefixIfAvailable(prefix)
	if type(prefix) ~= "string" or prefix == "" then
		return false
	end
	if type(_G.RegisterAddonMessagePrefix) ~= "function" then
		return false
	end
	_G.RegisterAddonMessagePrefix(prefix)
	return true
end

local function splitVersionPayload(msg)
	local fields = splitCommsPayloadFields(msg, "|")
	return fields[1], fields[2], fields[3], fields[4], fields[5]
end

local function getAddonMetadata(key, fallback)
	local value = GetAddOnMetadata(addonName, key)
	if value ~= nil and value ~= "" then
		return tostring(value)
	end
	return tostring(fallback or getUnknownText())
end

local function getRaidSchemaVersion()
	local getter = Database.GetRaidSchemaVersion
	if type(getter) == "function" then
		return tostring(getter() or getUnknownText())
	end
	return getUnknownText()
end

local function getSyncProtocolVersion()
	local syncer = Database.GetSyncer()
	if syncer and type(syncer.GetProtocolVersion) == "function" then
		return tostring(syncer:GetProtocolVersion() or getUnknownText())
	end
	return getUnknownText()
end

local function buildVersionPayload(kind)
	local info = Comms.GetVersionInfo()
	return tconcat({
		kind,
		info.addonVersion,
		info.interfaceVersion,
		info.raidSchemaVersion,
		info.syncProtocolVersion,
	}, "|")
end

local function getGroupTransport()
	local zone = select(2, IsInInstance())
	local raidCount = tonumber(GetNumRaidMembers()) or 0
	local partyCount = tonumber(GetNumPartyMembers()) or 0

	if zone == "pvp" or zone == "arena" then
		return "BATTLEGROUND"
	end
	if raidCount > 0 then
		return "RAID"
	end
	if partyCount > 0 then
		return "PARTY"
	end
	return nil
end

local function getPlayerName()
	local name = UnitName("player")
	return tostring(name or "")
end

local function sendAddonMessageNow(prefix, msg, channel, target)
	local ok
	if type(target) == "string" and target ~= "" then
		ok = pcall(SendAddonMessage, prefix, tostring(msg), channel, target)
	else
		ok = pcall(SendAddonMessage, prefix, tostring(msg), channel)
	end
	return ok == true
end

local function scheduleAddonQueueFlush()
	if Comms._addonQueueTimer then
		return true
	end

	Comms._addonQueueTimer = ScheduleTimer(Comms, function()
		Comms._addonQueueTimer = nil
		Comms:FlushAddonQueue(COMMS_ADDON_QUEUE_BURST)
	end, COMMS_ADDON_QUEUE_DELAY_SECONDS)
	return Comms._addonQueueTimer ~= nil
end

local function flushAddonQueue(limit)
	local queue = Comms._addonQueue
	local head = tonumber(Comms._addonQueueHead) or 1
	if type(queue) ~= "table" or queue[head] == nil then
		Comms._addonQueue = {}
		Comms._addonQueueHead = 1
		Comms._addonQueueTail = 0
		return 0
	end

	local burst = tonumber(limit) or COMMS_ADDON_QUEUE_BURST
	if burst <= 0 then
		burst = COMMS_ADDON_QUEUE_BURST
	end

	local sent = 0
	for i = 1, burst do
		local entry = queue[head]
		if not entry then
			break
		end

		queue[head] = nil
		head = head + 1
		if sendAddonMessageNow(entry.prefix, entry.msg, entry.channel, entry.target) then
			sent = sent + 1
		end
	end
	Comms._addonQueueHead = head
	if queue[head] ~= nil then
		scheduleAddonQueueFlush()
	else
		Comms._addonQueue = {}
		Comms._addonQueueHead = 1
		Comms._addonQueueTail = 0
	end
	return sent
end

function Comms.QueueAddonMessage(prefix, msg, channel, target, opts)
	if type(prefix) ~= "string" or prefix == "" or type(channel) ~= "string" or channel == "" or msg == nil then
		return false
	end

	if not (opts and opts.immediate == true) then
		local queue = Comms._addonQueue
		local head = tonumber(Comms._addonQueueHead) or 1
		local tail = tonumber(Comms._addonQueueTail) or 0
		if tail - head + 1 >= COMMS_ADDON_QUEUE_MAX then
			return false, "backpressure"
		end
		queue[tail + 1] = {
			prefix = prefix,
			msg = tostring(msg),
			channel = channel,
			target = (type(target) == "string" and target ~= "" and target) or nil,
		}
		Comms._addonQueueTail = tail + 1
		if scheduleAddonQueueFlush() then
			return true
		end

		return flushAddonQueue(COMMS_ADDON_QUEUE_MAX) > 0
	end

	return sendAddonMessageNow(prefix, msg, channel, target)
end

function Comms.QueueAddonMessages(prefix, messages, channel, target)
	if type(prefix) ~= "string" or prefix == "" or type(channel) ~= "string" or channel == "" or type(messages) ~= "table" then
		return false, "invalid"
	end
	local count = #messages
	if count < 1 then return true end
	local queue = Comms._addonQueue
	local head = tonumber(Comms._addonQueueHead) or 1
	local tail = tonumber(Comms._addonQueueTail) or 0
	if tail - head + 1 + count > COMMS_ADDON_QUEUE_MAX then
		return false, "backpressure"
	end
	for i = 1, count do
		if messages[i] == nil then return false, "invalid" end
	end
	for i = 1, count do
		queue[tail + i] = {
			prefix = prefix,
			msg = tostring(messages[i]),
			channel = channel,
			target = (type(target) == "string" and target ~= "" and target) or nil,
		}
	end
	Comms._addonQueueTail = tail + count
	if scheduleAddonQueueFlush() then return true end
	for i = 1, count do queue[tail + i] = nil end
	Comms._addonQueueTail = tail
	return false, "scheduler_unavailable"
end

function Comms.SendAddonBatch(prefix, messages, target)
	if type(target) == "string" and target ~= "" then
		return Comms.QueueAddonMessages(prefix, messages, "WHISPER", target)
	end
	local channel = getGroupTransport()
	if not channel then return false, "not_in_group" end
	return Comms.QueueAddonMessages(prefix, messages, channel)
end

function Comms.FlushAddonQueue(limit)
	return flushAddonQueue(limit)
end

local function sendGroupMessage(prefix, msg)
	local channel = getGroupTransport()
	if channel then
		local sent = Comms.QueueAddonMessage(prefix, msg, channel)
		if sent then
			return true, channel
		end
		return false
	end
	return false
end

-- ----- Public methods ----- --

function Payload.EncodeText(value)
	return encodeCommsPayloadText(value)
end

function Payload.DecodeText(value)
	return decodeCommsPayloadText(value)
end

function Payload.SplitFields(text, sep, out)
	return splitCommsPayloadFields(text, sep, out)
end

function Payload.PackFields(sep, ...)
	return packCommsPayloadFields(sep, ...)
end

function Comms.Sync(prefix, msg)
	return sendGroupMessage(prefix, msg)
end

local function resolveChannelId(channelName)
	if type(channelName) ~= "string" or channelName == "" or type(GetChannelList) ~= "function" then
		return nil, "channel_unavailable"
	end
	local wanted = string.lower(channelName)
	local callOk, rows = pcall(function() return { GetChannelList() } end)
	if not callOk then
		return nil, "channel_unavailable"
	end
	local resolved
	for i = 1, #rows, 2 do
		local id, name = tonumber(rows[i]), rows[i + 1]
		if id and id > 0 and type(name) == "string" and string.lower(name) == wanted then
			if resolved and resolved ~= id then
				return nil, "ambiguous_channel"
			end
			resolved = id
		end
	end
	if not resolved then
		return nil, "channel_unavailable"
	end
	return resolved
end

local function canSpeakOfficer()
	if type(IsInGuild) ~= "function" or not IsInGuild() then
		return false
	end
	if type(GetGuildInfo) ~= "function" or type(GuildControlGetRankFlags) ~= "function" then
		return false
	end
	local _, _, rankIndex = GetGuildInfo("player")
	if type(rankIndex) ~= "number" then
		return false
	end
	local ok, _, _, _, officerSpeak = pcall(GuildControlGetRankFlags, rankIndex + 1)
	return ok and officerSpeak == true
end

local function validateChatDestination(channel, target)
	if type(channel) ~= "string" or channel == "" then
		return nil, "invalid_channel"
	end
	local destination = string.upper(channel)
	if destination == "RAID" then
		if (tonumber(GetNumRaidMembers()) or 0) <= 0 then return nil, "not_in_raid" end
	elseif destination == "RAID_WARNING" then
		if (tonumber(GetNumRaidMembers()) or 0) <= 0 then return nil, "not_in_raid" end
		if type(Database.GetUnitRank) ~= "function" or (tonumber(Database.GetUnitRank("player", 0)) or 0) <= 0 then
			return nil, "insufficient_rank"
		end
	elseif destination == "PARTY" then
		if (tonumber(GetNumRaidMembers()) or 0) <= 0 and (tonumber(GetNumPartyMembers()) or 0) <= 0 then
			return nil, "not_in_party"
		end
	elseif destination == "GUILD" then
		if type(IsInGuild) ~= "function" or not IsInGuild() then return nil, "not_in_guild" end
	elseif destination == "OFFICER" then
		if not canSpeakOfficer() then return nil, "insufficient_rank" end
	elseif destination == "WHISPER" then
		if type(target) ~= "string" or target == "" then return nil, "invalid_target" end
	elseif destination == "CHANNEL" then
		if type(target) ~= "string" then return nil, "invalid_channel" end
		local channelId, reason = resolveChannelId(target)
		if not channelId then return nil, reason end
		return destination, channelId
	elseif destination ~= "SAY" and destination ~= "YELL" and destination ~= "EMOTE" then
		local channelId, reason = resolveChannelId(channel)
		if not channelId then return nil, reason end
		return "CHANNEL", channelId
	end
	return destination, target
end

function Comms.SendChat(msg, channel, language, target, bypass)
	if msg == nil then
		return nil, "invalid_message"
	end
	local destination, resolvedTarget = validateChatDestination(channel, target)
	if not destination then
		return nil, resolvedTarget
	end
	local callOk, result = pcall(SendChatMessage, tostring(msg), destination, language, resolvedTarget)
	if not callOk or result == false then
		return nil, "send_failed"
	end
	return true
end

function Comms.SendWhisper(target, msg)
	if type(target) == "string" and msg then
		return Comms.SendChat(msg, "WHISPER", nil, target)
	end
	return nil, "invalid_target"
end

function Comms.SendAddonWhisper(prefix, target, msg)
	if type(prefix) == "string" and type(target) == "string" and msg then
		return Comms.QueueAddonMessage(prefix, tostring(msg), "WHISPER", target)
	end
	return false
end

function Comms.NormalizeSender(sender)
	if type(sender) ~= "string" then
		return nil
	end
	local short = strmatch(sender, "^([^%-]+)") or sender
	return NormalizeName(short, true) or short
end

local function buildRequestSessionNonce()
	local getTime = _G.GetTime
	local stamp = type(getTime) == "function" and floor((tonumber(getTime()) or 0) * 1000) or 0
	local seed = tostring(UnitName("player") or "") .. ":" .. tostring(stamp) .. ":" .. tostring({})
	local hash = 5381
	for i = 1, #seed do
		hash = ((hash * 33) + strbyte(seed, i)) % 1000000000
	end
	return tostring(hash)
end

function Comms.NextRequestId(owner, fieldName, isUnavailable)
	if type(owner) ~= "table" then
		return nil
	end
	local key = fieldName or "_nextRequestId"
	if type(isUnavailable) ~= "function" then
		owner[key] = (tonumber(owner[key]) or 0) + 1
		return tostring(owner[key])
	end
	local nonce = tostring(owner._requestSessionNonce or buildRequestSessionNonce())
	owner._requestSessionNonce = nonce
	local counter = floor(tonumber(owner[key]) or -1)
	for _ = 1, 1024 do
		counter = (counter + 1) % 1000000
		local candidate = nonce .. "-" .. tostring(counter)
		if #candidate <= 64 and isUnavailable(candidate) ~= true then
			owner[key] = counter
			return candidate
		end
	end
	return nil, "request_id_exhausted"
end

function Comms:EnsureVersionPrefix()
	Comms.RegisterPrefixIfAvailable(VERSION_PREFIX)
end

function Comms.GetVersionInfo()
	return {
		addonVersion = getAddonMetadata("Version", getUnknownText()),
		interfaceVersion = getAddonMetadata("Interface", getUnknownText()),
		raidSchemaVersion = getRaidSchemaVersion(),
		syncProtocolVersion = getSyncProtocolVersion(),
	}
end

function Comms:RequestVersionCheck()
	self:EnsureVersionPrefix()
	local ok = sendGroupMessage(VERSION_PREFIX, buildVersionPayload(MSG_VERSION_REQ))
	if ok then
		addon:info(L.MsgVersionCheckSent)
		return true
	end
	addon:warn(L.MsgVersionCheckNotInGroup)
	return false
end

function Comms:HandleVersionMessage(prefix, msg, channel, sender)
	if prefix ~= VERSION_PREFIX then
		return false
	end
	if tostring(sender or "") == getPlayerName() then
		return true
	end

	local kind, addonVersion, interfaceVersion, schemaVersion, syncProtocol = splitVersionPayload(msg)
	if kind == MSG_VERSION_REQ then
		Comms.QueueAddonMessage(VERSION_PREFIX, buildVersionPayload(MSG_VERSION_ACK), "WHISPER", sender)
		return true
	end
	if kind == MSG_VERSION_ACK then
		addon:info(
			L.MsgVersionCheckPeer:format(
				tostring(sender or "?"),
				tostring(addonVersion or "?"),
				tostring(interfaceVersion or "?"),
				tostring(schemaVersion or "?"),
				tostring(syncProtocol or "?")
			)
		)
		return true
	end
	return true
end
