-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: direct addon namespace bindings
-- exports: addon.Services.Loot._Recording
-- events: no bus events; loot receipt, record, and reconciliation helpers
local addon = select(2, ...)
local Item = addon.Item
local Services = addon.Services
local Database = addon.Database
local Strings = addon.Strings
local Time = addon.Time

local GetCurrentTime = assert(Time and Time.GetCurrentTime, "Loot recording time provider is not initialized")
local GetItemKey = assert(Item.GetItemKey, "Loot recording item-key resolver is not initialized")
local GetItemStringFromLink =
	assert(Item.GetItemStringFromLink, "Loot recording item-string resolver is not initialized")
local NormalizeName = assert(Strings.NormalizeName, "Loot recording name normalizer is not initialized")

local tinsert = table.insert
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
		if (tonumber(raid.nextLootNid) or 1) <= preferred then
			raid.nextLootNid = preferred + 1
		end
		return preferred
	end
	local lootNid = tonumber(raid.nextLootNid) or 1
	raid.nextLootNid = lootNid + 1
	return lootNid
end

local function resolveRecordTime(value)
	local timestamp = tonumber(value) or tonumber(GetCurrentTime())
	assert(timestamp, "Loot record timestamp is not initialized")
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

function Recording.Append(raid, args)
	if type(raid) ~= "table" then
		return nil, 0
	end
	raid.loot = raid.loot or {}
	local row, lootNid = Recording.Build(raid, args)
	if not row then
		return nil, 0
	end
	tinsert(raid.loot, row)
	Database.GetRaidStore():MarkLootSyncRevision(raid, row, "loot_row")
	return row, lootNid, #raid.loot
end

-- ----- Reconciliation methods ----- --

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
	if args.rollType ~= nil then
		row.rollType = tonumber(args.rollType) or args.rollType
	end
	row.rollValue = strongerRollValue(row.rollValue, args.rollValue)
	if args.rollSessionId and (not row.rollSessionId or row.rollSessionId == "") then
		row.rollSessionId = tostring(args.rollSessionId)
	end
	if args.itemCount and (tonumber(args.itemCount) or 0) > (tonumber(row.itemCount) or 0) then
		row.itemCount = tonumber(args.itemCount) or row.itemCount
	end
	return row
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
