-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: direct addon namespace bindings
-- exports: addon.Services.Loot._Recording
-- events: no bus events; loot receipt, record, and reconciliation helpers
local addon = select(2, ...)
local Diag = addon.Diag
local Item = addon.Item
local Services = addon.Services
local Database = addon.Database
local Strings = addon.Strings
local Time = addon.Time

local GetCurrentTime = assert(Time and Time.GetCurrentTime, Diag.A.LootRecordingTimeProviderNotInitialized)
local GetItemKey = assert(Item.GetItemKey, Diag.A.LootRecordingItemKeyResolverNotInitialized)
local GetItemStringFromLink =
	assert(Item.GetItemStringFromLink, Diag.A.LootRecordingItemStringResolverNotInitialized)
local NormalizeName = assert(Strings.NormalizeName, Diag.A.LootRecordingNameNormalizerNotInitialized)

local tonumber = tonumber
local tostring = tostring
local type = type

addon.Services.EnsureNamespace("Loot")
local Loot = Services.Loot
local module = Loot
module._Recording = module._Recording or {}

local Recording = module._Recording

-- ----- Private helpers ----- --

local function resolveReceiptKind(args)
	if not args.itemLink then
		return "ignored", "missing_item"
	end
	local parsed = args.parsedGroupLoot
	if args.passiveGroupLoot == true and type(parsed) == "table" then
		if parsed.kind == "winner" then
			return "group_winner"
		end
		if parsed.kind == "roll" then
			return "group_roll"
		end
		if parsed.kind == "selection" then
			return "group_selection"
		end
	end
	if args.kind then
		return args.kind
	end
	return "loot_received"
end

local function allocateLootNid(raid, preferredLootNid)
	local preferred = tonumber(preferredLootNid)
	if preferred and preferred > 0 then
		return preferred
	end
	local lootNid = tonumber(raid.nextLootNid) or 1
	return lootNid
end

local function commitLootEvent(raid, eventType, payload)
	local raidStore = Database.GetRaidStore()
	local raidUid = raidStore:GetRaidUid(raid)
	if not raidUid then
		return nil, "RAID_NOT_ACTIVE"
	end
	return raidStore:CommitAuthoritativeEvent(raidUid, eventType, payload)
end

local function resolveRecordTime(value)
	local timestamp = tonumber(value) or tonumber(GetCurrentTime())
	assert(timestamp, Diag.A.LootRecordTimestampNotInitialized)
	return timestamp
end

local function itemKey(itemLink, itemString)
	if itemString and itemString ~= "" then
		return itemString
	end
	local key = GetItemStringFromLink(itemLink)
	if key and key ~= "" then
		return key
	end
	return itemLink
end

local function normalizeName(name)
	return NormalizeName(name, true)
end

local function strongerRollValue(current, incoming)
	local currentValue = tonumber(current) or 0
	local incomingValue = tonumber(incoming) or 0
	if incomingValue > currentValue then
		return incoming
	end
	return current
end

local function sameLooter(row, args)
	local rowLooterNid = tonumber(row and row.looterNid) or 0
	local targetLooterNid = tonumber(args and args.looterNid) or 0
	if rowLooterNid > 0 and targetLooterNid > 0 then
		return rowLooterNid == targetLooterNid
	end
	local rowLooter = normalizeName(row and row.looter)
	local targetLooter = normalizeName(args and args.looter)
	return rowLooter ~= nil and targetLooter ~= nil and rowLooter == targetLooter
end

-- ----- Receipt methods ----- --

function Recording.FromParsedLoot(args)
	args = args or {}
	local kind, reason = resolveReceiptKind(args)
	local parsed = args.parsedGroupLoot
	local rollSessionId = args.rollSessionId
	local rollId = args.rollId
	if type(parsed) == "table" then
		rollSessionId = rollSessionId or parsed.sessionId
		rollId = rollId or parsed.rollId
	end
	return {
		kind = kind,
		reason = reason,
		msg = args.msg,
		playerName = args.playerName,
		itemLink = args.itemLink,
		itemString = args.itemString,
		itemKey = GetItemKey(args.itemString, args.itemLink),
		itemCount = tonumber(args.itemCount) or 1,
		itemId = tonumber(args.itemId) or nil,
		itemName = args.itemName,
		itemRarity = args.itemRarity,
		itemTexture = args.itemTexture,
		itemType = args.itemType,
		rollType = args.rollType,
		rollValue = args.rollValue,
		rollSessionId = rollSessionId and tostring(rollSessionId) or nil,
		rollId = tonumber(rollId) or rollId,
		passiveGroupLoot = args.passiveGroupLoot == true,
		parsedGroupLoot = parsed,
	}
end

function Recording.ShouldCreateRecord(receipt)
	if type(receipt) ~= "table" then
		return false
	end
	return receipt.kind == "loot_received" or receipt.kind == "group_winner"
end

-- ----- Record methods ----- --

function Recording.Build(raid, args)
	if type(raid) ~= "table" or type(args) ~= "table" then
		return nil, 0
	end

	local lootNid = allocateLootNid(raid, args.lootNid)
	local looterNid = tonumber(args.looterNid) or 0
	local row = {
		itemId = args.itemId,
		itemName = args.itemName,
		itemString = args.itemString,
		itemLink = args.itemLink,
		itemRarity = args.itemRarity,
		itemTexture = args.itemTexture,
		itemCount = tonumber(args.itemCount) or 1,
		looterNid = (looterNid > 0) and looterNid or nil,
		rollType = args.rollType,
		rollValue = args.rollValue,
		rollSessionId = args.rollSessionId,
		lootNid = lootNid,
		bossNid = tonumber(args.bossNid) or 0,
		time = resolveRecordTime(args.time),
		source = args.source,
		lootSource = args.lootSource,
	}
	return row, lootNid
end

function Recording.MarkUpdated(raid, row, reason)
	if type(raid) ~= "table" or type(row) ~= "table" then
		return 0
	end
	local event, state = commitLootEvent(raid, "LOOT_UPDATED", { loot = row })
	if not event or not state then
		return 0
	end
	local lootNid = tonumber(row.lootNid)
	for i = 1, #(state.loot or {}) do
		if tonumber(state.loot[i] and state.loot[i].lootNid) == lootNid then
			return event.sequence, state.loot[i], state, i
		end
	end
	return event.sequence, nil, state
end

function Recording.Copy(row)
	if type(row) ~= "table" then
		return nil
	end
	local copy = {}
	for key, value in pairs(row) do
		copy[key] = value
	end
	return copy
end

function Recording.Append(raid, args)
	if type(raid) ~= "table" then
		return nil, 0
	end
	local row, lootNid = Recording.Build(raid, args)
	if not row then
		return nil, 0
	end
	local event, state = commitLootEvent(raid, "LOOT_ADDED", { loot = row })
	if type(state) == "string" then
		return nil, 0, nil, state
	end
	if type(event) ~= "table" or type(state) ~= "table" or type(state.loot) ~= "table" then
		return nil, 0
	end
	for i = 1, #state.loot do
		if tonumber(state.loot[i] and state.loot[i].lootNid) == lootNid then
			return state.loot[i], lootNid, i
		end
	end
	return nil, 0
end

-- ----- Reconciliation methods ----- --

function Recording.FindRecentAuthorityFallback(raid, args, ttlSeconds)
	if type(raid) ~= "table" or type(args) ~= "table" then
		return nil
	end
	local targetTime = tonumber(args.time) or 0
	local targetCount = tonumber(args.itemCount) or 1
	local targetItemKey = itemKey(args.itemLink, args.itemString)
	if not targetItemKey then
		return nil
	end
	local ttl = tonumber(ttlSeconds) or 0
	local lootList = raid.loot or {}
	-- Bound reconciliation to the newest 20 rows; older awards remain distinct.
	local firstIndex = #lootList - 19
	if firstIndex < 1 then
		firstIndex = 1
	end
	for i = #lootList, firstIndex, -1 do
		local row = lootList[i]
		local age = targetTime - (tonumber(row and row.time) or 0)
		if
			row
			and row.source == "DISTRIBUTION_AWARD"
			and age >= 0
			and age <= ttl
			and itemKey(row.itemLink, row.itemString) == targetItemKey
			and sameLooter(row, args)
			and (tonumber(row.itemCount) or 1) == targetCount
		then
			return row, i
		end
	end
	return nil
end

function Recording.FindTradeOnlyFallback(raid, args)
	if type(raid) ~= "table" or type(args) ~= "table" then
		return nil
	end

	local targetSessionId = args.rollSessionId and tostring(args.rollSessionId) or nil
	local targetItemKey = itemKey(args.itemLink, args.itemString)
	local targetLooterNid = tonumber(args.looterNid) or 0
	local targetLooter = normalizeName(args.looter)
	local targetBossNid = tonumber(args.bossNid) or 0
	local lootList = raid.loot or {}

	for i = #lootList, 1, -1 do
		local row = lootList[i]
		if row and row.source then
			local sameSession = targetSessionId
				and targetSessionId ~= ""
				and tostring(row.rollSessionId or "") == targetSessionId
			local sameItem = itemKey(row.itemLink, row.itemString) == targetItemKey
			local sameBoss = targetBossNid <= 0 or tonumber(row.bossNid) == targetBossNid
			local sameLooter = true
			if targetLooterNid > 0 then
				sameLooter = tonumber(row.looterNid) == targetLooterNid
			elseif targetLooter and row.looter then
				sameLooter = normalizeName(row.looter) == targetLooter
			end
			if
				sameItem
				and sameBoss
				and sameLooter
				and (sameSession or (not targetSessionId or targetSessionId == ""))
			then
				return row, i
			end
		end
	end
	return nil
end

function Recording.MergeTradeOnlyFallback(row, args)
	if type(row) ~= "table" or type(args) ~= "table" then
		return nil
	end
	local changed = false
	if args.rollType ~= nil then
		local rollType = tonumber(args.rollType) or args.rollType
		if row.rollType ~= rollType then
			row.rollType = rollType
			changed = true
		end
	end
	local rollValue = strongerRollValue(row.rollValue, args.rollValue)
	if row.rollValue ~= rollValue then
		row.rollValue = rollValue
		changed = true
	end
	if args.rollSessionId and (not row.rollSessionId or row.rollSessionId == "") then
		row.rollSessionId = tostring(args.rollSessionId)
		changed = true
	end
	if args.itemCount and (tonumber(args.itemCount) or 0) > (tonumber(row.itemCount) or 0) then
		row.itemCount = tonumber(args.itemCount) or row.itemCount
		changed = true
	end
	return row, changed
end

function Recording.ShouldSkipPassiveDuplicate(args)
	if type(args) ~= "table" then
		return false
	end
	local passive = args.PassiveGroupLoot
	local rollOutcome = args.rollOutcome
	if not (args.passiveGroupLoot and passive and passive.HasLoggedPassiveLoot) then
		return false
	end
	if
		(rollOutcome and rollOutcome.consumedPendingAward) and not (args.isPassiveWinnerMessage and args.rollSessionId)
	then
		return false
	end
	return passive.HasLoggedPassiveLoot(args.itemLink, args.playerName, args.rollSessionId) == true
end

function Recording.MarkPassiveLogged(args)
	if type(args) ~= "table" then
		return
	end
	local passive = args.PassiveGroupLoot
	if args.passiveGroupLoot and args.isPassiveWinnerMessage and passive and passive.RememberLoggedPassiveLoot then
		passive.RememberLoggedPassiveLoot(args.itemLink, args.playerName, args.rollSessionId)
	end
end
