-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: direct addon namespace bindings
-- exports: addon.Services.Loot._State
-- events: no bus events; state helpers only
-- notes: bootstrap-sensitive internal loot state helpers

local addon = select(2, ...)
local Diag = addon.Diag
local C = addon.C
local Database = addon.Database
local Services = addon.Services
local Time = addon.Time
local GetTime = assert(_G.GetTime, Diag.A.LootStateTimeApiNotInitialized)

-- ----- Internal state ----- --
addon.Services.EnsureNamespace("Loot")
local Loot = Services.Loot
local module = Loot
module._State = module._State or {}

local ContextState = module._State
local ContextHelpers = assert(module._Context, Diag.A.LootContextHelpersNotInitialized)

local normalizeBossEventContext =
	assert(ContextHelpers.NormalizeBossEventContext, Diag.A.MissingLootContextNormalizeBossEventContext)
local normalizeLootSessionState =
	assert(ContextHelpers.NormalizeLootSessionState, Diag.A.MissingLootContextNormalizeLootSessionState)
local normalizeLootSnapshotState =
	assert(ContextHelpers.NormalizeLootSnapshotState, Diag.A.MissingLootContextNormalizeLootSnapshotState)
local normalizeActiveLootContext =
	assert(ContextHelpers.NormalizeActiveLootContext, Diag.A.MissingLootContextNormalizeActiveLootContext)
local buildActiveLootContext =
	assert(ContextHelpers.BuildActiveLootContext, Diag.A.MissingLootContextBuildActiveLootContext)
local projectLootWindowBossContext =
	assert(ContextHelpers.ProjectLootWindowBossContext, Diag.A.MissingLootContextProjectLootWindowBossContext)
local projectLootSourceState =
	assert(ContextHelpers.ProjectLootSourceState, Diag.A.MissingLootContextProjectLootSourceState)

-- ----- Private helpers ----- --
local function ensureRaidState(raidState)
	return assert(type(raidState) == "table" and raidState or nil, Diag.A.LootContextStateRequiresRaidStateTable)
end

local function syncActiveContext(raidState, lootContext)
	local value = buildActiveLootContext(lootContext.activeLoot, lootContext.activeWindow, lootContext.source)
	return ContextState.SetActive(raidState, value)
end

local function mutateActiveContext(raidState, mutateFn)
	local activeLoot = ContextState.SyncActive(raidState)
	if type(activeLoot) ~= "table" then
		ContextState.SetActive(raidState, nil)
		return nil
	end

	mutateFn(activeLoot)
	return ContextState.SetActive(raidState, activeLoot)
end

-- ----- Public methods ----- --
function Database.EnsureLootRuntimeState()
	local state = addon.State
	state.loot = state.loot or {}
	state.raid = state.raid or {}

	local lootState = state.loot
	local raidState = state.raid
	lootState.itemInfo = lootState.itemInfo or {}
	lootState.currentRollType = tonumber(lootState.currentRollType) or 4
	lootState.currentRollItem = tonumber(lootState.currentRollItem) or 0
	lootState.currentItemIndex = tonumber(lootState.currentItemIndex) or 0
	lootState.nextRollSessionId = tonumber(lootState.nextRollSessionId) or 1
	if lootState.nextRollSessionId < 1 then
		lootState.nextRollSessionId = 1
	end

	local selectedItemCount = tonumber(lootState.selectedItemCount) or 1
	if selectedItemCount < 1 then
		selectedItemCount = 1
	end
	lootState.selectedItemCount = selectedItemCount

	raidState.lastLootCount = tonumber(raidState.lastLootCount) or 1
	if raidState.lastLootCount < 1 then
		raidState.lastLootCount = 1
	end

	local lootContext = type(raidState.lootContext) == "table" and raidState.lootContext or {}
	raidState.lootContext = lootContext

	if Loot and type(Loot.SyncRuntimeState) == "function" then
		lootContext = Loot:SyncRuntimeState(raidState)
		raidState.lootContext = lootContext
	end

	lootState.lootCount = tonumber(lootState.lootCount) or 0
	if lootState.lootCount < 0 then
		lootState.lootCount = 0
	end
	lootState.rollsCount = tonumber(lootState.rollsCount) or 0
	if lootState.rollsCount < 0 then
		lootState.rollsCount = 0
	end
	lootState.itemTraded = tonumber(lootState.itemTraded) or 0
	if lootState.itemTraded < 0 then
		lootState.itemTraded = 0
	end

	lootState.rollStarted = lootState.rollStarted == true
	if lootState.rollStarted and type(lootState.rollSession) ~= "table" then
		local sid = "RS:" .. tostring(lootState.nextRollSessionId)
		lootState.nextRollSessionId = lootState.nextRollSessionId + 1
		lootState.rollSession = {
			id = sid,
			itemKey = nil,
			itemId = nil,
			itemLink = nil,
			rollType = tonumber(lootState.currentRollType) or 4,
			lootNid = tonumber(lootState.currentRollItem) or 0,
			bossNid = nil,
			startedAt = GetTime(),
			endsAt = nil,
			source = "lootWindow",
			expectedWinners = selectedItemCount,
			active = true,
		}
	end
	if type(lootState.rollSession) == "table" then
		local session = lootState.rollSession
		if session.id == nil or session.id == "" then
			session.id = "RS:" .. tostring(lootState.nextRollSessionId)
			lootState.nextRollSessionId = lootState.nextRollSessionId + 1
		else
			session.id = tostring(session.id)
		end
		session.itemKey = session.itemKey or nil
		session.itemId = tonumber(session.itemId) or nil
		session.itemLink = session.itemLink or nil
		session.rollType = tonumber(session.rollType) or tonumber(lootState.currentRollType) or 4
		session.lootNid = tonumber(session.lootNid) or tonumber(lootState.currentRollItem) or 0
		session.bossNid = tonumber(session.bossNid) or nil
		session.startedAt = tonumber(session.startedAt) or GetTime()
		session.endsAt = tonumber(session.endsAt) or nil
		session.source = session.source or "lootWindow"
		session.expectedWinners = tonumber(session.expectedWinners) or selectedItemCount
		if session.expectedWinners < 1 then
			session.expectedWinners = 1
		end
		session.active = session.active ~= false
		lootState.currentRollType = session.rollType
		lootState.currentRollItem = session.lootNid
	end

	if lootState.opened == nil then
		lootState.opened = false
	end
	if lootState.fromInventory == nil then
		lootState.fromInventory = false
	end
	lootState.pendingAwards = lootState.pendingAwards or {}

	return state, lootState, lootState.itemInfo, raidState
end

function Database.GetItemIndex()
	local _, lootState = Database.EnsureLootRuntimeState()
	return tonumber(lootState.currentItemIndex) or 0
end

function ContextState.EnsureState(raidState)
	raidState = ensureRaidState(raidState)
	local lootContext = raidState.lootContext
	if type(lootContext) ~= "table" then
		lootContext = {}
		raidState.lootContext = lootContext
	end
	return lootContext
end

function ContextState.SetField(raidState, slotKey, value)
	raidState = ensureRaidState(raidState)
	local lootContext = ContextState.EnsureState(raidState)
	lootContext[slotKey] = value
	return value
end

function ContextState.SyncField(raidState, slotKey, normalizeFn)
	raidState = ensureRaidState(raidState)
	local lootContext = ContextState.EnsureState(raidState)
	local value = lootContext[slotKey]

	value = normalizeFn(value)

	return ContextState.SetField(raidState, slotKey, value)
end

function ContextState.SetActive(raidState, activeLoot)
	raidState = ensureRaidState(raidState)
	local lootContext = ContextState.EnsureState(raidState)
	local value = normalizeActiveLootContext(activeLoot)
	lootContext.activeLoot = value
	lootContext.activeWindow = projectLootWindowBossContext(value)
	lootContext.source = projectLootSourceState(value)
	return value
end

function ContextState.SyncActive(raidState)
	raidState = ensureRaidState(raidState)
	local lootContext = ContextState.EnsureState(raidState)
	return syncActiveContext(raidState, lootContext)
end

function ContextState.GetBossEvent(raidState)
	return ContextState.SyncField(raidState, "eventBoss", normalizeBossEventContext)
end

function ContextState.GetWindow(raidState)
	local activeLoot = ContextState.SyncActive(raidState)
	return projectLootWindowBossContext(activeLoot)
end

function ContextState.ClearWindow(raidState)
	mutateActiveContext(raidState, function(activeLoot)
		activeLoot.blocked = false
		activeLoot.source = nil
		activeLoot.sourceUnit = nil
		activeLoot.windowExpiresAt = 0
	end)
end

function ContextState.GetSource(raidState)
	local activeLoot = ContextState.SyncActive(raidState)
	return projectLootSourceState(activeLoot)
end

function ContextState.ClearSource(raidState)
	mutateActiveContext(raidState, function(activeLoot)
		activeLoot.kind = nil
		activeLoot.snapshotId = nil
		activeLoot.openedAt = 0
		activeLoot.expiresAt = 0
	end)
end

function ContextState.ResolveExpiry(now, ttlSeconds, defaultTtl, minTtl)
	local resolvedNow = tonumber(now) or Time.GetCurrentTime()
	local ttl = tonumber(ttlSeconds) or tonumber(defaultTtl) or 0
	local resolvedMinTtl = tonumber(minTtl) or tonumber(defaultTtl) or 0
	if ttl < resolvedMinTtl then
		ttl = resolvedMinTtl
	end
	return resolvedNow, ttl, resolvedNow + ttl
end

function ContextState.Reset(raidState)
	raidState = ensureRaidState(raidState)
	raidState.lootContext = nil
end

function ContextState.SyncRuntimeState(raidState)
	raidState = ensureRaidState(raidState)
	local lootContext = ContextState.EnsureState(raidState)

	lootContext.eventBoss = ContextState.SyncField(raidState, "eventBoss", normalizeBossEventContext)
	lootContext.activeLoot = syncActiveContext(raidState, lootContext)
	lootContext = ContextState.EnsureState(raidState)
	lootContext.sessions = ContextState.SyncField(raidState, "sessions", normalizeLootSessionState)
	lootContext.snapshots = ContextState.SyncField(raidState, "snapshots", normalizeLootSnapshotState)
	lootContext = ContextState.EnsureState(raidState)
	return lootContext
end

function module:SyncRuntimeState(raidState)
	return ContextState.SyncRuntimeState(raidState)
end

-- ----- Loot session helpers (merged from Loot/Sessions.lua) ----- --

module._Sessions = module._Sessions or {}
local Sessions = module._Sessions

local GROUP_LOOT_PENDING_AWARD_TTL_SECONDS_SESSION = tonumber(C.GROUP_LOOT_PENDING_AWARD_TTL_SECONDS) or 60

local function getSessionState(raidState)
	local state = ContextState.SyncField(raidState, "sessions", normalizeLootSessionState)
	if type(state) ~= "table" then
		state = {
			bySessionId = {},
		}
		ContextState.SetField(raidState, "sessions", state)
	end
	return state
end

function Sessions.PurgeExpired(raidState, now)
	local state = getSessionState(raidState)
	local currentTime = tonumber(now) or Time.GetCurrentTime()

	for sessionId, entry in pairs(state.bySessionId) do
		local expiresAt = tonumber(entry and entry.expiresAt) or 0
		local entryRaidNum = tonumber(entry and entry.raidNum) or 0
		local entryBossNid = tonumber(entry and entry.bossNid) or 0
		if
			type(sessionId) ~= "string"
			or sessionId == ""
			or entryRaidNum <= 0
			or entryBossNid <= 0
			or (expiresAt > 0 and expiresAt <= currentTime)
		then
			state.bySessionId[sessionId] = nil
		end
	end

	return state
end

function Sessions.Remember(raidState, raidNum, rollSessionId, bossNid, ttlSeconds, now)
	local sessionId = rollSessionId and tostring(rollSessionId) or nil
	local resolvedRaidNum = tonumber(raidNum) or 0
	local resolvedBossNid = tonumber(bossNid) or 0
	if not sessionId or sessionId == "" or resolvedRaidNum <= 0 or resolvedBossNid <= 0 then
		return
	end

	local state = getSessionState(raidState)
	local _, _, expiresAt = ContextState.ResolveExpiry(
		now,
		ttlSeconds,
		GROUP_LOOT_PENDING_AWARD_TTL_SECONDS_SESSION,
		GROUP_LOOT_PENDING_AWARD_TTL_SECONDS_SESSION
	)
	state.bySessionId[sessionId] = {
		raidNum = resolvedRaidNum,
		bossNid = resolvedBossNid,
		expiresAt = expiresAt,
	}
end

function Sessions.Resolve(raidState, raid, raidNum, rollSessionId, now, findBossByNid)
	local sessionId = rollSessionId and tostring(rollSessionId) or nil
	if not sessionId or sessionId == "" then
		return 0
	end

	local state = Sessions.PurgeExpired(raidState, now)
	local entry = state.bySessionId[sessionId]
	if type(entry) ~= "table" then
		return 0
	end

	local entryRaidNum = tonumber(entry.raidNum) or 0
	local entryBossNid = tonumber(entry.bossNid) or 0
	if entryRaidNum ~= (tonumber(raidNum) or 0) or entryBossNid <= 0 then
		state.bySessionId[sessionId] = nil
		return 0
	end

	if type(findBossByNid) == "function" and findBossByNid(raid, entryBossNid) then
		return entryBossNid
	end

	state.bySessionId[sessionId] = nil
	return 0
end
