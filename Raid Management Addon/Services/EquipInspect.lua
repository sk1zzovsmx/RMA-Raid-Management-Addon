--- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: direct addon namespace bindings
-- exports: addon.Services.EquipInspect
-- events: listens wow.INSPECT_TALENT_READY and wow.GET_ITEM_INFO_RECEIVED; emits EquipInspectStarted/EquipInspectUpdated/EquipInspectCompleted

local addon = select(2, ...)
local Diag = addon.Diag
local Database = addon.Database
local Services = addon.Services
local Events = addon.Events
local Bus = addon.Bus
local Timer = addon.Timer
local Time = addon.Time
local Strings = addon.Strings
local InspectCoordinator = assert(Services.InspectCoordinator, Diag.A.EquipInspectCoordinatorNotInitialized)

local InternalEvents = assert(Events.Internal, Diag.A.EquipInspectInternalEventsNotInitialized)
local TriggerEvent = assert(Bus.TriggerEvent, Diag.A.EquipInspectEventPublisherNotInitialized)
local RegisterCallback = assert(Bus.RegisterCallback, Diag.A.EquipInspectEventBusListenerNotInitialized)
local ResolveWowForwardedName =
	assert(Events.ResolveWowForwardedName, Diag.A.EquipInspectForwardedEventResolverNotInitialized)
local EquipInspectStartedEvent =
	assert(InternalEvents.EquipInspectStarted, Diag.A.EquipInspectStartedEventNotInitialized)
local EquipInspectCompletedEvent =
	assert(InternalEvents.EquipInspectCompleted, Diag.A.EquipInspectCompletedEventNotInitialized)
local EquipInspectUpdatedEvent =
	assert(InternalEvents.EquipInspectUpdated, Diag.A.EquipInspectUpdateEventNotInitialized)
local RaidCreateEvent = assert(InternalEvents.RaidCreate, Diag.A.EquipInspectRaidCreateEventNotInitialized)

local GetTime = assert(_G.GetTime, Diag.A.EquipInspectTimeApiNotInitialized)
local UnitGUID = assert(_G.UnitGUID, Diag.A.EquipInspectUnitGuidApiNotInitialized)
local UnitExists = assert(_G.UnitExists, Diag.A.EquipInspectUnitExistenceApiNotInitialized)
local UnitIsConnected = assert(_G.UnitIsConnected, Diag.A.EquipInspectUnitConnectionApiNotInitialized)
local CanInspect = assert(_G.CanInspect, Diag.A.EquipInspectInspectCapabilityApiNotInitialized)
local CheckInteractDistance = assert(_G.CheckInteractDistance, Diag.A.EquipInspectUnitRangeApiNotInitialized)
local NotifyInspect = assert(_G.NotifyInspect, Diag.A.EquipInspectNotifyInspectApiNotInitialized)
local GetInventoryItemLink = assert(_G.GetInventoryItemLink, Diag.A.EquipInspectInventoryItemLinkApiNotInitialized)
local GetInventoryItemTexture =
	assert(_G.GetInventoryItemTexture, Diag.A.EquipInspectInventoryItemTextureApiNotInitialized)
local GetInventoryItemQuality =
	assert(_G.GetInventoryItemQuality, Diag.A.EquipInspectInventoryItemQualityApiNotInitialized)
local GetItemInfo = assert(_G.GetItemInfo, Diag.A.EquipInspectItemInfoApiNotInitialized)

local type, tonumber, tostring = type, tonumber, tostring
local pairs, ipairs = pairs, ipairs
local floor = math.floor
local tinsert = table.insert
local tremove = table.remove

local ITEM_INFO_RETRY_SECONDS = 0.5
local RAID_CREATE_DELAY_SECONDS = 3.0
local SLOT_ORDER = { 1, 2, 3, 15, 5, 9, 10, 6, 7, 8, 11, 12, 13, 14, 16, 17, 18 }

-- ----- Internal state ----- --

addon.Services.EnsureNamespace("EquipInspect")
local module = Services.EquipInspect
Timer.BindMixin(module, "EquipInspect")

local queueByRaid = {}
local queuedByPlayer = {}
local runtimeStatusByRaid = {}
local activeRequestByRaid = {}
local sessionBusyByRaid = {}
local globalInspectRequest
local finalizeRequest
local terminalizeQueuedTimerWork

-- ----- Private helpers ----- --

local function now()
	return tonumber(GetTime()) or 0
end

local function epochNow()
	return tonumber(Time.GetCurrentTime()) or 0
end

local function normalizeRaidIndex(raidOrId)
	if type(raidOrId) == "table" then
		local raidIndex = tonumber(raidOrId.id) or tonumber(raidOrId.raidId) or tonumber(raidOrId.raidNum)
		if raidIndex then
			return raidIndex
		end

		local raidNid = tonumber(raidOrId.raidNid)
		if raidNid and type(Database.GetRaidIndexByNid) == "function" then
			return Database.GetRaidIndexByNid(raidNid)
		end
		return nil
	end
	return tonumber(raidOrId)
end

local function normalizePlayerNid(value)
	local n = tonumber(value) or 0
	if n <= 0 then
		return 0
	end
	return n
end

local function normalizeReason(value)
	if type(value) == "string" and value ~= "" then
		return value
	end
	return nil
end

local function ensureRuntime(raidNid)
	if not queueByRaid[raidNid] then
		queueByRaid[raidNid] = {}
	end
	if not queuedByPlayer[raidNid] then
		queuedByPlayer[raidNid] = {}
	end
	if not runtimeStatusByRaid[raidNid] then
		runtimeStatusByRaid[raidNid] = {}
	end
	return queueByRaid[raidNid], queuedByPlayer[raidNid], runtimeStatusByRaid[raidNid]
end

local function resolveRaidNid(raidOrId)
	if type(raidOrId) == "table" then
		local raidNid = tonumber(raidOrId.raidNid)
		if raidNid and raidNid > 0 then
			return raidNid
		end
	end
	local rid = normalizeRaidIndex(raidOrId)
	if not rid then
		return nil
	end
	local raid = Database.EnsureRaidByIndex(rid)
	local raidNid = tonumber(raid and raid.raidNid)
	return raidNid and raidNid > 0 and raidNid or nil
end

local function getRaid(raidNid)
	local nid = tonumber(raidNid)
	if not nid or nid <= 0 or type(Database.EnsureRaidByNid) ~= "function" then
		return nil
	end
	return Database.EnsureRaidByNid(nid)
end

local function isCurrentRaid(raidNid)
	local currentRaid = Database.EnsureRaidByIndex(normalizeRaidIndex(Database.GetCurrentRaid()))
	return tonumber(currentRaid and currentRaid.raidNid) == tonumber(raidNid)
end

local function emitStarted(raidNid, reason)
	if sessionBusyByRaid[raidNid] then
		return
	end
	sessionBusyByRaid[raidNid] = true
	TriggerEvent(EquipInspectStartedEvent, raidNid, reason or "start")
end

local function emitCompleted(raidNid)
	sessionBusyByRaid[raidNid] = false
	TriggerEvent(EquipInspectCompletedEvent, raidNid)
end

local function emitUpdated(raidNid, playerNid, snapshot)
	TriggerEvent(EquipInspectUpdatedEvent, raidNid, playerNid, snapshot)
end

local function setRuntimeStatus(raidId, playerNid, status, reason)
	local _, _, runtime = ensureRuntime(raidId)
	local key = normalizePlayerNid(playerNid)
	if key <= 0 then
		return
	end

	runtime[key] = {
		status = status,
		reason = normalizeReason(reason),
		updatedAt = now(),
	}
	if status == "queued" or status == "pending" then
		emitUpdated(raidId, key, runtime[key])
	end
end

local function clearRuntime(raidId, playerNid)
	local runtime = runtimeStatusByRaid[raidId]
	if runtime then
		runtime[normalizePlayerNid(playerNid)] = nil
	end
end

local function copyIfString(value)
	if type(value) == "string" then
		return value
	end
	return nil
end

local function compactPersistedInspectSnapshot(snapshot)
	if type(snapshot) ~= "table" then
		return nil
	end

	local avgIlvl = tonumber(snapshot.avgIlvl)
	if avgIlvl then
		avgIlvl = floor(avgIlvl)
	end

	local compact = {
		playerNid = tonumber(snapshot.playerNid) or nil,
		name = copyIfString(snapshot.name),
		guid = copyIfString(snapshot.guid),
		class = copyIfString(snapshot.class),
		status = copyIfString(snapshot.status),
		reason = copyIfString(snapshot.reason),
		inspectedAt = tonumber(snapshot.inspectedAt) or nil,
		avgIlvl = avgIlvl,
		specName = copyIfString(snapshot.specName),
		specIcon = copyIfString(snapshot.specIcon),
		mainTalentTree = tonumber(snapshot.mainTalentTree) or nil,
		secondarySpecName = copyIfString(snapshot.secondarySpecName),
		secondarySpecIcon = copyIfString(snapshot.secondarySpecIcon),
		activeTalentGroup = tonumber(snapshot.activeTalentGroup) or nil,
		numTalentGroups = tonumber(snapshot.numTalentGroups) or nil,
		secondaryTalentGroup = tonumber(snapshot.secondaryTalentGroup) or nil,
		secondaryMainTalentTree = tonumber(snapshot.secondaryMainTalentTree) or nil,
	}

	local out = {}
	for key, value in pairs(compact) do
		if value ~= nil then
			out[key] = value
		end
	end
	if next(out) then
		return out
	end
	return nil
end

local function parseItemLink(link)
	if type(link) ~= "string" then
		return nil
	end

	local payload = link:match("|Hitem:([^|]+)|h")
	if not payload then
		return nil
	end

	local parts = {}
	local token = ""
	for i = 1, #payload do
		local ch = payload:sub(i, i)
		if ch == ":" then
			parts[#parts + 1] = token
			token = ""
		else
			token = token .. ch
		end
	end
	parts[#parts + 1] = token

	return {
		itemId = tonumber(parts[1]) or 0,
		enchantId = tonumber(parts[2]) or 0,
		gems = {
			tonumber(parts[3]) or 0,
			tonumber(parts[4]) or 0,
			tonumber(parts[5]) or 0,
			tonumber(parts[6]) or 0,
		},
	}
end

local function getItemIlvl(itemId, link)
	if type(itemId) == "number" and itemId > 0 then
		local itemName, _, _, itemIlvl = GetItemInfo(itemId)
		if itemName ~= nil then
			return tonumber(itemIlvl) or 0, true
		end
	end
	if link then
		local itemName, _, _, itemIlvl = GetItemInfo(link)
		if itemName ~= nil then
			return tonumber(itemIlvl) or 0, true
		end
	end
	return 0, false
end

local function collectItems(unit)
	local items = {}
	local total = 0
	local count = 0
	local unresolvedByItem = {}
	local unresolvedSlots = {}

	for i = 1, #SLOT_ORDER do
		local slot = SLOT_ORDER[i]
		local link = GetInventoryItemLink(unit, slot)
		local data = parseItemLink(link) or {}
		local itemId = tonumber(data.itemId) or 0
		data.slot = slot
		data.itemLink = link
		data.texture = GetInventoryItemTexture(unit, slot)
		data.quality = tonumber(GetInventoryItemQuality(unit, slot)) or 0
		local resolved
		data.ilvl, resolved = getItemIlvl(itemId, link)

		if (link or data.texture) and not resolved then
			unresolvedSlots[slot] = true
			if itemId > 0 then
				unresolvedByItem[itemId] = true
			end
		elseif data.ilvl > 0 then
			total = total + data.ilvl
			count = count + 1
		end
		items[slot] = data
	end

	return items, (count > 0 and (total / count) or 0), unresolvedByItem, unresolvedSlots
end

local function getSpecInspectSnapshot(unit, player)
	local specInspect = Services.SpecInspect
	if type(specInspect) ~= "table" or type(specInspect.GetUnitTalentSnapshot) ~= "function" then
		return nil
	end

	local playerName = player and player.name or unit
	return specInspect:GetUnitTalentSnapshot(unit, playerName, "equip_inspect", true)
end

local function copySpecSnapshotFields(snapshot, talentSnapshot)
	if type(snapshot) ~= "table" or type(talentSnapshot) ~= "table" then
		return
	end

	snapshot.talentSnapshot = talentSnapshot
	snapshot.specName = talentSnapshot.specName
	snapshot.specIcon = talentSnapshot.icon
	snapshot.mainTalentTree = talentSnapshot.mainTalentTree
	snapshot.activeTalentGroup = talentSnapshot.activeGroup
	snapshot.numTalentGroups = talentSnapshot.numGroups
	snapshot.secondarySpecName = talentSnapshot.secondarySpecName
	snapshot.secondarySpecIcon = talentSnapshot.secondaryIcon
	snapshot.secondaryTalentGroup = talentSnapshot.secondaryGroup
	snapshot.secondaryMainTalentTree = talentSnapshot.secondaryMainTalentTree
end

local function buildReadyDetails(unit, player)
	local items, avgIlvl, unresolvedByItem, unresolvedSlots = collectItems(unit)
	local talentSnapshot = getSpecInspectSnapshot(unit, player)
	return {
		items = items,
		avgIlvl = avgIlvl,
		talentSnapshot = talentSnapshot,
		unresolvedByItem = unresolvedByItem,
		unresolvedSlots = unresolvedSlots,
	}
end

local function persistReadySnapshot(raid, playerNid, snapshot)
	local compact = compactPersistedInspectSnapshot(snapshot)
	if not compact then
		return nil
	end
	local store = type(Database.GetRaidStore) == "function" and Database.GetRaidStore() or nil
	if not store or type(store.CommitRaidInspectSnapshot) ~= "function" then
		return nil
	end
	return store:CommitRaidInspectSnapshot(raid, playerNid, compact)
end

local function getPlayerByNid(raid, playerNid)
	local players = raid and raid.players or nil
	if type(players) ~= "table" then
		return nil
	end
	for i = 1, #players do
		local player = players[i]
		if tonumber(player.playerNid) == tonumber(playerNid) then
			return player
		end
	end
	return nil
end

local function resolveUnit(raidNid, player)
	local roster = Services["Raid/Roster"] or Services.Raid
	if type(roster) ~= "table" then
		return nil
	end

	if type(roster.GetUnitByPlayerNid) == "function" then
		local raidIndex = Database.GetRaidIndexByNid(raidNid)
		local unit = raidIndex and roster:GetUnitByPlayerNid(raidIndex, player.playerNid) or nil
		if type(unit) == "string" and unit ~= "" then
			return unit
		end
	end
	if type(roster.GetPlayerUnit) == "function" then
		local unit = roster:GetPlayerUnit(player.playerNid)
		if type(unit) == "string" and unit ~= "" then
			return unit
		end
	end
	if type(roster.GetUnitID) == "function" and type(player.name) == "string" then
		local unit = roster:GetUnitID(player.name)
		if type(unit) == "string" and unit ~= "" and unit ~= "none" then
			return unit
		end
	end
	return nil
end

local function scheduleTimerSafely(callback, delay)
	local scheduled, handle = pcall(module.ScheduleTimer, module, callback, delay)
	if not scheduled or handle == nil then
		return nil
	end
	return handle
end

local function cancelOrphanedRaidWork(raidNid)
	local request = activeRequestByRaid[raidNid]
	if request and request.itemInfoRetryHandle then
		module:CancelTimer(request.itemInfoRetryHandle)
		request.itemInfoRetryHandle = nil
	end
	queueByRaid[raidNid] = nil
	queuedByPlayer[raidNid] = nil
	runtimeStatusByRaid[raidNid] = nil
	activeRequestByRaid[raidNid] = nil
	sessionBusyByRaid[raidNid] = nil
	if request and globalInspectRequest == request then
		globalInspectRequest = nil
	end
	if request and request.coordinatorOwner then
		InspectCoordinator:Cancel(request.coordinatorOwner)
	end
end

local tryFinalizeItemInfo

finalizeRequest = function(raidNid, playerNid, status, reason, unit, request)
	local raid = getRaid(raidNid)
	if not raid then
		cancelOrphanedRaidWork(raidNid)
		return nil
	end
	local currentRequest = activeRequestByRaid[raidNid]
	if currentRequest and currentRequest.itemInfoRetryHandle then
		module:CancelTimer(currentRequest.itemInfoRetryHandle)
		currentRequest.itemInfoRetryHandle = nil
	end

	local active = activeRequestByRaid[raidNid]
	if active then
		activeRequestByRaid[raidNid] = nil
	end

	local queue = queueByRaid[raidNid]
	if not queue then
		queue = {}
		queueByRaid[raidNid] = queue
	end
	if queuedByPlayer[raidNid] then
		queuedByPlayer[raidNid][playerNid] = nil
	end

	local snapshot
	local snapshotStatus = status
	if status == "ready" and unit then
		local player = getPlayerByNid(raid or {}, playerNid)
		local details = request and request.readyDetails or buildReadyDetails(unit, player)
		local resolvedGuid = UnitGUID(unit)
		snapshot = {
			status = status,
			reason = normalizeReason(reason),
			inspectedAt = epochNow(),
			playerNid = playerNid,
			avgIlvl = details.avgIlvl,
			guid = resolvedGuid,
			items = details.items,
		}
		copySpecSnapshotFields(snapshot, details.talentSnapshot)
		if player then
			snapshot.name = player.name
			snapshot.class = player.class
		end
	else
		snapshot = {
			status = status,
			reason = normalizeReason(reason),
			inspectedAt = now(),
			playerNid = playerNid,
		}
		if unit then
			snapshot.guid = UnitGUID(unit)
		end
	end

	if not snapshot.guid then
		local player = getPlayerByNid(raid or {}, playerNid)
		if player then
			snapshot.name = player.name
			snapshot.class = player.class
		end
	end

	if not snapshot.guid and request then
		local requestGuid = request.unitGUID
		if not requestGuid and request.unit then
			requestGuid = UnitGUID(request.unit)
		end
		snapshot.guid = requestGuid
	end

	if snapshotStatus == "ready" then
		local persisted = persistReadySnapshot(raid, playerNid, snapshot)
		if persisted ~= nil then
			local _, _, runtimeTable = ensureRuntime(raidNid)
			runtimeTable[playerNid] = snapshot
		else
			clearRuntime(raidNid, playerNid)
		end
		if persisted ~= true then
			snapshotStatus = "ready_noop"
		end
	else
		setRuntimeStatus(raidNid, playerNid, snapshotStatus, reason)
	end
	if
		snapshotStatus == "ready"
		or snapshotStatus == "skipped"
		or snapshotStatus == "timeout"
		or snapshotStatus == "failed"
	then
		emitUpdated(raidNid, playerNid, snapshot)
	end

	if #queue == 0 and not activeRequestByRaid[raidNid] then
		emitCompleted(raidNid)
	end

	if globalInspectRequest == request then
		globalInspectRequest = nil
	end
	if request and request.coordinatorOwner then
		InspectCoordinator:Release(request.coordinatorOwner, request.unitGUID)
	end
	module:ProcessQueue(raidNid)

	return snapshot
end

terminalizeQueuedTimerWork = function(onlyRaidNid, reason)
	local failures = {}
	local completedRaids = {}
	local coordinatorOwners = {}
	for raidNid, queue in pairs(queueByRaid) do
		if
			(not onlyRaidNid or tonumber(raidNid) == tonumber(onlyRaidNid))
			and type(queue) == "table"
			and #queue > 0
		then
			local seenPlayers = {}
			local active = activeRequestByRaid[raidNid]
			activeRequestByRaid[raidNid] = nil
			if active and active.coordinatorOwner then
				coordinatorOwners[#coordinatorOwners + 1] = active.coordinatorOwner
			end
			if active and active.playerNid then
				seenPlayers[normalizePlayerNid(active.playerNid)] = true
				failures[#failures + 1] = { raidNid = raidNid, request = active }
			end
			for i = 1, #queue do
				local request = queue[i]
				local playerNid = request and normalizePlayerNid(request.playerNid) or 0
				if playerNid > 0 and not seenPlayers[playerNid] then
					seenPlayers[playerNid] = true
					failures[#failures + 1] = { raidNid = raidNid, request = request }
				end
			end
			queueByRaid[raidNid] = {}
			queuedByPlayer[raidNid] = {}
			if sessionBusyByRaid[raidNid] then
				completedRaids[#completedRaids + 1] = raidNid
			end
			sessionBusyByRaid[raidNid] = false
		end
	end

	for i = 1, #failures do
		local failure = failures[i]
		local request = failure.request
		local _, _, runtime = ensureRuntime(failure.raidNid)
		runtime[normalizePlayerNid(request.playerNid)] = {
			status = "failed",
			reason = reason,
			updatedAt = now(),
		}
	end
	for i = 1, #coordinatorOwners do
		InspectCoordinator:Cancel(coordinatorOwners[i])
	end
	for i = 1, #failures do
		local failure = failures[i]
		local request = failure.request
		emitUpdated(failure.raidNid, request.playerNid, {
			status = "failed",
			reason = reason,
			inspectedAt = now(),
			playerNid = request.playerNid,
		})
	end
	for i = 1, #completedRaids do
		local raidNid = completedRaids[i]
		local queue = queueByRaid[raidNid]
		if not sessionBusyByRaid[raidNid] and not activeRequestByRaid[raidNid] and #(queue or {}) == 0 then
			TriggerEvent(EquipInspectCompletedEvent, raidNid)
		end
	end
end

tryFinalizeItemInfo = function(raidNid, request)
	if activeRequestByRaid[raidNid] ~= request or not request.inspectReady or not request.unit then
		return false
	end
	local raid = getRaid(raidNid)
	local player = getPlayerByNid(raid or {}, request.playerNid)
	local details = buildReadyDetails(request.unit, player)
	if not next(details.unresolvedSlots) then
		request.readyDetails = details
		finalizeRequest(raidNid, request.playerNid, "ready", nil, request.unit, request)
		return true
	end

	request.unresolvedByItem = details.unresolvedByItem
	request.unresolvedSlots = details.unresolvedSlots
	if not request.itemInfoRetryHandle then
		request.itemInfoRetryHandle = scheduleTimerSafely(function()
			request.itemInfoRetryHandle = nil
			tryFinalizeItemInfo(raidNid, request)
		end, ITEM_INFO_RETRY_SECONDS)
		if not request.itemInfoRetryHandle then
			finalizeRequest(raidNid, request.playerNid, "failed", "inspect_timer_failed", nil, request)
		end
	end
	return false
end

local function queuePlayer(raidNid, playerNid, reason, force)
	local queue, byPlayer, runtime = ensureRuntime(raidNid)
	local key = normalizePlayerNid(playerNid)
	if key <= 0 then
		return false, "missing_player"
	end

	local current = runtime[key]
	if not force and current and current.status == "ready" then
		return false, "ready"
	end
	if current and (current.status == "queued" or current.status == "pending") then
		return false, current.status
	end
	if not force and not current then
		local raid = getRaid(raidNid)
		local persisted = module:GetPersistedSnapshot(raid, key)
		if persisted and persisted.status == "ready" then
			return false, "ready"
		end
	end
	if byPlayer[key] then
		return false, "queued"
	end

	queue[#queue + 1] = { playerNid = key, reason = normalizeReason(reason), force = force == true }
	byPlayer[key] = true
	setRuntimeStatus(raidNid, key, "queued", reason)
	return true, "queued"
end

-- ----- Public methods ----- --

function module:ProcessQueue(raidNid)
	local resolved = tonumber(raidNid)
	if not resolved then
		return
	end
	if not getRaid(resolved) then
		cancelOrphanedRaidWork(resolved)
		return
	end
	if activeRequestByRaid[resolved] then
		return
	end
	local queue, byPlayer = ensureRuntime(resolved)
	if #queue == 0 then
		if sessionBusyByRaid[resolved] then
			emitCompleted(resolved)
		end
		return
	end

	emitStarted(resolved, "queue")
	local request = queue[1]
	tremove(queue, 1)
	if type(request) ~= "table" then
		if #queue > 0 then
			module:ProcessQueue(resolved)
		else
			emitCompleted(resolved)
		end
		return
	end

	local playerNid = normalizePlayerNid(request.playerNid)
	if playerNid <= 0 then
		module:ProcessQueue(resolved)
		return
	end

	activeRequestByRaid[resolved] = request
	setRuntimeStatus(resolved, playerNid, "pending", request.reason)
	if not isCurrentRaid(resolved) then
		finalizeRequest(resolved, playerNid, "skipped", "not_current_raid", nil, request)
		return
	end

	local raid = getRaid(resolved)
	local player = getPlayerByNid(raid or {}, playerNid)
	if not player then
		finalizeRequest(resolved, playerNid, "skipped", "missing_player", nil, request)
		return
	end

	local unit = resolveUnit(resolved, player)
	if not unit or not UnitExists(unit) then
		finalizeRequest(resolved, playerNid, "skipped", "missing_unit", nil, request)
		return false, "missing_unit"
	end
	if not UnitIsConnected(unit) then
		finalizeRequest(resolved, playerNid, "skipped", "offline", nil, request)
		return false, "offline"
	end
	if not CheckInteractDistance(unit, 1) then
		finalizeRequest(resolved, playerNid, "skipped", "out_of_range", nil, request)
		return false, "out_of_range"
	end
	if not CanInspect(unit) then
		finalizeRequest(resolved, playerNid, "skipped", "cannot_inspect", nil, request)
		return false, "cannot_inspect"
	end
	request.unit = unit
	request.unitGUID = UnitGUID(unit)
	request.coordinatorOwner = request

	local accepted, ownership = InspectCoordinator:Request(request.coordinatorOwner, unit, request.unitGUID, function()
		NotifyInspect(unit)
		globalInspectRequest = request
	end, function(reason)
		if reason == "timeout" and activeRequestByRaid[resolved] == request then
			local timeoutReason = request.inspectReady and "item_info_timeout" or "inspect_timeout"
			finalizeRequest(resolved, playerNid, "timeout", timeoutReason, nil, request)
		elseif reason == "start_failed" and activeRequestByRaid[resolved] == request then
			finalizeRequest(resolved, playerNid, "failed", "notify_failed", nil, request)
		elseif reason == "timer_failed" and activeRequestByRaid[resolved] == request then
			finalizeRequest(resolved, playerNid, "failed", "inspect_timer_failed", nil, request)
		elseif reason ~= "complete" and reason ~= "cancelled" and activeRequestByRaid[resolved] == request then
			finalizeRequest(resolved, playerNid, "failed", reason, nil, request)
		end
	end, "equipment")
	if not accepted then
		local failureReason = ownership == "timer_failed" and "inspect_timer_failed"
			or (ownership == "queue_full" and "inspect_queue_full")
			or ownership
		if activeRequestByRaid[resolved] == request then
			finalizeRequest(resolved, playerNid, "failed", failureReason, nil, request)
		end
		return false, failureReason
	end
	if activeRequestByRaid[resolved] ~= request then
		return false, "notify_failed"
	end
	return true, ownership == "active" and "pending" or "queued"
end

function module:StartRaidSnapshot(raidId, opts)
	local resolved = resolveRaidNid(raidId)
	if not resolved then
		return false, "missing_raid"
	end
	if not isCurrentRaid(resolved) then
		return false, "not_current_raid"
	end

	local raid = getRaid(resolved)
	if not raid then
		return false, "missing_raid"
	end

	local players = raid.players or {}
	local options = opts or {}
	local force = options.force == true
	local reason = normalizeReason(options.reason) or "raid_snapshot"
	for i = 1, #players do
		local player = players[i]
		queuePlayer(resolved, player and player.playerNid, reason, force)
	end

	if #queueByRaid[resolved] > 0 then
		local handle = scheduleTimerSafely(function()
			module:ProcessQueue(resolved)
		end, 0)
		if not handle then
			terminalizeQueuedTimerWork(resolved, "inspect_timer_failed")
			return false, "inspect_timer_failed"
		end
	end
	return true
end

function module:ForcePlayer(raidId, playerNid)
	local resolved = resolveRaidNid(raidId)
	if not resolved or not isCurrentRaid(resolved) then
		return false, "not_current_raid"
	end

	local raid = getRaid(resolved)
	if not raid then
		return false, "not_current_raid"
	end

	if not getPlayerByNid(raid, playerNid) then
		return false, "missing_player"
	end

	local queued, queueStatus = queuePlayer(resolved, playerNid, "manual_force_player", true)
	if not queued then
		return false, queueStatus
	end
	local processed, processStatus = module:ProcessQueue(resolved)
	if processed == false then
		return false, processStatus
	end
	local runtime = runtimeStatusByRaid[resolved]
	local current = runtime and runtime[normalizePlayerNid(playerNid)] or nil
	return true, processStatus or (current and current.status) or queueStatus
end

function module:GetSnapshot(raidOrId, playerNid)
	local rid = resolveRaidNid(raidOrId)
	local nid = normalizePlayerNid(playerNid)
	if nid <= 0 then
		return nil
	end

	local runtime = rid and runtimeStatusByRaid[rid] or nil
	if runtime and runtime[nid] then
		local attempt = runtime[nid]
		if attempt.status ~= "ready" then
			local persisted = module:GetPersistedSnapshot(raidOrId, nid)
			if persisted then
				persisted.status = attempt.status
				persisted.reason = attempt.reason
				persisted.updatedAt = attempt.updatedAt
				return persisted
			end
		end
		return attempt
	end

	return module:GetPersistedSnapshot(raidOrId, nid)
end

function module:GetPersistedSnapshot(raidOrId, playerNid)
	local raidNid = resolveRaidNid(raidOrId)
	local raid = getRaid(raidNid)
	local nid = normalizePlayerNid(playerNid)
	if not raid or nid <= 0 then
		return nil
	end
	local player = getPlayerByNid(raid, nid)
	return compactPersistedInspectSnapshot(player and player.inspect)
end

local function clearEquipInspectQueue(raidNid)
	local rid = tonumber(raidNid)
	if rid then
		if queueByRaid[rid] then
			while #queueByRaid[rid] > 0 do
				local req = tremove(queueByRaid[rid])
				if req and req.playerNid then
					clearRuntime(rid, req.playerNid)
				end
			end
		end
		queuedByPlayer[rid] = {}
		runtimeStatusByRaid[rid] = {}
		return
	end

	for k in pairs(queueByRaid) do
		clearEquipInspectQueue(k)
	end
end

local function handleInspectReady(guid)
	local readyGuid = normalizeReason(guid)
	for raidId, request in pairs(activeRequestByRaid) do
		if request == globalInspectRequest and (not readyGuid or request.unitGUID == readyGuid) then
			if request.unit then
				request.inspectReady = true
				tryFinalizeItemInfo(raidId, request)
			else
				finalizeRequest(raidId, request.playerNid, "failed", "missing_unit", nil, request)
			end
			return
		end
	end
end

local function handleItemInfoReceived(itemId, succeeded)
	if succeeded == false then
		return
	end
	local resolvedItemId = tonumber(itemId)
	if not resolvedItemId then
		return
	end
	for raidId, request in pairs(activeRequestByRaid) do
		if
			request == globalInspectRequest
			and request.inspectReady
			and request.unresolvedByItem
			and request.unresolvedByItem[resolvedItemId]
		then
			tryFinalizeItemInfo(raidId, request)
			return
		end
	end
end

local inspectReadyEvent =
	assert(ResolveWowForwardedName("INSPECT_TALENT_READY"), Diag.A.EquipInspectTalentReadyEventNotInitialized)
RegisterCallback(inspectReadyEvent, function(_, guid)
	handleInspectReady(guid)
end)

local itemInfoReceivedEvent =
	assert(ResolveWowForwardedName("GET_ITEM_INFO_RECEIVED"), Diag.A.EquipInspectItemInfoEventNotInitialized)
RegisterCallback(itemInfoReceivedEvent, function(_, itemId, succeeded)
	handleItemInfoReceived(itemId, succeeded)
end)

RegisterCallback(RaidCreateEvent, function(_, raidId)
	local raidNid = resolveRaidNid(raidId)
	if not raidNid then
		return
	end
	scheduleTimerSafely(function()
		if not getRaid(raidNid) then
			cancelOrphanedRaidWork(raidNid)
			return
		end
		local raidIndex = Database.GetRaidIndexByNid(raidNid)
		if raidIndex then
			module:StartRaidSnapshot(raidIndex, { reason = "raid_start" })
		end
	end, RAID_CREATE_DELAY_SECONDS)
end)
