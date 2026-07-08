-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: local feature = addon.Database.GetFeatureShared()
-- exports: addon.Services.Loot._Snapshots
-- events: no bus events; snapshot helpers only
-- notes: internal loot-window snapshot helpers

local addon = select(2, ...)
local feature = addon.Database.GetFeatureShared()
local Services = feature.Services

-- ----- Internal state ----- --
feature.EnsureServiceNamespace("Loot")
local Loot = Services.Loot
local module = Loot
module._Snapshots = module._Snapshots or {}

local Snapshots = module._Snapshots
local ContextState = assert(module._State, "Loot state helpers are not initialized")
local ContextHelpers = assert(module._Context, "Loot context helpers are not initialized")
local Item = feature.Item
local Time = feature.Time

local GetItemStringFromLink = assert(Item.GetItemStringFromLink, "Loot snapshot item-key resolver is not initialized")
local normalizeLootSnapshotState =
	assert(ContextHelpers.NormalizeLootSnapshotState, "Missing LootContext.NormalizeLootSnapshotState")

local tremove, tsort = table.remove, table.sort
local pairs, type = pairs, type
local tonumber, tostring = tonumber, tostring

local SIGNATURE_INDEX_VERSION = 1
local rebuildSnapshotIndex

-- ----- Private helpers ----- --
local function getSnapshotState(raidState)
	local state = ContextState.SyncField(raidState, "snapshots", normalizeLootSnapshotState)
	if type(state) ~= "table" then
		state = {
			byId = {},
			bySignature = {},
			nextId = 1,
			activeId = nil,
			nextPurgeAt = 0,
			signatureIndexVersion = SIGNATURE_INDEX_VERSION,
		}
		ContextState.SetField(raidState, "snapshots", state)
	elseif tonumber(state.signatureIndexVersion) ~= SIGNATURE_INDEX_VERSION then
		rebuildSnapshotIndex(state)
	end
	return state
end

local function buildSignature(itemCounts, totalCount)
	local resolvedTotalCount = tonumber(totalCount) or 0
	if type(itemCounts) ~= "table" or resolvedTotalCount <= 0 then
		return nil
	end

	local keys = {}
	for itemKey, itemCount in pairs(itemCounts) do
		if type(itemKey) == "string" and itemKey ~= "" and (tonumber(itemCount) or 0) > 0 then
			keys[#keys + 1] = itemKey
		end
	end
	if #keys == 0 then
		return nil
	end

	tsort(keys)

	local signature = tostring(resolvedTotalCount)
	for i = 1, #keys do
		local itemKey = keys[i]
		signature = signature .. "\001" .. itemKey .. "=" .. tostring(tonumber(itemCounts[itemKey]) or 0)
	end
	return signature
end

local function removeFromSignatureIndex(state, snapshot, snapshotId)
	local signature = type(snapshot) == "table" and snapshot.signature or nil
	local resolvedSnapshotId = tonumber(snapshotId) or tonumber(snapshot and snapshot.id) or 0
	if type(signature) ~= "string" or signature == "" or resolvedSnapshotId <= 0 then
		return
	end

	local list = state.bySignature[signature]
	if type(list) ~= "table" then
		state.bySignature[signature] = nil
		return
	end

	for i = #list, 1, -1 do
		if tonumber(list[i]) == resolvedSnapshotId then
			tremove(list, i)
		end
	end

	if #list == 0 then
		state.bySignature[signature] = nil
	end
end

local function indexSnapshot(state, snapshot)
	local snapshotId = tonumber(snapshot and snapshot.id) or 0
	local signature = type(snapshot) == "table" and snapshot.signature or nil
	if snapshotId <= 0 or type(signature) ~= "string" or signature == "" then
		return
	end

	local list = state.bySignature[signature]
	if type(list) ~= "table" then
		list = {}
		state.bySignature[signature] = list
	end

	for i = 1, #list do
		if tonumber(list[i]) == snapshotId then
			return
		end
	end

	list[#list + 1] = snapshotId
end

local function refreshSnapshotSignature(state, snapshot)
	if type(snapshot) ~= "table" then
		return
	end

	removeFromSignatureIndex(state, snapshot)
	snapshot.signature = buildSignature(snapshot.itemCounts, snapshot.totalCount)
	indexSnapshot(state, snapshot)
end

local function markSnapshotExpiry(state, snapshot, expiresAt)
	if type(snapshot) ~= "table" then
		return
	end

	local resolvedExpiresAt = tonumber(expiresAt) or 0
	snapshot.expiresAt = resolvedExpiresAt
	if resolvedExpiresAt > 0 and ((tonumber(state.nextPurgeAt) or 0) <= 0 or resolvedExpiresAt < state.nextPurgeAt) then
		state.nextPurgeAt = resolvedExpiresAt
	end
end

local function removeSnapshot(state, snapshotId, snapshot)
	local resolvedSnapshotId = tonumber(snapshotId) or tonumber(snapshot and snapshot.id) or 0
	if resolvedSnapshotId <= 0 then
		return
	end

	removeFromSignatureIndex(state, snapshot, resolvedSnapshotId)
	state.byId[resolvedSnapshotId] = nil
	if tonumber(state.activeId) == resolvedSnapshotId then
		state.activeId = nil
	end
end

local function buildItemCounts(items)
	local counts = {}
	local totalCount = 0
	if type(items) ~= "table" then
		return counts, totalCount
	end

	for i = 1, #items do
		local item = items[i]
		local itemKey = item and item.itemKey and tostring(item.itemKey) or nil
		local itemCount = tonumber(item and item.count) or 0
		if itemKey and itemKey ~= "" and itemCount > 0 then
			counts[itemKey] = (tonumber(counts[itemKey]) or 0) + itemCount
			totalCount = totalCount + itemCount
		end
	end

	return counts, totalCount
end

local function buildItemsSignature(items)
	local itemCounts, totalCount = buildItemCounts(items)
	if totalCount <= 0 then
		return itemCounts, totalCount, nil
	end
	return itemCounts, totalCount, buildSignature(itemCounts, totalCount)
end

rebuildSnapshotIndex = function(state)
	if type(state) ~= "table" then
		return
	end

	state.bySignature = {}
	state.nextPurgeAt = 0
	state.signatureIndexVersion = SIGNATURE_INDEX_VERSION

	for snapshotId, snapshot in pairs(state.byId) do
		if type(snapshot) ~= "table" then
			state.byId[snapshotId] = nil
		else
			snapshot.id = tonumber(snapshot.id) or tonumber(snapshotId) or 0
			snapshot.raidNum = tonumber(snapshot.raidNum) or 0
			snapshot.bossNid = tonumber(snapshot.bossNid) or 0
			snapshot.itemCounts = type(snapshot.itemCounts) == "table" and snapshot.itemCounts or {}
			snapshot.totalCount = tonumber(snapshot.totalCount) or 0
			snapshot.source = snapshot.source or nil
			snapshot.createdAt = tonumber(snapshot.createdAt) or 0
			snapshot.expiresAt = tonumber(snapshot.expiresAt) or 0
			snapshot.signature = buildSignature(snapshot.itemCounts, snapshot.totalCount)
			if snapshot.id <= 0 or snapshot.raidNum <= 0 or snapshot.bossNid <= 0 or not snapshot.signature then
				state.byId[snapshotId] = nil
			else
				indexSnapshot(state, snapshot)
				markSnapshotExpiry(state, snapshot, snapshot.expiresAt)
			end
		end
	end
end

-- ----- Public methods ----- --
function Snapshots.ClearActive(raidState)
	local state = getSnapshotState(raidState)
	state.activeId = nil
end

function Snapshots.PurgeExpired(raidState, now, force)
	local state = getSnapshotState(raidState)
	local currentTime = tonumber(now) or Time.GetCurrentTime()
	if force ~= true and (tonumber(state.nextPurgeAt) or 0) > currentTime then
		return state
	end

	local nextPurgeAt = 0

	for snapshotId, snapshot in pairs(state.byId) do
		local expiresAt = tonumber(snapshot and snapshot.expiresAt) or 0
		if type(snapshot) ~= "table" or (expiresAt > 0 and expiresAt <= currentTime) then
			removeSnapshot(state, snapshotId, snapshot)
		elseif expiresAt > 0 and (nextPurgeAt <= 0 or expiresAt < nextPurgeAt) then
			nextPurgeAt = expiresAt
		end
	end

	for signature, list in pairs(state.bySignature) do
		if type(list) ~= "table" or #list == 0 then
			state.bySignature[signature] = nil
		end
	end

	state.nextPurgeAt = nextPurgeAt
	return state
end

function Snapshots.Create(raidState, raidNum, bossNid, items, source, now, ttlSeconds, defaultTtl)
	local resolvedRaidNum = tonumber(raidNum) or 0
	local resolvedBossNid = tonumber(bossNid) or 0
	local itemCounts, totalCount = buildItemCounts(items)
	if resolvedRaidNum <= 0 or resolvedBossNid <= 0 or totalCount <= 0 then
		return nil
	end

	local state = getSnapshotState(raidState)
	local resolvedNow, _, expiresAt = ContextState.ResolveExpiry(now, ttlSeconds, defaultTtl, 1)
	local snapshotId = state.nextId
	state.nextId = snapshotId + 1
	state.byId[snapshotId] = {
		id = snapshotId,
		raidNum = resolvedRaidNum,
		bossNid = resolvedBossNid,
		itemCounts = itemCounts,
		totalCount = totalCount,
		source = source or "lootWindow",
		createdAt = resolvedNow,
	}
	state.activeId = snapshotId
	refreshSnapshotSignature(state, state.byId[snapshotId])
	markSnapshotExpiry(state, state.byId[snapshotId], expiresAt)
	return state.byId[snapshotId]
end

function Snapshots.MarkActive(raidState, snapshot, now, ttlSeconds, defaultTtl)
	if type(snapshot) ~= "table" then
		Snapshots.ClearActive(raidState)
		return 0
	end

	local bossNid = tonumber(snapshot.bossNid) or 0
	if bossNid <= 0 then
		Snapshots.ClearActive(raidState)
		return 0
	end

	local state = getSnapshotState(raidState)
	state.activeId = tonumber(snapshot.id) or nil
	local _, _, expiresAt = ContextState.ResolveExpiry(now, ttlSeconds, defaultTtl, 1)
	markSnapshotExpiry(state, snapshot, expiresAt)
	return bossNid
end

function Snapshots.FindMatching(raidState, raidNum, items, now)
	local resolvedRaidNum = tonumber(raidNum) or 0
	local _, totalCount, signature = buildItemsSignature(items)
	if resolvedRaidNum <= 0 or totalCount <= 0 or not signature then
		return nil
	end

	local state = Snapshots.PurgeExpired(raidState, now)
	local matched = nil
	local candidates = state.bySignature[signature]
	if type(candidates) ~= "table" then
		return nil
	end

	for i = 1, #candidates do
		local snapshot = state.byId[candidates[i]]
		if type(snapshot) == "table" and tonumber(snapshot.raidNum) == resolvedRaidNum then
			if not matched then
				matched = snapshot
			elseif (tonumber(matched.bossNid) or 0) ~= (tonumber(snapshot.bossNid) or 0) then
				return nil
			elseif (tonumber(snapshot.createdAt) or 0) > (tonumber(matched.createdAt) or 0) then
				matched = snapshot
			end
		end
	end

	return matched
end

function Snapshots.ConsumeActive(raidState, itemLink, now)
	local itemKey = itemLink and (GetItemStringFromLink(itemLink) or itemLink) or itemLink
	if not itemKey then
		return 0
	end

	local state = Snapshots.PurgeExpired(raidState, now)
	local activeId = tonumber(state.activeId) or 0
	local snapshot = state.byId[activeId]
	if type(snapshot) ~= "table" then
		state.activeId = nil
		return 0
	end

	local remaining = tonumber(snapshot.itemCounts and snapshot.itemCounts[itemKey]) or 0
	if remaining <= 0 then
		return tonumber(snapshot.bossNid) or 0
	end

	remaining = remaining - 1
	snapshot.totalCount = (tonumber(snapshot.totalCount) or 0) - 1
	if remaining > 0 then
		snapshot.itemCounts[itemKey] = remaining
	else
		snapshot.itemCounts[itemKey] = nil
	end

	if (tonumber(snapshot.totalCount) or 0) <= 0 then
		removeSnapshot(state, activeId, snapshot)
	else
		refreshSnapshotSignature(state, snapshot)
	end

	return tonumber(snapshot.bossNid) or 0
end

local contextBridge = {
	SetField = ContextState.SetField,
	SetActive = ContextState.SetActive,
	SyncActive = ContextState.SyncActive,
	GetWindow = ContextState.GetWindow,
	ClearWindow = ContextState.ClearWindow,
	ResolveExpiry = ContextState.ResolveExpiry,
	GetSource = ContextState.GetSource,
	ClearSource = ContextState.ClearSource,
	GetBossEvent = ContextState.GetBossEvent,
	SyncField = ContextState.SyncField,
	Reset = ContextState.Reset,
	RememberSession = module._Sessions.Remember,
	ResolveSession = module._Sessions.Resolve,
	ClearActiveSnapshot = Snapshots.ClearActive,
	CreateSnapshot = Snapshots.Create,
	MarkActiveSnapshot = Snapshots.MarkActive,
	FindMatchingSnapshot = Snapshots.FindMatching,
	ConsumeActiveSnapshot = Snapshots.ConsumeActive,
	CopyLootSource = module._Context.CopyLootSource,
}

module._ContextBridge = contextBridge

local registry = feature.ModuleRegistry
if registry and type(registry.AddModule) == "function" and type(registry.SetLoaded) == "function" then
	registry.AddModule("Services/Loot/Snapshots", {
		deps = {
			"Init",
			"Modules/ModuleRegistry",
			"Modules/Item",
			"Services/Loot/State",
			"Services/Loot/Context",
		},
	})
	registry.SetLoaded("Services/Loot/Snapshots")
end
