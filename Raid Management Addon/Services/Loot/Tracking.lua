-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: direct addon namespace bindings
-- exports: addon.Services.Loot._Tracking
-- events: no bus events; tracking helpers only
-- notes: tracking/snapshot helpers for loot service

local addon = select(2, ...)
local Database = addon.Database
local Item = addon.Item
local Services = addon.Services
local _, lootState, _, raidState = Database.EnsureLootRuntimeState()

-- ----- Internal state ----- --
addon.Services.EnsureNamespace("Loot")
local Loot = Services.Loot
local module = Loot
module._Tracking = module._Tracking or {}

local Tracking = module._Tracking
local ContextHelpers = assert(module._Context, "Loot context helpers are not initialized")
local resolveRaidRecord = assert(ContextHelpers.ResolveRaidRecord, "Missing LootContext.ResolveRaidRecord")
local PendingAwards = assert(module.PendingAwards, "Loot pending-award helpers are not initialized")
local PassiveGroupLoot = assert(module._PassiveGroupLoot, "Loot passive group-loot helpers are not initialized")
local normalizePendingAwardItemKey =
	assert(PendingAwards.NormalizePendingAwardItemKey, "Missing PendingAwards.NormalizePendingAwardItemKey")

local strmatch = string.match
local tostring, tonumber = tostring, tonumber
local type, pairs = type, pairs
local _G = _G
local GetMasterLootCandidate =
	assert(_G.GetMasterLootCandidate, "Loot tracking master-loot candidate API is not initialized")
local GetLootMethod = assert(_G.GetLootMethod, "Loot tracking loot-method API is not initialized")
local GetNumGroupMembers = assert(addon.GetNumGroupMembers, "Loot tracking group-count helper is not initialized")

-- ----- Private helpers ----- --
local function copyRollSessionSnapshot(session)
	if type(session) ~= "table" then
		return nil
	end

	return {
		id = session.id and tostring(session.id) or nil,
		itemKey = session.itemKey,
		itemId = tonumber(session.itemId) or nil,
		itemLink = session.itemLink,
		rollType = tonumber(session.rollType) or session.rollType,
		lootNid = tonumber(session.lootNid) or 0,
		bossNid = tonumber(session.bossNid) or nil,
		startedAt = tonumber(session.startedAt) or 0,
		endsAt = tonumber(session.endsAt) or nil,
		source = session.source,
		expectedWinners = tonumber(session.expectedWinners) or 1,
		active = session.active ~= false,
	}
end

local function buildLootWindowSnapshotItems(lootTable)
	local items = {}
	local currentItemIndex = tonumber(lootState.currentItemIndex) or 0

	for i = 1, lootState.lootCount do
		local item = lootTable and lootTable[i] or nil
		if item and item.itemLink then
			items[#items + 1] = {
				index = i,
				selected = i == currentItemIndex,
				itemKey = item.itemKey or (Item.GetItemStringFromLink(item.itemLink) or item.itemLink),
				itemName = item.itemName,
				itemLink = item.itemLink,
				itemTexture = item.itemTexture,
				itemColor = item.itemColor,
				itemCount = tonumber(item.count) or 1,
			}
		end
	end

	return items
end

local function buildPendingAwardSnapshot()
	local entries = {}

	for key, list in pairs(lootState.pendingAwards or {}) do
		if type(list) == "table" then
			for i = 1, #list do
				local pending = list[i]
				if type(pending) == "table" then
					entries[#entries + 1] = {
						key = key,
						itemKey = pending.itemLink and normalizePendingAwardItemKey(pending.itemLink) or nil,
						itemLink = pending.itemLink,
						looter = pending.looter,
						rollType = tonumber(pending.rollType) or pending.rollType,
						rollValue = tonumber(pending.rollValue) or 0,
						rollSessionId = pending.rollSessionId and tostring(pending.rollSessionId) or nil,
						expiresAt = tonumber(pending.expiresAt) or nil,
						ts = tonumber(pending.ts) or 0,
					}
				end
			end
		end
	end

	table.sort(entries, function(a, b)
		if tostring(a.itemKey or "") ~= tostring(b.itemKey or "") then
			return tostring(a.itemKey or "") < tostring(b.itemKey or "")
		end
		if tostring(a.looter or "") ~= tostring(b.looter or "") then
			return tostring(a.looter or "") < tostring(b.looter or "")
		end
		if (tonumber(a.ts) or 0) ~= (tonumber(b.ts) or 0) then
			return (tonumber(a.ts) or 0) < (tonumber(b.ts) or 0)
		end
		return tostring(a.rollSessionId or "") < tostring(b.rollSessionId or "")
	end)

	return entries
end

local function buildPassiveLootRollSnapshot()
	local entries = {}
	local state = raidState.passiveLootRolls
	local bySessionId = state and state.bySessionId or nil

	for sessionId, entry in pairs(bySessionId or {}) do
		if type(entry) == "table" then
			entries[#entries + 1] = {
				sessionId = tostring(sessionId),
				rollId = tonumber(entry.rollId) or nil,
				itemKey = entry.itemKey,
				itemLink = entry.itemLink,
				bossNid = tonumber(entry.bossNid) or nil,
				expiresAt = tonumber(entry.expiresAt) or 0,
			}
		end
	end

	table.sort(entries, function(a, b)
		return tostring(a.sessionId or "") < tostring(b.sessionId or "")
	end)

	return {
		nextSessionId = tonumber(state and state.nextSessionId) or 1,
		entries = entries,
	}
end

local function splitLoggedPassiveLootKey(key)
	local itemKey, looter = strmatch(tostring(key or ""), "^(.-)\001(.*)$")
	return itemKey, looter
end

local function buildLoggedPassiveLootSnapshot()
	local entries = {}
	local state = raidState.loggedPassiveLoot

	for key, list in pairs(state or {}) do
		local itemKey, looter = splitLoggedPassiveLootKey(key)
		if type(list) == "table" then
			for i = 1, #list do
				local marker = list[i]
				if type(marker) == "table" then
					entries[#entries + 1] = {
						itemKey = itemKey,
						looter = looter,
						rollSessionId = marker.rollSessionId and tostring(marker.rollSessionId) or nil,
						expiresAt = tonumber(marker.expiresAt) or 0,
					}
				end
			end
		end
	end

	table.sort(entries, function(a, b)
		if tostring(a.itemKey or "") ~= tostring(b.itemKey or "") then
			return tostring(a.itemKey or "") < tostring(b.itemKey or "")
		end
		if tostring(a.looter or "") ~= tostring(b.looter or "") then
			return tostring(a.looter or "") < tostring(b.looter or "")
		end
		return tostring(a.rollSessionId or "") < tostring(b.rollSessionId or "")
	end)

	return entries
end

local function buildBossNameByNid(raid)
	local names = {}
	local bosses = raid and raid.bossKills or {}

	for i = 1, #bosses do
		local boss = bosses[i]
		local bossNid = tonumber(boss and boss.bossNid) or 0
		if bossNid > 0 then
			names[bossNid] = boss.name or boss.boss
		end
	end

	return names
end

local function buildHistoryLootSnapshot(raid, raidNum, raidService)
	local entries = {}
	local loot = raid and raid.loot or {}
	local bossNames = buildBossNameByNid(raid)

	for i = 1, #loot do
		local entry = loot[i]
		if type(entry) == "table" then
			local looterNid = tonumber(entry.looterNid) or nil
			local looterName = nil
			if raidService and raidService.GetPlayerName and looterNid and looterNid > 0 then
				looterName = raidService:GetPlayerName(looterNid, raidNum)
			end

			entries[#entries + 1] = {
				lootNid = tonumber(entry.lootNid) or 0,
				itemId = tonumber(entry.itemId) or nil,
				itemName = entry.itemName,
				itemString = entry.itemString,
				itemLink = entry.itemLink,
				itemRarity = tonumber(entry.itemRarity) or entry.itemRarity,
				itemTexture = entry.itemTexture,
				itemCount = tonumber(entry.itemCount) or 1,
				looterNid = looterNid,
				looterName = looterName,
				rollType = tonumber(entry.rollType) or entry.rollType,
				rollValue = tonumber(entry.rollValue) or 0,
				rollSessionId = entry.rollSessionId and tostring(entry.rollSessionId) or nil,
				bossNid = tonumber(entry.bossNid) or 0,
				bossName = bossNames[tonumber(entry.bossNid) or 0],
				time = tonumber(entry.time) or 0,
				source = entry.source,
			}
		end
	end

	return entries
end

local function buildMasterLootCandidates(slot)
	local candidates = {}
	if tonumber(slot) == nil then
		return candidates
	end

	local groupCount = tonumber(GetNumGroupMembers()) or 0

	for i = 1, groupCount do
		local candidate = GetMasterLootCandidate(slot, i)
		if candidate and candidate ~= "" then
			candidates[#candidates + 1] = {
				index = i,
				name = candidate,
			}
		end
	end

	return candidates
end

local function buildMasterLootSnapshot(items, findLootSlotIndex)
	local method, masterLooterPartyId, roundRobinPartyId = GetLootMethod()

	local slots = {}
	if method == "master" then
		for i = 1, #items do
			local item = items[i]
			if item and item.itemLink then
				local slot = type(findLootSlotIndex) == "function" and findLootSlotIndex(item.itemLink) or nil
				slots[#slots + 1] = {
					index = item.index,
					slot = tonumber(slot) or nil,
					itemKey = item.itemKey,
					itemName = item.itemName,
					itemLink = item.itemLink,
					itemCount = tonumber(item.itemCount) or 1,
					candidates = buildMasterLootCandidates(slot),
				}
			end
		end
	end

	return {
		method = method,
		masterLooterPartyId = tonumber(masterLooterPartyId) or nil,
		roundRobinPartyId = tonumber(roundRobinPartyId) or nil,
		slots = slots,
	}
end

-- ----- Public methods ----- --
function Tracking.GetSnapshot(raidNum, lootTable, findLootSlotIndex)
	local currentRaidId, raid = resolveRaidRecord(raidNum)
	local raidService = Services.Raid
	local windowItems = buildLootWindowSnapshotItems(lootTable)

	return {
		schemaVersion = 1,
		state = {
			currentRaid = currentRaidId,
			opened = lootState.opened == true,
			fromInventory = lootState.fromInventory == true,
			currentItemIndex = tonumber(lootState.currentItemIndex) or 0,
			currentRollType = tonumber(lootState.currentRollType) or lootState.currentRollType,
			currentRollItem = tonumber(lootState.currentRollItem) or 0,
			lootCount = tonumber(lootState.lootCount) or 0,
			rollsCount = tonumber(lootState.rollsCount) or 0,
			selectedItemCount = tonumber(lootState.selectedItemCount) or 1,
			itemTraded = tonumber(lootState.itemTraded) or 0,
			lastLootCount = tonumber(raidState.lastLootCount) or 0,
		},
		window = {
			items = windowItems,
			source = raidService and raidService.GetActiveLootSource and raidService:GetActiveLootSource(currentRaidId)
				or nil,
		},
		rolls = {
			session = copyRollSessionSnapshot(lootState.rollSession),
			pendingAwards = buildPendingAwardSnapshot(),
			passive = buildPassiveLootRollSnapshot(),
			loggedReceipts = buildLoggedPassiveLootSnapshot(),
		},
		history = {
			raidNum = currentRaidId,
			loot = buildHistoryLootSnapshot(raid, currentRaidId, raidService),
		},
		masterLoot = buildMasterLootSnapshot(windowItems, findLootSlotIndex),
	}
end
