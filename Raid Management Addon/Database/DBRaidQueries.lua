-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: direct addon namespace bindings
-- exports: publish module APIs on addon.*
-- events: none
local addon = select(2, ...)
local DB = addon.DB
local Database = addon.Database
local Sort = addon.Sort
local Strings = addon.Strings
local LootSourceCandidates = addon.LootSourceCandidates
local Time = addon.Time
local GetLootSortName = Sort and Sort.GetLootSortName
local GetCurrentTime = assert(Time and Time.GetCurrentTime, "Raid queries time provider is not initialized")

local pairs, type = pairs, type
local tonumber, tostring = tonumber, tostring

local isBossFightRecord = Database.IsBossFightRecord

-- Raid read-only projection/query service.
do
	DB.RaidQueries = DB.RaidQueries or {}
	local module = DB.RaidQueries

	-- ----- Internal state ----- --

	-- ----- Private helpers ----- --
	local function normalizeRaid(raid)
		if type(raid) ~= "table" then
			return nil
		end
		local currentVersion = tonumber(Database.GetRaidSchemaVersion()) or 1
		local schemaVersion = tonumber(raid.schemaVersion)
		if schemaVersion and schemaVersion > currentVersion then
			return nil, "unsupported raid schema"
		end
		return raid
	end

	local function normalizeRaidForQuery(raid, opts)
		if type(opts) == "table" and opts.raw == true then
			return raid
		end
		return normalizeRaid(raid)
	end

	local function ensureRuntime(raid)
		return Database.GetRaidStore():GetRaidRuntimeForRead(raid)
	end

	local function getCollection(value)
		return type(value) == "table" and value or {}
	end

	local function countCollection(value)
		if type(value) ~= "table" then
			return 0
		end
		local count = 0
		for _ in pairs(value) do
			count = count + 1
		end
		return count
	end

	local function clearRow(row)
		for key in pairs(row) do
			row[key] = nil
		end
		return row
	end

	local function collectCanonicalTables(value, canonicalTables)
		if type(value) ~= "table" or canonicalTables[value] then
			return
		end
		canonicalTables[value] = true
		for _, item in pairs(value) do
			collectCanonicalTables(item, canonicalTables)
		end
	end

	local function prepareOutputRows(raid, out)
		local canonicalTables = {}
		collectCanonicalTables(raid, canonicalTables)
		if type(out) ~= "table" or canonicalTables[out] then
			return {}, canonicalTables
		end
		return out, canonicalTables
	end

	local function acquireOutputRow(rows, index, canonicalTables)
		local row = rows[index]
		if type(row) ~= "table" or canonicalTables[row] then
			row = {}
			rows[index] = row
			return row
		end
		return clearRow(row)
	end

	local function clearOutputTail(rows, count)
		for i = count + 1, #rows do
			rows[i] = nil
		end
		return rows
	end

	local function getPlayerByNid(raid, runtime, playerNid)
		local queryNid = tonumber(playerNid)
		if not (raid and queryNid and queryNid > 0) then
			return nil
		end

		local idxByNid = runtime and runtime.playerIdxByNid or nil
		local idx = idxByNid and idxByNid[queryNid] or nil
		local players = getCollection(raid.players)
		if idx then
			local player = players[idx]
			if type(player) == "table" and tonumber(player.playerNid) == queryNid then
				return player
			end
		end

		for i = 1, #players do
			local player = players[i]
			if type(player) == "table" and tonumber(player.playerNid) == queryNid then
				return player
			end
		end
		return nil
	end

	local function findBossByNid(raid, bossNid)
		local resolvedBossNid = tonumber(bossNid) or 0
		if resolvedBossNid <= 0 then
			return nil
		end

		local bosses = getCollection(raid and raid.bossKills)
		for i = 1, #bosses do
			local boss = bosses[i]
			if type(boss) == "table" and tonumber(boss.bossNid) == resolvedBossNid then
				return boss
			end
		end
		return nil
	end

	local function findBossByName(raid, bossName)
		local resolvedBossName = Strings.NormalizeLower(bossName, true)
		if not resolvedBossName or resolvedBossName == "" then
			return nil
		end

		local bosses = getCollection(raid and raid.bossKills)
		for i = #bosses, 1, -1 do
			local boss = bosses[i]
			if type(boss) == "table" then
				local candidateName = Strings.NormalizeLower(boss.name or boss.boss, true)
				if candidateName == resolvedBossName then
					return boss
				end
			end
		end
		return nil
	end

	local function findBossBySourceNpcId(raid, sourceNpcId)
		local resolvedNpcId = tonumber(sourceNpcId) or 0
		if resolvedNpcId <= 0 then
			return nil
		end

		local bosses = getCollection(raid and raid.bossKills)
		for i = #bosses, 1, -1 do
			local boss = bosses[i]
			if type(boss) == "table" and (tonumber(boss.sourceNpcId) or 0) == resolvedNpcId then
				return boss
			end
		end
		return nil
	end

	local function findBossBySourceKey(raid, sourceKey)
		local queryKey = Strings.TrimText(sourceKey, true)
		if not queryKey or queryKey == "" then
			return nil
		end

		local bosses = getCollection(raid and raid.bossKills)
		for i = #bosses, 1, -1 do
			local boss = bosses[i]
			if type(boss) == "table" and Strings.TrimText(boss.sourceKey, true) == queryKey then
				return boss
			end
		end
		return nil
	end

	local function resolveLootLooterNid(loot)
		if type(loot) ~= "table" then
			return nil
		end
		local looterNid = tonumber(loot.looterNid)
		if looterNid and looterNid > 0 then
			return looterNid
		end
		return nil
	end

	local function resolveLootLooterName(raid, runtime, loot)
		local looterNid = resolveLootLooterNid(loot)
		if looterNid then
			local player = getPlayerByNid(raid, runtime, looterNid)
			if player and player.name then
				return player.name, looterNid
			end
			return nil, looterNid
		end
		return nil, nil
	end

	local function resolveLootLooterNameFromMap(loot, playerNameByNid)
		local looterNid = resolveLootLooterNid(loot)
		if looterNid then
			local playerName = playerNameByNid and playerNameByNid[looterNid] or nil
			if playerName and playerName ~= "" then
				return playerName
			end
		end
		return ""
	end

	local function getAttendanceEntry(raid, runtime, playerNid)
		local attendance = raid and raid.attendance or nil
		local queryNid = tonumber(playerNid) or 0
		if type(attendance) ~= "table" or queryNid <= 0 then
			return nil
		end

		local attendanceIdxByPlayerNid = runtime and runtime.attendanceIdxByPlayerNid or nil
		local indexedEntry = attendanceIdxByPlayerNid and attendance[attendanceIdxByPlayerNid[queryNid]] or nil
		if type(indexedEntry) == "table" and tonumber(indexedEntry.playerNid) == queryNid then
			return indexedEntry
		end

		for i = 1, #attendance do
			local entry = attendance[i]
			if type(entry) == "table" and tonumber(entry.playerNid) == queryNid then
				return entry
			end
		end
		return nil
	end

	local function summarizeAttendance(entry, fallbackJoin, fallbackLeave)
		local now = GetCurrentTime()
		local totalSeconds = 0
		local onlineSeconds = 0
		local offlineSeconds = 0
		local segmentCount = 0
		local segments = entry and entry.segments or nil

		if type(segments) == "table" then
			for i = 1, #segments do
				local segment = segments[i]
				if type(segment) == "table" then
					local startTime = tonumber(segment.startTime) or 0
					local endTime = tonumber(segment.endTime) or now
					if startTime > 0 and endTime >= startTime then
						local duration = endTime - startTime
						totalSeconds = totalSeconds + duration
						if segment.online == false then
							offlineSeconds = offlineSeconds + duration
						else
							onlineSeconds = onlineSeconds + duration
						end
						segmentCount = segmentCount + 1
					end
				end
			end
		end

		if segmentCount == 0 then
			local joinTime = tonumber(fallbackJoin) or 0
			local leaveTime = tonumber(fallbackLeave) or now
			if joinTime > 0 and leaveTime >= joinTime then
				totalSeconds = leaveTime - joinTime
				onlineSeconds = totalSeconds
				segmentCount = 1
			end
		end

		return totalSeconds, onlineSeconds, offlineSeconds, segmentCount
	end

	-- ----- Public methods ----- --
	function module:FindBossByNid(raid, bossNid, opts)
		return findBossByNid(normalizeRaidForQuery(raid, opts), bossNid)
	end

	function module:FindBossByName(raid, bossName, opts)
		return findBossByName(normalizeRaidForQuery(raid, opts), bossName)
	end

	function module:FindBossBySourceNpcId(raid, sourceNpcId, opts)
		return findBossBySourceNpcId(normalizeRaidForQuery(raid, opts), sourceNpcId)
	end

	function module:FindBossBySourceKey(raid, sourceKey, opts)
		return findBossBySourceKey(normalizeRaidForQuery(raid, opts), sourceKey)
	end

	function module:ResolveLootLooterName(raid, loot, runtime)
		raid = normalizeRaid(raid)
		runtime = runtime or ensureRuntime(raid)
		return resolveLootLooterName(raid, runtime, loot)
	end

	function module:ResolveLootLooterNameFromMap(loot, playerNameByNid)
		return resolveLootLooterNameFromMap(loot, playerNameByNid)
	end

	function module:GetRaidSummary(raid)
		local normalizeError
		raid, normalizeError = normalizeRaid(raid)
		if type(raid) ~= "table" then
			return nil, normalizeError
		end

		return {
			raidNid = tonumber(raid.raidNid),
			zone = raid.zone,
			size = tonumber(raid.size) or 0,
			difficulty = tonumber(raid.difficulty) or 0,
			startTime = tonumber(raid.startTime) or 0,
			endTime = tonumber(raid.endTime) or 0,
			playersCount = countCollection(raid.players),
			bossCount = countCollection(raid.bossKills),
			lootCount = countCollection(raid.loot),
			changesCount = (function()
				local changes = getCollection(raid.changes)
				local count = 0
				for _ in pairs(changes) do
					count = count + 1
				end
				return count
			end)(),
		}
	end

	function module:GetBossKills(raid, out)
		local normalizeError
		raid, normalizeError = normalizeRaid(raid)
		if type(raid) ~= "table" then
			return nil, normalizeError
		end
		local rows, canonicalTables = prepareOutputRows(raid, out)
		local count = 0
		local bosses = getCollection(raid and raid.bossKills)
		for i = 1, #bosses do
			local boss = bosses[i]
			if type(boss) == "table" then
				local mode = boss.mode
				if not mode and boss.difficulty then
					mode = (boss.difficulty == 3 or boss.difficulty == 4) and "h" or "n"
				end
				local killTime = tonumber(boss.time) or 0
				count = count + 1
				local row = acquireOutputRow(rows, count, canonicalTables)
				row.id = tonumber(boss.bossNid)
				row.seq = i
				row.name = boss.name or ""
				row.mode = (mode == "h") and "H" or "N"
				row.difficulty = tonumber(boss.difficulty) or 0
				row.time = killTime
				row.timeFmt = (killTime > 0) and date("%H:%M", killTime) or ""
			end
		end

		return clearOutputTail(rows, count)
	end

	function module:GetRaidAttendance(raid, out)
		local normalizeError
		raid, normalizeError = normalizeRaid(raid)
		if type(raid) ~= "table" then
			return nil, normalizeError
		end
		local rows, canonicalTables = prepareOutputRows(raid, out)
		local count = 0
		local players = getCollection(raid and raid.players)
		local runtime = raid and ensureRuntime(raid) or nil
		for i = 1, #players do
			local player = players[i]
			if type(player) == "table" then
				local joinTime = tonumber(player.join)
				local leaveTime = tonumber(player.leave)
				local attendanceEntry = getAttendanceEntry(raid, runtime, player.playerNid)
				local totalSeconds, onlineSeconds, offlineSeconds, segmentCount =
					summarizeAttendance(attendanceEntry, joinTime, leaveTime)
				count = count + 1
				local row = acquireOutputRow(rows, count, canonicalTables)
				row.id = tonumber(player.playerNid)
				row.name = player.name
				row.class = player.class
				row.join = joinTime
				row.leave = leaveTime
				row.joinFmt = joinTime and date("%H:%M", joinTime) or ""
				row.leaveFmt = leaveTime and date("%H:%M", leaveTime) or ""
				row.attendanceSeconds = totalSeconds
				row.onlineSeconds = onlineSeconds
				row.offlineSeconds = offlineSeconds
				row.segmentCount = segmentCount
			end
		end

		return clearOutputTail(rows, count)
	end

	function module:GetBossAttendance(raid, bossNid, out)
		local normalizeError
		raid, normalizeError = normalizeRaid(raid)
		if type(raid) ~= "table" then
			return nil, normalizeError
		end
		local rows, canonicalTables = prepareOutputRows(raid, out)
		local count = 0
		local queryNid = tonumber(bossNid)
		if not (raid and queryNid) then
			return clearOutputTail(rows, count)
		end

		local runtime = ensureRuntime(raid)
		local bosses = getCollection(raid.bossKills)
		local bossIdxByNid = runtime and runtime.bossIdxByNid or nil
		local bossKill = bossIdxByNid and bosses[bossIdxByNid[queryNid]] or nil
		if not (type(bossKill) == "table" and isBossFightRecord(bossKill) and type(bossKill.players) == "table") then
			return clearOutputTail(rows, count)
		end

		local setByBossNid = runtime and runtime.bossPlayerSetByBossNid or nil
		local set = setByBossNid and setByBossNid[queryNid] or nil
		if type(set) ~= "table" then
			set = {}
			for i = 1, #bossKill.players do
				local playerNid = tonumber(bossKill.players[i])
				if playerNid and playerNid > 0 then
					set[playerNid] = true
				end
			end
		end

		local players = getCollection(raid.players)
		for i = 1, #players do
			local player = players[i]
			local playerNid = type(player) == "table" and tonumber(player.playerNid) or nil
			if type(player) == "table" and player.name and playerNid and set[playerNid] then
				count = count + 1
				local row = acquireOutputRow(rows, count, canonicalTables)
				row.id = playerNid
				row.name = player.name
				row.class = player.class
			end
		end

		return clearOutputTail(rows, count)
	end

	function module:GetLoot(raid, bossNid, playerName, out)
		local normalizeError
		raid, normalizeError = normalizeRaid(raid)
		if type(raid) ~= "table" then
			return nil, normalizeError
		end
		local rows, canonicalTables = prepareOutputRows(raid, out)
		local count = 0
		local bossFilterNid = tonumber(bossNid)
		local hasBossFilter = bossFilterNid and bossFilterNid > 0
		local hasPlayerFilter = playerName and playerName ~= ""
		local runtime = raid and ensureRuntime(raid) or nil
		local playerFilterNid = nil
		if hasPlayerFilter then
			local queryName = tostring(playerName)
			local playerNidByName = runtime and runtime.playerNidByName or nil
			playerFilterNid = playerNidByName and tonumber(playerNidByName[queryName]) or nil
			if not playerFilterNid then
				local players = getCollection(raid and raid.players)
				for i = #players, 1, -1 do
					local player = players[i]
					if type(player) == "table" and player.name == queryName then
						playerFilterNid = tonumber(player.playerNid)
						break
					end
				end
			end
		end

		local bosses = getCollection(raid and raid.bossKills)
		local bossIdxByNid = runtime and runtime.bossIdxByNid or nil
		local lootRows = getCollection(raid and raid.loot)
		local lootIndexList = nil
		local lootIdxByBossNid = runtime and runtime.lootIdxByBossNid or nil
		local lootIdxByLooterNid = runtime and runtime.lootIdxByLooterNid or nil
		local bossIndexList = hasBossFilter and lootIdxByBossNid and lootIdxByBossNid[bossFilterNid] or nil
		local looterIndexList = playerFilterNid and lootIdxByLooterNid and lootIdxByLooterNid[playerFilterNid] or nil
		if type(bossIndexList) == "table" and type(looterIndexList) == "table" then
			lootIndexList = (#bossIndexList <= #looterIndexList) and bossIndexList or looterIndexList
		elseif type(bossIndexList) == "table" then
			lootIndexList = bossIndexList
		elseif type(looterIndexList) == "table" then
			lootIndexList = looterIndexList
		elseif hasBossFilter or playerFilterNid then
			lootIndexList = {}
		end

		local function appendLootRow(loot)
			if type(loot) == "table" then
				local looterNid = nil
				local looterName = nil
				looterName, looterNid = resolveLootLooterName(raid, runtime, loot)
				local okBoss = (not hasBossFilter) or (tonumber(loot.bossNid) == bossFilterNid)
				local okPlayer = not hasPlayerFilter
					or (playerFilterNid and looterNid and playerFilterNid == looterNid)
					or ((not playerFilterNid) and looterName and looterName == playerName)
				if okBoss and okPlayer then
					local lootTime = tonumber(loot.time) or 0
					local sourceBossIndex = bossIdxByNid and bossIdxByNid[tonumber(loot.bossNid)] or nil
					local sourceBoss = sourceBossIndex and bosses[sourceBossIndex] or nil
					local sourceName, sourceKind, sourceCandidates, sourceKey =
						LootSourceCandidates.ResolveSourceMetadata(loot, sourceBoss)
					local looterPlayer = looterNid and getPlayerByNid(raid, runtime, looterNid) or nil
					count = count + 1
					local row = acquireOutputRow(rows, count, canonicalTables)
					row.id = tonumber(loot.lootNid)
					row.itemId = tonumber(loot.itemId)
					row.itemName = loot.itemName
					row.itemRarity = loot.itemRarity
					row.itemTexture = loot.itemTexture
					row.itemLink = loot.itemLink
					row.bossNid = tonumber(loot.bossNid) or 0
					row.sourceName = sourceName or ""
					row.sourceKind = sourceKind
					row.sourceCandidates = sourceCandidates
					row.sourceKey = sourceKey
					row.looterNid = looterNid
					row.looter = looterName or ""
					row.looterClass = looterPlayer and looterPlayer.class or nil
					row.rollType = tonumber(loot.rollType) or 0
					row.rollValue = tonumber(loot.rollValue) or 0
					row.sortName = (GetLootSortName and GetLootSortName(loot.itemName, loot.itemLink, loot.itemId))
						or tostring(loot.itemName or "")
					row.time = lootTime
					row.timeFmt = (lootTime > 0) and date("%H:%M", lootTime) or ""
				end
			end
		end

		if lootIndexList then
			for i = 1, #lootIndexList do
				appendLootRow(lootRows[lootIndexList[i]])
			end
		else
			for i = 1, #lootRows do
				appendLootRow(lootRows[i])
			end
		end

		return clearOutputTail(rows, count)
	end
end
