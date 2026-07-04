-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: local feature = addon.Database.GetFeatureShared()
-- exports: publish module APIs on addon.*
-- events: handles RMALogSync addon-message traffic; listens OptionsLoaded, ConfigpersistentSync, RaidCreate
local addon = select(2, ...)
local feature = addon.Database.GetFeatureShared()

local L = feature.L
local Diag = feature.Diag

local DB = feature.DB
local Events = feature.Events
local Database = feature.Database
local Options = feature.Options
local Bus = feature.Bus
local Strings = feature.Strings
local Timer = feature.Timer
local Comms = feature.Comms
local Services = feature.Services
local coreState = feature.coreState

local _G = _G
local tconcat = table.concat
local pairs, type, select = pairs, type, select
local strsub = string.sub
local tonumber, tostring = tonumber, tostring
local floor = math.floor
local format = string.format

local GetTime = _G.GetTime
local GetNumRaidMembers = _G.GetNumRaidMembers
local GetRaidRosterInfo = _G.GetRaidRosterInfo
local UnitIsGroupAssistant = feature.UnitIsGroupAssistant
local UnitIsGroupLeader = feature.UnitIsGroupLeader

local NormalizeName = Strings.NormalizeName
local NormalizeLower = Strings.NormalizeLower
local TrimText = Strings.TrimText

local InternalEvents = Events.Internal
local Payload = assert(Comms and Comms.Payload, "Comms payload helpers are not initialized")

-- Logger synchronization module.
do
    DB.Syncer = DB.Syncer or {}
    local module = DB.Syncer

    -- ----- Internal state ----- --
    local COMM_PREFIX = "RMALogSync"
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
    local MAX_DELTA_ROWS = 50
    local REQUEST_TTL_SECONDS = 30
    local INCOMING_TTL_SECONDS = 45
    local REQUEST_RATE_WINDOW_SECONDS = 30
    local REQUEST_RATE_MAX_PER_SENDER = 6
    local REQUEST_RATE_PRUNE_SECONDS = REQUEST_RATE_WINDOW_SECONDS * 2
    local OUTGOING_RATE_WINDOW_SECONDS = 30
    local OUTGOING_RATE_MAX_PER_TARGET = 4
    local OUTGOING_RATE_PRUNE_SECONDS = OUTGOING_RATE_WINDOW_SECONDS * 2
    local SYNC_OFFICER_LOOKUP_GRACE_SECONDS = 2
    local PASSIVE_CLEANUP_INTERVAL_SECONDS = 5
    local PERSISTENT_SYNC_INTERVAL_SECONDS = 120

    local loggerOptions = Options.AddNamespace("Logger", {
        persistentSync = false,
        ignoreGroupLoot = false,
        ignoreSelectionThreshold = true,
        loggerLootQualityThreshold = 4,
        syncRequirePlayer = "",
        syncPushPlayer = "",
    })

    module._incoming = module._incoming or {}
    module._pendingRequests = module._pendingRequests or {}
    module._requestRate = module._requestRate or {}
    module._outgoingRate = module._outgoingRate or {}
    module._outgoingCompressionByRequest = module._outgoingCompressionByRequest or {}
    module._nextRequestId = tonumber(module._nextRequestId) or 0
    module._nextPassiveCleanupAt = tonumber(module._nextPassiveCleanupAt) or 0
    module._persistentSyncHandle = module._persistentSyncHandle or nil
    module._persistentSyncCallbacksBound = module._persistentSyncCallbacksBound or false
    local chunkMessageBuffer = {}
    if Timer and Timer.BindMixin then
        Timer.BindMixin(module, "Database/DBSyncer")
    end

    -- ----- Private helpers ----- --
    local function clearChunkMessageBuffer()
        for key in pairs(chunkMessageBuffer) do
            chunkMessageBuffer[key] = nil
        end
    end

    local function nowSec()
        return (GetTime and GetTime()) or 0
    end

    local function parseNumber(value, fallback)
        local n = tonumber(value)
        if n == nil then
            return fallback
        end
        return n
    end

    local normalizeSender = Comms.NormalizeSender
        or function(sender)
            if type(sender) ~= "string" then
                return nil
            end
            local short = sender:match("^([^%-]+)") or sender
            return NormalizeName(short, true) or short
        end

    local function isSelfSender(sender)
        local selfName = Database.GetPlayerName()
        if not selfName then
            return false
        end
        local a = NormalizeLower(selfName, true)
        local b = NormalizeLower(normalizeSender(sender), true)
        return (a ~= nil and b ~= nil and a == b)
    end

    local isDebugEnabled = Options.IsDebugEnabled or function()
        return false
    end

    local Metrics = assert(module._Metrics, "DBSync metrics helpers are not initialized")
    local SnapshotPayload = assert(module._Payload, "DBSync payload helpers are not initialized")
    local SnapshotImport = assert(module._Import, "DBSync import helpers are not initialized")

    local function cleanupExpiredState()
        local now = nowSec()

        for key, st in pairs(module._incoming) do
            local age = now - (tonumber(st and st.createdAt) or now)
            if age > INCOMING_TTL_SECONDS then
                module._incoming[key] = nil
            end
        end

        for reqId, st in pairs(module._pendingRequests) do
            local age = now - (tonumber(st and st.createdAt) or now)
            if age > REQUEST_TTL_SECONDS then
                module._pendingRequests[reqId] = nil
            end
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
                addon:warn((Diag.W.LogSyncRequestRateLimited):format(tostring(sender), rate.count, REQUEST_RATE_WINDOW_SECONDS))
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
                addon:warn((Diag.W.LogSyncRequestRateLimited):format(tostring(key), rate.count, OUTGOING_RATE_WINDOW_SECONDS))
                rate.warned = true
            end
            return false, key
        end

        return true, key
    end

    local function canAnswerRequests(channel)
        if not addon.IsInGroup() then
            return false
        end
        if channel == "WHISPER" then
            return true
        end
        if not addon.IsInRaid() then
            return true
        end
        local raidService = Services and Services.Raid or nil
        if raidService and type(raidService.CanUseCapability) == "function" then
            return raidService:CanUseCapability("raid_leadership")
        end

        local isLeader = UnitIsGroupLeader and UnitIsGroupLeader("player")
        local isAssistant = UnitIsGroupAssistant and UnitIsGroupAssistant("player")
        return (isLeader or isAssistant) and true or false
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

    local function trackPendingRequest(syncer, requestId, pendingState)
        syncer._pendingRequests[requestId] = pendingState
    end

    local function sendAddonPayload(target, payload)
        if target and target ~= "" then
            Comms.QueueAddonMessage(COMM_PREFIX, payload, "WHISPER", target)
            return
        end

        Comms.Sync(COMM_PREFIX, payload)
    end

    local function buildIncomingSnapshotKey(sender, requestId, mode, raidNid)
        return format(
            "%s|%s|%s|%s",
            tostring(sender),
            tostring(requestId),
            tostring(mode),
            tostring(raidNid)
        )
    end

    local function shouldCompressOutgoingPayload(requestId)
        return module._outgoingCompressionByRequest[tostring(requestId or "")] == true
    end

    local function setOutgoingCompressionSupport(requestId, supportsCompression)
        local key = tostring(requestId or "")
        if key == "" then
            return
        end
        if supportsCompression == true then
            module._outgoingCompressionByRequest[key] = true
        else
            module._outgoingCompressionByRequest[key] = nil
        end
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
        sendAddonPayload(target, payload)
        Metrics.RecordOutgoingRequest(mode, #payload)
        if isDebugEnabled() then
            addon:debug((Diag.D.LogSyncRequestSent):format(tostring(requestId), tostring(raidRef)))
        end
    end

    local function sendChunkedPayload(kind, target, requestId, mode, raidNid, payload)
        local encodedPayload = SnapshotPayload.EncodeTransportText(payload, { compress = shouldCompressOutgoingPayload(requestId) })
        local payloadLen = #encodedPayload
        local totalChunks = floor((payloadLen + MAX_CHUNK_SIZE - 1) / MAX_CHUNK_SIZE)
        if totalChunks < 1 then
            totalChunks = 1
        end

        clearChunkMessageBuffer()
        chunkMessageBuffer[1] = kind
        chunkMessageBuffer[2] = PROTOCOL_VERSION
        chunkMessageBuffer[3] = requestId
        chunkMessageBuffer[4] = mode
        chunkMessageBuffer[5] = tonumber(raidNid) or 0
        chunkMessageBuffer[7] = totalChunks

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
            sendAddonPayload(target, msg)
        end

        clearChunkMessageBuffer()
        Metrics.RecordOutgoingSnapshot(mode, payloadLen, totalChunks)
        setOutgoingCompressionSupport(requestId, false)
        return true, totalChunks, payloadLen
    end

    local function sendDelta(target, requestId, mode, raid, sinceRevision)
        local payload, deltaRows = SnapshotPayload.BuildDelta(raid, sinceRevision)
        if not payload or (tonumber(deltaRows) or 0) > MAX_DELTA_ROWS then
            return false
        end

        return sendChunkedPayload(MSG_DELTA, target, requestId, mode, raid.raidNid, payload)
    end

    local function sendSnapshot(target, requestId, mode, raid)
        local payload = SnapshotPayload.Build(raid)
        if not payload then
            return
        end

        local ok, totalChunks, payloadLen = sendChunkedPayload(MSG_SNAPSHOT, target, requestId, mode, raid.raidNid, payload)
        if not ok then
            return
        end

        if isDebugEnabled() then
            addon:debug((Diag.D.LogSyncSnapshotSent):format(tostring(target or "GROUP"), tostring(requestId), tostring(raid.raidNid), totalChunks, payloadLen))
        end
    end

    local function completeRequest(requestId)
        local pending = module._pendingRequests[requestId]
        if not pending then
            return
        end
        pending.completed = true
        module._pendingRequests[requestId] = nil
    end

    local function shouldAcceptResponseSender(pending, rawSender)
        if type(pending) ~= "table" then
            return false
        end

        local sender = normalizeSender(rawSender) or tostring(rawSender or "")
        if sender == "" then
            return false
        end

        local expectedTarget = normalizeSender(pending.target)
        if expectedTarget and expectedTarget ~= "" then
            if sender ~= expectedTarget then
                return false
            end
            pending.sender = expectedTarget
            return true
        end

        local expectedSender = normalizeSender(pending.sender)
        if expectedSender and expectedSender ~= "" then
            return sender == expectedSender
        end

        pending.sender = sender
        return true
    end

    local function getSenderKey(rawSender)
        local sender = normalizeSender(rawSender) or tostring(rawSender or "")
        if sender == "" then
            return nil
        end
        return sender
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
            addon:debug((Diag.D.LogSyncSyncSenderFailed):format(tostring(sender), tostring(requestId), tostring(reason)))
        end
    end

    local function finalizeSnapshotFailure(isSync, pending, sender, requestId, reason)
        if isSync then
            rejectSyncSender(pending, sender, requestId, reason)
            return
        end
        completeRequest(requestId)
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

    local function isAuthorizedSyncResponder(rawSender, pending)
        if not addon.IsInRaid() then
            return true
        end
        local sender = getSenderKey(rawSender)
        if not sender then
            return false
        end

        local count = tonumber(GetNumRaidMembers and GetNumRaidMembers()) or 0
        for i = 1, count do
            local name, rank = GetRaidRosterInfo(i)
            local rosterName = getSenderKey(name)
            if rosterName and rosterName == sender then
                return (tonumber(rank) or 0) > 0
            end
        end

        local createdAt = tonumber(type(pending) == "table" and pending.createdAt) or 0
        if createdAt > 0 and (nowSec() - createdAt) <= SYNC_OFFICER_LOOKUP_GRACE_SECONDS then
            return true
        end
        return false
    end

    local function warnSyncSenderNotOfficer(pending, requestId, rawSender)
        if type(pending) ~= "table" then
            return
        end
        local sender = getSenderKey(rawSender) or tostring(rawSender or "?")
        pending.unauthorizedSenders = pending.unauthorizedSenders or {}
        if pending.unauthorizedSenders[sender] then
            return
        end
        pending.unauthorizedSenders[sender] = true
        addon:warn((Diag.W.LogSyncSenderNotOfficer):format(tostring(sender), tostring(requestId)))
    end

    local function isSyncSenderUnauthorized(pending, rawSender)
        if type(pending) ~= "table" then
            return false
        end
        local sender = getSenderKey(rawSender)
        if not sender then
            return false
        end
        local unauthorizedSenders = pending.unauthorizedSenders
        return type(unauthorizedSenders) == "table" and unauthorizedSenders[sender] == true
    end

    local function handleIncomingRequest(rawSender, channel, requestId, mode, raidRef, signature)
        if not canAnswerRequests(channel) then
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
            addon:debug((Diag.D.LogSyncRequestReceived):format(tostring(sender), tostring(requestId), tostring(raidRef)))
        end
        local sinceRevision = tonumber(signature and signature.sinceRevision) or 0
        setOutgoingCompressionSupport(requestId, signature and signature.supportsCompression == true)
        if mode == MODE_SYNC and sinceRevision > 0 and sendDelta(rawSender, requestId, mode, raid, sinceRevision) then
            return
        end
        sendSnapshot(rawSender, requestId, mode, raid)
    end

    local function refreshLoggerUi(focusRaidId)
        local selectedRaid = tonumber(focusRaidId) or tonumber(coreState and coreState.selectedRaid) or tonumber(Database.GetCurrentRaid())
        Bus.TriggerEvent(InternalEvents.LoggerSelectRaid, selectedRaid, "sync")
    end

    local function onSnapshotReady(sender, requestId, mode, snapshot)
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

            local ok, raid = pcall(SnapshotImport.ApplySnapshotToRaid, currentRaid, snapshot, false)
            if not ok then
                addon:error((Diag.E.LogSyncMergeFailed):format(tostring(sender), tostring(requestId), tostring(snapshot.header.raidNid), tostring(raid)))
                rejectSyncSender(pending, sender, requestId, "merge_failed")
                return
            end
            if not raid then
                addon:error((Diag.E.LogSyncMergeFailed):format(tostring(sender), tostring(requestId), tostring(snapshot.header.raidNid), "nil_result"))
                rejectSyncSender(pending, sender, requestId, "merge_failed")
                return
            end

            addon:info(L.MsgLoggerSyncApplied:format(tonumber(currentId) or 0, tostring(sender)))
            if isDebugEnabled() then
                addon:debug(
                    (Diag.D.LogSyncMergeApplied):format(tonumber(raid.raidNid) or 0, tonumber(currentId) or 0, tostring(sender), #(raid.bossKills or {}), #(raid.loot or {}))
                )
            end

            cleanupIncomingByRequest(requestId, MODE_SYNC)
            completeRequest(requestId)
            refreshLoggerUi(currentId)
            return
        end

        local ok, raid, raidId = pcall(SnapshotImport.ImportSnapshotAsNewRaid, snapshot)
        if not ok then
            addon:error((Diag.E.LogSyncMergeFailed):format(tostring(sender), tostring(requestId), tostring(snapshot.header.raidNid), tostring(raid)))
            completeRequest(requestId)
            return
        end
        if not raid then
            addon:error((Diag.E.LogSyncMergeFailed):format(tostring(sender), tostring(requestId), tostring(snapshot.header.raidNid), "nil_result"))
            completeRequest(requestId)
            return
        end

        if mode == MODE_PUSH then
            addon:info(L.MsgLoggerPushImported:format(tostring(sender), tonumber(raidId) or 0))
        else
            addon:info(L.MsgLoggerReqImported:format(tostring(sender), tonumber(raidId) or 0))
            completeRequest(requestId)
        end

        if isDebugEnabled() then
            addon:debug((Diag.D.LogSyncMergeApplied):format(tonumber(raid.raidNid) or 0, tonumber(raidId) or 0, tostring(sender), #(raid.bossKills or {}), #(raid.loot or {})))
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

        local ok, raid = pcall(SnapshotImport.ApplyDeltaToRaid, currentRaid, delta)
        if not ok then
            addon:error((Diag.E.LogSyncMergeFailed):format(tostring(sender), tostring(requestId), tostring(delta.header.raidNid), tostring(raid)))
            rejectSyncSender(pending, sender, requestId, "merge_failed")
            return
        end
        if not raid then
            addon:error((Diag.E.LogSyncMergeFailed):format(tostring(sender), tostring(requestId), tostring(delta.header.raidNid), "nil_result"))
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

        if not pending or pending.completed or pending.mode ~= mode then
            if isDebugEnabled() then
                addon:debug((Diag.D.LogSyncChunkIgnored):format(tostring(sender), tostring(requestId), tostring(raidNid)))
            end
            return true
        end

        if isSync and isSyncSenderFailed(pending, sender) then
            if isDebugEnabled() then
                addon:debug((Diag.D.LogSyncChunkIgnored):format(tostring(sender), tostring(requestId), tostring(raidNid)))
            end
            return true
        end

        local expectedTarget = normalizeSender(pending.target)
        if expectedTarget and expectedTarget ~= "" and not shouldAcceptResponseSender(pending, sender) then
            if isDebugEnabled() then
                addon:debug((Diag.D.LogSyncChunkIgnored):format(tostring(sender), tostring(requestId), tostring(raidNid)))
            end
            return true
        end

        return false
    end

    local function getOrCreateIncomingSnapshotState(sender, requestId, mode, raidNid, partCount, pending, isSync)
        local key = buildIncomingSnapshotKey(sender, requestId, mode, raidNid)
        local state = module._incoming[key]
        if state then
            return key, state
        end

        if isSync and isSyncSenderUnauthorized(pending, sender) then
            if isDebugEnabled() then
                addon:debug((Diag.D.LogSyncChunkIgnored):format(tostring(sender), tostring(requestId), tostring(raidNid)))
            end
            return key, nil
        end
        if isSync and not isAuthorizedSyncResponder(sender, pending) then
            warnSyncSenderNotOfficer(pending, requestId, sender)
            if isDebugEnabled() then
                addon:debug((Diag.D.LogSyncChunkIgnored):format(tostring(sender), tostring(requestId), tostring(raidNid)))
            end
            return key, nil
        end

        state = {
            createdAt = nowSec(),
            sender = sender,
            requestId = requestId,
            mode = mode,
            raidNid = raidNid,
            total = partCount,
            got = 0,
            parts = {},
        }
        module._incoming[key] = state
        return key, state
    end

    local function handleIncomingSnapshot(sender, requestId, mode, raidNid, partIndex, partCount, chunkData)
        local pending = module._pendingRequests[requestId]
        local isPush = (mode == MODE_PUSH)
        local isSync = (mode == MODE_SYNC)

        if shouldIgnoreSnapshotSender(sender, requestId, mode, raidNid, pending, isPush, isSync) then
            return
        end

        if partIndex < 1 or partCount < 1 or partIndex > partCount then
            addon:warn((Diag.W.LogSyncChunkMalformed):format(tostring(sender), tostring(requestId), tostring(partIndex), tostring(partCount)))
            return
        end

        local key, state = getOrCreateIncomingSnapshotState(sender, requestId, mode, raidNid, partCount, pending, isSync)
        if not state then
            return
        end

        if state.total ~= partCount then
            addon:warn((Diag.W.LogSyncChunkPartCountChanged):format(tostring(sender), tostring(requestId), tostring(raidNid), tonumber(state.total) or 0, tonumber(partCount) or 0))
            state.total = partCount
            state.got = 0
            state.parts = {}
            state.createdAt = nowSec()
        end

        if state.parts[partIndex] == nil then
            state.parts[partIndex] = chunkData or ""
            state.got = state.got + 1
            Metrics.RecordIncomingSnapshotChunk(mode, #(chunkData or ""))
        end

        if isDebugEnabled() then
            addon:debug((Diag.D.LogSyncChunkReceived):format(tostring(sender), tostring(requestId), partIndex, partCount))
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
            finalizeSnapshotFailure(isSync, pending, sender, requestId, "decode_failed")
            return
        end

        local snapshot = SnapshotPayload.Parse(payload)
        if not snapshot then
            addon:warn((Diag.W.LogSyncParseFailed):format(tostring(sender), tostring(requestId), tostring(raidNid)))
            finalizeSnapshotFailure(isSync, pending, sender, requestId, "parse_failed")
            return
        end

        local snapshotVersion = tonumber(snapshot.header.protocolVersion)
        if snapshotVersion ~= PROTOCOL_VERSION and snapshotVersion ~= LEGACY_PROTOCOL_VERSION then
            if isDebugEnabled() then
                addon:debug((Diag.D.LogSyncVersionMismatch):format(tostring(sender), tostring(snapshot.header.protocolVersion), PROTOCOL_VERSION))
            end
            finalizeSnapshotFailure(isSync, pending, sender, requestId, "version_mismatch")
            return
        end

        onSnapshotReady(sender, requestId, mode, snapshot)
    end

    local function handleIncomingDelta(sender, requestId, mode, raidNid, partIndex, partCount, chunkData)
        local pending = module._pendingRequests[requestId]
        local isSync = (mode == MODE_SYNC)

        if mode ~= MODE_SYNC or shouldIgnoreSnapshotSender(sender, requestId, mode, raidNid, pending, false, isSync) then
            return
        end

        if partIndex < 1 or partCount < 1 or partIndex > partCount then
            addon:warn((Diag.W.LogSyncChunkMalformed):format(tostring(sender), tostring(requestId), tostring(partIndex), tostring(partCount)))
            return
        end

        local key, state = getOrCreateIncomingSnapshotState(sender, requestId, mode, raidNid, partCount, pending, isSync)
        if not state then
            return
        end

        if state.total ~= partCount then
            addon:warn((Diag.W.LogSyncChunkPartCountChanged):format(tostring(sender), tostring(requestId), tostring(raidNid), tonumber(state.total) or 0, tonumber(partCount) or 0))
            state.total = partCount
            state.got = 0
            state.parts = {}
            state.createdAt = nowSec()
        end

        if state.parts[partIndex] == nil then
            state.parts[partIndex] = chunkData or ""
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
            finalizeSnapshotFailure(isSync, pending, sender, requestId, "decode_failed")
            return
        end

        local delta = SnapshotPayload.ParseDelta(payload)
        if not delta then
            addon:warn((Diag.W.LogSyncParseFailed):format(tostring(sender), tostring(requestId), tostring(raidNid)))
            finalizeSnapshotFailure(isSync, pending, sender, requestId, "parse_failed")
            return
        end

        if tonumber(delta.header.protocolVersion) ~= PROTOCOL_VERSION then
            if isDebugEnabled() then
                addon:debug((Diag.D.LogSyncVersionMismatch):format(tostring(sender), tostring(delta.header.protocolVersion), PROTOCOL_VERSION))
            end
            finalizeSnapshotFailure(isSync, pending, sender, requestId, "version_mismatch")
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

        local target = resolveExternalTarget(targetName)
        if not target then
            return false
        end

        local allowed = allowOutgoingRequest(target, MODE_REQ)
        if not allowed then
            return false, "rate_limited"
        end

        local requestId = nextRequestId(self)

        trackPendingRequest(self, requestId, {
            createdAt = nowSec(),
            mode = MODE_REQ,
            raidRef = requestRef,
            target = target,
            sender = target,
            completed = false,
        })

        sendRequest(MODE_REQ, requestId, requestRef, { supportsCompression = true }, target)
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

        local target = resolveExternalTarget(targetName)
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

        local requestId = nextRequestId(self)

        sendSnapshot(target, requestId, MODE_PUSH, raid)
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
        local raidStore = Database.GetRaidStoreOrNil("DBSyncer.RequestLoggerSync", { "GetRaidSyncRevision" })
        signature.sinceRevision = raidStore and raidStore:GetRaidSyncRevision(currentRaid) or 0
        signature.supportsCompression = true
        local requestId = nextRequestId(syncer)

        trackPendingRequest(syncer, requestId, {
            createdAt = nowSec(),
            mode = MODE_SYNC,
            signature = signature,
            sender = nil,
            failedSenders = {},
            unauthorizedSenders = {},
            completed = false,
        })

        sendRequest(MODE_SYNC, requestId, tonumber(currentRaid.raidNid) or 0, signature)
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
        if module._persistentSyncHandle and module.CancelTimer then
            module:CancelTimer(module._persistentSyncHandle)
        end
        module._persistentSyncHandle = nil
    end

    local function schedulePersistentSync(delay)
        if not isPersistentSyncEnabled() then
            stopPersistentSync()
            return false
        end
        if module._persistentSyncHandle or not module.ScheduleTimer then
            return module._persistentSyncHandle ~= nil
        end

        module._persistentSyncHandle = module:ScheduleTimer(function()
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
        if module._persistentSyncCallbacksBound or not (Bus and Bus.RegisterCallback) then
            return
        end

        Bus.RegisterCallback(InternalEvents.OptionsLoaded, function()
            module:RefreshPersistentSync(5)
        end)
        local persistentSyncEvent = (Events.GetConfigOptionChanged and Events.GetConfigOptionChanged("persistentSync")) or "ConfigpersistentSync"
        Bus.RegisterCallback(persistentSyncEvent, function()
            stopPersistentSync()
            if isPersistentSyncEnabled() then
                module:RequestLoggerPersistentSync()
                module:RefreshPersistentSync(PERSISTENT_SYNC_INTERVAL_SECONDS)
            end
        end)
        Bus.RegisterCallback(InternalEvents.RaidCreate, function()
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
                addon:debug((Diag.D.LogSyncVersionMismatch):format(tostring(sender), tostring(version), PROTOCOL_VERSION))
            end
            return
        end

        local requestId = tostring(fields[3] or "")
        if requestId == "" then
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

            local senderName = normalizeSender(sender) or tostring(sender)
            handleIncomingSnapshot(senderName, requestId, mode, raidNid, partIndex, partCount, chunkData)
            return
        end

        if kind == MSG_DELTA and version == PROTOCOL_VERSION and n >= 8 then
            local mode = tostring(fields[4] or "")
            if mode ~= MODE_SYNC then
                return
            end

            local raidNid = parseNumber(fields[5], nil)
            local partIndex = parseNumber(fields[6], 0)
            local partCount = parseNumber(fields[7], 0)
            local chunkData = fields[8] or ""
            if not raidNid then
                return
            end

            local senderName = normalizeSender(sender) or tostring(sender)
            handleIncomingDelta(senderName, requestId, mode, raidNid, partIndex, partCount, chunkData)
        end
    end
end

local registry = feature.ModuleRegistry
if type(registry) == "table" and type(registry.AddModule) == "function" and type(registry.SetLoaded) == "function" then
    registry.AddModule("Database/DBSyncer", {
        deps = {
            "Init",
            "Modules/ModuleRegistry",
            "Database/DB",
            "Database/DBSyncMetrics",
            "Database/DBSyncPayload",
            "Database/DBSyncImport",
            "Database/DBRaidStore",
            "Modules/Events",
            "Modules/Bus",
            "Modules/Timer",
            "Modules/Strings",
            "Modules/Comms",
        },
    })
    registry.SetLoaded("Database/DBSyncer")
end

