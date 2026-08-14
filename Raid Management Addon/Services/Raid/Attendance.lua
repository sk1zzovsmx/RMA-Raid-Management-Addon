-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: direct addon namespace bindings
-- exports: publish module APIs on addon.*
-- events: consumes RaidRosterDelta
local addon = select(2, ...)
local Database = addon.Database
local Events = addon.Events
local Bus = addon.Bus
local Services = addon.Services
local Time = addon.Time

local InternalEvents = assert(Events.Internal, "Raid attendance internal events are not initialized")
local TriggerEvent = assert(Bus.TriggerEvent, "Raid attendance event publisher is not initialized")
local RegisterCallback = assert(Bus.RegisterCallback, "Raid attendance event bus listener is not initialized")
local RaidAttendanceChangedEvent =
	assert(InternalEvents.RaidAttendanceChanged, "Raid attendance changed event is not initialized")
local RaidRosterDeltaEvent =
	assert(InternalEvents.RaidRosterDelta, "Raid attendance roster-delta event is not initialized")
local RaidCreateEvent = assert(InternalEvents.RaidCreate, "Raid attendance raid-create event is not initialized")

local _G = _G
local GetRaidRosterInfo = assert(_G.GetRaidRosterInfo, "Raid attendance roster info API is not initialized")
local GetNumRaidMembers = assert(_G.GetNumRaidMembers, "Raid attendance roster count API is not initialized")

local tinsert = table.insert
local type, tonumber, strlower = type, tonumber, strlower

local function normalizeName(value)
	if type(value) ~= "string" then
		return nil
	end
	return strlower(value)
end

do
	addon.Services.EnsureNamespace("Raid")
	local Raid = Services.Raid
	local module = Raid

	-- ----- Internal state ----- --

	-- ----- Private helpers ----- --
	local findAttendanceEntry
	local function copyValue(value, seen)
		if type(value) ~= "table" then
			return value
		end
		seen = seen or {}
		if seen[value] then
			return seen[value]
		end
		local copy = {}
		seen[value] = copy
		for key, item in pairs(value) do
			copy[copyValue(key, seen)] = copyValue(item, seen)
		end
		return copy
	end

	local function valuesEqual(left, right)
		if type(left) ~= type(right) then
			return false
		end
		if type(left) ~= "table" then
			return left == right
		end
		for key, value in pairs(left) do
			if not valuesEqual(value, right[key]) then
				return false
			end
		end
		for key in pairs(right) do
			if left[key] == nil then
				return false
			end
		end
		return true
	end

	local function commitAttendanceMutation(raid, stagedRaid, reason, deferPublication)
		local raidNid = tonumber(raid and raid.raidNid)
		if not raidNid then
			return false
		end
		local raidStore = Database.GetRaidStore()
		local raidUid = raidStore:GetRaidUid(raid)
		if not raidUid then
			return false
		end
		local committed = false
		for i = 1, #(stagedRaid.attendance or {}) do
			local candidate = stagedRaid.attendance[i]
			local current = findAttendanceEntry(raid, candidate and candidate.playerNid)
			if not current or not valuesEqual(current, candidate) then
				local event = raidStore:CommitAuthoritativeEvent(raidUid, "ATTENDANCE_UPDATED", {
					attendance = candidate,
				})
				if not event then
					return false
				end
				committed = true
			end
		end
		if not committed then
			return false
		end
		if not deferPublication then
			TriggerEvent(RaidAttendanceChangedEvent, raidNid, reason)
		end
		return true, raidNid
	end

	local function ensureAttendanceTable(raid)
		if type(raid.attendance) ~= "table" then
			raid.attendance = {}
		end
		return raid.attendance
	end

	findAttendanceEntry = function(raid, playerNid)
		local resolvedPlayerNid = tonumber(playerNid) or 0
		local attendance = raid and raid.attendance or nil
		if resolvedPlayerNid <= 0 or type(attendance) ~= "table" then
			return nil
		end

		for i = 1, #attendance do
			local entry = attendance[i]
			if type(entry) == "table" and tonumber(entry.playerNid) == resolvedPlayerNid then
				return entry
			end
		end
		return nil
	end

	local function ensureAttendanceEntry(raid, playerNid)
		local resolvedPlayerNid = tonumber(playerNid) or 0
		if resolvedPlayerNid <= 0 then
			return nil
		end

		local attendance = ensureAttendanceTable(raid)
		local existing = findAttendanceEntry(raid, resolvedPlayerNid)
		if existing then
			if type(existing.segments) ~= "table" then
				existing.segments = {}
			end
			existing.playerNid = resolvedPlayerNid
			return existing
		end

		local entry = {
			playerNid = resolvedPlayerNid,
			segments = {},
		}
		attendance[#attendance + 1] = entry
		return entry
	end

	local function findRaidPlayerByName(raid, playerName)
		local resolvedName = normalizeName(playerName)
		if not resolvedName then
			return nil
		end

		local players = raid and raid.players or nil
		if type(players) ~= "table" then
			return nil
		end

		for i = 1, #players do
			local player = players[i]
			if type(player) == "table" and normalizeName(player.name) == resolvedName then
				return player
			end
		end
		return nil
	end

	local function getOpenSegment(entry)
		local segments = entry and entry.segments or nil
		if type(segments) ~= "table" then
			return nil
		end

		for i = #segments, 1, -1 do
			local segment = segments[i]
			if type(segment) == "table" and not segment.endTime then
				return segment
			end
		end
		return nil
	end

	local function closeOpenSegment(entry, timestamp)
		local segment = getOpenSegment(entry)
		if not segment then
			return false
		end

		local resolvedTimestamp = tonumber(timestamp) or Time.GetCurrentTime()
		local startTime = tonumber(segment.startTime) or resolvedTimestamp
		if resolvedTimestamp < startTime then
			resolvedTimestamp = startTime
		end

		segment.endTime = resolvedTimestamp
		return true
	end

	local function closeAllOpenSegments(entry, timestamp)
		local changed = false
		if type(entry) ~= "table" then
			return false
		end

		local openSegment = getOpenSegment(entry)
		while openSegment do
			changed = closeOpenSegment(entry, timestamp) or changed
			openSegment = getOpenSegment(entry)
		end

		return changed
	end

	local function openSegment(entry, timestamp, subgroup, online)
		local resolvedTimestamp = tonumber(timestamp) or Time.GetCurrentTime()
		local resolvedSubgroup = tonumber(subgroup) or 1
		local resolvedOnline = nil
		if online == false then
			resolvedOnline = false
		end
		local segment = getOpenSegment(entry)

		if segment then
			local segmentSubgroup = tonumber(segment.subgroup) or 1
			local segmentOnline = segment.online
			if segmentSubgroup == resolvedSubgroup and segmentOnline == resolvedOnline then
				return segment, false
			end
			closeOpenSegment(entry, resolvedTimestamp)
			resolvedTimestamp = tonumber(segment.endTime) or resolvedTimestamp
		end

		local newSegment = {
			startTime = resolvedTimestamp,
			subgroup = resolvedSubgroup > 1 and resolvedSubgroup or nil,
		}
		if resolvedOnline == false then
			newSegment.online = false
		end
		tinsert(entry.segments, newSegment)
		return newSegment, true
	end

	local function applyRosterPresence(raid, event, timestamp, isLeaving)
		local playerNid = tonumber(event and event.playerNid) or 0
		if playerNid <= 0 then
			return false
		end

		local entry
		if isLeaving then
			entry = findAttendanceEntry(raid, playerNid)
		else
			entry = ensureAttendanceEntry(raid, playerNid)
		end
		if not entry then
			return false
		end

		if isLeaving then
			if type(entry.segments) ~= "table" then
				return false
			end
			return closeOpenSegment(entry, timestamp)
		end

		local _, changed = openSegment(entry, timestamp, event.subgroup, event.online)
		return changed
	end

	local function applyRosterList(raid, list, timestamp, isLeaving)
		local changed = false
		if type(list) ~= "table" then
			return false
		end

		for i = 1, #list do
			changed = applyRosterPresence(raid, list[i], timestamp, isLeaving) or changed
		end
		return changed
	end

	local function seedFromCurrentRoster(raid, reason)
		local canonicalRaid = raid
		raid = copyValue(canonicalRaid)
		local now = Time.GetCurrentTime()
		local playerCount = tonumber(GetNumRaidMembers()) or 0
		if playerCount <= 0 then
			return false
		end

		local changed = false
		for i = 1, playerCount do
			local name, _, subgroup, _, _, _, _, online = GetRaidRosterInfo(i)
			if type(name) == "string" and name ~= "" then
				local player = findRaidPlayerByName(raid, name)
				if player then
					local entry = ensureAttendanceEntry(raid, player.playerNid)
					if type(entry) == "table" then
						local _, opened = openSegment(entry, tonumber(player.join) or now, subgroup, online)
						changed = opened or changed
					end
				end
			end
		end

		if changed then
			return commitAttendanceMutation(canonicalRaid, raid, reason or "raid_start")
		end
		return changed
	end

	local function handleRosterDelta(_, delta, _, raidNum)
		local resolvedRaidNum = tonumber(raidNum) or tonumber(delta and delta.raidNum) or 0
		if resolvedRaidNum <= 0 or type(delta) ~= "table" then
			return
		end

		local raid = Database.EnsureRaidByIndex(resolvedRaidNum)
		if not raid then
			return
		end
		Database.EnsureRaidSchema(raid)
		local canonicalRaid = raid
		raid = copyValue(canonicalRaid)

		local timestamp = tonumber(delta.timestamp) or Time.GetCurrentTime()
		local joined = applyRosterList(raid, delta.joined, timestamp, false)
		local updated = applyRosterList(raid, delta.updated, timestamp, false)
		local left = applyRosterList(raid, delta.left, timestamp, true)
		local changed = joined or updated or left

		if changed then
			commitAttendanceMutation(canonicalRaid, raid, delta.reason or "attendance_roster")
		end
	end

	-- ----- Public methods ----- --

	function module:SeedAttendanceFromCurrentRoster(raidOrId, reason)
		local raidId = tonumber(raidOrId)
		if not raidId then
			if type(raidOrId) == "table" then
				raidId = tonumber(raidOrId.id) or tonumber(raidOrId.raidNum) or tonumber(raidOrId.raidNid)
			end
		end
		if not raidId then
			return false
		end
		local raid = Database.EnsureRaidByIndex(raidId)
		if not raid then
			return false
		end
		return seedFromCurrentRoster(raid, reason or "raid_start")
	end

	function module:CloseAttendanceForRaid(raidOrId, timestamp, reason, deferPublication)
		local raid = raidOrId
		if type(raidOrId) ~= "table" then
			raid = Database.EnsureRaidByIndex(tonumber(raidOrId) or 0)
		end
		if type(raid) ~= "table" then
			return false
		end
		local canonicalRaid = raid
		raid = copyValue(canonicalRaid)

		local attendance = ensureAttendanceTable(raid)
		local resolvedTimestamp = tonumber(timestamp) or Time.GetCurrentTime()
		local changed = false

		for i = 1, #attendance do
			local entry = attendance[i]
			if type(entry) == "table" and type(entry.segments) == "table" then
				changed = closeAllOpenSegments(entry, resolvedTimestamp) or changed
			end
		end

		if changed then
			return commitAttendanceMutation(canonicalRaid, raid, reason or "attendance_end", deferPublication)
		end
		return changed
	end

	RegisterCallback(RaidRosterDeltaEvent, handleRosterDelta)
	RegisterCallback(RaidCreateEvent, function(_, raidId)
		module:SeedAttendanceFromCurrentRoster(raidId, "raid_start")
	end)
end
