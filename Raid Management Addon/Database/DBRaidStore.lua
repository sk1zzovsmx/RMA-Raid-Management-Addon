-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: direct addon namespace bindings
-- exports: publish module APIs on addon.*
-- events: none
local addon = select(2, ...)
local DB = addon.DB
local coreState = addon.State
local Database = addon.Database
local SavedVariables = Database.SavedVariables
local Time = addon.Time
local GetCurrentTime = assert(Time and Time.GetCurrentTime, "Raid store time provider is not initialized")

local tinsert, tremove = table.insert, table.remove
local pairs, type = pairs, type
local tostring, tonumber = tostring, tonumber
local tconcat = table.concat
local format = string.format
local Events = addon.Events or {}
local InternalEvents = Events.Internal or {}
local RaidReplicationCommittedEvent = InternalEvents.RaidReplicationCommitted or "RaidReplicationCommitted"
local TriggerEvent = addon.Bus.TriggerEvent or function() end
local RaidEvents = DB.RaidEvents
local GetTime = _G.GetTime
local UnitFullName = _G.UnitFullName

local function deepCopy(value, seen)
	if type(value) ~= "table" then
		return value
	end
	seen = seen or {}
	if seen[value] then
		return seen[value]
	end
	local copy = {}
	seen[value] = copy
	for key, item in pairs(value) do
		copy[deepCopy(key, seen)] = deepCopy(item, seen)
	end
	return copy
end

local function checkpointIfRequired(record, limit)
	local excess = #record.events - limit
	if excess <= 0 then
		return
	end
	for _ = 1, excess do
		local removed = tremove(record.events, 1)
		record.checkpointSequence = removed.sequence
	end
end

-- Raid storage service.
do
	DB.RaidStore = DB.RaidStore or {}
	local module = DB.RaidStore

	-- ----- Internal state ----- --
	local RUNTIME_INDEX_MAP_KEYS = {
		"playersByName",
		"playerByNid",
		"playerNidByName",
		"playerIdxByNid",
		"bossIdxByNid",
		"bossByNid",
		"bossPlayerSetByBossNid",
		"lootIdxByNid",
		"lootByNid",
		"lootIdxByBossNid",
		"lootIdxByLooterNid",
		"attendanceIdxByPlayerNid",
		"attendanceByPlayerNid",
	}

	local storeState = coreState.raidStore
	if type(storeState) ~= "table" then
		storeState = {}
		coreState.raidStore = storeState
	end
	local stagedMutationBase = setmetatable({}, { __mode = "k" })
	local Validator
	local raidUidCounter = 0
	local sessionNonce
	local authorityGuard
	local validatedArchive
	local runtimeByRaid = setmetatable({}, { __mode = "k" })

	local function requireLocalAuthority(operation)
		if type(authorityGuard) ~= "function" then
			return nil, "AUTHORITY_GUARD_UNAVAILABLE"
		end
		local ok, allowed, reason = pcall(authorityGuard, operation)
		if not ok then
			return nil, "NOT_RAID_LEADER"
		end
		if allowed ~= true then
			return nil, reason or "NOT_RAID_LEADER"
		end
		return true
	end

	-- ----- Private helpers ----- --
	local function clearMap(map)
		if type(map) ~= "table" then
			return {}
		end
		for key in pairs(map) do
			map[key] = nil
		end
		return map
	end

	local isBossFightRecord = Database.IsBossFightRecord

	local function createNidAllocator(initialNext)
		local usedNids = {}
		local nextNid = tonumber(initialNext) or 1
		if nextNid < 1 then
			nextNid = 1
		end

		local function markAllocated(nid)
			usedNids[nid] = true
			if nid >= nextNid then
				nextNid = nid + 1
			end
			return nid
		end

		local function allocate(preferred)
			local nid = tonumber(preferred)
			if nid and nid > 0 and not usedNids[nid] then
				return markAllocated(nid)
			end

			while usedNids[nextNid] do
				nextNid = nextNid + 1
			end

			return markAllocated(nextNid)
		end

		local function getNext()
			return nextNid
		end

		return allocate, getNext
	end

	local function ensureRaidsTable()
		return SavedVariables.GetRaids()
	end

	local function getValidator()
		if not Validator then
			Validator = Database.GetRaidValidator()
		end
		return Validator
	end

	local function requireValidArchive()
		local quarantinedReason = SavedVariables.GetRaidArchiveError and SavedVariables.GetRaidArchiveError()
		if quarantinedReason then
			return nil, quarantinedReason
		end
		local archive = SavedVariables.GetRaids()
		if archive == validatedArchive then
			return archive
		end
		local valid, reason = getValidator():ValidateArchive(archive)
		if not valid then
			return nil, reason or "INVALID_RAID_ARCHIVE"
		end
		validatedArchive = archive
		return archive
	end

	local function requireCurrentStateDigest(record)
		local digest = type(record) == "table" and RaidEvents.DigestState(record.state) or nil
		if not digest or digest ~= record.digest then
			return nil, "CURRENT_STATE_DIGEST_MISMATCH"
		end
		return true
	end

	local function appendOrder(archive, raidUid)
		archive.order[#archive.order + 1] = raidUid
	end

	local function resolveRaidStartTime(value)
		if value ~= nil then
			local timestamp = tonumber(value)
			assert(timestamp, "Raid start timestamp is not initialized")
			return timestamp
		end

		local timestamp = tonumber(GetCurrentTime())
		assert(timestamp, "Raid start timestamp is not initialized")
		return timestamp
	end

	local function getSchemaVersion()
		local version = Database.GetRaidSchemaVersion() or 1
		version = tonumber(version) or 1
		if version < 1 then
			version = 1
		end
		return version
	end

	local function isRuntimeIndexReady(runtime)
		if type(runtime) ~= "table" then
			return false
		end
		for i = 1, #RUNTIME_INDEX_MAP_KEYS do
			if not (type(runtime[RUNTIME_INDEX_MAP_KEYS[i]]) == "table") then
				return false
			end
		end
		return true
	end

	local function ensureRuntimeTable(raid)
		local runtime = runtimeByRaid[raid]
		if type(runtime) ~= "table" then
			runtime = {}
			runtimeByRaid[raid] = runtime
		end
		return runtime
	end

	local function acquireRuntimeIndexMap(runtime, key)
		local map = clearMap(runtime[key])
		runtime[key] = map
		return map
	end

	local function acquireRuntimeIndexMaps(runtime)
		local maps = {}
		for i = 1, #RUNTIME_INDEX_MAP_KEYS do
			local key = RUNTIME_INDEX_MAP_KEYS[i]
			maps[key] = acquireRuntimeIndexMap(runtime, key)
		end
		return maps
	end

	local function appendRuntimeIndexList(indexMap, key, value, dedupe)
		if key == nil or value == nil then
			return
		end
		local list = indexMap[key]
		if type(list) ~= "table" then
			list = {}
			indexMap[key] = list
		end
		if dedupe == true then
			for i = 1, #list do
				if list[i] == value then
					return
				end
			end
		end
		list[#list + 1] = value
	end

	local function removeRuntimeIndexListValue(indexMap, value)
		if type(indexMap) ~= "table" or value == nil then
			return
		end
		for _, list in pairs(indexMap) do
			if type(list) == "table" then
				for i = #list, 1, -1 do
					if list[i] == value then
						tremove(list, i)
					end
				end
			end
		end
	end

	local function indexLootRuntimeRow(runtime, loot, index, replaceExisting)
		if type(runtime) ~= "table" or type(loot) ~= "table" then
			return false
		end
		local resolvedIndex = tonumber(index)
		if type(resolvedIndex) ~= "number" or resolvedIndex <= 0 then
			return false
		end
		local lootNid = tonumber(loot.lootNid)
		if not lootNid then
			return false
		end

		runtime.lootIdxByNid[lootNid] = resolvedIndex
		runtime.lootByNid[lootNid] = loot

		if replaceExisting then
			removeRuntimeIndexListValue(runtime.lootIdxByBossNid, resolvedIndex)
			removeRuntimeIndexListValue(runtime.lootIdxByLooterNid, resolvedIndex)
		end

		local bossNid = tonumber(loot.bossNid)
		if bossNid and bossNid > 0 then
			appendRuntimeIndexList(runtime.lootIdxByBossNid, bossNid, resolvedIndex, replaceExisting == true)
		end

		local looterNid = tonumber(loot.looterNid)
		if looterNid and looterNid > 0 then
			appendRuntimeIndexList(runtime.lootIdxByLooterNid, looterNid, resolvedIndex, replaceExisting == true)
		end

		return true
	end

	local function normalizeRuntimeState(raid)
		if type(raid) ~= "table" then
			return
		end
		runtimeByRaid[raid] = nil
	end

	local function stripRuntimeState(raid)
		if type(raid) ~= "table" then
			return
		end
		runtimeByRaid[raid] = nil
	end

	local function compactInspectSnapshot(snapshot)
		if type(snapshot) ~= "table" or snapshot.status ~= "ready" then
			return nil
		end
		local compact = {
			playerNid = tonumber(snapshot.playerNid),
			name = type(snapshot.name) == "string" and snapshot.name or nil,
			guid = type(snapshot.guid) == "string" and snapshot.guid or nil,
			class = type(snapshot.class) == "string" and snapshot.class or nil,
			status = "ready",
			avgIlvl = tonumber(snapshot.avgIlvl),
			specName = type(snapshot.specName) == "string" and snapshot.specName or nil,
			specIcon = type(snapshot.specIcon) == "string" and snapshot.specIcon or nil,
			mainTalentTree = tonumber(snapshot.mainTalentTree),
			secondarySpecName = type(snapshot.secondarySpecName) == "string" and snapshot.secondarySpecName or nil,
			secondarySpecIcon = type(snapshot.secondarySpecIcon) == "string" and snapshot.secondarySpecIcon or nil,
			activeTalentGroup = tonumber(snapshot.activeTalentGroup),
			numTalentGroups = tonumber(snapshot.numTalentGroups),
			secondaryTalentGroup = tonumber(snapshot.secondaryTalentGroup),
			secondaryMainTalentTree = tonumber(snapshot.secondaryMainTalentTree),
		}
		local inspectedAt = tonumber(snapshot.inspectedAt)
		if inspectedAt and inspectedAt >= 1000000000 then
			compact.inspectedAt = inspectedAt
		end
		return compact
	end

	local function compactInspectForPersistence(raid)
		local players = type(raid.inspect) == "table" and raid.inspect.players or nil
		local compactPlayers = {}
		if type(players) == "table" then
			for key, snapshot in pairs(players) do
				local compact = compactInspectSnapshot(snapshot)
				if compact then
					compactPlayers[key] = compact
				end
			end
		end
		raid.inspect = next(compactPlayers) and { players = compactPlayers } or nil
	end

	local function buildRuntimeSignature(raid, players, bosses, lootRows, attendance)
		return format(
			"%d|%d|%d|%d|%d|%d|%d",
			#players,
			#bosses,
			#lootRows,
			#attendance,
			tonumber(raid.nextPlayerNid) or 1,
			tonumber(raid.nextBossNid) or 1,
			tonumber(raid.nextLootNid) or 1
		)
	end

	local function getRuntimeCollections(raid)
		return raid.players or {}, raid.bossKills or {}, raid.loot or {}, raid.attendance or {}
	end

	local function buildRaidRuntimeSignature(raid)
		local players, bosses, lootRows, attendance = getRuntimeCollections(raid)
		return buildRuntimeSignature(raid, players, bosses, lootRows, attendance)
	end

	local function refreshRuntimeSignature(raid, runtime)
		runtime.signature = buildRaidRuntimeSignature(raid)
		return runtime.signature
	end

	local function appendNormalizedAttendanceSegment(entry, segment)
		if type(segment) ~= "table" then
			return
		end

		local startTime = tonumber(segment.startTime) or 0
		if startTime <= 0 then
			return
		end

		local out = {
			startTime = startTime,
		}

		local endTime = tonumber(segment.endTime) or 0
		if endTime > startTime then
			out.endTime = endTime
		end

		local subgroup = tonumber(segment.subgroup) or 1
		if subgroup > 1 then
			out.subgroup = subgroup
		end

		if segment.online == false then
			out.online = false
		end

		entry.segments[#entry.segments + 1] = out
	end

	local function normalizeAttendance(attendance, validPlayerNids)
		local out = {}
		if type(attendance) ~= "table" then
			return out
		end

		local seenPlayers = {}
		for i = 1, #attendance do
			local rawEntry = attendance[i]
			local playerNid = type(rawEntry) == "table" and tonumber(rawEntry.playerNid) or 0
			if playerNid > 0 and validPlayerNids[playerNid] and not seenPlayers[playerNid] then
				local entry = {
					playerNid = playerNid,
					segments = {},
				}
				seenPlayers[playerNid] = true

				local segments = rawEntry.segments
				if type(segments) == "table" then
					for j = 1, #segments do
						appendNormalizedAttendanceSegment(entry, segments[j])
					end
				end

				if #entry.segments > 0 then
					out[#out + 1] = entry
				end
			end
		end

		return out
	end

	local function markRaidNidIndexDirty()
		storeState.raidNidIndexDirty = true
	end

	local function buildArchiveRaidNidIndexSignature(archive)
		local parts = {}
		for i = 1, #archive.order do
			local raidUid = archive.order[i]
			local record = archive.raids[raidUid]
			local raidNid = record and not record.conflictOfRaidUid and record.state and record.state.raidNid or ""
			parts[i] = tostring(raidUid) .. ":" .. tostring(raidNid)
		end
		return tconcat(parts, "|")
	end

	local function rebuildArchiveRaidNidIndex(archive)
		local raidIdxByNid = {}
		local ambiguous = {}
		local activeNid
		local nextRaidNid = 1
		for i = 1, #archive.order do
			local archiveKey = archive.order[i]
			local record = archive.raids[archiveKey]
			local raidNid = tonumber(record and not record.conflictOfRaidUid and record.state and record.state.raidNid)
			if raidNid and raidNid > 0 then
				if archiveKey == archive.activeRaidUid then
					raidIdxByNid[raidNid] = i
					ambiguous[raidNid] = nil
					activeNid = raidNid
				elseif raidNid ~= activeNid and not ambiguous[raidNid] then
					if raidIdxByNid[raidNid] then
						raidIdxByNid[raidNid] = nil
						ambiguous[raidNid] = true
					else
						raidIdxByNid[raidNid] = i
					end
				end
				if raidNid >= nextRaidNid then
					nextRaidNid = raidNid + 1
				end
			end
		end
		storeState.raidIdxByNid = raidIdxByNid
		storeState.nextRaidNid = nextRaidNid
		storeState.raidNidIndexCount = #archive.order
		storeState.raidNidIndexSignature = buildArchiveRaidNidIndexSignature(archive)
		storeState.raidNidIndexDirty = nil
		return raidIdxByNid
	end

	local function ensureArchiveRaidNidIndex(archive)
		local signature = buildArchiveRaidNidIndexSignature(archive)
		if
			storeState.raidNidIndexDirty ~= true
			and type(storeState.raidIdxByNid) == "table"
			and storeState.raidNidIndexCount == #archive.order
			and storeState.raidNidIndexSignature == signature
		then
			return storeState.raidIdxByNid
		end
		return rebuildArchiveRaidNidIndex(archive)
	end

	local function rebuildRaidNidIndex()
		local archive = ensureRaidsTable()
		return archive, rebuildArchiveRaidNidIndex(archive)
	end

	local function ensureRaidNidIndex()
		local archive = ensureRaidsTable()
		return archive, ensureArchiveRaidNidIndex(archive)
	end

	local function getNextRaidNid(preferred)
		local _, raidIdxByNid = ensureRaidNidIndex()
		local raidNid = tonumber(preferred)
		if raidNid and raidNid > 0 and not raidIdxByNid[raidNid] then
			if raidNid >= (tonumber(storeState.nextRaidNid) or 1) then
				storeState.nextRaidNid = raidNid + 1
			end
			return raidNid
		end
		local nextRaidNid = tonumber(storeState.nextRaidNid) or 1
		while raidIdxByNid[nextRaidNid] do
			nextRaidNid = nextRaidNid + 1
		end
		storeState.nextRaidNid = nextRaidNid + 1
		return nextRaidNid
	end

	local function buildRuntimeIndexesForNormalizedRaid(raid)
		if not raid then
			return nil
		end

		local runtime = ensureRuntimeTable(raid)
		local maps = acquireRuntimeIndexMaps(runtime)
		local players, bosses, lootRows, attendance = getRuntimeCollections(raid)
		for i = 1, #players do
			local player = players[i]
			if type(player) == "table" then
				if player.name then
					maps.playersByName[player.name] = player
				end
				local playerNid = tonumber(player.playerNid)
				if playerNid then
					maps.playerByNid[playerNid] = player
					if player.name then
						maps.playerNidByName[player.name] = playerNid
					end
					maps.playerIdxByNid[playerNid] = i
				end
			end
		end

		for i = 1, #attendance do
			local entry = attendance[i]
			local playerNid = type(entry) == "table" and tonumber(entry.playerNid) or nil
			if playerNid then
				maps.attendanceIdxByPlayerNid[playerNid] = i
				maps.attendanceByPlayerNid[playerNid] = entry
			end
		end

		for i = 1, #bosses do
			local boss = bosses[i]
			if type(boss) == "table" then
				local bossNid = tonumber(boss.bossNid)
				if bossNid then
					maps.bossIdxByNid[bossNid] = i
					maps.bossByNid[bossNid] = boss
					local attendeeSet = {}
					local attendees = boss.players
					if type(attendees) == "table" then
						for j = 1, #attendees do
							local playerNid = tonumber(attendees[j])
							if playerNid and playerNid > 0 then
								attendeeSet[playerNid] = true
							end
						end
					end
					maps.bossPlayerSetByBossNid[bossNid] = attendeeSet
				end
			end
		end

		for i = 1, #lootRows do
			indexLootRuntimeRow(runtime, lootRows[i], i, false)
		end

		refreshRuntimeSignature(raid, runtime)

		return runtime
	end

	-- ----- Public methods ----- --
	function module:SetAuthorityGuard(guard)
		if type(guard) ~= "function" then
			return false, "INVALID_AUTHORITY_GUARD"
		end
		authorityGuard = guard
		return true
	end

	function module:EnsureArchive()
		return requireValidArchive()
	end

	function module:GetRecord(raidUid)
		local archive = requireValidArchive()
		if not archive then
			return nil
		end
		return type(raidUid) == "string" and type(archive.raids) == "table" and archive.raids[raidUid] or nil
	end

	function module:GetActiveRecord()
		local archive = requireValidArchive()
		if not archive then
			return nil
		end
		return type(archive.raids) == "table" and archive.activeRaidUid and archive.raids[archive.activeRaidUid] or nil
	end

	function module:GetStateByIndex(index)
		local archive = requireValidArchive()
		if not archive then
			return nil, tonumber(index)
		end
		if type(archive.order) ~= "table" or type(archive.raids) ~= "table" then
			return nil, tonumber(index)
		end
		local resolvedIndex = tonumber(index)
		local raidUid = resolvedIndex and archive.order[resolvedIndex] or nil
		local record = raidUid and archive.raids[raidUid] or nil
		return record and record.state or nil, resolvedIndex, record
	end

	function module:GetArchiveKeyByIndex(index)
		local archive = requireValidArchive()
		if not archive then
			return nil
		end
		if type(archive.order) ~= "table" then
			return nil
		end
		local resolvedIndex = tonumber(index)
		return resolvedIndex and archive.order[resolvedIndex] or nil
	end

	function module:GetIndexByArchiveKey(archiveKey)
		if type(archiveKey) ~= "string" then
			return nil
		end
		return self:GetIndexByUid(archiveKey)
	end

	function module:GetIndexByUid(raidUid)
		local archive = requireValidArchive()
		if not archive then
			return nil
		end
		if type(archive.order) ~= "table" or type(archive.raids) ~= "table" then
			return nil
		end
		for i = 1, #archive.order do
			if archive.order[i] == raidUid then
				return i
			end
		end
		return nil
	end

	function module:CreateActiveRaid(args)
		local validArchive, archiveReason = requireValidArchive()
		if not validArchive then
			return nil, archiveReason
		end
		local authorized, authorityReason = requireLocalAuthority()
		if not authorized then
			return nil, authorityReason
		end
		assert(RaidEvents, "Raid event reducer is not initialized")
		if type(args) ~= "table" then
			return nil, "INVALID_RAID_STATE"
		end
		if not sessionNonce then
			assert(GetTime, "Raid store monotonic time API is not initialized")
			sessionNonce = format("%08x", math.floor((GetTime() * 1000) % 4294967295))
		end
		local archive = validArchive
		if archive.activeRaidUid and archive.raids[archive.activeRaidUid] then
			return nil, "ACTIVE_RAID_EXISTS"
		end
		local creatorKey = args.authorityKey
		if type(creatorKey) ~= "string" or creatorKey == "" then
			local name, realm
			if UnitFullName then
				name, realm = UnitFullName("player")
			end
			creatorKey = name and (realm and (name .. "-" .. realm) or name) or nil
		end
		local serverTime = tonumber(args.serverTime) or tonumber(GetCurrentTime())
		local authorityEpoch = tonumber(args.authorityEpoch) or 1
		local initialState = {
			schemaVersion = getSchemaVersion(),
			raidNid = getNextRaidNid(args.raidNid),
			realm = args.realm,
			zone = args.zone,
			size = args.size,
			difficulty = args.difficulty,
			startTime = serverTime,
			players = deepCopy(type(args.players) == "table" and args.players or {}),
			bossKills = deepCopy(type(args.bossKills) == "table" and args.bossKills or {}),
			loot = deepCopy(type(args.loot) == "table" and args.loot or {}),
			changes = {},
			attendance = deepCopy(type(args.attendance) == "table" and args.attendance or {}),
			nextPlayerNid = tonumber(args.nextPlayerNid) or 1,
			nextBossNid = tonumber(args.nextBossNid) or 1,
			nextLootNid = tonumber(args.nextLootNid) or 1,
		}
		local function advanceNextNid(collection, field, current)
			local nextNid = tonumber(current) or 1
			for _, entity in pairs(collection) do
				local nid = tonumber(type(entity) == "table" and entity[field])
				if nid and nid >= nextNid then
					nextNid = nid + 1
				end
			end
			return nextNid
		end
		initialState.nextPlayerNid = advanceNextNid(initialState.players, "playerNid", initialState.nextPlayerNid)
		initialState.nextBossNid = advanceNextNid(initialState.bossKills, "bossNid", initialState.nextBossNid)
		initialState.nextLootNid = advanceNextNid(initialState.loot, "lootNid", initialState.nextLootNid)
		local raidUid
		repeat
			raidUidCounter = raidUidCounter + 1
			raidUid = RaidEvents.CreateRaidUid(creatorKey, serverTime, raidUidCounter, sessionNonce)
			if not raidUid then
				return nil, "INVALID_RAID_UID_INPUT"
			end
		until not archive.raids[raidUid]

		local event = {
			raidUid = raidUid,
			authorityEpoch = authorityEpoch,
			sequence = 1,
			eventUid = RaidEvents.BuildEventUid(raidUid, authorityEpoch, 1),
			eventType = "RAID_CREATED",
			payload = { state = deepCopy(initialState) },
		}
		local candidateState, reason = RaidEvents.Apply({}, event)
		if not candidateState then
			return nil, reason
		end
		event.resultDigest = assert(RaidEvents.DigestState(candidateState))
		local candidate = {
			status = "active",
			authorityEpoch = authorityEpoch,
			sequence = 1,
			digest = event.resultDigest,
			checkpointSequence = 0,
			state = candidateState,
			events = { deepCopy(event) },
		}
		local valid, validationReason = getValidator():ValidateRecord(candidate)
		if not valid then
			return nil, validationReason
		end
		archive.raids[raidUid] = candidate
		appendOrder(archive, raidUid)
		archive.activeRaidUid = raidUid
		markRaidNidIndexDirty()
		TriggerEvent(RaidReplicationCommittedEvent, deepCopy(event))
		return candidate.state, self:GetIndexByUid(raidUid), raidUid
	end

	function module:GetRaidUid(raid)
		if type(raid) ~= "table" then
			return nil
		end
		local archive = requireValidArchive()
		if not archive then
			return nil
		end
		if type(archive.order) ~= "table" or type(archive.raids) ~= "table" then
			return nil
		end
		for i = 1, #archive.order do
			local raidUid = archive.order[i]
			local record = archive.raids[raidUid]
			if record and record.state == raid then
				return raidUid
			end
		end
		return nil
	end

	function module:GetStateDigest(raid)
		return type(raid) == "table" and RaidEvents.DigestState(raid) or nil
	end

	function module:CommitAuthoritativeEvent(raidUid, eventType, payload)
		local archive, archiveReason = requireValidArchive()
		if not archive then
			return nil, archiveReason
		end
		local authorized, authorityReason = requireLocalAuthority()
		if not authorized then
			return nil, authorityReason
		end
		local current = self:GetRecord(raidUid)
		if not current or current.status ~= "active" then
			return nil, "RAID_NOT_ACTIVE"
		end
		local currentValid, currentReason = requireCurrentStateDigest(current)
		if not currentValid then
			return nil, currentReason
		end
		local nextSequence = current.sequence + 1
		local event = {
			raidUid = raidUid,
			authorityEpoch = current.authorityEpoch,
			sequence = nextSequence,
			eventUid = RaidEvents.BuildEventUid(raidUid, current.authorityEpoch, nextSequence),
			eventType = eventType,
			payload = deepCopy(payload),
		}
		local candidateState, reason = RaidEvents.Apply(current.state, event)
		if not candidateState then
			return nil, reason
		end
		event.resultDigest = assert(RaidEvents.DigestState(candidateState))
		local candidate = deepCopy(current)
		candidate.state = candidateState
		candidate.sequence = event.sequence
		candidate.digest = event.resultDigest
		candidate.events[#candidate.events + 1] = deepCopy(event)
		checkpointIfRequired(candidate, 512)
		local valid, validationReason = getValidator():ValidateRecord(candidate)
		if not valid then
			return nil, validationReason
		end
		archive.raids[raidUid] = candidate
		TriggerEvent(RaidReplicationCommittedEvent, deepCopy(event))
		return deepCopy(event), candidate.state
	end

	function module:PromoteAuthority(raidUid, recoveredSequence)
		local archive, archiveReason = requireValidArchive()
		if not archive then
			return nil, archiveReason
		end
		local authorized, authorityReason = requireLocalAuthority("promote")
		if not authorized then
			return nil, authorityReason
		end
		local current = self:GetRecord(raidUid)
		if not current or current.status ~= "active" or recoveredSequence ~= current.sequence then
			return nil, "RECOVERED_SEQUENCE_MISMATCH"
		end
		local currentValid, currentReason = requireCurrentStateDigest(current)
		if not currentValid then
			return nil, currentReason
		end
		local candidate = deepCopy(current)
		candidate.authorityEpoch = candidate.authorityEpoch + 1
		candidate.checkpointSequence = recoveredSequence
		candidate.events = {}
		local valid, validationReason = getValidator():ValidateRecord(candidate)
		if not valid then
			return nil, validationReason
		end
		archive.raids[raidUid] = candidate
		return deepCopy(candidate)
	end

	function module:ApplyReplicaEvent(event)
		local archive, archiveReason = requireValidArchive()
		if not archive then
			return nil, archiveReason
		end
		local current = type(event) == "table" and self:GetRecord(event.raidUid) or nil
		if not current or current.status ~= "active" then
			return nil, "RAID_NOT_ACTIVE"
		end
		if event.authorityEpoch ~= current.authorityEpoch then
			return nil, "AUTHORITY_EPOCH_MISMATCH"
		end
		if event.sequence ~= current.sequence + 1 then
			return nil, "SEQUENCE_MISMATCH"
		end
		if event.eventUid ~= RaidEvents.BuildEventUid(event.raidUid, event.authorityEpoch, event.sequence) then
			return nil, "INVALID_EVENT_UID"
		end
		local currentValid, currentReason = requireCurrentStateDigest(current)
		if not currentValid then
			return nil, currentReason
		end
		local candidateState, reason = RaidEvents.Apply(current.state, event)
		if not candidateState then
			return nil, reason
		end
		local digest, digestReason = RaidEvents.DigestState(candidateState)
		if not digest then
			return nil, digestReason
		end
		if digest ~= event.resultDigest then
			return nil, "DIGEST_MISMATCH"
		end
		local candidate = deepCopy(current)
		candidate.state = candidateState
		candidate.sequence = event.sequence
		candidate.digest = digest
		if event.eventType == "RAID_CONCLUDED" then
			candidate.status = "complete"
			candidate.checkpointSequence = event.sequence
			candidate.events = {}
		else
			candidate.events[#candidate.events + 1] = deepCopy(event)
			checkpointIfRequired(candidate, 512)
		end
		local valid, validationReason = getValidator():ValidateRecord(candidate)
		if not valid then
			return nil, validationReason
		end
		archive.raids[event.raidUid] = candidate
		if event.eventType == "RAID_CONCLUDED" then
			archive.activeRaidUid = nil
		end
		return deepCopy(event), candidate.state
	end

	function module:GetEventRange(raidUid, afterSequence, maximumCount)
		local record = self:GetRecord(raidUid)
		local sequence = tonumber(afterSequence)
		if not record then
			return nil, "RAID_NOT_FOUND"
		end
		if not sequence or sequence < record.checkpointSequence or sequence > record.sequence then
			return nil, "SNAPSHOT_REQUIRED"
		end
		local out = {}
		local limit = tonumber(maximumCount)
		for i = 1, #record.events do
			local event = record.events[i]
			if event.sequence > sequence then
				if #out > 0 and event.sequence ~= out[#out].sequence + 1 then
					return nil, "SNAPSHOT_REQUIRED"
				end
				out[#out + 1] = deepCopy(event)
				if limit and #out >= limit then
					break
				end
			end
		end
		if #out > 0 and out[1].sequence ~= sequence + 1 then
			return nil, "SNAPSHOT_REQUIRED"
		end
		return out
	end

	function module:BuildSnapshot(raidUid)
		local record = self:GetRecord(raidUid)
		if not record then
			return nil, "RAID_NOT_FOUND"
		end
		local snapshot = deepCopy(record)
		snapshot.raidUid = record.sourceRaidUid or raidUid
		snapshot.sourceRaidUid = nil
		snapshot.conflictOfRaidUid = nil
		snapshot.checkpointSequence = snapshot.sequence
		snapshot.events = {}
		return snapshot
	end

	local function detachedSnapshotCandidate(snapshot, requiredStatus)
		if type(snapshot) ~= "table" or type(snapshot.raidUid) ~= "string" then
			return nil, nil, "INVALID_SNAPSHOT"
		end
		local candidate = deepCopy(snapshot)
		local raidUid = candidate.raidUid
		local validRaidUid, raidUidReason = getValidator():ValidateRaidUid(raidUid)
		if not validRaidUid then
			return nil, nil, raidUidReason
		end
		candidate.raidUid = nil
		candidate.sourceRaidUid = nil
		candidate.conflictOfRaidUid = nil
		if requiredStatus and candidate.status ~= requiredStatus then
			return nil, nil, "INVALID_RAID_STATUS"
		end
		local valid, reason = getValidator():ValidateRecord(candidate)
		if not valid then
			return nil, nil, reason
		end
		return raidUid, candidate
	end

	function module:ReplaceActiveFromSnapshot(snapshot)
		local archive, archiveReason = requireValidArchive()
		if not archive then
			return nil, archiveReason
		end
		local raidUid, candidate, reason = detachedSnapshotCandidate(snapshot, "active")
		if not candidate then
			return nil, reason
		end
		local activeRaidUid = archive.activeRaidUid
		local activeRecord = activeRaidUid and archive.raids[activeRaidUid] or nil
		if activeRecord and activeRecord.status == "active" and activeRaidUid ~= raidUid then
			return nil, "ACTIVE_RAID_EXISTS"
		end
		local existing = archive.raids[raidUid]
		if existing and existing.digest == candidate.digest then
			archive.activeRaidUid = raidUid
			return existing.state
		end
		if existing and existing.digest ~= candidate.digest then
			return nil, "RAID_CONFLICT"
		end
		archive.raids[raidUid] = candidate
		appendOrder(archive, raidUid)
		archive.activeRaidUid = raidUid
		markRaidNidIndexDirty()
		return candidate.state
	end

	function module:RepairActiveFromSnapshot(snapshot)
		local archive, archiveReason = requireValidArchive()
		if not archive then
			return nil, archiveReason
		end
		local raidUid, candidate, reason = detachedSnapshotCandidate(snapshot)
		if not candidate then
			return nil, reason
		end
		if candidate.status ~= "active" and candidate.status ~= "complete" then
			return nil, "INVALID_RAID_STATUS"
		end
		if archive.activeRaidUid ~= raidUid then
			return nil, "RAID_NOT_ACTIVE"
		end
		local current = archive.raids[raidUid]
		if not current or current.status ~= "active" then
			return nil, "RAID_NOT_ACTIVE"
		end
		if candidate.authorityEpoch ~= current.authorityEpoch then
			return nil, "AUTHORITY_EPOCH_MISMATCH"
		end
		if candidate.sequence < current.sequence then
			return nil, "STALE_SNAPSHOT"
		end
		if candidate.sequence == current.sequence then
			if candidate.digest ~= current.digest or candidate.status ~= current.status then
				return nil, "DIGEST_CONFLICT"
			end
			local currentDigest = RaidEvents.DigestState(current.state)
			if currentDigest == current.digest then
				return current.state
			end
		end
		archive.raids[raidUid] = candidate
		archive.activeRaidUid = candidate.status == "active" and raidUid or nil
		markRaidNidIndexDirty()
		return candidate.state
	end

	function module:ImportHistoricalSnapshot(snapshot)
		local archive, archiveReason = requireValidArchive()
		if not archive then
			return nil, archiveReason
		end
		local sourceRaidUid, candidate, reason = detachedSnapshotCandidate(snapshot, "complete")
		if not candidate then
			return nil, reason
		end
		local sourceExists = false
		for i = 1, #archive.order do
			local localRaidUid = archive.order[i]
			local existing = archive.raids[localRaidUid]
			if existing and (existing.sourceRaidUid or localRaidUid) == sourceRaidUid then
				sourceExists = true
				if existing.digest == candidate.digest then
					return "ALREADY_PRESENT", nil, i, localRaidUid
				end
			end
		end
		candidate.sourceRaidUid = sourceRaidUid
		local localRaidUid = sourceRaidUid
		local outcome = "IMPORTED"
		local outcomeReason
		if sourceExists or archive.raids[localRaidUid] ~= nil then
			outcome = "CONFLICT"
			outcomeReason = "RAID_CONFLICT"
			candidate.conflictOfRaidUid = sourceRaidUid
			local base = sourceRaidUid .. ":history:" .. candidate.digest
			local allocated
			for suffix = 0, 31 do
				local key = suffix == 0 and base or base .. ":" .. tostring(suffix)
				if archive.raids[key] == nil then
					localRaidUid = key
					allocated = true
					break
				end
			end
			if not allocated then
				return nil, "HISTORY_KEY_CAPACITY"
			end
		end
		local finalValid, finalReason = getValidator():ValidateRecord(candidate)
		if not finalValid then
			return nil, finalReason
		end
		archive.raids[localRaidUid] = candidate
		appendOrder(archive, localRaidUid)
		markRaidNidIndexDirty()
		local index = #archive.order
		return outcome, outcomeReason, index, localRaidUid
	end

	function module:ConcludeActiveRaid(raidUid, endTime)
		local archive, archiveReason = requireValidArchive()
		if not archive then
			return nil, archiveReason
		end
		local authorized, authorityReason = requireLocalAuthority()
		if not authorized then
			return nil, authorityReason
		end
		raidUid = raidUid or archive.activeRaidUid
		if raidUid ~= archive.activeRaidUid then
			return nil, "RAID_NOT_ACTIVE"
		end
		local current = raidUid and archive.raids[raidUid] or nil
		if not current or current.status ~= "active" then
			return nil, "RAID_NOT_ACTIVE"
		end
		local currentValid, currentReason = requireCurrentStateDigest(current)
		if not currentValid then
			return nil, currentReason
		end
		local nextSequence = current.sequence + 1
		local event = {
			raidUid = raidUid,
			authorityEpoch = current.authorityEpoch,
			sequence = nextSequence,
			eventUid = RaidEvents.BuildEventUid(raidUid, current.authorityEpoch, nextSequence),
			eventType = "RAID_CONCLUDED",
			payload = { endTime = endTime },
		}
		local candidateState, reason = RaidEvents.Apply(current.state, event)
		if not candidateState then
			return nil, reason
		end
		event.resultDigest = assert(RaidEvents.DigestState(candidateState))
		local candidate = deepCopy(current)
		candidate.status = "complete"
		candidate.state = candidateState
		candidate.sequence = nextSequence
		candidate.digest = event.resultDigest
		candidate.checkpointSequence = nextSequence
		candidate.events = {}
		local valid, validationReason = getValidator():ValidateRecord(candidate)
		if not valid then
			return nil, validationReason
		end
		archive.raids[raidUid] = candidate
		archive.activeRaidUid = nil
		TriggerEvent(RaidReplicationCommittedEvent, deepCopy(event))
		return deepCopy(event), candidate.state
	end

	function module:GetAllRaids()
		local archive = requireValidArchive()
		local states = {}
		if not archive or type(archive.order) ~= "table" or type(archive.raids) ~= "table" then
			return states
		end
		for i = 1, #archive.order do
			local record = archive.raids[archive.order[i]]
			states[i] = record and record.state or nil
		end
		return states
	end

	function module:GetRawRaids()
		local archive = ensureRaidsTable()
		local states = {}
		if type(archive.order) ~= "table" or type(archive.raids) ~= "table" then
			return states
		end
		for i = 1, #archive.order do
			local record = archive.raids[archive.order[i]]
			states[i] = record and record.state or nil
		end
		return states
	end

	function module:EnsureRaidByIndex(index)
		local idx = tonumber(index)
		if not idx or idx < 1 then
			return nil, nil
		end

		return self:GetStateByIndex(idx)
	end

	function module:EnsureRaidByNid(raidNid)
		local nid = tonumber(raidNid)
		if not nid then
			return nil, nil, nil
		end

		local archive = requireValidArchive()
		if not archive then
			return nil, nil, nid
		end
		if type(archive.order) ~= "table" or type(archive.raids) ~= "table" then
			return nil, nil, nid
		end
		local raidIdxByNid = ensureArchiveRaidNidIndex(archive)
		local idx = raidIdxByNid[nid]
		local record = idx and archive.raids[archive.order[idx]] or nil
		return record and record.state or nil, idx, nid
	end

	function module:GetRaidNidByIndex(index)
		local raid = self:EnsureRaidByIndex(index)
		return raid and tonumber(raid.raidNid) or nil
	end

	function module:GetRaidIndexByNid(raidNid)
		local _, idx = self:EnsureRaidByNid(raidNid)
		return idx
	end

	function module:NormalizeRaidRecord(raid, contextTag, raidIndex)
		if type(raid) ~= "table" then
			return nil
		end

		local schemaVersion = getSchemaVersion()
		local storedSchemaVersion = tonumber(raid.schemaVersion)
		if storedSchemaVersion and storedSchemaVersion > schemaVersion then
			return nil, "unsupported raid schema"
		end

		raid.players = (type(raid.players) == "table") and raid.players or {}
		raid.bossKills = (type(raid.bossKills) == "table") and raid.bossKills or {}
		raid.loot = (type(raid.loot) == "table") and raid.loot or {}
		raid.changes = (type(raid.changes) == "table") and raid.changes or {}
		raid.attendance = (type(raid.attendance) == "table") and raid.attendance or {}

		if not storedSchemaVersion or storedSchemaVersion < schemaVersion then
			raid.schemaVersion = schemaVersion
		else
			raid.schemaVersion = storedSchemaVersion
		end

		local allocatePlayerNid, getNextPlayerNid = createNidAllocator(raid.nextPlayerNid)
		local assignedByRef = {}

		local players = raid.players
		local validPlayerNids = {}
		for i = 1, #players do
			local player = players[i]
			if type(player) == "table" then
				local assigned = assignedByRef[player]
				if assigned then
					player.playerNid = assigned
				else
					local playerNid = allocatePlayerNid(player.playerNid)
					player.playerNid = playerNid
					assignedByRef[player] = playerNid
				end

				local countMS = tonumber(player.countMS) or 0
				if countMS < 0 then
					countMS = 0
				end
				player.countMS = countMS
				player.count = nil

				local countOs = tonumber(player.countOs) or 0
				if countOs < 0 then
					countOs = 0
				end
				player.countOs = countOs

				local countFree = tonumber(player.countFree) or 0
				if countFree < 0 then
					countFree = 0
				end
				player.countFree = countFree

				local countSR = tonumber(player.countSR) or 0
				if countSR < 0 then
					countSR = 0
				end
				player.countSR = countSR

				local playerNid = tonumber(player.playerNid)
				if playerNid and playerNid > 0 then
					validPlayerNids[playerNid] = true
				end
			end
		end

		local allocateBossNid, getNextBossNid = createNidAllocator(raid.nextBossNid)

		local bosses = raid.bossKills
		for i = 1, #bosses do
			local boss = bosses[i]
			if type(boss) == "table" then
				boss.bossNid = allocateBossNid(boss.bossNid)

				local attendees = {}
				local seen = {}
				if isBossFightRecord(boss) then
					local rawPlayers = boss.players
					if type(rawPlayers) == "table" then
						for j = 1, #rawPlayers do
							local rawPlayer = rawPlayers[j]
							local playerNid = tonumber(rawPlayer)
							if playerNid and playerNid > 0 and validPlayerNids[playerNid] and not seen[playerNid] then
								seen[playerNid] = true
								attendees[#attendees + 1] = playerNid
							end
						end
					end
					if rawPlayers == nil then
						local killTime = tonumber(boss.time) or 0
						for j = 1, #players do
							local player = players[j]
							local playerNid = player and tonumber(player.playerNid) or nil
							if playerNid and validPlayerNids[playerNid] and not seen[playerNid] then
								local include = true
								if killTime > 0 then
									local joinTime = tonumber(player.join)
									if joinTime and joinTime > killTime then
										include = false
									end
									local leaveTime = tonumber(player.leave)
									if leaveTime and leaveTime > 0 and leaveTime < killTime then
										include = false
									end
								end
								if include then
									seen[playerNid] = true
									attendees[#attendees + 1] = playerNid
								end
							end
						end
					end
				end
				boss.players = attendees
				boss.attendanceMask = nil
			end
		end

		local allocateLootNid, getNextLootNid = createNidAllocator(raid.nextLootNid)

		local lootRows = raid.loot
		for i = 1, #lootRows do
			local loot = lootRows[i]
			if type(loot) == "table" then
				loot.lootNid = allocateLootNid(loot.lootNid)

				local looterNid = tonumber(loot.looterNid)
				if looterNid and looterNid > 0 and validPlayerNids[looterNid] then
					loot.looterNid = looterNid
				else
					loot.looterNid = nil
				end
				loot.looter = nil
			end
		end

		raid.attendance = normalizeAttendance(raid.attendance, validPlayerNids)

		raid.nextPlayerNid = getNextPlayerNid()
		raid.nextBossNid = getNextBossNid()
		raid.nextLootNid = getNextLootNid()
		raid.raidNid = tonumber(raid.raidNid)

		normalizeRuntimeState(raid)
		return raid
	end

	function module:EnsureRaidRuntime(raid)
		if type(raid) ~= "table" then
			return nil
		end

		local runtime = runtimeByRaid[raid]
		local signature = buildRaidRuntimeSignature(raid)
		if isRuntimeIndexReady(runtime) and runtime.signature == signature then
			return runtime
		end
		return buildRuntimeIndexesForNormalizedRaid(raid)
	end

	local function inspectSnapshotsEqual(left, right)
		if type(left) ~= type(right) then
			return false
		end
		if type(left) ~= "table" then
			return left == right
		end
		for key, value in pairs(left) do
			if key ~= "inspectedAt" and not inspectSnapshotsEqual(value, right[key]) then
				return false
			end
		end
		for key, value in pairs(right) do
			if key ~= "inspectedAt" and not inspectSnapshotsEqual(value, left[key]) then
				return false
			end
		end
		return true
	end

	function module:CommitRaidInspectSnapshot(raid, playerNid, readySnapshot)
		if type(raid) ~= "table" or type(readySnapshot) ~= "table" or readySnapshot.status ~= "ready" then
			return nil, "invalid ready inspect snapshot"
		end
		local resolvedPlayerNid = tonumber(playerNid)
		if not resolvedPlayerNid or resolvedPlayerNid <= 0 then
			return nil, "invalid inspect player nid"
		end
		local player
		for i = 1, #(raid.players or {}) do
			if tonumber(raid.players[i] and raid.players[i].playerNid) == resolvedPlayerNid then
				player = raid.players[i]
				break
			end
		end
		if not player then
			return nil, "missing inspect player"
		end
		local previous = player.inspect
		if previous and inspectSnapshotsEqual(previous, readySnapshot) then
			return false
		end
		local candidate = deepCopy(player)
		candidate.inspect = deepCopy(readySnapshot)
		local raidUid = self:GetRaidUid(raid)
		if not raidUid then
			return nil, "RAID_NOT_ACTIVE"
		end
		local event = self:CommitAuthoritativeEvent(raidUid, "PLAYER_UPDATED", { player = candidate })
		return event and true or nil
	end

	function module:UpsertLootIndex(raid, loot, index)
		if type(raid) ~= "table" then
			return nil
		end

		local runtime = runtimeByRaid[raid]
		if not isRuntimeIndexReady(runtime) then
			return nil
		end

		local lootRows = raid.loot or {}
		local resolvedIndex = tonumber(index) or #lootRows
		local row = loot or lootRows[resolvedIndex]
		local lootNid = tonumber(row and row.lootNid)
		if not lootNid or resolvedIndex < 1 then
			return nil
		end

		if not indexLootRuntimeRow(runtime, row, resolvedIndex, true) then
			return nil
		end
		refreshRuntimeSignature(raid, runtime)
		return runtime
	end

	function module:StripRuntime(raid)
		if type(raid) ~= "table" then
			return
		end
		stripRuntimeState(raid)
	end

	function module:NormalizeAllRaids()
		local archive = ensureRaidsTable()
		markRaidNidIndexDirty()
		rebuildArchiveRaidNidIndex(archive)
		return archive
	end

	function module:PrepareRaidForSave(raid, raidIndex)
		local normalizeError
		raid, normalizeError = self:NormalizeRaidRecord(raid, "save", raidIndex)
		if not raid then
			return nil, normalizeError
		end

		self:StripRuntime(raid)
		compactInspectForPersistence(raid)

		return raid
	end

	function module:PrepareAllRaidsForSave()
		local archive = ensureRaidsTable()
		if type(archive.order) ~= "table" or type(archive.raids) ~= "table" then
			return nil, "INVALID_RAID_ARCHIVE"
		end
		local schemaVersion = getSchemaVersion()
		for i = 1, #archive.order do
			local record = archive.raids[archive.order[i]]
			local state = record and record.state or nil
			local storedSchemaVersion = type(state) == "table" and tonumber(state.schemaVersion) or nil
			if storedSchemaVersion and storedSchemaVersion > schemaVersion then
				return nil, "unsupported raid schema", i
			end
		end
		return archive
	end

	local function restoreCapturedRaids(snapshot)
		if type(snapshot) ~= "table" or type(snapshot.raids) ~= "table" then
			return false
		end
		local restored = deepCopy(snapshot.raids)
		local archive = ensureRaidsTable()
		for key in pairs(archive) do
			archive[key] = nil
		end
		for key, value in pairs(restored) do
			archive[key] = value
		end
		storeState.nextRaidNid = snapshot.nextRaidNid
		markRaidNidIndexDirty()
		rebuildRaidNidIndex()
		return true
	end

	local function copyRaidHistoryValue(value, seen)
		if type(value) ~= "table" then
			return value
		end
		seen = seen or {}
		if seen[value] then
			return seen[value]
		end
		local copy = {}
		seen[value] = copy
		for key, item in pairs(value) do
			copy[copyRaidHistoryValue(key, seen)] = copyRaidHistoryValue(item, seen)
		end
		return copy
	end

	function module:CaptureRaidHistoryState()
		return { raids = copyRaidHistoryValue(ensureRaidsTable()), nextRaidNid = storeState.nextRaidNid }
	end

	function module:RestoreRaidHistoryState(snapshot)
		local validArchive, reason = requireValidArchive()
		if not validArchive then
			return false, reason
		end
		if type(snapshot) == "table" and type(snapshot.raids) == "table" then
			local validSnapshot, snapshotReason = getValidator():ValidateArchive(snapshot.raids)
			if not validSnapshot then
				return false, snapshotReason
			end
		end
		return restoreCapturedRaids(snapshot)
	end

	local function isPositiveInteger(value)
		return type(value) == "number" and value > 0 and value == math.floor(value)
	end

	local function validateRaidHistory(raid)
		local validator = Database.GetRaidValidator()
		local report = validator:GetRaidRecordValidation(raid, 0, Database.GetRaidSchemaVersion())
		if type(report) ~= "table" or type(report.details) ~= "table" then
			return false, "INVALID_RAID"
		end
		local details = report.details
		local detailCount, maximumDetailIndex = 0, 0
		for key in pairs(details) do
			if not isPositiveInteger(key) then
				return false, "INVALID_RAID"
			end
			detailCount = detailCount + 1
			if key > maximumDetailIndex then
				maximumDetailIndex = key
			end
		end
		if detailCount ~= maximumDetailIndex then
			return false, "INVALID_RAID"
		end
		for i = 1, maximumDetailIndex do
			local detail = details[i]
			if type(detail) ~= "table" or type(detail.level) ~= "string" or type(detail.code) ~= "string" then
				return false, "INVALID_RAID"
			end
			if detail.level == "E" then
				return false, detail.code
			end
		end
		return true
	end

	function module:StageRaidHistoryMutation(raid)
		if type(raid) ~= "table" then
			return nil
		end
		local stagedRaid = copyRaidHistoryValue(raid)
		stagedMutationBase[stagedRaid] = { raid = raid, digest = self:GetStateDigest(raid) }
		return stagedRaid
	end

	function module:CommitRaidHistoryMutation(raid, stagedRaid, opts, verify)
		-- A successful commit replaces nested rows. Callers must re-resolve row aliases from the canonical raid.
		opts = opts or {}
		local validArchive, archiveReason = requireValidArchive()
		if not validArchive then
			return false, archiveReason
		end
		if type(raid) ~= "table" or type(stagedRaid) ~= "table" then
			return false, "INVALID_RAID"
		end
		if not isPositiveInteger(stagedRaid.raidNid) then
			return false, "INVALID_RAID_NID"
		end
		if not isPositiveInteger(raid.raidNid) or raid.raidNid ~= stagedRaid.raidNid then
			return false, "INVALID_RAID"
		end
		local base = stagedMutationBase[stagedRaid]
		if not base or base.raid ~= raid or self:GetStateDigest(raid) ~= base.digest then
			return false, "CONFLICT"
		end
		local lootNid = opts.lootNid
		if lootNid ~= nil and not isPositiveInteger(lootNid) then
			return false, "INVALID_LOOT_SCOPE"
		end
		local raidUid = self:GetRaidUid(raid)
		local record = raidUid and self:GetRecord(raidUid) or nil
		if record and record.status == "active" then
			return false, "ACTIVE_RAID_REQUIRES_EVENT"
		end
		if not record then
			return false, "CONFLICT"
		end
		local valid, validationError = validateRaidHistory(stagedRaid)
		if not valid then
			return false, validationError
		end
		if type(verify) == "function" then
			local verifyOk, verified, verifyError = pcall(verify, stagedRaid)
			if not verifyOk then
				return false, "VERIFY_FAILED"
			end
			if verified ~= true then
				return false, verifyError or "VERIFY_FAILED"
			end
		end
		if lootNid then
			local matches = 0
			for i = 1, #(stagedRaid.loot or {}) do
				if stagedRaid.loot[i].lootNid == lootNid then
					matches = matches + 1
				end
			end
			if matches ~= 1 then
				return false, "INVALID_LOOT_SCOPE"
			end
		end
		local candidate = deepCopy(record)
		candidate.state = copyRaidHistoryValue(stagedRaid)
		candidate.digest = RaidEvents.DigestState(candidate.state)
		local recordValid, recordReason = getValidator():ValidateRecord(candidate)
		if not recordValid then
			return false, recordReason
		end
		self:EnsureArchive().raids[raidUid] = candidate
		markRaidNidIndexDirty()
		stagedMutationBase[stagedRaid] = nil
		return true, candidate.state
	end

	-- Completed-history edits use digest conflicts. Active attendance writes use
	-- ATTENDANCE_UPDATED events instead of this detached history path.
	function module:CommitAttendanceMutation(raid, stagedRaid, reason)
		return self:CommitRaidHistoryMutation(raid, stagedRaid, { reason = reason or "attendance" })
	end

	function module:CommitRaidHistoryCleanup(plan, currentRaidIdentity)
		local root, rootReason = requireValidArchive()
		if not root then
			return nil, rootReason
		end
		if type(plan) ~= "table" or plan.protectedArchiveKey ~= currentRaidIdentity then
			return nil, "CONFLICT"
		end
		if root.activeRaidUid ~= currentRaidIdentity then
			return nil, "CONFLICT"
		end
		local raidCandidates = type(plan.raidCandidates) == "table" and plan.raidCandidates or {}
		local lootCandidates = type(plan.lootCandidates) == "table" and plan.lootCandidates or {}
		if #raidCandidates == 0 and #lootCandidates == 0 then
			return {
				raidsRemoved = 0,
				lootRemoved = 0,
				removedRaidNids = {},
				affectedRaidNids = {},
				removedArchiveKeys = {},
				affectedArchiveKeys = {},
			}
		end
		local candidate = copyRaidHistoryValue(root)
		local deleteSet, lootDeleteSet = {}, {}
		for i = 1, #raidCandidates do
			local entry = raidCandidates[i]
			local archiveKey = type(entry) == "table" and entry.archiveKey or nil
			local record = archiveKey and candidate.raids[archiveKey] or nil
			if
				type(archiveKey) ~= "string"
				or archiveKey == candidate.activeRaidUid
				or not record
				or record.digest ~= entry.baseDigest
				or deleteSet[archiveKey]
			then
				return nil, "CONFLICT"
			end
			deleteSet[archiveKey] = true
		end
		for i = 1, #lootCandidates do
			local entry = lootCandidates[i]
			local archiveKey = type(entry) == "table" and entry.archiveKey or nil
			local record = archiveKey and candidate.raids[archiveKey] or nil
			local loot
			if record and record.digest == entry.baseDigest and not deleteSet[archiveKey] then
				for lootIndex = 1, #(record.state.loot or {}) do
					local row = record.state.loot[lootIndex]
					if tonumber(row and row.lootNid) == tonumber(entry.lootNid) then
						if loot then
							return nil, "CONFLICT"
						end
						loot = row
					end
				end
			end
			if
				not loot
				or tonumber(loot.itemId) ~= entry.itemId
				or loot.itemLink ~= entry.itemLink
				or tonumber(loot.bossNid) ~= entry.bossNid
			then
				return nil, "CONFLICT"
			end
			lootDeleteSet[archiveKey] = lootDeleteSet[archiveKey] or {}
			if lootDeleteSet[archiveKey][entry.lootNid] then
				return nil, "CONFLICT"
			end
			lootDeleteSet[archiveKey][entry.lootNid] = true
		end
		local removedRaidNids, affectedRaidNids = {}, {}
		local removedArchiveKeys, affectedArchiveKeys = {}, {}
		local raidsRemoved, lootRemoved = 0, 0
		for orderIndex = #candidate.order, 1, -1 do
			local archiveKey = candidate.order[orderIndex]
			local record = candidate.raids[archiveKey]
			if deleteSet[archiveKey] then
				candidate.raids[archiveKey] = nil
				tremove(candidate.order, orderIndex)
				raidsRemoved = raidsRemoved + 1
				removedArchiveKeys[#removedArchiveKeys + 1] = archiveKey
				removedRaidNids[#removedRaidNids + 1] = tonumber(record.state.raidNid)
			elseif lootDeleteSet[archiveKey] then
				for lootIndex = #record.state.loot, 1, -1 do
					if lootDeleteSet[archiveKey][tonumber(record.state.loot[lootIndex].lootNid)] then
						tremove(record.state.loot, lootIndex)
						lootRemoved = lootRemoved + 1
					end
				end
				record.digest = RaidEvents.DigestState(record.state)
				local recordValid, recordReason = getValidator():ValidateRecord(record)
				if not recordValid then
					return nil, recordReason
				end
				affectedArchiveKeys[#affectedArchiveKeys + 1] = archiveKey
				affectedRaidNids[#affectedRaidNids + 1] = tonumber(record.state.raidNid)
			end
		end
		local archiveValid, archiveReason = getValidator():ValidateArchive(candidate)
		if not archiveValid then
			return nil, archiveReason
		end
		SavedVariables.ReplaceRaids(candidate)
		validatedArchive = candidate
		markRaidNidIndexDirty()
		return {
			raidsRemoved = raidsRemoved,
			lootRemoved = lootRemoved,
			removedRaidNids = removedRaidNids,
			affectedRaidNids = affectedRaidNids,
			removedArchiveKeys = removedArchiveKeys,
			affectedArchiveKeys = affectedArchiveKeys,
		}
	end

	local function resolveDeletableArchiveKeyByRaidNid(archive, raidNid)
		local nid = tonumber(raidNid)
		if not nid or nid <= 0 then
			return nil
		end
		local resolvedKey, resolvedIndex
		for i = 1, #archive.order do
			local archiveKey = archive.order[i]
			local record = archive.raids[archiveKey]
			if tonumber(record and record.state and record.state.raidNid) == nid then
				if archiveKey == archive.activeRaidUid or record.status == "active" then
					return nil, nil, "ACTIVE_RAID_PROTECTED"
				end
				if resolvedKey then
					return nil, nil, "AMBIGUOUS_RAID_NID"
				end
				resolvedKey = archiveKey
				resolvedIndex = i
			end
		end
		return resolvedKey, resolvedIndex
	end

	function module:DeleteRaid(raidNid)
		local archive, archiveReason = requireValidArchive()
		if not archive then
			return false, nil, archiveReason
		end
		local archiveKey, _, resolveReason = resolveDeletableArchiveKeyByRaidNid(archive, raidNid)
		if not archiveKey then
			return false, nil, resolveReason
		end
		return self:DeleteRaidByArchiveKey(archiveKey)
	end

	function module:DeleteRaidByArchiveKey(archiveKey)
		local archive, reason = requireValidArchive()
		if not archive then
			return false, nil, reason
		end
		local index = self:GetIndexByArchiveKey(archiveKey)
		if not index or archive.activeRaidUid == archiveKey then
			return false, index
		end
		local candidate = copyRaidHistoryValue(archive)
		candidate.raids[archiveKey] = nil
		tremove(candidate.order, index)
		local valid, validationReason = getValidator():ValidateArchive(candidate)
		if not valid then
			return false, nil, validationReason
		end
		SavedVariables.ReplaceRaids(candidate)
		validatedArchive = candidate
		markRaidNidIndexDirty()
		return true, index
	end

	function module:DeleteRaidsByArchiveKey(archiveKeys, protectedArchiveKey)
		if type(archiveKeys) ~= "table" then
			return 0, {}
		end
		local archive, reason = requireValidArchive()
		if not archive then
			return 0, {}, reason
		end
		local deleteSet = {}
		for i = 1, #archiveKeys do
			local archiveKey = archiveKeys[i]
			if type(archiveKey) == "string" and archiveKey ~= protectedArchiveKey then
				deleteSet[archiveKey] = true
			end
		end
		local candidate = copyRaidHistoryValue(archive)
		local removedKeys = {}
		for i = #candidate.order, 1, -1 do
			local archiveKey = candidate.order[i]
			if deleteSet[archiveKey] and archiveKey ~= candidate.activeRaidUid then
				candidate.raids[archiveKey] = nil
				tremove(candidate.order, i)
				removedKeys[#removedKeys + 1] = archiveKey
			end
		end
		local valid, validationReason = getValidator():ValidateArchive(candidate)
		if not valid then
			return 0, {}, validationReason
		end
		if #removedKeys > 0 then
			SavedVariables.ReplaceRaids(candidate)
			validatedArchive = candidate
			markRaidNidIndexDirty()
		end
		return #removedKeys, removedKeys
	end

	function module:DeleteLootByArchiveKey(archiveKey, lootNids)
		local archive, reason = requireValidArchive()
		if not archive then
			return 0, reason
		end
		local record = archive.raids[archiveKey]
		if not record or type(lootNids) ~= "table" then
			return 0
		end
		if archive.activeRaidUid == archiveKey then
			return self:DeleteLootByNid(record.state.raidNid, lootNids, "loot_delete")
		end
		local deleteSet = {}
		for i = 1, #lootNids do
			local lootNid = tonumber(lootNids[i])
			if lootNid and lootNid > 0 then
				deleteSet[lootNid] = true
			end
		end
		local candidate = copyRaidHistoryValue(record)
		local removed = 0
		for i = #(candidate.state.loot or {}), 1, -1 do
			if deleteSet[tonumber(candidate.state.loot[i].lootNid)] then
				tremove(candidate.state.loot, i)
				removed = removed + 1
			end
		end
		if removed == 0 then
			return 0
		end
		candidate.digest = RaidEvents.DigestState(candidate.state)
		local valid, validationReason = getValidator():ValidateRecord(candidate)
		if not valid then
			return 0, validationReason
		end
		archive.raids[archiveKey] = candidate
		return removed
	end

	function module:DeleteRaidsByNid(raidNids, opts)
		if type(raidNids) ~= "table" then
			return 0, {}
		end
		local requestedNids = {}
		local seenNids = {}
		local protectedRaidNid = tonumber(type(opts) == "table" and opts.protectedRaidNid)
		for i = 1, #raidNids do
			local raidNid = tonumber(raidNids[i])
			if raidNid and raidNid > 0 and raidNid ~= protectedRaidNid and not seenNids[raidNid] then
				seenNids[raidNid] = true
				requestedNids[#requestedNids + 1] = raidNid
			end
		end
		local archive, archiveReason = requireValidArchive()
		if not archive then
			return 0, {}, archiveReason
		end
		local archiveKeys = {}
		local raidNidByArchiveKey = {}
		for i = 1, #requestedNids do
			local raidNid = requestedNids[i]
			local archiveKey, _, resolveReason = resolveDeletableArchiveKeyByRaidNid(archive, raidNid)
			if resolveReason then
				return 0, {}, resolveReason
			end
			if archiveKey then
				archiveKeys[#archiveKeys + 1] = archiveKey
				raidNidByArchiveKey[archiveKey] = raidNid
			end
		end
		local removed, removedKeys, deleteReason = self:DeleteRaidsByArchiveKey(archiveKeys, archive.activeRaidUid)
		local removedRaidNids = {}
		for i = 1, #removedKeys do
			removedRaidNids[i] = raidNidByArchiveKey[removedKeys[i]]
		end
		return removed, removedRaidNids, deleteReason
	end

	function module:DeleteLootByNid(raidNid, lootNids, reason)
		local archive, archiveReason = requireValidArchive()
		if not archive then
			return 0, archiveReason
		end
		local raid = self:EnsureRaidByNid(raidNid)
		if not (raid and type(raid.loot) == "table" and type(lootNids) == "table") then
			return 0
		end
		local deleteSet, ordered = {}, {}
		for i = 1, #lootNids do
			local lootNid = tonumber(lootNids[i])
			if lootNid and lootNid > 0 then
				deleteSet[lootNid] = true
			end
		end
		for lootNid in pairs(deleteSet) do
			ordered[#ordered + 1] = lootNid
		end
		table.sort(ordered)
		local raidUid = self:GetRaidUid(raid)
		if not raidUid then
			return 0
		end
		local removed = 0
		for i = 1, #ordered do
			local event = self:CommitAuthoritativeEvent(raidUid, "LOOT_DELETED", { lootNid = ordered[i] })
			if event then
				removed = removed + 1
			end
		end
		return removed
	end

	function Database.EnsureRaidSchema(raid)
		-- Canonical archive states may only change through store commits. Normalizing
		-- an exposed state alias here would invalidate its persisted digest.
		if module:GetRaidUid(raid) then
			return raid
		end
		return module:NormalizeRaidRecord(raid)
	end

	function Database.EnsureRaidByIndex(raidNum)
		local id = tonumber(raidNum)
		if not id then
			return nil, nil
		end
		return module:EnsureRaidByIndex(id)
	end

	function Database.EnsureRaidByNid(raidNid)
		local nid = tonumber(raidNid)
		if not nid then
			return nil, nil, nil
		end
		return module:EnsureRaidByNid(nid)
	end

	function Database.GetRaidNidByIndex(raidNum)
		return module:GetRaidNidByIndex(raidNum)
	end

	function Database.GetRaidIndexByNid(raidNid)
		return module:GetRaidIndexByNid(raidNid)
	end

	function Database.StripRuntimeRaidCaches(raid)
		module:StripRuntime(raid)
	end
end
