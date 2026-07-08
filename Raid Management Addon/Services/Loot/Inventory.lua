-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: local feature = addon.Database.GetFeatureShared()
-- exports: addon.Services.Loot._Inventory
-- events: none
-- notes: Inventory and awarded-count helpers for loot trade flows

local addon = select(2, ...)
local feature = addon.Database.GetFeatureShared()

local Database = feature.Database
local Services = feature.Services
-- ----- Internal state ----- --

local _G = _G
local GetNumLootItems = assert(_G.GetNumLootItems, "Loot inventory loot count API is not initialized")
local GetLootSlotLink = assert(_G.GetLootSlotLink, "Loot inventory loot slot link API is not initialized")
local GetContainerNumSlots =
	assert(_G.GetContainerNumSlots, "Loot inventory container slot count API is not initialized")
local GetContainerItemLink =
	assert(_G.GetContainerItemLink, "Loot inventory container item link API is not initialized")
local GetContainerItemInfo =
	assert(_G.GetContainerItemInfo, "Loot inventory container item info API is not initialized")

local debugDiag = feature.Diag and feature.Diag.D or {}
local _, lootState, itemInfo = Database.EnsureLootRuntimeState()
local Item = feature.Item

feature.EnsureServiceNamespace("Loot")
local Loot = Services.Loot
local module = Loot
module._Inventory = module._Inventory or {}
local Inventory = module._Inventory

-- ----- Private helpers ----- --

local type, tonumber, tostring = type, tonumber, tostring

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

function Inventory.LootLinkMatchesTarget(slotLink, itemLink, wantedKey, wantedId)
	if not slotLink then
		return false
	end
	if slotLink == itemLink then
		return true
	end
	if wantedKey then
		local slotKey = Item.GetItemStringFromLink(slotLink) or slotLink
		if slotKey == wantedKey then
			return true
		end
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

function Inventory.ResolveTradeAwardedCount()
	local selected = tonumber(lootState.selectedItemCount) or 1
	if selected < 1 then
		selected = 1
	end

	local before = tonumber(itemInfo.tradeStartCount)
	local after = nil
	local source = "fallback"
	local awarded = 1

	local bag = tonumber(itemInfo.tradeStartBag) or tonumber(itemInfo.bagID)
	local slot = tonumber(itemInfo.tradeStartSlot) or tonumber(itemInfo.slotID)
	if bag and slot and before and before > 0 then
		local currentIndex = tonumber(lootState.currentItemIndex) or 1
		local expectedLink = itemInfo.tradeStartItemLink
			or lootState.tradeItemLink
			or (Loot.GetItemLink and Loot.GetItemLink(currentIndex))
		local expectedKey = expectedLink and (Item.GetItemStringFromLink(expectedLink) or expectedLink) or nil
		local afterLink = GetContainerItemLink(bag, slot)
		if not afterLink then
			after = 0
		else
			local afterKey = Item.GetItemStringFromLink(afterLink) or afterLink
			if expectedKey and afterKey == expectedKey then
				local _, count = GetContainerItemInfo(bag, slot)
				after = tonumber(count) or 1
			else
				after = 0
			end
		end

		local delta = before - (after or 0)
		if delta > 0 then
			awarded = delta
			source = "delta"
		end
	end

	if awarded < 1 then
		awarded = 1
	end

	if addon.hasDebug then
		addon:debug(
			debugDiag.LogTradeAwardedCountResolved:format(awarded, source, tostring(before), tostring(after), selected)
		)
	end
	return awarded
end

function Inventory.ResolveInventoryAwardedCount()
	local awardedCount = tonumber(lootState.selectedItemCount) or 1
	if awardedCount < 1 then
		awardedCount = 1
	end
	if lootState.fromInventory and awardedCount > 1 then
		awardedCount = 1
	end
	return awardedCount
end

function Inventory.ResolveInventoryAwardedCountFromArgs(selectedItemCount, fromInventory)
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

local registry = feature.ModuleRegistry
if type(registry) == "table" and type(registry.AddModule) == "function" and type(registry.SetLoaded) == "function" then
	registry.AddModule("Services/Loot/Inventory", {
		deps = {
			"Init",
			"Modules/ModuleRegistry",
			"Modules/Item",
			"Services/Loot/State",
		},
	})
	registry.SetLoaded("Services/Loot/Inventory")
end
