-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: local feature = addon.Database.GetFeatureShared()
-- exports: addon.Services.Attendance.Export
-- events: none
local addon = select(2, ...)
local feature = addon.Database.GetFeatureShared()

local Database = feature.Database
local Services = feature.Services

local concat = table.concat
local tostring, tonumber, type = tostring, tonumber, type

feature.EnsureServiceNamespace("Attendance", "Export")
local Attendance = Services.Attendance
local Export = Attendance.Export
local RaidProjections = assert(Services.Raid.Projections, "Attendance export raid projections are not initialized")
local FormatTimestamp = RaidProjections.FormatTimestamp

local HEADER_RAID_ATTENDANCE = {
	"raidNid",
	"raidDate",
	"zone",
	"size",
	"difficulty",
	"playerNid",
	"player",
	"class",
	"join",
	"leave",
	"attendanceSeconds",
	"onlineSeconds",
	"offlineSeconds",
	"segmentCount",
}

local function csvEscape(value)
	value = tostring(value or "")
	if value:find('[,"\n\r]') then
		value = '"' .. value:gsub('"', '""') .. '"'
	end
	return value
end

local function appendCSVLine(lines, fields, encoded, count)
	for i = 1, count do
		encoded[i] = csvEscape(fields[i])
	end
	lines[#lines + 1] = concat(encoded, ",", 1, count)
end

local function finishPerf(label, startedAt, raidNid, rowCount, csv)
	if not (startedAt and addon._PerfFinish) then
		return
	end
	addon:_PerfFinish(
		label,
		startedAt,
		"raid=" .. tostring(raidNid or "") .. " rows=" .. tostring(rowCount or 0) .. " bytes=" .. tostring(#(csv or ""))
	)
end

function Export:GetRaidAttendanceCSV(raid, context)
	if type(raid) ~= "table" then
		return "", "INVALID_RAID"
	end

	local perfStart = addon.hasPerf and addon._PerfStart and addon:_PerfStart() or nil
	local raidMetadata = RaidProjections.BuildExportMetadata(raid)
	local queries = Database.GetRaidQueries()
	local attendanceRows = {}
	queries:GetRaidAttendance(raid, attendanceRows)
	local lines = {}
	local fields = {}
	local encoded = {}
	local rowCount = 0
	appendCSVLine(lines, HEADER_RAID_ATTENDANCE, encoded, #HEADER_RAID_ATTENDANCE)

	for i = 1, #attendanceRows do
		local entry = attendanceRows[i]
		if entry then
			fields[1] = raidMetadata.raidNid
			fields[2] = raidMetadata.raidDate
			fields[3] = raidMetadata.zone
			fields[4] = raidMetadata.size
			fields[5] = raidMetadata.difficulty
			fields[6] = tonumber(entry.id) or ""
			fields[7] = entry.name or ""
			fields[8] = entry.class or ""
			fields[9] = FormatTimestamp(entry.join)
			fields[10] = FormatTimestamp(entry.leave)
			fields[11] = tonumber(entry.attendanceSeconds) or 0
			fields[12] = tonumber(entry.onlineSeconds) or 0
			fields[13] = tonumber(entry.offlineSeconds) or 0
			fields[14] = tonumber(entry.segmentCount) or 0
			rowCount = rowCount + 1
			appendCSVLine(lines, fields, encoded, 14)
		end
	end

	local csv = concat(lines, "\n")
	finishPerf("Attendance.Export.GetRaidAttendanceCSV", perfStart, raidMetadata.raidNid, rowCount, csv)
	return csv
end

local registry = feature.ModuleRegistry
if type(registry) == "table" and type(registry.AddModule) == "function" and type(registry.SetLoaded) == "function" then
	registry.AddModule("Services/Attendance/Export", {
		deps = {
			"Init",
			"Database/DBRaidQueries",
			"Modules/ModuleRegistry",
			"Services/Raid/Projections",
		},
	})
	registry.SetLoaded("Services/Attendance/Export")
end
