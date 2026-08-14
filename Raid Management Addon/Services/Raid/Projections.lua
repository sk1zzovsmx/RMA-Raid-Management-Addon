-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: direct addon namespace bindings
-- exports: addon.Services.Raid.Projections
-- events: none
local addon = select(2, ...)
local Database = addon.Database
local Services = addon.Services

local twipe = table.wipe
local type, tostring, tonumber = type, tostring, tonumber
local date = date

addon.Services.EnsureNamespace("Raid", "Projections")
local Projections = Services.Raid.Projections

local function buildRaidListRow(raid, seq, queries)
	if not raid then
		return nil
	end

	local summary = queries:GetRaidSummary(raid)
	local difficulty = tonumber((summary and summary.difficulty) or raid.difficulty)
	local size = (summary and summary.size) or raid.size
	local mode = difficulty and ((difficulty == 3 or difficulty == 4) and "H" or "N") or "?"
	local startTime = (summary and summary.startTime) or raid.startTime
	return {
		id = seq,
		seq = seq,
		zone = raid.zone,
		size = size,
		difficulty = difficulty,
		sizeLabel = tostring(size or "") .. mode,
		date = startTime,
		dateFmt = date("%d/%m/%y %H:%M", startTime),
	}
end

function Projections.FormatTimestamp(value)
	local timestamp = tonumber(value)
	if timestamp and timestamp > 0 then
		return date("%Y-%m-%d %H:%M:%S", timestamp)
	end
	return ""
end

function Projections.GetDifficultyLabel(raid)
	local difficulty = tonumber(raid and raid.difficulty)
	local size = tonumber(raid and raid.size)
	if difficulty == 1 then
		return "10N"
	elseif difficulty == 2 then
		return "25N"
	elseif difficulty == 3 then
		return "10H"
	elseif difficulty == 4 then
		return "25H"
	end
	if size then
		return tostring(size) .. "?"
	end
	return ""
end

function Projections.FillRaidList(out)
	if type(out) ~= "table" then
		return
	end

	twipe(out)
	local raidStore = Database.GetRaidStore()
	local raids = raidStore:GetAllRaids()
	local queries = Database.GetRaidQueries()
	for i = 1, #raids do
		local raid = raidStore:EnsureRaidByIndex(i)
		local row = buildRaidListRow(raid, i, queries)
		if row then
			out[i] = row
		end
	end
end

function Projections.BuildExportMetadata(raid)
	return {
		raidNid = tonumber(raid and raid.raidNid) or "",
		raidDate = Projections.FormatTimestamp(raid and raid.startTime),
		zone = raid and raid.zone or "",
		size = tonumber(raid and raid.size) or "",
		difficulty = tonumber(raid and raid.difficulty) or "",
	}
end
