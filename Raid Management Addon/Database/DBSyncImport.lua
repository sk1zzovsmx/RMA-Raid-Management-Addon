-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: direct addon namespace bindings
-- exports: addon.Database.Syncer._Import
-- events: none

local addon = select(2, ...)
local DB = addon.DB
local Database = addon.Database
local Strings = addon.Strings
local Time = addon.Time
local coreState = addon.State

local type = type
local tonumber, tostring = tonumber, tostring
local max = math.max

local NormalizeName = Strings.NormalizeName
local NormalizeLower = Strings.NormalizeLower

-- ----- Internal state ----- --

DB.Syncer = DB.Syncer or {}
local module = DB.Syncer
local SnapshotPayload = assert(module._Payload, "DBSync payload helpers are not initialized")
module._Import = module._Import or {}
local SnapshotImport = module._Import

-- ----- Private helpers ----- --

local function buildNidIndex(list, nidField)
	local index = {}
	for i = 1, #list do
		local row = list[i]
		local nid = tonumber(row and row[nidField])
		if nid and nid > 0 then
			index[nid] = i
		end
	end
	return index
end

local function upsertByNid(list, index, nid)
	local idx = index[nid]
	if idx then
		return list[idx], idx
	end
	local row = {}
	list[#list + 1] = row
	idx = #list
	index[nid] = idx
	return row, idx
end

local function copyUniquePlayerNids(values, playerNidByName, validPlayerNids)
	local out = {}
	local seen = {}
	if type(values) ~= "table" then
		return out
	end
	for i = 1, #values do
		local raw = values[i]
		local playerNid = tonumber(raw)
		if not playerNid and type(raw) == "string" then
			playerNid = playerNidByName and playerNidByName[NormalizeLower(raw, true)] or nil
		end
		if playerNid and playerNid > 0 then
			if (not validPlayerNids) or validPlayerNids[playerNid] then
				if not seen[playerNid] then
					seen[playerNid] = true
					out[#out + 1] = playerNid
				end
			end
		end
	end
	return out
end

local function raidMatchesSignature(raid, signature)
	if not (raid and signature) then
		return false
	end

	local raidZone = tostring(raid.zone or "")
	local sigZone = tostring(signature.zone or "")
	if raidZone ~= sigZone then
		return false
	end

	local raidSize = tonumber(raid.size) or 0
	local sigSize = tonumber(signature.size) or 0
	if raidSize ~= sigSize then
		return false
	end

	local raidDiff = tonumber(raid.difficulty) or 0
	local sigDiff = tonumber(signature.diff) or 0
	if raidDiff ~= sigDiff then
		return false
	end

	return true
end

local function applySnapshotHeaderToRaid(raid, header)
	raid.schemaVersion = tonumber(header.schemaVersion) or tonumber(raid.schemaVersion) or 1
	raid.zone = header.zone or raid.zone
	raid.size = tonumber(header.size) or tonumber(raid.size)
	raid.difficulty = tonumber(header.difficulty) or tonumber(raid.difficulty)
	raid.realm = header.realm or raid.realm

	local startTime = tonumber(header.startTime)
	local endTime = tonumber(header.endTime)
	if startTime and startTime > 0 then
		raid.startTime = startTime
	end
	if endTime and endTime > 0 then
		raid.endTime = endTime
	end
end

local function applySnapshotNextNids(raid, header)
	raid.nextPlayerNid = max(tonumber(raid.nextPlayerNid) or 1, tonumber(header.nextPlayerNid) or 1)
	raid.nextBossNid = max(tonumber(raid.nextBossNid) or 1, tonumber(header.nextBossNid) or 1)
	raid.nextLootNid = max(tonumber(raid.nextLootNid) or 1, tonumber(header.nextLootNid) or 1)
end

local function finalizeSnapshotRaid(raid)
	Database.StripRuntimeRaidCaches(raid)
	Database.EnsureRaidSchema(raid)
	return raid
end

local function getSnapshotImportRaidStore()
	return Database.GetRaidStore()
end

local function createRaidFromSnapshotHeader(raidStore, header)
	return raidStore:CreateRaidRecord({
		realm = header.realm,
		zone = header.zone,
		size = tonumber(header.size),
		difficulty = tonumber(header.difficulty),
		startTime = tonumber(header.startTime) or Time.GetCurrentTime(),
		endTime = (tonumber(header.endTime) or 0) > 0 and tonumber(header.endTime) or nil,
	})
end

-- ----- Public methods ----- --

function SnapshotImport.BuildSignatureFromRaid(raid)
	return {
		zone = tostring(raid and raid.zone or ""),
		size = tonumber(raid and raid.size) or 0,
		diff = tonumber(raid and raid.difficulty) or 0,
	}
end

function SnapshotImport.RaidMatchesSignature(raid, signature)
	return raidMatchesSignature(raid, signature)
end

function SnapshotImport.RaidMatchesSnapshotHeader(raid, header)
	local signature = {
		zone = header and header.zone,
		size = header and header.size,
		diff = header and header.difficulty,
	}
	return raidMatchesSignature(raid, signature)
end

function SnapshotImport.GetCurrentRaidRecord()
	local currentId = Database.GetCurrentRaid()
	if not currentId then
		return nil, nil
	end
	return Database.EnsureRaidByIndex(currentId), currentId
end

function SnapshotImport.ResolveRaidByReference(raidRef, allowFallback)
	local n = tonumber(raidRef)
	if n and n > 0 then
		local byId, byIdIndex = Database.EnsureRaidByIndex(n)
		if byId then
			return byId, byIdIndex
		end

		local byNid, byNidIndex = Database.EnsureRaidByNid(n)
		if byNid then
			return byNid, byNidIndex
		end

		return nil, nil
	end

	if not allowFallback then
		return nil, nil
	end

	local selectedRaid = coreState and coreState.selectedRaid
	if selectedRaid then
		local raid = Database.EnsureRaidByIndex(selectedRaid)
		if raid then
			return raid, selectedRaid
		end
	end

	local currentRaid = Database.GetCurrentRaid()
	if currentRaid then
		return Database.EnsureRaidByIndex(currentRaid), currentRaid
	end

	return nil, nil
end

function SnapshotImport.ApplySnapshotToRaid(raid, snapshot, updateMeta, allowExternalRaidNid)
	if not (raid and snapshot and snapshot.header) then
		return nil
	end
	local header = snapshot.header
	if not allowExternalRaidNid then
		local destinationRaidNid = raid.raidNid
		if type(destinationRaidNid) ~= "number" or destinationRaidNid ~= math.floor(destinationRaidNid)
			or destinationRaidNid < 1 or destinationRaidNid > 2147483647 then return nil, "invalid_destination_raid" end
	end
	local raidStore = Database.GetRaidStore()
	local expectedRaidNid = allowExternalRaidNid and header.raidNid or raid.raidNid
	local valid, reason = SnapshotPayload.ValidateSnapshot(snapshot, raidStore:GetRaidSyncRevision(raid), expectedRaidNid)
	if not valid then return nil, reason end
	local canonicalRaid = raid
	if not allowExternalRaidNid then
		raid = raidStore:StageRaidHistoryMutation(canonicalRaid)
		if not raid then return nil, "STAGE_FAILED" end
	end

	if updateMeta then
		applySnapshotHeaderToRaid(raid, header)
	end

	raid.players = raid.players or {}
	local playerIdx = buildNidIndex(raid.players, "playerNid")
	for i = 1, #snapshot.players do
		local src = snapshot.players[i]
		local nid = tonumber(src and src.playerNid)
		if nid and nid > 0 then
			local dst = upsertByNid(raid.players, playerIdx, nid)
			local count = tonumber(src.count) or 0
			if count < 0 then
				count = 0
			end
			dst.playerNid = nid
			dst.name = NormalizeName(src.name, true) or src.name or dst.name
			dst.rank = tonumber(src.rank) or 0
			dst.subgroup = tonumber(src.subgroup) or 1
			dst.class = (src.class and src.class ~= "") and src.class or "UNKNOWN"
			dst.join = tonumber(src.join) or dst.join
			local leave = tonumber(src.leave) or 0
			dst.leave = (leave > 0) and leave or nil
			dst.countMS = count
		end
	end

	local _, playerNidByName, validPlayerNids = SnapshotPayload.BuildPlayerNameMaps(raid.players)

	if #(snapshot.attendance or {}) > 0 then
		local attendance = {}
		local attendanceByNid = {}
		for i = 1, #snapshot.attendance do
			local src = snapshot.attendance[i]
			local playerNid = tonumber(src and src.playerNid) or 0
			local startTime = tonumber(src and src.startTime) or 0
			if playerNid > 0 and validPlayerNids[playerNid] and startTime > 0 then
				local entry = attendanceByNid[playerNid]
				if not entry then
					entry = {
						playerNid = playerNid,
						segments = {},
					}
					attendanceByNid[playerNid] = entry
					attendance[#attendance + 1] = entry
				end

				local segment = {
					startTime = startTime,
				}
				local endTime = tonumber(src.endTime) or 0
				if endTime > startTime then
					segment.endTime = endTime
				end
				local subgroup = tonumber(src.subgroup) or 1
				if subgroup > 1 then
					segment.subgroup = subgroup
				end
				if src.online == false then
					segment.online = false
				end
				entry.segments[#entry.segments + 1] = segment
			end
		end
		raid.attendance = attendance
	end

	raid.bossKills = raid.bossKills or {}
	local bossIdx = buildNidIndex(raid.bossKills, "bossNid")
	for i = 1, #snapshot.bosses do
		local src = snapshot.bosses[i]
		local nid = tonumber(src and src.bossNid)
		if nid and nid > 0 then
			local dst = upsertByNid(raid.bossKills, bossIdx, nid)
			dst.bossNid = nid
			dst.name = src.name or dst.name
			dst.mode = (src.mode == "h") and "h" or "n"
			dst.difficulty = tonumber(src.difficulty) or dst.difficulty
			dst.time = tonumber(src.time) or dst.time
			if src.hash and src.hash ~= "" then
				dst.hash = src.hash
			end
			dst.players = copyUniquePlayerNids(src.players, playerNidByName, validPlayerNids)
		end
	end

	raid.loot = raid.loot or {}
	local lootIdx = buildNidIndex(raid.loot, "lootNid")
	for i = 1, #snapshot.loot do
		local src = snapshot.loot[i]
		local nid = tonumber(src and src.lootNid)
		if nid and nid > 0 then
			local dst = upsertByNid(raid.loot, lootIdx, nid)
			local count = tonumber(src.itemCount) or 1
			if count < 1 then
				count = 1
			end
			dst.lootNid = nid
			dst.itemId = tonumber(src.itemId) or dst.itemId
			dst.itemName = src.itemName or dst.itemName
			dst.itemString = src.itemString or dst.itemString
			dst.itemLink = src.itemLink or dst.itemLink
			dst.itemRarity = tonumber(src.itemRarity) or dst.itemRarity
			if src.itemTexture and src.itemTexture ~= "" then
				dst.itemTexture = src.itemTexture
			end
			dst.itemCount = count
			local looterNid = tonumber(src.looterNid)
			if not looterNid and type(src.looterName) == "string" then
				looterNid = playerNidByName[NormalizeLower(src.looterName, true)]
			end
			if looterNid and looterNid > 0 and validPlayerNids[looterNid] then
				dst.looterNid = looterNid
			end
			dst.looter = nil
			dst.rollType = tonumber(src.rollType) or 0
			dst.rollValue = tonumber(src.rollValue) or 0
			dst.bossNid = tonumber(src.bossNid) or 0
			dst.time = tonumber(src.time) or dst.time
		end
	end

	applySnapshotNextNids(raid, header)
	finalizeSnapshotRaid(raid)
	local targetRevision = tonumber(header.revision) or 0
	local allowRevisionZero = tonumber(header.protocolVersion) == 1 and targetRevision == 0
	if allowExternalRaidNid then
		return raid
	end
	local committed, committedRaid =
		raidStore:CommitRaidHistoryImport(canonicalRaid, raid, targetRevision, "snapshot", nil, allowRevisionZero)
	if not committed then return nil, committedRaid end
	return committedRaid
end

function SnapshotImport.ReplaceRaidFromAuthority(raid, snapshot)
	if not (raid and snapshot and snapshot.header) then
		return nil, "invalid_snapshot"
	end
	local localRaidNid = raid.raidNid
	if type(localRaidNid) ~= "number" or localRaidNid <= 0 then
		return nil, "invalid_destination_raid"
	end

	local header = snapshot.header
	local raidStore = getSnapshotImportRaidStore()
	local valid, reason = SnapshotPayload.ValidateSnapshot(snapshot, 0, header.raidNid)
	if not valid then return nil, reason end

	local staged = raidStore:StageRaidHistoryMutation(raid)
	if not staged then return nil, "STAGE_FAILED" end
	staged.raidNid = localRaidNid
	staged.schemaVersion = header.schemaVersion
	staged.realm = header.realm
	staged.zone = header.zone
	staged.size = header.size
	staged.difficulty = header.difficulty
	staged.startTime = header.startTime
	staged.endTime = header.endTime > 0 and header.endTime or nil
	staged.players = {}
	staged.attendance = {}
	staged.bossKills = {}
	staged.loot = {}
	staged.inspect = nil

	for i = 1, #snapshot.players do
		local src = snapshot.players[i]
		local leave = tonumber(src.leave) or 0
		staged.players[i] = {
			playerNid = src.playerNid,
			name = NormalizeName(src.name, true) or src.name,
			rank = src.rank,
			subgroup = src.subgroup,
			class = src.class,
			join = src.join,
			leave = leave > 0 and leave or nil,
			countMS = src.count,
		}
	end

	local _, playerNidByName, validPlayerNids = SnapshotPayload.BuildPlayerNameMaps(staged.players)
	local attendanceByNid = {}
	for i = 1, #snapshot.attendance do
		local src = snapshot.attendance[i]
		local playerNid = src.playerNid
		local entry = attendanceByNid[playerNid]
		if not entry then
			entry = { playerNid = playerNid, segments = {} }
			attendanceByNid[playerNid] = entry
			staged.attendance[#staged.attendance + 1] = entry
		end
		local segment = { startTime = src.startTime }
		if src.endTime > src.startTime then segment.endTime = src.endTime end
		if src.subgroup > 1 then segment.subgroup = src.subgroup end
		if src.online == false then segment.online = false end
		entry.segments[#entry.segments + 1] = segment
	end

	for i = 1, #snapshot.bosses do
		local src = snapshot.bosses[i]
		staged.bossKills[i] = {
			bossNid = src.bossNid,
			name = src.name,
			mode = src.mode == "h" and "h" or "n",
			difficulty = src.difficulty,
			time = src.time,
			hash = src.hash and src.hash ~= "" and src.hash or nil,
			players = copyUniquePlayerNids(src.players, playerNidByName, validPlayerNids),
		}
	end

	for i = 1, #snapshot.loot do
		local src = snapshot.loot[i]
		local looterNid = src.looterNid
		if not looterNid and type(src.looterName) == "string" then
			looterNid = playerNidByName[NormalizeLower(src.looterName, true)]
		end
		staged.loot[i] = {
			lootNid = src.lootNid,
			itemId = src.itemId,
			itemName = src.itemName,
			itemString = src.itemString,
			itemLink = src.itemLink,
			itemRarity = src.itemRarity,
			itemTexture = src.itemTexture ~= "" and src.itemTexture or nil,
			itemCount = src.itemCount,
			looterNid = looterNid,
			rollType = src.rollType,
			rollValue = src.rollValue,
			bossNid = src.bossNid,
			time = src.time,
		}
	end

	staged.nextPlayerNid = header.nextPlayerNid
	staged.nextBossNid = header.nextBossNid
	staged.nextLootNid = header.nextLootNid
	finalizeSnapshotRaid(staged)
	local committed, committedRaid =
		raidStore:CommitAuthoritativeRaidHistoryImport(raid, staged, tonumber(header.revision))
	if not committed then return nil, committedRaid end
	return committedRaid
end

local function applyDeltaToRaid(raid, delta, expectedRaidNid)
	if not (raid and delta and delta.header) then
		return nil
	end

	local raidStore = Database.GetRaidStore()
	local valid, reason = SnapshotPayload.ValidateDelta(delta, raidStore:GetRaidSyncRevision(raid), expectedRaidNid)
	if not valid then return nil, reason end
	local canonicalRaid = raid
	raid = raidStore:StageRaidHistoryMutation(canonicalRaid)
	if not raid then return nil, "STAGE_FAILED" end
	raid.loot = raid.loot or {}
	local _, playerNidByName, validPlayerNids = SnapshotPayload.BuildPlayerNameMaps(raid.players)
	local lootIdx = buildNidIndex(raid.loot, "lootNid")
	local lootRevisions = {}

	for i = 1, #(delta.loot or {}) do
		local src = delta.loot[i]
		local nid = tonumber(src and src.lootNid)
		if nid and nid > 0 then
			local dst = upsertByNid(raid.loot, lootIdx, nid)
			local count = tonumber(src.itemCount) or 1
			if count < 1 then
				count = 1
			end

			dst.lootNid = nid
			dst.itemId = tonumber(src.itemId) or dst.itemId
			dst.itemName = src.itemName or dst.itemName
			dst.itemString = src.itemString or dst.itemString
			dst.itemLink = src.itemLink or dst.itemLink
			dst.itemRarity = tonumber(src.itemRarity) or dst.itemRarity
			if src.itemTexture and src.itemTexture ~= "" then
				dst.itemTexture = src.itemTexture
			end
			dst.itemCount = count

			local looterNid = tonumber(src.looterNid)
			if not looterNid and type(src.looterName) == "string" then
				looterNid = playerNidByName[NormalizeLower(src.looterName, true)]
			end
			if looterNid and looterNid > 0 and validPlayerNids[looterNid] then
				dst.looterNid = looterNid
			end
			dst.looter = nil
			dst.rollType = tonumber(src.rollType) or 0
			dst.rollValue = tonumber(src.rollValue) or 0
			dst.bossNid = tonumber(src.bossNid) or 0
			dst.time = tonumber(src.time) or dst.time

			lootRevisions[nid] = tonumber(src.syncRevision) or tonumber(delta.header.revision) or 0
		end
	end

	applySnapshotNextNids(raid, delta.header)
	finalizeSnapshotRaid(raid)
	local committed, committedRaid = raidStore:CommitRaidHistoryImport(
		canonicalRaid, raid, tonumber(delta.header.revision) or 0, "delta", lootRevisions
	)
	if not committed then return nil, committedRaid end
	return committedRaid
end

function SnapshotImport.ApplyDeltaToRaid(raid, delta)
	return applyDeltaToRaid(raid, delta, raid and raid.raidNid)
end

function SnapshotImport.ApplyDeltaFromAuthority(raid, delta, sourceRaidNid)
	local sourceId = tonumber(sourceRaidNid)
	if not sourceId or sourceId <= 0 or sourceId ~= math.floor(sourceId) then
		return nil, "invalid_source_raid"
	end
	return applyDeltaToRaid(raid, delta, sourceId)
end

function SnapshotImport.ImportSnapshotAsNewRaid(snapshot)
	local header = snapshot and snapshot.header
	if not header then
		return nil, nil
	end

	local raidStore = getSnapshotImportRaidStore()
	local insertionState = raidStore:CaptureRaidInsertionState()
	local raid = createRaidFromSnapshotHeader(raidStore, header)

	-- A newly allocated local record intentionally receives a different local
	-- raidNid; the external id was already validated as part of the payload.
	local ok, appliedRaid, reason = pcall(SnapshotImport.ApplySnapshotToRaid, raid, snapshot, true, true)
	raid = ok and appliedRaid or nil
	if not raid then
		raidStore:RestoreRaidInsertionState(insertionState)
		if not ok then error(appliedRaid) end
		return nil, nil, reason
	end

	local targetRevision = tonumber(header.revision) or 0
	local allowRevisionZero = tonumber(header.protocolVersion) == 1 and targetRevision == 0
	local inserted, raidId, commitReason =
		raidStore:CommitNewRaidHistoryImport(raid, targetRevision, allowRevisionZero)
	if not inserted then raidStore:RestoreRaidInsertionState(insertionState) end
	return inserted, raidId, commitReason
end
