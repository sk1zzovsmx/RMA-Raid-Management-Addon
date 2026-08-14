-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: direct addon namespace bindings
-- exports: addon.Services.Loot.DistributionSession
-- events: LootDistributionSessionChanged

local addon = select(2, ...)
local Database = addon.Database
local Diag = addon.Diag
local Events = addon.Events
local Bus = addon.Bus
local Comms = addon.Comms
local Item = addon.Item
local Services = addon.Services
local Strings = addon.Strings
local Payload = assert(Comms.Payload, "Loot distribution payload codec is not initialized")
local InternalEvents = assert(Events.Internal, "Loot distribution internal events are not initialized")

local _G = _G
local GetTime = assert(_G.GetTime, "Loot distribution time API is not initialized")
local GetPlayerName = assert(Database.GetPlayerName, "Loot distribution player-name resolver is not initialized")
local SendSync = assert(Comms.Sync, "Loot distribution sync sender is not initialized")
local QueueAddonMessage = assert(Comms.QueueAddonMessage, "Loot distribution direct sender is not initialized")
local DistributionChangedEvent =
	assert(InternalEvents.LootDistributionSessionChanged, "Loot distribution change event is not initialized")
local TriggerEvent = assert(Bus.TriggerEvent, "Loot distribution event bus sender is not initialized")
local Raid = assert(Services.Raid, "Loot distribution raid service is not initialized")
local IsGroupMember = assert(Raid.IsGroupMember, "Loot distribution group-membership resolver is not initialized")
local IsLootAuthority = assert(Raid.IsLootAuthority, "Loot distribution authority resolver is not initialized")
local type, tostring, tonumber, next = type, tostring, tonumber, next
local tinsert, tsort, tconcat = table.insert, table.sort, table.concat

-- ----- Internal state ----- --
addon.Services.EnsureNamespace("Loot")
local Loot = Services.Loot
Loot.DistributionSession = Loot.DistributionSession or {}
local DistributionSession = Loot.DistributionSession

local PREFIX = "RMADist"
local SEP = "|"
local PROTOCOL_VERSION = 2

local MSG_ITEM = "ITEM"
local MSG_ROLL_START = "ROLL_START"
local MSG_ROLL_END = "ROLL_END"
local MSG_ITEM_DONE = "ITEM_DONE"
local MSG_ITEM_CANCELLED = "ITEM_CANCELLED"
local MSG_CLEAR = "CLEAR"
local MSG_WINDOW_BEGIN = "WINDOW_BEGIN"
local MSG_WINDOW_ITEM = "WINDOW_ITEM"
local MSG_WINDOW_END = "WINDOW_END"
local MSG_SESSION_END = "SESSION_END"
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
local MAX_INCOMING_WINDOWS = 8
local MAX_WINDOW_ROWS = 128
local MAX_WINDOW_BYTES = 32768
local WINDOW_TTL_SECONDS = 30
local STREAM_TOMBSTONE_TTL_SECONDS = 180
local MAX_STREAM_TOMBSTONES = 64
local ACTIVE_STREAM_TTL_SECONDS = 180
local MAX_ACTIVE_STREAMS = 64
local MAX_STREAMS = 256

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
		nextRevision = 1,
		order = {},
		itemsByKey = {},
		revision = 0,
	}
	DistributionSession._state = state
end
DistributionSession._incomingSnapshots = DistributionSession._incomingSnapshots or {}
local incomingSnapshots = DistributionSession._incomingSnapshots
DistributionSession._streams = DistributionSession._streams or {}
local streams = DistributionSession._streams
local nextStreamSequence = tonumber(DistributionSession._nextStreamSequence) or 1
DistributionSession._sessionOwners = DistributionSession._sessionOwners or {}
local sessionOwners = DistributionSession._sessionOwners
local nextSessionOwner = tonumber(DistributionSession._nextSessionOwner) or 1
local trustedAuthority = type(DistributionSession._trustedAuthority) == "string"
	and DistributionSession._trustedAuthority
	or nil
local sessionEndRequested = false
local lastWindowNow = tonumber(GetTime())
assert(lastWindowNow and lastWindowNow == lastWindowNow and lastWindowNow >= 0, "Loot distribution time is invalid")

-- ----- Private helpers ----- --
local function getIncomingNow()
	return GetTime()
end

local function ensurePrefix()
	Comms.RegisterPrefixIfAvailable(PREFIX)
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

local function getOrCreateRow(itemKey, ownerState)
	ownerState = ownerState or state
	itemKey = normalizeText(itemKey, true)
	if not itemKey then
		return nil
	end

	local row = ownerState.itemsByKey[itemKey]
	if row then
		return row
	end

	row = {
		itemKey = itemKey,
		order = #ownerState.order + 1,
		state = STATE_ACTIVE,
	}
	ownerState.itemsByKey[itemKey] = row
	ownerState.order[#ownerState.order + 1] = itemKey
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
		failureReason = row.failureReason,
		remaining = row.remaining,
		tieNamesText = row.tieNamesText,
		protocolVersion = row.protocolVersion or PROTOCOL_VERSION,
		sessionId = row.sessionId or state.sessionId,
		sender = row.sender,
	}
end

local function upsertRow(data, reason, ownerState, suppressNotification)
	ownerState = ownerState or state
	if type(data) ~= "table" then
		return nil
	end

	local itemKey = resolveItemKey(data.itemKey or data.key or data.itemLink, data.itemLink)
	if not itemKey then
		return nil
	end

	local row = getOrCreateRow(itemKey, ownerState)
	row.itemKey = itemKey
	row.sessionId = data.sessionId or row.sessionId or ownerState.sessionId
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
	elseif data.clearDuration then
		row.duration = nil
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
	if data.failureReason ~= nil then
		row.failureReason = normalizeText(data.failureReason, true)
	end
	if data.clearWinner then
		row.winnerName = nil
		row.rollValue = nil
		row.reason = nil
	end
	if data.remaining ~= nil then
		row.remaining = normalizeNumber(data.remaining)
	elseif data.clearRemaining then
		row.remaining = nil
	end
	if data.tieNamesText ~= nil then
		row.tieNamesText = normalizeText(data.tieNamesText, true)
	end

	if data.state then
		row.state = data.state
	elseif not row.state then
		row.state = STATE_ACTIVE
	end

	if not suppressNotification then
		local snapshot = copyRow(row)
		triggerChanged(reason, snapshot)
	end
	return row
end

local function clearState(sessionId)
	state.sessionId = normalizeText(sessionId, true) or buildSessionId()
	state.order = {}
	state.itemsByKey = {}
	state.revision = 0
	state.ownerKey = nil
	state.ownerSender = nil
	state.transitionSender = nil
	triggerChanged("clear", nil)
end
state.nextRevision = tonumber(state.nextRevision) or 1

local function incomingWindowKey(sender, sessionId)
	return tostring(sender or "?") .. "|" .. tostring(sessionId or "")
end

local function validRevision(value)
	local revision = tonumber(value)
	if
		not revision
		or revision ~= revision
		or revision <= 0
		or revision >= math.huge
		or revision ~= math.floor(revision)
	then
		return nil
	end
	return revision
end

local function validExpectedRows(value)
	local expectedRows = tonumber(value)
	if
		not expectedRows
		or expectedRows ~= expectedRows
		or expectedRows < 0
		or expectedRows > MAX_WINDOW_ROWS
		or expectedRows ~= math.floor(expectedRows)
	then
		return nil
	end
	return expectedRows
end

local MAX_SAFE_INTEGER = 9007199254740991

local function parseGeneratedSessionId(sessionId, authority)
	local owner, ordinalText, timeText = tostring(sessionId or ""):match("^([^:]+):(%d+):([%d%.]+)$")
	if not owner or owner == "" or owner ~= authority then
		return nil
	end
	local ordinal = tonumber(ordinalText)
	local timestamp = tonumber(timeText)
	if
		not ordinal
		or ordinal ~= ordinal
		or ordinal < 1
		or ordinal > MAX_SAFE_INTEGER
		or ordinal ~= math.floor(ordinal)
		or not timestamp
		or timestamp ~= timestamp
		or timestamp < 0
		or timestamp >= math.huge
	then
		return nil
	end
	return ordinal, timestamp
end

local function isNewerSessionId(candidate, current, authority)
	local candidateOrdinal, candidateTime = parseGeneratedSessionId(candidate, authority)
	local currentOrdinal, currentTime = parseGeneratedSessionId(current, authority)
	if not candidateOrdinal or not currentOrdinal then
		return false
	end
	return candidateTime > currentTime
		or (candidateTime == currentTime and candidateOrdinal > currentOrdinal)
end

local function canReplaceOwnerSession(sender, sessionId)
	if not state.sessionId or sessionId == state.sessionId then
		return true
	end
	local currentSender = state.ownerSender or state.transitionSender
	if currentSender and currentSender ~= sender then
		return parseGeneratedSessionId(sessionId, sender) ~= nil
	end
	if not currentSender and not parseGeneratedSessionId(state.sessionId, sender) then
		return parseGeneratedSessionId(sessionId, sender) ~= nil
	end
	return isNewerSessionId(sessionId, state.sessionId, sender)
end

local function boundedNow()
	local now = tonumber(GetTime())
	if not now or now ~= now or now < 0 or now >= math.huge then
		return lastWindowNow
	end
	if now < lastWindowNow then
		return lastWindowNow
	end
	lastWindowNow = now
	return now
end

local function clearOwnedDisplay(key)
	if state.ownerKey ~= key then
		return
	end
	state.order = {}
	state.itemsByKey = {}
	state.ownerKey = nil
	triggerChanged("session_expired", nil)
end

local function takeStreamSequence()
	local sequence = nextStreamSequence
	nextStreamSequence = sequence + 1
	DistributionSession._nextStreamSequence = nextStreamSequence
	return sequence
end

local function removeStreamIfEmpty(key, stream)
	if
		stream
		and not stream.window
		and not stream.committedRevision
		and not stream.tombstoneRevision
		and not stream.atomicSeenAt
	then
		streams[key] = nil
	end
end

local function findOldestStream(field, timestampField, sequenceField)
	local count, oldestKey, oldestAt, oldestSequence = 0, nil, nil, nil
	for key, stream in pairs(streams) do
		if not field or stream[field] then
			count = count + 1
			local timestamp = tonumber(stream[timestampField]) or 0
			local sequence = tonumber(stream[sequenceField]) or 0
			if not oldestAt or timestamp < oldestAt or (timestamp == oldestAt and sequence < oldestSequence) then
				oldestKey, oldestAt, oldestSequence = key, timestamp, sequence
			end
		end
	end
	return count, oldestKey
end

local function retireActiveStream(key, stream, createTombstone, now)
	local revision = tonumber(stream and stream.committedRevision)
	if not stream then
		return
	end
	stream.committedRevision = nil
	stream.lastActivity = nil
	clearOwnedDisplay(key)
	if createTombstone and revision then
		stream.tombstoneRevision = revision
		stream.endedAt = now or boundedNow()
		stream.tombstoneSequence = takeStreamSequence()
		local count, oldestKey = findOldestStream("tombstoneRevision", "endedAt", "tombstoneSequence")
		if count > MAX_STREAM_TOMBSTONES and oldestKey then
			local oldest = streams[oldestKey]
			oldest.tombstoneRevision, oldest.endedAt = nil, nil
			removeStreamIfEmpty(oldestKey, oldest)
		end
	end
	removeStreamIfEmpty(key, stream)
end

local function cleanupStreams()
	local now = boundedNow()
	for key, stream in pairs(streams) do
		local createdAt = tonumber(stream.window and stream.window.createdAt)
		if stream.window and (not createdAt or (now >= createdAt and (now - createdAt) >= WINDOW_TTL_SECONDS)) then
			stream.window = nil
		end
		local lastActivity = tonumber(stream.lastActivity)
		if stream.committedRevision and (not lastActivity or (now >= lastActivity and (now - lastActivity) >= ACTIVE_STREAM_TTL_SECONDS)) then
			retireActiveStream(key, stream, true, now)
		end
		local endedAt = tonumber(stream.endedAt)
		if stream.tombstoneRevision and (not endedAt or (now >= endedAt and (now - endedAt) >= STREAM_TOMBSTONE_TTL_SECONDS)) then
			stream.tombstoneRevision = nil
			stream.endedAt = nil
		end
		local atomicSeenAt = tonumber(stream.atomicSeenAt)
		if stream.atomicSeenAt and (not atomicSeenAt or (now >= atomicSeenAt and (now - atomicSeenAt) >= ACTIVE_STREAM_TTL_SECONDS)) then
			stream.atomicSeenAt = nil
		end
		removeStreamIfEmpty(key, stream)
	end
end

local function ensureStream(key)
	local stream = streams[key]
	if stream then
		return stream
	end
	cleanupStreams()
	local count, oldestKey, oldestPriority, oldestAt, oldestSequence = 0, nil, nil, nil, nil
	for candidateKey, candidate in pairs(streams) do
		count = count + 1
		local priority
		if candidate.committedRevision then
			priority = candidateKey == state.ownerKey and 4 or 3
		elseif candidate.atomicSeenAt and not candidate.window and not candidate.tombstoneRevision then
			priority = 1
		else
			priority = 2
		end
		local seenAt = tonumber(candidate.lastSeenAt) or 0
		local sequence = tonumber(candidate.lastSeenSequence) or 0
		if
			not oldestPriority
			or priority < oldestPriority
			or (priority == oldestPriority and seenAt < oldestAt)
			or (priority == oldestPriority and seenAt == oldestAt and sequence < oldestSequence)
		then
			oldestKey, oldestPriority, oldestAt, oldestSequence = candidateKey, priority, seenAt, sequence
		end
	end
	if count >= MAX_STREAMS and oldestKey then
		clearOwnedDisplay(oldestKey)
		streams[oldestKey] = nil
	end
	stream = { lastSeenAt = boundedNow(), lastSeenSequence = takeStreamSequence() }
	streams[key] = stream
	return stream
end

local function addStreamTombstone(key, revision)
	cleanupStreams()
	local count, oldestKey = findOldestStream("tombstoneRevision", "endedAt", "tombstoneSequence")
	if count >= MAX_STREAM_TOMBSTONES and oldestKey ~= key then
		local oldest = streams[oldestKey]
		oldest.tombstoneRevision, oldest.endedAt = nil, nil
		removeStreamIfEmpty(oldestKey, oldest)
	end
	local stream = ensureStream(key)
	stream.tombstoneRevision = revision
	stream.endedAt = boundedNow()
	stream.tombstoneSequence = takeStreamSequence()
	stream.lastSeenAt = stream.endedAt
	stream.lastSeenSequence = stream.tombstoneSequence
end

local function touchActiveStream(key, revision)
	cleanupStreams()
	local stream = ensureStream(key)
	if not stream.committedRevision then
		local count, oldestKey = findOldestStream("committedRevision", "lastActivity", "activeSequence")
		if count >= MAX_ACTIVE_STREAMS and oldestKey then
			retireActiveStream(oldestKey, streams[oldestKey], true)
		end
	end
	stream.committedRevision = revision
	stream.lastActivity = boundedNow()
	stream.activeSequence = takeStreamSequence()
	stream.lastSeenAt = stream.lastActivity
	stream.lastSeenSequence = stream.activeSequence
	stream.tombstoneRevision = nil
	stream.endedAt = nil
end

local function tombstoneSupersededOwner(nextKey)
	local previousKey = state.ownerKey
	if not previousKey or previousKey == nextKey then
		return
	end
	local previous = streams[previousKey]
	local previousRevision = tonumber(previous and previous.committedRevision) or 0
	addStreamTombstone(previousKey, previousRevision)
	previous = streams[previousKey]
	if previous then
		previous.committedRevision = nil
		previous.lastActivity = nil
		previous.window = nil
	end
end

local function removeIncomingWindow(key)
	local stream = streams[key]
	if stream then
		stream.window = nil
		removeStreamIfEmpty(key, stream)
	end
end

local function stageIncomingWindow(sender, sessionId, revision, expectedRows)
	local key = incomingWindowKey(sender, sessionId)
	cleanupStreams()
	local stream = ensureStream(key)
	if not stream.window then
		local count, oldestKey, oldestAt, oldestSequence = 0, nil, nil, nil
		for candidateKey, candidate in pairs(streams) do
			if candidate.window then
				count = count + 1
				local createdAt = tonumber(candidate.window.createdAt) or 0
				local sequence = tonumber(candidate.window.sequence) or 0
				if not oldestAt or createdAt < oldestAt or (createdAt == oldestAt and sequence < oldestSequence) then
					oldestKey, oldestAt, oldestSequence = candidateKey, createdAt, sequence
				end
			end
		end
		if count >= MAX_INCOMING_WINDOWS and oldestKey then
			streams[oldestKey].window = nil
			removeStreamIfEmpty(oldestKey, streams[oldestKey])
		end
	end
	local now = boundedNow()
	stream.window = {
		sessionId = sessionId,
		revision = revision,
		order = {},
		itemsByKey = {},
		bytes = 0,
		expectedRows = expectedRows,
		createdAt = now,
		sequence = takeStreamSequence(),
	}
	stream.atomicSeenAt = now
	stream.lastSeenAt = now
	stream.lastSeenSequence = stream.window.sequence
	return stream.window
end

local function acceptIncomingMutation(sender, sessionId, revision, messageState)
	sender = normalizeText(sender, true)
	sessionId = normalizeText(sessionId, true)
	if not sender or sender ~= trustedAuthority then
		return nil, "untrusted_authority"
	end
	if not sessionId then
		return nil, "invalid_session"
	end
	local key = incomingWindowKey(sender, sessionId)
	local stream = streams[key]
	if stream and stream.tombstoneRevision then
		return nil, "session_ended"
	end
	if messageState == "snapshot" then
		if stream and (stream.atomicSeenAt or stream.window or stream.committedRevision) then
			return nil, "atomic_stream_active"
		end
		if state.ownerKey and key ~= state.ownerKey and sender == state.ownerSender then
			return nil, "session_transition_required"
		end
		if
			not state.ownerKey
			and state.sessionId
			and sessionId ~= state.sessionId
			and (not state.transitionSender or sender == state.transitionSender)
		then
			return nil, "session_transition_required"
		end
		return true, key, stream
	end
	if messageState == "clear" then
		if
			state.sessionId
			and sessionId ~= state.sessionId
			and not canReplaceOwnerSession(sender, sessionId)
		then
			return nil, "stale_session"
		end
		return true, key, stream
	end
	if messageState == "legacy" then
		if state.ownerKey and key ~= state.ownerKey then
			return nil, "session_not_active"
		end
		return true, key, stream
	end
	if not canReplaceOwnerSession(sender, sessionId) then
		return nil, "session_not_active"
	end
	revision = validRevision(revision)
	if not revision then
		return nil, "invalid_revision"
	end
	local committedRevision = tonumber(stream and stream.committedRevision)
	if messageState == "window_begin" then
		if committedRevision and revision ~= committedRevision + 1 then
			return nil, revision <= committedRevision and "stale_revision" or "revision_gap"
		end
		local stagedRevision = tonumber(stream and stream.window and stream.window.revision)
		if stagedRevision and revision < stagedRevision then
			return nil, "stale_revision"
		end
		return true, key, stream, revision
	end
	if messageState == "window_item" or messageState == "window_end" then
		local window = stream and stream.window
		if not window or revision ~= window.revision then
			return nil, "window_not_staged"
		end
		if committedRevision and revision ~= committedRevision + 1 then
			return nil, "revision_gap"
		end
		return true, key, stream, revision
	end
	if messageState == "session_end" then
		if key ~= state.ownerKey or not committedRevision or revision ~= committedRevision then
			return nil, "session_not_active"
		end
		return true, key, stream, revision
	end
	return nil, "invalid_message_state"
end

local function cleanupIncomingWindows()
	cleanupStreams()
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

local function publishWindowItemRow(row, revision)
	return publishMessage(
		MSG_WINDOW_ITEM,
		PROTOCOL_VERSION,
		ensureSessionId(),
		revision,
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

local function publishItemCancelledRow(row, winnerName)
	return publishMessage(
		MSG_ITEM_CANCELLED,
		PROTOCOL_VERSION,
		ensureSessionId(),
		row.itemKey,
		encodeText(winnerName),
		encodeText(row.failureReason)
	)
end

local function handleItemMessage(fields, sender)
	if not isSupportedVersion(fields[2]) then
		return true
	end
	local sessionId = normalizeText(fields[3], true)
	if not acceptIncomingMutation(sender, sessionId, nil, "legacy") then
		return true
	end
	local streamKey = incomingWindowKey(sender, sessionId)
	local stream = streams[streamKey]
	if stream and (stream.atomicSeenAt or stream.window or stream.committedRevision) then
		return true
	end
	sessionId = setSessionId(sessionId)
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

local function handleWindowItemMessage(fields, sender, messageBytes)
	if not isSupportedVersion(fields[2]) then
		return true
	end
	cleanupIncomingWindows()
	local sessionId = normalizeText(fields[3], true)
	local accepted, key, stream = acceptIncomingMutation(sender, sessionId, fields[4], "window_item")
	if not accepted then
		return true
	end
	local window = stream.window
	window.bytes = (tonumber(window.bytes) or 0) + (tonumber(messageBytes) or 0)
	if window.bytes > MAX_WINDOW_BYTES or #window.order >= MAX_WINDOW_ROWS then
		removeIncomingWindow(key)
		return true
	end
	local itemKey = resolveItemKey(fields[5], decodeText(fields[8]))
	if not itemKey or window.itemsByKey[itemKey] then
		removeIncomingWindow(key)
		return true
	end
	local row = upsertRow({
		protocolVersion = fields[2],
		sessionId = sessionId,
		itemKey = fields[5],
		count = fields[6],
		quality = fields[7],
		itemLink = decodeText(fields[8]),
		itemName = decodeText(fields[9]),
		itemTexture = decodeText(fields[10]),
		slot = fields[11],
		state = STATE_ACTIVE,
		sender = sender,
	}, "window_item", window, true)
	return row ~= nil
end

local function handleWindowBeginMessage(fields, sender)
	if not isSupportedVersion(fields[2]) then
		return true
	end
	cleanupIncomingWindows()
	local sessionId = normalizeText(fields[3], true)
	local expectedRows = fields[5] ~= nil and validExpectedRows(fields[5]) or nil
	if fields[5] ~= nil and expectedRows == nil then
		return true
	end
	local accepted, _, _, revision = acceptIncomingMutation(sender, sessionId, fields[4], "window_begin")
	if not accepted then
		return true
	end
	stageIncomingWindow(sender, sessionId, revision, expectedRows)
	return true
end

local function handleWindowEndMessage(fields, sender)
	if not isSupportedVersion(fields[2]) then
		return true
	end
	local sessionId = normalizeText(fields[3], true)
	local accepted, key, stream, revision = acceptIncomingMutation(sender, sessionId, fields[4], "window_end")
	if not accepted then
		return true
	end
	local window = stream.window
	if window.expectedRows ~= nil and #window.order ~= window.expectedRows then
		removeIncomingWindow(key)
		return true
	end
	tombstoneSupersededOwner(key)
	state.sessionId = sessionId
	state.revision = revision
	state.order = window.order
	state.itemsByKey = window.itemsByKey
	state.ownerKey = key
	state.ownerSender = sender
	state.transitionSender = sender
	touchActiveStream(key, revision)
	removeIncomingWindow(key)
	triggerChanged("window", nil)
	return true
end

local function handleSessionEndMessage(fields, sender)
	if not isSupportedVersion(fields[2]) then
		return true
	end
	local sessionId = normalizeText(fields[3], true)
	local accepted, key, stream, revision = acceptIncomingMutation(sender, sessionId, fields[4], "session_end")
	if accepted then
		removeIncomingWindow(key)
		addStreamTombstone(key, revision)
		stream = streams[key]
		if stream then
			stream.committedRevision = nil
			stream.lastActivity = nil
		end
		state.order = {}
		state.itemsByKey = {}
		state.revision = revision or state.revision or 0
		state.ownerKey = nil
		state.ownerSender = nil
		state.transitionSender = sender
		triggerChanged("session_end", nil)
		return true, true
	end
	return true
end

local function handleRollStartMessage(fields, sender)
	if not isSupportedVersion(fields[2]) then
		return true
	end
	local sessionId = normalizeText(fields[3], true)
	if not acceptIncomingMutation(sender, sessionId, nil, "legacy") then
		return true
	end
	sessionId = setSessionId(sessionId)
	local duration = normalizeNumber(fields[6])
	local row = upsertRow({
		protocolVersion = fields[2],
		sessionId = sessionId,
		itemKey = fields[4],
		rollType = fields[5],
		duration = duration,
		remaining = duration,
		clearDuration = duration == nil,
		clearRemaining = duration == nil,
		state = STATE_ROLLING,
		sender = sender,
	}, "roll_start")
	return row ~= nil
end

local function handleRollEndMessage(fields, sender)
	if not isSupportedVersion(fields[2]) then
		return true
	end
	local sessionId = normalizeText(fields[3], true)
	if not acceptIncomingMutation(sender, sessionId, nil, "legacy") then
		return true
	end
	sessionId = setSessionId(sessionId)
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
	local sessionId = normalizeText(fields[3], true)
	if not acceptIncomingMutation(sender, sessionId, nil, "legacy") then
		return true
	end
	sessionId = setSessionId(sessionId)
	local row = upsertRow({
		sessionId = sessionId,
		itemKey = fields[4],
		winnerName = decodeText(fields[5]),
		state = STATE_DONE,
		sender = sender,
	}, "item_done")
	return row ~= nil
end

local function handleItemCancelledMessage(fields, sender)
	if not isSupportedVersion(fields[2]) then
		return true
	end
	local sessionId = normalizeText(fields[3], true)
	if not acceptIncomingMutation(sender, sessionId, nil, "legacy") then
		return true
	end
	local row = upsertRow({
		sessionId = setSessionId(sessionId),
		itemKey = fields[4],
		winnerName = decodeText(fields[5]),
		failureReason = decodeText(fields[6]),
		clearWinner = true,
		state = STATE_ACTIVE,
		sender = sender,
	}, "item_cancelled")
	return row ~= nil
end

local function handleRollTickMessage(fields, sender)
	if not isSupportedVersion(fields[2]) then
		return true
	end
	local sessionId = normalizeText(fields[3], true)
	if not acceptIncomingMutation(sender, sessionId, nil, "legacy") then
		return true
	end
	sessionId = setSessionId(sessionId)
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
	local sessionId = normalizeText(fields[3], true)
	if not acceptIncomingMutation(sender, sessionId, nil, "legacy") then
		return true
	end
	sessionId = setSessionId(sessionId)
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
	local sessionId = normalizeText(fields[3], true)
	if not acceptIncomingMutation(sender, sessionId, nil, "legacy") then
		return true
	end
	sessionId = setSessionId(sessionId)
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

	local accepted, key = acceptIncomingMutation(sender, sessionId, nil, "snapshot")
	if not accepted then
		return true
	end
	if string.len(decodedSnapshot or "") > MAX_INCOMING_SNAPSHOT_BYTES then
		return true
	end
	local rows, rowCount = splitText(decodedSnapshot, SNAP_ROW_SEP, snapshotRowsScratch)
	if rowCount > MAX_WINDOW_ROWS then
		return true
	end
	local candidate = { sessionId = sessionId, revision = 0, order = {}, itemsByKey = {} }
	local applied = 0

	for i = 1, rowCount do
		local rowText = rows[i]
		if rowText and rowText ~= "" then
			local rowFields = splitText(rowText, SEP, snapshotFieldScratch)
			local itemKey = resolveItemKey(rowFields[1], decodeText(rowFields[4]))
			if not itemKey or candidate.itemsByKey[itemKey] then
				return true
			end
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
			}, "snapshot", candidate, true)
			if row then
				applied = applied + 1
			else
				return true
			end
		end
	end
	accepted = acceptIncomingMutation(sender, sessionId, nil, "snapshot")
	if not accepted then
		return true
	end
	tombstoneSupersededOwner(key)
	state.sessionId = sessionId
	state.revision = 0
	state.order = candidate.order
	state.itemsByKey = candidate.itemsByKey
	state.ownerKey = key
	state.ownerSender = sender
	state.transitionSender = sender
	local stream = ensureStream(key)
	stream.lastActivity = boundedNow()
	stream.lastSeenAt = stream.lastActivity
	stream.lastSeenSequence = takeStreamSequence()
	triggerChanged("snapshot", nil)

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
	local sessionId = normalizeText(fields[4], true)
	if not acceptIncomingMutation(sender, sessionId, nil, "snapshot") then
		return true
	end
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
	local sessionId = normalizeText(fields[4], true)
	if not acceptIncomingMutation(sender, sessionId, nil, "snapshot") then
		return true
	end
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
	sessionEndRequested = false
	return publishMessage(MSG_CLEAR, PROTOCOL_VERSION, sessionId)
end

function DistributionSession.BeginWindow(expectedRows)
	if not canPublish() then
		return nil, "publish_not_allowed"
	end
	expectedRows = validExpectedRows(expectedRows)
	if expectedRows == nil then
		return nil, "invalid_expected_rows"
	end
	local revision = tonumber(state.nextRevision) or 1
	if not publishMessage(MSG_WINDOW_BEGIN, PROTOCOL_VERSION, ensureSessionId(), revision, expectedRows) then
		return nil, "window_begin_send_failed"
	end
	state.revision = revision
	state.pendingWindow = { revision = revision, expectedRows = expectedRows }
	return revision
end

function DistributionSession.EndWindow(revision)
	revision = tonumber(revision)
	local pending = state.pendingWindow
	if
		not revision
		or revision ~= state.revision
		or not pending
		or pending.revision ~= revision
		or not pending.readyToEnd
	then
		return false
	end
	local sent = publishMessage(MSG_WINDOW_END, PROTOCOL_VERSION, ensureSessionId(), revision)
	if sent then
		state.pendingWindow = nil
		state.nextRevision = revision + 1
	end
	return sent
end

function DistributionSession.PublishSessionEnd()
	if not canPublish() or not state.sessionId then
		return false
	end
	local sent = publishMessage(MSG_SESSION_END, PROTOCOL_VERSION, state.sessionId, tonumber(state.revision) or 0)
	if sent then
		state.sessionId = nil
		state.order = {}
		state.itemsByKey = {}
	end
	return sent == true
end

function DistributionSession.AcquireSessionOwnership(reason)
	if not state.sessionId or sessionEndRequested then
		return nil
	end
	local token = tostring(nextSessionOwner) .. ":" .. tostring(reason or "session")
	nextSessionOwner = nextSessionOwner + 1
	DistributionSession._nextSessionOwner = nextSessionOwner
	sessionOwners[token] = true
	return token
end

function DistributionSession.RequestSessionEnd()
	if not state.sessionId then
		return false
	end
	if next(sessionOwners) then
		sessionEndRequested = true
		return false
	end
	local sent = DistributionSession.PublishSessionEnd()
	if sent then
		sessionEndRequested = false
	end
	return sent
end

function DistributionSession.ReleaseSessionOwnership(token)
	if not token or sessionOwners[token] ~= true then
		return false
	end
	if sessionEndRequested then
		local hasOtherOwner = false
		for ownerToken in pairs(sessionOwners) do
			if ownerToken ~= token then
				hasOtherOwner = true
				break
			end
		end
		if hasOtherOwner then
			sessionOwners[token] = nil
			return true
		end
		if not DistributionSession.PublishSessionEnd() then
			return false
		end
		sessionEndRequested = false
	end
	sessionOwners[token] = nil
	return true
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

function DistributionSession.PublishWindowItems(items, revision)
	if type(items) ~= "table" or not canPublish() then
		return nil, "invalid_window_items"
	end
	revision = tonumber(revision)
	local pending = state.pendingWindow
	if not revision or revision ~= state.revision or not pending or pending.revision ~= revision then
		return nil, "invalid_window_revision"
	end
	if #items ~= pending.expectedRows then
		state.pendingWindow = nil
		return nil, "window_row_count_mismatch"
	end
	local candidate = { sessionId = ensureSessionId(), order = {}, itemsByKey = {} }
	for i = 1, #items do
		local item = items[i]
		local itemKey = type(item) == "table" and resolveItemKey(item.itemKey or item.itemLink, item.itemLink) or nil
		if not itemKey or candidate.itemsByKey[itemKey] then
			state.pendingWindow = nil
			return nil, "invalid_window_item"
		end
		if not upsertRow(item, "window_item", candidate, true) then
			state.pendingWindow = nil
			return nil, "invalid_window_item"
		end
	end
	state.order = candidate.order
	state.itemsByKey = candidate.itemsByKey
	for i = 1, #candidate.order do
		local row = candidate.itemsByKey[candidate.order[i]]
		if not publishItemRow(row) then
			state.pendingWindow = nil
			return nil, "legacy_item_send_failed"
		end
		if not publishWindowItemRow(row, revision) then
			state.pendingWindow = nil
			return nil, "window_item_send_failed"
		end
	end
	pending.readyToEnd = true
	if not DistributionSession.EndWindow(revision) then
		state.pendingWindow = nil
		return nil, "window_end_send_failed"
	end
	triggerChanged("window", nil)
	return true
end

function DistributionSession.PublishRollStart(itemKeyOrLink, rollType, duration)
	if not canPublish() then
		return false
	end
	local itemKey = resolveItemKey(itemKeyOrLink, itemKeyOrLink)
	if not itemKey then
		return false
	end

	duration = normalizeNumber(duration)
	local row = upsertRow({
		itemKey = itemKey,
		rollType = rollType,
		duration = duration,
		remaining = duration,
		clearDuration = duration == nil,
		clearRemaining = duration == nil,
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
	local normalizedWinner = normalizeText(winnerName, true)
	local committed = state.itemsByKey[itemKey]
	if committed and committed.state == STATE_DONE and committed.winnerName == normalizedWinner then
		return publishItemDoneRow(committed)
	end

	local row = upsertRow({
		itemKey = itemKey,
		winnerName = normalizedWinner,
		state = STATE_DONE,
	}, "item_done")
	if not row then
		return false
	end
	return publishItemDoneRow(row)
end

function DistributionSession.PublishItemCancelled(itemKeyOrLink, winnerName, reason)
	if not canPublish() then
		return false
	end
	local itemKey = resolveItemKey(itemKeyOrLink, itemKeyOrLink)
	if not itemKey then
		return false
	end
	local row = upsertRow(
		{ itemKey = itemKey, winnerName = winnerName, failureReason = reason, clearWinner = true, state = STATE_ACTIVE },
		"item_cancelled"
	)
	if not row then
		return false
	end
	return publishItemCancelledRow(row, winnerName)
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

function DistributionSession.HandleMessage(prefix, msg, _channel, sender)
	if prefix ~= PREFIX then
		return false
	end

	local fields = splitFields(msg)
	local kind = fields[1]
	if kind == MSG_SNAPSHOT_REQ then
		if not IsGroupMember(Raid, sender) then
			return true
		end
	elseif kind ~= MSG_HELLO then
		if IsLootAuthority(Raid, sender) then
			trustedAuthority = tostring(sender or "")
			DistributionSession._trustedAuthority = trustedAuthority
		elseif kind ~= MSG_SESSION_END or tostring(sender or "") ~= trustedAuthority then
			return true
		end
	end
	if kind == MSG_CLEAR then
		if not isSupportedVersion(fields[2]) then
			return true
		end
		local accepted, key = acceptIncomingMutation(sender, fields[3], nil, "clear")
		if accepted then
			tombstoneSupersededOwner(key)
			clearState(fields[3])
			state.transitionSender = sender
		end
		return true
	end
	if kind == MSG_ITEM then
		return handleItemMessage(fields, sender)
	end
	if kind == MSG_WINDOW_ITEM then
		return handleWindowItemMessage(fields, sender, string.len(msg or ""))
	end
	if kind == MSG_WINDOW_BEGIN then
		return handleWindowBeginMessage(fields, sender)
	end
	if kind == MSG_WINDOW_END then
		return handleWindowEndMessage(fields, sender)
	end
	if kind == MSG_SESSION_END then
		local handled, closed = handleSessionEndMessage(fields, sender)
		if closed then
			trustedAuthority = nil
			DistributionSession._trustedAuthority = nil
		end
		return handled
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
	if kind == MSG_ITEM_CANCELLED then
		return handleItemCancelledMessage(fields, sender)
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
		revision = tonumber(state.revision) or 0,
		rows = rows,
	}
end

ensurePrefix()
