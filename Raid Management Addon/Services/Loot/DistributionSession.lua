-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: local feature = addon.Database.GetFeatureShared()
-- exports: addon.Services.Loot._DistributionSession
-- events: LootDistributionSessionChanged

local addon = select(2, ...)
local feature = addon.Database.GetFeatureShared()

local Database = feature.Database
local Diag = feature.Diag
local Events = feature.Events
local Bus = feature.Bus
local Comms = feature.Comms
local Item = feature.Item
local Services = feature.Services
local Strings = feature.Strings
local Payload = assert(Comms.Payload, "Loot distribution payload codec is not initialized")
local InternalEvents = assert(Events.Internal, "Loot distribution internal events are not initialized")

local _G = _G
local GetTime = assert(_G.GetTime, "Loot distribution time API is not initialized")
local RegisterAddonMessagePrefix =
	assert(_G.RegisterAddonMessagePrefix, "Loot distribution prefix registration API is not initialized")
local GetPlayerName = assert(Database.GetPlayerName, "Loot distribution player-name resolver is not initialized")
local SendSync = assert(Comms.Sync, "Loot distribution sync sender is not initialized")
local QueueAddonMessage = assert(Comms.QueueAddonMessage, "Loot distribution direct sender is not initialized")
local DistributionChangedEvent =
	assert(InternalEvents.LootDistributionSessionChanged, "Loot distribution change event is not initialized")
local TriggerEvent = assert(Bus.TriggerEvent, "Loot distribution event bus sender is not initialized")
local type, tostring, tonumber = type, tostring, tonumber
local tinsert, tsort, tconcat = table.insert, table.sort, table.concat

-- ----- Internal state ----- --
feature.EnsureServiceNamespace("Loot")
local Loot = Services.Loot
local module = Loot
module._DistributionSession = module._DistributionSession or {}

local DistributionSession = module._DistributionSession

local PREFIX = "RMADist"
local SEP = "|"
local PROTOCOL_VERSION = 2

local MSG_ITEM = "ITEM"
local MSG_ROLL_START = "ROLL_START"
local MSG_ROLL_END = "ROLL_END"
local MSG_ITEM_DONE = "ITEM_DONE"
local MSG_CLEAR = "CLEAR"
local MSG_HELLO = "HELLO"
local MSG_SNAPSHOT_REQ = "SNAP_REQ"
local MSG_SNAPSHOT = "SNAP"
local MSG_ROLL_TICK = "ROLL_TICK"
local MSG_TIE_START = "TIE_START"
local MSG_AWARDED = "AWARDED"
local MSG_SNAPSHOT_CHUNK = "SNAP_CHUNK"

local SNAP_ROW_SEP = "~"
local MAX_SNAPSHOT_CHUNK_SIZE = 180
local MAX_SNAPSHOT_CHUNKS = 64
local SNAPSHOT_INCOMING_TTL_SECONDS = 180
local MAX_INCOMING_SNAPSHOT_BYTES = MAX_SNAPSHOT_CHUNK_SIZE * MAX_SNAPSHOT_CHUNKS

local STATE_ACTIVE = "active"
local STATE_ROLLING = "rolling"
local STATE_WINNER = "winner"
local STATE_DONE = "done"
local STATE_AWARDED = "awarded"

local state = DistributionSession._state
if type(state) ~= "table" then
	state = {
		sessionId = nil,
		nextSessionOrdinal = 1,
		order = {},
		itemsByKey = {},
	}
	DistributionSession._state = state
end
DistributionSession._incomingSnapshots = DistributionSession._incomingSnapshots or {}
local incomingSnapshots = DistributionSession._incomingSnapshots

-- ----- Private helpers ----- --
local function getIncomingNow()
	return GetTime()
end

local function ensurePrefix()
	RegisterAddonMessagePrefix(PREFIX)
end

local encodeText = Payload.EncodeText

local decodeText = function(value)
	local decoded = Payload.DecodeText(value)
	if decoded ~= nil then
		return decoded
	end
	return tostring(value or "")
end

local function packFields(...)
	return Payload.PackFields(SEP, ...)
end

local function splitText(text, sep, out)
	return Payload.SplitFields(text, sep, out)
end

local splitScratch = {}
local function splitFields(text)
	return Payload.SplitFields(text, SEP, splitScratch)
end

local snapshotRowsScratch = {}
local snapshotFieldScratch = {}

local function normalizeNumber(value)
	local numeric = tonumber(value)
	if numeric then
		return numeric
	end
	return nil
end

local normalizeText = Strings.NormalizeText

local resolveItemKey = assert(Item.GetItemKey, "Loot distribution item-key resolver is not initialized")

local function buildSessionId()
	local playerName = normalizeText(GetPlayerName(), true)
	assert(playerName, "Loot distribution player name is not initialized")
	local ordinal = tonumber(state.nextSessionOrdinal) or 1
	state.nextSessionOrdinal = ordinal + 1

	local now = tonumber(GetTime())
	assert(now, "Loot distribution time API returned invalid timestamp")
	return tostring(playerName) .. ":" .. tostring(ordinal) .. ":" .. tostring(now)
end

local function ensureSessionId()
	if not state.sessionId or state.sessionId == "" then
		state.sessionId = buildSessionId()
	end
	return state.sessionId
end

local function setSessionId(sessionId)
	sessionId = normalizeText(sessionId, true)
	if sessionId then
		state.sessionId = sessionId
	else
		ensureSessionId()
	end
	return state.sessionId
end

local function canPublish()
	local raid = assert(Services.Raid, "Loot distribution raid service is not initialized")
	local CanUseCapability =
		assert(raid.CanUseCapability, "Loot distribution raid capability resolver is not initialized")
	return CanUseCapability(raid, "loot") == true
end

local function triggerChanged(reason, row)
	TriggerEvent(DistributionChangedEvent, reason, row, state.sessionId)
end

local function getOrCreateRow(itemKey)
	itemKey = normalizeText(itemKey, true)
	if not itemKey then
		return nil
	end

	local row = state.itemsByKey[itemKey]
	if row then
		return row
	end

	row = {
		itemKey = itemKey,
		order = #state.order + 1,
		state = STATE_ACTIVE,
	}
	state.itemsByKey[itemKey] = row
	state.order[#state.order + 1] = itemKey
	return row
end

local function cleanupIncomingSnapshots()
	local now = getIncomingNow()
	for key, snapshotState in pairs(incomingSnapshots) do
		if type(snapshotState) ~= "table" then
			incomingSnapshots[key] = nil
		else
			local createdAt = tonumber(snapshotState.createdAt)
			if createdAt == nil or (now > 0 and (now - createdAt) >= SNAPSHOT_INCOMING_TTL_SECONDS) then
				incomingSnapshots[key] = nil
			end
		end
	end
end

local function copyRow(row)
	if type(row) ~= "table" then
		return nil
	end
	return {
		itemKey = row.itemKey,
		itemLink = row.itemLink,
		itemName = row.itemName,
		itemTexture = row.itemTexture,
		itemColor = row.itemColor,
		quality = row.quality,
		count = row.count,
		slot = row.slot,
		order = row.order,
		state = row.state,
		rollType = row.rollType,
		duration = row.duration,
		winnerName = row.winnerName,
		rollValue = row.rollValue,
		reason = row.reason,
		remaining = row.remaining,
		tieNamesText = row.tieNamesText,
		protocolVersion = row.protocolVersion or PROTOCOL_VERSION,
		sessionId = row.sessionId or state.sessionId,
		sender = row.sender,
	}
end

local function upsertRow(data, reason)
	if type(data) ~= "table" then
		return nil
	end

	local itemKey = resolveItemKey(data.itemKey or data.key or data.itemLink, data.itemLink)
	if not itemKey then
		return nil
	end

	local row = getOrCreateRow(itemKey)
	row.itemKey = itemKey
	row.sessionId = data.sessionId or row.sessionId or state.sessionId
	row.itemLink = normalizeText(data.itemLink, true) or row.itemLink
	row.itemName = normalizeText(data.itemName or data.name, true) or row.itemName
	row.itemTexture = normalizeText(data.itemTexture or data.texture, true) or row.itemTexture
	row.itemColor = normalizeText(data.itemColor or data.color, true) or row.itemColor
	row.quality = normalizeNumber(data.quality or data.itemRarity or data.rarity) or row.quality
	row.count = normalizeNumber(data.count or data.itemCount) or row.count or 1
	row.slot = normalizeNumber(data.slot or data.index) or row.slot
	row.sender = normalizeText(data.sender, true) or row.sender
	row.protocolVersion = normalizeNumber(data.protocolVersion) or row.protocolVersion or PROTOCOL_VERSION

	if data.rollType ~= nil then
		row.rollType = normalizeNumber(data.rollType) or data.rollType
	end
	if data.duration ~= nil then
		row.duration = normalizeNumber(data.duration)
	end
	if data.winnerName ~= nil then
		row.winnerName = normalizeText(data.winnerName, true)
	end
	if data.rollValue ~= nil then
		row.rollValue = normalizeNumber(data.rollValue)
	end
	if data.reason ~= nil then
		row.reason = normalizeText(data.reason, true)
	end
	if data.remaining ~= nil then
		row.remaining = normalizeNumber(data.remaining)
	end
	if data.tieNamesText ~= nil then
		row.tieNamesText = normalizeText(data.tieNamesText, true)
	end

	if data.state then
		row.state = data.state
	elseif not row.state then
		row.state = STATE_ACTIVE
	end

	local snapshot = copyRow(row)
	triggerChanged(reason, snapshot)
	return row
end

local function clearState(sessionId)
	state.sessionId = normalizeText(sessionId, true) or buildSessionId()
	state.order = {}
	state.itemsByKey = {}
	triggerChanged("clear", nil)
end

local function sendMessage(...)
	ensurePrefix()
	local ok = SendSync(PREFIX, packFields(...))
	return ok == true
end

local function publishMessage(...)
	if not canPublish() then
		return false
	end
	return sendMessage(...)
end

local function sendDirect(channel, target, ...)
	ensurePrefix()
	return QueueAddonMessage(PREFIX, packFields(...), channel, target)
end

local function isSupportedVersion(version)
	local numeric = tonumber(version)
	if numeric == PROTOCOL_VERSION then
		return true
	end
	if addon.hasDebug and Diag and Diag.W and Diag.W.LogDistributionUnsupportedVersion then
		addon:warn(Diag.W.LogDistributionUnsupportedVersion:format(tostring(version)))
	end
	return false
end

local function encodeSnapshot()
	local rows = {}
	for i = 1, #state.order do
		local row = state.itemsByKey[state.order[i]]
		if row then
			rows[#rows + 1] = packFields(
				row.itemKey,
				row.count or 1,
				row.quality or "",
				encodeText(row.itemLink),
				encodeText(row.itemName),
				encodeText(row.itemTexture),
				row.slot or "",
				row.state or "",
				row.rollType or "",
				row.duration or "",
				encodeText(row.winnerName),
				row.rollValue or "",
				encodeText(row.reason),
				row.remaining or "",
				encodeText(row.tieNamesText)
			)
		end
	end
	return encodeText(tconcat(rows, SNAP_ROW_SEP))
end

local function countSnapshotRows()
	local count = 0
	for i = 1, #state.order do
		if state.itemsByKey[state.order[i]] then
			count = count + 1
		end
	end
	return count
end

local function publishItemRow(row)
	return publishMessage(
		MSG_ITEM,
		PROTOCOL_VERSION,
		ensureSessionId(),
		row.itemKey,
		row.count or 1,
		row.quality or "",
		encodeText(row.itemLink),
		encodeText(row.itemName),
		encodeText(row.itemTexture),
		row.slot or ""
	)
end

local function publishRollStartRow(row)
	return publishMessage(
		MSG_ROLL_START,
		PROTOCOL_VERSION,
		ensureSessionId(),
		row.itemKey,
		row.rollType or "",
		row.duration or ""
	)
end

local function publishRollEndRow(row)
	return publishMessage(
		MSG_ROLL_END,
		PROTOCOL_VERSION,
		ensureSessionId(),
		row.itemKey,
		encodeText(row.winnerName),
		row.rollValue or "",
		encodeText(row.reason)
	)
end

local function publishItemDoneRow(row)
	return publishMessage(MSG_ITEM_DONE, PROTOCOL_VERSION, ensureSessionId(), row.itemKey, encodeText(row.winnerName))
end

local function handleItemMessage(fields, sender)
	if not isSupportedVersion(fields[2]) then
		return true
	end
	local sessionId = setSessionId(fields[3])
	local row = upsertRow({
		sessionId = sessionId,
		itemKey = fields[4],
		count = fields[5],
		quality = fields[6],
		itemLink = decodeText(fields[7]),
		itemName = decodeText(fields[8]),
		itemTexture = decodeText(fields[9]),
		slot = fields[10],
		state = STATE_ACTIVE,
		sender = sender,
	}, "item")
	return row ~= nil
end

local function handleRollStartMessage(fields, sender)
	if not isSupportedVersion(fields[2]) then
		return true
	end
	local sessionId = setSessionId(fields[3])
	local row = upsertRow({
		sessionId = sessionId,
		itemKey = fields[4],
		rollType = fields[5],
		duration = fields[6],
		state = STATE_ROLLING,
		sender = sender,
	}, "roll_start")
	return row ~= nil
end

local function handleRollEndMessage(fields, sender)
	if not isSupportedVersion(fields[2]) then
		return true
	end
	local sessionId = setSessionId(fields[3])
	local winnerName = decodeText(fields[5])
	local row = upsertRow({
		sessionId = sessionId,
		itemKey = fields[4],
		winnerName = winnerName,
		rollValue = fields[6],
		reason = decodeText(fields[7]),
		state = normalizeText(winnerName, true) and STATE_WINNER or STATE_ACTIVE,
		sender = sender,
	}, "roll_end")
	return row ~= nil
end

local function handleItemDoneMessage(fields, sender)
	if not isSupportedVersion(fields[2]) then
		return true
	end
	local sessionId = setSessionId(fields[3])
	local row = upsertRow({
		sessionId = sessionId,
		itemKey = fields[4],
		winnerName = decodeText(fields[5]),
		state = STATE_DONE,
		sender = sender,
	}, "item_done")
	return row ~= nil
end

local function handleRollTickMessage(fields, sender)
	if not isSupportedVersion(fields[2]) then
		return true
	end
	local sessionId = setSessionId(fields[3])
	local row = upsertRow({
		protocolVersion = fields[2],
		sessionId = sessionId,
		itemKey = fields[4],
		remaining = fields[5],
		state = STATE_ROLLING,
		sender = sender,
	}, "roll_tick")
	return row ~= nil
end

local function handleTieStartMessage(fields, sender)
	if not isSupportedVersion(fields[2]) then
		return true
	end
	local sessionId = setSessionId(fields[3])
	local row = upsertRow({
		protocolVersion = fields[2],
		sessionId = sessionId,
		itemKey = fields[4],
		tieNamesText = decodeText(fields[5]),
		state = STATE_WINNER,
		sender = sender,
	}, "tie_start")
	return row ~= nil
end

local function handleAwardedMessage(fields, sender)
	if not isSupportedVersion(fields[2]) then
		return true
	end
	local sessionId = setSessionId(fields[3])
	local row = upsertRow({
		protocolVersion = fields[2],
		sessionId = sessionId,
		itemKey = fields[4],
		winnerName = decodeText(fields[5]),
		rollValue = fields[6],
		state = STATE_AWARDED,
		sender = sender,
	}, "awarded")
	return row ~= nil
end

local function applySnapshot(protocolVersion, sessionId, decodedSnapshot, sender)
	protocolVersion = normalizeNumber(protocolVersion)
	if protocolVersion ~= PROTOCOL_VERSION then
		return true
	end

	local rows, rowCount = splitText(decodedSnapshot, SNAP_ROW_SEP, snapshotRowsScratch)
	local applied = 0

	clearState(sessionId)
	for i = 1, rowCount do
		local rowText = rows[i]
		if rowText and rowText ~= "" then
			local rowFields = splitText(rowText, SEP, snapshotFieldScratch)
			local row = upsertRow({
				protocolVersion = protocolVersion,
				sessionId = sessionId,
				itemKey = rowFields[1],
				count = rowFields[2],
				quality = rowFields[3],
				itemLink = decodeText(rowFields[4]),
				itemName = decodeText(rowFields[5]),
				itemTexture = decodeText(rowFields[6]),
				slot = rowFields[7],
				state = normalizeText(rowFields[8], true) or STATE_ACTIVE,
				rollType = rowFields[9],
				duration = rowFields[10],
				winnerName = decodeText(rowFields[11]),
				rollValue = rowFields[12],
				reason = decodeText(rowFields[13]),
				remaining = rowFields[14],
				tieNamesText = decodeText(rowFields[15]),
				sender = sender,
			}, "snapshot")
			if row then
				applied = applied + 1
			end
		end
	end

	if addon.hasDebug and Diag and Diag.D and Diag.D.LogDistributionSnapshotApplied then
		addon:debug(Diag.D.LogDistributionSnapshotApplied:format(applied, tostring(sender or "?")))
	end
	return true
end

local function handleSnapshotMessage(fields, sender)
	if not isSupportedVersion(fields[2]) then
		return true
	end

	local protocolVersion = normalizeNumber(fields[2])
	local sessionId = normalizeText(fields[4], true) or buildSessionId()
	local decoded = decodeText(fields[5])
	return applySnapshot(protocolVersion, sessionId, decoded, sender)
end

local function handleSnapshotChunkMessage(fields, sender)
	cleanupIncomingSnapshots()

	local protocolVersion = tonumber(fields[2])
	if protocolVersion ~= PROTOCOL_VERSION then
		return true
	end

	local requestId = normalizeText(fields[3], true) or ""
	local sessionId = normalizeText(fields[4], true) or buildSessionId()
	local chunkIndex = tonumber(fields[5])
	local totalChunks = tonumber(fields[6])
	local chunk = fields[7] or ""
	local chunkLength = string.len(chunk)

	if
		not (chunkIndex and chunkIndex > 0 and totalChunks and totalChunks > 0 and totalChunks <= MAX_SNAPSHOT_CHUNKS)
	then
		return true
	end
	if chunkIndex > totalChunks then
		return true
	end

	local key = tostring(sender or "?") .. "|" .. requestId .. "|" .. sessionId
	if chunkLength > MAX_SNAPSHOT_CHUNK_SIZE then
		incomingSnapshots[key] = nil
		return true
	end

	local snapshotState = incomingSnapshots[key]
	local priorTotal = tonumber(snapshotState and snapshotState.total)
	if snapshotState then
		local totalMismatch = priorTotal ~= totalChunks
		local isMalformed = type(snapshotState.chunks) ~= "table"
			or type(snapshotState.received) ~= "number"
			or type(snapshotState.chunkBytes) ~= "table"
			or type(snapshotState.bytes) ~= "number"
		if totalMismatch or isMalformed then
			incomingSnapshots[key] = nil
			snapshotState = nil
			return true
		end
	end
	if type(snapshotState) ~= "table" or snapshotState.total ~= totalChunks then
		snapshotState = {
			total = totalChunks,
			chunks = {},
			received = 0,
			chunkBytes = {},
			bytes = 0,
			createdAt = getIncomingNow(),
		}
		incomingSnapshots[key] = snapshotState
	end

	local priorLength = tonumber(snapshotState.chunkBytes[chunkIndex])
	local nextBytes = snapshotState.bytes or 0
	if priorLength then
		nextBytes = nextBytes - priorLength
	else
		snapshotState.received = (snapshotState.received or 0) + 1
	end
	nextBytes = nextBytes + chunkLength
	if nextBytes > MAX_INCOMING_SNAPSHOT_BYTES then
		incomingSnapshots[key] = nil
		return true
	end

	snapshotState.chunks[chunkIndex] = chunk
	snapshotState.chunkBytes[chunkIndex] = chunkLength
	snapshotState.bytes = nextBytes
	snapshotState.received = snapshotState.received or 0

	if snapshotState.createdAt == nil then
		snapshotState.createdAt = getIncomingNow()
	end

	if snapshotState.received < totalChunks then
		return true
	end

	local encoded = {}
	for i = 1, totalChunks do
		encoded[i] = snapshotState.chunks[i] or ""
	end
	incomingSnapshots[key] = nil

	local decoded = decodeText(tconcat(encoded))
	return applySnapshot(protocolVersion, sessionId, decoded, sender)
end

-- ----- Public methods ----- --

function DistributionSession.Clear()
	if not canPublish() then
		return false
	end
	local sessionId = buildSessionId()
	clearState(sessionId)
	return publishMessage(MSG_CLEAR, PROTOCOL_VERSION, sessionId)
end

function DistributionSession.PublishItem(item)
	if not canPublish() then
		return false
	end
	local row = upsertRow(item, "item")
	if not row then
		return false
	end
	if row.state ~= STATE_ROLLING and row.state ~= STATE_WINNER and row.state ~= STATE_DONE then
		row.state = STATE_ACTIVE
	end
	return publishItemRow(row)
end

function DistributionSession.PublishWindowItems(items)
	if type(items) ~= "table" or not canPublish() then
		return false
	end

	local sent = false
	for i = 1, #items do
		if DistributionSession.PublishItem(items[i]) then
			sent = true
		end
	end
	return sent
end

function DistributionSession.PublishRollStart(itemKeyOrLink, rollType, duration)
	if not canPublish() then
		return false
	end
	local itemKey = resolveItemKey(itemKeyOrLink, itemKeyOrLink)
	if not itemKey then
		return false
	end

	local row = upsertRow({
		itemKey = itemKey,
		rollType = rollType,
		duration = duration,
		state = STATE_ROLLING,
	}, "roll_start")
	if not row then
		return false
	end
	return publishRollStartRow(row)
end

function DistributionSession.PublishRollEnd(itemKeyOrLink, winnerName, rollValue, reason)
	if not canPublish() then
		return false
	end
	local itemKey = resolveItemKey(itemKeyOrLink, itemKeyOrLink)
	if not itemKey then
		return false
	end

	local row = upsertRow({
		itemKey = itemKey,
		winnerName = winnerName,
		rollValue = rollValue,
		reason = reason,
		state = STATE_WINNER,
	}, "roll_end")
	if not row then
		return false
	end
	return publishRollEndRow(row)
end

function DistributionSession.PublishItemDone(itemKeyOrLink, winnerName)
	if not canPublish() then
		return false
	end
	local itemKey = resolveItemKey(itemKeyOrLink, itemKeyOrLink)
	if not itemKey then
		return false
	end

	local row = upsertRow({
		itemKey = itemKey,
		winnerName = winnerName,
		state = STATE_DONE,
	}, "item_done")
	if not row then
		return false
	end
	return publishItemDoneRow(row)
end

function DistributionSession.RequestSnapshot()
	return publishMessage(MSG_SNAPSHOT_REQ, PROTOCOL_VERSION, ensureSessionId())
end

function DistributionSession.PublishSnapshot(target, requestId)
	if not canPublish() then
		return false
	end

	local sessionId = ensureSessionId()
	local snapshot = encodeSnapshot()
	local snapshotLength = string.len(snapshot or "")
	if snapshotLength <= MAX_SNAPSHOT_CHUNK_SIZE then
		local sent
		if target and target ~= "" then
			sent = sendDirect("WHISPER", target, MSG_SNAPSHOT, PROTOCOL_VERSION, requestId or "", sessionId, snapshot)
		else
			sent = publishMessage(MSG_SNAPSHOT, PROTOCOL_VERSION, requestId or "", sessionId, snapshot)
		end
		if sent and addon.hasDebug and Diag and Diag.D and Diag.D.LogDistributionSnapshotSent then
			addon:debug(Diag.D.LogDistributionSnapshotSent:format(countSnapshotRows(), tostring(target or "group")))
		end
		return sent == true
	end

	local chunkCount = math.ceil(snapshotLength / MAX_SNAPSHOT_CHUNK_SIZE)
	if chunkCount > MAX_SNAPSHOT_CHUNKS then
		return false
	end

	local sentAll = true
	for chunkIndex = 1, chunkCount do
		local chunkStart = ((chunkIndex - 1) * MAX_SNAPSHOT_CHUNK_SIZE) + 1
		local chunkEnd = chunkIndex * MAX_SNAPSHOT_CHUNK_SIZE
		local chunk = snapshot:sub(chunkStart, chunkEnd)
		local sent
		if target and target ~= "" then
			sent = sendDirect(
				"WHISPER",
				target,
				MSG_SNAPSHOT_CHUNK,
				PROTOCOL_VERSION,
				requestId or "",
				sessionId,
				chunkIndex,
				chunkCount,
				chunk
			)
		else
			sent = publishMessage(
				MSG_SNAPSHOT_CHUNK,
				PROTOCOL_VERSION,
				requestId or "",
				sessionId,
				chunkIndex,
				chunkCount,
				chunk
			)
		end
		if sent ~= true then
			sentAll = false
		end
	end

	if sentAll and addon.hasDebug and Diag and Diag.D and Diag.D.LogDistributionSnapshotSent then
		addon:debug(Diag.D.LogDistributionSnapshotSent:format(countSnapshotRows(), tostring(target or "group")))
	end
	return sentAll == true
end

function DistributionSession.PublishRollTick(itemKeyOrLink, remaining)
	if not canPublish() then
		return false
	end
	local itemKey = resolveItemKey(itemKeyOrLink, itemKeyOrLink)
	local row = upsertRow({
		itemKey = itemKey,
		remaining = remaining,
		state = STATE_ROLLING,
	}, "roll_tick")
	if not row then
		return false
	end
	return publishMessage(MSG_ROLL_TICK, PROTOCOL_VERSION, ensureSessionId(), row.itemKey, row.remaining or "")
end

function DistributionSession.PublishTieStart(itemKeyOrLink, names)
	if not canPublish() then
		return false
	end
	local itemKey = resolveItemKey(itemKeyOrLink, itemKeyOrLink)
	local tieNamesText = type(names) == "table" and tconcat(names, ",") or tostring(names or "")
	local row = upsertRow({
		itemKey = itemKey,
		tieNamesText = tieNamesText,
		state = STATE_WINNER,
	}, "tie_start")
	if not row then
		return false
	end
	return publishMessage(MSG_TIE_START, PROTOCOL_VERSION, ensureSessionId(), row.itemKey, encodeText(tieNamesText))
end

function DistributionSession.PublishAwarded(itemKeyOrLink, winnerName, rollValue)
	if not canPublish() then
		return false
	end
	local itemKey = resolveItemKey(itemKeyOrLink, itemKeyOrLink)
	local row = upsertRow({
		itemKey = itemKey,
		winnerName = winnerName,
		rollValue = rollValue,
		state = STATE_AWARDED,
	}, "awarded")
	if not row then
		return false
	end
	return publishMessage(
		MSG_AWARDED,
		PROTOCOL_VERSION,
		ensureSessionId(),
		row.itemKey,
		encodeText(winnerName),
		row.rollValue or ""
	)
end

function DistributionSession.HandleMessage(prefix, msg, _channel, sender)
	if prefix ~= PREFIX then
		return false
	end

	local fields = splitFields(msg)
	local kind = fields[1]
	if kind == MSG_CLEAR then
		if not isSupportedVersion(fields[2]) then
			return true
		end
		clearState(fields[3])
		return true
	end
	if kind == MSG_ITEM then
		return handleItemMessage(fields, sender)
	end
	if kind == MSG_ROLL_START then
		return handleRollStartMessage(fields, sender)
	end
	if kind == MSG_ROLL_END then
		return handleRollEndMessage(fields, sender)
	end
	if kind == MSG_ITEM_DONE then
		return handleItemDoneMessage(fields, sender)
	end
	if kind == MSG_HELLO then
		return isSupportedVersion(fields[2])
	end
	if kind == MSG_SNAPSHOT_REQ then
		if not isSupportedVersion(fields[2]) then
			return true
		end
		return DistributionSession.PublishSnapshot(sender, fields[3])
	end
	if kind == MSG_SNAPSHOT then
		return handleSnapshotMessage(fields, sender)
	end
	if kind == MSG_SNAPSHOT_CHUNK then
		return handleSnapshotChunkMessage(fields, sender)
	end
	if kind == MSG_ROLL_TICK then
		return handleRollTickMessage(fields, sender)
	end
	if kind == MSG_TIE_START then
		return handleTieStartMessage(fields, sender)
	end
	if kind == MSG_AWARDED then
		return handleAwardedMessage(fields, sender)
	end
	return true
end

function DistributionSession.GetDisplayModel()
	local rows = {}
	for i = 1, #state.order do
		local key = state.order[i]
		local row = key and state.itemsByKey[key] or nil
		if row then
			rows[#rows + 1] = copyRow(row)
		end
	end
	tsort(rows, function(a, b)
		local left = tonumber(a and a.slot) or tonumber(a and a.order) or 0
		local right = tonumber(b and b.slot) or tonumber(b and b.order) or 0
		if left ~= right then
			return left < right
		end
		return tostring(a and a.itemKey or "") < tostring(b and b.itemKey or "")
	end)
	return {
		prefix = PREFIX,
		protocolVersion = PROTOCOL_VERSION,
		sessionId = state.sessionId,
		rows = rows,
	}
end

ensurePrefix()

local registry = feature.ModuleRegistry
if registry and type(registry.AddModule) == "function" and type(registry.SetLoaded) == "function" then
	registry.AddModule("Services/Loot/DistributionSession", {
		deps = {
			"Init",
			"Modules/ModuleRegistry",
			"Modules/Events",
			"Modules/Bus",
			"Modules/Comms",
			"Modules/Item",
		},
	})
	registry.SetLoaded("Services/Loot/DistributionSession")
end
