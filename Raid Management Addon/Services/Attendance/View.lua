-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: direct addon namespace bindings
-- exports: publish module APIs on addon.*
-- events: none
local addon = select(2, ...)
local Database = addon.Database
local Services = addon.Services

local type, tostring, tonumber = type, tostring, tonumber
local floor = math.floor

addon.Database.EnsureServiceNamespace("Attendance", "View")
local Attendance = Services.Attendance
local View = Attendance.View

local function getOutputCount(out)
	if type(out) ~= "table" then
		return 0
	end
	return #out
end

local function getRaidPerfId(raid)
	return tostring((raid and raid.raidNid) or "?")
end

local function finishPerf(label, startedAt, raid, out, extraDetails)
	if not (startedAt and addon._PerfFinish) then
		return
	end

	local details = "raid=" .. getRaidPerfId(raid) .. " rows=" .. tostring(getOutputCount(out))
	if extraDetails and extraDetails ~= "" then
		details = details .. " " .. tostring(extraDetails)
	end
	addon:_PerfFinish(label, startedAt, details)
end

local function getEquipInspectSnapshot(raid, playerNid)
	local equipInspect = Services.EquipInspect
	local nid = tonumber(playerNid)
	if not nid then
		return nil
	end

	if equipInspect and type(equipInspect.GetSnapshot) == "function" then
		local snapshot = equipInspect:GetSnapshot(raid, nid)
		if snapshot then
			return snapshot
		end
	end

	local inspectData = raid and raid.inspect
	local players = inspectData and inspectData.players
	if type(players) ~= "table" then
		return nil
	end

	return players[nid] or players[tostring(nid)]
end

local function enrichAttendanceRowsWithInspect(raid, out)
	if type(out) ~= "table" then
		return
	end

	for i = 1, #out do
		local row = out[i]
		local rowId = tonumber(row.playerNid) or tonumber(row.id)
		row.playerNid = rowId

		if rowId then
			local snapshot = getEquipInspectSnapshot(raid, rowId)
			row.inspect = snapshot
			if snapshot then
				local avgIlvl = tonumber(snapshot.avgIlvl)
				row.avgIlvl = avgIlvl
				if avgIlvl and avgIlvl > 0 then
					row.avgIlvlFmt = tostring(floor(avgIlvl + 0.5))
				else
					row.avgIlvlFmt = ""
				end
				row.specName = snapshot.specName
				row.specFmt = snapshot.specName or ""
				row.secondarySpecName = snapshot.secondarySpecName
				row.secondarySpecIcon = snapshot.secondarySpecIcon
			else
				row.avgIlvl = nil
				row.avgIlvlFmt = ""
				row.specName = nil
				row.specFmt = ""
				row.secondarySpecName = nil
				row.secondarySpecIcon = nil
			end
		else
			row.inspect = nil
			row.avgIlvl = nil
			row.avgIlvlFmt = ""
			row.specName = nil
			row.specFmt = ""
			row.secondarySpecName = nil
			row.secondarySpecIcon = nil
		end
	end
end

function View:FillRaidAttendeesList(out, raid)
	local perfStart = addon.hasPerf and addon._PerfStart and addon:_PerfStart() or nil
	local queries = Database.GetRaidQueries()
	local result = queries:GetRaidAttendance(raid, out)
	enrichAttendanceRowsWithInspect(raid, out)
	finishPerf("Attendance.View.FillRaidAttendeesList", perfStart, raid, out)
	return result
end
