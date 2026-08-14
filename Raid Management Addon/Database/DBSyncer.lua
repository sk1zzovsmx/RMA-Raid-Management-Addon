-- ----- RMA Lua Contract ----- --
-- deps: addon.DB.RaidStore, addon.DB.SyncProtocol, addon.DB.SyncSession, addon.Comms, addon.Services.Raid, addon.Timer
-- shared: addon.DB.Syncer
-- exports: event-driven version-5 active-raid replication and recovery
-- events: handles RMARaidSync; listens raid commits, load, raid creation, roster, and zone changes

local addon = select(2, ...)
local DB = addon.DB
local Database = addon.Database
local Events = addon.Events
local Bus = addon.Bus
local Comms = addon.Comms
local Options = addon.Options
local Services = addon.Services
local Diag = addon.Diagnose or addon.Diag
local L = addon.L

local Protocol = assert(DB.SyncProtocol, Diag.A.SyncProtocolDependencyNotInitialized)
local SYNC_PROTOCOL_VERSION = assert(Protocol.VERSION == 5 and Protocol.VERSION, Diag.A.SyncProtocolMustBeVersion5)
local Session = assert(DB.SyncSession, Diag.A.SyncSessionDependencyNotInitialized)
local RaidStore = assert(DB.RaidStore, Diag.A.RaidStoreDependencyNotInitialized)
local Raid = assert(Services.Raid, Diag.A.RaidServiceDependencyNotInitialized)
local Timer = assert(addon.Timer, Diag.A.SyncTimerDependencyNotInitialized)
local RegisterCallback = assert(Bus.RegisterCallback, Diag.A.SyncEventBusNotInitialized)
local TriggerEvent = assert(Bus.TriggerEvent, Diag.A.SyncEventPublisherNotInitialized)

local type, tostring, tonumber = type, tostring, tonumber
local pairs = pairs
local UnitName = assert(_G.UnitName, Diag.A.SyncPlayerIdentityApiNotInitialized)
local GetTime = assert(_G.GetTime, Diag.A.SyncClockApiNotInitialized)

DB.Syncer = DB.Syncer or {}
local module = DB.Syncer

local COMM_PREFIX = "RMARaidSync"
local MAX_WIRE_BYTES = 255
local MAX_RANGE_EVENTS = 512
local LIVE_HEAD_DELAY_SECONDS = 0.25
local RECENT_CONCLUSION_TTL_SECONDS = 45
local DISCOVERY_RETRY_SECONDS = 3
local MAX_REENTRY_TRANSITION_EVENTS = 2
local STATUS_SYNCHRONIZED = "synchronized"
local STATUS_RECOVERING = "recovering"
local STATUS_HANDOVER = "handover"
local STATUS_TRANSFERRING_HISTORY = "transferring_history"
local STATUS_SUSPENDED = "suspended"
local STATUS_FAILED = "failed"
local HISTORY_OFFER_TTL_SECONDS = 30
local HISTORY_RESULT_TTL_SECONDS = 30
local HISTORY_OUTGOING_OFFER_RETENTION_SECONDS = 65
local HISTORY_ACCEPTED_TTL_SECONDS = 65
local HISTORY_TRANSFER_TTL_SECONDS = 65
local MAX_HISTORY_OFFERS = 32
local MAX_HISTORY_RESULTS = 32
local LIVE_LOOT_PART_TTL_SECONDS = 5
local MAX_LIVE_LOOT_ASSEMBLIES = 16
local MAX_LIVE_LOOT_PARTS = 32
local MAX_LIVE_LOOT_PAYLOAD_BYTES = 8192
local MAX_LIVE_LOOT_CHUNK_BYTES = 180

if Options and Options.RegisterNamespace then
	Options.RegisterNamespace("Logger", {
		ignoreGroupLoot = false,
		ignoreSelectionThreshold = true,
		loggerLootQualityThreshold = 4,
	})
end

local InternalEvents = assert(Events.Internal, Diag.A.SyncInternalEventsNotInitialized)
local WowEvents = assert(Events.Wow, Diag.A.SyncWoWEventsNotInitialized)
local OptionsLoadedEvent = assert(InternalEvents.OptionsLoaded, Diag.A.OptionsLoadedEventNotInitialized)
local RaidCreateEvent = assert(InternalEvents.RaidCreate, Diag.A.RaidCreateEventNotInitialized)
local RaidRosterDeltaEvent = assert(InternalEvents.RaidRosterDelta, Diag.A.RaidRosterEventNotInitialized)
local RaidInstanceRecognizedEvent =
	assert(InternalEvents.RaidInstanceRecognized, Diag.A.RaidInstanceEventNotInitialized)
local RaidReplicationCommittedEvent =
	assert(InternalEvents.RaidReplicationCommitted, Diag.A.RaidReplicationCommitEventNotInitialized)
local RaidAuthorityRecoveryFinishedEvent =
	assert(InternalEvents.RaidAuthorityRecoveryFinished, Diag.A.RaidAuthorityRecoveryEventNotInitialized)
local RaidReentryRecoveryReadyEvent = InternalEvents.RaidReentryRecoveryReady or "RaidReentryRecoveryReady"
local RaidReentryDecisionResolvedEvent = InternalEvents.RaidReentryDecisionResolved or "RaidReentryDecisionResolved"
local LoggerSelectRaidEvent = assert(InternalEvents.LoggerSelectRaid, Diag.A.LoggerRaidSelectionEventNotInitialized)
local LoggerDataChangedEvent = InternalEvents.LoggerDataChanged or "LoggerDataChanged"
local LoggerRaidOfferReceivedEvent =
	assert(InternalEvents.LoggerRaidOfferReceived, Diag.A.LoggerRaidOfferEventNotInitialized)
local ZoneChangedNewAreaEvent = assert(WowEvents.ZoneChangedNewArea, Diag.A.ZoneChangeEventNotInitialized)
local PartyLootMethodChangedEvent =
	assert(WowEvents.PartyLootMethodChanged, Diag.A.LootMethodChangeEventNotInitialized)

module._status = module._status or STATUS_SYNCHRONIZED
module._statusReason = module._statusReason or "UP_TO_DATE"
module._recentConclusion = nil
module._recovery = nil
module._handover = nil
module._reentry = nil
module._deferReentryAdvertise = false
module._discovery = nil
module._lastWarnedAuthorityPair = nil
module._incomingOffers = {}
module._outgoingOffers = {}
module._historyResults = {}
module._historyTransfer = nil
module._nextOfferId = tonumber(module._nextOfferId) or 0
module._pendingHeadAdvertisement = nil
module._admissionRetry = nil
module._liveLootAssemblies = {}

Timer.BindMixin(module, "Database/DBSyncer")

local function normalizeName(value)
	if type(value) ~= "string" or value == "" then
		return nil
	end
	local normalized = Comms.NormalizeSender(value)
	if type(normalized) ~= "string" or normalized == "" then
		return nil
	end
	return string.lower(normalized)
end

local localPlayer = normalizeName(UnitName("player"))
module._knownAuthority = normalizeName(Raid:GetRaidLeaderName())

local function setStatus(status, reason)
	module._status = status
	module._statusReason = reason
	return status ~= STATUS_FAILED and status ~= STATUS_SUSPENDED
end

local function countEntries(values)
	local count = 0
	for _ in pairs(values) do
		count = count + 1
	end
	return count
end

local function pruneExpiring(values, now)
	for key, value in pairs(values) do
		if type(value) ~= "table" or tonumber(value.expiresAt) == nil or value.expiresAt <= now then
			values[key] = nil
		end
	end
end

local function pruneHistoryRuntime()
	local now = GetTime()
	pruneExpiring(module._incomingOffers, now)
	pruneExpiring(module._outgoingOffers, now)
	pruneExpiring(module._historyResults, now)
	local transfer = module._historyTransfer
	if transfer and transfer.expiresAt <= now then
		module._historyTransfer = nil
	end
	if
		module._status == STATUS_TRANSFERRING_HISTORY
		and module._historyTransfer == nil
		and next(module._outgoingOffers) == nil
	then
		setStatus(STATUS_SYNCHRONIZED, "HISTORY_EXPIRED")
	end
	return now
end

local function historyOfferKey(peer, offerId)
	return tostring(peer) .. "\t" .. tostring(offerId)
end

local function copyScalarTable(value)
	local copy = {}
	for key, item in pairs(value) do
		copy[key] = item
	end
	return copy
end

local function sameOfferSummary(offer, body)
	return offer.raidUid == body.raidUid
		and offer.authorityEpoch == body.authorityEpoch
		and offer.sequence == body.sequence
		and offer.digest == body.digest
		and offer.zone == body.zone
		and offer.startTime == body.startTime
		and offer.size == body.size
		and offer.difficulty == body.difficulty
		and offer.lootCount == body.lootCount
end

local function addBounded(values, key, value, maximum)
	if values[key] == nil and countEntries(values) >= maximum then
		return false, "HISTORY_CAPACITY"
	end
	values[key] = value
	return true
end

local function nextOfferId()
	for _ = 1, 1024 do
		module._nextOfferId = (module._nextOfferId + 1) % 1000000
		local offerId = "offer-" .. tostring(math.floor(GetTime() * 1000)) .. "-" .. tostring(module._nextOfferId)
		if #offerId <= 64 then
			local collision = false
			for _, offer in pairs(module._outgoingOffers) do
				if offer.offerId == offerId then
					collision = true
					break
				end
			end
			if not collision then
				return offerId
			end
		end
	end
	return nil, "OFFER_ID_EXHAUSTED"
end

local function findOutgoingOffer(sender, raidUid, requestId)
	for _, offer in pairs(module._outgoingOffers) do
		if
			offer.target == sender
			and offer.raidUid == raidUid
			and (offer.acceptedRequestId == nil or offer.acceptedRequestId == requestId)
		then
			return offer
		end
	end
	return nil
end

local function notifyHistoryOutcome(outcome, peer)
	local templates = {
		IMPORTED = L and L.StrLoggerHistoryShareImported,
		ALREADY_PRESENT = L and L.StrLoggerHistoryShareAlreadyPresent,
		CONFLICT = L and L.StrLoggerHistoryShareConflict,
		DECLINED = L and L.StrLoggerHistoryShareDeclined,
		FAILED = L and L.StrLoggerHistoryShareFailed,
	}
	local template = templates[outcome]
	if type(template) ~= "string" then
		return
	end
	local message = template:format(tostring(peer or "?"))
	if outcome == "CONFLICT" or outcome == "FAILED" then
		if addon.warn then
			addon:warn(message)
		end
	elseif addon.info then
		addon:info(message)
	end
end

local function trace(eventName, details)
	if not (Options and Options.IsDebugEnabled and Options.IsDebugEnabled()) then
		return
	end
	if addon.debug then
		local historyEvent = string.sub(tostring(eventName), 1, 8) == "HISTORY_"
		local template = historyEvent and Diag and Diag.D and Diag.D.LogRaidHistoryShareTrace
			or Diag and Diag.D and Diag.D.LogRaidSyncTrace
			or "[RaidSync] event=%s %s"
		addon:debug(template:format(tostring(eventName), tostring(details or "")))
	end
end

local function currentRecordAndUid()
	local record = RaidStore:GetActiveRecord()
	if not record then
		return nil, nil
	end
	local raidUid = record.raidUid
	if not raidUid and RaidStore.GetRaidUid then
		raidUid = RaidStore:GetRaidUid(record.state)
	end
	return record, raidUid
end

local function headFromRecord(record, raidUid)
	if type(record) ~= "table" or type(raidUid) ~= "string" then
		return nil
	end
	local head = {
		raidUid = raidUid,
		authorityEpoch = record.authorityEpoch,
		sequence = record.sequence,
		checkpointSequence = record.checkpointSequence,
		digest = record.digest,
		status = record.status,
	}
	local state = type(record.state) == "table" and record.state or record
	if type(state) == "table" and type(state.zone) == "string"
		and (tonumber(state.size) == 10 or tonumber(state.size) == 25)
		and tonumber(state.difficulty)
	then
		head.zone = state.zone
		head.size = tonumber(state.size)
		head.difficulty = tonumber(state.difficulty)
	end
	return head
end

local function pruneLiveLootAssemblies(now)
	local oldestKey, oldestTime
	for key, assembly in pairs(module._liveLootAssemblies) do
		if type(assembly) ~= "table" or tonumber(assembly.expiresAt) == nil or assembly.expiresAt <= now then
			module._liveLootAssemblies[key] = nil
		elseif not oldestTime or assembly.createdAt < oldestTime then
			oldestKey = key
			oldestTime = assembly.createdAt
		end
	end
	return oldestKey
end

local function samePositionAndDigest(localHead, remoteHead)
	return localHead
		and remoteHead
		and localHead.raidUid == remoteHead.raidUid
		and localHead.authorityEpoch == remoteHead.authorityEpoch
		and localHead.sequence == remoteHead.sequence
		and localHead.digest == remoteHead.digest
end

local function sameRaidAndEpoch(localHead, remoteHead)
	return localHead
		and remoteHead
		and localHead.raidUid == remoteHead.raidUid
		and localHead.authorityEpoch == remoteHead.authorityEpoch
end

local function canRequestRange(localHead, remoteHead)
	if not sameRaidAndEpoch(localHead, remoteHead) then
		return false
	end
	local firstMissing = (tonumber(localHead.sequence) or 0) + 1
	local remoteSequence = tonumber(remoteHead.sequence) or 0
	local checkpoint = tonumber(remoteHead.checkpointSequence) or 0
	return firstMissing <= remoteSequence
		and firstMissing > checkpoint
		and remoteSequence - firstMissing + 1 <= MAX_RANGE_EVENTS
end

local function sendGroup(kind, body)
	local message, reason = Protocol.Encode(kind, "-", "-", body)
	if not message then
		return false, reason
	end
	return Comms.SendAddonBatch(COMM_PREFIX, { message })
end

local function sendDirectFireAndForget(kind, target, body)
	local message, reason = Protocol.Encode(kind, "-", "-", body)
	if not message then
		return false, reason
	end
	return Comms.QueueAddonMessage(COMM_PREFIX, message, "WHISPER", target)
end

local function cancelPendingHead()
	local pending = module._pendingHeadAdvertisement
	if pending and pending.timer then
		module:CancelTimer(pending.timer)
	end
	module._pendingHeadAdvertisement = nil
end

local function scheduleConsolidatedHead(record, raidUid)
	local head = headFromRecord(record, raidUid)
	if not head or head.status ~= "active" then
		return false, "NO_ACTIVE_RAID"
	end
	cancelPendingHead()
	local pending = { head = head }
	module._pendingHeadAdvertisement = pending
	local scheduled, timerOrReason = pcall(module.ScheduleTimer, module, function()
		if module._pendingHeadAdvertisement ~= pending then
			return
		end
		module._pendingHeadAdvertisement = nil
		local currentRecord, currentRaidUid = currentRecordAndUid()
		local currentHead = headFromRecord(currentRecord, currentRaidUid)
		if not Raid:IsRaidLeader() or normalizeName(Raid:GetRaidLeaderName()) ~= localPlayer
			or not currentHead or currentHead.status ~= "active"
			or currentHead.raidUid ~= pending.head.raidUid
			or currentHead.authorityEpoch ~= pending.head.authorityEpoch
			or currentHead.sequence ~= pending.head.sequence
		then
			return
		end
		sendGroup("HEAD", currentHead)
	end, LIVE_HEAD_DELAY_SECONDS)
	if scheduled and timerOrReason then
		pending.timer = timerOrReason
		return true
	end
	if module._pendingHeadAdvertisement == pending then
		module._pendingHeadAdvertisement = nil
	end
	local currentRecord, currentRaidUid = currentRecordAndUid()
	local currentHead = headFromRecord(currentRecord, currentRaidUid)
	if Raid:IsRaidLeader() and normalizeName(Raid:GetRaidLeaderName()) == localPlayer
		and currentHead and currentHead.status == "active"
	then
		return sendGroup("HEAD", currentHead)
	end
	return false, timerOrReason or "HEAD_SCHEDULE_FAILED"
end

local function cancelDiscovery()
	local pending = module._discovery
	if pending and pending.timer then
		module:CancelTimer(pending.timer)
	end
	module._discovery = nil
end

local function sendHeadRequest(authority)
	return sendDirectFireAndForget("HEAD_REQ", authority, {})
end

local function isValidHandoverHead(handover, head)
	if type(head) ~= "table" or type(head.raidUid) ~= "string" then
		return false
	end
	if head.status ~= "active"
		or type(head.authorityEpoch) ~= "number"
		or type(head.sequence) ~= "number"
		or type(head.checkpointSequence) ~= "number"
		or head.sequence < 1
		or head.checkpointSequence < 0
		or head.checkpointSequence > head.sequence
		or type(head.digest) ~= "string"
	then
		return false
	end
	if handover.raidUid == nil then
		return true
	end
	local record, raidUid = currentRecordAndUid()
	return head.raidUid == handover.raidUid
		and raidUid == handover.raidUid
		and record ~= nil
		and head.authorityEpoch == record.authorityEpoch
end

local function recordHandoverHead(sender, head)
	local handover = module._handover
	if not handover or not isValidHandoverHead(handover, head) then
		return false, "INVALID_HANDOVER_HEAD"
	end
	local normalized = normalizeName(sender)
	if not normalized then
		return false, "INVALID_SENDER"
	end
	handover.heads[normalized] = headFromRecord(head, head.raidUid)
	return true
end

local function applyRange(events, expectedHead)
	if type(events) ~= "table" or #events < 1 or #events > MAX_RANGE_EVENTS then
		return nil, "INVALID_EVENT_RANGE"
	end
	local snapshot = RaidStore.CaptureRaidHistoryState and RaidStore:CaptureRaidHistoryState() or nil
	for i = 1, #events do
		local event = events[i]
		local applied, reason = RaidStore:ApplyReplicaEvent(event)
		if not applied then
			if snapshot and RaidStore.RestoreRaidHistoryState then
				RaidStore:RestoreRaidHistoryState(snapshot)
			end
			return nil, reason
		end
	end
	local record, raidUid = currentRecordAndUid()
	local head = headFromRecord(record, raidUid)
	if not samePositionAndDigest(head, expectedHead) then
		if snapshot and RaidStore.RestoreRaidHistoryState then
			RaidStore:RestoreRaidHistoryState(snapshot)
		end
		return nil, "DIGEST_MISMATCH"
	end
	TriggerEvent(LoggerDataChangedEvent, "raid_sync")
	return true
end

local function notifyReplicaInstalled(raidUid, wasPresent)
	TriggerEvent(LoggerDataChangedEvent, "raid_sync")
	if wasPresent then
		return
	end
	local raidIndex = RaidStore.GetIndexByUid and RaidStore:GetIndexByUid(raidUid) or nil
	if raidIndex then
		TriggerEvent(LoggerSelectRaidEvent, raidIndex, "sync")
	end
end

local function releaseRecovery(recovery, reason, cancelPending)
	if module._recovery ~= recovery then
		return false, "STALE_RECOVERY"
	end
	module._recovery = nil
	if cancelPending and recovery.requestId then
		Session:CancelRequest(recovery.requestId, reason or "RECOVERY_OBSOLETE")
	end
	return true
end

local function clearAdmissionRetry(reason)
	local retry = module._admissionRetry
	if not retry then
		return false
	end
	module._admissionRetry = nil
	if retry.timer then
		module:CancelTimer(retry.timer)
		retry.timer = nil
	end
	return true
end

local function sameAdmissionRetryTarget(retry, sender, head)
	return retry
		and retry.sender == sender
		and retry.head
		and head
		and retry.head.raidUid == head.raidUid
		and retry.head.authorityEpoch == head.authorityEpoch
		and retry.head.sequence == head.sequence
		and retry.head.digest == head.digest
end

local function preferAdmissionRetryHead(sender, remoteHead)
	local retry = module._admissionRetry
	if
		retry
		and retry.sender == sender
		and retry.head
		and retry.head.raidUid == remoteHead.raidUid
		and retry.head.authorityEpoch == remoteHead.authorityEpoch
		and retry.head.sequence > remoteHead.sequence
	then
		return retry.head
	end
	return remoteHead
end

local function samePositionWithDifferentDigest(expected, actual)
	return expected
		and expected.sequence == actual.sequence
		and expected.digest ~= actual.digest
end

local function rejectInflightDigestConflict(sender, remotePosition)
	local recovery = module._recovery
	if
		recovery
		and recovery.sender == sender
		and recovery.raidUid == remotePosition.raidUid
		and recovery.authorityEpoch == remotePosition.authorityEpoch
		and (
			samePositionWithDifferentDigest(recovery, remotePosition)
			or samePositionWithDifferentDigest(recovery.followUp, remotePosition)
		)
	then
		releaseRecovery(recovery, "DIGEST_CONFLICT", true)
		clearAdmissionRetry("DIGEST_CONFLICT")
		setStatus(STATUS_SUSPENDED, "DIGEST_CONFLICT")
		return true
	end
	local retry = module._admissionRetry
	if
		retry
		and retry.sender == sender
		and retry.head
		and retry.head.raidUid == remotePosition.raidUid
		and retry.head.authorityEpoch == remotePosition.authorityEpoch
		and samePositionWithDifferentDigest(retry.head, remotePosition)
	then
		clearAdmissionRetry("DIGEST_CONFLICT")
		setStatus(STATUS_SUSPENDED, "DIGEST_CONFLICT")
		return true
	end
	return false
end

local finishHandoverRecovery
local broadcastCommittedEvent
local suspendReentry
local publishReentryReady
local cancelReentry
local compareHead

local function finishRecovery(recovery, succeeded, reason)
	if not releaseRecovery(recovery, reason, false) then
		return false, "STALE_RECOVERY"
	end
	if recovery.handover then
		return finishHandoverRecovery(recovery.handover, succeeded, reason)
	end
	if recovery.reentry then
		if not succeeded then
			return suspendReentry(recovery.reentry, reason or "SNAPSHOT_FAILED")
		end
		return publishReentryReady(recovery.reentry, recovery.raidUid)
	end
	if succeeded then
		clearAdmissionRetry("RECOVERY_SUCCEEDED")
		setStatus(STATUS_SYNCHRONIZED, "UP_TO_DATE")
		return true
	end
	setStatus(STATUS_FAILED, reason or "RECOVERY_FAILED")
	return false
end

local requestSnapshot

local function sameRecovery(left, right)
	return left
		and right
		and left.sender == right.sender
		and left.kind == right.kind
		and left.raidUid == right.raidUid
		and left.authorityEpoch == right.authorityEpoch
		and left.sequence == right.sequence
		and left.fromSequence == right.fromSequence
		and left.toSequence == right.toSequence
		and left.digest == right.digest
end

local function coalesceReplicaRecovery(pending, recovery)
	if
		(pending.kind ~= "RANGE_REQ" and pending.kind ~= "SNAP_REQ")
		or (recovery.kind ~= "RANGE_REQ" and recovery.kind ~= "SNAP_REQ")
		or pending.handover
		or pending.reentry
		or recovery.handover
		or recovery.reentry
		or pending.sender ~= recovery.sender
		or pending.raidUid ~= recovery.raidUid
		or pending.authorityEpoch ~= recovery.authorityEpoch
	then
		return false
	end
	local latest = pending.followUp or pending
	if recovery.sequence > latest.sequence then
		pending.followUp = recovery
	end
	return true
end

local function admissionRetryDelay(reason, retryDelay)
	if reason == "RATE_LIMIT" or reason == "RATE_CAPACITY" then
		if type(retryDelay) == "number" and retryDelay >= 0 then
			return retryDelay
		end
		return nil
	end
	if reason == "backpressure" or reason == "scheduler_unavailable" then
		return LIVE_HEAD_DELAY_SECONDS
	end
	return nil
end

local function scheduleAdmissionRetry(sender, remoteHead, reason, retryDelay)
	local delay = admissionRetryDelay(reason, retryDelay)
	if delay == nil then
		return false, reason
	end
	local retry = module._admissionRetry
	if retry then
		if
			retry.sender == sender
			and retry.head
			and retry.head.raidUid == remoteHead.raidUid
			and retry.head.authorityEpoch == remoteHead.authorityEpoch
		then
			if retry.retryUsed then
				clearAdmissionRetry("ADMISSION_RETRY_EXHAUSTED")
				return false, reason
			end
			if remoteHead.sequence > retry.head.sequence then
				retry.head = remoteHead
			end
			return true
		end
		clearAdmissionRetry("ADMISSION_RETRY_REPLACED")
	end
	retry = {
		sender = sender,
		head = remoteHead,
		retryUsed = false,
	}
	module._admissionRetry = retry
	local scheduled, timerOrReason = pcall(module.ScheduleTimer, module, function()
		if module._admissionRetry ~= retry then
			return
		end
		retry.timer = nil
		retry.retryUsed = true
		compareHead(retry.sender, retry.head, true)
	end, delay)
	if not scheduled or not timerOrReason then
		module._admissionRetry = nil
		return false, "TIMER_UNAVAILABLE"
	end
	retry.timer = timerOrReason
	return true
end

local function admitRecovery(recovery)
	local pending = module._recovery
	if pending then
		if sameRecovery(pending, recovery) then
			return true, "RECOVERY_PENDING"
		end
		if coalesceReplicaRecovery(pending, recovery) then
			return true, "RECOVERY_PENDING"
		end
		return false, "RECOVERY_IN_PROGRESS"
	end
	module._recovery = recovery
	return nil
end

local function requestRange(remoteSender, fromSequence, toSequence, remoteHead, handover)
	if module._status == STATUS_SUSPENDED then
		return false, "SUSPENDED"
	end
	local body = {
		raidUid = remoteHead.raidUid,
		authorityEpoch = remoteHead.authorityEpoch,
		fromSequence = fromSequence,
		toSequence = toSequence,
	}
	local recovery = {
		sender = remoteSender,
		kind = "RANGE_REQ",
		raidUid = remoteHead.raidUid,
		authorityEpoch = remoteHead.authorityEpoch,
		sequence = remoteHead.sequence,
		fromSequence = fromSequence,
		toSequence = toSequence,
		digest = remoteHead.digest,
		checkpointSequence = remoteHead.checkpointSequence,
		status = remoteHead.status,
		handover = handover,
	}
	local admitted, admissionReason = admitRecovery(recovery)
	if admitted ~= nil then
		return admitted, admissionReason
	end
	setStatus(STATUS_RECOVERING, "MISSING_RANGE")
	local requestId, reason, retryDelay = Session:BeginRequest(
		"RANGE_REQ",
		remoteSender,
		body,
		"RANGE_DATA",
		body,
		function(ok, why, result)
			if module._recovery ~= recovery then
				return
			end
			if not ok or type(result) ~= "table" then
				local fallback = recovery.followUp or remoteHead
				releaseRecovery(recovery, why or "RANGE_FAILED", false)
				requestSnapshot(remoteSender, fallback, handover)
				return
			end
			local applied, applyReason = applyRange(result.events, remoteHead)
			if not applied then
				local fallback = recovery.followUp or remoteHead
				releaseRecovery(recovery, applyReason or "RANGE_INVALID", false)
				requestSnapshot(remoteSender, fallback, handover)
				return
			end
			local followUp = recovery.followUp
			local finished = finishRecovery(recovery, true, applyReason)
			if followUp and followUp.sequence > remoteHead.sequence then
				return compareHead(followUp.sender, followUp)
			end
			return finished
		end,
		Session.RATE_CLASS_LIVE
	)
	if not requestId then
		local failureReason = reason or "RANGE_REQUEST_FAILED"
		releaseRecovery(recovery, failureReason, false)
		if handover then
			return finishHandoverRecovery(handover, false, failureReason)
		end
		local retried, retryReason = scheduleAdmissionRetry(remoteSender, remoteHead, failureReason, retryDelay)
		if retried then
			return false, failureReason
		end
		if retryReason == "TIMER_UNAVAILABLE" then
			failureReason = retryReason
		end
		setStatus(STATUS_FAILED, failureReason)
		return false, failureReason
	end
	clearAdmissionRetry("LIVE_REQUEST_ADMITTED")
	if module._recovery == recovery then
		recovery.requestId = requestId
	end
	trace("RANGE_REQ", remoteHead.raidUid .. " " .. tostring(fromSequence) .. "-" .. tostring(toSequence))
	return true
end

requestSnapshot = function(remoteSender, remoteHead, handover, reentry)
	if module._status == STATUS_SUSPENDED then
		return false, "SUSPENDED"
	end
	local body = { raidUid = remoteHead.raidUid }
	local metadata = {
		raidUid = remoteHead.raidUid,
		authorityEpoch = remoteHead.authorityEpoch,
		sequence = remoteHead.sequence,
	}
	local recovery = {
		sender = remoteSender,
		kind = "SNAP_REQ",
		raidUid = remoteHead.raidUid,
		authorityEpoch = remoteHead.authorityEpoch,
		sequence = remoteHead.sequence,
		digest = remoteHead.digest,
		checkpointSequence = remoteHead.checkpointSequence,
		status = remoteHead.status,
		handover = handover,
		reentry = reentry,
	}
	local admitted, admissionReason = admitRecovery(recovery)
	if admitted ~= nil then
		return admitted, admissionReason
	end
	setStatus(STATUS_RECOVERING, "SNAPSHOT_REQUIRED")
	local requestId, reason, retryDelay = Session:BeginRequest(
		"SNAP_REQ",
		remoteSender,
		body,
		"SNAP_DATA",
		metadata,
		function(ok, why, result)
			if module._recovery ~= recovery then
				return
			end
			if not ok or type(result) ~= "table" or type(result.snapshot) ~= "table" then
				finishRecovery(recovery, false, why or "SNAPSHOT_FAILED")
				return
			end
			local snapshot = result.snapshot
			if
				snapshot.raidUid ~= remoteHead.raidUid
				or snapshot.authorityEpoch ~= remoteHead.authorityEpoch
				or snapshot.sequence ~= remoteHead.sequence
				or snapshot.digest ~= remoteHead.digest
			then
				finishRecovery(recovery, false, "SNAPSHOT_MISMATCH")
				return
			end
			local current, currentUid = currentRecordAndUid()
			local wasPresent = RaidStore.GetIndexByUid and RaidStore:GetIndexByUid(snapshot.raidUid) ~= nil
			local replaced, replaceReason
			if current and currentUid == snapshot.raidUid then
				replaced, replaceReason = RaidStore:RepairActiveFromSnapshot(snapshot)
			else
				replaced, replaceReason = RaidStore:ReplaceActiveFromSnapshot(snapshot)
			end
			if replaced ~= nil then
				notifyReplicaInstalled(snapshot.raidUid, wasPresent)
			end
			local followUp = recovery.followUp
			local finished = finishRecovery(recovery, replaced ~= nil, replaceReason)
			if replaced ~= nil and followUp then
				return compareHead(followUp.sender, followUp)
			end
			return finished
		end,
		Session.RATE_CLASS_LIVE
	)
	if not requestId then
		local failureReason = reason or "SNAPSHOT_REQUEST_FAILED"
		releaseRecovery(recovery, failureReason, false)
		if handover then
			return finishHandoverRecovery(handover, false, failureReason)
		end
		if reentry then
			return suspendReentry(reentry, failureReason)
		end
		local retried, retryReason = scheduleAdmissionRetry(remoteSender, remoteHead, failureReason, retryDelay)
		if retried then
			return false, failureReason
		end
		if retryReason == "TIMER_UNAVAILABLE" then
			failureReason = retryReason
		end
		setStatus(STATUS_FAILED, failureReason)
		return false, failureReason
	end
	clearAdmissionRetry("LIVE_REQUEST_ADMITTED")
	if module._recovery == recovery then
		recovery.requestId = requestId
	end
	trace("SNAP_REQ", remoteHead.raidUid)
	return true
end

local function publishHandoverFinished(handover, succeeded, reason)
	if not handover or handover.finished then
		return false
	end
	handover.finished = true
	TriggerEvent(RaidAuthorityRecoveryFinishedEvent, handover.raidUid, succeeded == true, reason)
	return true
end

local function suspendHandover(handover, reason)
	if module._handover ~= handover then
		return false, "STALE_HANDOVER"
	end
	local outcomeReason = reason or "HANDOVER_FAILED"
	setStatus(STATUS_SUSPENDED, outcomeReason)
	publishHandoverFinished(handover, false, outcomeReason)
	if outcomeReason ~= "DIGEST_CONFLICT" then
		module._handover = nil
	end
	return false, outcomeReason
end

local function cancelHandover(handover, reason)
	if not handover or module._handover ~= handover then
		return false
	end
	if handover.timer then
		module:CancelTimer(handover.timer)
		handover.timer = nil
	end
	local recovery = module._recovery
	if recovery and recovery.handover == handover then
		releaseRecovery(recovery, reason or "HANDOVER_CANCELLED", true)
	end
	publishHandoverFinished(handover, false, reason or "HANDOVER_CANCELLED")
	module._handover = nil
	return true
end

local function promoteHandover(handover)
	if module._handover ~= handover or normalizeName(Raid:GetRaidLeaderName()) ~= handover.newAuthority then
		return false, "STALE_HANDOVER"
	end
	local record, raidUid = currentRecordAndUid()
	if not record or raidUid ~= handover.raidUid then
		return suspendHandover(handover, "HANDOVER_BASE_MISSING")
	end
	local recoveredIndex
	if handover.needsRaidSelection then
		recoveredIndex = RaidStore.GetIndexByUid and RaidStore:GetIndexByUid(handover.raidUid) or nil
		if not recoveredIndex or not Database or type(Database.SetCurrentRaid) ~= "function" then
			return suspendHandover(handover, "HANDOVER_SELECTION_UNAVAILABLE")
		end
	end
	local promoted, promotedOrReason = RaidStore:PromoteAuthority(handover.raidUid, record.sequence)
	if not promoted then
		return suspendHandover(handover, promotedOrReason or "HANDOVER_PROMOTION_FAILED")
	end
	if recoveredIndex then
		assert(Database.SetCurrentRaid(recoveredIndex) == recoveredIndex, Diag.A.RecoveredRaidSelectionFailed)
	end
	setStatus(STATUS_SYNCHRONIZED, "UP_TO_DATE")
	module._handover = nil
	publishHandoverFinished(handover, true, "UP_TO_DATE")
	return module:AdvertiseHead()
end

finishHandoverRecovery = function(handover, succeeded, reason)
	if not succeeded then
		return suspendHandover(handover, reason or "HANDOVER_RECOVERY_FAILED")
	end
	return promoteHandover(handover)
end

local function selectHandoverBase(handover)
	local positions = {}
	local selectedSender, selectedHead
	for sender, head in pairs(handover.heads) do
		if isValidHandoverHead(handover, head) then
			local position = head.raidUid .. "\t" .. tostring(head.authorityEpoch) .. "\t" .. tostring(head.sequence)
			local digest = positions[position]
			if digest and digest ~= head.digest then
				return nil, nil, "DIGEST_CONFLICT"
			end
			positions[position] = head.digest
			if not selectedHead or head.sequence > selectedHead.sequence then
				selectedSender, selectedHead = sender, head
			end
		end
	end
	local previousHead = handover.heads[handover.previousAuthority]
	if previousHead and isValidHandoverHead(handover, previousHead) then
		return handover.previousAuthority, previousHead
	end
	return selectedSender, selectedHead
end

local function completeHandover(handover)
	if module._handover ~= handover then
		return false, "STALE_HANDOVER"
	end
	local sender, selected, reason = selectHandoverBase(handover)
	if not selected then
		if handover.raidUid == nil and reason == nil then
			setStatus(STATUS_SYNCHRONIZED, "NO_RECOVERABLE_COPY")
			publishHandoverFinished(handover, false, "NO_RECOVERABLE_COPY")
			module._handover = nil
			return true, "NO_RECOVERABLE_COPY"
		end
		return suspendHandover(handover, reason or "HANDOVER_BASE_MISSING")
	end
	if handover.raidUid == nil then
		handover.raidUid = selected.raidUid
	end
	local record, raidUid = currentRecordAndUid()
	local localHead = headFromRecord(record, raidUid)
	if samePositionAndDigest(localHead, selected) then
		return promoteHandover(handover)
	end
	if canRequestRange(localHead, selected) then
		return requestRange(sender, localHead.sequence + 1, selected.sequence, selected, handover)
	end
	return requestSnapshot(sender, selected, handover)
end

local function isValidReentryHead(reentry, head)
	if type(head) ~= "table" or head.status ~= "active"
		or type(head.raidUid) ~= "string" or type(head.authorityEpoch) ~= "number"
		or type(head.sequence) ~= "number" or type(head.checkpointSequence) ~= "number"
		or type(head.digest) ~= "string" or head.sequence < 0
		or head.checkpointSequence < 0 or head.checkpointSequence > head.sequence
	then
		return false
	end
	if reentry.raidUid then
		return head.raidUid == reentry.raidUid and head.authorityEpoch == reentry.authorityEpoch
	end
	return type(head.zone) == "string" and (head.size == 10 or head.size == 25)
		and type(head.difficulty) == "number"
		and head.zone == reentry.context.zone and head.size == reentry.context.size
		and head.difficulty == reentry.context.difficulty
end

local function recordReentryHead(sender, head)
	local reentry = module._reentry
	if not reentry or reentry.phase ~= "collecting" or not Raid:IsGroupMember(sender) then
		return false, "REENTRY_NOT_COLLECTING"
	end
	if reentry.raidUid and type(head) == "table" and head.status == "active"
		and (head.raidUid ~= reentry.raidUid or head.authorityEpoch ~= reentry.authorityEpoch)
	then
		return suspendReentry(reentry, "AUTHORITY_EPOCH_MISMATCH")
	end
	local normalized = normalizeName(sender)
	if not normalized or normalized == localPlayer or not isValidReentryHead(reentry, head) then
		return false, "INVALID_REENTRY_HEAD"
	end
	reentry.heads[normalized] = headFromRecord(head, head.raidUid)
	return true
end

local function selectReentryBase(reentry)
	local selectedSender, selectedHead
	local positions = {}
	local identities = {}
	for sender, head in pairs(reentry.heads) do
		if isValidReentryHead(reentry, head) then
			local identity = head.raidUid .. "\t" .. tostring(head.authorityEpoch)
			identities[identity] = true
			local position = identity .. "\t" .. tostring(head.sequence)
			local digest = positions[position]
			if digest and digest ~= head.digest then
				return nil, nil, "DIGEST_CONFLICT"
			end
			positions[position] = head.digest
			if not selectedHead or head.sequence > selectedHead.sequence
				or (head.sequence == selectedHead.sequence and selectedSender == localPlayer and sender ~= localPlayer)
			then
				selectedSender, selectedHead = sender, head
			end
		end
	end
	if not reentry.raidUid and countEntries(identities) > 1 then
		return nil, nil, "RAID_IDENTITY_CONFLICT"
	end
	return selectedSender, selectedHead
end

suspendReentry = function(reentry, reason)
	if module._reentry ~= reentry then
		return false, "STALE_REENTRY"
	end
	if reentry.timer then
		module:CancelTimer(reentry.timer)
		reentry.timer = nil
	end
	reentry.transitionEvents = nil
	local recovery = module._recovery
	if recovery and recovery.reentry == reentry then
		releaseRecovery(recovery, reason or "REENTRY_SUSPENDED", true)
	end
	reentry.phase = "suspended"
	setStatus(STATUS_SUSPENDED, reason or "REENTRY_SUSPENDED")
	trace("REENTRY_SUSPENDED", tostring(reason or "REENTRY_SUSPENDED"))
	if not reentry.warned then
		reentry.warned = true
		local template = L and L.WarnRaidReentryRecoverySuspended
		addon:warn((template or "Raid database recovery was suspended (%s). Recording remains paused and no raid copy was overwritten.")
			:format(tostring(reason or "REENTRY_SUSPENDED")))
	end
	return false, reason
end

cancelReentry = function(reentry, reason)
	if module._reentry ~= reentry then
		return false, "STALE_REENTRY"
	end
	if reentry.timer then
		module:CancelTimer(reentry.timer)
		reentry.timer = nil
	end
	reentry.transitionEvents = nil
	local recovery = module._recovery
	if recovery and recovery.reentry == reentry then
		releaseRecovery(recovery, reason or "REENTRY_CANCELLED", true)
	end
	reentry.phase = "cancelled"
	module._reentry = nil
	setStatus(STATUS_SYNCHRONIZED, reason or "REENTRY_CANCELLED")
	trace("REENTRY_CANCELLED", tostring(reason or "REENTRY_CANCELLED"))
	return true
end

publishReentryReady = function(reentry, raidUid)
	if module._reentry ~= reentry then
		return false, "STALE_REENTRY"
	end
	if reentry.timer then
		module:CancelTimer(reentry.timer)
		reentry.timer = nil
	end
	reentry.phase = "decision"
	reentry.selectedRaidUid = raidUid
	setStatus(STATUS_RECOVERING, "REENTRY_DECISION_REQUIRED")
	local record = RaidStore:GetActiveRecord()
	TriggerEvent(RaidReentryRecoveryReadyEvent, {
		raidUid = raidUid,
		context = copyScalarTable(reentry.context),
		raid = record and record.state or nil,
	})
	return true
end

local function sameReentryContext(left, right)
	return type(left) == "table" and type(right) == "table"
		and left.zone == right.zone
		and tonumber(left.size) == tonumber(right.size)
		and tonumber(left.difficulty) == tonumber(right.difficulty)
end

local function resolveReentryDecision(_, raidUid, decision, context)
	local reentry = module._reentry
	if not reentry or reentry.phase ~= "decision" then
		return false, "STALE_REENTRY_DECISION"
	end
	if not sameReentryContext(reentry.context, context) then
		return false, "REENTRY_CONTEXT_MISMATCH"
	end
	if decision == "new" then
		if reentry.selectedRaidUid ~= nil or raidUid ~= nil then
			return false, "REENTRY_UID_MISMATCH"
		end
	elseif (decision == "resume" or decision == "replace") and reentry.selectedRaidUid == raidUid then
		-- The recovered active raid can only be continued or concluded once.
	else
		return false, "INVALID_REENTRY_DECISION"
	end
	reentry.phase = "transition"
	reentry.transitionEvents = {}
	if decision == "replace" then
		reentry.expectedLifecycle = { "RAID_CONCLUDED", "RAID_CREATED" }
	elseif decision == "new" then
		reentry.expectedLifecycle = { "RAID_CREATED" }
	else
		reentry.expectedLifecycle = {}
	end
	local succeeded, resultOrReason, deferredRaidId = Raid:ApplyReentryDecision(raidUid, decision, context)
	if succeeded ~= true then
		return suspendReentry(reentry, resultOrReason or "REENTRY_TRANSITION_FAILED")
	end
	if reentry.transitionFailure then
		return suspendReentry(reentry, reentry.transitionFailure)
	end
	if #reentry.transitionEvents ~= #reentry.expectedLifecycle then
		return suspendReentry(reentry, "REENTRY_LIFECYCLE_INCOMPLETE")
	end
	if module._reentry ~= reentry then
		return false, "STALE_REENTRY"
	end
	local transitionEvents = reentry.transitionEvents or {}
	reentry.transitionEvents = nil
	module._reentry = nil
	setStatus(STATUS_SYNCHRONIZED, "UP_TO_DATE")
	for i = 1, #transitionEvents do
		broadcastCommittedEvent(nil, transitionEvents[i])
	end
	if deferredRaidId ~= nil then
		module._deferReentryAdvertise = true
		local invoked, notified, notifyReason = pcall(Raid.NotifyDeferredRaidCreate, Raid, deferredRaidId)
		module._deferReentryAdvertise = false
		if invoked ~= true or notified ~= true then
			module._reentry = reentry
			return suspendReentry(reentry, notifyReason or "REENTRY_RAID_CREATE_NOTIFY_FAILED")
		end
	end
	return module:AdvertiseHead()
end

local function completeReentry(reentry)
	if module._reentry ~= reentry or reentry.phase ~= "collecting" then
		return false, "STALE_REENTRY"
	end
	local remoteHeadCount = 0
	for sender in pairs(reentry.heads) do
		if sender ~= localPlayer then
			remoteHeadCount = remoteHeadCount + 1
		end
	end
	if remoteHeadCount == 0 and reentry.retries == 0 then
		reentry.retries = 1
		sendGroup("HEAD_REQ", {})
		reentry.timer = module:ScheduleTimer(function()
			reentry.timer = nil
			completeReentry(reentry)
		end, DISCOVERY_RETRY_SECONDS)
		return true
	end
	local sender, selected, reason = selectReentryBase(reentry)
	if reason then
		return suspendReentry(reentry, reason)
	end
	if not selected then
		return publishReentryReady(reentry, nil)
	end
	local record, raidUid = currentRecordAndUid()
	local localHead = headFromRecord(record, raidUid)
	local localDigest = record and RaidStore.GetStateDigest and RaidStore:GetStateDigest(record.state) or nil
	if samePositionAndDigest(localHead, selected) and localDigest == record.digest then
		return publishReentryReady(reentry, selected.raidUid)
	end
	reentry.phase = "snapshot"
	return requestSnapshot(sender, selected, nil, reentry)
end

local function startReentry(instanceName, instanceDiff)
	if module._handover then
		return false, "HANDOVER_ACTIVE"
	end
	if module._reentry then
		return nil
	end
	local context, contextReason = Raid:ResolveRaidInstanceContext(instanceName, instanceDiff)
	if not context then
		return false, contextReason
	end
	local record, raidUid = currentRecordAndUid()
	local reentry = {
		phase = "collecting",
		context = context,
		raidUid = raidUid,
		authorityEpoch = record and record.authorityEpoch or nil,
		heads = {},
		retries = 0,
	}
	if record and raidUid then
		reentry.heads[localPlayer] = headFromRecord(record, raidUid)
	end
	module._reentry = reentry
	setStatus(STATUS_RECOVERING, "REENTRY_RECOVERY")
	trace("REENTRY_STARTED", context.zone)
	sendGroup("HEAD_REQ", {})
	reentry.timer = module:ScheduleTimer(function()
		reentry.timer = nil
		completeReentry(reentry)
	end, DISCOVERY_RETRY_SECONDS)
	return nil
end

local function isRealAuthorityHandover(previousAuthority, currentAuthority)
	return previousAuthority ~= nil
		and currentAuthority ~= nil
		and previousAuthority ~= currentAuthority
end

local function refreshAuthority()
	local currentAuthority = normalizeName(Raid:GetRaidLeaderName())
	local previousAuthority = module._knownAuthority
	if currentAuthority == previousAuthority then
		return false
	end
	module._knownAuthority = currentAuthority
	local key = tostring(previousAuthority or "?") .. ">" .. tostring(currentAuthority or "?")
	if module._lastWarnedAuthorityPair ~= key then
		if previousAuthority == localPlayer and currentAuthority then
			addon:warn(L.WarnRaidDatabaseAuthorityReleased:format(currentAuthority))
		elseif currentAuthority == localPlayer and previousAuthority then
			addon:warn(L.WarnRaidDatabaseAuthorityReceived:format(previousAuthority))
		end
		module._lastWarnedAuthorityPair = key
	end
	if module._reentry then
		cancelReentry(module._reentry, "AUTHORITY_CHANGED")
	elseif module._handover then
		cancelHandover(module._handover, "AUTHORITY_CHANGED")
	elseif module._recovery then
		releaseRecovery(module._recovery, "AUTHORITY_CHANGED", true)
	end
	clearAdmissionRetry("AUTHORITY_CHANGED")
	local record, raidUid = currentRecordAndUid()
	local head = headFromRecord(record, raidUid)
	if isRealAuthorityHandover(previousAuthority, currentAuthority)
		and currentAuthority == localPlayer
		and Raid:IsRaidLeader()
	then
		local handover = {
			raidUid = raidUid,
			previousAuthority = previousAuthority,
			newAuthority = currentAuthority,
			startedAt = GetTime(),
			heads = {},
			needsRaidSelection = head == nil,
		}
		module._handover = handover
		if head then
			handover.heads[localPlayer] = head
		else
			sendGroup("HEAD_REQ", {})
		end
		setStatus(STATUS_HANDOVER, "AUTHORITY_CHANGED")
		handover.timer = module:ScheduleTimer(function()
			handover.timer = nil
			completeHandover(handover)
		end, 1)
	end
	if currentAuthority ~= localPlayer and head then
		sendGroup("HEAD", head)
	end
	return true
end

local function requestActiveRaidIfNeeded(eventName, instanceName, instanceKey, instanceDiff)
	refreshAuthority()
	local authority = normalizeName(Raid:GetRaidLeaderName())
	if Raid:IsRaidLeader() and authority == localPlayer then
		local activeRecord = RaidStore:GetActiveRecord()
		if Database and Database.GetCurrentRaid and Database.GetCurrentRaid() == nil and activeRecord then
			return startReentry(instanceName, instanceDiff)
		end
		cancelDiscovery()
		return
	end
	local activeRecord = RaidStore:GetActiveRecord()
	local currentRaid = Database and Database.GetCurrentRaid and Database.GetCurrentRaid() or nil
	local unresolvedReentry = activeRecord
		and currentRaid == nil
		and (authority == nil or authority == localPlayer)
	if activeRecord and not unresolvedReentry then
		cancelDiscovery()
		return
	end
	local validAuthority = authority and authority ~= localPlayer and Raid:IsGroupMember(authority)
	if module._discovery and (module._discovery.authority == nil or module._discovery.authority == authority) then
		return
	end
	cancelDiscovery()
	local pending = {
		authority = validAuthority and authority or nil,
		instanceName = instanceName,
		instanceDiff = instanceDiff,
	}
	module._discovery = pending
	if validAuthority then
		sendHeadRequest(authority)
		if module._discovery ~= pending then
			return
		end
	end
	pending.timer = module:ScheduleTimer(function()
		if module._discovery ~= pending then
			return
		end
		module._discovery = nil
		refreshAuthority()
		local retryActiveRecord = RaidStore:GetActiveRecord()
		local retryCurrentRaid = Database and Database.GetCurrentRaid and Database.GetCurrentRaid() or nil
		local retryAuthority = normalizeName(Raid:GetRaidLeaderName())
		if retryActiveRecord
			and retryCurrentRaid == nil
			and Raid:IsRaidLeader()
			and retryAuthority == localPlayer
		then
			startReentry(pending.instanceName, pending.instanceDiff)
			return
		end
		if retryActiveRecord then
			return
		end
		local currentAuthority = normalizeName(Raid:GetRaidLeaderName())
		if
			not RaidStore:GetActiveRecord()
			and not Raid:IsRaidLeader()
			and currentAuthority
			and currentAuthority ~= localPlayer
			and (pending.authority == nil or currentAuthority == pending.authority)
			and Raid:IsGroupMember(currentAuthority)
		then
			sendHeadRequest(currentAuthority)
		end
	end, DISCOVERY_RETRY_SECONDS)
end

compareHead = function(remoteSender, remoteHead)
	if rejectInflightDigestConflict(remoteSender, remoteHead) then
		return false, "DIGEST_CONFLICT"
	end
	local record, raidUid = currentRecordAndUid()
	local localHead = headFromRecord(record, raidUid)
	if
		localHead
		and localHead.raidUid == remoteHead.raidUid
		and localHead.authorityEpoch == remoteHead.authorityEpoch
		and localHead.sequence == remoteHead.sequence
		and localHead.digest ~= remoteHead.digest
	then
		clearAdmissionRetry("DIGEST_CONFLICT")
		return setStatus(STATUS_SUSPENDED, "DIGEST_CONFLICT")
	end
	remoteHead = preferAdmissionRetryHead(remoteSender, remoteHead)
	if not localHead and remoteHead.status == "complete" then
		local completed = RaidStore:GetRecord(remoteHead.raidUid)
		if completed and completed.status == "complete" then
			localHead = headFromRecord(completed, remoteHead.raidUid)
		end
	end
	if samePositionAndDigest(localHead, remoteHead) then
		local retry = module._admissionRetry
		if sameAdmissionRetryTarget(retry, remoteSender, remoteHead) then
			clearAdmissionRetry("RECOVERY_SATISFIED")
		end
		if module._recovery then
			releaseRecovery(module._recovery, "RECOVERY_SATISFIED", true)
		end
		return setStatus(STATUS_SYNCHRONIZED, "UP_TO_DATE")
	end
	if not localHead and remoteHead.status == "complete" then
		return false, "HISTORY_CONSENT_REQUIRED"
	end
	if localHead and localHead.status == "complete" then
		return false, "HISTORY_CONSENT_REQUIRED"
	end
	if
		localHead
		and localHead.raidUid == remoteHead.raidUid
		and localHead.authorityEpoch == remoteHead.authorityEpoch
		and localHead.sequence == remoteHead.sequence
	then
		clearAdmissionRetry("DIGEST_CONFLICT")
		return setStatus(STATUS_SUSPENDED, "DIGEST_CONFLICT")
	end
	if
		localHead
		and localHead.raidUid == remoteHead.raidUid
		and tonumber(remoteHead.authorityEpoch) < tonumber(localHead.authorityEpoch)
	then
		return false, "OLD_AUTHORITY_EPOCH"
	end
	if remoteHead.status == "complete" then
		if
			not localHead
			or localHead.status ~= "active"
			or localHead.raidUid ~= remoteHead.raidUid
			or localHead.authorityEpoch ~= remoteHead.authorityEpoch
			or remoteHead.sequence <= localHead.sequence
		then
			return false, "HISTORY_CONSENT_REQUIRED"
		end
		return requestSnapshot(remoteSender, remoteHead)
	end
	if sameRaidAndEpoch(localHead, remoteHead) and canRequestRange(localHead, remoteHead) then
		return requestRange(remoteSender, localHead.sequence + 1, remoteHead.sequence, remoteHead)
	end
	return requestSnapshot(remoteSender, remoteHead)
end

local handleHead
local handleEvent
local handleLiveLootPart
local handleRangeRequest
local handleRangeData
local handleSnapshotRequest
local handleSnapshotData
local handleOffer
local handleResult

handleHead = function(sender, envelope)
	if envelope.body.status == "active" then
		cancelDiscovery()
	end
	return compareHead(sender, envelope.body)
end

handleEvent = function(sender, envelope)
	local event = envelope.body.event
	if
		rejectInflightDigestConflict(sender, {
			raidUid = event.raidUid,
			authorityEpoch = event.authorityEpoch,
			sequence = event.sequence,
			digest = event.resultDigest,
		})
	then
		return false, "DIGEST_CONFLICT"
	end
	local record, raidUid = currentRecordAndUid()
	if not record then
		if event.eventType == "RAID_CONCLUDED" then
			return false, "LIVE_RAID_NOT_PRESENT"
		end
		local remoteHead = {
			raidUid = event.raidUid,
			authorityEpoch = event.authorityEpoch,
			sequence = event.sequence,
			checkpointSequence = event.sequence,
			digest = event.resultDigest,
			status = "active",
		}
		return requestSnapshot(sender, remoteHead)
	end
	if event.raidUid ~= raidUid then
		return false, "RAID_UID_MISMATCH"
	end
	if event.authorityEpoch < record.authorityEpoch then
		return false, "OLD_AUTHORITY_EPOCH"
	end
	if event.authorityEpoch ~= record.authorityEpoch then
		return false, "AUTHORITY_EPOCH_MISMATCH"
	end
	if event.sequence == record.sequence + 1 then
		local applied, reason = RaidStore:ApplyReplicaEvent(event)
		if not applied then
			if reason == "DIGEST_MISMATCH" then
				clearAdmissionRetry("DIGEST_MISMATCH")
			end
			return setStatus(STATUS_SUSPENDED, reason or "EVENT_REJECTED")
		end
		TriggerEvent(LoggerDataChangedEvent, "raid_sync")
		local recovery = module._recovery
		local followUp = recovery and recovery.followUp or nil
		if
			recovery
			and recovery.raidUid == event.raidUid
			and recovery.authorityEpoch == event.authorityEpoch
			and recovery.sequence <= event.sequence
		then
			releaseRecovery(recovery, "RECOVERY_SATISFIED_BY_EVENT", true)
		end
		local currentRecord, currentRaidUid = currentRecordAndUid()
		local localHead = headFromRecord(currentRecord, currentRaidUid)
		if sameAdmissionRetryTarget(module._admissionRetry, sender, localHead) then
			clearAdmissionRetry("RECOVERY_SATISFIED_BY_EVENT")
		end
		if followUp and followUp.sequence > event.sequence then
			return compareHead(followUp.sender, followUp)
		end
		return setStatus(STATUS_SYNCHRONIZED, "UP_TO_DATE")
	end
	if event.sequence <= record.sequence then
		if event.sequence == record.sequence and event.resultDigest ~= record.digest then
			clearAdmissionRetry("DIGEST_CONFLICT")
			return setStatus(STATUS_SUSPENDED, "DIGEST_CONFLICT")
		end
		return true
	end
	if event.eventType == "RAID_CONCLUDED" then
		local remoteHead = {
			raidUid = event.raidUid,
			authorityEpoch = event.authorityEpoch,
			sequence = event.sequence,
			checkpointSequence = event.sequence,
			digest = event.resultDigest,
			status = "complete",
		}
		return requestSnapshot(sender, remoteHead)
	end
	local remoteHead = {
		raidUid = event.raidUid,
		authorityEpoch = event.authorityEpoch,
		sequence = event.sequence,
		checkpointSequence = 0,
		digest = event.resultDigest,
		status = "active",
	}
	return requestRange(sender, record.sequence + 1, event.sequence, remoteHead)
end

local function liveLootAssemblyKey(sender, body)
	return table.concat({ sender, body.raidUid, tostring(body.authorityEpoch), tostring(body.sequence) }, "\t")
end

handleLiveLootPart = function(sender, envelope)
	local body = envelope.body
	local now = GetTime()
	local oldestKey = pruneLiveLootAssemblies(now)
	local key = liveLootAssemblyKey(sender, body)
	local assembly = module._liveLootAssemblies[key]
	if not assembly then
		if countEntries(module._liveLootAssemblies) >= MAX_LIVE_LOOT_ASSEMBLIES and oldestKey then
			module._liveLootAssemblies[oldestKey] = nil
		end
		assembly = {
			createdAt = now,
			expiresAt = now + LIVE_LOOT_PART_TTL_SECONDS,
			partCount = body.partCount,
			parts = {},
			received = 0,
			bytes = 0,
		}
		module._liveLootAssemblies[key] = assembly
	elseif assembly.partCount ~= body.partCount then
		module._liveLootAssemblies[key] = nil
		return false, "LIVE_LOOT_PART_CONFLICT"
	end

	local existing = assembly.parts[body.partIndex]
	if existing then
		if existing == body.chunk then
			return true
		end
		module._liveLootAssemblies[key] = nil
		return false, "LIVE_LOOT_PART_CONFLICT"
	end
	if assembly.bytes + #body.chunk > MAX_LIVE_LOOT_PAYLOAD_BYTES then
		module._liveLootAssemblies[key] = nil
		return false, "LIVE_LOOT_PART_TOO_LARGE"
	end
	assembly.parts[body.partIndex] = body.chunk
	assembly.received = assembly.received + 1
	assembly.bytes = assembly.bytes + #body.chunk
	if assembly.received < assembly.partCount then
		return true
	end

	module._liveLootAssemblies[key] = nil
	local serialized = table.concat(assembly.parts)
	if #serialized < 1 or #serialized > MAX_LIVE_LOOT_PAYLOAD_BYTES then
		return false, "LIVE_LOOT_PART_DECODE_FAILED"
	end
	local event, decodeReason = Protocol.DecodeLiveLootPayload(serialized)
	if not event then
		return false, decodeReason or "LIVE_LOOT_PART_DECODE_FAILED"
	end
	if
		event.raidUid ~= body.raidUid
		or event.authorityEpoch ~= body.authorityEpoch
		or event.sequence ~= body.sequence
	then
		return false, "LIVE_LOOT_PART_METADATA_MISMATCH"
	end
	return handleEvent(sender, { body = { event = event } })
end

handleRangeRequest = function(sender, envelope)
	local currentAuthority = normalizeName(Raid:GetRaidLeaderName())
	if not Raid:IsRaidLeader() and sender ~= currentAuthority then
		return false, "NOT_AUTHORITY"
	end
	local allowed, reason = Session:AllowIncomingRequest(sender, Session.RATE_CLASS_LIVE)
	if not allowed then
		return false, reason
	end
	local body = envelope.body
	local record = RaidStore:GetRecord(body.raidUid)
	if not record or record.status ~= "active" or record.authorityEpoch ~= body.authorityEpoch then
		return false, "RANGE_UNAVAILABLE"
	end
	if body.toSequence > record.sequence then
		return false, "RANGE_UNAVAILABLE"
	end
	local events, rangeReason =
		RaidStore:GetEventRange(body.raidUid, body.fromSequence - 1, body.toSequence - body.fromSequence + 1)
	if not events or #events ~= body.toSequence - body.fromSequence + 1 then
		return false, rangeReason or "RANGE_UNAVAILABLE"
	end
	return Session:QueueTransfer("RANGE_DATA", envelope.requestId, sender, body, { events = events }, Session.RATE_CLASS_LIVE)
end

handleRangeData = function(sender, envelope)
	return Session:ReceiveChunk(sender, envelope)
end

handleSnapshotRequest = function(sender, envelope)
	pruneHistoryRuntime()
	local offer = findOutgoingOffer(sender, envelope.body.raidUid, envelope.requestId)
	if offer then
		if not Raid:IsGroupMember(sender) then
			return false, "HISTORY_CONSENT_REQUIRED"
		end
		local allowed, reason = Session:AllowIncomingRequest(sender, Session.RATE_CLASS_HISTORY)
		if not allowed then
			return false, reason
		end
		local historicalRecord = RaidStore:GetRecord(offer.localRaidUid)
		if not historicalRecord or historicalRecord.status ~= "complete" then
			return false, "SNAPSHOT_UNAVAILABLE"
		end
		if offer.state == "offered" then
			offer.state = "accepted"
			offer.acceptedRequestId = envelope.requestId
			offer.expiresAt = GetTime() + HISTORY_ACCEPTED_TTL_SECONDS
		elseif offer.state ~= "accepted" or offer.acceptedRequestId ~= envelope.requestId then
			return false, "HISTORY_CONSENT_REQUIRED"
		end
		local snapshot, snapshotReason = RaidStore:BuildSnapshot(offer.localRaidUid)
		if not snapshot or snapshot.status ~= "complete" then
			return false, snapshotReason or "SNAPSHOT_UNAVAILABLE"
		end
		local metadata = {
			raidUid = snapshot.raidUid,
			authorityEpoch = snapshot.authorityEpoch,
			sequence = snapshot.sequence,
		}
		return Session:QueueTransfer("SNAP_DATA", envelope.requestId, sender, metadata, { snapshot = snapshot }, Session.RATE_CLASS_HISTORY)
	end
	local currentAuthority = normalizeName(Raid:GetRaidLeaderName())
	if not Raid:IsRaidLeader() and sender ~= currentAuthority then
		return false, "NOT_AUTHORITY"
	end
	local allowed, reason = Session:AllowIncomingRequest(sender, Session.RATE_CLASS_LIVE)
	if not allowed then
		return false, reason
	end
	local current, currentUid = currentRecordAndUid()
	local snapshot, snapshotReason
	if current and currentUid == envelope.body.raidUid then
		snapshot, snapshotReason = RaidStore:BuildSnapshot(envelope.body.raidUid)
	end
	if not snapshot or snapshot.status ~= "active" then
		local recent = module._recentConclusion
		if recent and recent.expiresAt < GetTime() then
			module._recentConclusion = nil
			recent = nil
		end
		if not recent or recent.raidUid ~= envelope.body.raidUid then
			return false, snapshotReason or "SNAPSHOT_UNAVAILABLE"
		end
		snapshot = recent.snapshot
	end
	local metadata = {
		raidUid = envelope.body.raidUid,
		authorityEpoch = snapshot.authorityEpoch,
		sequence = snapshot.sequence,
	}
	return Session:QueueTransfer("SNAP_DATA", envelope.requestId, sender, metadata, { snapshot = snapshot }, Session.RATE_CLASS_LIVE)
end

handleSnapshotData = function(sender, envelope)
	return Session:ReceiveChunk(sender, envelope)
end

handleOffer = function(sender, envelope)
	local now = pruneHistoryRuntime()
	local key = historyOfferKey(sender, envelope.requestId)
	local existing = module._incomingOffers[key]
	if existing then
		if sameOfferSummary(existing, envelope.body) then
			return true
		end
		return false, "OFFER_CONFLICT"
	end
	local offer = {
		offerId = envelope.requestId,
		sender = sender,
		target = normalizeName(envelope.target),
		raidUid = envelope.body.raidUid,
		authorityEpoch = envelope.body.authorityEpoch,
		sequence = envelope.body.sequence,
		digest = envelope.body.digest,
		zone = envelope.body.zone,
		startTime = envelope.body.startTime,
		size = envelope.body.size,
		difficulty = envelope.body.difficulty,
		lootCount = envelope.body.lootCount,
		state = "offered",
		expiresAt = now + HISTORY_OFFER_TTL_SECONDS,
	}
	local added, reason = addBounded(module._incomingOffers, key, offer, MAX_HISTORY_OFFERS)
	if not added then
		return false, reason
	end
	Bus.TriggerEvent(LoggerRaidOfferReceivedEvent, copyScalarTable(offer))
	trace("HISTORY_OFFER_RECEIVED", offer.raidUid)
	return true
end

handleResult = function(sender, envelope)
	local now = pruneHistoryRuntime()
	local matchedKey
	for key, offer in pairs(module._outgoingOffers) do
		local declined = envelope.body.outcome == "DECLINED"
		local validDecline = declined and offer.state == "offered" and offer.offerId == envelope.requestId
		local validTerminal = not declined
			and offer.state == "accepted"
			and offer.acceptedRequestId == envelope.requestId
		if offer.target == sender and (validDecline or validTerminal) then
			matchedKey = key
			break
		end
	end
	if not matchedKey then
		return false, "UNKNOWN_HISTORY_RESULT"
	end
	local result = {
		sender = sender,
		requestId = envelope.requestId,
		outcome = envelope.body.outcome,
		reason = envelope.body.reason,
		expiresAt = now + HISTORY_RESULT_TTL_SECONDS,
	}
	local added, reason =
		addBounded(module._historyResults, historyOfferKey(sender, envelope.requestId), result, MAX_HISTORY_RESULTS)
	if not added then
		return false, reason
	end
	module._outgoingOffers[matchedKey] = nil
	local failed = envelope.body.outcome == "FAILED" or envelope.body.outcome == "CONFLICT"
	setStatus(failed and STATUS_FAILED or STATUS_SYNCHRONIZED, envelope.body.outcome)
	notifyHistoryOutcome(envelope.body.outcome, sender)
	trace("HISTORY_RESULT", envelope.body.outcome)
	return true
end

local function handleHeadRequest(sender)
	local leader = normalizeName(Raid:GetRaidLeaderName())
	if sender == leader and leader ~= localPlayer and Raid:IsGroupMember(sender) then
		local record, raidUid = currentRecordAndUid()
		local head = headFromRecord(record, raidUid)
		return head and sendDirectFireAndForget("HEAD", sender, head) or false
	end
	if Raid:IsRaidLeader() and leader == localPlayer and Raid:IsGroupMember(sender) then
		return module:AdvertiseHead()
	end
	return false
end

local HANDLERS = {
	HEAD_REQ = handleHeadRequest,
	HEAD = handleHead,
	EVENT = handleEvent,
	LIVE_LOOT = handleEvent,
	LIVE_LOOT_PART = handleLiveLootPart,
	RANGE_REQ = handleRangeRequest,
	RANGE_DATA = handleRangeData,
	SNAP_REQ = handleSnapshotRequest,
	SNAP_DATA = handleSnapshotData,
	OFFER = handleOffer,
	RESULT = handleResult,
}

function module:GetProtocolVersion()
	return SYNC_PROTOCOL_VERSION
end

function module:GetStatus()
	pruneHistoryRuntime()
	pruneLiveLootAssemblies(GetTime())
	return self._status, self._statusReason
end

function module:IsAuthorityRecovering(raidUid)
	local handover = self._handover
	if handover and (raidUid == nil or handover.raidUid == raidUid) then
		return true
	end
	local reentry = self._reentry
	if reentry and (raidUid == nil or reentry.raidUid == nil or reentry.raidUid == raidUid) then
		return true
	end
	local record, activeUid = currentRecordAndUid()
	return record ~= nil and Raid:IsRaidLeader() and Database and Database.GetCurrentRaid
		and Database.GetCurrentRaid() == nil and (raidUid == nil or raidUid == activeUid)
end

function module:AdvertiseHead()
	if not Raid:IsRaidLeader() then
		return false, "NOT_AUTHORITY"
	end
	if self._handover then
		return false, "HANDOVER_IN_PROGRESS"
	end
	if self._reentry then
		return false, "AUTHORITY_RECOVERING"
	end
	if Database and Database.GetCurrentRaid and Database.GetCurrentRaid() == nil then
		return false, "AUTHORITY_RECOVERY_REQUIRED"
	end
	local record, raidUid = currentRecordAndUid()
	local head = headFromRecord(record, raidUid)
	if not head then
		return false, "NO_ACTIVE_RAID"
	end
	return sendGroup("HEAD", head)
end

function module:RequestMissingRange(sender, remoteHead, fromSequence, toSequence)
	return requestRange(sender, fromSequence, toSequence, remoteHead)
end

function module:RequestSnapshot(sender, remoteHead)
	return requestSnapshot(sender, remoteHead)
end

function module:OfferHistoricalRaid(raidUid, target)
	local now = pruneHistoryRuntime()
	local normalizedTarget = normalizeName(target)
	if not normalizedTarget or normalizedTarget == localPlayer or not Raid:IsGroupMember(target) then
		return false, "INVALID_HISTORY_TARGET"
	end
	local record = RaidStore:GetRecord(raidUid)
	if not record or record.status ~= "complete" or type(record.state) ~= "table" then
		return false, "HISTORY_NOT_COMPLETE"
	end
	local snapshot, snapshotReason = RaidStore:BuildSnapshot(raidUid)
	if not snapshot or snapshot.status ~= "complete" then
		return false, snapshotReason or "SNAPSHOT_UNAVAILABLE"
	end
	for key, offer in pairs(self._outgoingOffers) do
		if offer.target == normalizedTarget and offer.localRaidUid == raidUid then
			self._outgoingOffers[key] = nil
		end
	end
	local offerId, idReason = nextOfferId()
	if not offerId then
		return false, idReason
	end
	local state = snapshot.state
	local body = {
		raidUid = snapshot.raidUid,
		authorityEpoch = snapshot.authorityEpoch,
		sequence = snapshot.sequence,
		digest = snapshot.digest,
		zone = state.zone,
		startTime = state.startTime,
		size = state.size,
		difficulty = state.difficulty,
		lootCount = type(state.loot) == "table" and #state.loot or 0,
	}
	local message, encodeReason = Protocol.Encode("OFFER", offerId, target, body)
	if not message then
		return false, encodeReason
	end
	local key = historyOfferKey(normalizedTarget, offerId)
	local offer = {
		offerId = offerId,
		target = normalizedTarget,
		localRaidUid = raidUid,
		raidUid = snapshot.raidUid,
		authorityEpoch = snapshot.authorityEpoch,
		sequence = snapshot.sequence,
		digest = snapshot.digest,
		state = "offered",
		expiresAt = now + HISTORY_OUTGOING_OFFER_RETENTION_SECONDS,
	}
	local added, addReason = addBounded(self._outgoingOffers, key, offer, MAX_HISTORY_OFFERS)
	if not added then
		return false, addReason
	end
	local queued, queueReason = Comms.QueueAddonMessage(COMM_PREFIX, message, "WHISPER", target)
	if not queued then
		self._outgoingOffers[key] = nil
		return false, queueReason or "SEND_FAILED"
	end
	setStatus(STATUS_TRANSFERRING_HISTORY, "HISTORY_OFFERED")
	trace("HISTORY_OFFER_SENT", raidUid)
	return true, offerId
end

function module:AcceptHistoricalOffer(sender, offerId)
	local now = pruneHistoryRuntime()
	if self._historyTransfer then
		return false, "HISTORY_TRANSFER_IN_PROGRESS"
	end
	local normalizedSender = normalizeName(sender)
	local key = normalizedSender and historyOfferKey(normalizedSender, offerId) or nil
	local offer = key and self._incomingOffers[key] or nil
	if not offer or offer.state ~= "offered" or not Raid:IsGroupMember(sender) then
		return false, "OFFER_UNAVAILABLE"
	end
	offer.state = "accepted"
	offer.expiresAt = now + HISTORY_ACCEPTED_TTL_SECONDS
	self._historyTransfer = {
		sender = normalizedSender,
		offerId = offerId,
		raidUid = offer.raidUid,
		expiresAt = now + HISTORY_TRANSFER_TTL_SECONDS,
	}
	setStatus(STATUS_TRANSFERRING_HISTORY, "HISTORY_TRANSFER")
	local requestId, reason = Session:BeginRequest(
		"SNAP_REQ",
		sender,
		{ raidUid = offer.raidUid },
		"SNAP_DATA",
		{ raidUid = offer.raidUid, authorityEpoch = offer.authorityEpoch, sequence = offer.sequence },
		function(ok, why, result, request)
			local transfer = module._historyTransfer
			if not transfer or transfer.offerId ~= offerId or transfer.sender ~= normalizedSender then
				return
			end
			module._historyTransfer = nil
			module._incomingOffers[key] = nil
			local terminalRequestId = request and request.requestId or transfer.requestId or offerId
			if not ok or type(result) ~= "table" or type(result.snapshot) ~= "table" then
				Session:SendResult(sender, terminalRequestId, "FAILED", why or "TRANSFER_FAILED")
				setStatus(STATUS_FAILED, why or "TRANSFER_FAILED")
				notifyHistoryOutcome("FAILED", sender)
				return
			end
			local snapshot = result.snapshot
			if
				snapshot.raidUid ~= offer.raidUid
				or snapshot.authorityEpoch ~= offer.authorityEpoch
				or snapshot.sequence ~= offer.sequence
				or snapshot.digest ~= offer.digest
				or snapshot.status ~= "complete"
			then
				Session:SendResult(sender, terminalRequestId, "FAILED", "SNAPSHOT_MISMATCH")
				setStatus(STATUS_FAILED, "SNAPSHOT_MISMATCH")
				notifyHistoryOutcome("FAILED", sender)
				return
			end
			local outcome, importReason, importedIndex = RaidStore:ImportHistoricalSnapshot(snapshot)
			if not outcome then
				Session:SendResult(sender, terminalRequestId, "FAILED", importReason or "IMPORT_FAILED")
				setStatus(STATUS_FAILED, importReason or "IMPORT_FAILED")
				notifyHistoryOutcome("FAILED", sender)
				return
			end
			Session:SendResult(sender, terminalRequestId, outcome, importReason)
			notifyHistoryOutcome(outcome, sender)
			trace("HISTORY_IMPORT", outcome)
			if outcome == "IMPORTED" or outcome == "CONFLICT" then
				Bus.TriggerEvent(LoggerSelectRaidEvent, importedIndex, "sync")
			end
			setStatus(outcome == "CONFLICT" and STATUS_FAILED or STATUS_SYNCHRONIZED, outcome)
		end,
		Session.RATE_CLASS_HISTORY
	)
	if not requestId then
		offer.state = "offered"
		offer.expiresAt = now + HISTORY_OFFER_TTL_SECONDS
		self._historyTransfer = nil
		setStatus(STATUS_FAILED, reason or "HISTORY_REQUEST_FAILED")
		return false, reason
	end
	if self._historyTransfer then
		self._historyTransfer.requestId = requestId
	end
	return true, requestId
end

function module:DeclineHistoricalOffer(sender, offerId)
	pruneHistoryRuntime()
	local normalizedSender = normalizeName(sender)
	local key = normalizedSender and historyOfferKey(normalizedSender, offerId) or nil
	local offer = key and self._incomingOffers[key] or nil
	if not offer or offer.state ~= "offered" then
		return false, "OFFER_UNAVAILABLE"
	end
	self._incomingOffers[key] = nil
	if Raid:IsGroupMember(sender) then
		Session:SendResult(sender, offerId, "DECLINED")
	end
	notifyHistoryOutcome("DECLINED", sender)
	return true
end

function module:OnAddonMessage(prefix, message, channel, rawSender)
	if prefix ~= COMM_PREFIX or type(message) ~= "string" or #message < 1 or #message > MAX_WIRE_BYTES then
		return false
	end
	local sender = normalizeName(rawSender)
	if not sender or sender == localPlayer then
		return false
	end
	local envelope = Protocol.Decode(message)
	if type(envelope) ~= "table" or type(envelope.body) ~= "table" then
		return false
	end
	if not Raid:IsGroupMember(rawSender) then
		return false
	end
	pruneHistoryRuntime()
	refreshAuthority()
	local kind = envelope.kind
	local handler = HANDLERS[kind]
	if not handler then
		return false
	end
	local leader = normalizeName(Raid:GetRaidLeaderName())
	local handover = module._handover
	local reentry = module._reentry
	if kind == "HEAD" and handover and handover.newAuthority == localPlayer then
		return recordHandoverHead(sender, envelope.body)
	end
	if kind == "HEAD" and reentry and normalizeName(Raid:GetRaidLeaderName()) == localPlayer
		and Raid:IsRaidLeader()
	then
		return recordReentryHead(sender, envelope.body)
	end
	if
		kind == "HEAD"
		or kind == "EVENT"
		or kind == "LIVE_LOOT"
		or kind == "LIVE_LOOT_PART"
		or kind == "RANGE_DATA"
		or kind == "SNAP_DATA"
	then
		local handoverResponse = handover
			and handover.newAuthority == localPlayer
			and module._recovery
			and module._recovery.handover == handover
			and module._recovery.sender == sender
			and (kind == "RANGE_DATA" or kind == "SNAP_DATA")
		local reentryResponse = module._reentry
			and module._recovery
			and module._recovery.reentry == module._reentry
			and module._recovery.sender == sender
			and kind == "SNAP_DATA"
		local historyResponse = kind == "SNAP_DATA"
			and module._historyTransfer
			and module._historyTransfer.sender == sender
			and module._historyTransfer.requestId == envelope.requestId
		if not handoverResponse and not reentryResponse and not historyResponse and (not leader or sender ~= leader) then
			return false
		end
	end
	if
		kind ~= "HEAD_REQ"
		and kind ~= "HEAD"
		and kind ~= "EVENT"
		and kind ~= "LIVE_LOOT"
		and kind ~= "LIVE_LOOT_PART"
	then
		if normalizeName(envelope.target) ~= localPlayer then
			return false
		end
	end
	return handler(sender, envelope, channel)
end

local function buildFragmentedLiveLoot(event)
	local serialized, serializeReason = Protocol.EncodeLiveLootPayload(event)
	if not serialized then
		return nil, serializeReason
	end
	if #serialized > MAX_LIVE_LOOT_PAYLOAD_BYTES then
		return nil, "LIVE_LOOT_TOO_LARGE"
	end

	for chunkBytes = MAX_LIVE_LOOT_CHUNK_BYTES, 1, -1 do
		local partCount = math.ceil(#serialized / chunkBytes)
		if partCount > MAX_LIVE_LOOT_PARTS then
			return nil, "LIVE_LOOT_TOO_MANY_PARTS"
		end
		local messages = {}
		local retrySmaller = false
		for partIndex = 1, partCount do
			local chunk = string.sub(serialized, (partIndex - 1) * chunkBytes + 1, partIndex * chunkBytes)
			local message, reason = Protocol.Encode("LIVE_LOOT_PART", "-", "-", {
				raidUid = event.raidUid,
				authorityEpoch = event.authorityEpoch,
				sequence = event.sequence,
				partIndex = partIndex,
				partCount = partCount,
				chunk = chunk,
			})
			if not message then
				if reason == "MESSAGE_TOO_LARGE" then
					retrySmaller = true
					break
				end
				return nil, reason
			end
			messages[partIndex] = message
		end
		if not retrySmaller then
			return messages
		end
	end
	return nil, "MESSAGE_TOO_LARGE"
end

broadcastCommittedEvent = function(_, event)
	if not Raid:IsRaidLeader() or module._handover or type(event) ~= "table" then
		return
	end
	local reentry = module._reentry
	if reentry then
		if reentry.phase == "transition" then
			local events = reentry.transitionEvents
			local expected = reentry.expectedLifecycle
			local expectedType = type(expected) == "table" and expected[#events + 1] or nil
			if type(events) ~= "table" or #events >= MAX_REENTRY_TRANSITION_EVENTS or not expectedType then
				reentry.transitionFailure = "REENTRY_UNEXPECTED_LIFECYCLE"
				return
			end
			if event.eventType ~= expectedType then
				reentry.transitionFailure = "REENTRY_LIFECYCLE_ORDER"
				return
			end
			if expectedType == "RAID_CONCLUDED" and event.raidUid ~= reentry.selectedRaidUid then
				reentry.transitionFailure = "REENTRY_LIFECYCLE_UID"
				return
			end
			if expectedType == "RAID_CREATED" then
				if type(event.raidUid) ~= "string" or event.raidUid == "" or event.raidUid == reentry.selectedRaidUid then
					reentry.transitionFailure = "REENTRY_LIFECYCLE_UID"
					return
				end
				reentry.createdRaidUid = event.raidUid
			end
			if #events + 1 > #expected then
				reentry.transitionFailure = "REENTRY_UNEXPECTED_LIFECYCLE"
				return
			end
			events[#events + 1] = event
		end
		return
	end
	local record = RaidStore:GetRecord(event.raidUid)
	if not record or event.authorityEpoch ~= record.authorityEpoch or event.sequence ~= record.sequence then
		return
	end
	if event.eventType == "RAID_CONCLUDED" then
		local snapshot = RaidStore:BuildSnapshot(event.raidUid)
		if snapshot and snapshot.status == "complete" then
			module._recentConclusion = {
				raidUid = event.raidUid,
				snapshot = snapshot,
				expiresAt = GetTime() + RECENT_CONCLUSION_TTL_SECONDS,
			}
		end
	end
	if event.eventType == "RAID_CONCLUDED" then
		cancelPendingHead()
		sendGroup("EVENT", { event = event })
		local finalHead = headFromRecord(record, event.raidUid)
		if finalHead then
			sendGroup("HEAD", finalHead)
		end
		return
	end
	if event.eventType == "LOOT_ADDED" then
		local wire, reason = Protocol.Encode("LIVE_LOOT", "-", "-", { event = event })
		if wire then
			local queued, queueReason = Comms.SendAddonBatch(COMM_PREFIX, { wire })
			if not queued then
				setStatus(STATUS_FAILED, queueReason or "LIVE_LOOT_SEND_FAILED")
			end
		elseif reason == "MESSAGE_TOO_LARGE" then
			local messages, fragmentReason = buildFragmentedLiveLoot(event)
			if not messages then
				setStatus(STATUS_FAILED, fragmentReason or "LIVE_LOOT_FRAGMENT_FAILED")
			else
				local queued, queueReason = Comms.SendAddonBatch(COMM_PREFIX, messages)
				if not queued then
					setStatus(STATUS_FAILED, queueReason or "LIVE_LOOT_SEND_FAILED")
				end
			end
		elseif reason ~= "NON_RECONSTRUCTIBLE_LIVE_LOOT" then
			setStatus(STATUS_FAILED, reason or "LIVE_LOOT_ENCODE_FAILED")
		end
	else
		sendGroup("EVENT", { event = event })
	end
	if record.status == "active" then
		scheduleConsolidatedHead(record, event.raidUid)
	end
end

local function advertiseIfAuthoritative()
	if module._deferReentryAdvertise then
		return
	end
	if not refreshAuthority() and not module._reentry then
		module:AdvertiseHead()
	end
end

assert(RaidStore:SetAuthorityGuard(function(operation)
	refreshAuthority()
	local isRaidLeader = Raid:IsRaidLeader() == true
	local identifiedLeader = normalizeName(Raid:GetRaidLeaderName())
	if operation == "promote" then
		return module._handover ~= nil
	end
	if module._handover ~= nil then
		return false, "AUTHORITY_RECOVERING"
	end
	if module._reentry ~= nil then
		if module._reentry.phase ~= "transition" then
			return false, "AUTHORITY_RECOVERING"
		end
	end
	if Raid:IsRaidLeader() and RaidStore:GetActiveRecord() and Database and Database.GetCurrentRaid
		and Database.GetCurrentRaid() == nil
	then
		return false, "AUTHORITY_RECOVERY_REQUIRED"
	end
	return isRaidLeader and identifiedLeader ~= nil and identifiedLeader == localPlayer
end))
Comms.RegisterPrefixIfAvailable(COMM_PREFIX)
RegisterCallback(RaidReplicationCommittedEvent, broadcastCommittedEvent)
RegisterCallback(RaidInstanceRecognizedEvent, requestActiveRaidIfNeeded)
RegisterCallback(RaidReentryDecisionResolvedEvent, resolveReentryDecision)
RegisterCallback(OptionsLoadedEvent, advertiseIfAuthoritative)
RegisterCallback(RaidCreateEvent, advertiseIfAuthoritative)
RegisterCallback(RaidRosterDeltaEvent, advertiseIfAuthoritative)
RegisterCallback(ZoneChangedNewAreaEvent, advertiseIfAuthoritative)
RegisterCallback(PartyLootMethodChangedEvent, advertiseIfAuthoritative)
