-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: local feature = addon.Database.GetFeatureShared()
-- exports: addon.Services.Raid.Projections
-- events: none
local addon = select(2, ...)
local feature = addon.Database.GetFeatureShared()

local Database = feature.Database
local Services = feature.Services

local twipe = table.wipe
local type, tostring, tonumber = type, tostring, tonumber
local date = date

feature.EnsureServiceNamespace("Raid", "Projections")
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
		id = tonumber(raid.raidNid),
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

function Projections.FillRaidList(out, contextTag)
	if type(out) ~= "table" then
		return
	end

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

local registry = feature.ModuleRegistry
if type(registry) == "table" and type(registry.AddModule) == "function" and type(registry.SetLoaded) == "function" then
	registry.AddModule("Services/Raid/Projections", {
		deps = {
			"Init",
			"Modules/ModuleRegistry",
			"Database/DBRaidStore",
			"Database/DBRaidQueries",
		},
	})
	registry.SetLoaded("Services/Raid/Projections")
end
