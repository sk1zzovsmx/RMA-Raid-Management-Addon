-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: local feature = addon.Database.GetFeatureShared()
-- exports: addon.Services.Master.LootSpam
-- events: none
-- notes: pure Master loot spam message models
local addon = select(2, ...)
local feature = addon.Database.GetFeatureShared()

local Master = feature.EnsureServiceNamespace("Master")

local LootSpam = Master.LootSpam or {}
Master.LootSpam = LootSpam

local L = feature.L

local type = type
local tonumber = tonumber

-- ----- Internal state ----- --

-- ----- Private helpers ----- --
local function buildHeader(sourceName)
	local template = L.ChatSpamLootFrom
	if sourceName and type(template) == "string" and template:find("%s", 1, true) then
		return template:format(sourceName)
	end
	return L.ChatSpamLoot
end

-- ----- Public methods ----- --

function LootSpam.BuildPlan(opts)
	opts = opts or {}
	local items = opts.items or {}
	local lootLines = {}
	local reservedLines = {}
	local reservedCount = 0

	for i = 1, #items do
		local item = items[i]
		if item and item.itemLink then
			local count = tonumber(item.count) or 1
			local suffix = count > 1 and (" x" .. count) or ""
			lootLines[#lootLines + 1] = (tonumber(item.index) or i) .. ". " .. item.itemLink .. suffix
			if item.reservedPlayers and item.reservedPlayers ~= "" then
				reservedCount = reservedCount + 1
				reservedLines[reservedCount] = (L.ChatSpamLootReservedLine or "%d. %s by %s"):format(
					reservedCount,
					item.itemLink,
					item.reservedPlayers
				)
			end
		end
	end

	return {
		header = buildHeader(opts.sourceName),
		lootLines = lootLines,
		reservedHeader = reservedCount > 0 and (L.ChatSpamLootReservedHeader or "Item reserved:") or nil,
		reservedLines = reservedLines,
	}
end

local registry = feature.ModuleRegistry
if type(registry) == "table" and type(registry.AddModule) == "function" and type(registry.SetLoaded) == "function" then
	registry.AddModule("Services/Master/LootSpam", {
		deps = {
			"Init",
			"Modules/ModuleRegistry",
		},
	})
	registry.SetLoaded("Services/Master/LootSpam")
end
