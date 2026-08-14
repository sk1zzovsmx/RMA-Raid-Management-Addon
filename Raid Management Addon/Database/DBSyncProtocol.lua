-- ----- RMA Lua Contract ----- --
-- deps: addon.DB.RaidEvents, addon.Comms.Payload, addon.Json, addon.Item
-- shared: addon.DB.SyncProtocol
-- exports: version-4 raid replication envelope and body codec
-- events: none

local addon = select(2, ...)
local DB = addon.DB
local RaidEvents = assert(DB.RaidEvents, "Raid event codec dependency is not initialized")
local Payload = assert(addon.Comms and addon.Comms.Payload, "Comms payload helpers are not initialized")
local Json = assert(addon.Json, "JSON codec is not initialized")
local Item = assert(addon.Item, "Item dependency is not initialized")

DB.SyncProtocol = DB.SyncProtocol or {}
local Protocol = DB.SyncProtocol

local floor = math.floor
local format = string.format
local byte = string.byte
local gsub = string.gsub
local match = string.match
local type = type
local lower = string.lower

local MAX_SEQUENCE = 999999999
local MAX_AUTHORITY_EPOCH = 999999
local MAX_RANGE_EVENTS = 512
local MAX_PART_COUNT = 256
local MAX_LIVE_LOOT_PART_COUNT = 32
local MAX_CHUNK_BYTES = 220
local MAX_MESSAGE_BYTES = 243
local WIRE_MARKER = "R4"

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
	LIVE_LOOT = { event = true },
	LIVE_LOOT_PART = {
		raidUid = true,
		authorityEpoch = true,
		sequence = true,
		partIndex = true,
		partCount = true,
		chunk = true,
	},
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

local LOOT_FIELDS = {
	lootNid = true,
	itemId = true,
	itemName = true,
	itemString = true,
	itemLink = true,
	itemRarity = true,
	itemTexture = true,
	itemCount = true,
	looterNid = true,
	rollType = true,
	rollValue = true,
	rollSessionId = true,
	bossNid = true,
	time = true,
	source = true,
	lootSource = true,
}

local LOOT_SOURCE_FIELDS = {
	kind = true,
	bossNid = true,
	sourceNpcId = true,
	sourceName = true,
	sourceKey = true,
	openedAt = true,
	snapshotId = true,
	candidates = true,
}

local LOOT_SOURCE_CANDIDATE_FIELDS = {
	name = true,
	kind = true,
	sourceKey = true,
	npcId = true,
}

local ITEM_RARITY_BY_COLOR = {
	ff9d9d9d = 0,
	ffffffff = 1,
	ff1eff00 = 2,
	ff0070dd = 3,
	ffa335ee = 4,
	ffff8000 = 5,
	ffe6cc80 = 6,
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

local function finiteNumber(value, minimum, maximum)
	if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
		return nil
	end
	if value < minimum or value > maximum then
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
			if
				not displayAscii(body.zone, 1, 80)
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
	LIVE_LOOT = function(body)
		if type(body.event) ~= "table" or body.event.resultDigest == nil then
			return nil
		end
		return RaidEvents.ValidateEvent(body.event)
	end,
	LIVE_LOOT_PART = function(body)
		local partIndex = exactInteger(body.partIndex, 1, MAX_LIVE_LOOT_PART_COUNT)
		local partCount = exactInteger(body.partCount, 1, MAX_LIVE_LOOT_PART_COUNT)
		return validRaidUid(body.raidUid)
			and exactInteger(body.authorityEpoch, 1, MAX_AUTHORITY_EPOCH)
			and exactInteger(body.sequence, 1, MAX_SEQUENCE)
			and partIndex
			and partCount
			and partIndex <= partCount
			and addonChannelChunk(body.chunk)
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
	if kind == "HEAD_REQ" or kind == "HEAD" or kind == "EVENT" or kind == "LIVE_LOOT" or kind == "LIVE_LOOT_PART" then
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

local function deepEqual(left, right, seen)
	if left == right then
		return true
	end
	if type(left) ~= "table" or type(right) ~= "table" then
		return false
	end
	seen = seen or {}
	if seen[left] == right then
		return true
	end
	seen[left] = right
	for key, value in pairs(left) do
		if not deepEqual(value, right[key], seen) then
			return false
		end
	end
	for key in pairs(right) do
		if left[key] == nil then
			return false
		end
	end
	return true
end

local function denseArray(value, count)
	if type(value) ~= "table" then
		return nil
	end
	local seen = 0
	for key in pairs(value) do
		if type(key) ~= "number" or key ~= floor(key) or key < 1 or key > count then
			return nil
		end
		seen = seen + 1
	end
	return seen == count
end

local function closedMap(value, schema)
	if type(value) ~= "table" then
		return nil
	end
	for key in pairs(value) do
		if type(key) ~= "string" or not schema[key] then
			return nil
		end
	end
	return true
end

local function compactScalar(value)
	if value == Json.NULL then
		return nil
	end
	local valueType = type(value)
	if valueType == "string" or valueType == "number" or valueType == "boolean" then
		return value
	end
	return nil
end

local function compactSlot(value)
	if value == nil then
		return Json.NULL
	end
	return value
end

local function encodeLootSource(source)
	if source == nil then
		return Json.NULL
	end
	if not closedMap(source, LOOT_SOURCE_FIELDS) then
		return nil, "NON_RECONSTRUCTIBLE_LIVE_LOOT"
	end
	local encodedCandidates = Json.NULL
	if source.candidates ~= nil then
		if type(source.candidates) ~= "table" then
			return nil, "NON_RECONSTRUCTIBLE_LIVE_LOOT"
		end
		local candidateCount = #source.candidates
		if candidateCount > MAX_RANGE_EVENTS or not denseArray(source.candidates, candidateCount) then
			return nil, "NON_RECONSTRUCTIBLE_LIVE_LOOT"
		end
		if candidateCount > 0 then
			encodedCandidates = {}
			for i = 1, candidateCount do
				local candidate = source.candidates[i]
				if not closedMap(candidate, LOOT_SOURCE_CANDIDATE_FIELDS) then
					return nil, "NON_RECONSTRUCTIBLE_LIVE_LOOT"
				end
				encodedCandidates[i] = {
					compactSlot(candidate.name),
					compactSlot(candidate.kind),
					compactSlot(candidate.sourceKey),
					compactSlot(candidate.npcId),
				}
			end
		end
	end
	return {
		compactSlot(source.kind),
		compactSlot(source.bossNid),
		compactSlot(source.sourceNpcId),
		compactSlot(source.sourceName),
		compactSlot(source.sourceKey),
		compactSlot(source.openedAt),
		compactSlot(source.snapshotId),
		encodedCandidates,
	}
end

local function decodeLootSource(encoded)
	if encoded == Json.NULL then
		return nil
	end
	if not denseArray(encoded, 8) then
		return nil, "INVALID_MESSAGE_BODY"
	end
	local candidates = encoded[8]
	local decodedCandidates
	if candidates ~= Json.NULL then
		if type(candidates) ~= "table" then
			return nil, "INVALID_MESSAGE_BODY"
		end
		local candidateCount = #candidates
		if candidateCount > MAX_RANGE_EVENTS or not denseArray(candidates, candidateCount) then
			return nil, "INVALID_MESSAGE_BODY"
		end
		if candidateCount > 0 then
			decodedCandidates = {}
			for i = 1, candidateCount do
				local candidate = candidates[i]
				if not denseArray(candidate, 4) then
					return nil, "INVALID_MESSAGE_BODY"
				end
				local decodedCandidate = {}
				for slot = 1, 4 do
					local value = candidate[slot]
					if value ~= Json.NULL and compactScalar(value) == nil then
						return nil, "INVALID_MESSAGE_BODY"
					end
				end
				if candidate[1] ~= Json.NULL then
					decodedCandidate.name = candidate[1]
				end
				if candidate[2] ~= Json.NULL then
					decodedCandidate.kind = candidate[2]
				end
				if candidate[3] ~= Json.NULL then
					decodedCandidate.sourceKey = candidate[3]
				end
				if candidate[4] ~= Json.NULL then
					decodedCandidate.npcId = candidate[4]
				end
				decodedCandidates[i] = decodedCandidate
			end
		end
	end
	local decoded = {}
	local names = { "kind", "bossNid", "sourceNpcId", "sourceName", "sourceKey", "openedAt", "snapshotId" }
	for i = 1, #names do
		local value = encoded[i]
		if value ~= Json.NULL and compactScalar(value) == nil then
			return nil, "INVALID_MESSAGE_BODY"
		end
		if value ~= Json.NULL then
			decoded[names[i]] = value
		end
	end
	if decodedCandidates then
		decoded.candidates = decodedCandidates
	end
	return decoded
end

local function itemFactsFromHyperlink(itemLink)
	if type(itemLink) ~= "string" then
		return nil
	end
	local color, itemName = match(itemLink, "^|c(%x%x%x%x%x%x%x%x)|Hitem:[%-%d:]+|h%[(.-)%]|h|r$")
	local itemRarity = color and ITEM_RARITY_BY_COLOR[lower(color)] or nil
	local itemId = Item.GetItemIdFromLink(itemLink)
	local itemString = Item.GetItemStringFromLink(itemLink)
	if not itemRarity or not itemId or not itemString then
		return nil
	end
	return itemId, itemString, itemName, itemRarity
end

local function compactLiveLoot(event)
	if type(event) ~= "table" or type(event.payload) ~= "table" or type(event.payload.loot) ~= "table" then
		return nil, "NON_RECONSTRUCTIBLE_LIVE_LOOT"
	end
	local loot = event.payload.loot
	if event.eventType ~= "LOOT_ADDED" or not closedMap(loot, LOOT_FIELDS) then
		return nil, "NON_RECONSTRUCTIBLE_LIVE_LOOT"
	end
	local source, sourceReason = encodeLootSource(loot.lootSource)
	if not source then
		return nil, sourceReason
	end
	return {
		event.raidUid,
		event.authorityEpoch,
		event.sequence,
		event.resultDigest,
		loot.lootNid,
		loot.itemLink,
		loot.itemCount,
		loot.looterNid,
		compactSlot(loot.rollType),
		loot.rollValue,
		compactSlot(loot.rollSessionId),
		loot.bossNid,
		loot.time,
		compactSlot(loot.source),
		compactSlot(loot.itemTexture),
		source,
	}
end

local function reconstructLiveLoot(encoded)
	if not denseArray(encoded, 16) then
		return nil, "INVALID_MESSAGE_BODY"
	end
	if
		not validRaidUid(encoded[1])
		or not exactInteger(encoded[2], 1, MAX_AUTHORITY_EPOCH)
		or not exactInteger(encoded[3], 1, MAX_SEQUENCE)
		or not validDigest(encoded[4])
		or not exactInteger(encoded[5], 1, MAX_SEQUENCE)
		or type(encoded[6]) ~= "string"
		or not exactInteger(encoded[7], 1, MAX_SEQUENCE)
		or not exactInteger(encoded[8], 1, MAX_SEQUENCE)
		or (encoded[9] ~= Json.NULL and not exactInteger(encoded[9], 0, 9))
		or not finiteNumber(encoded[10], 0, MAX_SEQUENCE)
		or (encoded[11] ~= Json.NULL and type(encoded[11]) ~= "string")
		or not exactInteger(encoded[12], 0, MAX_SEQUENCE)
		or not exactInteger(encoded[13], 1, 9999999999)
		or (encoded[14] ~= Json.NULL and type(encoded[14]) ~= "string")
		or (encoded[15] ~= Json.NULL and type(encoded[15]) ~= "string")
		or (encoded[16] ~= Json.NULL and type(encoded[16]) ~= "table")
	then
		return nil, "INVALID_MESSAGE_BODY"
	end
	local itemId, itemString, itemName, itemRarity = itemFactsFromHyperlink(encoded[6])
	if not itemId then
		return nil, "INVALID_MESSAGE_BODY"
	end
	local lootSource, sourceReason = decodeLootSource(encoded[16])
	if sourceReason then
		return nil, sourceReason
	end
	local loot = {
		lootNid = encoded[5],
		itemId = itemId,
		itemName = itemName,
		itemString = itemString,
		itemLink = encoded[6],
		itemRarity = itemRarity,
		itemCount = encoded[7],
		looterNid = encoded[8],
		bossNid = encoded[12],
		time = encoded[13],
	}
	if encoded[9] ~= Json.NULL then
		loot.rollType = encoded[9]
	end
	loot.rollValue = encoded[10]
	if encoded[11] ~= Json.NULL then
		loot.rollSessionId = encoded[11]
	end
	if encoded[14] ~= Json.NULL then
		loot.source = encoded[14]
	end
	if encoded[15] ~= Json.NULL then
		loot.itemTexture = encoded[15]
	end
	if lootSource then
		loot.lootSource = lootSource
	end
	local event = {
		raidUid = encoded[1],
		authorityEpoch = encoded[2],
		sequence = encoded[3],
		eventUid = RaidEvents.BuildEventUid(encoded[1], encoded[2], encoded[3]),
		eventType = "LOOT_ADDED",
		payload = { loot = loot },
		resultDigest = encoded[4],
	}
	return event
end

local function encodeLiveLootBody(event)
	local compact, compactReason = compactLiveLoot(event)
	if not compact then
		return nil, compactReason
	end
	local reconstructed, reconstructedReason = reconstructLiveLoot(compact)
	if not reconstructed or not deepEqual(event, reconstructed) then
		return nil, reconstructedReason or "NON_RECONSTRUCTIBLE_LIVE_LOOT"
	end
	return encodeJson(compact)
end

local function decodeLiveLootBody(text)
	local compact, reason = Protocol.DecodeBody(text)
	if not compact then
		return nil, reason
	end
	local event, eventReason = reconstructLiveLoot(compact)
	if not event then
		return nil, eventReason
	end
	return { event = event }
end

local function encodeLiveLootPartBody(body)
	return encodeJson({
		body.raidUid,
		body.authorityEpoch,
		body.sequence,
		body.partIndex,
		body.partCount,
		body.chunk,
	})
end

local function decodeLiveLootPartBody(text)
	local compact, reason = Protocol.DecodeBody(text)
	if not compact then
		return nil, reason
	end
	if not denseArray(compact, 6) then
		return nil, "INVALID_MESSAGE_BODY"
	end
	return {
		raidUid = compact[1],
		authorityEpoch = compact[2],
		sequence = compact[3],
		partIndex = compact[4],
		partCount = compact[5],
		chunk = compact[6],
	}
end

local function encodeBodyForKind(kind, body)
	if kind == "LIVE_LOOT" then
		return encodeLiveLootBody(body.event)
	elseif kind == "LIVE_LOOT_PART" then
		return encodeLiveLootPartBody(body)
	end
	return Protocol.EncodeBody(body)
end

local function decodeBodyForKind(kind, text)
	if kind == "LIVE_LOOT" then
		return decodeLiveLootBody(text)
	elseif kind == "LIVE_LOOT_PART" then
		return decodeLiveLootPartBody(text)
	end
	return Protocol.DecodeBody(text)
end

Protocol.VERSION = 4

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

function Protocol.EncodeLiveLootPayload(event)
	return encodeLiveLootBody(event)
end

function Protocol.DecodeLiveLootPayload(text)
	local body, reason = decodeLiveLootBody(text)
	if not body then
		return nil, reason
	end
	local valid, validationReason = validateBody("LIVE_LOOT", body)
	if not valid then
		return nil, validationReason
	end
	return body.event
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
	local encodedBody, encodeReason = encodeBodyForKind(kind, body)
	if not encodedBody then
		return nil, encodeReason
	end
	local message = Payload.PackFields("\t", WIRE_MARKER, kind, requestId, target, encodedBody)
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
	if count ~= 5 or fields[1] ~= WIRE_MARKER then
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
	local body, reason = decodeBodyForKind(kind, fields[5])
	if not body then
		return nil, reason
	end
	local valid, validationReason = validateBody(kind, body)
	if not valid then
		return nil, validationReason
	end
	return { kind = kind, requestId = fields[3], target = fields[4], body = body }
end
