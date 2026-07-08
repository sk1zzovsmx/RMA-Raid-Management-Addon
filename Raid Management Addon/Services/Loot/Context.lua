-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: local feature = addon.Database.GetFeatureShared()
-- exports: addon.Services.Loot._Context
-- events: no bus events; context helpers only
-- notes: bootstrap-sensitive internal loot helpers

local addon = select(2, ...)
local feature = addon.Database.GetFeatureShared()
local Database = feature.Database
local Services = feature.Services
local Strings = feature.Strings
local LootSourceCandidates = feature.LootSourceCandidates

-- ----- Internal state ----- --
feature.EnsureServiceNamespace("Loot")
local Loot = Services.Loot
local module = Loot
module._Context = module._Context or {}

local LootContext = module._Context

-- ----- Private helpers ----- --
local NormalizeText = assert(Strings.NormalizeText, "Loot context text normalizer is not initialized")
local GetCurrentRaid = assert(Database.GetCurrentRaid, "Loot context current-raid resolver is not initialized")
local EnsureRaidById = assert(Database.EnsureRaidById, "Loot context raid resolver is not initialized")
local EnsureRaidSchema = assert(Database.EnsureRaidSchema, "Loot context raid schema normalizer is not initialized")

local function isValidLootSourceKind(kind)
	return kind == "boss" or kind == "trash" or kind == "shared" or kind == "object"
end

local function hasActiveLootSource(context)
	if type(context) ~= "table" or not isValidLootSourceKind(context.kind) then
		return false
	end
	if context.kind == "object" then
		return true
	end
	return context.blocked == true or (tonumber(context.bossNid) or 0) > 0
end

local function hasActiveLootWindow(context)
	if type(context) ~= "table" then
		return false
	end
	local windowExpiresAt = tonumber(context.windowExpiresAt) or 0
	if windowExpiresAt <= 0 then
		return false
	end
	if context.blocked == true then
		return true
	end
	return (tonumber(context.bossNid) or 0) > 0
end

-- ----- Public methods ----- --
function LootContext.NormalizeBossEventContext(context)
	if type(context) ~= "table" then
		return nil
	end
	context.raidNum = tonumber(context.raidNum) or 0
	context.bossNid = tonumber(context.bossNid) or 0
	context.name = context.name or nil
	context.source = context.source or nil
	context.seenAt = tonumber(context.seenAt) or 0
	if context.bossNid <= 0 or context.raidNum <= 0 then
		return nil
	end
	return context
end

function LootContext.NormalizeLootWindowBossContext(context)
	if type(context) ~= "table" then
		return nil
	end
	context.raidNum = tonumber(context.raidNum) or 0
	context.bossNid = tonumber(context.bossNid) or 0
	context.blocked = context.blocked == true
	context.source = context.source or nil
	context.sourceUnit = context.sourceUnit or nil
	context.sourceNpcId = tonumber(context.sourceNpcId) or 0
	context.sourceName = context.sourceName or nil
	context.expiresAt = tonumber(context.expiresAt) or 0
	if context.raidNum <= 0 then
		return nil
	end
	if context.blocked ~= true and context.bossNid <= 0 then
		return nil
	end
	return context
end

function LootContext.NormalizeLootSessionState(state)
	if type(state) ~= "table" then
		return nil
	end
	state.bySessionId = type(state.bySessionId) == "table" and state.bySessionId or {}
	return state
end

function LootContext.NormalizeLootSnapshotState(state)
	if type(state) ~= "table" then
		return nil
	end
	state.byId = type(state.byId) == "table" and state.byId or {}
	state.bySignature = type(state.bySignature) == "table" and state.bySignature or {}
	state.nextId = tonumber(state.nextId) or 1
	state.activeId = tonumber(state.activeId) or nil
	state.nextPurgeAt = tonumber(state.nextPurgeAt) or 0
	state.signatureIndexVersion = tonumber(state.signatureIndexVersion) or 0
	if state.nextId < 1 then
		state.nextId = 1
	end
	return state
end

function LootContext.NormalizeLootSourceState(state)
	if type(state) ~= "table" then
		return nil
	end
	state.raidNum = tonumber(state.raidNum) or 0
	state.kind = isValidLootSourceKind(state.kind) and state.kind or nil
	state.bossNid = tonumber(state.bossNid) or 0
	state.sourceNpcId = tonumber(state.sourceNpcId) or 0
	state.sourceName = state.sourceName or nil
	state.sourceKey = NormalizeText(state.sourceKey, true)
	state.openedAt = tonumber(state.openedAt) or 0
	state.snapshotId = tonumber(state.snapshotId) or nil
	state.expiresAt = tonumber(state.expiresAt) or 0
	state.candidates = (state.kind == "shared") and LootSourceCandidates.Copy(state.candidates) or nil
	if state.raidNum <= 0 or not state.kind then
		return nil
	end
	return state
end

function LootContext.NormalizeActiveLootContext(context)
	if type(context) ~= "table" then
		return nil
	end
	context.raidNum = tonumber(context.raidNum) or 0
	context.kind = isValidLootSourceKind(context.kind) and context.kind or nil
	context.bossNid = tonumber(context.bossNid) or 0
	context.blocked = context.blocked == true
	context.source = context.source or nil
	context.sourceUnit = context.sourceUnit or nil
	context.sourceNpcId = tonumber(context.sourceNpcId) or 0
	context.sourceName = context.sourceName or nil
	context.sourceKey = NormalizeText(context.sourceKey, true)
	context.snapshotId = tonumber(context.snapshotId) or nil
	context.openedAt = tonumber(context.openedAt) or 0
	context.expiresAt = tonumber(context.expiresAt) or 0
	context.windowExpiresAt = tonumber(context.windowExpiresAt) or 0
	context.candidates = (context.kind == "shared") and LootSourceCandidates.Copy(context.candidates) or nil
	if context.raidNum <= 0 then
		return nil
	end

	local hasSource = hasActiveLootSource(context)
	local hasWindow = hasActiveLootWindow(context)
	if not hasSource and not hasWindow then
		return nil
	end

	if not hasSource then
		context.kind = nil
		context.snapshotId = nil
		context.openedAt = 0
		context.expiresAt = 0
	end
	if not hasWindow then
		context.blocked = false
		context.source = nil
		context.sourceUnit = nil
		context.windowExpiresAt = 0
	end

	return context
end

function LootContext.BuildActiveLootContext(activeLoot, lootWindowBossContext, lootSource)
	local context = LootContext.NormalizeActiveLootContext(activeLoot)
	if type(context) == "table" then
		return context
	end

	local activeWindow = LootContext.NormalizeLootWindowBossContext(lootWindowBossContext)
	local activeSource = LootContext.NormalizeLootSourceState(lootSource)
	if type(activeWindow) ~= "table" and type(activeSource) ~= "table" then
		return nil
	end

	return LootContext.NormalizeActiveLootContext({
		raidNum = tonumber(activeWindow and activeWindow.raidNum)
			or tonumber(activeSource and activeSource.raidNum)
			or 0,
		kind = activeSource and activeSource.kind or nil,
		bossNid = tonumber(activeWindow and activeWindow.bossNid)
			or tonumber(activeSource and activeSource.bossNid)
			or 0,
		blocked = activeWindow and activeWindow.blocked == true or false,
		source = activeWindow and activeWindow.source or nil,
		sourceUnit = activeWindow and activeWindow.sourceUnit or nil,
		sourceNpcId = tonumber(activeWindow and activeWindow.sourceNpcId) or tonumber(
			activeSource and activeSource.sourceNpcId
		) or 0,
		sourceName = (activeWindow and activeWindow.sourceName) or (activeSource and activeSource.sourceName) or nil,
		sourceKey = activeSource and activeSource.sourceKey or nil,
		snapshotId = tonumber(activeSource and activeSource.snapshotId) or nil,
		openedAt = tonumber(activeSource and activeSource.openedAt) or 0,
		expiresAt = tonumber(activeSource and activeSource.expiresAt) or 0,
		windowExpiresAt = tonumber(activeWindow and activeWindow.expiresAt) or 0,
		candidates = activeSource and activeSource.candidates or nil,
	})
end

function LootContext.ProjectLootWindowBossContext(context)
	context = LootContext.NormalizeActiveLootContext(context)
	if not hasActiveLootWindow(context) then
		return nil
	end

	return LootContext.NormalizeLootWindowBossContext({
		raidNum = tonumber(context.raidNum) or 0,
		bossNid = context.blocked == true and 0 or (tonumber(context.bossNid) or 0),
		blocked = context.blocked == true,
		source = context.source or nil,
		sourceUnit = context.sourceUnit or nil,
		sourceNpcId = tonumber(context.sourceNpcId) or 0,
		sourceName = context.sourceName or nil,
		expiresAt = tonumber(context.windowExpiresAt) or 0,
	})
end

function LootContext.ProjectLootSourceState(context)
	context = LootContext.NormalizeActiveLootContext(context)
	if not hasActiveLootSource(context) then
		return nil
	end

	local bossNid = tonumber(context.bossNid) or 0
	if context.kind == "object" then
		bossNid = 0
	end

	return LootContext.NormalizeLootSourceState({
		raidNum = tonumber(context.raidNum) or 0,
		kind = context.kind,
		bossNid = bossNid,
		sourceNpcId = tonumber(context.sourceNpcId) or 0,
		sourceName = context.sourceName or nil,
		sourceKey = context.sourceKey or nil,
		openedAt = tonumber(context.openedAt) or 0,
		snapshotId = tonumber(context.snapshotId) or nil,
		expiresAt = tonumber(context.expiresAt) or 0,
		candidates = context.candidates,
	})
end

function LootContext.ResolveRaidRecord(raidNum)
	local resolvedRaidNum = raidNum
	if not resolvedRaidNum then
		resolvedRaidNum = GetCurrentRaid()
	end
	if not resolvedRaidNum then
		return resolvedRaidNum, nil
	end

	local raid = EnsureRaidById(resolvedRaidNum)
	if raid then
		EnsureRaidSchema(raid)
	end
	return resolvedRaidNum, raid
end

function LootContext.CopyLootSource(context, bossNidOverride)
	local source = LootContext.ProjectLootSourceState(context)
	if type(source) ~= "table" then
		return nil
	end

	local bossNid = tonumber(source.bossNid) or 0
	local overrideBossNid = tonumber(bossNidOverride) or 0
	if bossNid <= 0 and overrideBossNid > 0 and source.kind ~= "object" then
		bossNid = overrideBossNid
	end

	local copied = {
		kind = source.kind,
		bossNid = bossNid,
		sourceNpcId = tonumber(source.sourceNpcId) or 0,
		sourceName = source.sourceName,
		sourceKey = source.sourceKey,
		openedAt = tonumber(source.openedAt) or 0,
		snapshotId = tonumber(source.snapshotId) or nil,
	}
	if source.kind == "shared" then
		copied.candidates = LootSourceCandidates.Copy(source.candidates)
	end
	return copied
end

local registry = feature.ModuleRegistry
if registry and type(registry.AddModule) == "function" and type(registry.SetLoaded) == "function" then
	registry.AddModule("Services/Loot/Context", {
		deps = {
			"Init",
			"Modules/ModuleRegistry",
			"Modules/Strings",
			"Modules/LootSourceCandidates",
		},
	})
	registry.SetLoaded("Services/Loot/Context")
end
