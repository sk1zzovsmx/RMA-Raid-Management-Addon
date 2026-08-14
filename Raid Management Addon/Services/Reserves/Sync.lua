-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: direct addon namespace bindings
-- exports: addon.Services.Reserves._Sync
-- events: handles RMAResSync addon-message traffic

local addon = select(2, ...)
local L = addon.L
local Comms = addon.Comms
local Services = addon.Services
local Strings = addon.Strings

local floor = math.floor
local tconcat = table.concat
local pairs, tostring, tonumber, type = pairs, tostring, tonumber, type
local _G = _G
local UnitName = assert(_G.UnitName, "Reserves sync unit name API is not initialized")
local GetTime = assert(_G.GetTime, "Reserves sync time API is not initialized")

-- ----- Internal state ----- --
addon.Services.EnsureNamespace("Reserves")
local Reserves = Services.Reserves
local module = Reserves
module._Sync = module._Sync or {}

local Sync = module._Sync
local Payload = assert(Comms.Payload, "Comms payload helpers are not initialized")
local sendAddonWhisper = assert(Comms.SendAddonWhisper, "Reserves sync whisper transport is not initialized")
local NormalizeLower = assert(Strings.NormalizeLower, "Reserves sync player normalizer is not initialized")
local Raid = assert(Services.Raid, "Reserves sync raid service is not initialized")
local GetPlayerRoleState = assert(Raid.GetPlayerRoleState, "Reserves sync raid-role resolver is not initialized")
local IsGroupMember = assert(Raid.IsGroupMember, "Reserves sync group-membership resolver is not initialized")
local IsReservesAuthority = assert(Raid.IsReservesAuthority, "Reserves sync authority resolver is not initialized")

local PREFIX = "RMAResSync"
local FIELD_SEP = "|"
local MSG_META_REQ = "META_REQ"
local MSG_META_ACK = "META_ACK"
local MSG_DATA_REQ = "DATA_REQ"
local MSG_DATA_CHUNK = "DATA_CHUNK"
local MSG_DATA_DONE = "DATA_DONE"
local MSG_DATA_ERR = "DATA_ERR"
local FORMAT_COMPACT = "C1"
local FORMAT_VERIFIED = "C2"
local MAX_CHUNK_SIZE = 220
local INCOMING_TTL_SECONDS = 180
local MAX_INCOMING_CHUNKS = 64
local MAX_OUTGOING_CHUNKS = MAX_INCOMING_CHUNKS
local MAX_INCOMING_BYTES = 24000
local MAX_META_PLAYERS = 2048
local MAX_META_ENTRIES = 4096

Sync._incoming = Sync._incoming or {}
Sync._pendingRequests = Sync._pendingRequests or {}
Sync._nextRequestId = Sync._nextRequestId or 0

-- ----- Private helpers ----- --
local normalizeSender = assert(Comms.NormalizeSender, "Reserves sync sender normalizer is not initialized")

local function requirePayload()
	return assert(Payload, "Comms payload helpers are not initialized")
end

local function ensurePrefix()
	Comms.RegisterPrefixIfAvailable(PREFIX)
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

local function shouldRequestRemoteData(remoteChecksum, remoteMode)
	local checksum = tostring(remoteChecksum or "")
	if checksum == "" then
		return false
	end

	local service = module
	if service and service.IsLocalDataAvailable and service:IsLocalDataAvailable() then
		return false
	end

	local localMeta = service and service.GetSyncMetadata and service:GetSyncMetadata() or nil
	return not (localMeta and localMeta.checksum == checksum and localMeta.mode == remoteMode)
end

local function requestDataFrom(target, requestId, checksum, remoteFormat)
	if target == "" then
		return false
	end
	local payload = requirePayload()
	if remoteFormat == FORMAT_COMPACT or remoteFormat == FORMAT_VERIFIED then
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

local function registerPendingRequest(requestId, source, checksum, mode, players, entries)
	Sync._pendingRequests[tostring(requestId)] = {
		source = source,
		checksum = tostring(checksum or ""),
		mode = mode,
		players = tonumber(players),
		entries = tonumber(entries),
		createdAt = getIncomingNow(),
	}
end

local function getPendingRequest(requestId)
	return Sync._pendingRequests[tostring(requestId)]
end

local function clearPendingRequest(requestId)
	Sync._pendingRequests[tostring(requestId)] = nil
end

local function parseBoundedCount(value, maximum)
	local numeric = tonumber(value)
	if not numeric or numeric < 0 or numeric ~= floor(numeric) or numeric > maximum then return nil end
	return numeric
end

local function validateMetadata(fields)
	if #fields ~= 8 or type(fields[2]) ~= "string" or fields[2] == "" or #fields[2] > 32 then return nil end
	local checksum = tostring(fields[3] or "")
	if #checksum > 64 or not checksum:match("^C2:%d+:%d+$") then return nil end
	if fields[4] ~= "multi" and fields[4] ~= "plus" then return nil end
	if fields[8] ~= FORMAT_VERIFIED then return nil end
	local players = parseBoundedCount(fields[5], MAX_META_PLAYERS)
	local entries = parseBoundedCount(fields[6], MAX_META_ENTRIES)
	if not players or not entries then return nil end
	return checksum, players, entries
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
	if idx <= 0 or idx ~= floor(idx) or total <= 0 or total ~= floor(total)
		or total > MAX_INCOMING_CHUNKS or idx > total or type(chunk) ~= "string" or chunk == "" then
		Sync._incoming[key] = nil
		return nil
	end

	local incoming = Sync._incoming[key]
	if type(incoming) == "table" and incoming.total ~= total then
		Sync._incoming[key] = nil
		return nil
	end
	if type(incoming) == "table" and incoming.chunks[idx] ~= nil then
		if incoming.chunks[idx] == chunk then return incoming end
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
	local projection, reason = module.BuildCanonicalProjection(data)
	if not projection then return nil, reason end

	for i = 1, #projection do
		local player = projection[i]
		if useCompact then
			lines[#lines + 1] = payload.PackFields(FIELD_SEP, "P", i, payload.EncodeText(player.name))
		end
		for j = 1, #player.rows do
			local row = player.rows[j]
			lines[#lines + 1] = payload.PackFields(
				FIELD_SEP,
				"R",
				useCompact and i or payload.EncodeText(player.name),
				row.rawID,
				row.quantity,
				row.plus,
				payload.EncodeText(row.class),
				payload.EncodeText(row.spec),
				payload.EncodeText(row.note),
				payload.EncodeText(row.source)
			)
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
	local compactPlayerKeys = {}
	local sawHeader = false
	local playerCount = 0
	local entryCount = 0
	local lineNumber = 0

	for line in tostring(payload or ""):gmatch("[^\n]+") do
		lineNumber = lineNumber + 1
		payloadCodec.SplitFields(line, FIELD_SEP, fields)
		if fields[1] == "H" then
			if sawHeader or lineNumber ~= 1 or #fields ~= 3 or (fields[2] ~= "multi" and fields[2] ~= "plus") then
				return nil, "invalid_schema"
			end
			sawHeader = true
			mode = (fields[2] == "plus") and "plus" or "multi"
			compact = fields[3] == FORMAT_COMPACT
		elseif fields[1] == "P" and compact then
			local playerIndex = tonumber(fields[2])
			local playerName = payloadCodec.DecodeText(fields[3])
			local playerKey = playerName and NormalizeLower(playerName, true) or nil
			if #fields ~= 3 or not sawHeader or playerIndex ~= (playerCount + 1) or not playerName
				or playerName == "" or not playerKey or compactPlayerKeys[playerKey] then
				return nil, "invalid_schema"
			end
			playerCount = playerCount + 1
			playerNamesByIndex[playerIndex] = playerName
			compactPlayerKeys[playerKey] = true
		elseif fields[1] == "R" then
			if not sawHeader or #fields ~= 9 then
				return nil, "invalid_schema"
			end
			local playerName
			local itemId
			if compact then
				playerName = playerNamesByIndex[tonumber(fields[2]) or 0]
				itemId = tonumber(fields[3])
			else
				playerName = payloadCodec.DecodeText(fields[2])
				itemId = tonumber(fields[3])
			end
			local quantity = tonumber(fields[4])
			local plus = tonumber(fields[5])
			local class = payloadCodec.DecodeText(fields[6])
			local spec = payloadCodec.DecodeText(fields[7])
			local note = payloadCodec.DecodeText(fields[8])
			local rowSource = payloadCodec.DecodeText(fields[9])
			if not playerName or playerName == "" or not itemId or itemId <= 0 or itemId ~= floor(itemId)
				or not quantity or quantity <= 0 or quantity ~= floor(quantity) or not plus or plus < 0
				or plus ~= floor(plus) or class == nil or spec == nil or note == nil or rowSource == nil then
				return nil, "invalid_schema"
			end
			local playerKey = NormalizeLower(playerName, true)
			if not playerKey or playerKey == "" then return nil, "invalid_schema" end
			local container = reserves[playerKey]
			if not container then
				container = { playerNameDisplay = playerName, reserves = {} }
				reserves[playerKey] = container
				if not compact then playerCount = playerCount + 1 end
			elseif container.playerNameDisplay ~= playerName then
				return nil, "invalid_schema"
			end
			container.reserves[#container.reserves + 1] = {
				rawID = itemId, quantity = quantity, plus = plus, class = class,
				spec = spec, note = note, source = rowSource,
			}
			entryCount = entryCount + 1
		else
			return nil, "invalid_schema"
		end
	end

	if not sawHeader or entryCount == 0 then
		return nil, "invalid_schema"
	end
	return reserves, mode, playerCount, entryCount
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
			FORMAT_VERIFIED
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
	local payload, payloadReason =
		buildPayload(data, meta and meta.mode or "multi", format == FORMAT_COMPACT and FORMAT_COMPACT or nil)
	if not payload then
		sendError(target, payloadReason or "invalid_data")
		return false
	end
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
	local incoming = Sync._incoming[key]
	local request = getPendingRequest(requestId)
	if type(incoming) ~= "table" or type(request) ~= "table" then
		return false, "missing_request"
	end

	local parts = {}
	for i = 1, tonumber(incoming.total) or 0 do
		if incoming.chunks[i] == nil then
			return false, "missing_chunk"
		end
		parts[i] = incoming.chunks[i]
	end

	local decodedPayload = requirePayload().DecodeText(tconcat(parts, ""))
	if not decodedPayload then
		Sync._incoming[key] = nil
		return false, "decode_failed"
	end

	local reserves, mode, players, entries = parsePayload(decodedPayload)
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
	if tostring(computedChecksum or "") ~= tostring(checksum or "") then
		Sync._incoming[key] = nil
		return false, "checksum_mismatch"
	end
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
	local rawSource = sender
	local source = normalizeSender(sender)
	cleanupIncoming()
	if kind == MSG_META_REQ or kind == MSG_DATA_REQ then
		if not IsGroupMember(Raid, rawSource) then
			return true
		end
	elseif not IsReservesAuthority(Raid, rawSource) then
		return true
	end

	if kind == MSG_META_REQ then
		sendMetadata(source, requestId)
		return true
	end

	if kind == MSG_DATA_REQ then
		sendData(source, requestId, fields[4])
		return true
	end

	if kind == MSG_META_ACK then
		local checksum, players, entries = validateMetadata(fields)
		if not checksum then return true end
		addon:info(
			L.MsgReservesSyncMeta:format(
				source,
				checksum,
				tostring(fields[4] or ""),
				players,
				entries
			)
		)
		if shouldRequestRemoteData(checksum, fields[4]) then
			registerPendingRequest(requestId, source, checksum, fields[4], players, entries)
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
		if #fields ~= 5 or not acceptIncomingChunk(key, idx, total, fields[5]) then
			Sync._incoming[key] = nil
			clearPendingRequest(requestId)
		end
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
		Sync._incoming[key] = nil
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
