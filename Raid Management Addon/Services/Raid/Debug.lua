-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: direct addon namespace bindings
-- exports: publish module APIs on addon.*
-- events: no direct bus events; publishes synthetic roster deltas through the Raid slice
local addon = select(2, ...)
local L = addon.L
local Diag = addon.Diag
local DebugEntryPoint = assert(addon.EntryPoints.Debug, "Raid debug entrypoint is not initialized")

local Database = addon.Database
local Options = addon.Options
local Services = addon.Services
local Strings = addon.Strings
local Time = addon.Time
local coreState = addon.State
local NormalizeName = assert(Strings.NormalizeName, "Debug synthetic name normalizer is not initialized")
local NormalizeLower = assert(Strings.NormalizeLower, "Debug mode normalizer is not initialized")

local tinsert, tremove = table.insert, table.remove
local pairs, type = pairs, type
local random = math.random
local tostring, tonumber = tostring, tonumber

-- Debug helper module.
-- Seeds a current raid with synthetic players and submits synthetic rolls.
do
	addon.Services.EnsureNamespace("Raid")
	local Raid = Services.Raid
	Raid.Debug = Raid.Debug or {}
	local module = Raid.Debug

	-- ----- Internal state ----- --
	local syntheticProfiles = {
		{ name = "RMADbgWar", class = "WARRIOR", subgroup = 1 },
		{ name = "RMADbgPri", class = "PRIEST", subgroup = 1 },
		{ name = "RMADbgMag", class = "MAGE", subgroup = 2 },
		{ name = "RMADbgRog", class = "ROGUE", subgroup = 2 },
	}
	local syntheticByName = {}
	local GetOption = Options.GetValue
	local IsDebugEnabled = Options.IsDebugEnabled
	local DEFAULT_RAID_GRID_DEBUG_COUNT = 25
	local MAX_RAID_GRID_DEBUG_COUNT = 40
	local MIN_RAID_GRID_DEBUG_COUNT = 1
	local RAID_GRID_DEBUG_CLASSES = {
		"WARRIOR",
		"PALADIN",
		"HUNTER",
		"ROGUE",
		"PRIEST",
		"DEATHKNIGHT",
		"SHAMAN",
		"MAGE",
		"WARLOCK",
		"DRUID",
	}

	-- ----- Private helpers ----- --
	local function normalizeSyntheticName(name)
		return NormalizeName(name, true)
	end

	local function isSyntheticProfileName(name)
		local normalized = normalizeSyntheticName(name)
		return normalized and syntheticByName[normalized] ~= nil
	end

	local function clearTable(map)
		if type(map) ~= "table" then
			return
		end
		for key in pairs(map) do
			map[key] = nil
		end
	end

	local function clampRaidGridDebugCount(count)
		local total = tonumber(count) or DEFAULT_RAID_GRID_DEBUG_COUNT
		total = math.floor(total)
		if total < MIN_RAID_GRID_DEBUG_COUNT then
			total = MIN_RAID_GRID_DEBUG_COUNT
		elseif total > MAX_RAID_GRID_DEBUG_COUNT then
			total = MAX_RAID_GRID_DEBUG_COUNT
		end
		return total
	end

	local function getDebugState()
		coreState.debug = coreState.debug or {}
		coreState.debug.syntheticByRaid = coreState.debug.syntheticByRaid or {}
		return coreState.debug
	end

	local function getCurrentRaidId()
		return Database.GetCurrentRaid()
	end

	local function getCurrentRaid()
		local raidId = getCurrentRaidId()
		if not raidId then
			return nil, nil
		end
		return Database.EnsureRaidByIndex(raidId), raidId
	end

	local function getSyntheticStateForRaid(raidId, create)
		local debugState = getDebugState()
		local syntheticByRaid = debugState.syntheticByRaid
		local key = tonumber(raidId) or -1

		if create and type(syntheticByRaid[key]) ~= "table" then
			syntheticByRaid[key] = {}
		end

		return syntheticByRaid[key], key, syntheticByRaid
	end

	local function rebuildSyntheticState(raid, raidId)
		local raidState, raidKey, syntheticByRaid = getSyntheticStateForRaid(raidId, true)
		clearTable(raidState)

		if type(raid) == "table" and type(raid.players) == "table" then
			for i = 1, #raid.players do
				local player = raid.players[i]
				if
					type(player) == "table"
					and type(player.name) == "string"
					and isSyntheticProfileName(player.name)
				then
					raidState[normalizeSyntheticName(player.name)] = true
				end
			end
		end

		if next(raidState) == nil then
			syntheticByRaid[raidKey] = nil
		end
	end

	local function buildRosterDeltaEntry(player)
		return {
			name = player.name,
			rank = player.rank or 0,
			subgroup = player.subgroup or 1,
			class = player.class or "UNKNOWN",
			unitID = nil,
		}
	end

	local function findSyntheticPlayer(raid, name)
		local targetName = normalizeSyntheticName(name)
		local players = raid and raid.players or {}
		for i = #players, 1, -1 do
			local player = players[i]
			if type(player) == "table" and normalizeSyntheticName(player.name) == targetName then
				return player, i
			end
		end
		return nil, nil
	end

	local function collectProtectedPlayerNids(raid)
		local protected = {}
		local bossKills = raid and raid.bossKills or {}
		local lootRows = raid and raid.loot or {}

		for i = 1, #bossKills do
			local bossKill = bossKills[i]
			local players = bossKill and bossKill.players or {}
			for j = 1, #players do
				local playerNid = tonumber(players[j])
				if playerNid and playerNid > 0 then
					protected[playerNid] = true
				end
			end
		end

		for i = 1, #lootRows do
			local loot = lootRows[i]
			local looterNid = loot and tonumber(loot.looterNid) or nil
			if looterNid and looterNid > 0 then
				protected[looterNid] = true
			end
		end

		return protected
	end

	local function hasSyntheticRollEntries()
		local rolls = Services.Rolls
		local entries = rolls and rolls.GetRolls and rolls:GetRolls() or nil
		if type(entries) ~= "table" then
			return false
		end

		for i = 1, #entries do
			local entry = entries[i]
			if entry and isSyntheticProfileName(entry.name) then
				return true
			end
		end

		return false
	end

	local function clearSyntheticRollStateIfNeeded()
		local rolls = Services.Rolls
		if not (rolls and rolls.ClearRolls and hasSyntheticRollEntries()) then
			return false
		end

		rolls:ClearRolls()
		return true
	end

	local function publishSyntheticDelta(delta, raidId)
		if Raid._PublishRosterDelta then
			Raid._PublishRosterDelta(delta, raidId)
		end
	end

	local function ensureCurrentRaidForDebug()
		local raid, raidId = getCurrentRaid()
		if not raidId or type(raid) ~= "table" then
			return nil, nil, "no_current_raid"
		end
		Database.EnsureRaidSchema(raid)
		return raid, raidId, nil
	end

	local function resolveSyntheticProfile(playerRef)
		local index = tonumber(playerRef)
		local normalized = normalizeSyntheticName(playerRef)
		if index and syntheticProfiles[index] then
			return syntheticProfiles[index]
		end
		return syntheticByName[normalized]
	end

	local function buildSyntheticPlayer(profile, existing, now)
		return {
			playerNid = existing and tonumber(existing.playerNid) or nil,
			name = normalizeSyntheticName(profile.name),
			rank = 0,
			subgroup = profile.subgroup or 1,
			class = profile.class or "UNKNOWN",
			join = (existing and existing.join) or now,
			leave = nil,
			count = (existing and tonumber(existing.count)) or 0,
		}
	end

	local function submitSyntheticRoll(profile, roll, raidId)
		local rolls = Services.Rolls
		local ok
		local reason

		if not (rolls and rolls.SubmitDebugRoll) then
			return nil, "rolls_service_unavailable"
		end

		ok, reason = rolls:SubmitDebugRoll(profile.name, roll)
		if IsDebugEnabled() then
			addon:debug(
				Diag.D.LogDebugRaidRoll:format(tostring(raidId), profile.name, roll, tostring(ok), tostring(reason))
			)
		end

		return {
			raidId = raidId,
			name = profile.name,
			roll = roll,
			ok = ok == true,
			reason = reason,
		},
			nil
	end

	local function buildRaidRollBatch(mode)
		local modeText = NormalizeLower(mode, true)
		local tieMode = modeText == "tie"
		local total = #syntheticProfiles
		local values = {}
		local tiedIndexes = {}
		local tieCount = 0
		local tieRoll = 0
		local wantLow = GetOption("Master", "sortAscending") == true

		if tieMode and total > 1 then
			tieCount = random(2, 3)
			if tieCount > total then
				tieCount = total
			end

			local selected = 0
			while selected < tieCount do
				local idx = random(1, total)
				if not tiedIndexes[idx] then
					tiedIndexes[idx] = true
					selected = selected + 1
				end
			end

			if wantLow then
				tieRoll = random(2, 45)
			else
				tieRoll = random(55, 99)
			end
		else
			tieMode = false
		end

		for i = 1, total do
			if tieMode and tiedIndexes[i] then
				values[i] = tieRoll
			elseif tieMode and wantLow then
				values[i] = random(tieRoll + 1, 100)
			elseif tieMode then
				values[i] = random(1, tieRoll - 1)
			else
				values[i] = random(1, 100)
			end
		end

		return {
			values = values,
			tieMode = tieMode,
			tieCount = tieCount,
			tieRoll = tieRoll,
		}
	end

	for i = 1, #syntheticProfiles do
		local profile = syntheticProfiles[i]
		profile.name = normalizeSyntheticName(profile.name)
		syntheticByName[profile.name] = profile
	end

	-- ----- Public methods ----- --
	function module:SeedRaidPlayers()
		local raidService = Services.Raid
		local raid, raidId, err = ensureCurrentRaidForDebug()
		local delta = {
			joined = {},
			updated = {},
			left = {},
			unresolved = {},
		}
		local now = Time.GetCurrentTime()
		local added = 0
		local refreshed = 0

		if err then
			return nil, err
		end
		if not (raidService and raidService.AddPlayer) then
			return nil, "raid_service_unavailable"
		end

		for i = 1, #syntheticProfiles do
			local profile = syntheticProfiles[i]
			local existing, existingIndex = findSyntheticPlayer(raid, profile.name)
			local player = buildSyntheticPlayer(profile, existing, now)

			if existingIndex and existing and existing.name ~= player.name then
				tremove(raid.players, existingIndex)
				if raidService and raidService.InvalidateRaidRuntime then
					raidService:InvalidateRaidRuntime(raidId)
				end
			end

			raidService:AddPlayer(player, raidId)
			if IsDebugEnabled() then
				addon:debug(Diag.D.LogDebugRaidSeed:format(tostring(raidId), player.name, player.class))
			end

			if not existing or existing.leave ~= nil then
				added = added + 1
				tinsert(delta.joined, buildRosterDeltaEntry(player))
			else
				refreshed = refreshed + 1
				tinsert(delta.updated, buildRosterDeltaEntry(player))
			end
		end

		raid = Database.EnsureRaidByIndex(raidId)
		rebuildSyntheticState(raid, raidId)
		publishSyntheticDelta(delta, raidId)

		return {
			raidId = raidId,
			added = added,
			refreshed = refreshed,
			total = #syntheticProfiles,
		}
	end

	function module:ClearRaidPlayers()
		local raidService = Services.Raid
		local raid, raidId, err = ensureCurrentRaidForDebug()
		local protectedNids
		local removed = 0
		local blocked = 0
		local clearedRolls = false
		local delta = {
			joined = {},
			updated = {},
			left = {},
			unresolved = {},
		}

		if err then
			return nil, err
		end

		protectedNids = collectProtectedPlayerNids(raid)

		for i = #raid.players, 1, -1 do
			local player = raid.players[i]
			if type(player) == "table" and isSyntheticProfileName(player.name) then
				local playerNid = tonumber(player.playerNid) or 0
				if playerNid > 0 and protectedNids[playerNid] then
					blocked = blocked + 1
					if IsDebugEnabled() then
						addon:debug(
							Diag.D.LogDebugRaidClearBlocked:format(tostring(raidId), player.name, tostring(playerNid))
						)
					end
				else
					removed = removed + 1
					tinsert(delta.left, buildRosterDeltaEntry(player))
					tremove(raid.players, i)
					if IsDebugEnabled() then
						addon:debug(
							Diag.D.LogDebugRaidClearRemoved:format(tostring(raidId), player.name, tostring(playerNid))
						)
					end
				end
			end
		end

		if removed > 0 and raidService and raidService.InvalidateRaidRuntime then
			raidService:InvalidateRaidRuntime(raidId)
		end

		rebuildSyntheticState(raid, raidId)

		if removed > 0 then
			clearedRolls = clearSyntheticRollStateIfNeeded()
			publishSyntheticDelta(delta, raidId)
		end

		return {
			raidId = raidId,
			removed = removed,
			blocked = blocked,
			clearedRolls = clearedRolls,
		}
	end

	function module:RollRaidPlayer(playerRef, rollValue)
		local seedResult, seedErr
		local profile = resolveSyntheticProfile(playerRef)
		local roll = tonumber(rollValue)

		if not profile then
			return nil, "unknown_player"
		end

		if roll == nil then
			roll = random(1, 100)
		end
		if roll < 1 or roll > 100 then
			return nil, "invalid_roll"
		end

		seedResult, seedErr = module:SeedRaidPlayers()
		if not seedResult then
			return nil, seedErr
		end

		return submitSyntheticRoll(profile, roll, seedResult.raidId)
	end

	function module:RequestRaidRolls(mode)
		local seedResult, err = module:SeedRaidPlayers()
		local submitted = 0
		local firstFailure = nil
		local rollBatch

		if not seedResult then
			return nil, err
		end

		rollBatch = buildRaidRollBatch(mode)

		for i = 1, #syntheticProfiles do
			local profile = syntheticProfiles[i]
			local result

			result, err = submitSyntheticRoll(profile, rollBatch.values[i], seedResult.raidId)
			if not result then
				return nil, err
			end
			if result.ok then
				submitted = submitted + 1
			elseif not firstFailure then
				firstFailure = result.reason
			end
		end

		return {
			raidId = seedResult.raidId,
			total = #syntheticProfiles,
			submitted = submitted,
			failed = #syntheticProfiles - submitted,
			firstFailure = firstFailure,
			tieMode = rollBatch.tieMode == true,
			tieCount = rollBatch.tieCount or 0,
			tieRoll = rollBatch.tieRoll or 0,
		}
	end

	function module.BuildRaidGridDebugRows(count, rosterRows)
		local total = clampRaidGridDebugCount(count)
		local result = {}
		local seen = {}

		if type(rosterRows) == "table" then
			for i = 1, #rosterRows do
				local row = rosterRows[i]
				local name = row and row.name
				if name and name ~= "" and not seen[name] then
					tinsert(result, {
						name = name,
						displayName = name,
						index = #result + 1,
						class = row.class or RAID_GRID_DEBUG_CLASSES[(#result % #RAID_GRID_DEBUG_CLASSES) + 1],
						debugOnly = true,
						realRoster = true,
					})
					seen[name] = true
				end
			end
		end

		if #result > total then
			total = #result
		end

		local fakeIndex = 1
		while #result < total do
			local name = "Player" .. tostring(fakeIndex)
			fakeIndex = fakeIndex + 1
			if not seen[name] then
				tinsert(result, {
					name = name,
					displayName = name,
					index = #result + 1,
					class = RAID_GRID_DEBUG_CLASSES[(#result % #RAID_GRID_DEBUG_CLASSES) + 1],
					debugOnly = true,
				})
				seen[name] = true
			end
		end

		return result, total
	end

	function module.GetRaidGridDebugTargetCount(debugState)
		return debugState and debugState.raidGridTargetCount or DEFAULT_RAID_GRID_DEBUG_COUNT
	end

	function module.IsRaidGridDebugFallbackEnabled(debugState, debugEnabled)
		if debugState and debugState.raidGridTargetCount then
			return true
		end
		return debugEnabled == true
	end

	local function reportCommandError(reason, playerRef)
		if reason == "no_current_raid" then
			addon:warn(L.MsgDebugRaidNoCurrent)
		elseif reason == "invalid_player" or reason == "unknown_player" then
			addon:warn(L.MsgDebugRaidUnknownPlayer, tostring(playerRef or "?"))
		elseif reason == "invalid_roll" then
			addon:warn(L.MsgDebugRaidInvalidRoll)
		elseif reason == "raid_service_unavailable" then
			addon:warn(L.MsgFeatureUnavailable, "Debug", "raid")
		elseif reason == "rolls_service_unavailable" then
			addon:warn(L.MsgFeatureUnavailable, "Debug", "rolls")
		elseif reason == "record_inactive" or reason == "missing_item" or reason == "session_inactive" then
			addon:warn(L.MsgDebugRaidNoActiveRoll)
		else
			addon:warn(L.MsgDebugRaidRollRejected, tostring(playerRef or "?"), tostring(reason or "unknown"))
		end
	end

	DebugEntryPoint.RegisterCommand("raid", "raid [seed|clear|rolls [tie]|roll <1-4|name> [1-100]]", L.StrCmdDebugRaid, function(argument)
		local command, args = Strings.SplitArgs(argument)
		local result, err
		if command == "seed" or command == "add" then
			result, err = module:SeedRaidPlayers()
			if result then
				addon:info(L.MsgDebugRaidSeeded, result.total, result.added, result.refreshed)
			else
				reportCommandError(err)
			end
			return
		end
		if command == "clear" or command == "reset" then
			result, err = module:ClearRaidPlayers()
			if result then
				addon:info(L.MsgDebugRaidCleared, result.removed, result.blocked)
				if result.clearedRolls then addon:info(L.MsgDebugRaidClearResetRolls) end
			else
				reportCommandError(err)
			end
			return
		end
		if command == "rolls" or command == "all" then
			local mode, extra = Strings.SplitArgs(args)
			if mode == "" then mode = nil end
			if (mode and mode ~= "tie") or (extra and extra ~= "") then
				DebugEntryPoint.ShowHelp()
				return
			end
			result, err = module:RequestRaidRolls(mode)
			if not result then
				reportCommandError(err)
			elseif result.submitted <= 0 and result.firstFailure then
				reportCommandError(result.firstFailure)
			elseif result.failed > 0 and result.firstFailure then
				addon:warn(L.MsgDebugRaidRollsPartial, result.submitted, result.total, tostring(result.firstFailure))
			elseif result.tieMode then
				addon:info(L.MsgDebugRaidRollsTie, result.submitted, result.total, result.tieCount, result.tieRoll)
			else
				addon:info(L.MsgDebugRaidRolls, result.submitted, result.total)
			end
			return
		end
		if command == "roll" then
			local playerRef, rollValue = Strings.SplitArgs(args)
			result, err = module:RollRaidPlayer(playerRef, rollValue)
			if not result then
				reportCommandError(err, playerRef)
			elseif not result.ok then
				reportCommandError(result.reason, result.name)
			else
				addon:info(L.MsgDebugRaidRollSingle, result.name, result.roll)
			end
			return
		end
		DebugEntryPoint.ShowHelp()
	end)
end
