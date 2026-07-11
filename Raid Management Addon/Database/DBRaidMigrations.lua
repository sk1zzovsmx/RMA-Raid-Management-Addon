-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: direct addon namespace bindings
-- exports: publish module APIs on addon.DB.RaidMigrations
-- events: none
local addon = select(2, ...)
local DB = addon.DB
local Database = addon.Database
local Strings = assert(addon.Strings, "String helpers are not initialized")
local LootSourceCandidates = assert(addon.LootSourceCandidates, "Loot source candidate helpers are not initialized")

local isBossFightRecord = Database.IsBossFightRecord
local tconcat = table.concat

local normalizeTextLower = assert(Strings.NormalizeLower, "String lower normalizer is not initialized")

local function buildCandidateSourceKey(candidate, name)
	local raidKey = normalizeTextLower(candidate and candidate.raid, true) or "unknown"
	local kind = normalizeTextLower(candidate and candidate.kind, true) or "boss"
	local npcId = tonumber(candidate and (candidate.npcId or candidate.sourceNpcId)) or 0
	local sourceName = normalizeTextLower(name or (candidate and (candidate.npcName or candidate.name)), true)
		or "unknown"
	return tconcat({ raidKey, kind, tostring(npcId), sourceName, "any" }, "|")
end

-- Current-schema raid persistence helpers.
do
	DB.RaidMigrations = DB.RaidMigrations or {}
	local module = DB.RaidMigrations

	-- ----- Internal state ----- --
	local EMPTY_MIGRATIONS = {}
	local SHARED_SOURCE_LABEL = LootSourceCandidates.GetSharedLabel()

	-- ----- Private helpers ----- --
	local function ensureTableField(raid, key, emptyAsMap)
		local value = raid[key]
		if type(value) ~= "table" then
			raid[key] = {}
			return
		end

		if emptyAsMap then
			return
		end
	end

	local normalizeName = assert(Strings.NormalizeName, "String name normalizer is not initialized")
	local normalizeTextOrNil = assert(Strings.NilIfEmpty, "String empty-value normalizer is not initialized")
	local isSharedSourceName =
		assert(LootSourceCandidates.IsSharedSourceName, "Loot source shared-name helper is not initialized")
	local compactSharedCandidates = assert(LootSourceCandidates.Copy, "Loot source candidate copier is not initialized")

	local function normalizePositiveNumberOrNil(value)
		local num = tonumber(value)
		if not num or num <= 0 then
			return nil
		end
		return num
	end

	local function copyStringOrNil(value)
		if type(value) == "string" then
			return value
		end
		return nil
	end

	local function compactInspectSnapshotForPersistence(snapshot)
		if type(snapshot) ~= "table" then
			return nil
		end

		local compact = {}
		compact.playerNid = tonumber(snapshot.playerNid) or nil
		compact.name = copyStringOrNil(snapshot.name)
		compact.guid = copyStringOrNil(snapshot.guid)
		compact.class = copyStringOrNil(snapshot.class)
		compact.status = copyStringOrNil(snapshot.status)
		compact.reason = copyStringOrNil(snapshot.reason)
		compact.inspectedAt = tonumber(snapshot.inspectedAt) or nil
		compact.avgIlvl = tonumber(snapshot.avgIlvl) or nil
		compact.specName = copyStringOrNil(snapshot.specName)
		compact.specIcon = copyStringOrNil(snapshot.specIcon)
		compact.mainTalentTree = tonumber(snapshot.mainTalentTree) or nil
		compact.secondarySpecName = copyStringOrNil(snapshot.secondarySpecName)
		compact.secondarySpecIcon = copyStringOrNil(snapshot.secondarySpecIcon)
		compact.activeTalentGroup = tonumber(snapshot.activeTalentGroup) or nil
		compact.numTalentGroups = tonumber(snapshot.numTalentGroups) or nil
		compact.secondaryTalentGroup = tonumber(snapshot.secondaryTalentGroup) or nil
		compact.secondaryMainTalentTree = tonumber(snapshot.secondaryMainTalentTree) or nil

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

	local function compactInspectForPersistence(inspect)
		if type(inspect) ~= "table" then
			return nil
		end

		local compact = {}
		compact.startedAt = tonumber(inspect.startedAt) or nil
		compact.completedAt = tonumber(inspect.completedAt) or nil
		compact.mode = copyStringOrNil(inspect.mode)

		local playersIn = inspect.players
		if type(playersIn) == "table" then
			local compactPlayers = {}
			for key, snapshot in pairs(playersIn) do
				local compactSnapshot = compactInspectSnapshotForPersistence(snapshot)
				if compactSnapshot then
					compactPlayers[key] = compactSnapshot
				end
			end
			if next(compactPlayers) then
				compact.players = compactPlayers
			end
		end

		if next(compact) then
			return compact
		end
		return nil
	end

	local function buildSharedSourceKeyFromCandidates(candidates)
		if type(candidates) ~= "table" then
			return nil
		end
		local keys = {}
		for i = 1, #candidates do
			local candidate = candidates[i]
			local sourceKey = normalizeTextOrNil(candidate and candidate.sourceKey)
				or buildCandidateSourceKey(candidate, candidate and candidate.name)
			if sourceKey then
				keys[#keys + 1] = sourceKey
			end
		end
		return (#keys > 0) and ("shared|" .. tconcat(keys, ";")) or nil
	end

	local function getLootSourceResolver()
		local resolver = addon.LootSources
		if type(resolver) == "table" and type(resolver.FindSource) == "function" then
			return resolver
		end
		return nil
	end

	local function buildLootSourceContext(raid)
		local zone = raid and raid.zone or nil
		return {
			raid = zone,
			zoneName = zone,
			instanceName = zone,
			raidSize = tonumber(raid and raid.size) or 0,
			difficulty = tonumber(raid and raid.difficulty) or 0,
		}
	end

	local function resolveSharedCandidatesFromItem(raid, loot)
		local resolver = getLootSourceResolver()
		local itemId = tonumber(loot and loot.itemId)
		if not resolver or not itemId or itemId <= 0 then
			return nil, nil
		end

		local source = resolver.FindSource(itemId, buildLootSourceContext(raid))
		if type(source) ~= "table" or source.kind ~= "shared" then
			return nil, nil
		end

		local candidates = compactSharedCandidates(source.candidates, nil)
		if not candidates then
			return nil, nil
		end

		return candidates, normalizeTextOrNil(source.sourceKey) or buildSharedSourceKeyFromCandidates(candidates)
	end

	local function migrateSharedLootSources(raid)
		if type(raid) ~= "table" then
			return raid
		end

		local sharedCandidatesByBossNid = {}
		local bosses = raid.bossKills or EMPTY_MIGRATIONS
		for i = 1, #bosses do
			local boss = bosses[i]
			if type(boss) == "table" then
				local sourceKind = boss.sourceKind
				local bossName = boss.name or boss.boss
				if sourceKind == "shared" or isSharedSourceName(bossName) then
					local candidates = compactSharedCandidates(boss.candidates, bossName)
					boss.name = SHARED_SOURCE_LABEL
					boss.boss = nil
					boss.sourceKind = "shared"
					boss.source = boss.source or "LootSources"
					boss.sourceNpcId = nil
					boss.candidates = nil

					local bossNid = tonumber(boss.bossNid) or 0
					if bossNid > 0 and candidates then
						sharedCandidatesByBossNid[bossNid] = candidates
					end
				end
			end
		end

		local lootRows = raid.loot or EMPTY_MIGRATIONS
		for i = 1, #lootRows do
			local loot = lootRows[i]
			if type(loot) == "table" then
				local lootSource = type(loot.lootSource) == "table" and loot.lootSource or nil
				local bossNid = tonumber(loot.bossNid) or 0
				local sourceName = lootSource and lootSource.sourceName or nil
				local sourceKind = lootSource and lootSource.kind or nil
				local bossCandidates = sharedCandidatesByBossNid[bossNid]

				if sourceKind == "shared" or bossCandidates or isSharedSourceName(sourceName) then
					local resolvedCandidates, resolvedSourceKey = resolveSharedCandidatesFromItem(raid, loot)
					lootSource = lootSource or {}
					lootSource.kind = "shared"
					lootSource.bossNid = bossNid
					lootSource.sourceNpcId = 0
					lootSource.sourceName = SHARED_SOURCE_LABEL
					lootSource.sourceKey = resolvedSourceKey or normalizeTextOrNil(lootSource.sourceKey)
					lootSource.candidates = resolvedCandidates
						or compactSharedCandidates(lootSource.candidates, sourceName)
						or bossCandidates
					if not lootSource.sourceKey then
						lootSource.sourceKey = buildSharedSourceKeyFromCandidates(lootSource.candidates)
					end
					loot.lootSource = lootSource
				end
			end
		end

		return raid
	end

	local function compactChangesMap(changes)
		local out = {}
		if type(changes) ~= "table" then
			return out
		end

		for rawName, rawSpec in pairs(changes) do
			local playerName = normalizeName(rawName)
			local spec = normalizeName(rawSpec)
			if playerName and spec then
				out[playerName] = spec
			end
		end

		return out
	end

	local function appendAttendanceSegment(entry, segment)
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

	local function compactAttendance(attendance)
		local out = {}
		if type(attendance) ~= "table" then
			return out
		end

		local seenPlayers = {}
		for i = 1, #attendance do
			local entry = attendance[i]
			local playerNid = tonumber(entry and entry.playerNid) or 0
			if playerNid > 0 and not seenPlayers[playerNid] then
				local normalizedEntry = {
					playerNid = playerNid,
					segments = {},
				}
				seenPlayers[playerNid] = true

				local segments = entry.segments
				if type(segments) == "table" then
					for j = 1, #segments do
						appendAttendanceSegment(normalizedEntry, segments[j])
					end
				end

				if #normalizedEntry.segments > 0 then
					out[#out + 1] = normalizedEntry
				end
			end
		end

		return out
	end

	local function compactRaidForPersistence(raid)
		if type(raid) ~= "table" then
			return nil
		end

		ensureTableField(raid, "players", false)
		ensureTableField(raid, "bossKills", false)
		ensureTableField(raid, "loot", false)
		ensureTableField(raid, "changes", true)
		ensureTableField(raid, "attendance", false)

		local players = raid.players
		for i = 1, #players do
			local player = players[i]
			if type(player) == "table" then
				local countMS = tonumber(player.countMS) or 0
				if countMS < 0 then
					countMS = 0
				end
				player.countMS = (countMS > 0) and countMS or nil
				player.count = nil

				local countOs = tonumber(player.countOs) or 0
				if countOs < 0 then
					countOs = 0
				end
				player.countOs = (countOs > 0) and countOs or nil

				local countFree = tonumber(player.countFree) or 0
				if countFree < 0 then
					countFree = 0
				end
				player.countFree = (countFree > 0) and countFree or nil

				local countSR = tonumber(player.countSR) or 0
				if countSR < 0 then
					countSR = 0
				end
				player.countSR = (countSR > 0) and countSR or nil

				local rank = tonumber(player.rank) or 0
				player.rank = (rank > 0) and rank or nil

				local subgroup = tonumber(player.subgroup) or 1
				player.subgroup = (subgroup > 1) and subgroup or nil

				player.join = normalizePositiveNumberOrNil(player.join)
				player.leave = normalizePositiveNumberOrNil(player.leave)

				local playerName = normalizeName(player.name)
				if playerName then
					player.name = playerName
				end

				local className = normalizeTextOrNil(player.class)
				player.class = className or "UNKNOWN"
			end
		end

		local bosses = raid.bossKills
		for i = 1, #bosses do
			local boss = bosses[i]
			if type(boss) == "table" then
				local difficulty = tonumber(boss.difficulty) or 0
				boss.difficulty = (difficulty > 0) and difficulty or nil

				local mode = normalizeTextLower(boss.mode, true)
				local derivedMode = nil
				if difficulty > 0 then
					derivedMode = (difficulty == 3 or difficulty == 4) and "h" or "n"
				end
				if mode == "h" or mode == "n" then
					boss.mode = (mode ~= derivedMode) and mode or nil
				else
					boss.mode = nil
				end

				boss.time = normalizePositiveNumberOrNil(boss.time)
				boss.hash = normalizeTextOrNil(boss.hash)
				boss.sourceKey = normalizeTextOrNil(boss.sourceKey)
				boss.attendanceMask = nil

				local attendees = {}
				local seen = {}
				if isBossFightRecord(boss) then
					local rawPlayers = boss.players
					if type(rawPlayers) == "table" then
						for j = 1, #rawPlayers do
							local playerNid = tonumber(rawPlayers[j])
							if playerNid and playerNid > 0 and not seen[playerNid] then
								seen[playerNid] = true
								attendees[#attendees + 1] = playerNid
							end
						end
					end
				end
				boss.players = attendees
			end
		end

		local lootRows = raid.loot
		for i = 1, #lootRows do
			local loot = lootRows[i]
			if type(loot) == "table" then
				loot.itemId = normalizePositiveNumberOrNil(loot.itemId)
				loot.itemName = normalizeTextOrNil(loot.itemName)
				loot.itemString = normalizeTextOrNil(loot.itemString)
				loot.itemLink = normalizeTextOrNil(loot.itemLink)
				loot.itemTexture = normalizeTextOrNil(loot.itemTexture)
				loot.rollSessionId = normalizeTextOrNil(loot.rollSessionId)
				loot.source = normalizeTextOrNil(loot.source)

				local itemRarity = tonumber(loot.itemRarity) or 0
				loot.itemRarity = (itemRarity > 0) and itemRarity or nil

				local itemCount = tonumber(loot.itemCount) or 1
				if itemCount < 1 then
					itemCount = 1
				end
				loot.itemCount = (itemCount > 1) and itemCount or nil

				local looterNid = tonumber(loot.looterNid)
				if looterNid and looterNid > 0 then
					loot.looterNid = looterNid
				else
					loot.looterNid = nil
				end
				loot.looter = nil

				local rollType = tonumber(loot.rollType) or 0
				loot.rollType = (rollType ~= 0) and rollType or nil

				local rollValue = tonumber(loot.rollValue) or 0
				loot.rollValue = (rollValue ~= 0) and rollValue or nil

				local bossNid = tonumber(loot.bossNid) or 0
				loot.bossNid = (bossNid > 0) and bossNid or nil

				loot.time = normalizePositiveNumberOrNil(loot.time)

				local lootSource = type(loot.lootSource) == "table" and loot.lootSource or nil
				if lootSource then
					local sourceKind = normalizeTextOrNil(lootSource.kind)
					lootSource.kind = sourceKind
					local sourceBossNid = tonumber(lootSource.bossNid) or tonumber(loot.bossNid) or 0
					lootSource.bossNid = (sourceBossNid > 0) and sourceBossNid or nil
					local sourceNpcId = tonumber(lootSource.sourceNpcId) or 0
					lootSource.sourceNpcId = (sourceNpcId > 0 or sourceKind == "shared") and sourceNpcId or nil
					lootSource.sourceName = normalizeTextOrNil(lootSource.sourceName)
					lootSource.sourceKey = normalizeTextOrNil(lootSource.sourceKey)
					lootSource.openedAt = normalizePositiveNumberOrNil(lootSource.openedAt)
					lootSource.snapshotId = normalizePositiveNumberOrNil(lootSource.snapshotId)

					if sourceKind == "shared" then
						lootSource.sourceName = SHARED_SOURCE_LABEL
						lootSource.sourceNpcId = 0
						lootSource.candidates = compactSharedCandidates(lootSource.candidates, nil)
					else
						lootSource.candidates = nil
					end
				end
			end
		end

		raid.changes = compactChangesMap(raid.changes)
		raid.attendance = compactAttendance(raid.attendance)

		local compactInspect = compactInspectForPersistence(raid.inspect)
		if compactInspect then
			raid.inspect = compactInspect
		else
			raid.inspect = nil
		end

		return raid
	end

	local function isCurrentSchema(raid, fromVersion, toVersion)
		local currentVersion = tonumber(toVersion) or module:GetCurrentVersion()
		local storedVersion = tonumber(fromVersion) or tonumber(raid and raid.schemaVersion) or 1
		return storedVersion >= currentVersion
	end

	-- ----- Public methods ----- --
	function module:GetCurrentVersion()
		local version = Database.GetRaidSchemaVersion() or 1
		version = tonumber(version) or 1
		if version < 1 then
			version = 1
		end
		return version
	end

	function module:MigrateRaidToCurrentSchema(raid, fromVersion, toVersion)
		local currentVersion = tonumber(toVersion) or self:GetCurrentVersion()
		local storedVersion = tonumber(fromVersion) or 1
		if isCurrentSchema(raid, fromVersion, currentVersion) then
			return raid
		end
		if currentVersion >= 6 and storedVersion < 6 then
			migrateSharedLootSources(raid)
		end
		return raid
	end

	function module:CompactRaidForPersistence(raid)
		migrateSharedLootSources(raid)
		return compactRaidForPersistence(raid)
	end
end
