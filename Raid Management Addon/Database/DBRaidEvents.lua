local addon = select(2, ...)
local Diag = addon.Diag
local DB = addon.DB
local LibDeflate = assert(LibStub("LibDeflate"), Diag.A.LibDeflateNotInitialized)

DB.RaidEvents = DB.RaidEvents or {}
local Events = DB.RaidEvents

local EVENT_TYPES = {
	RAID_CREATED = true,
	RAID_METADATA_UPDATED = true,
	PLAYER_UPDATED = true,
	PLAYER_DEPARTED = true,
	BOSS_UPDATED = true,
	ATTENDANCE_UPDATED = true,
	LOOT_ADDED = true,
	LOOT_UPDATED = true,
	LOOT_DELETED = true,
	RAID_CONCLUDED = true,
}

local MAX_CANONICAL_BYTE_COUNT = 999999999
local RAID_METADATA_FIELDS = {
	zone = true,
	size = true,
	difficulty = true,
}

local function exactInteger(value, minimum, maximum)
	if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
		return nil
	end
	if value ~= math.floor(value) or value < minimum or value > maximum then
		return nil
	end
	return value
end

local function normalizeIdentity(value)
	if type(value) ~= "string" then
		return nil
	end
	local identity = string.lower(string.match(value, "^%s*(.-)%s*$") or "")
	if #identity < 1 or #identity > 96 or string.find(identity, "[^%w%-_%.@]", 1) then
		return nil
	end
	return identity
end

local function normalizeToken(value, maximumBytes)
	if type(value) ~= "string" or #value < 1 or #value > maximumBytes then
		return nil
	end
	if string.find(value, "[^%w%-_]", 1) then
		return nil
	end
	return value
end

local function encodeNumber(value)
	if value ~= value or value == math.huge or value == -math.huge then
		return nil, "UNSUPPORTED_NUMBER"
	end
	if value == 0 then
		return "d1:0"
	end
	local encoded
	if value == math.floor(value) then
		encoded = string.format("%.0f", value)
	else
		encoded = string.format("%.17g", value)
	end
	return "d" .. #encoded .. ":" .. encoded
end

local function canonicalEncode(value)
	local active = {}

	local function encode(current, scalarOnly)
		local valueType = type(current)
		if valueType == "nil" then
			return "n"
		elseif valueType == "boolean" then
			return current and "b1" or "b0"
		elseif valueType == "number" then
			return encodeNumber(current)
		elseif valueType == "string" then
			return "s" .. #current .. ":" .. current
		elseif valueType ~= "table" then
			return nil, "UNSUPPORTED_VALUE_TYPE"
		end

		if scalarOnly then
			return nil, "UNSUPPORTED_MAP_KEY"
		end
		if active[current] then
			return nil, "CYCLIC_VALUE"
		end
		active[current] = true

		local count, maximum, dense = 0, 0, true
		for key in pairs(current) do
			count = count + 1
			if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then
				dense = false
			elseif key > maximum then
				maximum = key
			end
		end
		dense = dense and maximum == count

		local parts = {}
		if dense then
			parts[1] = "a" .. count .. ":"
			for i = 1, count do
				local item, reason = encode(current[i], false)
				if not item then
					active[current] = nil
					return nil, reason
				end
				parts[#parts + 1] = item
			end
		else
			local entries = {}
			for key, itemValue in pairs(current) do
				local encodedKey, keyReason = encode(key, true)
				if not encodedKey then
					active[current] = nil
					return nil, keyReason
				end
				local encodedValue, valueReason = encode(itemValue, false)
				if not encodedValue then
					active[current] = nil
					return nil, valueReason
				end
				entries[#entries + 1] = encodedKey .. encodedValue
			end
			table.sort(entries)
			parts[1] = "m" .. #entries .. ":"
			for i = 1, #entries do
				parts[#parts + 1] = entries[i]
			end
		end

		active[current] = nil
		return table.concat(parts)
	end

	return encode(value, false)
end

local function deepCopy(value, seen)
	if type(value) ~= "table" then
		return value
	end
	seen = seen or {}
	if seen[value] then
		return seen[value]
	end
	local copy = {}
	seen[value] = copy
	for key, item in pairs(value) do
		copy[deepCopy(key, seen)] = deepCopy(item, seen)
	end
	return copy
end

local function validRaidUid(value)
	return type(value) == "string" and #value >= 1 and #value <= 40 and string.find(value, "[^!-~]", 1) == nil
end

local function validEntity(entity, nidField)
	if type(entity) ~= "table" or not exactInteger(entity[nidField], 1, 999999999) then
		return nil
	end
	return canonicalEncode(entity)
end

local function validateEntityCollection(collection, nidField)
	if collection == nil then
		return true
	end
	if type(collection) ~= "table" then
		return nil
	end
	local seen = {}
	for _, entity in pairs(collection) do
		local nid = type(entity) == "table" and exactInteger(entity[nidField], 1, 999999999) or nil
		if not nid or seen[nid] then
			return nil
		end
		seen[nid] = true
	end
	return true
end

local function validPayloadTable(payload)
	if type(payload) ~= "table" then
		return nil, "INVALID_EVENT_PAYLOAD"
	end
	local encoded, reason = canonicalEncode(payload)
	if not encoded then
		return nil, reason
	end
	return true
end

local function validRaidMetadata(metadata)
	if type(metadata) ~= "table" then
		return nil
	end
	for key in pairs(metadata) do
		if type(key) ~= "string" or not RAID_METADATA_FIELDS[key] then
			return nil
		end
	end
	return true
end

local function validResultDigest(value)
	if type(value) ~= "string" then
		return nil
	end
	local checksum, byteCountText = string.match(value, "^([0-9a-f]+):([1-9][0-9]*)$")
	if not checksum or #checksum ~= 8 then
		return nil
	end
	local byteCount = tonumber(byteCountText)
	if not exactInteger(byteCount, 1, MAX_CANONICAL_BYTE_COUNT) or tostring(byteCount) ~= byteCountText then
		return nil
	end
	return true
end

local SCHEMAS = {
	RAID_CREATED = function(payload)
		if type(payload.state) ~= "table" then
			return nil, "INVALID_RAID_STATE"
		end
		if
			not validateEntityCollection(payload.state.players, "playerNid")
			or not validateEntityCollection(payload.state.bossKills, "bossNid")
			or not validateEntityCollection(payload.state.attendance, "playerNid")
			or not validateEntityCollection(payload.state.loot, "lootNid")
		then
			return nil, "INVALID_RAID_STATE"
		end
		return true
	end,
	RAID_METADATA_UPDATED = function(payload)
		if not validRaidMetadata(payload.metadata) then
			return nil, "INVALID_RAID_METADATA"
		end
		return true
	end,
	PLAYER_UPDATED = function(payload)
		if not validEntity(payload.player, "playerNid") then
			return nil, "INVALID_PLAYER"
		end
		return true
	end,
	PLAYER_DEPARTED = function(payload)
		if not exactInteger(payload.playerNid, 1, 999999999) or not exactInteger(payload.leave, 0, 9999999999) then
			return nil, "INVALID_PLAYER_DEPARTURE"
		end
		return true
	end,
	BOSS_UPDATED = function(payload)
		if not validEntity(payload.boss, "bossNid") then
			return nil, "INVALID_BOSS"
		end
		return true
	end,
	ATTENDANCE_UPDATED = function(payload)
		if not validEntity(payload.attendance, "playerNid") then
			return nil, "INVALID_ATTENDANCE"
		end
		return true
	end,
	LOOT_ADDED = function(payload)
		if not validEntity(payload.loot, "lootNid") then
			return nil, "INVALID_LOOT"
		end
		return true
	end,
	LOOT_UPDATED = function(payload)
		if not validEntity(payload.loot, "lootNid") then
			return nil, "INVALID_LOOT"
		end
		return true
	end,
	LOOT_DELETED = function(payload)
		if not exactInteger(payload.lootNid, 1, 999999999) then
			return nil, "INVALID_LOOT_NID"
		end
		return true
	end,
	RAID_CONCLUDED = function(payload)
		if not exactInteger(payload.endTime, 0, 9999999999) then
			return nil, "INVALID_END_TIME"
		end
		return true
	end,
}

local function validateEventAgainstSchemas(event, schemas)
	if type(event) ~= "table" then
		return nil, "INVALID_EVENT"
	end
	if not validRaidUid(event.raidUid) then
		return nil, "INVALID_RAID_UID"
	end
	local epoch = exactInteger(event.authorityEpoch, 1, 999999999)
	local sequence = exactInteger(event.sequence, 1, 999999999)
	if not epoch or not sequence then
		return nil, "INVALID_EVENT_POSITION"
	end
	if event.eventUid ~= Events.BuildEventUid(event.raidUid, epoch, sequence) then
		return nil, "INVALID_EVENT_UID"
	end
	if type(event.eventType) ~= "string" or not schemas[event.eventType] then
		return nil, "UNSUPPORTED_EVENT_TYPE"
	end
	local payloadValid, payloadReason = validPayloadTable(event.payload)
	if not payloadValid then
		return nil, payloadReason
	end
	local schema = SCHEMAS[event.eventType]
	if not schema then
		return nil, "UNSUPPORTED_EVENT_TYPE"
	end
	local valid, reason = schema(event.payload)
	if not valid then
		return nil, reason
	end
	if event.resultDigest ~= nil and not validResultDigest(event.resultDigest) then
		return nil, "INVALID_RESULT_DIGEST"
	end
	return true
end

local function findEntity(collection, nidField, nid)
	if type(collection) ~= "table" then
		return nil, nil, "INVALID_RAID_STATE"
	end
	local foundKey, foundEntity
	local seen = {}
	for key, entity in pairs(collection) do
		local entityNid = type(entity) == "table" and exactInteger(entity[nidField], 1, 999999999) or nil
		if not entityNid or seen[entityNid] then
			return nil, nil, "INVALID_RAID_STATE"
		end
		seen[entityNid] = true
		if entityNid == nid then
			foundKey, foundEntity = key, entity
		end
	end
	return foundKey, foundEntity
end

local function ensureCollection(state, field)
	if state[field] == nil then
		state[field] = {}
	end
	if type(state[field]) ~= "table" then
		return nil
	end
	return state[field]
end

local function sameValue(left, right)
	local leftEncoded = canonicalEncode(left)
	local rightEncoded = canonicalEncode(right)
	return leftEncoded == rightEncoded
end

local REDUCERS = {}

local DISTRIBUTION_AWARD_COUNTER_FIELDS = {
	[1] = "countMS",
	[2] = "countOs",
	[3] = "countSR",
	[4] = "countFree",
}

-- Countable distribution awards carry their counter fact in the existing
-- LOOT_ADDED row, so replicas apply loot and counters as one state change.
local function prepareDistributionAwardCounter(state, lootRow)
	if lootRow.source ~= "DISTRIBUTION_AWARD" then
		return true
	end
	local rollType = exactInteger(lootRow.rollType, 0, 7)
	local itemCount = exactInteger(lootRow.itemCount, 1, 999999999)
	if not rollType or not itemCount then
		return nil, "INVALID_DISTRIBUTION_AWARD"
	end
	local counterField = DISTRIBUTION_AWARD_COUNTER_FIELDS[rollType]
	if not counterField then
		return true
	end
	local looterNid = exactInteger(lootRow.looterNid, 1, 999999999)
	if not looterNid then
		return nil, "INVALID_DISTRIBUTION_AWARD"
	end
	local players = ensureCollection(state, "players")
	if not players then
		return nil, "INVALID_RAID_STATE"
	end
	local _, player, findReason = findEntity(players, "playerNid", looterNid)
	if findReason then
		return nil, findReason
	end
	if not player then
		return nil, "ENTITY_NOT_FOUND"
	end
	local currentCount = exactInteger(player[counterField] or 0, 0, 999999999)
	local nextCount = currentCount and exactInteger(currentCount + itemCount, 0, 999999999) or nil
	if not nextCount then
		return nil, "INVALID_DISTRIBUTION_AWARD_COUNTER"
	end
	return true, player, counterField, nextCount
end

REDUCERS.RAID_CREATED = function(_, payload)
	return deepCopy(payload.state)
end

REDUCERS.RAID_METADATA_UPDATED = function(state, payload)
	local changed = false
	for key, value in pairs(payload.metadata) do
		if key ~= "players" and key ~= "bossKills" and key ~= "attendance" and key ~= "loot" then
			if not sameValue(state[key], value) then
				changed = true
			end
			state[key] = deepCopy(value)
		end
	end
	if not changed then
		return nil, "DUPLICATE_EVENT"
	end
	return state
end

local function upsertEntity(state, field, payloadField, nidField, payload, requireExisting, nextNidField)
	local collection = ensureCollection(state, field)
	if not collection then
		return nil, "INVALID_RAID_STATE"
	end
	local entity = payload[payloadField]
	local index, current, findReason = findEntity(collection, nidField, entity[nidField])
	if findReason then
		return nil, findReason
	end
	if requireExisting and not index then
		return nil, "ENTITY_NOT_FOUND"
	end
	if current and sameValue(current, entity) then
		return nil, "DUPLICATE_EVENT"
	end
	if index then
		collection[index] = deepCopy(entity)
	else
		collection[#collection + 1] = deepCopy(entity)
	end
	if nextNidField and (type(state[nextNidField]) ~= "number" or state[nextNidField] <= entity[nidField]) then
		state[nextNidField] = entity[nidField] + 1
	end
	return state
end

REDUCERS.PLAYER_UPDATED = function(state, payload)
	return upsertEntity(state, "players", "player", "playerNid", payload, false, "nextPlayerNid")
end

REDUCERS.PLAYER_DEPARTED = function(state, payload)
	local players = ensureCollection(state, "players")
	if not players then
		return nil, "INVALID_RAID_STATE"
	end
	local _, player, findReason = findEntity(players, "playerNid", payload.playerNid)
	if findReason then
		return nil, findReason
	end
	if not player then
		return nil, "ENTITY_NOT_FOUND"
	end
	if player.leave == payload.leave then
		return nil, "DUPLICATE_EVENT"
	end
	player.leave = payload.leave
	return state
end

REDUCERS.BOSS_UPDATED = function(state, payload)
	return upsertEntity(state, "bossKills", "boss", "bossNid", payload, false, "nextBossNid")
end

REDUCERS.ATTENDANCE_UPDATED = function(state, payload)
	return upsertEntity(state, "attendance", "attendance", "playerNid", payload, false)
end

REDUCERS.LOOT_ADDED = function(state, payload)
	local loot = ensureCollection(state, "loot")
	if not loot then
		return nil, "INVALID_RAID_STATE"
	end
	local existingIndex, _, findReason = findEntity(loot, "lootNid", payload.loot.lootNid)
	if findReason then
		return nil, findReason
	end
	if existingIndex then
		return nil, "DUPLICATE_ENTITY_NID"
	end
	local counterReady, player, counterField, nextCount = prepareDistributionAwardCounter(state, payload.loot)
	if not counterReady then
		return nil, player
	end
	loot[#loot + 1] = deepCopy(payload.loot)
	if counterField then
		player[counterField] = nextCount
	end
	local nextNid = payload.loot.lootNid + 1
	if type(state.nextLootNid) ~= "number" or state.nextLootNid < nextNid then
		state.nextLootNid = nextNid
	end
	return state
end

REDUCERS.LOOT_UPDATED = function(state, payload)
	return upsertEntity(state, "loot", "loot", "lootNid", payload, true)
end

REDUCERS.LOOT_DELETED = function(state, payload)
	local loot = ensureCollection(state, "loot")
	if not loot then
		return nil, "INVALID_RAID_STATE"
	end
	local index, _, findReason = findEntity(loot, "lootNid", payload.lootNid)
	if findReason then
		return nil, findReason
	end
	if not index then
		return nil, "ENTITY_NOT_FOUND"
	end
	if type(index) == "number" then
		table.remove(loot, index)
	else
		loot[index] = nil
	end
	return state
end

local function validateConclusionState(state)
	if type(state.players) ~= "table" or type(state.attendance) ~= "table" then
		return nil, "INVALID_RAID_STATE"
	end
	for _, player in pairs(state.players) do
		if type(player) ~= "table" then
			return nil, "INVALID_RAID_STATE"
		end
	end
	for _, attendance in pairs(state.attendance) do
		if type(attendance) ~= "table" or type(attendance.segments) ~= "table" then
			return nil, "INVALID_RAID_STATE"
		end
		for _, segment in pairs(attendance.segments) do
			if type(segment) ~= "table" then
				return nil, "INVALID_RAID_STATE"
			end
		end
	end
	return true
end

REDUCERS.RAID_CONCLUDED = function(state, payload)
	local valid, reason = validateConclusionState(state)
	if not valid then
		return nil, reason
	end
	state.endTime = payload.endTime
	for _, player in pairs(state.players or {}) do
		if type(player) == "table" and player.leave == nil then
			player.leave = payload.endTime
		end
	end
	for _, attendance in pairs(state.attendance or {}) do
		for _, segment in pairs(type(attendance) == "table" and attendance.segments or {}) do
			if type(segment) == "table" and segment.endTime == nil then
				segment.endTime = payload.endTime
			end
		end
	end
	return state
end

local function applyEventToCopiedState(state, event)
	if type(state) ~= "table" then
		return nil, "INVALID_RAID_STATE"
	end
	local _, stateReason = canonicalEncode(state)
	if stateReason then
		return nil, stateReason
	end
	if state.endTime ~= nil then
		return nil, "RAID_CONCLUDED"
	end
	local reducer = REDUCERS[event.eventType]
	if not reducer then
		return nil, "UNSUPPORTED_EVENT_TYPE"
	end
	local copiedState = deepCopy(state)
	local nextState, reason = reducer(copiedState, event.payload)
	if not nextState then
		return nil, reason
	end
	return nextState
end

function Events.CreateRaidUid(creatorKey, serverTime, counter, sessionNonce)
	local identity = normalizeIdentity(creatorKey)
	local timestamp = exactInteger(serverTime, 1, 9999999999)
	local ordinal = exactInteger(counter, 1, 999999)
	local nonce = normalizeToken(sessionNonce, 12)
	if not identity or not timestamp or not ordinal or not nonce then
		return nil, "INVALID_RAID_UID_INPUT"
	end
	local seed = identity .. ":" .. timestamp .. ":" .. ordinal .. ":" .. nonce
	local checksum = string.format("%08x", LibDeflate:Adler32(seed))
	return "r:" .. timestamp .. ":" .. ordinal .. ":" .. checksum
end

function Events.BuildEventUid(raidUid, epoch, sequence)
	return tostring(raidUid) .. ":" .. tostring(epoch) .. ":" .. tostring(sequence)
end

function Events.DigestState(state)
	local encoded, reason = canonicalEncode(state)
	if not encoded then
		return nil, reason
	end
	return string.format("%08x:%d", LibDeflate:Adler32(encoded), #encoded)
end

function Events.ValidateEvent(event)
	return validateEventAgainstSchemas(event, EVENT_TYPES)
end

function Events.Apply(state, event)
	local valid, reason = Events.ValidateEvent(event)
	if not valid then
		return nil, reason
	end
	return applyEventToCopiedState(state, event)
end
