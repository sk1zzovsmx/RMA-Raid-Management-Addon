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
local strmatch = string.match
local _G = _G
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
local LibSerialize = assert(LibStub("LibSerialize"), "LibSerialize is not initialized")
local LibDeflate = assert(LibStub("LibDeflate"), "LibDeflate is not initialized")
local ChatThrottleLib = assert(_G.ChatThrottleLib, "ChatThrottleLib is not initialized")
local WIRE_VERSION = 5
local VALID_PRIORITIES = { ALERT = true, NORMAL = true, BULK = true }
local VALID_ADDON_DESTINATIONS = {
	RAID = true,
	PARTY = true,
	BATTLEGROUND = true,
	GUILD = true,
	OFFICER = true,
	WHISPER = true,
}

-- ----- Internal state ----- --

local VERSION_PREFIX = "RMAVersion"
local MSG_VERSION_REQ = "REQ"
local MSG_VERSION_ACK = "ACK"

-- ----- Private helpers ----- --

local function getUnknownText()
	return tostring((L and L.StrUnknown) or "unknown")
end

function Payload.Serialize(value)
	local okSerialize, serialized = pcall(LibSerialize.Serialize, LibSerialize, value)
	if not okSerialize or type(serialized) ~= "string" or serialized == "" then
		return nil, "SERIALIZE_FAILED"
	end
	local okEncode, encoded = pcall(LibDeflate.EncodeForWoWAddonChannel, LibDeflate, serialized)
	if not okEncode or type(encoded) ~= "string" or encoded == "" then
		return nil, "CHANNEL_ENCODE_FAILED"
	end
	return encoded
end

function Payload.Deserialize(text)
	if type(text) ~= "string" or text == "" then
		return nil, "MALFORMED_PAYLOAD"
	end
	local okDecode, serialized = pcall(LibDeflate.DecodeForWoWAddonChannel, LibDeflate, text)
	if not okDecode or type(serialized) ~= "string" or serialized == "" then
		return nil, "CHANNEL_DECODE_FAILED"
	end
	local okCall, success, value = pcall(LibSerialize.Deserialize, LibSerialize, serialized)
	if not okCall or success ~= true then
		return nil, "DESERIALIZE_FAILED"
	end
	return value
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
	return Payload.Serialize({ WIRE_VERSION, kind, false, false, info })
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

local function stableQueueName(prefix, channel, target)
	return tostring(prefix) .. ":" .. tostring(channel) .. ":" .. string.lower(tostring(target or "group"))
end

local function normalizeTransportOptions(prefix, channel, target, opts)
	if opts ~= nil and type(opts) ~= "table" then
		return nil, "invalid_options"
	end
	local priority = opts and opts.priority or "NORMAL"
	if not VALID_PRIORITIES[priority] then
		return nil, "invalid_priority"
	end
	local queueName = opts and opts.queueName
	if queueName ~= nil and (type(queueName) ~= "string" or queueName == "") then
		return nil, "invalid_queue_name"
	end
	return priority, queueName or stableQueueName(prefix, channel, target)
end

local function validateAddonDestination(channel, target)
	if type(channel) ~= "string" or channel == "" then
		return nil
	end
	local destination = string.upper(channel)
	if not VALID_ADDON_DESTINATIONS[destination] then
		return nil
	end
	if destination == "WHISPER" then
		return type(target) == "string" and target ~= "" and destination or nil
	end
	return target == nil and destination or nil
end

function Comms.QueueAddonMessage(prefix, msg, channel, target, opts)
	if
		type(prefix) ~= "string"
		or prefix == ""
		or type(channel) ~= "string"
		or channel == ""
		or type(msg) ~= "string"
		or msg == ""
	then
		return false, "invalid"
	end
	local destination = validateAddonDestination(channel, target)
	if not destination then
		return false, "invalid_destination"
	end
	local priority, queueName = normalizeTransportOptions(prefix, destination, target, opts)
	if not priority then
		return false, queueName
	end
	local ok =
		pcall(ChatThrottleLib.SendAddonMessage, ChatThrottleLib, priority, prefix, msg, destination, target, queueName)
	return ok == true, ok and nil or "send_failed"
end

function Comms.QueueAddonMessages(prefix, messages, channel, target, opts)
	if
		type(prefix) ~= "string"
		or prefix == ""
		or type(channel) ~= "string"
		or channel == ""
		or type(messages) ~= "table"
	then
		return false, "invalid"
	end
	local destination = validateAddonDestination(channel, target)
	if not destination then
		return false, "invalid_destination"
	end
	local priority, queueName = normalizeTransportOptions(prefix, destination, target, opts)
	if not priority then
		return false, queueName
	end
	local count = 0
	for key, message in pairs(messages) do
		if type(key) ~= "number" or key < 1 or key % 1 ~= 0 or type(message) ~= "string" or message == "" then
			return false, "invalid"
		end
		count = count + 1
	end
	for i = 1, count do
		if messages[i] == nil then
			return false, "invalid"
		end
	end
	if count < 1 then
		return true
	end
	for i = 1, count do
		local queued, reason = Comms.QueueAddonMessage(prefix, messages[i], destination, target, {
			priority = priority,
			queueName = queueName,
		})
		if not queued then
			return false, reason
		end
	end
	return true
end

function Comms.SendAddonBatch(prefix, messages, target, opts)
	if type(target) == "string" and target ~= "" then
		return Comms.QueueAddonMessages(prefix, messages, "WHISPER", target, opts)
	end
	local channel = getGroupTransport()
	if not channel then
		return false, "not_in_group"
	end
	return Comms.QueueAddonMessages(prefix, messages, channel, nil, opts)
end

local function sendGroupMessage(prefix, msg, opts)
	local channel = getGroupTransport()
	if channel then
		local sent = Comms.QueueAddonMessage(prefix, msg, channel, nil, opts)
		if sent then
			return true, channel
		end
		return false
	end
	return false
end

function Comms.Sync(prefix, msg)
	return sendGroupMessage(prefix, msg)
end

local function resolveChannelId(channelName)
	if type(channelName) ~= "string" or channelName == "" or type(GetChannelList) ~= "function" then
		return nil, "channel_unavailable"
	end
	local wanted = string.lower(channelName)
	local callOk, rows = pcall(function()
		return { GetChannelList() }
	end)
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
		if (tonumber(GetNumRaidMembers()) or 0) <= 0 then
			return nil, "not_in_raid"
		end
	elseif destination == "RAID_WARNING" then
		if (tonumber(GetNumRaidMembers()) or 0) <= 0 then
			return nil, "not_in_raid"
		end
		if type(Database.GetUnitRank) ~= "function" or (tonumber(Database.GetUnitRank("player", 0)) or 0) <= 0 then
			return nil, "insufficient_rank"
		end
	elseif destination == "PARTY" then
		if (tonumber(GetNumRaidMembers()) or 0) <= 0 and (tonumber(GetNumPartyMembers()) or 0) <= 0 then
			return nil, "not_in_party"
		end
	elseif destination == "GUILD" then
		if type(IsInGuild) ~= "function" or not IsInGuild() then
			return nil, "not_in_guild"
		end
	elseif destination == "OFFICER" then
		if not canSpeakOfficer() then
			return nil, "insufficient_rank"
		end
	elseif destination == "WHISPER" then
		if type(target) ~= "string" or target == "" then
			return nil, "invalid_target"
		end
	elseif destination == "CHANNEL" then
		if type(target) ~= "string" then
			return nil, "invalid_channel"
		end
		local channelId, reason = resolveChannelId(target)
		if not channelId then
			return nil, reason
		end
		return destination, channelId
	elseif destination ~= "SAY" and destination ~= "YELL" and destination ~= "EMOTE" then
		local channelId, reason = resolveChannelId(channel)
		if not channelId then
			return nil, reason
		end
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
	local callOk, result = pcall(
		ChatThrottleLib.SendChatMessage,
		ChatThrottleLib,
		bypass == true and "ALERT" or "NORMAL",
		"RMA",
		tostring(msg),
		destination,
		language,
		resolvedTarget,
		stableQueueName("RMAChat", destination, resolvedTarget)
	)
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
	local payload = buildVersionPayload(MSG_VERSION_REQ)
	local ok = payload and sendGroupMessage(VERSION_PREFIX, payload, { priority = "ALERT" })
	if ok then
		addon:info(L.MsgVersionCheckSent)
		return true
	end
	addon:warn(L.MsgVersionCheckNotInGroup)
	return false
end

local function isDenseVersionEnvelope(envelope)
	if type(envelope) ~= "table" then
		return false
	end
	for i = 1, 5 do
		if envelope[i] == nil then
			return false
		end
	end
	for key in pairs(envelope) do
		if type(key) ~= "number" or key < 1 or key > 5 or key % 1 ~= 0 then
			return false
		end
	end
	return envelope[3] == false and envelope[4] == false
end

local function isValidVersionInfo(info)
	if type(info) ~= "table" then
		return false
	end
	return type(info.addonVersion) == "string"
		and info.addonVersion ~= ""
		and type(info.interfaceVersion) == "string"
		and info.interfaceVersion ~= ""
		and type(info.raidSchemaVersion) == "string"
		and info.raidSchemaVersion ~= ""
		and type(info.syncProtocolVersion) == "string"
		and info.syncProtocolVersion ~= ""
end

function Comms:HandleVersionMessage(prefix, msg, channel, sender)
	if prefix ~= VERSION_PREFIX then
		return false
	end
	if tostring(sender or "") == getPlayerName() then
		return true
	end

	local envelope = Payload.Deserialize(msg)
	if not isDenseVersionEnvelope(envelope) or envelope[1] ~= WIRE_VERSION then
		return true
	end
	local kind = envelope[2]
	local info = envelope[5]
	if (kind ~= MSG_VERSION_REQ and kind ~= MSG_VERSION_ACK) or not isValidVersionInfo(info) then
		return true
	end
	if kind == MSG_VERSION_REQ then
		local response = buildVersionPayload(MSG_VERSION_ACK)
		if response then
			Comms.QueueAddonMessage(VERSION_PREFIX, response, "WHISPER", sender, { priority = "ALERT" })
		end
		return true
	end
	if kind == MSG_VERSION_ACK then
		addon:info(
			L.MsgVersionCheckPeer:format(
				tostring(sender or "?"),
				tostring(info.addonVersion),
				tostring(info.interfaceVersion),
				tostring(info.raidSchemaVersion),
				tostring(info.syncProtocolVersion)
			)
		)
		return true
	end
	return true
end
