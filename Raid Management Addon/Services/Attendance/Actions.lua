-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: direct addon namespace bindings
-- exports: publish module APIs on addon.*
-- events: none
local addon = select(2, ...)
local Database = addon.Database
local Services = addon.Services

local tinsert = table.insert
local tremove = table.remove
local type, tonumber = type, tonumber

addon.Database.EnsureServiceNamespace("Attendance", "Actions")
local Attendance = Services.Attendance
local Actions = Attendance.Actions
local Store = Attendance.Store

local function touchRaidSyncRevision(raid, reason)
	Database.GetRaidStore():TouchRaidSyncRevision(raid, reason or "attendance")
end

local function normalizeRaidAfterMutation(raid)
	if type(raid) ~= "table" then
		return
	end
	Database.EnsureRaidSchema(raid)
	Store:InvalidateRaidIndexes(raid)
end

function Actions:DeleteRaidAttendees(rID, playerNids)
	local raid = Store:GetRaid(rID)
	if not (raid and raid.players and playerNids and #playerNids > 0) then
		return 0
	end

	local ids = {}
	local seen = {}
	for i = 1, #playerNids do
		local nid = tonumber(playerNids[i]) or playerNids[i]
		if nid ~= nil then
			local _, idx = Store:GetPlayer(raid, nid)
			if idx and not seen[idx] then
				seen[idx] = true
				tinsert(ids, idx)
			end
		end
	end
	table.sort(ids, function(a, b)
		return a > b
	end)

	local removedNids = {}
	local removed = 0
	for i = 1, #ids do
		local idx = ids[i]
		local player = raid.players[idx]
		local playerNid = player and tonumber(player.playerNid)
		if playerNid and playerNid > 0 then
			removedNids[playerNid] = true
			tremove(raid.players, idx)
			removed = removed + 1
		end
	end

	if removed == 0 then
		return 0
	end

	if raid.attendance then
		for i = #raid.attendance, 1, -1 do
			local row = raid.attendance[i]
			local playerNid = tonumber(row and row.playerNid)
			if playerNid and removedNids[playerNid] then
				tremove(raid.attendance, i)
			end
		end
	end

	if raid.bossKills then
		for i = 1, #raid.bossKills do
			local boss = raid.bossKills[i]
			if boss and boss.players then
				for j = #boss.players, 1, -1 do
					local attendeeNid = tonumber(boss.players[j])
					if attendeeNid and removedNids[attendeeNid] then
						tremove(boss.players, j)
					end
				end
			end
		end
	end

	if raid.loot then
		for i = #raid.loot, 1, -1 do
			local loot = raid.loot[i]
			local looterNid = loot and tonumber(loot.looterNid) or nil
			if looterNid and removedNids[looterNid] then
				tremove(raid.loot, i)
			end
		end
	end

	touchRaidSyncRevision(raid, "attendance_delete")
	normalizeRaidAfterMutation(raid)
	return removed
end
