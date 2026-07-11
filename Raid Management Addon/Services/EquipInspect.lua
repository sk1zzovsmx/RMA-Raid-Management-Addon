--- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: direct addon namespace bindings
-- exports: addon.Services.EquipInspect
-- events: listens wow.INSPECT_TALENT_READY and wow.PLAYER_REGEN_ENABLED; emits EquipInspectStarted/EquipInspectUpdated/EquipInspectCompleted

local addon = select(2, ...)
local Database = addon.Database
local Services = addon.Services
local Events = addon.Events
local Bus = addon.Bus
local Timer = addon.Timer
local Strings = addon.Strings

local InternalEvents = assert(Events.Internal, "EquipInspect internal events are not initialized")
local TriggerEvent = assert(Bus.TriggerEvent, "EquipInspect event publisher is not initialized")
local RegisterCallback = assert(Bus.RegisterCallback, "EquipInspect event bus listener is not initialized")
local ResolveWowForwardedName =
	assert(Events.ResolveWowForwardedName, "EquipInspect forwarded-event resolver is not initialized")
local EquipInspectStartedEvent =
	assert(InternalEvents.EquipInspectStarted, "EquipInspect started event is not initialized")
local EquipInspectCompletedEvent =
	assert(InternalEvents.EquipInspectCompleted, "EquipInspect completed event is not initialized")
local EquipInspectUpdatedEvent =
	assert(InternalEvents.EquipInspectUpdated, "EquipInspect update event is not initialized")
local RaidCreateEvent = assert(InternalEvents.RaidCreate, "EquipInspect raid-create event is not initialized")

local GetTime = assert(_G.GetTime, "EquipInspect time API is not initialized")
local UnitGUID = assert(_G.UnitGUID, "EquipInspect unit GUID API is not initialized")
local UnitExists = assert(_G.UnitExists, "EquipInspect unit existence API is not initialized")
local UnitIsConnected = assert(_G.UnitIsConnected, "EquipInspect unit connection API is not initialized")
local CanInspect = assert(_G.CanInspect, "EquipInspect inspect capability API is not initialized")
local CheckInteractDistance = assert(_G.CheckInteractDistance, "EquipInspect unit range API is not initialized")
local NotifyInspect = assert(_G.NotifyInspect, "EquipInspect notify inspect API is not initialized")
local ClearInspectPlayer = assert(_G.ClearInspectPlayer, "EquipInspect clear inspect API is not initialized")
local UnitAffectingCombat = assert(_G.UnitAffectingCombat, "EquipInspect combat state API is not initialized")
local GetInventoryItemLink = assert(_G.GetInventoryItemLink, "EquipInspect inventory item link API is not initialized")
local GetInventoryItemTexture =
	assert(_G.GetInventoryItemTexture, "EquipInspect inventory item texture API is not initialized")
local GetInventoryItemQuality =
	assert(_G.GetInventoryItemQuality, "EquipInspect inventory item quality API is not initialized")
local GetItemInfo = assert(_G.GetItemInfo, "EquipInspect item info API is not initialized")

local type, tonumber, tostring = type, tonumber, tostring
local pairs, ipairs = pairs, ipairs
local tinsert = table.insert
local tremove = table.remove

local THROTTLE_SECONDS = 1.75
local TIMEOUT_SECONDS = 8
local RAID_CREATE_DELAY_SECONDS = 3.0
local SLOT_ORDER = { 1, 2, 3, 15, 5, 9, 10, 6, 7, 8, 11, 12, 13, 14, 16, 17, 18 }

-- ----- Internal state ----- --

addon.Database.EnsureServiceNamespace("EquipInspect")
local module = Services.EquipInspect
Timer.BindMixin(module, "EquipInspect")

local queueByRaid = {}
local queuedByPlayer = {}
local runtimeStatusByRaid = {}
local activeRequestByRaid = {}
local sessionBusyByRaid = {}

-- ----- Private helpers ----- --

local function now()
	return tonumber(GetTime()) or 0
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

local function ensureInspectRoot(raid)
	if type(raid) ~= "table" then
		return nil
	end
	if type(raid.inspect) ~= "table" then
		raid.inspect = {}
	end
	if type(raid.inspect.players) ~= "table" then
		raid.inspect.players = {}
	end
	return raid.inspect
end

local function ensureRuntime(raidId)
	if not queueByRaid[raidId] then
		queueByRaid[raidId] = {}
	end
	if not queuedByPlayer[raidId] then
		queuedByPlayer[raidId] = {}
	end
	if not runtimeStatusByRaid[raidId] then
		runtimeStatusByRaid[raidId] = {}
	end
	return queueByRaid[raidId], queuedByPlayer[raidId], runtimeStatusByRaid[raidId]
end

local function getRaid(raidOrId)
	if type(raidOrId) == "table" then
		return raidOrId
	end

	local rid = normalizeRaidIndex(raidOrId)
	if not rid then
		return nil
	end
	return Database.EnsureRaidByIndex(rid)
end

local function isCurrentRaid(raidId)
	local rid = normalizeRaidIndex(raidId)
	local current = normalizeRaidIndex(Database.GetCurrentRaid())
	return rid and current and rid == current
end

local function emitStarted(raidId, reason)
	if sessionBusyByRaid[raidId] then
		return
	end
	sessionBusyByRaid[raidId] = true
	TriggerEvent(EquipInspectStartedEvent, raidId, reason or "start")
end

local function emitCompleted(raidId)
	sessionBusyByRaid[raidId] = false
	local raid = getRaid(raidId)
	local inspect = ensureInspectRoot(raid)
	if inspect then
		inspect.completedAt = now()
	end
	TriggerEvent(EquipInspectCompletedEvent, raidId)
end

local function emitUpdated(raidId, playerNid, snapshot)
	TriggerEvent(EquipInspectUpdatedEvent, raidId, playerNid, snapshot)
end

local function setRuntimeStatus(raidId, playerNid, status, reason)
	local _, _, runtime = ensureRuntime(raidId)
	local key = normalizePlayerNid(playerNid)
	if key <= 0 then
		return
	end

	if status == "queued" or status == "pending" then
		runtime[key] = {
			status = status,
			reason = normalizeReason(reason),
			updatedAt = now(),
		}
		emitUpdated(raidId, key, runtime[key])
		return
	end

	runtime[key] = nil
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

	local compact = {
		playerNid = tonumber(snapshot.playerNid) or nil,
		name = copyIfString(snapshot.name),
		guid = copyIfString(snapshot.guid),
		class = copyIfString(snapshot.class),
		status = copyIfString(snapshot.status),
		reason = copyIfString(snapshot.reason),
		inspectedAt = tonumber(snapshot.inspectedAt) or nil,
		avgIlvl = tonumber(snapshot.avgIlvl) or nil,
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
		local _, _, _, itemIlvl = GetItemInfo(itemId)
		if type(itemIlvl) == "number" and itemIlvl > 0 then
			return itemIlvl
		end
	end
	if link then
		local _, _, _, itemIlvl = GetItemInfo(link)
		if type(itemIlvl) == "number" and itemIlvl > 0 then
			return itemIlvl
		end
	end
	return 0
end

local function collectItems(unit)
	local items = {}
	local total = 0
	local count = 0

	for i = 1, #SLOT_ORDER do
		local slot = SLOT_ORDER[i]
		local link = GetInventoryItemLink(unit, slot)
		local data = parseItemLink(link) or {}
		local itemId = tonumber(data.itemId) or 0
		data.slot = slot
		data.itemLink = link
		data.texture = GetInventoryItemTexture(unit, slot)
		data.quality = tonumber(GetInventoryItemQuality(unit, slot)) or 0
		data.ilvl = getItemIlvl(itemId, link)

		if data.ilvl > 0 then
			total = total + data.ilvl
			count = count + 1
		end
		items[slot] = data
	end

	return items, (count > 0 and (total / count) or 0)
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
	local items, avgIlvl = collectItems(unit)
	local talentSnapshot = getSpecInspectSnapshot(unit, player)
	return {
		items = items,
		avgIlvl = avgIlvl,
		talentSnapshot = talentSnapshot,
	}
end

local function persistReadySnapshot(raid, playerNid, snapshot)
	local inspect = ensureInspectRoot(raid)
	if not inspect then
		return
	end
	inspect.players[playerNid] = compactPersistedInspectSnapshot(snapshot)
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

local function resolveUnit(raidId, player)
	local roster = Services["Raid/Roster"] or Services.Raid
	if type(roster) ~= "table" then
		return nil
	end

	if type(roster.GetUnitByPlayerNid) == "function" then
		local unit = roster:GetUnitByPlayerNid(raidId, player.playerNid)
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

local function finalizeRequest(raidId, playerNid, status, reason, unit, request)
	local currentRequest = activeRequestByRaid[raidId]
	if currentRequest and currentRequest.timeoutHandle then
		module:CancelTimer(currentRequest.timeoutHandle)
	end

	local active = activeRequestByRaid[raidId]
	if active then
		activeRequestByRaid[raidId] = nil
	end

	local queue = queueByRaid[raidId]
	if not queue then
		queue = {}
		queueByRaid[raidId] = queue
	end
	if queuedByPlayer[raidId] then
		queuedByPlayer[raidId][playerNid] = nil
	end

	local snapshot
	local snapshotStatus = status
	if status == "ready" and unit then
		local raid = getRaid(raidId)
		local player = getPlayerByNid(raid or {}, playerNid)
		local details = buildReadyDetails(unit, player)
		local resolvedGuid = UnitGUID(unit)
		snapshot = {
			status = status,
			reason = normalizeReason(reason),
			inspectedAt = now(),
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

		persistReadySnapshot(raid, playerNid, snapshot)
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
		persistReadySnapshot(getRaid(raidId), playerNid, snapshot)
	end

	if not snapshot.guid then
		local raid = getRaid(raidId)
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
		local _, _, runtimeTable = ensureRuntime(raidId)
		runtimeTable[playerNid] = snapshot
	else
		setRuntimeStatus(raidId, playerNid, snapshotStatus, reason)
	end
	if
		snapshotStatus == "ready"
		or snapshotStatus == "skipped"
		or snapshotStatus == "timeout"
		or snapshotStatus == "failed"
	then
		emitUpdated(raidId, playerNid, snapshot)
	end

	if #queue == 0 then
		emitCompleted(raidId)
	else
		module:ScheduleTimer(function()
			module:ProcessQueue(raidId)
		end, THROTTLE_SECONDS)
	end

	pcall(ClearInspectPlayer)

	return snapshot
end

local function scheduleRetryCurrentRequest(raidId, request, delay)
	local resolved = normalizeRaidIndex(raidId)
	if not resolved or type(request) ~= "table" then
		return
	end

	local queue = queueByRaid[resolved]
	if not queue then
		queue = {}
		queueByRaid[resolved] = queue
	end

	if activeRequestByRaid[resolved] == request then
		activeRequestByRaid[resolved] = nil
		tinsert(queue, 1, request)
		request.retryHandle = module:ScheduleTimer(function()
			module:ProcessQueue(resolved)
		end, delay or THROTTLE_SECONDS)
	end
end

local function queuePlayer(raidId, playerNid, reason, force)
	local queue, byPlayer, runtime = ensureRuntime(raidId)
	local key = normalizePlayerNid(playerNid)
	if key <= 0 then
		return false
	end

	local current = runtime[key]
	if not force and current and current.status == "ready" then
		return false
	end
	if current and (current.status == "queued" or current.status == "pending") then
		return false
	end
	if not force and not current then
		local raid = getRaid(raidId)
		local persisted = module:GetPersistedSnapshot(raid, key)
		if persisted and persisted.status == "ready" then
			return false
		end
	end
	if byPlayer[key] then
		return false
	end

	queue[#queue + 1] = { playerNid = key, reason = normalizeReason(reason), force = force == true }
	byPlayer[key] = true
	setRuntimeStatus(raidId, key, "queued", reason)
	return true
end

-- ----- Public methods ----- --

function module:ProcessQueue(raidId)
	local resolved = normalizeRaidIndex(raidId)
	if not resolved then
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
		return
	end
	if not UnitIsConnected(unit) then
		finalizeRequest(resolved, playerNid, "skipped", "offline", nil, request)
		return
	end
	if not CheckInteractDistance(unit, 1) then
		finalizeRequest(resolved, playerNid, "skipped", "out_of_range", nil, request)
		return
	end
	if not CanInspect(unit) then
		finalizeRequest(resolved, playerNid, "skipped", "cannot_inspect", nil, request)
		return
	end
	if UnitAffectingCombat("player") then
		request.reason = "retry"
		scheduleRetryCurrentRequest(resolved, request, THROTTLE_SECONDS)
		return
	end
	request.unit = unit
	request.unitGUID = UnitGUID(unit)

	local ok, err = pcall(function()
		NotifyInspect(unit)
	end)
	if not ok then
		finalizeRequest(resolved, playerNid, "failed", "notify_failed")
		return
	end

	request.timeoutHandle = module:ScheduleTimer(function()
		local active = activeRequestByRaid[resolved]
		if active == request then
			finalizeRequest(resolved, playerNid, "timeout", "inspect_timeout", nil, request)
		end
	end, TIMEOUT_SECONDS)
end

function module:StartRaidSnapshot(raidId, opts)
	local resolved = normalizeRaidIndex(raidId)
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
	local inspect = ensureInspectRoot(raid)
	if inspect then
		inspect.startedAt = now()
		inspect.mode = reason
	end

	for i = 1, #players do
		local player = players[i]
		queuePlayer(resolved, player and player.playerNid, reason, force)
	end

	if #queueByRaid[resolved] > 0 then
		module:ScheduleTimer(function()
			module:ProcessQueue(resolved)
		end, 0)
	end
	return true
end

function module:ForcePlayer(raidId, playerNid)
	local resolved = normalizeRaidIndex(raidId)
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

	queuePlayer(resolved, playerNid, "manual_force_player", true)
	module:ProcessQueue(resolved)
	return true
end

function module:GetSnapshot(raidOrId, playerNid)
	local rid = normalizeRaidIndex(raidOrId)
	local nid = normalizePlayerNid(playerNid)
	if nid <= 0 then
		return nil
	end

	local runtime = rid and runtimeStatusByRaid[rid] or nil
	if runtime and runtime[nid] then
		return runtime[nid]
	end

	return module:GetPersistedSnapshot(raidOrId, nid)
end

function module:GetPersistedSnapshot(raidOrId, playerNid)
	local raid = getRaid(raidOrId)
	local nid = normalizePlayerNid(playerNid)
	if not raid or nid <= 0 then
		return nil
	end
	local inspect = raid.inspect
	if type(inspect) ~= "table" then
		return nil
	end
	local persisted = inspect.players and (inspect.players[nid] or inspect.players[tostring(nid)])
	return compactPersistedInspectSnapshot(persisted)
end

local function clearEquipInspectQueue(raidId)
	local rid = normalizeRaidIndex(raidId)
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
		if request and (not readyGuid or request.unitGUID == readyGuid) then
			if request.unit then
				finalizeRequest(raidId, request.playerNid, "ready", nil, request.unit, request)
			else
				finalizeRequest(raidId, request.playerNid, "failed", "missing_unit", nil, request)
			end
			return
		end
	end
end

local function handlePlayerRegenEnabled()
	local rid = Database.GetCurrentRaid()
	rid = normalizeRaidIndex(rid)
	if rid and #(queueByRaid[rid] or {}) > 0 then
		module:ProcessQueue(rid)
	end
end

local inspectReadyEvent =
	assert(ResolveWowForwardedName("INSPECT_TALENT_READY"), "EquipInspect talent-ready event is not initialized")
RegisterCallback(inspectReadyEvent, function(_, guid)
	handleInspectReady(guid)
end)

local playerRegenEnabledEvent =
	assert(ResolveWowForwardedName("PLAYER_REGEN_ENABLED"), "EquipInspect regen-enabled event is not initialized")
RegisterCallback(playerRegenEnabledEvent, function()
	handlePlayerRegenEnabled()
end)

RegisterCallback(RaidCreateEvent, function(_, raidId)
	module:ScheduleTimer(function()
		module:StartRaidSnapshot(raidId, { reason = "raid_start" })
	end, RAID_CREATE_DELAY_SECONDS)
end)
