-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: direct addon namespace bindings
-- exports: addon.Services.Logger.Export
-- events: none
local addon = select(2, ...)
local Database = addon.Database
local Services = addon.Services
local Strings = addon.Strings

local tostring, tonumber, type = tostring, tonumber, type
local concat = table.concat

-- ----- Internal state ----- --
addon.Services.EnsureNamespace("Logger", "Export")
local Logger = Services.Logger
local Export = Logger.Export
local RaidProjections = assert(Services.Raid.Projections, "Logger export raid projections are not initialized")
local FormatTimestamp = RaidProjections.FormatTimestamp
local Store = assert(Logger.Store, "Logger export store is not initialized")
local Helpers = assert(Logger.Helpers, "Logger export helpers are not initialized")
local formatRollTypeForExport = Helpers.FormatRollTypeForExport
local formatRollValueForExport = Helpers.FormatRollValueForExport
local AppendCSVRow = assert(Strings.AppendCSVRow, "Logger CSV row encoder is not initialized")

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
function Export:BuildCSV(raid, context)
	if type(raid) ~= "table" then
		return "", "INVALID_RAID"
	end

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
	AppendCSVRow(lines, HEADER_LOOT, encoded, #HEADER_LOOT)

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
			AppendCSVRow(lines, fields, encoded, 16)
		end
	end

	local csv = concat(lines, "\n")
	finishPerf("Logger.Export.GetLootCSV", perfStart, raidMetadata.raidNid, rowCount, csv)
	return csv
end
