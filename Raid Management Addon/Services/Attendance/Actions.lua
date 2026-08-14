-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: direct addon namespace bindings
-- exports: publish module APIs on addon.*
-- events: emits RaidAttendanceChanged after completed mutations
local addon = select(2, ...)
local Database = addon.Database
local Events = addon.Events
local Bus = addon.Bus
local Services = addon.Services

local type, tonumber = type, tonumber

local InternalEvents = assert(Events.Internal, "Attendance actions internal events are not initialized")
local TriggerEvent = assert(Bus.TriggerEvent, "Attendance actions event publisher is not initialized")
local RaidAttendanceChangedEvent =
	assert(InternalEvents.RaidAttendanceChanged, "Attendance actions changed event is not initialized")

addon.Services.EnsureNamespace("Attendance", "Actions")
local Attendance = Services.Attendance
local Actions = Attendance.Actions

function Actions:DeleteRaidAttendance(raidNid, playerNids)
	local resolvedRaidNid = tonumber(raidNid)
	local raidStore = Database.GetRaidStore()
	local raid = resolvedRaidNid and raidStore:EnsureRaidByNid(resolvedRaidNid) or nil
	if not (raid and type(raid.attendance) == "table" and playerNids and #playerNids > 0) then
		return 0
	end

	local selected = {}
	for i = 1, #playerNids do
		local playerNid = tonumber(playerNids[i])
		if playerNid and playerNid > 0 then
			selected[playerNid] = true
		end
	end

	local stagedRaid = raidStore:StageRaidHistoryMutation(raid)
	if not stagedRaid then
		return 0
	end
	local kept = {}
	local removed = 0
	for i = 1, #stagedRaid.attendance do
		local row = stagedRaid.attendance[i]
		local playerNid = tonumber(row and row.playerNid)
		if playerNid and selected[playerNid] then
			removed = removed + 1
		else
			kept[#kept + 1] = row
		end
	end

	if removed == 0 then
		return 0
	end

	stagedRaid.attendance = kept
	local committed = raidStore:CommitAttendanceMutation(raid, stagedRaid, "attendance_delete")
	if committed ~= true then
		return 0
	end
	TriggerEvent(RaidAttendanceChangedEvent, resolvedRaidNid, "attendance_delete")
	return removed
end
