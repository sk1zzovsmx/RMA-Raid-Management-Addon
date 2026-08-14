-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: direct addon namespace bindings
-- exports: addon.Services.Loot.Inventory
-- events: none
-- notes: Inventory and awarded-count helpers for loot trade flows

local addon = select(2, ...)
local Diag = addon.Diag
local Services = addon.Services
-- ----- Internal state ----- --

local _G = _G
local GetNumLootItems = assert(_G.GetNumLootItems, Diag.A.LootInventoryLootCountApiNotInitialized)
local GetLootSlotLink = assert(_G.GetLootSlotLink, Diag.A.LootInventoryLootSlotLinkApiNotInitialized)
local GetContainerNumSlots =
	assert(_G.GetContainerNumSlots, Diag.A.LootInventoryContainerSlotCountApiNotInitialized)
local GetContainerItemLink =
	assert(_G.GetContainerItemLink, Diag.A.LootInventoryContainerItemLinkApiNotInitialized)
local GetContainerItemInfo =
	assert(_G.GetContainerItemInfo, Diag.A.LootInventoryContainerItemInfoApiNotInitialized)

local Item = addon.Item

addon.Services.EnsureNamespace("Loot")
local Loot = Services.Loot
Loot.Inventory = Loot.Inventory or {}
local Inventory = Loot.Inventory

-- ----- Private helpers ----- --

local type, tonumber = type, tonumber
local strlower = string.lower

local function normalizePartner(name)
	if type(name) ~= "string" or name == "" then
		return nil
	end
	return strlower((name:gsub("%s*%-[^%-]+$", "")))
end

local function itemMatches(link, wantedKey, wantedId)
	if not link then
		return false
	end
	local key = Item.GetItemStringFromLink(link)
	if wantedKey and key then
		return wantedKey == key
	end
	local itemId = Item.GetItemIdFromLink(link)
	return wantedId ~= nil and itemId ~= nil and wantedId == itemId
end

local function countOwnedItem(wantedKey, wantedId)
	local total = 0
	for bag = 0, 4 do
		for slot = 1, GetContainerNumSlots(bag) do
			local link = GetContainerItemLink(bag, slot)
			if itemMatches(link, wantedKey, wantedId) then
				local _, count = GetContainerItemInfo(bag, slot)
				total = total + (tonumber(count) or 1)
			end
		end
	end
	return total
end

-- ----- Public methods ----- --

function Inventory.FindLootSlotIndex(itemLink)
	local wantedKey = Item.GetItemStringFromLink(itemLink) or itemLink
	local wantedId = Item.GetItemIdFromLink(itemLink)
	for i = 1, GetNumLootItems() do
		local tempItemLink = GetLootSlotLink(i)
		if Inventory.LootLinkMatchesTarget(tempItemLink, itemLink, wantedKey, wantedId) then
			return i
		end
	end
	return nil
end

function Inventory.ValidateLootSlot(slot, itemLink)
	local current = GetLootSlotLink(tonumber(slot) or 0)
	if not current then
		return nil, "loot_slot_missing"
	end

	local wantedKey = Item.GetItemStringFromLink(itemLink)
	local currentKey = Item.GetItemStringFromLink(current)
	if wantedKey and currentKey then
		if wantedKey == currentKey then
			return true
		end
		return nil, "loot_slot_changed"
	end

	local wantedId = Item.GetItemIdFromLink(itemLink)
	local currentId = Item.GetItemIdFromLink(current)
	if wantedId and currentId and wantedId == currentId then
		return true
	end
	return nil, "loot_slot_changed"
end

function Inventory.LootLinkMatchesTarget(slotLink, itemLink, wantedKey, wantedId)
	if not slotLink then
		return false
	end
	if slotLink == itemLink then
		return true
	end
	local targetKey = Item.GetItemStringFromLink(itemLink)
	local slotKey = Item.GetItemStringFromLink(slotLink)
	if targetKey and slotKey then
		return slotKey == targetKey
	end
	if wantedKey and slotKey and slotKey == wantedKey then
		return true
	end
	if wantedId then
		local slotId = Item.GetItemIdFromLink(slotLink)
		if slotId and slotId == wantedId then
			return true
		end
	end
	return false
end

function Inventory.FindTradeableInventoryMatch(itemLink, itemId)
	if not itemLink and not itemId then
		return nil
	end

	local wantedKey = itemLink and (Item.GetItemStringFromLink(itemLink) or itemLink) or nil
	local wantedId = tonumber(itemId) or (itemLink and Item.GetItemIdFromLink(itemLink)) or nil
	local totalCount = 0
	local firstBag, firstSlot, firstSlotCount
	local hasMatch = false

	for bag = 0, 4 do
		local n = GetContainerNumSlots(bag)
		for slot = 1, n do
			local link = GetContainerItemLink(bag, slot)
			if link then
				local key = Item.GetItemStringFromLink(link) or link
				local linkId = Item.GetItemIdFromLink(link)
				local matches = (wantedKey and key == wantedKey) or (wantedId and linkId == wantedId)
				if matches then
					hasMatch = true
					if not Item.IsBagItemSoulbound(bag, slot) then
						local _, count = GetContainerItemInfo(bag, slot)
						local slotCount = tonumber(count) or 1
						totalCount = totalCount + slotCount
						if not firstBag then
							firstBag = bag
							firstSlot = slot
							firstSlotCount = slotCount
						end
					end
				end
			end
		end
	end

	return totalCount, firstBag, firstSlot, firstSlotCount, hasMatch
end

function Inventory.ResolveTradeableInventoryItem(itemLink, cachedBag, cachedSlot, selectedItemCount)
	local totalCount, bag, slot, slotCount
	local usedFastPath = false
	local wantedKey = Item.GetItemStringFromLink(itemLink) or itemLink
	local wantedId = Item.GetItemIdFromLink(itemLink)

	cachedBag = tonumber(cachedBag)
	cachedSlot = tonumber(cachedSlot)

	if cachedBag and cachedSlot then
		local cachedLink = GetContainerItemLink(cachedBag, cachedSlot)
		if cachedLink then
			local cachedKey = Item.GetItemStringFromLink(cachedLink) or cachedLink
			local cachedId = Item.GetItemIdFromLink(cachedLink)
			local sameItem = (wantedKey and cachedKey == wantedKey) or (wantedId and cachedId == wantedId)
			if sameItem and not Item.IsBagItemSoulbound(cachedBag, cachedSlot) then
				local _, count = GetContainerItemInfo(cachedBag, cachedSlot)
				bag = cachedBag
				slot = cachedSlot
				slotCount = tonumber(count) or 1
				usedFastPath = true
			end
		end
	end

	if not (bag and slot) then
		totalCount, bag, slot, slotCount = Inventory.FindTradeableInventoryMatch(itemLink, wantedId)
	elseif usedFastPath then
		if (tonumber(selectedItemCount) or 1) > 1 then
			totalCount = Inventory.FindTradeableInventoryMatch(itemLink, wantedId)
		else
			totalCount = tonumber(slotCount) or 1
		end
	end

	if not (bag and slot) then
		return nil
	end

	return {
		bag = bag,
		slot = slot,
		slotCount = tonumber(slotCount) or 1,
		totalCount = tonumber(totalCount) or tonumber(slotCount) or 1,
	}
end

function Inventory.CaptureTradeEvidence(itemLink, bagId, slotId)
	local itemKey = Item.GetItemStringFromLink(itemLink)
	local itemId = Item.GetItemIdFromLink(itemLink)
	if not itemKey and not itemId then
		return nil, "trade_item_invalid"
	end

	local bag = tonumber(bagId)
	local slot = tonumber(slotId)
	if bag == nil or slot == nil then
		for candidateBag = 0, 4 do
			for candidateSlot = 1, GetContainerNumSlots(candidateBag) do
				if itemMatches(GetContainerItemLink(candidateBag, candidateSlot), itemKey, itemId) then
					bag = candidateBag
					slot = candidateSlot
					break
				end
			end
			if bag ~= nil then
				break
			end
		end
	end
	if bag == nil or slot == nil then
		return nil, "trade_item_missing"
	end

	local sourceLink = GetContainerItemLink(bag, slot)
	if not itemMatches(sourceLink, itemKey, itemId) then
		return nil, "trade_item_changed"
	end
	local _, sourceCount = GetContainerItemInfo(bag, slot)
	return {
		itemLink = itemLink,
		itemKey = itemKey,
		itemId = itemId,
		bagId = bag,
		slotId = slot,
		sourceLocationKnown = true,
		sourceLink = sourceLink,
		sourceCount = tonumber(sourceCount) or 1,
		totalCount = countOwnedItem(itemKey, itemId),
	}
end

function Inventory.VerifyTradeEvidence(evidence, partnerName, requiredCount)
	if type(evidence) ~= "table" then
		return nil, "trade_evidence_missing"
	end
	local expectedPartner = normalizePartner(evidence.expectedPartner)
	local actualPartner = normalizePartner(partnerName or evidence.actualPartner)
	if not actualPartner then
		return nil, "trade_partner_unavailable"
	end
	if expectedPartner and actualPartner ~= expectedPartner then
		return nil, "trade_partner_changed"
	end

	local sourceDelta = 0
	if evidence.sourceLocationKnown then
		local currentLink = GetContainerItemLink(evidence.bagId, evidence.slotId)
		local sourceAfter = 0
		if itemMatches(currentLink, evidence.itemKey, evidence.itemId) then
			local _, currentCount = GetContainerItemInfo(evidence.bagId, evidence.slotId)
			sourceAfter = tonumber(currentCount) or 1
		end
		sourceDelta = (tonumber(evidence.sourceCount) or 0) - sourceAfter
	end
	local totalAfter = countOwnedItem(evidence.itemKey, evidence.itemId)
	local totalDelta = (tonumber(evidence.totalCount) or 0) - totalAfter
	local awardedCount = sourceDelta
	if totalDelta > awardedCount then
		awardedCount = totalDelta
	end
	local minimumAwardedCount = math.max(1, tonumber(requiredCount) or 1)
	if awardedCount >= minimumAwardedCount then
		return true, awardedCount
	end
	return nil, "trade_transfer_unverified"
end

function Inventory.ResolveInventoryAwardedCount(selectedItemCount, fromInventory)
	local awardedCount = tonumber(selectedItemCount) or 1
	if awardedCount < 1 then
		awardedCount = 1
	end
	if fromInventory and awardedCount > 1 then
		awardedCount = 1
	end
	return awardedCount
end

function Inventory.BuildMultiAwardSlotCandidates(itemLink)
	local slots = {}
	local slotMap = {}
	local wantedKey = Item.GetItemStringFromLink(itemLink) or itemLink
	local wantedId = Item.GetItemIdFromLink(itemLink)

	for slot = 1, GetNumLootItems() do
		local link = GetLootSlotLink(slot)
		if Inventory.LootLinkMatchesTarget(link, itemLink, wantedKey, wantedId) then
			slots[#slots + 1] = slot
			slotMap[slot] = true
		end
	end
	return slots, slotMap
end
