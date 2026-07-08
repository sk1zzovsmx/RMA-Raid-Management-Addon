-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: local feature = addon.Database.GetFeatureShared()
-- exports: publish module APIs on addon.*
-- events: owns addon-message send helpers and RMAVersion payload handling

local addonName = ...
local addon = select(2, ...)
local feature = addon.Database.GetFeatureShared()

local type, tostring, tonumber = type, tostring, tonumber
local pcall = pcall
local select = select
local strfind, strmatch, strsub = string.find, string.match, string.sub
local tconcat, tremove = table.concat, table.remove
local _G = _G
local SendAddonMessage = assert(_G.SendAddonMessage, "Comms addon-message send API is not initialized")
local SendChatMessage = assert(_G.SendChatMessage, "Comms chat send API is not initialized")
local GetAddOnMetadata = assert(_G.GetAddOnMetadata, "Comms addon metadata API is not initialized")
local UnitName = assert(_G.UnitName, "Comms unit name API is not initialized")
local IsInInstance = assert(_G.IsInInstance, "Comms instance state API is not initialized")
local GetNumRaidMembers = assert(_G.GetNumRaidMembers, "Comms raid member count API is not initialized")
local GetNumPartyMembers = assert(_G.GetNumPartyMembers, "Comms party member count API is not initialized")

local Comms = feature.Comms or {}
addon.Comms = Comms
Comms.Payload = Comms.Payload or {}
local Payload = Comms.Payload
local L = feature.L
local Database = feature.Database
local Strings = feature.Strings
local NormalizeName = assert(Strings.NormalizeName, "Comms sender name normalizer is not initialized")
local Timer = feature.Timer
local BindTimerMixin = assert(Timer.BindMixin, "Comms timer mixin is not initialized")

Comms._addonQueue = Comms._addonQueue or {}
Comms._addonQueueTimer = Comms._addonQueueTimer

local COMMS_ADDON_QUEUE_BURST = 4
local COMMS_ADDON_QUEUE_DELAY_SECONDS = 0.08
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
	return addon.Base64 or feature.Base64
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
	if type(queue) ~= "table" or #queue == 0 then
		return 0
	end

	local burst = tonumber(limit) or COMMS_ADDON_QUEUE_BURST
	if burst <= 0 then
		burst = COMMS_ADDON_QUEUE_BURST
	end

	local sent = 0
	for i = 1, burst do
		local entry = queue[1]
		if not entry then
			break
		end

		tremove(queue, 1)
		if sendAddonMessageNow(entry.prefix, entry.msg, entry.channel, entry.target) then
			sent = sent + 1
		end
	end
	if #queue > 0 then
		scheduleAddonQueueFlush()
	end
	return sent
end

function Comms.QueueAddonMessage(prefix, msg, channel, target, opts)
	if type(prefix) ~= "string" or prefix == "" or type(channel) ~= "string" or channel == "" or msg == nil then
		return false
	end

	if not (opts and opts.immediate == true) then
		Comms._addonQueue[#Comms._addonQueue + 1] = {
			prefix = prefix,
			msg = tostring(msg),
			channel = channel,
			target = (type(target) == "string" and target ~= "" and target) or nil,
		}
		if scheduleAddonQueueFlush() then
			return true
		end

		return flushAddonQueue(#Comms._addonQueue) > 0
	end

	return sendAddonMessageNow(prefix, msg, channel, target)
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

function Comms.SendChat(msg, channel, language, target, bypass)
	if not msg then
		return
	end
	SendChatMessage(tostring(msg), channel, language, target)
end

function Comms.SendWhisper(target, msg)
	if type(target) == "string" and msg then
		SendChatMessage(msg, "WHISPER", nil, target)
		return true
	end
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

function Comms.NextRequestId(owner, fieldName)
	if type(owner) ~= "table" then
		return nil
	end
	local key = fieldName or "_nextRequestId"
	owner[key] = (tonumber(owner[key]) or 0) + 1
	return tostring(owner[key])
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

do
	local name = "Modules/Comms"
	local deps = { "Init", "Modules/Timer", "Modules/Base64", "Modules/Strings" }
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
