-- ----- RMA Lua Contract ----- --
-- deps: addon.Comms, addon.Services.Reserves, addon.Services.Raid, addon.Strings
-- shared: addon.Services.Reserves._Sync
-- exports: R5 reserves metadata and canonical transfer synchronization
-- events: handles RMAResSync addon-message traffic

local addon = select(2, ...)
local L = addon.L
local Comms = addon.Comms
local Services = addon.Services
local Strings = addon.Strings

local floor, ceil = math.floor, math.ceil
local pairs, tostring, tonumber, type = pairs, tostring, tonumber, type
local tconcat = table.concat
local _G = _G
local UnitName = assert(_G.UnitName, "Reserves sync unit name API is not initialized")
local GetTime = assert(_G.GetTime, "Reserves sync time API is not initialized")

addon.Services.EnsureNamespace("Reserves")
local module = Services.Reserves
module._Sync = module._Sync or {}
local Sync = module._Sync

local Payload = assert(Comms.Payload, "Comms payload helpers are not initialized")
local QueueAddonMessage = assert(Comms.QueueAddonMessage, "Reserves sync direct transport is not initialized")
local QueueAddonMessages = assert(Comms.QueueAddonMessages, "Reserves sync batch transport is not initialized")
local SendAddonBatch = assert(Comms.SendAddonBatch, "Reserves sync group transport is not initialized")
local NormalizeLower = assert(Strings.NormalizeLower, "Reserves sync player normalizer is not initialized")
local Raid = assert(Services.Raid, "Reserves sync raid service is not initialized")
local GetPlayerRoleState = assert(Raid.GetPlayerRoleState, "Reserves sync raid-role resolver is not initialized")
local IsGroupMember = assert(Raid.IsGroupMember, "Reserves sync group-membership resolver is not initialized")
local IsReservesAuthority = assert(Raid.IsReservesAuthority, "Reserves sync authority resolver is not initialized")

local PREFIX = "RMAResSync"
local WIRE_VERSION = 5
local MAX_MESSAGE_BYTES = 243
local MSG_META_REQ = "META_REQ"
local MSG_META_ACK = "META_ACK"
local MSG_DATA_REQ = "DATA_REQ"
local MSG_DATA_CHUNK = "DATA_CHUNK"
local MSG_DATA_DONE = "DATA_DONE"
local MSG_DATA_ERR = "DATA_ERR"
local MAX_CHUNK_SIZE = 220
local INCOMING_TTL_SECONDS = 180
local MAX_INCOMING_CHUNKS = 64
local MAX_OUTGOING_CHUNKS = MAX_INCOMING_CHUNKS
local MAX_INCOMING_BYTES = 24000
local MAX_META_PLAYERS = 2048
local MAX_META_ENTRIES = 4096
local MAX_PENDING_REQUESTS = 32
local MAX_INCOMING_ASSEMBLIES = 16
local MAX_INCOMING_PER_SENDER = 4
local MAX_REQUEST_SEQUENCE = 999999

local MESSAGE_KINDS = {
	[MSG_META_REQ] = true,
	[MSG_META_ACK] = true,
	[MSG_DATA_REQ] = true,
	[MSG_DATA_CHUNK] = true,
	[MSG_DATA_DONE] = true,
	[MSG_DATA_ERR] = true,
}

Sync._incoming = Sync._incoming or {}
Sync._pendingRequests = Sync._pendingRequests or {}
Sync._nextRequestId = Sync._nextRequestId or 0

local normalizeSender = assert(Comms.NormalizeSender, "Reserves sync sender normalizer is not initialized")

local function ensurePrefix()
	Comms.RegisterPrefixIfAvailable(PREFIX)
end

local function getIncomingNow()
	return GetTime()
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
	for key in pairs(schema) do
		if value[key] == nil then
			return nil
		end
	end
	return true
end

local function parseBoundedCount(value, maximum)
	if type(value) ~= "number" or value < 0 or value ~= floor(value) or value > maximum then
		return nil
	end
	return value
end

local function validRequestId(value)
	return type(value) == "string" and value ~= "" and #value <= 32
end

local function encodeMessage(kind, requestId, target, body)
	local message, reason = Payload.Serialize({ 5, kind, requestId or false, target or false, body or {} })
	if not message then
		return nil, reason
	end
	if #message > MAX_MESSAGE_BYTES then
		return nil, "MESSAGE_TOO_LARGE"
	end
	return message
end

local function queueAlert(kind, requestId, target, body)
	local message, reason = encodeMessage(kind, requestId, target, body)
	if not message then
		return false, reason
	end
	if type(target) == "string" and target ~= "" then
		return QueueAddonMessage(PREFIX, message, "WHISPER", target, { priority = "ALERT" })
	end
	return SendAddonBatch(PREFIX, { message }, nil, { priority = "ALERT" })
end

local function canProvideReserves()
	if not (module.IsLocalDataAvailable and module:IsLocalDataAvailable()) then
		return false
	end
	local role = GetPlayerRoleState(Raid) or {}
	return role.isMasterLooter == true or role.isLeader == true or role.isAssistant == true
end

local function sendError(target, requestId, reason)
	return queueAlert(MSG_DATA_ERR, requestId, target, { reason = tostring(reason or "unknown") })
end

local function shouldRequestRemoteData(remoteChecksum, remoteMode)
	local checksum = tostring(remoteChecksum or "")
	if checksum == "" or module:IsLocalDataAvailable() then
		return false
	end
	local localMeta = module.GetSyncMetadata and module:GetSyncMetadata() or nil
	return not (localMeta and localMeta.checksum == checksum and localMeta.mode == remoteMode)
end

local function requestDataFrom(target, requestId, checksum)
	if target == "" then
		return false
	end
	local queued = queueAlert(MSG_DATA_REQ, requestId, target, { checksum = checksum })
	if not queued then
		return false
	end
	addon:info(L.MsgReservesSyncDataRequested)
	return true
end

local function getPendingRequest(requestId)
	return Sync._pendingRequests[requestId]
end

local function clearPendingRequest(requestId)
	local pending = Sync._pendingRequests[requestId]
	if type(pending) == "table" and type(pending.source) == "string" then
		Sync._incoming[pending.source .. ":" .. requestId] = nil
	end
	Sync._pendingRequests[requestId] = nil
end

local function countPendingRequests()
	local count = 0
	for _ in pairs(Sync._pendingRequests) do
		count = count + 1
	end
	return count
end

local function nextRequestId()
	local sequence = floor(tonumber(Sync._nextRequestId) or 0)
	if sequence < 0 or sequence > MAX_REQUEST_SEQUENCE then
		sequence = 0
	end
	for _ = 1, MAX_PENDING_REQUESTS + 1 do
		sequence = sequence + 1
		if sequence > MAX_REQUEST_SEQUENCE then
			sequence = 1
		end
		local requestId = "R" .. tostring(sequence)
		if Sync._pendingRequests[requestId] == nil then
			Sync._nextRequestId = sequence
			return requestId
		end
	end
	return nil
end

local function bindPendingRequest(requestId, source, checksum, mode, players, entries)
	local pending = getPendingRequest(requestId)
	if type(pending) ~= "table" or pending.stage ~= "metadata" or pending.source ~= nil then
		return nil
	end
	pending.stage = "data"
	pending.source = source
	pending.checksum = checksum
	pending.mode = mode
	pending.players = players
	pending.entries = entries
	return pending
end

local function cleanupIncoming()
	local now = getIncomingNow()
	for key, pending in pairs(Sync._incoming) do
		local createdAt = type(pending) == "table" and tonumber(pending.createdAt) or nil
		if not createdAt or (now > 0 and (now - createdAt) >= INCOMING_TTL_SECONDS) then
			Sync._incoming[key] = nil
		end
	end
	for requestId, pending in pairs(Sync._pendingRequests) do
		local createdAt = type(pending) == "table" and tonumber(pending.createdAt) or nil
		if not createdAt or (now > 0 and (now - createdAt) >= INCOMING_TTL_SECONDS) then
			clearPendingRequest(requestId)
		end
	end
end

local function canAllocateIncoming(source)
	local globalCount = 0
	local senderCount = 0
	for _, incoming in pairs(Sync._incoming) do
		if type(incoming) == "table" then
			globalCount = globalCount + 1
			if incoming.source == source then
				senderCount = senderCount + 1
			end
		end
	end
	return globalCount < MAX_INCOMING_ASSEMBLIES and senderCount < MAX_INCOMING_PER_SENDER
end

local function acceptIncomingChunk(key, source, requestId, index, count, chunk)
	if
		not parseBoundedCount(index, MAX_INCOMING_CHUNKS)
		or index < 1
		or not parseBoundedCount(count, MAX_INCOMING_CHUNKS)
		or count < 1
		or index > count
		or type(chunk) ~= "string"
		or chunk == ""
		or #chunk > MAX_CHUNK_SIZE
	then
		Sync._incoming[key] = nil
		return nil
	end
	local incoming = Sync._incoming[key]
	if type(incoming) == "table" and incoming.total ~= count then
		Sync._incoming[key] = nil
		return nil
	end
	if type(incoming) == "table" and incoming.chunks[index] ~= nil then
		if incoming.chunks[index] == chunk then
			return incoming
		end
		Sync._incoming[key] = nil
		return nil
	end
	if type(incoming) ~= "table" then
		if not canAllocateIncoming(source) then
			return nil
		end
		incoming = {
			total = count,
			chunks = {},
			chunkBytes = {},
			createdAt = getIncomingNow(),
			bytes = 0,
			source = source,
			requestId = requestId,
		}
		Sync._incoming[key] = incoming
	end
	local nextBytes = incoming.bytes + #chunk
	if nextBytes > MAX_INCOMING_BYTES then
		Sync._incoming[key] = nil
		return nil
	end
	incoming.chunks[index] = chunk
	incoming.chunkBytes[index] = #chunk
	incoming.bytes = nextBytes
	return incoming
end

local function buildTransfer(data, mode)
	local projection, reason = module.BuildCanonicalProjection(data)
	if not projection then
		return nil, reason
	end
	local transfer = { mode = mode == "plus" and "plus" or "multi", players = {} }
	for i = 1, #projection do
		local sourcePlayer = projection[i]
		local player = { name = sourcePlayer.name, rows = {} }
		transfer.players[i] = player
		for j = 1, #sourcePlayer.rows do
			local sourceRow = sourcePlayer.rows[j]
			player.rows[j] = {
				rawID = sourceRow.rawID,
				quantity = sourceRow.quantity,
				plus = sourceRow.plus,
				class = sourceRow.class,
				spec = sourceRow.spec,
				note = sourceRow.note,
				source = sourceRow.source,
			}
		end
	end
	return transfer
end

local TRANSFER_FIELDS = { mode = true, players = true }
local PLAYER_FIELDS = { name = true, rows = true }
local ROW_FIELDS = {
	rawID = true,
	quantity = true,
	plus = true,
	class = true,
	spec = true,
	note = true,
	source = true,
}

local function parseTransfer(transfer)
	if not closedMap(transfer, TRANSFER_FIELDS) or (transfer.mode ~= "multi" and transfer.mode ~= "plus") then
		return nil, "invalid_schema"
	end
	local players = transfer.players
	local playerCount = type(players) == "table" and #players or 0
	if not denseArray(players, playerCount) or playerCount > MAX_META_PLAYERS then
		return nil, "invalid_schema"
	end
	local reserves = {}
	local entryCount = 0
	for i = 1, playerCount do
		local player = players[i]
		if not closedMap(player, PLAYER_FIELDS) or type(player.name) ~= "string" or player.name == "" then
			return nil, "invalid_schema"
		end
		local key = NormalizeLower(player.name, true)
		local rowCount = type(player.rows) == "table" and #player.rows or 0
		if not key or key == "" or reserves[key] or rowCount < 1 or not denseArray(player.rows, rowCount) then
			return nil, "invalid_schema"
		end
		local container = { playerNameDisplay = player.name, reserves = {} }
		reserves[key] = container
		for j = 1, rowCount do
			local row = player.rows[j]
			if not closedMap(row, ROW_FIELDS) then
				return nil, "invalid_schema"
			end
			container.reserves[j] = {
				rawID = row.rawID,
				quantity = row.quantity,
				plus = row.plus,
				class = row.class,
				spec = row.spec,
				note = row.note,
				source = row.source,
			}
			entryCount = entryCount + 1
			if entryCount > MAX_META_ENTRIES then
				return nil, "invalid_schema"
			end
		end
	end
	local projection, reason = module.BuildCanonicalProjection(reserves)
	if not projection then
		return nil, reason or "invalid_schema"
	end
	return reserves, transfer.mode, playerCount, entryCount
end

local function sendMetadata(target, requestId)
	if not canProvideReserves() then
		sendError(target, requestId, "no_data")
		return false
	end
	local _, meta = Sync:GetPayload()
	return queueAlert(MSG_META_ACK, requestId, target, {
		checksum = meta and meta.checksum or "",
		mode = meta and meta.mode or "multi",
		players = meta and meta.players or 0,
		entries = meta and meta.entries or 0,
		source = normalizeSender(UnitName("player")),
	})
end

local function buildChunkMessages(requestId, target, encoded)
	for chunkBytes = MAX_CHUNK_SIZE, 1, -1 do
		local count = ceil(#encoded / chunkBytes)
		if count > MAX_OUTGOING_CHUNKS then
			return nil, "payload_too_large"
		end
		local messages = {}
		local valid = true
		for index = 1, count do
			local chunk = string.sub(encoded, (index - 1) * chunkBytes + 1, index * chunkBytes)
			local message, reason = encodeMessage(MSG_DATA_CHUNK, requestId, target, {
				index = index,
				count = count,
				chunk = chunk,
			})
			if not message then
				if reason ~= "MESSAGE_TOO_LARGE" then
					return nil, reason
				end
				valid = false
				break
			end
			messages[index] = message
		end
		if valid then
			return messages
		end
	end
	return nil, "payload_too_large"
end

local function sendData(target, requestId)
	if not canProvideReserves() then
		sendError(target, requestId, "no_data")
		return false
	end
	local data, meta = Sync:GetPayload()
	local transfer, transferReason = buildTransfer(data, meta and meta.mode or "multi")
	if not transfer then
		sendError(target, requestId, transferReason or "invalid_data")
		return false
	end
	local encoded, encodeReason = Payload.Serialize(transfer)
	if not encoded or #encoded > MAX_INCOMING_BYTES then
		sendError(target, requestId, encodeReason or "payload_too_large")
		return false
	end
	local messages, messageReason = buildChunkMessages(requestId, target, encoded)
	if not messages then
		sendError(target, requestId, messageReason)
		return false
	end
	local queueName = PREFIX .. ":WHISPER:" .. string.lower(tostring(normalizeSender(target) or target))
	local queued = QueueAddonMessages(PREFIX, messages, "WHISPER", target, {
		priority = "BULK",
		queueName = queueName,
	})
	if not queued then
		return false
	end
	return queueAlert(MSG_DATA_DONE, requestId, target, { checksum = meta and meta.checksum or "" })
end

local function applyIncoming(sender, requestId, checksum)
	local key = sender .. ":" .. requestId
	local incoming = Sync._incoming[key]
	local request = getPendingRequest(requestId)
	if type(incoming) ~= "table" or type(request) ~= "table" then
		return false, "missing_request"
	end
	local parts = {}
	for i = 1, incoming.total do
		if incoming.chunks[i] == nil then
			return false, "missing_chunk"
		end
		parts[i] = incoming.chunks[i]
	end
	local transfer = Payload.Deserialize(tconcat(parts, ""))
	if type(transfer) ~= "table" then
		Sync._incoming[key] = nil
		return false, "decode_failed"
	end
	local reserves, mode, players, entries = parseTransfer(transfer)
	if not reserves then
		Sync._incoming[key] = nil
		return false, mode
	end
	if mode ~= request.mode then
		Sync._incoming[key] = nil
		return false, "mode_mismatch"
	end
	if players ~= request.players or entries ~= request.entries then
		Sync._incoming[key] = nil
		return false, "count_mismatch"
	end
	local computedChecksum = module.BuildCanonicalChecksum(reserves)
	if tostring(computedChecksum or "") ~= checksum then
		Sync._incoming[key] = nil
		return false, "checksum_mismatch"
	end
	local ok, reason = Sync:SetSyncedData(reserves, { source = sender, checksum = checksum, mode = mode })
	Sync._incoming[key] = nil
	return ok, reason
end

local function finishIncomingIfReady(sender, requestId)
	local pending = getPendingRequest(requestId)
	if type(pending) ~= "table" or pending.source ~= sender or type(pending.doneChecksum) ~= "string" then
		return false, "not_ready"
	end
	local ok, reason = applyIncoming(sender, requestId, pending.doneChecksum)
	if not ok and (reason == "missing_request" or reason == "missing_chunk") then
		return false, "not_ready"
	end
	Sync._incoming[sender .. ":" .. requestId] = nil
	clearPendingRequest(requestId)
	if ok then
		addon:info(L.MsgReservesSyncApplied:format(sender))
	else
		addon:warn(L.MsgReservesSyncFailed:format(tostring(reason or "unknown")))
	end
	return ok, reason
end

local function decodeEnvelope(message)
	if type(message) ~= "string" or message == "" or #message > MAX_MESSAGE_BYTES then
		return nil
	end
	local envelope = Payload.Deserialize(message)
	if not denseArray(envelope, 5) or envelope[1] ~= WIRE_VERSION or not MESSAGE_KINDS[envelope[2]] then
		return nil
	end
	if
		not validRequestId(envelope[3])
		or (envelope[4] ~= false and type(envelope[4]) ~= "string")
		or type(envelope[5]) ~= "table"
	then
		return nil
	end
	return envelope[2], envelope[3], envelope[4], envelope[5]
end

local function validTarget(kind, target)
	if kind == MSG_META_REQ then
		return target == false
	end
	if type(target) ~= "string" or target == "" then
		return false
	end
	local wireTarget = string.lower(tostring(normalizeSender(target) or ""))
	local playerTarget = string.lower(tostring(normalizeSender(UnitName("player")) or ""))
	return wireTarget == playerTarget
end

function Sync:RequestMetadata()
	ensurePrefix()
	cleanupIncoming()
	if countPendingRequests() >= MAX_PENDING_REQUESTS then
		return false, "request_capacity"
	end
	local requestId = nextRequestId()
	if not requestId then
		return false, "request_id_unavailable"
	end
	local queued = queueAlert(MSG_META_REQ, requestId, nil, {})
	if not queued then
		addon:warn(L.MsgReservesSyncNotInGroup)
		return false
	end
	Sync._pendingRequests[requestId] = { stage = "metadata", createdAt = getIncomingNow() }
	addon:info(L.MsgReservesSyncRequested)
	return true, requestId
end

function Sync:HandleMessage(prefix, msg, _channel, sender)
	if prefix ~= PREFIX then
		return false
	end
	cleanupIncoming()
	local kind, requestId, target, body = decodeEnvelope(msg)
	if not kind or not validTarget(kind, target) then
		return true
	end
	local rawSource = sender
	local source = normalizeSender(sender)
	if type(source) ~= "string" or source == "" then
		return true
	end
	if kind == MSG_META_REQ or kind == MSG_DATA_REQ then
		if not IsGroupMember(Raid, rawSource) then
			return true
		end
	elseif not IsReservesAuthority(Raid, rawSource) then
		return true
	end

	if kind == MSG_META_REQ then
		if next(body) ~= nil then
			return true
		end
		sendMetadata(source, requestId)
		return true
	end

	if kind == MSG_DATA_REQ then
		if not closedMap(body, { checksum = true }) or type(body.checksum) ~= "string" or #body.checksum > 64 then
			return true
		end
		sendData(source, requestId)
		return true
	end

	if kind == MSG_META_ACK then
		local pending = getPendingRequest(requestId)
		if type(pending) ~= "table" or pending.stage ~= "metadata" or pending.source ~= nil then
			return true
		end
		if not closedMap(body, { checksum = true, mode = true, players = true, entries = true, source = true }) then
			return true
		end
		local checksum = type(body.checksum) == "string" and body.checksum or ""
		local players = parseBoundedCount(body.players, MAX_META_PLAYERS)
		local entries = parseBoundedCount(body.entries, MAX_META_ENTRIES)
		if
			not checksum:match("^C2:%d+:%d+$")
			or #checksum > 64
			or (body.mode ~= "multi" and body.mode ~= "plus")
			or not players
			or not entries
			or type(body.source) ~= "string"
		then
			return true
		end
		addon:info(L.MsgReservesSyncMeta:format(source, checksum, body.mode, players, entries))
		if shouldRequestRemoteData(checksum, body.mode) then
			if bindPendingRequest(requestId, source, checksum, body.mode, players, entries) then
				if not requestDataFrom(source, requestId, checksum) then
					clearPendingRequest(requestId)
				end
			end
		else
			clearPendingRequest(requestId)
		end
		return true
	end

	if kind == MSG_DATA_CHUNK then
		if not closedMap(body, { index = true, count = true, chunk = true }) then
			return true
		end
		local pending = getPendingRequest(requestId)
		if not pending or pending.source ~= source then
			return true
		end
		local key = source .. ":" .. requestId
		if not acceptIncomingChunk(key, source, requestId, body.index, body.count, body.chunk) then
			Sync._incoming[key] = nil
			clearPendingRequest(requestId)
		elseif pending.doneChecksum then
			finishIncomingIfReady(source, requestId)
		end
		return true
	end

	if kind == MSG_DATA_DONE then
		if not closedMap(body, { checksum = true }) or type(body.checksum) ~= "string" then
			return true
		end
		local pending = getPendingRequest(requestId)
		local key = source .. ":" .. requestId
		if not pending then
			Sync._incoming[key] = nil
			return true
		end
		if pending.source ~= source then
			return true
		end
		if body.checksum ~= pending.checksum then
			Sync._incoming[key] = nil
			clearPendingRequest(requestId)
			return true
		end
		pending.doneChecksum = body.checksum
		finishIncomingIfReady(source, requestId)
		return true
	end

	if kind == MSG_DATA_ERR then
		if not closedMap(body, { reason = true }) or type(body.reason) ~= "string" then
			return true
		end
		local pending = getPendingRequest(requestId)
		if not pending or pending.source ~= source then
			return true
		end
		clearPendingRequest(requestId)
		Sync._incoming[source .. ":" .. requestId] = nil
		addon:warn(L.MsgReservesSyncFailed:format(body.reason))
		return true
	end

	return true
end
