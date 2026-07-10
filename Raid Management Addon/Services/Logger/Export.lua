-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: local feature = addon.Database.GetFeatureShared()
-- exports: addon.Services.Logger.Export
-- events: none
local addon = select(2, ...)
local feature = addon.Database.GetFeatureShared()

local Database = feature.Database
local Services = feature.Services

local tostring, tonumber, type = tostring, tonumber, type
local concat = table.concat

-- ----- Internal state ----- --
feature.EnsureServiceNamespace("Logger", "Export")
local Logger = Services.Logger
local Export = Logger.Export
local RaidProjections = assert(Services.Raid.Projections, "Logger export raid projections are not initialized")
local FormatTimestamp = RaidProjections.FormatTimestamp
local Store = assert(Logger.Store, "Logger export store is not initialized")
local Helpers = assert(Logger.Helpers, "Logger export helpers are not initialized")
local formatRollTypeForExport = Helpers.FormatRollTypeForExport
local formatRollValueForExport = Helpers.FormatRollValueForExport

local HEADER_LOOT = {
	"raidNid",
	"raidDate",
	"zone",
	"size",
	"difficulty",
	"bossNid",
	"boss",
	"bossTime",
	"lootNid",
	"itemId",
	"itemName",
	"winner",
	"class",
	"rollType",
	"rollValue",
	"lootTime",
}

-- ----- Private helpers ----- --
local function normalizeContext(context)
	return type(context) == "table" and context or {}
end

local function encodeCSVField(value)
	if value == nil then
		return ""
	end

	local text = tostring(value)
	if text:find('[",\r\n]') then
		text = text:gsub('"', '""')
		return '"' .. text .. '"'
	end
	return text
end

local function appendCSVLine(lines, fields, encoded, fieldCount)
	local count = fieldCount or #fields
	for i = 1, count do
		encoded[i] = encodeCSVField(fields[i])
	end
	lines[#lines + 1] = concat(encoded, ",", 1, count)
end

local function finishPerf(label, startedAt, raidNid, rowCount, csvText)
	if not (startedAt and addon._PerfFinish) then
		return
	end

	local resolvedRowCount = tonumber(rowCount) or 0
	local byteCount = type(csvText) == "string" and #csvText or 0
	local details = "raid="
		.. tostring(raidNid or "")
		.. " rows="
		.. tostring(resolvedRowCount)
		.. " bytes="
		.. tostring(byteCount)
	addon:_PerfFinish(label, startedAt, details)
end

local function getSelectedPlayerName(raid, context)
	local selectedPlayerNid = tonumber(context and context.selectedPlayerNid)
	if not selectedPlayerNid then
		return nil
	end

	local player = Store:GetPlayer(raid, selectedPlayerNid)
	return player and player.name or nil
end

local function getBossNameByNid(raid, bossNid)
	local boss = Store:GetBoss(raid, bossNid)
	return boss and boss.name or ""
end

local function getBossTimeByNid(raid, bossNid)
	local boss = Store:GetBoss(raid, bossNid)
	return boss and boss.time or nil
end

-- ----- Public methods ----- --
function Export:GetCSV(mode, raid, context)
	if type(raid) ~= "table" then
		return "", "INVALID_RAID"
	end

	if mode == "loot" then
		return self:GetLootCSV(raid, context)
	end

	return "", "INVALID_MODE"
end

function Export:GetLootCSV(raid, context)
	local perfStart = addon.hasPerf and addon._PerfStart and addon:_PerfStart() or nil
	context = normalizeContext(context)
	local raidMetadata = RaidProjections.BuildExportMetadata(raid)
	local queries = Database.GetRaidQueries()
	local playerName = getSelectedPlayerName(raid, context)
	local lootRows = {}
	queries:GetLoot(raid, context.selectedBossNid, playerName, lootRows)
	local lines = {}
	local fields = {}
	local encoded = {}
	local rowCount = 0
	appendCSVLine(lines, HEADER_LOOT, encoded, #HEADER_LOOT)

	for i = 1, #lootRows do
		local loot = lootRows[i]
		if loot then
			local bossNid = tonumber(loot.bossNid) or ""
			fields[1] = raidMetadata.raidNid
			fields[2] = raidMetadata.raidDate
			fields[3] = raidMetadata.zone
			fields[4] = raidMetadata.size
			fields[5] = raidMetadata.difficulty
			fields[6] = bossNid
			fields[7] = loot.sourceName or getBossNameByNid(raid, bossNid)
			fields[8] = FormatTimestamp(getBossTimeByNid(raid, bossNid))
			fields[9] = tonumber(loot.id) or ""
			fields[10] = tonumber(loot.itemId) or ""
			fields[11] = loot.itemName or ""
			fields[12] = loot.looter or ""
			fields[13] = loot.looterClass or ""
			fields[14] = formatRollTypeForExport(loot.rollType)
			fields[15] = formatRollValueForExport(loot.rollValue)
			fields[16] = FormatTimestamp(loot.time)
			rowCount = rowCount + 1
			appendCSVLine(lines, fields, encoded, 16)
		end
	end

	local csv = concat(lines, "\n")
	finishPerf("Logger.Export.GetLootCSV", perfStart, raidMetadata.raidNid, rowCount, csv)
	return csv
end
local registry = feature.ModuleRegistry
if type(registry) == "table" and type(registry.AddModule) == "function" and type(registry.SetLoaded) == "function" then
	registry.AddModule("Services/Logger/Export", {
		deps = {
			"Init",
			"Database/DBRaidQueries",
			"Modules/ModuleRegistry",
			"Services/Raid/Projections",
			"Services/Logger/Store",
			"Services/Logger/Helpers",
		},
	})
	registry.SetLoaded("Services/Logger/Export")
end
