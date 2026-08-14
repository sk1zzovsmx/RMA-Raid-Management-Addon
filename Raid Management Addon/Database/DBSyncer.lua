-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: direct addon namespace bindings
-- exports: publish module APIs on addon.*
-- events: handles RMALogSync addon-message traffic; listens OptionsLoaded, ConfigpersistentSync, RaidCreate
local addon = select(2, ...)
local L = addon.L
local Diag = addon.Diag

local DB = addon.DB
local Events = addon.Events
local Database = addon.Database
local Options = addon.Options
local Bus = addon.Bus
local Strings = addon.Strings
local Timer = addon.Timer
local Comms = addon.Comms
local Services = addon.Services
local coreState = addon.State

local _G = _G
local tconcat = table.concat
local pairs, type, select = pairs, type, select
local strsub = string.sub
local tonumber, tostring = tonumber, tostring
local floor = math.floor
local format = string.format

local GetTime = assert(_G.GetTime, "DBSyncer time API is not initialized")
local GetNumRaidMembers = assert(_G.GetNumRaidMembers, "DBSyncer raid member count API is not initialized")
local GetRaidRosterInfo = assert(_G.GetRaidRosterInfo, "DBSyncer raid roster API is not initialized")

local NormalizeName = Strings.NormalizeName
local NormalizeLower = Strings.NormalizeLower
local TrimText = Strings.TrimText

local InternalEvents = assert(Events.Internal, "DBSyncer internal events are not initialized")
local Payload = assert(Comms.Payload, "Comms payload helpers are not initialized")
local TriggerEvent = assert(Bus.TriggerEvent, "DBSyncer event publisher is not initialized")
local RegisterCallback = assert(Bus.RegisterCallback, "DBSyncer event bus listener is not initialized")
local BuildConfigOptionChangedName =
	assert(Events.BuildConfigOptionChangedName, "DBSyncer config event resolver is not initialized")
local OptionsLoadedEvent = assert(InternalEvents.OptionsLoaded, "DBSyncer options-loaded event is not initialized")
local LoggerSelectRaidEvent =
	assert(InternalEvents.LoggerSelectRaid, "DBSyncer logger-select-raid event is not initialized")
local RaidCreateEvent = assert(InternalEvents.RaidCreate, "DBSyncer raid-create event is not initialized")
local BindTimerMixin = assert(Timer.BindMixin, "DBSyncer timer mixin is not initialized")

-- Logger synchronization module.
do
	DB.Syncer = DB.Syncer or {}
	local module = DB.Syncer

	-- ----- Internal state ----- --
	local COMM_PREFIX = "RMALogSync"
	Comms.RegisterPrefixIfAvailable(COMM_PREFIX)
	local LEGACY_PROTOCOL_VERSION = 1
	local PROTOCOL_VERSION = 2

	local FIELD_SEP = "\t"
	local splitFields = Payload.SplitFields
	local packFields = Payload.PackFields

	local MSG_REQUEST = "RQ"
	local MSG_SNAPSHOT = "SN"
	local MSG_DELTA = "DL"

	local MODE_REQ = "REQ"
	local MODE_PUSH = "PUSH"
	local MODE_SYNC = "SYNC"

	local MAX_CHUNK_SIZE = 220
	local MAX_CHUNKS = 256
	local MAX_ENCODED_BYTES = MAX_CHUNK_SIZE * MAX_CHUNKS
	local MAX_INCOMING_STATES = 64
	local MAX_INCOMING_STATES_PER_SENDER = 8
	local MAX_REQUEST_ID_BYTES = 64
	local MAX_DELTA_ROWS = 50
	local REQUEST_TTL_SECONDS = 30
	local INCOMING_TTL_SECONDS = 45
	local REQUEST_RATE_WINDOW_SECONDS = 30
	local REQUEST_RATE_MAX_PER_SENDER = 6
	local REQUEST_RATE_PRUNE_SECONDS = REQUEST_RATE_WINDOW_SECONDS * 2
	local OUTGOING_RATE_WINDOW_SECONDS = 30
	local OUTGOING_RATE_MAX_PER_TARGET = 4
	local OUTGOING_RATE_PRUNE_SECONDS = OUTGOING_RATE_WINDOW_SECONDS * 2
	local PASSIVE_CLEANUP_INTERVAL_SECONDS = 5
	local PERSISTENT_SYNC_INTERVAL_SECONDS = 120
	local MAX_PUSH_CONSENTS = 128
	local MAX_TERMINAL_REQUESTS = 128

	local loggerOptions = Options.RegisterNamespace("Logger", {
		persistentSync = true,
		ignoreGroupLoot = false,
		ignoreSelectionThreshold = true,
		loggerLootQualityThreshold = 4,
		syncRequirePlayer = "",
		syncPushPlayer = "",
	})

	module._incoming = module._incoming or {}
	module._pendingRequests = module._pendingRequests or {}
	module._terminalRequests = module._terminalRequests or {}
	module._requestRate = module._requestRate or {}
	module._outgoingRate = module._outgoingRate or {}
	module._pushConsents = module._pushConsents or {}
	module._outboundPushes = module._outboundPushes or {}
	module._nextRequestId = tonumber(module._nextRequestId) or 0
	module._nextPassiveCleanupAt = tonumber(module._nextPassiveCleanupAt) or 0
	module._persistentSyncHandle = module._persistentSyncHandle or nil
	module._persistentSyncCallbacksBound = module._persistentSyncCallbacksBound or false
	local chunkMessageBuffer = {}
	BindTimerMixin(module, "Database/DBSyncer")
	local ScheduleTimer = assert(module.ScheduleTimer, "DBSyncer persistent-sync scheduler is not initialized")
	local CancelTimer = assert(module.CancelTimer, "DBSyncer persistent-sync canceler is not initialized")

	-- ----- Private helpers ----- --
	local function clearChunkMessageBuffer()
		for key in pairs(chunkMessageBuffer) do
			chunkMessageBuffer[key] = nil
		end
	end

	local function nowSec()
		return GetTime()
	end

	local function parseNumber(value, fallback)
		local n = tonumber(value)
		if n == nil then
			return fallback
		end
		return n
	end

	local normalizeSender = assert(Comms.NormalizeSender, "DBSync sender normalizer is not initialized")

	local function isSelfSender(sender)
		local selfName = Database.GetPlayerName()
		if not selfName then
			return false
		end
		local a = NormalizeLower(selfName, true)
		local b = NormalizeLower(normalizeSender(sender), true)
		return (a ~= nil and b ~= nil and a == b)
	end

	local isDebugEnabled = Options.IsDebugEnabled

	local Metrics = assert(module._Metrics, "DBSync metrics helpers are not initialized")
	local SnapshotPayload = assert(module._Payload, "DBSync payload helpers are not initialized")
	local SnapshotImport = assert(module._Import, "DBSync import helpers are not initialized")

	local terminalizeRequest
	local releasePushConsent

	local function cleanupExpiredState()
		local now = nowSec()

		for key, st in pairs(module._incoming) do
			local age = now - (tonumber(st and st.createdAt) or now)
			if age > INCOMING_TTL_SECONDS then
				if st and st.pushConsentKey then
					local consent = module._pushConsents[st.pushConsentKey]
					if consent and consent.status == "inflight" then
						consent.status = "available"
						if consent.timeoutExtended ~= true then
							consent.createdAt = now
							consent.timeoutExtended = true
						end
					end
				end
				module._incoming[key] = nil
			end
		end

		for key, st in pairs(module._pushConsents) do
			local age = now - (tonumber(st and st.createdAt) or now)
			if age > INCOMING_TTL_SECONDS then
				module._pushConsents[key] = nil
			end
		end

		local expiredRequests = {}
		for reqId, st in pairs(module._pendingRequests) do
			local age = now - (tonumber(st and st.createdAt) or now)
			if age > REQUEST_TTL_SECONDS then
				expiredRequests[#expiredRequests + 1] = reqId
			end
		end
		for i = 1, #expiredRequests do
			terminalizeRequest(expiredRequests[i], "timeout")
		end

		for reqId, st in pairs(module._terminalRequests) do
			local age = now - (tonumber(st and st.terminalAt) or now)
			if age > REQUEST_TTL_SECONDS then
				module._terminalRequests[reqId] = nil
			end
		end

		for reqId, st in pairs(module._outboundPushes) do
			local age = now - (tonumber(st and st.createdAt) or now)
			if age > INCOMING_TTL_SECONDS then module._outboundPushes[reqId] = nil end
		end

		for sender, st in pairs(module._requestRate) do
			local stamp = tonumber(st and st.windowStart) or tonumber(st and st.lastSeen) or now
			local age = now - stamp
			if age > REQUEST_RATE_PRUNE_SECONDS then
				module._requestRate[sender] = nil
			end
		end

		for target, st in pairs(module._outgoingRate) do
			local stamp = tonumber(st and st.windowStart) or tonumber(st and st.lastSeen) or now
			local age = now - stamp
			if age > OUTGOING_RATE_PRUNE_SECONDS then
				module._outgoingRate[target] = nil
			end
		end
	end

	local function cleanupExpiredStatePassive()
		local now = nowSec()
		if now < (tonumber(module._nextPassiveCleanupAt) or 0) then
			return
		end

		module._nextPassiveCleanupAt = now + PASSIVE_CLEANUP_INTERVAL_SECONDS
		cleanupExpiredState()
	end

	local function cleanupIncomingByRequest(requestId, mode)
		local requestKey = tostring(requestId or "")
		local modeKey = tostring(mode or "")
		if requestKey == "" or modeKey == "" then
			return
		end
		for key, st in pairs(module._incoming) do
			local incomingRequestId = tostring(st and st.requestId or "")
			local incomingMode = tostring(st and st.mode or "")
			if incomingRequestId == requestKey and incomingMode == modeKey then
				module._incoming[key] = nil
			end
		end
	end

	local function allowIncomingRequest(rawSender)
		local sender = normalizeSender(rawSender) or tostring(rawSender or "?")
		local now = nowSec()
		local rate = module._requestRate[sender]
		if not rate then
			module._requestRate[sender] = {
				windowStart = now,
				lastSeen = now,
				count = 1,
				warned = false,
			}
			return true, sender
		end

		local windowStart = tonumber(rate.windowStart) or now
		if (now - windowStart) > REQUEST_RATE_WINDOW_SECONDS then
			rate.windowStart = now
			rate.lastSeen = now
			rate.count = 1
			rate.warned = false
			return true, sender
		end

		rate.lastSeen = now
		rate.count = (tonumber(rate.count) or 0) + 1
		if rate.count > REQUEST_RATE_MAX_PER_SENDER then
			if not rate.warned then
				addon:warn(
					(Diag.W.LogSyncRequestRateLimited):format(tostring(sender), rate.count, REQUEST_RATE_WINDOW_SECONDS)
				)
				rate.warned = true
			end
			return false, sender
		end

		return true, sender
	end

	local function normalizeOutgoingTarget(target, mode)
		local normalized = normalizeSender(target)
		if normalized and normalized ~= "" then
			return normalized
		end
		if target and target ~= "" then
			return tostring(target)
		end
		if mode and mode ~= "" then
			return tostring(mode)
		end
		return "GROUP"
	end

	local function allowOutgoingRequest(target, mode)
		local key = normalizeOutgoingTarget(target, mode)
		local now = nowSec()
		local rate = module._outgoingRate[key]
		if not rate then
			module._outgoingRate[key] = {
				windowStart = now,
				lastSeen = now,
				count = 1,
				warned = false,
			}
			return true, key
		end

		local windowStart = tonumber(rate.windowStart) or now
		if (now - windowStart) > OUTGOING_RATE_WINDOW_SECONDS then
			rate.windowStart = now
			rate.lastSeen = now
			rate.count = 1
			rate.warned = false
			return true, key
		end

		rate.lastSeen = now
		rate.count = (tonumber(rate.count) or 0) + 1
		if rate.count > OUTGOING_RATE_MAX_PER_TARGET then
			if not rate.warned then
				addon:warn(
					(Diag.W.LogSyncRequestRateLimited):format(tostring(key), rate.count, OUTGOING_RATE_WINDOW_SECONDS)
				)
				rate.warned = true
			end
			return false, key
		end

		return true, key
	end

	local function stableSenderKey(rawSender)
		local sender = TrimText(rawSender or "")
		if sender == "" then
			return nil
		end
		return NormalizeLower(sender, true) or sender
	end

	local function shortSenderKey(rawSender)
		local sender = stableSenderKey(rawSender)
		if not sender then
			return nil
		end
		return string.match(sender, "^([^%-]+)") or sender
	end

	local function findRaidRosterMember(rawSender)
		local sender = stableSenderKey(rawSender)
		if not sender then
			return nil
		end
		local senderShort = shortSenderKey(sender)
		local shortMatchedName, shortMatchedRank, shortMatchCount
		local count = tonumber(GetNumRaidMembers()) or 0
		for i = 1, count do
			local name, rank = GetRaidRosterInfo(i)
			local rosterName = stableSenderKey(name)
			if rosterName == sender then
				return rosterName, tonumber(rank) or 0
			end
			if rosterName and shortSenderKey(rosterName) == senderShort then
				shortMatchCount = (shortMatchCount or 0) + 1
				shortMatchedName = rosterName
				shortMatchedRank = tonumber(rank) or 0
			end
		end
		if shortMatchCount == 1 then
			return shortMatchedName, shortMatchedRank
		end
		return nil
	end

	local function isCurrentGroupMember(rawSender)
		if addon.IsInRaid() then
			return findRaidRosterMember(rawSender) ~= nil
		end
		local raidService = Services.Raid
		return raidService and raidService.IsGroupMember and raidService:IsGroupMember(rawSender) == true
	end

	local function canAnswerRequests(rawSender, channel)
		if not addon.IsInGroup() then
			return false
		end
		if channel == "WHISPER" and not isCurrentGroupMember(rawSender) then
			return false
		end
		if channel == "WHISPER" then
			return true
		end
		if not addon.IsInRaid() then
			return true
		end
		local raidService = assert(Services.Raid, "DBSyncer raid service is not initialized")
		local CanUseCapability =
			assert(raidService.CanUseCapability, "DBSyncer raid capability resolver is not initialized")
		return CanUseCapability(raidService, "raid_leadership") == true
	end

	local function normalizeTargetName(raw)
		local text = TrimText(raw or "")
		if text == "" then
			return nil
		end
		return NormalizeName(text, true) or text
	end

	local function ensureGroupSyncAvailable()
		cleanupExpiredState()
		if addon.IsInGroup() then
			return true
		end

		addon:warn(L.MsgLoggerSyncNotInGroup)
		return false
	end

	local function resolveExternalTarget(targetName)
		local target = normalizeTargetName(targetName)
		if not target then
			addon:warn(L.MsgLoggerSyncTargetRequired)
			return nil
		end
		if isSelfSender(target) then
			addon:warn(L.MsgLoggerSyncTargetSelf)
			return nil
		end

		return target
	end

	local function isPersistentSyncEnabled()
		return loggerOptions and loggerOptions:Get("persistentSync") == true
	end

	local nextRequestId = Comms.NextRequestId

	local function isRequestIdUnavailable(requestId)
		if module._pendingRequests[requestId] or module._terminalRequests[requestId] or module._outboundPushes[requestId] then
			return true
		end
		for _, incoming in pairs(module._incoming) do
			if tostring(incoming and incoming.requestId or "") == requestId then return true end
		end
		for _, consent in pairs(module._pushConsents) do
			if tostring(consent and consent.requestId or "") == requestId then return true end
		end
		return false
	end

	local function allocateRequestId(syncer)
		return nextRequestId(syncer, nil, isRequestIdUnavailable)
	end

	local function trackPendingRequest(syncer, requestId, pendingState)
		if syncer._pendingRequests[requestId] or syncer._terminalRequests[requestId] then
			return false, "request_id_in_use"
		end
		syncer._pendingRequests[requestId] = pendingState
		pendingState.timeoutHandle = ScheduleTimer(syncer, function()
			if syncer._pendingRequests[requestId] == pendingState then
				terminalizeRequest(requestId, "timeout")
			end
		end, REQUEST_TTL_SECONDS)
		if not pendingState.timeoutHandle then
			syncer._pendingRequests[requestId] = nil
			return false, "timer_unavailable"
		end
		return true
	end

	local function rollbackPendingRequest(syncer, requestId)
		local pending = syncer._pendingRequests[requestId]
		if not pending then return end
		if pending.timeoutHandle then CancelTimer(syncer, pending.timeoutHandle) end
		pending.timeoutHandle = nil
		syncer._pendingRequests[requestId] = nil
	end

	local function sendAddonPayload(target, payload)
		if target and target ~= "" then
			return Comms.QueueAddonMessage(COMM_PREFIX, payload, "WHISPER", target)
		end

		return Comms.Sync(COMM_PREFIX, payload)
	end

	local function buildIncomingSnapshotKey(sender, requestId, mode, raidNid)
		return format("%s|%s|%s|%s", tostring(sender), tostring(requestId), tostring(mode), tostring(raidNid))
	end

	local function sendRequest(mode, requestId, raidRef, signature, target)
		signature = signature or {}
		local payload = packFields(
			FIELD_SEP,
			MSG_REQUEST,
			PROTOCOL_VERSION,
			requestId,
			mode,
			tonumber(raidRef) or 0,
			SnapshotPayload.EncodeText(signature.zone),
			tonumber(signature.size) or 0,
			tonumber(signature.diff) or 0,
			tonumber(signature.sinceRevision) or 0,
			signature.supportsCompression == true and 1 or 0
		)
		local queued, reason = sendAddonPayload(target, payload)
		if not queued then return false, reason end
		Metrics.RecordOutgoingRequest(mode, #payload)
		if isDebugEnabled() then
			addon:debug((Diag.D.LogSyncRequestSent):format(tostring(requestId), tostring(raidRef)))
		end
		return true
	end

	local function sendChunkedPayload(kind, target, requestId, mode, raidNid, payload)
		local encodedPayload =
			SnapshotPayload.EncodeTransportText(payload, { compress = false })
		local payloadLen = #encodedPayload
		local totalChunks = floor((payloadLen + MAX_CHUNK_SIZE - 1) / MAX_CHUNK_SIZE)
		if totalChunks < 1 then
			totalChunks = 1
		end
		if payloadLen > MAX_ENCODED_BYTES or totalChunks > MAX_CHUNKS then
			return false, "payload_too_large"
		end

		clearChunkMessageBuffer()
		chunkMessageBuffer[1] = kind
		chunkMessageBuffer[2] = PROTOCOL_VERSION
		chunkMessageBuffer[3] = requestId
		chunkMessageBuffer[4] = mode
		chunkMessageBuffer[5] = tonumber(raidNid) or 0
		chunkMessageBuffer[7] = totalChunks

		local messages = {}
		for idx = 1, totalChunks do
			local fromPos = ((idx - 1) * MAX_CHUNK_SIZE) + 1
			local toPos = fromPos + MAX_CHUNK_SIZE - 1
			chunkMessageBuffer[6] = idx
			chunkMessageBuffer[8] = strsub(encodedPayload, fromPos, toPos)

			local msg = packFields(
				FIELD_SEP,
				chunkMessageBuffer[1],
				chunkMessageBuffer[2],
				chunkMessageBuffer[3],
				chunkMessageBuffer[4],
				chunkMessageBuffer[5],
				chunkMessageBuffer[6],
				chunkMessageBuffer[7],
				chunkMessageBuffer[8]
			)
			messages[idx] = msg
		end
		local queued, reason = Comms.SendAddonBatch(COMM_PREFIX, messages, target)
		if not queued then
			clearChunkMessageBuffer()
			return false, reason or "backpressure"
		end

		clearChunkMessageBuffer()
		Metrics.RecordOutgoingSnapshot(mode, payloadLen, totalChunks)
		return true, totalChunks, payloadLen
	end

	local function sendDelta(target, requestId, mode, raid, sinceRevision)
		local payload, deltaRows = SnapshotPayload.BuildDelta(raid, sinceRevision)
		if not payload or (tonumber(deltaRows) or 0) > MAX_DELTA_ROWS then
			return false, "delta_unavailable"
		end

		return sendChunkedPayload(MSG_DELTA, target, requestId, mode, raid.raidNid, payload)
	end

	local function sendSnapshot(target, requestId, mode, raid)
		local payload = SnapshotPayload.Build(raid)
		if not payload then
			return false, "payload_unavailable"
		end

		local ok, totalChunks, payloadLen =
			sendChunkedPayload(MSG_SNAPSHOT, target, requestId, mode, raid.raidNid, payload)
		if not ok then
			return false, totalChunks
		end

		if isDebugEnabled() then
			addon:debug(
				(Diag.D.LogSyncSnapshotSent):format(
					tostring(target or "GROUP"),
					tostring(requestId),
					tostring(raid.raidNid),
					totalChunks,
					payloadLen
				)
			)
		end
		return true
	end

	local function trimTerminalRequests()
		local count, oldestId, oldestAt = 0, nil, nil
		for requestId, state in pairs(module._terminalRequests) do
			count = count + 1
			local terminalAt = tonumber(state and state.terminalAt) or 0
			if oldestAt == nil or terminalAt < oldestAt then
				oldestId, oldestAt = requestId, terminalAt
			end
		end
		if count >= MAX_TERMINAL_REQUESTS and oldestId then
			module._terminalRequests[oldestId] = nil
		end
	end

	terminalizeRequest = function(requestId, reason)
		local pending = module._pendingRequests[requestId]
		if not pending or pending.completed == true then
			return false
		end
		pending.completed = true
		pending.terminalReason = reason
		pending.terminalAt = nowSec()
		if pending.timeoutHandle then CancelTimer(module, pending.timeoutHandle) end
		pending.timeoutHandle = nil
		for key, incoming in pairs(module._incoming) do
			if incoming and incoming.requestContext == pending then
				if incoming and incoming.pushConsentKey then
					local consent = module._pushConsents[incoming.pushConsentKey]
					if consent and consent.requestContext == pending then
						module._pushConsents[incoming.pushConsentKey] = nil
					else
						releasePushConsent(incoming.pushConsentKey)
					end
				end
				module._incoming[key] = nil
			end
		end
		for consentKey, consent in pairs(module._pushConsents) do
			if consent and consent.requestContext == pending then
				module._pushConsents[consentKey] = nil
			end
		end
		module._pendingRequests[requestId] = nil
		trimTerminalRequests()
		module._terminalRequests[requestId] = {
			createdAt = pending.createdAt,
			terminalAt = pending.terminalAt,
			mode = pending.mode,
			raidRef = pending.raidRef,
			raidNid = pending.raidNid,
			target = pending.target,
			sender = pending.sender,
			reason = reason,
		}
		if type(pending.callback) == "function" and pending.callbackDelivered ~= true then
			pending.callbackDelivered = true
			local ok, callbackError = pcall(pending.callback, reason, pending)
			if not ok then
				addon:error(tostring(callbackError))
			end
		end
		return true
	end

	local function completeRequest(requestId)
		return terminalizeRequest(requestId, "complete")
	end

	local function getSenderKey(rawSender)
		return stableSenderKey(rawSender)
	end

	local function markSyncSenderFailed(pending, rawSender)
		if type(pending) ~= "table" then
			return nil
		end
		local sender = getSenderKey(rawSender)
		if not sender then
			return nil
		end
		pending.failedSenders = pending.failedSenders or {}
		pending.failedSenders[sender] = true
		return sender
	end

	local function rejectSyncSender(pending, rawSender, requestId, reason)
		local sender = markSyncSenderFailed(pending, rawSender)
		if not sender then
			sender = getSenderKey(rawSender) or tostring(rawSender or "?")
		end
		if isDebugEnabled() then
			addon:debug(
				(Diag.D.LogSyncSyncSenderFailed):format(tostring(sender), tostring(requestId), tostring(reason))
			)
		end
	end

	local function finalizeSnapshotFailure(isSync, pending, sender, requestId, reason, responseMode)
		if responseMode == MODE_PUSH then return end
		if isSync then
			rejectSyncSender(pending, sender, requestId, reason)
			return
		end
		terminalizeRequest(requestId, reason or "failed")
	end

	local function isSyncSenderFailed(pending, rawSender)
		if type(pending) ~= "table" then
			return false
		end
		local sender = getSenderKey(rawSender)
		if not sender then
			return false
		end
		local failedSenders = pending.failedSenders
		return type(failedSenders) == "table" and failedSenders[sender] == true
	end

	local function isAuthorizedSyncResponder(rawSender)
		if not addon.IsInRaid() then
			return true
		end
		local _, rank = findRaidRosterMember(rawSender)
		return rank ~= nil and rank > 0
	end

	local function identitiesMatchRosterMember(left, right)
		local leftRosterName = select(1, findRaidRosterMember(left))
		local rightRosterName = select(1, findRaidRosterMember(right))
		return leftRosterName ~= nil and rightRosterName ~= nil and leftRosterName == rightRosterName
	end

	local function hasPushConsent(rawSender, pending)
		local rosterName, rank = findRaidRosterMember(rawSender)
		if rank == nil or rank <= 0 then
			return false, nil
		end

		if
			type(pending) == "table"
			and pending.completed ~= true
			and pending.mode == MODE_REQ
			and (nowSec() - (tonumber(pending.createdAt) or 0)) <= REQUEST_TTL_SECONDS
			and identitiesMatchRosterMember(rawSender, pending.target or pending.sender)
		then
			return true, rosterName, true
		end

		local configuredSource = loggerOptions and loggerOptions:Get("syncRequirePlayer")
		return identitiesMatchRosterMember(rawSender, configuredSource), rosterName, false
	end

	local function buildPushConsentKey(rosterName, requestId, raidNid)
		return format("%s|%s|%s|%s", tostring(rosterName), tostring(requestId), MODE_PUSH, tostring(raidNid))
	end

	local function trimPushConsentCache()
		local count, oldestKey, oldestAt = 0, nil, nil
		for key, st in pairs(module._pushConsents) do
			count = count + 1
			local createdAt = tonumber(st and st.createdAt) or 0
			if st and st.status == "consumed" and (oldestAt == nil or createdAt < oldestAt) then
				oldestKey, oldestAt = key, createdAt
			end
		end
		if count >= MAX_PUSH_CONSENTS and oldestKey then
			module._pushConsents[oldestKey] = nil
			return true
		end
		return count < MAX_PUSH_CONSENTS
	end

	local function acquirePushConsent(sender, requestId, raidNid, pending, incomingKey)
		local rosterName, rank = findRaidRosterMember(sender)
		if not rosterName or rank == nil or rank <= 0 then
			return nil
		end
		local terminal = module._terminalRequests[requestId]
		if
			terminal
			and terminal.mode == MODE_REQ
			and tonumber(terminal.raidRef) == tonumber(raidNid)
			and identitiesMatchRosterMember(sender, terminal.target or terminal.sender)
		then
			return nil
		end
		local consentKey = buildPushConsentKey(rosterName, requestId, raidNid)
		local consent = module._pushConsents[consentKey]
		if consent then
			if consent.status == "inflight" and module._incoming[incomingKey] then
				return consentKey
			end
			if consent.status == "available" then
				consent.status = "inflight"
				return consentKey
			end
			return nil
		end
		local authorized, _, correlated = hasPushConsent(sender, pending)
		if not authorized then
			return nil
		end
		if not trimPushConsentCache() then
			return nil
		end
		module._pushConsents[consentKey] = {
			createdAt = nowSec(),
			status = "inflight",
			correlated = correlated == true,
			requestId = requestId,
			requestContext = correlated == true and pending or nil,
		}
		return consentKey
	end

	releasePushConsent = function(consentKey)
		local consent = consentKey and module._pushConsents[consentKey]
		if consent and consent.status == "inflight" then
			consent.status = "available"
		end
	end

	local function consumePushConsent(consentKey)
		local consent = consentKey and module._pushConsents[consentKey]
		if consent and consent.status == "inflight" then
			consent.status = "consumed"
			consent.createdAt = nowSec()
		end
	end

	local function completeCorrelatedPushRequest(consentKey)
		local consent = consentKey and module._pushConsents[consentKey]
		local pending = consent and consent.requestContext
		if pending and module._pendingRequests[consent.requestId] == pending then
			terminalizeRequest(consent.requestId, "complete")
		end
	end

	local function warnSyncSenderNotOfficer(pending, requestId, rawSender)
		if type(pending) ~= "table" then
			return
		end
		local sender = getSenderKey(rawSender) or tostring(rawSender or "?")
		addon:warn((Diag.W.LogSyncSenderNotOfficer):format(tostring(sender), tostring(requestId)))
	end

	local function handleIncomingRequest(rawSender, channel, requestId, mode, raidRef, signature)
		if not canAnswerRequests(rawSender, channel) then
			return
		end

		local allowed, sender = allowIncomingRequest(rawSender)
		if not allowed then
			return
		end

		local raid = nil
		if mode == MODE_REQ then
			raid = select(1, SnapshotImport.ResolveRaidByReference(raidRef, false))
		elseif mode == MODE_SYNC then
			raid = select(1, SnapshotImport.GetCurrentRaidRecord())
			if raid and not SnapshotImport.RaidMatchesSignature(raid, signature) then
				raid = nil
			end
		end

		if not raid then
			return
		end

		if isDebugEnabled() then
			addon:debug(
				(Diag.D.LogSyncRequestReceived):format(tostring(sender), tostring(requestId), tostring(raidRef))
			)
		end
		local sinceRevision = tonumber(signature and signature.sinceRevision) or 0
		if mode == MODE_SYNC and sinceRevision > 0 then
			local sent, reason = sendDelta(rawSender, requestId, mode, raid, sinceRevision)
			if sent or reason ~= "delta_unavailable" then return end
		end
		sendSnapshot(rawSender, requestId, mode, raid)
	end

	local function refreshLoggerUi(focusRaidId)
		local selectedRaid = tonumber(focusRaidId)
			or tonumber(coreState and coreState.selectedRaid)
			or tonumber(Database.GetCurrentRaid())
		TriggerEvent(LoggerSelectRaidEvent, selectedRaid, "sync")
	end

	local function onSnapshotReady(sender, requestId, mode, snapshot, pushConsentKey)
		if mode == MODE_SYNC then
			local currentRaid, currentId = SnapshotImport.GetCurrentRaidRecord()
			local pending = module._pendingRequests[requestId]
			if not currentRaid then
				addon:warn(L.MsgLoggerSyncNoCurrent)
				completeRequest(requestId)
				return
			end
			if not SnapshotImport.RaidMatchesSnapshotHeader(currentRaid, snapshot.header) then
				rejectSyncSender(pending, sender, requestId, "raid_mismatch")
				return
			end

			local ok, raid, importReason = pcall(SnapshotImport.ApplySnapshotToRaid, currentRaid, snapshot, false)
			if not ok then
				addon:error(
					(Diag.E.LogSyncMergeFailed):format(
						tostring(sender),
						tostring(requestId),
						tostring(snapshot.header.raidNid),
						tostring(raid)
					)
				)
				rejectSyncSender(pending, sender, requestId, "merge_failed")
				return
			end
			if not raid then
				addon:error(
					(Diag.E.LogSyncMergeFailed):format(
						tostring(sender),
						tostring(requestId),
						tostring(snapshot.header.raidNid),
						tostring(importReason or "nil_result")
					)
				)
				rejectSyncSender(pending, sender, requestId, "merge_failed")
				return
			end

			addon:info(L.MsgLoggerSyncApplied:format(tonumber(currentId) or 0, tostring(sender)))
			if isDebugEnabled() then
				addon:debug(
					(Diag.D.LogSyncMergeApplied):format(
						tonumber(raid.raidNid) or 0,
						tonumber(currentId) or 0,
						tostring(sender),
						#(raid.bossKills or {}),
						#(raid.loot or {})
					)
				)
			end

			cleanupIncomingByRequest(requestId, MODE_SYNC)
			completeRequest(requestId)
			refreshLoggerUi(currentId)
			return
		end

		local ok, raid, raidId, importReason = pcall(SnapshotImport.ImportSnapshotAsNewRaid, snapshot)
		if not ok then
			releasePushConsent(pushConsentKey)
			addon:error(
				(Diag.E.LogSyncMergeFailed):format(
					tostring(sender),
					tostring(requestId),
					tostring(snapshot.header.raidNid),
					tostring(raid)
				)
			)
			if mode == MODE_REQ then terminalizeRequest(requestId, "merge_failed") end
			return
		end
		if not raid then
			releasePushConsent(pushConsentKey)
			addon:error(
				(Diag.E.LogSyncMergeFailed):format(
					tostring(sender),
					tostring(requestId),
					tostring(snapshot.header.raidNid),
					tostring(importReason or "nil_result")
				)
			)
			if mode == MODE_REQ then terminalizeRequest(requestId, "merge_failed") end
			return
		end

		if mode == MODE_PUSH then
			consumePushConsent(pushConsentKey)
			addon:info(L.MsgLoggerPushImported:format(tostring(sender), tonumber(raidId) or 0))
			completeCorrelatedPushRequest(pushConsentKey)
		else
			addon:info(L.MsgLoggerReqImported:format(tostring(sender), tonumber(raidId) or 0))
			completeRequest(requestId)
		end

		if isDebugEnabled() then
			addon:debug(
				(Diag.D.LogSyncMergeApplied):format(
					tonumber(raid.raidNid) or 0,
					tonumber(raidId) or 0,
					tostring(sender),
					#(raid.bossKills or {}),
					#(raid.loot or {})
				)
			)
		end

		refreshLoggerUi(raidId)
	end

	local function onDeltaReady(sender, requestId, mode, delta)
		if mode ~= MODE_SYNC then
			completeRequest(requestId)
			return
		end

		local currentRaid, currentId = SnapshotImport.GetCurrentRaidRecord()
		local pending = module._pendingRequests[requestId]
		if not currentRaid then
			addon:warn(L.MsgLoggerSyncNoCurrent)
			completeRequest(requestId)
			return
		end
		if tonumber(currentRaid.raidNid) ~= tonumber(delta.header and delta.header.raidNid) then
			rejectSyncSender(pending, sender, requestId, "raid_mismatch")
			return
		end

		local ok, raid, importReason = pcall(SnapshotImport.ApplyDeltaToRaid, currentRaid, delta)
		if not ok then
			addon:error(
				(Diag.E.LogSyncMergeFailed):format(
					tostring(sender),
					tostring(requestId),
					tostring(delta.header.raidNid),
					tostring(raid)
				)
			)
			rejectSyncSender(pending, sender, requestId, "merge_failed")
			return
		end
		if not raid then
			addon:error(
				(Diag.E.LogSyncMergeFailed):format(
					tostring(sender),
					tostring(requestId),
					tostring(delta.header.raidNid),
					tostring(importReason or "nil_result")
				)
			)
			rejectSyncSender(pending, sender, requestId, "merge_failed")
			return
		end

		addon:info(L.MsgLoggerSyncApplied:format(tonumber(currentId) or 0, tostring(sender)))
		cleanupIncomingByRequest(requestId, MODE_SYNC)
		completeRequest(requestId)
		refreshLoggerUi(currentId)
	end

	local function shouldIgnoreSnapshotSender(sender, requestId, mode, raidNid, pending, isPush, isSync)
		if isPush then
			return false
		end

		if module._terminalRequests[requestId] then
			if pending then terminalizeRequest(requestId, "reused") end
			return true
		end
		if pending and (nowSec() - (tonumber(pending.createdAt) or 0)) > REQUEST_TTL_SECONDS then
			terminalizeRequest(requestId, "timeout")
			return true
		end

		if not pending or pending.completed or pending.mode ~= mode then
			if isDebugEnabled() then
				addon:debug(
					(Diag.D.LogSyncChunkIgnored):format(tostring(sender), tostring(requestId), tostring(raidNid))
				)
			end
			return true
		end

		local expectedRaidNid = tonumber(pending.raidNid or pending.raidRef)
		if expectedRaidNid and expectedRaidNid ~= tonumber(raidNid) then
			return true
		end

		if isSync and isSyncSenderFailed(pending, sender) then
			if isDebugEnabled() then
				addon:debug(
					(Diag.D.LogSyncChunkIgnored):format(tostring(sender), tostring(requestId), tostring(raidNid))
				)
			end
			return true
		end

		local expectedTarget = normalizeSender(pending.target)
		if expectedTarget and expectedTarget ~= "" and not identitiesMatchRosterMember(pending.target, sender) then
			if isDebugEnabled() then
				addon:debug(
					(Diag.D.LogSyncChunkIgnored):format(tostring(sender), tostring(requestId), tostring(raidNid))
				)
			end
			return true
		end

		return false
	end

	local function getOrCreateIncomingSnapshotState(sender, requestId, mode, raidNid, partCount, pending, isSync, envelopeVersion, envelopeKind)
		local key = buildIncomingSnapshotKey(sender, requestId, mode, raidNid)
		local state = module._incoming[key]
		if state then
			return key, state
		end

		local globalCount = 0
		local senderCount = 0
		for _, incoming in pairs(module._incoming) do
			globalCount = globalCount + 1
			if incoming and incoming.sender == sender then
				senderCount = senderCount + 1
			end
		end
		if globalCount >= MAX_INCOMING_STATES or senderCount >= MAX_INCOMING_STATES_PER_SENDER then
			return key, nil
		end

		if isSync and not isAuthorizedSyncResponder(sender) then
			warnSyncSenderNotOfficer(pending, requestId, sender)
			if isDebugEnabled() then
				addon:debug(
					(Diag.D.LogSyncChunkIgnored):format(tostring(sender), tostring(requestId), tostring(raidNid))
				)
			end
			return key, nil
		end

		state = {
			createdAt = nowSec(),
			sender = sender,
			requestId = requestId,
			envelopeVersion = envelopeVersion,
			envelopeKind = envelopeKind,
			mode = mode,
			raidNid = raidNid,
			total = partCount,
			got = 0,
			parts = {},
			encodedBytes = 0,
			requestContext = (mode == MODE_REQ or isSync) and pending or nil,
		}
		module._incoming[key] = state
		return key, state
	end

	local function handleIncomingSnapshot(sender, requestId, mode, raidNid, partIndex, partCount, chunkData, envelopeVersion)
		local pending = module._pendingRequests[requestId]
		local isPush = (mode == MODE_PUSH)
		local isSync = (mode == MODE_SYNC)

		if shouldIgnoreSnapshotSender(sender, requestId, mode, raidNid, pending, isPush, isSync) then
			return
		end

		if #tostring(requestId or "") > MAX_REQUEST_ID_BYTES or partIndex < 1 or partCount < 1 or partCount > MAX_CHUNKS or partIndex > partCount or #(chunkData or "") > MAX_CHUNK_SIZE then
			addon:warn(
				(Diag.W.LogSyncChunkMalformed):format(
					tostring(sender),
					tostring(requestId),
					tostring(partIndex),
					tostring(partCount)
				)
			)
			return
		end

		local pushConsentKey
		if isPush then
			local incomingKey = buildIncomingSnapshotKey(sender, requestId, mode, raidNid)
			pushConsentKey = acquirePushConsent(sender, requestId, raidNid, pending, incomingKey)
			if not pushConsentKey then
				if isDebugEnabled() then
					addon:debug(
						(Diag.D.LogSyncChunkIgnored):format(tostring(sender), tostring(requestId), tostring(raidNid))
					)
				end
				return
			end
		end

		local key, state =
			getOrCreateIncomingSnapshotState(sender, requestId, mode, raidNid, partCount, pending, isSync, envelopeVersion, MSG_SNAPSHOT)
		if not state then
			releasePushConsent(pushConsentKey)
			return
		end
		state.pushConsentKey = pushConsentKey
		if isPush and pushConsentKey then
			local consent = module._pushConsents[pushConsentKey]
			state.requestContext = consent and consent.requestContext or nil
		end

		if state.total ~= partCount then
			addon:warn(
				(Diag.W.LogSyncChunkPartCountChanged):format(
					tostring(sender),
					tostring(requestId),
					tostring(raidNid),
					tonumber(state.total) or 0,
					tonumber(partCount) or 0
				)
			)
			module._incoming[key] = nil
			releasePushConsent(state.pushConsentKey)
			return
		end
		if state.envelopeVersion ~= envelopeVersion or state.envelopeKind ~= MSG_SNAPSHOT then
			module._incoming[key] = nil
			releasePushConsent(state.pushConsentKey)
			finalizeSnapshotFailure(isSync, pending, sender, requestId, "version_mismatch", mode)
			return
		end

		if state.parts[partIndex] == nil then
			if state.encodedBytes + #(chunkData or "") > MAX_ENCODED_BYTES then
				module._incoming[key] = nil
				releasePushConsent(state.pushConsentKey)
				return
			end
			state.parts[partIndex] = chunkData or ""
			state.encodedBytes = state.encodedBytes + #(chunkData or "")
			state.got = state.got + 1
			Metrics.RecordIncomingSnapshotChunk(mode, #(chunkData or ""))
		end

		if isDebugEnabled() then
			addon:debug(
				(Diag.D.LogSyncChunkReceived):format(tostring(sender), tostring(requestId), partIndex, partCount)
			)
		end

		if state.got < state.total then
			return
		end

		for i = 1, state.total do
			local piece = state.parts[i]
			if piece == nil then
				module._incoming[key] = nil
				releasePushConsent(state.pushConsentKey)
				return
			end
		end
		module._incoming[key] = nil

		Metrics.RecordIncomingSnapshotComplete(mode)
		local encodedPayload = tconcat(state.parts, "")
		local payload = SnapshotPayload.DecodeTransportText(encodedPayload)
		if payload == nil then
			releasePushConsent(state.pushConsentKey)
			addon:warn((Diag.W.LogSyncDecodeFailed):format(tostring(sender), tostring(requestId), tostring(raidNid)))
			finalizeSnapshotFailure(isSync, pending, sender, requestId, "decode_failed", mode)
			return
		end

		local snapshot = SnapshotPayload.Parse(payload)
		if not snapshot then
			releasePushConsent(state.pushConsentKey)
			addon:warn((Diag.W.LogSyncParseFailed):format(tostring(sender), tostring(requestId), tostring(raidNid)))
			finalizeSnapshotFailure(isSync, pending, sender, requestId, "parse_failed", mode)
			return
		end
		if tonumber(snapshot.header and snapshot.header.protocolVersion) ~= state.envelopeVersion then
			releasePushConsent(state.pushConsentKey)
			finalizeSnapshotFailure(isSync, pending, sender, requestId, "version_mismatch", mode)
			return
		end
		local localRevision = 0
		if isSync then
			local currentRaid = select(1, SnapshotImport.GetCurrentRaidRecord())
			if currentRaid then localRevision = Database.GetRaidStore():GetRaidSyncRevision(currentRaid) end
		end
		local validSnapshot, validationReason = SnapshotPayload.ValidateSnapshot(snapshot, localRevision, raidNid)
		if not validSnapshot then
			releasePushConsent(state.pushConsentKey)
			finalizeSnapshotFailure(isSync, pending, sender, requestId, validationReason, mode)
			return
		end

		local snapshotVersion = tonumber(snapshot.header.protocolVersion)
		if snapshotVersion ~= PROTOCOL_VERSION and snapshotVersion ~= LEGACY_PROTOCOL_VERSION then
			releasePushConsent(state.pushConsentKey)
			if isDebugEnabled() then
				addon:debug(
					(Diag.D.LogSyncVersionMismatch):format(
						tostring(sender),
						tostring(snapshot.header.protocolVersion),
						PROTOCOL_VERSION
					)
				)
			end
			finalizeSnapshotFailure(isSync, pending, sender, requestId, "version_mismatch", mode)
			return
		end

		onSnapshotReady(sender, requestId, mode, snapshot, state.pushConsentKey)
	end

	local function handleIncomingDelta(sender, requestId, mode, raidNid, partIndex, partCount, chunkData, envelopeVersion)
		local pending = module._pendingRequests[requestId]
		local isSync = (mode == MODE_SYNC)
		local incomingKey = buildIncomingSnapshotKey(sender, requestId, mode, raidNid)
		local existing = module._incoming[incomingKey]
		if existing and (existing.envelopeKind ~= MSG_DELTA or existing.envelopeVersion ~= envelopeVersion) then
			module._incoming[incomingKey] = nil
			releasePushConsent(existing.pushConsentKey)
			finalizeSnapshotFailure(isSync, pending, sender, requestId, "version_mismatch", mode)
			return
		end

		if
			mode ~= MODE_SYNC or shouldIgnoreSnapshotSender(sender, requestId, mode, raidNid, pending, false, isSync)
		then
			return
		end

		if envelopeVersion ~= PROTOCOL_VERSION then
			return
		end

		if #tostring(requestId or "") > MAX_REQUEST_ID_BYTES or partIndex < 1 or partCount < 1 or partCount > MAX_CHUNKS or partIndex > partCount or #(chunkData or "") > MAX_CHUNK_SIZE then
			addon:warn(
				(Diag.W.LogSyncChunkMalformed):format(
					tostring(sender),
					tostring(requestId),
					tostring(partIndex),
					tostring(partCount)
				)
			)
			return
		end

		local key, state =
			getOrCreateIncomingSnapshotState(sender, requestId, mode, raidNid, partCount, pending, isSync, envelopeVersion, MSG_DELTA)
		if not state then
			return
		end

		if state.total ~= partCount then
			addon:warn(
				(Diag.W.LogSyncChunkPartCountChanged):format(
					tostring(sender),
					tostring(requestId),
					tostring(raidNid),
					tonumber(state.total) or 0,
					tonumber(partCount) or 0
				)
			)
			module._incoming[key] = nil
			return
		end
		if state.envelopeVersion ~= envelopeVersion or state.envelopeKind ~= MSG_DELTA then
			module._incoming[key] = nil
			finalizeSnapshotFailure(isSync, pending, sender, requestId, "version_mismatch", mode)
			return
		end

		if state.parts[partIndex] == nil then
			if state.encodedBytes + #(chunkData or "") > MAX_ENCODED_BYTES then
				module._incoming[key] = nil
				return
			end
			state.parts[partIndex] = chunkData or ""
			state.encodedBytes = state.encodedBytes + #(chunkData or "")
			state.got = state.got + 1
			Metrics.RecordIncomingSnapshotChunk(mode, #(chunkData or ""))
		end

		if state.got < state.total then
			return
		end

		for i = 1, state.total do
			local piece = state.parts[i]
			if piece == nil then
				module._incoming[key] = nil
				return
			end
		end
		module._incoming[key] = nil

		Metrics.RecordIncomingSnapshotComplete(mode)
		local encodedPayload = tconcat(state.parts, "")
		local payload = SnapshotPayload.DecodeTransportText(encodedPayload)
		if payload == nil then
			addon:warn((Diag.W.LogSyncDecodeFailed):format(tostring(sender), tostring(requestId), tostring(raidNid)))
			finalizeSnapshotFailure(isSync, pending, sender, requestId, "decode_failed", mode)
			return
		end

		local delta = SnapshotPayload.ParseDelta(payload)
		if not delta then
			addon:warn((Diag.W.LogSyncParseFailed):format(tostring(sender), tostring(requestId), tostring(raidNid)))
			finalizeSnapshotFailure(isSync, pending, sender, requestId, "parse_failed", mode)
			return
		end
		if tonumber(delta.header and delta.header.protocolVersion) ~= state.envelopeVersion then
			finalizeSnapshotFailure(isSync, pending, sender, requestId, "version_mismatch", mode)
			return
		end
		local currentRaid = select(1, SnapshotImport.GetCurrentRaidRecord())
		local localRevision = currentRaid and Database.GetRaidStore():GetRaidSyncRevision(currentRaid) or 0
		local validDelta, validationReason = SnapshotPayload.ValidateDelta(delta, localRevision, raidNid)
		if not validDelta then
			finalizeSnapshotFailure(isSync, pending, sender, requestId, validationReason, mode)
			return
		end

		if tonumber(delta.header.protocolVersion) ~= PROTOCOL_VERSION then
			if isDebugEnabled() then
				addon:debug(
					(Diag.D.LogSyncVersionMismatch):format(
						tostring(sender),
						tostring(delta.header.protocolVersion),
						PROTOCOL_VERSION
					)
				)
			end
			finalizeSnapshotFailure(isSync, pending, sender, requestId, "version_mismatch", mode)
			return
		end

		onDeltaReady(sender, requestId, mode, delta)
	end

	-- ----- Public methods ----- --
	function module:GetProtocolVersion()
		return PROTOCOL_VERSION
	end

	function module:GetSyncMetrics()
		return Metrics.Get()
	end

	function module:ResetSyncMetrics()
		return Metrics.Reset()
	end

	function module:RequestLoggerReq(raidRef, targetName)
		if not ensureGroupSyncAvailable() then
			return false
		end

		local requestRef = tonumber(raidRef)
		if not requestRef or requestRef <= 0 then
			addon:warn(L.MsgLoggerSyncRaidRefRequired)
			return false
		end

		local target = resolveExternalTarget(targetName or (loggerOptions and loggerOptions:Get("syncRequirePlayer")))
		if not target then
			return false
		end

		local allowed = allowOutgoingRequest(target, MODE_REQ)
		if not allowed then
			return false, "rate_limited"
		end

		local requestId, requestIdReason = allocateRequestId(self)
		if not requestId then return false, requestIdReason end

		local tracked, trackReason = trackPendingRequest(self, requestId, {
			createdAt = nowSec(),
			mode = MODE_REQ,
			raidRef = requestRef,
			target = target,
			sender = target,
			completed = false,
		})
		if not tracked then return false, trackReason end

		local queued, reason = sendRequest(MODE_REQ, requestId, requestRef, { supportsCompression = false }, target)
		if not queued then
			rollbackPendingRequest(self, requestId)
			return false, reason
		end
		addon:info(L.MsgLoggerReqSent:format(tostring(requestRef), tostring(target)))
		return true
	end

	function module:BroadcastLoggerPush(raidRef, targetName)
		if not ensureGroupSyncAvailable() then
			return false
		end

		local raidRefNum = tonumber(raidRef)
		if not raidRefNum or raidRefNum <= 0 then
			addon:warn(L.MsgLoggerSyncRaidRefRequired)
			return false
		end

		local target = resolveExternalTarget(targetName or (loggerOptions and loggerOptions:Get("syncPushPlayer")))
		if not target then
			return false
		end

		local raid = select(1, SnapshotImport.ResolveRaidByReference(raidRefNum, false))
		if not raid then
			addon:warn(L.MsgLoggerSyncNoRaid)
			return false
		end

		local allowed = allowOutgoingRequest(target, MODE_PUSH)
		if not allowed then
			return false, "rate_limited"
		end

		local requestId, requestIdReason = allocateRequestId(self)
		if not requestId then return false, requestIdReason end

		local sent, reason = sendSnapshot(target, requestId, MODE_PUSH, raid)
		if not sent then return false, reason end
		self._outboundPushes[requestId] = { createdAt = nowSec(), target = target, raidNid = raid.raidNid }
		addon:info(L.MsgLoggerSyncPushSent:format(tostring(tonumber(raid.raidNid) or raidRefNum), tostring(target)))
		return true
	end

	local function requestLoggerSync(syncer, quiet)
		if not ensureGroupSyncAvailable() then
			return false
		end

		local currentRaid, currentRaidId = SnapshotImport.GetCurrentRaidRecord()
		if not currentRaid then
			addon:warn(L.MsgLoggerSyncNoCurrent)
			return false
		end

		local signature = SnapshotImport.BuildSignatureFromRaid(currentRaid)
		signature.sinceRevision = Database.GetRaidStore():GetRaidSyncRevision(currentRaid)
		signature.supportsCompression = false
		local requestId, requestIdReason = allocateRequestId(syncer)
		if not requestId then return false, requestIdReason end

		local tracked, trackReason = trackPendingRequest(syncer, requestId, {
			createdAt = nowSec(),
			mode = MODE_SYNC,
			raidNid = tonumber(currentRaid.raidNid) or 0,
			signature = signature,
			sender = nil,
			failedSenders = {},
			completed = false,
		})
		if not tracked then return false, trackReason end

		local queued, reason = sendRequest(MODE_SYNC, requestId, tonumber(currentRaid.raidNid) or 0, signature)
		if not queued then
			rollbackPendingRequest(syncer, requestId)
			return false, reason
		end
		if quiet ~= true then
			addon:info(L.MsgLoggerSyncSent:format(tonumber(currentRaidId) or 0))
		end
		return true
	end

	function module:RequestLoggerSync()
		return requestLoggerSync(self, false)
	end

	function module:RequestLoggerPersistentSync()
		if not isPersistentSyncEnabled() then
			return false
		end
		if not (addon.IsInGroup and addon.IsInGroup()) then
			return false
		end
		if not SnapshotImport.GetCurrentRaidRecord() then
			return false
		end
		return requestLoggerSync(self, true)
	end

	local function stopPersistentSync()
		if module._persistentSyncHandle then
			CancelTimer(module, module._persistentSyncHandle)
		end
		module._persistentSyncHandle = nil
	end

	local function schedulePersistentSync(delay)
		if not isPersistentSyncEnabled() then
			stopPersistentSync()
			return false
		end
		if module._persistentSyncHandle then
			return module._persistentSyncHandle ~= nil
		end

		module._persistentSyncHandle = ScheduleTimer(module, function()
			module._persistentSyncHandle = nil
			module:RequestLoggerPersistentSync()
			module:RefreshPersistentSync(PERSISTENT_SYNC_INTERVAL_SECONDS)
		end, tonumber(delay) or PERSISTENT_SYNC_INTERVAL_SECONDS)
		return module._persistentSyncHandle ~= nil
	end

	function module:RefreshPersistentSync(delay)
		if not isPersistentSyncEnabled() then
			stopPersistentSync()
			return false
		end
		return schedulePersistentSync(delay)
	end

	local function bindPersistentSyncCallbacks()
		if module._persistentSyncCallbacksBound then
			return
		end

		RegisterCallback(OptionsLoadedEvent, function()
			module:RefreshPersistentSync(5)
		end)
		local persistentSyncEvent = BuildConfigOptionChangedName("persistentSync")
		RegisterCallback(persistentSyncEvent, function()
			stopPersistentSync()
			if isPersistentSyncEnabled() then
				module:RequestLoggerPersistentSync()
				module:RefreshPersistentSync(PERSISTENT_SYNC_INTERVAL_SECONDS)
			end
		end)
		RegisterCallback(RaidCreateEvent, function()
			module:RefreshPersistentSync(5)
		end)

		module._persistentSyncCallbacksBound = true
	end

	bindPersistentSyncCallbacks()

	function module:OnAddonMessage(prefix, msg, channel, sender)
		if prefix ~= COMM_PREFIX then
			return
		end
		if isSelfSender(sender) then
			return
		end
		if type(msg) ~= "string" or msg == "" then
			return
		end

		cleanupExpiredStatePassive()

		local fields, n = splitFields(msg, FIELD_SEP)
		if n < 4 then
			return
		end

		local kind = fields[1]
		local version = parseNumber(fields[2], 0)
		if version ~= PROTOCOL_VERSION and version ~= LEGACY_PROTOCOL_VERSION then
			if isDebugEnabled() then
				addon:debug(
					(Diag.D.LogSyncVersionMismatch):format(tostring(sender), tostring(version), PROTOCOL_VERSION)
				)
			end
			return
		end

		local requestId = tostring(fields[3] or "")
		if requestId == "" or #requestId > MAX_REQUEST_ID_BYTES then
			return
		end

		if kind == MSG_REQUEST and n >= 8 then
			local mode = tostring(fields[4] or "")
			if mode ~= MODE_REQ and mode ~= MODE_SYNC then
				return
			end

			local raidRef = parseNumber(fields[5], 0)
			local zone = SnapshotPayload.DecodeText(fields[6])
			if zone == nil then
				return
			end

			local sigSize = parseNumber(fields[7], 0)
			local sigDiff = parseNumber(fields[8], 0)
			if mode == MODE_SYNC and (sigSize < 1 or sigSize > 40 or sigDiff < 1 or sigDiff > 4) then
				return
			end
			local signature = {
				zone = zone,
				size = sigSize,
				diff = sigDiff,
				sinceRevision = (version == PROTOCOL_VERSION) and parseNumber(fields[9], 0) or 0,
				supportsCompression = version == PROTOCOL_VERSION and parseNumber(fields[10], 0) == 1,
			}

			Metrics.RecordIncomingRequest(mode, #msg)
			handleIncomingRequest(sender, channel, requestId, mode, raidRef, signature)
			return
		end

		if kind == MSG_SNAPSHOT and n >= 8 then
			local mode = tostring(fields[4] or "")
			if mode ~= MODE_REQ and mode ~= MODE_PUSH and mode ~= MODE_SYNC then
				return
			end

			local raidNid = parseNumber(fields[5], nil)
			local partIndex = parseNumber(fields[6], 0)
			local partCount = parseNumber(fields[7], 0)
			local chunkData = fields[8] or ""
			if not raidNid then
				return
			end

			local senderName = stableSenderKey(sender) or tostring(sender)
			handleIncomingSnapshot(senderName, requestId, mode, raidNid, partIndex, partCount, chunkData, version)
			return
		end

		if kind == MSG_DELTA and n >= 8 then
			local mode = tostring(fields[4] or "")
			local raidNid = parseNumber(fields[5], nil)
			local partIndex = parseNumber(fields[6], 0)
			local partCount = parseNumber(fields[7], 0)
			local chunkData = fields[8] or ""
			if not raidNid then
				return
			end

			local senderName = stableSenderKey(sender) or tostring(sender)
			handleIncomingDelta(senderName, requestId, mode, raidNid, partIndex, partCount, chunkData, version)
		end
	end
end
