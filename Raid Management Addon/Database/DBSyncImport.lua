-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: local feature = addon.Database.GetFeatureShared()
-- exports: addon.Database.Syncer._Import
-- events: none

local addon = select(2, ...)
local feature = addon.Database.GetFeatureShared()

local DB = feature.DB
local Database = feature.Database
local Strings = feature.Strings
local Time = feature.Time
local coreState = feature.coreState

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
	return Database.GetRaidStoreOrNil("DBSyncer.ImportSnapshotAsNewRaid", { "CreateRaidRecord", "InsertRaid" })
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
	return Database.EnsureRaidById(currentId), currentId
end

function SnapshotImport.ResolveRaidByReference(raidRef, allowFallback)
	local n = tonumber(raidRef)
	if n and n > 0 then
		local byId, byIdIndex = Database.EnsureRaidById(n)
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
		local raid = Database.EnsureRaidById(selectedRaid)
		if raid then
			return raid, selectedRaid
		end
	end

	local currentRaid = Database.GetCurrentRaid()
	if currentRaid then
		return Database.EnsureRaidById(currentRaid), currentRaid
	end

	return nil, nil
end

function SnapshotImport.ApplySnapshotToRaid(raid, snapshot, updateMeta)
	if not (raid and snapshot and snapshot.header) then
		return nil
	end
	local header = snapshot.header

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
	local raidStore = Database.GetRaidStoreOrNil("DBSyncImport.ApplySnapshotToRaid", { "SetRaidSyncRevision" })
	if raidStore then
		raidStore:SetRaidSyncRevision(raid, tonumber(header.revision) or 0, "snapshot")
	end
	return finalizeSnapshotRaid(raid)
end

function SnapshotImport.ApplyDeltaToRaid(raid, delta)
	if not (raid and delta and delta.header) then
		return nil
	end

	raid.loot = raid.loot or {}
	local _, playerNidByName, validPlayerNids = SnapshotPayload.BuildPlayerNameMaps(raid.players)
	local lootIdx = buildNidIndex(raid.loot, "lootNid")
	local raidStore =
		Database.GetRaidStoreOrNil("DBSyncImport.ApplyDeltaToRaid", { "SetRaidSyncRevision", "SetLootSyncRevision" })

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

			if raidStore then
				raidStore:SetLootSyncRevision(
					raid,
					dst,
					tonumber(src.syncRevision) or tonumber(delta.header.revision) or 0
				)
			end
		end
	end

	applySnapshotNextNids(raid, delta.header)
	if raidStore then
		raidStore:SetRaidSyncRevision(raid, tonumber(delta.header.revision) or 0, "delta")
	end
	return finalizeSnapshotRaid(raid)
end

function SnapshotImport.ImportSnapshotAsNewRaid(snapshot)
	local header = snapshot and snapshot.header
	if not header then
		return nil, nil
	end

	local raidStore = getSnapshotImportRaidStore()
	if not raidStore then
		return nil, nil
	end

	local raid = createRaidFromSnapshotHeader(raidStore, header)

	raid = SnapshotImport.ApplySnapshotToRaid(raid, snapshot, true)
	if not raid then
		return nil, nil
	end

	return raidStore:InsertRaid(raid)
end

local registry = feature.ModuleRegistry
if type(registry) == "table" and type(registry.AddModule) == "function" and type(registry.SetLoaded) == "function" then
	registry.AddModule("Database/DBSyncImport", {
		deps = {
			"Init",
			"Modules/ModuleRegistry",
			"Database/DB",
			"Database/DBSchema",
			"Database/DBRaidStore",
			"Database/DBSyncPayload",
			"Modules/Strings",
			"Modules/Time",
		},
	})
	registry.SetLoaded("Database/DBSyncImport")
end
