-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: direct addon namespace bindings
-- exports: publish module APIs on addon.*
-- events: none
local addon = select(2, ...)
local Database = addon.Database
local Services = addon.Services

local type, tonumber = type, tonumber

addon.Services.EnsureNamespace("Attendance", "Store")
local Attendance = Services.Attendance
local Store = Attendance.Store

function Store:GetRaid(rID)
	return rID and Database.GetRaidStore():EnsureRaidByIndex(rID) or nil
end

function Store:GetPlayer(raid, playerNid)
	local queryNid = tonumber(playerNid)
	if not (raid and queryNid) then
		return nil
	end
	local runtime = Database.GetRaidStore():EnsureRaidRuntime(raid)
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
