-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: direct addon namespace bindings
-- exports: publish module APIs on addon.*
-- events: none
local addon = select(2, ...)
local L = addon.L
local DB = addon.DB
local Database = addon.Database
local IgnoredMobs = addon.IgnoredMobs

local pairs, type, tonumber = pairs, type, tonumber
local sort = table.sort
local strsub = string.sub
local tostring = tostring
local IsTrashMobName = IgnoredMobs.IsTrashMobName

-- Read-only raid validation service.
do
	DB.RaidValidator = DB.RaidValidator or {}
	local module = DB.RaidValidator
	local function validRaidUid(value)
		return type(value) == "string" and #value >= 1 and #value <= 40 and value:find("[^!-~]") == nil
	end

	-- ----- Internal state ----- --

	-- ----- Private helpers ----- --
	local function pushDetail(result, level, code, data)
		local details = result.details
		details[#details + 1] = {
			level = level,
			code = code,
			data = data or {},
		}

		if level == "E" then
			result.err = result.err + 1
		elseif level == "W" then
			result.warn = result.warn + 1
		else
			result.ok = result.ok + 1
		end
	end

	local function orderedKeys(collection)
		local keys = {}
		if type(collection) ~= "table" then
			return keys
		end
		for key in pairs(collection) do
			keys[#keys + 1] = key
		end
		sort(keys, function(left, right)
			local leftType = type(left)
			local rightType = type(right)
			if leftType == rightType then
				if leftType == "number" or leftType == "string" then
					return left < right
				end
				return tostring(left) < tostring(right)
			end
			return leftType < rightType
		end)
		return keys
	end

	local function validateSequenceKey(result, key, code, dataField)
		if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then
			local data = {}
			data[dataField] = key
			pushDetail(result, "E", code, data)
		end
	end

	local function findPrivateStateKey(value, seen)
		if type(value) ~= "table" then
			return nil
		end
		seen = seen or {}
		if seen[value] then
			return nil
		end
		seen[value] = true
		for key, item in pairs(value) do
			if type(key) == "string" and strsub(key, 1, 1) == "_" then
				return key
			end
			local nested = findPrivateStateKey(item, seen)
			if nested then
				return nested
			end
		end
		return nil
	end

	local function validateRaidSourceKeys(result, raid)
		local key = findPrivateStateKey(raid)
		if key then
			pushDetail(result, "E", "RUNTIME_OUTSIDE", { key = key })
		end
	end

	local function validateSchemaVersion(result, normalized, currentSchemaVersion)
		local schemaVersion = tonumber(normalized.schemaVersion)
		if not schemaVersion then
			pushDetail(result, "E", "SCHEMA_MISSING")
		elseif schemaVersion > currentSchemaVersion then
			pushDetail(result, "E", "SCHEMA_VERSION_FUTURE", {
				schemaVersion = schemaVersion,
				currentVersion = currentSchemaVersion,
			})
		else
			result.ok = result.ok + 1
		end
	end

	local function validatePlayers(result, players)
		local maxPlayerNid = 0
		local playerByNid = {}
		if type(players) ~= "table" then
			pushDetail(result, "E", "PLAYERS_INVALID")
			return maxPlayerNid, playerByNid
		end

		local keys = orderedKeys(players)
		for keyIndex = 1, #keys do
			local i = keys[keyIndex]
			validateSequenceKey(result, i, "PLAYER_KEY_INVALID", "playerIndex")
			local player = players[i]
			if type(player) == "table" then
				local playerNid = tonumber(player.playerNid) or 0
				if playerNid > maxPlayerNid then
					maxPlayerNid = playerNid
				end
				if playerNid > 0 and playerByNid[playerNid] then
					pushDetail(result, "E", "PLAYER_NID_DUPLICATE", { playerIndex = i, playerNid = playerNid })
				elseif playerNid > 0 then
					playerByNid[playerNid] = true
				end

				local countMS = tonumber(player.countMS)
				if countMS == nil then
					pushDetail(result, "E", "PLAYER_COUNT_TYPE", { playerIndex = i })
				elseif countMS < 0 then
					pushDetail(result, "E", "PLAYER_COUNT_NEGATIVE", {
						playerIndex = i,
						value = countMS,
					})
				else
					result.ok = result.ok + 1
				end
			else
				pushDetail(result, "E", "PLAYER_ROW_INVALID", { playerIndex = i })
			end
		end

		return maxPlayerNid, playerByNid
	end

	local function validateBosses(result, bosses, playerByNid)
		local maxBossNid = 0
		local bossByNid = {}
		local hasTrashBoss = false

		if type(bosses) ~= "table" then
			pushDetail(result, "E", "BOSSES_INVALID")
			return 0, {}, false
		end
		local keys = orderedKeys(bosses)
		for keyIndex = 1, #keys do
			local i = keys[keyIndex]
			validateSequenceKey(result, i, "BOSS_KEY_INVALID", "bossIndex")
			local boss = bosses[i]
			if type(boss) == "table" then
				local bossNid = tonumber(boss.bossNid) or 0
				if bossNid > maxBossNid then
					maxBossNid = bossNid
				end
				if bossNid > 0 and bossByNid[bossNid] then
					pushDetail(result, "E", "BOSS_NID_DUPLICATE", { bossIndex = i, bossNid = bossNid })
				elseif bossNid > 0 then
					bossByNid[bossNid] = true
				end
				if IsTrashMobName(boss.name) then
					hasTrashBoss = true
				end

				local attendees = boss.players
				if type(attendees) == "table" then
					local attendeeKeys = orderedKeys(attendees)
					for attendeeKeyIndex = 1, #attendeeKeys do
						local j = attendeeKeys[attendeeKeyIndex]
						validateSequenceKey(result, j, "BOSS_ATTENDEE_KEY_INVALID", "attendeeIndex")
						local attendeeNid = tonumber(attendees[j]) or 0
						if attendeeNid <= 0 then
							pushDetail(result, "E", "BOSS_ATTENDEE_INVALID", {
								bossIndex = i,
								attendeeIndex = j,
							})
						elseif not playerByNid[attendeeNid] then
							pushDetail(result, "E", "BOSS_ATTENDEE_MISSING_PLAYER", {
								bossIndex = i,
								attendeeIndex = j,
								playerNid = attendeeNid,
							})
						else
							result.ok = result.ok + 1
						end
					end
				elseif attendees ~= nil then
					pushDetail(result, "E", "BOSS_PLAYERS_INVALID", { bossIndex = i })
				end
			else
				pushDetail(result, "E", "BOSS_ROW_INVALID", { bossIndex = i })
			end
		end

		return maxBossNid, bossByNid, hasTrashBoss
	end

	local function validateAttendance(result, attendance, playerByNid)
		if type(attendance) ~= "table" then
			pushDetail(result, "E", "ATTENDANCE_INVALID")
			return
		end

		local keys = orderedKeys(attendance)
		for keyIndex = 1, #keys do
			local i = keys[keyIndex]
			validateSequenceKey(result, i, "ATTENDANCE_KEY_INVALID", "attendanceIndex")
			local entry = attendance[i]
			if type(entry) == "table" then
				local playerNid = tonumber(entry.playerNid) or 0
				if playerNid <= 0 then
					pushDetail(result, "E", "ATTENDANCE_PLAYER_INVALID", { attendanceIndex = i })
				elseif not playerByNid[playerNid] then
					pushDetail(result, "E", "ATTENDANCE_PLAYER_MISSING", {
						attendanceIndex = i,
						playerNid = playerNid,
					})
				else
					result.ok = result.ok + 1
				end

				local segments = entry.segments
				if type(segments) == "table" then
					local segmentKeys = orderedKeys(segments)
					for segmentKeyIndex = 1, #segmentKeys do
						local j = segmentKeys[segmentKeyIndex]
						validateSequenceKey(result, j, "ATTENDANCE_SEGMENT_KEY_INVALID", "segmentIndex")
						local segment = segments[j]
						if type(segment) == "table" then
							local startTime = tonumber(segment.startTime) or 0
							local endTime = tonumber(segment.endTime) or 0
							if startTime <= 0 then
								pushDetail(result, "E", "ATTENDANCE_SEGMENT_START_INVALID", {
									attendanceIndex = i,
									segmentIndex = j,
								})
							elseif endTime > 0 and endTime < startTime then
								pushDetail(result, "E", "ATTENDANCE_SEGMENT_END_INVALID", {
									attendanceIndex = i,
									segmentIndex = j,
								})
							else
								result.ok = result.ok + 1
							end
						else
							pushDetail(result, "E", "ATTENDANCE_SEGMENT_ROW_INVALID", {
								attendanceIndex = i,
								segmentIndex = j,
							})
						end
					end
				elseif segments ~= nil then
					pushDetail(result, "E", "ATTENDANCE_SEGMENTS_INVALID", { attendanceIndex = i })
				end
			else
				pushDetail(result, "E", "ATTENDANCE_ROW_INVALID", { attendanceIndex = i })
			end
		end
	end

	local function validateLootRows(result, lootRows, bossByNid, playerByNid, hasTrashBoss)
		local maxLootNid = 0
		local seenLootNids = {}
		if type(lootRows) ~= "table" then
			pushDetail(result, "E", "LOOT_INVALID")
			return 0
		end

		local keys = orderedKeys(lootRows)
		for keyIndex = 1, #keys do
			local i = keys[keyIndex]
			validateSequenceKey(result, i, "LOOT_KEY_INVALID", "lootIndex")
			local loot = lootRows[i]
			if type(loot) == "table" then
				local lootNid = tonumber(loot.lootNid) or 0
				if lootNid > maxLootNid then
					maxLootNid = lootNid
				end
				if lootNid > 0 and seenLootNids[lootNid] then
					pushDetail(result, "E", "LOOT_NID_DUPLICATE", { lootIndex = i, lootNid = lootNid })
				elseif lootNid > 0 then
					seenLootNids[lootNid] = true
				end

				local lootBossNid = tonumber(loot.bossNid) or 0
				if lootBossNid > 0 and not bossByNid[lootBossNid] then
					pushDetail(result, "E", "LOOT_MISSING_BOSS", {
						lootIndex = i,
						bossNid = lootBossNid,
					})
				elseif lootBossNid <= 0 and not hasTrashBoss then
					pushDetail(result, "W", "LOOT_UNKNOWN_BOSS_WITHOUT_TRASH", {
						lootIndex = i,
					})
				else
					result.ok = result.ok + 1
				end

				local looterNid = tonumber(loot.looterNid) or 0
				if looterNid > 0 and not playerByNid[looterNid] then
					pushDetail(result, "E", "LOOT_MISSING_LOOTER", {
						lootIndex = i,
						looterNid = looterNid,
					})
				elseif looterNid <= 0 then
					pushDetail(result, "W", "LOOT_MISSING_LOOTER", {
						lootIndex = i,
					})
				else
					result.ok = result.ok + 1
				end
			else
				pushDetail(result, "E", "LOOT_ROW_INVALID", { lootIndex = i })
			end
		end

		return maxLootNid
	end

	local function validateNidCounter(result, normalized, field, required)
		local actual = tonumber(normalized[field]) or 0
		if actual < required then
			pushDetail(result, "E", "COUNTER_TOO_LOW", {
				field = field,
				actual = actual,
				required = required,
			})
		else
			result.ok = result.ok + 1
		end
	end

	local function validateNidCounters(result, normalized, maxPlayerNid, maxBossNid, maxLootNid)
		validateNidCounter(result, normalized, "nextPlayerNid", maxPlayerNid + 1)
		validateNidCounter(result, normalized, "nextBossNid", maxBossNid + 1)
		validateNidCounter(result, normalized, "nextLootNid", maxLootNid + 1)
	end

	-- ----- Public methods ----- --
	function module:ValidateRaidUid(raidUid)
		if not validRaidUid(raidUid) then
			return nil, "INVALID_RAID_UID"
		end
		return true
	end

	function module:ValidateRecord(record)
		if type(record) ~= "table" then
			return nil, "INVALID_RAID_RECORD"
		end
		if record.status ~= "active" and record.status ~= "complete" then
			return nil, "INVALID_RAID_STATUS"
		end
		if record.sourceRaidUid ~= nil and not validRaidUid(record.sourceRaidUid) then
			return nil, "INVALID_SOURCE_RAID_UID"
		end
		if record.status ~= "complete" and (record.sourceRaidUid ~= nil or record.conflictOfRaidUid ~= nil) then
			return nil, "INVALID_HISTORICAL_PROVENANCE"
		end
		if
			record.conflictOfRaidUid ~= nil
			and (type(record.conflictOfRaidUid) ~= "string" or record.conflictOfRaidUid ~= record.sourceRaidUid)
		then
			return nil, "INVALID_CONFLICT_RAID_UID"
		end
		local epoch = tonumber(record.authorityEpoch)
		local sequence = tonumber(record.sequence)
		local checkpoint = tonumber(record.checkpointSequence)
		if
			not epoch
			or epoch < 1
			or epoch ~= math.floor(epoch)
			or not sequence
			or sequence < 0
			or sequence ~= math.floor(sequence)
			or (record.status == "active" and sequence < 1)
			or not checkpoint
			or checkpoint < 0
			or checkpoint > sequence
			or checkpoint ~= math.floor(checkpoint)
		then
			return nil, "INVALID_RECORD_POSITION"
		end
		if type(record.state) ~= "table" or type(record.events) ~= "table" then
			return nil, "INVALID_RAID_RECORD"
		end
		if findPrivateStateKey(record.state) then
			return nil, "RUNTIME_OUTSIDE"
		end
		if record.status == "active" and record.state.endTime ~= nil then
			return nil, "INVALID_ACTIVE_RAID_STATE"
		end
		if record.status == "complete" and #record.events ~= 0 then
			return nil, "INVALID_COMPLETE_LEDGER"
		end
		if record.status == "complete" then
			local endTime = record.state.endTime
			local startTime = record.state.startTime
			if
				type(endTime) ~= "number"
				or endTime ~= endTime
				or endTime == math.huge
				or endTime == -math.huge
				or endTime < 0
				or endTime > 9999999999
				or endTime ~= math.floor(endTime)
				or (startTime ~= nil and (type(startTime) ~= "number" or endTime < startTime))
			then
				return nil, "INVALID_COMPLETE_RAID_STATE"
			end
		end
		local digest, digestReason = DB.RaidEvents.DigestState(record.state)
		if not digest then
			return nil, digestReason
		end
		if digest ~= record.digest then
			return nil, "DIGEST_MISMATCH"
		end
		local expectedSequence = checkpoint + 1
		local raidUid
		for i = 1, #record.events do
			local event = record.events[i]
			if type(event) ~= "table" or event.resultDigest == nil then
				return nil, "INVALID_RESULT_DIGEST"
			end
			local valid, reason = DB.RaidEvents.ValidateEvent(event)
			if not valid then
				return nil, reason
			end
			if event.authorityEpoch ~= epoch or event.sequence ~= expectedSequence then
				return nil, "INVALID_EVENT_POSITION"
			end
			raidUid = raidUid or event.raidUid
			if event.raidUid ~= raidUid then
				return nil, "INVALID_RAID_UID"
			end
			expectedSequence = expectedSequence + 1
		end
		if expectedSequence - 1 ~= sequence then
			return nil, "EVENT_GAP"
		end
		if #record.events > 0 and record.events[#record.events].resultDigest ~= record.digest then
			return nil, "DIGEST_MISMATCH"
		end
		return true
	end

	function module:ValidateArchive(archive)
		if
			type(archive) ~= "table"
			or archive.formatVersion ~= 1
			or type(archive.order) ~= "table"
			or type(archive.raids) ~= "table"
		then
			return nil, "INVALID_RAID_ARCHIVE"
		end
		local ordered = {}
		for i = 1, #archive.order do
			local raidUid = archive.order[i]
			if type(raidUid) ~= "string" or ordered[raidUid] or type(archive.raids[raidUid]) ~= "table" then
				return nil, "INVALID_ARCHIVE_ORDER"
			end
			ordered[raidUid] = true
		end
		local activeCount, activeRaidUid = 0, nil
		for raidUid, record in pairs(archive.raids) do
			if type(raidUid) ~= "string" or not ordered[raidUid] then
				return nil, "INVALID_ARCHIVE_ORDER"
			end
			local valid, reason = self:ValidateRecord(record)
			if not valid then
				return nil, reason
			end
			if record.status == "active" then
				activeCount = activeCount + 1
				activeRaidUid = raidUid
			end
		end
		if activeCount > 1 then
			return nil, "MULTIPLE_ACTIVE_RAIDS"
		end
		if archive.activeRaidUid == nil then
			if activeCount ~= 0 then
				return nil, "ACTIVE_RAID_POINTER_MISMATCH"
			end
		elseif
			type(archive.activeRaidUid) ~= "string"
			or activeCount ~= 1
			or activeRaidUid ~= archive.activeRaidUid
		then
			return nil, "ACTIVE_RAID_POINTER_MISMATCH"
		end
		return true
	end

	function module:GetRaidRecordValidation(raid, index, currentSchemaVersion)
		local raidNid = type(raid) == "table" and tonumber(raid.raidNid) or nil
		local result = {
			index = index == nil and 0 or index,
			raidNid = raidNid,
			ok = 0,
			warn = 0,
			err = 0,
			details = {},
		}

		if type(raid) ~= "table" then
			pushDetail(result, "E", "RAID_NOT_TABLE")
			return result
		end

		-- Validate source keys directly (without normalization side effects).
		validateRaidSourceKeys(result, raid)
		currentSchemaVersion = tonumber(currentSchemaVersion) or tonumber(Database.GetRaidSchemaVersion()) or 1
		local sourceSchemaVersion = tonumber(raid.schemaVersion)
		if sourceSchemaVersion and sourceSchemaVersion > currentSchemaVersion then
			validateSchemaVersion(result, raid, currentSchemaVersion)
			return result
		end

		validateSchemaVersion(result, raid, currentSchemaVersion)

		local players = raid.players
		local bosses = raid.bossKills
		local lootRows = raid.loot
		local attendance = raid.attendance

		local maxPlayerNid, playerByNid = validatePlayers(result, players)
		validateAttendance(result, attendance, playerByNid)
		local maxBossNid, bossByNid, hasTrashBoss = validateBosses(result, bosses, playerByNid)
		local maxLootNid = validateLootRows(result, lootRows, bossByNid, playerByNid, hasTrashBoss)
		validateNidCounters(result, raid, maxPlayerNid, maxBossNid, maxLootNid)

		return result
	end

	function module:ValidateAllRaids(opts)
		opts = opts or {}
		local includeInfo = opts.includeInfo == true
		local maxDetails = tonumber(opts.maxDetails) or 40
		if maxDetails < 1 then
			maxDetails = 1
		end

		local currentSchemaVersion = Database.GetRaidSchemaVersion() or 1
		currentSchemaVersion = tonumber(currentSchemaVersion) or 1
		if currentSchemaVersion < 1 then
			currentSchemaVersion = 1
		end

		local raids = Database.GetRaidStore():GetRawRaids()
		local report = {
			raids = 0,
			ok = 0,
			warn = 0,
			err = 0,
			currentSchemaVersion = currentSchemaVersion,
			details = {},
			truncatedCount = 0,
		}
		if type(raids) ~= "table" then
			report.err = 1
			report.details[1] = { level = "E", code = "RAIDS_INVALID", data = {}, index = 0 }
			return report
		end

		local raidKeys = orderedKeys(raids)
		report.raids = #raidKeys
		for keyIndex = 1, #raidKeys do
			local i = raidKeys[keyIndex]
			local raidResult = self:GetRaidRecordValidation(raids[i], i, currentSchemaVersion)
			validateSequenceKey(raidResult, i, "RAID_KEY_INVALID", "index")
			report.ok = report.ok + (raidResult.ok or 0)
			report.warn = report.warn + (raidResult.warn or 0)
			report.err = report.err + (raidResult.err or 0)

			local details = raidResult.details or {}
			for j = 1, #details do
				local entry = details[j]
				if entry.level ~= "I" or includeInfo then
					if #report.details < maxDetails then
						report.details[#report.details + 1] = {
							level = entry.level,
							code = entry.code,
							data = entry.data,
							index = raidResult.index,
							raidNid = raidResult.raidNid,
						}
					else
						report.truncatedCount = report.truncatedCount + 1
					end
				end
			end
		end

		return report
	end
end
