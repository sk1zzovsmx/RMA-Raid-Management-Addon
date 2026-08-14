-- ----- RMA Lua Contract ----- --
-- deps: addon.DB.SyncProtocol, addon.Comms, addon.Timer, LibStub("LibDeflate")
-- shared: addon.DB.SyncSession
-- exports: bounded request correlation, transfer chunking, assembly, expiry, and results
-- events: none

local addon = select(2, ...)
local DB = addon.DB
local Protocol = assert(DB.SyncProtocol, "Sync protocol dependency is not initialized")
local Comms = assert(addon.Comms, "Comms dependency is not initialized")
local Timer = assert(addon.Timer, "Timer dependency is not initialized")
local LibDeflate = assert(LibStub("LibDeflate"), "LibDeflate is not initialized")

DB.SyncSession = DB.SyncSession or {}
local Session = DB.SyncSession

local type, tostring, tonumber, pairs = type, tostring, tonumber, pairs
local floor, ceil = math.floor, math.ceil
local concat = table.concat
local sub = string.sub
local byte = string.byte
local pcall = pcall
local GetTime = assert(_G.GetTime, "Sync session clock is not initialized")
local UnitName = assert(_G.UnitName, "Sync session player identity is not initialized")

local PREFIX = "RMARaidSync"
local REQUEST_TTL_SECONDS = 30
local ASSEMBLY_TTL_SECONDS = 45
local MAX_CHUNK_BYTES = 220
local MAX_CHUNKS = 256
local MAX_ENCODED_BYTES = MAX_CHUNK_BYTES * MAX_CHUNKS
local MAX_ASSEMBLIES = 64
local MAX_ASSEMBLIES_PER_SENDER = 8
local MAX_DECODED_BYTES = 65536
local RATE_WINDOW_SECONDS = 30
local MAX_INCOMING_REQUESTS_PER_SENDER = 6
local MAX_OUTGOING_OPERATIONS_PER_TARGET = 4
local MAX_RATE_PEERS = 128

local REQUEST_PENDING = "pending"
local REQUEST_ASSEMBLING = "assembling"
local REQUEST_COMPLETE = "complete"
local REQUEST_FAILED = "failed"

Session._pendingRequests = Session._pendingRequests or {}
Session._assemblies = Session._assemblies or {}
Session._assemblyCount = tonumber(Session._assemblyCount) or 0
Session._assembliesBySender = Session._assembliesBySender or {}
Session._nextRequestId = tonumber(Session._nextRequestId) or -1
Session._incomingRates = Session._incomingRates or {}
Session._outgoingRates = Session._outgoingRates or {}

Timer.BindMixin(Session, "Database/DBSyncSession")

local completeRequest

local RESPONSE_METADATA_FIELDS = {
	RANGE_DATA = { "raidUid", "authorityEpoch", "fromSequence", "toSequence" },
	SNAP_DATA = { "raidUid", "authorityEpoch", "sequence" },
}

local EXPECTED_RESPONSE_KIND = {
	RANGE_REQ = "RANGE_DATA",
	SNAP_REQ = "SNAP_DATA",
}

local function normalizeSender(sender)
	local normalized = Comms.NormalizeSender(sender)
	if type(normalized) ~= "string" or normalized == "" then
		return nil
	end
	return string.lower(normalized)
end

local function localPlayerName()
	return normalizeSender(UnitName("player"))
end

local function pruneRateMap(rateMap, now)
	local cutoff = now - RATE_WINDOW_SECONDS
	local peerCount = 0
	for peer, timestamps in pairs(rateMap) do
		local writeIndex = 1
		for i = 1, #timestamps do
			if timestamps[i] > cutoff then
				timestamps[writeIndex] = timestamps[i]
				writeIndex = writeIndex + 1
			end
		end
		for i = writeIndex, #timestamps do
			timestamps[i] = nil
		end
		if writeIndex == 1 then
			rateMap[peer] = nil
		else
			peerCount = peerCount + 1
		end
	end
	return peerCount
end

local function allowRate(rateMap, peer, limit, now)
	local normalizedPeer = normalizeSender(peer)
	if not normalizedPeer then
		return false, "INVALID_TARGET"
	end
	local peerCount = pruneRateMap(rateMap, now)
	local timestamps = rateMap[normalizedPeer]
	if not timestamps then
		if peerCount >= MAX_RATE_PEERS then
			return false, "RATE_CAPACITY"
		end
		timestamps = {}
		rateMap[normalizedPeer] = timestamps
	end
	if #timestamps >= limit then
		return false, "RATE_LIMIT"
	end
	timestamps[#timestamps + 1] = now
	return true, normalizedPeer
end

local function copyExpectedMetadata(responseKind, metadata)
	local fields = RESPONSE_METADATA_FIELDS[responseKind]
	if not fields or type(metadata) ~= "table" then
		return nil
	end
	local copy = {}
	for i = 1, #fields do
		local field = fields[i]
		if metadata[field] == nil then
			return nil
		end
		copy[field] = metadata[field]
	end
	return copy
end

local function metadataMatches(responseKind, expected, actual)
	local fields = RESPONSE_METADATA_FIELDS[responseKind]
	if not fields or type(expected) ~= "table" or type(actual) ~= "table" then
		return false
	end
	for i = 1, #fields do
		local field = fields[i]
		if actual[field] ~= expected[field] then
			return false
		end
	end
	return true
end

local function buildSessionNonce()
	local seed = tostring(UnitName("player") or "")
		.. ":"
		.. tostring(floor((tonumber(GetTime()) or 0) * 1000))
		.. ":"
		.. tostring({})
	local hash = 5381
	for i = 1, #seed do
		hash = ((hash * 33) + byte(seed, i)) % 1000000000
	end
	return tostring(hash)
end

local function nextRequestId()
	local nonce = Session._requestSessionNonce
	if type(nonce) ~= "string" then
		nonce = buildSessionNonce()
		Session._requestSessionNonce = nonce
	end
	local counter = floor(tonumber(Session._nextRequestId) or -1)
	for _ = 1, 1024 do
		counter = (counter + 1) % 1000000
		local candidate = nonce .. "-" .. tostring(counter)
		if #candidate <= 64 and Session._pendingRequests[candidate] == nil then
			Session._nextRequestId = counter
			return candidate
		end
	end
	return nil, "REQUEST_ID_EXHAUSTED"
end

local function assemblyKey(sender, requestId)
	return sender .. "\t" .. requestId
end

local function releaseAssembly(assembly)
	if not assembly or assembly.released then
		return
	end
	assembly.released = true
	Session._assemblies[assembly.key] = nil
	Session._assemblyCount = Session._assemblyCount - 1
	if Session._assemblyCount < 0 then
		Session._assemblyCount = 0
	end
	local senderCount = (Session._assembliesBySender[assembly.sender] or 1) - 1
	if senderCount > 0 then
		Session._assembliesBySender[assembly.sender] = senderCount
	else
		Session._assembliesBySender[assembly.sender] = nil
	end
end

local function scheduleRequestTimer(request)
	request.timer = Session:ScheduleTimer(function()
		Session:Expire(GetTime())
	end, REQUEST_TTL_SECONDS)
	return request.timer ~= nil
end

local function resendRequest(request)
	if request.timer then
		Session:CancelTimer(request.timer)
		request.timer = nil
	end
	local queued, reason = Comms.QueueAddonMessage(PREFIX, request.encodedRequest, "WHISPER", request.target)
	if not queued then
		request.state = REQUEST_FAILED
		return completeRequest(request, false, reason or "SEND_FAILED")
	end
	if not scheduleRequestTimer(request) then
		request.state = REQUEST_FAILED
		return completeRequest(request, false, "TIMER_UNAVAILABLE")
	end
	return true
end

completeRequest = function(request, succeeded, reason)
	if not request or request.completed then
		return false
	end
	request.completed = true
	if request.timer then
		Session:CancelTimer(request.timer)
		request.timer = nil
	end
	Session._pendingRequests[request.requestId] = nil
	if request.assembly then
		releaseAssembly(request.assembly)
		request.assembly = nil
	end
	request.state = succeeded and REQUEST_COMPLETE or REQUEST_FAILED
	local callback = request.callback
	request.callback = nil
	if type(callback) == "function" then
		pcall(callback, succeeded == true, reason, request.resultBody, request)
	end
	return succeeded == true
end

local function failRequest(request, reason)
	if request then
		request.state = REQUEST_FAILED
	end
	completeRequest(request, false, reason)
	return nil, reason
end

local function encodeTransferText(body)
	local serialized, reason = Protocol.EncodeBody(body)
	if not serialized then
		return nil, reason
	end
	if #serialized > MAX_DECODED_BYTES then
		return nil, "TRANSFER_TOO_LARGE"
	end
	local okEncode, encoded = pcall(LibDeflate.EncodeForWoWAddonChannel, LibDeflate, serialized)
	if not okEncode or type(encoded) ~= "string" or encoded == "" then
		return nil, "ENCODE_FAILED"
	end
	if #encoded > MAX_ENCODED_BYTES then
		return nil, "TRANSFER_TOO_LARGE"
	end
	return encoded
end

local function decodeTransferText(encoded)
	if type(encoded) ~= "string" or #encoded > MAX_ENCODED_BYTES then
		return nil, "TRANSFER_TOO_LARGE"
	end
	local okDecode, serialized = pcall(LibDeflate.DecodeForWoWAddonChannel, LibDeflate, encoded)
	if not okDecode or type(serialized) ~= "string" then
		return nil, "DECODE_FAILED"
	end
	if #serialized > MAX_DECODED_BYTES then
		return nil, "DECODED_BODY_TOO_LARGE"
	end
	return Protocol.DecodeBody(serialized)
end

local function copyChunkBody(metadata, partIndex, partCount, chunk)
	local body = {}
	for key, value in pairs(metadata) do
		body[key] = value
	end
	body.partIndex = partIndex
	body.partCount = partCount
	body.chunk = chunk
	return body
end

local function buildTransferMessages(kind, requestId, target, metadata, encoded, chunkBytes)
	local count = ceil(#encoded / chunkBytes)
	if count < 1 or count > MAX_CHUNKS then
		return nil, "TOO_MANY_CHUNKS"
	end
	local messages = {}
	for i = 1, count do
		local chunk = sub(encoded, (i - 1) * chunkBytes + 1, i * chunkBytes)
		local message, reason = Protocol.Encode(kind, requestId, target, copyChunkBody(metadata, i, count, chunk))
		if not message then
			return nil, reason
		end
		messages[i] = message
	end
	return messages
end

function Session:AllowIncomingRequest(sender)
	return allowRate(self._incomingRates, sender, MAX_INCOMING_REQUESTS_PER_SENDER, GetTime())
end

function Session:BeginRequest(kind, target, body, expectedResponseKind, expectedMetadata, callback)
	local rateAllowed, normalizedTarget =
		allowRate(self._outgoingRates, target, MAX_OUTGOING_OPERATIONS_PER_TARGET, GetTime())
	if not rateAllowed then
		return nil, normalizedTarget
	end
	if type(target) ~= "string" or target == "" or type(callback) ~= "function" then
		return nil, "INVALID_REQUEST"
	end
	if EXPECTED_RESPONSE_KIND[kind] ~= expectedResponseKind then
		return nil, "INVALID_RESPONSE_CONTRACT"
	end
	local metadataCopy = copyExpectedMetadata(expectedResponseKind, expectedMetadata)
	if not metadataCopy then
		return nil, "INVALID_RESPONSE_CONTRACT"
	end
	local requestId, idReason = nextRequestId()
	if not requestId then
		return nil, idReason
	end
	local encoded, reason = Protocol.Encode(kind, requestId, target, body)
	if not encoded then
		return nil, reason
	end
	local request = {
		requestId = requestId,
		kind = kind,
		target = target,
		normalizedTarget = normalizedTarget,
		encodedRequest = encoded,
		expectedResponseKind = expectedResponseKind,
		expectedMetadata = metadataCopy,
		callback = callback,
		retryCount = 0,
		deadline = GetTime() + REQUEST_TTL_SECONDS,
		state = REQUEST_PENDING,
	}
	self._pendingRequests[requestId] = request
	local queued, queueReason = Comms.QueueAddonMessage(PREFIX, encoded, "WHISPER", target)
	if not queued then
		self._pendingRequests[requestId] = nil
		return nil, queueReason or "SEND_FAILED"
	end
	if not scheduleRequestTimer(request) then
		self._pendingRequests[requestId] = nil
		return nil, "TIMER_UNAVAILABLE"
	end
	return requestId
end

function Session:QueueTransfer(kind, requestId, target, metadata, body)
	local rateAllowed, rateReason =
		allowRate(self._outgoingRates, target, MAX_OUTGOING_OPERATIONS_PER_TARGET, GetTime())
	if not rateAllowed then
		return false, rateReason
	end
	if type(metadata) ~= "table" or type(body) ~= "table" then
		return false, "INVALID_TRANSFER"
	end
	local encoded, reason = encodeTransferText(body)
	if not encoded then
		return false, reason
	end
	for chunkBytes = MAX_CHUNK_BYTES, 1, -1 do
		local messages, buildReason = buildTransferMessages(kind, requestId, target, metadata, encoded, chunkBytes)
		if messages then
			return Comms.QueueAddonMessages(PREFIX, messages, "WHISPER", target)
		end
		if buildReason == "TOO_MANY_CHUNKS" then
			return false, buildReason
		end
		if buildReason ~= "MESSAGE_TOO_LARGE" then
			return false, buildReason
		end
	end
	return false, "MESSAGE_TOO_LARGE"
end

function Session:ReceiveChunk(sender, envelope)
	if type(envelope) ~= "table" or type(envelope.body) ~= "table" then
		return nil, "INVALID_CHUNK"
	end
	local normalizedSender = normalizeSender(sender)
	local requestId = envelope.requestId
	local body = envelope.body
	local kind = envelope.kind
	local request = self._pendingRequests[requestId]
	if not normalizedSender or type(requestId) ~= "string" or requestId == "-" then
		return nil, "INVALID_CHUNK"
	end
	if kind ~= "RANGE_DATA" and kind ~= "SNAP_DATA" then
		return nil, "INVALID_CHUNK_KIND"
	end
	if envelope.target == "-" or normalizeSender(envelope.target) ~= localPlayerName() then
		return nil, "INVALID_TARGET"
	end
	if not request or request.completed then
		return nil, "UNKNOWN_REQUEST"
	end
	if normalizedSender ~= request.normalizedTarget then
		return failRequest(request, "SENDER_MISMATCH")
	end
	if kind ~= request.expectedResponseKind then
		return failRequest(request, "RESPONSE_KIND_MISMATCH")
	end
	if not metadataMatches(kind, request.expectedMetadata, body) then
		return failRequest(request, "RESPONSE_METADATA_MISMATCH")
	end
	local partCount, partIndex = tonumber(body.partCount), tonumber(body.partIndex)
	if
		not partCount
		or partCount ~= floor(partCount)
		or partCount < 1
		or partCount > MAX_CHUNKS
		or not partIndex
		or partIndex ~= floor(partIndex)
		or partIndex < 1
		or partIndex > partCount
		or type(body.chunk) ~= "string"
		or #body.chunk < 1
	then
		return failRequest(request, "INVALID_CHUNK")
	end
	if #body.chunk > MAX_CHUNK_BYTES then
		return failRequest(request, "TRANSFER_TOO_LARGE")
	end
	local encodedBytes = #body.chunk
	if encodedBytes > MAX_ENCODED_BYTES then
		return failRequest(request, "TRANSFER_TOO_LARGE")
	end
	local key = assemblyKey(normalizedSender, requestId)
	local assembly = self._assemblies[key]
	if assembly then
		if assembly.kind ~= kind or assembly.target ~= envelope.target or assembly.partCount ~= partCount then
			return failRequest(request, "ASSEMBLY_MISMATCH")
		end
		if not metadataMatches(kind, assembly.metadata, body) then
			return failRequest(request, "RESPONSE_METADATA_MISMATCH")
		end
		local existing = assembly.chunks[partIndex]
		if existing then
			if existing == body.chunk then
				return true
			end
			return failRequest(request, "CONFLICTING_CHUNK")
		end
		if assembly.encodedBytes + #body.chunk > MAX_ENCODED_BYTES then
			return failRequest(request, "TRANSFER_TOO_LARGE")
		end
	else
		if
			self._assemblyCount >= MAX_ASSEMBLIES
			or (self._assembliesBySender[normalizedSender] or 0) >= MAX_ASSEMBLIES_PER_SENDER
		then
			return failRequest(request, "ASSEMBLY_CAPACITY")
		end
		assembly = {
			key = key,
			sender = normalizedSender,
			requestId = requestId,
			kind = kind,
			target = envelope.target,
			partCount = partCount,
			metadata = copyExpectedMetadata(kind, body),
			chunks = {},
			received = 0,
			encodedBytes = 0,
			deadline = GetTime() + ASSEMBLY_TTL_SECONDS,
		}
		self._assemblies[key] = assembly
		self._assemblyCount = self._assemblyCount + 1
		self._assembliesBySender[normalizedSender] = (self._assembliesBySender[normalizedSender] or 0) + 1
		request.assembly = assembly
		request.state = REQUEST_ASSEMBLING
	end
	assembly.chunks[partIndex] = body.chunk
	assembly.received = assembly.received + 1
	assembly.encodedBytes = assembly.encodedBytes + #body.chunk
	if assembly.received < assembly.partCount then
		return true
	end
	local ordered = {}
	for i = 1, assembly.partCount do
		if type(assembly.chunks[i]) ~= "string" then
			return failRequest(request, "MISSING_CHUNK")
		end
		ordered[i] = assembly.chunks[i]
	end
	local decoded, decodeReason = decodeTransferText(concat(ordered))
	if not decoded then
		return failRequest(request, decodeReason)
	end
	request.resultBody = decoded
	return completeRequest(request, true, "COMPLETE")
end

function Session:CompleteRequest(requestId, succeeded, reason)
	local request = self._pendingRequests[requestId]
	if not request then
		return false, "UNKNOWN_REQUEST"
	end
	return completeRequest(request, succeeded == true, reason)
end

function Session:CancelRequest(requestId, reason)
	local request = self._pendingRequests[requestId]
	if not request then
		return false, "UNKNOWN_REQUEST"
	end
	request.state = REQUEST_FAILED
	completeRequest(request, false, reason or "CANCELLED")
	return true
end

local function expireRequest(request, now)
	if request.retryCount == 0 then
		request.retryCount = 1
		request.deadline = now + REQUEST_TTL_SECONDS
		return resendRequest(request)
	end
	request.state = REQUEST_FAILED
	return completeRequest(request, false, "TIMEOUT")
end

function Session:Expire(now)
	now = tonumber(now) or GetTime()
	pruneRateMap(self._incomingRates, now)
	pruneRateMap(self._outgoingRates, now)
	local expiredRequests = {}
	for _, request in pairs(self._pendingRequests) do
		if request.deadline <= now then
			expiredRequests[#expiredRequests + 1] = request
		end
	end
	for i = 1, #expiredRequests do
		expireRequest(expiredRequests[i], now)
	end
	local expiredAssemblies = {}
	for _, assembly in pairs(self._assemblies) do
		if assembly.deadline <= now then
			expiredAssemblies[#expiredAssemblies + 1] = assembly
		end
	end
	for i = 1, #expiredAssemblies do
		local assembly = expiredAssemblies[i]
		local request = self._pendingRequests[assembly.requestId]
		if request then
			failRequest(request, "ASSEMBLY_TIMEOUT")
		else
			releaseAssembly(assembly)
		end
	end
	return #expiredRequests + #expiredAssemblies
end

function Session:SendResult(target, requestId, outcome, reason)
	local encoded, encodeReason = Protocol.Encode("RESULT", requestId, target, { outcome = outcome, reason = reason })
	if not encoded then
		return false, encodeReason
	end
	return Comms.QueueAddonMessage(PREFIX, encoded, "WHISPER", target)
end
