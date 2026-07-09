-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: local feature = addon.Database.GetFeatureShared()
-- exports: publish module APIs on addon.*
-- events: none
local addon = select(2, ...)
local feature = addon.Database.GetFeatureShared()

local Database = feature.Database
local Services = feature.Services

local twipe = table.wipe
local type, tostring, tonumber = type, tostring, tonumber
local date = date
local floor = math.floor

feature.EnsureServiceNamespace("Attendance", "View")
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

local function buildRaidListRow(raid, seq, queries)
	if not raid then
		return nil
	end

	local summary = queries:GetRaidSummary(raid)
	local row = {}
	row.id = tonumber(raid.raidNid)
	row.seq = seq
	row.zone = raid.zone
	row.size = (summary and summary.size) or raid.size
	row.difficulty = tonumber((summary and summary.difficulty) or raid.difficulty)
	local mode = row.difficulty and ((row.difficulty == 3 or row.difficulty == 4) and "H" or "N") or "?"
	row.sizeLabel = tostring(row.size or "") .. mode
	row.date = (summary and summary.startTime) or raid.startTime
	row.dateFmt = date("%d/%m/%y %H:%M", row.date)
	return row
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

function View:GetRaidDifficultyLabel(raid)
	return Attendance.Store:GetRaidDifficultyLabel(raid)
end

function View:FillRaidAttendeesList(out, raid)
	local perfStart = addon.hasPerf and addon._PerfStart and addon:_PerfStart() or nil
	local queries = Database.GetRaidQueries()
	local result = queries:GetRaidAttendance(raid, out)
	enrichAttendanceRowsWithInspect(raid, out)
	finishPerf("Attendance.View.FillRaidAttendeesList", perfStart, raid, out)
	return result
end

function View:FillRaidList(out, contextTag)
	if type(out) ~= "table" then
		return
	end

	local perfStart = addon.hasPerf and addon._PerfStart and addon:_PerfStart() or nil
	twipe(out)
	local raidStore = Database.GetRaidStoreOrNil(contextTag, { "GetAllRaids", "GetRaidByIndex" })
	local raids = raidStore and raidStore:GetAllRaids() or {}
	local queries = Database.GetRaidQueries()
	for i = 1, #raids do
		local raid = (raidStore and raidStore:GetRaidByIndex(i)) or Database.EnsureRaidById(i)
		local row = buildRaidListRow(raid, i, queries)
		if row then
			out[i] = row
		end
	end
	finishPerf("Attendance.View.FillRaidList", perfStart, nil, out, "context=" .. tostring(contextTag or ""))
end

local registry = feature.ModuleRegistry
if type(registry) == "table" and type(registry.AddModule) == "function" and type(registry.SetLoaded) == "function" then
	registry.AddModule("Services/Attendance/View", {
		deps = {
			"Init",
			"Modules/ModuleRegistry",
			"Database/DBRaidQueries",
			"Services/Attendance/Store",
			"Services/EquipInspect",
		},
	})
	registry.SetLoaded("Services/Attendance/View")
end
