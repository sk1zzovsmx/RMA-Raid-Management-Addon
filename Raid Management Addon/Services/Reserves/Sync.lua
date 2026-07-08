-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: local feature = addon.Database.GetFeatureShared()
-- exports: addon.Services.Reserves._Sync
-- events: handles RMAResSync addon-message traffic

local addon = select(2, ...)
local feature = addon.Database.GetFeatureShared()

local L = feature.L
local Comms = feature.Comms
local Services = feature.Services
local Strings = feature.Strings

local floor = math.floor
local sort = table.sort
local tconcat = table.concat
local pairs, tostring, tonumber, type = pairs, tostring, tonumber, type
local _G = _G
local UnitName = assert(_G.UnitName, "Reserves sync unit name API is not initialized")
local GetTime = assert(_G.GetTime, "Reserves sync time API is not initialized")
local RegisterAddonMessagePrefix =
	assert(_G.RegisterAddonMessagePrefix, "Reserves sync prefix registration API is not initialized")

-- ----- Internal state ----- --
feature.EnsureServiceNamespace("Reserves")
local Reserves = Services.Reserves
local module = Reserves
module._Sync = module._Sync or {}

local Sync = module._Sync
local Payload = assert(Comms.Payload, "Comms payload helpers are not initialized")
local sendAddonWhisper = assert(Comms.SendAddonWhisper, "Reserves sync whisper transport is not initialized")
local NormalizeLower = assert(Strings.NormalizeLower, "Reserves sync player normalizer is not initialized")
local Raid = assert(Services.Raid, "Reserves sync raid service is not initialized")
local GetPlayerRoleState = assert(Raid.GetPlayerRoleState, "Reserves sync raid-role resolver is not initialized")

local PREFIX = "RMAResSync"
local FIELD_SEP = "|"
local MSG_META_REQ = "META_REQ"
local MSG_META_ACK = "META_ACK"
local MSG_DATA_REQ = "DATA_REQ"
local MSG_DATA_CHUNK = "DATA_CHUNK"
local MSG_DATA_DONE = "DATA_DONE"
local MSG_DATA_ERR = "DATA_ERR"
local FORMAT_COMPACT = "C1"
local MAX_CHUNK_SIZE = 220
local INCOMING_TTL_SECONDS = 180
local MAX_INCOMING_CHUNKS = 64
local MAX_OUTGOING_CHUNKS = MAX_INCOMING_CHUNKS
local MAX_INCOMING_BYTES = 24000

Sync._incoming = Sync._incoming or {}
Sync._pendingRequests = Sync._pendingRequests or {}
Sync._nextRequestId = Sync._nextRequestId or 0

-- ----- Private helpers ----- --
local normalizeSender = assert(Comms.NormalizeSender, "Reserves sync sender normalizer is not initialized")

local function requirePayload()
	return assert(Payload, "Comms payload helpers are not initialized")
end

local function ensurePrefix()
	RegisterAddonMessagePrefix(PREFIX)
end

local function getIncomingNow()
	return GetTime()
end

local function canProvideReserves()
	local service = module
	if not (service and service.IsLocalDataAvailable and service:IsLocalDataAvailable()) then
		return false
	end

	local role = GetPlayerRoleState(Raid) or {}
	return role.isMasterLooter == true or role.isLeader == true or role.isAssistant == true
end

local function sendError(target, reason)
	local payload = requirePayload()
	sendAddonWhisper(PREFIX, target, payload.PackFields(FIELD_SEP, MSG_DATA_ERR, tostring(reason or "unknown")))
end

local function shouldRequestRemoteData(remoteChecksum)
	local checksum = tostring(remoteChecksum or "")
	if checksum == "" then
		return false
	end

	local service = module
	if service and service.IsLocalDataAvailable and service:IsLocalDataAvailable() then
		return false
	end

	local localMeta = service and service.GetSyncMetadata and service:GetSyncMetadata() or nil
	return not (localMeta and localMeta.checksum == checksum)
end

local function requestDataFrom(target, requestId, checksum, remoteFormat)
	if target == "" then
		return false
	end
	local payload = requirePayload()
	if remoteFormat == FORMAT_COMPACT then
		sendAddonWhisper(
			PREFIX,
			target,
			payload.PackFields(FIELD_SEP, MSG_DATA_REQ, requestId, checksum or "", FORMAT_COMPACT)
		)
	else
		sendAddonWhisper(PREFIX, target, payload.PackFields(FIELD_SEP, MSG_DATA_REQ, requestId, checksum or ""))
	end
	addon:info(L.MsgReservesSyncDataRequested)
	return true
end

local function registerPendingRequest(requestId, source, checksum)
	Sync._pendingRequests[tostring(requestId)] = {
		source = source,
		checksum = tostring(checksum or ""),
		createdAt = getIncomingNow(),
	}
end

local function getPendingRequest(requestId)
	return Sync._pendingRequests[tostring(requestId)]
end

local function clearPendingRequest(requestId)
	Sync._pendingRequests[tostring(requestId)] = nil
end

local function sortedPlayerKeys(data)
	local keys = {}
	for key in pairs(data or {}) do
		keys[#keys + 1] = key
	end
	sort(keys)
	return keys
end

local function cleanupIncoming()
	local now = getIncomingNow()
	for key, pending in pairs(Sync._incoming) do
		if type(pending) ~= "table" then
			Sync._incoming[key] = nil
		else
			local createdAt = tonumber(pending.createdAt)
			if createdAt and now > 0 and (now - createdAt) >= INCOMING_TTL_SECONDS then
				Sync._incoming[key] = nil
			end
		end
	end

	for requestId, pending in pairs(Sync._pendingRequests) do
		if type(pending) ~= "table" then
			Sync._pendingRequests[requestId] = nil
		else
			local createdAt = tonumber(pending.createdAt)
			if createdAt and now > 0 and (now - createdAt) >= INCOMING_TTL_SECONDS then
				Sync._pendingRequests[requestId] = nil
			end
		end
	end
end

local function acceptIncomingChunk(key, idx, total, chunk)
	if idx <= 0 or total <= 0 or total > MAX_INCOMING_CHUNKS or idx > total then
		Sync._incoming[key] = nil
		return nil
	end

	local incoming = Sync._incoming[key]
	if type(incoming) == "table" and incoming.total ~= total then
		Sync._incoming[key] = nil
		return nil
	end

	if type(incoming) ~= "table" then
		incoming = {
			total = total,
			chunks = {},
			chunkBytes = {},
			createdAt = getIncomingNow(),
			bytes = 0,
		}
		Sync._incoming[key] = incoming
	end

	local chunkText = chunk or ""
	local chunkSize = tonumber(#chunkText) or 0
	local previous = tonumber(incoming.chunkBytes[idx]) or 0
	local nextBytes = (incoming.bytes or 0) - previous + chunkSize
	if nextBytes > MAX_INCOMING_BYTES then
		Sync._incoming[key] = nil
		return nil
	end

	incoming.chunkBytes[idx] = chunkSize
	incoming.chunks[idx] = chunkText
	incoming.bytes = nextBytes
	return incoming
end

local function buildPayload(data, mode, format)
	local payload = requirePayload()
	local useCompact = format == FORMAT_COMPACT
	local lines = { payload.PackFields(FIELD_SEP, "H", mode or "multi", useCompact and FORMAT_COMPACT or "") }
	local keys = sortedPlayerKeys(data)

	for i = 1, #keys do
		local playerKey = keys[i]
		local player = data[playerKey]
		if type(player) == "table" and type(player.reserves) == "table" then
			local playerName = player.playerNameDisplay or player.original or playerKey
			if useCompact then
				lines[#lines + 1] = payload.PackFields(FIELD_SEP, "P", i, payload.EncodeText(playerName))
			end
			for j = 1, #player.reserves do
				local row = player.reserves[j]
				if type(row) == "table" and row.rawID then
					if useCompact then
						lines[#lines + 1] = payload.PackFields(
							FIELD_SEP,
							"R",
							i,
							tonumber(row.rawID) or 0,
							tonumber(row.quantity) or 1,
							tonumber(row.plus) or 0,
							payload.EncodeText(row.class),
							payload.EncodeText(row.spec),
							payload.EncodeText(row.note),
							payload.EncodeText(row.source)
						)
					else
						lines[#lines + 1] = payload.PackFields(
							FIELD_SEP,
							"R",
							payload.EncodeText(playerName),
							tonumber(row.rawID) or 0,
							tonumber(row.quantity) or 1,
							tonumber(row.plus) or 0,
							payload.EncodeText(row.class),
							payload.EncodeText(row.spec),
							payload.EncodeText(row.note),
							payload.EncodeText(row.source)
						)
					end
				end
			end
		end
	end

	return tconcat(lines, "\n")
end

local function parsePayload(payload)
	local payloadCodec = requirePayload()
	local reserves = {}
	local mode = "multi"
	local fields = {}
	local compact = false
	local playerNamesByIndex = {}

	for line in tostring(payload or ""):gmatch("[^\n]+") do
		payloadCodec.SplitFields(line, FIELD_SEP, fields)
		if fields[1] == "H" then
			mode = (fields[2] == "plus") and "plus" or "multi"
			compact = fields[3] == FORMAT_COMPACT
		elseif fields[1] == "P" and compact then
			local playerIndex = tonumber(fields[2])
			local playerName = payloadCodec.DecodeText(fields[3])
			if playerIndex and playerIndex > 0 and playerName and playerName ~= "" then
				playerNamesByIndex[playerIndex] = playerName
			end
		elseif fields[1] == "R" then
			local playerName
			local itemId
			if compact then
				playerName = playerNamesByIndex[tonumber(fields[2]) or 0]
				itemId = tonumber(fields[3])
			else
				playerName = payloadCodec.DecodeText(fields[2])
				itemId = tonumber(fields[3])
			end
			if playerName and playerName ~= "" and itemId and itemId > 0 then
				local playerKey = NormalizeLower(playerName, true)
				local container = reserves[playerKey]
				if not container then
					container = {
						playerNameDisplay = playerName,
						reserves = {},
					}
					reserves[playerKey] = container
				end
				container.reserves[#container.reserves + 1] = {
					rawID = itemId,
					quantity = tonumber(fields[4]) or 1,
					plus = tonumber(fields[5]) or 0,
					class = payloadCodec.DecodeText(fields[6]),
					spec = payloadCodec.DecodeText(fields[7]),
					note = payloadCodec.DecodeText(fields[8]),
					source = payloadCodec.DecodeText(fields[9]),
				}
			end
		end
	end

	return reserves, mode
end

local function sendMetadata(target, requestId)
	local payload = requirePayload()
	if not canProvideReserves() then
		sendAddonWhisper(PREFIX, target, payload.PackFields(FIELD_SEP, MSG_DATA_ERR, requestId, "no_data"))
		return false
	end

	local _, meta = Sync:GetPayload()
	sendAddonWhisper(
		PREFIX,
		target,
		payload.PackFields(
			FIELD_SEP,
			MSG_META_ACK,
			requestId,
			meta and meta.checksum or "",
			meta and meta.mode or "multi",
			meta and meta.players or 0,
			meta and meta.entries or 0,
			normalizeSender(UnitName("player")),
			FORMAT_COMPACT
		)
	)
	return true
end

local function sendData(target, requestId, format)
	local payloadCodec = requirePayload()
	if not canProvideReserves() then
		sendError(target, "no_data")
		return false
	end

	local data, meta = Sync:GetPayload()
	local payload =
		buildPayload(data, meta and meta.mode or "multi", format == FORMAT_COMPACT and FORMAT_COMPACT or nil)
	local encoded = payloadCodec.EncodeText(payload)
	local payloadLen = #encoded
	local totalChunks = floor((payloadLen + MAX_CHUNK_SIZE - 1) / MAX_CHUNK_SIZE)
	if totalChunks < 1 then
		totalChunks = 1
	end
	if totalChunks > MAX_OUTGOING_CHUNKS then
		sendAddonWhisper(
			PREFIX,
			target,
			payloadCodec.PackFields(FIELD_SEP, MSG_DATA_ERR, tostring(requestId), "payload_too_large")
		)
		return false
	end

	for idx = 1, totalChunks do
		local fromPos = ((idx - 1) * MAX_CHUNK_SIZE) + 1
		local toPos = fromPos + MAX_CHUNK_SIZE - 1
		local chunk = encoded:sub(fromPos, toPos)
		sendAddonWhisper(
			PREFIX,
			target,
			payloadCodec.PackFields(FIELD_SEP, MSG_DATA_CHUNK, requestId, idx, totalChunks, chunk)
		)
	end

	sendAddonWhisper(
		PREFIX,
		target,
		payloadCodec.PackFields(FIELD_SEP, MSG_DATA_DONE, requestId, meta and meta.checksum or "")
	)
	return true
end

local function applyIncoming(sender, requestId, checksum)
	local key = tostring(sender or "?") .. ":" .. tostring(requestId or "")
	local pending = Sync._incoming[key]
	if type(pending) ~= "table" then
		return false, "missing_request"
	end

	local parts = {}
	for i = 1, tonumber(pending.total) or 0 do
		if pending.chunks[i] == nil then
			return false, "missing_chunk"
		end
		parts[i] = pending.chunks[i]
	end

	local decodedPayload = requirePayload().DecodeText(tconcat(parts, ""))
	if not decodedPayload then
		Sync._incoming[key] = nil
		return false, "decode_failed"
	end

	local reserves, mode = parsePayload(decodedPayload)
	local ok, reason = Sync:SetSyncedData(reserves, {
		source = sender,
		checksum = checksum,
		mode = mode,
	})
	Sync._incoming[key] = nil
	return ok, reason
end

-- ----- Public methods ----- --

function Sync:RequestMetadata()
	ensurePrefix()
	local requestId = Comms.NextRequestId(Sync, "_nextRequestId")
	local payload = requirePayload()
	local ok = Comms.Sync(PREFIX, payload.PackFields(FIELD_SEP, MSG_META_REQ, requestId))
	if ok == false then
		addon:warn(L.MsgReservesSyncNotInGroup)
		return false
	end
	addon:info(L.MsgReservesSyncRequested)
	return true
end

function Sync:HandleMessage(prefix, msg, channel, sender)
	if prefix ~= PREFIX then
		return false
	end

	local fields = {}
	requirePayload().SplitFields(msg, FIELD_SEP, fields)
	local kind = fields[1]
	local requestId = fields[2]
	local source = normalizeSender(sender)
	cleanupIncoming()

	if kind == MSG_META_REQ then
		sendMetadata(source, requestId)
		return true
	end

	if kind == MSG_DATA_REQ then
		sendData(source, requestId, fields[4])
		return true
	end

	if kind == MSG_META_ACK then
		local checksum = tostring(fields[3] or "")
		addon:info(
			L.MsgReservesSyncMeta:format(
				source,
				checksum,
				tostring(fields[4] or ""),
				tonumber(fields[5]) or 0,
				tonumber(fields[6]) or 0
			)
		)
		if shouldRequestRemoteData(checksum) then
			registerPendingRequest(requestId, source, checksum)
			requestDataFrom(source, requestId, checksum, fields[8])
		end
		return true
	end

	if kind == MSG_DATA_CHUNK then
		local pending = getPendingRequest(requestId)
		if not pending or pending.source ~= source then
			return true
		end
		local key = source .. ":" .. tostring(requestId or "")
		local idx = tonumber(fields[3]) or 0
		local total = tonumber(fields[4]) or 0
		acceptIncomingChunk(key, idx, total, fields[5])
		return true
	end

	if kind == MSG_DATA_DONE then
		local pending = getPendingRequest(requestId)
		local key = source .. ":" .. tostring(requestId or "")
		if not pending then
			Sync._incoming[key] = nil
			return true
		end

		if pending.source ~= source then
			return true
		end

		if tostring(fields[3] or "") ~= tostring(pending.checksum) then
			Sync._incoming[key] = nil
			clearPendingRequest(requestId)
			return true
		end

		local ok, reason = applyIncoming(source, requestId, fields[3])
		clearPendingRequest(requestId)
		if ok then
			addon:info(L.MsgReservesSyncApplied:format(source))
		else
			addon:warn(L.MsgReservesSyncFailed:format(tostring(reason or "unknown")))
		end
		return true
	end

	if kind == MSG_DATA_ERR then
		addon:warn(L.MsgReservesSyncFailed:format(tostring(fields[3] or fields[2] or "unknown")))
		return true
	end

	return true
end

local registry = feature.ModuleRegistry
if type(registry) == "table" and type(registry.AddModule) == "function" and type(registry.SetLoaded) == "function" then
	registry.AddModule("Services/Reserves/Sync", {
		deps = {
			"Init",
			"Modules/ModuleRegistry",
			"Modules/Comms",
			"Modules/Strings",
			"Services/Raid/Capabilities",
		},
	})
	registry.SetLoaded("Services/Reserves/Sync")
end
