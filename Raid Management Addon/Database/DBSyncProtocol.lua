-- ----- RMA Lua Contract ----- --
-- deps: addon.DB.RaidEvents, addon.Comms.Payload, addon.Json
-- shared: addon.DB.SyncProtocol
-- exports: version-3 raid replication envelope and body codec
-- events: none

local addon = select(2, ...)
local DB = addon.DB
local RaidEvents = assert(DB.RaidEvents, "Raid event codec dependency is not initialized")
local Payload = assert(addon.Comms and addon.Comms.Payload, "Comms payload helpers are not initialized")
local Json = assert(addon.Json, "JSON codec is not initialized")

DB.SyncProtocol = DB.SyncProtocol or {}
local Protocol = DB.SyncProtocol

local floor = math.floor
local format = string.format
local byte = string.byte
local gsub = string.gsub
local match = string.match
local type = type

local MAX_SEQUENCE = 999999999
local MAX_AUTHORITY_EPOCH = 999999
local MAX_RANGE_EVENTS = 512
local MAX_PART_COUNT = 256
local MAX_CHUNK_BYTES = 220
local MAX_MESSAGE_BYTES = 243

local OUTCOMES = {
	IMPORTED = true,
	ALREADY_PRESENT = true,
	CONFLICT = true,
	DECLINED = true,
	FAILED = true,
}

local MESSAGE_SCHEMAS = {
	HEAD_REQ = {},
	HEAD = {
		raidUid = true,
		authorityEpoch = true,
		sequence = true,
		checkpointSequence = true,
		digest = true,
		status = true,
		zone = false,
		size = false,
		difficulty = false,
	},
	EVENT = { event = true },
	RANGE_REQ = { raidUid = true, authorityEpoch = true, fromSequence = true, toSequence = true },
	RANGE_DATA = {
		raidUid = true,
		authorityEpoch = true,
		fromSequence = true,
		toSequence = true,
		partIndex = true,
		partCount = true,
		chunk = true,
	},
	SNAP_REQ = { raidUid = true },
	SNAP_DATA = {
		raidUid = true,
		authorityEpoch = true,
		sequence = true,
		partIndex = true,
		partCount = true,
		chunk = true,
	},
	OFFER = {
		raidUid = true,
		authorityEpoch = true,
		sequence = true,
		digest = true,
		zone = true,
		startTime = true,
		size = true,
		difficulty = true,
		lootCount = true,
	},
	RESULT = { outcome = true, reason = false },
}

local function exactInteger(value, minimum, maximum)
	if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
		return nil
	end
	if value ~= floor(value) or value < minimum or value > maximum then
		return nil
	end
	return value
end

local function visibleAscii(value, minimumBytes, maximumBytes)
	if type(value) ~= "string" or #value < minimumBytes or #value > maximumBytes then
		return nil
	end
	for i = 1, #value do
		local valueByte = byte(value, i)
		if valueByte < 33 or valueByte > 126 then
			return nil
		end
	end
	return true
end

local function displayAscii(value, minimumBytes, maximumBytes)
	if type(value) ~= "string" or #value < minimumBytes or #value > maximumBytes then
		return nil
	end
	for i = 1, #value do
		local valueByte = byte(value, i)
		if valueByte < 32 or valueByte == 127 or valueByte == 124 then
			return nil
		end
	end
	return true
end

local function addonChannelChunk(value)
	if type(value) ~= "string" or #value < 1 or #value > MAX_CHUNK_BYTES then
		return nil
	end
	return not string.find(value, "\000", 1, true)
end

local function validRaidUid(value)
	return visibleAscii(value, 1, 40)
end

local function validDigest(value)
	if type(value) ~= "string" then
		return nil
	end
	local checksum, byteCountText =
		match(value, "^([0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]):([1-9][0-9]*)$")
	if not checksum then
		return nil
	end
	local byteCount = tonumber(byteCountText)
	return exactInteger(byteCount, 1, MAX_SEQUENCE) and tostring(byteCount) == byteCountText
end

local function closedBody(body, schema)
	if type(body) ~= "table" then
		return nil
	end
	for key in pairs(body) do
		if type(key) ~= "string" or schema[key] == nil then
			return nil
		end
	end
	for key, required in pairs(schema) do
		if required and body[key] == nil then
			return nil
		end
	end
	return true
end

local function validRange(body)
	local fromSequence = exactInteger(body.fromSequence, 1, MAX_SEQUENCE)
	local toSequence = exactInteger(body.toSequence, 1, MAX_SEQUENCE)
	return fromSequence
		and toSequence
		and fromSequence <= toSequence
		and toSequence - fromSequence + 1 <= MAX_RANGE_EVENTS
end

local function validParts(body)
	local partIndex = exactInteger(body.partIndex, 1, MAX_PART_COUNT)
	local partCount = exactInteger(body.partCount, 1, MAX_PART_COUNT)
	return partIndex and partCount and partIndex <= partCount and addonChannelChunk(body.chunk)
end

local VALIDATORS = {
	HEAD_REQ = function()
		return true
	end,
	HEAD = function(body)
		local hasZone = body.zone ~= nil
		local hasSize = body.size ~= nil
		local hasDifficulty = body.difficulty ~= nil
		local hasContext = hasZone or hasSize or hasDifficulty
		if hasContext then
			if not (hasZone and hasSize and hasDifficulty) then
				return nil
			end
			local size = exactInteger(body.size, 10, 25)
			if not displayAscii(body.zone, 1, 80)
				or (size ~= 10 and size ~= 25)
				or not exactInteger(body.difficulty, 1, 4)
			then
				return nil
			end
		end
		local sequence = exactInteger(body.sequence, 0, MAX_SEQUENCE)
		local checkpoint = exactInteger(body.checkpointSequence, 0, MAX_SEQUENCE)
		return validRaidUid(body.raidUid)
			and exactInteger(body.authorityEpoch, 1, MAX_AUTHORITY_EPOCH)
			and sequence
			and (sequence >= 1 or body.status == "complete")
			and checkpoint
			and checkpoint <= sequence
			and validDigest(body.digest)
			and (body.status == "active" or body.status == "complete")
	end,
	EVENT = function(body)
		if type(body.event) ~= "table" or body.event.resultDigest == nil then
			return nil
		end
		return RaidEvents.ValidateEvent(body.event)
	end,
	RANGE_REQ = function(body)
		return validRaidUid(body.raidUid)
			and exactInteger(body.authorityEpoch, 1, MAX_AUTHORITY_EPOCH)
			and validRange(body)
	end,
	RANGE_DATA = function(body)
		return validRaidUid(body.raidUid)
			and exactInteger(body.authorityEpoch, 1, MAX_AUTHORITY_EPOCH)
			and validRange(body)
			and validParts(body)
	end,
	SNAP_REQ = function(body)
		return validRaidUid(body.raidUid)
	end,
	SNAP_DATA = function(body)
		return validRaidUid(body.raidUid)
			and exactInteger(body.authorityEpoch, 1, MAX_AUTHORITY_EPOCH)
			and exactInteger(body.sequence, 0, MAX_SEQUENCE)
			and validParts(body)
	end,
	OFFER = function(body)
		return validRaidUid(body.raidUid)
			and exactInteger(body.authorityEpoch, 1, MAX_AUTHORITY_EPOCH)
			and exactInteger(body.sequence, 0, MAX_SEQUENCE)
			and validDigest(body.digest)
			and displayAscii(body.zone, 1, 128)
			and exactInteger(body.startTime, 1, 9999999999)
			and exactInteger(body.size, 1, 40)
			and exactInteger(body.difficulty, 1, 4)
			and exactInteger(body.lootCount, 0, 10000)
	end,
	RESULT = function(body)
		return OUTCOMES[body.outcome] and (body.reason == nil or visibleAscii(body.reason, 1, 96))
	end,
}

local function validateBody(kind, body)
	local schema = MESSAGE_SCHEMAS[kind]
	if not schema or not closedBody(body, schema) then
		return nil, "INVALID_MESSAGE_BODY"
	end
	local valid, reason = VALIDATORS[kind](body)
	if not valid then
		return nil, reason or "INVALID_MESSAGE_BODY"
	end
	return true
end

local function validateEnvelope(kind, requestId, target)
	if kind == "HEAD_REQ" or kind == "HEAD" or kind == "EVENT" then
		if requestId ~= "-" or target ~= "-" then
			return nil, "INVALID_ENVELOPE_TARGET"
		end
		return true
	end
	if requestId == "-" or target == "-" or not visibleAscii(requestId, 1, 64) or not visibleAscii(target, 1, 64) then
		return nil, "INVALID_ENVELOPE_TARGET"
	end
	return true
end

local JSON_ESCAPES = {
	['"'] = '\\"',
	["\\"] = "\\\\",
	["\b"] = "\\b",
	["\f"] = "\\f",
	["\n"] = "\\n",
	["\r"] = "\\r",
	["\t"] = "\\t",
}

local function encodeJsonString(value)
	return '"'
		.. gsub(value, '[%z\1-\31\\"]', function(character)
			return JSON_ESCAPES[character] or format("\\u%04x", byte(character))
		end)
		.. '"'
end

local function encodeJson(value, active)
	local valueType = type(value)
	if value == Json.NULL then
		return "null"
	elseif valueType == "boolean" then
		return value and "true" or "false"
	elseif valueType == "number" then
		if value ~= value or value == math.huge or value == -math.huge then
			return nil, "INVALID_BODY_NUMBER"
		end
		return format("%.17g", value)
	elseif valueType == "string" then
		return encodeJsonString(value)
	elseif valueType ~= "table" then
		return nil, "INVALID_BODY_VALUE"
	end

	active = active or {}
	if active[value] then
		return nil, "CYCLIC_BODY"
	end
	active[value] = true
	local count, maximum, dense = 0, 0, true
	for key in pairs(value) do
		count = count + 1
		if type(key) ~= "number" or key < 1 or key ~= floor(key) then
			dense = false
		elseif key > maximum then
			maximum = key
		end
	end
	dense = dense and maximum == count and count > 0

	local parts = {}
	if dense then
		for i = 1, count do
			local encoded, reason = encodeJson(value[i], active)
			if not encoded then
				active[value] = nil
				return nil, reason
			end
			parts[i] = encoded
		end
		active[value] = nil
		return "[" .. table.concat(parts, ",") .. "]"
	end

	local keys = {}
	for key in pairs(value) do
		if type(key) ~= "string" then
			active[value] = nil
			return nil, "INVALID_BODY_KEY"
		end
		keys[#keys + 1] = key
	end
	table.sort(keys)
	for i = 1, #keys do
		local key = keys[i]
		local encoded, reason = encodeJson(value[key], active)
		if not encoded then
			active[value] = nil
			return nil, reason
		end
		parts[i] = encodeJsonString(key) .. ":" .. encoded
	end
	active[value] = nil
	return "{" .. table.concat(parts, ",") .. "}"
end

Protocol.VERSION = 3

function Protocol.EncodeBody(body)
	if type(body) ~= "table" then
		return nil, "INVALID_MESSAGE_BODY"
	end
	return encodeJson(body)
end

function Protocol.DecodeBody(text)
	if type(text) ~= "string" or text == "" then
		return nil, "MALFORMED_MESSAGE_BODY"
	end
	if string.find(text, "[%z\1-\31]") then
		return nil, "MALFORMED_MESSAGE_BODY_CONTROL"
	end
	local ok, body, reason = pcall(Json.Decode, text)
	if not ok or type(body) ~= "table" then
		return nil, reason or "MALFORMED_MESSAGE_BODY"
	end
	return body
end

function Protocol.Encode(kind, requestId, target, body)
	if not MESSAGE_SCHEMAS[kind] then
		return nil, "UNKNOWN_MESSAGE_KIND"
	end
	requestId = requestId or "-"
	target = target or "-"
	local envelopeValid, envelopeReason = validateEnvelope(kind, requestId, target)
	if not envelopeValid then
		return nil, envelopeReason
	end
	local valid, reason = validateBody(kind, body)
	if not valid then
		return nil, reason
	end
	local encodedBody, encodeReason = Protocol.EncodeBody(body)
	if not encodedBody then
		return nil, encodeReason
	end
	local message = Payload.PackFields("\t", "R3", kind, requestId, target, encodedBody)
	if #message > MAX_MESSAGE_BYTES then
		return nil, "MESSAGE_TOO_LARGE"
	end
	return message
end

function Protocol.Decode(message)
	if type(message) ~= "string" then
		return nil, "UNSUPPORTED_PROTOCOL"
	end
	local fields, count = Payload.SplitFields(message, "\t")
	if count ~= 5 or fields[1] ~= "R3" then
		return nil, "UNSUPPORTED_PROTOCOL"
	end
	local kind = fields[2]
	if not MESSAGE_SCHEMAS[kind] then
		return nil, "UNKNOWN_MESSAGE_KIND"
	end
	local envelopeValid, envelopeReason = validateEnvelope(kind, fields[3], fields[4])
	if not envelopeValid then
		return nil, envelopeReason
	end
	local body, reason = Protocol.DecodeBody(fields[5])
	if not body then
		return nil, reason
	end
	local valid, validationReason = validateBody(kind, body)
	if not valid then
		return nil, validationReason
	end
	return { kind = kind, requestId = fields[3], target = fields[4], body = body }
end
