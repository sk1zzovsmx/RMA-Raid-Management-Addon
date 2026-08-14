-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: direct addon namespace bindings
-- exports: publish module APIs on addon.*
-- events: emits RaidCreate
local addon = select(2, ...)
local L = addon.L
local Diag = addon.Diag

local Events = addon.Events
local C = addon.C
local Database = addon.Database
local Bus = addon.Bus
local Strings = addon.Strings
local Time = addon.Time
local Services = addon.Services
local Base64 = addon.Base64
local IgnoredMobs = addon.IgnoredMobs or {}
local LootSources = addon.LootSources
local LootSourceCandidates = addon.LootSourceCandidates

local InternalEvents = assert(Events.Internal, "Raid state internal events are not initialized")
local TriggerEvent = assert(Bus.TriggerEvent, "Raid state event publisher is not initialized")
local RaidCreateEvent = assert(InternalEvents.RaidCreate, "Raid state raid-create event is not initialized")
local RaidAttendanceChangedEvent =
	assert(InternalEvents.RaidAttendanceChanged, "Raid state attendance event is not initialized")

local coreState = addon.State
local raidState = addon.State.raid
if coreState.nextReset == nil then
	coreState.nextReset = 0
end

local tinsert, twipe = table.insert, table.wipe
local ipairs, type, select = ipairs, type, select

local tostring, tonumber = tostring, tonumber
local IsTrashMobName = IgnoredMobs.IsTrashMobName
local GetTrashMobName = IgnoredMobs.GetTrashMobName
local _G = _G
local UnitExists = UnitExists
local UnitGUID = UnitGUID
local UnitIsDead = UnitIsDead
local UnitName = assert(_G.UnitName, "Raid state unit name API is not initialized")
local UnitRace = UnitRace
local GetInstanceInfo = assert(_G.GetInstanceInfo, "Raid state instance info API is not initialized")
local GetNumRaidMembers = assert(_G.GetNumRaidMembers, "Raid state roster count API is not initialized")
local GetGroupTypeAndCount = addon.GetGroupTypeAndCount
local BossIDs = addon.BossIDs
local GetCreatureId = assert(addon.GetCreatureId, "Raid state creature-id helper is not initialized")

-- Raid helper module.
-- Manages raid state, roster, boss kills, and loot logging.
do
	addon.Services.EnsureNamespace("Raid")
	local Raid = Services.Raid
	local module = Raid
	local function scheduleRosterRefresh()
		local schedule = assert(module._ScheduleRosterRefreshInternal, "Raid roster scheduler is not initialized")
		return schedule()
	end

	local function cancelRosterRefresh()
		local cancel = assert(module._CancelRosterRefreshInternal, "Raid roster cancellation is not initialized")
		return cancel()
	end
	-- ----- Internal state ----- --
	local getRaidRosterInfo = GetRaidRosterInfo
	local masterLootCandidateCache = {
		itemLink = nil,
		rosterVersion = nil,
		indexByName = {},
	}
	local UNKNOWN_OBJECT = _G.UNKNOWNOBJECT
	local UNKNOWN_BEING = _G.UNKNOWNBEING or _G.UKNOWNBEING

	local trimText = Strings.TrimText

	local BOSS_KILL_DEDUPE_WINDOW_SECONDS = tonumber(C.BOSS_KILL_DEDUPE_WINDOW_SECONDS) or 30
	local BOSS_EVENT_CONTEXT_TTL_SECONDS = tonumber(C.BOSS_EVENT_CONTEXT_TTL_SECONDS) or BOSS_KILL_DEDUPE_WINDOW_SECONDS
	local GROUP_LOOT_PENDING_AWARD_TTL_SECONDS = tonumber(C.GROUP_LOOT_PENDING_AWARD_TTL_SECONDS) or 60
	local RECENT_LOOT_DEATH_CONTEXT_TTL_SECONDS = tonumber(C.RECENT_LOOT_DEATH_CONTEXT_TTL_SECONDS) or 8
	local RECENT_TRASH_DEATH_CONTEXT_THROTTLE_SECONDS = tonumber(C.RECENT_TRASH_DEATH_CONTEXT_THROTTLE_SECONDS) or 1
	local LOOT_WINDOW_BOSS_CONTEXT_TTL_SECONDS =
		math.max(BOSS_EVENT_CONTEXT_TTL_SECONDS, GROUP_LOOT_PENDING_AWARD_TTL_SECONDS)
	local LootService = assert(Services.Loot, "Raid state loot namespace is not initialized")
	local LootContextState = assert(LootService._State, "Loot context state owner is not initialized")
	local LootSessions = assert(LootService._Sessions, "Loot session owner is not initialized")
	local LootSnapshots = assert(LootService._Snapshots, "Loot snapshot owner is not initialized")
	local LootContext = assert(LootService._Context, "Loot context owner is not initialized")
	local recentTrashDeathContextRaidNum = 0
	local recentTrashDeathContextSeenAt = 0
	local recentTrashDeathContextActivityAt = 0

	-- ----- Private helpers ----- --
	local isDebugEnabled = addon.Options.IsDebugEnabled

	local function notifyRaidCreate(raidId)
		TriggerEvent(RaidCreateEvent, raidId)
	end

	local function isTraceEnabled()
		return addon.hasTrace ~= nil
	end

	local function isUnknownName(name)
		return (not name) or name == "" or name == UNKNOWN_OBJECT or name == UNKNOWN_BEING
	end
	module._IsUnknownNameInternal = isUnknownName

	local function invalidateMasterLootCandidateCache()
		masterLootCandidateCache.itemLink = nil
		masterLootCandidateCache.rosterVersion = nil
		twipe(masterLootCandidateCache.indexByName)
	end

	local function getRosterVersion()
		if type(module.GetRosterVersion) == "function" then
			return module:GetRosterVersion()
		end
		return 0
	end

	local function buildMasterLootCandidateCache(itemLink)
		local currentRosterVersion = getRosterVersion()
		masterLootCandidateCache.itemLink = itemLink
		masterLootCandidateCache.rosterVersion = currentRosterVersion
		twipe(masterLootCandidateCache.indexByName)

		for p = 1, addon.GetNumGroupMembers() do
			local candidate = GetMasterLootCandidate(p)
			if candidate and candidate ~= "" then
				masterLootCandidateCache.indexByName[candidate] = p
			end
		end

		if isDebugEnabled() then
			addon:debug(
				Diag.D.LogMLCandidateCacheBuilt:format(
					tostring(itemLink),
					addon.tLength(masterLootCandidateCache.indexByName)
				)
			)
		end
		return masterLootCandidateCache
	end

	local function ensureMasterLootCandidateCache(itemLink)
		local currentRosterVersion = getRosterVersion()
		if
			masterLootCandidateCache.itemLink ~= itemLink
			or masterLootCandidateCache.rosterVersion ~= currentRosterVersion
		then
			return buildMasterLootCandidateCache(itemLink)
		end
		return masterLootCandidateCache
	end

	local function setLootContextField(slotKey, value)
		return LootContextState.SetField(raidState, slotKey, value)
	end

	local function setActiveLootContextState(activeLoot)
		return LootContextState.SetActive(raidState, activeLoot)
	end

	local function syncActiveLootContextState()
		return LootContextState.SyncActive(raidState)
	end

	function Database.GetCurrentRaid()
		return coreState.currentRaid
	end

	function Database.SetCurrentRaid(raidNum)
		coreState.currentRaid = raidNum
		return coreState.currentRaid
	end

	function Database.GetLastBoss()
		return coreState.lastBoss
	end

	function Database.SetLastBoss(bossNid)
		coreState.lastBoss = bossNid
		return coreState.lastBoss
	end

	function Database.GetNextReset()
		return tonumber(coreState.nextReset) or 0
	end

	function Database.SetNextReset(nextReset)
		coreState.nextReset = tonumber(nextReset) or 0
		return coreState.nextReset
	end

	local function findBossByNid(raid, bossNid)
		local queries = Database.GetRaidQueries()
		return queries:FindBossByNid(raid, bossNid)
	end

	local function findBossByName(raid, bossName)
		local queries = Database.GetRaidQueries()
		return queries:FindBossByName(raid, bossName)
	end

	local function findBossBySourceNpcId(raid, sourceNpcId)
		local queries = Database.GetRaidQueries()
		return queries:FindBossBySourceNpcId(raid, sourceNpcId)
	end

	local function findBossBySourceKey(raid, sourceKey)
		local queries = Database.GetRaidQueries()
		return queries:FindBossBySourceKey(raid, sourceKey)
	end

	local function classifyNpcLootSource(npcId)
		local resolvedNpcId = tonumber(npcId) or 0
		if resolvedNpcId <= 0 then
			return "unknown", 0
		end

		if type(IgnoredMobs.Contains) == "function" and IgnoredMobs.Contains(resolvedNpcId) then
			return "ignored", resolvedNpcId
		end

		local bossLib = BossIDs
		local bossIds = bossLib and bossLib.BossIDs
		if not bossIds then
			return "unknown", resolvedNpcId
		end
		if bossIds[resolvedNpcId] == true then
			local bossName = type(bossLib.GetBossName) == "function" and bossLib:GetBossName(resolvedNpcId) or nil
			return "boss", resolvedNpcId, bossName
		end

		return "trash", resolvedNpcId
	end

	local function getLootWindowBossContextState()
		return LootContextState.GetWindow(raidState)
	end

	local function clearLootWindowBossContext()
		LootContextState.ClearWindow(raidState)
	end

	local setActiveLootSource
	local setLootWindowBossContext

	local function resolveContextExpiry(now, ttlSeconds, defaultTtl, minTtl)
		return LootContextState.ResolveExpiry(now, ttlSeconds, defaultTtl, minTtl)
	end

	local function setBlockedLootWindowBossContext(raidNum, source, now, ttlSeconds, sourceMeta, minTtlSeconds)
		local resolvedRaidNum = tonumber(raidNum) or 0
		if resolvedRaidNum <= 0 then
			clearLootWindowBossContext()
			return 0
		end

		local minTtl = tonumber(minTtlSeconds) or LOOT_WINDOW_BOSS_CONTEXT_TTL_SECONDS
		local resolvedNow, _, expiresAt =
			resolveContextExpiry(now, ttlSeconds, LOOT_WINDOW_BOSS_CONTEXT_TTL_SECONDS, minTtl)
		local activeLoot = syncActiveLootContextState() or {}
		activeLoot.raidNum = resolvedRaidNum
		activeLoot.kind = "trash"
		activeLoot.bossNid = 0
		activeLoot.blocked = true
		activeLoot.source = source or "lootWindowBlocked"
		activeLoot.sourceUnit = sourceMeta and sourceMeta.unit or nil
		activeLoot.sourceNpcId = tonumber(sourceMeta and sourceMeta.npcId) or 0
		activeLoot.sourceName = sourceMeta and sourceMeta.name or nil
		activeLoot.sourceKey = nil
		activeLoot.snapshotId = nil
		activeLoot.openedAt = resolvedNow
		activeLoot.expiresAt = expiresAt
		activeLoot.windowExpiresAt = expiresAt
		setActiveLootContextState(activeLoot)

		if isDebugEnabled() then
			addon:debug(
				Diag.D.LogBossLootWindowContextBlocked:format(
					resolvedRaidNum,
					tostring(sourceMeta and sourceMeta.unit or "?"),
					tostring(sourceMeta and sourceMeta.name or "?"),
					tonumber(sourceMeta and sourceMeta.npcId) or 0,
					tostring(source or "lootWindowBlocked")
				)
			)
		end

		return 0
	end

	local function getLootSourceState()
		return LootContextState.GetSource(raidState)
	end

	local function clearLootSourceState()
		LootContextState.ClearSource(raidState)
	end

	local function getBossEventContextState()
		return LootContextState.GetBossEvent(raidState)
	end

	local function normalizeRecentLootDeathContext(context)
		if type(context) ~= "table" then
			return nil
		end

		context.raidNum = tonumber(context.raidNum) or 0
		context.kind = (context.kind == "boss" or context.kind == "trash" or context.kind == "shared") and context.kind
			or nil
		context.bossNid = tonumber(context.bossNid) or 0
		context.sourceNpcId = tonumber(context.sourceNpcId) or 0
		context.sourceName = context.sourceName or nil
		context.source = context.source or nil
		context.seenAt = tonumber(context.seenAt) or 0

		if context.raidNum <= 0 or not context.kind then
			return nil
		end
		if context.kind == "boss" and context.bossNid <= 0 and not context.sourceName then
			return nil
		end

		return context
	end

	local function getRecentLootDeathContextState()
		return LootContextState.SyncField(raidState, "recentDeath", normalizeRecentLootDeathContext)
	end

	local function getRaidSourceContext(raid, raidNum, now)
		local instanceName, instanceDifficulty, maxPlayers
		local liveName, _, liveDifficulty, _, liveMaxPlayers = GetInstanceInfo()
		if type(liveName) == "string" and liveName ~= "" then
			instanceName = liveName
		end
		liveDifficulty = tonumber(liveDifficulty) or 0
		liveMaxPlayers = tonumber(liveMaxPlayers) or 0
		if liveDifficulty > 0 then
			instanceDifficulty = liveDifficulty
		end
		if liveMaxPlayers > 0 then
			maxPlayers = liveMaxPlayers
		end

		local zoneName = instanceName or (raid and raid.zone) or nil
		local difficulty = instanceDifficulty or tonumber(raid and raid.difficulty) or nil
		local raidSize = maxPlayers or tonumber(raid and raid.size) or nil
		local recentContext = getRecentLootDeathContextState()
		local recentSourceNpcId
		local recentSourceName

		if type(recentContext) == "table" then
			local resolvedRaidNum = tonumber(raidNum) or 0
			local contextRaidNum = tonumber(recentContext.raidNum) or 0
			local seenAt = tonumber(recentContext.seenAt) or 0
			local currentTime = tonumber(now) or Time.GetCurrentTime()
			local isCurrentRaid = resolvedRaidNum <= 0 or contextRaidNum == resolvedRaidNum
			local isRecent = seenAt <= 0 or currentTime - seenAt <= RECENT_LOOT_DEATH_CONTEXT_TTL_SECONDS

			if isCurrentRaid and isRecent then
				recentSourceNpcId = tonumber(recentContext.sourceNpcId) or nil
				recentSourceName = recentContext.sourceName
			end
		end
		if not recentSourceName then
			local bossEventContext = getBossEventContextState()
			if type(bossEventContext) == "table" then
				local resolvedRaidNum = tonumber(raidNum) or 0
				local contextRaidNum = tonumber(bossEventContext.raidNum) or 0
				local seenAt = tonumber(bossEventContext.seenAt) or 0
				local currentTime = tonumber(now) or Time.GetCurrentTime()
				local isCurrentRaid = resolvedRaidNum <= 0 or contextRaidNum == resolvedRaidNum
				local isRecent = seenAt <= 0 or currentTime - seenAt <= BOSS_EVENT_CONTEXT_TTL_SECONDS

				if isCurrentRaid and isRecent then
					recentSourceName = bossEventContext.name
				end
			end
		end

		return {
			raid = zoneName,
			zoneName = zoneName,
			difficulty = difficulty,
			raidSize = raidSize,
			recentSourceNpcId = recentSourceNpcId,
			recentSourceName = recentSourceName,
			now = tonumber(now) or Time.GetCurrentTime(),
			raidNum = tonumber(raidNum) or 0,
		}
	end

	local function setRecentLootDeathContext(raidNum, kind, sourceName, sourceNpcId, bossNid, source, seenAt)
		local resolvedRaidNum = tonumber(raidNum) or 0
		if resolvedRaidNum <= 0 or (kind ~= "boss" and kind ~= "trash") then
			setLootContextField("recentDeath", nil)
			recentTrashDeathContextRaidNum = 0
			recentTrashDeathContextSeenAt = 0
			recentTrashDeathContextActivityAt = 0
			return nil
		end

		if kind ~= "trash" then
			recentTrashDeathContextRaidNum = 0
			recentTrashDeathContextSeenAt = 0
			recentTrashDeathContextActivityAt = 0
		end

		return setLootContextField("recentDeath", {
			raidNum = resolvedRaidNum,
			kind = kind,
			bossNid = tonumber(bossNid) or 0,
			sourceNpcId = tonumber(sourceNpcId) or 0,
			sourceName = sourceName,
			source = source or "UNIT_DIED",
			seenAt = tonumber(seenAt) or Time.GetCurrentTime(),
		})
	end

	local function rememberRecentTrashDeathContext(raidNum, sourceName, sourceNpcId, now)
		local resolvedRaidNum = tonumber(raidNum) or 0
		local currentTime = tonumber(now) or Time.GetCurrentTime()
		local elapsed = currentTime - (tonumber(recentTrashDeathContextSeenAt) or 0)
		if
			resolvedRaidNum == recentTrashDeathContextRaidNum
			and elapsed >= 0
			and elapsed < RECENT_TRASH_DEATH_CONTEXT_THROTTLE_SECONDS
		then
			recentTrashDeathContextActivityAt = currentTime
			return nil
		end

		recentTrashDeathContextRaidNum = resolvedRaidNum
		recentTrashDeathContextSeenAt = currentTime
		recentTrashDeathContextActivityAt = currentTime
		return setRecentLootDeathContext(resolvedRaidNum, "trash", sourceName, sourceNpcId, 0, "UNIT_DIED", currentTime)
	end

	local function resetLootContextState()
		LootContextState.Reset(raidState)
		recentTrashDeathContextRaidNum = 0
		recentTrashDeathContextSeenAt = 0
		recentTrashDeathContextActivityAt = 0
	end

	local function clearActiveLootWindowItemSnapshot()
		LootSnapshots.ClearActive(raidState)
	end

	local function createLootWindowItemSnapshot(raidNum, bossNid, items, source, now, ttlSeconds)
		return LootSnapshots.Create(
			raidState,
			raidNum,
			bossNid,
			items,
			source,
			now,
			ttlSeconds,
			LOOT_WINDOW_BOSS_CONTEXT_TTL_SECONDS
		)
	end

	local function setActiveLootWindowItemSnapshot(raid, raidNum, snapshot, now, ttlSeconds)
		local bossNid =
			LootSnapshots.MarkActive(raidState, snapshot, now, ttlSeconds, LOOT_WINDOW_BOSS_CONTEXT_TTL_SECONDS)
		if bossNid <= 0 then
			return 0
		end
		setLootWindowBossContext(
			raid,
			raidNum,
			bossNid,
			snapshot.source or "lootWindow",
			now,
			ttlSeconds,
			nil,
			snapshot.id
		)
		return bossNid
	end

	local function findMatchingLootWindowItemSnapshot(raidNum, items)
		return LootSnapshots.FindMatching(raidState, raidNum, items)
	end

	local function consumeActiveLootWindowItemSnapshot(itemLink)
		return LootSnapshots.ConsumeActive(raidState, itemLink)
	end

	local function resolveLootWindowSourceUnitContext(raid)
		if type(UnitExists) ~= "function" or type(UnitGUID) ~= "function" then
			return nil
		end

		local function buildUnitContext(unit, options)
			if not UnitExists(unit) then
				return nil
			end
			options = options or {}

			local guid = UnitGUID(unit)
			local npcId = guid and GetCreatureId(guid) or 0
			if npcId <= 0 then
				return nil
			end

			local sourceKind, _, sourceBossName = classifyNpcLootSource(npcId)
			local name = UnitName(unit)
			if sourceKind == "boss" then
				if not options.allowBossMatch then
					return nil
				end

				local boss = findBossBySourceNpcId(raid, npcId)
				if not boss and name then
					boss = findBossByName(raid, name)
				end
				if not boss and sourceBossName then
					boss = findBossByName(raid, sourceBossName)
				end
				if not boss then
					local canCreateFromDeadBoss = not options.requireDeadBossForCreate
						or (type(UnitIsDead) == "function" and UnitIsDead(unit))
					if options.allowBossCreate and canCreateFromDeadBoss and (name or sourceBossName) then
						return {
							kind = "boss",
							unit = unit,
							npcId = npcId,
							name = name or sourceBossName,
							bossNid = 0,
						}
					end
					return nil
				end

				return {
					kind = "boss",
					unit = unit,
					npcId = npcId,
					name = boss.name or name or sourceBossName,
					bossNid = tonumber(boss.bossNid) or 0,
				}
			end

			if options.allowNonBoss and sourceKind == "trash" then
				return {
					kind = "nonBoss",
					unit = unit,
					npcId = npcId,
					name = name,
					bossNid = 0,
				}
			end

			return nil
		end

		local function buildCorpseUnitContext(unit, allowNonBoss)
			return buildUnitContext(unit, {
				allowBossMatch = true,
				allowBossCreate = true,
				allowNonBoss = allowNonBoss == true,
				requireDeadBossForCreate = true,
			})
		end

		local targetContext = buildCorpseUnitContext("target", true)
		if targetContext then
			return targetContext
		end

		local mouseoverContext = buildCorpseUnitContext("mouseover", true)
		if mouseoverContext then
			return mouseoverContext
		end

		return nil
	end

	setActiveLootSource = function(raid, raidNum, kind, bossNid, sourceMeta, now, ttlSeconds, snapshotId)
		local resolvedRaidNum = tonumber(raidNum) or 0
		local resolvedKind = (kind == "boss" or kind == "trash" or kind == "shared" or kind == "object") and kind or nil
		if resolvedRaidNum <= 0 or not resolvedKind then
			clearLootSourceState()
			return nil
		end

		local resolvedNow, _, expiresAt = resolveContextExpiry(now, ttlSeconds, LOOT_WINDOW_BOSS_CONTEXT_TTL_SECONDS, 1)
		local resolvedBossNid = tonumber(bossNid) or 0
		local boss = (resolvedBossNid > 0) and findBossByNid(raid, resolvedBossNid) or nil
		local sourceName = sourceMeta and sourceMeta.name or nil
		if not sourceName and boss then
			sourceName = boss.name or boss.boss
		end

		local activeLoot = syncActiveLootContextState() or {}
		activeLoot.raidNum = resolvedRaidNum
		activeLoot.kind = resolvedKind
		activeLoot.bossNid = resolvedBossNid
		activeLoot.sourceNpcId = tonumber(sourceMeta and sourceMeta.npcId)
			or tonumber(sourceMeta and sourceMeta.sourceNpcId)
			or 0
		activeLoot.sourceName = sourceName
		activeLoot.sourceKey = trimText(sourceMeta and sourceMeta.sourceKey, true)
		activeLoot.candidates = (resolvedKind == "shared")
				and LootSourceCandidates.Copy(sourceMeta and sourceMeta.candidates)
			or nil
		activeLoot.snapshotId = tonumber(snapshotId) or nil
		activeLoot.openedAt = resolvedNow
		activeLoot.expiresAt = expiresAt
		return setActiveLootContextState(activeLoot)
	end

	setLootWindowBossContext = function(
		raid,
		raidNum,
		bossNid,
		source,
		now,
		ttlSeconds,
		sourceMeta,
		snapshotId,
		updateLootSource
	)
		local resolvedRaidNum = tonumber(raidNum) or 0
		local resolvedBossNid = tonumber(bossNid) or 0
		local boss = findBossByNid(raid, resolvedBossNid)
		if resolvedRaidNum <= 0 or resolvedBossNid <= 0 or not boss then
			clearLootWindowBossContext()
			return 0
		end

		local _, _, expiresAt = resolveContextExpiry(
			now,
			ttlSeconds,
			LOOT_WINDOW_BOSS_CONTEXT_TTL_SECONDS,
			LOOT_WINDOW_BOSS_CONTEXT_TTL_SECONDS
		)
		local activeLoot = syncActiveLootContextState() or {}
		activeLoot.raidNum = resolvedRaidNum
		activeLoot.bossNid = resolvedBossNid
		activeLoot.blocked = false
		activeLoot.source = source or "lootWindow"
		activeLoot.sourceUnit = sourceMeta and sourceMeta.unit or nil
		activeLoot.sourceNpcId = tonumber(sourceMeta and sourceMeta.npcId) or tonumber(activeLoot.sourceNpcId) or 0
		activeLoot.sourceName = sourceMeta and sourceMeta.name or tostring(boss.name)
		activeLoot.windowExpiresAt = expiresAt
		if updateLootSource ~= false then
			activeLoot.kind = IsTrashMobName(boss.name) and "trash" or "boss"
			activeLoot.sourceKey = trimText(sourceMeta and sourceMeta.sourceKey, true)
			activeLoot.snapshotId = tonumber(snapshotId) or nil
			activeLoot.openedAt = tonumber(now) or Time.GetCurrentTime()
			activeLoot.expiresAt = expiresAt
		end
		setActiveLootContextState(activeLoot)

		if isDebugEnabled() then
			addon:debug(
				Diag.D.LogBossLootWindowContextSet:format(
					tostring(boss.name),
					resolvedBossNid,
					resolvedRaidNum,
					tostring(source or "lootWindow")
				)
			)
		end

		return resolvedBossNid
	end

	local function resolveLootWindowContextState(raid, raidNum, now)
		local lootWindowBossContext = getLootWindowBossContextState()
		if type(lootWindowBossContext) ~= "table" then
			return nil
		end

		local currentTime = tonumber(now) or Time.GetCurrentTime()
		local contextRaidNum = tonumber(lootWindowBossContext.raidNum) or 0
		local contextBossNid = tonumber(lootWindowBossContext.bossNid) or 0
		local expiresAt = tonumber(lootWindowBossContext.expiresAt) or 0

		if contextRaidNum ~= (tonumber(raidNum) or 0) or contextBossNid <= 0 then
			if lootWindowBossContext.blocked ~= true then
				clearLootWindowBossContext()
				return nil
			end
			if contextRaidNum ~= (tonumber(raidNum) or 0) then
				clearLootWindowBossContext()
				return nil
			end
		end

		if expiresAt > 0 and currentTime > expiresAt then
			clearLootWindowBossContext()
			return nil
		end

		if lootWindowBossContext.blocked == true then
			return "blocked", lootWindowBossContext, nil
		end

		local boss = findBossByNid(raid, contextBossNid)
		if not boss then
			clearLootWindowBossContext()
			return nil
		end

		return "boss", lootWindowBossContext, boss
	end

	local function resolveLootWindowBossContext(raid, raidNum, now)
		local contextState, lootWindowBossContext, boss = resolveLootWindowContextState(raid, raidNum, now)
		if contextState ~= "boss" then
			return 0
		end

		if isDebugEnabled() then
			addon:debug(
				Diag.D.LogBossLootWindowContextRecovered:format(
					tostring(boss.name),
					tonumber(lootWindowBossContext.bossNid) or 0,
					tonumber(lootWindowBossContext.raidNum) or 0,
					tostring(lootWindowBossContext.source or "lootWindow")
				)
			)
		end

		return tonumber(lootWindowBossContext.bossNid) or 0
	end

	local function rememberLootBossSession(raidNum, rollSessionId, bossNid, ttlSeconds)
		LootSessions.Remember(raidState, raidNum, rollSessionId, bossNid, ttlSeconds, Time.GetCurrentTime())
	end

	local function resolveLootBossSession(raid, raidNum, rollSessionId, now)
		return LootSessions.Resolve(raidState, raid, raidNum, rollSessionId, now, findBossByNid)
	end

	local function invalidateRaidRuntime(raid)
		if type(raid) == "table" then
			Database.StripRuntimeRaidCaches(raid)
		end
	end
	module._InvalidateRaidRuntimeInternal = invalidateRaidRuntime

	local function buildDefaultRaidPlayer(name)
		return {
			name = name,
			rank = 0,
			subgroup = 1,
			class = "UNKNOWN",
			join = Time.GetCurrentTime(),
			leave = nil,
			countMS = 0,
		}
	end

	local function ensureRaidPlayerNid(name, raidNum)
		local resolvedName = Strings.NormalizeName(name, true) or name
		if not resolvedName or resolvedName == "" then
			return 0, resolvedName
		end

		local playerNid = module:GetPlayerID(resolvedName, raidNum)
		if playerNid > 0 then
			return playerNid, resolvedName
		end

		module:AddPlayer(buildDefaultRaidPlayer(resolvedName), raidNum)
		playerNid = module:GetPlayerID(resolvedName, raidNum)
		return playerNid, resolvedName
	end

	local function resolveRaidDifficulty(instanceDiff)
		local diff = tonumber(instanceDiff)
		local _, instanceType, liveDiff, _, _, dynDiff, isDyn = GetInstanceInfo()
		if instanceType ~= "raid" then
			return diff
		end

		liveDiff = tonumber(liveDiff)
		if isDyn then
			local baseDiff = liveDiff or diff
			if baseDiff then
				return baseDiff + (2 * (tonumber(dynDiff) or 0))
			end
			return nil
		end

		-- Prefer live difficulty from GetInstanceInfo(): event payload can be stale during
		-- automatic fallback (for example 25H requested, 25N applied by the instance).
		return liveDiff or diff
	end

	local function getRaidSizeFromDifficulty(instanceDiff)
		local diff = tonumber(instanceDiff)
		if not diff then
			return nil
		end
		return (diff % 2 == 0) and 25 or 10
	end
	module._ResolveRaidDifficultyInternal = resolveRaidDifficulty
	module._GetRaidSizeFromDifficultyInternal = getRaidSizeFromDifficulty

	local function findRecentBossKillByName(raid, bossName, now)
		if not raid or not bossName then
			return nil, nil
		end

		local bossKills = raid.bossKills or {}
		for i = #bossKills, 1, -1 do
			local bossKill = bossKills[i]
			local killTime = tonumber(bossKill and bossKill.time) or 0
			local delta = now - killTime
			if delta > BOSS_KILL_DEDUPE_WINDOW_SECONDS then
				return nil, nil
			end
			if delta >= 0 and bossKill and bossKill.name == bossName then
				return bossKill, delta
			end
		end
		return nil, nil
	end

	local function clearBossEventContext()
		setLootContextField("eventBoss", nil)
	end

	local function setBossEventContext(raidNum, bossNid, bossName, source, seenAt)
		raidNum = tonumber(raidNum) or 0
		bossNid = tonumber(bossNid) or 0
		if raidNum <= 0 or bossNid <= 0 or not bossName then
			clearBossEventContext()
			return nil
		end

		local bossEventContext = setLootContextField("eventBoss", {
			raidNum = raidNum,
			bossNid = bossNid,
			name = bossName,
			source = source or "event",
			seenAt = tonumber(seenAt) or Time.GetCurrentTime(),
		})

		if isDebugEnabled() then
			addon:debug(
				Diag.D.LogBossEventContextSet:format(tostring(bossName), bossNid, raidNum, tostring(source or "event"))
			)
		end

		return bossEventContext
	end

	local function resolveBossEventContext(raidNum, now, applyLastBoss)
		local bossEventContext = getBossEventContextState()
		if type(bossEventContext) ~= "table" then
			return 0
		end

		local contextRaidNum = tonumber(bossEventContext.raidNum) or 0
		local contextBossNid = tonumber(bossEventContext.bossNid) or 0
		local contextBossName = bossEventContext.name
		local delta = (tonumber(now) or 0) - (tonumber(bossEventContext.seenAt) or 0)

		if contextRaidNum ~= (tonumber(raidNum) or 0) or contextBossNid <= 0 or IsTrashMobName(contextBossName) then
			clearBossEventContext()
			return 0
		end

		if delta < 0 or delta > BOSS_EVENT_CONTEXT_TTL_SECONDS then
			clearBossEventContext()
			return 0
		end

		if applyLastBoss then
			Database.SetLastBoss(contextBossNid)
			if isDebugEnabled() then
				addon:debug(
					Diag.D.LogBossEventContextRecovered:format(
						tostring(contextBossName),
						contextBossNid,
						tonumber(delta) or -1,
						tostring(bossEventContext.source or "event")
					)
				)
			end
		end

		return contextBossNid
	end

	local function recoverBossEventContext(raidNum, now)
		return resolveBossEventContext(raidNum, now, true)
	end

	local function peekBossEventContext(raidNum, now)
		return resolveBossEventContext(raidNum, now, false)
	end

	local function hasRecoverableBossEventContext(raidNum, now)
		return peekBossEventContext(raidNum, now) > 0
	end

	local function resolveRecentLootDeathContext(raid, raidNum, now, ttlSeconds, source)
		local context = getRecentLootDeathContextState()
		if type(context) ~= "table" then
			return nil
		end

		local currentTime = tonumber(now) or Time.GetCurrentTime()
		local contextRaidNum = tonumber(context.raidNum) or 0
		local contextSeenAt = tonumber(context.seenAt) or 0
		if
			context.kind == "trash"
			and contextRaidNum == recentTrashDeathContextRaidNum
			and recentTrashDeathContextActivityAt > contextSeenAt
		then
			contextSeenAt = recentTrashDeathContextActivityAt
		end
		local delta = currentTime - contextSeenAt
		if contextRaidNum ~= (tonumber(raidNum) or 0) or delta < 0 or delta > RECENT_LOOT_DEATH_CONTEXT_TTL_SECONDS then
			setLootContextField("recentDeath", nil)
			return nil
		end

		if context.kind == "trash" then
			setBlockedLootWindowBossContext(
				raidNum,
				source or "lootWindowRecentDeath",
				currentTime,
				RECENT_LOOT_DEATH_CONTEXT_TTL_SECONDS,
				{
					npcId = tonumber(context.sourceNpcId) or 0,
					name = context.sourceName,
				},
				RECENT_LOOT_DEATH_CONTEXT_TTL_SECONDS
			)
			return "blocked", 0
		end

		local bossNid = tonumber(context.bossNid) or 0
		local boss = findBossByNid(raid, bossNid)
		if not boss and context.sourceName then
			boss = findBossByName(raid, context.sourceName)
			bossNid = tonumber(boss and boss.bossNid) or bossNid
		end
		if not boss and context.sourceName then
			local sourceNpcId = tonumber(context.sourceNpcId) or 0
			local sourceNpcIdArg = sourceNpcId > 0 and sourceNpcId or nil
			bossNid = tonumber(module:AddBoss(context.sourceName, nil, raidNum, sourceNpcIdArg)) or 0
		end
		if bossNid <= 0 then
			return nil
		end

		local sourceMeta = {
			npcId = tonumber(context.sourceNpcId) or 0,
			name = context.sourceName,
		}
		return "boss",
			setLootWindowBossContext(
				raid,
				raidNum,
				bossNid,
				source or "lootWindowRecentDeath",
				currentTime,
				ttlSeconds,
				sourceMeta
			)
	end

	local function ensureLootWindowBossContext(raid, raidNum, now, ttlSeconds, source)
		local currentTime = tonumber(now) or Time.GetCurrentTime()
		local contextState = resolveLootWindowContextState(raid, raidNum, currentTime)
		if contextState == "blocked" then
			return 0
		end

		local bossNid = resolveLootWindowBossContext(raid, raidNum, currentTime)
		if bossNid > 0 then
			return bossNid
		end

		local sourceUnitContext = resolveLootWindowSourceUnitContext(raid)
		if type(sourceUnitContext) == "table" then
			if sourceUnitContext.kind == "boss" then
				local sourceBossNid = tonumber(sourceUnitContext.bossNid) or 0
				if sourceBossNid <= 0 and sourceUnitContext.name then
					sourceBossNid = tonumber(
						module:AddBoss(sourceUnitContext.name, nil, raidNum, sourceUnitContext.npcId)
					) or 0
					sourceUnitContext.bossNid = sourceBossNid
				end
				if sourceBossNid > 0 then
					return setLootWindowBossContext(
						raid,
						raidNum,
						sourceBossNid,
						source or "lootWindowUnit",
						currentTime,
						ttlSeconds,
						sourceUnitContext
					)
				end
			elseif sourceUnitContext.kind == "nonBoss" then
				setBlockedLootWindowBossContext(
					raidNum,
					source or "lootWindowBlocked",
					currentTime,
					ttlSeconds,
					sourceUnitContext
				)
				return 0
			end
		end

		local recentState, recentBossNid = resolveRecentLootDeathContext(raid, raidNum, currentTime, ttlSeconds, source)
		if recentState == "blocked" then
			return 0
		end
		if recentState == "boss" and recentBossNid > 0 then
			return recentBossNid
		end

		bossNid = peekBossEventContext(raidNum, currentTime)
		if bossNid <= 0 then
			setActiveLootSource(raid, raidNum, "object", 0, nil, currentTime, ttlSeconds, nil)
			return 0
		end

		return setLootWindowBossContext(raid, raidNum, bossNid, source or "lootWindow", currentTime, ttlSeconds)
	end

	local function findAndRememberBossContextForLoot(
		raid,
		raidNum,
		rollSessionId,
		now,
		ttlSeconds,
		allowLootWindowContext,
		allowContextRecovery,
		applyLastBossOnRecovery
	)
		local currentTime = tonumber(now) or Time.GetCurrentTime()
		local bossNid = resolveLootBossSession(raid, raidNum, rollSessionId, currentTime)
		local contextBlocked = false

		if bossNid <= 0 and allowLootWindowContext then
			local contextState = resolveLootWindowContextState(raid, raidNum, currentTime)
			if contextState == "blocked" then
				contextBlocked = true
				allowContextRecovery = false
			else
				bossNid = resolveLootWindowBossContext(raid, raidNum, currentTime)
			end
		end
		if bossNid <= 0 and not contextBlocked then
			local recentState, recentBossNid =
				resolveRecentLootDeathContext(raid, raidNum, currentTime, ttlSeconds, "lootRecentDeath")
			if recentState == "blocked" then
				contextBlocked = true
				allowContextRecovery = false
			elseif recentState == "boss" and recentBossNid > 0 then
				bossNid = recentBossNid
			end
		end
		if bossNid <= 0 and not contextBlocked and allowContextRecovery then
			if applyLastBossOnRecovery then
				bossNid = recoverBossEventContext(raidNum, currentTime)
			else
				bossNid = peekBossEventContext(raidNum, currentTime)
			end
		end

		if bossNid > 0 and rollSessionId then
			rememberLootBossSession(raidNum, rollSessionId, bossNid, ttlSeconds)
		end

		return tonumber(bossNid) or 0
	end

	local function setActiveLootSourceFromBossNid(raid, raidNum, bossNid, now, ttlSeconds)
		local currentSource = getLootSourceState()
		if
			type(currentSource) == "table"
			and tonumber(currentSource.bossNid) == (tonumber(bossNid) or 0)
			and currentSource.kind
		then
			return currentSource
		end

		local boss = findBossByNid(raid, bossNid)
		if not boss then
			return nil
		end
		local sourceKind = IsTrashMobName(boss.name) and "trash" or "boss"
		return setActiveLootSource(raid, raidNum, sourceKind, bossNid, nil, now, ttlSeconds, nil)
	end

	local function findOrCreateLootSourceBossNid(raid, raidNum, source, now)
		if type(raid) ~= "table" or type(source) ~= "table" then
			return 0
		end

		local sourceNpcId = tonumber(source.npcId) or 0
		local sourceName = trimText(source.npcName, true)
		if not sourceName or sourceName == "" then
			return 0
		end
		if source.kind ~= "shared" and sourceNpcId <= 0 then
			return 0
		end

		local sourceKey = trimText(source.sourceKey, true)
		local existingBoss
		if source.kind ~= "shared" and sourceKey then
			existingBoss = findBossBySourceKey(raid, sourceKey)
		end
		if not existingBoss and sourceNpcId > 0 then
			existingBoss = findBossBySourceNpcId(raid, sourceNpcId)
		end
		if not existingBoss and (source.kind == "boss" or source.kind == "shared") then
			existingBoss = findBossByName(raid, sourceName)
		end
		if existingBoss then
			local existingBossNid = tonumber(existingBoss.bossNid) or 0
			if existingBossNid > 0 then
				if source.kind == "boss" then
					Database.SetLastBoss(existingBossNid)
					setBossEventContext(raidNum, existingBossNid, sourceName, "LootSources", now)
				end
				return existingBossNid
			end
		end

		Database.EnsureRaidSchema(raid)

		local instanceDiff = resolveRaidDifficulty()
		if not instanceDiff then
			instanceDiff = tonumber(raid.difficulty) or nil
		end

		local currentTime = tonumber(now) or Time.GetCurrentTime()
		-- Static loot-source records attribute items only; real boss events own attendance snapshots.
		local players = {}

		local bossNid = tonumber(raid.nextBossNid) or 1
		raid.nextBossNid = bossNid + 1

		local killInfo = {
			bossNid = bossNid,
			name = sourceName,
			sourceNpcId = sourceNpcId,
			sourceKind = source.kind,
			sourceKey = source.kind ~= "shared" and sourceKey or nil,
			source = "LootSources",
			difficulty = instanceDiff,
			mode = (instanceDiff == 3 or instanceDiff == 4) and "h" or "n",
			players = players,
			time = currentTime,
			hash = Base64.Encode(raidNum .. "|" .. sourceName .. "|" .. bossNid),
		}

		tinsert(raid.bossKills, killInfo)
		invalidateRaidRuntime(raid)

		if source.kind == "boss" then
			Database.SetLastBoss(bossNid)
			setBossEventContext(raidNum, bossNid, sourceName, "LootSources", killInfo.time)
		end

		return bossNid
	end

	local function findOrCreateBossNidFromLootSource(raid, raidNum, itemId, rollSessionId, now, ttlSeconds, deferShared)
		local numericItemId = tonumber(itemId) or 0
		if type(LootSources) ~= "table" or type(LootSources.FindSource) ~= "function" or numericItemId <= 0 then
			return 0, "unavailable"
		end

		local currentTime = tonumber(now) or Time.GetCurrentTime()
		local context = getRaidSourceContext(raid, raidNum, currentTime)
		local source = LootSources.FindSource(numericItemId, context)
		local reason = type(source) == "table" and source.reason or nil

		if reason == "missing" then
			if isDebugEnabled() then
				addon:debug(Diag.D.LogLootSourceMissing:format(tostring(numericItemId), tostring(context.raid)))
			end
			return 0, "missing"
		end

		if reason == "ambiguous" then
			local candidates = type(source.candidates) == "table" and #source.candidates or 0
			if isDebugEnabled() then
				addon:debug(
					Diag.D.LogLootSourceAmbiguous:format(tostring(numericItemId), tostring(context.raid), candidates)
				)
			end
			return 0, "ambiguous"
		end

		if deferShared == true and source.kind == "shared" then
			return 0, "shared"
		end

		local bossNid = findOrCreateLootSourceBossNid(raid, raidNum, source, currentTime)
		if bossNid > 0 then
			setActiveLootSource(raid, raidNum, source.kind, bossNid, {
				npcId = tonumber(source.npcId) or 0,
				name = source.npcName,
				sourceKey = source.sourceKey,
				candidates = source.candidates,
			}, currentTime, ttlSeconds, nil)
		end
		if bossNid > 0 and rollSessionId then
			rememberLootBossSession(raidNum, rollSessionId, bossNid, ttlSeconds)
		end

		if bossNid > 0 and isDebugEnabled() then
			addon:debug(
				Diag.D.LogLootSourceResolved:format(
					tostring(numericItemId),
					tostring(context.raid),
					tostring(source.npcName),
					tonumber(source.npcId) or 0,
					tostring(source.kind),
					tostring(source.confidence)
				)
			)
		end

		if bossNid > 0 then
			return bossNid
		end
		return 0, "unresolved"
	end

	local function findOrCreateTrashBossNid(raidNum, raid)
		local bossKills = raid and raid.bossKills or {}
		for i = #bossKills, 1, -1 do
			local boss = bossKills[i]
			if boss and IsTrashMobName(boss.name) then
				local existingBossNid = tonumber(boss.bossNid) or 0
				if existingBossNid > 0 then
					return existingBossNid
				end
			end
		end

		local createdBossNid = tonumber(module:AddBoss(GetTrashMobName(), nil, raidNum)) or 0
		return createdBossNid
	end

	-- ----- Public methods ----- --

	function module:RequestMasterLootCandidateRefresh()
		invalidateMasterLootCandidateCache()
	end

	function module:FindMasterLootCandidateIndex(itemLink, playerName)
		local cache = ensureMasterLootCandidateCache(itemLink)
		local candidateIndex = cache.indexByName[playerName]
		if not candidateIndex then
			if isDebugEnabled() then
				addon:debug(Diag.D.LogMLCandidateCacheMiss:format(tostring(itemLink), tostring(playerName)))
			end
			cache = buildMasterLootCandidateCache(itemLink)
			candidateIndex = cache.indexByName[playerName]
		end
		return candidateIndex
	end

	function module:CanResolveMasterLootCandidates(itemLink)
		local cache = ensureMasterLootCandidateCache(itemLink)
		return next(cache.indexByName) ~= nil
	end

	function module:EnsureRaidPlayerNid(name, raidNum)
		return ensureRaidPlayerNid(name, raidNum)
	end

	function module:FindAndRememberBossContextForLootSession(raidNum, rollSessionId, options)
		options = options or {}
		local raid = Database.EnsureRaidByIndex(raidNum)
		if not raid then
			return 0
		end
		return findAndRememberBossContextForLoot(
			raid,
			raidNum,
			rollSessionId,
			options.now,
			options.ttlSeconds,
			options.allowLootWindowContext == true,
			options.allowContextRecovery == true,
			false
		)
	end

	function module:SetBossContextForLootSession(raidNum, rollSessionId, bossNid, ttlSeconds)
		rememberLootBossSession(raidNum, rollSessionId, bossNid, ttlSeconds)
		return tonumber(bossNid) or 0
	end

	function module:EnsureLootWindowItemContext(raidNum, items, options)
		options = options or {}
		local raid = Database.EnsureRaidByIndex(raidNum)
		if not raid then
			return 0
		end

		local snapshot = findMatchingLootWindowItemSnapshot(raidNum, items)
		if snapshot then
			return setActiveLootWindowItemSnapshot(raid, raidNum, snapshot, options.now, options.ttlSeconds)
		end

		local bossNid = tonumber(options.bossNid) or 0
		if bossNid <= 0 then
			bossNid = ensureLootWindowBossContext(raid, raidNum, options.now, options.ttlSeconds, options.source)
		end
		if bossNid <= 0 then
			clearActiveLootWindowItemSnapshot()
			return 0
		end

		snapshot =
			createLootWindowItemSnapshot(raidNum, bossNid, items, options.source, options.now, options.ttlSeconds)
		if not snapshot then
			local boss = findBossByNid(raid, bossNid)
			setActiveLootSource(
				raid,
				raidNum,
				boss and IsTrashMobName(boss.name) and "trash" or "boss",
				bossNid,
				nil,
				options.now,
				options.ttlSeconds,
				nil
			)
			return bossNid
		end

		return setActiveLootWindowItemSnapshot(raid, raidNum, snapshot, options.now, options.ttlSeconds)
	end

	function module:ConsumeLootWindowItemContext(itemLink)
		return consumeActiveLootWindowItemSnapshot(itemLink)
	end

	function module:GetActiveLootSource(raidNum, bossNidOverride)
		local source = getLootSourceState()
		if type(source) ~= "table" then
			return nil
		end

		local expiresAt = tonumber(source.expiresAt) or 0
		if expiresAt > 0 and Time.GetCurrentTime() > expiresAt then
			clearLootSourceState()
			return nil
		end

		local queryRaidNum = tonumber(raidNum) or tonumber(Database.GetCurrentRaid()) or 0
		local sourceRaidNum = tonumber(source.raidNum) or 0
		if queryRaidNum > 0 and sourceRaidNum > 0 and queryRaidNum ~= sourceRaidNum then
			return nil
		end

		return LootContext.CopyLootSource(syncActiveLootContextState(), bossNidOverride)
	end

	function module:FindOrCreateBossNidForLoot(raid, raidNum, rollSessionId, options)
		options = options or {}
		local currentTime = tonumber(options.now) or Time.GetCurrentTime()
		local allowContextRecovery = options.allowContextRecovery == true
		local allowContextFallback = options.allowContextFallback ~= false
		local allowLootWindowContext = options.allowLootWindowContext == true
		local allowTrashFallback = options.allowTrashFallback == true
		local ttlSeconds = options.ttlSeconds

		local preferContextForShared = allowContextFallback == true
		local bossNid, lootSourceReason = findOrCreateBossNidFromLootSource(
			raid,
			raidNum,
			options.itemId,
			rollSessionId,
			currentTime,
			ttlSeconds,
			preferContextForShared
		)
		if bossNid <= 0 and lootSourceReason == "shared" and allowContextFallback then
			bossNid = findAndRememberBossContextForLoot(
				raid,
				raidNum,
				rollSessionId,
				currentTime,
				ttlSeconds,
				allowLootWindowContext,
				allowContextRecovery,
				true
			)
			if bossNid > 0 then
				setActiveLootSourceFromBossNid(raid, raidNum, bossNid, currentTime, ttlSeconds)
			else
				bossNid, lootSourceReason = findOrCreateBossNidFromLootSource(
					raid,
					raidNum,
					options.itemId,
					rollSessionId,
					currentTime,
					ttlSeconds,
					false
				)
			end
		end
		if bossNid <= 0 and lootSourceReason ~= "ambiguous" and allowContextFallback then
			bossNid = findAndRememberBossContextForLoot(
				raid,
				raidNum,
				rollSessionId,
				currentTime,
				ttlSeconds,
				allowLootWindowContext,
				allowContextRecovery,
				true
			)
			if bossNid > 0 then
				setActiveLootSourceFromBossNid(raid, raidNum, bossNid, currentTime, ttlSeconds)
			end
		end
		if bossNid <= 0 and allowTrashFallback then
			bossNid = findOrCreateTrashBossNid(raidNum, raid)
			if bossNid > 0 then
				setActiveLootSource(raid, raidNum, "trash", bossNid, {
					name = GetTrashMobName(),
				}, currentTime, ttlSeconds, nil)
			end
		end
		if bossNid > 0 then
			if allowLootWindowContext then
				setLootWindowBossContext(raid, raidNum, bossNid, "lootWindow", currentTime, ttlSeconds, nil, nil, false)
			end
		end
		return tonumber(bossNid) or 0
	end

	function module:ClearLootWindowBossContext()
		clearLootWindowBossContext()
		clearActiveLootWindowItemSnapshot()
	end

	local function finalizeRaidRecord(raidNum, currentTime, deferAttendancePublication)
		local raid = Database.EnsureRaidByIndex(raidNum)
		if not raid then
			return
		end
		local duration = currentTime - (raid.startTime or currentTime)
		addon:info(
			Diag.I.LogRaidEnded:format(
				raidNum or -1,
				tostring(raid.zone),
				tonumber(raid.size) or -1,
				raid.bossKills and #raid.bossKills or 0,
				raid.loot and #raid.loot or 0,
				duration
			)
		)
		for _, player in ipairs(raid.players) do
			if not player.leave then
				player.leave = currentTime
			end
		end
		raid.endTime = currentTime
		local attendanceChanged, attendanceRaidNid
		if type(module.CloseAttendanceForRaid) == "function" then
			attendanceChanged, attendanceRaidNid = module:CloseAttendanceForRaid(
				raid, currentTime, "raid_end", deferAttendancePublication
			)
		end
		return attendanceChanged, attendanceRaidNid
	end

	-- Creates a new raid log entry.
	function module:Create(zoneName, raidSize, raidDiff)
		if not addon.IsInRaid() then
			return false
		end

		local num = tonumber(GetNumRaidMembers()) or 0
		if num == 0 then
			return false
		end

		local realm = Database.GetRealmName()
		local pendingPlayerMeta = {}
		local currentTime = Time.GetCurrentTime()

		local instanceDiff = tonumber(raidDiff)
		if not instanceDiff then
			instanceDiff = resolveRaidDifficulty()
		end

		local raidStore = Database.GetRaidStore()
		local createState = {
			history = raidStore:CaptureRaidHistoryState(),
			currentRaid = Database.GetCurrentRaid(),
			lastBoss = Database.GetLastBoss(),
			roster = module:CaptureRosterSessionState(realm),
		}
		if type(createState.history) ~= "table" or type(createState.roster) ~= "table" then
			return false
		end
		local function rollbackCreate()
			coreState.currentRaid = createState.currentRaid
			coreState.lastBoss = createState.lastBoss
			local historyOk = raidStore:RestoreRaidHistoryState(createState.history)
			local rosterOk = module:RestoreRosterSessionState(createState.roster)
			return historyOk == true and rosterOk == true
		end

		local createOk, raidInfo = pcall(raidStore.CreateRaidRecord, raidStore, {
			realm = realm,
			zone = zoneName,
			size = raidSize,
			difficulty = tonumber(instanceDiff) or nil,
			startTime = currentTime,
		})
		if not createOk or not raidInfo then
			rollbackCreate()
			return false
		end

		for i = 1, num do
			local name, rank, subgroup, level, classL, class = getRaidRosterInfo(i)
			if name then
				local unitID = "raid" .. tostring(i)
				local raceL, race = UnitRace(unitID)

				local p = {
					playerNid = raidInfo.nextPlayerNid,
					name = name,
					rank = rank or 0,
					subgroup = subgroup or 1,
					class = class or "UNKNOWN",
					join = Time.GetCurrentTime(),
					leave = nil,
					countMS = 0,
				}
				raidInfo.nextPlayerNid = (tonumber(raidInfo.nextPlayerNid) or 1) + 1

				tinsert(raidInfo.players, p)

				pendingPlayerMeta[#pendingPlayerMeta + 1] = { name, unitID, level, race, raceL, class, classL }
			end
		end

		local insertOk, _, raidId = pcall(raidStore.InsertRaid, raidStore, raidInfo)
		if not insertOk or not raidId then
			rollbackCreate()
			return false
		end

		local switchOk, switchedRaidId = pcall(Database.SetCurrentRaid, raidId)
		if not switchOk or switchedRaidId ~= raidId then
			rollbackCreate()
			return false
		end
		local attendanceChanged, attendanceRaidNid
		local commitOk = pcall(function()
			if createState.currentRaid then
				if type(module.CancelInstanceChecks) == "function" then
					module:CancelInstanceChecks()
				end
				cancelRosterRefresh()
				-- Preserve the historical callback context while the old raid closes.
				coreState.currentRaid = createState.currentRaid
				attendanceChanged, attendanceRaidNid = finalizeRaidRecord(createState.currentRaid, currentTime, true)
				coreState.currentRaid = raidId
				Database.SetLastBoss(nil)
			end
			module:CommitRosterSession(realm, pendingPlayerMeta, num)
			resetLootContextState()
		end)
		if not commitOk then
			rollbackCreate()
			return false
		end

		if attendanceChanged and attendanceRaidNid then
			TriggerEvent(RaidAttendanceChangedEvent, attendanceRaidNid, "raid_end")
		end
		notifyRaidCreate(Database.GetCurrentRaid())

		-- Publication is the commit point. Diagnostics and scheduling are
		-- failure-isolated because they cannot roll back listener side effects.
		local logged, logError = pcall(addon.info, addon, Diag.I.LogRaidCreated:format(
			Database.GetCurrentRaid() or -1,
			tostring(zoneName),
			tonumber(raidSize) or -1,
			#raidInfo.players
		))
		if not logged and type(addon.error) == "function" then
			pcall(addon.error, addon, tostring(logError))
		end

		-- Schedule one delayed roster refresh.
		local scheduled, scheduleError = pcall(scheduleRosterRefresh)
		if not scheduled and type(addon.error) == "function" then
			pcall(addon.error, addon, tostring(scheduleError))
		end
		return true
	end

	-- Ends the current raid log entry, marking end time.
	function module:End()
		if type(module.CancelInstanceChecks) == "function" then
			module:CancelInstanceChecks()
		end
		if not Database.GetCurrentRaid() then
			return
		end
		-- Stop any pending roster update when ending the raid
		cancelRosterRefresh()
		local currentTime = Time.GetCurrentTime()
		finalizeRaidRecord(Database.GetCurrentRaid(), currentTime)
		Database.SetCurrentRaid(nil)
		Database.SetLastBoss(nil)
		resetLootContextState()
	end

	-- Performs an initial raid check on player login.
	function module:CheckInitialRaidState()
		-- Cancel any pending first-check timer before starting a new one
		if module.CheckInitialRaidStateHandle then
			module:CancelTimer(module.CheckInitialRaidStateHandle)
			module.CheckInitialRaidStateHandle = nil
		end
		if not addon.IsInGroup() then
			return
		end

		if Database.GetCurrentRaid() and module:CheckPlayer(Database.GetPlayerName(), Database.GetCurrentRaid()) then
			-- Restart the roster update timer: cancel the old one and schedule a new one
			scheduleRosterRefresh()
			return
		end

		local instanceName, instanceType, instanceDiff = GetInstanceInfo()
		if isDebugEnabled() then
			addon:debug(
				Diag.D.LogRaidCheckInitialRaidState:format(
					tostring(addon.IsInGroup()),
					tostring(Database.GetCurrentRaid() ~= nil),
					tostring(instanceName),
					tostring(instanceType),
					tostring(instanceDiff)
				)
			)
		end
		if instanceType == "raid" then
			module:Check(instanceName, instanceDiff)
			return
		end
	end

	-- Adds a player to the raid log.
	function module:AddPlayer(t, raidNum)
		raidNum = raidNum or Database.GetCurrentRaid()
		if not raidNum or not t or not t.name then
			return
		end
		local raid = Database.EnsureRaidByIndex(raidNum)
		if not raid then
			return
		end
		Database.EnsureRaidSchema(raid)

		local players = module:GetPlayers(raidNum)
		local found = false
		local nextPlayerNid = tonumber(raid.nextPlayerNid) or 1

		for i, p in ipairs(players) do
			if t.name == p.name then
				t.countMS = t.countMS or p.countMS or 0
				t.playerNid = tonumber(t.playerNid) or tonumber(p.playerNid) or nextPlayerNid
				if tonumber(t.playerNid) >= nextPlayerNid then
					raid.nextPlayerNid = tonumber(t.playerNid) + 1
				end
				raid.players[i] = t
				found = true
				break
			end
		end

		if not found then
			t.countMS = t.countMS or 0
			t.playerNid = tonumber(t.playerNid) or nextPlayerNid
			raid.nextPlayerNid = tonumber(t.playerNid) + 1
			tinsert(raid.players, t)
			if isTraceEnabled() then
				addon:trace(Diag.D.LogRaidPlayerJoin:format(tostring(t.name), tonumber(raidNum) or -1))
			end
		else
			if isTraceEnabled() then
				addon:trace(Diag.D.LogRaidPlayerRefresh:format(tostring(t.name), tonumber(raidNum) or -1))
			end
		end
		invalidateRaidRuntime(raid)
	end

	-- Adds a boss kill to the active raid log.
	function module:AddBoss(bossName, manDiff, raidNum, sourceNpcId)
		sourceNpcId = tonumber(sourceNpcId)
		local sourceKind = sourceNpcId and classifyNpcLootSource(sourceNpcId) or nil
		if sourceKind == "ignored" then
			if isTraceEnabled() then
				addon:trace(Diag.D.LogBossUnitDiedIgnored:format(sourceNpcId, tostring(bossName)))
			end
			return 0
		end

		if isUnknownName(bossName) then
			bossName = nil
		end

		raidNum = raidNum or Database.GetCurrentRaid()
		if not raidNum or not bossName then
			if isDebugEnabled() then
				addon:debug(Diag.D.LogBossAddSkipped:format(tostring(raidNum), tostring(bossName)))
			end
			return 0
		end
		local isTrashBoss = IsTrashMobName(bossName)

		local raid = Database.EnsureRaidByIndex(raidNum)
		if not raid then
			return 0
		end
		Database.EnsureRaidSchema(raid)

		local instanceDiff = resolveRaidDifficulty()
		if manDiff then
			instanceDiff = (raid.size == 10) and 1 or 2
			if Strings.NormalizeLower(manDiff, true) == "h" then
				instanceDiff = instanceDiff + 2
			end
		end

		local currentTime = Time.GetCurrentTime()
		local bossSource = sourceNpcId and "UNIT_DIED" or "YELL"
		local existingBoss, delta = findRecentBossKillByName(raid, bossName, currentTime)
		if existingBoss then
			local existingBossNid = tonumber(existingBoss.bossNid) or 0
			if existingBossNid > 0 then
				Database.SetLastBoss(existingBossNid)
				if not isTrashBoss then
					setBossEventContext(raidNum, existingBossNid, bossName, bossSource, currentTime)
				else
					clearBossEventContext()
				end
			end
			if isTraceEnabled() then
				addon:trace(
					Diag.D.LogBossDuplicateSuppressed:format(
						tostring(bossName),
						sourceNpcId or -1,
						existingBossNid,
						tonumber(delta) or -1
					)
				)
			end
			return existingBossNid
		end

		local players = {}
		local seenPlayers = {}
		for unit in addon.UnitIterator(true) do
			if UnitIsConnected(unit) then
				local name = UnitName(unit)
				if name then
					local resolvedName = Strings.NormalizeName(name, true) or name
					local playerNid = ensureRaidPlayerNid(resolvedName, raidNum)
					if playerNid > 0 and not seenPlayers[playerNid] then
						seenPlayers[playerNid] = true
						tinsert(players, playerNid)
					end
				end
			end
		end

		local bossNid = tonumber(raid.nextBossNid) or 1
		raid.nextBossNid = bossNid + 1

		local killInfo = {
			bossNid = bossNid,
			name = bossName,
			sourceNpcId = sourceNpcId or nil,
			difficulty = instanceDiff,
			mode = (instanceDiff == 3 or instanceDiff == 4) and "h" or "n",
			players = players,
			time = currentTime,
			hash = Base64.Encode(raidNum .. "|" .. bossName .. "|" .. bossNid),
		}

		tinsert(raid.bossKills, killInfo)
		invalidateRaidRuntime(raid)
		Database.SetLastBoss(bossNid)
		if not isTrashBoss then
			setBossEventContext(raidNum, bossNid, bossName, bossSource, currentTime)
		else
			clearBossEventContext()
		end
		addon:info(
			Diag.I.LogBossLogged:format(
				tostring(bossName),
				tonumber(instanceDiff) or -1,
				tonumber(raidNum) or -1,
				#players
			)
		)
		if isDebugEnabled() then
			addon:debug(
				Diag.D.LogBossLastBossHash:format(tonumber(Database.GetLastBoss()) or -1, tostring(killInfo.hash))
			)
		end
		return bossNid
	end

	-- Raid functions.

	function module:IsPlayerInRaid()
		if addon.IsInRaid() then
			return true
		end
		local groupType = GetGroupTypeAndCount()
		if groupType == "raid" then
			return true
		end
		if UnitInRaid("player") then
			return true
		end
		return (tonumber(GetNumRaidMembers()) or 0) > 0
	end

	-- Returns raid size: 10 or 25.
	function module:GetRaidSize()
		local _, _, members = GetGroupTypeAndCount()
		if members == 0 then
			return 0
		end

		local diff = Time.GetDifficulty()
		if diff then
			return (diff == 1 or diff == 3) and 10 or 25
		end

		return members > 20 and 25 or 10
	end

	-- Checks if a raid log is expired (older than the weekly reset).
	function module:IsRaidExpired(rID)
		local raid = Database.EnsureRaidByIndex(rID)
		if not raid then
			return true
		end

		local startTime = raid.startTime
		local currentTime = Time.GetCurrentTime()
		local week = 604800 -- 7 days in seconds

		if Database.GetNextReset() and Database.GetNextReset() > currentTime then
			return startTime < (Database.GetNextReset() - week)
		end

		return currentTime >= startTime + week
	end

	-- Retrieves all loot for a given raid and optional boss number.
	function module:GetLoot(raidNum, bossNid)
		raidNum = raidNum or Database.GetCurrentRaid()
		local raid = Database.EnsureRaidByIndex(raidNum)
		bossNid = tonumber(bossNid) or 0
		if not raid then
			return {}
		end
		Database.EnsureRaidSchema(raid)

		local loot = raid.loot or {}
		if bossNid <= 0 then
			return loot
		end

		local items = {}
		for _, v in ipairs(loot) do
			if tonumber(v.bossNid) == bossNid then
				tinsert(items, v)
			end
		end
		return items
	end

	-- Processes COMBAT_LOG_EVENT_UNFILTERED for boss-kill detection.
	function module:COMBAT_LOG_EVENT_UNFILTERED(...)
		if not Database.GetCurrentRaid() then
			return
		end

		-- Hot-path fast check: inspect the event type before unpacking extra args.
		local subEvent = select(2, ...)
		if subEvent ~= "UNIT_DIED" then
			return
		end

		-- 3.3.5a base params (8):
		-- timestamp, event, sourceGUID, sourceName, sourceFlags, destGUID, destName, destFlags
		local destGUID, destName, destFlags = select(6, ...)
		if bit.band(destFlags or 0, COMBATLOG_OBJECT_TYPE_PLAYER) ~= 0 then
			return
		end

		-- LibCompat embeds GetCreatureId with the 3.3.5a GUID parsing rules.
		local npcId = destGUID and GetCreatureId(destGUID)
		local sourceKind, sourceNpcId, sourceBossName = classifyNpcLootSource(npcId)
		if sourceKind == "ignored" then
			if isTraceEnabled() then
				addon:trace(Diag.D.LogBossUnitDiedIgnored:format(tonumber(sourceNpcId) or -1, tostring(destName)))
			end
			return
		end
		if sourceKind ~= "boss" then
			if sourceKind == "trash" then
				local currentRaid = Database.GetCurrentRaid()
				local currentTime = Time.GetCurrentTime()
				if hasRecoverableBossEventContext(currentRaid, currentTime) then
					rememberRecentTrashDeathContext(currentRaid, destName, sourceNpcId, currentTime)
				end
			end
			return
		end

		local boss = destName or sourceBossName
		if boss then
			if isTraceEnabled() then
				addon:trace(Diag.D.LogBossUnitDiedMatched:format(tonumber(sourceNpcId) or -1, tostring(boss)))
			end
			local bossNid = module:AddBoss(boss, nil, nil, sourceNpcId)
			setRecentLootDeathContext(
				Database.GetCurrentRaid(),
				"boss",
				boss,
				sourceNpcId,
				bossNid,
				"UNIT_DIED",
				Time.GetCurrentTime()
			)
		end
	end
end
