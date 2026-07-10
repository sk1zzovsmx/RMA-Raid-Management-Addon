-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: local feature = addon.Database.GetFeatureShared()
-- exports: publish module APIs on addon.*
-- events: none
local addon = select(2, ...)
local feature = addon.Database.GetFeatureShared()

local Database = feature.Database
local Services = feature.Services

local type, tonumber, tostring = type, tonumber, tostring

feature.EnsureServiceNamespace("Attendance", "Store")
local Attendance = Services.Attendance
local Store = Attendance.Store

local function ensureRaid(raid)
	local raidStore = Database.GetRaidStoreOrNil("Attendance.Store.EnsureRaid", { "NormalizeRaidRecord" })
	if raidStore then
		return raidStore:NormalizeRaidRecord(raid)
	end
	return Database.EnsureRaidSchema(raid)
end

function Store:GetRaid(rID)
	local raidStore = Database.GetRaidStoreOrNil("Attendance.Store.GetRaid", { "GetRaidByIndex" })
	if raidStore then
		local raid = rID and raidStore:GetRaidByIndex(rID) or nil
		if raid then
			ensureRaid(raid)
		end
		return raid
	end
	local raid = rID and Database.EnsureRaidById(rID) or nil
	if raid then
		ensureRaid(raid)
	end
	return raid
end

function Store:GetPlayer(raid, playerNid)
	local queryNid = tonumber(playerNid)
	if not (raid and queryNid) then
		return nil
	end
	local raidStore = Database.GetRaidStoreOrNil("Attendance.Store.GetPlayer", { "EnsureRaidRuntime" })
	local runtime = raidStore and raidStore:EnsureRaidRuntime(raid) or nil
	local idxByNid = runtime and runtime.playerIdxByNid or nil
	local idx = idxByNid and idxByNid[queryNid] or nil
	return idx and raid.players[idx] or nil, idx
end

function Store:InvalidateRaidIndexes(raid)
	if type(raid) ~= "table" then
		return
	end
	Database.StripRuntimeRaidCaches(raid)
end

local registry = feature.ModuleRegistry
if type(registry) == "table" and type(registry.AddModule) == "function" and type(registry.SetLoaded) == "function" then
	registry.AddModule("Services/Attendance/Store", {
		deps = {
			"Init",
			"Modules/ModuleRegistry",
			"Database/DBRaidStore",
		},
	})
	registry.SetLoaded("Services/Attendance/Store")
end
