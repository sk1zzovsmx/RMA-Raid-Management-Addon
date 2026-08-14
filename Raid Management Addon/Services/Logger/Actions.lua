-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: direct addon namespace bindings
-- exports: publish module APIs on addon.*
-- events: emits logger data-change notifications via addon.Bus
local addon = select(2, ...)
local L = addon.L
local Diag = addon.Diag
local Strings = addon.Strings
local Base64 = addon.Base64
local Database = addon.Database
local Services = addon.Services
local LootSourceCandidates = addon.LootSourceCandidates
local Timer = addon.Timer
local Time = addon.Time
local Bus = addon.Bus
local Events = addon.Events
local GetCurrentTime = assert(Time and Time.GetCurrentTime, Diag.A.LoggerActionsTimeProviderNotInitialized)
local TriggerEvent = assert(Bus.TriggerEvent, Diag.A.LoggerActionsEventPublisherNotInitialized)
local InternalEvents = assert(Events.Internal, Diag.A.LoggerActionsInternalEventsNotInitialized)
local LoggerLootChangedEvent =
	assert(InternalEvents.LoggerLootChanged, Diag.A.LoggerActionsLootChangedEventNotInitialized)
local LoggerDataChangedEvent =
	assert(InternalEvents.LoggerDataChanged, Diag.A.LoggerActionsDataChangedEventNotInitialized)

local function notifyLoggerDataChanged(reason, result)
	TriggerEvent(LoggerDataChangedEvent, {
		reason = reason,
		result = result,
	})
end

local tinsert = table.insert
local tremove = table.remove
local ipairs = ipairs
local pairs, type = pairs, type
local tonumber, tostring = tonumber, tostring
local lower = string.lower
local abs = math.abs
local EPIC_ITEM_RARITY = 4
local RAW_QUERY_OPTS = { raw = true }
local ITEM_LINK_RARITIES = {
	ff9d9d9d = 0,
	ffffffff = 1,
	ff1eff00 = 2,
	ff0070dd = 3,
	ffa335ee = 4,
	ffff8000 = 5,
	ffe6cc80 = 6,
	ffe5cc80 = 6,
}
local HISTORY_SCAN_CHUNK_SIZE = 25
local HISTORY_SCAN_DELAY_SECONDS = 0.01
local LOOT_SOURCE_REBUILD_CHUNK_SIZE = 25
local LOOT_SOURCE_REBUILD_DELAY_SECONDS = 0.01
local HISTORY_CLEANUP_CHUNK_SIZE = 25
local HISTORY_CLEANUP_DELAY_SECONDS = 0.01

-- ----- Internal state ----- --
addon.Services.EnsureNamespace("Logger", "Actions")
local Logger = Services.Logger
local Actions = Logger.Actions
local Store = Logger.Store
local Helpers = Logger.Helpers
local LootSources = addon.LootSources
local LootSourcesData = addon.LootSourcesData
Timer.BindMixin(Actions, "Logger.Actions")

local commitRaidSelections
local resolveLoggerLootEntry
local applyLoggerLootMutation
local verifyLoggerLootMutation
local trimText
local hasRaidData
local getCurrentRaidNid
local restoreCurrentRaidIndex
local findBossByNid
local findBossByName
local findBossBySourceNpcId
local shouldRebuildLootSource
local resolveLootSource
local findOrCreateStaticSourceBoss
local applyStaticLootSource
local playerExists
local scanRaidHistory
local activeHistoryScan
local activeHistoryCleanup
local activeLootSourceRebuild

-- ----- Private helpers ----- --

trimText = function(value)
	if Strings.TrimText then
		return Strings.TrimText(value or "")
	end
	return Strings.NormalizeName(value) or ""
end

local function hasTableEntries(value)
	if type(value) ~= "table" then
		return false
	end
	return next(value) ~= nil
end

local function countTableEntries(value)
	if type(value) ~= "table" then
		return 0
	end
	local count = 0
	for _ in pairs(value) do
		count = count + 1
	end
	return count
end

local function getRaidFirstTime(raid)
	local best
	local bosses = raid and raid.bossKills or {}
	for i = 1, #bosses do
		local ts = tonumber(bosses[i] and bosses[i].time)
		if ts and ts > 0 and (not best or ts < best) then
			best = ts
		end
	end
	local lootRows = raid and raid.loot or {}
	for i = 1, #lootRows do
		local ts = tonumber(lootRows[i] and lootRows[i].time)
		if ts and ts > 0 and (not best or ts < best) then
			best = ts
		end
	end
	return best or 0
end

hasRaidData = function(raid)
	if type(raid) ~= "table" then
		return false
	end
	return hasTableEntries(raid.players)
		or hasTableEntries(raid.bossKills)
		or hasTableEntries(raid.loot)
		or hasTableEntries(raid.attendance)
		or hasTableEntries(raid.changes)
end

local function getLootRarity(loot)
	if type(loot) ~= "table" then
		return nil
	end
	local rarity = tonumber(loot.itemRarity or loot.itemQuality or loot.quality or loot.rarity)
	if rarity then
		return rarity
	end
	local color = type(loot.itemLink) == "string" and loot.itemLink:match("|c(%x%x%x%x%x%x%x%x)|Hitem:") or nil
	if color then
		return ITEM_LINK_RARITIES[lower(color)]
	end
	return nil
end

local function isNonEpicLoot(loot)
	local rarity = getLootRarity(loot)
	return rarity ~= nil and rarity < EPIC_ITEM_RARITY
end

local function isRaidWithoutBossEncounter(raid)
	return hasRaidData(raid) and countTableEntries(raid and raid.bossKills) <= 0
end

playerExists = function(raid, playerNid)
	local queryNid = tonumber(playerNid)
	if not (raid and queryNid and queryNid > 0) then
		return false
	end
	local players = raid.players or {}
	for i = 1, #players do
		if tonumber(players[i] and players[i].playerNid) == queryNid then
			return true
		end
	end
	return false
end

getCurrentRaidNid = function()
	local currentRaid = Database.GetCurrentRaid()
	if not currentRaid then
		return nil
	end
	local raids = Database.GetRaidStore():GetAllRaids()
	return tonumber(raids[currentRaid] and raids[currentRaid].raidNid)
end

restoreCurrentRaidIndex = function(currentRaidNid)
	if not currentRaidNid then
		Database.SetCurrentRaid(nil)
		Database.SetLastBoss(nil)
		return
	end

	local currentRaidId
	local raids = Database.GetRaidStore():GetAllRaids()
	for i = 1, #raids do
		if tonumber(raids[i] and raids[i].raidNid) == tonumber(currentRaidNid) then
			currentRaidId = i
			break
		end
	end
	Database.SetCurrentRaid(currentRaidId)
	if not currentRaidId then
		Database.SetLastBoss(nil)
	end
end

findBossByNid = function(raid, bossNid, opts)
	local queries = Database.GetRaidQueries()
	return queries:FindBossByNid(raid, bossNid, opts)
end

findBossByName = function(raid, bossName, opts)
	local queries = Database.GetRaidQueries()
	return queries:FindBossByName(raid, bossName, opts)
end

findBossBySourceNpcId = function(raid, sourceNpcId, opts)
	local queries = Database.GetRaidQueries()
	return queries:FindBossBySourceNpcId(raid, sourceNpcId, opts)
end

local function findBossBySourceKey(raid, sourceKey, opts)
	local queries = Database.GetRaidQueries()
	return queries:FindBossBySourceKey(raid, sourceKey, opts)
end

shouldRebuildLootSource = function(raid, loot)
	if type(loot) ~= "table" then
		return false
	end

	local boss = findBossByNid(raid, loot.bossNid)
	local sourceName = boss and trimText(boss.name or boss.boss) or ""
	return sourceName == ""
end

resolveLootSource = function(raid, loot)
	local resolver = LootSources
	if type(resolver) ~= "table" or type(resolver.FindSource) ~= "function" then
		return nil
	end

	local itemId = tonumber(loot and loot.itemId)
	if not itemId or itemId <= 0 then
		return nil
	end

	local context = {
		raid = raid and raid.zone or nil,
		zoneName = raid and raid.zone or nil,
		instanceName = raid and raid.zone or nil,
		raidSize = tonumber(raid and raid.size) or 0,
		difficulty = tonumber(raid and raid.difficulty) or 0,
	}
	local source = resolver.FindSource(itemId, context)
	if type(source) ~= "table" or source.reason == "missing" or source.reason == "ambiguous" then
		return nil
	end
	return source
end

findOrCreateStaticSourceBoss = function(raid, raidIndex, source, sourceTime)
	if type(raid) ~= "table" or type(source) ~= "table" then
		return 0, false
	end

	local sourceKind = source.kind
	local sourceNpcId = tonumber(source.npcId) or 0
	local sourceName = trimText(source.npcName)
	if sourceName == "" then
		return 0, false
	end
	if sourceKind ~= "shared" and sourceNpcId <= 0 then
		return 0, false
	end

	local sourceKey = trimText(source.sourceKey)
	local existingBoss = (sourceKind ~= "shared" and findBossBySourceKey(raid, sourceKey))
		or findBossBySourceNpcId(raid, sourceNpcId)
		or findBossByName(raid, sourceName)
	local existingBossNid = tonumber(existingBoss and existingBoss.bossNid) or 0
	if existingBossNid > 0 then
		return existingBossNid, false
	end

	Database.EnsureRaidSchema(raid)
	raid.bossKills = raid.bossKills or {}

	local bossNid = tonumber(raid.nextBossNid) or 1
	raid.nextBossNid = bossNid + 1

	local difficulty = tonumber(raid.difficulty) or 0
	local hashPrefix = tonumber(raid.raidNid) or tonumber(raidIndex) or 0
	tinsert(raid.bossKills, {
		bossNid = bossNid,
		name = sourceName,
		sourceNpcId = sourceNpcId,
		sourceKind = sourceKind,
		sourceKey = sourceKind ~= "shared" and sourceKey ~= "" and sourceKey or nil,
		source = "LootSources",
		difficulty = difficulty,
		mode = (difficulty == 3 or difficulty == 4) and "h" or "n",
		players = {},
		time = tonumber(sourceTime) or GetCurrentTime(),
		hash = Base64.Encode(tostring(hashPrefix) .. "|" .. sourceName .. "|" .. tostring(bossNid)),
	})
	return bossNid, true
end

applyStaticLootSource = function(loot, source, bossNid)
	local sourceName = trimText(source.npcName)
	loot.bossNid = bossNid
	loot.lootSource = {
		kind = source.kind,
		bossNid = bossNid,
		sourceNpcId = tonumber(source.npcId) or 0,
		sourceName = sourceName,
		sourceKey = trimText(source.sourceKey) ~= "" and trimText(source.sourceKey) or nil,
	}
	if source.kind == "shared" then
		loot.lootSource.sourceName = "Shared"
		loot.lootSource.candidates = LootSourceCandidates.Copy(source.candidates)
	end
end

local function scanRaidPlayers(raid, result)
	local seenNames = {}
	local playersWithLoot = {}
	local lootRows = raid.loot or {}

	for i = 1, #lootRows do
		local looterNid = tonumber(lootRows[i] and lootRows[i].looterNid) or 0
		if looterNid > 0 then
			playersWithLoot[looterNid] = true
		end
	end

	local players = raid.players or {}
	for i = 1, #players do
		local player = players[i]
		local playerNid = tonumber(player and player.playerNid) or 0
		local playerName = trimText(player and player.name)
		if playerNid > 0 and not playersWithLoot[playerNid] then
			result.playersWithoutLoot = result.playersWithoutLoot + 1
		end
		if playerName ~= "" then
			local key = lower(playerName)
			local existing = seenNames[key]
			if existing and existing ~= playerName then
				result.playerNameConflicts = result.playerNameConflicts + 1
			elseif not existing then
				seenNames[key] = playerName
			end
		end
	end
end

local function scanRaidBosses(raid, result)
	local lootByBoss = {}
	local lootRows = raid.loot or {}
	for i = 1, #lootRows do
		local bossNid = tonumber(lootRows[i] and lootRows[i].bossNid) or 0
		if bossNid > 0 then
			lootByBoss[bossNid] = true
		end
	end

	local bosses = raid.bossKills or {}
	for i = 1, #bosses do
		local bossNid = tonumber(bosses[i] and bosses[i].bossNid) or 0
		if bossNid > 0 and not lootByBoss[bossNid] then
			result.bossesWithoutLoot = result.bossesWithoutLoot + 1
		end
	end
end

local function scanRaidLoot(raid, result)
	local lootRows = raid.loot or {}
	for i = 1, #lootRows do
		local loot = lootRows[i]
		if type(loot) == "table" then
			result.lootRows = result.lootRows + 1
			if isNonEpicLoot(loot) then
				result.nonEpicLoot = result.nonEpicLoot + 1
			end
			local bossNid = tonumber(loot.bossNid) or 0
			if bossNid <= 0 then
				result.missingSources = result.missingSources + 1
			elseif not findBossByNid(raid, bossNid, RAW_QUERY_OPTS) then
				result.invalidSources = result.invalidSources + 1
			end

			local looterNid = tonumber(loot.looterNid) or 0
			if looterNid > 0 and not playerExists(raid, looterNid) then
				result.orphanLoot = result.orphanLoot + 1
			end
		end
	end
end

local function scanRaidAttendance(raid, result)
	local attendance = raid.attendance or {}
	for _, row in pairs(attendance) do
		local playerNid = tonumber(row and row.playerNid) or tonumber(row and row.nid) or 0
		if playerNid > 0 and not playerExists(raid, playerNid) then
			result.orphanAttendance = result.orphanAttendance + 1
		end
	end
end

local function newHistoryScanResult()
	return {
		raids = 0,
		emptyRaids = 0,
		raidsWithoutBosses = 0,
		lootRows = 0,
		nonEpicLoot = 0,
		missingSources = 0,
		invalidSources = 0,
		orphanLoot = 0,
		orphanAttendance = 0,
		playersWithoutLoot = 0,
		bossesWithoutLoot = 0,
		playerNameConflicts = 0,
		duplicateRaidCandidates = 0,
	}
end

local function scanRaidHistoryRow(raid, result)
	if type(raid) ~= "table" then
		return
	end
	if not hasRaidData(raid) then
		result.emptyRaids = result.emptyRaids + 1
	end
	if isRaidWithoutBossEncounter(raid) then
		result.raidsWithoutBosses = result.raidsWithoutBosses + 1
	end
	scanRaidPlayers(raid, result)
	scanRaidBosses(raid, result)
	scanRaidLoot(raid, result)
	scanRaidAttendance(raid, result)
end

local function countDuplicateRaidCandidatesForIndex(raids, index)
	local count = 0
	local left = raids[index]
	if hasRaidData(left) then
		local leftTime = getRaidFirstTime(left)
		for j = index + 1, #raids do
			local right = raids[j]
			if
				hasRaidData(right)
				and trimText(left.zone) == trimText(right.zone)
				and (tonumber(left.size) or 0) == (tonumber(right.size) or 0)
				and (tonumber(left.difficulty) or 0) == (tonumber(right.difficulty) or 0)
			then
				local rightTime = getRaidFirstTime(right)
				if leftTime <= 0 or rightTime <= 0 or abs(leftTime - rightTime) <= 1800 then
					count = count + 1
				end
			end
		end
	end
	return count
end

local function countDuplicateRaidCandidates(raids)
	local count = 0
	for i = 1, #raids do
		count = count + countDuplicateRaidCandidatesForIndex(raids, i)
	end
	return count
end

local function getRaidHistoryScanRaids()
	return Database.GetRaidStore():GetAllRaids()
end

local function normalizeHistoryScanChunkSize(value)
	local chunkSize = tonumber(value) or HISTORY_SCAN_CHUNK_SIZE
	if chunkSize < 1 then
		return HISTORY_SCAN_CHUNK_SIZE
	end
	return chunkSize
end

local function normalizeHistoryScanDelay(value)
	local delay = tonumber(value) or HISTORY_SCAN_DELAY_SECONDS
	if delay < 0 then
		return HISTORY_SCAN_DELAY_SECONDS
	end
	return delay
end

local function normalizeLootSourceRebuildChunkSize(value)
	local chunkSize = tonumber(value) or LOOT_SOURCE_REBUILD_CHUNK_SIZE
	if chunkSize < 1 then
		return LOOT_SOURCE_REBUILD_CHUNK_SIZE
	end
	return chunkSize
end

local function normalizeLootSourceRebuildDelay(value)
	local delay = tonumber(value) or LOOT_SOURCE_REBUILD_DELAY_SECONDS
	if delay < 0 then
		return LOOT_SOURCE_REBUILD_DELAY_SECONDS
	end
	return delay
end

local function normalizeHistoryCleanupChunkSize(value)
	local chunkSize = tonumber(value) or HISTORY_CLEANUP_CHUNK_SIZE
	if chunkSize < 1 then
		return HISTORY_CLEANUP_CHUNK_SIZE
	end
	return chunkSize
end

local function normalizeHistoryCleanupDelay(value)
	local delay = tonumber(value) or HISTORY_CLEANUP_DELAY_SECONDS
	if delay < 0 then
		return HISTORY_CLEANUP_DELAY_SECONDS
	end
	return delay
end

local function cancelHistoryScan(state)
	if state and state.handle then
		Actions:CancelTimer(state.handle)
		state.handle = nil
	end
	if activeHistoryScan == state then
		activeHistoryScan = nil
	end
end

local function finalizeHistoryCleanupState(state)
	if not (state and state.raidStore) or state.finalized then
		return
	end
	state.finalized = true
	restoreCurrentRaidIndex(state.currentRaidNid)
end

local function cancelHistoryCleanup(state)
	if not state or state.terminal then
		return false
	end
	if state and state.handle then
		Actions:CancelTimer(state.handle)
		state.handle = nil
	end
	finalizeHistoryCleanupState(state)
	if state and type(state.result) == "table" then
		state.result.cancelled = true
		state.result.complete = false
	end
	state.terminal = true
	if activeHistoryCleanup == state then
		activeHistoryCleanup = nil
	end
	if state and type(state.callback) == "function" then
		state.callback(state.result, false)
	end
	return true
end

local function restoreLootSourceInstance(instanceKey)
	if instanceKey then
		LootSourcesData.ActivateInstance(instanceKey)
	else
		LootSourcesData.DeactivateInstance()
	end
end

local function withHistoricalLootSourceInstance(instanceName, callback)
	local entryInstanceKey = LootSourcesData.GetActiveInstanceKey()
	local function runHistoricalCallback()
		local activated = LootSourcesData.ActivateInstance(instanceName) == true
		return callback(activated)
	end
	local ok, result = pcall(runHistoricalCallback)
	restoreLootSourceInstance(entryInstanceKey)
	if not ok then
		error(result)
	end
	return result
end

local function cancelLootSourceRebuild(state)
	if state and state.handle then
		Actions:CancelTimer(state.handle)
		state.handle = nil
	end
	if activeLootSourceRebuild == state then
		activeLootSourceRebuild = nil
	end
end

local function scheduleChunkedAction(state, callback)
	if state.cancelled then
		return
	end
	state.handle = Actions:ScheduleTimer(callback, state.delay)
end

local function newHistoryCleanupResult()
	return {
		emptyRaids = 0,
		nonEpicLoot = 0,
		noBossEncounter = 0,
		raidsRemoved = 0,
		lootRemoved = 0,
		affectedRaidNids = {},
		changed = false,
		complete = false,
		cancelled = false,
		failed = false,
	}
end

local function getHistoryCleanupContext()
	local raidStore = Database.GetRaidStore()
	local raids = raidStore:GetAllRaids()
	local archive = raidStore:EnsureArchive()
	return raidStore, raids, archive and archive.activeRaidUid or nil
end

local function newHistoryCleanupPlan(protectedRaidNid, protectedArchiveKey)
	return {
		raidNids = {},
		raidCandidates = {},
		lootNidsByRaidNid = {},
		lootCandidates = {},
		emptyRaids = 0,
		noBossEncounter = 0,
		protectedRaidNid = tonumber(protectedRaidNid),
		protectedArchiveKey = protectedArchiveKey,
	}
end

local function getHistoryCleanupBaseDigest(raid)
	return Database.GetRaidStore():GetStateDigest(raid)
end

local function stageRaidForHistoryCleanup(raid, plan, key, archiveKey)
	local raidNid = tonumber(raid and raid.raidNid)
	if not raidNid then
		return
	end
	if archiveKey and archiveKey == plan.protectedArchiveKey then
		return
	end
	if not archiveKey and raidNid == tonumber(plan.protectedRaidNid) then
		return
	end
	plan.raidNids[#plan.raidNids + 1] = raidNid
	plan.raidCandidates[#plan.raidCandidates + 1] = {
		raidNid = raidNid,
		archiveKey = archiveKey,
		baseDigest = getHistoryCleanupBaseDigest(raid),
		predicate = key,
	}
	plan[key] = plan[key] + 1
end

local function stageNonEpicLootAt(raid, lootRows, index, plan, archiveKey)
	if archiveKey and archiveKey == plan.protectedArchiveKey then
		return false
	end
	local loot = lootRows and lootRows[index] or nil
	if isNonEpicLoot(loot) then
		local raidNid = tonumber(raid and raid.raidNid)
		local lootNid = tonumber(loot and loot.lootNid)
		if not (raidNid and lootNid) then
			return false
		end
		local lootNids = plan.lootNidsByRaidNid[raidNid]
		if not lootNids then
			lootNids = {}
			plan.lootNidsByRaidNid[raidNid] = lootNids
		end
		lootNids[#lootNids + 1] = lootNid
		plan.lootCandidates[#plan.lootCandidates + 1] = {
			raidNid = raidNid,
			archiveKey = archiveKey,
			baseDigest = getHistoryCleanupBaseDigest(raid),
			lootNid = lootNid,
			itemId = tonumber(loot.itemId),
			itemLink = loot.itemLink,
			bossNid = tonumber(loot.bossNid),
		}
		return true
	end
	return false
end

local function executeHistoryCleanupPlan(raidStore, plan, result)
	local currentIdentity = plan.protectedArchiveKey or getCurrentRaidNid()
	local committed, failure = raidStore:CommitRaidHistoryCleanup(plan, currentIdentity)
	if not committed then
		return false, failure
	end
	result.emptyRaids = plan.emptyRaids
	result.noBossEncounter = plan.noBossEncounter
	result.raidsRemoved = committed.raidsRemoved
	result.lootRemoved = committed.lootRemoved
	result.nonEpicLoot = committed.lootRemoved
	result.affectedRaidNids = committed.affectedRaidNids
	for i = 1, #committed.removedRaidNids do
		result.affectedRaidNids[#result.affectedRaidNids + 1] = committed.removedRaidNids[i]
	end
	result.changed = result.raidsRemoved > 0 or result.lootRemoved > 0
	result.complete = true
	return true
end

local function newLootSourceRebuildResult()
	return {
		raids = 0,
		scanned = 0,
		repaired = 0,
		bossesCreated = 0,
		unresolved = 0,
		changed = false,
		complete = false,
		cancelled = false,
		failed = false,
		conflict = false,
		partial = false,
		affectedRaidNids = {},
	}
end

local function getLootSourceRebuildRaids()
	local raidStore = Database.GetRaidStore()
	local allRaids = raidStore:GetAllRaids()
	local activeRecord = raidStore:GetActiveRecord()
	local activeRaid = type(activeRecord) == "table" and activeRecord.state or nil
	local completed = {}
	for i = 1, #(allRaids or {}) do
		if allRaids[i] ~= activeRaid then
			completed[#completed + 1] = allRaids[i]
		end
	end
	return completed
end

local function applyLootSourceRebuildChange(raid, stagedRaid)
	return Database.GetRaidStore():CommitRaidHistoryMutation(raid, stagedRaid, { reason = "rebuild_sources" })
end

local function rebuildLootSourceRow(raid, raidIndex, loot, result, sourceResolutionAvailable)
	if type(loot) ~= "table" then
		return false
	end

	result.scanned = result.scanned + 1
	if shouldRebuildLootSource(raid, loot) then
		local source
		if sourceResolutionAvailable ~= false then
			source = resolveLootSource(raid, loot)
		end
		local bossNid, created = findOrCreateStaticSourceBoss(raid, raidIndex, source, loot.time)
		if bossNid > 0 then
			applyStaticLootSource(loot, source, bossNid)
			result.repaired = result.repaired + 1
			if created then
				result.bossesCreated = result.bossesCreated + 1
			end
			return true
		end
		result.unresolved = result.unresolved + 1
	end
	return false
end

scanRaidHistory = function()
	local raids = getRaidHistoryScanRaids()
	local result = newHistoryScanResult()
	if type(raids) ~= "table" then
		return result
	end

	result.raids = #raids
	for i = 1, #raids do
		scanRaidHistoryRow(raids[i], result)
	end
	result.duplicateRaidCandidates = countDuplicateRaidCandidates(raids)
	return result
end

-- ----- Public methods ----- --

commitRaidSelections = function(raid, opts)
	if not raid then
		return
	end
	opts = opts or {}

	-- Rebuild canonical raid schema/runtime indexes after in-place mutations.
	Database.EnsureRaidSchema(raid)

	if opts.invalidate ~= false then
		Store._InvalidateIndexes(raid)
	end

	local log = type(opts.selectionState) == "table" and opts.selectionState or nil
	if not log then
		return
	end

	local changedBoss, changedPlayer, changedBossPlayer, changedItem = false, false, false, false

	local function clearBossSelection()
		if log.selectedBoss ~= nil then
			changedBoss = true
		end
		if log.selectedBossPlayer ~= nil then
			changedBossPlayer = true
		end
		if log.selectedItem ~= nil then
			changedItem = true
		end
		log.selectedBoss = nil
		log.selectedBossPlayer = nil
		log.selectedItem = nil
	end

	-- Validate boss selection (bossNid)
	if log.selectedBoss then
		local bossKill = Store:GetBoss(raid, log.selectedBoss)
		if not bossKill then
			clearBossSelection()
		end
	else
		-- No boss selected: dependent selections must be cleared
		if log.selectedBossPlayer ~= nil then
			log.selectedBossPlayer = nil
			changedBossPlayer = true
		end
		if log.selectedItem ~= nil then
			log.selectedItem = nil
			changedItem = true
		end
	end

	-- Validate loot selection (lootNid)
	if log.selectedItem then
		local lootEntry = Store:GetLoot(raid, log.selectedItem)
		if not lootEntry then
			log.selectedItem = nil
			changedItem = true
		end
	end

	-- Validate player selections (playerNid).
	if opts.clearPlayers then
		if log.selectedPlayer ~= nil then
			log.selectedPlayer = nil
			changedPlayer = true
		end
		if log.selectedBossPlayer ~= nil then
			log.selectedBossPlayer = nil
			changedBossPlayer = true
		end
	else
		if log.selectedPlayer and not Store:GetPlayer(raid, log.selectedPlayer) then
			log.selectedPlayer = nil
			changedPlayer = true
		end
		if log.selectedBossPlayer and not Store:GetPlayer(raid, log.selectedBossPlayer) then
			log.selectedBossPlayer = nil
			changedBossPlayer = true
		end
	end

	local triggerSelectionEvent = opts.triggerSelectionEvent
	if type(triggerSelectionEvent) == "function" then
		if changedBoss then
			triggerSelectionEvent(log, "selectedBoss")
		end
		if changedPlayer then
			triggerSelectionEvent(log, "selectedPlayer")
		end
		if changedBossPlayer then
			triggerSelectionEvent(log, "selectedBossPlayer")
		end
		if changedItem then
			triggerSelectionEvent(log, "selectedItem")
		end
	end
end

resolveLoggerLootEntry = function(raidID, lootNid)
	local raid = Store:GetRaid(raidID)
	if not raid then
		addon:error(Diag.E.LogLoggerNoRaidSession:format(tostring(raidID), tostring(lootNid)))
		return nil, nil
	end

	local lootCount = raid.loot and #raid.loot or 0
	local it = Store:GetLoot(raid, lootNid)
	if not it then
		local rawItemMatch, rawItemMatches = Helpers.FindLootByItemId(raid, lootNid)
		if rawItemMatch and addon.error then
			addon:error(
				Diag.E.LogLoggerLootNidExpected:format(
					tostring(raidID),
					tostring(lootNid),
					tostring(rawItemMatch.itemLink),
					tonumber(rawItemMatches) or 0
				)
			)
		end
		addon:error(Diag.E.LogLoggerItemNotFound:format(raidID, tostring(lootNid), lootCount))
		return nil, nil
	end

	return raid, it
end

applyLoggerLootMutation = function(raid, it, raidID, lootNid, looter, rollType, rollValue)
	if not looter or looter == "" then
		addon:warn(Diag.W.LogLoggerLooterEmpty:format(raidID, tostring(lootNid), tostring(it.itemLink)))
	end
	if rollType == nil then
		addon:warn(Diag.W.LogLoggerRollTypeNil:format(raidID, tostring(lootNid), tostring(looter)))
	end

	local currentLooterName = Store._ResolveLootLooterName(raid, it)
	if addon.hasDebug then
		addon:debug(
			Diag.D.LogLoggerLootBefore:format(
				raidID,
				tostring(lootNid),
				tostring(it.itemLink),
				tostring(currentLooterName),
				tostring(it.rollType),
				tostring(it.rollValue)
			)
		)
	end
	if currentLooterName and currentLooterName ~= "" and looter and looter ~= "" and currentLooterName ~= looter then
		addon:warn(
			Diag.W.LogLoggerLootOverwrite:format(
				raidID,
				tostring(lootNid),
				tostring(it.itemLink),
				tostring(currentLooterName),
				tostring(looter)
			)
		)
	end

	local expectedLooterNid
	local expectedRollType
	local expectedRollValue
	if looter and looter ~= "" then
		local looterNid = Store._ResolveLootLooterNid(raid, looter)
		if not looterNid then
			addon:warn(Diag.W.LogLoggerLooterEmpty:format(raidID, tostring(lootNid), tostring(it.itemLink)))
			return false, nil, nil, nil
		end
		it.looterNid = looterNid
		it.looter = nil
		expectedLooterNid = looterNid
	end
	local normalizedRollType = Helpers.NormalizeRollType(rollType)
	if normalizedRollType then
		it.rollType = normalizedRollType
		expectedRollType = normalizedRollType
	end
	local normalizedRollValue = Helpers.NormalizeRollValue(rollValue)
	if normalizedRollValue then
		it.rollValue = normalizedRollValue
		expectedRollValue = normalizedRollValue
	end

	return true, expectedLooterNid, expectedRollType, expectedRollValue
end

verifyLoggerLootMutation = function(
	raidID,
	lootNid,
	it,
	recordedLooterName,
	expectedLooterNid,
	expectedRollType,
	expectedRollValue
)
	local ok = true
	if expectedLooterNid and tonumber(it.looterNid) ~= expectedLooterNid then
		ok = false
	end
	if expectedRollType and it.rollType ~= expectedRollType then
		ok = false
	end
	if expectedRollValue and it.rollValue ~= expectedRollValue then
		ok = false
	end
	if not ok then
		addon:error(
			Diag.E.LogLoggerVerifyFailed:format(
				raidID,
				tostring(lootNid),
				tostring(recordedLooterName),
				tostring(it.rollType),
				tostring(it.rollValue)
			)
		)
		return false
	end

	if addon.hasDebug then
		addon:debug(Diag.D.LogLoggerVerified:format(raidID, tostring(lootNid)))
		if not Database.GetLastBoss() then
			addon:debug(Diag.D.LogLoggerRecordedNoBossContext:format(raidID, tostring(lootNid), tostring(it.itemLink)))
		end
	end
	return true
end
local function resolveLootEditRaidId(source, selectedRaid, currentRaid, raidIDOverride)
	if raidIDOverride then
		return raidIDOverride
	end

	local isLoggerSource = (type(source) == "string") and (source:find("^LOGGER_") ~= nil)
	if isLoggerSource then
		return selectedRaid or currentRaid
	end
	return currentRaid or selectedRaid
end

local function setLootEntry(raidID, lootNid, looter, rollType, rollValue, source)
	if addon.hasTrace then
		addon:trace(
			Diag.D.LogLoggerLootLogAttempt:format(
				tostring(source),
				tostring(raidID),
				tostring(lootNid),
				tostring(looter),
				tostring(rollType),
				tostring(rollValue),
				tostring(Database.GetLastBoss())
			)
		)
	end

	local raid, it = resolveLoggerLootEntry(raidID, lootNid)
	if not raid then
		return false
	end
	local raidStore = Database.GetRaidStore()
	local raidUid = raidStore:GetRaidUid(raid)
	local raidRecord = raidUid and raidStore:GetRecord(raidUid) or nil
	local isActiveRaid = raidRecord and raidRecord.status == "active"
	local stagedLoot = {}
	local stagedRaid
	if isActiveRaid then
		for key, value in pairs(it) do
			stagedLoot[key] = value
		end
	else
		stagedRaid = raidStore:StageRaidHistoryMutation(raid)
		for i = 1, #(stagedRaid and stagedRaid.loot or {}) do
			if tonumber(stagedRaid.loot[i].lootNid) == tonumber(lootNid) then
				stagedLoot = stagedRaid.loot[i]
				break
			end
		end
	end
	it = stagedLoot

	local ok, expectedLooterNid, expectedRollType, expectedRollValue =
		applyLoggerLootMutation(raid, it, raidID, lootNid, looter, rollType, rollValue)
	if not ok then
		return false
	end

	local recordedLooterName = Store._ResolveLootLooterName(raid, it)
	if addon.hasDebug then
		addon:debug(
			Diag.D.LogLoggerLootRecorded:format(
				tostring(source),
				raidID,
				tostring(lootNid),
				tostring(it.itemLink),
				tostring(recordedLooterName),
				tostring(it.rollType),
				tostring(it.rollValue)
			)
		)
	end

	if
		not verifyLoggerLootMutation(
			raidID,
			lootNid,
			it,
			recordedLooterName,
			expectedLooterNid,
			expectedRollType,
			expectedRollValue
		)
	then
		return false
	end
	if isActiveRaid then
		return raidStore:CommitAuthoritativeEvent(raidUid, "LOOT_UPDATED", { loot = it }) ~= nil
	end
	return raidStore:CommitRaidHistoryMutation(raid, stagedRaid, { lootNid = lootNid }) == true
end

function Actions:RecordLoot(request)
	if type(request) ~= "table" then
		return false, "INVALID_REQUEST"
	end

	local source = request.source
	local raidID = resolveLootEditRaidId(
		source,
		request.selectedRaid,
		request.currentRaid or Database.GetCurrentRaid(),
		request.raidId or request.raidID
	)
	local lootNid = request.lootNid or request.itemID
	local ok = setLootEntry(raidID, lootNid, request.looter, request.rollType, request.rollValue, source)
	if not ok then
		return false, "WRITE_FAILED"
	end

	TriggerEvent(LoggerLootChangedEvent, {
		raidId = raidID,
		lootNid = lootNid,
		source = source,
	})
	return true
end

function Actions:ResolveLootEditWinner(raidID, lootNid, rawText)
	local text = trimText(rawText)
	local normalizedName = Strings.NormalizeLower(text)
	if not normalizedName or normalizedName == "" then
		return nil, L.ErrLoggerWinnerEmpty
	end

	local raid = Store:GetRaid(raidID)
	if not raid then
		return nil, L.ErrLoggerInvalidRaid
	end

	local loot = Store:GetLoot(raid, lootNid)
	if not loot then
		return nil, L.ErrLoggerInvalidItem
	end

	local bossKill = (loot.bossNid and raid) and Store:GetBoss(raid, loot.bossNid) or nil
	local winner = Helpers.FindLoggerPlayer(normalizedName, raid, bossKill)
	if not winner then
		return nil, L.ErrLoggerWinnerNotFound:format(text)
	end

	return winner
end

-- Bulk delete: removes multiple loot entries (by nid) with a single Commit()
-- Returns: number of removed entries
function Actions:DeleteLootMany(rID, lootNids, opts)
	local raid = Store:GetRaid(rID)
	if not (raid and lootNids and raid.loot) then
		return 0
	end
	local raidStore = Database.GetRaidStore()
	local archiveKey = raidStore:GetArchiveKeyByIndex(rID)
	local removed = archiveKey and raidStore:DeleteLootByArchiveKey(archiveKey, lootNids)
		or raidStore:DeleteLootByNid(raid.raidNid, lootNids, "loot_delete")

	if removed > 0 then
		commitRaidSelections(raid, opts)
	end
	return removed
end

function Actions:DeleteRaid(rID)
	local sel = tonumber(rID)
	local raid = sel and Database.EnsureRaidByIndex(sel) or nil
	if not raid then
		return false
	end

	if Database.GetCurrentRaid() and Database.GetCurrentRaid() == sel then
		addon:error(L.ErrCannotDeleteRaid)
		return false
	end

	local raidStore = Database.GetRaidStore()
	local removedIdx = sel
	local archiveKey = raidStore:GetArchiveKeyByIndex(sel)
	local deleted, idx
	if archiveKey then
		deleted, idx = raidStore:DeleteRaidByArchiveKey(archiveKey)
	else
		deleted, idx = raidStore:DeleteRaid(raid.raidNid)
	end
	if not deleted then
		return false
	end
	removedIdx = idx or removedIdx

	if Database.GetCurrentRaid() and Database.GetCurrentRaid() > removedIdx then
		Database.SetCurrentRaid(Database.GetCurrentRaid() - 1)
	end

	return true
end

function Actions:DeleteRaidsByIndex(raidIndexes)
	local result = { removed = 0, affectedRaidNids = {}, changed = false, complete = true }
	if type(raidIndexes) ~= "table" then
		return result
	end
	local raidStore = Database.GetRaidStore()
	local archive = raidStore:EnsureArchive()
	local protectedArchiveKey = archive and archive.activeRaidUid or nil
	local archiveKeys, seen = {}, {}
	for i = 1, #raidIndexes do
		local archiveKey = raidStore:GetArchiveKeyByIndex(raidIndexes[i])
		if archiveKey and archiveKey ~= protectedArchiveKey and not seen[archiveKey] then
			seen[archiveKey] = true
			archiveKeys[#archiveKeys + 1] = archiveKey
		end
	end
	local removedKeys
	result.removed, removedKeys = raidStore:DeleteRaidsByArchiveKey(archiveKeys, protectedArchiveKey)
	if result.removed > 0 then
		result.changed = true
		for i = 1, #removedKeys do
			result.affectedRaidNids[#result.affectedRaidNids + 1] = removedKeys[i]
		end
		if protectedArchiveKey then
			Database.SetCurrentRaid(raidStore:GetIndexByArchiveKey(protectedArchiveKey))
		end
		notifyLoggerDataChanged("raid_delete", result)
	end
	return result
end

function Actions:DeleteRaidByNid(raidNid)
	local nid = tonumber(raidNid)
	if not nid then
		return false
	end
	local raid, sel = Database.EnsureRaidByNid(nid)
	if not (raid and sel) then
		return false
	end

	local currentRaidNid = Database.GetRaidNidByIndex(Database.GetCurrentRaid())
	if currentRaidNid and tonumber(currentRaidNid) == nid then
		addon:error(L.ErrCannotDeleteRaid)
		return false
	end

	local raidStore = Database.GetRaidStore()
	local removedIdx = sel
	local deleted, idx = raidStore:DeleteRaid(nid)
	if not deleted then
		return false
	end
	removedIdx = idx or removedIdx

	if Database.GetCurrentRaid() and Database.GetCurrentRaid() > removedIdx then
		Database.SetCurrentRaid(Database.GetCurrentRaid() - 1)
	end

	return true
end

function Actions:DeleteRaidsByNid(raidNids)
	local result = { removed = 0, affectedRaidNids = {}, changed = false, complete = true }
	if type(raidNids) ~= "table" then
		return result
	end
	local currentRaidNid = getCurrentRaidNid()
	local candidates = {}
	local seen = {}
	for i = 1, #raidNids do
		local raidNid = tonumber(raidNids[i])
		if raidNid and raidNid ~= tonumber(currentRaidNid) and not seen[raidNid] then
			seen[raidNid] = true
			candidates[#candidates + 1] = raidNid
		end
	end
	local removedRaidNids
	result.removed, removedRaidNids = Database.GetRaidStore():DeleteRaidsByNid(candidates, {
		protectedRaidNid = currentRaidNid,
	})
	if result.removed > 0 then
		result.changed = true
		for i = 1, #removedRaidNids do
			result.affectedRaidNids[#result.affectedRaidNids + 1] = removedRaidNids[i]
		end
		restoreCurrentRaidIndex(currentRaidNid)
		notifyLoggerDataChanged("raid_delete", result)
	end
	return result
end

function Actions:PurgeRaidHistory()
	local raidStore = Database.GetRaidStore()
	local currentRaidNid = getCurrentRaidNid()
	local raids = raidStore:GetAllRaids()
	local removed = type(raids) == "table" and #raids or 0
	local archive = raidStore:EnsureArchive()
	local isArchive = type(archive) == "table" and archive.formatVersion == 1
	local protectedArchiveKey = archive and archive.activeRaidUid or nil
	local archiveKeys = {}
	for i = 1, #raids do
		local archiveKey = raidStore:GetArchiveKeyByIndex(i)
		if archiveKey and archiveKey ~= protectedArchiveKey then
			archiveKeys[#archiveKeys + 1] = archiveKey
		end
	end
	if isArchive then
		removed = raidStore:DeleteRaidsByArchiveKey(archiveKeys, protectedArchiveKey)
	else
		local raidNids = {}
		for i = 1, #raids do
			if raids[i] and raids[i].raidNid then
				raidNids[#raidNids + 1] = raids[i].raidNid
			end
		end
		removed = raidStore:DeleteRaidsByNid(raidNids, { protectedRaidNid = currentRaidNid })
	end

	if currentRaidNid then
		restoreCurrentRaidIndex(currentRaidNid)
	else
		Database.SetCurrentRaid(nil)
		Database.SetLastBoss(nil)
	end

	local result = {
		removed = removed,
	}
	notifyLoggerDataChanged("purge", result)
	return result
end

function Actions:CleanupRaidHistory(options)
	options = (type(options) == "table") and options or {}
	local raidStore, raids, protectedArchiveKey = getHistoryCleanupContext()
	local result = newHistoryCleanupResult()
	if type(raids) ~= "table" then
		result.complete = true
		return result
	end

	local currentRaidNid = getCurrentRaidNid()
	local plan = newHistoryCleanupPlan(currentRaidNid, protectedArchiveKey)
	local cleanEmptyRaids = options.emptyRaids == true
	local cleanNonEpicLoot = options.nonEpicLoot == true
	local cleanNoBossEncounter = options.noBossEncounter == true
	for i = #raids, 1, -1 do
		local raid = raids[i]
		local archiveKey = raidStore:GetArchiveKeyByIndex(i)
		if cleanEmptyRaids and not hasRaidData(raid) then
			stageRaidForHistoryCleanup(raid, plan, "emptyRaids", archiveKey)
		elseif cleanNoBossEncounter and isRaidWithoutBossEncounter(raid) then
			stageRaidForHistoryCleanup(raid, plan, "noBossEncounter", archiveKey)
		elseif cleanNonEpicLoot then
			local lootRows = raid and raid.loot or {}
			for lootIndex = #lootRows, 1, -1 do
				stageNonEpicLootAt(raid, lootRows, lootIndex, plan, archiveKey)
			end
		end
	end

	local applied, failure = executeHistoryCleanupPlan(raidStore, plan, result)
	if not applied then
		result = newHistoryCleanupResult()
		result.failed = true
		result.conflict = failure == "CONFLICT"
		result.error = tostring(failure)
	end
	restoreCurrentRaidIndex(currentRaidNid)
	if result.changed then
		notifyLoggerDataChanged("cleanup", result)
	end

	return result
end

function Actions:StartRaidHistoryCleanup(callback, opts)
	opts = (type(opts) == "table") and opts or {}
	if activeHistoryCleanup then
		activeHistoryCleanup.cancelled = true
		cancelHistoryCleanup(activeHistoryCleanup)
	end

	local raidStore, raids, protectedArchiveKey = getHistoryCleanupContext()
	local result = newHistoryCleanupResult()
	if type(raids) ~= "table" then
		result.complete = true
		if type(callback) == "function" then
			callback(result, true)
		end
		return {
			Cancel = function()
				return false
			end,
			IsCancelled = function()
				return true
			end,
		}
	end

	local state = {
		raidStore = raidStore,
		raids = raids,
		result = result,
		plan = newHistoryCleanupPlan(getCurrentRaidNid(), protectedArchiveKey),
		callback = callback,
		currentRaidNid = getCurrentRaidNid(),
		cleanEmptyRaids = opts.emptyRaids == true,
		cleanNonEpicLoot = opts.nonEpicLoot == true,
		cleanNoBossEncounter = opts.noBossEncounter == true,
		chunkSize = normalizeHistoryCleanupChunkSize(opts.chunkSize),
		delay = normalizeHistoryCleanupDelay(opts.delaySeconds),
		raidIndex = #raids,
		lootIndex = nil,
		cancelled = false,
		terminal = false,
	}
	activeHistoryCleanup = state

	local function completeCleanup()
		if state.terminal then
			return
		end
		local applied, failure = executeHistoryCleanupPlan(state.raidStore, state.plan, state.result)
		if not applied then
			restoreCurrentRaidIndex(state.currentRaidNid)
			state.result = newHistoryCleanupResult()
			state.result.failed = true
			state.result.conflict = failure == "CONFLICT"
			state.result.error = tostring(failure)
			state.terminal = true
			if activeHistoryCleanup == state then
				activeHistoryCleanup = nil
			end
			if type(state.callback) == "function" then
				state.callback(state.result, false)
			end
			return
		end
		finalizeHistoryCleanupState(state)
		state.terminal = true
		if activeHistoryCleanup == state then
			activeHistoryCleanup = nil
		end
		if state.result.changed then
			notifyLoggerDataChanged("cleanup", state.result)
		end
		if type(state.callback) == "function" then
			state.callback(state.result, true)
		end
	end

	local runChunk

	runChunk = function()
		state.handle = nil
		if state.cancelled then
			return
		end

		local processed = 0
		while processed < state.chunkSize and state.raidIndex >= 1 do
			local raid = state.raids[state.raidIndex]
			local archiveKey = state.raidStore:GetArchiveKeyByIndex(state.raidIndex)
			if type(raid) ~= "table" then
				state.raidIndex = state.raidIndex - 1
				state.lootIndex = nil
				processed = processed + 1
			elseif state.cleanEmptyRaids and not hasRaidData(raid) then
				stageRaidForHistoryCleanup(raid, state.plan, "emptyRaids", archiveKey)
				state.raidIndex = state.raidIndex - 1
				state.lootIndex = nil
				processed = processed + 1
			elseif state.cleanNoBossEncounter and isRaidWithoutBossEncounter(raid) then
				stageRaidForHistoryCleanup(raid, state.plan, "noBossEncounter", archiveKey)
				state.raidIndex = state.raidIndex - 1
				state.lootIndex = nil
				processed = processed + 1
			elseif state.cleanNonEpicLoot then
				local lootRows = raid.loot or {}
				if state.lootIndex == nil then
					state.lootIndex = #lootRows
				end
				if state.lootIndex >= 1 then
					stageNonEpicLootAt(raid, lootRows, state.lootIndex, state.plan, archiveKey)
					state.lootIndex = state.lootIndex - 1
					processed = processed + 1
				else
					state.raidIndex = state.raidIndex - 1
					state.lootIndex = nil
					processed = processed + 1
				end
			else
				state.raidIndex = state.raidIndex - 1
				state.lootIndex = nil
				processed = processed + 1
			end
		end

		if state.raidIndex < 1 then
			completeCleanup()
			return
		end
		scheduleChunkedAction(state, runChunk)
	end

	scheduleChunkedAction(state, runChunk)

	local handle = {}
	function handle:Cancel()
		if state.terminal then
			return false
		end
		state.cancelled = true
		return cancelHistoryCleanup(state)
	end
	function handle:IsCancelled()
		return state.cancelled == true
	end
	return handle
end

function Actions:RebuildLootSources()
	local raids = getLootSourceRebuildRaids()
	local result = newLootSourceRebuildResult()
	if type(raids) ~= "table" then
		return result
	end

	for raidIndex = 1, #raids do
		local raid = raids[raidIndex]
		if type(raid) == "table" then
			result.raids = result.raids + 1
			withHistoricalLootSourceInstance(raid.zone, function(sourceResolutionAvailable)
				local stagedRaid = Database.GetRaidStore():StageRaidHistoryMutation(raid)
				local changed = false
				local lootRows = stagedRaid.loot or {}
				for lootIndex = 1, #lootRows do
					local loot = lootRows[lootIndex]
					changed = rebuildLootSourceRow(stagedRaid, raidIndex, loot, result, sourceResolutionAvailable)
						or changed
				end
				if changed then
					local committed, commitError = applyLootSourceRebuildChange(raid, stagedRaid)
					if not committed then
						error(commitError or "loot source rebuild commit failed")
					end
				end
			end)
		end
	end
	if result.repaired > 0 or result.bossesCreated > 0 then
		notifyLoggerDataChanged("rebuild_sources", result)
	end

	return result
end

function Actions:StartLootSourceRebuild(callback, opts)
	opts = opts or {}
	if activeLootSourceRebuild then
		activeLootSourceRebuild.cancelled = true
		cancelLootSourceRebuild(activeLootSourceRebuild)
	end

	local raids = getLootSourceRebuildRaids()
	local result = newLootSourceRebuildResult()
	if type(raids) ~= "table" then
		if type(callback) == "function" then
			callback(result, true)
		end
		return {
			Cancel = function()
				return false
			end,
			IsCancelled = function()
				return true
			end,
		}
	end

	local state = {
		raids = raids,
		result = result,
		callback = callback,
		chunkSize = normalizeLootSourceRebuildChunkSize(opts.chunkSize),
		delay = normalizeLootSourceRebuildDelay(opts.delaySeconds),
		raidIndex = 1,
		lootIndex = 1,
		raidStarted = false,
		raidChanged = false,
		cancelled = false,
	}
	activeLootSourceRebuild = state
	local function publishCommittedPartial()
		if state.result.changed and not state.published then
			state.published = true
			state.result.partial = true
			notifyLoggerDataChanged("rebuild_sources", state.result)
		end
	end

	local function completeRebuild()
		if activeLootSourceRebuild == state then
			activeLootSourceRebuild = nil
		end
		if state.result.repaired > 0 or state.result.bossesCreated > 0 then
			state.result.changed = true
			if not state.published then
				state.published = true
				notifyLoggerDataChanged("rebuild_sources", state.result)
			end
		end
		state.result.complete = true
		state.terminal = true
		if type(state.callback) == "function" then
			state.callback(state.result, true)
		end
	end

	local function failRebuild(reason)
		if activeLootSourceRebuild == state then
			activeLootSourceRebuild = nil
		end
		state.result.failed = true
		state.result.conflict = reason == "CONFLICT"
		state.result.complete = false
		state.result.error = reason
		state.terminal = true
		publishCommittedPartial()
		if type(state.callback) == "function" then
			state.callback(state.result, false)
		end
	end

	local function finishCurrentRaid(raid)
		if state.raidStarted and state.raidChanged then
			local committed, commitError = applyLootSourceRebuildChange(raid, state.stagedRaid)
			if not committed then
				return false, commitError or "loot source rebuild commit failed"
			end
			state.result.changed = true
			state.result.affectedRaidNids[#state.result.affectedRaidNids + 1] = raid.raidNid
		end
		local raidResult = state.raidResult
		if raidResult then
			state.result.repaired = state.result.repaired + raidResult.repaired
			state.result.bossesCreated = state.result.bossesCreated + raidResult.bossesCreated
			state.result.unresolved = state.result.unresolved + raidResult.unresolved
		end
		state.stagedRaid = nil
		state.raidResult = nil
		state.temporaryInstanceKey = nil
		state.raidStarted = false
		state.raidChanged = false
		state.lootIndex = 1
		state.raidIndex = state.raidIndex + 1
		return true
	end

	local runChunk
	local function processChunk()
		local processed = 0
		while processed < state.chunkSize and state.raidIndex <= #state.raids do
			local raid = state.raids[state.raidIndex]
			if type(raid) ~= "table" then
				state.raidIndex = state.raidIndex + 1
				state.lootIndex = 1
				processed = processed + 1
			else
				if not state.raidStarted then
					state.result.raids = state.result.raids + 1
					state.raidStarted = true
					state.raidChanged = false
					state.lootIndex = 1
					state.stagedRaid = Database.GetRaidStore():StageRaidHistoryMutation(raid)
					state.raidResult = newLootSourceRebuildResult()
					local activated = LootSourcesData.ActivateInstance(raid.zone) == true
					state.temporaryInstanceKey = activated and LootSourcesData.GetActiveInstanceKey() or nil
				end

				local lootRows = state.stagedRaid.loot or {}
				if state.lootIndex <= #lootRows then
					state.raidChanged = rebuildLootSourceRow(
						state.stagedRaid,
						state.raidIndex,
						lootRows[state.lootIndex],
						state.raidResult,
						state.temporaryInstanceKey ~= nil
					) or state.raidChanged
					state.result.scanned = state.result.scanned + 1
					state.lootIndex = state.lootIndex + 1
					processed = processed + 1
				else
					local finished, finishError = finishCurrentRaid(raid)
					if not finished then
						return nil, finishError
					end
					processed = processed + 1
				end
			end
		end

		return state.raidIndex > #state.raids
	end

	runChunk = function()
		state.handle = nil
		if state.cancelled then
			return
		end
		local entryInstanceKey = LootSourcesData.GetActiveInstanceKey()
		local function processHistoricalChunk()
			local raid = state.raids[state.raidIndex]
			if state.raidStarted and type(raid) == "table" then
				local activated = LootSourcesData.ActivateInstance(raid.zone) == true
				state.temporaryInstanceKey = activated and LootSourcesData.GetActiveInstanceKey() or nil
			end
			return processChunk()
		end
		local ok, completedOrError, processError = pcall(processHistoricalChunk)
		restoreLootSourceInstance(entryInstanceKey)
		if not ok then
			cancelLootSourceRebuild(state)
			failRebuild(tostring(completedOrError))
			return
		end
		if completedOrError == nil then
			cancelLootSourceRebuild(state)
			failRebuild(processError)
			return
		end
		if completedOrError then
			local completionOk, completionError = pcall(completeRebuild)
			if not completionOk then
				state.cancelled = true
				cancelLootSourceRebuild(state)
				error(completionError)
			end
			return
		end
		scheduleChunkedAction(state, runChunk)
	end

	scheduleChunkedAction(state, runChunk)

	local handle = {}
	function handle:Cancel()
		if state.cancelled or state.terminal then
			return false
		end
		state.cancelled = true
		cancelLootSourceRebuild(state)
		state.result.cancelled = true
		state.result.complete = false
		publishCommittedPartial()
		state.terminal = true
		if type(state.callback) == "function" then
			state.callback(state.result, false)
		end
		return true
	end
	function handle:IsCancelled()
		return state.cancelled == true or activeLootSourceRebuild ~= state
	end
	return handle
end

function Actions:ScanRaidHistory()
	return scanRaidHistory()
end

function Actions:StartRaidHistoryScan(callback, opts)
	opts = opts or {}
	if activeHistoryScan then
		activeHistoryScan.cancelled = true
		cancelHistoryScan(activeHistoryScan)
	end

	local raids = getRaidHistoryScanRaids()
	local result = newHistoryScanResult()
	if type(raids) ~= "table" then
		if type(callback) == "function" then
			callback(result, true)
		end
		return {
			Cancel = function()
				return false
			end,
			IsCancelled = function()
				return true
			end,
		}
	end

	result.raids = #raids
	local state = {
		raids = raids,
		result = result,
		callback = callback,
		chunkSize = normalizeHistoryScanChunkSize(opts.chunkSize),
		delay = normalizeHistoryScanDelay(opts.delaySeconds),
		phase = "raids",
		index = 1,
		cancelled = false,
	}
	activeHistoryScan = state

	local function completeScan()
		if activeHistoryScan == state then
			activeHistoryScan = nil
		end
		if type(state.callback) == "function" then
			state.callback(state.result, true)
		end
	end

	local runChunk

	runChunk = function()
		state.handle = nil
		if state.cancelled then
			return
		end

		local processed = 0
		if state.phase == "raids" then
			while processed < state.chunkSize and state.index <= #state.raids do
				scanRaidHistoryRow(state.raids[state.index], state.result)
				state.index = state.index + 1
				processed = processed + 1
			end
			if state.index > #state.raids then
				state.phase = "duplicates"
				state.index = 1
			end
		end

		processed = 0
		if state.phase == "duplicates" then
			while processed < state.chunkSize and state.index <= #state.raids do
				state.result.duplicateRaidCandidates = state.result.duplicateRaidCandidates
					+ countDuplicateRaidCandidatesForIndex(state.raids, state.index)
				state.index = state.index + 1
				processed = processed + 1
			end
			if state.index > #state.raids then
				completeScan()
				return
			end
		end

		scheduleChunkedAction(state, runChunk)
	end

	scheduleChunkedAction(state, runChunk)

	local handle = {}
	function handle:Cancel()
		if state.cancelled then
			return false
		end
		state.cancelled = true
		cancelHistoryScan(state)
		return true
	end
	function handle:IsCancelled()
		return state.cancelled == true or activeHistoryScan ~= state
	end
	return handle
end

function Actions:SetCurrentRaid(rID)
	if not Services.Raid:IsRaidLeader() then
		addon:error(L.ErrCannotSetCurrentNotRaidLeader)
		return false
	end

	local sel = tonumber(rID)
	local raid = sel and Database.EnsureRaidByIndex(sel) or nil
	if not (sel and raid) then
		return false
	end

	-- This is meant to fix duplicate raid creation while actively raiding.
	if not addon.IsInRaid() then
		addon:error(L.ErrCannotSetCurrentNotInRaid)
		return false
	end

	local instanceName, instanceType, instanceDiff, _, _, dynDiff, isDyn = GetInstanceInfo()
	if isDyn then
		instanceDiff = instanceDiff + (2 * dynDiff)
	end
	if instanceType ~= "raid" then
		addon:error(L.ErrCannotSetCurrentNotInInstance)
		return false
	end
	if raid.zone and raid.zone ~= instanceName then
		addon:error(L.ErrCannotSetCurrentZoneMismatch)
		return false
	end

	local raidDiff = tonumber(raid.difficulty)
	local curDiff = tonumber(instanceDiff)
	if not (raidDiff and curDiff and raidDiff == curDiff) then
		addon:error(L.ErrCannotSetCurrentRaidDifficulty)
		return false
	end

	local raidSize = tonumber(raid.size)
	local groupSize = Services.Raid:GetRaidSize()
	if not raidSize or raidSize ~= groupSize then
		addon:error(L.ErrCannotSetCurrentRaidSize)
		return false
	end

	if Services.Raid:IsRaidExpired(sel) then
		addon:error(L.ErrCannotSetCurrentRaidReset)
		return false
	end

	Database.SetCurrentRaid(sel)
	Database.SetLastBoss(nil)

	-- Sync roster/dropdowns immediately so subsequent logging targets the selected raid.
	Services.Raid:RefreshAndPublish()

	addon:info(L.LogRaidSetCurrent:format(sel, tostring(raid.zone), raidSize))
	return true
end
